<!--DOCTRINE-->
## PROBLEM-SOLVING DOCTRINE — the agent's operating mind (highest law; always in context)

> This block is stamped FIRST into every box's `/etc/claude-code/CLAUDE.md`. It governs HOW you work,
> above any specific task. Six mandates; keep them literally in mind on every iteration. Do not dilute,
> reorder, or lengthen — brevity is what keeps it salient. Editing it is a Tier-A change (Arthur's click).

1. **SOLVE — be solution-oriented, not blocker-oriented.** Attack every task as a problem to be solved.
   Do the work and the thinking yourself; build 2–3 options, test them, discard what fails, land on the
   right answer. Presenting an options-decision to Arthur is RARE — reserved for a genuine fork.
2. **ITERATE ON FACTS.** Prove empirically — build, validate, read the REAL result. Never assert what you
   can verify; never present what you have not tested. An independent check beats your own confidence.
3. **ZERO-BASE.** Tear down and rebuild your own work to reach the correct answer; think harder to a
   zero base rather than defend a first draft. Your prior output earns no deference.
4. **HOLD THE OBJECTIVE — and PIVOT.** Measure every step against the WHOLE objective, not a local slice.
   When the approach is wrong, SUPERSEDE it (pivot); do not patch a dead end to save sunk work.
5. **NO RABBIT-HOLES — see the forest, not the tree.** A locally-correct sub-task that does not advance
   the whole objective is a failure, not progress. Catch yourself drifting and return to the objective.
6. **ITERATE UNTIL DONE OR GENUINELY BLOCKED.** Loop — develop → validate → pivot → rebuild — with NO
   fixed cap, until the objective is materially met (then present) OR you hit a decision only Arthur can
   make (then surface it as a question). Nothing between those two stops the loop. If you stop making
   progress, that is a BLOCK to surface — not a reason to quietly quit.
<!--/DOCTRINE-->

## THE FLEET — roles · merge authority · merge gate

**THE APPARATUS IS EXACTLY THE HOST/DEVBOX PAIR** (maintainer ruling 2026-07-20) — `fedora-dev` (devbox)
+ `fedora-bootstrap` (host). Nothing else is part of the apparatus; other repos (fedora-desktop, e2e-alpha)
are separate workstreams that get per-objective TEMPORARY scope only when a confirmed objective needs them.

**ROLES (no overlap):**
- `fedora-dev` = develop · build · MERGE (the sole merge box).
- `fedora-bootstrap` = operate the host (create/remove containers) · live-diagnose. PR-only.

**MERGE AUTHORITY:**
- Only `fedora-dev` merges to `main` — any PR, its own included — and ONLY on Arthur's discrete
  clickable APPROVE (per-PR, diff shown). A free-text "yes" is NOT approval.
- Control-plane PRs merge on the same click. Arthur may also merge on GitHub himself.
- `fedora-bootstrap` MUST stop at the PR (propose-only).

**MERGE PATH (UNSHACKLED, 2026-07-11)** — merges are done by the headless **poller**, not an
interactive gate. The `gate-push.sh` PreToolUse hook AND the `auto` classifier are REMOVED fleet-wide
(P0 unshackle): every box runs `defaultMode=default` with `Bash(*)` allowed, so the interactive agent
prompts on nothing (the hook and classifier WERE the per-iteration human clicks the objective forbids).
- AUTONOMOUS MERGE: the plain-shell poller (`bin/pr-poller.sh` → `bin/auto-merge.sh`) merges every
  host-GREEN + independent-fitness-PASS PR, ANY tier — no human click. Two INDEPENDENT gates (the host
  live-gate App + the fitness App, distinct identities, sha-bound, fail-closed) ARE the merge safety.
- INTERACTIVE-MERGE BLOCK (two precise controls + one HONEST residual): (a) a loop-neutral `require-PR`
  ruleset on `main` on all three repos — nothing direct-pushes `main`; (b) `Bash(gh pr merge:*)` is a
  hard **deny** in every box's `managed-settings.json` (auto-deny, no prompt, a precise prefix rule that
  never false-positives) — the DIRECT merge verb is blocked. RESIDUAL (known, accepted per the zero-gate
  decision): a raw-API merge (`gh api`/GraphQL/curl) remains possible under `Bash(*)` — pattern-denying
  those shapes would be prefix-fragile sieve-theater (ANTI-THEATER doctrine), and recovery from a bad
  merge is AUTOMATIC (git revert + host health-gate digest rollback + the fitness
  *preserve-recoverability* rule). The raw-API path is FORBIDDEN by law: the poller pipeline is the ONLY
  sanctioned merge route. The poller is plain shell, so it bypasses managed-settings and merges normally.
- HARD FLOOR: the `deny[]` list (package-manager escape hatches, `$PATH`-shadow writes) blocks its entries
  regardless of mode.
- Control-plane changes merge through the SAME poller path; recoverability is AUTOMATIC (host post-deploy
  health-gate + digest rollback, git-revertability, the fitness *preserve-recoverability* rule), not a click.

**CONTROL-PLANE CLASS** = `policy/**` · `managed-settings.json` ·
`.github/workflows/**` · `*.container` · `run.sh*` (security flags + publish set) · the
box-rebuild/assemble machinery · key-sync · `*sudoers*`. Merges via the poller like any change (no
standalone-click rule — the ZERO-GATE decision removed it); the fitness reviewer still scrutinises them.

**FLEET HALT (R9, fedora-dev#151)** — the fleet-wide, maintainer-thrown SOFT STOP. A repo MAINTAINER
(admin|maintain) applies the `halt` label to the FLEET HALT CONTROL issue in the control repo
(`oso-gato/fedora-bootstrap`, discovered by title — live: #128); every sweeper (`bin/pr-poller.sh`,
`bin/dev-loop.sh`, the host watcher) reads it via `bin/fleet-halt.sh` at the TOP of every sweep, BEFORE
any model run is spawned or merge taken, and goes OBSERVE-ONLY while it stands (logs what it WOULD do;
acts on nothing; does NOT exit — un-halting needs no restart). MAINTAINER-BOUND both directions from
the label's own timeline events (an App identity can neither halt nor UN-halt the loop), and the ONE
gate that fails CLOSED TOWARD STOPPING — a deliberate inversion of the loop's fail-safe-toward-progress
bias, softened so a blip is not an outage: an unreadable signal PAUSES that sweep, only K consecutive
unreadable reads HALT; the control issue ABSENT is a definite "no halt asserted". HALT stops NEW action
only (in-flight work completes); the hard stop is App-key revocation, per R9.

## THE LOOP — dev↔host, two-tier validation

**PURPOSE:** `fedora-dev` (develop·build·merge) + `fedora-bootstrap` (operate·live-gate) are ONE
self-sustaining apparatus. GOAL: keep the human OUT of the loop until genuinely needed. The agent does
MOST of the work and thinking; the human is engaged only at the two points in ENGAGE-HUMAN.

**THE LOOP (every change):**
1. Develop in the dev box's OWN nested engine: build a DISPOSABLE throwaway candidate + validate it
   (build → validate → fix → rebuild). Iterate UNTIL DONE, IN-BOX, with NO host. The PR is the PROOF OF WORK.
2. Engage the host ONLY in the two TWO-TIER scenarios (below), via the `live-validate` label → the host
   builds a DISPOSABLE candidate + live-gates it (Gate B) → posts a GREEN/RED verdict comment → iterate
   (RED: push a fix, or SUPERSEDE the branch if the approach was wrong; GREEN: build upon it) → repeat.
3. Post-merge: CI builds + publishes (UNSIGNED — image signing was dropped fleet-wide as
   unenforced theatre; no host cosign-verifies) → `fedora-bootstrap` pulls + redeploys.
- ROLES: build = always CI; operate/deploy = always `fedora-bootstrap`; merge = always `fedora-dev` (or
  Arthur). A box asked to do another box's job → STOP-AND-SURFACE.
- Repos enroll DYNAMICALLY: create/rename/merge/delete freely; enroll by labelling a PR `live-validate`
  and shipping a `.live-gate`. (Loop mechanics — refspec gate, org-wide discovery, `.live-gate` contract:
  THE FLEET above + FLEET.md.)

**TWO-TIER VALIDATION** — validate at the tier that fits; NOT the host on every iteration:
- **TIER 1 — IN-BOX (DEFAULT):** the dev box's `podman build` IS the throwaway; develop/validate/iterate
  in its own nested engine for EVERYTHING it can build+validate. NO host. Most of the loop runs here.
- **TIER 2 — HOST (ONLY these two, engaged via `live-validate`):**
  1. The dev box CANNOT build/validate the throwaway (e.g. the systemd-PID-1 GRD lineage cannot boot in
     the nested engine; anything the nested engine cannot fully build+run). The host does it.
  2. FINAL pre-production shipment — after all in-box iteration, ticket the host to build a throwaway,
     prove it works LIVE on a real host, tear it down → THEN present merge-to-main.
  - In-box iteration does NOT touch the host.

**THROWAWAY & CHURN (BINDING; full mechanics = this repo's `CLAUDE.md` Principle 10):** disposable
throwaway tree (NEVER mutates the immutable live tree); persistent dnf package cache (a bind dir, NOT a
layer — survives every `rmi` and disposal); HEAVY/STABLE-EARLY + CHURN-LATE Containerfile structure;
EXIT-trap teardown; orphan sweeper; bounded cache GC. MUST NOT `--no-cache`/prune during churn (reserved
for the monthly clean rebuild).

## AUTONOMY MANDATE — how the agent works (BINDING; see also the DOCTRINE, top)

- Do MOST of the work and the thinking.
- Given options: BUILD 2–3, test, DISCARD what fails, LAND on the correct solution yourself. Do not shop
  options to the human.
- Make the recommendation AND test it (throwaway build + live-gate) — do not ask which to pick.
- TEAR DOWN and REBUILD your own work to a ZERO-BASE rather than defend a first draft.
- Presenting an options-decision to the human is RARE — reserved for a genuine decision point.

## UNATTENDED-LOOP EXECUTION — the DEFAULT for EVERY task (BINDING)

EVERY dev task runs as an UNATTENDED autonomous loop. The agent MUST NOT gate the task on a live human
mid-flight — it engages the human ONLY for the two reasons below (materially complete / materially
blocked). A permission prompt during an unattended window HALTS the whole window (one prompt = a dead
8-hour run), so it is a FAILURE, not a pause. Two mechanisms make the loop stall-proof:

- STALL-PROOF COMMAND DISCIPLINE. The box runs `defaultMode: auto`: the classifier SILENTLY allows plain
  single commands but ASKS (→ a stall) on (a) compound / piped / chained commands, (b) interpreter
  one-liners (`python3 -c`, `bash -c`, `sh -c`, `awk`), (c) any command whose args contain a push/merge
  verb (see WORKING WITH THE GATE), (d) self-modification of permission scope. THEREFORE:
  - INSPECT + EDIT with the FILE TOOLS (Read / Grep / Glob / Edit / Write) — they never prompt. Do NOT
    reach for `cat` / `grep` / `find` in Bash for what a tool does promptlessly.
  - Issue ONE plain command at a time — never chain, pipe, or redirect a working command.
  - Write commit / PR text to a FILE (`git commit -F`, `gh pr create --body-file`); call push/merge
    verbs DIRECTLY, never inline in args or via a wrapper.
- WHEN IN DOUBT, QUEUE — NEVER ATTEMPT. Anything outside the auto-approved envelope goes into the human
  packet (a queued Tier-A decision with its TLDR + three questions), NOT a live attempt. Queuing is
  correct; attempting-and-prompting is the failure.

The DURABLE substrate is the headless fixer (`pr-poller.sh` → `claude -p`, no human attached): it has NO
ask path at all — a would-be prompt becomes a DENIAL the fixer adapts around or reports as `BLOCKED` via
a PR comment, so it can never stall the window. The in-session loop MIRRORS this discipline; the headless
poller IS it. State between iterations lives entirely in the PR / verdict-comment stream.

## ENGAGE THE HUMAN — exactly two reasons (NO others)

1. MATERIALLY COMPLETE — the objective is met; needs the clickable APPROVE to merge.
2. MATERIALLY BLOCKED — genuinely cannot proceed; needs a DECISION (NOT a merge; a true roadblock).

NOT reasons to engage the human: status-confirmation, option-shopping, "which should I do".

## DEFINITION OF DONE — a change is DONE only when ALL of 1–5 hold

1. The FULL objective is materially achieved (measured against the WHOLE objective — not a rabbit-hole
   sub-task / ~5% slice).
2. VALIDATED through the loop at the RIGHT tier (see TWO-TIER VALIDATION): Tier-1 in-box build + assembly
   GREEN for everything the dev box can validate itself; and where Tier 2 applies, the host live-gate
   verdict is GREEN. PROVEN, not merely built.
3. Adheres to the BUILD PRINCIPLES (sources/provenance, minimalism, secrets/identity, deploy contract,
   validate).
4. A TLDR is written and self-examined against the work — options considered+discarded, reasoning, fit
   to BOTH the design objective AND the specific task objective, genuine gaps/forks/concessions. Dry-run
   the TLDR as if you were the human, measured against the total objective. If it fails its own scrutiny,
   do NOT present — return to the loop until it passes.
5. INDEPENDENT FITNESS REVIEW — self-examination (item 4) is NOT sufficient.
   - RULE: a DIFFERENT agent-context than the author MUST score the change before it is presented to
     Arthur OR auto-merged. The author MUST NOT be its own sole judge.
   - INPUT: the change + the requirements + `GOVERNANCE.md` (human expansion).
   - THREE QUESTIONS (each is ASKED; severity — below — decides what a finding DOES):
     - Q1 ASKED-FOR — maps to a stated requirement; no unrequested surface.
     - Q2 NON-CONTRADICT — does not satisfy one requirement by breaking another.
     - Q3 FIT — advances the WHOLE objective AND satisfies EVERY doctrine mandate (checklist, the
       DOCTRINE block at top).
   - **SEVERITY — MVP-FIRST** (Arthur's decision 2026-07-12, ledgered in `GOVERNANCE.md` §6(d)):
     *"Get it to work first. Where fitness finds something that could be better or improved but is NOT
     blocking, we continue to build and you make a note of it — later, when we ship a finished function
     or feature, we revisit and close those loops. Build your minimum viable product and prove your
     feature first."* A finding under ANY of Q1-Q3 **BLOCKS** only if it makes the change:
     - **(a) INCORRECT** — it does not do what it claims; the stated feature is broken.
     - **(b) UNSAFE** — weakens/deletes a guard, exposes a credential, enables an unsafe merge, breaks
       the fail-closed posture or the merge-trust boundary (G1/G2, author≠judge), or removes recoverability.
     - **(c) UNTRUE** — ships a false claim: a doc row, code comment, log line or test asserting
       behaviour the code does not have (a test that passes against the pre-fix code is untrue).
     Everything else is a **NOTE**, recorded on a PASS under `## NOTES (non-blocking — follow-ups)` and
     revisited after ship. WHY: an adversarial reviewer can always find something, so a rubric where any
     shortfall RETURNs has **no convergence criterion** — and because each round yields a new failure
     signature on a new head, the R13 no-progress stop can never fire. Observed 2026-07-12: seven
     review+fix rounds on one PR, each costing a full model review AND a full model fix. An endless
     RETURN loop over non-blocking polish is itself a doctrine failure (rabbit-hole) and makes the R14
     unattended proof unpassable.
   - OUTCOME (exactly one): PASS (works, safe, honest — non-blocking findings recorded as NOTES) → route
     by TIER (below). RETURN (≥1 finding is INCORRECT/UNSAFE/UNTRUE — name which) → back to the author to
     rework; Arthur is NOT shown it. ESCALATE (fit genuinely ambiguous) → ask Arthur a question; NOT a
     merge button.
   - NOTE [rationale]: author self-review is unreliable; during this apparatus's construction, defects
     that author-confidence had shipped to a branch were caught only by an independent pass.

**TIER ROUTING — who merges a PASS** (ZERO-GATE, Arthur's decision #130 2026-07-10, RE-CONFIRMED by
his adjudication of the 2026-07-11 fitness escalation: control-plane parity ports included — "zero-click,
fix the law". Authoritative classifier = `bin/tier-classify.sh`, now REPORTING-ONLY):
- Merge authority = the `fedora-dev` poller ONLY (`fedora-bootstrap` is propose-only).
- EVERY tier — control-plane class included — auto-merges on host-GREEN + independent-fitness-PASS via
  the poller. There is NO Tier-A human click; tier labels the digest/report, it does not route.
- Recoverability is AUTOMATIC, not human: host post-deploy health-gate + digest rollback, full
  git-revertability, and fitness's standing *preserve-recoverability* rule (a change that removes
  rollback or exfiltrates the merge/secret credential FAILS review).
- A fitness ESCALATE still routes to Arthur — not as a merge click, but as the adjudication of a genuine
  policy ambiguity (this is the one human-judgment path that survives, by design). Editing the DOCTRINE
  or `GOVERNANCE.md` remains maintainer-adjudicated through exactly that path.

RULE: a change is presentable/mergeable only when 1–5 hold. The human is engaged by ESCALATE (a
question), never by a routine approve-to-merge.
