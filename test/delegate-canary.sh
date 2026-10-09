#!/usr/bin/env bash
# Tests for delegate/scripts/canary.sh, offline: a fake delegate, fake Fiber
# event logs and local git remotes (never the real ~/.fiber, ~/.cache, a live
# model or a real checkout). HOME and TMPDIR are temp dirs set here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CANARY="$SCRIPT_DIR/../delegate/scripts/canary.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-delegate-canary.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME"
export TMPDIR="$T/tmp"
mkdir -p "$TMPDIR"
export FIBER_HOME="$T/fiber-home"
mkdir -p "$FIBER_HOME"

# --- local origin (bare) and clone at $HOME/work/fiber (the defaults) ---
git init -q --bare "$T/upstream.git"
git init -q -b main "$T/seed"
git -C "$T/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$T/seed" remote add origin "$T/upstream.git"
git -C "$T/seed" push -q origin main
git -C "$T/seed" branch --set-upstream-to=origin/main main 2>/dev/null || true
mkdir -p "$HOME/work"
git clone -q "$T/upstream.git" "$HOME/work/fiber"
BASE="$(git -C "$HOME/work/fiber" rev-parse origin/main)"

# --- fakes: delegate (run/watch), gh (logs, exits 1), git (logs, execs real) ---
FBIN="$T/fakebin"
FLOG="$T/fakelog"
mkdir -p "$FBIN" "$FLOG"
export FAKE_LOGDIR="$FLOG"
REAL_GIT="$(command -v git)"
cat >"$FBIN/delegate" <<EOF
#!/usr/bin/env bash
set -uo pipefail
REAL_GIT="$REAL_GIT"
cmd="\${1:-}"
if [ \$# -gt 0 ]; then shift; fi
case "\$cmd" in
  run)
    model=""; cwd=""; prompt=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --model) model="\$2"; shift 2 ;;
        --cwd) cwd="\$2"; shift 2 ;;
        --prompt-file) prompt="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf 'run %s %s\n' "\$model" "\$cwd" >>"\$FAKE_LOGDIR/calls.log"
    case "\$model" in
      fiber/*)
        if [ "\${CANARY_FAKE_FAIL:-}" = "fiber" ]; then exit 1; fi ;;
    esac
    id="job-\$\$-\$RANDOM"
    printf 'work by %s\n' "\$id" >"\$cwd/work.txt"
    touch "\$cwd/work-marker"
    case "\$model" in
      fiber/*) ;;
      *) touch "\$cwd/pass-marker" ;;
    esac
    "\$REAL_GIT" -C "\$cwd" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
    "\$REAL_GIT" -C "\$cwd" -c user.email=t@t -c user.name=t commit -qm "fake \$id" >/dev/null 2>&1
    sid="sid-\$id"
    mkdir -p "\$TMPDIR/delegate-jobs"
    case "\$model" in
      fiber/*) cost="0.04" ;;
      *) cost="0.05" ;;
    esac
    jq -n --arg sid "\$sid" --arg model "\$model" --arg cwd "\$cwd" \
      --arg cost "\$cost" \
      '{status:"DONE",
        result:{status:"DONE",model:\$model,sessionId:\$sid,backend:"x",
          usage:{inputTokens:1000,outputTokens:100,cacheReadTokens:500,cacheWriteTokens:0},
          costUsd:(\$cost|tonumber),durationMs:null,
          gateResult:null,
          changeSet:{headBefore:"abc",headAfter:"abc"}},
        supervisorPid:1,
        resume:{model:\$model,backend:"x",cwd:\$cwd,sessionId:\$sid,gate:"g"}}' \
      >"\$TMPDIR/delegate-jobs/\$id.json"
    case "\$model" in
      fiber/*)
        if [ -n "\${FAKE_EVENTS:-}" ]; then
          mkdir -p "\$FIBER_HOME/projects/p/sessions/\$sid"
          cp "\$FAKE_EVENTS" "\$FIBER_HOME/projects/p/sessions/\$sid/events.jsonl"
        fi ;;
    esac
    printf '%s\n' "\$id" ;;
  watch)
    printf 'watch %s\n' "\$*" >>"\$FAKE_LOGDIR/calls.log"
    exit 0 ;;
  *)
    echo "fake delegate: unknown command \$cmd" >&2
    exit 2 ;;
esac
EOF
chmod +x "$FBIN/delegate"
cat >"$FBIN/gh" <<EOF
#!/bin/sh
printf 'gh %s\n' "\$*" >>"$FAKE_LOGDIR/gh.log"
echo "gh disabled in test" >&2
exit 1
EOF
chmod +x "$FBIN/gh"
cat >"$FBIN/git" <<EOF
#!/bin/sh
printf 'git %s\n' "\$*" >>"$FAKE_LOGDIR/git.log"
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$FBIN/git"
PATH="$FBIN:$PATH"
export PATH
export DELEGATE_BIN="$FBIN/delegate"

printf 'Do the thing.\n' >"$T/brief.md"

# --- Task 2 fixture: main lines, reviewer lines, an extension line, a dupe generation_id ---
FAKE_TMPDIR="$TMPDIR"
cat >"$T/ev2.jsonl" <<EOF
{"kind":"usage_recorded","session_id":"s1","ts":1,"schema_version":1,"action_id":"a1","seq":1,"payload":{"generation_id":"g1","model":"m","tokens":{"input":10,"output":1,"cache_read":1,"cache_write":{}},"cost":0.25}}
{"kind":"usage_recorded","session_id":"s1","ts":2,"schema_version":1,"seq":2,"payload":{"generation_id":"gR","model":"m","tokens":{"input":200,"output":20,"cache_read":30,"cache_write":{"ephemeral":10}},"cost":0.125}}
{"kind":"usage_recorded","session_id":"s1","ts":3,"schema_version":1,"action_id":"a2","seq":3,"payload":{"generation_id":"gE","model":"m","tokens":{"input":10,"output":1,"cache_read":1,"cache_write":{}},"cost":0.25,"extension":"ext1"}}
{"kind":"usage_recorded","session_id":"s1","ts":4,"schema_version":1,"action_id":"a3","seq":4,"payload":{"generation_id":"g1","model":"m","tokens":{"input":100,"output":10,"cache_read":50,"cache_write":{}},"cost":0.5}}
{"kind":"usage_recorded","session_id":"s1","ts":5,"schema_version":1,"action_id":"a4","seq":5,"payload":{"generation_id":"gC","model":"m","tokens":{"input":1,"output":1,"cache_read":1,"cache_write":{}},"cost":0.125,"origin_session_id":"s-del"}}
{"kind":"tool_call_requested","session_id":"s1","ts":6,"schema_version":1,"action_id":"r1","seq":6,"payload":{"name":"bash","arguments":{"command":"cargo test"}}}
{"kind":"permission_resolved","session_id":"s1","ts":7,"schema_version":1,"action_id":"r1","seq":7,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":8,"schema_version":1,"action_id":"r2","seq":8,"payload":{"name":"write","arguments":{"path":"$FAKE_TMPDIR/note.txt"}}}
{"kind":"permission_resolved","session_id":"s1","ts":9,"schema_version":1,"action_id":"r2","seq":9,"payload":{"decision":"allow","decided_by":"reviewer"}}
EOF

# --- Task 2: happy-path run ---
OUT="$T/out"
FAKE_EVENTS="$T/ev2.jsonl" bash "$CANARY" run 223 "$T/brief.md" \
  --gate 'test -f work-marker' --out "$OUT" || fail "canary run exits 0"

# layout
for side in pi fiber; do
  for f in worktree diff.patch gate.log gate.exit metrics.json prompt.md; do
    [ -f "$OUT/$side/$f" ] || fail "$side/$f exists"
  done
done
[ -f "$OUT/summary.md" ] || fail "summary.md exists"

# worktree files point at the two fresh worktrees
PI_WT="$(cat "$OUT/pi/worktree")"
FIBER_WT="$(cat "$OUT/fiber/worktree")"
[ "$PI_WT" = "$HOME/work/fiber-canary-223-pi" ] || fail "pi worktree path ($PI_WT)"
[ "$FIBER_WT" = "$HOME/work/fiber-canary-223-fiber" ] || fail "fiber worktree path ($FIBER_WT)"
[ -d "$PI_WT" ] && [ -d "$FIBER_WT" ] || fail "worktrees exist"
[ "$(git -C "$PI_WT" rev-parse HEAD)" != "$BASE" ] || fail "pi worktree has the fake commit"
[ "$(git -C "$FIBER_WT" rev-parse HEAD)" != "$BASE" ] || fail "fiber worktree has the fake commit"
[ -s "$OUT/pi/diff.patch" ] && [ -s "$OUT/fiber/diff.patch" ] || fail "diffs are non-empty"
[ "$(cat "$OUT/pi/gate.exit")" = "0" ] || fail "pi gate passes"
[ "$(cat "$OUT/fiber/gate.exit")" = "0" ] || fail "fiber gate passes"

# prompt wrapper: brief text, no-push line, own worktree and branch
for spec in "pi:$PI_WT" "fiber:$FIBER_WT"; do
  side="${spec%%:*}"; wt="${spec#*:}"
  grep -q "Do the thing" "$OUT/$side/prompt.md" || fail "$side prompt keeps the brief"
  grep -q "Canary run: work only in $wt" "$OUT/$side/prompt.md" || fail "$side prompt names its worktree"
  grep -q "canary/223-$side" "$OUT/$side/prompt.md" || fail "$side prompt names its branch"
  grep -q "Do not push" "$OUT/$side/prompt.md" || fail "$side prompt forbids pushing"
done

# every metrics.json key, both sides
for side in pi fiber; do
  jq -e 'has("side") and has("outcome") and has("job_id") and has("model")
    and has("base") and has("dirty") and has("wall_ms") and has("tokens")
    and has("cost") and has("reviewed_calls") and has("denials")
    and has("sandbox") and has("per_review_tokens_est") and has("notes")' \
    "$OUT/$side/metrics.json" >/dev/null || fail "$side metrics has every key"
  jq -e '.tokens | has("input") and has("output") and has("cache_read")' \
    "$OUT/$side/metrics.json" >/dev/null || fail "$side tokens keys"
  jq -e '.cost | has("total") and has("main") and has("reviewer")' \
    "$OUT/$side/metrics.json" >/dev/null || fail "$side cost keys"
  jq -e '.sandbox.contained.count != null and .sandbox.needs_out.count != null
    and .sandbox.unknown.count != null' \
    "$OUT/$side/metrics.json" >/dev/null || fail "$side sandbox keys"
done

# shared base, clean tree, job records
[ "$(jq -r .base "$OUT/pi/metrics.json")" = "$BASE" ] || fail "pi base is origin/main"
[ "$(jq -r .base "$OUT/fiber/metrics.json")" = "$BASE" ] || fail "fiber base matches pi"
[ "$(jq -r .dirty "$OUT/pi/metrics.json")" = "false" ] || fail "pi tree clean"
[ "$(jq -r .dirty "$OUT/fiber/metrics.json")" = "false" ] || fail "fiber tree clean"
[ "$(jq -r .outcome "$OUT/pi/metrics.json")" = "DONE" ] || fail "pi outcome DONE"
[ "$(jq -r .outcome "$OUT/fiber/metrics.json")" = "DONE" ] || fail "fiber outcome DONE"
[ "$(jq -r .model "$OUT/pi/metrics.json")" = "opencode-go/muse-spark-1.3-contributor" ] || fail "pi model"
[ "$(jq -r .model "$OUT/fiber/metrics.json")" = "fiber/opencode-go/muse-spark-1.3-contributor" ] || fail "fiber model"
PI_ID="$(jq -r .job_id "$OUT/pi/metrics.json")"
FIBER_ID="$(jq -r .job_id "$OUT/fiber/metrics.json")"
[ -n "$PI_ID" ] && [ -f "$TMPDIR/delegate-jobs/$PI_ID.json" ] || fail "pi record exists"
[ -n "$FIBER_ID" ] && [ -f "$TMPDIR/delegate-jobs/$FIBER_ID.json" ] || fail "fiber record exists"
jq -e '(.wall_ms | type) == "number"' "$OUT/pi/metrics.json" >/dev/null || fail "pi wall is a number"
jq -e '(.wall_ms | type) == "number"' "$OUT/fiber/metrics.json" >/dev/null || fail "fiber wall is a number"

# tokens and total cost come from the record
[ "$(jq -r .tokens.input "$OUT/pi/metrics.json")" = "1000" ] || fail "pi tokens in"
[ "$(jq -r .tokens.output "$OUT/fiber/metrics.json")" = "100" ] || fail "fiber tokens out"
[ "$(jq -r .tokens.cache_read "$OUT/pi/metrics.json")" = "500" ] || fail "pi tokens cache-read"
[ "$(jq -r .cost.total "$OUT/pi/metrics.json")" = "0.05" ] || fail "pi total cost"
[ "$(jq -r .cost.total "$OUT/fiber/metrics.json")" = "0.04" ] || fail "fiber total cost"

# reviewer split: dupe g1 folds to its latest line; extension and delegate copy count as main
[ "$(jq -r .cost.main "$OUT/fiber/metrics.json")" = "0.875" ] || fail "fiber main cost 0.875"
[ "$(jq -r .cost.reviewer "$OUT/fiber/metrics.json")" = "0.125" ] || fail "fiber reviewer cost"
[ "$(jq -r .cost.main "$OUT/pi/metrics.json")" = "0.05" ] || fail "pi main equals total"
[ "$(jq -r .cost.reviewer "$OUT/pi/metrics.json")" = "0" ] || fail "pi reviewer is 0"
[ "$(jq -r .reviewed_calls "$OUT/fiber/metrics.json")" = "2" ] || fail "fiber reviewed calls"
[ "$(jq -r .reviewed_calls "$OUT/pi/metrics.json")" = "0" ] || fail "pi reviewed calls 0"
[ "$(jq -r .per_review_tokens_est "$OUT/fiber/metrics.json")" = "130" ] || fail "fiber per-review tokens"
[ "$(jq -r .per_review_tokens_est "$OUT/pi/metrics.json")" = "null" ] || fail "pi per-review null"
[ "$(jq -r '.denials | length' "$OUT/fiber/metrics.json")" = "0" ] || fail "fiber no denials"
[ "$(jq -r '.denials | length' "$OUT/pi/metrics.json")" = "0" ] || fail "pi no denials"
[ "$(jq -r .sandbox.contained.count "$OUT/fiber/metrics.json")" = "2" ] || fail "fiber contained 2"
[ "$(jq -r .sandbox.needs_out.count "$OUT/fiber/metrics.json")" = "0" ] || fail "fiber needs_out 0"
[ "$(jq -r .sandbox.unknown.count "$OUT/fiber/metrics.json")" = "0" ] || fail "fiber unknown 0"
[ "$(jq -r .sandbox.contained.count "$OUT/pi/metrics.json")" = "0" ] || fail "pi sandbox zeros"
[ "$(jq -r '.notes | length' "$OUT/pi/metrics.json")" = "0" ] || fail "pi notes empty"

# launch barrier: both runs before any watch
awk '/^run /{runs[++n]=NR} /^watch /{watches[++m]=NR}
  END{exit !((n==2) && (m==2) && (runs[1]<watches[1]) && (runs[2]<watches[1]))}' \
  "$FLOG/calls.log" || fail "both runs precede both watches"

# summary table
grep -q '^# Canary 223' "$OUT/summary.md" || fail "summary heading"
grep -q "$BASE" "$OUT/summary.md" || fail "summary base"
grep -q '| outcome | DONE | DONE |' "$OUT/summary.md" || fail "summary outcome row"
grep -q '| gate | pass | pass |' "$OUT/summary.md" || fail "summary gate row"
grep -q '| reviewed calls | 0 | 2 |' "$OUT/summary.md" || fail "summary reviewed row"

echo "task 2 cases passed"

# --- Task 3 fixture: every sandbox class, plus one deny ---
cat >"$T/ev3.jsonl" <<EOF
{"kind":"usage_recorded","session_id":"s1","ts":1,"schema_version":1,"action_id":"a0","seq":1,"payload":{"generation_id":"gM","model":"m","tokens":{"input":10,"output":1,"cache_read":1,"cache_write":{}},"cost":1}}
{"kind":"usage_recorded","session_id":"s1","ts":2,"schema_version":1,"seq":2,"payload":{"generation_id":"gR","model":"m","tokens":{"input":500,"output":100,"cache_read":150,"cache_write":{"warm":50}},"cost":0.5}}
{"kind":"tool_call_requested","session_id":"s1","ts":3,"schema_version":1,"action_id":"c1","seq":3,"payload":{"name":"bash","arguments":{"command":"cargo test"}}}
{"kind":"permission_resolved","session_id":"s1","ts":4,"schema_version":1,"action_id":"c1","seq":4,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":5,"schema_version":1,"action_id":"c2","seq":5,"payload":{"name":"write","arguments":{"path":"\$TMPDIR/x.txt"}}}
{"kind":"permission_resolved","session_id":"s1","ts":6,"schema_version":1,"action_id":"c2","seq":6,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":7,"schema_version":1,"action_id":"n1","seq":7,"payload":{"name":"bash","arguments":{"command":"curl https://example.com"}}}
{"kind":"permission_resolved","session_id":"s1","ts":8,"schema_version":1,"action_id":"n1","seq":8,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":9,"schema_version":1,"action_id":"n2","seq":9,"payload":{"name":"bash","arguments":{"command":"git push origin main"}}}
{"kind":"permission_resolved","session_id":"s1","ts":10,"schema_version":1,"action_id":"n2","seq":10,"payload":{"decision":"deny","decided_by":"reviewer","reason":"no pushing"}}
{"kind":"tool_call_requested","session_id":"s1","ts":11,"schema_version":1,"action_id":"n3","seq":11,"payload":{"name":"bash","arguments":{"command":"echo x > /etc/foo"}}}
{"kind":"permission_resolved","session_id":"s1","ts":12,"schema_version":1,"action_id":"n3","seq":12,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":13,"schema_version":1,"action_id":"n4","seq":13,"payload":{"name":"write","arguments":{"path":"\$HOME/x"}}}
{"kind":"permission_resolved","session_id":"s1","ts":14,"schema_version":1,"action_id":"n4","seq":14,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":15,"schema_version":1,"action_id":"u1","seq":15,"payload":{"name":"bash","arguments":{"command":"cat /etc/hosts | python3 -"}}}
{"kind":"permission_resolved","session_id":"s1","ts":16,"schema_version":1,"action_id":"u1","seq":16,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"permission_resolved","session_id":"s1","ts":17,"schema_version":1,"action_id":"u9","seq":17,"payload":{"decision":"allow","decided_by":"reviewer"}}
EOF

# --- Task 3: the gate passes on pi only; the run still exits 0 ---
OUT3="$T/out3"
FAKE_EVENTS="$T/ev3.jsonl" bash "$CANARY" run 224 "$T/brief.md" \
  --gate 'test -f pass-marker' --out "$OUT3" || fail "canary run exits 0 with a failing gate"
[ "$(cat "$OUT3/pi/gate.exit")" = "0" ] || fail "pi gate passes"
[ "$(cat "$OUT3/fiber/gate.exit")" = "1" ] || fail "fiber gate fails"
grep -q '| gate | pass | fail |' "$OUT3/summary.md" || fail "summary gate row"

M3="$OUT3/fiber/metrics.json"
[ "$(jq -r .cost.main "$M3")" = "1" ] || fail "task3 main cost"
[ "$(jq -r .cost.reviewer "$M3")" = "0.5" ] || fail "task3 reviewer cost"
[ "$(jq -r .reviewed_calls "$M3")" = "8" ] || fail "task3 reviewed calls"
[ "$(jq -r .per_review_tokens_est "$M3")" = "100" ] || fail "task3 per-review tokens"
[ "$(jq -r .sandbox.contained.count "$M3")" = "2" ] || fail "task3 contained 2"
[ "$(jq -r .sandbox.needs_out.count "$M3")" = "4" ] || fail "task3 needs_out 4"
[ "$(jq -r .sandbox.unknown.count "$M3")" = "2" ] || fail "task3 unknown 2"
jq -e '.sandbox.contained.commands | any(contains("cargo test"))' "$M3" >/dev/null || fail "contained lists cargo test"
jq -e '.sandbox.contained.commands | any(contains("x.txt"))' "$M3" >/dev/null || fail "contained lists tmp write"
jq -e '.sandbox.needs_out.commands | any(contains("curl"))' "$M3" >/dev/null || fail "needs_out lists curl"
jq -e '.sandbox.needs_out.commands | any(contains("git push"))' "$M3" >/dev/null || fail "needs_out lists git push"
jq -e '.sandbox.needs_out.commands | any(contains("/etc/foo"))' "$M3" >/dev/null || fail "needs_out lists outside redirect"
jq -e '.sandbox.unknown.commands | any(contains("python3"))' "$M3" >/dev/null || fail "unknown lists piped interpreter"
jq -e '.sandbox.unknown.commands | any(. == "unknown")' "$M3" >/dev/null || fail "unknown lists the unmatched call"
[ "$(jq -r '.denials | length' "$M3")" = "1" ] || fail "one denial"
[ "$(jq -r '.denials[0].action_id' "$M3")" = "n2" ] || fail "denial action"
[ "$(jq -r '.denials[0].decided_by' "$M3")" = "reviewer" ] || fail "denial decider"
[ "$(jq -r '.denials[0].reason' "$M3")" = "no pushing" ] || fail "denial reason"
jq -e '.denials[0].command | contains("git push")' "$M3" >/dev/null || fail "denial command"
[ "$(jq -r '.denials | length' "$OUT3/pi/metrics.json")" = "0" ] || fail "pi denials empty"

echo "task 3 cases passed"

# --- Task 4: harness error on the fiber side ---
OUT4="$T/out4"
if FAKE_EVENTS="$T/ev2.jsonl" CANARY_FAKE_FAIL=fiber bash "$CANARY" run 225 "$T/brief.md" \
  --gate 'test -f work-marker' --out "$OUT4"; then
  fail "canary run exits 1 on harness error"
else
  [ $? -eq 1 ] || fail "harness error exits 1"
fi
[ "$(jq -r .outcome "$OUT4/pi/metrics.json")" = "DONE" ] || fail "pi side completes"
[ "$(jq -r .outcome "$OUT4/fiber/metrics.json")" = "harness_error" ] || fail "fiber harness_error"
[ "$(jq -r .job_id "$OUT4/fiber/metrics.json")" = "null" ] || fail "fiber job id null"
jq -e '.notes | any(contains("delegate run failed"))' "$OUT4/fiber/metrics.json" >/dev/null || fail "fiber note"
for f in worktree diff.patch gate.log gate.exit metrics.json prompt.md; do
  [ -f "$OUT4/fiber/$f" ] || fail "failed side still writes $f"
done
[ "$(cat "$OUT4/pi/gate.exit")" = "0" ] || fail "pi gate passes after fiber failure"
[ "$(jq -r .reviewed_calls "$OUT4/fiber/metrics.json")" = "null" ] || fail "fiber reviewed null"
[ "$(jq -r .cost.main "$OUT4/fiber/metrics.json")" = "null" ] || fail "fiber main null"

# nothing is ever pushed: no git push argv, no gh pr call, in any run so far
grep -q '^git push' "$FLOG/git.log" && fail "no git push is ever run"
if [ -f "$FLOG/gh.log" ]; then grep -q '^gh pr' "$FLOG/gh.log" && fail "no gh pr is ever run"; fi
[ -s "$FLOG/git.log" ] || fail "git wrapper logged calls"
grep -q 'fetch origin' "$FLOG/git.log" || fail "clone was fetched"

# a second run refuses until clean
if FAKE_EVENTS="$T/ev2.jsonl" bash "$CANARY" run 225 "$T/brief.md" \
  --gate 'test -f work-marker' --out "$OUT4" 2>/dev/null; then
  fail "second run should refuse"
else
  [ $? -eq 2 ] || fail "rerun refusal exits 2"
fi

# usage errors exit 2
bash "$CANARY" run 'a/b' "$T/brief.md" --gate true --out "$T/out-bad" 2>/dev/null && fail "bad ticket exits 2"
bash "$CANARY" run 226 "$T/no-such-brief.md" --gate true --out "$T/out-bad" 2>/dev/null && fail "missing brief exits 2"
bash "$CANARY" run 226 "$T/brief.md" --out "$T/out-bad" 2>/dev/null && fail "missing gate exits 2"
bash "$CANARY" frobnicate 2>/dev/null && fail "bad subcommand exits 2"
bash "$CANARY" clean 2>/dev/null && fail "clean without ticket exits 2"

# clean removes both worktrees and branches, keeps the metrics
bash "$CANARY" clean 225 --out "$OUT4" || fail "clean exits 0"
[ ! -e "$HOME/work/fiber-canary-225-pi" ] || fail "pi worktree removed"
[ ! -e "$HOME/work/fiber-canary-225-fiber" ] || fail "fiber worktree removed"
git -C "$HOME/work/fiber" show-ref --verify --quiet refs/heads/canary/225-pi && fail "pi branch removed"
git -C "$HOME/work/fiber" show-ref --verify --quiet refs/heads/canary/225-fiber && fail "fiber branch removed"
[ ! -f "$OUT4/pi/worktree" ] && [ ! -f "$OUT4/fiber/worktree" ] || fail "worktree files removed"
[ -f "$OUT4/pi/metrics.json" ] && [ -f "$OUT4/summary.md" ] || fail "metrics stay after clean"
git -C "$HOME/work/fiber" worktree list --porcelain | grep -q '225' && fail "225 worktrees unregistered"

# a cleaned ticket runs again
FAKE_EVENTS="$T/ev2.jsonl" bash "$CANARY" run 225 "$T/brief.md" \
  --gate 'test -f work-marker' --out "$OUT4" || fail "run works again after clean"
[ "$(jq -r .outcome "$OUT4/pi/metrics.json")" = "DONE" ] || fail "rerun pi DONE"
[ "$(jq -r .outcome "$OUT4/fiber/metrics.json")" = "DONE" ] || fail "rerun fiber DONE"
bash "$CANARY" clean 225 --out "$OUT4" || fail "second clean exits 0"

# clean with nothing to remove still exits 0
bash "$CANARY" clean 999 --out "$T/out-empty" || fail "clean of a fresh ticket exits 0"

# final no-push guarantee across every run above
grep -q '^git push' "$FLOG/git.log" && fail "no git push is ever run"
if [ -f "$FLOG/gh.log" ]; then grep -q '^gh pr' "$FLOG/gh.log" && fail "no gh pr is ever run"; fi

echo "task 4 cases passed"
