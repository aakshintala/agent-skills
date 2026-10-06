---
name: ci-triage
description: "Classify a failed CI run before any retry or fix: real failure, flake, stale base, merge conflict or infrastructure. Use when CI fails on a PR, or before rerunning any CI job."
---

Failed CI is evidence. Classify it before touching code or rerunning anything. The tool is `~/.agents/bin/gh-ci` (`snapshot`, `wait`, `failures`, `watch-verified`, `resample`; usage at the top of the script).

### 1. Read

`gh-ci snapshot <pr>` for the head SHA and status, `gh-ci failures <run>` for the red legs and their failing tests.

Done when every red leg has its failing test or step named.

### 2. Classify

One class per red leg, and the one action it allows:

- **Merge conflict**: GitHub runs no CI on a conflicting PR. Rebase onto `origin/main` and resolve with `resolving-merge-conflicts`.
- **Stale base**: the failure is in code the diff never touched, and `origin/main` has moved past the merge-base. Rebase onto `origin/main`. Check this before calling anything a flake.
- **Infrastructure**: a runner, network or quota outage, with no test failing. Report it with the run id and head SHA; change no code.
- **Flake**: the same test passes elsewhere on the same platform, and nothing in the diff links to it. One fresh build (an empty commit), never a job retry. An identical second failure means it isn't a flake: reclassify as real. File the flake as an issue in the `test-only` category (per `docs/agents/triage-labels.md`), never `bug`: test name, signature, run link, suspected cause. A fixed test passes on the base commit by construction, so its PR states the root cause and the evidence (runs under load) in place of a test that fails on base.
- **Real failure**: the diff causes it. Fix it in a new commit.

`gh-ci resample` reruns a job to measure how often an intermittent failure happens. It is a diagnostic, never a way to get green.

Done when every red leg has a class, posted as a PR comment with its evidence.

### 3. Act and re-enter

Take each class's action. Any commit this makes re-enters `review-loop` at its verify step, on the same counter, so the merged head is one a verdict covers. Wait with `gh-ci wait <pr> [--timeout <s>]`, in the wait mode your harness instructions prescribe: it blocks until no required check on the PR's current head is pending, then exits 0 when all are green, 1 printing each `failing: <name>`, 3 when the PR still has merge conflicts after about 30 s of re-checks (or once the timeout budget is spent), or 124 on timeout. Use it rather than a loop of your own over `gh-ci snapshot`.

Done when the required checks are green on the PR's current head SHA, or the failure is reported with its class, run id and SHA.
