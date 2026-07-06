# GOVERNANCE — the product-owner constitution for the autonomous dev loop

> **What this is.** The fixed reference the fitness gate grades every change against, and the standing
> law for how work reaches (or does not reach) the maintainer. Written by the **product owner** — a
> non-coding maintainer whose authority is *intent*, not code review. The developer and reviewer agents
> do NOT edit this; only the maintainer does (a change to this file is itself Tier A — his click).
>
> This is the human-readable map. The **binding, stamped** operative rules live in
> `policy/fleet-core.md` (THE SELF-SUSTAINING APPARATUS) which every box carries in-context; this file
> is the full articulation that block points to. Existing Build Principles / provenance / two-tier
> validation are incorporated **by reference** (`CLAUDE.md` Principles 1–11 + `fleet-core.md`) — never
> duplicated, because duplication is drift.

---

## 1. The objective (north star)

A **genuinely autonomous development loop**: the maintainer states a requirement in product terms; the
agents design, build, validate, and iterate **without the maintainer in the per-iteration loop**; only
decisions that need his *judgment* reach him. He owns *what* and *why*, not *how*; he cannot review
code, so his click is **authorization on intent**, never a code inspection.

**Success** = the maintainer spends attention only on (a) stating requirements, (b) answering genuine
judgment questions, (c) authorizing boundary changes — never on rubber-stamping unreadable code or
catching rabbit-holes after the fact.

## 2. Standing principles (what the gate grades against)

1. **Throwaway builds.** Every build is disposable — the image is deleted after validation, in-box AND
   on the host. (Mechanics: `CLAUDE.md` Principle 10 + `fleet-core.md` THROWAWAY & CHURN.)
2. **No waste.** Caches / package trees / layers persist within **bounded** time+size limits, so N
   iterations never re-download N times, and churn can never exhaust the disk.
3. **Human out of the per-iteration loop.** develop → build → validate → verdict → redevelop iterates
   autonomously; only the outcomes in §4–5 reach the maintainer. **Open gap (today):** the loop only
   turns while a live agent session polls for the verdict — so the maintainer is still a *heartbeat*.
   The supervised poller (§6a) is the approved fix that WOULD close this, but it is **not yet built**;
   until it is, this principle is an intent, not yet fully realized.
4. **Proportionate controls, not maximal.** A control that blocks the maintainer's *own* legitimate work
   for a threat that doesn't exist for a solo operator is **overzealous → trim it**. A control that
   defends genuinely untrusted input (un-merged PR code) is **warranted → keep it**. Corollary
   (**anti-theater**): a control that *implies* protection it can't deliver (a pattern-scan sieve) is
   **worse than none** — see `CLAUDE.md` class-(c) ANTI-THEATER.
5. **The click is authorization, not review.** The maintainer merges on *intent fit*, not diff
   inspection — so the competent reviewer in the loop is the **automation**: throwaway build, live-gate,
   healthcheck + auto-rollback, and **independent review agents**. These must be strong; they are the
   only reviewers.
6. **Separation of duties is mandatory — THE KEY RULE.** The agent that writes a change may NEVER be the
   sole judge of it. This **replaces** the old Definition-of-Done step where the agent *self-examined its
   own TLDR* with an **independent agent (different context) review** before anything is presented or
   auto-merged. (Proven repeatedly: during this apparatus's own construction, author-confidence shipped
   real security defects to branch **four times**; an independent pass caught every one.)
7. **Rabbit-holes are returned, not presented.** Work that fulfils one requirement while breaking
   another, or that doesn't advance (or actively hampers) the objective, is sent back to rework — the
   maintainer never sees it.
8. **Reversibility governs autonomy.** Reversible, non-boundary work merges autonomously; boundary or
   irreversible work needs the maintainer's click (§3–4).

## 3. The boundary (what needs the maintainer's click)

The click has exactly two jobs — **anti-hijack** (gate any change to a control that would catch a
subverted agent) and **irreversibility** (gate anything that can't be recalled). Concretely, **Tier A =**

- the **control-plane class** (already defined in `fleet-core.md`): `policy/**`,
  `managed-settings.json`, `policy/hooks/gate-push.sh`, `.github/workflows/**`, `*.container`, `run.sh*`
  security flags, box-rebuild/assemble machinery, key-sync, `*sudoers*`, secrets/identity, the live-gate
  **fence** — and **this GOVERNANCE.md**;
- **+ anything that operates or mutates the live host WITHOUT an automatic safety net;**
- **+ anything hard to undo** (data migration, published/signed artifacts, external-facing actions).

Everything else is **reversible / non-boundary → Tier B/C**, auto-merged. Docs/comments = Tier C.

**The reversibility rule for host changes (resolved).** A **repo merge** to `fedora-bootstrap` is just
source and is trivially revertible → it auto-merges under the gate (if not otherwise Tier A). But
**applying** that change to the live host — the operator re-running `setup.sh` **as root** — has **no
automatic rollback today**, so the root host-apply is **Tier A (the maintainer's click)**. A *workload*
redeploy is different: it is reversible-by-construction (health-gated + auto-rollback to the prior
image digest), so it stays autonomous. **The host-apply moves to auto-merge only once it has the same
health-check + automatic rollback the workloads have** (a future build; until then, the click is doing
real work, not ceremony).

## 4. The tiers (who merges, and whether a human touches it)

**Merge authority — `fedora-dev` ONLY, always.** Every merge to `main`, in any repo, is executed by
`fedora-dev` (the sole merge box). `fedora-bootstrap` + `fedora-desktop` are **propose-only** — their
`gate-push.sh` **denies** any `main`-touching action (they have nothing to approve). A Tier B/C PR
authored by bootstrap/desktop is still **merged by fedora-dev**, never the proposing box.

| Tier | What | Merge (always by fedora-dev) | Maintainer sees |
|---|---|---|---|
| **A** | Boundary / irreversible (§3) | **Maintainer's click required** — fedora-dev's in-session clickable `ask`, OR the maintainer acting **remotely** (GitHub web / a machine outside the boxes). NEVER auto; NEVER from bootstrap/desktop. Preceded by the Stage-3 adversarial review that can RETURN it. | a decision + the 3-question brief + review verdicts |
| **B** | Reversible, non-boundary feature work | **fedora-dev auto-merges** under the fitness gate | a line in the digest |
| **C** | Docs / comments only | **fedora-dev auto-merges** | a line in the digest |

*The "click to merge" prompt is a **fedora-dev-session** construct by design — the only box whose gate
routes `main`-touching actions to `ask` rather than `deny`. The maintainer's remote action (GitHub web
/ a non-box machine) is the other Tier A path.*

## 5. The governance workflow (how this feeds the loop)

> **BUILD STATUS — read this before assuming the machine does the below.** This section is the TARGET
> workflow and the binding *rule*. The **automation that runs it unattended is largely NOT built yet.**
> During this apparatus's construction the stages were performed **manually** (a human orchestrated the
> independent review agents and the tier routing by hand). What EXISTS today: the independent-review
> *practice* (spawn a different-context agent — done repeatedly, caught real defects), the merge gate
> (`gate-push.sh` — real), and the tier *definitions*. What is **NOT built**: an automated Stage-0
> intent check, an automated fitness-review harness, automated tier routing + Tier-B/C auto-merge +
> digest, and the §6a poller. So merging this doc makes it the **law**; it does not by itself make the
> machine *enforce* the law — that enforcement is the next body of work. Until then, an agent (or the
> maintainer) follows this by discipline, exactly as was done to build it.

Two requirement levels: **this constitution (standing)** and a **per-request spec (per request)**.

**Stage 0 — Design & front-end intent check.** On a request, the agent drafts a per-request spec +
approach and checks it against this constitution. A *new direction* or a conflict with a principle →
**surface to the maintainer as a question BEFORE work starts** (cheapest place to kill a rabbit-hole).
Clearly within it → proceed autonomously.

**Stage 1 — Independent fitness review** (a *different* agent/context than the author), scoring the
change against both the per-request spec and this constitution — **the three questions:**
1. **Did the maintainer ask for this?** Maps to a specific requirement, or it's scope-creep.
2. **Does it contradict another requirement?** Satisfies A by breaking B → RETURN.
3. **Fit for purpose?** Advances the whole objective, or locally-correct-but-globally-useless / hampering?

**Stage 2 — three outcomes, only one reaches the maintainer:**
- **PASS** (all three positive) → route by tier (§4): Tier A → his click; Tier B/C → auto-merge + digest.
- **RETURN** (fails Q2/Q3) → back to the developer agent to rework; the maintainer never sees it.
- **ESCALATE** (genuinely ambiguous fit) → to the maintainer as a **question, not a merge button**.

**Stage 3 — Tier A also gets an adversarial pass.** For boundary changes, an independent agent tries to
**break** it (the security-review pattern); it can RETURN, and repeats until it converges clean, before
the maintainer's click. (This is what the fence fix went through — multiple rounds, real bugs caught.)

## 6. Resolved decisions (each states DECISION vs current STATUS explicitly)

**(a) Supervised poller.**
- **DECISION:** BUILD IT (approved). A small always-on in-box service watches for the host verdict and
  re-wakes the agent to iterate — **no merge authority** (the click stays the only boundary control).
  This is what makes the loop autonomous rather than "autonomous while a human babysits a session."
- **STATUS: NOT YET BUILT.** No code exists yet — the decision is made, the work is not started. Until
  it is built, the loop still needs a live agent session to be the heartbeat (principle 3's open gap).

**(b) Host-validation isolation — gVisor.**
- **DECISION:** a real VM is provider-blocked (Hostinger disables nested virtualization, verified), so a
  throwaway KVM/Firecracker VM is impossible on this VPS. The feasible stronger boundary is **gVisor
  (`runsc`)** — a user-space kernel over the fence — adopted **provisionally**, proven-opt-in per lineage.
- **STATUS: apparatus BUILT + merged; the feasibility test is PENDING.** The install + opt-in wiring is
  merged (default = plain fence — it changes nothing until a lineage is proven). The empirical test —
  whether gVisor runs the fleet fully or only partially (a systemd-PID-1 lineage like grd may not boot
  under it) — **has not run yet**; it fires as the loop's first end-to-end exercise when the host boots.
  Outcome then decides: full gVisor / gVisor-for-most + plain-fence-for-grd / drop gVisor + keep the fence.
  **gVisor is therefore NOT yet decided to stay** — the test decides.

---

*Editing this file is a Tier A / control-plane change — so the constitution can only change on the
maintainer's click, which is correct.*
