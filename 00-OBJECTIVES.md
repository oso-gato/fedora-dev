# Apparatus — OBJECTIVE (spec of record)

> **THE WHY** — the objective / north star this apparatus is built to.

> **Confirmed by the maintainer.** This is the durable objective the apparatus builds to. It is the ground truth the fitness gate
> re-grounds on, mirrored by spec issue [#135](https://github.com/oso-gato/fedora-dev/issues/135). The
> **functional + non-functional requirements** live in [`00-REQUIREMENTS.md`](./00-REQUIREMENTS.md); the
> **build principles** in [`00-BUILDPRINCIPLE.md`](./00-BUILDPRINCIPLE.md). This objective is locked;
> amendment is a new maintainer confirmation (R1), never a silent edit.

## Objective

The human maintainer states the objective. The dev container then responds with a tightened, expanded set of objectives and, through discussion, settles the functional requirements for confirmation. The resulting requirements document — which includes both the objective and the functional requirements — becomes the build objective; the session then designs, iterates, validates, and finally ships the product. This must take exactly **ONE interaction**: from the maintainer specifying the objective to the confirmation of the objective and the functional requirements. After that confirmation, the system runs self-autonomously until the product ships.

What we are building is that apparatus itself: a **self-sustaining autonomous development-loop pair** — a HOST (erebus, fedora-bootstrap) and a DEV CONTAINER (nox, fedora-dev), both running the Claude Code agent — that, from a single confirmed requirements document, derives a work plan, builds and validates each feature, and ships the whole objective with no further human interaction and automatic recovery. Humans do not approve the final shipment. It must actually deliver: proven end-to-end, the pair building and shipping the product independently and autonomously. We build it by **dogfooding the partial apparatus we already have — the race car repaired while racing** — every piece landing through the gate-free loop.

The whole platform follows the **immutable-host, containerise-everything** model — the Fedora Bluefin custom-image principle: the host OS is immutable and every application runs in a container. The host runs the latest Claude Code inside a **Distrobox** container, which is why it is called **"claudebox."** The dev container is itself containerised and stays relatively stable until recreated. Claude Code advances every single day; because it is containerised it carries its own rebuild cadence, rebuilt independently of dev-container recreations and host updates — **three decoupled clocks**: the host image, the dev container, and the claudebox-resident Claude Code.

The dev container is **multi-tenant**. It runs an undefined number of isolated claudebox sessions, each running its own autonomous loop on its own declared repository or repo-set, independently and exclusively. The host is the **single shared validator** for all of them — it validates every session's tickets and returns each outcome to the session it came from — and **no session reads, touches, or iterates another session's work**. Isolation is **by scope**, not by identity. GitHub issues are the first-class ticket bus, and the dev box never touches erebus — it instructs the host's agent.

Validation is **two-tier**, because the cheapest proof that can be trusted should be the one used: a session proves whatever it can **inside the container**, and engages the host **only for the live validation the container cannot perform itself** — then iterates on the host's verdict **until it is GREEN**. Where the container cannot validate a build at all, that fallback is forced, not chosen, and every iteration round-trips to the host. No build or validation ever touches the live host or the apparatus repos' working state: the live main branch, the running host, and the running container change **only through the controlled merge-and-deploy path**. Because the host is immutable, the same discipline governs development: **every validation build is thrown away, and every tree that build uses is thrown away with it**. That is held in a **churn-balance** — the same packages must not be re-downloaded on every iteration (time and bandwidth), yet nothing may accumulate without bound (limited host storage): **exactly one durable input persists, and everything else is ephemeral and bounded.**

Isolation is by scope, and **self-development is in scope, not forbidden**. Workload and other-development builds never mutate the host, the fedora-dev repo, or the bootstrap repo — that is the red line. But the **apparatus session**, one whose declared scope IS the apparatus (fedora-dev + fedora-bootstrap), legitimately develops and evolves the host and the dev container through the loop; that is a first-class objective, not a forbidden mutation. The red line is **workload build-isolation, not "never touch the control plane."**

Self-development is complete only when merged code becomes **live** code — **a merge is not a deployment (merged ≠ live)**. The apparatus must therefore **refresh itself**: refresh the host to the latest merged development, and rebuild the dev container to its latest repo image. Because neither box can safely rebuild itself from the inside, the apparatus **leverages the pair to stagger** — each box refreshes the other from outside — so that once a change to the dev-container or host repo merges, the pair refreshes itself. Each refresh is confirmed by **reading the live artifact back against the merged source, fail-closed**: not done until verified live on the target.

The apparatus is built to **distrust its own reports and its own sense of progress** — every past session failed exactly here, so the defence must be structural, not the agent trying harder. Against **falsified truth**: an agent can hallucinate and state an untruth, or issue a judgement from memory that was never validated against the facts — or against a baseline that has since shifted under development. So no outcome is accepted on an agent's word; each is **proven empirically against the live facts at the moment of the check**, read back from the real artifact, cross-checked by an independent context, and **never satisfied by a proxy mistaken for the real thing**. Against **silent liveness failure**: an agent can get stuck and stop progressing, hang, crash, or simply pause and sit idle indefinitely — and if nothing wakes the system, it assumes work is still ongoing and burns hours waiting on a corpse. So **liveness is monitored, never assumed**, and the **absence of a completion signal is treated as a failure to surface — not as evidence of progress**. The apparatus never discharges its responsibility to "the agent has it" without proving the agent actually has it — **not crashed, not idle, not stuck**. This is the standing defence against hallucination, falsified outcomes, judging by memory, assumption, presumption, and the hubris of reporting done what was never checked.

All software entering the platform — the host, the claudebox, the dev container, and every throwaway validation build — must come from an **official source at the strongest level of provenance available, fail-closed and pinned**, with weaker and unofficial sources forbidden outright. **Take the highest level an artifact admits; never descend to a lower one a higher would satisfy.** And **disposability does not excuse an untrusted source** — a throwaway build obeys exactly the same standard as the thing it is proving.

Every package and artifact is installed **minimally — relative to the chosen capability, not to an absolute package count** — and nothing enters without a recorded justification. But **minimum never means less capability**: once a capability is decided, take the smallest footprint that genuinely makes *that* capability work, and between options delivering the **same** capability prefer the smaller, higher-provenance one. A lighter option that **reduces** the capability is not "more minimal" — it is a lesser function, and choosing it is a recorded capability trade-off, never a minimalism win.

Throughout, the apparatus continuously self-checks each change against three questions: (a) is it a stated requirement, (b) does it contradict anything, (c) does it advance the objective.

## Operating scope — the maintainer's install choice

The apparatus works on **every repository the maintainer has installed its GitHub App on — private
repositories included**. That installed set **is** the scope, read live from the installation itself.

Why this rather than a list the apparatus keeps: a GitHub App **cannot create a repository**, so every
repository is human-made, and installing the App on one is already a deliberate human act. A second
list in software would add no authority — only a copy that drifts out of date. So the maintainer widens
or narrows the apparatus's reach by installing or removing the App, and **the apparatus never widens
its own reach**. Which repositories that is today, and the identities the apparatus works under, are
operational facts — not part of this objective.

## Document authority — the Trinity and the design

Why the spec is split the way it is: **what the apparatus is for must be stable, while how it is built must be free to move.** So this document, the requirements, and the build principles are **confirmed once by the maintainer and thereafter fixed** — amendment is a new confirmation, never a silent edit (R1) — whereas **the design ([`00-DESIGN.md`](./00-DESIGN.md)) is dev-owned and deliberately mutable**: an architecture taken seriously but altered on validated fact, because what is ultimately built to is the objective, and the design merely serves it. Who may change which document, and by what authority, is `00-GOVERNANCE.md`.

## Ship gate — the final gate before shipping

Nothing ships on its builder's own word. A product is declared ready and **shipped only after an independent, adversarial review has verified the built product against the confirmed spec** — measured in the order it was constructed: the objective first, then the requirements, then the build principles. If that review does not pass, the product goes **back into the loop**, not out the door. **An author is never the sole judge of its own conformance** — that is the whole point of the gate.
