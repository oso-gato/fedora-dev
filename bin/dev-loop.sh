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
# THE CAP BOUNDS AUTHOR RUNS, NOT THE ENUMERATION (this is load-bearing). `dev-author` leaves an
# authored issue OPEN and still `backlog`-labelled — it closes only when the PR merges (`Closes #N`) —
# and it exits a cheap no-op for anything already authored. So truncating the SORTED backlog to the
# first MAX_PER_PASS numbers would spend the whole cap re-skipping the lowest issues while their PRs are
# in flight, and the tail would NEVER be offered: with a stalled PR (RED / closed / parked) holding a
# slot, that is permanent STARVATION, not deferral. Instead the driver walks the WHOLE backlog and
# counts only the runs that actually SPAWN a bounded model run; an in-flight skip costs no slot.
# Symmetrically, an issue whose author run surfaced a dev-task QUESTION is PARKED — re-offered only once
# a human touches the issue after the question was posted — so a stuck ticket never re-spends a model
# run, never re-asks the same question into noise, and never holds a cap slot. Nothing is dropped: every
# deferral is re-enumerated next pass, and any human touch un-parks.
#
#   dev-loop.sh <repo> [--once]   drive the backlog for <repo> (default: one full pass, then exit)
#   dev-loop.sh --watch <repo>    keep draining the backlog on an interval (LOOP_INTERVAL, default 300s)
#   dev-loop.sh --selftest        exercise the pure helpers (no gh / author / network)
#
# ENV: ORG (default oso-gato); BACKLOG_LABEL (default backlog); DEV_AUTHOR (default the sibling
#      bin/dev-author.sh, overridable for the mock test); LOOP_INTERVAL (--watch cadence, default 300);
#      MAX_PER_PASS (safety cap on author RUNS SPAWNED per pass, default 5 — a runaway-planner backstop;
#      skips and parked issues cost no slot); DEV_LOOP_STATE (park-marker dir).
set -uo pipefail

ORG="${ORG:-oso-gato}"
BACKLOG_LABEL="${BACKLOG_LABEL:-backlog}"
LOOP_INTERVAL="${LOOP_INTERVAL:-300}"
MAX_PER_PASS="${MAX_PER_PASS:-5}"
STATE="${DEV_LOOP_STATE:-$HOME/.local/state/dev-loop}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DEV_AUTHOR="${DEV_AUTHOR:-$HERE/dev-author.sh}"

log(){ printf '[%s] dev-loop: %s\n' "$(date -u +%H:%M:%S 2>/dev/null || echo --:--:--)" "$*" >&2; }

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
#   QUESTION  rc 4|5|6          → the run spawned but could not finish (BLOCKED / no-progress / in-box
#                                 RED) and posted a dev-task question on the issue. Slot + PARK it.
#   RETRY     any other rc      → environmental, no question posted (2 unreadable issue, 3 worktree,
#                                 7 push, 8 PR-create). Retried next pass; still takes a slot, so a
#                                 broken environment cannot spin the whole backlog in one pass.
run_class(){
  case "$1" in
    0)     case "$2" in https://*) printf 'AUTHORED';; *) printf 'SKIPPED';; esac ;;
    4|5|6) printf 'QUESTION' ;;
    *)     printf 'RETRY' ;;
  esac
}

# park_state <parked-stamp> <issue-updatedAt> → PARKED | ACTIVE.
# An issue whose author run surfaced a question is parked at the updatedAt the issue carried RIGHT AFTER
# that question was posted; it goes ACTIVE again only when the issue is touched later than that (a human
# answering or refining it). ISO-8601 UTC sorts lexicographically, so a string compare is the whole test.
# Fail-safe toward ACTIVE: a missing/unreadable stamp or updatedAt re-offers the issue — we would rather
# re-ask than silently drop a feature.
park_state(){
  local stamp="$1" upd="$2"
  [ -n "$stamp" ] && [ -n "$upd" ] || { printf 'ACTIVE'; return; }
  if [[ "$upd" > "$stamp" ]]; then printf 'ACTIVE'; else printf 'PARKED'; fi
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
  echo "== run_class (the cap counts MODEL RUNS; an in-flight skip must cost no slot) =="
  ck "PR url + rc0 → AUTHORED" "$(run_class 0 'https://github.com/o/r/pull/9')" "AUTHORED"
  ck "rc0, no url → SKIPPED"   "$(run_class 0 '')" "SKIPPED"
  ck "rc4 BLOCKED → QUESTION"  "$(run_class 4 '')" "QUESTION"
  ck "rc5 no-progress → QUESTION" "$(run_class 5 '')" "QUESTION"
  ck "rc6 in-box RED → QUESTION"  "$(run_class 6 '')" "QUESTION"
  ck "rc7 push fail → RETRY"   "$(run_class 7 '')" "RETRY"
  ck "rc2 unreadable → RETRY"  "$(run_class 2 '')" "RETRY"
  echo "== park_state (a surfaced question parks the issue until a human touches it) =="
  ck "untouched since the question → PARKED" "$(park_state 2026-07-12T10:00:00Z 2026-07-12T10:00:00Z)" "PARKED"
  ck "older touch → PARKED"                  "$(park_state 2026-07-12T10:00:00Z 2026-07-12T09:00:00Z)" "PARKED"
  ck "human touched it later → ACTIVE"       "$(park_state 2026-07-12T10:00:00Z 2026-07-12T11:00:00Z)" "ACTIVE"
  ck "never parked → ACTIVE"                 "$(park_state '' 2026-07-12T10:00:00Z)" "ACTIVE"
  ck "unreadable updatedAt → ACTIVE (never drop)" "$(park_state 2026-07-12T10:00:00Z '')" "ACTIVE"
  echo; echo "dev-loop selftest: $p passed, $f failed"
  [ "$f" -eq 0 ]; exit
fi

# ---- ONE PASS over the backlog --------------------------------------------------------------------
one_pass(){ # <repo>
  local repo="$1" slug="$ORG/$1"
  # ONE list call carries BOTH the issue number and its updatedAt (the park clock) — the parked check
  # below therefore costs no extra API call per issue.
  local raw; raw="$(gh issue list --repo "$slug" --label "$BACKLOG_LABEL" --state open \
                    --json number,updatedAt -q '.[] | [.number, .updatedAt] | @tsv' 2>/dev/null)" \
    || { log "backlog query failed for $slug — skipping this pass"; return 0; }
  local -A upd=(); local num ts
  while IFS=$'\t' read -r num ts; do [ -n "$num" ] && upd["$num"]="$ts"; done <<<"$raw"
  # The WHOLE backlog is enumerated — never truncated (see THE CAP BOUNDS AUTHOR RUNS, above).
  local nums; nums="$(parse_backlog "$(printf '%s\n' "${!upd[@]}")")"
  [ -n "$nums" ] || { log "$slug backlog is empty — nothing to author"; return 0; }

  local n rc out pf spawned=0 authored=0 asked=0 skipped=0 parked=0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if [ "$spawned" -ge "$MAX_PER_PASS" ]; then
      log "MAX_PER_PASS=$MAX_PER_PASS author run(s) spawned — the REST of the backlog is DEFERRED to the next pass"
      break
    fi
    pf="$STATE/${repo}-${n}.parked"
    if [ "$(park_state "$(cat "$pf" 2>/dev/null)" "${upd[$n]:-}")" = PARKED ]; then
      parked=$((parked+1)); log "  parked $slug#$n — a question is open on it and no one has answered; not re-asking"; continue
    fi
    log "→ authoring backlog $slug#$n via dev-author"
    # dev-author is fail-closed + idempotent: already-authored / non-backlog / has-PR issues no-op inside
    # it, so the driver need not track that state. Any non-zero exit is logged and the loop CONTINUES —
    # one stuck feature must never wedge the rest.
    out="$("$DEV_AUTHOR" "$repo" "$n" 2>/dev/null)"; rc=$?
    case "$(run_class "$rc" "$out")" in
      AUTHORED)
        spawned=$((spawned+1)); authored=$((authored+1)); rm -f "$pf"
        log "  authored $slug#$n → $out" ;;
      SKIPPED)
        skipped=$((skipped+1)); rm -f "$pf"
        log "  skipped $slug#$n (already authored / a PR is in flight) — no cap slot spent" ;;
      QUESTION)
        spawned=$((spawned+1)); asked=$((asked+1))
        # PARK at the issue's CURRENT updatedAt — which now includes the question dev-author just posted
        # — so the issue is re-offered only once a human touches it AFTER the question. An unreadable
        # timestamp leaves no park file ⇒ ACTIVE next pass (fail-safe: re-ask rather than drop).
        gh issue view "$n" --repo "$slug" --json updatedAt -q .updatedAt 2>/dev/null > "$pf" || rm -f "$pf"
        [ -s "$pf" ] || rm -f "$pf"
        log "  dev-author rc=$rc for $slug#$n — a dev-task question is on the issue; PARKED until a human answers" ;;
      RETRY)
        spawned=$((spawned+1))
        log "  dev-author rc=$rc for $slug#$n (environmental — no question posted) — retrying next pass" ;;
    esac
  done <<<"$nums"
  log "$slug pass complete — $spawned author run(s) spawned: $authored PR(s) opened, $asked question(s) surfaced; $skipped in-flight skip(s), $parked parked"
}

# ---- ENTRY -----------------------------------------------------------------------------------------
mkdir -p "$STATE"
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
