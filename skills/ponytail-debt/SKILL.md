---
name: ponytail-debt
description: >
  Harvest every `ponytail:` comment into a ledger of deliberate shortcuts, flagging
  any with no upgrade trigger. Use when asked what was deferred, which shortcuts
  were taken, or for the ponytail ledger. Reports only.
---

<!-- Adapted from DietrichGebert/ponytail 4.9.0 (MIT, see ../ponytail-review/LICENSE). -->

A `ponytail:` comment marks a deliberate shortcut: `ponytail: <ceiling>, <upgrade trigger>`. The ledger keeps a deferral from quietly becoming permanent.

## 1. Scan

`grep -rnE '(#|//|--) ?ponytail:' .`, skipping `node_modules`, `.git` and build output. Add the comment prefixes your stack uses. The prefix keeps prose about the convention out of the ledger.

## 2. Report

One row per marker, grouped by file:

`<file>:<line>, <what was simplified>. ceiling: <limit>. upgrade: <trigger>.`

Tag a marker that names no upgrade trigger `no-trigger`: those are the ones that rot. End with `<N> markers, <M> with no trigger.` Nothing found: `No ponytail: debt.`
