# Apparatus — BUILD PRINCIPLES (construction spec of record)

> **The third leg of the Trinity.** Companion to [`00-OBJECTIVES.md`](./00-OBJECTIVES.md) (the **WHY** /
> what) and [`00-REQUIREMENTS.md`](./00-REQUIREMENTS.md) (the functional **WHAT** it must do + its
> non-functional qualities). This document is the **HOW WE CONSTRUCT & PACKAGE ANY ARTIFACT** — the
> uniform, artifact-agnostic constraints every build obeys, whether it is the host image, the dev
> container, a workload image, or a throwaway validation candidate. A functional requirement says what
> a thing must *do*; a build principle says how anything the apparatus builds must be *made*.
>
> **Relationship to the other two docs.** The objective and the functional requirements are confirmed
> once by the maintainer and are fixed (amendment = a new confirmation, R1). These build principles are
> confirmed with them and share that authority — they are graded by the same fitness gate and enforced
> by the same mechanical scans. The **design** ([`00-DESIGN.md`](./00-DESIGN.md)) is dev-owned and
> mutable-on-fact; a build principle is not. Where a per-repo `CLAUDE.md` BUILD PRINCIPLES table exists
> (fedora-dev, fedora-bootstrap), it is the **per-repo instantiation** of these
> apparatus-wide principles; it must not contradict them, and DRY (BP9) governs which is authoritative.
>
> Revised from the 2026-07-14 spec by the best-practice-lens holistic review: **BP1/BP3/BP4/BP5 are the
> construction constraints relocated here from functional requirements R21/R32/R22/R11** (those numbers
> now point here); **BP6 is the isolated-working-tree discipline extracted from R3**; **BP2/BP7/BP8/BP9
> are newly codified gaps.** Capabilities, not implementations.

## BP1 — PROVENANCE (← was R21)
Every artifact entering ANY tree the apparatus builds — host image, claudebox `additional_packages`, dev container, **and every throwaway validation build alike** — is admitted **fail-closed and version-pinned** at the strongest level it admits of a three-level hierarchy: **L1** Fedora's own dnf repos; **L2** the vendor's/developer's own RPM or dnf `.repo` with `gpgcheck=1`; **L3** last-resort official-upstream binary with no L1/L2 source, itself provenance-graded (**c1** GPG signature > **c2** published checksum > **c3** resolve-log, strongest first) and **disclosed per artifact**. It is a defect to descend to a lower level a higher one would satisfy. Forbidden outright and enforced by a mechanical scan gate: COPR/third-party repos, language package managers onto PATH (pip/pipx/npm-g/cargo/go/gem/brew), tarballs onto PATH, curl-pipe-sh, mirror/aggregator binaries, flatpak, snap. Disposability grants no exemption. Fitness treats a source below the strongest available level, an unpinned artifact, or any forbidden source as **(b) UNSAFE**.

## BP2 — VERIFY-BEFORE-ADOPT (new — gap 2)
Before adopting or bumping ANY source, version, or artifact, its existence and identity are **fact-checked against the live upstream** (not asserted from memory or a stale pin), and a **risky install** (a version-mismatched vendor RPM, a new `.repo`, an L3 binary) is **exercised in a scratch throwaway build before it is wired into a real build file**. This is BP1's companion: BP1 grades the *source level*, BP2 confirms the *input actually exists and matches intent at build time* — the anti-hallucination guard on the construction inputs, mirroring the standing empirical-proof rule (R24) at the build boundary. A version/source adopted without a live fact-check, or a risky install wired in unproven, is a reviewable defect.

## BP3 — CAPABILITY-RELATIVE MINIMALISM (← was R32)
Every package/artifact is installed at the **minimal leaf footprint for its decided capability, not to an absolute count**: no package enters any built tree without a **recorded justification**; dnf runs with **`install_weak_deps=False`**; the **most specific leaf package** is chosen over any convenience metapackage; the **irreducible hard-dependency closure** of a chosen capability is accepted and disclosed, not fought. Minimality is **capability-relative** — between equal-capability options prefer the smaller-footprint, built-in, higher-provenance one; **dropping a capability to shrink the footprint is a recorded capability trade-off, never scored a minimalism win**. Enforced as a fitness check on every package-adding change.

## BP4 — IMMUTABLE-HOST / CONTAINERISE-EVERYTHING (← was R22)
The platform is built as an **immutable custom host image** (the Fedora Bluefin custom-image principle) with **every application — claudebox, the dev container, and all workloads — running in a container**. Nothing is installed mutably onto the running host; all host change is by **image rebase/redeploy through the merge-and-deploy path**. A mechanical/fitness check fails any change that installs to or mutates the live host filesystem outside the image-build path. (The one scoped, disclosed exception is SELinux labeling on the dev container, required for nested rootless podman — a control-plane decision, not an in-session edit.)

## BP5 — THROWAWAY-BUILD & CHURN (← was R11)
Every build a throwaway. Teardown (EXIT-trap) covers **every throwaway tree, image, and run container**; an orphan sweeper reaps crash/kill leaks. The one durable input — the bind-mounted package cache — holds re-downloadable inputs, **never build output, and is never an image layer** (0-byte re-download standard across iterations). That cache is **garbage-collected by age then size to a hard ceiling** so it can never grow without limit or exhaust host storage — a scheduled, self-verifying actuator distinct from EXIT-trap teardown and the orphan sweeper. Containerfiles are structured **heavy/stable-early, churn-late**; `--no-cache`/prune is reserved for the monthly clean rebuild, never used during churn.

## BP6 — ISOLATED WORKING TREE (new — gap 3, extracted from R3)
Every authoring or build action runs in a **fresh, per-session-namespaced working tree that never mutates the immutable live tree, a shared clone, or another session's tree.** All mutable local state (worktree roots, lock/flock paths, claim/progress markers, scratch) is namespaced per session-id; the checked-out branch is **re-verified to belong to the session's own namespace before EVERY commit and push** (a shared working tree has one HEAD+index — a concurrent checkout silently relocates an unguarded commit onto the wrong branch). The `cd` into an isolated tree is a **fail-closed guard**, never a prefix: a body that must run in the tree is bound to the successful `cd`, so a failed enter runs NO mutating step in the caller's cwd. This is the codified fix for the 2026-06-28 cross-branch-leak incident. Fitness/mechanical checks treat a mutating action outside an isolated tree, or a commit/push without a branch re-verification, as **(b) UNSAFE**.

## BP7 — STAGED ROLLOUT / BACKWARD-COMPAT (new — gap 4)
Because the platform runs on **decoupled clocks** and **self-refresh**, the pair necessarily runs **mixed versions across a refresh window** — so any change to a **shared contract** (the ticket-bus grammar R5, the session registry R27, the dev↔host protocol R17/R23, a manifest/verdict format) is rolled out **consumer-before-producer and remains compatible across the window**: a new producer emission is **gated OFF by default** until the consumer that understands it is confirmed deployed, and a not-yet-upgraded counterpart **fail-safe refuses** an unrecognized shape rather than mis-parsing it. A producer-first shared-contract change that can strand or wedge the counterpart is **(b) UNSAFE**. (The `DEVBOX_MANIFEST_V2` default-off gate is the worked instance; the scope feature changes shared contracts and obeys this.)

## BP8 — TEST-QUALITY / MUTATION-PROVEN (new — gap 1)
Every behavioral change ships a test that **drives the REAL execution boundary** (the actual podman/git/kernel/process semantics under test, not a stub that asserts what a mock was told) and is **proven to FAIL against the pre-change code** — a test that passes against the unfixed code is **(c) UNTRUE** and a defect. Guards are **mutation-checked in-suite**: the pre-fix behavior is mechanically restored on a copy and the row must fail, so no row can pass vacuously. A change that silently caps, drops, or truncates coverage states it (BP9 / NFR no-silent-degradation). This is the construction-side of the objective's "distrust your own reports": the apparatus's confidence in a change rests on tests that actually bite. Fitness treats a vacuous/tautological test, or a behavioral change with no biting test, as a blocking finding.

## BP9 — DOCUMENTATION-DRY (new — gap 5; principle now, drift-audit tooling backlogged)
**One authoritative home per concept; every other mention is a one-line pointer or deleted.** Evidence and benchmarks live only in the principle they prove; fleet-wide-identical blocks are enforced identical (the `fleet-guard-parity.sh` precedent). This binds every spec/doc the apparatus authors, this Trinity included. **STATEMENT scope (2026-07-14):** the principle is binding now; the **automated cross-document drift-audit** that would mechanically detect a concept drifting across docs is **backlogged** as follow-on tooling. Until it lands, DRY is enforced by review, not machine.

---

### Where the originally-proposed BP7/BP8 went (best-practice re-classification, 2026-07-14)

Two constructs first drafted as build principles were re-homed by the holistic review — recorded here so a reader does not look for them:
- **No-secrets-in-layers** — a *security quality* the running system has, not a construction constraint → **NFR RUNTIME SECURITY POSTURE** in `00-REQUIREMENTS.md` (absorbed with least-privilege + least-scope).
- **Deploy-contract (every image ships a single sanctioned `run.sh`)** — a *functional requirement of the artifact*, and it **fails the build-principle universality test** (the setup.sh-genesis host ships no `run.sh`; a throwaway is never deployed) → **stated by [R35 DEPLOY-INTERFACE CONTRACT](./00-REQUIREMENTS.md)** and instantiated per-repo by each `CLAUDE.md` Principle 7. (An earlier draft of this note mis-cited it as "carried by R10"; R10 is the deploy *behavior* that *consumes* the interface — R35 is where the interface is defined.)
