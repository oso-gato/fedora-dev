# THE FLEET — the oso-gato container swarm

Three Claude Code agents ("claudeboxes") across one VPS host. Each carries a **stamped law** — its
`policy/CLAUDE.md`, re-stamped into `/etc/claude-code/CLAUDE.md` on every box rebuild, overriding
project files, prompts, and memory. All three open that law with the **identical `THE FLEET` block**,
so they share one merge model, one control-plane definition, and one spin-up pattern; their roles do
**not** overlap.

> This file is the human-readable **map**. The binding, mechanically-enforced **law** is each repo's
> `policy/CLAUDE.md` (`THE FLEET` block + the per-box ROLE). Keep this file and that block in sync —
> one wording, edited once and propagated to all three; the policy block is authoritative.

## At a glance

| Box | Role | Builds? | Merges? | Operates host? | Spin up |
|-----|------|:--:|:--:|:--:|---------|
| **fedora-dev** | develop · build · **merge** | ✅ nested | ✅ **(sole merger)** | ❌ | `./spin-up.sh` |
| **fedora-bootstrap** | operate host · live-diagnose → PR | ❌ (CI) | ❌ PR-only | ✅ incl. create/remove | `./day0.sh` (Day-0) |
| **fedora-desktop** | knowledge-work + own toolset → PR | ❌ (CI) | ❌ PR-only | ❌ | `./spin-up.sh` |

## The merge spine (shared by all three)

Everyone develops on branches and **opens PRs**. **Only `fedora-dev` merges to `main`** — any PR
including its own and any control-plane change — and **only** on Arthur's **discrete clickable
APPROVE** (a free-text "yes" is not approval).

**Handoff:** propose → open PR → `fedora-dev` lists + presents the PRs → you APPROVE → `fedora-dev`
merges → CI builds + cosign-signs → GHCR → `fedora-bootstrap` pulls + redeploys. Build is always CI;
operate/deploy is always `fedora-bootstrap`; merge is always `fedora-dev` (or Arthur on the web).

**The promotion gate is REFSPEC-AWARE and fail-closed:** routine feature-branch pushes (an explicit
non-`main`, non-`HEAD`, non-tag destination refspec) run AUTONOMOUSLY with no prompt; only a push
that could touch `main` (a bare `git push`, a `main`/`HEAD`/`refs/tags/*` destination,
`--all`/`--mirror`/`--tags`, or any unparseable / quoted / chained target) PLUS the merge verbs
(`gh pr merge`, `gh pr create --merge|--squash|--rebase|--auto`, `gh api …/merge|/merges`) route to
an in-session clickable `ask` only Arthur can answer. There is NO approval-marker mechanism (the
shipped hook uses native `ask`/`deny`). A loop-neutral **`require-PR` ruleset** on `main`
(no required reviews or status checks) is active on all three repos — it forces every change
through a PR, closing the headless `claude -p` bypass; `main` has no required-review branch
protection and no CI label-gate beyond this thin floor (the click already gates every merge).

## The three boxes

**`fedora-dev` — DEVELOP · BUILD · MERGE.** Develops image-source repos, builds them in its nested
`podman` engine (`CONTAINER_HOST`) to validate, opens PRs; **and** is the fleet's sole merge box
(lists open PRs → your APPROVE → merges, control-plane included). *Boundary:* never operates/deploys
a host or live container; `podman` only against its nested engine.

**`fedora-bootstrap` — OPERATE + LIVE-DIAGNOSE → PR** *(the genesis / mother-platform box, on the
VPS).* The only agent on the host: operates + maintains it (incl. creating/removing containers), the
only box that sees the live containers; live-diagnoses them and develops fixes to the fleet image
repos it operates → opens PRs. *Boundary:* never merges/pushes/tags `main` (`fedora-dev` does); never
`podman build` (CI does); never applies host changes itself (the operator re-runs `setup.sh` — no host
root). Host genesis path is `day0.sh` → `setup.sh` (there is no `spin-up.sh`/`run.sh`/Quadlet here).

**`fedora-desktop` — KNOWLEDGE WORK + TOOLSET DEV → PR** *(the application box).* Primary: operate +
maintain the LLM wiki + Obsidian vault (writer **under direction**). Secondary: develop, **only in its
own repo**, in-container tooling that supports the knowledge work (open to `core` + extra users).
*Boundary:* PR-only (never merges any `main`, incl. its own); every other repo off-limits; vault
content governed by the vault's own `CLAUDE.md` (discrete approval); untrusted content parsed in a
throwaway no-secret sandbox; never operates a host.

### The two-axis model — how the three claudeboxes relate

Each box hosts the same thing — Claude Code in a Distrobox ("claudebox") — so the three are **not**
three bespoke builds. Each is **one shared invariant plus a point in a grid of two ORTHOGONAL axes.**
A difference between any two boxes is therefore always exactly one of: the invariant (never — that is
*drift*, and CI fails it), the **substrate** axis, or the **role** axis. Nothing else.

**The invariant — the claude-code guard payload (identical in all three, ENFORCED).**
`policy/managed-settings.json` (the agent deny-list + the `DISABLE_UPDATES`/`DISABLE_AUTOUPDATER`
self-update lockout + bypass/mode/allowManaged + the `gate-push` hook *wiring*), the `claudebox-init.sh`
self-update lockout + native-build-shadow self-heal, and the claude-code **provenance** (Anthropic
`latest` channel, `gpgcheck=1`, pinned signing key). `bin/fleet-guard-parity.sh` (CI on push/PR **+
daily**) compares this payload across all three public repos and **fails the build on any drift** — so
it cannot silently diverge. It once did: the self-update lockout landed in `fedora-dev` but was missing
from **both** other boxes until an audit caught it; the parity check is what makes that recurrence
impossible.

**Axis A — SUBSTRATE (the architecture).** How the box is built and supervised. Drives supervision,
rebuild serialization, and the init-bridge channel — and *only* those.

| box | substrate |
|---|---|
| `fedora-dev` | **container** — `Containerfile` + `entrypoint.sh` as PID 1; *no systemd* (inotify rebuild-watcher + `flock` serialization + `podman exec` init bridge) |
| `fedora-desktop` | **container** — `Containerfile`(+`.grd`) + `entrypoint.sh`; the `grd` lineage runs **systemd as PID 1** |
| `fedora-bootstrap` | **host** — `setup.sh` on the VPS; **systemd --user** (timer/unit serialization + `distrobox enter -- sudo` init bridge) |

**Axis B — ROLE (merge authority + job).** Expressed by the `gate-push.sh` terminal verb (the refspec
parser is identical; only the verb differs) plus each box's job.

| box | role | `gate-push` verb |
|---|---|---|
| `fedora-dev` | **MERGER** (sole merge authority) | main-touching push + merge verbs → **ASK** (Arthur's in-session click) |
| `fedora-bootstrap` | **proposer** (PR-only) | → **DENY** |
| `fedora-desktop` | **proposer** (PR-only) | → **DENY** |

Role also sets: live-gate ownership (`fedora-bootstrap` *operates* Gate B; `fedora-dev` + `fedora-desktop`
are *clients* via the `live-validate` label), per-box package sets, and the role-divergent
`policy/CLAUDE.md`.

**The grid, and the key reading:**

| box | Axis A (substrate) | Axis B (role) |
|---|---|---|
| `fedora-dev` | container | **MERGER** (ask) |
| `fedora-bootstrap` | **host** | proposer (deny) |
| `fedora-desktop` | container | proposer (deny) |

The axes are independent. **`fedora-bootstrap` and `fedora-desktop` are wired the SAME on role** — both
proposer/**DENY**, both live-gate clients — so they differ from each other **only on substrate** (bootstrap
is the host, desktop is a container). **`fedora-dev` differs from both only on role** (it is the sole
merger) — *not* on substrate (it is a container, like desktop). The familiar "2 containers + 1 host"
split is Axis A; the "1 merger + 2 proposers" split is Axis B; the two cut across each other, and the
guard payload underneath is held identical by the parity check.

## The dev loop (the mechanic)

The dev↔host loop runs autonomously EXCEPT the final merge: develop → open PR (feature pushes are
autonomous) → label it `live-validate` → the host live-gate (Gate B) DISCOVERS it ORG-WIDE by that
label (no repo list to maintain), fetches the PR head on-demand, applies a STRUCTURAL GUARD (only
builds a candidate carrying a `Containerfile`/`.live-gate`, else skips cleanly), builds it DISPOSABLY
per the repo's own in-repo `.live-gate` contract (PARSED, never executed) under loopback-only fences,
and posts a GREEN/RED verdict comment → iterate (RED: push a fix, or SUPERSEDE the branch if the
approach was wrong; GREEN: BUILD UPON it) until green → Arthur's discrete clickable APPROVE →
fedora-dev merges. The human is OUT of the per-iteration loop — only the merge is a click. Repos are
discovered DYNAMICALLY: create/rename/merge/delete freely; enroll one just by labelling its PR
`live-validate` and shipping a `.live-gate`.

One loop, the same shape for every repo — only the tail differs (image repos publish to GHCR;
`fedora-bootstrap` ships no image and "deploys" by the operator re-running `setup.sh`). Work is born
as a branch, carried as a **PR**, proven on the host, merged by one authority, then deployed. No box
skips a step; a box asked to do another box's step **STOP-AND-SURFACE**s.

### The autonomy mandate, two-tier validation, and DoD

Full law: `policy/CLAUDE.md` (THE SELF-SUSTAINING APPARATUS section); always in context for the active box. Loop mechanics — steps 1–9 below.

1. **Intake & route.** A request lands on the box that *owns* the affected repo — the box that can
   both develop **and** operate/diagnose it. `fedora-dev` owns image-source development for every image
   repo it clones; `fedora-bootstrap` owns `fedora-bootstrap` + `fedora-dev` + any workload it operates
   and can live-diagnose; `fedora-desktop` owns only `fedora-desktop`. A repo a box neither owns nor can
   diagnose is **surface-only** — it proposes a diff and the owning box (or the operator) opens the PR.
2. **Develop → open PR.** The owning box develops on a branch and opens a PR against `main`. The PR
   **is** the work item and the handoff token (see *The ticket system*). **Feature-branch pushes are
   autonomous** (no prompt — the refspec-aware gate only stops a push that could touch `main` plus the
   merge verbs). `fedora-bootstrap` and `fedora-desktop` **stop here** — they are PR-only.
3. **CI build-only check.** On the image repos (`fedora-dev` / `fedora-desktop`), `build.yml` fires on
   `pull_request`: `build` runs **build-only** (`push=false`, no cosign) — proving the image *builds*
   while publishing nothing pullable. There is **no CI control-plane label-gate**; control-plane changes
   are kept standalone and flagged in the merge TLDR, gated by Arthur's click. `fedora-bootstrap` ships
   no image, so it has no build-only CI step.
4. **Host pre-merge live-gate (Tier 2 — when the box can't validate it, or the final pre-production shipment; see *Two-tier validation*).** Label the PR `live-validate` — that
   is the whole enrolment, for **any repo in the org** (the host discovers it ORG-WIDE by the label, no
   per-repo list to maintain). On the host, `live-gate-watch.timer` (15 s poll) runs
   `live-gate-watch.sh`, which finds the `live-validate` PRs across the org and, **once per head commit**
   (dedup marker `~/.local/state/live-gate/<WL>-<sha>.done`), calls `live-gate-run.sh`. That fetches the
   head on-demand, applies a **STRUCTURAL GUARD** (only builds a candidate carrying a
   `Containerfile`/`.live-gate`, else skips cleanly), resolves the gate contract from the PR-shipped
   **in-repo `.live-gate`** (PARSED as a declarative contract, **never executed** as a script; else host
   fallback `~/.config/live-gate/<WL>.env`), builds a **disposable** candidate via `build-candidate.sh`
   (`localhost/disposable/<name>:val-<sha>`, never pushed, `--rm`/`rmi`'d), runs **Gate B**
   (`validate-candidate.sh`: launch under **loopback-only fences** → wait `healthy` → access-path probe),
   and posts a `Host live-gate (Gate B): VERDICT GREEN|RED` comment back. The host **comments, never
   merges**.
5. **Iterate on RED.** A RED verdict → the owning box pushes a fix commit (or **SUPERSEDES** the branch
   if the approach was wrong); the new head SHA has no `.done` marker, so the host re-gates it exactly
   once. On GREEN, **BUILD UPON** it. Loop until GREEN. The human is OUT of this per-iteration loop.
   **Present only GREEN.**
6. **Present.** `fedora-dev` lists that repo's open PRs and presents them to Arthur one at a time as a
   **discrete clickable decision**, diff shown.
7. **APPROVE → merge.** Arthur clicks **APPROVE** (a free-text "yes" is *not* approval) →
   `fedora-dev` — the **sole merge authority** — merges to `main` (its own PRs and control-plane PRs
   included; control-plane PRs are kept standalone and flagged in the merge TLDR, gated by the same
   click). Arthur may also merge on GitHub himself.
8. **CI publish + sign (image repos).** Push to `main` triggers `build.yml`'s `build` job with
   `push=true`: publishes `ghcr.io/oso-gato/<name>:latest` (+ dated + sha tags) and `cosign sign`s the
   digest via keyless OIDC. `fedora-bootstrap` publishes no image — its analogue is step 9's operator
   `setup.sh` re-run.
9. **Deploy.** `fedora-bootstrap` redeploys via `workload-refresh@<name>` (busy-probe gated; auto-
   rollback on healthcheck failure). For the host itself, the operator re-runs `setup.sh` as root.

```
 Arthur ─ request
    │
    ▼
 [owning box]  develop on branch ──► open PR (= the ticket)  ──► CI build-only (build, push=false)
    │                                      │
    │                              label: live-validate
    │                                      ▼
    │                    [fedora-bootstrap HOST]  live-gate-watch.timer → live-gate-run.sh
    │                    build-candidate.sh (localhost/disposable/*) → Gate B (validate-candidate.sh)
    │                                      │
    │                          gh pr comment: VERDICT GREEN│RED   (comments, NEVER merges)
    │                                      │
    │                  RED ─► push fix (new SHA re-gates) ──┐
    │                  GREEN ─────────────────────────────┐│
    ▼                                                      ▼▼
 [fedora-dev]  present PR (diff shown) ─► Arthur clicks APPROVE ─► fedora-dev MERGES to main
                                                              │   (sole merger; control-plane same click)
                                                              ▼
                                              CI build.yml (push=true) → GHCR :latest + cosign sign
                                                              │
                                                              ▼
                              [fedora-bootstrap HOST]  workload-refresh@<name> → container-refresh.sh
                              busy-probe → pull → digest-compare → restart <name>.service (Quadlet)
                              └─ unhealthy ─► digest rollback (retag :latest to prior, .rolled-back)
```

## The ticket system (how work flows)

**The PR is the ticket.** There is no separate tracker; the open PR against `main` is both the unit of
work and the unit of handoff. State rides on **labels** and on **host-side verdict comments**; nothing
merges except through the clickable-APPROVE gate.

**Label vocabulary (the connective tissue):**

| Label | Meaning | Applied by |
|-------|---------|-----------|
| `live-validate` | Enroll an open PR (in **any repo in the org**) for the host pre-merge live-gate. `live-gate-watch.sh` discovers labelled PRs ORG-WIDE by the label (no per-repo list), applies a structural guard (builds only a candidate carrying a `Containerfile`/`.live-gate`, else skips), and gates each new head SHA once (`<WL>-<sha>.done`). Omit it → the host never builds or comments. | the developing box / PR author (in practice `fedora-dev`) |

There is **no CI label-gate** for control-plane changes (no waiver label, no CI guard job): a
control-plane PR (see *Shared invariants → Control-plane class*) is kept **standalone, never bundled**
and **flagged in the merge TLDR** so Arthur scrutinises it — gated, like every merge, by his in-session
click.

**Verdict carrier.** The host's `gh pr comment` (`VERDICT GREEN|RED` + last log lines) is the
machine-readable handoff that tells `fedora-dev` whether a PR is ready to present. GREEN = presentable;
RED = keep iterating. Dedup is per head SHA via the `.done` marker, so each commit is gated exactly once
and a fresh commit always re-gates.

**Paused-work & cross-box handovers — GitHub Issues (convention).** Labels and verdict comments are
script-driven; this one is a human/agent **convention**, not automation. When work must pause or be
handed to a box that does **not** own the repo (e.g. `fedora-bootstrap` surfaces a fix for a repo it
can't live-diagnose, or a task parks mid-flight — like the grd go-live handover), open a **GitHub
Issue** in the target repo with the request + the proposed diff. The owning box (or the operator) turns
it into a branch + PR, re-entering the loop at step 2.

**Box-to-box handoffs (who picks up what):**
- **propose → open PR** — any box, on a repo it owns.
- **STOP at the PR** — `fedora-bootstrap` and `fedora-desktop` are PR-only; their refspec-aware
  `gate-push.sh` lets feature-branch pushes run autonomously but **denies** any main-touching push or
  merge verb (these boxes never merge — there is nothing to approve, so the gate denies rather than
  asks; only `fedora-dev`'s gate asks, because it is the box that merges).
- **live-validate → host verdict** — label any repo's PR; `fedora-bootstrap` discovers it org-wide,
  builds disposably per the in-repo `.live-gate` (parsed, never executed), and comments GREEN/RED; the
  owning box iterates on RED (push a fix, or supersede the branch). Human-out until the merge click.
- **APPROVE → merge** — Arthur clicks; `fedora-dev` merges (sole authority, control-plane included).
  Gate + `require-PR` mechanics: see **The merge spine** above.
- **merged → deploy** — `fedora-bootstrap` pulls + redeploys via `workload-refresh@<name>`.
- **wrong box** — a box asked to do another box's step STOP-AND-SURFACEs for the human to re-route.

## Shared invariants (identical in all three)

- **Spin-up:** the wizard **asks for `TS_AUTHKEY`** (blank → `login.tailscale.com` web-login);
  `IMAGE=ghcr.io/oso-gato/<name>:latest` for a host deploy; **never hand-roll `podman`.**
- **Control-plane class** (`policy/**`, `managed-settings.json`, `gate-push.sh`,
  `.github/workflows/**`, `*.container`, `run.sh*` security flags + publish set, the
  box-rebuild/assemble machinery, key-sync, `*sudoers*`): standalone, never bundled; flagged in the
  merge TLDR and gated by Arthur's click (no CI label-gate).
- **Claude-code guard payload** (the `managed-settings.json` deny-list + self-update lockout, the
  `claudebox-init.sh` lockout + native-shadow self-heal, the claude-code provenance): **byte-identical
  in all three, CI-enforced** by `bin/fleet-guard-parity.sh` (push/PR + daily). This is the *invariant*
  underneath the two-axis model — Axes A/B may diverge; this may not. See *The two-axis model* above.
- **Sources** (dnf → vendor `.repo` → AppImage/`.war`, GPG/sha-verified) · **no secrets in image
  layers** · **headless everywhere** (software-GL); sensitive ports tailnet-only, the desktop's web
  gate the one public door.
- **Multi-device terminal:** one shared `main` tmux group; a tmux window has ONE size shared by all
  co-viewing clients, so `/etc/tmux.conf` is `window-size latest` (the device that last sent input
  wins → whole session rescales) + `fill-character ' '` (idle larger device blank-letterboxes, never
  `·`-garbles) + `prefix+g` to cycle latest/smallest/largest. Differently-sized devices on the SAME
  tab can NEVER both be full-size (one program = one pty = one cell grid) — a tmux invariant, not a
  bug to "fix"; the active device wins and the rest degrade cleanly (crop/blank-letterbox).
