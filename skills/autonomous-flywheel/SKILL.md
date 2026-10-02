---
name: autonomous-flywheel
description: "Flywheel: land a stack of tickets or PRs through parallel lanes, at any hour, with the owner away: frontier, fences, merge terms, round report. Fires when asked to run or continue a flywheel session, or to land a stack of PRs."
---

# Autonomous flywheel

Schedule many tickets through `implement` in parallel lanes, or many PRs through `review-loop` and `ci-triage`. Each ticket's own work is `implement`; this skill holds only the scheduling around it. The owner confirms the session at start, then may be away for the rest of it.

### 1. Confirm the session

With the owner, at start (a typed start means they're present now):

- Repo, work source (a list of tickets, or a stack of PRs for PR-stack mode), base commit.
- Models: the Work and Hard tier picks (per the `delegate` skill), and the lane budget (2 works).
- Merge terms: the cases that need the owner's call beyond the workflow doc's merge rule. Terms only add cases; the workflow doc's merge rule always holds. CI-boundary changes (workflows, rulesets) need the owner's call unless the terms include them.
- `gh auth status` shows the `workflow` scope; without it, PRs touching `.github/workflows/*` fail to merge.
- Whether the owner will be around for rulings (see `implement`).

Write these to the state file (step 4).

Done when the owner has confirmed every bullet.

### 2. Fill the lanes

- Take the **frontier**: open tickets whose blockers are all closed. A ticket enters a lane only when its fence (the plan's Files) is disjoint from every running lane's.
- Start each ticket's sub-orchestrator with `briefs/ticket-orchestrator.md`, filled with `~/.agents/bin/fill-brief` (`SKILLS` is this pack's `skills` folder as an absolute path, so a harness that doesn't load the pack still finds `implement`). It runs `implement` for that ticket and reports back here.
- Give every job its own worktree: delegation doesn't enforce read-only, so a shared directory lets parallel jobs damage each other. In the shared checkout run only `git fetch`.
- When a lane closes, start the next disjoint ticket at once. An idle lane needs a reason in the state file (no disjoint work, or a pending ruling reshapes the queue).

**PR-stack mode**: for PRs with no ticket, run `review-loop`, then `ci-triage`, then merge, for each PR in the stack.

Done when every lane is filled or its idle reason is recorded.

### 3. Rule and merge

Answer each sub-orchestrator's escalations as `implement`'s rules say. Merge a PR only within the confirmed terms; a case the terms don't cover waits for the owner, posted on its ticket.

Done when every reported PR is merged, or waits on the owner with the exact action posted.

### 4. Keep the state file

Keep `/tmp/<repo>-flywheel-state.md`: the session config, each lane's ticket, branch, worktree and status, open escalations, rulings made, and the next steps. Update it after every merge, ruling and lane change. A fresh session continues from this file alone; `/handoff` is not involved.

Done when, after each update, the file alone would let a fresh session continue.

### 5. Close the round

1. Run `retro` on the round.
2. Write the round report: merged / open / parked, items needing the owner with exact actions, and leftover threads with issue links. Short.

Done when the report lists every ticket's or PR's end state and every owner action.
