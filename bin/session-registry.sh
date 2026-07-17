#!/usr/bin/env bash
# session-registry.sh — the durable SESSION→SCOPE registry (R27) + pairwise-DISJOINT enforcement (R28).
#
# WHY: with more than one agent session live at once, two sessions acting on the SAME repo can stomp
# each other's branches (the 2026-06-28 cross-branch-leak class, multiplied). So each session DECLARES
# the repo-set it is working, the declaration is stored durably + concurrency-safe under flock, and a
# claim is DENIED (R28) if it intersects any OTHER currently-LIVE session's scope — pairwise-disjoint by
# construction. Liveness is the lock-lib adjudication (bin/lock-lib.sh via bin/session-id.sh): a repo
# held only by a DEAD session is FREE (its holder's /proc starttime is gone), and stale entries are
# reaped, so a crashed or torn-down session never wedges a repo forever.
#
# STORE: one file per session under ${SCOPE_REGISTRY_DIR:-$HOME/.local/state/scope-registry}, named by
# the (sanitized) SID, up to FOUR lines: <sid> / <liveness-record> / <repo…> / <backing-ref>. The 4th
# line (R16, added 2026-07-16) is the git-anchored BACKING REF '<repo> <objective-path> <confirmed-sha>'
# the READER re-verifies the cached repos against — this store stays a DUMB cache; the AUTHORITY is git.
# A pre-backing 3-line entry (or a '-' 4th line) has NO backing and the reader fails it closed (UNBACKED).
# All mutation is serialized by a single flock on the store's `.lock` — real cross-process mutex.
#
# SUBCOMMANDS:
#   register [--backing '<repo> <path> <sha>'] <sid> <repo…>
#                            record the session's scope + its liveness coordinates (+ optional backing
#                            ref). DENIED (rc 1) if the requested repo-set intersects ANY OTHER live
#                            session (R28 — the --backing flag never joins that check). Re-registering
#                            the same SID replaces its own scope (it never conflicts with itself).
#   resolve  <sid>           print that session's repo-set (its own only).
#   resolve-backing <sid>    print that session's BACKING REF line (empty if unregistered / no backing).
#   release  <sid>           remove that session's entry.
#   list                     list LIVE sessions and their scopes (TSV: sid<TAB>repos).
#   reap                     remove entries whose holder is DEAD (per lock-lib liveness), freeing repos.
#   --selftest               exercise register/resolve/resolve-backing/release/list/reap + disjointness.
#
# PURE HELPERS (R28; sourceable + selftested): disjoint <A…> -- <B…> · overlaps <A…> -- <B…>.
#
# ENV: SCOPE_REGISTRY_DIR (store dir; TESTS MUST override to a tempdir) · SESSION_HOLDER_PID (the pid
#      whose liveness backs a register — default `$$`; the seam that binds a session to its long-lived
#      holder process, and the test's dying-holder hook).

# Harden options ONLY when executed directly — sourcing must not clobber the parent's `set -e`.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then set -uo pipefail; fi

_SR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=session-id.sh
. "$_SR_DIR/session-id.sh"    # → session_id / session_coords / session_coords_alive (+ lock-lib)

# ---- PURE HELPERS (R28) — --selftest covers exactly these ------------------------------------------
# _intersect <A…> -- <B…> → the names present in BOTH sets, one per line. The `--` argument separates
# the two space-listed sets.
_intersect(){
  local -a A=() B=(); local seen=0 x
  for x in "$@"; do
    if [ "$seen" = 0 ] && [ "$x" = "--" ]; then seen=1; continue; fi
    if [ "$seen" = 0 ]; then A+=("$x"); else B+=("$x"); fi
  done
  local a b
  for a in ${A[@]+"${A[@]}"}; do
    [ -n "$a" ] || continue
    for b in ${B[@]+"${B[@]}"}; do
      [ "$a" = "$b" ] && { printf '%s\n' "$a"; break; }
    done
  done
}
# overlaps <A…> -- <B…> → prints the intersection; rc 0 iff the sets intersect.
overlaps(){ local out; out="$(_intersect "$@")"; [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }; return 1; }
# disjoint <A…> -- <B…> → rc 0 iff the sets share NOTHING (prints nothing).
disjoint(){ [ -z "$(_intersect "$@")" ]; }

# ---- STORE plumbing (assume the flock is held by _run_locked) --------------------------------------
_regdir(){ printf '%s' "${SCOPE_REGISTRY_DIR:-$HOME/.local/state/scope-registry}"; }
_key(){ local k="${1//[^A-Za-z0-9._-]/_}"; printf '%s' "${k:-_}"; }   # SID → safe filename stem
_entry(){ printf '%s/%s.session' "$(_regdir)" "$(_key "$1")"; }
_read_sid(){    sed -n '1p' "$1" 2>/dev/null; }
_read_record(){ sed -n '2p' "$1" 2>/dev/null; }
_read_repos(){  sed -n '3p' "$1" 2>/dev/null; }
_read_backing(){ sed -n '4p' "$1" 2>/dev/null; }   # line 4 = the R16 BACKING REF '<repo> <path> <sha>'
                                                    # (absent on a pre-backing 3-line entry ⇒ empty)

# run "$@" with the store's exclusive flock held (real cross-process mutex). The impl operates lockless.
_run_locked(){
  local d; d="$(_regdir)"; mkdir -p "$d"
  ( flock 9 || exit 3; "$@" ) 9>"$d/.lock"
}

# remove dead-holder entries (a repo held only by a dead session is free). Silent; used by register.
_reap_locked(){
  local f rec
  for f in "$(_regdir)"/*.session; do
    [ -e "$f" ] || continue
    rec="$(_read_record "$f")"
    [ "$(session_coords_alive "$rec")" = DEFER ] || rm -f "$f"
  done
}

# ---- SUBCOMMAND impls ------------------------------------------------------------------------------
_reg_impl(){ # [--backing '<repo> <path> <sha>'] <sid> <repo…>
  # The OPTIONAL leading --backing flag records the R16 git-anchored authority (repo + objective-doc
  # path + maintainer-confirmed sha) the read-path re-verifies the cached repos against; absent ⇒ '-'
  # (a pre-backing entry — the reader fails it closed as UNBACKED, R16). Parsed FIRST so it is never
  # swallowed into the variadic sid+repos or the R28 disjoint check.
  local backing="-"
  if [ "${1:-}" = "--backing" ]; then backing="${2:-}"; shift 2 2>/dev/null || shift "$#"; fi
  [ -n "$backing" ] || backing="-"
  local sid="${1:-}"; shift || true
  [ -n "$sid" ] && [ "$#" -ge 1 ] || { echo "session-registry: register needs <sid> and at least one repo" >&2; return 2; }
  local key; key="$(_key "$sid")"
  _reap_locked                                   # free any repos held only by dead sessions first
  # R28 pairwise-disjoint: deny if the request intersects ANY OTHER live session's scope.
  local f other conflict="" conflict_sid=""
  for f in "$(_regdir)"/*.session; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "$key.session" ] && continue      # never conflict with ourselves
    other="$(_read_repos "$f")"
    local c; c="$(overlaps "$@" -- $other)" || continue      # rc 0 ⇒ they intersect
    conflict="$(printf '%s' "$c" | tr '\n' ' ')"; conflict_sid="$(_read_sid "$f")"; break
  done
  if [ -n "$conflict" ]; then
    echo "session-registry: DENY register '$sid' — repo(s) [${conflict% }] already held by live session '$conflict_sid'" >&2
    return 1
  fi
  { printf '%s\n' "$sid"; printf '%s\n' "$(session_coords)"; printf '%s\n' "$*"; printf '%s\n' "$backing"; } > "$(_entry "$sid")"
  echo "session-registry: registered '$sid' → $* (backing: $backing)"
}

_resolve_impl(){ # <sid>
  local sid="${1:-}"; [ -n "$sid" ] || { echo "session-registry: resolve needs <sid>" >&2; return 2; }
  local f; f="$(_entry "$sid")"; [ -e "$f" ] || return 0
  _read_repos "$f"
}

_resolve_backing_impl(){ # <sid> → the session's BACKING REF line (empty if unregistered or pre-backing 3-line)
  local sid="${1:-}"; [ -n "$sid" ] || { echo "session-registry: resolve-backing needs <sid>" >&2; return 2; }
  local f; f="$(_entry "$sid")"; [ -e "$f" ] || return 0
  local b; b="$(_read_backing "$f")"; [ "$b" = "-" ] && return 0   # '-' sentinel ⇒ no backing, print nothing
  printf '%s' "$b"
}

_refresh_impl(){ # <sid> — rewrite ONLY line-2 coords to the CURRENT holder (SESSION_HOLDER_PID/$$),
  # preserving line-3 repos + line-4 backing. A RESUMED session (new pid, same sid) calls this so its
  # entry stays LIVE and a later register()'s reap does not free its still-held scope. No entry ⇒ no-op.
  local sid="${1:-}"; [ -n "$sid" ] || { echo "session-registry: refresh needs <sid>" >&2; return 2; }
  local f; f="$(_entry "$sid")"; [ -e "$f" ] || return 0
  local repos backing; repos="$(_read_repos "$f")"; backing="$(_read_backing "$f")"
  { printf '%s\n' "$sid"; printf '%s\n' "$(session_coords)"; printf '%s\n' "$repos"; printf '%s\n' "$backing"; } > "$f"
  echo "session-registry: refreshed liveness for '$sid'"
}

_release_impl(){ # <sid>
  local sid="${1:-}"; [ -n "$sid" ] || { echo "session-registry: release needs <sid>" >&2; return 2; }
  rm -f "$(_entry "$sid")"
  echo "session-registry: released '$sid'"
}

_list_impl(){
  local f rec
  for f in "$(_regdir)"/*.session; do
    [ -e "$f" ] || continue
    rec="$(_read_record "$f")"
    [ "$(session_coords_alive "$rec")" = DEFER ] || continue   # list LIVE sessions only (no mutation)
    printf '%s\t%s\n' "$(_read_sid "$f")" "$(_read_repos "$f")"
  done
}

_reap_impl(){
  local f rec n=0
  for f in "$(_regdir)"/*.session; do
    [ -e "$f" ] || continue
    rec="$(_read_record "$f")"
    if [ "$(session_coords_alive "$rec")" != DEFER ]; then
      echo "session-registry: reaped dead session '$(_read_sid "$f")'"; rm -f "$f"; n=$((n+1))
    fi
  done
  [ "$n" = 0 ] && echo "session-registry: reap — no dead sessions"
  return 0
}

_usage(){ echo "usage: session-registry.sh register [--backing '<repo> <path> <sha>'] <sid> <repo…> | resolve <sid> | resolve-backing <sid> | refresh <sid> | release <sid> | list | reap | --selftest" >&2; }

# ===================================================================================================
# DIRECT-EXECUTION: CLI dispatch + selftest. Sourcing loads the functions (incl. the R28 pure helpers)
# and does nothing else.
# ===================================================================================================
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "${1:-}" = "--selftest" ]; then
    fail=0; ok(){ echo "ok: $1"; }; bad(){ echo "FAIL: $1"; fail=1; }
    export SCOPE_REGISTRY_DIR; SCOPE_REGISTRY_DIR="$(mktemp -d)"
    HOLDERS=""
    cleanup(){ kill $HOLDERS >/dev/null 2>&1 || true; rm -rf "$SCOPE_REGISTRY_DIR"; }
    trap cleanup EXIT
    # detach the holder's std fds — else the backgrounded sleep inherits the $(…) command-sub pipe
    # and the capture blocks for the full 300 s waiting for an EOF that never comes.
    live_holder(){ sleep 300 </dev/null >/dev/null 2>&1 & local p=$!; HOLDERS="$HOLDERS $p"; printf '%s' "$p"; }

    echo "== pure helpers (R28) =="
    disjoint a b -- c d          && ok "disjoint sets are disjoint"        || bad "disjoint mis-scored disjoint sets"
    disjoint a b -- b c          && bad "disjoint scored overlapping sets as disjoint" || ok "disjoint rejects overlapping sets"
    overlaps a b -- b c >/dev/null && ok "overlaps detects a shared name"  || bad "overlaps missed a shared name"
    overlaps a b -- c d >/dev/null && bad "overlaps invented an overlap"   || ok "overlaps finds nothing in disjoint sets"
    [ "$(overlaps a b c -- x b y)" = b ] && ok "overlaps prints the shared name" || bad "overlaps printed the wrong intersection"

    echo "== register / resolve / disjointness deny =="
    HPA="$(live_holder)"; HPB="$(live_holder)"
    SESSION_HOLDER_PID="$HPA" _run_locked _reg_impl sidA repo-one >/dev/null && ok "register sidA→repo-one" || bad "register sidA failed"
    SESSION_HOLDER_PID="$HPB" _run_locked _reg_impl sidB repo-two >/dev/null && ok "register sidB→repo-two (disjoint)" || bad "register sidB failed"
    [ "$(_run_locked _resolve_impl sidA)" = repo-one ] && ok "resolve sidA = repo-one" || bad "resolve sidA wrong"
    [ "$(_run_locked _resolve_impl sidB)" = repo-two ] && ok "resolve sidB = repo-two" || bad "resolve sidB wrong"

    echo "== backing ref (R16 4th line — backward-compatible with the 3-line readers) =="
    [ -z "$(_run_locked _resolve_backing_impl sidA)" ] && ok "a 3-line entry has NO backing (empty)" || bad "3-line entry leaked a backing"
    SESSION_HOLDER_PID="$HPA" _run_locked _reg_impl --backing 'fedora-dev 00-OBJECTIVES.md deadbeef' sidA repo-one >/dev/null \
      && ok "register --backing sidA" || bad "register --backing failed"
    [ "$(_run_locked _resolve_backing_impl sidA)" = 'fedora-dev 00-OBJECTIVES.md deadbeef' ] \
      && ok "resolve-backing round-trips the ref" || bad "resolve-backing lost the ref"
    [ "$(_run_locked _resolve_impl sidA)" = repo-one ] && ok "resolve (line 3) UNAFFECTED by the added line 4" || bad "line 4 corrupted resolve"
    [ "$(_run_locked _list_impl | grep -c .)" = 2 ] && ok "list UNAFFECTED by line 4 (still 2 live)" || bad "line 4 broke list"

    echo "== refresh (resumed session: NEW coords, scope + backing PRESERVED) =="
    HPR="$(live_holder)"
    bR="$(_run_locked _resolve_impl sidA)"; bB="$(_run_locked _resolve_backing_impl sidA)"
    SESSION_HOLDER_PID="$HPR" _run_locked _refresh_impl sidA >/dev/null && ok "refresh sidA under a new holder pid" || bad "refresh failed"
    [ "$(_run_locked _resolve_impl sidA)" = "$bR" ] && ok "refresh PRESERVED repos (line 3)" || bad "refresh lost repos"
    [ "$(_run_locked _resolve_backing_impl sidA)" = "$bB" ] && ok "refresh PRESERVED backing (line 4)" || bad "refresh lost backing"
    grep -q "^$HPR " "$(_entry sidA)" && ok "refresh WROTE the new holder's coords (line 2)" || bad "refresh did not update coords"
    _run_locked _refresh_impl nosuchsid >/dev/null 2>&1 && ok "refresh of an unregistered sid is a safe no-op (rc 0)" || bad "refresh of a missing sid errored"
    # re-point sidA back to HPA so the reap section below (which kills HPA) still frees it
    SESSION_HOLDER_PID="$HPA" _run_locked _refresh_impl sidA >/dev/null
    if SESSION_HOLDER_PID="$HPB" _run_locked _reg_impl sidB repo-one 2>/dev/null; then
      bad "sidB claimed repo-one while live sidA holds it — R28 deny missing"
    else ok "sidB DENIED repo-one (held by live sidA)"; fi
    [ "$(_run_locked _resolve_impl sidB)" = repo-two ] && ok "a denied register did not mutate sidB" || bad "denied register corrupted sidB"

    echo "== list (live only) =="
    [ "$(_run_locked _list_impl | wc -l)" = 2 ] && ok "list shows both live sessions" || bad "list did not show 2 live sessions"

    echo "== reap frees a dead holder's repos =="
    kill "$HPA" 2>/dev/null; wait "$HPA" 2>/dev/null || true
    _run_locked _reap_impl >/dev/null
    [ -z "$(_run_locked _resolve_impl sidA)" ] && ok "reap released dead sidA's claim" || bad "reap did not release sidA"
    [ "$(_run_locked _list_impl | wc -l)" = 1 ] && ok "list now shows only the live session" || bad "list still shows the reaped session"
    SESSION_HOLDER_PID="$HPB" _run_locked _reg_impl sidB repo-one >/dev/null && ok "sidB now claims repo-one (freed by reap)" || bad "sidB could not claim the freed repo"
    [ "$(_run_locked _resolve_impl sidB)" = repo-one ] && ok "sidB scope replaced with repo-one" || bad "sidB scope not replaced"

    echo "== release =="
    _run_locked _release_impl sidB >/dev/null
    [ -z "$(_run_locked _resolve_impl sidB)" ] && ok "release removed sidB" || bad "release did not remove sidB"

    [ "$fail" = 0 ] && echo "ALL SESSION-REGISTRY SELFTESTS PASS" || echo "SESSION-REGISTRY SELFTESTS FAILED"
    exit "$fail"
  fi

  cmd="${1:-}"; shift 2>/dev/null || true
  case "$cmd" in
    register) _run_locked _reg_impl "$@";;
    resolve)  _run_locked _resolve_impl "$@";;
    resolve-backing) _run_locked _resolve_backing_impl "$@";;
    refresh)  _run_locked _refresh_impl "$@";;
    release)  _run_locked _release_impl "$@";;
    list)     _run_locked _list_impl "$@";;
    reap)     _run_locked _reap_impl "$@";;
    *) _usage; exit 2;;
  esac
fi
