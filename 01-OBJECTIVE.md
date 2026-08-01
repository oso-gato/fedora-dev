# Unify the apparatus into a single repository

> **THE WHY** — the pair is one machine; its source should be one repository.

> **PROPOSED 2026-08-01 — NOT YET CONFIRMED.** Drafted by the dev box at the maintainer's
> instruction, after an 11-agent analysis recommended *against* the merge and the maintainer
> overruled it. That overrule is recorded, not re-litigated: see `## Out of scope`. Revision 3 —
> the binding half was rebuilt after an independent fitness review returned revision 1 with seven
> blocking findings, and `## Delivered means` was set to `merged` by the maintainer (revision 2 had
> `running`, chosen by the drafter without asking; see that section for what the choice costs here).
> Companion to [`00-OBJECTIVES.md`](./00-OBJECTIVES.md), which it does not amend in purpose — but
> see `## Notes` for the text that goes stale and who may fix it. Takes effect only on the
> maintainer's confirmation (R1).

## Objective

The apparatus is **one machine** — an immutable HOST that brings a bare VPS up on Day 0, and a
multi-tenant DEV CONTAINER that develops and builds on it. Its source is two repositories, and that
split is not free: **a change to the apparatus does not land once.** It lands twice, by hand, in
lockstep, or it lands once and quietly leaves the other half behind.

The outcome wanted is this: **a change to the apparatus lands ONE time, and both halves are running
it.** No porting a fix from one half to the other. No guard whose only job is to notice that the port
never happened. No half-landed window where the two halves read the same signal to opposite
conclusions. No step in host provisioning that reaches across the network into another repository's
`main` and dies if it cannot.

That outcome is wanted in the shape the maintainer has chosen: **one repository, holding the host
bootstrap and provisioning alongside the dev container.** The shape is his. *How* that shape is
reached — flat, subtree, prefixed, or something better — is the loop's to work out, subject to the
invariants below, which are not preferences but the mechanisms currently holding the apparatus's
safety properties up.

This is a **control-plane change to the machine that would be performing it**, executed by that
machine on itself while it runs. It is the race car repaired while racing, on the chassis. It is
therefore ordered, gated and reversible at every step, or it is not attempted.

## Scope

- **One repository holds both halves.** The host's Day-0 bootstrap, provisioning and operation, and
  the dev container's spec, build and loop machinery, resolve from one tree and merge through one
  pipeline.
- **`fedora-dev` is the surviving repository.** Not symmetric and not a preference:
  `.github/workflows/build.yml` is the only publisher of `ghcr.io/oso-gato/fedora-dev:latest`, it
  exists only in fedora-dev, and Actions do not run in an archived repository. The name is also load-
  bearing — the scope reader's fail-closed self-exemption matches it literally.
- **This document is under R1 before it carries authority.** `01-OBJECTIVE.md` is added to
  `bin/auto-merge.sh`'s `TRINITY_PATHS` and to `.github/CODEOWNERS`, and that lands **before** this
  objective is confirmed. Otherwise the loop can auto-merge an amendment to the objective it is
  judged against — the author≠judge boundary, broken at the root.
- **The duplicated payload collapses to one source of truth.** Where the two halves genuinely share
  a file, there is one copy. Where they legitimately differ — and most of the current ten differ
  because the boxes differ, not because anyone drifted — the difference is *stated as intentional*,
  not left to a guard to re-derive.
- **The cross-repo runtime dependency disappears.** Host provisioning reads its law from the same
  tree it was cloned from. It never fetches it over the network, and never fails because GitHub was
  unreachable.
- **The porting apparatus is retired, and its guarantees are not.** ~900 lines exist to alarm on
  drift between exactly these two repos. They go — but only together with whatever replaces the
  properties they were checking.
- **The invariants below hold, verified, after the move.** Each is enforced today by a mechanism
  that breaks *silently* if the tree moves under it. They are in scope precisely because they are
  the ways this goes wrong quietly rather than loudly:
  - **The R1 spec hold still fires at all three `00-GOVERNANCE.md` §6(f) layers.**
    `bin/auto-merge.sh` matches the confirmed spec by bare root filename; `.github/CODEOWNERS`
    matches it by root-anchored path; the `main` Code-Owner branch rule keys off CODEOWNERS and is
    the only thing that blocks *even a raw-API merge*. A relocated spec doc matches **none** of the
    three, and the only carve-out from zero-gate fails **open** — a defect PR #224 already caused
    once.
  - **The self-refresh still applies to BOTH halves.** `hcr_install_from` hard-errors on a missing
    manifest source — the loud path. The silent one is `bin/host-refresh.sh`'s root-anchored
    classifiers: `IMAGE_RE=^(Containerfile[^/]*|install[^/]*\.sh|entrypoint[^/]*\.sh)$` stops
    matching a relocated `Containerfile`, so **no redeploy ticket is ever filed again and the dev
    container freezes at its last pre-move digest**, while `INERT_RE` stops classifying a relocated
    doc as inert, so a README edit files an apply-bootstrap that re-runs `setup.sh` as root on the
    live host. Both classifiers and every manifest path resolve correctly in the new tree, proven by
    test, not by reading.
  - **The live-gate fence never widens.** fedora-dev's `.live-gate` sets a global `CAND_FENCE`
    carrying `NET_ADMIN`, `SYS_ADMIN`, `/dev/net/tun`, `/dev/fuse` and `label=disable`;
    fedora-bootstrap's sets none and relies on the hardest default. One merged contract must not let
    the host's `shellgate` inherit that fence for **un-merged PR code**.
  - **The loop can still fix itself.** The scope reader's fail-closed self-exemption still matches
    the surviving repo, including once the retired one is archived.
  - **The record still resolves.** Every SHA, PR and issue URL cited in the design and governance
    ledgers still points at something.

## Out of scope

- **Other repositories.** `fedora-desktop`, `knowledge-desktop` and every workload/tenant repo stay
  where they are. This unifies the *pair*, not the fleet.
- **The apparatus's purpose.** `00-OBJECTIVES.md`, `00-REQUIREMENTS.md`, `00-BUILDPRINCIPLE.md` and
  `00-GOVERNANCE.md` are unchanged in intent. Their *text* is a different matter — see `## Notes`.
- **The container boundary.** The dev/host separation of duties, the two distinct App identities,
  and author≠judge are untouched: that boundary is **identity**-based, never repo-based. One repo,
  still two actors.
- Ruled out: **keeping two repos and fixing the drift in place** (five bounded PRs, ~155 lines) —
  the maintainer was shown this alternative with its evidence and chose unification anyway. Its
  reasoning is not lost: every fix in it that is a *precondition* of the move is folded into Scope
  above. Recorded so it is not re-proposed as a fresh idea.
- Ruled out: **rewriting history with `filter-repo`** — it invalidates every SHA cited in
  `00-DESIGN.md`, the governance ledger and the verdict-comment stream, which is the apparatus's
  record of itself.
- Ruled out: **deleting the retired repository** — archive it, so every cited URL still resolves.
- Ruled out: **renaming the surviving repository** — the scope reader's self-exemption matches it by
  name; a new name makes that match nothing, and an App-enumeration outage would then freeze the
  loop's ability to repair even itself.

## Acceptance

```
$ bash unified-repo.test.sh
```

observed: FAILS today (no such file — writing it is part of this work)

Its first act is `cd "$(git rev-parse --show-toplevel)"`; every pathspec is `:(top)`-anchored. It
must assert each of the following, every one of which was **run and seen failing** on 2026-08-01:

```
$ git ls-files | grep -q 'setup\.sh$' && git ls-files | grep -q 'Containerfile$' \
    && test "$(git ls-files | grep -c 'auto-merge\.sh$')" = 1
observed: FAILS today (both halves' entry points do not resolve from one tree — two repos)

$ ! git grep -qF 'raw.githubusercontent.com/oso-gato/fedora-dev' -- ':(top)'
observed: FAILS today (rc=1 — the grep FINDS 1 hit at setup-user.sh:96, a fatal cross-repo
          fetch; observed in fedora-bootstrap @ origin/main)

$ git show HEAD:.github/workflows/build.yml | awk '
    /^on:[[:space:]]*$/            {ino=1; next}
    ino && /^[^[:space:]]/         {ino=0}
    ino && /^  [a-zA-Z_-]+:/       {t=$1; sub(":","",t); trig=t}
    ino && trig=="push" && /^    paths(-ignore)?:/ {found=1}
    END {exit !found}'
observed: FAILS today (rc=1 — no paths: under the PUSH trigger, so every commit republishes
          :latest; observed in fedora-dev @ origin/main. fedora-bootstrap has no build.yml at
          all. The state machine is keyed on YAML indentation and re-anchors at each trigger:
          a naive `/push:/{p=1} p&&/paths:/` reads a paths: under pull_request: as satisfying
          push: — verified, it returns rc=0 on exactly the defect it must catch)

$ git show HEAD:.github/CODEOWNERS | grep -qE '^/?dev/00-OBJECTIVES\.md[[:space:]]+@oso-gato'
observed: FAILS today (rc=1 — CODEOWNERS is root-anchored; a relocated spec doc is owned by
          nobody, and the Code-Owner branch rule is what blocks even a raw-API merge)

$ git show HEAD:bin/auto-merge.sh | grep -m1 '^TRINITY_PATHS=' | grep -q '01-OBJECTIVE.md'
observed: FAILS today (rc=1 — TRINITY_PATHS lists only the four 00-* docs)

$ git show HEAD:bin/host-refresh.sh | grep -m1 '^IMAGE_RE=' | grep -q 'dev/'
observed: FAILS today (rc=1 — IMAGE_RE is ^(Containerfile[^/]*|...)$; a relocated Containerfile
          matches nothing, so the dev container silently never redeploys again)

$ ! git show HEAD:.live-gate | grep -q '^CAND_FENCE='
observed: FAILS today (rc=1 — fedora-dev's .live-gate sets a global CAND_FENCE with NET_ADMIN,
          SYS_ADMIN, /dev/net/tun, /dev/fuse, label=disable; every wide cap must live under a
          FENCE_<target> key so the host's shellgate cannot inherit it)

$ git grep -q 'repo-scope' -- ':(top)live-gate-run.sh' ':(top)live-gate-watch.sh'
observed: FAILS today (rc=1 — zero references; host PR discovery is org-wide and unscoped;
          observed in fedora-bootstrap @ origin/main)
```

At least one assertion per invariant must **execute** the mechanism rather than grep for it — a text
suite is the one instrument that cannot see a silent break. The cheapest and highest-value:
drive `bin/auto-merge.sh` against a synthetic PR file list containing a relocated spec doc and
require the **exit 4** maintainer-merge hold.

Done when `unified-repo.test.sh` passes on the unified repository's `main`.

## Delivered means

merged

**What `merged` gives up — stated plainly, because it is not free here.** The maintainer chose
`merged`, so this objective is delivered when it is on `main`; an absent live probe may not block the
ship. That is a legitimate choice and it is his to make, but note where this particular change's
failure modes live: **every silent hazard named in `## Scope` manifests only *after* merge, on the
live host.** A frozen dev container (`IMAGE_RE` no longer matching a relocated `Containerfile`), a
control clone that cannot fast-forward from a re-pointed remote, an R1 hold that stopped firing —
none of them are visible to a test suite run on the merged tree. So the following are recorded as
**post-merge verification, deliberately outside the ship gate**, and someone must still read them:

- `~/.local/state/host-code-refresh/applied.sha` holds a sha from the unified repo. (This file, not
  the heartbeat: `HCR_OUTCOME="OK applied <sha>"` is overwritten by `OK uptodate <sha>` on the next
  15-minute tick.)
- A post-move dev-container redeploy has been filed **and** applied — the check that catches the
  frozen-container failure, which is otherwise silent and indefinite.

If either is to gate the ship rather than follow it, this field becomes `running` — a one-word
change, and the only one needed.

## How

The host half is proven live from the new source — its control clone re-pointed and
`applied.sha` READ showing it applied — before the dev half moves. Note `host-code-refresh.sh` only
ever fetches inside a pre-existing clone and has no re-point or re-clone path, so the re-point must
land through the old repo first; if that ordering is impossible, that is a genuine fork — surface it.
Land every dispatch filter as a no-op first and flip it in a separate change.
Ship the replacement for a retired guard in the SAME change that retires it: `fleet-guard-parity.sh`
`exit 0`s (a PASS) below two participants, so deleting it disarms silently.
Prove reversibility before each irreversible step, and come back to the maintainer BEFORE archiving
the retired repository — that one the loop cannot undo.
Stop after 2 attempts at the same failure, and treat a wait that cannot end as a failure.

## Notes

- **THE ONE DECISION FOR THE MAINTAINER: does the Trinity amendment ride this same confirmation?**
  `00-REQUIREMENTS.md` R16 fail-closes to the two-repo set `{fedora-dev, fedora-bootstrap}`, and
  `00-OBJECTIVES.md` describes a two-repo pair in prose. Both go textually false the moment the
  retired repo is archived — and `bin/auto-merge.sh` holds any PR touching those docs at exit 4, so
  this is the one thing in scope that **the loop is structurally forbidden from fixing itself**.
  Either confirm the amendment with this objective, or it blocks at the end.
- **The R1 protection this document claims is thinner than it reads — disclosed, not hidden.**
  `.github/CODEOWNERS` covers only the four spec docs; it does **not** cover itself, and it does not
  cover `bin/auto-merge.sh`. So the machinery enforcing maintainer-only spec amendment is itself
  freely auto-mergeable through the normal poller path, and adding `01-OBJECTIVE.md` to that guard
  inherits the same weakness. Closing it is a two-line addition (`/.github/CODEOWNERS` and
  `/bin/auto-merge.sh` as maintainer-owned) but it changes what the loop may merge unattended, so it
  is a maintainer decision, not a loop fix. Pre-existing; not introduced by this objective.
- **Adopted follow-on, not a precondition:** giving the host an R16 scope check. `bin/repo-scope.sh`
  has declared itself "meant to be MIRRORED into fedora-bootstrap" since #167 and never was, so host
  PR discovery is org-wide and unscoped. Nothing about joining the trees causes that to start or stop
  — it is real, and it is a rider. Its gate is the last acceptance assertion above; if it is dropped
  from this objective it needs its own ticket, not silence.
- **Relation to the standing plan (fedora-dev#274):** this objective serves none of #274's three
  moves. It is here because the maintainer ranked it above them, which outranks the loop's judgement
  — recorded, not contested.
- **A live defect found during this analysis, not in this scope:** `fedora-bootstrap`'s
  `gh-app-provision.sh:81` still uses bare `openssl pkey -noout` where the dev copy uses
  `openssl pkey -passin pass: -noout`. A Day-0 operator pasting an encrypted key on the host hits a
  silent hang the dev side fixed on 2026-07-11 — its own comment records it "cost a live host visit
  once." Neither copy is in any guard's payload. Wants its own ticket, today.
- `fedora-desktop/policy/managed-settings.json` is drifted right now (missing the `Stop` anti-stall
  hook block the other two share byte-identically). Also out of scope here; also wants a ticket.
- The `VERSION` file's meaning under one repo is undecided: 94 of 180 host commits in 90 days touch
  it, and 63 `UPGRADING.md` rows verify against it. Applied repo-wide it becomes a conflict hotspot
  against `POLLER_REBASE_MAX=6`. The loop should decide and record, not ask.
