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
"$FILL" "$T/t.md" 'NOEQUALS' >/dev/null 2>&1; [ "$?" = "2" ] || fail "key without = exits 2"
"$FILL" "$T/does-not-exist.md" 'A=1' >/dev/null 2>&1; [ "$?" = "2" ] || fail "missing template exits 2"

echo "fill-brief: all cases passed"
