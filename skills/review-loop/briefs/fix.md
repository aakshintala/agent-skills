Answer the review findings on PR #__PR__ in __REPO__, in worktree `__WORKTREE__` on branch `__BRANCH__`. Do not delegate further.

## Findings

__FINDINGS__

## Rules

- Check each finding against the code before acting. Fix it when the code shows the defect. When the finding is wrong, leave the code and answer it with evidence: a test, a call site, a command's output.
- An over-engineering finding is a hypothesis: apply it only when the cut costs no memory, behaviour or lines.
- Stay inside the fence: __FENCE__. When you need a file outside it, stop and report.
- Mark a deliberate shortcut with a `debt: <ceiling>, <upgrade trigger>` comment. A shortcut that would weaken a rule a doc, spec or ticket states gets no marker: stop and report.
- Keep every test's timeouts, waits, retry counts and numeric tolerances as they are. A fix that needs a looser one stops and reports the cause it would hide.
- When the same check fails twice after your fixes, stop: report the assumption your fixes share, and start no third patch.
- Refer to issues as `see #N` or `#N's case` in commit messages; a closing keyword (close, fix, resolve and their forms) before an issue number closes that issue on merge.
- Before pushing, the gate passes: `__GATE__`. Commit and push.

## Report

The pushed head SHA, then one line per finding: `fixed` or `refuted: <evidence>`. Then **Friction**: up to 3 bullets ("none" is fine). End with a STATUS line.
