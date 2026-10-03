#!/usr/bin/env bash
# Tests for bin/pr-closes. Exits non-zero on the first failed case.
# Uses the --check mode (PR JSON on stdin), so no network is needed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRC="$SCRIPT_DIR/../bin/pr-closes"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# pr_json <title> <body> [<sha> <headline> <commit body>]...: the shape
# `gh pr view --json title,body,commits` prints.
pr_json() {
  local title="$1" body="$2"; shift 2
  local commits="[]"
  while [ $# -ge 3 ]; do
    commits="$(jq -c --arg oid "$1" --arg h "$2" --arg b "$3" \
      '. + [{oid: $oid, messageHeadline: $h, messageBody: $b}]' <<<"$commits")"
    shift 3
  done
  jq -n --arg t "$title" --arg b "$body" --argjson c "$commits" \
    '{title: $t, body: $b, commits: $c}'
}

# check <json>: runs --check, leaves stdout in $out and the exit code in $rc.
check() {
  out="$(printf '%s' "$1" | "$PRC" --check 2>/dev/null)"
  rc=$?
}

# Resolves #12 in the body alone: OK, exit 0, one line.
check "$(pr_json 'Add a thing' $'Does a thing.\n\nResolves #12')"
[ "$rc" = "0" ] || fail "Resolves only exits 0 (got $rc: $out)"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] || fail "OK is one line: [$out]"
case "$out" in OK*) ;; *) fail "OK line starts with OK: [$out]" ;; esac

# closes: #333 in a commit message: flagged with the commit sha and matched text.
check "$(pr_json 'Pipe fix' 'Resolves #330' abcdef1234567890 'Fix the pipe' 'the pipe closes: #333 now')"
[ "$rc" = "1" ] || fail "commit closes: #333 exits 1 (got $rc)"
printf '%s\n' "$out" | grep -q '#333' || fail "commit closes: names #333: [$out]"
printf '%s\n' "$out" | grep -q 'commit abcdef1' || fail "commit closes: names the commit: [$out]"
printf '%s\n' "$out" | grep -q 'closes: #333' || fail "commit closes: shows matched text: [$out]"
printf '%s\n' "$out" | grep -q '#330' && fail "Resolves #330 is not flagged: [$out]"

# Fixes #5 in the title: flagged as title.
check "$(pr_json 'Fixes #5 crash' 'Resolves #4')"
[ "$rc" = "1" ] || fail "title Fixes #5 exits 1 (got $rc)"
printf '%s\n' "$out" | grep -q '#5.*title.*Fixes #5' || fail "title Fixes #5 flagged as title: [$out]"

# see #7 is not a closing keyword.
check "$(pr_json 'Tidy, see #7' $'see #7 for context\n\nResolves #6' 1111111 'see #7' '')"
[ "$rc" = "0" ] || fail "see #7 exits 0 (got $rc: $out)"

# resolved #9 in a commit, with #9 in Resolves: OK.
check "$(pr_json 'Thing' 'Resolves #9' 2222222 'Work' 'this resolved #9')"
[ "$rc" = "0" ] || fail "resolved #9 in Resolves exits 0 (got $rc: $out)"

# cross-repo fixes owner/repo#3: flagged.
check "$(pr_json 'Thing' $'Resolves #3\nAlso fixes owner/repo#3')"
[ "$rc" = "1" ] || fail "cross-repo fixes exits 1 (got $rc)"
printf '%s\n' "$out" | grep -q 'owner/repo#3.*body' || fail "cross-repo fixes flagged in body: [$out]"

# case-insensitive keyword in the body, outside the Resolves list: flagged.
check "$(pr_json 'Thing' $'Resolves #1\nThis CLOSED #2 too')"
[ "$rc" = "1" ] || fail "CLOSED #2 exits 1 (got $rc)"
printf '%s\n' "$out" | grep -q '#2.*body' || fail "CLOSED #2 flagged in body: [$out]"

# a keyword inside a longer word is not a keyword.
check "$(pr_json 'Thing' $'Resolves #1\nprefixes #2 and unfixed #3')"
[ "$rc" = "0" ] || fail "prefixes/unfixed exit 0 (got $rc: $out)"

# no Resolves line and no keyword: OK.
check "$(pr_json 'Thing' 'Part of #38')"
[ "$rc" = "0" ] || fail "Part of exits 0 (got $rc: $out)"

# each stray issue is reported, one line each.
check "$(pr_json 'Thing' 'Resolves #1' 3333333 'fix #4' 'closes #5')"
[ "$rc" = "1" ] || fail "two strays exit 1 (got $rc)"
[ "$(printf '%s\n' "$out" | grep -c '^#')" = "2" ] || fail "two strays, two lines: [$out]"

# bad usage exits 2
"$PRC" >/dev/null 2>&1; [ "$?" = "2" ] || fail "no args exits 2"
"$PRC" 12 --bogus >/dev/null 2>&1; [ "$?" = "2" ] || fail "unknown flag exits 2"
"$PRC" 12 --repo >/dev/null 2>&1; [ "$?" = "2" ] || fail "--repo without value exits 2"
printf 'not json' | "$PRC" --check >/dev/null 2>&1; [ "$?" = "2" ] || fail "bad JSON exits 2"

echo "pr-closes: all cases passed"
