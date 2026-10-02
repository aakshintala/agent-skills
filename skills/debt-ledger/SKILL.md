---
name: debt-ledger
description: >
  Harvest every `debt:` comment into a ledger of deliberate shortcuts, flagging
  any with no upgrade trigger or that weaken a stated rule. Use when asked what
  was deferred, which shortcuts were taken, or for the debt ledger. Reports only.
---

<!-- Adapted from DietrichGebert/ponytail 4.9.0 (MIT, see ../overbuild-review/LICENSE). -->

A `debt:` comment marks a deliberate shortcut: `debt: <ceiling>, <upgrade trigger>`. It never weakens a rule a doc, spec or ticket states; a shortcut that would is a stop-and-report, not a marker. The ledger keeps a deferral from quietly becoming permanent.

## 1. Scan

`grep -rnE '(#|//|--) ?debt:' .`, skipping `node_modules`, `.git` and build output. Add the comment prefixes your stack uses. The prefix keeps prose about the convention out of the ledger.

## 2. Check

For each marker, read the code it sits on and the rules the repo's docs state for that code. Tag it:

- `no-trigger`: it names no upgrade trigger. These are the ones that rot.
- `weakens-rule`: the shortcut falls short of a rule a doc, spec or ticket states. Name the rule's file and section.

## 3. Report

One row per marker, grouped by file:

`<file>:<line>, <what was simplified>. ceiling: <limit>. upgrade: <trigger>. [tags]`

End with `<N> markers, <M> with no trigger, <K> weakening a stated rule.` Nothing found: `No debt: markers.`
