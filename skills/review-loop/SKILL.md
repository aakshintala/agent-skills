---
name: review-loop
description: "Review, repair and verify a PR until it can merge: two reviews from a different model family, fix rounds with scoped verifies, and a two-round stop. Use when a PR needs review before merge, whether it came from implement, the flywheel's PR-stack mode, or triage."
---

The loop for one PR. Reviews run on models from a different family than the PR's implementer; pick them per the `delegate` skill.

**Identity.** A verdict covers the `git patch-id --stable` of the PR's diff: a rebase that keeps the patch keeps its verdict, and any other change needs a new one. CI covers the head SHA: a green run on an older SHA never satisfies merge.

**Counter.** Each PR has one counter. A fix round is one fix dispatch plus its scoped verify, and adds one.

### 1. Review

```
~/.agents/bin/review-pr <pr> --repo <owner/name> --cwd <clone> [--issue <n> --spec <n>] --model <correctness> --overbuild-model <over-engineering> [--workflow-doc <path>]
```

A PR with no ticket leaves out `--issue` and `--spec` and is reviewed against its own description. It runs the correctness review (`code-review`) and the over-engineering review (`overbuild-review`) as separate jobs, posts both on the PR with the patch-id, and prints only the verdicts, findings, CI state, and any job that didn't finish. An `UNFINISHED` line means that review didn't run: rerun it, and read nothing in its absence as approval.

Done when both reviews have verdict lines for the current patch-id.

### 2. Route

Every verdict `APPROVE` and no open P1 or P2: the loop is done. Otherwise send every open finding in one fix round: fill `briefs/fix.md` with `~/.agents/bin/fill-brief` (findings as `FINDINGS=@<file>`) and dispatch it in the PR's worktree as a gated job. When every open finding is trivial by `implement`'s fix-by-churn rule, fix them inline and run the gate yourself instead; the round still counts, and step 3 still verifies it.

Done when the fix round is dispatched with all open findings.

### 3. Verify

Judge the repair by its diff (`git diff <reviewed head>..<new head>`) and gate output, never the fix worker's report. Then:

```
~/.agents/bin/review-pr <pr> --repo <owner/name> --cwd <clone> --model <correctness> --verify <findings file> --since <reviewed head>
```

`FIX-OK`: the loop is done. `FIX-INCOMPLETE`: back to step 2 with the open findings, while the counter is below 2.

Done when the verify has printed `FIX-OK` or `FIX-INCOMPLETE` for the current patch-id.

### 4. Stop at two

After round 2, no round 3 runs.

- Only P3 findings open: answer each on the PR with evidence, or with a `debt:` comment naming its ceiling and upgrade trigger. The loop is done. A P3 that a marker could close only by weakening a rule a doc, spec or ticket states counts as an open P2.
- Any P1 or P2 open: the lane stops. Load `attack-the-premise`, post the assumption the fixes share, and rule one of:
  - **re-plan**: back to `planning`; the counter resets;
  - **take back**: implement it yourself; it gets a full review (step 1, a different family from you), and the counter resets;
  - **park**: when the premise touches the ticket's core outcome (see `implement`).

  A second round-2 stop on the same ticket parks it, whatever the earlier ruling.

When you answer findings yourself, follow "Answering the findings" in `code-review`. A commit `ci-triage` makes re-enters at step 3 on the same counter.
