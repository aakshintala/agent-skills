Check this plan for issue #__ISSUE__ in __REPO__ against the code it cites. Do not edit anything. Do not delegate further.

Read the ticket (`gh issue view __ISSUE__ --repo __REPO__ --comments`) and every file the plan names, at __BASE__, in your working directory.

## Plan

__PLAN__

## Report

Max 300 words, one line each: what, where, the smallest fix.
1. Contradictions between the plan and the ticket, the docs or the code.
2. Rulings the plan makes without listing them under Rulings.
3. A rule under Rules this ticket implements that is not quoted word for word from its cited file and section, or a governing rule the ticket or its docs state that the plan leaves out.
4. Design-level over-engineering: a new abstraction, dependency or configuration the ticket doesn't need.
5. Each invariant under Interfaces: construct an input that breaks it. Report the breaking input, or the strongest input you tried and why the invariant holds against it.
6. An open design choice in Review Focus: a hazard the plan names without a ruling or an invariant.
7. A Rung lower than the plan's own Interfaces and Review Focus call for: `strong` for state carried across calls, concurrency or timing, replay, or a rule with several cases; `frontier` for cross-cutting design.

`PLAN OK` when items 1–4, 6 and 7 find nothing and every invariant held under item 5; list the item 5 attempts above it. End with a STATUS line.
