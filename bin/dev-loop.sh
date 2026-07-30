#!/usr/bin/env bash
# dev-loop.sh — the DEV-LOOP DRIVER (apparatus spec fedora-dev#135 work-plan P3).
#
# The plain-shell driver that closes the human out of the per-feature loop: it enumerates the OPEN
# `backlog`-labelled feature issues the planner produced (R2) and runs the autonomous feature-author
# (`bin/dev-author.sh`, R3) over each one. The author isolates a worktree, implements with a bounded
# `claude -p`, gates in-box, and opens a `live-validate` PR that the existing host-live-gate → fitness →
# poller pipeline ships — so the driver writes NO build, validate, or merge logic; it only SEQUENCES the
# author across the backlog. It is to dev-author what poller-service is to pr-poller.
#
# THE PLAN ARM — HOW AN OBJECTIVE BECOMES A BACKLOG (added after the fitness RETURN on d339476). Until
# now this driver started at the backlog and NOTHING in the fleet ever invoked `bin/dev-plan.sh`: the
# planner — the one component that enforces R1, the maintainer's confirmation of an objective — was
# built, tested, and unreachable. `grep -rn dev-plan bin/*.sh` found no caller, only prose. That is the
# gap the intake front door fell into: an objective filed as `backlog` would have been swept by the arm
# BELOW straight into `dev-author` → PR → auto-merge, so an UNCONFIRMED objective became merged code and
# the maintainer's `approved` tap was never read by anything. So each pass now does the step upstream of
# its own backlog first:
#
#     open issues labelled BOTH $INTAKE_LABEL (`objective`) and $APPROVED_LABEL (`approved`)
#         → bin/dev-plan.sh <repo> <n>  → `backlog` feature issues → the arm below authors them.
#
# THE LABEL FILTER IS DISCOVERY, NOT AUTHORISATION — and that distinction is the whole trust boundary.
# Applying a label needs only triage/write, which every fleet App identity holds, so this query alone
# would be self-authorising. It is not the gate: `dev-plan.sh` independently resolves WHO applied
# `approved` (the last `labeled` timeline event) and binds that actor to admin|maintain, refusing
# anything else. This arm can therefore only ever OFFER an objective to a gate it does not control —
# a label the loop applied to itself buys it nothing.
#
# AN OBJECTIVE THE PLANNER STOPPED ON IS PARKED, exactly like a blocked backlog issue: `dev-plan.sh`
# comments its own refusal/BLOCKED reason on the issue, and while that comment is the NEWEST one the
# objective is not re-offered — otherwise a non-maintainer's `approved` label (or one transiently
# unfetchable timeline read) would re-post the identical refusal every LOOP_INTERVAL forever, the silent
# spin R4 forbids. A reply un-parks it, and the refusal itself tells the maintainer what to do.
# (The R39 bounded release below is deliberately NOT wired to this park yet — a planner park is
# overwhelmingly "a human must tap the label properly", which no automatic re-attempt can change.
# Extending the clock to this arm is a follow-up, recorded here rather than half-built.)
#
# It is DETERMINISTIC and idempotent by construction:
#   * discovery is one `gh issue list --label backlog --state open` (no local list to maintain);
#   * dev-author's own per-(repo,issue) marker + "is there already an open PR?" guard make a re-run a
#     no-op for anything already authored — so the loop can run on a timer without double-authoring;
#   * a BLOCKED/no-progress author surfaces a dev-task question on its issue and the driver moves on
#     (one stuck feature never blocks the rest); the human is engaged only by those questions (R13).
#
# NO LOCAL STATE — THE DRIVER HOLDS NONE (spec #135's design law: *no local state anywhere — every
# component resumes by re-reading GitHub*; R5: issues/PRs are the sole IPC, WAL and audit log; R14's
# E2E-KILL: both boxes killed mid-work must resume FROM THE BUS ALONE). Every fact this driver acts on is
# re-derived from GitHub each pass: the backlog from the label query, and PARK STATE from the issue's own
# COMMENT STREAM (below). Kill the box, wipe its disks, run the sweep from another box — the behaviour is
# identical, because there is nothing local to lose.
#
# THE CAP BOUNDS AUTHOR RUNS, NOT THE ENUMERATION (this is load-bearing). `dev-author` leaves an
# authored issue OPEN and still `backlog`-labelled — it closes only when the PR merges (`Closes #N`) —
# and it exits a cheap no-op for anything already authored. So truncating the SORTED backlog to the
# first MAX_PER_PASS numbers would spend the whole cap re-skipping the lowest issues while their PRs are
# in flight, and the tail would NEVER be offered: with a stalled PR (RED / closed / parked) holding a
# slot, that is permanent STARVATION, not deferral. Instead the driver walks the WHOLE backlog and
# counts only the runs that actually SPAWN a bounded model run; an in-flight skip costs no slot.
#
# PARKING, DERIVED FROM THE BUS (never from a local marker). An issue whose author run surfaced a
# question must not be re-offered every pass — that would re-spend a bounded model run, re-ask the
# identical question into noise, and (counting toward the cap) hold a slot forever. The record of that
# fact is the QUESTION ITSELF: `dev-author`'s surface_blocked() posts a comment whose LINE 1 is the
# machine-owned anchor $BLOCKED_ANCHOR. So park state is a pure READ of the issue's newest comment:
#
#     PARKED  ⟺  the NEWEST comment on the issue is a $DEV_LOGIN-authored, line-1-anchored dev-author
#                question — i.e. a question is open and NOBODY has replied to it yet.
#     ACTIVE  ⟺  anything else — no comments, a later reply from a human (the answer), a later comment
#                from anyone at all, or no question ever posted.
#
# UN-PARK = REPLY ON THE ISSUE. The issue thread IS the bus (R5), and a reply is the one unambiguous,
# machine-readable "answered" signal; answering a question by commenting on it is what a human does
# anyway. (A silent edit of the issue BODY does not un-park — deliberately: the previous design keyed on
# `updatedAt`, which a bot's own comment also bumps, making "was it touched?" unreadable without a local
# stamp to compare against. Reading the comment stream needs no stamp, hence no local state.)
#
# …AND THE PARK NOW HAS A BOUNDED RELEASE (R39 gate resilience, #277). A reply was previously the ONLY
# way out: a machine that had stopped and could not restart, i.e. a phone call to the maintainer. But a
# large share of what parks an issue never needed a human at all — dev-author rc 3 (worktree), 7 (push)
# and 8 (PR-create) are ENVIRONMENTAL, and they park exactly like a genuine design question does. So the
# park is now run through bin/stop-release.sh's three-state clock, per issue:
#
#     HOLD      inside the cool-off ($PARK_COOLOFF) — parked, silent, cheap, re-read next pass.
#     RELEASE   the cool-off elapsed and budget remains — announce it on the bus, then RE-OFFER the
#               issue to dev-author on this very pass (a re-attempt is the release; #177 means the
#               author reads the thread, so it sees both the old question and this announcement).
#     ESCALATE  $PARK_MAX_RELEASES releases are spent — tell the maintainer ONCE and stay parked.
#
# THE BUDGET LIVES ON THE BUS, NOT ON DISK (the no-local-state law, unbroken). Each release posts one
# $RELEASE_ANCHOR-anchored comment, and "releases so far" is a COUNT of those comments in the thread —
# so a wiped box resumes with the same budget, and a release that could not be ANNOUNCED is not taken
# (no record ⇒ no bound ⇒ a re-attempt every pass, the silent spin R4 forbids: it HOLDS instead).
# The escalation comment is itself a park anchor — it is a question, and a reply un-parks it like any
# other. The budget is per-issue lifetime: a human reply gets its author run through the ordinary ACTIVE
# path, and does not refill the AUTOMATIC budget.
#
# HELD-TIME COMES FROM AN EXTERNAL CLOCK (R24 no-proxy): the parking comment's own `createdAt`, read
# fresh each pass, so a restart cannot reset it. An unreadable age HOLDS and says so loudly — it never
# releases on a broken clock (bin/stop-release.sh's disclosed residual, made visible here).
#
# IDENTITY-BOUND (the auto-merge G2 discipline, as in dev-plan's confirmation gate): the anchor acts only
# on LINE 1 (a quoted or mid-prose token is inert) and ONLY from $DEV_LOGIN — the dev box's own App
# identity. A stranger pasting the marker into a comment on a public repo must not be able to freeze a
# feature out of the backlog forever.
#
# FAIL-SAFE TOWARD ACTIVE — never toward a silent drop. Anything unreadable (a failed list, an empty
# login, a question dev-author could not post because the comment API failed) reads as ACTIVE, so the
# issue is RE-OFFERED. We would rather re-ask a question than strand a feature nobody was ever told
# about. (This is strictly better than the marker it replaces: a marker parked the issue even when the
# question had FAILED to post — silently dropping the feature with no human ever told.)
#
# NO SOFT STOP GATES A PASS. The maintainer-thrown HALT label was RETIRED 2026-07-30 (R9) on its own
# record: 0 maintainer throws ever, 935 false self-fires, 338 real actions suppressed. Stopping the
# authoring loop is now App-key revocation or stopping the container — both stronger, neither needing
# this loop's cooperation or a readable GitHub.
#
#   dev-loop.sh <repo> [--once]   plan the approved objectives, then drive the backlog for <repo> —
#                                 ONE full pass, then exit
#   dev-loop.sh --watch <repo>    supervised loop (flock singleton): one pass every $LOOP_INTERVAL s;

#   dev-loop.sh --selftest        exercise the pure helpers (no gh / author / network)
#
# ENV: ORG (default oso-gato); BACKLOG_LABEL (default backlog); DEV_AUTHOR (default the sibling
#      bin/dev-author.sh, overridable for the mock test);
#      INTAKE_LABEL (the label bin/intake-file.sh files an objective under, default objective) +
#      APPROVED_LABEL (the maintainer's confirmation label, default approved) + DEV_PLAN (default the
#      sibling bin/dev-plan.sh, overridable for the mock test) + MAX_PLANS_PER_PASS (cap on PLANNER runs
#      spawned per pass, default 2 — a planner run is a bounded model run, and an objective the planner
#      already handled costs no slot);
#      MAX_PER_PASS (safety cap on author RUNS SPAWNED per pass, default 5 — a runaway-planner backstop;
#      skips and parked issues cost no slot); DEV_LOGIN (the dev box's App identity, whose questions the
#      park gate trusts — default oso-gato-nox-claudebox, the same bare comment-author form the poller's
#      FITNESS_LOGIN uses; empty ⇒ parking is DISABLED, every question re-offered, never dropped);
#      test); LOOP_INTERVAL (seconds between --watch passes, default 300 — authoring cadence, not the
#      poller's 10 s: each pass may spawn bounded model runs); DEV_LOOP_LOCK (the --watch singleton lock,
#      default ${XDG_RUNTIME_DIR:-/tmp}/dev-loop-watch-<repo>.lock — tmpfs, never $HOME: the driver
#      keeps NO local state);
#      PARK_COOLOFF (seconds a parked issue holds before a bounded release, default 21600 = 6 h — long
#      enough that a human usually answers first, so the release is the EXCEPTION not the cadence);
#      PARK_MAX_RELEASES (bounded automatic re-attempts per issue, default 2; 0 declares "this stop has
#      no automatic release" and escalates on the first check); STOP_RELEASE (the bounded-release
#      library, default the sibling bin/stop-release.sh).
set -uo pipefail

ORG="${ORG:-oso-gato}"
BACKLOG_LABEL="${BACKLOG_LABEL:-backlog}"
MAX_PER_PASS="${MAX_PER_PASS:-5}"
DEV_LOGIN="${DEV_LOGIN-oso-gato-nox-claudebox}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DEV_AUTHOR="${DEV_AUTHOR:-$HERE/dev-author.sh}"
# THE PLAN ARM (see the header). $INTAKE_LABEL must stay DISTINCT from $BACKLOG_LABEL — an objective
# filed under the label this driver hands to dev-author is an unconfirmed objective going straight to
# implementation, which is the R1 bypass this arm exists to close.
INTAKE_LABEL="${INTAKE_LABEL:-objective}"
APPROVED_LABEL="${APPROVED_LABEL:-approved}"
DEV_PLAN="${DEV_PLAN:-$HERE/dev-plan.sh}"
MAX_PLANS_PER_PASS="${MAX_PLANS_PER_PASS:-2}"

# the R16 operating-scope reader (#167) — rc 0 is the ONLY "in scope"; see bin/repo-scope.sh.
REPO_SCOPE="${REPO_SCOPE:-$HERE/repo-scope.sh}"
# R16 per-session scope (2026-07-16): inside a REAL agent session narrow to THIS session's objective-BACKED
# scope (inherited by the dev-author children it spawns); headless (no real session env) leaves
# SCOPE_SESSION unset → ceiling only, byte-identical (never the pid-token session_id fallback, which would
# fail-close every repo). Detached-timer SID binding is a deferred NOTE.
if [ -z "${SCOPE_SESSION:-}" ] && [ -n "${CLAUDE_SESSION_ID:-}${CLAUDE_CODE_SESSION_ID:-}" ]; then
  export SCOPE_SESSION="$(. "$(dirname "$REPO_SCOPE")/session-id.sh" >/dev/null 2>&1; session_id 2>/dev/null || true)"
fi
LOOP_INTERVAL="${LOOP_INTERVAL:-300}"
# R39 bounded release of the park (#277) — see "…AND THE PARK NOW HAS A BOUNDED RELEASE" above.
PARK_COOLOFF="${PARK_COOLOFF:-21600}"
PARK_MAX_RELEASES="${PARK_MAX_RELEASES:-2}"
STOP_RELEASE="${STOP_RELEASE:-$HERE/stop-release.sh}"

# The machine-owned line-1 anchor of dev-author's surface_blocked() comment — the ONLY record of "a
# question is open on this issue", and therefore the whole park gate. It is a CONTRACT with dev-author:
# `dev-loop.test.sh` asserts bin/dev-author.sh still emits exactly this prefix, so a reword there can
# never silently un-park every blocked issue and set the loop re-asking forever.
BLOCKED_ANCHOR='^\*\*dev-author → needs a decision \(BLOCKED\):\*\*'

# The driver's OWN machine-owned line-1 anchors (#277). RELEASE_ANCHOR is the bus record of one spent
# release — counting those comments IS the budget, which is why it must be posted BEFORE the re-attempt.
# ESCALATE_ANCHOR is a question to the maintainer, so it PARKS like dev-author's, and a reply un-parks it.
# Plain-text forms are matched by jq `startswith` on line 1; the regex form is what park_state greps.
RELEASE_ANCHOR='**dev-loop → bounded release:**'
ESCALATE_ANCHOR='**dev-loop → release budget spent (needs a decision):**'
ESCALATE_ANCHOR_RE='^\*\*dev-loop → release budget spent \(needs a decision\):\*\*'
# What counts as "a question is open on this issue" — either gate's anchor (line-1, identity-bound).
PARK_ANCHOR="$BLOCKED_ANCHOR|$ESCALATE_ANCHOR_RE"

# The PLANNER's own machine-owned line-1 anchors — a CONTRACT with bin/dev-plan.sh in exactly the way
# $BLOCKED_ANCHOR is one with bin/dev-author.sh (`dev-loop.test.sh` pins both against the real scripts).
# `refused:` = the objective is not maintainer-confirmed; `needs a decision (BLOCKED…)` = the planner ran
# and stopped. Either means dev-plan has already SAID something on the issue and re-running it would only
# repeat it, so the objective parks until somebody replies.
PLAN_PARK_ANCHOR='^\*\*dev-plan → (refused|needs a decision)'

log(){ printf '[%s] dev-loop: %s\n' "$(date -u +%H:%M:%S 2>/dev/null || echo --:--:--)" "$*" >&2; }

# The bounded-release clock (bin/stop-release.sh, #277). FAIL-SAFE: if the library is missing or does not
# define the function, every park keeps TODAY'S terminal shape (a permanent HOLD until a human replies)
# rather than the driver breaking — a degraded release path must never cost us the loop itself.
if ! . "$STOP_RELEASE" 2>/dev/null || ! declare -F release_verdict >/dev/null 2>&1; then
  log "WARN: bounded-release library unavailable ($STOP_RELEASE) — parks stay TERMINAL until a human replies"
  release_verdict(){ printf 'HOLD'; }
fi

# ---- PURE HELPERS (--selftest covers exactly these) ------------------------------------------------

# parse_backlog <newline-list-of-issue-numbers> → the numbers, sorted numeric-ascending, deduped, with
# any non-numeric line dropped (fail-safe: a garbled gh line never becomes a bogus issue number).
parse_backlog(){
  printf '%s\n' "$1" | grep -E '^[0-9]+$' | sort -n -u
}

# run_class <dev-author-rc> <dev-author-stdout> → AUTHORED | SKIPPED | QUESTION | RETRY.
# The cap counts MODEL RUNS SPAWNED, so the driver must tell a run apart from a guard no-op. dev-author's
# ONLY stdout emission is the URL of the PR it opened (its guard path prints nothing and exits 0), so
# (rc, stdout) classifies every outcome without duplicating its guard here:
#   AUTHORED  rc 0 + a PR URL   → a PR is in the pipeline. Spent a run ⇒ consumes a cap slot.
#   SKIPPED   rc 0, no URL      → its guard no-op'd (already authored / an open PR exists / not backlog-
#                                 labelled). NO model run was spawned ⇒ NO cap slot: an in-flight feature
#                                 must never crowd the tail of the backlog out (the starvation above).
#   QUESTION  rc 3|4|5|6|7|8    → the run spawned but could not finish, and dev-author POSTED a dev-task
#                                 question on the issue — EVERY one of these paths calls its
#                                 surface_blocked() (3 worktree, 4 BLOCKED, 5 no-progress, 7 push,
#                                 8 PR-create). rc 6 is RETIRED — an in-box RED no longer asks anyone
#                                 anything, it hands off to the host gate + fixer (MOVE 2 of #274) — but
#                                 it stays mapped so a resurrected rc 6 parks rather than spins.
#                                 Spends a slot; the question it left on the issue
#                                 is what PARKS it next pass (park_state, below) — the driver itself
#                                 records nothing.
#   RETRY     any other rc      → dev-author posted NOTHING (rc 2 — it could not even read the issue, so
#                                 it fails closed BEFORE it can comment). Retried next pass; still takes a
#                                 slot, so a broken environment cannot spin the whole backlog in one pass.
run_class(){
  case "$1" in
    0)           case "$2" in https://*) printf 'AUTHORED';; *) printf 'SKIPPED';; esac ;;
    3|4|5|6|7|8) printf 'QUESTION' ;;
    *)           printf 'RETRY' ;;
  esac
}

# park_state <dev-login> <newest-comment-author> <newest-comment-line-1> → PARKED | ACTIVE.
# The whole park gate, derived from the bus — no local state, nothing to lose (see PARKING, above):
# PARKED only when the issue's NEWEST comment is a question OUR OWN dev identity left on it and nobody
# has replied since. Identity-bound + line-1-anchored (G2): a stranger's pasted marker, or the marker
# quoted mid-prose, is inert. Everything else — including an unreadable/empty author — is ACTIVE, so the
# issue is re-offered rather than silently dropped.
# The optional 4th argument selects WHICH anchor set counts as an open question, so the plan arm can
# reuse this gate (and its identity binding) for dev-plan's anchors without a second copy of the logic.
park_state(){
  local me="$1" who="$2" line1="$3" anchor="${4:-$PARK_ANCHOR}"
  [ -n "$me" ] && [ "$who" = "$me" ] || { printf 'ACTIVE'; return; }
  if printf '%s' "$line1" | grep -qE "$anchor"; then printf 'PARKED'; else printf 'ACTIVE'; fi
}

# plan_class <dev-plan-rc> <dev-plan-stdout> → PLANNED | SKIPPED | STOPPED. The same (rc, stdout)
# reading run_class does for the author, and for the same reason: MAX_PLANS_PER_PASS must count PLANNER
# RUNS, not invocations. dev-plan's only stdout emission is the URLs of the backlog issues it filed, and
# an ALREADY-PLANNED objective exits 0 having printed nothing and spawned no model — but it keeps its
# labels forever, so charging it a slot would let two planned objectives starve every later one.
#   PLANNED  rc 0 + issue URLs → it decomposed the objective. Spends a slot.
#   SKIPPED  rc 0, no URLs     → already planned (its `planned:` tombstone is on the bus) / nothing new
#                                to file. No model run ⇒ no slot.
#   STOPPED  any other rc      → unconfirmed (3), BLOCKED (4), or a filing failure. dev-plan has posted
#                                its own reason on the issue where it could; that comment parks it.
plan_class(){
  case "$1" in
    0) case "$2" in *https://*) printf 'PLANNED';; *) printf 'SKIPPED';; esac ;;
    *) printf 'STOPPED' ;;
  esac
}

# held_seconds <iso8601-timestamp> <now-epoch> → seconds held, or '' when the clock is UNREADABLE.
# The park's age comes from the parking comment's own createdAt (an EXTERNAL clock, R24 no-proxy: a
# restart cannot reset it). Pure given its two arguments, so --selftest covers it. EVERY unreadable
# shape yields '' — which release_verdict turns into HOLD, never a release on a broken clock:
#   * a missing/empty/unparseable timestamp (an older gh, a field that did not come back);
#   * a FUTURE timestamp (clock skew) — that is an unreadable clock, NOT an age of 0, and reading it as
#     0 would be the #270 inversion again (an unusable input ARMING the axis instead of disabling it).
held_seconds(){
  local iso="${1:-}" now="${2:-}" t
  case "$now" in ''|*[!0-9]*) return;; esac
  [ -n "$iso" ] || return
  # STRUCTURAL guard before `date` ever sees it: GNU date resolves an EMPTY or whitespace-only string to
  # TODAY AT MIDNIGHT and exits 0 — so a missing createdAt would read as an age of up-to-24h and could
  # RELEASE on a clock that told us nothing. Demand an ISO-8601 shape (YYYY-…) so only a real timestamp
  # is ever parsed; everything else is unreadable, which is a HOLD.
  case "$iso" in [0-9][0-9][0-9][0-9]-*) ;; *) return;; esac
  t="$(date -u -d "$iso" +%s 2>/dev/null)" || return
  case "$t" in ''|*[!0-9]*) return;; esac
  [ "$now" -ge "$t" ] || return
  printf '%s' "$((now - t))"
}

# ---- SELFTEST --------------------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  Q='**dev-author → needs a decision (BLOCKED):** the author run could not finish.'
  echo "== parse_backlog (numeric-only, sorted, deduped) =="
  ck "sorts + dedupes"        "$(parse_backlog $'12\n3\n12\n7')" "$(printf '3\n7\n12')"
  ck "drops non-numeric junk" "$(parse_backlog $'5\nnot-a-number\n \n9')" "$(printf '5\n9')"
  ck "empty → empty"          "$(parse_backlog '')" ""
  echo "== run_class (the cap counts MODEL RUNS; an in-flight skip must cost no slot) =="
  ck "PR url + rc0 → AUTHORED" "$(run_class 0 'https://github.com/o/r/pull/9')" "AUTHORED"
  ck "rc0, no url → SKIPPED"   "$(run_class 0 '')" "SKIPPED"
  ck "rc4 BLOCKED → QUESTION"  "$(run_class 4 '')" "QUESTION"
  ck "rc5 no-progress → QUESTION" "$(run_class 5 '')" "QUESTION"
  ck "rc6 (RETIRED — no longer emitted) still parks, never spins" "$(run_class 6 '')" "QUESTION"
  # 3|7|8 ALSO call dev-author's surface_blocked() — a question IS on the issue, so they must PARK like
  # any other surfaced question, never spin as RETRY (which re-spends a model run + re-asks every pass).
  ck "rc3 worktree → QUESTION"    "$(run_class 3 '')" "QUESTION"
  ck "rc7 push fail → QUESTION"   "$(run_class 7 '')" "QUESTION"
  ck "rc8 PR-create → QUESTION"   "$(run_class 8 '')" "QUESTION"
  ck "rc2 unreadable (posts nothing) → RETRY"  "$(run_class 2 '')" "RETRY"
  echo "== park_state — DERIVED from the issue's newest comment (no local state to lose) =="
  ck "our unanswered question is the newest comment → PARKED" \
     "$(park_state oso-gato-nox-claudebox oso-gato-nox-claudebox "$Q")" "PARKED"
  ck "a human replied after it → ACTIVE (the answer un-parks)" \
     "$(park_state oso-gato-nox-claudebox arthur 'try scoping it to one probe')" "ACTIVE"
  ck "no comments at all → ACTIVE" "$(park_state oso-gato-nox-claudebox '' '')" "ACTIVE"
  ck "our own later 'shipped' comment → ACTIVE (not a question)" \
     "$(park_state oso-gato-nox-claudebox oso-gato-nox-claudebox '**dev-author → shipped:** authored #900')" "ACTIVE"
  # G2 / identity: the anchor is machine-owned. A stranger on a PUBLIC repo pasting it must not be able to
  # freeze a feature out of the backlog forever; a quoted marker must not act from any author.
  ck "a STRANGER pasting the marker is inert → ACTIVE" \
     "$(park_state oso-gato-nox-claudebox randomer "$Q")" "ACTIVE"
  ck "the marker QUOTED (not at line-1 start) is inert → ACTIVE" \
     "$(park_state oso-gato-nox-claudebox oso-gato-nox-claudebox "> $Q")" "ACTIVE"
  ck "empty DEV_LOGIN disables parking → ACTIVE (re-offer, never drop)" \
     "$(park_state '' '' "$Q")" "ACTIVE"
  # #277: our OWN escalation is a question too — it must park, so the loop does not re-offer an issue
  # whose automatic budget is spent on every single pass forever.
  E="$ESCALATE_ANCHOR the bounded releases are spent."
  ck "our ESCALATION comment parks the issue → PARKED" \
     "$(park_state oso-gato-nox-claudebox oso-gato-nox-claudebox "$E")" "PARKED"
  ck "a STRANGER's forged escalation is inert → ACTIVE" \
     "$(park_state oso-gato-nox-claudebox randomer "$E")" "ACTIVE"
  # …but a RELEASE announcement is NOT a question: it is the un-park, so the issue must read ACTIVE.
  ck "our RELEASE announcement does NOT park → ACTIVE" \
     "$(park_state oso-gato-nox-claudebox oso-gato-nox-claudebox "$RELEASE_ANCHOR re-offering it now.")" "ACTIVE"
  echo "== plan_class — the plan cap counts PLANNER RUNS, so an already-planned objective costs nothing =="
  ck "rc0 + filed backlog URLs → PLANNED" \
     "$(plan_class 0 'https://github.com/oso-gato/fedora-dev/issues/9')" "PLANNED"
  ck "rc0, nothing filed → SKIPPED (already planned — must NOT burn a slot)" "$(plan_class 0 '')" "SKIPPED"
  ck "rc3 unconfirmed → STOPPED"     "$(plan_class 3 '')" "STOPPED"
  ck "rc4 planner BLOCKED → STOPPED" "$(plan_class 4 '')" "STOPPED"
  ck "rc12 out of scope → STOPPED"   "$(plan_class 12 '')" "STOPPED"
  echo "== the plan arm reuses park_state with the PLANNER's anchors (identity- + line-1-bound) =="
  PR_='**dev-plan → refused:** this objective is not yet confirmed.'
  PB_='**dev-plan → needs a decision (BLOCKED):** the planner produced no features.'
  ck "dev-plan's refusal is the newest comment → PARKED" \
     "$(park_state oso-gato-nox-claudebox oso-gato-nox-claudebox "$PR_" "$PLAN_PARK_ANCHOR")" "PARKED"
  ck "dev-plan's BLOCKED question → PARKED" \
     "$(park_state oso-gato-nox-claudebox oso-gato-nox-claudebox "$PB_" "$PLAN_PARK_ANCHOR")" "PARKED"
  ck "a maintainer's reply after it → ACTIVE (re-offered to the planner)" \
     "$(park_state oso-gato-nox-claudebox arthur 'approved properly now')" "ACTIVE"
  ck "a STRANGER pasting dev-plan's refusal is inert → ACTIVE" \
     "$(park_state oso-gato-nox-claudebox randomer "$PR_" "$PLAN_PARK_ANCHOR")" "ACTIVE"
  ck "dev-plan's 'planned:' summary is NOT a park (dev-plan itself no-ops on it) → ACTIVE" \
     "$(park_state oso-gato-nox-claudebox oso-gato-nox-claudebox '**dev-plan → planned:** 3 feature(s)' "$PLAN_PARK_ANCHOR")" "ACTIVE"
  # The author arm must be unaffected by the new argument: its own anchor set is still the default.
  ck "park_state with no anchor argument still uses the AUTHOR anchors" \
     "$(park_state oso-gato-nox-claudebox oso-gato-nox-claudebox "$Q")" "PARKED"
  echo "== the intake label is NOT the label this driver authors from (the R1 bypass, fitness d339476) =="
  ck "INTAKE_LABEL and BACKLOG_LABEL are distinct" \
     "$([ "$INTAKE_LABEL" != "$BACKLOG_LABEL" ] && echo distinct || echo SAME)" "distinct"
  echo "== held_seconds — an EXTERNAL clock, and every unreadable shape yields '' (⇒ HOLD) =="
  ck "a real age is computed"        "$(held_seconds '2026-07-20T00:00:00Z' 1784592000)" "86400"
  ck "exactly now → 0"              "$(held_seconds '2026-07-21T00:00:00Z' 1784592000)" "0"
  ck "empty timestamp → unreadable"  "$(held_seconds '' 1784592000)" ""
  ck "garbage timestamp → unreadable" "$(held_seconds 'not-a-date' 1784592000)" ""
  # GNU date resolves these to TODAY AT MIDNIGHT and exits 0 — an age of up-to-24h out of nothing at
  # all, which could RELEASE a park on a clock that was never read. The structural guard rejects them.
  ck "whitespace-only → unreadable (date would say 'midnight today')" "$(held_seconds ' ' 1784592000)" ""
  ck "a bare word date → unreadable" "$(held_seconds 'today' 1784592000)" ""
  ck "FUTURE timestamp (skew) → unreadable, NOT 0 (#270's inversion)" \
                                     "$(held_seconds '2027-01-01T00:00:00Z' 1784592000)" ""
  ck "unreadable now → unreadable"   "$(held_seconds '2026-07-20T00:00:00Z' '')" ""
  # The wiring itself: an unreadable age must reach release_verdict as a HOLD, never a release.
  ck "unreadable age folds to HOLD through release_verdict" \
     "$(release_verdict "$(held_seconds '' 1784592000)" 0 300 2)" "HOLD"
  echo; echo "dev-loop selftest: $p passed, $f failed"
  [ "$f" -eq 0 ]; exit
fi

# ---- THE PLAN ARM: an APPROVED objective reaches the planner ---------------------------------------
# Runs at the TOP of every pass, under the SAME R16 scope check and R9 halt read as the authoring arm
# (it spawns bounded model runs and files issues — it is "new action" in exactly R9's sense). Anything
# it files lands as `backlog`, so the arm below picks it up in this very pass, bounded by MAX_PER_PASS.
# NO LOCAL STATE, like everything else here: discovery is one label query and the park is derived from
# the objective's own newest comment.
plan_pass(){ # <repo> <slug>
  local repo="$1" slug="$2"
  [ -x "$DEV_PLAN" ] || { log "planner not executable ($DEV_PLAN) — no objective is planned this pass"; return 0; }
  # Same @tsv discipline as the backlog query (number, newest comment's author, newest comment's line 1)
  # and the same HAND SPLIT below: an issue with no comments emits two EMPTY trailing fields, which
  # `IFS=$'\t' read` would fold away.
  local jqf='.[] | [ .number,
        ((.comments | last | .author.login) // ""),
        ((.comments | last | .body // "") | split("\n")[0])
      ] | @tsv'
  local raw
  raw="$(gh issue list --repo "$slug" --label "$INTAKE_LABEL" --label "$APPROVED_LABEL" --state open \
          --json number,comments -q "$jqf" 2>/dev/null)" \
    || { log "objective query failed for $slug — nothing planned this pass (retried next; no objective is lost)"; return 0; }
  local -A pwho=() pline=(); local ln num w line1 TAB=$'\t'
  while IFS= read -r ln; do
    [ -n "$ln" ] || continue
    num="${ln%%$TAB*}"; ln="${ln#*$TAB}"
    w="${ln%%$TAB*}";   line1="${ln#*$TAB}"
    case "$num" in ''|*[!0-9]*) continue ;; esac
    pwho["$num"]="$w"; pline["$num"]="$line1"
  done <<<"$raw"
  local nums; nums="$(parse_backlog "$(printf '%s\n' "${!pwho[@]}")")"
  [ -n "$nums" ] || return 0
  # FD 3 + stdin closed, for the reason spelled out at the authoring arm: dev-plan spawns a bounded
  # `claude -p`, which drains any stdin it inherits to EOF and would otherwise swallow this list.
  local n rc out spawned=0
  while IFS= read -r n <&3; do
    [ -n "$n" ] || continue
    if [ "$spawned" -ge "$MAX_PLANS_PER_PASS" ]; then
      log "MAX_PLANS_PER_PASS=$MAX_PLANS_PER_PASS planner run(s) spawned — the remaining approved objective(s) are DEFERRED to the next pass"
      break
    fi
    if [ "$(park_state "$DEV_LOGIN" "${pwho[$n]:-}" "${pline[$n]:-}" "$PLAN_PARK_ANCHOR")" = PARKED ]; then
      log "  parked objective $slug#$n — dev-plan's own refusal/question is still the newest comment (re-running it would only repeat it); reply on the issue to re-offer it"
      continue
    fi
    log "→ planning approved objective $slug#$n via dev-plan"
    # The label got it HERE; dev-plan decides whether it may act on it (it re-resolves the applier and
    # binds them to a maintainer role — see THE LABEL FILTER IS DISCOVERY, NOT AUTHORISATION).
    out="$("$DEV_PLAN" "$repo" "$n" </dev/null)"; rc=$?
    case "$(plan_class "$rc" "$out")" in
      PLANNED)
        spawned=$((spawned+1))
        log "  planned objective $slug#$n → backlog: $(printf '%s' "$out" | tr '\n' ' ')" ;;
      SKIPPED)
        log "  skipped objective $slug#$n (already planned / nothing new to file) — no cap slot spent" ;;
      STOPPED)
        spawned=$((spawned+1))
        log "  dev-plan rc=$rc for objective $slug#$n — it recorded its own reason on the issue (unconfirmed / blocked / could not file); it parks until someone replies" ;;
    esac
  done 3<<<"$nums"
}

# ---- ONE PASS over the backlog --------------------------------------------------------------------
one_pass(){ # <repo>
  local repo="$1" slug="$ORG/$1"
  # R16 OPERATING SCOPE (#167) — checked FIRST, every pass (a local file read; the scope can change
  # through a confirmed merge, so --watch must re-read it like the halt switch): an out-of-scope
  # repo gets NO enumeration and NO author run — one loud line. rc≠0 (127 included) is never a go.
  if ! "$REPO_SCOPE" check "$repo" 2>/dev/null; then
    log "R16 SCOPE: repo '$repo' is outside the maintainer-confirmed operating scope — pass refused (no enumeration, no author run, nothing filed)"
    return 0
  fi
  # THE STEP UPSTREAM OF THIS BACKLOG (see THE PLAN ARM in the header): an `approved` objective is
  # handed to the planner FIRST, so anything it decomposes is authored by the arm below in this same
  # pass. It carries the halt state rather than re-reading it — one halt read per pass.
  plan_pass "$repo" "$slug"
  # ONE list call carries the issue number, its NEWEST comment (author + line 1 + createdAt) AND the
  # release budget already spent on it — the park state, its CLOCK and its BUDGET are all DERIVED from
  # that one read (see PARKING and THE BUDGET LIVES ON THE BUS, above), so the driver keeps NO local
  # state AND still costs no extra API call per issue. jq guards the empty-comment case: `last` of [] is
  # null, and `.body // ""` keeps split() from ever seeing it; @tsv escapes any tab/newline inside a
  # body, so a comment can never forge an extra field.
  #
  # THE ROW IS SPLIT BY HAND, NOT BY `IFS=$'\t' read` — and that is load-bearing, not style. Tab is IFS
  # *whitespace*, so `read` COLLAPSES runs of it and DROPS empty fields: an issue whose newest comment
  # has no readable createdAt emits an empty 4th field, the two tabs around it fold into one, and the
  # RELEASE COUNT slides into the timestamp's slot — the driver would then age the park against a number
  # like "0" and RELEASE on a clock it never read. (Harmless while every empty field was trailing, which
  # is why the pre-#277 three-field read was fine; adding fields after createdAt is what exposed it.)
  # The `%%`/`#` expansions below preserve every empty field exactly, and keep @tsv — whose escaping of
  # tabs/newlines inside a body is what guarantees the field count in the first place.
  #
  # The two counts are IDENTITY-BOUND and LINE-1-anchored, exactly like park_state (the auto-merge G2
  # discipline): only OUR OWN $DEV_LOGIN comments count, so a stranger on a public repo can neither
  # inflate an issue's spent budget to force an escalation nor forge an escalation to silence one.
  # Placeholders are substituted rather than interpolated inline, to keep the filter readable and the
  # anchors (which contain `*` and parentheses) out of nested shell quoting.
  local jqf; jqf='.[] | [ .number,
        ((.comments | last | .author.login) // ""),
        ((.comments | last | .body // "") | split("\n")[0]),
        ((.comments | last | .createdAt) // ""),
        ([.comments[] | select(((.author.login) // "") == "@ME@"
             and (((.body) // "") | split("\n")[0] | startswith("@REL@")))] | length),
        ([.comments[] | select(((.author.login) // "") == "@ME@"
             and (((.body) // "") | split("\n")[0] | startswith("@ESC@")))] | length)
      ] | @tsv'
  jqf="${jqf//@ME@/$DEV_LOGIN}"; jqf="${jqf//@REL@/$RELEASE_ANCHOR}"; jqf="${jqf//@ESC@/$ESCALATE_ANCHOR}"
  local raw; raw="$(gh issue list --repo "$slug" --label "$BACKLOG_LABEL" --state open \
                    --json number,comments -q "$jqf" 2>/dev/null)" \
    || { log "backlog query failed for $slug — skipping this pass"; return 0; }
  # The pass reads its clock ONCE, so every issue in it is aged against the same instant.
  local now; now="$(date -u +%s 2>/dev/null)" || now=""
  local -A who=() line1=() cage=() crel=() cesc=(); local ln num w rest ts nrel nesc TAB=$'\t'
  while IFS= read -r ln; do
    num="${ln%%$TAB*}"; ln="${ln#*$TAB}"
    w="${ln%%$TAB*}";   ln="${ln#*$TAB}"
    rest="${ln%%$TAB*}"; ln="${ln#*$TAB}"
    ts="${ln%%$TAB*}";  ln="${ln#*$TAB}"
    nrel="${ln%%$TAB*}"; nesc="${ln#*$TAB}"
    [ -n "$num" ] || continue
    who["$num"]="$w"; line1["$num"]="$rest"; cage["$num"]="$ts"
    crel["$num"]="$nrel"; cesc["$num"]="$nesc"
  done <<<"$raw"
  # The WHOLE backlog is enumerated — never truncated (see THE CAP BOUNDS AUTHOR RUNS, above).
  local nums; nums="$(parse_backlog "$(printf '%s\n' "${!who[@]}")")"
  [ -n "$nums" ] || { log "$slug backlog is empty — nothing to author"; return 0; }

  # THE NUMBERS RIDE FD 3, NOT STDIN (the pr-poller.sh idiom, adopted here for the same reason it exists
  # there): the loop body spawns `dev-author`, which spawns a bounded `claude -p` — and `claude -p` DRAINS
  # whatever stdin it inherits, to EOF. Fed off FD 0, this loop hands it THE REST OF THE BACKLOG: the
  # author swallows it, the next `read` sees EOF, and the pass ends after ONE issue while still logging a
  # tidy "1 author run(s) spawned" — a silent truncation of a maintainer's confirmed work-list (proven:
  # against a stdin-faithful author, a 4-issue backlog authored only its first). FD 3 is free (FD 9 is the
  # poller's flock). Belt AND braces: the author is ALSO run with stdin CLOSED below, because no child of
  # this driver has any business reading the driver's stdin — and a future child that does must not be
  # able to re-open this hole.
  local n rc out spawned=0 authored=0 asked=0 skipped=0 parked=0 would=0 released=0
  local held used verdict
  while IFS= read -r n <&3; do
    [ -n "$n" ] || continue
    if [ "$spawned" -ge "$MAX_PER_PASS" ]; then
      log "MAX_PER_PASS=$MAX_PER_PASS author run(s) spawned — the REST of the backlog is DEFERRED to the next pass"
      break
    fi
    if [ "$(park_state "$DEV_LOGIN" "${who[$n]:-}" "${line1[$n]:-}")" = PARKED ]; then
      # THE BOUNDED RELEASE (#277). A park is allowed; a park with no way out is not. Age comes from the
      # parking comment's own createdAt, budget from the release comments already on the thread.
      held="$(held_seconds "${cage[$n]:-}" "$now")"
      used="${crel[$n]:-0}"
      verdict="$(release_verdict "$held" "$used" "$PARK_COOLOFF" "$PARK_MAX_RELEASES")"
      case "$verdict" in
        RELEASE)
          # R9 HALT: a release POSTS and then SPAWNS, so it is exactly the "new action" a halted pass
          # must not take. Observe it instead — the release is still due next pass, nothing is lost.
          # THE ANNOUNCEMENT IS THE BUDGET RECORD, so it is posted BEFORE the re-attempt and a failure to
          # post HOLDS. Releasing without a record would leave `used` unchanged and re-attempt on EVERY
          # pass — an unbounded model-run spin (R4), which is the very thing this clock exists to prevent.
          if ! gh issue comment "$n" --repo "$slug" --body "$RELEASE_ANCHOR this ticket parked $((held / 3600))h ago and the cool-off has elapsed, so the loop is RE-ATTEMPTING it automatically (release $((used + 1)) of $PARK_MAX_RELEASES).

No reply is needed: if the parked run failed for an environmental reason (a worktree, push or PR-create failure) the re-attempt is likely to clear it. If it fails the same way again the loop will retry until the budget is spent, then ask you directly."$'\n\n<sub>autonomous dev-loop — R39 bounded release (#277). Not an approval request.</sub>' >/dev/null 2>&1; then
            parked=$((parked+1))
            log "  parked $slug#$n — the release announcement could not be posted, so the release is NOT taken (the bus record IS the budget); retrying next pass"
            continue
          fi
          released=$((released+1))
          log "  RELEASED $slug#$n — parked ${held}s ≥ ${PARK_COOLOFF}s cool-off; re-attempting now (release $((used + 1)) of $PARK_MAX_RELEASES)"
          # …and fall through to the author run below: the re-attempt IS the release.
          ;;
        ESCALATE)
          parked=$((parked+1))
          # ONCE is the contract: our own escalation comment on the thread is the idempotence anchor, so
          # a wiped box does not re-ask either. It parks (park_state treats it as a question), and a
          # reply un-parks it like any other.
          if [ "${cesc[$n]:-0}" -gt 0 ]; then
            log "  parked $slug#$n — automatic release budget spent ($used/$PARK_MAX_RELEASES) and the maintainer has already been told; holding (reply on the issue to re-offer it)"
            continue
          fi
          if gh issue comment "$n" --repo "$slug" --body "$ESCALATE_ANCHOR this ticket has used all $PARK_MAX_RELEASES of its automatic re-attempts and is still parked, so the loop has stopped re-attempting it and is asking you instead.

The question above it on this thread is the one that needs an answer. Replying on this issue re-offers the ticket to the author on the next pass."$'\n\n<sub>autonomous dev-loop — R39 bounded release exhausted (#277). A dev-task question, not an approval request.</sub>' >/dev/null 2>&1; then
            log "  ESCALATED $slug#$n — automatic release budget spent ($used/$PARK_MAX_RELEASES); the maintainer has been asked, once"
          else
            log "  parked $slug#$n — release budget spent, but the escalation comment could not be posted; retrying next pass"
          fi
          continue ;;
        *)
          parked=$((parked+1))
          # The HOLD is logged WITH the age it read — that is what makes the unreadable-clock residual
          # visible rather than a silent permanent park (bin/stop-release.sh's disclosed trade).
          if [ -n "$held" ]; then
            log "  parked $slug#$n — my unanswered question is still the newest comment (held ${held}s of ${PARK_COOLOFF}s cool-off, $used/$PARK_MAX_RELEASES release(s) used); reply on the issue to re-offer it now"
          else
            log "  parked $slug#$n — my unanswered question is still the newest comment, and its AGE IS UNREADABLE (createdAt missing/unparseable), so the bounded release cannot fire: this park is releasable only by a reply until the clock reads again"
          fi
          continue ;;
      esac
    fi
    # R9 HALT (#151): OBSERVE-ONLY — the offer is LOGGED (the operator sees the queue) but no bounded
    # model run spawns. The check sits ONCE at the top of the pass, not here per issue: HALT stops NEW
    # passes' work, it does not abort a pass already spawning (in-flight work is never killed).
    log "→ authoring backlog $slug#$n via dev-author"
    # dev-author is fail-closed + idempotent: already-authored / non-backlog / has-PR issues no-op inside
    # it, so the driver need not track that state. Any non-zero exit is logged and the loop CONTINUES —
    # one stuck feature must never wedge the rest.
    # </dev/null: the model run must inherit no stdin (see FD 3, above). Its stderr is NOT discarded —
    # dev-author's log lines are the only trace of what a spawned run did, and swallowing them is what
    # would have made the truncation above invisible in production.
    out="$("$DEV_AUTHOR" "$repo" "$n" </dev/null)"; rc=$?
    case "$(run_class "$rc" "$out")" in
      AUTHORED)
        spawned=$((spawned+1)); authored=$((authored+1))
        log "  authored $slug#$n → $out" ;;
      SKIPPED)
        skipped=$((skipped+1))
        log "  skipped $slug#$n (already authored / a PR is in flight) — no cap slot spent" ;;
      QUESTION)
        spawned=$((spawned+1)); asked=$((asked+1))
        # NOTHING is recorded here — the question dev-author just posted IS the record, and next pass
        # reads it straight off the issue as PARKED. If that comment FAILED to post, the issue reads
        # ACTIVE and is re-offered: fail-safe toward re-asking, never toward a silently stranded feature.
        log "  dev-author rc=$rc for $slug#$n — a dev-task question is now on the issue; it parks until someone replies" ;;
      RETRY)
        spawned=$((spawned+1))
        log "  dev-author rc=$rc for $slug#$n (environmental — no question posted) — retrying next pass" ;;
    esac
  done 3<<<"$nums"
  log "$slug pass complete — $spawned author run(s) spawned: $authored PR(s) opened, $asked question(s) surfaced; $skipped in-flight skip(s), $parked parked, $released bounded release(s) taken"
}

# ---- ENTRY -----------------------------------------------------------------------------------------
if [ "${1:-}" = "--watch" ]; then
  # THE HARD-REFUSAL THAT STOOD HERE IS LIFTED BY #151 ITSELF (its req 9) — and ONLY because the
  # interlock it stood in for now EXISTS: one_pass() reads the fleet HALT switch at the top of EVERY
  # pass, before any model run is spawned. A clock that spawns bounded model runs is now stoppable
  # within one sweep, from a phone, with no restart — which is exactly what R9 demanded and what the
  # refusal existed to withhold until true. Lifting it WITHOUT the check landing in the same change is
  # the one thing #151 forbids.
  REPO="${2:?usage: dev-loop.sh --watch <repo>}"
  LOCK="${DEV_LOOP_LOCK:-${XDG_RUNTIME_DIR:-/tmp}/dev-loop-watch-$REPO.lock}"
  exec 9>"$LOCK"
  flock -n 9 || { log "another dev-loop --watch for $REPO holds the lock; exiting"; exit 0; }
  trap 'log "dev-loop --watch stopping (signal)"; exit 0' TERM INT HUP
  log "dev-loop --watch up (repo=$REPO interval=${LOOP_INTERVAL}s)"
  while :; do
    one_pass "$REPO" || log "pass error (continuing)"
    sleep "$LOOP_INTERVAL"
  done
fi
REPO="${1:?usage: dev-loop.sh <repo> [--once] | --watch <repo> | --selftest}"
case "${2:-}" in
  ''|--once) : ;;  # one pass IS the default; --once names it explicitly (caller-friendliness)
  *) log "unknown argument '$2' (usage: dev-loop.sh <repo> [--once] | --watch <repo> | --selftest)"; exit 2 ;;
esac
one_pass "$REPO"
