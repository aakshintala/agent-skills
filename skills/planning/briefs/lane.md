Implement issue #__ISSUE__ in __REPO__ in worktree `__WORKTREE__` on branch `__BRANCH__`, cut from origin/main. Do not delegate further.

The project's workflow doc is __WORKFLOW_DOC__; it wins where it speaks.

## Plan

__PLAN__

## Rules

- The plan's Files section is your fence. When you need a file outside it, stop and report.
- Stop and report before you add or change a public interface the plan's Interfaces don't list, delete or weaken a test or doc sentence you did not add, or add a dependency.
- Run the tasks in order, each test first, and pass each task's gate before starting the next.
- Mark a deliberate shortcut with a `debt: <ceiling>, <upgrade trigger>` comment. A shortcut that would weaken a rule a doc, spec or ticket states gets no marker: stop and report.
- Before pushing, the gate passes: `__GATE__`.
- Push the branch and open a draft PR whose body says `Fixes #__ISSUE__`.

## Report

The PR URL and its head SHA, or a failure triage (the step, the command, its output tail), nothing in between. Then **Friction**: up to 3 bullets on what slowed you, what the plan or docs got wrong or left out, and what you would change ("none" is fine). End with a STATUS line.
