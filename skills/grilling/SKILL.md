---
name: grilling
description: Grill the user relentlessly about a plan, decision, or idea. Use when the user wants to stress-test their thinking, or uses any 'grill' trigger phrases.
---

Interview the user relentlessly until you reach a shared understanding. Map this
as a **design tree**: every decision branches into the decisions that hang off it.

Work the tree in **rounds**. The **frontier** is every decision whose
prerequisites are already settled: the questions you can ask _now_ without
guessing at answers you haven't heard yet. A question whose answer depends on
another question open in this round belongs to a _later_ round.

Before the first round, when the thing being grilled is something you have just
met — an unfamiliar harness, a coined term, a subsystem you have only read the
name of — spend a message explaining what it is for, with concrete examples, and
ask whether it is worth doing at all right now. Grilling a design assumes the
thing should exist. Sometimes the honest first answer is "not yet", and every
round you would have run was wasted.

Each round runs three steps, in order.

## 1. Premises

The frontier rests on assumptions you carried in rather than asked about. They
are the expensive error: a wrong premise doesn't make one answer wrong, it makes
the whole round a set of correct answers to the wrong questions.

State them as flat statements, never as questions:

```
PREMISES
1. <statement this round's questions assume>
2. <statement>
```

Write them out in prose, in your own message, before you touch the question
tool — each premise a plain sentence plus what changes if it is wrong. A premise
the user first meets as an option inside the tool has not been stated; they are
being asked to ratify something they never read. Neither has a premise written
only in your reasoning: the user does not see it. The premises must be visible
output text in the same message as the Q0 call.

Then validate them as **Q0**, in its own call to your host's question tool, in
the same turn: ask whether they hold, carrying an option to strike. Q0 stays out
of the round's batch because a struck premise reshapes the frontier, and the
batched questions would be framed on ground that just moved. A struck premise
sends you back to recompute the frontier and open the round again on the new one.
Skip Q0 only when the round genuinely rests on nothing new.

## 2. Brief each batch

Split the round into batches no larger than the question tool's cap (4 in Claude
Code). Each batch opens with a brief in prose: one short paragraph per question,
carrying its context, the options argued at full strength, and your
recommendation. The brief sits directly above the call it explains, so the user
reads the context and answers it together. Hold back what hangs off a question
until that question is asked.

The brief is visible output text in the same message as the question call, never
only in your reasoning. Make no other tool call between the brief and its
question call: finish the research first.

## 3. Ask

Put the batch to the user in one call to your host's question tool, one entry per
question, in the order the brief gave them. The tool renders each question
discretely and returns structured answers. Question and option text stays short,
a sentence and a label with at most one line of trade-off, because the brief
already carries the context. Context packed into the tool is hard to read.

After each batch, recheck the batches still to come: an answer can make a later
question moot or change its framing. Drop or reword those before briefing them.

Lead each question with your recommended option. Where a question picks between
approaches rather than settling a fact, at least two options reach the user: the
smallest thing that works, and the one you'd want to live with. A question
offering one real option is a decision you already made.

**Ask only what is contested.** A decision that follows from a rule already
settled is not a question; asking it spends the user's attention to hear "yes".
Put those in a short "recording unless you object" list that names the rule each
one follows, and keep the tool call for the choices that are genuinely open —
value and taste calls, where your recommendation could reasonably lose. The list
goes in the prose of the round's last batch, with one short confirm question in
the tool.

Before each question reaches the user, in its brief:

- **Steelman the option you are not recommending.** Say what comparable tools do
  and why, and argue that option at full strength. An option written to lose
  tells the user nothing, and they will answer the strawman rather than the
  choice.
- **Pressure-test the recommendation** against the edge cases you can think of.
  If it breaks on one, that belongs in the question, not in a later correction.
- **Quote a prior decision, never paraphrase it.** When you cite what was settled
  earlier, paste the words. A paraphrase drifts toward what you now expect it to
  have said.

The answers reshape the tree: settled decisions push the frontier outward and
unblock what depended on them. Recompute, and run the next round.

## Facts are yours

Finding _facts_ is your job, never the user's. When a frontier question needs a
fact from the environment (filesystem, tools, etc.), dispatch a sub-agent to find
it; don't ask the user for anything you could look up yourself. Don't block on
it: a running exploration is an unsettled prerequisite, so only the questions
downstream of it wait for the sub-agent to report; brief and ask the rest of the
frontier now. The _decisions_ are the user's: put each to them and wait.

**Probe before you state a limit.** "The API can't do that", "that's impossible
on this platform", "X needs a credential" are facts, so they fall under the rule
above: state one holding the verbatim error, the documented line, or a live probe
you just ran. A failure that merely resembles a familiar story is a hypothesis;
probe it. An unprobed limit the user accepts reshapes every later round, and
nothing revisits it.

The session is done when the frontier is empty: every branch of the design tree
visited, nothing left silently assumed. Do not act on it until the user confirms
you have reached a shared understanding.
