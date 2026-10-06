# switchyard

Skills, helper scripts and the `delegate` CLI for coding agents (Claude Code, pi): planning a ticket, landing it through delegated lanes, reviewing and repairing PRs, triaging CI, and running a flywheel of tickets with the owner away.

Started from [mattpocock/skills](https://github.com/mattpocock/skills) and reworked since.

## Layout

| Path | What it holds |
| --- | --- |
| `skills/` | One folder per skill: `SKILL.md`, plus brief templates in `briefs/` where the skill starts other jobs. |
| `delegate/` | The `delegate` CLI (Rust): runs a brief on another model and reports a job record. |
| `bin/` | Scripts the skills call: `fill-brief`, `review-pr`, `gh-ci`, `pr-closes`, `ship-pr`, `check-pack`. |
| `test/` | Tests for the scripts. `test/run` runs every suite. |
| `docs/agents/` | This repo's own setup for the skills: issue tracker, triage labels, workflow doc. |

## Install

Clone to `~/.agents` and link the skills into your agent's skills folder, for example:

```bash
git clone https://github.com/aakshintala/switchyard ~/.agents
for s in ~/.agents/skills/*/; do ln -s "$s" ~/.claude/skills/; done
```

The skills call scripts at `~/.agents/bin/`.

## delegate

Delegated work runs through the `delegate` CLI in `delegate/`, a Rust binary that runs tasks on Cursor, pi and Claude Code models. Install it with `~/.agents/delegate/bin/setup.sh`; see [delegate/README.md](delegate/README.md). It moved here from `aakshintala/delegate`, which is archived and keeps the old issue and PR history.

## Working on it

Branch, open a PR, squash merge. CI (`ci`) runs `test/run` and delegate's format, lint and tests, and must pass on a head up to date with `main`. Several skills are adapted from other MIT-licensed projects; each says so in a comment at the top and carries its upstream licence beside it.

## Licence

MIT. See [LICENSE](LICENSE).
