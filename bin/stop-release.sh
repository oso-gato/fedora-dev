#!/usr/bin/env bash
# stop-release.sh — the BOUNDED-RELEASE library (R39 GATE RESILIENCE, MOVE 2 / #277).
#
# THE DEFECT IT CLOSES. R39 says every gate that can block the loop has a bounded, automatic recovery
# path; R43 binds that rule to NEW gates only. The gates that already existed kept the shape they were
# born with — fail-closed, correct in isolation, and TERMINAL: a dev-loop park held until a human
# replied on the issue, a review that exhausted its tries was "never re-run" on that head, a fixer that
# repeated one failure signature never ran again. Each is a machine that has stopped and cannot
# restart, which is functionally a phone call to the maintainer.
#
# THE CONTRACT. A stop is allowed. A stop with no way out is not. Every stopping condition gets the
# same three-state clock, so the loop's stops behave identically wherever they live:
#
#     HOLD      the stop stands — inside its cool-off. Cheap, silent, re-evaluated next sweep.
#     RELEASE   the cool-off has elapsed and releases remain: RE-ATTEMPT the thing that stopped.
#     ESCALATE  the bounded releases are spent (or none was configured): tell the maintainer, ONCE.
#
# The caller owns the two inputs and the escalation's idempotence; this owns only the DECISION, so it
# is pure, selftested, and identical at every site. HELD-TIME comes from the caller's own clock —
# preferably an EXTERNAL one (a comment's createdAt, a head commit's committer date: R24 no-proxy), so
# a restart cannot reset it; RELEASES-SO-FAR is likewise derived from the bus where the bus records it.
#
# THE TWO FAIL DIRECTIONS, chosen deliberately (each is a real failure mode, not a default):
#
#   * AN UNUSABLE BOUND DISABLES THE RELEASE, IT NEVER ARMS IT — #270's lesson, mirrored. There, an
#     unreadable bound read as 0 turned `age > bound` permanently TRUE and SIGTERMed a healthy poller
#     every check. Here the same slip is `held >= 0` ⇒ RELEASE on EVERY sweep: a bounded model run
#     re-spent every 10s, forever, which is the silent spin R4 forbids. So a non-positive-integer
#     cool-off can never yield RELEASE. It does NOT fall back to a silent HOLD either — a stop nobody
#     can release is exactly the thing this library exists to abolish — it ESCALATES: the honest
#     answer, and bounded to once by the caller's own anchor.
#
#   * AN UNREADABLE AGE HOLDS, IT NEVER RELEASES. `held` is re-read from an external clock on EVERY
#     sweep, so a transient unreadable age (a failed API read) costs ONE sweep of waiting, not the
#     release. Treating it as 0 would instead release immediately and repeatedly — churn keyed to an
#     API failure. DISCLOSED RESIDUAL: an age source that is PERMANENTLY unreadable therefore holds
#     indefinitely. That is the one uncovered path, and it is the right trade (a broken clock must not
#     drive a model run); it is visible because every caller logs the HOLD with the age it read.
#
# max_releases=0 is a VALID, deliberate configuration meaning "this stop has no automatic release" —
# it escalates on the first check. That is how a stop that genuinely cannot be released is declared,
# rather than left silently terminal.
#
# SOURCEABLE — sourcing defines the function and does NOTHING else (no I/O, no globals mutated, no
# shell options touched). The selftest below is guarded on `${BASH_SOURCE[0]}` = `$0`, so it fires ONLY
# on a direct `stop-release.sh --selftest` run: under `source`, `$1` is the CALLER'S first argument, and
# an unguarded `[ "${1:-}" = --selftest ]` would make a sourcing caller's own `--selftest` run THIS
# selftest and `exit` (bin/dev-loop.sh has exactly such a flag — the guard is load-bearing, not hygiene).
#
# EXPORTS:
#   release_verdict <held-seconds> <releases-so-far> <cool-off-seconds> <max-releases>
#                             → HOLD | RELEASE | ESCALATE
#
# WIRED CALLER (one, today): bin/dev-loop.sh — the BACKLOG PARK. An issue whose author run surfaced a
# question parked until a human replied, forever; it now holds for a cool-off, RE-OFFERS itself a bounded
# number of times (the re-attempt is what fixes the transient half of that stop — a failed worktree, push
# or PR-create, dev-author rc 3/7/8 — which never needed a human at all), then ESCALATES once and stays
# put. The release budget is recorded ON THE BUS (a machine-anchored comment per release), so it survives
# a wiped box like every other fact this loop acts on.
#
# NOT YET WIRED — the remaining stops keep today's terminal shape until a later change moves them
# (disclosed, so merged `main` never reads as if they were done): bin/pr-poller.sh's exhausted fitness
# review (`review_due` PARKED) and its no-progress fixer stop. The whole-loop ENUMERATION of stopping
# conditions, and the audit that keeps it honest, are likewise still to come — no STOPS.md and no
# stop-audit.sh exist yet, and this file does not pretend otherwise.
#
# COVERAGE: the pure core by `--selftest` here; the WIRED park end-to-end (hold → release → escalate,
# with the release-path mutation) by dev-loop.test.sh.
# Control-plane (the loop's stop/release policy). MUST be tracked 100755.

# release_verdict <held-seconds> <releases-so-far> <cool-off-seconds> <max-releases>
#   -> HOLD | RELEASE | ESCALATE
release_verdict(){
  local held="${1:-}" used="${2:-}" cool="${3:-}" max="${4:-}"
  # An unusable cool-off can never ARM the release axis (see THE TWO FAIL DIRECTIONS above). It is not
  # a silent hold either: a stop with no usable release is surfaced, exactly once, by the caller.
  case "$cool" in ''|*[!0-9]*) printf 'ESCALATE'; return;; esac
  [ "$cool" -gt 0 ] || { printf 'ESCALATE'; return; }
  # A garbled release COUNT must not read as "plenty left" — count it as spent-nothing (0) and let the
  # bound below decide; a garbled BOUND is "no release configured" (0), which escalates immediately.
  case "$used" in ''|*[!0-9]*) used=0;; esac
  case "$max"  in ''|*[!0-9]*) max=0;;  esac
  [ "$used" -ge "$max" ] && { printf 'ESCALATE'; return; }
  # An unreadable age waits for a readable one — it never releases on a broken clock.
  case "$held" in ''|*[!0-9]*) printf 'HOLD'; return;; esac
  [ "$held" -ge "$cool" ] && printf 'RELEASE' || printf 'HOLD'
}

# ---- SELFTEST --------------------------------------------------------------------------------------
# The BASH_SOURCE guard is what makes the SOURCEABLE claim above true: under `source`, `$1` belongs to
# the CALLER, so without it a caller invoked with `--selftest` would run this selftest and exit.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = "--selftest" ]; then
  p=0; f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  echo "== the ordinary clock: hold inside the cool-off, release past it, escalate when spent =="
  ck "inside the cool-off → HOLD"          "$(release_verdict 100 0 300 2)" "HOLD"
  ck "cool-off exactly elapsed → RELEASE"  "$(release_verdict 300 0 300 2)" "RELEASE"
  ck "past the cool-off → RELEASE"         "$(release_verdict 999 0 300 2)" "RELEASE"
  ck "one release spent, bound 2 → RELEASE" "$(release_verdict 999 1 300 2)" "RELEASE"
  ck "releases EXHAUSTED → ESCALATE"       "$(release_verdict 999 2 300 2)" "ESCALATE"
  ck "over-spent (state drift) → ESCALATE" "$(release_verdict 999 9 300 2)" "ESCALATE"
  # The bound is checked BEFORE the clock: an exhausted stop escalates without waiting out another
  # cool-off it can never use. (A caller's escalation anchor is what makes this once, not per-sweep.)
  ck "exhausted INSIDE the cool-off → ESCALATE (no pointless wait)" \
                                           "$(release_verdict 1 2 300 2)" "ESCALATE"
  echo "== max_releases=0 — the deliberate 'this stop has no automatic release' declaration =="
  ck "bound 0 → ESCALATE at once"          "$(release_verdict 0 0 300 0)" "ESCALATE"
  ck "bound 0, aged → ESCALATE"            "$(release_verdict 99999 0 300 0)" "ESCALATE"
  echo "== an UNUSABLE BOUND disables the release, never arms it (#270's inversion, mirrored) =="
  ck "cool-off 0 → ESCALATE, never RELEASE"        "$(release_verdict 1 0 0 2)" "ESCALATE"
  ck "cool-off 0 @ age 0 → ESCALATE, never RELEASE" "$(release_verdict 0 0 0 2)" "ESCALATE"
  ck "cool-off non-numeric → ESCALATE"             "$(release_verdict 99999 0 x 2)" "ESCALATE"
  ck "cool-off empty → ESCALATE"                   "$(release_verdict 99999 0 '' 2)" "ESCALATE"
  ck "cool-off negative → ESCALATE"                "$(release_verdict 99999 0 -5 2)" "ESCALATE"
  echo "== an UNREADABLE AGE holds — it never releases on a broken clock =="
  ck "age non-numeric → HOLD"  "$(release_verdict x 0 300 2)" "HOLD"
  ck "age empty → HOLD"        "$(release_verdict '' 0 300 2)" "HOLD"
  ck "age negative → HOLD"     "$(release_verdict -1 0 300 2)" "HOLD"
  # ...but a broken clock must not out-rank an EXHAUSTED bound: that stop is already spent.
  ck "unreadable age + exhausted → ESCALATE" "$(release_verdict x 2 300 2)" "ESCALATE"
  echo "== a garbled release COUNT is 'nothing spent', never 'plenty left' =="
  ck "count non-numeric → treated as 0"  "$(release_verdict 999 x 300 2)" "RELEASE"
  ck "count non-numeric, bound 0 → ESCALATE" "$(release_verdict 999 x 300 0)" "ESCALATE"
  ck "garbled BOUND is 'no release configured' → ESCALATE" "$(release_verdict 999 0 300 x)" "ESCALATE"
  echo; echo "stop-release selftest: $p passed, $f failed"
  [ "$f" -eq 0 ]; exit
fi
