#!/usr/bin/env bash
# Tests for bin/review-pr start/collect, using stand-in delegate/gh
# functions and a throwaway git repo as CLONE (no network, no models).
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
mkdir -p "$TMPDIR" "$T/canned" "$T/state"

# --- throwaway repos: ORIGIN carries refs/pull/7/head, CLONE is cloned from it
git init -q -b main "$T/origin"
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
# PR 8: NEW_SHA is one commit on top of main (OLD_SHA is main's tip).
OLD_SHA="$FAKE_SHA"
git -C "$T/origin" checkout -q -b feat
echo pr >"$T/origin/pr.txt"
git -C "$T/origin" add pr.txt
git -C "$T/origin" commit -qm pr
NEW_SHA="$(git -C "$T/origin" rev-parse HEAD)"
git -C "$T/origin" checkout -q main
git -C "$T/origin" update-ref refs/pull/8/head "$NEW_SHA"
EXPECTED_NEW_PID="$(git -C "$T/origin" diff "main...$NEW_SHA" | git patch-id --stable | awk '{print $1}')"
[ -n "$EXPECTED_NEW_PID" ] || fail "fixture new patch-id computable"
git clone -q "$T/origin" "$T/clone"
EXPECTED_PID="$(git patch-id --stable <"$T/diff.txt" | awk '{print $1}')"
[ -n "$EXPECTED_PID" ] || fail "fixture patch-id computable"

# --- fake gh
gh() (
  set -euo pipefail
  [ "$1" = "pr" ] || { echo "fake gh: only pr supported" >&2; exit 2; }
  shift
  case "$1" in
    view)
      if [ "${5:-}" = "--json" ] && [ "${6:-}" = "number" ]; then
        if [ -e "$T/state/not-pr" ]; then
          echo "GraphQL: Could not resolve to a PullRequest with the number of $2. (repository.pullRequest)" >&2
          exit 1
        fi
        printf '{"number":%s}\n' "$2"; exit 0
      fi
      h="$FAKE_SHA"
      if [ -f "$T/state/heads.txt" ]; then
        h="$(head -1 "$T/state/heads.txt")"
        if [ "$(wc -l <"$T/state/heads.txt")" -gt 1 ]; then
          tail -n +2 "$T/state/heads.txt" >"$T/state/heads.tmp"; mv "$T/state/heads.tmp" "$T/state/heads.txt"
        fi
      fi
      printf '{"headRefOid":"%s","baseRefName":"main"}\n' "$h";;
    diff) cat "$T/diff.txt";;
    checks) cat "$T/checks.txt";;
    comment)
      if [ -e "$T/state/fail-comment" ]; then echo "fake gh: comment failed" >&2; exit 1; fi
      pr="$2"; shift 2
      body=""
      while [ $# -gt 0 ]; do case "$1" in
        --repo) shift 2;;
        --body-file) body="$2"; shift 2;;
        *) shift;;
      esac; done
      printf '%s' "$pr" >"$T/state/comment-pr.txt"
      cp "$body" "$T/state/comment.md"
      echo "https://example.invalid/x/pull/$pr"
      ;;
    *) echo "fake gh: unknown $1" >&2; exit 2;;
  esac
)

# --- fake delegate: run files the canned record keyed by worktree role
delegate() (
  set -euo pipefail
  cmd="${1:?}"; shift
  case "$cmd" in
    run)
      model=""; cwd=""; prompt=""
      while [ $# -gt 0 ]; do case "$1" in
        --model) model="$2"; shift 2;;
        --cwd) cwd="$2"; shift 2;;
        --prompt-file) prompt="$2"; shift 2;;
        *) shift;;
      esac; done
      role="${cwd##*-}"
      if [ -e "$T/state/fail-$role" ]; then echo "fake delegate: run failed for $role" >&2; exit 1; fi
      printf '%s %s\n' "$role" "$model" >>"$T/state/runs.txt"
      cp "$prompt" "$T/state/prompt-$role.md"
      id="job-$role"
      mkdir -p "${TMPDIR:-/tmp}/delegate-jobs"
      cp "$T/canned/$role.json" "${TMPDIR:-/tmp}/delegate-jobs/$id.json"
      printf '%s\n' "$id"
      ;;
    watch)
      printf 'watch %s\n' "$*" >>"$T/state/watch.txt"
      while [ $# -gt 0 ]; do case "$1" in --timeout) shift 2;; *) break;; esac; done
      for id in "$@"; do cat "${TMPDIR:-/tmp}/delegate-jobs/$id.json"; done
      ;;
    *) echo "fake delegate: unknown $cmd" >&2; exit 2;;
  esac
)
# --- fake sleep: log the call, return at once
sleep() (
  echo "$*" >>"$T/state/sleeps.txt"
)
export T FAKE_SHA
export -f gh delegate sleep

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
  rm -f "$T/state"/fail-* "$T/state/not-pr" "$T/state/heads.txt" "$T/state/sleeps.txt"
  rm -f "$T/state"/prompt-*.md "$TMPDIR"/delegate-jobs/*.json "$TMPDIR"/review-pr/* 2>/dev/null || true
}

start_review() {
  # start_review ...args: run review-pr start, stdout is the "<role> <id>" lines.
  bash "$REVIEW" start "$@"
}

stale_ts_for() {
  # stale_ts_for AGE: touch -t timestamp for AGE (hours by default;
  # trailing h for hours, m for minutes). Keeps bare numbers meaning hours
  # so existing callers are unchanged.
  stale_age_spec="$1"
  case "$stale_age_spec" in
    *m) stale_n="${stale_age_spec%m}"; stale_unit="M"; stale_word="minutes";;
    *h) stale_n="${stale_age_spec%h}"; stale_unit="H"; stale_word="hours";;
    *) stale_n="$stale_age_spec"; stale_unit="H"; stale_word="hours";;
  esac
  date -v-"${stale_n}${stale_unit}" +%Y%m%d%H%M 2>/dev/null || date -d "$stale_n $stale_word ago" +%Y%m%d%H%M
}

stale_state() {
  # stale_state RUN_DIR JID ROLE STATE_AGE STATUS CLONE [RECORD_AGE]: plant
  # one stale-run fixture: a real worktree RUN_DIR/wt-ROLE added from the
  # fixture clone, a state file TMPDIR/review-pr/JID aged STATE_AGE, and,
  # unless STATUS is NOREC, a job record carrying that status aged
  # RECORD_AGE (default STATE_AGE, so existing callers age both together).
  stale_run_dir="$1"; stale_jid="$2"; stale_role="$3"
  stale_age="$4"; stale_status="$5"; stale_clone="$6"
  stale_rec_age="${7:-$4}"
  mkdir -p "$TMPDIR/review-pr" "$TMPDIR/delegate-jobs"
  git -C "$T/clone" worktree add -q --detach "$stale_run_dir/wt-$stale_role" "$FAKE_SHA" || fail "stale fixture worktree setup"
  {
    printf 'role=%s\n' "$stale_role"
    printf 'repo=%s\n' "O/N"
    printf 'pr=%s\n' "7"
    printf 'sha=%s\n' "$FAKE_SHA"
    printf 'patch_id=%s\n' "none"
    printf 'model=%s\n' "M"
    printf 'clone=%s\n' "$stale_clone"
    printf 'worktree=%s\n' "$stale_run_dir/wt-$stale_role"
    printf 'run_dir=%s\n' "$stale_run_dir"
  } >"$TMPDIR/review-pr/$stale_jid"
  if [ "$stale_status" = "NOREC" ]; then
    rm -f "$TMPDIR/delegate-jobs/$stale_jid.json"
  else
    printf '{"status":"%s"}\n' "$stale_status" >"$TMPDIR/delegate-jobs/$stale_jid.json"
    stale_rec_ts="$(stale_ts_for "$stale_rec_age")"
    touch -t "$stale_rec_ts" "$TMPDIR/delegate-jobs/$stale_jid.json" || fail "stale fixture record touch"
  fi
  stale_ts="$(stale_ts_for "$stale_age")"
  touch -t "$stale_ts" "$TMPDIR/review-pr/$stale_jid" || fail "stale fixture touch"
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
overbuild job-overbuild
watch: delegate watch job-review job-overbuild
collect: review-pr collect job-review job-overbuild" ] || fail "start prints a role id line per job, then watch and collect with the ids: [$start_out]"
[ ! -e "$T/state/comment.md" ] || fail "start posts no comment"
[ -f "$TMPDIR/review-pr/job-review" ] || fail "start saves state findable by job id"
[ -f "$TMPDIR/review-pr/job-overbuild" ] || fail "start saves state for every job"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-')" = "2" ] || fail "start leaves the worktrees for the jobs"
[ ! -e "$T/state/watch.txt" ] || fail "start does not wait"
out="$(bash "$REVIEW" collect job-review job-overbuild 2>"$T/stderr.txt")" || fail "collect exits 0"
[ "$(printf '%s' "$out" | head -1)" = "patch-id $EXPECTED_PID" ] || fail "collect patch-id line"
grep -q "^VERDICT spec: CHANGES$" <<<"$out" || fail "collect carries VERDICT lines"
grep -q "^VERDICT overbuild: APPROVE$" <<<"$out" || fail "collect labels the overbuild verdict"
grep -q "^VERDICT: APPROVE$" <<<"$out" && fail "overbuild verdict is never bare"
grep -q "^P1 fix the off-by-one$" <<<"$out" || fail "collect carries P1 lines"
grep -q "^CI $SHORT pass$" <<<"$out" || fail "collect CI line"
grep -q UNFINISHED <<<"$out" && fail "collect has no UNFINISHED"
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
[ -z "$(ls -d "$TMPDIR"/review-pr.run.* 2>/dev/null)" ] || fail "collect removes the run dir"
[ ! -e "$T/state/watch.txt" ] || fail "collect does not wait"

# --- case: repeated --issue values fill the review brief together
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --issue 3 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "multi-issue start exits 0"
grep -q 'Code review of PR #7 in O/N for issue #1 and #3 (spec #2)' \
  "$T/state/prompt-review.md" || fail "review brief joins multiple issues"
grep -q '__[A-Z]' "$T/state/prompt-review.md" && fail "multi-issue review brief has no placeholders"
bash "$REVIEW" collect job-review job-overbuild >/dev/null 2>&1 || fail "multi-issue collect exits 0"

# --- case: three issues keep first-occurrence order and drop duplicates
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --issue 3 --issue 1 --issue 4 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "deduplicated multi-issue start exits 0"
grep -q 'Code review of PR #7 in O/N for issue #1, #3 and #4 (spec #2)' \
  "$T/state/prompt-review.md" || fail "review brief joins three distinct issues in order"
bash "$REVIEW" collect job-review job-overbuild >/dev/null 2>&1 || fail "deduplicated multi-issue collect exits 0"

# --- case: malformed issue values and issues in verify mode fail before launch
for bad_issue in '#3' '3x'; do
  reset_state
  start_review 7 --repo O/N --cwd "$T/clone" --issue "$bad_issue" --spec 2 \
    --model M --overbuild-model M2 >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "malformed --issue $bad_issue exits 2"
  [ ! -e "$T/state/runs.txt" ] || fail "malformed --issue $bad_issue starts no job"
done
reset_state
printf 'P1 findings text\n' >"$T/findings.txt"
start_review 7 --repo O/N --cwd "$T/clone" --model M --verify "$T/findings.txt" \
  --since "$FAKE_SHA" --issue 1 --issue 2 >/dev/null 2>&1
[ "$?" -eq 2 ] || fail "verify rejects repeated --issue values"
[ ! -e "$T/state/runs.txt" ] || fail "verify with --issue starts no job"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)" = "0" ] || \
  fail "verify with --issue creates no worktree"

# --- case: a job that did not finish is UNFINISHED, never done; collect exits 1
reset_state
printf 'ci\tfail\n' >"$T/checks.txt"
write_record review ERROR "something broke mid-run"
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-review job-overbuild 2>/dev/null)" && fail "unfinished collect exits 1"
rec="$TMPDIR/delegate-jobs/job-review.json"
grep -q "^UNFINISHED review ERROR gate=none $rec reason: something broke mid-run$" <<<"$out" || fail "unfinished names role status gate record"
grep -q "^CI $SHORT fail$" <<<"$out" || fail "failing CI line"
[ "$(cat "$T/state/comment-pr.txt")" = "7" ] || fail "unfinished still posts the comment"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-')" = "0" ] || fail "unfinished still removes worktrees"

# --- case: an ERROR job's UNFINISHED line names the reason from the record
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review ERROR "$(printf 'Your authentication token has expired.\nmore')"
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-review job-overbuild 2>/dev/null)" && fail "error reason collect exits 1"
printf '%s\n' "$out" | grep "UNFINISHED review ERROR" | grep -q "reason: Your authentication token has expired\." || fail "ERROR line names the record reason"
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review ERROR ""
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-review job-overbuild 2>/dev/null)" && fail "empty reason collect exits 1"
grep -q "^UNFINISHED review ERROR" <<<"$out" || fail "empty error text is still UNFINISHED"
grep -q "reason:" <<<"$out" && fail "empty error text prints no reason"

# --- case: DONE without a verdict line is UNFINISHED; collect exits 1
reset_state
: >"$T/checks.txt"
write_record review DONE "all good, nothing to report
STATUS: DONE" 3
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-review job-overbuild 2>/dev/null)" && fail "no-verdict collect exits 1"
grep -q "^UNFINISHED review DONE gate=3 .*/job-review.json$" <<<"$out" || fail "no-verdict UNFINISHED with gate"
grep -q "^CI $SHORT none$" <<<"$out" || fail "empty checks CI none"

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
out="$(bash "$REVIEW" collect job-review job-overbuild 2>/dev/null)" || fail "decorated verdicts collect exits 0"
grep -q "^VERDICT standards: APPROVE$" <<<"$out" || fail "decorated standards verdict accepted"
grep -q "^VERDICT spec: CHANGES$" <<<"$out" || fail "decorated spec verdict accepted"
grep -q "^VERDICT overbuild: CHANGES$" <<<"$out" || fail "decorated overbuild verdict accepted"
grep -q UNFINISHED <<<"$out" && fail "decorated verdicts are finished"
grep -q BAD-VERDICT <<<"$out" && fail "decorated verdicts are not bad"

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
out="$(bash "$REVIEW" collect job-review job-overbuild 2>/dev/null)" && fail "bad verdict collect exits 1"
grep -q "^BAD-VERDICT overbuild VERDICT: REQUEST_CHANGES$" <<<"$out" || fail "bad verdict names role and line"
grep -q UNFINISHED <<<"$out" && fail "bad verdict is never UNFINISHED"

# --- case: an unknown job id is UNFINISHED; collect exits 1
reset_state
: >"$T/checks.txt"
out="$(bash "$REVIEW" collect job-nope 2>/dev/null)" && fail "unknown id collect exits 1"
grep -q "^UNFINISHED job-nope MISSING" <<<"$out" || fail "unknown id is UNFINISHED"

# --- case: verify mode runs one job with SINCE and FINDINGS filled
reset_state
printf 'ci\tpending\n' >"$T/checks.txt"
printf 'P2 findings text & more\n' >"$T/findings.txt"
write_record verify DONE "rechecked
FIX-OK all repaired
STATUS: DONE" 0
start_out="$(start_review 7 --repo O/N --cwd "$T/clone" --model M \
  --verify "$T/findings.txt" --since "$FAKE_SHA" 2>"$T/stderr4.txt")" || fail "verify start exits 0"
[ "$start_out" = "verify job-verify
watch: delegate watch job-verify
collect: review-pr collect job-verify" ] || fail "verify start prints its job id, then watch and collect: [$start_out]"
out="$(bash "$REVIEW" collect job-verify 2>/dev/null)" || fail "verify collect exits 0"
grep -q "^FIX-OK all repaired$" <<<"$out" || fail "verify carries FIX-OK line"
grep -q "^CI $SHORT pending$" <<<"$out" || fail "verify pending CI line"
[ "$(wc -l <"$T/state/runs.txt" | tr -d ' ')" = "1" ] || fail "verify runs exactly one job"
grep -q '^verify M$' "$T/state/runs.txt" || fail "verify job role and model"
grep -q "git diff $FAKE_SHA..HEAD" "$T/state/prompt-verify.md" || fail "verify brief SINCE filled"
grep -q 'P2 findings text & more' "$T/state/prompt-verify.md" || fail "verify brief FINDINGS filled"
grep -q '^## verify (M)$' "$T/state/comment.md" || fail "comment verify heading"

# --- case: bad usage exits 2
bash "$REVIEW" >/dev/null 2>&1; [ "$?" = "2" ] || fail "no args exits 2"
bash "$REVIEW" start 7 --repo O/N --cwd "$T/clone" --model M >/dev/null 2>&1; [ "$?" = "2" ] || fail "start missing flags exits 2"
bash "$REVIEW" collect >/dev/null 2>&1; [ "$?" = "2" ] || fail "collect without ids exits 2"
bash "$REVIEW" 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
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
out="$(bash "$REVIEW" collect job-review job-overbuild 2>/dev/null)" && fail "one-axis review collect exits 1"
grep -q "^UNFINISHED review DONE" <<<"$out" || fail "one-axis review is UNFINISHED"

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
out="$(bash "$REVIEW" collect job-review job-overbuild 2>/dev/null)" || fail "concerns with a verdict collect exits 0"
grep -q UNFINISHED <<<"$out" && fail "concerns with a verdict is finished"
grep -q 'for issue #7 (spec #7)' "$T/state/prompt-review.md" || fail "ticketless PR is its own issue and spec"

# --- case: a verdict glued onto narration is no verdict
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "long narration about what to drop no behavior.VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-review job-overbuild 2>/dev/null)" && fail "glued verdict collect exits 1"
grep -q 'UNFINISHED overbuild' <<<"$out" || fail "glued verdict is unfinished overbuild"
grep -q BAD-VERDICT <<<"$out" && fail "glued verdict is not bad"
grep -q '^VERDICT overbuild: APPROVE$' <<<"$out" && fail "glued line is not a verdict line"

# --- case: verify with a finding line that mentions VERDICT and a real FIX-OK line
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
printf 'P2 findings text\n' >"$T/findings.txt"
write_record verify DONE "- P2 fixture/test: fixed. Fixture's final assistant message (line 30) begins \`VERDICT: APPROVE\`, and the test's exact \`assert_eq!\` pins \`\nVERDICT: APPROVE\n\`, asserting the verdict starts a line.
FIX-OK
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --model M \
  --verify "$T/findings.txt" --since "$FAKE_SHA" >/dev/null 2>&1 || fail "verify start exits 0"
out="$(bash "$REVIEW" collect job-verify 2>/dev/null)" || fail "mention plus FIX-OK collect exits 0"
grep -q '^FIX-OK$' <<<"$out" || fail "FIX-OK counts"
grep -q BAD-VERDICT <<<"$out" && fail "mention line is not bad"
grep -q UNFINISHED <<<"$out" && fail "mention plus FIX-OK is finished"

# --- case: prose that merely contains FIX-OK is not a verify verdict
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
printf 'P2 findings text\n' >"$T/findings.txt"
write_record verify DONE "this is not FIX-OK yet
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --model M \
  --verify "$T/findings.txt" --since "$FAKE_SHA" >/dev/null 2>&1 || fail "verify start exits 0"
out="$(bash "$REVIEW" collect job-verify 2>/dev/null)" && fail "not FIX-OK prose collect exits 1"
grep -q 'UNFINISHED verify' <<<"$out" || fail "not FIX-OK prose is unfinished verify"
grep -q '^FIX-OK$' <<<"$out" && fail "not FIX-OK prose is not FIX-OK"
grep -q BAD-VERDICT <<<"$out" && fail "not FIX-OK prose is not bad"

# --- case: a bare FIX-OK line is a verdict
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
printf 'P2 findings text\n' >"$T/findings.txt"
write_record verify DONE "FIX-OK" 0
start_review 7 --repo O/N --cwd "$T/clone" --model M \
  --verify "$T/findings.txt" --since "$FAKE_SHA" >/dev/null 2>&1 || fail "verify start exits 0"
out="$(bash "$REVIEW" collect job-verify 2>/dev/null)" || fail "bare FIX-OK collect exits 0"
grep -q "^FIX-OK$" <<<"$out" || fail "bare FIX-OK counts"
grep -q BAD-VERDICT <<<"$out" && fail "bare FIX-OK is not bad"

# --- case: prose or a finding that merely mentions VERDICT is no verdict attempt
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
the word VERDICT appears here in plain prose
P3 x.ts:1 — yagni — cut VERDICT helper — replace with inline
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-review job-overbuild 2>/dev/null)" || fail "verdict mention collect exits 0"
grep -q BAD-VERDICT <<<"$out" && fail "a VERDICT mention is not a bad verdict"
grep -q UNFINISHED <<<"$out" && fail "a VERDICT mention is finished"

# --- case: a RUNNING job waits: no post, nothing removed, retry collects
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review RUNNING "still working, no verdict yet"
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-review job-overbuild 2>/dev/null)" && fail "running collect exits 1"
[ "$out" = "RUNNING review job-review: wait with delegate watch job-review job-overbuild" ] || \
  fail "running line names role id and watch: [$out]"
[ ! -e "$T/state/comment.md" ] || fail "running collect posts no comment"
[ -f "$TMPDIR/review-pr/job-review" ] || fail "running collect keeps state for the retry"
[ -f "$TMPDIR/review-pr/job-overbuild" ] || fail "running collect keeps the sibling state"
rd="$(sed -n 's/^run_dir=//p' "$TMPDIR/review-pr/job-review")"
[ -n "$rd" ] && [ -d "$rd" ] || fail "running collect keeps the run dir"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-')" = "2" ] || fail "running collect keeps the worktrees"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
cp "$T/canned/review.json" "$TMPDIR/delegate-jobs/job-review.json"
out="$(bash "$REVIEW" collect job-review job-overbuild 2>/dev/null)" || fail "retry after running exits 0"
grep -q "^VERDICT standards: APPROVE$" <<<"$out" || fail "retry carries the review verdict"
grep -q "^VERDICT overbuild: APPROVE$" <<<"$out" || fail "retry carries the labelled overbuild verdict"
grep -q UNFINISHED <<<"$out" && fail "retry is finished"

# --- case: collect with only one role's job id fails before posting and keeps state
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-review 2>/dev/null)" && fail "partial collect exits 1"
grep -q "^UNFINISHED overbuild MISSING" <<<"$out" || fail "partial collect names the missing role"
[ ! -e "$T/state/comment.md" ] || fail "partial collect posts no comment"
[ -f "$TMPDIR/review-pr/job-review" ] || fail "partial collect keeps state for the retry"
[ -f "$TMPDIR/review-pr/job-overbuild" ] || fail "partial collect keeps the sibling state"
out="$(bash "$REVIEW" collect job-review job-overbuild 2>/dev/null)" || fail "retry with both ids exits 0"
grep -q UNFINISHED <<<"$out" && fail "retry is finished"

# --- case: a failed comment post keeps state for the retry
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
touch "$T/state/fail-comment"
bash "$REVIEW" collect job-review job-overbuild >/dev/null 2>&1 && fail "failed post collect exits nonzero"
[ -f "$TMPDIR/review-pr/job-review" ] || fail "failed post keeps state"
[ -f "$TMPDIR/review-pr/job-overbuild" ] || fail "failed post keeps every state"
rm -f "$T/state/fail-comment"
out="$(bash "$REVIEW" collect job-review job-overbuild 2>/dev/null)" || fail "retry after failed post exits 0"
[ "$(cat "$T/state/comment-pr.txt")" = "7" ] || fail "retry posts the comment"

# --- case: a failing second start leaves the launched job's worktree and state
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
touch "$T/state/fail-overbuild"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 && fail "start with a failing job exits nonzero"
rm -f "$T/state/fail-overbuild"
[ -f "$TMPDIR/review-pr/job-review" ] || fail "failed start keeps the launched state"
wt="$(sed -n 's/^worktree=//p' "$TMPDIR/review-pr/job-review")"
rd="$(sed -n 's/^run_dir=//p' "$TMPDIR/review-pr/job-review")"
[ -n "$wt" ] && [ -d "$wt" ] || fail "failed start keeps the launched worktree"
git -C "$T/clone" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
rm -rf "$rd"
rm -f "$TMPDIR/review-pr/job-review"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-')" = "0" ] || fail "failed-start cleanup leaves no worktree"
# --- case: --head with a lagging API head: wait, then review exactly the pushed head
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
printf '%s\n%s\n%s\n' "$OLD_SHA" "$OLD_SHA" "$NEW_SHA" >"$T/state/heads.txt"
start_review 8 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 \
  --head "$NEW_SHA" >/dev/null 2>&1 || fail "--head lagging start exits 0"
[ "$(wc -l <"$T/state/sleeps.txt")" -eq 2 ] || fail "--head lagging sleeps twice"
wt="$(sed -n 's/^worktree=//p' "$TMPDIR/review-pr/job-review")"
[ "$(git -C "$wt" rev-parse HEAD)" = "$NEW_SHA" ] || fail "--head worktree is at the expected head"
[ "$(sed -n 's/^sha=//p' "$TMPDIR/review-pr/job-review")" = "$NEW_SHA" ] || fail "--head state sha"
[ "$(sed -n 's/^patch_id=//p' "$TMPDIR/review-pr/job-review")" = "$EXPECTED_NEW_PID" ] || fail "--head state patch_id"
bash "$REVIEW" collect job-review job-overbuild >/dev/null 2>&1 || fail "--head collect exits 0"
[ "$(head -1 "$T/state/comment.md")" = "review-pr: patch-id $EXPECTED_NEW_PID, head $NEW_SHA" ] || fail "--head comment first line"

# --- case: --head the API never reaches: exit 1, nothing created or posted
reset_state
printf '%s\n' "$OLD_SHA" >"$T/state/heads.txt"
err="$(start_review 8 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 \
  --head "$NEW_SHA" 2>&1 >/dev/null)" && fail "--head timeout exits nonzero"
grep -q "$OLD_SHA" <<<"$err" || fail "--head timeout names the API head"
grep -q "$NEW_SHA" <<<"$err" || fail "--head timeout names the expected head"
[ ! -e "$T/state/runs.txt" ] || fail "--head timeout starts no job"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-')" = "0" ] || fail "--head timeout makes no worktree"
[ -z "$(ls -d "$TMPDIR"/review-pr.run.* 2>/dev/null)" ] || fail "--head timeout makes no run dir"
[ -z "$(ls "$TMPDIR/review-pr" 2>/dev/null)" ] || fail "--head timeout saves no state"
[ ! -e "$T/state/comment.md" ] || fail "--head timeout posts nothing"
[ "$(wc -l <"$T/state/sleeps.txt")" -eq 30 ] || fail "--head timeout polls 30 times"

# --- case: an issue number, not a PR: exit 2 at once, nothing created
reset_state
touch "$T/state/not-pr"
err="$(start_review 9 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 \
  --head "$NEW_SHA" 2>&1 >/dev/null)"
[ $? -eq 2 ] || fail "not-a-PR exits 2"
[ "$err" = "review-pr: #9 is not a pull request in O/N (an issue number?)" ] || fail "not-a-PR message: $err"
[ ! -e "$T/state/sleeps.txt" ] || fail "not-a-PR does not wait"
[ ! -e "$T/state/runs.txt" ] || fail "not-a-PR starts no job"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-')" = "0" ] || fail "not-a-PR makes no worktree"

# --- case: --head already matching: no wait
reset_state
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
printf '%s\n' "$NEW_SHA" >"$T/state/heads.txt"
start_review 8 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 \
  --head "$NEW_SHA" >/dev/null 2>&1 || fail "--head matching start exits 0"
[ ! -e "$T/state/sleeps.txt" ] || fail "--head matching does not sleep"
wt="$(sed -n 's/^worktree=//p' "$TMPDIR/review-pr/job-review")"
[ "$(git -C "$wt" rev-parse HEAD)" = "$NEW_SHA" ] || fail "--head matching worktree head"
bash "$REVIEW" collect job-review job-overbuild >/dev/null 2>&1 || fail "--head matching collect exits 0"

# --- case: --head must be a full SHA
reset_state
err="$(start_review 8 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 \
  --head abc123 2>&1 >/dev/null)"
[ $? -eq 2 ] || fail "--head short sha is a usage error"
[ "$err" = "review-pr: --head needs the full 40-character SHA (git rev-parse <sha>)" ] || \
  fail "--head short sha message: [$err]"

# --- case: --head in verify mode
reset_state
write_record verify DONE "FIX-OK
STATUS: DONE" 0
printf 'P1 x\n' >"$T/findings.txt"
printf '%s\n' "$NEW_SHA" >"$T/state/heads.txt"
start_review 8 --repo O/N --cwd "$T/clone" --model M --verify "$T/findings.txt" \
  --since "$OLD_SHA" --head "$NEW_SHA" >/dev/null 2>&1 || fail "--head verify start exits 0"
wt="$(sed -n 's/^worktree=//p' "$TMPDIR/review-pr/job-verify")"
[ "$(git -C "$wt" rev-parse HEAD)" = "$NEW_SHA" ] || fail "--head verify worktree head"
bash "$REVIEW" collect job-verify >/dev/null 2>&1 || true

# --- case: verify on a rebased PR compares only the repair patch
reset_state
write_record verify DONE "FIX-OK
STATUS: DONE" 0
git init -q -b main "$T/rebase-origin"
git -C "$T/rebase-origin" config user.email t@t
git -C "$T/rebase-origin" config user.name t
echo 'base line' >"$T/rebase-origin/main.txt"
git -C "$T/rebase-origin" add .
git -C "$T/rebase-origin" commit -qm 'rebase fixture base'
git -C "$T/rebase-origin" checkout -q -b pr9
echo 'original line' >"$T/rebase-origin/pr.txt"
git -C "$T/rebase-origin" add pr.txt
git -C "$T/rebase-origin" commit -qm 'reviewed change'
OLD9="$(git -C "$T/rebase-origin" rev-parse HEAD)"
git -C "$T/rebase-origin" checkout -q main
echo 'main moved' >"$T/rebase-origin/main.txt"
git -C "$T/rebase-origin" commit -qam 'move main'
git -C "$T/rebase-origin" checkout -q -b rebased-pr9
echo 'original line' >"$T/rebase-origin/pr.txt"
git -C "$T/rebase-origin" add pr.txt
git -C "$T/rebase-origin" commit -qm 'replay reviewed change'
echo 'repair line' >"$T/rebase-origin/pr.txt"
git -C "$T/rebase-origin" commit -qam 'repair'
NEW9="$(git -C "$T/rebase-origin" rev-parse HEAD)"
git -C "$T/rebase-origin" update-ref refs/pull/9/head "$NEW9"
git clone -q "$T/rebase-origin" "$T/rebase-clone"
printf '%s\n' "$NEW9" >"$T/state/heads.txt"
start_review 9 --repo O/N --cwd "$T/rebase-clone" --model M \
  --verify "$T/findings.txt" --since "$OLD9" --head "$NEW9" \
  >/dev/null 2>"$T/rebase-stderr.txt" || fail "rebased verify start exits 0"
REPAIR_BASE="$(sed -n 's/^review-pr: repair base \([0-9a-f]\{40\}\).*/\1/p' "$T/rebase-stderr.txt")"
[ -n "$REPAIR_BASE" ] || fail "verify logs the repair base"
[ "$REPAIR_BASE" != "$OLD9" ] || fail "rebased verify uses a base other than the reviewed head"
grep -q "git diff $REPAIR_BASE..HEAD" "$T/state/prompt-verify.md" || fail "rebased verify brief uses repair base"
[ "$(git -C "$T/rebase-clone" diff --name-only "$REPAIR_BASE" "$NEW9")" = "pr.txt" ] || \
  fail "rebased verify diff excludes changes that only exist on main"
repair_diff="$(git -C "$T/rebase-clone" diff "$REPAIR_BASE" "$NEW9" -- pr.txt)"
grep -q '^-original line$' <<<"$repair_diff" || fail "rebased verify diff removes reviewed line"
grep -q '^+repair line$' <<<"$repair_diff" || fail "rebased verify diff contains the repair line"
if grep -q 'main moved' <<<"$repair_diff"; then fail "rebased verify diff excludes main's change"; fi
grep -q "review-pr: repair base $REPAIR_BASE" "$T/rebase-stderr.txt" || fail "stderr identifies repair base"
bash "$REVIEW" collect job-verify >/dev/null 2>&1 || fail "rebased verify collect exits 0"

# --- case: verify reports conflicts while excluding changes only on main
reset_state
write_record verify DONE "FIX-OK
STATUS: DONE" 0
git init -q -b main "$T/conflict-origin"
git -C "$T/conflict-origin" config user.email t@t
git -C "$T/conflict-origin" config user.name t
echo 'same line' >"$T/conflict-origin/shared.txt"
git -C "$T/conflict-origin" add .
git -C "$T/conflict-origin" commit -qm 'conflict fixture base'
git -C "$T/conflict-origin" checkout -q -b pr10
echo 'reviewed branch line' >"$T/conflict-origin/shared.txt"
git -C "$T/conflict-origin" commit -qam 'reviewed conflicting change'
OLD_CONFLICT="$(git -C "$T/conflict-origin" rev-parse HEAD)"
git -C "$T/conflict-origin" checkout -q main
echo 'main line' >"$T/conflict-origin/shared.txt"
echo 'main only' >"$T/conflict-origin/main-only.txt"
git -C "$T/conflict-origin" add .
git -C "$T/conflict-origin" commit -qm 'conflicting main change'
git -C "$T/conflict-origin" checkout -q -b rebased-pr10
echo 'resolved line' >"$T/conflict-origin/shared.txt"
git -C "$T/conflict-origin" commit -qam 'resolve rebase conflict'
echo 'repair line' >"$T/conflict-origin/shared.txt"
git -C "$T/conflict-origin" commit -qam 'repair conflict resolution'
NEW_CONFLICT="$(git -C "$T/conflict-origin" rev-parse HEAD)"
git -C "$T/conflict-origin" update-ref refs/pull/10/head "$NEW_CONFLICT"
git clone -q "$T/conflict-origin" "$T/conflict-clone"
printf '%s\n' "$NEW_CONFLICT" >"$T/state/heads.txt"
start_review 10 --repo O/N --cwd "$T/conflict-clone" --model M \
  --verify "$T/findings.txt" --since "$OLD_CONFLICT" --head "$NEW_CONFLICT" \
  >/dev/null 2>"$T/conflict-stderr.txt" || fail "conflicted verify start exits 0"
CONFLICT_BASE="$(sed -n 's/^review-pr: repair base \([0-9a-f]\{40\}\).*/\1/p' "$T/conflict-stderr.txt")"
[ -n "$CONFLICT_BASE" ] || fail "conflicted verify logs repair base"
git -C "$T/conflict-clone" cat-file -e "$CONFLICT_BASE^{commit}" || fail "conflicted repair base is a commit"
grep -q "$OLD_CONFLICT does not replay cleanly onto .*the repair diff includes the rebase's conflict resolution" \
  "$T/conflict-stderr.txt" || fail "conflicted verify reports merge-tree conflict"
conflict_files="$(git -C "$T/conflict-clone" diff --name-only "$CONFLICT_BASE" "$NEW_CONFLICT")"
[ "$conflict_files" = "shared.txt" ] || fail "conflicted repair diff excludes main-only files: [$conflict_files]"
bash "$REVIEW" collect job-verify >/dev/null 2>&1 || fail "conflicted verify collect exits 0"

# --- case: missing --since fails before creating a worktree, state or job
reset_state
MISSING_SINCE=ffffffffffffffffffffffffffffffffffffffff
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M \
  --verify "$T/findings.txt" --since "$MISSING_SINCE" 2>&1 >/dev/null)" && \
  fail "missing --since exits nonzero"
grep -q -- "--since $MISSING_SINCE is not fetchable" <<<"$err" || fail "missing --since error names the value"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)" = "0" ] || \
  fail "missing --since creates no worktree"
[ -z "$(ls "$TMPDIR/review-pr" 2>/dev/null)" ] || fail "missing --since saves no state"
[ -z "$(ls -d "$TMPDIR"/review-pr.run.* 2>/dev/null)" ] || fail "missing --since leaves no run dir"
[ ! -e "$T/state/runs.txt" ] || fail "missing --since launches no job"

# --- case: collect unregisters the run's worktrees after --cwd is gone, and
# leaves another run's worktrees alone
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "sibling run start exits 0"
mkdir -p "$T/keep"
mv "$TMPDIR/review-pr/job-review" "$T/keep/job-review"
mv "$TMPDIR/review-pr/job-overbuild" "$T/keep/job-overbuild"
sibling_rd="$(sed -n 's/^run_dir=//p' "$T/keep/job-review")"
git -C "$T/clone" worktree add -q --detach "$T/lane" HEAD
start_review 7 --repo O/N --cwd "$T/lane" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start from a lane worktree exits 0"
rd="$(sed -n 's/^run_dir=//p' "$TMPDIR/review-pr/job-review")"
rm -rf "$T/lane"
bash "$REVIEW" collect job-review job-overbuild >/dev/null 2>&1 || fail "collect after --cwd is gone exits 0"
[ "$(git -C "$T/clone" worktree list | grep -c "$(basename "$rd")/wt-" || true)" = "0" ] || \
  fail "collect unregisters the run's worktrees when --cwd is gone"
[ ! -e "$rd" ] || fail "collect removes the run dir when --cwd is gone"
[ "$(git -C "$T/clone" worktree list | grep -c "$(basename "$sibling_rd")/wt-")" = "2" ] || \
  fail "collect leaves another run's worktrees registered"
[ -d "$sibling_rd/wt-review" ] || fail "collect leaves another run's dir"

# --- case: start prunes a finished run nobody collected
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
stale_rd="$(mktemp -d "$TMPDIR/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-old review 7 DONE "$T/clone"
stale_sf="$TMPDIR/review-pr/job-old"
stale_wt="$stale_rd/wt-review"
start_out="$(start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 2>"$T/stderr.txt")" || fail "pruning start exits 0"
[ "$start_out" = "review job-review
overbuild job-overbuild
watch: delegate watch job-review job-overbuild
collect: review-pr collect job-review job-overbuild" ] || fail "pruning start prints only the new jobs: [$start_out]"
[ ! -e "$stale_sf" ] || fail "prune removes the stale state file"
[ ! -e "$stale_wt" ] || fail "prune removes the stale worktree"
[ ! -e "$stale_rd" ] || fail "prune removes the stale run dir"
stale_base="$(basename "$stale_rd")"
[ "$(git -C "$T/clone" worktree list | grep -c "$stale_base/wt-" || true)" = "0" ] || fail "prune unregisters the stale worktree"
[ -f "$TMPDIR/review-pr/job-review" ] || fail "pruning start still saves the new state"
bash "$REVIEW" collect job-review job-overbuild >/dev/null 2>&1 || fail "collect after prune exits 0"

# --- case: start keeps a stale state file whose job is still running
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
stale_rd="$(mktemp -d "$TMPDIR/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-old review 7 RUNNING "$T/clone"
stale_sf="$TMPDIR/review-pr/job-old"
stale_wt="$stale_rd/wt-review"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start with a running stale run exits 0"
[ -f "$stale_sf" ] || fail "running stale state is kept"
[ -d "$stale_wt" ] || fail "running stale worktree is kept"
[ -d "$stale_rd" ] || fail "running stale run dir is kept"
bash "$REVIEW" collect job-review job-overbuild >/dev/null 2>&1 || fail "collect after running-stale exits 0"
git -C "$T/clone" worktree remove --force "$stale_wt" >/dev/null 2>&1 || rm -rf "$stale_wt"
rm -rf "$stale_rd"
rm -f "$stale_sf" "$TMPDIR/delegate-jobs/job-old.json"

# --- case: start keeps a finished run whose state file is fresh
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
stale_rd="$(mktemp -d "$TMPDIR/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-old review 1 DONE "$T/clone" 0
stale_sf="$TMPDIR/review-pr/job-old"
stale_wt="$stale_rd/wt-review"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start with a fresh stale run exits 0"
[ -f "$stale_sf" ] || fail "fresh state is kept"
[ -d "$stale_wt" ] || fail "fresh worktree is kept"
[ -d "$stale_rd" ] || fail "fresh run dir is kept"
bash "$REVIEW" collect job-review job-overbuild >/dev/null 2>&1 || fail "collect after fresh-stale exits 0"
git -C "$T/clone" worktree remove --force "$stale_wt" >/dev/null 2>&1 || rm -rf "$stale_wt"
rm -rf "$stale_rd"
rm -f "$stale_sf" "$TMPDIR/delegate-jobs/job-old.json"

# --- case: start prunes a stale state file with no job record
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
stale_rd="$(mktemp -d "$TMPDIR/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-old review 7 NOREC "$T/clone"
stale_sf="$TMPDIR/review-pr/job-old"
stale_wt="$stale_rd/wt-review"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "pruning start exits 0"
[ ! -e "$stale_sf" ] || fail "prune removes the recordless state file"
[ ! -e "$stale_wt" ] || fail "prune removes the recordless worktree"
[ ! -e "$stale_rd" ] || fail "prune removes the recordless run dir"
bash "$REVIEW" collect job-review job-overbuild >/dev/null 2>&1 || fail "collect after recordless prune exits 0"

# --- case: start prunes a DONE run two hours after it ends
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
stale_rd="$(mktemp -d "$TMPDIR/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-done2 review 2h DONE "$T/clone" 2h
stale_sf="$TMPDIR/review-pr/job-done2"
stale_wt="$stale_rd/wt-review"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "pruning start exits 0"
[ ! -e "$stale_sf" ] || fail "prune removes the two-hour finished state file"
[ ! -e "$stale_wt" ] || fail "prune removes the two-hour finished worktree"
[ ! -e "$stale_rd" ] || fail "prune removes the two-hour finished run dir"
bash "$REVIEW" collect job-review job-overbuild >/dev/null 2>&1 || fail "collect after two-hour prune exits 0"

# --- case: start keeps a long job that finished ten minutes ago
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
stale_rd="$(mktemp -d "$TMPDIR/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-justdone review 7h DONE "$T/clone" 10m
stale_sf="$TMPDIR/review-pr/job-justdone"
stale_wt="$stale_rd/wt-review"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start with a just-finished run exits 0"
[ -f "$stale_sf" ] || fail "just-finished state is kept"
[ -d "$stale_wt" ] || fail "just-finished worktree is kept"
[ -d "$stale_rd" ] || fail "just-finished run dir is kept"
bash "$REVIEW" collect job-review job-overbuild >/dev/null 2>&1 || fail "collect after just-finished exits 0"
git -C "$T/clone" worktree remove --force "$stale_wt" >/dev/null 2>&1 || rm -rf "$stale_wt"
rm -rf "$stale_rd"
rm -f "$stale_sf" "$TMPDIR/delegate-jobs/job-justdone.json"

# --- case: a run with no record is kept at two hours, pruned at seven
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
young_rd="$(mktemp -d "$TMPDIR/review-pr.run.XXXXXX")"
stale_state "$young_rd" job-norec2 review 2h NOREC "$T/clone"
old_rd="$(mktemp -d "$TMPDIR/review-pr.run.XXXXXX")"
stale_state "$old_rd" job-norec7 review 7h NOREC "$T/clone"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start with recordless runs exits 0"
[ -f "$TMPDIR/review-pr/job-norec2" ] || fail "two-hour recordless state is kept"
[ -d "$young_rd/wt-review" ] || fail "two-hour recordless worktree is kept"
[ ! -e "$TMPDIR/review-pr/job-norec7" ] || fail "prune removes the seven-hour recordless state"
[ ! -e "$old_rd" ] || fail "prune removes the seven-hour recordless run dir"
bash "$REVIEW" collect job-review job-overbuild >/dev/null 2>&1 || fail "collect after recordless ages exits 0"
git -C "$T/clone" worktree remove --force "$young_rd/wt-review" >/dev/null 2>&1 || rm -rf "$young_rd/wt-review"
rm -rf "$young_rd"
rm -f "$TMPDIR/review-pr/job-norec2"

# --- case: start prunes a stale two-role run sharing one run dir when the clone is gone
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
gone_clone="$T/clone-gone"
stale_rd="$(mktemp -d "$TMPDIR/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-stale-review review 7 DONE "$gone_clone"
stale_state "$stale_rd" job-stale-overbuild overbuild 7 DONE "$gone_clone"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start with a stale two-role run exits 0"
[ ! -e "$TMPDIR/review-pr/job-stale-review" ] || fail "prune removes the stale two-role review state"
[ ! -e "$TMPDIR/review-pr/job-stale-overbuild" ] || fail "prune removes the stale two-role overbuild state"
[ ! -e "$stale_rd" ] || fail "prune removes the shared run dir"
stale_base="$(basename "$stale_rd")"
[ "$(git -C "$T/clone" worktree list | grep -c "$stale_base/wt-" || true)" = "0" ] || fail "prune deregisters both worktrees when the clone is gone"
[ -f "$TMPDIR/review-pr/job-review" ] || fail "two-role prune still saves the new state"
bash "$REVIEW" collect job-review job-overbuild >/dev/null 2>&1 || fail "collect after two-role prune exits 0"

# --- case: start spares a run with a live sibling: review DONE but overbuild RUNNING
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record review DONE "VERDICT standards: APPROVE
VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
stale_rd="$(mktemp -d "$TMPDIR/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-live-review review 7 DONE "$T/clone"
stale_state "$stale_rd" job-live-overbuild overbuild 7 RUNNING "$T/clone"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start with a live sibling exits 0"
[ -f "$TMPDIR/review-pr/job-live-review" ] || fail "live run keeps the finished state"
[ -f "$TMPDIR/review-pr/job-live-overbuild" ] || fail "live run keeps the running state"
[ -d "$stale_rd/wt-review" ] || fail "live run keeps the finished worktree"
[ -d "$stale_rd/wt-overbuild" ] || fail "live run keeps the running worktree"
[ -d "$stale_rd" ] || fail "live run keeps the run dir"
stale_base="$(basename "$stale_rd")"
[ "$(git -C "$T/clone" worktree list | grep -c "$stale_base/wt-" || true)" = "2" ] || fail "live run keeps both worktrees registered"
bash "$REVIEW" collect job-review job-overbuild >/dev/null 2>&1 || fail "collect after live-sibling exits 0"
git -C "$T/clone" worktree remove --force "$stale_rd/wt-review" >/dev/null 2>&1 || rm -rf "$stale_rd/wt-review"
git -C "$T/clone" worktree remove --force "$stale_rd/wt-overbuild" >/dev/null 2>&1 || rm -rf "$stale_rd/wt-overbuild"
rm -rf "$stale_rd"
rm -f "$TMPDIR/review-pr/job-live-review" "$TMPDIR/review-pr/job-live-overbuild"
rm -f "$TMPDIR/delegate-jobs/job-live-review.json" "$TMPDIR/delegate-jobs/job-live-overbuild.json"

echo "review-pr: all cases passed"
