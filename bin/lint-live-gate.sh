#!/usr/bin/env bash
# lint-live-gate.sh — Tier-1 (in-box) validation of a repo's `.live-gate` contract, BEFORE the
# host live-gate (Gate B) ever builds/runs it. Catches the class of contract bugs that the host's
# parser ACCEPTS but the host then chokes on at launch — e.g. an unexpanded cross-variable
# reference (`SECRET_MOUNT_grd="$_GD_SECRET_MOUNT"` resolves to the literal string
# `$_GD_SECRET_MOUNT` → podman "invalid container path"). Moving this to Tier-1 saves a wasted
# host round-trip (the whole point of two-tier validation: validate at the LOWEST tier that can).
#
# GRAMMAR = the host's EXACT parser: `lg_load` + `pt` are VENDORED VERBATIM from
# fedora-bootstrap/live-gate-run.sh (the canonical, control-plane `.live-gate` grammar — the
# contract is PARSED, never sourced). KEEP IN LOCKSTEP: if the host's lg_load/pt change, update
# this copy in the same effort. When the fedora-bootstrap clone is present locally, the soft
# drift-check below WARNs if the two have diverged.
#
# Usage: lint-live-gate.sh <repo-dir>
#   exit 0 = no `.live-gate` (nothing to lint), OR it is well-formed and every target resolves to
#            a sane, host-runnable contract.
#   exit 1 = a problem the host gate would hit — printed per-target so the agent iterates in-box.
#        lint-live-gate.sh --cfile <repo-dir>
#   print the FIRST declared target's resolved build file (CFILE) and exit 0 — the repo's OWN
#   contract, resolved by the SAME vendored lg_load the host uses. validate.sh consumes this (#180)
#   so a non-image repo that declares its build target (fedora-bootstrap's shellgate =>
#   Containerfile.livegate) is built from IT, never from a hardcoded second filename convention.
#   exit 1 + nothing on stdout when there is no .live-gate or it does not parse (the LINT mode,
#   which T0 gates, is where a parse failure gets EXPLAINED — this mode only answers "what file").
set -uo pipefail
MODE=lint; [ "${1:-}" = --cfile ] && { MODE=cfile; shift; }
REPO="${1:?usage: lint-live-gate.sh [--cfile] <repo-dir>}"
LG="$REPO/.live-gate"
if [ ! -f "$LG" ]; then
  [ "$MODE" = cfile ] && exit 1
  echo "lint-live-gate: no .live-gate in $REPO — nothing to lint"; exit 0
fi
fail=0; lg_reason=""
bad(){ echo "  [FAIL] $*"; fail=1; }
ok(){  echo "  [ok]   $*"; }

# ============================================================================================
# VENDORED VERBATIM from fedora-bootstrap/live-gate-run.sh — `lg_load` + `pt`. KEEP IN LOCKSTEP.
# (The host PARSES the contract line-by-line and assigns via `printf -v`; it never sources/evals.)
# ============================================================================================
lg_load(){
  local file="$1" line trimmed key rest body after more val
  local s i nn c nx closed remainder
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"          # strip leading whitespace for the tests below
    [ -z "$trimmed" ] && continue
    case "$trimmed" in '#'*) continue;; esac            # comment line
    case "$trimmed" in
      [A-Za-z_]*=*) : ;;
      *) lg_reason="line is not a KEY=VALUE assignment: ${trimmed:0:48}"; return 1;;
    esac
    key="${trimmed%%=*}"; rest="${trimmed#*=}"
    case "$key" in *[!A-Za-z0-9_]*) lg_reason="invalid key name: $key"; return 1;; esac
    case "$key" in                                       # schema-key allowlist (no arbitrary clobber)
      LIVE_GATE_TARGETS|HEALTH|CAND_*|CFILE_*|FENCE_*|HEALTH_*|PROBE_*|SECRET_MOUNT_*|SECRET_ENV_*|MEMORY_*|PIDS_*) : ;;
      *) echo "[live-gate] WARN: ignoring non-schema key in contract: $key"; continue;;
    esac
    case "$rest" in
      \'*)  # single-quoted: VERBATIM (single quotes neutralise $() ` && ; < > etc.)
        body="${rest#\'}"
        if [[ "$body" == *\'* ]]; then                  # closes on this line
          val="${body%%\'*}"
          after="${body#*\'}"; after="${after#"${after%%[![:space:]]*}"}"
          case "$after" in ''|'#'*) :;; *) lg_reason="trailing content after value for $key"; return 1;; esac
        else                                            # multi-line single-quoted (e.g. SECRET_ENV)
          val="$body"
          while IFS= read -r more || [ -n "$more" ]; do
            if [[ "$more" == *\'* ]]; then
              val+=$'\n'"${more%%\'*}"
              after="${more#*\'}"; after="${after#"${after%%[![:space:]]*}"}"
              case "$after" in ''|'#'*) :;; *) lg_reason="trailing content after multi-line value for $key"; return 1;; esac
              break
            fi
            val+=$'\n'"$more"
          done
        fi
        ;;
      \"*)  # double-quoted: scan to the first UNESCAPED " ; unescape only \" \$ \\ \` ; refuse $()/`
        s="${rest#\"}"; nn=${#s}; i=0; val=""; closed=0; remainder=""
        while (( i < nn )); do
          c="${s:i:1}"
          if [ "$c" = '\' ] && (( i+1 < nn )); then
            nx="${s:i+1:1}"
            case "$nx" in '"'|'$'|'\'|'`') val+="$nx"; i=$((i+2)); continue;; esac
            val+="$c"; i=$((i+1)); continue
          fi
          if [ "$c" = '"' ]; then closed=1; remainder="${s:i+1}"; break; fi
          val+="$c"; i=$((i+1))
        done
        (( closed )) || { lg_reason="unterminated double-quote for $key"; return 1; }
        remainder="${remainder#"${remainder%%[![:space:]]*}"}"
        case "$remainder" in ''|'#'*) :;; *) lg_reason="trailing content after value for $key"; return 1;; esac
        case "$val" in *'$('*|*'`'*) lg_reason="command substitution/backtick in value for $key (refused outside single quotes)"; return 1;; esac
        ;;
      *)  # unquoted: must be a single bare token (no whitespace / shell metacharacters)
        val="$rest"
        case "$val" in
          *[[:space:]]*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*|*'`'*|*'$'*|*'('*|*')'*)
            lg_reason="unsafe unquoted value for $key (quote it if it is meant literally)"; return 1;;
        esac
        ;;
    esac
    printf -v "$key" '%s' "$val"                         # assign literally — never eval
  done < "$file"
  return 0
}
pt(){ local v="${1}_${2}"; printf '%s' "${!v:-$3}"; }
# ============================================================================================
# end vendored
# ============================================================================================

# --cfile mode (#180): answer "what file does this repo say to build" and nothing else. lg_load's
# WARN lines (non-schema keys) go to stdout, so they are silenced here — the caller wants ONE token;
# the lint mode below is where contract problems get explained (and T0 gates it).
if [ "$MODE" = cfile ]; then
  lg_load "$LG" >/dev/null 2>&1 || exit 1
  read -r -a targets <<< "${LIVE_GATE_TARGETS:-default}"
  printf '%s\n' "$(pt CFILE "${targets[0]}" "${CAND_CFILE:-Containerfile}")"
  exit 0
fi

echo "== lint-live-gate: $LG =="

# soft drift-check — both repos are cloned on the dev box, so compare like-for-like source.
HOST_LGR="${FD_HOST_LGR:-$HOME/repos/fedora-bootstrap/live-gate-run.sh}"
if [ -f "$HOST_LGR" ]; then
  _h="$(sed -n '/^lg_load(){/,/^}/p' "$HOST_LGR" | tr -d '[:space:]')"
  _m="$(sed -n '/^lg_load(){/,/^}/p' "$0"        | tr -d '[:space:]')"
  if [ -n "$_h" ] && [ "$_h" = "$_m" ]; then ok "grammar parity: vendored lg_load matches fedora-bootstrap"
  else echo "  [WARN] vendored lg_load DIFFERS from $HOST_LGR — re-sync this file (control-plane grammar drift)"; fi
fi

# 1) does the contract PARSE? (the host rejects RED on any violation — same verdict here)
if ! lg_load "$LG"; then
  bad "contract REJECTED by lg_load — the host would RED it: $lg_reason"
  echo "VERDICT: RED"; exit 1
fi
ok "contract parses (lg_load accepted)"

read -r -a targets <<< "${LIVE_GATE_TARGETS:-default}"
echo "targets: ${targets[*]}"
for t in "${targets[@]}"; do
  echo "-- target [$t] --"
  cfile="$(pt CFILE "$t" "${CAND_CFILE:-Containerfile}")"
  fence="$(pt FENCE "$t" "${CAND_FENCE:-}")"
  health="$(pt HEALTH "$t" "${HEALTH:-}")"
  probe="$(pt PROBE "$t" "${CAND_PROBE:-}")"
  smount="$(pt SECRET_MOUNT "$t" "${CAND_SECRET_MOUNT:-}")"
  senv="$(pt SECRET_ENV "$t" "${CAND_SECRET_ENV:-}")"

  # CFILE must resolve to a file that exists in the repo
  if [ -f "$REPO/$cfile" ]; then ok "CFILE=$cfile exists"; else bad "CFILE=$cfile not found in $REPO"; fi

  # UNEXPANDED CROSS-VARIABLE REFERENCE (the $_GD_* bug): a resolved value that is a LONE bare
  # $VAR — the contract is parsed not sourced, so it stays the literal string and the host chokes.
  for kv in "HEALTH=$health" "PROBE=$probe" "SECRET_MOUNT=$smount" "SECRET_ENV=$senv" "FENCE=$fence"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$v" in
      '$'[A-Za-z_]*)
        case "$v" in
          *[[:space:]]*) : ;;   # has structure → a real command/value, not a lone reference
          *) bad "$k for [$t] is a bare unexpanded variable reference ($v) — the gate PARSES (never sources); INLINE the literal value (this is the \$_GD_* class)";;
        esac ;;
    esac
  done

  # SECRET_MOUNT must be a literal ABSOLUTE container path (podman -v needs it; $ means unexpanded)
  case "$smount" in
    "")  echo "  [warn] SECRET_MOUNT empty for [$t] (ok only if the entrypoint needs no secrets file)";;
    *'$'*) bad "SECRET_MOUNT=$smount for [$t] contains '\$' — must be a literal absolute path";;
    /*)  ok "SECRET_MOUNT=$smount (absolute)";;
    *)   bad "SECRET_MOUNT=$smount for [$t] is not absolute (podman -v needs an absolute path)";;
  esac

  # FENCE must not publish a port — the host gate is loopback-only and FAILS CLOSED on -p/--publish
  case " $fence " in
    *' -p '*|*' --publish '*|*' -P '*|*' --publish-all '*) bad "FENCE for [$t] carries a publish flag — the gate is loopback-only and fails closed";;
    *) [ -n "$fence" ] && ok "FENCE has no publish flag" || ok "FENCE empty (host default --network=none --cap-drop=ALL)";;
  esac

  [ -n "$health" ] || echo "  [warn] HEALTH empty for [$t] (host falls back to the image HEALTHCHECK)"
  [ -n "$probe" ]  || echo "  [warn] PROBE empty for [$t] (health-only gate — no access-path probe)"
done

echo "VERDICT: $([ $fail = 0 ] && echo GREEN || echo RED)   (Tier-1 contract lint)"
exit $fail
