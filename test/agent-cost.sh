#!/usr/bin/env bash
# Tests for bin/agent-cost, against a fixture transcript tree (never ~/.claude).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/../bin/agent-cost"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-agent-cost.XXXXXX")"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/p1/s1/subagents"
SUB="$T/p1/s1/subagents/agent-a.jsonl"
printf '{"agentType":"claude-worker"}\n' >"$T/p1/s1/subagents/agent-a.meta.json"

# Subagent. Message m1 is streamed twice: the first chunk is a stub, the last wins.
#   m1 (final): input 1000, cache write 400000 (1h 100000 -> w5 300000, w1 100000), read 2000000, out 100000
#   m2 (+10min): cache write 600000 (1h 200000 -> w5 400000, w1 200000): a bigwrite;
#                carries a poll (delegate watch) tool_use
#   two messages without an id (+11, +12 min): read 500000, out 10000 each: two turns, not one
#   one tool_result over 20000 chars: bigres; one malformed line: skipped
# Totals: inp 1000, w5 700000, w1 300000, cr 4000000, out 170000, turns 4
#   cost = 1000 + 1.25*700000 + 2*300000 + 0.1*4000000 + 5*170000 = 2726000 -> 2.7M, per 2.73M
cat >"$SUB" <<'FIXTURE'
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"m1","usage":{"input_tokens":1,"output_tokens":1}}}
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"m1","usage":{"input_tokens":1000,"cache_creation_input_tokens":400000,"cache_creation":{"ephemeral_1h_input_tokens":100000},"cache_read_input_tokens":2000000,"output_tokens":100000}}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"BIGRESULT"}]}}
this line is not json {"type":
{"type":"assistant","timestamp":"2026-01-01T00:10:00Z","message":{"id":"m2","content":[{"type":"tool_use","name":"Bash","input":{"command":"delegate watch x"}}],"usage":{"cache_creation_input_tokens":600000,"cache_creation":{"ephemeral_1h_input_tokens":200000},"cache_read_input_tokens":1000000,"output_tokens":50000}}}
{"type":"assistant","timestamp":"2026-01-01T00:11:00Z","message":{"usage":{"cache_read_input_tokens":500000,"output_tokens":10000}}}
{"type":"assistant","timestamp":"2026-01-01T00:12:00Z","message":{"usage":{"cache_read_input_tokens":500000,"output_tokens":10000}}}
FIXTURE
python3 -I -c 'import sys; p=sys.argv[1]; s=open(p).read().replace("BIGRESULT","x"*25000); open(p,"w").write(s)' "$SUB"

# bg ticket-orchestrator: input 1000000, cache write 800000 (all 5m), out 100000
#   cost = 1000000 + 1.25*800000 + 5*100000 = 2500000 -> 2.5M
cat >"$T/p1/bg.jsonl" <<'FIXTURE'
{"type":"system","agentSetting":"ticket-orchestrator"}
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"b1","usage":{"input_tokens":1000000,"cache_creation_input_tokens":800000,"output_tokens":100000}}}
FIXTURE

# main interactive session: no agentSetting, excluded
cat >"$T/p1/main.jsonl" <<'FIXTURE'
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"x1","usage":{"input_tokens":9000000}}}
FIXTURE

# old bg session (mtime 10 days back): input 4000000 -> cost 4.0M; only with days=30
cat >"$T/p1/old.jsonl" <<'FIXTURE'
{"type":"system","agentSetting":"claude-worker"}
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"o1","usage":{"input_tokens":4000000}}}
FIXTURE
python3 -I -c 'import os,sys,time; t=time.time()-10*86400; os.utime(sys.argv[1],(t,t))' "$T/p1/old.jsonl"

SUBLINE='sub:claude-worker        n=  1 cost=    2.7M  per= 2.73M turns/agent=    4 cw5=0.7M cw1=0.3M cr=4M out=0.17M bigwrites=1 (0.6M) polls=1 bigres=1'
BGLINE='bg:ticket-orchestrator   n=  1 cost=    2.5M  per= 2.50M turns/agent=    1 cw5=0.8M cw1=0.0M cr=0M out=0.10M bigwrites=0 (0.0M) polls=0 bigres=0'
OLDLINE='bg:claude-worker         n=  1 cost=    4.0M  per= 4.00M turns/agent=    1 cw5=0.0M cw1=0.0M cr=0M out=0.00M bigwrites=0 (0.0M) polls=0 bigres=0'

OUT="$(AGENT_COST_ROOT="$T" python3 -I "$BIN")" || fail "default run exited non-zero"
EXPECT="$SUBLINE
$BGLINE"
[ "$OUT" = "$EXPECT" ] || fail "default output differs:
$OUT
--- expected
$EXPECT"

OUT="$(AGENT_COST_ROOT="$T" python3 -I "$BIN" 30)" || fail "30-day run exited non-zero"
EXPECT="$OLDLINE
$SUBLINE
$BGLINE"
[ "$OUT" = "$EXPECT" ] || fail "30-day output differs:
$OUT
--- expected
$EXPECT"

OUT="$(AGENT_COST_ROOT="$T" python3 -I "$BIN" 0.5)" || fail "fractional run exited non-zero"
[ "$OUT" = "$SUBLINE
$BGLINE" ] || fail "fractional days output differs"

# missing root: nothing, exit 0
OUT="$(AGENT_COST_ROOT="$T/nope" python3 -I "$BIN")" || fail "missing root exited non-zero"
[ -z "$OUT" ] || fail "missing root printed output"

# bad usage: exit 2, usage on stderr
check_bad() {
  local err rc
  err="$(AGENT_COST_ROOT="$T" python3 -I "$BIN" "$@" 2>&1 >/dev/null)"
  rc=$?
  [ "$rc" = "2" ] || fail "args '$*': exit $rc, want 2"
  case "$err" in *sage*) ;; *) fail "args '$*': no usage line on stderr" ;; esac
}
check_bad abc
check_bad 0
check_bad -1
check_bad 1 2
check_bad -h

echo "agent-cost: ok"
