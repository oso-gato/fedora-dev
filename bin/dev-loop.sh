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
# THE R9 FLEET HALT GATES EVERY PASS (fedora-dev#151; spec #135 R9 + P3's "HALT check in every sweep").
# one_pass() reads the fleet-wide HALT switch (bin/fleet-halt.sh: a maintainer-applied `halt` label on
# the FLEET HALT CONTROL issue in the control repo — maintainer-BOUND like every fleet trust anchor, so
# the loop can neither halt nor UN-halt itself) at the TOP of every pass, BEFORE any author model run is
# spawned. rc 0 alone means GO. Anything else — a maintainer HALT, an unreadable-signal PAUSE, a checker
# that cannot run at all — makes the pass OBSERVE-ONLY (fail-closed TOWARD STOPPING, R9's deliberate
# inversion of the loop's usual fail-safe-toward-progress): the backlog is still enumerated and logged,
# so the operator sees the queue, but nothing spawns and nothing is filed. HALT stops NEW action only —
# an author run already in flight completes (killing it mid-push is how work is lost; the hard kill is
# App-key revocation, per R9); a maintainer removing the label resumes on the next pass, no restart.
# This is the interlock the old `--watch` hard-refusal (exit 2) stood in for: #151 (its req 9) lifts
# that refusal IN THE SAME CHANGE that lands the check — a clock that spawns bounded model runs is now
# stoppable within one sweep, which is exactly what R9 demanded before a timer mode could exist.
#
#   dev-loop.sh <repo> [--once]   drive the backlog for <repo> — ONE full pass, then exit
#   dev-loop.sh --watch <repo>    supervised loop (flock singleton): one pass every $LOOP_INTERVAL s;
#                                 the R9 fleet HALT gates every pass (#151)
#   dev-loop.sh --selftest        exercise the pure helpers (no gh / author / network)
#
# ENV: ORG (default oso-gato); BACKLOG_LABEL (default backlog); DEV_AUTHOR (default the sibling
#      bin/dev-author.sh, overridable for the mock test);
#      MAX_PER_PASS (safety cap on author RUNS SPAWNED per pass, default 5 — a runaway-planner backstop;
#      skips and parked issues cost no slot); DEV_LOGIN (the dev box's App identity, whose questions the
#      park gate trusts — default oso-gato-nox-claudebox, the same bare comment-author form the poller's
#      FITNESS_LOGIN uses; empty ⇒ parking is DISABLED, every question re-offered, never dropped);
#      FLEET_HALT (the R9 halt reader, default the sibling bin/fleet-halt.sh — overridable for the mock
#      test); LOOP_INTERVAL (seconds between --watch passes, default 300 — authoring cadence, not the
#      poller's 10 s: each pass may spawn bounded model runs); DEV_LOOP_LOCK (the --watch singleton lock,
#      default ${XDG_RUNTIME_DIR:-/tmp}/dev-loop-watch-<repo>.lock — tmpfs, never $HOME: the driver
#      keeps NO local state).
set -uo pipefail

ORG="${ORG:-oso-gato}"
BACKLOG_LABEL="${BACKLOG_LABEL:-backlog}"
MAX_PER_PASS="${MAX_PER_PASS:-5}"
DEV_LOGIN="${DEV_LOGIN-oso-gato-nox-claudebox}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DEV_AUTHOR="${DEV_AUTHOR:-$HERE/dev-author.sh}"
# the R9 fleet HALT reader (#151) — rc 0 is the ONLY "go"; see the header. Overridable for the mock test.
FLEET_HALT="${FLEET_HALT:-$HERE/fleet-halt.sh}"
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

# The machine-owned line-1 anchor of dev-author's surface_blocked() comment — the ONLY record of "a
# question is open on this issue", and therefore the whole park gate. It is a CONTRACT with dev-author:
# `dev-loop.test.sh` asserts bin/dev-author.sh still emits exactly this prefix, so a reword there can
# never silently un-park every blocked issue and set the loop re-asking forever.
BLOCKED_ANCHOR='^\*\*dev-author → needs a decision \(BLOCKED\):\*\*'

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
park_state(){
  local me="$1" who="$2" line1="$3"
  [ -n "$me" ] && [ "$who" = "$me" ] || { printf 'ACTIVE'; return; }
  if printf '%s' "$line1" | grep -qE "$BLOCKED_ANCHOR"; then printf 'PARKED'; else printf 'ACTIVE'; fi
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
  echo; echo "dev-loop selftest: $p passed, $f failed"
  [ "$f" -eq 0 ]; exit
fi

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
  # R9 FLEET HALT (#151) — read at the TOP of every pass, BEFORE any author model run is spawned (R9's
  # bound is "within one sweep"). rc 0 alone means GO; a maintainer HALT, an unreadable-signal PAUSE, or
  # a checker that cannot run at all (fail-closed toward stopping BY CONSTRUCTION — rc 127 is not rc 0)
  # makes this pass OBSERVE-ONLY: the backlog is still enumerated and logged below, so the operator sees
  # the queue, but no author run spawns and nothing is filed. Un-halt resumes on the next pass.
  local halted=0 hmsg
  if ! hmsg="$("$FLEET_HALT")"; then
    halted=1
    log "FLEET HALT: ${hmsg:-halt checker unavailable (fail-closed toward stopping)} — OBSERVE-ONLY pass (no author run will be spawned, nothing filed)"
  fi
  # ONE list call carries BOTH the issue number and its NEWEST comment (author + line 1) — the park state
  # is DERIVED from that comment (see PARKING, above), so the driver keeps NO local state AND costs no
  # extra API call per issue. jq guards the empty-comment case: `last` of [] is null, and `.body // ""`
  # keeps split() from ever seeing it; @tsv escapes any tab/newline inside a body, so a comment can never
  # forge an extra field.
  local raw; raw="$(gh issue list --repo "$slug" --label "$BACKLOG_LABEL" --state open \
                    --json number,comments \
                    -q '.[] | [.number, ((.comments | last | .author.login) // ""),
                               ((.comments | last | .body // "") | split("\n")[0])] | @tsv' 2>/dev/null)" \
    || { log "backlog query failed for $slug — skipping this pass"; return 0; }
  local -A who=() line1=(); local num w rest
  while IFS=$'\t' read -r num w rest; do
    [ -n "$num" ] || continue; who["$num"]="$w"; line1["$num"]="$rest"
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
  local n rc out spawned=0 authored=0 asked=0 skipped=0 parked=0 would=0
  while IFS= read -r n <&3; do
    [ -n "$n" ] || continue
    if [ "$spawned" -ge "$MAX_PER_PASS" ]; then
      log "MAX_PER_PASS=$MAX_PER_PASS author run(s) spawned — the REST of the backlog is DEFERRED to the next pass"
      break
    fi
    if [ "$(park_state "$DEV_LOGIN" "${who[$n]:-}" "${line1[$n]:-}")" = PARKED ]; then
      parked=$((parked+1))
      log "  parked $slug#$n — my unanswered question is still the newest comment on it; not re-asking (reply on the issue to re-offer it)"
      continue
    fi
    # R9 HALT (#151): OBSERVE-ONLY — the offer is LOGGED (the operator sees the queue) but no bounded
    # model run spawns. The check sits ONCE at the top of the pass, not here per issue: HALT stops NEW
    # passes' work, it does not abort a pass already spawning (in-flight work is never killed).
    if [ "$halted" = 1 ]; then
      would=$((would+1))
      log "  HALTED — would author $slug#$n (R9 fleet HALT; observe-only, no model run, nothing filed)"
      continue
    fi
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
  if [ "$halted" = 1 ]; then
    log "$slug pass complete — HALTED (R9): $would issue(s) WOULD have been offered, $parked parked; no author run spawned, nothing filed"
  else
    log "$slug pass complete — $spawned author run(s) spawned: $authored PR(s) opened, $asked question(s) surfaced; $skipped in-flight skip(s), $parked parked"
  fi
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
  log "dev-loop --watch up (repo=$REPO interval=${LOOP_INTERVAL}s; R9 fleet HALT read at the top of every pass — #151)"
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
