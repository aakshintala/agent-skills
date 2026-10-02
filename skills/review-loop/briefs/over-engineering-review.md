Over-engineering review of PR #__PR__ in __REPO__. Do not edit, push or comment. Do not delegate further.

Follow `__SKILLS__/overbuild-review/SKILL.md`. Your working directory is a checkout of the PR head; the diff is `gh pr diff __PR__ --repo __REPO__`. A cut that would weaken a rule the ticket's plan quotes under `Rules this ticket implements` is not a finding.

First line exactly `VERDICT: APPROVE` when there is nothing to cut, else `VERDICT: CHANGES`. Then one line per finding, biggest cut first:

Max 150 words. End with a STATUS line.
