#!/usr/bin/env bash
# Tests for bin/ship-pr: real git on throwaway repos (a bare origin, a clone
# and a linked worktree), a stand-in gh and sleep (no network). The real
# gh-ci and pr-closes run against the stand-in gh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHIP="$SCRIPT_DIR/../bin/ship-pr"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-ship-pr.XXXXXX")"
trap 'rm -rf "$T"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GH_CI_INTERVAL=7 SHIP_PR_INTERVAL=1
MERGE_SHA="1f2e3d4c5b6a79881726354433221100ffeeddcc"

# --- fake gh. Reads $ST (state dir) and $ORIGIN. The PR head is origin's
# --- feature branch, so a push is visible to gh-ci. --jq runs through jq.
mkdir -p "$T/fakebin"
cat >"$T/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >>"$ST/gh.log"
[ "$1" = "pr" ] || { echo "fake gh: only pr supported" >&2; exit 2; }
shift
sub="$1"; shift
rd() { [ -e "$ST/$1" ] && cat "$ST/$1" || echo "$2"; }
case "$sub" in
  view)
    [ ! -e "$ST/view-fail" ] || exit 1
    case " $* " in *" --json body "*) [ ! -e "$ST/body-fail" ] || exit 1;; esac
    if h="$(git --git-dir="$ORIGIN" rev-parse refs/heads/feature 2>/dev/null)"; then
      echo "$h" >"$ST/lasthead"
    else
      h="$(cat "$ST/lasthead")"
    fi
    state="$(rd state OPEN)"
    json="$(jq -nc --arg h "$h" --arg s "$state" --arg d "$(rd draft false)" --arg ms "$(rd merge-state CLEAN)" --arg b "$(rd body 'Resolves #97')" \
      --argjson bn "$([ -e "$ST/body-null" ] && echo true || echo false)" --argjson c "$(rd commits '[]')" --arg m "$MERGE_SHA" \
      '{state:$s, headRefName:"feature", headRefOid:$h, isDraft:($d=="true"), mergeStateStatus:$ms,
        title:"t", body:(if $bn then null else $b end), commits:$c, mergeCommit:(if $s=="MERGED" then {oid:$m} else null end)}')"
    jq=""
    while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && jq="$2"; shift; done
    if [ -n "$jq" ]; then jq -r "$jq" <<<"$json"; else echo "$json"; fi;;
  checks)
    if [ -e "$ST/checks-hook" ]; then bash "$ST/checks-hook"; rm -f "$ST/checks-hook"; fi
    resp="$(cat "$ST/checks")"
    printf '%s\n' "$resp"
    case "$resp" in
      *'"bucket":"fail"'*) exit 1;;
      *'"bucket":"pending"'*) exit 8;;
    esac;;
  ready) echo false >"$ST/draft";;
  merge)
    [ ! -e "$ST/merge-fail" ] || exit 1
    [ -e "$ST/no-merge" ] || echo MERGED >"$ST/state"
    [ ! -e "$ST/merge-deletes-branch" ] || git --git-dir="$ORIGIN" update-ref -d refs/heads/feature;;
  *) echo "fake gh: unknown $sub" >&2; exit 2;;
esac
EOF
printf '#!/usr/bin/env bash\necho "$*" >>"$ST/sleeps.txt"\n' >"$T/fakebin/sleep"
# --- git wrapper: with $ST/delete-fails, `push origin --delete` fails the way
# --- GitHub's does after it auto-deletes the branch on merge.
cat >"$T/fakebin/git" <<EOF
#!/usr/bin/env bash
if [ -e "\$ST/delete-fails" ] && [[ " \$* " == *" push origin --delete "* ]]; then
  echo "error: cannot lock ref 'refs/remotes/origin/feature': unable to resolve reference" >&2
  exit 1
fi
exec "$(command -v git)" "\$@"
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/sleep" "$T/fakebin/git"
export PATH="$T/fakebin:$PATH"

# --- fixture: main with file.txt, feature (one commit) pushed and checked out in $WT.
setup() {
  S="$T/case"; rm -rf "$S"; mkdir -p "$S/st"
  export ST="$S/st" ORIGIN="$S/origin.git" MERGE_SHA
  WT="$S/wt"; C="$S/clone"
  git init -q --bare -b main "$ORIGIN"
  git init -q -b main "$C"
  git -C "$C" remote add origin "$ORIGIN"
  printf 'a\nb\nc\n' >"$C/file.txt"
  git -C "$C" add . && git -C "$C" commit -qm init
  git -C "$C" push -q origin main
  git -C "$C" worktree add -q -b feature "$WT"
  echo feature >"$WT/feature.txt"
  git -C "$WT" add . && git -C "$WT" commit -qm feature
  git -C "$WT" push -q -u origin feature
  HEAD0="$(git -C "$WT" rev-parse HEAD)"
  echo '[{"bucket":"pass","name":"ci"}]' >"$ST/checks"
}

origin_head() { git --git-dir="$ORIGIN" rev-parse --verify -q refs/heads/feature; }
# bump_ref <ref> in origin: a new commit on top, without a checkout.
bump_ref() {
  git --git-dir="$ORIGIN" update-ref "$1" \
    "$(git --git-dir="$ORIGIN" commit-tree "$1^{tree}" -p "$1" -m bump)"
}
# advance_main <file> <content>: a commit on main pushed to origin.
advance_main() {
  printf '%s\n' "$2" >"$C/$1"
  git -C "$C" add . && git -C "$C" commit -qm "main $1"
  git -C "$C" push -q origin main
}
# checks_hook <shell>: runs once, inside the first `gh pr checks`.
checks_hook() { printf '%s\n' "$1" >"$ST/checks-hook"; }

OUT=""; ERR=""; CODE=0
run() {
  O0="$(origin_head)"; W0="$(git -C "$WT" rev-parse HEAD 2>/dev/null)"
  OUT="$("$SHIP" "$@" 2>"$S/stderr.txt")"; CODE=$?
  ERR="$(cat "$S/stderr.txt")"
}
ship() { run 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT" "$@"; }
untouched() {
  [ "$(origin_head)" = "$O0" ] || fail "$1: origin branch unchanged"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$W0" ] || fail "$1: worktree HEAD unchanged"
}
expect() { [ "$CODE" = "$1" ] || fail "$2: exit $1 (got $CODE): out=[$OUT] err=[$ERR]"; }
no_merge() { ! grep -q '^gh pr \(merge\|ready\)' "$ST/gh.log" 2>/dev/null || fail "$1: no ready or merge call"; }

# ===== exit 2: usage and preconditions
setup
for args in "" "abc" "7" "7 --repo O/N --reviewed x" "7 --reviewed x --worktree $WT" \
            "7 --repo O/N --worktree $WT" "7 --repo O/N --reviewed x --worktree $WT --bogus 1" \
            "7 --repo O/N --reviewed x --worktree $WT --timeout x" \
            "7 --repo O/N --reviewed x --worktree $WT --timeout -1" \
            "7 --repo O/N --reviewed x --worktree $WT --gate"; do
  # shellcheck disable=SC2086
  run $args; expect 2 "usage [$args]"; untouched "usage [$args]"
  grep -q '^usage: ship-pr' <<<"$ERR" || fail "usage text for [$args]: [$ERR]"
done

setup; touch "$ST/view-fail"; ship; expect 2 "unreadable PR"; untouched "unreadable PR"
setup; echo CLOSED >"$ST/state"; ship; expect 2 "PR not open"; untouched "PR not open"
setup; run 7 --repo O/N --reviewed "$HEAD0" --worktree "$S"; expect 2 "not a checkout"
setup; git -C "$WT" checkout -q -b other; ship; expect 2 "wrong branch"; untouched "wrong branch"
setup; echo x >>"$WT/feature.txt"; ship; expect 2 "dirty tree"; untouched "dirty tree"
setup; echo x >"$WT/untracked.txt"; ship; expect 2 "untracked file"; untouched "untracked file"
setup; bump_ref refs/heads/feature; ship; expect 2 "HEAD differs from PR head"; untouched "HEAD differs"
setup; run 7 --repo O/N --reviewed deadbeefdeadbeefdeadbeefdeadbeefdeadbeef --worktree "$WT"
expect 2 "unknown reviewed"; untouched "unknown reviewed"
no_merge "preconditions"

# ===== exit 3: rebase conflict aborts cleanly
setup
echo changed >"$WT/file.txt"; git -C "$WT" commit -qam "touch file"; git -C "$WT" push -q origin feature
HEAD0="$(git -C "$WT" rev-parse HEAD)"
advance_main file.txt conflicting
ship; expect 3 "rebase conflict"; untouched "rebase conflict"
for d in rebase-merge rebase-apply; do
  [ ! -e "$(git -C "$WT" rev-parse --git-path $d)" ] || fail "conflict leaves no $d"
done
[ -z "$(git -C "$WT" status --porcelain)" ] || fail "conflict leaves a clean tree"
no_merge "conflict"

# ===== exit 4: a different patch than the reviewed one
setup
git -C "$C" checkout -q -b other
echo other >"$C/other.txt"; git -C "$C" add . && git -C "$C" commit -qm other
OTHER="$(git -C "$C" rev-parse HEAD)"
run 7 --repo O/N --reviewed "$OTHER" --worktree "$WT"; expect 4 "patch-id mismatch"; untouched "patch-id mismatch"
no_merge "mismatch"

# ===== exit 1: gate
setup
ship --gate 'echo gate-line-1; echo gate-line-2; exit 3'
expect 1 "failing gate"; untouched "failing gate"
grep -q gate-line-2 <<<"$OUT" || fail "gate tail on stdout: [$OUT]"
no_merge "failing gate"
setup; advance_main other.txt o
ship --gate 'exit 3'; expect 1 "failing gate after rebase"
[ "$(origin_head)" = "$O0" ] || fail "no push before the gate"
setup; ship --gate 'git commit -q --allow-empty -m gate'
expect 1 "gate that commits"; [ "$(origin_head)" = "$O0" ] || fail "gate commit never pushed"; no_merge "gate commit"
setup; ship --gate 'echo x >>feature.txt'; expect 1 "gate that dirties"; no_merge "gate dirty"
setup; ship --gate 'test "$PWD" = "$(cd "'"$WT"'" && pwd -P)"; test -f feature.txt'
expect 0 "gate runs in the worktree"

# ===== exit 1 and 124: push and CI
setup; echo '[{"bucket":"fail","name":"ci"},{"bucket":"pass","name":"lint"}]' >"$ST/checks"
ship; expect 1 "failing CI"; untouched "failing CI, no rebase, no push"
grep -q '^failing: ci$' <<<"$OUT" || fail "failing line printed: [$OUT]"
no_merge "failing CI"
[ -d "$WT" ] || fail "worktree kept after failing CI"

setup; echo DIRTY >"$ST/merge-state"
ship; expect 3 "conflict after the push"; no_merge "conflict after the push"
grep -q "PR conflicts with origin/main after the push; rebase again, then rerun" <<<"$ERR" || fail "conflict message: [$ERR]"
[ -d "$WT" ] || fail "worktree kept after a conflict"

setup; echo '[{"bucket":"pending","name":"ci"}]' >"$ST/checks"
ship --timeout 0; expect 124 "CI timeout"; no_merge "CI timeout"

setup; echo '[{"bucket":"pending","name":"ci"}]' >"$ST/checks"
ship --timeout 14; expect 124 "CI timeout after sleeps"
[ "$(cat "$ST/sleeps.txt")" = "7
7" ] || fail "timeout counts gh-ci sleeps: [$(cat "$ST/sleeps.txt")]"

setup; advance_main other.txt o
checks_hook 'git --git-dir="$ORIGIN" rev-parse refs/heads/feature >"$ST/at-ci"'
ship; expect 0 "rebased happy path"
PIN="$(sed -n 's/.*--match-head-commit //p' "$ST/gh.log")"
[ "$(cat "$ST/at-ci")" = "$PIN" ] || fail "origin branch is the rebased head before the CI wait"
[ "$PIN" != "$HEAD0" ] || fail "the rebase moved HEAD"

setup; checks_hook 'git --git-dir="$ORIGIN" update-ref refs/heads/feature "$(git --git-dir="$ORIGIN" commit-tree "refs/heads/feature^{tree}" -p refs/heads/feature -m b)"'
ship; expect 1 "CI passes on a moved head"; no_merge "moved head"
grep -q 'other than' <<<"$ERR" || fail "moved head message: [$ERR]"

setup; checks_hook 'git --git-dir="$ORIGIN" update-ref refs/heads/main "$(git --git-dir="$ORIGIN" commit-tree "refs/heads/main^{tree}" -p refs/heads/main -m b)"'
ship; expect 1 "origin/main moved during CI"; no_merge "main moved"
grep -q 'origin/main moved during CI; rerun ship-pr' <<<"$ERR" || fail "main moved message: [$ERR]"
[ -d "$WT" ] || fail "worktree kept when main moved"

# ===== exit 5: stray closing keywords
setup; echo 'Resolves #97. also fixes #9' >"$ST/body"
ship; expect 5 "stray closing keyword"; no_merge "pr-closes"
grep -q '^#9 body: fixes #9$' <<<"$OUT" || fail "stray line printed: [$OUT]"
[ -d "$WT" ] || fail "worktree kept on exit 5"

# ===== --body-has: required PR body lines, checked before any rebase, push or CI call
setup
for args in "--body-has" "--body-has ''" ; do
  # shellcheck disable=SC2086
  eval "ship $args"; expect 2 "usage [$args]"; untouched "usage [$args]"
  grep -q '^usage: ship-pr' <<<"$ERR" || fail "usage text for [$args]: [$ERR]"
done
ship --body-has "$(printf 'a\nb')"; expect 2 "newline prefix"; untouched "newline prefix"
grep -q '^usage: ship-pr' <<<"$ERR" || fail "usage text for newline prefix: [$ERR]"
[ ! -e "$ST/gh.log" ] || fail "bad --body-has makes no gh call"

printf 'Resolves #97\nDoc friction: none\n' >"$ST/body"
ship --body-has 'Resolves #' --body-has 'Doc friction:'; expect 0 "body has every line"

# nothing_ran <name>: exit 5 left origin and worktree alone, made no CI call, kept the worktree.
nothing_ran() {
  expect 5 "$1"; untouched "$1"; no_merge "$1"
  ! grep -q '^gh pr checks' "$ST/gh.log" || fail "$1: no CI call"
  [ -d "$WT" ] || fail "$1: worktree kept"
}
setup; advance_main other.txt o; printf 'Resolves #97\n' >"$ST/body"
ship --body-has 'Resolves #' --body-has 'Doc friction:'; nothing_ran "one line missing"
[ "$OUT" = "missing body line: Doc friction:" ] || fail "one missing line printed: [$OUT]"
grep -q 'PR body lacks required lines; edit the PR body, then rerun' <<<"$ERR" || fail "miss message: [$ERR]"

setup; printf 'x\n' >"$ST/body"
ship --body-has 'Resolves #' --body-has 'Doc friction:'; nothing_ran "two lines missing"
[ "$OUT" = "missing body line: Resolves #
missing body line: Doc friction:" ] || fail "both missing lines printed: [$OUT]"

for b in '  Doc friction: x' 'doc friction: x' 'see Doc friction: x'; do
  setup; printf '%s\n' "$b" >"$ST/body"
  ship --body-has 'Doc friction:'; nothing_ran "no match for [$b]"
done
setup; printf 'Resolves #97\nab\n' >"$ST/body"
ship --body-has 'Resolves #[0-9]*' --body-has 'a.b' --body-has '*'; nothing_ran "glob and regex are literal"
[ "$(wc -l <<<"$OUT")" -eq 3 ] || fail "all three literal prefixes missing: [$OUT]"
setup; printf 'Resolves #[0-9]*: x\na.b\n* item\n' >"$ST/body"
ship --body-has 'Resolves #[0-9]*' --body-has 'a.b' --body-has '*'; expect 0 "literal glob and regex prefixes match"

setup; printf 'Resolves #97\r\nDoc friction: none\r\n' >"$ST/body"
ship --body-has 'Resolves #97' --body-has 'Doc friction: none'; expect 0 "CRLF body"
setup; printf 'Resolves #97\nDoc friction: none' >"$ST/body"
ship --body-has 'Doc friction: none'; expect 0 "no trailing newline"

setup; touch "$ST/body-fail"
ship --body-has 'Resolves #'; expect 2 "body read failure"; untouched "body read failure"
grep -q 'cannot read PR 7 body' <<<"$ERR" || fail "body read message: [$ERR]"
setup; touch "$ST/body-null"
ship --body-has null; nothing_ran "null body"
setup; : >"$ST/body"
ship --body-has x; nothing_ran "empty body"

setup; ship; expect 0 "no --body-has"
! grep -q -- '--json body' "$ST/gh.log" || fail "no --body-has: no body read before pr-closes"

# ===== merge and cleanup
setup; echo true >"$ST/draft"
cd "$WT" || fail "cd worktree"
run 7 --repo O/N --reviewed "$HEAD0" --worktree .
cd "$T" || fail "cd out"
expect 0 "draft happy path"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "merged line: [$OUT]"
grep -q "^gh pr merge 7 --repo O/N --squash --match-head-commit $HEAD0\$" "$ST/gh.log" || fail "merge call: [$(grep merge "$ST/gh.log")]"
[ "$(grep -n '^gh pr ready 7 --repo O/N' "$ST/gh.log" | cut -d: -f1)" -lt "$(grep -n '^gh pr merge' "$ST/gh.log" | cut -d: -f1)" ] \
  || fail "ready runs before merge"
[ ! -e "$WT" ] || fail "worktree removed"
git -C "$C" rev-parse --verify -q refs/heads/feature >/dev/null && fail "local branch deleted"
origin_head >/dev/null && fail "origin branch deleted"

setup; ship; expect 0 "non-draft happy path"
! grep -q '^gh pr ready' "$ST/gh.log" || fail "non-draft never marked ready"
[ ! -e "$WT" ] || fail "non-draft: worktree removed"

setup; touch "$ST/merge-deletes-branch"; ship; expect 0 "remote branch already deleted"
grep -q 'cleanup:' <<<"$ERR" && fail "a missing remote ref counts as done: [$ERR]"

setup; touch "$ST/merge-deletes-branch" "$ST/delete-fails"; ship; expect 0 "auto-deleted remote, push error"
grep -q 'cleanup:' <<<"$ERR" && fail "a missing remote ref counts as done, whatever the push says: [$ERR]"

setup; touch "$ST/delete-fails"; ship; expect 0 "remote delete fails, branch still there"
grep -q 'cleanup: push origin --delete feature failed' <<<"$ERR" || fail "a remote branch still there is reported: [$ERR]"

setup; touch "$ST/no-merge"; ship; expect 1 "never MERGED"
[ -d "$WT" ] || fail "worktree kept when never MERGED"
[ "$(origin_head)" = "$HEAD0" ] || fail "origin branch kept when never MERGED"
[ "$(wc -l <"$ST/sleeps.txt")" -eq 11 ] || fail "11 sleeps across 12 polls: [$(cat "$ST/sleeps.txt")]"

setup; touch "$ST/merge-fail"; ship; expect 1 "merge refused"
[ -d "$WT" ] || fail "worktree kept when the merge is refused"

echo "ship-pr: all cases passed"
