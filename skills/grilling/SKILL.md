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

Then validate them as **Q0**, in its own call to your host's question tool,
before anything else in the round: ask whether they hold, carrying an option to
strike. Q0 stays out of the round's batch because a struck premise reshapes the
frontier, and the batched questions would be framed on ground that just moved. A
struck premise sends you back to recompute the frontier and open the round again
on the new one. Skip Q0 only when the round genuinely rests on nothing new.

## 2. Brief the frontier

A round of two or more questions opens with a brief: one line per question, plus
the context they share. The user sees the shape of the round before committing to
any single answer, and each question then stays short because the shared context
is already on the table. Hold back what hangs off a question until that question
is asked. A single-question round has no shared context to state, so it skips the
brief.

## 3. Ask

Put the whole round to the user in one call to your host's question tool, one
entry per frontier question, in the order the brief listed them. The tool renders
each question discretely and returns structured answers, so a batched round reads
as a list to work through rather than a wall of prose to answer by hand. Where the
frontier exceeds the tool's cap, ask in successive calls, still in brief order.

Lead each question with your recommended option. Where a question picks between
approaches rather than settling a fact, at least two options reach the user: the
smallest thing that works, and the one you'd want to live with. A question
offering one real option is a decision you already made.

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
