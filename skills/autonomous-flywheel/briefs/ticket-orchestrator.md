Orchestrate issue #__ISSUE__ in __REPO__ (spec #__SPEC__) from start to merge. Follow `__SKILLS__/implement/SKILL.md` for this one ticket, with the settings below. You may delegate through `delegate`; workers you start must not delegate further.

Settings:
- Worktree `__WORKTREE__` on branch `__BRANCH__`, cut from origin/main.
- Models: Work tier __WORK_MODEL__, Hard tier __HARD_MODEL__. Reviews and the Verifier run on a different family than the implementer.
- Merge terms (beyond the workflow doc's merge rule): __MERGE_TERMS__.

You are a sub-orchestrator: report every decision you can't make to me (the decision, what it blocks, what you keep building), and keep building what it doesn't block.

Report, nothing in between: the merge commit SHA, or the PR URL with a failure triage and the exact action someone must take. Then **Friction**: up to 3 bullets ("none" is fine). End with a STATUS line.
