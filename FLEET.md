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
Mechanically enforced by the `gate-push.sh` PreToolUse hook + `managed-settings.json` + the CI
control-plane diff-guard — not prose-only.

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

## The dev loop (the mechanic)

One loop, the same shape for every repo — only the tail differs (image repos publish to GHCR;
`fedora-bootstrap` ships no image and "deploys" by the operator re-running `setup.sh`). Work is born
as a branch, carried as a **PR**, proven on the host, merged by one authority, then deployed. No box
skips a step; a box asked to do another box's step **STOP-AND-SURFACE**s.

1. **Intake & route.** A request lands on the box that *owns* the affected repo — the box that can
   both develop **and** operate/diagnose it. `fedora-dev` owns image-source development for every image
   repo it clones; `fedora-bootstrap` owns `fedora-bootstrap` + `fedora-dev` + any workload it operates
   and can live-diagnose; `fedora-desktop` owns only `fedora-desktop`. A repo a box neither owns nor can
   diagnose is **surface-only** — it proposes a diff and the owning box (or the operator) opens the PR.
2. **Develop → open PR.** The owning box develops on a branch and opens a PR against `main`. The PR
   **is** the work item and the handoff token (see *The ticket system*). `fedora-bootstrap` and
   `fedora-desktop` **stop here** — they are PR-only.
3. **CI build-only check.** On the image repos (`fedora-dev` / `fedora-desktop`), `build.yml` fires on
   `pull_request`: a `control-plane-guard` job fails the PR if it touches a control-plane file without
   the `control-plane-approved` label, then `build` runs **build-only** (`push=false`, no cosign) —
   proving the image *builds* while publishing nothing pullable. `fedora-bootstrap` ships no image: its
   guard is the **standalone** `control-plane-guard.yml` (no build/publish).
4. **Host pre-merge live-gate (expected for any runtime change).** Label the PR `live-validate`. On the
   host, `live-gate-watch.timer` (15 s poll) runs `live-gate-watch.sh`, which lists `live-validate` PRs
   and, **once per head commit** (dedup marker `~/.local/state/live-gate/<WL>-<sha>.done`), calls
   `live-gate-run.sh`. That fetches the head, resolves the gate preset (PR-shipped `.live-gate` file
   first, else host fallback `~/.config/live-gate/<WL>.env`), builds a **disposable** candidate via
   `build-candidate.sh` (`localhost/disposable/<name>:val-<sha>`, never pushed, `--rm`/`rmi`'d), runs
   **Gate B** (`validate-candidate.sh`: launch fenced → wait `healthy` → access-path probe), and posts a
   `Host live-gate (Gate B): VERDICT GREEN|RED` comment back. The host **comments, never merges**.
5. **Iterate on RED.** A RED verdict → the owning box pushes a fix commit; the new head SHA has no
   `.done` marker, so the host re-gates it exactly once. Loop until GREEN. **Present only GREEN.**
6. **Present.** `fedora-dev` lists that repo's open PRs and presents them to Arthur one at a time as a
   **discrete clickable decision**, diff shown.
7. **APPROVE → merge.** Arthur clicks **APPROVE** (one-shot; a free-text "yes" is *not* approval) →
   `fedora-dev` — the **sole merge authority** — merges to `main` (its own PRs and control-plane PRs
   included; control-plane PRs additionally need the human-applied `control-plane-approved` label for CI
   to pass). Arthur may also merge on GitHub himself.
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
 [owning box]  develop on branch ──► open PR (= the ticket)  ──► CI build-only (control-plane-guard + build, push=false)
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
| `live-validate` | Enroll an open PR for the host pre-merge live-gate. `live-gate-watch.sh` polls `gh pr list --label live-validate --state open` and gates each new head SHA once (`<WL>-<sha>.done`). Omit it → the host never builds or comments. | the developing box / PR author (in practice `fedora-dev`) |
| `control-plane-approved` | CI waiver for the control-plane guard. A PR touching a control-plane file (`policy/**`, `.github/workflows/**`, `managed-settings.json`, `*.container`, `run.sh*`, `gate-push.sh`, box-rebuild/assemble, key-sync, `*sudoers*`) **fails CI** without it. Control-plane PRs are standalone, never bundled. | a human reviewer (Arthur), by hand on GitHub, after seeing the isolated diff |

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
- **STOP at the PR** — `fedora-bootstrap` and `fedora-desktop` are PR-only; their `gate-push.sh`
  unconditionally denies any push/merge to `main`.
- **live-validate → host verdict** — `fedora-dev` labels; `fedora-bootstrap` builds disposably and
  comments GREEN/RED; `fedora-dev` iterates on RED.
- **APPROVE → merge** — Arthur clicks; `fedora-dev` merges (sole authority, control-plane included);
  server-side branch protection on `main` is the primary backstop.
- **merged → deploy** — `fedora-bootstrap` pulls + redeploys via `workload-refresh@<name>`.
- **wrong box** — a box asked to do another box's step STOP-AND-SURFACEs for the human to re-route.

## Shared invariants (identical in all three)

- **Spin-up:** the wizard **asks for `TS_AUTHKEY`** (blank → `login.tailscale.com` web-login);
  `IMAGE=ghcr.io/oso-gato/<name>:latest` for a host deploy; **never hand-roll `podman`.**
- **Control-plane class** (`policy/**`, `managed-settings.json`, `gate-push.sh`,
  `.github/workflows/**`, `*.container`, `run.sh*` security flags, key-sync, `*sudoers*`): standalone,
  never bundled; needs the human-applied `control-plane-approved` label.
- **Sources** (dnf → vendor `.repo` → AppImage/`.war`, GPG/sha-verified) · **no secrets in image
  layers** · **headless everywhere** (software-GL); sensitive ports tailnet-only, the desktop's web
  gate the one public door.
