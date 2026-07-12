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
# `--watch` IS REFUSED UNTIL R9 HALT EXISTS (fedora-dev#151). Spec #135 R9 requires a HALT switch that
# freezes every poller within one sweep, and P3 lists a HALT check in every sweep; NO box implements one
# today (not pr-poller, not the host watcher, not this driver). A timer-driven `--watch` is the ONE thing
# in this script that would spawn bounded model runs unattended, on a clock, with nothing able to stop
# them mid-sweep — and an interlock that ships as a CODE COMMENT is not an interlock. So `--watch`
# HARD-REFUSES (exit 2) until #151 lands: what ships here is a single pass, driven one at a time by a
# caller that stops it by not calling it again. #151 carries the HALT design (signal on the bus,
# maintainer binding, fail-CLOSED); wiring it back on is then a few lines.
#
#   dev-loop.sh <repo> [--once]   drive the backlog for <repo> — ONE full pass, then exit (the only mode)
#   dev-loop.sh --watch <repo>    REFUSED until the R9 HALT switch exists (#151)
#   dev-loop.sh --selftest        exercise the pure helpers (no gh / author / network)
#
# ENV: ORG (default oso-gato); BACKLOG_LABEL (default backlog); DEV_AUTHOR (default the sibling
#      bin/dev-author.sh, overridable for the mock test);
#      MAX_PER_PASS (safety cap on author RUNS SPAWNED per pass, default 5 — a runaway-planner backstop;
#      skips and parked issues cost no slot); DEV_LOGIN (the dev box's App identity, whose questions the
#      park gate trusts — default oso-gato-nox-claudebox, the same bare comment-author form the poller's
#      FITNESS_LOGIN uses; empty ⇒ parking is DISABLED, every question re-offered, never dropped).
set -uo pipefail

ORG="${ORG:-oso-gato}"
BACKLOG_LABEL="${BACKLOG_LABEL:-backlog}"
MAX_PER_PASS="${MAX_PER_PASS:-5}"
DEV_LOGIN="${DEV_LOGIN-oso-gato-nox-claudebox}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DEV_AUTHOR="${DEV_AUTHOR:-$HERE/dev-author.sh}"

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
#                                 surface_blocked() (3 worktree, 4 BLOCKED, 5 no-progress, 6 in-box RED,
#                                 7 push, 8 PR-create). Spends a slot; the question it left on the issue
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
  ck "rc6 in-box RED → QUESTION"  "$(run_class 6 '')" "QUESTION"
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
  local n rc out spawned=0 authored=0 asked=0 skipped=0 parked=0
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
  log "$slug pass complete — $spawned author run(s) spawned: $authored PR(s) opened, $asked question(s) surfaced; $skipped in-flight skip(s), $parked parked"
}

# ---- ENTRY -----------------------------------------------------------------------------------------
if [ "${1:-}" = "--watch" ]; then
  # REFUSED, structurally — not warned about in a comment (see the R9 HALT note at the top). A clock that
  # spawns bounded model runs with no HALT switch to stop them mid-sweep is precisely what spec #135 R9
  # forbids, and this flag is the only way this script could become one.
  log "REFUSED: --watch needs the R9 HALT switch, which NO box implements yet (fedora-dev#151)."
  log "         Until #151 lands, drive one pass at a time: dev-loop.sh <repo> [--once]."
  exit 2
fi
REPO="${1:?usage: dev-loop.sh <repo> [--once] | --selftest}"
case "${2:-}" in
  ''|--once) : ;;  # one pass IS the default; --once names it explicitly (caller-friendliness)
  *) log "unknown argument '$2' (usage: dev-loop.sh <repo> [--once] | --selftest)"; exit 2 ;;
esac
one_pass "$REPO"
