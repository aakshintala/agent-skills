#!/usr/bin/env bash
# Tests for bin/ci-health, using a stand-in gh serving fixture files
# (no network). Fake gh maps the api path to test/fixtures/ci-health,
# logs its args, and fails paths listed in $T/fail-<key>.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HEALTH="$SCRIPT_DIR/../bin/ci-health"
FIX="$SCRIPT_DIR/fixtures/ci-health"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-ci-health.XXXXXX")"
export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export CI_HEALTH_NOW="2026-10-09T18:30:00Z"

# --- fake gh ---
cat >"$T/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
# args: gh api [--allow-escape-sequences] <path>
echo "gh $*" >>"$FAKE_GH_LOG"
path=""
for a in "$@"; do
  case "$a" in
    api|--allow-escape-sequences) continue;;
    -*) continue;;
    *) path="$a";;
  esac
done
[ -n "$path" ] || { echo "fake gh: no path" >&2; exit 2; }
scen="$FAKE_SCEN"
serve() { # serve <file>: cat it, or fail when the fail flag is set
  local f="$1" key="$2"
  if [ -e "$T/fail-$key" ]; then
    cat "$T/fail-$key" >&2
    exit 1
  fi
  if [ -e "$scen/$f" ]; then cat "$scen/$f"; return 0; fi
  if [ -e "$FAKE_BASE/$f" ]; then cat "$FAKE_BASE/$f"; return 0; fi
  echo "fake gh: no fixture $f for $path" >&2
  exit 2
}
case "$path" in
  *actions/runs\?branch=main*)
    serve main-runs.json main;;
  *actions/runs\?created=*)
    case "$path" in *page=1*) serve runs.json runs;; *) printf '{"workflow_runs":[]}';; esac;;
  *actions/runs/*/jobs*)
    rid="$(printf '%s' "$path" | sed -E 's/.*runs\/([0-9]+).*/\1/')"
    f="jobs-$rid.json"
    if [ -e "$T/fail-jobs-$rid" ]; then cat "$T/fail-jobs-$rid" >&2; exit 1; fi
    if [ -e "$scen/$f" ]; then cat "$scen/$f";
    elif [ -e "$FAKE_BASE/$f" ]; then cat "$FAKE_BASE/$f";
    else printf '{"total_count":0,"jobs":[]}'; fi;;
  *actions/jobs/*/logs)
    jid="$(printf '%s' "$path" | sed -E 's/.*jobs\/([0-9]+).*/\1/')"
    if [ -e "$T/fail-log-$jid" ]; then cat "$T/fail-log-$jid" >&2; exit 1; fi
    serve "logs/$jid.txt" "log-$jid";;
  *actions/cache/usage)
    serve cache.json cache;;
  *commits/main)
    serve head.json head;;
  *commits\?sha=main*)
    serve target.json target;;
  *compare/*)
    base="$(printf '%s' "$path" | sed -E 's/.*compare\/([^.]+).*/\1/')"
    f="compare-${base:0:8}.json"
    if [ -e "$scen/$f" ]; then cat "$scen/$f"; else serve compare.json compare; fi;;
  *) echo "fake gh: unknown path $path" >&2; exit 2;;
esac
FAKEGH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
export FAKE_BASE="$FIX/_base"

export HOME="$T/home"
export TMPDIR="$T/tmp"
mkdir -p "$HOME" "$TMPDIR"

OUT=""; CODE=0
setup() { # setup <scenario>: fresh HOME, scenario fixtures
  export FAKE_SCEN="$FIX/$1"
  export FAKE_GH_LOG="$T/gh-args-$1.txt"
  : >"$FAKE_GH_LOG"
  rm -rf "$HOME" "$TMPDIR" "$T"/fail-*
  mkdir -p "$HOME" "$TMPDIR"
}
run_health() {
  OUT="$(python3 "$HEALTH" --repo O/N "$@" 2>"$T/stderr.txt")"; CODE=$?
}
expect() { # expect <code> <grep>: exit code and output pattern
  [ "$CODE" = "$1" ] || fail "exit $1 (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
  grep -q "$2" <<<"$OUT" || fail "output matches [$2]: [$OUT]"
}
jget() { # jget <python-expr>: eval OUT as JSON (OUT must be --json output)
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print('"$1"')' "$OUT"
}

# --- calm: exit 0, one-line summary ---
setup calm
run_health
expect 0 "^ci-health O/N: OK"
grep -q "pr p90" <<<"$OUT" || fail "summary queue part: [$OUT]"
grep -q "saturated 0m" <<<"$OUT" || fail "summary saturation part: [$OUT]"
grep -q "cache 8.00 GB" <<<"$OUT" || fail "summary cache part: [$OUT]"

# --- calm --json: field presence and values ---
setup calm
run_health --json
[ "$CODE" = "0" ] || fail "calm json exits 0 (got $CODE): [$OUT]"
[ "$(jget "d['pr_queue']['Selection']['n']")" = "2" ] || fail "Selection n=2: [$OUT]"
[ "$(jget "d['pr_queue']['Tests linux-x64']['n']")" = "1" ] || fail "Tests n=1: [$OUT]"
[ "$(jget "d['pr_queue'].get('Mutants', 'absent')")" = "absent" ] || fail "Mutants excluded: [$OUT]"
[ "$(jget "d['main_queue']")" = "{}" ] || fail "main_queue empty: [$OUT]"
[ "$(jget "d['saturated_minutes']")" = "0" ] || fail "saturated 0"
[ "$(jget "d['macos_capped_minutes']")" = "0" ] || fail "macos capped 0"
[ "$(jget "d['backstop']['commits_behind']")" = "0" ] || fail "behind 0: [$OUT]"
[ "$(jget "d['backstop']['red_streak']")" = "0" ] || fail "red streak 0"
[ "$(jget "d['backstop']['red_causes']")" = "[]" ] || fail "red causes []"
[ "$(jget "d['timeouts']")" = "[]" ] || fail "no timeouts"
[ "$(jget "d['design_failures']")" = "[]" ] || fail "no design failures"
[ "$(jget "d['cache_bytes']")" = "8000000000" ] || fail "cache bytes"
[ "$(jget "d['breaches']")" = "[]" ] || fail "no breaches"
[ "$(jget "d['partial']")" = "False" ] || fail "not partial"
[ "$(jget "d['window']")" = "{'start': '2026-10-09T17:15:00Z', 'end': '2026-10-09T18:30:00Z'}" ] \
  || fail "window: [$OUT]"
[ "$(jget "d['backstop']['head_sha']")" = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ] || fail "head sha"

# --- queue-p90 breach, and the flag moves it out ---
setup q90
run_health
expect 1 "BREACH queue-p90"
setup q90
run_health --queue-p90 99
expect 0 "^ci-health O/N: OK"

# --- queue-max: a 17.2m Selection and a still-queued Tests job breach;
# --- a terminal job that never started is excluded ---
setup qmax
run_health
[ "$CODE" = "1" ] || fail "qmax exits 1 (got $CODE): [$OUT]"
grep -q "BREACH queue-max" <<<"$OUT" || fail "qmax line: [$OUT]"
setup qmax
run_health --json
grep -q "Selection queued 17.2 min (job 21)" <<<"$OUT" || fail "queue-max detail: [$OUT]"
grep -q "job 22" <<<"$OUT" || fail "still-queued job breaches: [$OUT]"
setup qmax
run_health --json
[ "$(jget "sorted(d['pr_queue'].keys())")" = "['Selection', 'Tests linux-x64']" ] \
  || fail "terminal-unstarted job excluded: [$OUT]"
setup qmax
run_health --queue-max 99
[ "$CODE" = "1" ] || fail "queue-p90 still breaches at --queue-max 99 (got $CODE): [$OUT]"
grep -q "queue-p90" <<<"$OUT" || fail "only queue-p90 left: [$OUT]"

# --- saturation: flags move the breach in and out ---
setup sat
run_health --sat-jobs 2 --sat-min 2
expect 1 "BREACH saturation"
setup sat
run_health
expect 0 "^ci-health O/N: OK"

# --- design: timeout (9.8m cancelled Tests linux-arm, limit 10) ---
setup timeout
run_health
expect 1 "BREACH design"
setup timeout
run_health --json
[ "$CODE" = "1" ] || fail "timeout json exits 1 (got $CODE)"
[ "$(jget "len(d['timeouts'])")" = "1" ] || fail "one timeout: [$OUT]"
[ "$(jget "d['timeouts'][0]['minutes']")" = "9.8" ] || fail "timeout minutes: [$OUT]"
[ "$(jget "d['design_failures'][0]['kind']")" = "timeout" ] || fail "design kind: [$OUT]"

# --- design: bench comment failure ---
setup bench
run_health --json
expect 1 "bench-comment"
[ "$(jget "d['design_failures'][0]['kind']")" = "bench-comment" ] || fail "bench kind: [$OUT]"

# --- design: release exit 127 ---
setup rel127
run_health --json
expect 1 "release-exit-127"
[ "$(jget "d['design_failures'][0]['kind']")" = "release-exit-127" ] || fail "release kind: [$OUT]"

# --- cache breach, and the flag moves it out ---
setup cache
run_health
expect 1 "BREACH cache"
setup cache
run_health --cache-max 11
expect 0 "^ci-health O/N: OK"

# --- backstop: uncovered target breaches ---
setup bs-breach
run_health
expect 1 "BREACH backstop"
setup bs-breach
run_health --json
[ "$(jget "d['backstop']['commits_behind']")" = "5" ] || fail "behind 5: [$OUT]"
grep -q '"check": "backstop"' <<<"$OUT" || fail "backstop check: [$OUT]"
grep -q 'backstop-broken' <<<"$OUT" && fail "no broken breach: [$OUT]"

# --- backstop: no green known breaches, nulls reported ---
setup bs-nogreen
run_health
expect 1 "BREACH backstop"
setup bs-nogreen
run_health --json
[ "$(jget "d['backstop']['last_core_green_sha']")" = "None" ] || fail "green null: [$OUT]"
[ "$(jget "d['backstop']['last_core_green_at']")" = "None" ] || fail "green at null: [$OUT]"
[ "$(jget "d['backstop']['red_streak']")" = "2" ] || fail "red streak 2: [$OUT]"

# --- backstop-broken: two reds, same compile error ---
setup broken-same
run_health
expect 1 "BREACH backstop-broken"
setup broken-same
run_health --json
[ "$(jget "d['backstop']['red_streak']")" = "2" ] || fail "streak 2: [$OUT]"
[ "$(jget "d['backstop']['red_causes']")" = "['compile tui: error[E0277]: mismatched types']" ] \
  || fail "red causes: [$OUT]"
grep -q '"check": "backstop"' <<<"$OUT" && fail "covered backstop stays quiet: [$OUT]"

# --- same jobs, different tests: red but not broken ---
setup broken-diff
run_health
expect 0 "^ci-health O/N: OK"
setup broken-diff
run_health --json
[ "$(jget "d['backstop']['red_streak']")" = "2" ] || fail "streak 2: [$OUT]"
[ "$(jget "d['backstop']['red_causes']")" = "['test fiber-core doors::open', 'test fiber-core doors::watch']" ] \
  || fail "red causes: [$OUT]"

# --- state: second run fetches no jobs; corrupt state warns and runs ---
setup calm
run_health
[ "$CODE" = "0" ] || fail "first run exits 0 (got $CODE)"
[ -e "$HOME/.cache/switchyard/ci-health.json" ] || fail "state written under HOME"
python3 -c "import json; d=json.load(open('$HOME/.cache/switchyard/ci-health.json')); assert d['last_core_green_sha'], d; assert '101' in d['runs'], d.keys()" \
  || fail "state holds check time, job cache and last green"
run_health
[ "$CODE" = "0" ] || fail "second run exits 0 (got $CODE)"
[ "$(grep -c 'actions/runs/101/jobs' "$FAKE_GH_LOG")" = "1" ] \
  || fail "jobs fetched once across runs: [$(cat "$FAKE_GH_LOG")]"
echo "not json" >"$HOME/.cache/switchyard/ci-health.json"
run_health
expect 0 "^ci-health O/N: OK"
grep -qi "state unreadable" "$T/stderr.txt" || fail "corrupt state warning: [$(cat "$T/stderr.txt")]"

# --- exits: 2 on bad flag, missing repo, runs failure ---
OUT="$(python3 "$HEALTH" --repo O/N --bogus 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "bad flag exits 2 (got $CODE)"
OUT="$(python3 "$HEALTH" --window 5 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "missing repo exits 2 (got $CODE)"
OUT="$(python3 "$HEALTH" --repo 'not a repo' 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "bad repo exits 2 (got $CODE)"
OUT="$(python3 "$HEALTH" --repo O/N --window 5x 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "bad window exits 2 (got $CODE)"
OUT="$(python3 "$HEALTH" --repo O/N --sat-jobs 0 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "bad sat-jobs exits 2 (got $CODE)"
setup calm
echo "HTTP 401 Unauthorized" >"$T/fail-runs"
run_health
[ "$CODE" = "2" ] || fail "runs 401 exits 2 (got $CODE): [$OUT]"

# --- exits: 3 on partial without breach; 1 wins over 3 ---
setup calm
echo "HTTP 500 boom" >"$T/fail-jobs-101"
run_health --json
[ "$CODE" = "3" ] || fail "one jobs failure exits 3 (got $CODE): [$OUT]"
[ "$(jget "d['partial']")" = "True" ] || fail "partial true: [$OUT]"
setup bs-breach
echo "HTTP 500 boom" >"$T/fail-jobs-101"
run_health
[ "$CODE" = "1" ] || fail "breach beats partial (got $CODE): [$OUT]"

echo "ci-health: all cases passed"
