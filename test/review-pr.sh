#!/usr/bin/env bash
# Tests for bin/review-pr start/collect, using stand-in delegate/gh
# executables and a throwaway git repo as CLONE (no network, no models).
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
    printf 'watch %s\n' "\$*" >>"$T/state/watch.txt"
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
  rm -f "$T/state/runs.txt" "$T/state/watch.txt" "$T/state/comment.md" "$T/state/comment-pr.txt"
  rm -f "$T/state"/prompt-*.md "$TMPDIR"/delegate-jobs/*.json "$TMPDIR"/review-pr/* 2>/dev/null || true
}

start_review() {
  # start_review ...args: run review-pr start, stdout is the "<role> <id>" lines.
  "$REVIEW" start "$@"
}

# --- case: review-mode success across start and collect
reset_state
printf 'ci\tpass\nlint\tpass\n' >"$T/checks.txt"
write_record review DONE "too long, will quote the verdict lines
VERDICT standards: APPROVE
VERDICT spec: CHANGES
P1 fix the off-by-one
STATUS: DONE" 0
write_record overbuild DONE "looks lean
VERDICT: APPROVE
STATUS: DONE" 0
start_out="$(start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 2>"$T/stderr.txt")" || fail "start exits 0"
[ "$start_out" = "review job-review
overbuild job-overbuild" ] || fail "start prints one role id line per job: [$start_out]"
[ ! -e "$T/state/comment.md" ] || fail "start posts no comment"
[ -f "$TMPDIR/review-pr/job-review" ] || fail "start saves state findable by job id"
[ -f "$TMPDIR/review-pr/job-overbuild" ] || fail "start saves state for every job"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-')" = "2" ] || fail "start leaves the worktrees for the jobs"
[ ! -e "$T/state/watch.txt" ] || fail "start does not wait"
out="$("$REVIEW" collect job-review job-overbuild 2>"$T/stderr.txt")" || fail "collect exits 0"
[ "$(printf '%s' "$out" | head -1)" = "patch-id $EXPECTED_PID" ] || fail "collect patch-id line"
printf '%s' "$out" | grep -q "^VERDICT spec: CHANGES$" || fail "collect carries VERDICT lines"
printf '%s' "$out" | grep -q "^P1 fix the off-by-one$" || fail "collect carries P1 lines"
printf '%s' "$out" | grep -q "^CI $SHORT pass$" || fail "collect CI line"
printf '%s' "$out" | grep -q UNFINISHED && fail "collect has no UNFINISHED"
leftovers="$(printf '%s' "$out" | grep -vE '^(patch-id |VERDICT|P[123] |FIX-OK|FIX-INCOMPLETE|CI |UNFINISHED |BAD-VERDICT )' || true)"
[ -z "$leftovers" ] || fail "collect stdout shapes only: [$leftovers]"
[ "$(cat "$T/state/comment-pr.txt")" = "7" ] || fail "comment posted to PR 7"
[ "$(head -1 "$T/state/comment.md")" = "review-pr: patch-id $EXPECTED_PID, head $FAKE_SHA" ] || fail "comment first line"
grep -q '^## review (M)$' "$T/state/comment.md" || fail "comment review heading"
grep -q '^## overbuild (M2)$' "$T/state/comment.md" || fail "comment overbuild heading"
grep -q 'P1 fix the off-by-one' "$T/state/comment.md" || fail "comment carries full text"
grep -q 'Code review of PR #7 in O/N for issue #1 (spec #2)' "$T/state/prompt-review.md" || fail "review brief filled"
grep -q '__[A-Z]' "$T/state/prompt-review.md" && fail "review brief has no placeholders left"
grep -q '__[A-Z]' "$T/state/prompt-overbuild.md" && fail "overbuild brief has no placeholders left"
grep -q 'workflow doc is none' "$T/state/prompt-review.md" || fail "workflow doc defaults to none"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-')" = "0" ] || fail "collect removes the worktrees"
[ ! -e "$T/state/watch.txt" ] || fail "collect does not wait"

# --- case: a job that did not finish is UNFINISHED, never done; collect exits 1
reset_state
printf 'ci\tfail\n' >"$T/checks.txt"
write_record review ERROR "something broke mid-run"
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$("$REVIEW" collect job-review job-overbuild 2>/dev/null)" && fail "unfinished collect exits 1"
rec="$TMPDIR/delegate-jobs/job-review.json"
printf '%s' "$out" | grep -q "^UNFINISHED review ERROR gate=none $rec$" || fail "unfinished names role status gate record"
printf '%s' "$out" | grep -q "^CI $SHORT fail$" || fail "failing CI line"
[ "$(cat "$T/state/comment-pr.txt")" = "7" ] || fail "unfinished still posts the comment"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-')" = "0" ] || fail "unfinished still removes worktrees"

# --- case: DONE without a verdict line is UNFINISHED; collect exits 1
reset_state
: >"$T/checks.txt"
write_record review DONE "all good, nothing to report
STATUS: DONE" 3
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$("$REVIEW" collect job-review job-overbuild 2>/dev/null)" && fail "no-verdict collect exits 1"
printf '%s' "$out" | grep -q "^UNFINISHED review DONE gate=3 .*/job-review.json$" || fail "no-verdict UNFINISHED with gate"
printf '%s' "$out" | grep -q "^CI $SHORT none$" || fail "empty checks CI none"

# --- case: a decorated verdict is accepted
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE '  `VERDICT standards: APPROVE`
**VERDICT spec: CHANGES**
P1 a.ts:1 — defect — fix
STATUS: DONE' 0
write_record overbuild DONE '**VERDICT: CHANGES**
P3 a.ts:2 — yagni — cut helper — replace with inline
STATUS: DONE' 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$("$REVIEW" collect job-review job-overbuild 2>/dev/null)" || fail "decorated verdicts collect exits 0"
printf '%s' "$out" | grep -q "^VERDICT standards: APPROVE$" || fail "decorated standards verdict accepted"
printf '%s' "$out" | grep -q "^VERDICT spec: CHANGES$" || fail "decorated spec verdict accepted"
printf '%s' "$out" | grep -q "^VERDICT: CHANGES$" || fail "decorated overbuild verdict accepted"
printf '%s' "$out" | grep -q UNFINISHED && fail "decorated verdicts are finished"
printf '%s' "$out" | grep -q BAD-VERDICT && fail "decorated verdicts are not bad"

# --- case: an unrecognised verdict fails loudly, never UNFINISHED; collect exits 1
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: REQUEST_CHANGES
P3 x.ts:1 — yagni — cut foo — replace with bar
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$("$REVIEW" collect job-review job-overbuild 2>/dev/null)" && fail "bad verdict collect exits 1"
printf '%s' "$out" | grep -q "^BAD-VERDICT overbuild VERDICT: REQUEST_CHANGES$" || fail "bad verdict names role and line"
printf '%s' "$out" | grep -q UNFINISHED && fail "bad verdict is never UNFINISHED"

# --- case: an unknown job id is UNFINISHED; collect exits 1
reset_state
: >"$T/checks.txt"
out="$("$REVIEW" collect job-nope 2>/dev/null)" && fail "unknown id collect exits 1"
printf '%s' "$out" | grep -q "^UNFINISHED job-nope MISSING" || fail "unknown id is UNFINISHED"

# --- case: verify mode runs one job with SINCE and FINDINGS filled
reset_state
printf 'ci\tpending\n' >"$T/checks.txt"
printf 'P2 findings text & more\n' >"$T/findings.txt"
write_record verify DONE "rechecked
FIX-OK all repaired
STATUS: DONE" 0
start_out="$(start_review 7 --repo O/N --cwd "$T/clone" --model M \
  --verify "$T/findings.txt" --since "$FAKE_SHA" 2>"$T/stderr4.txt")" || fail "verify start exits 0"
[ "$start_out" = "verify job-verify" ] || fail "verify start prints its job id: [$start_out]"
out="$("$REVIEW" collect job-verify 2>/dev/null)" || fail "verify collect exits 0"
printf '%s' "$out" | grep -q "^FIX-OK all repaired$" || fail "verify carries FIX-OK line"
printf '%s' "$out" | grep -q "^CI $SHORT pending$" || fail "verify pending CI line"
[ "$(wc -l <"$T/state/runs.txt" | tr -d ' ')" = "1" ] || fail "verify runs exactly one job"
grep -q '^verify M$' "$T/state/runs.txt" || fail "verify job role and model"
grep -q "git diff $FAKE_SHA..HEAD" "$T/state/prompt-verify.md" || fail "verify brief SINCE filled"
grep -q 'P2 findings text & more' "$T/state/prompt-verify.md" || fail "verify brief FINDINGS filled"
grep -q '^## verify (M)$' "$T/state/comment.md" || fail "comment verify heading"

# --- case: bad usage exits 2
"$REVIEW" >/dev/null 2>&1; [ "$?" = "2" ] || fail "no args exits 2"
"$REVIEW" start 7 --repo O/N --cwd "$T/clone" --model M >/dev/null 2>&1; [ "$?" = "2" ] || fail "start missing flags exits 2"
"$REVIEW" collect >/dev/null 2>&1; [ "$?" = "2" ] || fail "collect without ids exits 2"
"$REVIEW" 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1; [ "$?" = "2" ] || fail "old blocking form exits 2"


# --- case: a review with only one axis's verdict is UNFINISHED; collect exits 1
reset_state
: >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$("$REVIEW" collect job-review job-overbuild 2>/dev/null)" && fail "one-axis review collect exits 1"
printf '%s' "$out" | grep -q "^UNFINISHED review DONE" || fail "one-axis review is UNFINISHED"

# --- case: a ticketless PR whose reviewer ends DONE_WITH_CONCERNS with a full verdict
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE_WITH_CONCERNS "VERDICT standards: APPROVE
VERDICT spec: CHANGES
P2 a.sh:1 — defect — fix
STATUS: DONE_WITH_CONCERNS" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$("$REVIEW" collect job-review job-overbuild 2>/dev/null)" || fail "concerns with a verdict collect exits 0"
printf '%s' "$out" | grep -q UNFINISHED && fail "concerns with a verdict is finished"
grep -q 'for issue #7 (spec #7)' "$T/state/prompt-review.md" || fail "ticketless PR is its own issue and spec"
echo "review-pr: all cases passed"
