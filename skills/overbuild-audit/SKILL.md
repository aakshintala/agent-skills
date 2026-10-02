---
name: overbuild-audit
description: >
  Whole-repo audit for over-engineering: a ranked list of what to delete,
  simplify, or replace with stdlib or native equivalents. Use when the user
  asks to audit a codebase for bloat or what can be deleted from a repo.
  Reports only; applies nothing.
---

<!-- Adapted from DietrichGebert/ponytail 4.9.0 (MIT, see ../overbuild-review/LICENSE). -->

Scan the whole tree for over-engineering. Rank findings biggest cut first. Use the tags in [`overbuild-review`](../overbuild-review/SKILL.md).

## Hunt

Deps the stdlib or platform already ships, single-implementation interfaces, factories with one product, wrappers that only delegate, files exporting one thing, dead flags and config, hand-rolled stdlib.

## Output

One line per finding, ranked: `<tag> <what to cut>. <replacement>. [path]`. End with `net: -<N> lines, -<M> deps possible.` Nothing to cut: `Lean already. Ship.`

## Scope

Over-engineering only. Send correctness bugs, security holes and performance to `code-review`. List findings; leave the code unchanged.
