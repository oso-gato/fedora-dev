#!/usr/bin/env bash
# fleet-halt.sh — the R9 FLEET HALT switch: the fleet-wide, maintainer-thrown SOFT STOP (fedora-dev#151;
# apparatus spec #135 R9 "a pinned HALT control freezes every poller within one sweep" + P3's "HALT
# check in every sweep").
#
# THE SIGNAL — on GitHub, read fresh every sweep, never local state (spec #135's design law): the
# `$HALT_LABEL` label on the FLEET HALT CONTROL issue in the control repo (live today:
# oso-gato/fedora-bootstrap#128). The issue is DISCOVERED BY TITLE — a strict PREFIX match on
# `$HALT_TITLE` against a search-API phrase query; no hardcoded number, no local cache — and ALL
# matching issues are read, any HALT winning, so an unlabelled decoy can never mask a halted control.
# ABSENT is a DEFINITE "no halt asserted" ⇒ RUN: a sweeper must never freeze the fleet because an issue
# was tidied away (collapsing absent into unreadable is the deployment hazard #151's note names).
#
# MAINTAINER-BOUND, BOTH DIRECTIONS (bin/dev-plan.sh's applier-bound `approved` discipline, reused not
# reinvented): label PRESENCE proves nothing — applying one needs only triage/write, which every fleet
# App identity holds — so the state derives from the label's own TIMELINE EVENTS, walked newest-first,
# each actor role-checked against the permission API (admin|maintain). The FIRST maintainer-authored
# event decides: `labeled` ⇒ HALT, `unlabeled` ⇒ clear. A non-maintainer event is INERT in BOTH
# directions (logged loudly — it means something tried): an App applying `halt` cannot stop the fleet
# (no self-halt), and an App REMOVING a maintainer's `halt` cannot restart it (no self-un-halt — the
# maintainer's older `labeled` event is still the newest MAINTAINER event, so the fold stays HALT).
# Empirically pinned 2026-07-13: the permission endpoint answers HTTP 200 + role_name "" for App bot
# actors (`<app>[bot]`, the form the REST timeline reports), so App noise resolves DEFINITIVELY inert
# and can never stop the fleet.
#
# FAIL DIRECTION — the ONE gate that biases TOWARD STOPPING (R9's deliberate inversion of the loop's
# usual fail-safe-toward-progress), softened so one dropped packet is not a fleet outage:
#   * a CLEAN read decides (RUN, or HALT naming the maintainer);
#   * an UNREADABLE signal — discovery/timeline fetch failed, or a walked actor's role UNRESOLVABLE
#     (the lookup itself errored; distinct from the definitive empty role an App gets) ⇒ **RUN**,
#     logged, and logged LOUDLY past $HALT_FAILS_MAX consecutive failures. It NEVER escalates to HALT.
#     INVERTED 2026-07-28 (STEP 3 of #274) on measured evidence: the old fail-closed behaviour produced
#     935 halts of which ZERO were thrown by the maintainer — 100% were "the API returned garbage" —
#     suppressing 338 concrete actions, and one of them BLOCKED THE TICKET THAT WOULD HAVE REPAIRED A
#     SIX-DAY OUTAGE. The earlier reasoning ("a gate that cannot be read cannot be trusted to say go")
#     mistook this label for a safety gate. It is not: merge safety is the two INDEPENDENT gates, and
#     R9's hard stop is App-key revocation. So an unreadable read is not evidence of a halt, and
#     treating it as one converts internet weather into a fleet outage. The "fail-open is defeated by
#     breaking the read" objection is answered by that same hard stop, which no read can defeat.
#
# CONTRACT (what every caller relies on): stdout is ONE line whose FIRST WORD is the state; the exit
# code is the gate. rc 0 = RUN. rc 10 = HALT (a maintainer-applied label, definitively read). rc 20 is
# RETIRED — an unreadable signal now returns rc 0 (RUN), never a pause. Callers MUST treat every
# non-zero rc — including a checker that is missing or crashed (127, anything) — as "take no new action
# this sweep", so the fail-closed direction holds BY CONSTRUCTION. Detail rides stderr (the caller's
# log). HALT freezes NEW action only: a bounded model run or merge already in flight completes (killing
# a fixer mid-push is how work is lost); the hard kill is App-key revocation, per R9.
#
# CALLERS (R9 coverage — the check belongs at the TOP of each sweep, BEFORE any model run is spawned or
# any merge taken): bin/pr-poller.sh (every tick) and bin/dev-loop.sh (every pass) in this repo; the
# host's live-gate-watch.sh is the fedora-bootstrap half of #151 — this file is CANONICAL here and
# meant to be mirrored there (the gh-app-provision.sh precedent; keep in lockstep).
#   MIRROR DIVERGENCE, DISCLOSED (2026-07-28): fedora-bootstrap carries its own copy, which still fails
#   CLOSED on an unreadable read. Until that copy is brought into lockstep by its own PR, the dev side
#   fails open and the host side fails closed. Nothing is unsafe — the host retains the older, more
#   conservative direction, and the host gate posts verdicts rather than merging — but the two halves
#   of #151 are not identical today, and a reader of this "CANONICAL / keep in lockstep" line would
#   otherwise assume they are.
#
# COST: 2 REST calls per check while the label has never been touched (1 search + 1 timeline); once it
# has, + the permission lookups of the walked actors (memoized per actor; the walk stops at the first
# decisive event). The consecutive-failure counter in $HALT_STATE_DIR is operational scratch, not a
# record: a wiped box resets it to 0 and simply re-reads the signal — the record of a HALT is GitHub.
#
#   fleet-halt.sh              read the switch: RUN (rc 0) | HALT (rc 10, maintainer-applied only)
#   fleet-halt.sh --selftest   exercise the pure helpers (no gh / network)
#
# ENV: HALT_REPO (default oso-gato/fedora-bootstrap — the control repo); HALT_TITLE (default
#      "FLEET HALT CONTROL" — the discovery prefix); HALT_LABEL (default halt); HALT_FAILS_MAX
#      (default 3 — consecutive unreadable reads before the log gets LOUD; it never halts); HALT_STATE_DIR
#      (default ${XDG_RUNTIME_DIR:-/tmp}/fleet-halt — tmpfs scratch for that counter).
set -uo pipefail

HALT_REPO="${HALT_REPO:-oso-gato/fedora-bootstrap}"
HALT_TITLE="${HALT_TITLE:-FLEET HALT CONTROL}"
HALT_LABEL="${HALT_LABEL:-halt}"
HALT_FAILS_MAX="${HALT_FAILS_MAX:-3}"
HALT_STATE_DIR="${HALT_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/fleet-halt}"

log(){ printf 'fleet-halt: %s\n' "$*" >&2; }

# ---- PURE HELPERS (--selftest covers exactly these) ------------------------------------------------

# role_can_halt <role_name> → 1 only for a repo maintainer (admin|maintain) — dev-plan's
# role_can_confirm discipline verbatim: write/triage/read/empty/unknown → 0. Every fleet App identity
# resolves to write or "" (empirically: role_name "" for `<app>[bot]`), so the loop can neither throw
# nor clear its own HALT.
role_can_halt(){ case "$1" in admin|maintain) printf 1;; *) printf 0;; esac; }

# halt_fold <newest-first "event<TAB>trit<TAB>actor" lines> → HALT <actor> | CLEAR | UNREADABLE <actor>
# trit: 1 = actor proven maintainer · 0 = DEFINITIVELY not (role fetched OK: "", write, triage, …) ·
# x = role UNRESOLVABLE (the lookup itself failed). The FIRST decisive line — newest-first — wins:
#   1 + labeled   ⇒ HALT          1 + unlabeled ⇒ CLEAR (the maintainer's own un-halt)
#   0             ⇒ INERT in BOTH directions, keep walking (self-halt AND self-un-halt closed: an App's
#                   `unlabeled` is skipped, so the maintainer's older `labeled` still decides HALT)
#   x             ⇒ UNREADABLE — this event MIGHT be a maintainer's, so skipping it could either miss a
#                   fresh HALT or resurrect a cleared one; an unreadable read routes to RUN, not HALT.
# No decisive line at all ⇒ CLEAR (no maintainer has ever touched the label).
halt_fold(){
  local ev trit actor
  while IFS=$'\t' read -r ev trit actor; do
    [ -n "$ev" ] || continue
    case "$trit" in
      1) case "$ev" in
           labeled)   printf 'HALT %s' "$actor"; return;;
           unlabeled) printf 'CLEAR'; return;;
         esac;;
      x) printf 'UNREADABLE %s' "$actor"; return;;
    esac
  done <<<"$1"
  printf 'CLEAR'
}

# unreadable_action <consecutive-unreadable-reads> <max> → RUN | RUN_LOUD.  **NEVER HALT.**
#
# THE INVERSION (STEP 3 of #274, 2026-07-28). This used to escalate to HALT after N unreadable reads,
# on the reasoning that a gate which cannot be read should fail toward stopping. The measured result
# was the opposite of safety: **935 halts, ZERO of them thrown by the maintainer.** 100% were "the
# GitHub API returned garbage three times in a row." They suppressed 338 concrete actions, and during
# the 2026-07-28 six-day outage a halt BLOCKED THE VERY TICKET THAT WOULD HAVE REPAIRED THE BOX.
#
# WHY FAILING OPEN IS CORRECT HERE, and this is the load-bearing argument — it is not "the halt was
# annoying":
#   1. THE HALT IS NOT A SAFETY GATE. Merge safety is the two INDEPENDENT gates (host live-gate GREEN
#      + independent fitness PASS, distinct App identities, sha-bound, fail-closed). An unreadable halt
#      signal does not make a merge unsafe, because it is not what makes a merge safe. Failing this
#      open weakens NOTHING about what may be merged.
#   2. THERE IS A HARDER STOP BEHIND IT. R9 states the hard stop is App-key REVOCATION. The label is a
#      SOFT, convenience stop with a real mechanism behind it, so it does not need to be absolute.
#   3. AN UNREADABLE SIGNAL IS NOT EVIDENCE OF A HALT. Treating "I cannot see the label" as "the label
#      is set" converts routine internet weather into a fleet-wide outage — and did, 935 times.
#
# WHAT STILL HALTS: a label that is READ, PRESENT, and applied by a MAINTAINER (resolved from the
# label's own timeline event). That is unchanged and remains maintainer-bound in both directions.
#
# The streak still matters for VISIBILITY, not for action: past the bound the log gets loud, because a
# persistently unreadable signal is a real problem worth surfacing — just not by stopping the loop.
unreadable_action(){
  case "$1" in ''|*[!0-9]*) printf 'RUN'; return 0 ;; esac
  case "$2" in ''|*[!0-9]*) printf 'RUN'; return 0 ;; esac
  [ "$1" -ge "$2" ] && printf 'RUN_LOUD' || printf 'RUN'
}

# ---- SELFTEST --------------------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0; T=$'\t'
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  echo "== role_can_halt (maintainer-bound: admin|maintain only — the dev-plan discipline) =="
  ck "admin can halt"                    "$(role_can_halt admin)" 1
  ck "maintain can halt"                 "$(role_can_halt maintain)" 1
  ck "write cannot (fleet Apps)"         "$(role_can_halt write)" 0
  ck "triage cannot"                     "$(role_can_halt triage)" 0
  ck "empty cannot (App bots get \"\")"  "$(role_can_halt '')" 0
  ck "unknown cannot"                    "$(role_can_halt wat)" 0
  echo "== halt_fold (newest-first; the FIRST maintainer event decides; App noise inert BOTH ways) =="
  ck "no events → CLEAR"                 "$(halt_fold '')" "CLEAR"
  ck "maintainer labeled → HALT"         "$(halt_fold "labeled${T}1${T}arthur")" "HALT arthur"
  ck "maintainer un-labeled (newest) → CLEAR" \
     "$(halt_fold "unlabeled${T}1${T}arthur
labeled${T}1${T}arthur")" "CLEAR"
  ck "App labeled → CLEAR (self-halt closed)" \
     "$(halt_fold "labeled${T}0${T}nox[bot]")" "CLEAR"
  ck "App UN-labeled a maintainer's halt → still HALT (self-un-halt closed)" \
     "$(halt_fold "unlabeled${T}0${T}nox[bot]
labeled${T}1${T}arthur")" "HALT arthur"
  ck "App noise atop a maintainer's clear → CLEAR" \
     "$(halt_fold "labeled${T}0${T}nox[bot]
unlabeled${T}1${T}arthur
labeled${T}1${T}arthur")" "CLEAR"
  ck "unresolvable actor → UNREADABLE (which now CONTINUES, loudly — never halts)" \
     "$(halt_fold "unlabeled${T}x${T}ghost
labeled${T}1${T}arthur")" "UNREADABLE ghost"
  ck "resolvable events BELOW an unresolvable one never decide first" \
     "$(halt_fold "labeled${T}x${T}ghost
unlabeled${T}1${T}arthur")" "UNREADABLE ghost"
  echo "== unreadable_action — an unreadable signal NEVER halts (the 935-false-halts inversion) =="
  ck "1/3 → RUN"                    "$(unreadable_action 1 3)" "RUN"
  ck "2/3 → RUN"                    "$(unreadable_action 2 3)" "RUN"
  ck "3/3 → RUN_LOUD, still running" "$(unreadable_action 3 3)" "RUN_LOUD"
  ck "9/3 → RUN_LOUD, still running" "$(unreadable_action 9 3)" "RUN_LOUD"
  ck "395 consecutive (the real outage) still RUNS" "$(unreadable_action 395 3)" "RUN_LOUD"
  ck "K=1 does not halt either"     "$(unreadable_action 1 1)" "RUN_LOUD"
  ck "unreadable streak → RUN"      "$(unreadable_action x 3)" "RUN"
  ck "unreadable bound → RUN"       "$(unreadable_action 1 x)" "RUN"
  echo "   (there is deliberately NO input to this function that returns HALT)"
  echo; echo "fleet-halt selftest: $p passed, $f failed"
  [ "$f" -eq 0 ]; exit
fi

# ---- I/O — the real read ---------------------------------------------------------------------------
mkdir -p "$HALT_STATE_DIR" 2>/dev/null || true
FAILS="$HALT_STATE_DIR/consecutive-unreadable"

oneline(){ printf '%s' "$1" | tr '\n\t' '  ' | tail -c 300; }

# signal_unreadable <detail> — logs an unreadable read and CONTINUES (never returns; exits 0 = RUN).
# The counter is best-effort scratch and affects only how loudly this logs, never whether work proceeds:
# if it cannot be written, every unreadable read simply logs quietly and the loop still runs.
signal_unreadable(){
  local n=0
  [ -f "$FAILS" ] && n="$(cat "$FAILS" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0;; esac
  n=$((n+1)); printf '%s' "$n" > "$FAILS" 2>/dev/null || true
  # THE INVERSION: an unreadable signal is NOT evidence of a halt, so the loop KEEPS RUNNING. Loudly
  # past the bound, because a persistently unreadable control signal is a real problem worth seeing —
  # just not one worth stopping delivery for. exit 0 = RUN (see unreadable_action for the argument).
  if [ "$(unreadable_action "$n" "$HALT_FAILS_MAX")" = RUN_LOUD ]; then
    log "signal UNREADABLE $n consecutive read(s) (>= $HALT_FAILS_MAX) — CONTINUING ANYWAY. An unreadable signal is not a halt: merge safety is the two independent gates, not this label, and the hard stop is App-key revocation (R9). Fix the signal; the loop keeps delivering. Detail: $1"
    printf 'RUN — signal unreadable %s consecutive read(s), continuing (not a halt): %s\n' "$n" "$1"
    exit 0
  fi
  log "signal unreadable ($n/$HALT_FAILS_MAX consecutive) — continuing; retrying the read next sweep: $1"
  printf 'RUN — signal unreadable (%s/%s), continuing: %s\n' "$n" "$HALT_FAILS_MAX" "$1"
  exit 0
}

# 1) DISCOVER the control issue(s) BY TITLE. Search-API phrase query, then a strict local PREFIX match
# on the returned titles (search matches words; the prefix is the contract). state:any — a closed
# control issue still carries its label history.
rows="$(gh api -X GET search/issues -f q="repo:$HALT_REPO in:title \"$HALT_TITLE\"" \
        -q '.items[] | [(.number|tostring), .title] | @tsv' 2>&1)" \
  || signal_unreadable "control-issue discovery failed: $(oneline "$rows")"
control=""
while IFS=$'\t' read -r inum ititle; do
  case "$inum" in ''|*[!0-9]*) continue;; esac
  case "$ititle" in "$HALT_TITLE"*) control="$control $inum";; esac
done <<<"$rows"

if [ -z "$control" ]; then
  rm -f "$FAILS"
  log "no issue titled '$HALT_TITLE…' in $HALT_REPO — ABSENT is a definite 'no halt asserted' (a tidied-away issue must never freeze the fleet)"
  printf 'RUN\n'; exit 0
fi

# 2) per control issue: the label's OWN timeline decides (presence is never trusted — see the header).
# Walked newest-first; each actor's role is fetched lazily (the walk stops at the first decisive event)
# and memoized. A failed role lookup is NOT memoized — the next read should retry it.
declare -A MAINT_MEMO
resolve_trit(){ # <actor> → 1|0|x  (proven maintainer | definitively not | unresolvable)
  local a="$1" role t
  [ -n "${MAINT_MEMO[$a]:-}" ] && { printf '%s' "${MAINT_MEMO[$a]}"; return; }
  if role="$(gh api "repos/$HALT_REPO/collaborators/$a/permission" -q .role_name 2>/dev/null)"; then
    t="$(role_can_halt "$role")"
    [ "$t" = 1 ] || log "'$HALT_LABEL' event by @$a is INERT (role: ${role:-none} — not a maintainer). Something OTHER than a maintainer touched the HALT label."
    MAINT_MEMO[$a]="$t"; printf '%s' "$t"
  else
    printf 'x'
  fi
}

verdict=CLEAR; who=""; where=""
for inum in $control; do
  evs="$(gh api "repos/$HALT_REPO/issues/$inum/timeline" --paginate \
         -q '.[] | select((.event=="labeled" or .event=="unlabeled") and (.label.name=="'"$HALT_LABEL"'")) | [.event, .actor.login] | @tsv' 2>&1)" \
    || signal_unreadable "timeline of $HALT_REPO#$inum unreadable: $(oneline "$evs")"
  [ -n "$evs" ] || continue
  annotated=""
  while IFS=$'\t' read -r ev actor; do
    case "$ev" in labeled|unlabeled) : ;; *) continue;; esac    # stray non-event lines never walk
    trit="$(resolve_trit "$actor")"
    annotated="$annotated$(printf '%s\t%s\t%s' "$ev" "$trit" "$actor")"$'\n'
    case "$trit" in 1|x) break;; esac    # decisive/unreadable — older events cannot change the fold
  done <<<"$(tac <<<"$evs")"
  fverdict="$(halt_fold "$annotated")"
  case "$fverdict" in
    HALT*)       verdict=HALT; who="${fverdict#HALT }"; where="$inum"; break;;   # any HALT ⇒ HALT
    UNREADABLE*) signal_unreadable "role of @${fverdict#UNREADABLE } (a '$HALT_LABEL' event on $HALT_REPO#$inum) unresolvable — cannot rule a maintainer in or out";;
  esac
done

rm -f "$FAILS"    # a clean read — whatever it says — resets the escalation
if [ "$verdict" = HALT ]; then
  log "HALTED — '$HALT_LABEL' asserted on $HALT_REPO#$where by maintainer @$who"
  printf 'HALT — %s label on %s#%s by maintainer @%s\n' "$HALT_LABEL" "$HALT_REPO" "$where" "$who"
  exit 10
fi
printf 'RUN\n'; exit 0
