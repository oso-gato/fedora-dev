# GOVERNANCE — the product-owner constitution for the autonomous dev loop

> **THE WHO** — who decides, and the record of every ruling (the decision log).

> **What this is.** The fixed reference the fitness gate grades every change against, and the standing
> law for how work reaches (or does not reach) the maintainer. Written by the **product owner** — a
> non-coding maintainer whose authority is *intent*, not code review. The developer and reviewer agents
> do NOT edit this; only the maintainer changes it — by his own edit/merge, or by his recorded act
> (§6(c) records how the one 2026-07-11 amendment was authorized; whether comment-based
> pre-authorization becomes a standing amendment procedure is HIS open question, not assumed here).
>
> Merge routing is **zero-gate** — see §6(c). This constitution is `00-GOVERNANCE.md`, part of the
> confirmed `00-*` spec family and **MAINTAINER-MERGE-ONLY** (R1): only the maintainer merges a change
> to it, and the loop assigns it to him.
>
> This is the human-readable map. The **binding, stamped** operative rules live in
> `policy/fleet-core.md` (THE SELF-SUSTAINING APPARATUS) which every box carries in-context; this file
> is the full articulation that block points to. Existing Build Principles / provenance / two-tier
> validation are incorporated **by reference** (`CLAUDE.md` Principles 1–11 + `fleet-core.md`) — never
> duplicated, because duplication is drift (BP9).

---

## Authority & boundary (what is uniquely governance)

This constitution grades every change; **only the maintainer edits it** (authority is on *intent*, not
code review). Its boundary job is exactly two things — **anti-hijack** (gate any change to a control
that would catch a subverted agent) and **irreversibility** (gate anything that can't be recalled).

- **Control-plane class** is defined once in `fleet-core.md` (CONTROL-PLANE CLASS); this doc **and** the
  PROBLEM-SOLVING DOCTRINE are members of it.
- **Merge routing is zero-gate** (§6(c)) — every PR, control-plane included, auto-merges under the two
  independent App gates. The **single exception** is the confirmed spec: a PR editing the Trinity
  (`00-OBJECTIVES.md` / `00-REQUIREMENTS.md` / `00-BUILDPRINCIPLE.md`) or this `00-GOVERNANCE.md` is
  **MAINTAINER-MERGE-ONLY** and is held + assigned to the maintainer (R1; §6(f)).
- The surviving **human-judgment path** under zero-gate is a fitness **ESCALATE** (a question, never a
  merge button); amending this constitution or the DOCTRINE is maintainer-adjudicated through it.

## The four docs of record (MECE — one concept, one home)

Governance owns only the authority above and the §6 decision log below. It does **not restate** anyone
else's content — but it does **map** it, because MECE forbids duplicated content, not a signpost: a
visible partition is what lets an author route a new sentence to exactly one home. Each concern lives
in exactly one doc:

**why** → [`00-OBJECTIVES.md`](./00-OBJECTIVES.md) · **what** → [`00-REQUIREMENTS.md`](./00-REQUIREMENTS.md) · **how** → [`00-BUILDPRINCIPLE.md`](./00-BUILDPRINCIPLE.md) · **who** → this doc.

## Known risks & accepted residuals

What the apparatus DEPENDS on, and the holes it knowingly runs with. An unnamed risk is still a risk —
it is just one nobody can weigh. Governance owns this because it already records decisions *and their
consequences*; each entry says what could bite, and why it is accepted for now.

| # | Risk / dependency | Why accepted (for now) |
|---|---|---|
| K1 | **GitHub is a total single point of failure.** R5 makes it the *sole* IPC, work-log and audit trail. If GitHub is unavailable the apparatus has no bus, no durable state and no audit — it does not degrade, it stops. | No second bus exists, and building one would duplicate the thing that makes the loop auditable. Accepted; a real outage is a full stop, not data loss (the record survives in GitHub). |
| K2 | **A raw-API merge can bypass the interactive merge block.** The `gh pr merge` deny is a command-prefix rule; a direct API call is not covered. | Pattern-denying every API shape is sieve-theater (see the anti-theater doctrine); recovery is automatic (git revert + health-gate rollback). NARROWED for the confirmed spec by the R1 Code-Owner rule, which GitHub enforces server-side. |
| K3 | **One shared credential for every tenant session.** Isolation between sessions is enforced by code, not by identity, so the hard stop (key revocation, R9) necessarily stops *all* sessions at once. | Per-tenant identities would multiply the credential surface. Accepted; the soft stop (HALT) is per-session and maintainer-thrown. |
| K4 | **The apparatus merges its own control-plane changes.** Under zero-gate (§6(c)) it can rewrite its own machinery without a human. | Deliberate — it is what makes self-development possible. Safety is *recoverability*, not prevention: git-revertable, health-gated, auto-rolled-back. The confirmed spec is the one carve-out (R1, §6(f)). |
| K5 | **Stronger container isolation is undecided.** gVisor is installed and opt-in but its feasibility test has never run (§6(b)). | The plain fence is the current boundary; the decision is pending real evidence, not assumed. |
| K6 | **The operative law can drift from the spec.** `policy/fleet-core.md` — the rules actually stamped into every agent's context — is not itself locked, and has already contradicted the confirmed spec once (it asserted control-plane auto-merge with no R1 carve-out until 2026-07-24). | Being resolved: the durable fix is to strip original authority from the stamp so it can only *derive* from these four documents. Until then, `bin/fleet-guard-parity.sh` guards its shape but not its agreement with the spec. |

## 6. Resolved decisions (each states DECISION vs current STATUS explicitly)

**(e) SCOPE = THE LIVE APP INSTALLATION — the two-camp wall retired (the maintainer's decision, 2026-07-27).**
- **DECISION (the maintainer, adjudicating the 2026-07-22 audit's top finding):**
  > The objective is the development pair working wherever the GitHub App has authority. If I give the
  > App access to a private repo, then it's available. [On the audit flagging the App as installed on
  > the "camp-2" private repos:] reality is right — fix the document so the audit stops flagging it.
- **What it changes:** operating scope is the **live App installation, private repositories included** —
  read from the installation itself, never from a list in code. The earlier two-camp model (a
  "vibe-coded camp the apparatus develops" vs a "private-data camp it can never reach") is **retired**.
  R36 no longer grades a private-repo install as (b) UNSAFE; the security line that remains is that the
  apparatus must **never SELF-widen** its own installation.
- **Why:** the two-camp table hardcoded a repo list that had already drifted — the App was in fact
  installed on repos the doc named forbidden, and on others it did not list at all. The audit read that
  as its top UNSAFE finding, but it was a **doc-vs-reality contradiction, not a code defect**: R16
  already defined scope as the live installation, so a second hardcoded list added no authority — only
  a copy that drifts. Scope is a maintainer act (install/remove), not a software allowlist.
- **STATUS: ENACTED** via the PR carrying this entry. The App installation itself is unchanged — this
  records that the existing install IS the authorized scope.

**(g) AUTONOMY IS THE TIE-BREAKER — server-enforced merge declined; the deploy-path human tap removed (the maintainer's decision, 2026-07-27).**
- **DECISION (the maintainer, after a zero-base benchmark of the build and the requirements against the
  objective):** autonomy is the foremost objective. Where a control would increase human involvement
  beyond the single confirming interaction — and recovery from its absence is automatic — **the control
  is declined.** Approved: the five autonomy-preservation requirements (R39–R43), the R7 restatement,
  and the R14 sequencing.
- **What it decides, concretely:**
  1. **Server-side merge enforcement is DECLINED** (R7). Requiring the two gates as GitHub branch rules
     would move gate control out of code the apparatus can fix and into a setting only the maintainer
     can change: a broken gate would then be a human summons. Residual K2 accepted, bounded by automatic
     recoverability. The confirmed spec remains the exception (R1), because there recovery is *not*
     automatic — a silently rewritten objective cannot be rolled back by a health check.
  2. **The standing human tap in the merged→live path is REMOVED** (R41) — including the `approved`
     label gate on a deploy that requires a container recreate. **This SUPERSEDES the approval-gated
     R17 design confirmed 2026-07-19.** The reasoning has changed with evidence: a deployment is
     reversible by construction (health-gate + digest rollback + read-back), so gating it bought little
     and cost a recurring human act on the normal path. **Approval governs GOALS, not deployments.**
- **Why (the finding that drove it):** the requirement set specified ~19 ways for the loop to STOP and
  none for it to recover from a stop. Every gate was fail-closed — correct in isolation, but a closed
  gate with no self-heal is a human summons. Measured: one stalled gate produced 12 manual merges. The
  drift was never "too much security"; it was **security without recovery** (now R39/R43).
- **The limit of this ruling:** it is NOT "fewer gates". Machine gates cost nothing while they work and
  are demanded by the objective's distrust-your-own-reports clause. It is that **every blocking gate
  must carry a bounded automatic recovery** — the rule R39/R43 now state.
- **STATUS: ENACTED** for the spec (R7/R14/R39–R43 in the PR carrying this entry). R41's build —
  removing the live deploy tap — is the first implementation task.

**(f) TRINITY = MAINTAINER-MERGE-ONLY — durable enforcement of R1 (the maintainer's decision, 2026-07-23).**
- **DECISION (the maintainer, this session):** a PR that amends the confirmed spec (the Trinity —
  `00-OBJECTIVES.md` / `00-REQUIREMENTS.md` / `00-BUILDPRINCIPLE.md`) or this constitution
  (`00-GOVERNANCE.md`) must be **merged by the human maintainer, never autonomously**, and must be
  **assigned to `@oso-gato`** so it surfaces clearly in the GitHub app. "Make it durable and update the docs."
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

### 6(g) — THE FLEET SOFT HALT IS RETIRED (maintainer decision, 2026-07-30)

**DECISION.** The pinned, maintainer-thrown `halt` label — the fleet-wide soft stop every sweeper read
before acting — is **deleted**, and R9 is rewritten to carry only the hard stop. Asked directly whether
the e-stop served his objective, the maintainer's answer was to delete it and retire the requirement.

**THE EVIDENCE, measured rather than argued.**

| | |
|---|---|
| Times a maintainer ever threw it | **0**, all-time |
| Times it fired by itself | **935**, every one false |
| Cause split | **574** `gh: command not found` (a broken tool inside the box) · **332** API garbage · **29** dead credential |
| Suppressed action-attempts | **498** across five buckets — **338** fix-attempts (ONE PR at ONE sha, re-declined on 338 consecutive ~26s polls; that PR was later closed UNMERGED; **no outage-repair ticket among them**), 101 authoring-loop launches, 31 host-refresh scans, 19 reconcile, 9 ship-actuator |
| Cost | ~**870 lines** across both repos, **14 call sites** |

**WHY IT WAS NEVER A SAFETY FEATURE.** It duplicated two stops that are strictly stronger and need no
code — **App-key revocation** (works when GitHub is unreachable; the stop of record) and **stopping the
containers** — while itself depending on GitHub being readable, so it failed precisely when an outage
made it matter. An adversarial audit of the last attempt to repair it (three independent refuters, two
returning REFUTED) found the fix's own justification contained four false or vacuous claims, and a
narrow case in which work could merge **while a halt was standing**. A control whose only measured
effect is to break things is not a safety feature; it is a liability with a reassuring name.

**THE ZERO USES ARE NOT EVIDENCE OF SAFETY.** The `halt` LABEL DID NOT EXIST on either repo until
2026-07-30T12:55:25Z — created during this session's cleanup. Zero applications is what a switch with no
handle predicts, and that fact retires the "never needed, therefore safe to weaken" argument in both
directions. It is recorded here because it was used, wrongly, to justify the preceding change.

**WHAT REMAINS.** R9 keeps revocation as the stop of record. R20 and R27 lose their HALT clauses. No
sweeper reads any soft stop, so a missing reader can no longer freeze the fleet either — the failure
mode that produced 935 of the 935.

**PROCESS NOTE.** This retires a confirmed requirement, so it is MAINTAINER-MERGE-ONLY (R1) and the loop
holds it. That carve-out is the one gate deliberately kept when everything else went zero-gate.


---

*Editing this file or the PROBLEM-SOLVING DOCTRINE is a control-plane change — maintainer-adjudicated via
a fitness ESCALATE (zero-gate removed the click), and enforced MAINTAINER-MERGE-ONLY (R1).*
