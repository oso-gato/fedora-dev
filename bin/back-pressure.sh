#!/usr/bin/env bash
# back-pressure.sh — the SHARED-RESOURCE fair-share / back-pressure decider (R39; gap 10, fedora-dev#208).
#
# WHY: the objective runs an "undefined number of sessions" (R20) — N tenant claudebox sessions — against
# ONE shared host validator, ONE shared dev App identity (a 5k/h REST + 30/min search budget, SHARED with
# the fixer per bin/pr-poller.sh), and a shared storage/dnf-cache budget. R29 makes the PAIRWISE (N≈2)
# concurrent case cross-contamination-safe; this is its N-scaling generalization: under unbounded N a
# shared resource must degrade GRACEFULLY (bounded per-session share, no tenant starving another) and,
# when the shared budget is exhausted, emit a SATURATION SIGNAL — never a silent cap (R37).
#
# THE MECHANISM is a single admission decision any actuator makes BEFORE it consumes a shared resource,
# given four scalars: the resource's total BUDGET, the number of live SESSIONS sharing it (R27 registry),
# the resource's current TOTAL in-flight usage, and THIS session's current in-flight usage:
#
#   fair_share = max(1, budget / n)            # the floor guaranteed to EVERY declared session; ≥1 so a
#                                              # session is never structurally starved to zero, even when
#                                              # there are more sessions than budget units (over-subscription).
#   decide:
#     total >= budget                → SATURATED  (the shared budget is exhausted — back-pressure + SIGNAL)
#     session >= fair_share          → WAIT       (this session has had its fair share; its peers' shares
#                                                   are RESERVED so none is starved — yield, retry later)
#     otherwise                      → ADMIT      (within this session's guaranteed share; a unit is free)
#
# AT N=1 fair_share = budget, so a lone tenant uses the WHOLE budget and only ever hits SATURATED at true
# exhaustion — i.e. the mechanism is a pure global cap with a signal, and per-session throttling appears
# only as N grows (exactly "non-blocking now; revisit when a second+ concurrent tenant makes it real").
#
# FAIR-SHARE MODEL (disclosed): this is a STRICT reserving fair share — each declared session's share is
# held even when a peer is momentarily idle, so no tenant can EVER starve another (the issue's explicit
# ask). It is therefore NOT work-conserving: a lone active session at N>1 will WAIT on a unit its idle
# peer is not using. Work-conservation (letting a session borrow an idle peer's slack) needs per-peer
# in-flight accounting and is a named follow-up (00-DESIGN.md NOTES), not this MVP. At N=1 the strict
# share IS the whole budget, so there is no waste in the load-bearing single-tenant case today.
#
# THE SATURATION SIGNAL (R37 — no silent cap): a SATURATED or WAIT verdict is NEVER silent. `decide`
# prints the verdict token on stdout AND a human-readable reason on stderr (the caller's log), naming the
# resource (optional label) and the numbers, so a bounded/degraded path can never masquerade as a
# complete one. A consumer that back-pressures inherently surfaces it by construction.
#
# CONTRACT (what every caller relies on — mirrors bin/fleet-halt.sh's rc discipline): `decide` writes ONE
# line whose FIRST WORD is the verdict, and the EXIT CODE is the gate:
#     rc 0  = ADMIT       — the ONLY "go"; consume a unit.
#     rc 10 = WAIT        — fair-share back-pressure; do not consume, retry later (no starvation of peers).
#     rc 20 = SATURATED   — the shared budget is exhausted; do not consume, retry later.
#     rc 2  = usage/input error (a non-numeric or non-positive budget, etc.) — a misconfiguration.
# A caller MUST treat every non-zero rc as "do not consume this unit now" (fail-closed by construction).
# FAIL DIRECTION: not a trust boundary — fail-safe TOWARD PROGRESS. `live-sessions` clamps an
# unreadable/empty registry to N=1 (the acting session is at least itself), which yields the LARGEST fair
# share (least throttling); the global BUDGET cap (SATURATED) still protects the shared resource from
# total exhaustion regardless of the session count read.
#
# SUBCOMMANDS:
#   decide <budget> <n> <total-in-flight> <session-in-flight> [resource-label]
#                              admission verdict for one unit (ADMIT rc0 | WAIT rc10 | SATURATED rc20).
#   fair-share <budget> <n>    print the per-session guaranteed floor (max(1, budget/n)).
#   live-sessions              print N = the count of LIVE sessions from the R27 registry (fail-safe → 1).
#   --selftest                 exercise the pure core (bp_fair_share / bp_verdict) — no registry / gh / net.
#
# PURE HELPERS (sourceable + selftested): bp_fair_share <budget> <n> · bp_verdict <budget> <n> <total>
# <session> (prints ADMIT|WAIT|SATURATED|ERR, no I/O, no rc semantics — the CLI maps token→rc+signal).
#
# ENV: SCOPE_REGISTRY_DIR (the R27 registry store `live-sessions` counts; tests override to a tempdir).
#
# NOTE [status]: the mechanism + its signal are BUILT and tested here; LIVE WIRING into the shared-resource
# actuators (the host validator scheduler, the poller/App-budget consumers, the storage GC) is deferred to
# when N>1 makes it load-bearing (per #208 and the 00-DESIGN.md NOTES) — dead-simple to drop in: one
# `decide` call gated on its rc. Codifying R39 + shipping the proven decider is the MVP; arming it live is
# the follow-on the issue itself scopes to "when N grows".
set -uo pipefail

_BP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log(){ printf 'back-pressure: %s\n' "$*" >&2; }

# ---- PURE HELPERS (--selftest covers exactly these; no I/O, no rc semantics) ------------------------

# _is_uint <s> → rc 0 iff s is a non-empty string of ASCII digits (a non-negative integer).
_is_uint(){ case "${1:-}" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

# bp_fair_share <budget> <n> → the per-session guaranteed floor: max(1, budget/n) by integer division.
# n<1 is treated as 1 (a live actuator is always at least itself). Prints ERR on a bad/zero budget.
bp_fair_share(){
  local budget="${1:-}" n="${2:-}"
  _is_uint "$budget" && [ "$budget" -ge 1 ] || { printf 'ERR'; return; }
  _is_uint "$n" || n=1
  [ "$n" -ge 1 ] || n=1
  local fs=$(( budget / n ))
  [ "$fs" -ge 1 ] || fs=1        # over-subscription (more sessions than budget): each still guaranteed 1
  printf '%s' "$fs"
}

# bp_verdict <budget> <n> <total-in-flight> <session-in-flight> → ADMIT | WAIT | SATURATED | ERR.
# Pure: the decision table above, no I/O. The CLI maps the token to the rc + the R37 signal.
bp_verdict(){
  local budget="${1:-}" n="${2:-}" total="${3:-}" session="${4:-}"
  _is_uint "$budget" && [ "$budget" -ge 1 ] || { printf 'ERR'; return; }
  _is_uint "$total" && _is_uint "$session" || { printf 'ERR'; return; }
  _is_uint "$n" || n=1
  [ "$n" -ge 1 ] || n=1
  local fs; fs="$(bp_fair_share "$budget" "$n")"
  [ "$fs" = ERR ] && { printf 'ERR'; return; }
  if [ "$total" -ge "$budget" ]; then printf 'SATURATED'; return; fi   # global budget exhausted
  if [ "$session" -ge "$fs" ]; then printf 'WAIT'; return; fi          # BP-FAIRSHARE-CAP: peers' shares reserved
  printf 'ADMIT'
}

# ---- REGISTRY READ (fail-safe toward progress) -----------------------------------------------------

# bp_live_sessions → N = count of LIVE sessions in the R27 registry. An unreadable/empty registry, or a
# missing session-registry.sh, clamps to 1 (the acting session is at least itself; the LARGEST fair share
# = least throttling — the global budget cap still bounds total consumption).
bp_live_sessions(){
  local reg="$_BP_DIR/session-registry.sh" out n=0
  if [ -f "$reg" ]; then
    out="$(bash "$reg" list 2>/dev/null)" || out=""
    n="$(printf '%s\n' "$out" | grep -c '[^[:space:]]' 2>/dev/null)" || n=0
  fi
  case "$n" in ''|*[!0-9]*) n=0;; esac
  [ "$n" -ge 1 ] || n=1
  printf '%s' "$n"
}

# ---- SELFTEST --------------------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }

  echo "== bp_fair_share (max(1, budget/n); ≥1 under over-subscription; ERR on a bad budget) =="
  ck "N=1 → whole budget"                "$(bp_fair_share 4 1)" 4
  ck "N=2, budget 4 → 2"                 "$(bp_fair_share 4 2)" 2
  ck "N=3, budget 10 → 3 (floor)"        "$(bp_fair_share 10 3)" 3
  ck "over-subscribed (n>budget) → 1"    "$(bp_fair_share 3 5)" 1
  ck "n=0 treated as 1 → whole budget"   "$(bp_fair_share 4 0)" 4
  ck "zero budget → ERR"                 "$(bp_fair_share 0 2)" ERR
  ck "non-numeric budget → ERR"          "$(bp_fair_share x 2)" ERR

  echo "== bp_verdict — N=1 (a lone tenant: whole budget, signal only at true exhaustion) =="
  ck "empty budget → ADMIT"              "$(bp_verdict 4 1 0 0)" ADMIT
  ck "budget nearly full → ADMIT"        "$(bp_verdict 4 1 3 3)" ADMIT
  ck "budget exhausted → SATURATED"      "$(bp_verdict 4 1 4 4)" SATURATED
  ck "over budget → SATURATED"           "$(bp_verdict 4 1 5 5)" SATURATED

  echo "== bp_verdict — N=2, budget 4 (fair share = 2; peers' shares reserved → no starvation) =="
  ck "idle session, slack → ADMIT"       "$(bp_verdict 4 2 0 0)" ADMIT
  ck "under share, slack → ADMIT"        "$(bp_verdict 4 2 2 1)" ADMIT
  ck "AT fair share, peer idle → WAIT"   "$(bp_verdict 4 2 2 2)" WAIT
  ck "over share → WAIT"                 "$(bp_verdict 4 2 3 3)" WAIT
  ck "global exhausted → SATURATED"      "$(bp_verdict 4 2 4 2)" SATURATED

  echo "== bp_verdict — over-subscription N=5, budget 3 (each capped at 1; excess sessions saturate) =="
  ck "idle session, slack → ADMIT"       "$(bp_verdict 3 5 2 0)" ADMIT
  ck "session at its 1-unit share → WAIT" "$(bp_verdict 3 5 2 1)" WAIT
  ck "global full, session idle → SATURATED" "$(bp_verdict 3 5 3 0)" SATURATED

  echo "== bp_verdict — input validation =="
  ck "zero budget → ERR"                 "$(bp_verdict 0 2 0 0)" ERR
  ck "non-numeric total → ERR"           "$(bp_verdict 4 2 x 0)" ERR
  ck "non-numeric session → ERR"         "$(bp_verdict 4 2 0 y)" ERR

  echo; echo "back-pressure selftest: $p passed, $f failed"
  [ "$f" -eq 0 ]; exit
fi

# ---- CLI DISPATCH ----------------------------------------------------------------------------------
cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  fair-share)
    fs="$(bp_fair_share "${1:-}" "${2:-}")"
    [ "$fs" = ERR ] && { log "fair-share: bad args (need <budget≥1> <n>)"; exit 2; }
    printf '%s\n' "$fs"; exit 0
    ;;
  live-sessions)
    bp_live_sessions; printf '\n'; exit 0
    ;;
  decide)
    budget="${1:-}"; n="${2:-}"; total="${3:-}"; session="${4:-}"; label="${5:-shared budget}"
    v="$(bp_verdict "$budget" "$n" "$total" "$session")"
    case "$v" in
      ADMIT)
        printf 'ADMIT\n'; exit 0;;
      WAIT)
        fs="$(bp_fair_share "$budget" "$n")"
        log "WAIT — session at its fair share of $label (session=$session ≥ fair=$fs of budget=$budget across n=$n sessions); yielding so no peer starves (R29/R39, no silent cap R37)"
        printf 'WAIT — session at fair share (session=%s ≥ fair=%s, budget=%s, n=%s)\n' "$session" "$fs" "$budget" "$n"
        exit 10;;
      SATURATED)
        log "SATURATED — $label exhausted (in_flight=$total ≥ budget=$budget, n=$n sessions); back-pressuring, retry later (R39; SIGNALLED per R37 — no silent cap)"
        printf 'SATURATED — %s exhausted (in_flight=%s ≥ budget=%s, n=%s)\n' "$label" "$total" "$budget" "$n"
        exit 20;;
      *)
        log "decide: bad args — usage: decide <budget≥1> <n> <total-in-flight> <session-in-flight> [label]"
        exit 2;;
    esac
    ;;
  *)
    echo "usage: back-pressure.sh decide <budget> <n> <total-in-flight> <session-in-flight> [label] | fair-share <budget> <n> | live-sessions | --selftest" >&2
    exit 2
    ;;
esac
