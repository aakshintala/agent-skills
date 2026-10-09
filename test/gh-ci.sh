#!/usr/bin/env bash
# Tests for bin/gh-ci wait, using stand-in gh and sleep functions
# (no network). Fake gh serves successive heads and check responses
# from state files (last line sticky) and logs its args.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GHCI="$SCRIPT_DIR/../bin/gh-ci"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-gh-ci.XXXXXX")"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/state"
export GH_CI_REPO="O/N"
export GH_CI_INTERVAL=7

A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# --- fake gh: pr view prints "<sha> <state>"; heads, merge states (default
# --- CLEAN) and checks advance one line per call, last line sticky.
gh() (
  set -euo pipefail
  echo "gh $*" >>"$T/state/gh-args.txt"
  if [ "$1" = "api" ]; then
    # rules (default none) and classic protection (default 404) of the base branch
    jq=""; for a in "$@"; do [ "${prev:-}" = "--jq" ] && jq="$a"; prev="$a"; done
    case "$2" in
      repos/O/N/rules/branches/main)
        [ ! -e "$T/state/rules-fail" ] || { echo "gh: forbidden (HTTP 403)" >&2; exit 1; }
        json="$(cat "$T/state/rules" 2>/dev/null || echo '[]')";;
      repos/O/N/branches/main/protection/required_status_checks)
        [ -e "$T/state/classic" ] || { echo "gh: Branch not protected (HTTP 404)" >&2; exit 1; }
        json="$(cat "$T/state/classic")";;
      *) echo "fake gh: unknown api $2" >&2; exit 2;;
    esac
    jq -r "$jq" <<<"$json"; exit 0
  fi
  if [ "$1" = "run" ]; then
    shift
    case "${1:-}" in
      list)
        [ ! -e "$T/state/runs-fail" ] || { echo "fake gh: cannot list runs" >&2; exit 1; }
        cat "$T/state/runs.json"
        exit 0;;
      view)
        shift
        _rv_run="${1:-}"; shift || true
        _rv_job=""; _prev=""
        for _a in "$@"; do
          if [ "$_prev" = "--job" ]; then _rv_job="$_a"; fi
          _prev="$_a"
        done
        case " $* " in
          *" --log-failed "*)
            cat "$T/state/log-$_rv_job.txt"
            exit 0;;
          *" --json jobs "*)
            [ ! -e "$T/state/jobs-fail" ] || { echo "fake gh: cannot read jobs" >&2; exit 1; }
            cat "$T/state/jobs-$_rv_run.json"
            exit 0;;
          *" --json name "*)
            cat "$T/state/run-name-$_rv_run.txt" 2>/dev/null || printf '%s\n' "wf-$_rv_run"
            exit 0;;
          *)
            echo "fake gh: unknown run view args: $*" >&2; exit 2;;
        esac;;
      *)
        echo "fake gh: unknown run $1" >&2; exit 2;;
    esac
  fi
  [ "$1" = "pr" ] || { echo "fake gh: only pr, run and api supported" >&2; exit 2; }
  shift
  advance() {
    local f="$1"
    head -1 "$f"
    if [ "$(wc -l <"$f")" -gt 1 ]; then
      tail -n +2 "$f" >"$f.tmp"; mv "$f.tmp" "$f"
    fi
  }
  case "$1" in
    view)
      if [ -e "$T/state/view-fail" ]; then exit 3; fi
      case " $* " in *" baseRefName "*) echo main; exit 0;; esac
      case " $* " in *" isDraft "*)
        if [ -e "$T/state/draft" ]; then cat "$T/state/draft"; else echo "false"; fi
        exit 0;;
      esac
      h="$(advance "$T/state/heads.txt")"
      m=CLEAN
      if [ -e "$T/state/merge-state.txt" ]; then m="$(advance "$T/state/merge-state.txt")"; fi
      printf '%s %s\n' "$h" "$m";;
    checks)
      resp="$(advance "$T/state/checks.txt")"
      # With --required, gh serves only the required checks: when the
      # required-filter state file lists names (one per line), keep those.
      case " $* " in
        *" --required "*)
          if [ -e "$T/state/required-filter" ]; then
            resp="$(printf '%s' "$resp" | jq -c --rawfile names "$T/state/required-filter" '
              if type != "array" then . else
                ($names | split("\n")) as $ns | map(select(.name as $n | $ns | index($n)))
              end' 2>/dev/null || printf '%s' "$resp")"
          fi;;
      esac
      printf '%s\n' "$resp"
      case "$resp" in
        *'"bucket":"cancel"'*|*'"bucket": "cancel"'*) exit 1;;
        *'"bucket":"fail"'*|*'"bucket": "fail"'*) exit 1;;
        *'"bucket":"pending"'*|*'"bucket": "pending"'*) exit 8;;
      esac
      exit 0;;
    *) echo "fake gh: unknown $1" >&2; exit 2;;
  esac
)
sleep() ( echo "$*" >>"$T/state/sleeps.txt" )
export T
export -f gh sleep

reset_state() {
  rm -f "$T/state/sleeps.txt" "$T/state/gh-args.txt" "$T/state/merge-state.txt" "$T/state/view-fail"
  rm -f "$T/state/heads.txt" "$T/state/checks.txt" "$T/state/rules" "$T/state/rules-fail" "$T/state/classic" "$T/state/draft"
  rm -f "$T/state/runs.json" "$T/state/runs-fail" "$T/state/jobs-fail"
  rm -f "$T/state/required-filter"
  rm -f "$T/state"/jobs-*.json "$T/state"/run-name-*.txt "$T/state"/log-*.txt
  : >"$T/state/gh-args.txt"
}

set_heads() { printf '%s\n' "$@" >"$T/state/heads.txt"; }
set_merge() { printf '%s\n' "$@" >"$T/state/merge-state.txt"; }
set_checks() { printf '%s\n' "$@" >"$T/state/checks.txt"; }

OUT=""; CODE=0
run_wait() {
  OUT="$(bash "$GHCI" wait "$@" 2>"$T/stderr.txt")"; CODE=$?
}

RULES_CI='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci"}]}}]'

# --- case: pending then green, with a passing name containing
# --- "failing: 0 pending: 0" (proves no substring matching)
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks \
  '[{"bucket":"pending","name":"ci"},{"bucket":"pass","name":"setup"}]' \
  '[{"bucket":"pass","name":"failing: 0 pending: 0 lint-fail"},{"bucket":"pass","name":"ci"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "pending-then-green exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "pending-then-green pass line: [$OUT]"
grep -q "failing:" <<<"$OUT" && fail "passing names never listed as failing: [$OUT]"
[ -s "$T/state/sleeps.txt" ] || fail "pending-then-green sleeps at least once"
grep -q "^7$" "$T/state/sleeps.txt" || fail "sleep uses GH_CI_INTERVAL: [$(cat "$T/state/sleeps.txt")]"
grep -q -- '--required --json name,bucket,workflow,event,link$' "$T/state/gh-args.txt" \
  || fail "required set fetched with --required"
grep -q '^gh pr checks 7 --repo O/N --json name,bucket,workflow,event,link$' "$T/state/gh-args.txt" \
  || fail "newest-run map fetched without --required"

# --- case: pending then one failure (plus one pass)
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks \
  '[{"bucket":"pending","name":"ci"}]' \
  '[{"bucket":"fail","name":"ci"},{"bucket":"pass","name":"lint"}]'
run_wait 7
[ "$CODE" = "1" ] || fail "one failure exits 1 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: fail" <<<"$OUT" || fail "fail header: [$OUT]"
grep -q "^failing: ci$" <<<"$OUT" || fail "failing job named: [$OUT]"
grep -q "failing: lint" <<<"$OUT" && fail "passing job not listed: [$OUT]"

# --- case: cancel counts as failing
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"cancel","name":"ci"}]'
run_wait 7
[ "$CODE" = "1" ] || fail "cancel exits 1 (got $CODE): [$OUT]"
grep -q "^failing: ci$" <<<"$OUT" || fail "cancel named as failing: [$OUT]"

# --- case: failing name with an embedded newline still fails (not timeout)
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"fail","name":"ci\nextra"},{"bucket":"pass","name":"ci"}]'
run_wait 7 --timeout 0
[ "$CODE" = "1" ] || fail "newline failing name exits 1 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: fail" <<<"$OUT" || fail "newline failing name header: [$OUT]"

# --- case: passing name with an embedded newline plus a fake record still passes
reset_state
set_heads "$A"
set_checks '[{"bucket":"pass","name":"ok\nfail\u001fphantom"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "injection passing name exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "injection passing name line: [$OUT]"
grep -q "failing:" <<<"$OUT" && fail "injection names never listed as failing: [$OUT]"

# --- case: always pending hits the timeout
reset_state
export GH_CI_INTERVAL=30
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"pending","name":"ci"}]'
run_wait 7 --timeout 60
[ "$CODE" = "124" ] || fail "timeout exits 124 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} timeout after 60s" <<<"$OUT" || fail "timeout header: [$OUT]"
grep -q "^pending: ci$" <<<"$OUT" || fail "pending job named: [$OUT]"
[ "$(cat "$T/state/sleeps.txt")" = "30
30" ] || fail "timeout sleeps exactly twice with 30: [$(cat "$T/state/sleeps.txt")]"

# --- case: --timeout 0 polls exactly once
reset_state
export GH_CI_INTERVAL=30
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"pending","name":"ci"}]'
run_wait 7 --timeout 0
[ "$CODE" = "124" ] || fail "timeout 0 exits 124 (got $CODE): [$OUT]"
[ ! -e "$T/state/sleeps.txt" ] || fail "timeout 0 never sleeps"

# --- case: empty list and non-JSON output never exit 0 early while a check is required
reset_state
export GH_CI_INTERVAL=7
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[]' 'no checks reported on this head yet' '[{"bucket":"pass","name":"ci"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "empty-then-green exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "empty-then-green pass line: [$OUT]"
[ "$(grep -c '^gh pr checks' "$T/state/gh-args.txt")" -ge 3 ] \
  || fail "empty outputs keep polling"

# --- case: head changes mid-wait waits on the new head
reset_state
set_heads "$A" "$B"; echo "$RULES_CI" >"$T/state/rules"
set_checks \
  '[{"bucket":"pending","name":"ci"}]' \
  '[{"bucket":"pass","name":"ci"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "head change exits 0 (got $CODE): [$OUT]"
grep -q "head: ${B:0:8} CI: pass" <<<"$OUT" || fail "head change names new head: [$OUT]"

# --- case: head moves during a verdict discards it
reset_state
set_heads "$A" "$B"; echo "$RULES_CI" >"$T/state/rules"
set_checks \
  '[{"bucket":"fail","name":"ci"}]' \
  '[{"bucket":"pass","name":"ci"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "verdict race exits 0 (got $CODE): [$OUT]"
grep -q "head: ${B:0:8} CI: pass" <<<"$OUT" || fail "verdict race names new head: [$OUT]"

# --- cases: conflicts. Grace polls sleep 5 s (not GH_CI_INTERVAL) and count
# --- toward --timeout; only a head that stays DIRTY is reported.
CONFLICT_MSG="PR 7 has merge conflicts: GitHub runs no CI on it. Rebase first."
sleeps_are() { # sleeps_are <n> <secs>: sleeps.txt is exactly n lines of secs
  local want="" i
  for i in $(seq 1 "$1"); do want="${want}${2}"$'\n'; done
  [ "$(cat "$T/state/sleeps.txt" 2>/dev/null)" = "${want%$'\n'}" ]
}
PASS='[{"bucket":"pass","name":"ci"}]'
PEND='[{"bucket":"pending","name":"ci"}]'

# persistent DIRTY: exit 3 after six 5 s sleeps
reset_state
export GH_CI_INTERVAL=30
set_heads "$A"; set_checks "$PASS"; set_merge DIRTY
run_wait 7
[ "$CODE" = "3" ] || fail "persistent conflict exits 3 (got $CODE): [$OUT]"
grep -qF "$CONFLICT_MSG" "$T/stderr.txt" || fail "conflict message: [$(cat "$T/stderr.txt")]"
sleeps_are 6 5 || fail "conflict grace is six 5s sleeps: [$(cat "$T/state/sleeps.txt")]"

# DIRTY then CLEAN within the grace: normal verdict
reset_state
set_heads "$A"; set_checks "$PASS"; echo "$RULES_CI" >"$T/state/rules"; set_merge DIRTY DIRTY CLEAN
run_wait 7
[ "$CODE" = "0" ] || fail "recovered conflict exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "recovered conflict pass line: [$OUT]"
sleeps_are 2 5 || fail "recovered conflict sleeps twice: [$(cat "$T/state/sleeps.txt")]"

# UNKNOWN resets the clock: three DIRTY, UNKNOWN (pending checks), then six DIRTY sleeps
reset_state
set_heads "$A"; set_checks "$PEND"; echo "$RULES_CI" >"$T/state/rules"
set_merge DIRTY DIRTY DIRTY UNKNOWN DIRTY
run_wait 7
[ "$CODE" = "3" ] || fail "reset clock still ends in 3 (got $CODE): [$OUT]"
[ "$(grep -c '^5$' "$T/state/sleeps.txt")" = "9" ] || fail "3 + 6 grace sleeps: [$(tr '\n' ' ' <"$T/state/sleeps.txt")]"
[ "$(grep -c -v '^5$' "$T/state/sleeps.txt")" = "1" ] || fail "UNKNOWN polls checks at the interval: [$(tr '\n' ' ' <"$T/state/sleeps.txt")]"

# UNKNOWN with pending checks never reports a conflict
reset_state
set_heads "$A"; set_checks "$PEND"; echo "$RULES_CI" >"$T/state/rules"; set_merge UNKNOWN
run_wait 7 --timeout 60
[ "$CODE" = "124" ] || fail "UNKNOWN is not a conflict (got $CODE): [$OUT]"

# a new head restarts the clock
reset_state
set_heads "$A" "$A" "$A" "$B"; set_checks "$PASS"; set_merge DIRTY
run_wait 7
[ "$CODE" = "3" ] || fail "head change conflict exits 3 (got $CODE): [$OUT]"
sleeps_are 9 5 || fail "clock restarts on the new head (3 + 6 sleeps): [$(tr '\n' ' ' <"$T/state/sleeps.txt")]"

# --timeout bounds the grace; budget spent while DIRTY reports the conflict
reset_state
set_heads "$A"; set_checks "$PASS"; set_merge DIRTY
run_wait 7 --timeout 0
[ "$CODE" = "3" ] || fail "timeout 0 on conflict exits 3 (got $CODE): [$OUT]"
[ ! -e "$T/state/sleeps.txt" ] || fail "timeout 0 on conflict never sleeps"
reset_state
set_heads "$A"; set_checks "$PASS"; set_merge DIRTY
run_wait 7 --timeout 10
[ "$CODE" = "3" ] || fail "timeout 10 on conflict exits 3 (got $CODE): [$OUT]"
sleeps_are 2 5 || fail "timeout 10 sleeps two 5s: [$(cat "$T/state/sleeps.txt")]"

# a conflict that appears after the checks call discards the verdict
reset_state
set_heads "$A"; set_checks "$PASS"; echo "$RULES_CI" >"$T/state/rules"; set_merge CLEAN DIRTY
run_wait 7 --timeout 0
[ "$CODE" = "3" ] || fail "conflict after checks exits 3 (got $CODE): [$OUT]"

# snapshot and watch-verified exit 3 at once
reset_state
set_heads "$A"; set_checks "$PASS"; set_merge DIRTY
OUT="$(bash "$GHCI" snapshot 7 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "3" ] || fail "snapshot conflict exits 3 (got $CODE): [$OUT]"
grep -qF "$CONFLICT_MSG" "$T/stderr.txt" || fail "snapshot conflict message: [$(cat "$T/stderr.txt")]"
[ ! -e "$T/state/sleeps.txt" ] || fail "snapshot conflict never sleeps"
OUT="$(bash "$GHCI" watch-verified 99 --pr 7 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "3" ] || fail "watch-verified conflict exits 3 (got $CODE): [$OUT]"

# --- case: unreadable head never exits 0
reset_state
set_heads "$A"
set_checks '[{"bucket":"pass","name":"ci"}]'
touch "$T/state/view-fail"
OUT="$(bash "$GHCI" wait 7 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" != "0" ] || fail "unreadable head exits non-zero (got $CODE): [$OUT]"
grep -qi "could not read the head" "$T/stderr.txt" || fail "unreadable head message: [$(cat "$T/stderr.txt")]"
[ ! -e "$T/state/sleeps.txt" ] || fail "unreadable head never sleeps"

# --- cases: a required check green on the head passes whenever it ran;
# --- a required name of the base branch with no check on the head is pending
# a green required check passes at once, and startedAt is never requested
reset_state
export GH_CI_INTERVAL=7
set_heads "$A"; set_checks "$PASS"; echo "$RULES_CI" >"$T/state/rules"
run_wait 7
[ "$CODE" = "0" ] || fail "green required check exits 0 (got $CODE): [$OUT]"
[ ! -e "$T/state/sleeps.txt" ] || fail "green required check never sleeps"
grep -q -- '--json name,bucket,workflow,event,link$' "$T/state/gh-args.txt" || fail "checks call asks for name,bucket,workflow,event,link"
! grep -q startedAt "$T/state/gh-args.txt" || fail "startedAt is never requested"

# only a differently named (draft) check ran: --required lists nothing, ci is pending
reset_state
set_heads "$A"; set_checks '[]'; echo "$RULES_CI" >"$T/state/rules"
run_wait 7 --timeout 7
[ "$CODE" = "124" ] || fail "draft-only check times out (got $CODE): [$OUT]"
grep -q "^pending: ci$" <<<"$OUT" || fail "draft-only names ci pending: [$OUT]"

# a required name with no check stays pending, while the others pass
reset_state
set_heads "$A"
set_checks '[{"bucket":"pass","name":"lint"}]'
echo '{"contexts":["lint","ci"]}' >"$T/state/classic"
run_wait 7 --timeout 7
[ "$CODE" = "124" ] || fail "absent required check times out (got $CODE): [$OUT]"
grep -q "^pending: ci$" <<<"$OUT" || fail "absent check named pending: [$OUT]"

# no required names (classic 404, no rules): gh's "no checks" text passes at once (#155)
reset_state
set_heads "$A"; set_checks 'no checks reported on the '"'"'main'"'"' branch'
run_wait 7 --timeout 0
[ "$CODE" = "0" ] || fail "no required names, no-checks text passes (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "no required names pass line: [$OUT]"
[ ! -e "$T/state/sleeps.txt" ] || fail "no required names never sleeps"
! grep -q '^gh pr checks' "$T/state/gh-args.txt" || fail "no required names never calls pr checks"

# no required names while a non-required check is pending: still passes at once (#155)
reset_state
set_heads "$A"; set_checks '[{"bucket":"pending","name":"lint"}]'
run_wait 7 --timeout 0
[ "$CODE" = "0" ] || fail "no required names, pending non-required passes (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "non-required pending pass line: [$OUT]"
[ ! -e "$T/state/sleeps.txt" ] || fail "non-required pending never sleeps"

# rules lookup fails: warning, empty list stays pending
reset_state
set_heads "$A"; set_checks '[]'; touch "$T/state/rules-fail"
run_wait 7 --timeout 0
[ "$CODE" = "124" ] || fail "unreadable names, empty list is pending (got $CODE): [$OUT]"
grep -q "gh-ci: cannot read required checks; absent ones are not detected" "$T/stderr.txt" \
  || fail "lookup warning: [$(cat "$T/stderr.txt")]"
grep -q -- '--required --json name,bucket,workflow,event,link$' "$T/state/gh-args.txt" \
  || fail "fallback still uses --required: [$(cat "$T/state/gh-args.txt")]"

# --- cases: draft PRs settle on the head's checks (no --required, no padding)
# a draft whose only check is `CI (draft)` passes at once, though `CI` is required
reset_state
export GH_CI_INTERVAL=7
set_heads "$A"; echo true >"$T/state/draft"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"pass","name":"CI (draft)"}]'
run_wait 7 --timeout 7
[ "$CODE" = "0" ] || fail "draft green exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass (draft: required checks run once ready)" <<<"$OUT" \
  || fail "draft pass note: [$OUT]"
[ ! -e "$T/state/sleeps.txt" ] || fail "draft green never sleeps"
! grep -q -- --required "$T/state/gh-args.txt" || fail "draft: checks call drops --required"
! grep -q 'rules/branches' "$T/state/gh-args.txt" || fail "draft: required names never read"

# a draft with a failing check fails
reset_state
set_heads "$A"; echo true >"$T/state/draft"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"fail","name":"CI (draft)"}]'
run_wait 7
[ "$CODE" = "1" ] || fail "draft failure exits 1 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: fail" <<<"$OUT" || fail "draft fail header: [$OUT]"
grep -q '^failing: CI (draft)$' <<<"$OUT" || fail "draft failing job named: [$OUT]"

# --- cases: wait ignores checks from a superseded workflow run
# a stale fail from run 1 next to passes from run 2 of the same workflow passes
reset_state
set_heads "$A"; echo true >"$T/state/draft"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"name":"CI (draft)","bucket":"fail","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/1/job/11"},{"name":"CI","bucket":"pass","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/2/job/21"},{"name":"lint","bucket":"pass","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/2/job/22"}]'
run_wait 7 --timeout 7
[ "$CODE" = "0" ] || fail "superseded draft fail exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass (draft: required checks run once ready)" <<<"$OUT" \
  || fail "superseded draft pass line: [$OUT]"
grep -q -- '--json name,bucket,workflow,event,link$' "$T/state/gh-args.txt" \
  || fail "draft checks call asks for workflow,event,link"

# a failing check from the current run still fails
reset_state
set_heads "$A"; echo true >"$T/state/draft"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"name":"CI (draft)","bucket":"pass","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/1/job/11"},{"name":"CI","bucket":"fail","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/2/job/21"}]'
run_wait 7
[ "$CODE" = "1" ] || fail "current-run failure exits 1 (got $CODE): [$OUT]"
grep -q "^failing: CI$" <<<"$OUT" || fail "current failing job named: [$OUT]"

# a failing status context with a non-Actions link is kept
reset_state
set_heads "$A"; echo true >"$T/state/draft"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"name":"third-party","bucket":"fail","link":"https://example.com/status/1"},{"name":"CI","bucket":"pass","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/2/job/21"}]'
run_wait 7
[ "$CODE" = "1" ] || fail "status-context failure exits 1 (got $CODE): [$OUT]"
grep -q "^failing: third-party$" <<<"$OUT" || fail "status context named: [$OUT]"

# a cancelled required check from an old run is pending while the new run's
# required job has not appeared yet (a non-required job proves the new run)
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
printf 'ci\n' >"$T/state/required-filter"
set_checks '[{"name":"ci","bucket":"cancel","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/1/job/11"},{"name":"setup","bucket":"pending","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/2/job/21"}]'
run_wait 7 --timeout 0
[ "$CODE" = "124" ] || fail "superseded required cancel is pending (got $CODE): [$OUT]"
grep -q "^pending: ci$" <<<"$OUT" || fail "superseded required check named pending: [$OUT]"

# a cancelled required check replaced by a passing one in the new run passes
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"name":"ci","bucket":"cancel","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/1/job/11"},{"name":"ci","bucket":"pass","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/2/job/21"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "replaced required cancel passes (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "replaced required pass line: [$OUT]"

# required names unreadable: the newest-run map still uses every check, so a
# cancelled required check from a superseded run is pending, not failing
reset_state
set_heads "$A"; touch "$T/state/rules-fail"
printf 'ci\n' >"$T/state/required-filter"
set_checks '[{"name":"ci","bucket":"cancel","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/1/job/11"},{"name":"setup","bucket":"pending","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/2/job/21"}]'
run_wait 7 --timeout 0
[ "$CODE" = "124" ] || fail "superseded required cancel with unreadable names is pending (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} timeout after 0s" <<<"$OUT" || fail "superseded unreadable-names timeout header: [$OUT]"

# a draft with no checks yet stays pending to timeout
reset_state
set_heads "$A"; echo true >"$T/state/draft"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[]'
run_wait 7 --timeout 7
[ "$CODE" = "124" ] || fail "draft empty stays pending (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} timeout after 7s" <<<"$OUT" || fail "draft empty timeout header: [$OUT]"

# --- case: usage errors exit 2
reset_state
run_wait; [ "$CODE" = "2" ] || fail "missing pr exits 2 (got $CODE)"
run_wait --pr 7; [ "$CODE" = "2" ] || fail "--pr misuse exits 2 (got $CODE)"
run_wait 7 --bogus; [ "$CODE" = "2" ] || fail "unknown flag exits 2 (got $CODE)"
run_wait 7 --timeout abc; [ "$CODE" = "2" ] || fail "non-numeric timeout exits 2 (got $CODE)"
run_wait 7 --timeout; [ "$CODE" = "2" ] || fail "missing timeout value exits 2 (got $CODE)"
run_wait 7 --since 2026-10-06T12:00:00Z; [ "$CODE" = "2" ] || fail "--since is an unknown flag, exits 2 (got $CODE)"

# --- case: no subcommand and unknown subcommand print usage, exit 2
OUT="$(bash "$GHCI" 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "no args exits 2 (got $CODE)"
grep -q '^usage: gh-ci' "$T/stderr.txt" || fail "no args prints usage on stderr: [$(cat "$T/stderr.txt")]"
OUT="$(bash "$GHCI" bogus 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "unknown subcommand exits 2 (got $CODE)"
grep -q '^usage: gh-ci' "$T/stderr.txt" || fail "unknown subcommand prints usage on stderr"

# usage comes before the repo lookup: with no override and a failing gh
(
  gh() ( exit 1 )
  export -f gh
  for a in "" bogus; do
    OUT="$(env -u GH_CI_REPO bash "$GHCI" $a 2>"$T/stderr.txt")"; CODE=$?
    [ "$CODE" = "2" ] || fail "usage without repo lookup exits 2 for [$a] (got $CODE)"
    grep -q '^usage: gh-ci' "$T/stderr.txt" || fail "usage without repo lookup for [$a]"
  done
) || exit 1

# --- cases: failures prints a cleaned digest of the failed and cancelled jobs ---
run_failures() {
  OUT="$(bash "$GHCI" failures "$@" 2>"$T/stderr.txt")"; CODE=$?
}
set_runs() { printf '%s' "$1" >"$T/state/runs.json"; }
set_jobs() { printf '%s' "$2" >"$T/state/jobs-$1.json"; }
make_rust_log() { # 100 ANSI/timestamp/prefixed lines with Rust failures inside
  local jid="$1" i msg
  {
    for i in $(seq 1 100); do
      case "$i" in
        90) msg="test foo::bar ... FAILED";;
        95) msg="error[E0308]: mismatched types";;
        *) msg="line $i content";;
      esac
      printf 'myjob\tmystep\t2026-10-07T12:00:%02dZ \033[31m%s\033[0m\n' "$((i % 60))" "$msg"
    done
  } >"$T/state/log-$jid.txt"
}
ESC_BYTES="$(printf '\033')"

# a 100-line coloured, timestamped, prefixed log digests to its last 60
# cleaned lines, Rust failure lines included
reset_state
set_jobs 123 '{"jobs":[{"databaseId":111,"name":"build","conclusion":"failure"}]}'
make_rust_log 111
run_failures 123
[ "$CODE" = "0" ] || fail "failures digest exits 0 (got $CODE): [$OUT]"
grep -q "=== wf-123 / build (111): failure" <<<"$OUT" || fail "failure header: [$OUT]"
grep -q "test foo::bar ... FAILED" <<<"$OUT" || fail "Rust FAILED line in digest"
grep -q "error\[E0308\]: mismatched types" <<<"$OUT" || fail "Rust error line in digest"
LINES="$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
[ "$LINES" = "61" ] || fail "header plus exactly 60 lines (got $LINES)"
grep -q "$ESC_BYTES" <<<"$OUT" && fail "no escape bytes in digest"
grep -q "2026-10-07" <<<"$OUT" && fail "no timestamps in digest"
grep -q "myjob" <<<"$OUT" && fail "no job/step prefix in digest"
grep -q "line 41 content" <<<"$OUT" || fail "keeps the last 60 (line 41 present)"
grep -q "line 40 content" <<<"$OUT" && fail "drops lines before the last 60"

# --pr with one failed and one passed run on the head: only the failed run
reset_state
set_heads "$A"
set_runs '[{"databaseId":11,"name":"ci","conclusion":"failure"},{"databaseId":22,"name":"lint","conclusion":"success"}]'
set_jobs 11 '{"jobs":[{"databaseId":111,"name":"build","conclusion":"failure"}]}'
set_jobs 22 '{"jobs":[{"databaseId":222,"name":"ok-job","conclusion":"success"}]}'
make_rust_log 111
run_failures --pr 7
[ "$CODE" = "0" ] || fail "--pr digest exits 0 (got $CODE): [$OUT]"
grep -q "=== ci / build (111): failure" <<<"$OUT" || fail "--pr failed run header: [$OUT]"
grep -q "ok-job" <<<"$OUT" && fail "passed run jobs never appear: [$OUT]"
grep -q "lint" <<<"$OUT" && fail "passed run name never appears: [$OUT]"
grep -q "superseded" <<<"$OUT" && fail "nothing superseded, no note line: [$OUT]"
grep -q -- "run list .*--limit 100" "$T/state/gh-args.txt" || fail "--pr lists runs with --limit 100: [$(cat "$T/state/gh-args.txt")]"

# gh prints ESC as the literal text ^[ ; those colour codes are stripped too
reset_state
set_jobs 123 '{"jobs":[{"databaseId":111,"name":"build","conclusion":"failure"}]}'
{
  printf 'myjob\tmystep\t2026-10-07T12:00:01Z ^[[32;1m        PASS^[[0m ok\n'
  printf 'myjob\tmystep\t2026-10-07T12:00:02Z ^[[31;1m        FAIL^[[0m [   8.5s] jobs a_test\n'
} >"$T/state/log-111.txt"
run_failures 123
[ "$CODE" = "0" ] || fail "literal-escape digest exits 0 (got $CODE): [$OUT]"
grep -qF '^[[' <<<"$OUT" && fail "no literal ^[[ codes in digest: [$OUT]"
grep -q "$ESC_BYTES" <<<"$OUT" && fail "no escape bytes in literal-escape digest"
grep -q "FAIL" <<<"$OUT" || fail "literal-escape digest keeps FAIL: [$OUT]"
grep -q "a_test" <<<"$OUT" || fail "literal-escape digest keeps a_test: [$OUT]"

# --pr ignores a superseded run: cancelled run 1 replaced by a successful
# run 2 of the same workflow reports no failed jobs
reset_state
set_heads "$A"
set_runs '[{"databaseId":1,"name":"CI","workflowName":"CI","event":"pull_request","conclusion":"cancelled"},{"databaseId":2,"name":"CI","workflowName":"CI","event":"pull_request","conclusion":"success"}]'
set_jobs 2 '{"jobs":[{"databaseId":222,"name":"ok-job","conclusion":"success"}]}'
run_failures --pr 7
[ "$CODE" = "0" ] || fail "superseded cancel exits 0 (got $CODE): [$OUT]"
grep -q "no failed jobs on ${A:0:8}" <<<"$OUT" || fail "superseded cancel line: [$OUT]"
grep -qx "skipped 1 superseded runs: 1" <<<"$OUT" || fail "superseded cancel names run 1: [$OUT]"
grep -q -- "run list .*databaseId,name,event,conclusion,workflowName" "$T/state/gh-args.txt" \
  || fail "run list asks for event,workflowName: [$(cat "$T/state/gh-args.txt")]"

# --pr names every superseded failed or cancelled run, after the digest; a
# superseded success is not named
reset_state
set_heads "$A"
set_runs '[{"databaseId":37925057416,"name":"CI","workflowName":"CI","event":"pull_request","conclusion":"cancelled"},{"databaseId":37925058210,"name":"CI","workflowName":"CI","event":"pull_request","conclusion":"failure"},{"databaseId":37925059000,"name":"CI","workflowName":"CI","event":"pull_request","conclusion":"success"},{"databaseId":40000000001,"name":"Lint","workflowName":"Lint","event":"pull_request","conclusion":"success"},{"databaseId":40000000002,"name":"Lint","workflowName":"Lint","event":"pull_request","conclusion":"failure"}]'
set_jobs 37925059000 '{"jobs":[{"databaseId":222,"name":"ok-job","conclusion":"success"}]}'
set_jobs 40000000002 '{"jobs":[{"databaseId":111,"name":"build","conclusion":"failure"}]}'
make_rust_log 111
run_failures --pr 7
[ "$CODE" = "0" ] || fail "two superseded exits 0 (got $CODE): [$OUT]"
grep -q "=== Lint / build (111): failure" <<<"$OUT" || fail "kept failed run digest: [$OUT]"
grep -q "superseded runs: " <<<"$OUT" || fail "note after the digest: [$OUT]"
[ "$(tail -n 1 <<<"$OUT")" = "skipped 2 superseded runs: 37925057416 37925058210" ] \
  || fail "note names the cancelled and failed superseded runs in order: [$OUT]"
grep -q "40000000001" <<<"$OUT" && fail "superseded success is not named: [$OUT]"
grep -q "37925059000" <<<"$OUT" && fail "kept run is not named as superseded: [$OUT]"

# superseded runs that all succeeded name nothing
reset_state
set_heads "$A"
set_runs '[{"databaseId":1,"name":"CI","workflowName":"CI","event":"pull_request","conclusion":"success"},{"databaseId":2,"name":"CI","workflowName":"CI","event":"pull_request","conclusion":"success"}]'
set_jobs 2 '{"jobs":[{"databaseId":222,"name":"ok-job","conclusion":"success"}]}'
run_failures --pr 7
[ "$CODE" = "0" ] || fail "superseded successes exit 0 (got $CODE): [$OUT]"
grep -q "superseded" <<<"$OUT" && fail "superseded successes name no run: [$OUT]"

# --pr still reports a cancelled run of another workflow
reset_state
set_heads "$A"
set_runs '[{"databaseId":1,"name":"A","workflowName":"A","event":"pull_request","conclusion":"cancelled"},{"databaseId":2,"name":"B","workflowName":"B","event":"pull_request","conclusion":"success"}]'
set_jobs 1 '{"jobs":[{"databaseId":111,"name":"old-job","conclusion":"cancelled"}]}'
set_jobs 2 '{"jobs":[{"databaseId":222,"name":"ok-job","conclusion":"success"}]}'
run_failures --pr 7
[ "$CODE" = "0" ] || fail "other-workflow cancel exits 0 (got $CODE): [$OUT]"
grep -q "=== A / old-job: cancelled" <<<"$OUT" || fail "other-workflow cancelled line: [$OUT]"

# a cancelled job prints one line and triggers no log call
reset_state
set_jobs 123 '{"jobs":[{"databaseId":222,"name":"flaky","conclusion":"cancelled"},{"databaseId":111,"name":"build","conclusion":"failure"}]}'
make_rust_log 111
run_failures 123
[ "$CODE" = "0" ] || fail "cancelled digest exits 0 (got $CODE): [$OUT]"
grep -q "=== wf-123 / flaky: cancelled" <<<"$OUT" || fail "cancelled line: [$OUT]"
grep -q -- "--job 222" "$T/state/gh-args.txt" && fail "no log call for cancelled jobs"
grep -q -- "--job 111" "$T/state/gh-args.txt" || fail "log call for failed jobs"

# nothing failed: names the run, or the PR head short SHA, and exits 0
reset_state
set_jobs 123 '{"jobs":[{"databaseId":111,"name":"build","conclusion":"success"}]}'
run_failures 123
[ "$CODE" = "0" ] || fail "no failures exits 0 (got $CODE): [$OUT]"
grep -q "no failed jobs" <<<"$OUT" || fail "no-failures line: [$OUT]"
grep -q "123" <<<"$OUT" || fail "no-failures names the run: [$OUT]"
reset_state
set_heads "$A"
set_runs '[]'
run_failures --pr 7
[ "$CODE" = "0" ] || fail "--pr no failures exits 0 (got $CODE): [$OUT]"
grep -q "no failed jobs" <<<"$OUT" || fail "--pr no-failures line: [$OUT]"
grep -q "${A:0:8}" <<<"$OUT" || fail "--pr no-failures names the short SHA: [$OUT]"

# GH_CI_LOG_LINES=5 keeps 5 lines
reset_state
set_jobs 123 '{"jobs":[{"databaseId":111,"name":"build","conclusion":"failure"}]}'
make_rust_log 111
OUT="$(GH_CI_LOG_LINES=5 bash "$GHCI" failures 123 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "0" ] || fail "log-lines=5 exits 0 (got $CODE): [$OUT]"
LINES="$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
[ "$LINES" = "6" ] || fail "5 lines kept (got $LINES)"

# failures usage errors exit 2
reset_state
run_failures; [ "$CODE" = "2" ] || fail "failures with no argument exits 2 (got $CODE)"
run_failures --pr; [ "$CODE" = "2" ] || fail "failures --pr with no number exits 2 (got $CODE)"
run_failures --pr abc; [ "$CODE" = "2" ] || fail "failures --pr abc exits 2 (got $CODE)"
reset_state
run_failures abc; [ "$CODE" = "2" ] || fail "failures abc exits 2 (got $CODE)"
[ ! -s "$T/state/gh-args.txt" ] || fail "failures abc makes no gh call: [$(cat "$T/state/gh-args.txt")]"

echo "gh-ci: all cases passed"
