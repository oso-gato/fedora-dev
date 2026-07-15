# Apparatus — ARCHITECTURE & DESIGN (design of record)

> Companion to [`00-OBJECTIVES.md`](./00-OBJECTIVES.md) (the **WHY**) and
> [`00-REQUIREMENTS.md`](./00-REQUIREMENTS.md) (the functional **WHAT** + acceptance). This document is
> the **HOW**, in two registers: the **ARCHITECTURE** — the whole system's intended structure,
> architected **upfront** from the requirements — and the **DESIGN** — the per-portion mechanisms,
> designed just-in-time as each portion is built. Read: objective → requirements → this.
>
> **The workflow this document serves.** Objectives translate into functional requirements; the whole
> system is then **architected upfront** (Part 1) — but it is **not designed** upfront. We design a
> **portion**, build against it, validate, and iterate — always **keeping the broader architecture in
> mind** — and only then update Part 2 to match what was **actually built**. So Part 1 is the
> structural roadmap the portions build within; Part 2 always describes what EXISTS (or is being
> built, tagged as such) — never an aspiration. Where the built machinery has not yet caught up to the
> confirmed architecture, Part 2 says so with a `[BUILT — transitional]` tag naming the target.
>
> **Findings change the design — and sometimes the architecture.** Build/validate findings classify
> two ways: most prompt a **different design under the same architecture**; a **profound** finding may
> force a review of the architecture itself. Both are legitimate. The architecture is a roadmap to be
> taken seriously, **not stone** — the endgame is to solve the problem. But an architecture change
> carries a higher burden than a design change: it must be **grounded in verified fact** (empirically
> demonstrated findings — never a hallucinated or falsified claim), justified by sound architectural
> principles, and recorded in Part 3 with its evidence. The same grounding rule governs this document
> itself: every Part 1 claim is held to the confirmed spec, and spec-vs-built conflations are defects
> (the first adversarial fact-check of this very document found ten — see Part 3).
>
> **Three parts — each opens with its forest.** Part 1 and Part 2 each begin with a short OVERVIEW
> (A0 / D0 — the bird's-eye "system context") that introduces and anchors every section before any
> detail: read the overview to navigate; read the sections to build.
> - **PART 1 — THE ARCHITECTURE.** The whole system, upfront, as the confirmed objective +
>   requirements define it: the actors, the bus, the loop, the trust boundaries. The roadmap every
>   portion is built within and measured against. A0 overview → A1–A7.
> - **PART 2 — THE DESIGN AS IT STANDS.** The current, correct design of each portion. Tagged
>   `[BUILT]`, `[BUILT — transitional]` (works, but deviates from the confirmed architecture; target
>   named), `[BUILDING]`, or `[DESIGNED]`. D0 overview → D1–D5.
> - **PART 3 — THE JOURNEY.** The road travelled, the roads avoided, and the roads that **failed** —
>   design-level and architecture-level findings alike, with their evidence — so a future reader (or a
>   wiped box) does not re-walk a proven dead-end. This is what used to live murkily in agent memory.
>
> **Scope note.** Part 1 covers the whole apparatus. Part 2 opens with the **rebuild-continuity /
> multi-tenant** portion (the active workstream, 2026-07) and grows to cover the other portions as
> each is next revisited. A portion's absence from Part 2 means "not yet transcribed," not "no design."

---

# PART 1 — THE ARCHITECTURE

The intended structure of the whole apparatus, derived upfront from the confirmed objective +
requirements (2026-07-14 set). Portions are designed and built **within** this frame; deviations are
findings to record in Part 3, never silent edits.

## A0. System overview — the forest

The apparatus is a **self-sustaining autonomous development loop** run by a **pair** of actors — an
immutable HOST and a multi-tenant DEV CONTAINER, each the other's lever (**A1**) — coordinating
exclusively over **GitHub**, which is at once the message bus, the audit log, and the canonical
durable state (**A2**). On that bus runs **the loop**: one human-confirmed spec is planned, authored,
validated, independently judged across trust domains, merged server-side with no human click,
deployed, and read back live (**A3**). All validation happens at two tiers on **disposable
throwaways** — nothing ever mutates a live system or a working tree (**A4**). Inside the dev
container, **N tenant sessions** run concurrent autonomous loops, isolated by declared scope, tracked
in a session registry (**A5**). The whole stack rides **three decoupled rebuild clocks** on an
immutable substrate, with lifecycle continuity across rebuilds guaranteed, not lucky (**A6**). Around
everything stands a **fail-closed control plane** — scope, halt, liveness, merge trust,
recoverability — with only a handful of human anchors (**A7**).

The anchors, one line each:

| § | Anchor | One line |
|---|---|---|
| **A1** | The pair | two actors, symmetric actuation; a bootstrap paradox means MOVE THE ACTOR |
| **A2** | The bus | GitHub = IPC + WAL + audit; canonical durable state; signals identity/sha/scope-bound; parse, never execute |
| **A3** | The loop | confirm once → plan → author → validate → judge → server-merge → deploy → verify-live → self-refresh |
| **A4** | Validation | two tiers, disposable throwaways, one durable input (the package cache) |
| **A5** | Multi-tenancy | N sessions, disjoint declared scopes, the R27 registry as source of truth |
| **A6** | The clocks | host image · dev image · claudebox — decoupled; rebuild continuity (R17) |
| **A7** | Control plane | fail-closed gates; scans layered, never the sole guard; three human anchors |

## A1. The pair — two actors, symmetric actuation

The apparatus is a **PAIR**, each the other's lever: the **HOST** (erebus, `fedora-bootstrap` — the
immutable substrate, operator of containers, the single shared validator) and the **DEV CONTAINER**
(nox, `fedora-dev` — multi-tenant development and build), both running the Claude Code agent. The dev
box never touches the host directly — it **instructs the host's agent** over the ticket bus (A2); the
host enacts on the dev container via podman, from outside. Neither box rebuilds the very agent doing
the work: the host rebuilds the dev container; the dev box tickets the host's refresh (R17/R23 —
pair-driven, staggered ordering). **Architectural consequence:** a bootstrap paradox — "X cannot act
on itself" (install itself, kill itself, restore itself) — is resolved by **MOVING THE ACTOR** to the
other half of the pair, never by relaxing the requirement. A design convention this document adds (not
itself a spec clause): when a cross-repo contract changes, the **consumer lands before the producer**
emits the new form, so nothing is ever rejected mid-rollout.

## A2. GitHub is the bus — and the canonical durable state

Issues are tickets; PRs are the work items ("the PR is the ticket"); comments carry machine verdicts —
GitHub is the sole IPC, WAL, and audit log (R5). **No durable authoring/progress state persists
outside GitHub** — every loop component is crash/kill/restart-resumable from the PR/issue stream —
with the spec's named exceptions: the **per-session coordination namespace** (lock, markers, scope,
verdict-routing — local container state *by design*, R3), the home-volume **session registry** (R27),
and the one durable build input (the package cache, A4). Machine-read signals are **identity-bound
and line-1-anchored** with a fixed verb allowlist; everything gating binds to the **full 40-hex head
sha AND the merge-base sha** (a verdict auto-voids when the base advances past it, R25) **AND the
per-session scope/routing token** (verdict routing matches sha + session key together, R5) — so
prose, quoted examples, or embedded logs can never forge a signal, and a stale or misrouted verdict
can never gate. Untrusted content (PR heads, ticket bodies, manifests, `.live-gate` contracts) is
**PARSED as bounded data, never executed**.

## A3. The autonomous loop

One confirmed spec → shipped product, humans out of the per-iteration loop:

**intake** (R1: the maintainer confirms the requirement set exactly once) → **plan** (spec → a
backlog of feature issues) → **author** (issue → implementation in a fresh isolated worktree → draft
PR at first push) → **validate** (two-tier, A4) → **independent self-check** (R6: every head sha is
judged by a **non-author identity on the other trust domain — erebus** — grounded in the confirmed
spec, never the PR's own body; findings are generative, feeding the fixer; MVP-first severity — only
INCORRECT / UNSAFE / UNTRUE blocks, everything else is a NOTE) → **click-free, server-enforced merge**
(R7: GitHub **native auto-merge** the instant the required live-gate + fitness checks — postable only
by the host validator identity, sha-bound — are green; out-of-scope repos get no auto-merge;
**no custom merge executor**, so a compromised author box cannot merge anything) → **deploy** (CI
builds + publishes; the host pulls + redeploys under a health-gate with automatic digest rollback) →
**verified-live read-back** (merged ≠ live: the live artifact is re-read and matched against merged
source before a feature closes, R2/R23) → **self-refresh** (a merge to either apparatus repo
**automatically arms** the matching refresh, no human step — the host direction ticketed by the dev
box, the dev-container direction driven by the host, R23).

A standing design law runs through every stage: **models exercise judgment; plain shell takes
actions.** Every actuator is deterministic, auditable, and re-checks its own gates.

## A4. Two-tier validation on throwaways

**Tier 1 (default, in-box):** the dev box validates everything its nested engine can — build,
assembly, lint — iterating with no host and no human. **Tier 2 (the host live-gate):** what only a
real host can prove — a live boot, health, access paths — runs there on a **disposable candidate**
under loopback fences, returning a GREEN/RED verdict; on RED the loop fixes and re-gates. Scenario B
(host per iteration) exists only where the nested engine fundamentally cannot run the artifact (e.g.
systemd-PID-1). Nothing ever mutates the live host, the running container, or the repos' git working
state: fresh worktrees for source, throwaway trees + images for builds (EXIT-trap teardown, orphan
sweeping), and exactly **one durable input** — the package cache, bind-mounted (not an image layer)
and GC'd by age-then-size.

## A5. Multi-tenancy — isolation by scope, sessions as first-class citizens

The dev container is multi-tenant: **N isolated claudebox sessions** (tenants), each an autonomous
loop on its own **declared, pairwise-disjoint repo-set** (R16: per-session operating scope,
maintainer-gated additions, fail-closed to NOTHING when undeclared). Sessions share one dev App
identity; isolation is enforced by **code and scope, not identity**: per-session state namespacing
(R3), a durable **SESSION REGISTRY** (R27 — session-id, scope, container-id; the single source of
truth every session-aware actuator reads), disjointness checks before acting (R28), and the
per-session routing token on every bus message (R5). The host validates every session's tickets but
routes each outcome **only to its originating session**. Whole-container operations (rebuild) act on
**all resident sessions together** (R20); per-session control (HALT targeting) resolves through the
registry.

## A6. Three decoupled clocks on an immutable substrate

Immutable-host, containerise-everything. Three independent rebuild cadences: the **host image**, the
**dev container image** (monthly CI + on-merge), and the **claudebox** carrying claude-code (daily +
on-demand) — so the agent advances daily without destabilising the substrate. Durable truth lives in
exactly two places: **git** (the specs, the code, the law stamped into the box at every rebuild) and
the **home volume** (session state, the registry, credentials, caches) — everything else is
reproducible from spec. **Lifecycle continuity is a requirement, not luck** (R17): a purposeful
rebuild is KILL → REBUILD → RESTORE every session → RESUME (actively working) → VERIFIED, orchestrated
by the pair (A1).

## A7. The control plane — fail-closed gates, few human anchors

Safety is **structural at the boundary**: the boundary is always a gate's own fail-closed
verification, and the spec's mandated mechanical scans (the R6(b) red-line scan, R12's diff scan,
R21's forbidden-pattern gate, R22's cadence check) are **enforcement layers on top of it — never the
sole guard** (the anti-theater doctrine: a pattern-sieve alone is not a boundary). The standing
controls: the **per-session operating scope** (R16, A5) over the **maintainer-confirmed repo set**
(R7 — out-of-scope repos get no auto-merge, fail-closed); the **fleet HALT** (R9 —
maintainer-thrown, read at the top of every sweep, the one gate that deliberately fails toward
STOPPING; the hard stop is revocation of the single shared key); **liveness-bound locks** (R26 — a
dead or prior-generation holder is adjudicated and reclaimed, never deferred to); **merge trust**
(R6/R7: author ≠ judge across trust domains, verdicts postable only by the host validator identity,
sha- and base-bound per R25, server-enforced merge with no custom executor); and **recoverability
preserved by rule** (health-gate digest rollback + git revert; a change that removes rollback or
exfiltrates a credential fails review). The human appears at exactly these anchors: the one R1
confirmation, ESCALATE adjudications, and maintainer-bound controls (HALT, scope additions). Every
gate declares its **fail direction** deliberately: fail-safe toward progress by default, fail-closed
at trust boundaries, fail-toward-stop only for HALT.

---

# PART 2 — THE DESIGN AS IT STANDS

## D0. Design overview — the portions at a glance

The portions transcribed so far, in dependency order. The **ticket bus (D1)** is the pair's actuation
channel — everything below rides it. The **merge pipeline (D2)** ships every change; it works today
via the poller but deviates from the confirmed R7 architecture, and the deviation is named, not
hidden. **R17 rebuild continuity (D3)** is the host-orchestrated KILL→REBUILD→RESTORE→RESUME→VERIFY
lifecycle, live-proven single-tenant then completed multi-tenant by **assign-at-launch session
identity + resume-by-id (D4)** — where the build found the live process table already IS the registry
— with the **folder-trust pre-seed (D5)** closing the last resume gap.

| § | Portion | Status |
|---|---|---|
| **D1** | The pair + the ticket bus | `[BUILT]` |
| **D2** | The merge pipeline | `[BUILT — transitional toward R7]` |
| **D3** | R17 — rebuild continuity | `[BUILT]` |
| **D4** | Multi-tenant session identity + restore (R20/R27) | `[BUILT]` |
| **D5** | Folder-trust pre-seed | `[BUILT]` |

## D1. The pair + the ticket bus  `[BUILT]`

The ticket bus (A2) as built: a `host-task`-labelled GitHub issue in the control repo whose
**line 1** is `host-op: <verb> [args]`; the host's `host-agent-watch.sh` consumes it, performs the
**allowlisted** op, posts `host-agent: DONE|FAILED`, and closes it. The dev-side producer is
`bin/host-ticket.sh` (`--wait` blocks on the verdict; every ticket is stamped with the filing
session's id for per-session routing). Verbs are a fixed allowlist (`redeploy <workload>`,
`rebuild-devbox <devbox>`) — never free-form host operations.

## D2. The merge pipeline  `[BUILT — transitional toward R7]`

As built, merges are executed by the **dev-side poller** (`bin/pr-poller.sh` → `bin/auto-merge.sh`,
plain shell): it routes each open PR by (host live-gate verdict, fitness verdict), runs a bounded
fixer on RED/RETURN, and merges on host-GREEN + fitness-PASS re-checked fail-closed (G1
distinct-logins, G2 line-1 + full-head-sha binding, author ≠ judge, `--match-head-commit` pin,
dry-run unless armed). The independent fitness review runs as a **dev-side second App identity**
(`oso-gato-fitness-claudebox`).

**Deviation from the confirmed architecture, named:** R7 mandates **GitHub native auto-merge with no
custom merge executor** and both checks **postable only by the host validator identity**; R6 places
the judge **on the other trust domain (erebus)**; R25 additionally binds verdicts to the
**merge-base sha** with auto-voiding on base drift (not yet implemented — base-drift unmergeability
is the open #150 class); R5's per-session routing token is not yet on every verdict. The poller is
the working transitional mechanism that shipped the loop; converging it to R7/R6/R25 is architecture
work ahead, not a silent status quo.

## D3. R17 — Rebuild continuity  `[BUILT]`

**Requirement (R17 + R20 + R27):** a purposeful rebuild is a complete lifecycle — KILL → REBUILD →
RESTORE **every** session → RESUME (actively working, not merely present) → VERIFIED (live
read-back + every restored session alive, **by container ID never name**).

**Design — the host orchestrates from OUTSIDE** (per A1). Code inside the dev box dies at the KILL
step, so it cannot run the lifecycle. The host does the whole thing via podman: a container destroyed
**from the host** leaves no PID-namespace ghost, which an in-container `distrobox rm -f` cannot
avoid. The dev box's only job is to declare **what was running**.

- **Host executor** — the `rebuild-devbox` verb (fedora-bootstrap `host-agent-watch.sh`). Ticket
  line 1 `host-op: rebuild-devbox fedora-dev`; a session **manifest** rides in the body. It kills the
  container, rebuilds to spec, recreates each session, resumes it, and verifies. There is **no
  per-session rebuild** (R20): rebuild is whole-container, restoring all resident sessions together.
- **Author-gate `[BUILT — transitional toward R23]`:** the executor refuses a bot-authored ticket
  (issue author must be a human admin|maintain) — an implementation safety choice for a destructive
  verb, **not** a spec clause: R23 mandates that a merge to either apparatus repo **automatically
  arms** the matching refresh with **no human step**, so this gate is a residual that dissolving is
  required, not optional, on the way to full R23/R14 (human-interaction-count = 1).
- **Dev producer** — `bin/rebuild-request.sh` (fedora-dev). Enumerates what is running, composes the
  manifest + ticket, and — because of the author-gate above — **presents it for a maintainer to
  author** (a prefilled new-issue URL) rather than filing it itself.
- **Manifest grammar** — the cross-repo contract, PARSED not executed (A2), between
  `%%DEVBOX-MANIFEST-BEGIN%%` / `%%DEVBOX-MANIFEST-END%%` sentinels; one line per session; strict
  name/cwd allowlists (one bad line rejects the whole ticket).
  - **v1 `[BUILT]`:** `session <name> <cwd>` → resumed with `claude --continue` (cwd-scoped).
  - **v2 `[BUILT]`:** `session <name> <cwd> <sid>` → resumed with `claude --resume <sid>` (see D4).
    The `<sid>` is a strict fixed-width UUID (8-4-4-4-12 hex), validated byte-identically on both
    sides (producer `valid_sid` ≡ executor `parse_manifest`). v2 emission is behind a rollout gate
    (D4) so a 4-field line never reaches a not-yet-upgraded executor.

**Live-proven 2026-07-14:** a real `rebuild-devbox` killed the box, rebuilt it, recreated the `main`
session, and resumed `claude --continue` all the way back to the live conversation. The one gap
surfaced: Claude's first-run folder-trust prompt (see D5).

## D4. R20 / R27 — Multi-tenant session identity + restore  `[BUILT]`

**The reality.** The dev container is multi-tenant (A5). An operator SSH/moshes in and runs **N tmux
WINDOWS** in the shared `main` session; each window is a bash shell **or** an interactive claude
session. **Tenants = the claude windows.** They routinely **share a cwd** (`/home/core`).

**Why v1 is insufficient.** `session <name> <cwd>` + `claude --continue` resumes only the
**most-recent** session in a cwd, so N tenants sharing `/home/core` **collapse to 1** on restore.
Confirmed live (2 live tenants, same cwd). A design-level finding — the architecture (registry-backed
restore, A5) already called for identity; v1 shipped without it as the single-tenant MVP.

**The design — assign-at-launch.**
- **Identity is ASSIGNED, not discovered.** A live session's *self-generated* id is **not**
  recoverable from outside it — it is not in `/proc/<pid>/environ` (claude generates it *after*
  launch) and the process holds no open `<sid>.jsonl` fd. So a scanner cannot learn an
  *unassigned* id. Instead `bin/claude` (the launch wrapper) **mints a UUID** and launches
  `claude --session-id <uuid>`. *(Verified: `--session-id` assigns it; `--resume <uuid>` resumes it.)*
- **The live process table IS the registry `[design-level finding — built]`.** The design first
  reached for a separate registry *file* (`bin/claude` writes `{uuid, cwd, window, liveness}` on
  launch, releases on exit, a crashed entry reaped by liveness adjudication). The build found that
  unnecessary: because the uuid is *assigned on the argv*, it lands in the process's own
  `/proc/<pid>/cmdline`, and the cwd in `/proc/<pid>/cwd` — so the **running `claude` processes
  already ARE the registry**, with no file to write, no release-on-exit, and no liveness reaping (a
  dead tenant is simply *absent* from `/proc` — crash-safe by construction). This is strictly simpler
  and more robust than a file that can go stale; the assign-at-launch decision is what makes the
  once-dead-end `/proc` scan viable (it reads the *assigned* id, not the unknowable self-generated one).
  This scopes to what **restore** needs (identity + cwd + liveness); R27's fuller registry — the
  per-session *scope* the R16/R28 scope/HALT actuators (A5) read — is not in the cmdline and remains a
  separate concern for those portions, not retired by this finding.
- **Restore reads the live process table.** The producer (`bin/rebuild-request.sh`,
  `enumerate_claude_procs`) scans `/proc` for interactive `claude` tenants — reading the assigned
  `<uuid>` from the cmdline and the cwd from `/proc` — and emits `session <name> <cwd> <uuid>` per
  live tenant (excluding headless `claude -p` and subagents). The executor resumes each with
  `claude --resume <uuid>` in a recreated tmux window. Every tenant returns **by id**, even sharing a cwd.

**V2 rollout gate `[BUILT]`.** The 4-field by-id grammar is understood only by the upgraded executor
(fedora-bootstrap#143). Because the *running* host executor's deploy LAGS the merge (a host-apply),
v2 emission is behind `DEVBOX_MANIFEST_V2`, **default OFF**: by default the producer emits v1 3-field
lines, safe against any deployed executor (and even ungated, a 4-field line to a 3-field executor is a
*fail-safe REFUSE* — `parse_manifest` is validated before the kill, so no session is stranded, the
rebuild just does not fire). Flipped on in the fedora-dev deploy env once the host executor carries #143.

**Staging — executor-first** (the A1 consumer-before-producer convention), all landed:
1. `bin/claude` assign-at-launch `[fedora-dev #196, merged]`;
2. executor accepts the `<sid>` field + `--resume`, backward-compatible with v1's 3-field grammar
   `[fedora-bootstrap #143, merged]` — landed FIRST so a v2 manifest is never rejected;
3. producer emits the `<sid>` manifest from the `/proc` scan `[fedora-dev #197]`.

**Caveat.** `bin/claude` is baked into the image (`/usr/local/bin`), so the foundation takes effect
only after a fedora-dev **image rebuild + redeploy**, not instantly like a live-clone change — which
is also why the v2 gate defaults off until both halves are deployed.

## D5. Folder-trust pre-seed  `[BUILT]`

A restored (or fresh) interactive claude stalls on the first-run *"Is this a project you trust?"*
prompt — "restored but idle," which R17 RESUME forbids (surfaced live 2026-07-14, see D3). **Fix:**
pre-seed `~/.claude.json` `projects["<cwd>"].hasTrustDialogAccepted = true`
(+ `hasCompletedProjectOnboarding`) for each tenant cwd, so claude starts active. (The `-p`
non-interactive mode skips the prompt, but a restored session is a real TTY, so the config seed — not
`-p` — is the path. There is no fleet-wide managed-settings key to disable the prompt; trust is
per-path.) **Built** as `bin/seed-claude-trust.py` (atomic, idempotent — writes only when a flag
actually changes, so it never races claude's own `~/.claude.json` writes — and never raises), invoked
by `bin/claude` inside the launch enter for the session's own cwd `[fedora-dev #196, merged]`. python3
is present in-box (not at base), so the seed runs inside the box, not at the base wrapper level.

---

# PART 3 — THE JOURNEY (roads travelled · avoided · failed)

Findings land here with their evidence, classified **design-level** (a different design under the
same architecture) or **architecture-level** (profound — the frame itself had to move). An
architecture-level entry must cite the verified facts that forced it.

## This document's own first fact-check (2026-07-15)

The first draft of Part 1 was adversarially verified against the full `00-OBJECTIVES.md` +
`00-REQUIREMENTS.md` and **ten discrepancies were found — all one failure class: attributing to the
confirmed spec what only the BUILT machinery does** (the poller presented as the architectural merge
authority where R7 mandates native auto-merge with no custom executor; the dev-side fitness App where
R6 places the judge on erebus; the human rebuild author-gate where R23 mandates no-human-step arming;
head-sha-only binding where R25 adds the merge-base sha; "no local state" stated without R3's named
exception). **Lesson:** the architecture must be transcribed from the confirmed spec, never inferred
from the running system — the built state belongs in Part 2, tagged `[BUILT — transitional]` where it
deviates. This is why the preamble's grounding rule applies to this document itself.

## R17 rebuild continuity → multi-tenant restore (2026-07-14/15)

**Road travelled.**
- **v1 single-tenant producer** (`bin/rebuild-request.sh`, #191): enumerate tmux sessions →
  `session <name> <cwd>` → `claude --continue`. Byte-compat-tested against the executor's *real*
  parser; **live-proven** (a real rebuild restored the session). Correct for one session, and the
  right MVP to prove the host executor end-to-end before adding identity.
- **v2 multi-tenant** (all landed/landing): `bin/claude` assign-at-launch + folder-trust seed
  (#196, merged); executor 4-field `--resume <sid>` grammar (fedora-bootstrap#143, merged); producer
  `/proc` scan + `DEVBOX_MANIFEST_V2` gate (#197). The executor's *real* `parse_manifest` is embedded
  verbatim in the producer's test as the cross-repo parity oracle; the sid grammar is strict
  fixed-width UUID on both sides; both guards (sid + cwd) are in-suite mutation-proven.

**Roads that FAILED — dead-ends, do not re-walk (all design-level).**
- **`claude --continue` for multi-tenant.** It is cwd-scoped ("most recent conversation in this
  cwd"), so N tenants sharing `/home/core` collapse to 1. Fundamental, not a tuning issue → resume
  must be **by id**.
- **A `/proc` scanner to read an UNASSIGNED (self-generated) session-id.** `CLAUDE_CODE_SESSION_ID`
  is **not** in `/proc/<pid>/environ` (claude sets it *after* launch) and the process holds no open
  `<sid>.jsonl` fd. A sibling process **cannot** learn a self-generated id. Verified empirically (both
  live tenants read `sid=none`). *(This dead-ended reading an id the process never advertised — NOT
  the `/proc` scan itself, which is the chosen mechanism once the id is ASSIGNED on the argv; see
  "The chosen road" below.)*
- **Transcript-mtime mapping (pid → most-recent `.jsonl`).** Ambiguous when tenants share a cwd (all
  write to the same `~/.claude/projects/<slug>/`). Cannot reliably map pid → sid.

**Roads AVOIDED — considered, not taken.**
- **SessionStart/SessionEnd hooks (self-registration).** Would work (a session knows its own id from
  inside), but adds a dependency on claude hook config/reliability under managed-settings, and needs
  a filter to exclude headless `claude -p` / subagent runs. Avoided in favour of assign-at-launch
  (no hook dependency, id deterministic).
- **A separate registry FILE** (`bin/claude` writes `{uuid,cwd,window,liveness}` on launch, releases
  on exit, crashed entries liveness-reaped). Designed, then found unnecessary — see the finding below.

**The chosen road: assign-at-launch, and the process table IS the registry.** `bin/claude` mints the
UUID and passes `--session-id`; round-trip verified (`--session-id` assigns, `--resume` resumes). The
**design-level finding during the build:** once the id is assigned *on the argv*, it lives in
`/proc/<pid>/cmdline` and the cwd in `/proc/<pid>/cwd` — so the running `claude` processes already ARE
the registry. That **retired the planned registry file entirely**: no launch-write, no release-on-exit,
no liveness reaping (a dead tenant is simply absent from `/proc` — crash-safe by construction). The
same fact reopened the earlier "`/proc` scanner" dead-end as the *chosen* mechanism: the dead-end was
reading the *self-generated* id (impossible); reading the *assigned* one from the cmdline is trivial.
Simpler and more robust than the file it replaced. `enumerate_claude_procs` (#197) is that scan.

**A deploy-ordering finding (design-level, from the fitness gate).** The producer and the executor
ship in different repos on independent deploy clocks, and fedora-dev's `bin/claude` already assigns
session-ids on `main` — so a 4-field manifest could reach a *running* host executor that has not yet
deployed the 4-field grammar. Verified fail-safe (the executor validates the manifest BEFORE the kill,
so a rejected 4-field line REFUSES the rebuild rather than stranding sessions), but made moot by design:
v2 emission is gated behind `DEVBOX_MANIFEST_V2`, **default OFF** (D4), so the producer never hands a
not-yet-upgraded executor a line it would reject. The gate is flipped once the host executor is
confirmed on #143 — the consumer-before-producer (A1) convention, enforced in code rather than by hope.

**An architecture-level precedent (2026-07-13, pre-dating this doc).** R17 was first declared
"unbuildable as written" because code inside the claudebox dies at the KILL step — a conclusion
scoped to the component instead of the SYSTEM. The maintainer's correction ("the pair is the
orchestrator"; move the actor to the host) is now architecture A1. The evidence that grounded it:
the ticket bus already worked dev→host, and a host-side kill provably leaves no PID-namespace ghost
where an in-container teardown provably does.

## Supporting merge-loop incidents (2026-07-14) — surfaced while landing the R17 work

- **The fitness-login separation-of-duties bug (#192).** A strict-SoD arm (`FITNESS_SAME_IDENTITY=0`)
  with `FITNESS_LOGIN` unset let the poller default the *reviewer* login to the **dev** identity, so
  the author≠judge guard refused **every** review → all auto-merges blocked fleet-wide. Fix: default
  `FITNESS_LOGIN` to the fitness App under strict mode. **Lesson:** a make-it-work default that is
  only correct for one mode is a latent trap in the other.
- **The distrobox-enter restart race.** After a container restart, the entrypoint's supervise-loop
  `distrobox enter` hung in `podman logs -f` waiting for a setup sentinel that had already scrolled
  past its `--since` window → the poller + deadman never launched. Recovery: kill the stuck enters;
  the loops relaunch fresh against the ready box. **Lesson:** a restart can strand services in the
  enter-wait; R17's clean, host-orchestrated lifecycle is the durable fix.
