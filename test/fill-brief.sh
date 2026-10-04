#!/usr/bin/env bash
# Tests for bin/fill-brief. Exits non-zero on the first failed case.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILL="$SCRIPT_DIR/../bin/fill-brief"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-fill-brief.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# basic fill of two placeholders
printf 'a __A__ b __B__ c\n' >"$T/t.md"
out="$("$FILL" "$T/t.md" 'A=1' 'B=2')" || fail "basic fill exits 0"
[ "$out" = "a 1 b 2 c" ] || fail "basic fill content: got [$out]"

# unfilled placeholder: exit 1, nothing on stdout, named on stderr
printf 'hello __NAME__, __NAME__ again, __OTHER__\n' >"$T/u.md"
stdout="$("$FILL" "$T/u.md" 2>"$T/err.txt")" && fail "unfilled exits 1"
[ -z "$stdout" ] || fail "unfilled prints nothing on stdout"
grep -q '^unfilled: __NAME__$' "$T/err.txt" || fail "unfilled names __NAME__"
grep -q '^unfilled: __OTHER__$' "$T/err.txt" || fail "unfilled names __OTHER__"
[ "$(wc -l <"$T/err.txt" | tr -d ' ')" = "2" ] || fail "unfilled names each placeholder once"

# unknown key: exit 1, nothing on stdout, named on stderr
printf 'hi\n' >"$T/k.md"
stdout="$("$FILL" "$T/k.md" 'ZZZ=1' 2>"$T/err2.txt")" && fail "unknown key exits 1"
[ -z "$stdout" ] || fail "unknown key prints nothing on stdout"
grep -q '^unknown key: ZZZ$' "$T/err2.txt" || fail "unknown key names ZZZ"

# unknown key alongside an otherwise clean fill still fails
printf 'hi __WHO__\n' >"$T/k2.md"
"$FILL" "$T/k2.md" 'WHO=you' 'EXTRA=1' >/dev/null 2>"$T/err3.txt" && fail "unknown key with valid fill exits 1"
grep -q '^unknown key: EXTRA$' "$T/err3.txt" || fail "unknown key with valid fill names EXTRA"

# key early in a long template must not trip pipefail + grep -q EPIPE (issue #55)
{ echo '__A__'; seq 1 5000 | sed 's/^/filler line /'; } >"$T/big.md"
"$FILL" "$T/big.md" 'A=x' >"$T/big-out.txt" 2>"$T/big-err.txt" || fail "a key early in a long template is known"
[ "$(head -1 "$T/big-out.txt")" = "x" ] || fail "a key early in a long template fills first line"

# a value that quotes a placeholder is data, not an unfilled placeholder (issue #70)
printf 'Plan:\n__PLAN__\n' >"$T/q.md"
printf 'quote: `diff __SINCE__..HEAD`\n' >"$T/qp.md"
out="$("$FILL" "$T/q.md" "PLAN=@$T/qp.md" 2>"$T/err-q.txt")" || fail "quoted placeholder in value exits 0"
case "$out" in *'diff __SINCE__..HEAD'*) ;; *) fail "quoted placeholder printed literally: got [$out]" ;; esac
# a template placeholder with no key still fails as unfilled
printf 'Plan:\n__PLAN__ __SINCE__\n' >"$T/q2.md"
"$FILL" "$T/q2.md" "PLAN=@$T/qp.md" >/dev/null 2>"$T/err-q2.txt" && fail "template placeholder with no key exits 1"
grep -q '^unfilled: __SINCE__$' "$T/err-q2.txt" || fail "template placeholder with no key names __SINCE__"

# adjacent placeholders are filled separately
printf '__A____B__\n' >"$T/adj.md"
out="$("$FILL" "$T/adj.md" 'A=1' 'B=2')" || fail "adjacent placeholders exit 0"
[ "$out" = "12" ] || fail "adjacent placeholders content: got [$out]"

# multi-line @file value containing & \ $ / passes through unchanged
printf 'first __V__ last\n' >"$T/m.md"
printf 'a&b\\c$d/e\nsecond & \\ line\n' >"$T/val.txt"
"$FILL" "$T/m.md" "V=@$T/val.txt" >"$T/got.txt" || fail "atfile fill exits 0"
printf 'first a&b\\c$d/e\nsecond & \\ line\n last\n' >"$T/want.txt"
cmp -s "$T/got.txt" "$T/want.txt" || fail "atfile value is literal"

# a repeated placeholder is filled everywhere
printf 'x __A__ y __A__\n' >"$T/r.md"
out="$("$FILL" "$T/r.md" 'A=Z')" || fail "repeat fill exits 0"
[ "$out" = "x Z y Z" ] || fail "repeat fill content: got [$out]"

# bad usage exits 2
"$FILL" >/dev/null 2>&1; [ "$?" = "2" ] || fail "no args exits 2"
usage_out="$("$FILL" 2>&1 >/dev/null)" || true
case "$usage_out" in *"--out must come first"*) ;; *) fail "usage mentions --out must come first" ;; esac
"$FILL" "$T/t.md" 'NOEQUALS'>/dev/null 2>&1; [ "$?" = "2" ] || fail "key without = exits 2"
"$FILL" "$T/does-not-exist.md" 'A=1' >/dev/null 2>&1; [ "$?" = "2" ] || fail "missing template exits 2"

# --out writes the file and prints exactly the launch line
printf 'a __A__ b\n' >"$T/o.md"
"$FILL" --out "$T/brief.md" "$T/o.md" 'A=1' >"$T/line.txt" || fail "--out exits 0"
[ "$(wc -l <"$T/line.txt" | tr -d ' ')" = "1" ] || fail "--out prints exactly one line"
[ "$(cat "$T/line.txt")" = "Read $T/brief.md and follow it." ] || fail "--out prints launch line"
"$FILL" "$T/o.md" 'A=1' >"$T/std.txt" || fail "stdout mode exits 0"
cmp -s "$T/brief.md" "$T/std.txt" || fail "--out file matches stdout mode"

# --out with a relative path exits 2, nothing on stdout
stdout="$("$FILL" --out rel/brief.md "$T/o.md" 'A=1' 2>"$T/err-rel.txt")"; [ "$?" = "2" ] || fail "relative --out exits 2"
[ -z "$stdout" ] || fail "relative --out prints nothing on stdout"

# --out to an unwritable path exits 1, nothing on stdout
stdout="$("$FILL" --out "$T/no-such-dir/brief.md" "$T/o.md" 'A=1' 2>/dev/null)"; [ "$?" = "1" ] || fail "unwritable --out exits 1"
[ -z "$stdout" ] || fail "unwritable --out prints nothing on stdout"
[ ! -e "$T/no-such-dir/brief.md" ] || fail "unwritable --out writes nothing"

# a failing placeholder check with --out exits 1 and writes nothing
printf 'hello __NAME__\n' >"$T/ou.md"
rm -f "$T/should-not-exist.md"
stdout="$("$FILL" --out "$T/should-not-exist.md" "$T/ou.md" 2>"$T/err-ou.txt")"; [ "$?" = "1" ] || fail "unfilled --out exits 1"
[ -z "$stdout" ] || fail "unfilled --out prints nothing on stdout"
grep -q '^unfilled: __NAME__$' "$T/err-ou.txt" || fail "unfilled --out names __NAME__"
[ ! -e "$T/should-not-exist.md" ] || fail "unfilled --out writes nothing"

# --out with a newline in the path exits 2, nothing on stdout, writes nothing
nl_path="$T/bad
name.md"
stdout="$("$FILL" --out "$nl_path" "$T/o.md" 'A=1' 2>"$T/err-nl.txt")"; [ "$?" = "2" ] || fail "newline --out exits 2"
[ -z "$stdout" ] || fail "newline --out prints nothing on stdout"
[ ! -e "$nl_path" ] || fail "newline --out writes nothing"

# --out to a write-only file exits 1: the read-back cannot be verified
printf '' >"$T/empty.md"
: >"$T/wo.md"
chmod 200 "$T/wo.md"
stdout="$("$FILL" --out "$T/wo.md" "$T/empty.md" 2>"$T/err-wo.txt")"; [ "$?" = "1" ] || fail "unreadable --out exits 1"
[ -z "$stdout" ] || fail "unreadable --out prints nothing on stdout"
grep -q 'cannot read output file' "$T/err-wo.txt" || fail "unreadable --out names read error"
chmod 600 "$T/wo.md"

echo "fill-brief: all cases passed"
