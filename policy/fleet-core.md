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

**ROLES (no overlap):**
- `fedora-dev` = develop · build · MERGE (the sole merge box).
- `fedora-bootstrap` = operate the host (create/remove containers) · live-diagnose. PR-only.
- `fedora-desktop` = own knowledge-work toolset. PR-only.

**MERGE AUTHORITY:**
- Only `fedora-dev` merges to `main` — any PR, its own included — and ONLY on Arthur's discrete
  clickable APPROVE (per-PR, diff shown). A free-text "yes" is NOT approval.
- Control-plane PRs merge on the same click. Arthur may also merge on GitHub himself.
- `fedora-bootstrap` + `fedora-desktop` MUST stop at the PR (propose-only).

**MERGE GATE** — the managed `gate-push.sh` PreToolUse hook + `managed-settings.json` are the SOLE
control plane (refspec-aware, fail-closed, in-session):
- AUTONOMOUS (no prompt): a feature-branch push — an explicit non-`main`, non-`HEAD`, non-tag
  destination refspec.
- GATED: any push that could touch `main` (a bare `git push`; a `main`/`HEAD`/`refs/tags/*`
  destination; `--all`/`--mirror`/`--tags`; any unparseable/quoted/chained target) PLUS the merge verbs
  (`gh pr merge`; `gh pr create --merge|--squash|--rebase|--auto`; `gh api …/merge|/merges`).
- GATED ROUTES TO: on `fedora-dev` → an in-session clickable `ask` (only Arthur answers); on
  `fedora-bootstrap` + `fedora-desktop` → an in-session `deny`.
  - EXCEPTION (`fedora-desktop` only): its automatic vault git-sync `git -C <vault> push` is allowed.
- No approval-marker mechanism — native `ask`/`deny` only; nothing reaches `main` without Arthur's
  out-of-band click (prompt-injection cannot fake it).
- SERVER FLOOR: a loop-neutral `require-PR` ruleset on `main` (no required reviews or status checks) is
  active on all three repos — it forces every change through a PR, closing the headless `claude -p` path
  that in-session hooks cannot catch.
  - NOTE [rationale]: `main` carries no required-review branch protection and no CI label-gate beyond
    this thin floor — in a single-operator fleet those layers added friction without proportional value;
    the click already gates every merge.
- Control-plane changes MUST stay STANDALONE (never bundled) and be FLAGGED in the merge TLDR.

**CONTROL-PLANE CLASS** = `policy/**` · `managed-settings.json` · `policy/hooks/gate-push.sh` ·
`.github/workflows/**` · `*.container` · `run.sh*` (security flags + publish set) · the
box-rebuild/assemble machinery · key-sync · `*sudoers*`. MUST be standalone, never bundled.

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
3. Post-merge: CI builds + signs + publishes → `fedora-bootstrap` pulls + redeploys.
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
   - THREE QUESTIONS (all must pass):
     - Q1 ASKED-FOR — maps to a stated requirement. Else → scope-creep → RETURN.
     - Q2 NON-CONTRADICT — does not satisfy one requirement by breaking another. Else → RETURN.
     - Q3 FIT — advances the WHOLE objective AND satisfies EVERY doctrine mandate (checklist, the
       DOCTRINE block at top). Any mandate violated → FAIL Q3 → RETURN.
   - OUTCOME (exactly one): PASS (all three) → route by TIER (below). RETURN (Q2 or Q3 fails) → back to
     the author to rework; Arthur is NOT shown it. ESCALATE (fit genuinely ambiguous) → ask Arthur a
     question; NOT a merge button.
   - NOTE [rationale]: author self-review is unreliable; during this apparatus's construction, defects
     that author-confidence had shipped to a branch were caught only by an independent pass.

**TIER ROUTING — who merges a PASS** (authoritative boundary classifier = `bin/tier-classify.sh` (code,
fail-closed); human expansion = `GOVERNANCE.md` §3):
- Merge authority = `fedora-dev` ONLY (`fedora-bootstrap` + `fedora-desktop` are propose-only, gate → deny).
- TIER A → Arthur's click, preceded by an independent ADVERSARIAL pass (Stage 3 — an agent tries to
  *break* it; repeats until clean). Tier A = control-plane class + live-host-apply-without-auto-rollback
  + hard-to-undo. Editing `GOVERNANCE.md` or the DOCTRINE is itself Tier A.
- TIER B/C → `fedora-dev` auto-merges under the fitness gate, digest-reported, no human = reversible /
  non-boundary / docs.

RULE: only when 1–5 hold does a change go to the human (reason: approve-to-merge). The TLDR is the final
step before the human.
