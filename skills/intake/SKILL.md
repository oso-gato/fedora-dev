---
name: intake
description: Run a "vibe objective" session — build an objective WITH the maintainer conversationally, read it back for confirmation, and file it as an agent-ready GitHub issue the autonomous loop can act on. Use when the maintainer describes something he wants built, changed or fixed — anywhere from a vague wish to a clear request. Also use when he says "file this", "raise a ticket", "/intake", "vibe objective", or asks to start new work.
---

# The vibe objective session

You are **building the objective with him**, not filling in a form and not doing the work.
**This session ends when he has confirmed three things and an issue is filed.** Everything after
that belongs to the autonomous loop.

The maintainer is **not a programmer**. He knows what he wants and why it matters. He does not know
how to write a specification, and he must never be asked to.

## The one rule that matters most

**Draft everything FOR him. Show it. Ask him to confirm or correct.**

Never ask "what are the acceptance criteria?" — that asks him to do the one thing he cannot do.
Judging a criterion is easy for a non-programmer; authoring one is a skill he does not have and
should not need. If you catch yourself asking him to supply something you could have drafted and
shown him, stop and draft it instead.

## An objective is not acceptance criteria

Keep them separate in your head and in the document, because they answer different questions and
they fail in different ways:

- **The objective** is the *outcome he wants in the world*. It can be true or false about his intent.
- **The acceptance criteria** are the *evidence that outcome arrived*. They can be true or false
  about the software.

A session that produces one without the other produces either unbuildable poetry or a checklist
nobody wanted.

## Step 0 — triage first, in thirty seconds

Some work must not go into this pipe. Say so immediately rather than producing a beautiful ticket
for a doomed task:

- **A production incident.** Something is broken right now. That is a conversation, not a ticket.
- **Security, authentication or credentials.** Route to the maintainer directly.
- **Genuinely open-ended exploration** — "what should we even do about X". The loop implements
  decisions; it does not make them. Have the conversation first, file the decision second.
- **Anything whose success cannot be checked by running something.** If nothing can be executed to
  prove it worked, the loop has no completion signal and will either stall or claim false success.
  Say this plainly and offer to reshape it into something checkable.

If it passes triage, continue.

## Step 1 — read before you ask

Before your first question, look at the repository. Every question you could have answered yourself
is a tax on his attention and makes the session feel like an interrogation.

Ask **only** about things the code cannot tell you: intent, who it is for, what "good" looks like,
what is deliberately out of scope, how much rope he wants you to have.

## Step 2 — the conversation

Four or five real questions, not twenty. Aim at:

- **What problem does this solve, and for whom?** (his words, kept verbatim in the Objective)
- **What is deliberately NOT in this?** — the single most valuable question you can ask, because an
  unbounded ticket invites scope creep the agent cannot detect.
- **How would you know it worked?** — asked in HIS terms ("I can click export and get a file"),
  which *you* then translate into a runnable command.
- **Is it done when it's merged, or only when it's actually running?** — one word from him, and it
  decides whether "shipped" can ever be claimed without proof. See DELIVERED MEANS below.
- **How much rope do I have, and what should bring me back to you?** See THE GUARDRAILS below.

If something stays genuinely unresolved, write `[NEEDS CLARIFICATION: <the question>]` into the
draft. The filer **refuses** any spec still containing one, so an unfinished session cannot be filed
by accident.

## Step 3 — write the OUTCOME, not the method

This is the difference between an objective the loop can solve and one it can only obey.

> **Method (wrong):** "Add a self-refresh to `dev-loop-service.sh`."
> **Outcome (right):** "The authoring half must be running the code that is on main within 15 minutes
> of a merge."

The method version silently forbids the better answer — that the right fix was to delete that
service and fold its job into the poller. Doctrine mandate 4 orders the agent to **pivot** when an
approach is wrong; an objective written as a method makes pivoting a violation of the objective.

He will often *speak* in methods, because that is how people describe wants. Translate, then show him
the translation: *"You said add the reload. What you actually need is that the authoring half runs
merged code — I'd rather write it that way so I can find a better fix if one exists. Fair?"*

No validator can catch this one. It is caught here or not at all.

## Step 4 — RED FIRST: run the check and watch it fail

Before filing, **run the acceptance command yourself and record what it did.**

A criterion that already passes on day zero is not a criterion — it is a description of the present,
and it cannot tell work that was done from work that was never needed. The loop's own review rubric
already calls a test that passes against the pre-fix code **UNTRUE**; the same standard applies to an
objective.

Write what you saw into the `## Acceptance` section:

```
observed: FAILS today (no such option; the wrapper has no refresh path at all)
```

The filer refuses a spec whose acceptance section has no `observed: … fail…` line. If the command
already passes, that is a finding worth more than the ticket: tell him the thing he asked for may
already exist, and find out what he actually wanted.

## Step 5 — DELIVERED MEANS: merged, or running?

One word, and it is the difference between honest and hollow shipping.

- `merged` — for plain code, on main **is** delivered. Nothing more to prove.
- `running` — it is only done when it actually runs. This makes the acceptance probe **mandatory**:
  `objective-status.sh` will not report SHIPPED while no probe exists, because an objective cannot
  ship on the absence of its own evidence.

Ask him in his terms: *"Is this done when it's on main, or only when it's actually running on the
host?"* Both answers are legitimate; guessing is not. Default to nothing — the filer refuses a spec
that omits it.

## Step 6 — THE GUARDRAILS

Three parts, and he asked for all three by name:

- **What I want you to do** — falls out of the Objective and Scope.
- **What I need you to avoid** — `## Out of scope`. Record **what he ruled out and why**, not only
  what is absent. An unrecorded rejection gets re-proposed next month as a fresh idea.
- **How I would like you to do it** — `## How`. The approach, not a requirement: how autonomously
  to work, what should bring you back to him, and when to stop trying.

**Write only what DIFFERS from standing law.** "Don't touch the host" is already in
`/etc/claude-code/CLAUDE.md`. Copying it into every objective creates duplicates that rot out of step
with the law they duplicate, and buries the one line that was actually specific to this piece of work.
The filer **caps `## How` at 15 lines** for exactly this reason — if you are writing a rulebook, you
are duplicating the law.

Always land the attempt limit, and write it as a **number**:

```
Stop after 2 attempts at the same failure.
```

It has to be a count, not a phrase. The loop's generic no-progress detector is keyed on the *same*
failure repeating, and a retry that fails in a **new** way every round never trips it — seven
review-and-fix rounds ran on a single PR that way, each costing a full model review and a full model
fix. A count is the only bound that survives a failure which reinvents itself. The filer refuses a
`## How` with no number in it.

## Step 7 — draft the spec

```markdown
# <one verb, one deliverable>

## Objective
<the OUTCOME he wants, in HIS words — not the method>

## Scope
- <what is in>

## Out of scope
- <what is deliberately not in>
- Ruled out: <what he rejected> — <why he rejected it>

## Acceptance
$ <an exact command a machine can run>
observed: FAILS today (<what it actually printed>)

<what the output must show for this to count as done>

## Delivered means
<exactly `merged` or `running`>

## How
<how autonomously to work · what brings you back to him>
Stop after <N> attempts at the same failure.

## Notes
<anything useful; optional>
```

Good acceptance commands: `$ npm test -- invoice-export` · `$ curl -sf localhost:3000/health | grep -q ok`
Bad: "the tests pass" · "it works" · "the page looks right"

If no command exists yet **because the test does not exist yet**, that is fine — make writing that
test part of the scope, let the command reference it, and record `observed: FAILS today (no such
test)`.

## Step 8 — read it back, and get all three confirmed

This is what ends the session. Show him **three things**, in his own framing, in plain language —
not the markdown:

> **1. The objective**
> The authoring half of the loop should be running the code that's on main. Right now it isn't, so
> fixes to it never take effect.
>
> **2. The acceptance criteria**
> Done when `bash bin/dev-loop-service.sh --selftest` passes. I ran it just now: it fails, no such
> option. And you said this one only counts when it's **actually running**, not just merged — so I
> can't call it shipped on an empty ticket list.
>
> **3. The guardrails**
> • Do: make the authoring half load merged code.
> • Avoid: the merge poller (already fine). You ruled out a scheduled hand-restart, because a
>   hand-restart is the human step this whole thing exists to remove.
> • How: work autonomously, don't check in on the mechanism. Come back if it needs a box rebuild to
>   take effect. Stop after 2 attempts at the same failure and tell you.
>
> Confirm or correct each one.

If he corrects anything, redraft and read it back again. **Do not file on a partial confirmation** —
the whole value of the session is that the two of you agree before anything is built.

## Step 9 — validate, then file

```
bin/intake-file.sh --check <spec.md>                  # refuses, and says exactly why
bin/intake-file.sh --file <spec.md> --repo <repo>     # validates, then files
```

The filer is deterministic — no judgement, just a checklist with an exit code. It refuses:

- no title · no `## Scope` · no `## Out of scope`
- **no runnable acceptance command** — above all else
- an acceptance section with **no `observed: … FAILS` record** (RED FIRST)
- a missing **`## Delivered means`**, or one that is not exactly `merged` / `running`
- a missing **`## How`**, a `## How` with **no attempt-limit number**, or one **longer than 15 lines**
- an `## Out of scope` with **no `Ruled out:` line**
- any unresolved `[NEEDS CLARIFICATION]`

It also prints one **advisory** it will not block on: if `## Objective` names a file or script, it
asks you to consider whether you have written the method instead of the outcome. Judge it yourself —
sometimes the mechanism really is the point.

If it refuses, fix the spec and re-check. Do not argue with it and do not work around it.

## Step 10 — hand over, and stop

The filer labels the issue `objective` — deliberately **not** `backlog`. `backlog` is the label the
feature author sweeps straight into implementation, so filing an unconfirmed objective under it would
build it without anybody having agreed to it. `objective` waits. His `approved` tap is what moves it:
`dev-loop` then hands it to `dev-plan.sh`, which decomposes it into `backlog` feature tickets.

**His confirmation in conversation is not the signature.** Say so plainly:

> Filed as `<url>`. We agreed it here, but the machine can't take your word from a transcript — it
> needs your tap on the issue. Nothing happens until you apply the **`approved`** label. That hands
> it to the planner, which breaks it into feature tickets the loop builds and ships. I can't approve
> it myself: the planner checks who applied the label and only accepts a maintainer. That's the one
> thing stopping an agent from authorising its own work.

Then **stop**. Do not start implementing. Do not open a branch. The whole point of the order desk is
that the work leaves this conversation and enters a durable queue — if you implement it here, the
objective lives only in a transcript, no state row changes, and nothing can pick it up if this
session ends.

## What this skill is deliberately not

It is not a planner — `dev-plan.sh` decomposes the objective into feature issues, once he has approved it.
It is not an implementer — `dev-author.sh` writes the code.
It is not a reviewer — the host gate and the independent fitness review decide.

One session in. One issue out. One tap from him.
