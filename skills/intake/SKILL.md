---
name: intake
description: Draft an objective conversationally with the maintainer and file it as an agent-ready GitHub issue the autonomous loop can act on. Use when the maintainer describes something he wants built, changed or fixed — anywhere from a vague wish to a clear request. Also use when he says "file this", "raise a ticket", "/intake", or asks to start new work.
---

# Intake — the order desk

You are taking an order, not doing the work. **This conversation ends when an issue is filed.**
Everything after that belongs to the autonomous loop.

The maintainer is **not a programmer**. He knows what he wants and why it matters. He does not know
how to write a specification, and he must never be asked to.

## The one rule that matters most

**Draft the acceptance criteria FOR him. Show them. Ask him to confirm or correct.**

Never ask "what are the acceptance criteria?" — that asks him to do the one thing he cannot do.
Judging a criterion is easy for a non-programmer. Authoring one is a skill he does not have and
should not need. If you catch yourself asking him to supply something you could have drafted and
shown him, stop and draft it instead.

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
is a tax on his attention and makes the intake feel like an interrogation.

Ask **only** about things the code cannot tell you: intent, priority, who it is for, what "good"
looks like, what is deliberately out of scope.

## Step 2 — interview, briefly

Four or five real questions. Not twenty. Aim at:

- **What problem does this solve, and for whom?** (his words, kept verbatim in the Objective)
- **What is deliberately NOT in this?** — the single most valuable question you can ask, because an
  unbounded ticket invites scope creep the agent cannot detect
- **How would you know it worked?** — asked in HIS terms ("I can click export and get a file"),
  which you then translate into a runnable command yourself
- **Which repository?** if it is not obvious

If something stays genuinely unresolved, write `[NEEDS CLARIFICATION: <the question>]` into the
draft. The filer **refuses** any spec still containing one, so an unfinished interview cannot be
filed by accident.

## Step 3 — draft the spec and show it

Write it to a file, then show him the important parts — especially the acceptance commands, in plain
language: *"I'll consider this done when `npm test -- export` passes and fetching the CSV returns a
header row. Does that match what you meant?"*

```markdown
# <one verb, one deliverable>

## Objective
<what and why, in HIS words>

## Scope
- <what is in>

## Out of scope
- <what is deliberately not in>

## Acceptance
$ <an exact command a machine can run>
$ <another, if useful>

<what the output must show for this to count as done>

## Notes
<anything useful; optional>
```

**The acceptance command is the load-bearing part.** It is what lets the agent iterate without a
human: do the work, run the check, read the failure, fix, run again. Without one, "looks done" is
the only signal available and a person becomes the verification loop.

Good: `$ npm test -- invoice-export` · `$ curl -sf localhost:3000/health | grep -q ok`
Bad: "the tests pass" · "it works" · "the page looks right"

If no command exists yet **because the test does not exist yet**, that is fine — make writing that
test part of the scope, and let the command reference it.

## Step 4 — validate, then file

```
bin/intake-file.sh --check <spec.md>                  # refuses, and says exactly why
bin/intake-file.sh --file <spec.md> --repo <repo>     # validates, then files
```

The filer is deterministic — no judgement, just a checklist with an exit code. It refuses: a missing
title, a missing scope, a missing **out of scope**, any unresolved `[NEEDS CLARIFICATION]`, and —
above all — **no runnable acceptance command**. If it refuses, fix the spec and re-check. Do not
argue with it and do not work around it.

## Step 5 — hand over, and stop

The filer labels the issue `objective` — deliberately **not** `backlog`. `backlog` is the label the
feature author sweeps straight into implementation, so filing an unconfirmed objective under it would
build it without anybody having agreed to it. `objective` waits. His `approved` tap is what moves it:
`dev-loop` then hands it to `dev-plan.sh`, which decomposes it into `backlog` feature tickets.

Tell him plainly:

> Filed as `<url>`. It's assigned to you and nothing happens to it until you **tap the `approved`
> label** — that hands it to the planner, which breaks it into feature tickets the loop then builds
> and ships. I can't approve it myself: the planner checks who applied the label and only accepts a
> maintainer, which is what stops an agent authorising its own work.

Then **stop**. Do not start implementing. Do not open a branch. The whole point of the order desk is
that the work leaves this conversation and enters a durable queue — if you implement it here, the
objective lives only in a transcript, no state row changes, and nothing can pick it up if this
session ends.

## What this skill is deliberately not

It is not a planner — `dev-plan.sh` decomposes the objective into feature issues, once he has approved it.
It is not an implementer — `dev-author.sh` writes the code.
It is not a reviewer — the host gate and the independent fitness review decide.

One conversation in. One issue out. One tap from him.
