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
  [ "$1" = "pr" ] || { echo "fake gh: only pr and api supported" >&2; exit 2; }
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
  : >"$T/state/gh-args.txt"
}

set_heads() { printf '%s\n' "$@" >"$T/state/heads.txt"; }
set_merge() { printf '%s\n' "$@" >"$T/state/merge-state.txt"; }
set_checks() { printf '%s\n' "$@" >"$T/state/checks.txt"; }

OUT=""; CODE=0
run_wait() {
  OUT="$(bash "$GHCI" wait "$@" 2>"$T/stderr.txt")"; CODE=$?
}

# --- case: pending then green, with a passing name containing
# --- "failing: 0 pending: 0" (proves no substring matching)
reset_state
set_heads "$A"
set_checks \
  '[{"bucket":"pending","name":"ci"},{"bucket":"pass","name":"setup"}]' \
  '[{"bucket":"pass","name":"failing: 0 pending: 0 lint-fail"},{"bucket":"pass","name":"ci"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "pending-then-green exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "pending-then-green pass line: [$OUT]"
grep -q "failing:" <<<"$OUT" && fail "passing names never listed as failing: [$OUT]"
[ -s "$T/state/sleeps.txt" ] || fail "pending-then-green sleeps at least once"
grep -q "^7$" "$T/state/sleeps.txt" || fail "sleep uses GH_CI_INTERVAL: [$(cat "$T/state/sleeps.txt")]"
[ -z "$(grep '^gh pr checks' "$T/state/gh-args.txt" | grep -v -- --required || true)" ] \
  || fail "pr checks is called with --required"

# --- case: pending then one failure (plus one pass)
reset_state
set_heads "$A"
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
set_heads "$A"
set_checks '[{"bucket":"cancel","name":"ci"}]'
run_wait 7
[ "$CODE" = "1" ] || fail "cancel exits 1 (got $CODE): [$OUT]"
grep -q "^failing: ci$" <<<"$OUT" || fail "cancel named as failing: [$OUT]"

# --- case: failing name with an embedded newline still fails (not timeout)
reset_state
set_heads "$A"
set_checks '[{"bucket":"fail","name":"ci\nextra"}]'
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
set_heads "$A"
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
set_heads "$A"
set_checks '[{"bucket":"pending","name":"ci"}]'
run_wait 7 --timeout 0
[ "$CODE" = "124" ] || fail "timeout 0 exits 124 (got $CODE): [$OUT]"
[ ! -e "$T/state/sleeps.txt" ] || fail "timeout 0 never sleeps"

RULES_CI='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci"}]}}]'

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
set_heads "$A" "$B"
set_checks \
  '[{"bucket":"pending","name":"ci"}]' \
  '[{"bucket":"pass","name":"ci"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "head change exits 0 (got $CODE): [$OUT]"
grep -q "head: ${B:0:8} CI: pass" <<<"$OUT" || fail "head change names new head: [$OUT]"

# --- case: head moves during a verdict discards it
reset_state
set_heads "$A" "$B"
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
set_heads "$A"; set_checks "$PASS"; set_merge DIRTY DIRTY CLEAN
run_wait 7
[ "$CODE" = "0" ] || fail "recovered conflict exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "recovered conflict pass line: [$OUT]"
sleeps_are 2 5 || fail "recovered conflict sleeps twice: [$(cat "$T/state/sleeps.txt")]"

# UNKNOWN resets the clock: three DIRTY, UNKNOWN (pending checks), then six DIRTY sleeps
reset_state
set_heads "$A"; set_checks "$PEND"
set_merge DIRTY DIRTY DIRTY UNKNOWN DIRTY
run_wait 7
[ "$CODE" = "3" ] || fail "reset clock still ends in 3 (got $CODE): [$OUT]"
[ "$(grep -c '^5$' "$T/state/sleeps.txt")" = "9" ] || fail "3 + 6 grace sleeps: [$(tr '\n' ' ' <"$T/state/sleeps.txt")]"
[ "$(grep -c -v '^5$' "$T/state/sleeps.txt")" = "1" ] || fail "UNKNOWN polls checks at the interval: [$(tr '\n' ' ' <"$T/state/sleeps.txt")]"

# UNKNOWN with pending checks never reports a conflict
reset_state
set_heads "$A"; set_checks "$PEND"; set_merge UNKNOWN
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
set_heads "$A"; set_checks "$PASS"; set_merge CLEAN DIRTY
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
grep -q -- '--json name,bucket$' "$T/state/gh-args.txt" || fail "checks call asks for name,bucket"
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

# no required names (classic 404, no rules): empty list passes (#155)
reset_state
set_heads "$A"; set_checks '[]'
run_wait 7 --timeout 0
[ "$CODE" = "0" ] || fail "no required names, empty list passes (got $CODE): [$OUT]"

# rules lookup fails: warning, empty list stays pending
reset_state
set_heads "$A"; set_checks '[]'; touch "$T/state/rules-fail"
run_wait 7 --timeout 0
[ "$CODE" = "124" ] || fail "unreadable names, empty list is pending (got $CODE): [$OUT]"
grep -q "gh-ci: cannot read required checks; absent ones are not detected" "$T/stderr.txt" \
  || fail "lookup warning: [$(cat "$T/stderr.txt")]"

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

echo "gh-ci: all cases passed"
