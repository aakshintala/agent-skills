---
name: attack-the-premise
description: "My second fix failed the same test, gate or review finding as the first. Use before starting a third patch: stop patching, write down the assumption both fixes share, and question it."
---

<!-- Adapted from pstack's principle-attack-the-premise by Lauren Tan (MIT, see LICENSE). -->

Two fixes that share a premise and fail the same check are evidence against the premise, not the fixes. Start no third patch until the steps below are done.

### 1. Write the premise down

The one sentence every failed fix assumed. Post it where the work is tracked (the PR, the ticket, or the chat).

Done when the sentence is written.

### 2. Take a census

Count the failure per actor (per test, caller, worker, input class, platform), as a rerunnable script. The census shows which actors hold the imbalance, not how large it is.

Done when the script runs and its output is posted beside the premise.

### 3. Read the skew

When the same few actors hold most of the imbalance on every run, something assigns them that role: find it. That assignment is the cause. When the census is even across actors, the premise is not the cause: look elsewhere, and keep the census as evidence.

### 4. Remove the asymmetry

Change what assigns the role (rotate it, randomize it, move it) so no actor holds it on every run. A return path, a retry, a shared pool or a periodic rebalance compensates instead: it leaves the assignment in place and adds work on every run.
