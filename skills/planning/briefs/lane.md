Implement issue #__ISSUE__ in __REPO__ in worktree `__WORKTREE__` on branch `__BRANCH__`, starting from __BASE__. Do not delegate further.

The project's workflow doc is __WORKFLOW_DOC__; it wins where it speaks.

## Plan

__PLAN__

## Rules

- The plan's Files section is your fence. When you need a file outside it, stop and report.
- Stop and report before you add or change a public interface the plan's Interfaces don't list, delete or weaken a test or doc sentence you did not add, loosen any test's timeout, wait, retry count or numeric tolerance (your own tests included) that neither the plan nor the ticket's acceptance criteria call for, or add a dependency. For a looser bound, report the cause it would hide.
- Run the tasks in order, each test first, and pass each task's gate before starting the next.
- Run only the gate and the tests your tasks name. Suites the workflow doc gives to CI, such as mutation testing (`cargo mutants`), benchmarks and backstops, run in CI: read their result from the CI log, and report when you need one reproduced.
- Run every command in the foreground, so it ends before your turn does; start no background or detached process.
- Mark a deliberate shortcut with a `debt: <ceiling>, <upgrade trigger>` comment. A shortcut that would weaken a rule a doc, spec or ticket states gets no marker: stop and report.
- Commit your work before any command that discards changes (`git reset --hard`, `git checkout -- <path>`, `git restore`, a rebase). Make a scratch commit, such as one kept as evidence, on a throwaway branch (`git switch -c scratch/<name>`), then switch back to the lane branch and delete the scratch one.
- Set work aside with a commit. The stash stack is shared with every other worktree of the repo, so `git stash` can pop another agent's changes.
- Before pushing, the gate passes: `__GATE__`.
- Refer to other issues as `see #N` or `#N's case` in commit messages and PR text. GitHub closes any issue a closing keyword (close, fix, resolve and their forms) precedes, so the only issue reference you write with one is the PR body's closing line.
- Push the branch. When no PR is open on it, open a draft PR whose body starts with `__CLOSING__`.

## Report

The PR URL and its head SHA, or a failure triage (the step, the command, its output tail), nothing in between. Then **Friction**: up to 3 bullets on what slowed you, what the plan or docs got wrong or left out, and what you would change ("none" is fine). End with a STATUS line.
