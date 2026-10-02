#!/usr/bin/env bash
# Tests for bin/review-pr, using stand-in delegate/gh executables and a
# throwaway git repo as CLONE (no network, no models).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REVIEW="$SCRIPT_DIR/../bin/review-pr"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-review-pr.XXXXXX")"
trap 'rm -rf "$T"' EXIT

export TMPDIR="$T/tmp"
mkdir -p "$TMPDIR" "$T/fakebin" "$T/canned" "$T/state"

# --- throwaway repos: ORIGIN carries refs/pull/7/head, CLONE is cloned from it
git init -q "$T/origin"
git -C "$T/origin" config user.email t@t
git -C "$T/origin" config user.name t
echo v1 >"$T/origin/file.txt"
git -C "$T/origin" add .
git -C "$T/origin" commit -qm init
FAKE_SHA="$(git -C "$T/origin" rev-parse HEAD)"
SHORT="${FAKE_SHA:0:8}"
echo v2 >"$T/origin/file.txt"
git -C "$T/origin" diff >"$T/diff.txt"
git -C "$T/origin" checkout -q -- file.txt
git -C "$T/origin" update-ref refs/pull/7/head "$FAKE_SHA"
git clone -q "$T/origin" "$T/clone"
EXPECTED_PID="$(git patch-id --stable <"$T/diff.txt" | awk '{print $1}')"
[ -n "$EXPECTED_PID" ] || fail "fixture patch-id computable"

# --- fake gh
cat >"$T/fakebin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ "\$1" = "pr" ] || { echo "fake gh: only pr supported" >&2; exit 2; }
shift
case "\$1" in
  view) printf '{"headRefOid":"$FAKE_SHA"}\n';;
  diff) cat "$T/diff.txt";;
  checks) cat "$T/checks.txt";;
  comment)
    pr="\$2"; shift 2
    body=""
    while [ \$# -gt 0 ]; do case "\$1" in
      --repo) shift 2;;
      --body-file) body="\$2"; shift 2;;
      *) shift;;
    esac; done
    printf '%s' "\$pr" >"$T/state/comment-pr.txt"
    cp "\$body" "$T/state/comment.md"
    echo "https://example.invalid/x/pull/\$pr"
    ;;
  *) echo "fake gh: unknown \$1" >&2; exit 2;;
esac
EOF

# --- fake delegate: run files the canned record keyed by worktree role
cat >"$T/fakebin/delegate" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cmd="\${1:?}"; shift
case "\$cmd" in
  run)
    model=""; cwd=""; prompt=""
    while [ \$# -gt 0 ]; do case "\$1" in
      --model) model="\$2"; shift 2;;
      --cwd) cwd="\$2"; shift 2;;
      --prompt-file) prompt="\$2"; shift 2;;
      *) shift;;
    esac; done
    role="\${cwd##*-}"
    printf '%s %s\n' "\$role" "\$model" >>"$T/state/runs.txt"
    cp "\$prompt" "$T/state/prompt-\$role.md"
    id="job-\$role"
    mkdir -p "\${TMPDIR:-/tmp}/delegate-jobs"
    cp "$T/canned/\$role.json" "\${TMPDIR:-/tmp}/delegate-jobs/\$id.json"
    printf '%s\n' "\$id"
    ;;
  watch)
    while [ \$# -gt 0 ]; do case "\$1" in --timeout) shift 2;; *) break;; esac; done
    for id in "\$@"; do cat "\${TMPDIR:-/tmp}/delegate-jobs/\$id.json"; done
    ;;
  *) echo "fake delegate: unknown \$cmd" >&2; exit 2;;
esac
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/delegate"
export PATH="$T/fakebin:$PATH"

write_record() {
  # write_record ROLE STATUS TEXT [GATE_EXIT]: GATE_EXIT absent means gateResult null.
  local gate_json="null" text_json
  if [ $# -ge 4 ]; then gate_json="{\"exitCode\": $4}"; fi
  text_json="$(printf '%s' "$3" | jq -Rs .)"
  printf '{"status":"%s","result":{"status":"%s","text":%s,"gateResult":%s}}\n' \
    "$2" "$2" "$text_json" "$gate_json" >"$T/canned/$1.json"
}

reset_state() {
  rm -f "$T/state/runs.txt" "$T/state/comment.md" "$T/state/comment-pr.txt"
  rm -f "$T/state"/prompt-*.md "$TMPDIR"/delegate-jobs/*.json
}

# --- case: review-mode success
reset_state
printf 'ci\tpass\nlint\tpass\n' >"$T/checks.txt"
write_record review DONE "too long, will quote the verdict lines
VERDICT standards: APPROVE
VERDICT spec: CHANGES
P1 fix the off-by-one
STATUS: DONE" 0
write_record ponytail DONE "looks lean
VERDICT: APPROVE
STATUS: DONE" 0
out="$("$REVIEW" 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --ponytail-model M2 2>"$T/stderr.txt")" || fail "success exits 0"
[ "$(printf '%s' "$out" | head -1)" = "patch-id $EXPECTED_PID" ] || fail "success patch-id line"
printf '%s' "$out" | grep -q "^VERDICT spec: CHANGES$" || fail "success carries VERDICT lines"
printf '%s' "$out" | grep -q "^P1 fix the off-by-one$" || fail "success carries P1 lines"
printf '%s' "$out" | grep -q "^CI $SHORT pass$" || fail "success CI line"
printf '%s' "$out" | grep -q UNFINISHED && fail "success has no UNFINISHED"
leftovers="$(printf '%s' "$out" | grep -vE '^(patch-id |VERDICT|P[123] |FIX-OK|FIX-INCOMPLETE|CI |UNFINISHED )' || true)"
[ -z "$leftovers" ] || fail "success stdout shapes only: [$leftovers]"
[ "$(cat "$T/state/comment-pr.txt")" = "7" ] || fail "comment posted to PR 7"
[ "$(head -1 "$T/state/comment.md")" = "review-pr: patch-id $EXPECTED_PID, head $FAKE_SHA" ] || fail "comment first line"
grep -q '^## review (M)$' "$T/state/comment.md" || fail "comment review heading"
grep -q '^## ponytail (M2)$' "$T/state/comment.md" || fail "comment ponytail heading"
grep -q 'P1 fix the off-by-one' "$T/state/comment.md" || fail "comment carries full text"
grep -q 'Code review of PR #7 in O/N for issue #1 (spec #2)' "$T/state/prompt-review.md" || fail "review brief filled"
grep -q '__[A-Z]' "$T/state/prompt-review.md" && fail "review brief has no placeholders left"
grep -q '__[A-Z]' "$T/state/prompt-ponytail.md" && fail "ponytail brief has no placeholders left"
grep -q 'workflow doc is none' "$T/state/prompt-review.md" || fail "workflow doc defaults to none"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-')" = "0" ] || fail "worktrees removed on exit"

# --- case: a job that did not finish is UNFINISHED, never done; exit 1
reset_state
printf 'ci\tfail\n' >"$T/checks.txt"
write_record review ERROR "something broke mid-run"
write_record ponytail DONE "VERDICT: APPROVE
STATUS: DONE" 0
out="$("$REVIEW" 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --ponytail-model M2 2>/dev/null)" && fail "unfinished exits 1"
rec="$TMPDIR/delegate-jobs/job-review.json"
printf '%s' "$out" | grep -q "^UNFINISHED review ERROR gate=none $rec$" || fail "unfinished names role status gate record"
printf '%s' "$out" | grep -q "^CI $SHORT fail$" || fail "failing CI line"

# --- case: DONE without a verdict line is UNFINISHED; exit 1
reset_state
: >"$T/checks.txt"
write_record review DONE "all good, nothing to report
STATUS: DONE" 3
write_record ponytail DONE "VERDICT: APPROVE
STATUS: DONE" 0
out="$("$REVIEW" 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --ponytail-model M2 2>/dev/null)" && fail "no-verdict exits 1"
printf '%s' "$out" | grep -q "^UNFINISHED review DONE gate=3 .*/job-review.json$" || fail "no-verdict UNFINISHED with gate"
printf '%s' "$out" | grep -q "^CI $SHORT none$" || fail "empty checks CI none"

# --- case: verify mode runs one job with SINCE and FINDINGS filled
reset_state
printf 'ci\tpending\n' >"$T/checks.txt"
printf 'P2 findings text & more\n' >"$T/findings.txt"
write_record verify DONE "rechecked
FIX-OK all repaired
STATUS: DONE" 0
out="$("$REVIEW" 7 --repo O/N --cwd "$T/clone" --model M \
  --verify "$T/findings.txt" --since "$FAKE_SHA" 2>"$T/stderr4.txt")" || fail "verify exits 0"
printf '%s' "$out" | grep -q "^FIX-OK all repaired$" || fail "verify carries FIX-OK line"
printf '%s' "$out" | grep -q "^CI $SHORT pending$" || fail "verify pending CI line"
[ "$(wc -l <"$T/state/runs.txt" | tr -d ' ')" = "1" ] || fail "verify runs exactly one job"
grep -q '^verify M$' "$T/state/runs.txt" || fail "verify job role and model"
grep -q "git diff $FAKE_SHA..HEAD" "$T/state/prompt-verify.md" || fail "verify brief SINCE filled"
grep -q 'P2 findings text & more' "$T/state/prompt-verify.md" || fail "verify brief FINDINGS filled"
grep -q '^## verify (M)$' "$T/state/comment.md" || fail "comment verify heading"

# --- case: bad usage exits 2
"$REVIEW" >/dev/null 2>&1; [ "$?" = "2" ] || fail "no args exits 2"
"$REVIEW" 7 --repo O/N --cwd "$T/clone" --model M >/dev/null 2>&1; [ "$?" = "2" ] || fail "review missing flags exits 2"


# --- case: a review with only one axis's verdict is UNFINISHED; exit 1
reset_state
: >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record ponytail DONE "VERDICT: APPROVE
STATUS: DONE" 0
out="$("$REVIEW" 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --ponytail-model M2 2>/dev/null)" && fail "one-axis review exits 1"
printf '%s' "$out" | grep -q "^UNFINISHED review DONE" || fail "one-axis review is UNFINISHED"
echo "review-pr: all cases passed"
