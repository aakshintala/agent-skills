Read-only code review of PR #__PR__ in __REPO__ (`gh pr view __PR__`, `gh pr diff __PR__`), for issue #__ISSUE__ (`gh issue view __ISSUE__ --comments`; spec #__SPEC__). Do not edit, push or comment. Do not delegate further.

Review on two axes:
- Standards: does the diff follow the repo's documented standards (AGENTS.md, docs/agents/, existing code idiom)?
- Spec: does it do what #__ISSUE__ and #__SPEC__ ask, including every acceptance criterion?

Output, max 200 words: a verdict line `VERDICT: APPROVE` or `VERDICT: CHANGES`, then findings as `P1|P2|P3 file:line — defect — fix`, most severe first. P1 = wrong behaviour or security, P2 = missed acceptance criterion, P3 = minor. No praise. End with a STATUS line.
