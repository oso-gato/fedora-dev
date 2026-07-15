# Apparatus — DESIGN (design of record)

> Companion to [`00-OBJECTIVES.md`](./00-OBJECTIVES.md) (the **WHY**) and
> [`00-REQUIREMENTS.md`](./00-REQUIREMENTS.md) (the functional **WHAT** + acceptance). This document is
> the **HOW** — the architecture and mechanisms that satisfy the requirements, and *why this design and
> not the ones we discarded*. Read: objective → requirements → this.
>
> **This doc is LIVING, not locked.** The objective is R1-confirmed and frozen; this design is
> maintained to match reality. We do **not** design the whole system up front. We design a **portion**,
> build against it, validate, iterate if it fails, and **then update Part 1 here to match what was
> actually built**. So Part 1 always describes what EXISTS (or is being built, tagged as such) — never
> an aspiration.
>
> **Two parts.**
> - **PART 1 — THE DESIGN AS IT STANDS.** The current, correct design of each subsystem. Tagged
>   `[BUILT]`, `[BUILDING]`, or `[DESIGNED]`.
> - **PART 2 — THE JOURNEY.** The road travelled, the roads avoided, and the roads that **failed** — so
>   a future reader (or a wiped box) does not re-walk a proven dead-end. This is what used to live
>   murkily in agent memory.
>
> **Scope note.** This doc opens with the **rebuild-continuity / multi-tenant** area (the active
> workstream, 2026-07). It grows to cover the other subsystems (the merge pipeline, the dev engine, the
> scope/halt fences) as each is next revisited. A subsystem's absence here means "not yet transcribed,"
> not "no design."

---

# PART 1 — THE DESIGN AS IT STANDS

## 1. The pair + the ticket bus  `[BUILT]`

The apparatus is a **PAIR**: `fedora-dev` (nox — develop/build/merge) and `fedora-bootstrap` (erebus —
the host: operate/live-gate). The split is deliberate: the dev box is walled off from host operations,
and the host owns the container lifecycle. They cooperate over a **ticket bus** — a `host-task`-labelled
GitHub issue in the control repo whose **line 1** is `host-op: <verb> [args]`; the host's
`host-agent-watch.sh` consumes it, performs the allowlisted op, posts `host-agent: DONE|FAILED`, and
closes it.

The pair is **symmetric**: dev enacts on the host via tickets; the host enacts on the dev container via
podman. The design consequence (from the R17 work): **a bootstrap paradox — "X cannot act on itself" —
is resolved by MOVING THE ACTOR to the other half of the pair, never by relaxing the requirement.**

## 2. R17 — Rebuild continuity  `[BUILT single-tenant · BUILDING multi-tenant]`

**Requirement (R17 + R20 + R27):** a purposeful rebuild is a complete lifecycle — KILL → REBUILD →
RESTORE **every** session → RESUME (actively working, not merely present) → VERIFIED (live read-back +
every restored session alive, **by container ID never name**).

**Design — the host orchestrates from OUTSIDE.** Code inside the dev box dies at the KILL step, so it
cannot run the lifecycle. The host does the whole thing via podman: a container destroyed **from the
host** leaves no PID-namespace ghost, which an in-container `distrobox rm -f` cannot avoid. The dev box's
only job is to declare **what was running**.

- **Host executor** — the `rebuild-devbox` verb (fedora-bootstrap `host-agent-watch.sh`). Ticket line 1
  `host-op: rebuild-devbox fedora-dev`; a session **manifest** rides in the body. It kills the container,
  rebuilds to spec, recreates each session, resumes it, and verifies. **AUTHOR-GATED** to a human
  admin|maintain — it refuses a bot author, because a destructive whole-box rebuild is an explicit human
  action by design (R17 "purposeful"). There is **no per-session rebuild** (R20): rebuild is
  whole-container, restoring all resident sessions together.
- **Dev producer** — `bin/rebuild-request.sh` (fedora-dev). Enumerates what is running, composes the
  manifest + ticket, and **presents it for a maintainer to author** (a prefilled new-issue URL). It does
  not file the ticket itself (the author-gate). It weakens no gate.
- **Manifest grammar** — the cross-repo contract, PARSED not executed, between
  `%%DEVBOX-MANIFEST-BEGIN%%` / `%%DEVBOX-MANIFEST-END%%` sentinels; one line per session; strict
  name/cwd allowlists (one bad line rejects the whole ticket).
  - **v1 `[BUILT]`:** `session <name> <cwd>` → resumed with `claude --continue` (cwd-scoped).
  - **v2 `[BUILDING]`:** `session <name> <cwd> <sid>` → resumed with `claude --resume <sid>` (see §3).

**Live-proven 2026-07-14:** a real `rebuild-devbox` killed the box, rebuilt it, recreated the `main`
session, and resumed `claude --continue` all the way back to the live conversation. The one gap surfaced:
Claude's first-run folder-trust prompt (see §4).

## 3. R20 / R27 — Multi-tenant session registry + restore  `[DESIGNED — building]`

**The reality.** The dev container is multi-tenant. An operator SSH/moshes in and runs **N tmux
WINDOWS** in the shared `main` session; each window is a bash shell **or** an interactive claude session.
**Tenants = the claude windows.** They routinely **share a cwd** (`/home/core`).

**Why v1 is insufficient.** `session <name> <cwd>` + `claude --continue` resumes only the **most-recent**
session in a cwd, so N tenants sharing `/home/core` **collapse to 1** on restore. Confirmed live (2 live
tenants, same cwd).

**The design — assign-at-launch.**
- **Identity is ASSIGNED, not discovered.** A live session's id is **not** recoverable from outside it —
  it is not in `/proc/<pid>/environ` (claude generates it *after* launch) and the process holds no open
  `<sid>.jsonl` fd. So a scanner cannot learn it. Instead `bin/claude` (the launch wrapper) **mints a
  UUID** and launches `claude --session-id <uuid>` — the id is known at the natural point. *(Verified:
  `--session-id` assigns it; `--resume <uuid>` resumes it.)*
- **The registry (R27) is the source of truth.** `bin/claude` registers `{uuid, cwd, tmux-window,
  container-id, liveness}` on launch and releases on exit; a crashed session is reaped by the lock-lib
  liveness adjudication. The record extends today's `{sid, coords, scope}`.
- **Restore reads the registry.** The producer emits `session <name> <cwd> <uuid>` per **live registry
  entry** (not tmux-session enumeration); the executor resumes each with `claude --resume <uuid>` in a
  recreated window. Every tenant returns **by id**, even sharing a cwd.

**Staging — the pair, executor-first** (per the R17 stagger rule: the consumer of a new contract lands
before the producer emits it):
1. registry schema + `bin/claude` registration `[fedora-dev]`;
2. executor accepts the `<sid>` field + `--resume`, **backward-compatible** with v1's 3-field grammar
   `[fedora-bootstrap]` — lands FIRST so a v2 manifest is never rejected;
3. producer emits the `<sid>` manifest from the registry `[fedora-dev]`.

**Caveat.** `bin/claude` is baked into the image (`/usr/local/bin`), so the foundation takes effect only
after a fedora-dev **image rebuild + redeploy**, not instantly like a live-clone change.

## 4. Folder-trust pre-seed  `[DESIGNED]`

A restored (or fresh) interactive claude stalls on the first-run *"Is this a project you trust?"* prompt
— "restored but idle," which R17 RESUME forbids. **Fix:** pre-seed `~/.claude.json`
`projects["<cwd>"].hasTrustDialogAccepted = true` (+ `hasCompletedProjectOnboarding`) for each tenant
cwd, so claude starts active. (The `-p` non-interactive mode skips the prompt, but a restored session is
a real TTY, so the config seed — not `-p` — is the path. There is no fleet-wide managed-settings key to
disable the prompt; trust is per-path.)

---

# PART 2 — THE JOURNEY (roads travelled · avoided · failed)

## R17 rebuild continuity → multi-tenant restore (2026-07-14/15)

**Road travelled.**
- **v1 single-tenant producer** (`bin/rebuild-request.sh`, #191): enumerate tmux sessions →
  `session <name> <cwd>` → `claude --continue`. Byte-compat-tested against the executor's *real* parser;
  **live-proven** (a real rebuild restored the session). Correct for one session, and the right MVP to
  prove the host executor end-to-end before adding identity.

**Roads that FAILED — dead-ends, do not re-walk.**
- **`claude --continue` for multi-tenant.** It is cwd-scoped ("most recent conversation in this cwd"), so
  N tenants sharing `/home/core` collapse to 1. Fundamental, not a tuning issue → resume must be **by id**.
- **A base-level `/proc` scanner to read live session-ids.** `CLAUDE_CODE_SESSION_ID` is **not** in
  `/proc/<pid>/environ` (claude sets it *after* launch) and the process holds no open `<sid>.jsonl` fd.
  A sibling process **cannot** learn a live session's id. Verified empirically (both live tenants read
  `sid=none`).
- **Transcript-mtime mapping (pid → most-recent `.jsonl`).** Ambiguous when tenants share a cwd (all
  write to the same `~/.claude/projects/<slug>/`). Cannot reliably map pid → sid.

**Roads AVOIDED — considered, not taken.**
- **SessionStart/SessionEnd hooks (self-registration).** Would work (a session knows its own id from
  inside), but adds a dependency on claude hook config/reliability under managed-settings, and needs a
  filter to exclude headless `claude -p` / subagent runs. Avoided in favour of assign-at-launch (no hook
  dependency, id deterministic).
- **A separate supervised registrar service** scanning `/proc` (like the deadman). Blocked by the same
  "cannot read the id" dead-end above.

**The chosen road: assign-at-launch.** `bin/claude` mints the UUID and passes `--session-id`; as the
launch wrapper it knows the cwd + tmux window, so it registers at the exact right point. Round-trip
verified. The id becomes deterministic, external, and resumable.

## Supporting merge-loop incidents (2026-07-14) — surfaced while landing the R17 work

- **The fitness-login separation-of-duties bug (#192).** A strict-SoD arm (`FITNESS_SAME_IDENTITY=0`)
  with `FITNESS_LOGIN` unset let the poller default the *reviewer* login to the **dev** identity, so the
  author≠judge guard refused **every** review → all auto-merges blocked fleet-wide. Fix: default
  `FITNESS_LOGIN` to the fitness App under strict mode. **Lesson:** a make-it-work default that is only
  correct for one mode is a latent trap in the other.
- **The distrobox-enter restart race.** After a container restart, the entrypoint's supervise-loop
  `distrobox enter` hung in `podman logs -f` waiting for a setup sentinel that had already scrolled past
  its `--since` window → the poller + deadman never launched. Recovery: kill the stuck enters; the loops
  relaunch fresh against the ready box. **Lesson:** a restart can strand services in the enter-wait;
  R17's clean, host-orchestrated lifecycle is the durable fix.
