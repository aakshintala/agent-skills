#!/usr/bin/env bash
# Tests for bin/check-pack, against fixture packs (never the real tree).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/../bin/check-pack"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-check-pack.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# --- fixture pack holding a missing skill, a broken link and a bad template
BAD="$T/bad"
mkdir -p "$BAD/skills/alpha/briefs" "$BAD/skills/beta"
cat >"$BAD/skills/alpha/SKILL.md" <<'EOF'
# Alpha
Load the `beta` skill and the `nosuch` skill.
Call the Skill tool with "beta".
Run `/beta` to start.
See [the guide](./guide.md) and [missing](./nope.md).
Follow `__SKILLS__/beta/SKILL.md` and `__SKILLS__/ghost/SKILL.md`.
The binary lives at `~/.agents/bin/alpha`.
EOF
printf '# Guide\n' >"$BAD/skills/alpha/guide.md"
printf '# Beta\n' >"$BAD/skills/beta/SKILL.md"
mkdir -p "$BAD/.agents/bin"
printf 'x\n' >"$BAD/.agents/bin/alpha"
cat >"$BAD/skills/alpha/briefs/job.md" <<'EOF'
Do __WORK__ on __work__ now.
Template uses {{thing}} too.
EOF

out="$("$CHECK" "$BAD" 2>"$T/baderr.txt")" && fail "bad pack exits 1"
printf '%s' "$out" | grep -q '^skills/alpha/SKILL.md:[0-9]*: .*nosuch' || fail "bad pack flags missing skill"
printf '%s' "$out" | grep -q '^skills/alpha/SKILL.md:[0-9]*: .*nope.md' || fail "bad pack flags broken link"
printf '%s' "$out" | grep -q '^skills/alpha/SKILL.md:[0-9]*: .*ghost' || fail "bad pack flags missing __SKILLS__ file"
printf '%s' "$out" | grep -q '^skills/alpha/briefs/job.md:[0-9]*: .*[Pp]laceholder.*__work__' || fail "bad pack flags bad placeholder"
printf '%s' "$out" | grep -q '^skills/alpha/briefs/job.md:[0-9]*: .*{{thing}}' || fail "bad pack flags braces token"
printf '%s' "$out" | grep -q 'beta' && fail "bad pack never flags the good skill"
[ -s "$T/baderr.txt" ] && fail "bad pack is silent on stderr"

# --- fixture pack holding only good references passes silently
GOOD="$T/good"
mkdir -p "$GOOD/skills/alpha/briefs" "$GOOD/skills/beta"
cat >"$GOOD/skills/alpha/SKILL.md" <<'EOF'
# Alpha
Load the `beta` skill and the `delegate` skill.
Call the Skill tool with "beta" and the Skill tool with `delegate`.
Run `/beta` or `/beta now` to start.
See [the guide](./guide.md) and [beta](../beta/SKILL.md).
Follow `__SKILLS__/beta/SKILL.md`.
The binary lives at `~/.agents/bin/alpha`.
EOF
printf '# Guide\n' >"$GOOD/skills/alpha/guide.md"
printf '# Beta\n' >"$GOOD/skills/beta/SKILL.md"
mkdir -p "$GOOD/.agents/bin"
printf 'x\n' >"$GOOD/.agents/bin/alpha"
cat >"$GOOD/skills/alpha/briefs/job.md" <<'EOF'
Do __WORK__ on __OTHER_WORK2__ now.
EOF
out="$("$CHECK" "$GOOD" 2>"$T/gooderr.txt")" || fail "good pack exits 0"
[ -z "$out" ] || fail "good pack prints nothing: [$out]"
[ -s "$T/gooderr.txt" ] && fail "good pack is silent on stderr"

# --- bad usage exits 2
"$CHECK" "$T/does-not-exist" >/dev/null 2>&1; [ "$?" = "2" ] || fail "missing ROOT exits 2"

echo "check-pack: all cases passed"
