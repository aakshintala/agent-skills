---
name: planning
description: "Write a ticket's implementation plan: a contract sketch (rulings, files, tasks, interfaces, review focus), checked by a different-family Verifier, posted on the ticket, and filled into the lane brief. Use when planning a ticket before a lane builds it, or filling a preflight, Verifier or lane brief."
---

The orchestrator writes every ticket's plan, after reading the code it describes: a lane fails on a plan describing code its author never read. The plan becomes the body of the lane's brief.

**Briefs.** The templates are `briefs/preflight.md`, `briefs/verifier.md` and `briefs/lane.md`. Fill them with `~/.agents/bin/fill-brief <template> KEY=VALUE...` (a value of `@<file>` reads the file), which fails on any unfilled placeholder or unknown key, so the brief never goes out half-filled and you write only the values.

### 1. Read

Read every file the preflight listed and every file the plan will name. Send bulk reading beyond that (history, issue archives, unrelated modules) to sub-agents that return summaries.

Done when you have read every file the plan will cite.

### 2. Write the plan

A plan is a sketch of contracts and invariants, never code: a function body in a plan is the implementation done twice.

```
# Plan: #<n> <title>
<one-line goal>

## Global Constraints   copied word for word from the spec
## Rulings              each contradiction found and the default chosen, tagged core or non-blocking
## Files                each file touched and what changes; this is the lane's fence
## Tasks                in order; each: behaviour, test first, gate command, done-when
## Interfaces           signatures, invariants, one literal example per line on the wire; no bodies
## Review Focus         input classes and failure modes the tests may not cover
```

Size each task as the smallest unit that carries its own test cycle. Tasks run in order in one lane, under one `review-loop` for the PR. A migration may break the callers it lists under Rulings instead of paying for interim compatibility.

Done when every section is filled and every ruling is tagged.

### 3. Verify

Fill `briefs/verifier.md` with `PLAN=@<plan file>` and run it on a cheap-tier model from a different family than yours. For each line it returns, fix the plan or record a ruling. A core ruling still open parks the ticket (see `implement`).

Done when the Verifier says `PLAN OK`, or every line it returned is answered in the plan.

### 4. Post

Post the plan as a comment on the ticket. When the plan changes, edit that comment in place; GitHub keeps its history.

Done when the ticket's plan comment holds the current plan.

### 5. Brief the lane

Fill `briefs/lane.md` with `PLAN=@<plan file>`, the worktree, branch, gate command, and `STOP_LIMITS`: the scale or scope at which the lane stops and asks, such as "more than 20 files changed" or "deleting a test".

Done when `fill-brief` exits 0.
