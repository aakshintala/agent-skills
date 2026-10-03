---
name: implement
description: "Take one ticket from start to merge: preflight, plan, Verifier, lane, gate, review, CI, merge. Use when asked to implement, land or work a ticket end to end, in session or as a sub-orchestrator."
---

You are the orchestrator for one ticket. The **main orchestrator** is the session the owner started; a **sub-orchestrator** was started by another orchestrator's brief.

## Rules

- **Never wait on a human.** A sub-orchestrator posts a decision it can't make to the tracker, with its options and a recommendation: a comment on the ticket it blocks, or a `needs-info` ticket when it blocks none. It may also open follow-up tickets. It searches the tracker for an existing issue before opening one, reports each decision to its parent (the link, what it blocks, what it keeps building), lists every issue it opened or commented on in its report, and keeps building what the decision doesn't block. It never writes a handoff. The main orchestrator keeps the conversation with the owner (what to ask, when, and in what order). It asks the owner once, at the start, whether they'll be around for rulings, and switches on "going away" or "back": when they're present, ask in chat; when they're away, comment on the ticket the decision blocks (or open a new ticket when it blocks none) and keep building the rest.
- **Park** a ticket when an open decision touches its core outcome: post the question on the ticket, label it `needs-info` (per `docs/agents/triage-labels.md`), and stop work on it.
- **Judge by evidence.** Read the diff and the gate output, never a worker's report. Report success only with fresh output of the gate in the same message.
- **The gate** is the lane's gate command plus three pre-push checks: the worktree's HEAD descends from the remote branch's tip, every changed file is in the plan's Files, and `git log origin/main..<branch> --stat` shows only this ticket's commits.
- **Fix by churn.** Make a trivial change (a one-line deletion, a rename, a PR-body or label fix) inline, then run the gate yourself and state its output. Send a change that may start a run-and-fix loop (new behaviour, a fix whose cause isn't confirmed, an edit across several files) to a gated job.
- **One worktree per job**, named for its branch, deleted on merge.

### 1. Check setup

Read `docs/agents/` and the workflow doc it names; the workflow doc wins where it speaks. With no `docs/agents/`, stop and report "repo not set up".

A main orchestrator outside a flywheel then confirms with the owner the Work and Hard tier picks (per the `delegate` skill) and a review pool: a correctness and an over-engineering reviewer, each from a family other than the implementers'. A sub-orchestrator takes these from its brief.

Done when you know the tracker, labels, workflow doc and models.

### 2. Preflight

Fill `../planning/briefs/preflight.md` with `fill-brief --out <absolute path>` (e.g. `/tmp/<repo>-<issue>-preflight.md`) and run it as its own job, on a model from a different family than yours, before any plan exists, using the printed line verbatim as the prompt, never a hand-written path. A `core` item parks the ticket. `non-blocking` items and the file list go to the plan.

Done when the preflight has returned and no `core` item is open.

### 3. Plan

Follow `planning` steps 1–5.

Done when the lane brief is filled.

### 4. Lane

Cut a worktree from `origin/main` and dispatch the lane brief on a Work-tier model (per the `delegate` skill). The lane brief was filled with `fill-brief --out <absolute path>`; use the printed line verbatim as the lane's prompt, never a hand-written path.

Done when the lane reports a PR URL and head SHA, or a failure triage.

### 5. Gate

Confirm the remote tip equals the lane's reported SHA (`git log origin/<branch> -1`), read the diff, and run the gate yourself. A file outside the fence or a failing check goes back to the lane, or you take the work back.

Done when the gate passes on the remote tip.

### 6. Review

Run `review-loop` on the PR.

Done when `review-loop` is done.

### 7. CI

Run `ci-triage` until the required checks are green on the current head SHA. Green comes from a fix, never a rerun: a flake gets `ci-triage`'s one fresh build and a `test-only` issue, and `gh-ci resample` only measures how often a failure happens.

Done when CI is green on the head a verdict covers.

### 8. Merge

Promote the draft PR to ready, then merge by the workflow doc's rule, plus any session terms the flywheel confirmed. Close linked issues and delete the worktree. Delete the remote branch (`git push origin --delete <branch>`); a `remote ref does not exist` error means the repo already deleted it on merge, which counts as done.

Done when the PR is merged, or escalated as the rules above say.

### 9. Report

The merge SHA, or the PR URL with its failure triage and the action someone must take; then **Friction**: up to 3 bullets. The main orchestrator then names the next phase: the next ticket on the frontier, or `retro` when the round is done.
