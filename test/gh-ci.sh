#!/usr/bin/env bash
# Tests for bin/gh-ci wait, using stand-in gh and sleep executables
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

mkdir -p "$T/fakebin" "$T/state"
export GH_CI_REPO="O/N"

A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# --- fake gh: pr view prints "<sha> CLEAN" (or DIRTY behind the marker),
# --- heads and checks advance one line per call, last line sticky.
cat >"$T/fakebin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "gh \$*" >>"$T/state/gh-args.txt"
[ "\$1" = "pr" ] || { echo "fake gh: only pr supported" >&2; exit 2; }
shift
advance() {
  local f="\$1"
  head -1 "\$f"
  if [ "\$(wc -l <"\$f")" -gt 1 ]; then
    tail -n +2 "\$f" >"\$f.tmp"; mv "\$f.tmp" "\$f"
  fi
}
case "\$1" in
  view)
    h="\$(advance "$T/state/heads.txt")"
    if [ -e "$T/state/dirty" ]; then printf '%s DIRTY\n' "\$h";
    else printf '%s CLEAN\n' "\$h"; fi;;
  checks)
    resp="\$(advance "$T/state/checks.txt")"
    printf '%s\n' "\$resp"
    case "\$resp" in
      *'"bucket":"cancel"'*|*'"bucket": "cancel"'*) exit 1;;
      *'"bucket":"fail"'*|*'"bucket": "fail"'*) exit 1;;
      *'"bucket":"pending"'*|*'"bucket": "pending"'*) exit 8;;
    esac
    exit 0;;
  *) echo "fake gh: unknown \$1" >&2; exit 2;;
esac
EOF
cat >"$T/fakebin/sleep" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/state/sleeps.txt"
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/sleep"
export PATH="$T/fakebin:$PATH"

reset_state() {
  rm -f "$T/state/sleeps.txt" "$T/state/gh-args.txt" "$T/state/dirty"
  rm -f "$T/state/heads.txt" "$T/state/checks.txt"
  : >"$T/state/gh-args.txt"
}

set_heads() { printf '%s\n' "$@" >"$T/state/heads.txt"; }
set_checks() { printf '%s\n' "$@" >"$T/state/checks.txt"; }

OUT=""; CODE=0
run_wait() {
  OUT="$("$GHCI" wait "$@" 2>"$T/stderr.txt")"; CODE=$?
}

# --- case: pending then green, with a passing name containing
# --- "failing: 0 pending: 0" (proves no substring matching)
reset_state
export GH_CI_INTERVAL=7
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
export GH_CI_INTERVAL=7
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

# --- case: empty list and non-JSON output never exit 0 early
reset_state
export GH_CI_INTERVAL=7
set_heads "$A"
set_checks '[]' 'no checks reported on this head yet' '[{"bucket":"pass","name":"ci"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "empty-then-green exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "empty-then-green pass line: [$OUT]"
[ "$(grep -c '^gh pr checks' "$T/state/gh-args.txt")" -ge 3 ] \
  || fail "empty outputs keep polling"

# --- case: head changes mid-wait waits on the new head
reset_state
export GH_CI_INTERVAL=7
set_heads "$A" "$B"
set_checks \
  '[{"bucket":"pending","name":"ci"}]' \
  '[{"bucket":"pass","name":"ci"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "head change exits 0 (got $CODE): [$OUT]"
grep -q "head: ${B:0:8} CI: pass" <<<"$OUT" || fail "head change names new head: [$OUT]"

# --- case: head moves during a verdict discards it
reset_state
export GH_CI_INTERVAL=7
set_heads "$A" "$B"
set_checks \
  '[{"bucket":"fail","name":"ci"}]' \
  '[{"bucket":"pass","name":"ci"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "verdict race exits 0 (got $CODE): [$OUT]"
grep -q "head: ${B:0:8} CI: pass" <<<"$OUT" || fail "verdict race names new head: [$OUT]"

# --- case: conflicting PR fails at once
reset_state
export GH_CI_INTERVAL=7
set_heads "$A"
set_checks '[{"bucket":"pass","name":"ci"}]'
touch "$T/state/dirty"
OUT="$("$GHCI" wait 7 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" != "0" ] || fail "conflict exits non-zero"
grep -qi "merge conflicts" "$T/stderr.txt" || fail "conflict message: [$(cat "$T/stderr.txt")]"
[ ! -e "$T/state/sleeps.txt" ] || fail "conflict never sleeps"

# --- case: usage errors exit 2
reset_state
run_wait; [ "$CODE" = "2" ] || fail "missing pr exits 2 (got $CODE)"
run_wait --pr 7; [ "$CODE" = "2" ] || fail "--pr misuse exits 2 (got $CODE)"
run_wait 7 --bogus; [ "$CODE" = "2" ] || fail "unknown flag exits 2 (got $CODE)"
run_wait 7 --timeout abc; [ "$CODE" = "2" ] || fail "non-numeric timeout exits 2 (got $CODE)"
run_wait 7 --timeout; [ "$CODE" = "2" ] || fail "missing timeout value exits 2 (got $CODE)"

echo "gh-ci: all cases passed"
