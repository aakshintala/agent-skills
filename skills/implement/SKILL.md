---
name: implement
description: "Take one ticket from start to merge: preflight, plan, Verifier, lane, gate, review, CI, merge. Use when asked to implement, land or work a ticket end to end, in session or as a sub-orchestrator."
---

You are the orchestrator for one ticket. The **main orchestrator** is the session the owner started; a **sub-orchestrator** was started by another orchestrator's brief.

## Rules

- **Never wait on a human.** A sub-orchestrator reports a decision it can't make to its parent (the decision, what it blocks, what it keeps building) and keeps building what the decision doesn't block. It never posts to the tracker or writes a handoff. The main orchestrator asks the owner once, at the start, whether they'll be around for rulings, and switches on "going away" or "back": when they're present, ask in chat; when they're away, comment on the ticket the decision blocks (or open a new ticket when it blocks none) and keep building the rest.
- **Park** a ticket when an open decision touches its core outcome: post the question on the ticket, label it `needs-info` (per `docs/agents/triage-labels.md`), and stop work on it.
- **Judge by evidence.** Read the diff and the gate output, never a worker's report. Report success only with fresh output of the gate in the same message.
- **The gate** is the lane's gate command plus three pre-push checks: the worktree's HEAD descends from the remote branch's tip, every changed file is in the plan's Files, and `git log origin/main..<branch> --stat` shows only this ticket's commits.
- **One worktree per job**, named for its branch, deleted on merge.

### 1. Check setup

Read `docs/agents/` and the workflow doc it names; the workflow doc wins where it speaks. With no `docs/agents/`, stop and report "repo not set up".

Done when you know the tracker, labels and workflow doc.

### 2. Preflight

Fill `../planning/briefs/preflight.md` and run it on a model from a different family than yours, as its own job, before any plan exists. A `core` item parks the ticket. `non-blocking` items and the file list go to the plan.

Done when the preflight has returned and no `core` item is open.

### 3. Plan

Follow `planning` steps 1–5.

Done when the lane brief is filled.

### 4. Lane

Cut a worktree from `origin/main` and dispatch the lane brief on a Work-tier model (per the `delegate` skill).

Done when the lane reports a PR URL and head SHA, or a failure triage.

### 5. Gate

Confirm the remote tip equals the lane's reported SHA (`git log origin/<branch> -1`), read the diff, and run the gate yourself. A file outside the fence or a failing check goes back to the lane, or you take the work back.

Done when the gate passes on the remote tip.

### 6. Review

Run `review-loop` on the PR.

Done when `review-loop` is done.

### 7. CI

Run `ci-triage` until the required checks are green on the current head SHA.

Done when CI is green on the head a verdict covers.

### 8. Merge

Promote the draft PR to ready, then merge by the workflow doc's rule, plus any session terms the flywheel confirmed. Close linked issues and delete the worktree. Delete the remote branch only when it still exists (`git ls-remote --exit-code --heads origin <branch>`): repos that delete merged branches have already done it.

Done when the PR is merged, or escalated as the rules above say.

### 9. Report

The merge SHA, or the PR URL with its failure triage and the action someone must take; then **Friction**: up to 3 bullets. The main orchestrator then names the next phase: the next ticket on the frontier, or `retro` when the round is done.
