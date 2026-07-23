# GOVERNANCE — the product-owner constitution for the autonomous dev loop

> **What this is.** The fixed reference the fitness gate grades every change against, and the standing
> law for how work reaches (or does not reach) the maintainer. Written by the **product owner** — a
> non-coding maintainer whose authority is *intent*, not code review. The developer and reviewer agents
> do NOT edit this; only the maintainer changes it — by his own edit/merge, or by his recorded act
> (§6(c) records how the one 2026-07-11 amendment was authorized; whether comment-based
> pre-authorization becomes a standing amendment procedure is HIS open question, not assumed here).
>
> **⚠️ AMENDED 2026-07-11 — ZERO-GATE ENACTED (see §6(c) for the maintainer's recorded decision).**
> The Tier-A "maintainer's click" merge routing in §3–§5 below is **superseded**: every PR — control-plane
> included — merges via the autonomous two-gate pipeline (host live-gate + independent fitness, distinct
> App identities, sha-bound); a fitness **ESCALATE** routes a genuine judgment question to the maintainer
> (a question, never a merge button). The click-era text is retained below for history and for everything
> in it that still binds (the three questions, RETURN/ESCALATE semantics, the anti-hijack intent).
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
| **A** | Boundary / irreversible (§3) | ~~Maintainer's click required~~ **SUPERSEDED by §6(c) zero-gate: auto-merges under the two-gate pipeline like every tier**; the Stage-3 adversarial review runs inside the fitness gate and can RETURN it; a genuine governance trade-off ESCALATEs as a question. | an ESCALATE question when one arises + a line in the digest |
| **B** | Reversible, non-boundary feature work | **fedora-dev auto-merges** under the fitness gate | a line in the digest |
| **C** | Docs / comments only | **fedora-dev auto-merges** | a line in the digest |

*(Pre-amendment note, historical: the "click to merge" prompt was a fedora-dev-session construct; the
gate-push hook that produced it was retired 2026-07-11 — §6(c).)*

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
3. **Fit for purpose?** Advances the whole objective (not locally-correct-but-globally-useless / hampering) **and honors the PROBLEM-SOLVING DOCTRINE** (`fleet-core.md`, top): solution-oriented · iterated-on-facts (validated, not asserted) · zero-based · objective-held & pivoted (not patched) · no rabbit-hole. Q3 grades the change against those six as a checklist — violating one FAILS Q3.

**Stage 2 — three outcomes, only one reaches the maintainer** *(amended per §6(c) — zero-gate)*:
- **PASS** (all three positive) → **auto-merge, ANY tier** (control-plane included) + digest. Tier labels
  the digest; it no longer routes to a click.
- **RETURN** (fails Q2/Q3) → back to the developer agent to rework; the maintainer never sees it.
- **ESCALATE** (genuinely ambiguous fit / a governance trade-off) → to the maintainer as a **question,
  not a merge button** — the one human-judgment path that survives zero-gate, by design.

**Stage 3 — boundary changes also get an adversarial pass** *(amended per §6(c))*: for control-plane
changes an independent agent tries to **break** it (the security-review pattern); it can RETURN, and
repeats until it converges clean — running **inside the fitness gate**, not as a pre-merge click ritual.
(This is what the fence fix and the 2026-07-11 unshackle wave went through — multiple rounds, real
defects caught: two rebuild-bricks, an overclaimed safety statement, a false verification claim.)

## 6. Resolved decisions (each states DECISION vs current STATUS explicitly)

**(f) TRINITY = MAINTAINER-MERGE-ONLY — durable enforcement of R1 (the maintainer's decision, 2026-07-23).**
- **DECISION (the maintainer, this session):** a PR that amends the confirmed spec (the Trinity —
  `00-OBJECTIVES.md` / `00-REQUIREMENTS.md` / `00-BUILDPRINCIPLE.md`) or this `GOVERNANCE.md` must be
  **merged by the human maintainer, never autonomously**, and must be **assigned to `@oso-gato`** so it
  surfaces clearly in the GitHub app. "Make it durable and update the docs."
- **What it changes:** the ONE documented exception to the zero-gate auto-merge model (§6(c)). It closes
  the 2026-07-22 audit's finding #16 (a confirmed-requirement edit, PR #224, had auto-merged — the spec
  was immutable only on paper). Three enforcing layers, defence in depth:
  (1) **loop guard** — `bin/auto-merge.sh` detects a Trinity/GOVERNANCE path in the PR's files and
  REFUSES (exit 4, a distinct "maintainer-merge hold" the poller parks QUIETLY, not a trust-boundary
  alarm), while assigning `@oso-gato` + labelling `maintainer-merge`;
  (2) **server-side review-request** — `.github/CODEOWNERS` maps those paths to `@oso-gato`, so GitHub
  auto-requests the maintainer's review (visible in the app);
  (3) **server-side block (maintainer's one-time settings act)** — a branch-protection / ruleset
  "Require review from Code Owners" on `main` makes GitHub BLOCK the merge (even a raw-API merge) until
  the maintainer approves — the belt to the loop-guard suspenders, and it also closes the known
  raw-API-merge residual for these paths.
- **ADVERSE EFFECTS (recorded):** Trinity/GOVERNANCE PRs no longer merge autonomously — they wait for
  the maintainer (intended; a rare, high-consequence class). The nox App cannot self-approve a
  Code-Owner-review requirement, so even a doctrine-audit-proposed spec amendment is correctly BLOCKED on
  the human (R1). Non-Trinity work is unaffected — the whole rest of the loop stays zero-gate autonomous.
- **STATUS: ENACTED** via the PR carrying this entry (the loop guard + CODEOWNERS + the R1/objective doc
  codification). Layer (3), the branch-protection rule, is the maintainer's one-time GitHub-settings act
  (mirror it as versioned config per R15).

**(d) MVP-FIRST SEVERITY — the maintainer's recorded enactment (2026-07-12).**
- **DECISION (the maintainer's own words, posted from his account `oso-gato` on fedora-dev#158 —
  https://github.com/oso-gato/fedora-dev/pull/158#issuecomment-4951654555):**
  > CONFIRMED — MVP-first is my standing instruction. Get it to work first; where fitness
  > finds something that could be better or improved but is not blocking, we continue to
  > build and it is recorded as a note. Later, when we ship a finished function or feature,
  > we revisit and close those loops. Build the minimum viable product and prove the feature
  > first.
  >
  > I authorize this PR to (1) land the BLOCKING/NON-BLOCKING severity split in the fitness
  > rubric and (2) amend policy/fleet-core.md so Q1/Q3 read as NOTE-generating rather than
  > auto-RETURN, with a GOVERNANCE.md §6(d) ledger entry recording this decision.
- **What it changes:** the fitness gate's Q1/Q2/Q3 are still all ASKED, but a finding BLOCKS (RETURN)
  only if it makes the change **(a) INCORRECT**, **(b) UNSAFE**, or **(c) UNTRUE**; every other finding
  is a **NOTE recorded on a PASS** (`## NOTES (non-blocking — follow-ups)`) and revisited after ship.
  Supersedes §5's reading of Q1-scope-creep / Q3-mandate-violation as auto-RETURN; the operative text is
  `policy/fleet-core.md` §"INDEPENDENT FITNESS REVIEW" (amended in the same PR as this entry).
- **Why (recorded so the rationale survives):** an adversarial reviewer can always find something, so a
  rubric where any shortfall RETURNs has no convergence criterion — and because each round yields a new
  failure signature on a new head, the R13 no-progress stop can never fire. Observed 2026-07-12: SEVEN
  review+fix rounds on one PR (#144), each a full model review AND a full model fix. An endless RETURN
  loop over non-blocking polish burns the maintainer's budget, is itself a doctrine failure
  (rabbit-hole), and makes the R14 unattended proof unpassable. The gate's teeth are unchanged where
  they earned their place: every serious catch to date (the `approved`-label maintainer bypass; the
  fail-open `cd && set +o pipefail;` shared-clone slip; doc rows asserting behaviour the code lacks)
  still RETURNs under (a)/(b)/(c).
- **The chain of enactment:** the rubric change first shipped WITHOUT a law amendment (#157) → the
  fitness gate itself **ESCALATEd** it — correctly, citing the (c)-UNTRUE gap (the stamped law would
  assert gate behaviour the gate no longer had) and the missing maintainer record — → the maintainer's
  recorded comment above → #158 (rubric + fleet-core amendment + this entry, one motion).
- **STATUS: ENACTED** on #158's merge; the stamped law re-carries it at the next box rebuild.

**(c) ZERO-GATE — the maintainer's recorded enactment (2026-07-11).**
- **DECISION (the maintainer's own words, posted from his account `oso-gato` on fedora-dev#139 —
  https://github.com/oso-gato/fedora-dev/pull/139#issuecomment-4945056383):**
  > CONFIRMED — zero-click merge authority applies to ALL tiers, control-plane included
  > (re-confirming my #130 ZERO-GATE decision). The TIER ROUTING rewrite in this PR
  > correctly records my decision. I authorize amending GOVERNANCE.md §5/§6 to match,
  > via a PR citing this comment. Adversarial review continues inside the fitness gate,
  > not as a pre-merge click. Also confirming: fedora-desktop is in the unshackle scope.
- **What it supersedes:** the Tier-A→click routing (§4 table row A, §5 Stage 2), the pre-click Stage-3
  ritual (§5), and §6(a)'s "no merge authority" clause. The interactive gate-push hook + auto-classifier
  are retired in fedora-dev (#137/#139) and fedora-bootstrap (#122, v1.2.59); the fedora-desktop port
  (#114) is in flight, confirmed in scope by the comment above. The poller IS the merge authority, under
  two independent gates (host live-gate App + fitness App). Recoverability is automatic (host
  health-gate digest rollback, git revert, fitness's standing preserve-recoverability rule), not a click.
- **The chain of enactment (recorded as it actually happened):** #130 (ZERO-GATE poller, 2026-07-10) →
  #137 (hook retirement; merged 2026-07-11 08:35Z by the poller App under the standing #130 decision,
  BEFORE the comment below existed — the maintainer's recorded confirmation is retroactive and covers it,
  "re-confirming my #130 ZERO-GATE decision") → the recorded comment above → #139 (fleet-core TIER
  ROUTING amendment, merged bc5d868) → this GOVERNANCE amendment (the one edit the comment pre-authorized).
- **STATUS: ENACTED.** The stamped operative law (`fleet-core.md` TIER ROUTING) already carries it.

**(a) Supervised poller.**
- **DECISION:** BUILD IT (approved). A small always-on in-box service watches for the host verdict and
  re-wakes the agent to iterate — *(the "no merge authority" clause is superseded by §6(c): the poller
  is now the merge authority, under the two independent gates)*.
  This is what makes the loop autonomous rather than "autonomous while a human babysits a session."
- **STATUS: BUILT + ARMED** (superseding the earlier "not yet built" — `bin/pr-poller.sh` +
  `bin/poller-service.sh` + `bin/auto-merge.sh` run live; first zero-click merge #129, org-wide #136+).

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

## 7. Keeping the doctrine alive (self-check + self-propose)

The PROBLEM-SOLVING DOCTRINE (`fleet-core.md`, top) is not a plaque — it is enforced and audited:
- **Always in context** — stamped FIRST into every box's `/etc/claude-code/CLAUDE.md` (managed policy,
  overrides all). Un-droppable by construction.
- **Self-checked, per change** — the fitness gate's **Q3 grades every change against the six mandates**
  as a checklist; a violation FAILS Q3 → RETURN. The doctrine is the rubric, exercised on every PR.
- **Drift-guarded, daily** — `fleet-guard-parity` **CHECK 6** asserts the `<!--DOCTRINE-->` block is
  present, delimited, carries all six mandates, and stays lean (≤40 lines — brevity is the
  anti-dilution property). Runs on push/PR **and the daily 04:30 UTC cron**. A silent deletion or
  bloating fails CI.
- **Self-proposing, on cadence** — a periodic **doctrine audit** (reusing the independent fitness
  harness, §5, pointed at the doctrine itself) asks: *(1) still fit for the objective? (2) are recent
  merges actually honoring it, or routing around it? (3) drifted?* Where it finds a gap it opens a
  **Tier-A amendment PR → the maintainer's click**. The doctrine notices when it is stale or violated,
  but **never self-amends** — only the maintainer ratifies a change.

---

*Editing this file (or the doctrine) is a Tier A / control-plane change — so the constitution can only
change on the maintainer's click, which is correct.*
