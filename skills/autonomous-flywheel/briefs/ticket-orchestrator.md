Orchestrate issue #__ISSUE__ in __REPO__ (spec #__SPEC__) from implementation to merge. Load the `autonomous-flywheel` skill and run its steps 2–5 for this one ticket; this brief supplies the session's settings, so skip step 1. You may delegate through `delegate`; workers you start must not delegate further.

Settings:
- Worktree `__WORKTREE__` on branch `__BRANCH__`, cut from origin/main.
- Fence: owns __OWNS__; forbidden __FORBIDDEN__.
- Implementation model: __LANE_MODEL__. Review models: __REVIEW_MODELS__ (never the implementation model).
- Review briefs: `briefs/review.md` and `briefs/over-engineering-review.md` beside the skill, placeholders filled.
- Merge authority: __MERGE_TERMS__.
- Owner rulings already posted: __RULED__.

Report, nothing in between: the merge commit SHA, or the PR URL with a failure triage and the exact action the owner or orchestrator must take. Then **Friction**: up to 3 bullets ("none" is fine). End with a STATUS line.
