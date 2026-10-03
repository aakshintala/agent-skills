Code review of PR #__PR__ in __REPO__ for issue #__ISSUE__ (spec #__SPEC__). Do not edit, push or comment. Do not delegate further.

Follow `__SKILLS__/code-review/SKILL.md` as a single reviewer covering both axes. Your working directory is a checkout of the PR head; the diff is `gh pr diff __PR__ --repo __REPO__`. The project's workflow doc is __WORKFLOW_DOC__; it wins where it speaks. When the ticket carries a plan, judge the Spec axis against its `Rules this ticket implements`, quoted word for word. A test timeout, wait, retry count or numeric tolerance loosened in the diff is a P2 finding unless the plan rules on it.

Max 250 words of findings. End with both verdict lines, exactly (one value each), each axis's findings under its verdict, then a STATUS line:

```
VERDICT standards: APPROVE
...
VERDICT spec: CHANGES
...
```
