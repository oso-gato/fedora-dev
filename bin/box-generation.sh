#!/usr/bin/env bash
# box-generation.sh — THE GENERATION FENCE: a service must not keep running inside a container that
# no longer exists.
#
# WHY THIS EXISTS (the 2026-07-28 sterile-loop outage). The box was rebuilt at 06:21:33 into container
# 23b54ca4. The OLD container 88875de5 was torn down — but three service chains kept running inside its
# destroyed rootfs: poller-service (started Wed Jul 22), apparatus-deadman, dev-loop. Their base-level
# supervise loops in entrypoint.sh could not relaunch them, because each loop blocks on a
# `distrobox enter` child that can never exit. The wedge had stood for SIX DAYS.
#
# The failure mode is the nasty one: a torn-down overlay keeps working for anything already resolved,
# and fails only for what must be looked up fresh. `bash`, `date`, `grep` kept working. `gh` — installed
# into the deleted upper layer — vanished. So the poller stayed alive, kept logging, kept sweeping, and
# every single sweep failed. Worse, the then-live halt reader read its signal ONLY through `gh api`, so a missing
# binary self-inflicted a fleet-wide R9 HALT (395 consecutive unreadable reads), which then gated the
# very ticket that could have repaired the box, and collapsed R16 scope from 7 repos to 2.
#
# EVERY health signal read HEALTHY throughout: the process was alive, the log was fresh, the clone was
# not behind. The deadman itself was inside the same corpse, so the watcher was as blind as the watched.
#
# THE RULE THIS ENFORCES: a service that has lost its own filesystem must DIE, not degrade. Dying is
# recoverable — the supervise loop re-enters the live box and relaunches. Degrading is not: it looks
# healthy while doing nothing, which is precisely the state no other axis can see.
#
#   box-generation.sh check          rc 0 = current, rc 92 = orphaned/deps-lost (logs the reason), rc 0 on UNKNOWN
#   box-generation.sh id             print this container's id
#   box-generation.sh live           print the live box's stamped id
#   box-generation.sh --selftest     exercise the pure core (no container, no I/O)
#
# FAIL DIRECTION — asymmetric ON PURPOSE. Only a DEFINITE mismatch is an orphan. An unreadable stamp, a
# stamp from before this fence existed, or an unreadable self-id is UNKNOWN ⇒ KEEP RUNNING. A fence that
# kills services on missing evidence would take the whole loop down the first time a marker was absent.
# The dependency probe is the opposite direction and deliberately so: a REQUIRED binary that cannot be
# resolved is positive proof this rootfs is broken, so that alone is fatal.
set -uo pipefail

BOX_STATE="${BOX_STATE:-$HOME/.local/state/claudebox}"
BOX_ASSEMBLED="${BOX_ASSEMBLED:-$BOX_STATE/.assembled}"
BOX_CONTAINERENV="${BOX_CONTAINERENV:-/run/.containerenv}"
# The binaries a fleet service CANNOT function without. `gh` is the whole point: every actuator in the
# apparatus reaches GitHub through it, and its absence is what turned a dead container into a fleet HALT.
BOX_REQUIRED_BINS="${BOX_REQUIRED_BINS:-gh git}"
BOX_ORPHAN_RC="${BOX_ORPHAN_RC:-92}"

# ---- PURE CORE (--selftest covers exactly this) ----------------------------------------------------
# bg_generation_verdict <self-id> <live-id> → CURRENT | ORPHAN | UNKNOWN
# ORPHAN requires BOTH ids to be present AND different — positive proof, never an inference from absence.
bg_generation_verdict(){
  local self="${1-}" live="${2-}"
  [ -n "$self" ] || { printf 'UNKNOWN\n'; return 0; }
  [ -n "$live" ] || { printf 'UNKNOWN\n'; return 0; }
  [ "$self" = "$live" ] && { printf 'CURRENT\n'; return 0; }
  printf 'ORPHAN\n'
}

# bg_deps_verdict <missing-bins> → OK | LOST
# A required binary that will not resolve is positive proof the rootfs is broken. Unlike the generation
# check this needs no marker, so it catches a torn-down container even on a box stamped before this
# fence shipped — which is exactly the box the 2026-07-28 outage happened on.
bg_deps_verdict(){
  local missing="${1-}"
  [ -n "${missing// /}" ] && { printf 'LOST\n'; return 0; }
  printf 'OK\n'
}

# bg_action <gen-verdict> <deps-verdict> → RUN | DIE
# Either positive proof is enough to die. UNKNOWN never kills.
bg_action(){
  local gen="${1-}" deps="${2-}"
  [ "$gen" = ORPHAN ] && { printf 'DIE\n'; return 0; }
  [ "$deps" = LOST ] && { printf 'DIE\n'; return 0; }
  printf 'RUN\n'
}

if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"; else f=$((f+1)); printf '  FAIL %s want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  echo "== generation verdict — ORPHAN needs POSITIVE proof, never an absence =="
  ck "same id is current"            "$(bg_generation_verdict abc abc)" "CURRENT"
  ck "THE 2026-07-28 CASE: different id is an orphan" "$(bg_generation_verdict 88875de5 23b54ca4)" "ORPHAN"
  ck "no self-id -> unknown, keep running"  "$(bg_generation_verdict '' 23b54ca4)" "UNKNOWN"
  ck "no stamp -> unknown, keep running"    "$(bg_generation_verdict 23b54ca4 '')" "UNKNOWN"
  ck "neither known -> unknown"             "$(bg_generation_verdict '' '')" "UNKNOWN"
  echo "== dependency verdict — a required binary that will not resolve proves a broken rootfs =="
  ck "nothing missing is OK"          "$(bg_deps_verdict '')" "OK"
  ck "whitespace only is OK"          "$(bg_deps_verdict '   ')" "OK"
  ck "THE 2026-07-28 CASE: gh missing is LOST" "$(bg_deps_verdict 'gh')" "LOST"
  ck "several missing is LOST"        "$(bg_deps_verdict 'gh git')" "LOST"
  echo "== action — either positive proof kills; UNKNOWN never does =="
  ck "orphan dies"                    "$(bg_action ORPHAN OK)" "DIE"
  ck "lost deps dies (even if generation is unknown)" "$(bg_action UNKNOWN LOST)" "DIE"
  ck "orphan AND lost dies"           "$(bg_action ORPHAN LOST)" "DIE"
  ck "current + ok runs"              "$(bg_action CURRENT OK)" "RUN"
  ck "UNKNOWN alone NEVER kills"      "$(bg_action UNKNOWN OK)" "RUN"
  ck "current with unknown deps runs" "$(bg_action CURRENT '')" "RUN"
  echo; echo "box-generation selftest: $p passed, $f failed"; [ "$f" -eq 0 ]; exit
fi

# ---- I/O -------------------------------------------------------------------------------------------
log(){ echo "box-generation: $*" >&2; }

# this container's id, from the runtime's own marker (authoritative, needs no engine call)
bg_self_id(){
  [ -r "$BOX_CONTAINERENV" ] || return 0
  local l; while IFS= read -r l; do
    case "$l" in id=\"*) l="${l#id=\"}"; printf '%s' "${l%\"}"; return 0 ;; esac
  done < "$BOX_CONTAINERENV"
}

# the LIVE box's id, stamped into .assembled by the assembler. Field 1 of the first line.
# A pre-fence .assembled has no id ⇒ empty ⇒ UNKNOWN ⇒ keep running (see FAIL DIRECTION).
bg_live_id(){
  [ -r "$BOX_ASSEMBLED" ] || return 0
  local first; read -r first _ < "$BOX_ASSEMBLED" 2>/dev/null || return 0
  case "$first" in
    ''|*[!0-9a-f]*) return 0 ;;   # not a container id (old marker held something else) ⇒ unknown
    *) [ "${#first}" -ge 12 ] && printf '%s' "$first" ;;
  esac
}

bg_missing_bins(){
  local b out=""
  for b in $BOX_REQUIRED_BINS; do command -v "$b" >/dev/null 2>&1 || out="$out $b"; done
  printf '%s' "${out# }"
}

case "${1:-check}" in
  id)   bg_self_id; echo ;;
  live) bg_live_id; echo ;;
  check)
    self="$(bg_self_id)"; live="$(bg_live_id)"; missing="$(bg_missing_bins)"
    gen="$(bg_generation_verdict "$self" "$live")"
    deps="$(bg_deps_verdict "$missing")"
    if [ "$(bg_action "$gen" "$deps")" = DIE ]; then
      # ONE loud line naming the real cause. The 2026-07-28 outage produced 700+ lines of
      # "gh: command not found" and not one that said why — this is the line that was missing.
      log "GENERATION-ORPHAN — this service is running inside a container that is no longer live."
      log "  self=${self:-<unreadable>} live=${live:-<unstamped>} generation=$gen missing-bins=${missing:-none} deps=$deps"
      log "  EXITING rc=$BOX_ORPHAN_RC so the supervise loop can re-enter the LIVE box and relaunch."
      log "  (A service that has lost its own rootfs must die, not degrade into a silent no-op.)"
      exit "$BOX_ORPHAN_RC"
    fi
    exit 0 ;;
  *) echo "usage: box-generation.sh {check|id|live|--selftest}" >&2; exit 2 ;;
esac
