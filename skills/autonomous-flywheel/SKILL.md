---
name: autonomous-flywheel
description: "Flywheel unattended multi-PR landing: implement, triage CI, merge on green, morning report. Fires when asked to land a stack of PRs unattended or continue a flywheel session."
---

# Autonomous Flywheel

Land a stack of PRs with minimal supervision: implement, review, repair,
triage CI, merge on green, and leave a morning report. Work the steps in
order; each ends with its done-condition.

## 1. Session config (fill in at start)

- Repo path, `main` branch, base commit.
- Required check name(s), merge method (e.g. squash-only), ruleset notes
  (strict on/off, thread resolution, approval count).
- Reviewer routing: which models review, who never reviews.
- Implementation model: which model runs implementation lanes. Confirm
  with the owner at session start before spawning lanes; there is no
  standing default, so ask every session.
- Lane budget: max implementation lanes (2 works), reviews read-only and
  may overlap.
- Merge authority: get explicit blanket terms up front (what may merge,
  what needs a call). CI-boundary changes (workflows, rulesets) always
  need an owner merge call unless explicitly included.

Done when every bullet is filled and the owner has confirmed the
implementation model and blanket merge terms.

## 2. Implement

- One worktree per branch, named for the branch, deleted on merge. Shared
  checkout stays on `main`; never reuse a worktree across branches.
- Each implementation lane brief declares its file fence (`owns` /
  `forbidden`); cite repo AGENTS.md instead of restating it. The
  orchestrator spawns only pairwise-disjoint fences and defers the rest
  to follow-ups. When the issue text says to wire through the composition
  root, include the root and its config-threading files in the initial
  fence. A lane that needs a file outside its fence stops and
  escalates instead of proceeding.
- Keep every implementation lane filled: when a lane closes out, immediately
  start the next disjoint-fenced work. Holding a lane idle needs a reason
  recorded in the handoff (no disjoint work exists, or a pending verdict
  reshapes the queue). A collision means the fence was wrong; an idle lane
  with fenced work waiting means the orchestrator stalled.
- A lane brief is incomplete unless it states the completion bar: report
  a PR URL or a failure triage, nothing in between. Lanes waiting on
  long tests keep running; they do not report done early.
- Implementation lanes touch code; review lanes are read-only and may
  overlap freely.
- Before pushing, verify the worktree HEAD lineage matches the remote
  branch — a stale base regresses files past the merge. A rejected
  non-fast-forward push is a signal, not an obstacle: stop and compare
  lineages.
- Before opening the PR, verify the branch holds only its own commits:
  `git log origin/main..branch --stat` shows fenced files and nothing
  else. A foreign commit riding along lands under the wrong title at
  squash-merge and strands the PR it belongs to.
- After every lane push, the orchestrator confirms the remote tip SHA
  equals the lane's reported SHA (`git log origin/<branch> -1`). A
  "pushed" report with the commit local-only sends no PR to CI.
- Track each lane's close-out on the orchestrator task list: verified-lineage
  push, PR body with Fixes/Part-of linkage, linked issues closed after
  merge, worktree deleted.
- Announce each wave on intercom (`send`, one message): branches and
  worktrees owned. Two sessions writing to one worktree corrupts it;
  the announcement is the tripwire.

Done when each PR in the stack has a pushed branch from its own worktree
with verified lineage, all implement fences are pairwise disjoint and
recorded in the handoff.

## 3. Review

- Run each review through the `code-review` skill (Standards then Spec
  axes); return findings with tight word caps and aggregate without
  reranking. Never full re-review: scoped FIX-OK
  verifies only, then a PR comment recording the verdict.
- Open PRs as drafts; promote to ready only after the recorded verdict plus
  draft CI green with a clean flake watch.
- A repair commit always gets a scoped verify before merge.
- A regression test ships only with its negative control recorded: the
  exact failure with the fix reverted, then green with it. A test that
  passes both ways proves nothing about the fix.

Done when every PR carries a recorded verdict comment and every repair
commit has a scoped verify.

## 4. Triage CI

- Failed CI is evidence. Repair in a new commit; never rerun to green.
  The only exception is an explicit owner ruling.
- Watch CI with `gh-ci` (`~/.pi/agent/bin/gh-ci`): `snapshot <pr>` for
  status (exact head SHA, CI/flake verdicts, pending/failing counts),
  `failures <run>` to list red legs with their failing tests,
  `watch-verified <run> --pr <n>` to block until the aggregate resolves
  on the exact head (exit 0 means green). A watch firing means "look",
  never "it's green": verify every signal with `snapshot` before acting.
- Hand every wait a lane cannot block on back to the orchestrator with
  exact run ids and head SHAs; the orchestrator owns all cross-completion
  waits. A lane's own background processes die with the lane, so a
  "watcher running" report from a finished lane is an open loop, not
  coverage.
- Triage every red leg as flake vs real before touching code: did the
  retry fire, did it fail twice, is there a control (same test green
  elsewhere on the same platform), does the branch plausibly link to the
  failure? Document the verdict in a PR comment, no reruns.
- Flakes become issues (test name, signature, run link, suspected cause,
  deflake strategy). Deflake by rewriting the test, never by rerunning.
- Retry/flake-reporting workflow features must be non-blocking by design:
  annotation jobs fail red for visibility but stay out of the required
  gate, or every flake blocks the queue it was meant to unblock.

Done when every red leg has a documented flake-vs-real verdict and every
flake has a filed issue.

## 5. Merge

- Verify with the freshly built binary from the checkout, never a PATH
  binary. Cross-compile for the deploy target before pushing repairs.
- Merge only on the required check green for the exact head commit.
- GitHub tokens need `workflow` scope to merge PRs touching
  `.github/workflows/*`; without it the merge fails with a policy error
  and only the owner (UI click or `gh auth refresh -s workflow`) can land
  it. Check `gh auth status` before an continuous run.

Done when the PR is merged on the required check green for its exact head
commit, or escalated to the owner per the blanket terms.

## 6. Handoff file (compaction survival)

- Keep `/tmp/<repo>-flywheel-handoff.md`: goal, constraints, done /
  in-progress / blocked, key decisions, next steps, critical context
  (branches, test paths, error strings).
- Append after every merge, triage, or decision. A fresh session must be
  able to continue from this file alone.

Done when the file alone lets a fresh session continue (check after each
append: branches, test paths, and error strings present).

## 7. Morning report

Scoreboard (merged / open / flakes filed), items needing the owner with
exact actions, research-lane findings side by side, and leftover threads
with issue links. Short.

Done when the report lists every PR's end state plus owner actions.
