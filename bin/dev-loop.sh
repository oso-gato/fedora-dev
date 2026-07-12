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
# It is DETERMINISTIC and idempotent by construction:
#   * discovery is one `gh issue list --label backlog --state open` (no local list to maintain);
#   * dev-author's own per-(repo,issue) marker + "is there already an open PR?" guard make a re-run a
#     no-op for anything already authored — so the loop can run on a timer without double-authoring;
#   * a BLOCKED/no-progress author surfaces a dev-task question on its issue and the driver moves on
#     (one stuck feature never blocks the rest); the human is engaged only by those questions (R13).
#
#   dev-loop.sh <repo> [--once]   drive the backlog for <repo> (default: one full pass, then exit)
#   dev-loop.sh --watch <repo>    keep draining the backlog on an interval (LOOP_INTERVAL, default 300s)
#   dev-loop.sh --selftest        exercise the pure helpers (no gh / author / network)
#
# ENV: ORG (default oso-gato); BACKLOG_LABEL (default backlog); DEV_AUTHOR (default the sibling
#      bin/dev-author.sh, overridable for the mock test); LOOP_INTERVAL (--watch cadence, default 300);
#      MAX_PER_PASS (safety cap on authors spawned per pass, default 5 — a runaway-planner backstop).
set -uo pipefail

ORG="${ORG:-oso-gato}"
BACKLOG_LABEL="${BACKLOG_LABEL:-backlog}"
LOOP_INTERVAL="${LOOP_INTERVAL:-300}"
MAX_PER_PASS="${MAX_PER_PASS:-5}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DEV_AUTHOR="${DEV_AUTHOR:-$HERE/dev-author.sh}"

log(){ printf '[%s] dev-loop: %s\n' "$(date -u +%H:%M:%S 2>/dev/null || echo --:--:--)" "$*" >&2; }

# ---- PURE HELPERS (--selftest covers exactly these) ------------------------------------------------

# parse_backlog <newline-list-of-issue-numbers> → the numbers, sorted numeric-ascending, deduped, with
# any non-numeric line dropped (fail-safe: a garbled gh line never becomes a bogus issue number).
parse_backlog(){
  printf '%s\n' "$1" | grep -E '^[0-9]+$' | sort -n -u
}

# cap_list <count-cap> <newline-numbers> → the first <cap> numbers (the runaway-planner backstop; the
# rest are picked up on the next pass, so nothing is dropped — only deferred).
cap_list(){
  local cap="$1"; printf '%s\n' "$2" | grep -E '^[0-9]+$' | head -n "$cap"
}

# ---- SELFTEST --------------------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  echo "== parse_backlog (numeric-only, sorted, deduped) =="
  ck "sorts + dedupes"        "$(parse_backlog $'12\n3\n12\n7')" "$(printf '3\n7\n12')"
  ck "drops non-numeric junk" "$(parse_backlog $'5\nnot-a-number\n \n9')" "$(printf '5\n9')"
  ck "empty → empty"          "$(parse_backlog '')" ""
  echo "== cap_list (runaway backstop; defers, never drops) =="
  ck "caps to N"              "$(cap_list 2 $'1\n2\n3\n4')" "$(printf '1\n2')"
  ck "under cap → all"        "$(cap_list 5 $'1\n2')" "$(printf '1\n2')"
  echo; echo "dev-loop selftest: $p passed, $f failed"
  [ "$f" -eq 0 ]; exit
fi

# ---- ONE PASS over the backlog --------------------------------------------------------------------
one_pass(){ # <repo>
  local repo="$1" slug="$ORG/$1"
  local raw; raw="$(gh issue list --repo "$slug" --label "$BACKLOG_LABEL" --state open \
                    --json number -q '.[].number' 2>/dev/null)" \
    || { log "backlog query failed for $slug — skipping this pass"; return 0; }
  local nums; nums="$(cap_list "$MAX_PER_PASS" "$(parse_backlog "$raw")")"
  [ -n "$nums" ] || { log "$slug backlog is empty — nothing to author"; return 0; }
  local n acted=0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    log "→ authoring backlog $slug#$n via dev-author"
    # dev-author is fail-closed + idempotent: already-authored / non-backlog / has-PR issues are skipped
    # inside it, so the driver need not track state. A non-zero exit (BLOCKED/no-progress) is logged and
    # the loop CONTINUES — one stuck feature must never wedge the rest.
    if "$DEV_AUTHOR" "$repo" "$n" >/dev/null 2>&1; then acted=$((acted+1))
    else log "  dev-author returned non-zero for $slug#$n (BLOCKED/no-progress/skip) — continuing"; fi
  done <<<"$nums"
  log "$slug pass complete — $acted author run(s) reached the pipeline"
}

# ---- ENTRY -----------------------------------------------------------------------------------------
if [ "${1:-}" = "--watch" ]; then
  REPO="${2:?usage: dev-loop.sh --watch <repo>}"
  log "watch mode: draining $ORG/$REPO backlog every ${LOOP_INTERVAL}s"
  while :; do one_pass "$REPO"; sleep "$LOOP_INTERVAL"; done
else
  REPO="${1:?usage: dev-loop.sh <repo> [--once] | --watch <repo> | --selftest}"
  case "${2:-}" in
    ''|--once) : ;;  # one pass IS the default; --once names it explicitly (timer-unit friendliness)
    *) log "unknown argument '$2' (usage: dev-loop.sh <repo> [--once] | --watch <repo> | --selftest)"; exit 2 ;;
  esac
  one_pass "$REPO"
fi
