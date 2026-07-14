#!/usr/bin/env bash
# session-id.sh — the multi-session KEYSTONE (R3): mint a STABLE, liveness-bound session id.
#
# WHY: multi-session isolation needs one durable name per agent session that (a) is STABLE for a
# process's whole life (so every actuator in that session agrees which scope it holds) and (b) DIFFERS
# across boots and box-generations (so a name from a torn-down box can never be mistaken for a live
# peer's). The id alone cannot prove liveness — a name is not a heartbeat — so this also emits the
# session's liveness COORDINATES (the exact `pid boot starttime gen` record bin/lock-lib.sh adjudicates),
# which bin/session-registry.sh stores so a reaper can later decide the holder alive or dead.
#
# SOURCEABLE — sourcing defines the functions and nothing else; run directly with --selftest.
#
# EXPORTS:
#   session_id                → the SID, chosen by source order: (1) `${CLAUDE_SESSION_ID}` verbatim
#                               when set (the explicit/test override); else (2) the SANITIZED
#                               `${CLAUDE_CODE_SESSION_ID}` when set — the REAL per-session id claude-code
#                               exports (a UUID, inherited by every subprocess), so all of a session's
#                               actuators agree on ONE name; else (3) a deterministic token derived from
#                               ll_box_gen + ll_boot_id + this process's pid. Stable within a process
#                               (pid is constant, `$$` is unchanged in a subshell); differs across
#                               boots/box-generations. Every form is a safe token matching [A-Za-z0-9._-]+.
#   session_coords [pid]      → the liveness record `pid boot starttime gen` for <pid> (default the
#                               HOLDER pid — SESSION_HOLDER_PID if set, else `$$`), '-' for any empty
#                               field. This is exactly what lock_verdict consumes.
#   session_coords_alive <record>
#                             → feeds <record> to lock_verdict against the CURRENT boot/gen and the
#                               recorded pid's live starttime → DEFER (holder alive) | TAKEOVER_* (dead/
#                               stale). The reaper's alive/dead primitive.
#
# ENV SEAMS:
#   CLAUDE_SESSION_ID       an explicit override — used VERBATIM as the SID when non-empty (test/manual
#                           seam; outranks the real source below).
#   CLAUDE_CODE_SESSION_ID  the REAL per-session id claude-code sets in the agent's environment (a UUID,
#                           inherited by subprocesses). When CLAUDE_SESSION_ID is unset this is the SID,
#                           run through _session_sanitize — the production source that makes every
#                           actuator in one session share ONE stable name.
#   SESSION_HOLDER_PID      the pid whose liveness backs this session (default `$$`); the seam that binds
#                           a session to a long-lived holder process (and the test's dying-holder hook).

# Harden options ONLY when executed directly — sourcing must not clobber the parent's `set -e`.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then set -uo pipefail; fi

# Locate + source the liveness library relative to THIS file (works sourced or executed).
_SI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lock-lib.sh
. "$_SI_DIR/lock-lib.sh"

# _session_sanitize <s> — reduce to the safe token grammar [A-Za-z0-9._-]; empty ⇒ 'x' placeholder so
# a component never collapses a field boundary in the SID.
_session_sanitize(){ local s="${1//[^A-Za-z0-9._-]/}"; printf '%s' "${s:-x}"; }

# session_id — deterministic + stable within a process; source order: explicit override → the REAL
# claude-code session id → the computed fallback.
session_id(){
  # (1) explicit/test override — used VERBATIM (never sanitized: the caller owns the exact bytes).
  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then printf '%s' "$CLAUDE_SESSION_ID"; return 0; fi
  # (2) the REAL per-session id claude-code exports (a UUID, inherited by subprocesses). SANITIZED to the
  # safe token grammar so it can never collapse a field boundary in a stamped ticket. This is the
  # production source: every actuator in one session reads the SAME env var → the SAME stable SID.
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then _session_sanitize "$CLAUDE_CODE_SESSION_ID"; return 0; fi
  # (3) box-generation + boot-id + pid: box_gen/boot_id are stable for a box-incarnation; `$$` is constant
  # for the process (and unchanged inside a subshell), so repeated calls are byte-identical. Starttime
  # is deliberately EXCLUDED — it flutters ±1 tick between reads, which would break stability. This
  # PER-PROCESS fallback differs across every process, so it is a last resort only (no session env).
  printf 's.%s.%s.%s' "$(_session_sanitize "$(ll_box_gen)")" "$(_session_sanitize "$(ll_boot_id)")" "$$"
}

# session_coords [pid] — the liveness record for the holder pid.
session_coords(){ # [pid]
  local pid="${1:-${SESSION_HOLDER_PID:-$$}}"
  local b s g
  b="$(ll_boot_id)"; s="$(ll_proc_start "$pid")"; g="$(ll_box_gen)"
  # '-' placeholders keep the whitespace-framed record parseable when a field is unreadable (the
  # lock_verdict writer contract).
  printf '%s %s %s %s' "$pid" "${b:--}" "${s:--}" "${g:--}"
}

# session_coords_alive <record> — DEFER (holder alive) | TAKEOVER_* (dead/stale/foreign-gen).
session_coords_alive(){ # <record-line>
  local rec="$1" rpid nowstart=""
  read -r rpid _ <<<"$rec"
  case "${rpid:-}" in ''|*[!0-9]*) : ;; *) nowstart="$(ll_proc_start "$rpid")";; esac
  lock_verdict "$rec" "$(ll_boot_id)" "$nowstart" "$(ll_box_gen)"
}

# ---- SELFTEST (direct-execution only) --------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = "--selftest" ]; then
  fail=0
  ok(){ echo "ok: $1"; }
  bad(){ echo "FAIL: $1"; fail=1; }

  # HERMETIC: the computed-fallback cases below must exercise source (3), so clear BOTH real session
  # seams from the ambient env (the box exports CLAUDE_CODE_SESSION_ID — leaving it set would make
  # session_id return the sanitized UUID and mask the computed path). Each override case re-sets its
  # own var in a subshell prefix, so unsetting here scopes cleanly.
  unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

  # STABLE within a process: repeated calls (incl. through a subshell) are byte-identical.
  a="$(session_id)"; b="$(session_id)"
  [ "$a" = "$b" ] && ok "session_id is stable across repeated calls ($a)" || bad "session_id changed between calls ('$a' vs '$b')"

  # FORMAT: the default (computed) SID is a safe token.
  case "$a" in
    *[!A-Za-z0-9._-]*) bad "default SID is not a safe [A-Za-z0-9._-]+ token ('$a')";;
    '') bad "default SID is empty";;
    *) ok "default SID is a safe token";;
  esac

  # OVERRIDE respected verbatim.
  ov="$(CLAUDE_SESSION_ID='my-Session_1.2' session_id)"
  [ "$ov" = 'my-Session_1.2' ] && ok "CLAUDE_SESSION_ID override is used verbatim" || bad "override not honoured (got '$ov')"

  # REAL claude-code source (2): with CLAUDE_CODE_SESSION_ID set and CLAUDE_SESSION_ID unset, session_id
  # returns the SANITIZED CLAUDE_CODE_SESSION_ID and is byte-identical across repeated calls — the
  # cross-invocation stability the whole ticket-isolation scheme rests on.
  ccid='4b6b113d-fc1f-4e75-a545-745c626c9ac9'
  cc1="$(CLAUDE_CODE_SESSION_ID="$ccid" session_id)"; cc2="$(CLAUDE_CODE_SESSION_ID="$ccid" session_id)"
  [ "$cc1" = "$ccid" ] && ok "CLAUDE_CODE_SESSION_ID (sanitized) is the SID when CLAUDE_SESSION_ID is unset ($cc1)" \
    || bad "CLAUDE_CODE_SESSION_ID not used as the SID (got '$cc1')"
  [ "$cc1" = "$cc2" ] && ok "CLAUDE_CODE_SESSION_ID-derived SID is byte-identical across calls" \
    || bad "CLAUDE_CODE_SESSION_ID SID changed between calls ('$cc1' vs '$cc2')"
  # the sanitizer IS applied on this path (unsafe chars dropped to the safe token grammar).
  ccs="$(CLAUDE_CODE_SESSION_ID='ab/cd 12:34' session_id)"
  [ "$ccs" = 'abcd1234' ] && ok "CLAUDE_CODE_SESSION_ID is sanitized to [A-Za-z0-9._-] ($ccs)" \
    || bad "CLAUDE_CODE_SESSION_ID was not sanitized (got '$ccs')"
  # PRECEDENCE: the explicit override still outranks the real source when both are set.
  prec="$(CLAUDE_SESSION_ID='explicit-1' CLAUDE_CODE_SESSION_ID="$ccid" session_id)"
  [ "$prec" = 'explicit-1' ] && ok "CLAUDE_SESSION_ID outranks CLAUDE_CODE_SESSION_ID when both set" \
    || bad "source order wrong — CLAUDE_SESSION_ID must win (got '$prec')"

  # DIFFERS across box-generations (the anti-orphan property): a different gen ⇒ a different SID.
  g1="$(POLLER_BOX_GEN=genA session_id)"; g2="$(POLLER_BOX_GEN=genB session_id)"
  [ "$g1" != "$g2" ] && ok "SID differs across box-generations" || bad "SID did not change with the box generation ('$g1')"

  # COORDS: the current holder is alive (DEFER); an impossible holder pid is dead.
  rec="$(session_coords)"
  [ "$(session_coords_alive "$rec")" = DEFER ] && ok "session_coords(self) adjudicates DEFER (alive)" \
    || bad "session_coords(self) did not adjudicate alive (rec='$rec')"
  deadrec="$(SESSION_HOLDER_PID=999999999 session_coords)"
  v="$(session_coords_alive "$deadrec")"
  case "$v" in TAKEOVER_*) ok "an impossible holder pid adjudicates dead ($v)";; *) bad "an impossible holder pid was not dead (got '$v')";; esac

  [ "$fail" = 0 ] && echo "ALL SESSION-ID SELFTESTS PASS" || echo "SESSION-ID SELFTESTS FAILED"
  exit "$fail"
fi
