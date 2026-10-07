---
name: planning
description: "Write a ticket's implementation plan: a contract sketch (rulings, files, tasks, interfaces, review focus), checked by a different-family Verifier, posted on the ticket, and filled into the lane brief. Use when planning a ticket before a lane builds it, or filling a preflight, Verifier or lane brief."
---

The orchestrator writes every ticket's plan, after reading the code it describes: a lane fails on a plan describing code its author never read. The plan becomes the body of the lane's brief.

**Briefs.** The templates are `briefs/preflight.md`, `briefs/verifier.md` and `briefs/lane.md`. Fill them with `~/.agents/bin/fill-brief <template> KEY=VALUE...` (a value of `@<file>` reads the file), which fails on any unfilled placeholder or unknown key (naming the keys the template takes), so the brief never goes out half-filled and you write only the values. When a filled brief starts another job, fill it with `--out <absolute path>` (e.g. `~/.cache/agents/<repo>-<issue>-<template>.md`: a durable directory, since a reboot clears `/tmp`; `fill-brief` creates it) and use the printed line verbatim as its prompt, never a hand-written path.

**Base.** Every brief takes `BASE`, the code the plan describes, which the orchestrator prepares (see `implement` step 2): `origin/main` for a new ticket, the PR's branch with `origin/main` merged in for a re-plan. Read, plan and verify against that base.

### 1. Read

Read every file the preflight listed and every file the plan will name. Send bulk reading beyond that (history, issue archives, unrelated modules) to sub-agents that return summaries.

Done when you have read every file the preflight listed and every file the plan will cite.

### 2. Write the plan

A plan is a sketch of contracts and invariants, never code: a function body in a plan is the implementation done twice.

```
# Plan: #<n> <title>
<one-line goal>

## Project constraints  pointers to the repo's standing rules (dependencies, budgets, code rules) where the workflow doc lists them; never copied
## Rules this ticket implements  each governing sentence from a doc, spec or ticket, quoted word for word with its file and section
## Rulings              each contradiction found and the default chosen, tagged core or non-blocking
## Files                each file touched and what changes, including every test that names a changed signature, type or listed value (search for them); this is the lane's fence
## Tasks                in order; each: behaviour, test first, gate command, done-when
## Interfaces           signatures, invariants, one literal example per line on the wire; no bodies
## Review Focus         where reviewers look: input classes and failure modes the tests may not cover
## Rung                 the lane's rung (per the `delegate` skill) and the reason
## Size                 estimated lines of code and lines of tests, separately; the split, if any
```

The quoted rules are what the Verifier, the reviews and any finding are judged against: a finding that contradicts a quoted rule is refuted by quoting it.

A hazard you know of is settled in the plan: a ruling (what the code does about it), or an invariant under Interfaces, which the Verifier attacks and the lane keeps. Review Focus holds only places to look. A hazard you can't rule on is a `core` ruling, and parks the ticket.

The rung is `standard` by default. It is `strong` when Interfaces or Review Focus involve state carried across calls, concurrency or timing, replay, or a quoted rule with several cases, and `frontier` for cross-cutting design.

Estimate tests from the testing rules the workflow doc states (every case, every listed sequence), never as a fraction of the code: plans have come in at half their merged size, mostly in tests. When the workflow doc's size rule calls for a split (past 1,800 lines of code plus tests only when the doc says nothing about size), split the ticket into parts from the start: each part a lane and PR of its own, in order, cut at a seam that leaves main green, `Part of #<n>` until the last, which is `Resolves #<n>`.

Size each task as the smallest unit that carries its own test cycle. Tasks run in order in one lane, under one `review-loop` for the PR. A migration may break the callers it lists under Rulings instead of paying for interim compatibility.

Done when every section is filled, the size is estimated with any split it calls for, every ruling is tagged, and every known hazard is a ruling or an invariant.

### 3. Verify

Fill `briefs/verifier.md` with `PLAN=@<plan file>` and the base, and run it in a checkout of the base on a `strong` model from a different family than yours, or a `frontier` one when the plan's rung is `frontier`. For each line it returns, fix the plan or record a ruling. A core ruling still open parks the ticket (see `implement`).

Done when the Verifier says `PLAN OK`, or every line it returned is answered in the plan.

### 4. Post

Post the plan as a comment on the ticket. When the plan changes, edit that comment in place; GitHub keeps its history.

Done when the ticket's plan comment holds the current plan.

### 5. Brief the lane

Fill `briefs/lane.md` with `PLAN=@<plan file>`, the base, worktree, branch, gate command and `CLOSING`: `Resolves #<n>` for a PR that finishes the ticket, `Part of #<n>` for one part of a split. The brief's stop limits are structural: they catch a change of scope, and a large change inside scope is review's to judge.

Done when `fill-brief` exits 0.
