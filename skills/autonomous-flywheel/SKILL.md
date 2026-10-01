---
name: autonomous-flywheel
description: "Flywheel unattended multi-PR landing: implement, triage CI, merge on green, morning report. Fires when asked to land a stack of PRs unattended or continue a flywheel session."
---

# Autonomous Flywheel

Land a stack of PRs with minimal supervision: implement, review, repair,
triage CI, merge on green, and leave a morning report. Step 1 runs once
at the start. Steps 2–5 run for every PR, several PRs in flight at once.
Step 6 runs throughout and step 7 closes each round. Each step ends
with its done-condition.

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
- Token: `gh auth status` shows the `workflow` scope. Without it, PRs
  touching `.github/workflows/*` fail to merge with a policy error and
  only the owner can land them (UI click or `gh auth refresh -s workflow`).
- Work source: the stack of PRs to land, or the tracker's tickets.

Done when every bullet is filled and the owner has confirmed the
implementation model and blanket merge terms.

## 2. Implement

- When working from tickets, take the **frontier**: open tickets whose
  blockers are all closed. A ticket enters a lane only when its fence is
  disjoint from every running lane's.
- **Doc preflight** before a ticket enters a lane: a read-only reviewer
  reads the docs the ticket cites and lists contradictions between them,
  defaults nothing states, failure cases with no error code, and
  acceptance criteria that fight a doc. Each item goes to the owner before
  the lane starts; a ruling that lands mid-lane costs a merge and a round.
  Brief: `briefs/preflight.md`.
- **Plan first** when a ticket spans more than one module, adds a
  subsystem, or would describe code the orchestrator has not read: the
  lane implements an owner-reviewed plan, never the bare ticket. Delegate
  the plan to the Hard tier from the `delegate` skill.
- When a fork or sub-orchestrator runs a ticket end to end, brief it with
  `briefs/ticket-orchestrator.md`. A brief reaches an agent that never saw
  this conversation, so it carries every setting itself. Fill every
  `__PLACEHOLDER__` in a brief before sending it.
- One worktree per branch, named for the branch, deleted on merge; never
  reuse a worktree across branches. In the shared checkout run only
  `git fetch` and read `origin/main`: sibling sessions leave it on their
  own branches, so a pull there moves theirs.
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
  a PR URL or a failure triage, nothing in between, then **Friction**: up
  to 3 bullets on what slowed the lane, what the brief or docs got wrong
  or left out, and what it would change ("none" is fine). Every repair
  message repeats the Friction line. Lanes waiting on long tests keep
  running; they do not report done early.
- A brief or ruling that defines a line on the wire (an event, a command,
  a file record) carries one literal example line. A field list alone
  leaves its nesting to the lane's guess.
- Checks that CI runs sharded, such as mutation testing, stay in CI. The
  lane pushes and reads the CI result instead of running a slower local
  copy.
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

Done when each PR in the stack has a pushed branch from its own worktree
with verified lineage, all implement fences are pairwise disjoint and
recorded in the handoff.

## 3. Review

- Review each PR once with the `code-review` skill (Standards and Spec
  axes); return findings with tight word caps and aggregate without
  reranking. Record the verdict as a PR comment. Delegated brief:
  `briefs/review.md`.
- Alongside it, run one over-engineering review (the `ponytail-review`
  method) and record it as its own PR comment. A correctness reviewer
  only ever asks for more code; this pass asks whether the code should
  exist. Each suggestion is a **hypothesis**: the lane applies it only if
  it removes code without adding cost (memory, behaviour, lines), and
  otherwise reports back and keeps the original. Delegated brief:
  `briefs/over-engineering-review.md`.
- After a repair, run a **scoped verify**, never a full re-review: check
  only that each finding is fixed and the repair commit adds no new
  problem, then record FIX-OK (or the remaining findings) as a PR comment.
- **Stop rule.** Every verify finds a smaller defect in the last repair.
  From repair round 3 on, only P1/P2 correctness findings get another
  round; a smaller one is answered on the PR with evidence or with a
  `ponytail:` comment naming its ceiling.
- Open PRs as drafts; promote to ready only after the recorded verdict plus
  draft CI green with a clean flake watch.
- A regression test ships only with its negative control recorded: the
  exact failure with the fix reverted, then green with it. A test that
  passes both ways proves nothing about the fix.

Done when every PR carries a recorded verdict comment and every repair
commit has a recorded scoped verify.

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
- Flake annotation jobs stay out of the required check, or every flake
  blocks the queue.

Done when every red leg has a documented flake-vs-real verdict and every
flake has a filed issue.

## 5. Merge

- Verify behaviour against what the checkout builds, never an installed
  copy on `PATH`.
- Merge only on the required check green for the exact head commit, with
  the configured merge method.

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

## 7. Close the round

1. Run `/retro` on the round, from the lanes' Friction bullets, the
   review and verify comments, and the handoff log. Keep only what will
   recur every round; a point-in-time snag is not a lesson.
2. Fold what the owner accepts into this skill, memory, or the repo's
   docs, each in its one right place.
3. Write the morning report: scoreboard (merged / open / flakes filed),
   items needing the owner with exact actions, and leftover threads with
   issue links. Short.

Done when the retro's accepted items are written down and the report
lists every PR's end state plus owner actions.
