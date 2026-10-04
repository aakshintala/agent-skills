# delegate

A small CLI that runs coding and research tasks on Cursor, pi, or Claude Code models by driving the local `cursor-agent` binary in headless mode. Jobs are detached supervisors; you poll status from JSON files on disk.

## Install

delegate ships inside [switchyard](https://github.com/aakshintala/switchyard). With switchyard cloned at `~/.agents`:

```bash
~/.agents/delegate/bin/setup.sh
```

This builds `delegate`, copies it to `~/.local/bin/delegate`, optionally migrates an old host profile, and links the skill for Claude Code. pi loads it from `~/.agents/skills` without a link.

You need Rust (`cargo`), and `cursor-agent` on PATH with `cursor-agent login` before running jobs.

## Commands

| Command | Purpose |
| --- | --- |
| `delegate run` | Start a job (prompt on stdin or `--prompt-file`); prints the job id. |
| `delegate resume <jobId>` | Continue a finished job that has a session id; optional model/gate overrides. |
| `delegate cancel <jobId>` | Stop a running job and print its terminal record. |
| `delegate watch <jobId>...` | Block until each job is terminal (optional `--timeout` seconds). |
| `delegate models` | List configured model ids, labels, backends, prices, and tiers. |
| `delegate doctor` | Check the binary, `cursor-agent`, login, and model menu drift. |

Every job runs with writes enabled. A read task says "do not edit" in its brief; the record's `changeSet` shows any write. Parallel jobs need separate cwds (one worktree per lane).

## Backends

| Backend | Status |
| --- | --- |
| `cursor` | Implemented (`cursor-agent`). |
| `pi` | Implemented (`pi`). |
| `claude` | Implemented (`claude`). |

Model ids and prices come from bundled `config/models.json`, merged with your host profile.

## Status records

Each job writes `$TMPDIR/delegate-jobs/<jobId>.json` (use `$TMPDIR` when set, otherwise the OS temp directory). Prompt text is stored alongside as `<jobId>.prompt` until the supervisor starts.

## Host profile

Optional JSON at `~/.config/delegate/host-profile.json` (or `$XDG_CONFIG_HOME/delegate/host-profile.json`). Override the path with `DELEGATE_HOST_PROFILE`. Keys can set `default`, `models`, `gate`, `idleMs`, and `toolIdleMs`. Missing file is fine; defaults are built in.

## Skill

The skill lives in switchyard's `skills/delegate/`. Setup links `~/.claude/skills/delegate` to it, and pi reads `~/.agents/skills` directly, so both load it from the checkout and an edit is live without a reinstall.
