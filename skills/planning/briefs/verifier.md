Check this plan for issue #__ISSUE__ in __REPO__ against the code it cites. Do not edit anything. Do not delegate further.

Read the ticket (`gh issue view __ISSUE__ --repo __REPO__ --comments`) and every file the plan names, on origin/main.

## Plan

__PLAN__

## Report

Max 200 words, one line each: what, where, the smallest fix.
1. Contradictions between the plan and the ticket, the docs or the code.
2. Rulings the plan makes without listing them under Rulings.
3. A rule under Rules this ticket implements that is not quoted word for word from its cited file and section, or a governing rule the ticket or its docs state that the plan leaves out.
4. Design-level over-engineering: a new abstraction, dependency or configuration the ticket doesn't need.

Nothing found: `PLAN OK`. End with a STATUS line.
