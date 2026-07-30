#!/usr/bin/env bash
# immutability-probe.sh — MEASURE the dev box's build-and-teardown cycle for RESIDUE.
# (fedora-dev#313 — feat-02 of objective #310 "prove both boxes stay immutable, and keep proving it".)
#
# WHAT THIS IS. The objective's acceptance command. BP5/Principle 10 claims a throwaway build leaves
# NOTHING behind: the candidate image, its temp tree and its containers are disposable, and only the dnf
# package cache persists. That claim was ASSERTED by the teardown trap and never MEASURED. This probe
# runs a REAL build-and-teardown cycle and reads what survived it — from OUTSIDE.
#
# IT DOES NOT WITNESS ITSELF. Every observation is delegated to `residue-witness.sh` (feat-01, #312), an
# independent read-only enumerator of the four residue classes (image/tree/container/mount) that imports
# nothing from the teardown machinery. The objective rules the alternative out explicitly: *"asserting
# immutability from the code that implements it — a teardown trap cannot be its own witness."* This file
# therefore contains no enumerator and no residue definition of its own; it SEQUENCES cycles and FOLDS
# the witness's verdicts. What "residue" means lives in one place, and it is not here.
#
# IT MEASURES, IT DOES NOT TIDY. Between a cycle and its AFTER snapshot this probe runs no sweeper, no
# image removal and no recursive delete — nothing. (Those verbs are named DESCRIPTIVELY here and nowhere
# literally, the witness's own convention, so the test's mechanical scan for them comes back EMPTY in
# CODE AND COMMENTS with no comment-stripping needed to read its result — a scan that trips over the
# very sentence promising restraint teaches a reader to distrust the scan.) If a cycle leaves residue,
# reporting it IS the job; cleaning it up would
# destroy the only evidence the objective wants. There is deliberately no `--reap` mode. The one place a
# removal happens is the REAP ARM, and there the removal is performed by the SWEEPER UNDER TEST (inside
# the next build), never by this file — which is the whole point of that arm.
#
# THE THREE ARMS OF THE DEV HALF:
#   clean   — snapshot, run a real `build-throwaway.sh -c <ctx>` cycle, let its EXIT trap fire normally,
#             snapshot, diff. GREEN iff ZERO residue. This is the trap's advertised behaviour.
#   kill-9  — the trap-LESS path, which is the real leak mode: a second cycle is killed with SIGKILL the
#             moment it has created its throwaway tree, so no trap can run. Its residue is REPORTED under
#             its own label — it is expected, not a failure.
#   reap    — the documented orphan sweeper runs at the START of every build, so a THIRD cycle must
#             reap what the kill-9 cycle leaked. GREEN iff every staged leak is GONE afterwards.
#
# A BUILD FAILURE IS STILL A VALID MEASUREMENT — AND IS NEVER FOLDED INTO THE RESIDUE VERDICT. A failed
# build must ALSO leave nothing behind (that is precisely the path BP5 cares about), so the build's rc is
# reported on its own, beside the residue verdict, and neither masks the other: a failed build cannot be
# reported as a residue GREEN, and it cannot hide a residue RED.
#
# STAGING THE SWEEPER'S PRECONDITION — DISCLOSED, NOT HIDDEN. The sweeper is AGE-BOUNDED by design
# (`FD_STALE_MIN`, default 720 min) so a concurrent in-flight build is never reaped. A leak seconds old
# is therefore NOT yet the sweeper's business, and asserting otherwise would test a policy the sweeper
# does not have. So the reap arm ages the probe's OWN leaked tree past the threshold (`touch -d`) and
# lets the sweeper decide. That stages the sweeper's documented PRECONDITION; it does not perform, help
# or stand in for the reap, which remains entirely the sweeper's own code path.
#
# AND IT KEEPS ITS BLAST RADIUS TO ITS OWN ARTIFACTS. `FD_STALE_MIN` is pinned HIGH (a year) for every
# cycle this probe runs, rather than to 0. Lowering it would have been the shorter route to the same
# assertion and is the wrong one twice over: (a) the sweeper reaps by IMAGE ID, so `rmi -f` on a
# disposable tag destroys EVERY name that image has — on this box one such ID also carries the
# non-disposable `localhost/fd-greenfield:slice1`; (b) a 0-minute threshold reaps a CONCURRENT build's
# in-flight candidate and tree, which is exactly the accident the age bound exists to prevent. A
# measurement tool that damages the thing it measures is not a measurement tool. Pinned high, the probe
# reaps its own backdated leak and provably nothing else (nothing on a real box is a year old).
#
# VERDICT / EXIT CONTRACT (mirrors bin/recoverability-drill.sh, this repo's drill precedent):
#   line 1 is machine-readable:   immutability-probe: <overall> dev=<verdict> host=<verdict>
#   rc 0 = every measured half GREEN · 1 = RED (residue found) · 3 = STAGED/PARTIAL (a half not yet
#   measurable, or an arm that could not be staged) · 2 = usage/harness error.
#
#   immutability-probe.sh            BOTH halves — rc 0 ONLY when dev AND host each measured GREEN
#   immutability-probe.sh dev        the dev half only → rc 0 on a healthy box
#   immutability-probe.sh host       the host half only → the ticket-bus round-trip
#   immutability-probe.sh --selftest the pure verdict fold; no engine, no witness, no build, no bus.
#
# THE HOST HALF IS DEV-DRIVEN AND NEVER DEV-EXECUTED (#316, feat-05 — the change that makes the line
# above true). The dev box is walled off from host operations, so it does not measure the host: it FILES
# a ticket (`host-ticket.sh --wait immutability-probe`), WAITS, and READS the verdict the host posts.
# That is the sanctioned dev→host seam — the same shape bin/host-refresh.sh already uses — and the
# reason there is deliberately NO fallback that measures the host from here: doing so would be the dev
# box performing a host operation, and a nested-engine measurement of a DIFFERENT engine is not evidence
# about the host anyway.
#
# FAIL-CLOSED, BECAUSE AN UNMEASURED HALF MUST NEVER READ AS PROVEN. `host_fold` is the single decision
# point, and every uncertainty lands on STAGED (rc 3), never GREEN: a ticket that could not be filed, a
# timeout, an unreadable or absent verdict, an empty comment, a verdict whose grammar does not parse, and
# a cached verdict older than IMMUT_HOST_MAX_AGE. Only two things produce a host GREEN — a DONE ticket
# carrying a fresh GREEN verdict, or one carrying a cached GREEN still inside the age bound (disclosed as
# `cached` in the report, never silently). A host RED is echoed with its `RESIDUE <class> <key>` lines so
# the verdict is legible from the dev-side output and log without opening GitHub.
#
# AND AN UNDEPLOYED HOST CONSUMER IS NOT AN ALARM. Until feat-04 (#315) lands AND is deployed to erebus,
# the host agent rejects the verb; that is the EXPECTED BP7 pre-deploy state, so it reports STAGED with
# its reason printed — rc 3, not a RED. A missing consumer is a thing not yet built, not a box that
# failed its immutability check, and conflating the two would cry wolf on every run until deploy.
#
# ENV: IMMUT_PROBE_CTX (build context; default the live spec clone) · IMMUT_PROBE_WITNESS ·
#      IMMUT_PROBE_BUILD · IMMUT_PROBE_STALE_MIN · IMMUT_PROBE_KILL_WAIT · TMPDIR ·
#      IMMUT_PROBE_HOST_TICKET · IMMUT_PROBE_GH · IMMUT_PROBE_REPO_SCOPE · IMMUT_PROBE_HOST_VERB ·
#      IMMUT_HOST_MAX_AGE (default 86400) · HOST_TICKET_TIMEOUT (default 600, host-ticket's own bound).
#
# Covered by immutability-probe.test.sh. Control-plane (the immutability boundary's prover).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

WITNESS="${IMMUT_PROBE_WITNESS:-$HERE/residue-witness.sh}"
BUILDER="${IMMUT_PROBE_BUILD:-$HERE/build-throwaway.sh}"
CTX="${IMMUT_PROBE_CTX:-$HOME/.local/share/fedora-dev}"
STALE_MIN="${IMMUT_PROBE_STALE_MIN:-525600}"          # 1 year — see "blast radius" above
KILL_WAIT="${IMMUT_PROBE_KILL_WAIT:-180}"             # seconds to wait for the tree to appear
TMPD="${TMPDIR:-/tmp}"
THROWAWAY_ROOT="$HOME/.cache"
THROWAWAY_PREFIX="fd-throwaway"
OBJECTIVE="#310"

# ---- the host half's seams (all defaulted to production; the test drives fakes through them) --------
HOST_TICKET="${IMMUT_PROBE_HOST_TICKET:-$HERE/host-ticket.sh}"
REPO_SCOPE="${IMMUT_PROBE_REPO_SCOPE:-$HERE/repo-scope.sh}"
GH="${IMMUT_PROBE_GH:-gh}"
HOST_VERB="${IMMUT_PROBE_HOST_VERB:-immutability-probe}"
CONTROL_ORG="${HOST_TICKET_ORG:-oso-gato}"
CONTROL_REPO="${HOST_TICKET_REPO:-fedora-bootstrap}"
CONTROL_SLUG="$CONTROL_ORG/$CONTROL_REPO"
HOST_MAX_AGE="${IMMUT_HOST_MAX_AGE:-86400}"      # 24h — how stale a CACHED host verdict may be
TICKET_TIMEOUT="${HOST_TICKET_TIMEOUT:-600}"
# The belt below is what makes "can never hang a caller" a property of THIS file, so its bound must
# always be arithmetic: a garbage env value falls back to the default rather than breaking the `timeout`
# expression and removing the guarantee it exists to provide.
case "$TICKET_TIMEOUT" in ''|*[!0-9]*) TICKET_TIMEOUT=600;; esac

warn(){ printf 'immutability-probe: %s\n' "$*" >&2; }

# ---- PURE CORE (--selftest covers exactly these) ---------------------------------------------------

# residue_verdict <witness-diff-rc> → GREEN | RED | ERROR.
#
# THE COMPARISON'S DECISION POINT, and the anchor the test neutralizes: the witness's `diff` rc is the
# ONLY thing that decides whether a cycle was clean (0 = zero residue · 1 = residue · 2 = unusable
# input). An unusable snapshot is ERROR, never GREEN — "I could not compare" must not read as "nothing
# survived", which is the unmeasured-evidence failure this whole objective exists to end.
residue_verdict(){
  case "${1:-}" in
    0) printf 'GREEN';;
    1) printf 'RED';;
    *) printf 'ERROR';;
  esac
}

# reap_verdict <staged-count> <survivor-count> → GREEN | RED | STAGED.
#   staged 0    → STAGED: nothing was leaked, so nothing was proven reaped. A vacuous pass is not a pass
#                 (the witness's own "an unproven class is not a proven witness" discipline).
#   survivors 0 → GREEN:  every staged leak is gone after the next build's sweep.
#   else        → RED:    a leak survived the sweeper that is documented to reap it.
reap_verdict(){
  local staged="${1:-0}" survivors="${2:-0}"
  case "$staged" in ''|*[!0-9]*) printf 'STAGED'; return 0;; esac
  [ "$staged" -eq 0 ] && { printf 'STAGED'; return 0; }
  case "$survivors" in ''|*[!0-9]*) printf 'RED'; return 0;; esac
  if [ "$survivors" -eq 0 ]; then printf 'GREEN'; else printf 'RED'; fi
}

# overall_verdict <outcome…> → fold arm/half outcomes into GREEN | PARTIAL | RED.
#   any RED         → RED     (residue demonstrably survived — immutability is broken)
#   else any STAGED → PARTIAL (measured where measurable; ≥1 arm disclosed as not-yet-measured)
#   else            → GREEN
# ERROR folds to RED: a measurement that could not be taken must never soften the verdict.
overall_verdict(){
  local o red=0 staged=0
  for o in "$@"; do
    case "$o" in RED|ERROR) red=1;; STAGED|PARTIAL) staged=1;; esac
  done
  if [ "$red" = 1 ]; then printf 'RED'
  elif [ "$staged" = 1 ]; then printf 'PARTIAL'
  else printf 'GREEN'; fi
}

# verdict_rc <verdict> → the exit contract: 0 GREEN · 1 RED · 3 everything else (STAGED/PARTIAL).
verdict_rc(){ case "${1:-}" in GREEN) return 0;; RED|ERROR) return 1;; *) return 3;; esac }

# residue_names <diff-output> → only the RESIDUE lines (the survivors a report must name verbatim).
residue_names(){ printf '%s\n' "${1:-}" | grep '^RESIDUE ' ; }

# residue_count <diff-output> → how many survivors.
residue_count(){ printf '%s\n' "${1:-}" | grep -c '^RESIDUE ' ; }

# residue_trees <diff-output> → the tree-class survivor PATHS (the class the reap arm can age + assert).
residue_trees(){ printf '%s\n' "${1:-}" | sed -n 's/^RESIDUE tree \(.*\)$/\1/p' ; }

# ---- THE HOST HALF'S PURE FOLD (#316) --------------------------------------------------------------

# host_verdict_of <comment-text> → GREEN | RED | NONE.
# Reads the MACHINE-OWNED header only: a line that STARTS with `immutability-probe:` (optionally bold)
# followed by the verdict token. Anchoring at column 0 is the same G2 discipline auto-merge.sh uses on a
# gate comment — prose quoting the word GREEN further down a RED report can never flip the verdict, and
# the token is captured by position rather than by searching the line for a colour word.
host_verdict_of(){
  local v
  v="$(printf '%s\n' "${1:-}" \
       | sed -n 's/^\*\{0,2\}immutability-probe:[[:space:]]*\(GREEN\|RED\)\([^A-Za-z].*\)\{0,1\}$/\1/p' \
       | head -1)"
  printf '%s' "${v:-NONE}"
}

# host_cached_age <comment-text> → the cached verdict's age IN SECONDS, or "" when the verdict is fresh.
# The host labels a reused measurement `cached (<age>)`; a bare number is seconds, and s/m/h/d suffixes
# are accepted so the host may report in whatever unit reads well.
host_cached_age(){
  local raw n unit
  raw="$(printf '%s\n' "${1:-}" \
         | sed -n 's/.*[Cc]ached[[:space:]]*(\([0-9]\{1,\}[smhd]\{0,1\}\)).*/\1/p' | head -1)"
  [ -n "$raw" ] || { printf ''; return 0; }
  n="${raw%[smhd]}"; unit="${raw#"$n"}"
  case "$unit" in
    m) printf '%s' $((n * 60));;
    h) printf '%s' $((n * 3600));;
    d) printf '%s' $((n * 86400));;
    *) printf '%s' "$n";;
  esac
}

# unsupported_op_p <text> → 0 when the host said the VERB ITSELF is unknown to it. This is the BP7
# pre-deploy state (feat-04/#315 not yet on erebus), NOT a residue failure — telling them apart is what
# stops the probe crying wolf on every run until the consumer deploys.
unsupported_op_p(){
  printf '%s\n' "${1:-}" \
    | grep -qiE 'unsupported|unknown (host-)?op|not in the allowlist|unrecogni[sz]ed|no such (host-)?op'
}

# host_fold <ticket-rc> <filed 0|1> <comment-text> <max-age> → "<VERDICT> <reason-slug>".
#
# THE SINGLE DECISION POINT for the host half, and the one the mapping table in #316 is written against.
# Pure, so --selftest can drive every row of that table with no bus. EVERY uncertainty folds to STAGED:
# the objective's whole point is that an unmeasured half must never read as proven, so GREEN is reachable
# from exactly two states and nothing else.
host_fold(){
  local rc="${1:-}" filed="${2:-0}" text="${3:-}" maxage="${4:-86400}" v age
  # Never filed ⇒ the bus was unreachable (no credential, no network, missing producer). Nothing was
  # measured, so there is nothing to report but STAGED — this is never an alarm and never a RED.
  [ "$filed" = 1 ] || { printf 'STAGED unfiled'; return 0; }
  case "$rc" in
    0)
      # DONE. The verdict COMMENT decides — the ticket outcome only says the host agent ran the op.
      if printf '%s\n' "$text" | grep -q '^RESIDUE '; then printf 'RED measured'; return 0; fi
      v="$(host_verdict_of "$text")"
      case "$v" in
        RED)  printf 'RED measured';   return 0;;
        NONE) printf 'STAGED noverdict'; return 0;;
      esac
      age="$(host_cached_age "$text")"
      if [ -n "$age" ]; then
        case "$maxage" in ''|*[!0-9]*) printf 'STAGED badmaxage'; return 0;; esac
        if [ "$age" -le "$maxage" ]; then printf 'GREEN cached'; else printf 'STAGED stale'; fi
        return 0
      fi
      printf 'GREEN fresh'; return 0;;
    1)
      # FAILED. A failure carrying MEASUREMENT (residue lines, or an explicit RED header) is a real host
      # RED — the host measured the box and found survivors. A failure that merely says it does not know
      # the verb is the pre-deploy state. Everything else failed without measuring anything.
      if printf '%s\n' "$text" | grep -q '^RESIDUE '; then printf 'RED measured'; return 0; fi
      [ "$(host_verdict_of "$text")" = RED ] && { printf 'RED measured'; return 0; }
      if unsupported_op_p "$text"; then printf 'STAGED unsupported'; return 0; fi
      printf 'STAGED failed'; return 0;;
    2)   printf 'STAGED timeout';    return 0;;
    124) printf 'STAGED timeout';    return 0;;
    *)   printf 'STAGED unreadable'; return 0;;
  esac
}

# host_reason_line <reason-slug> <url> <age> <maxage> → the human sentence under line 1. The PROVENANCE
# (which ticket, how fresh) is part of the verdict: a GREEN nobody can trace is the unmeasured-evidence
# failure wearing a better colour.
host_reason_line(){
  local slug="${1:-}" url="${2:-}" age="${3:-}" maxage="${4:-}" via
  via="${url:+ — via $url}"
  case "$slug" in
    fresh)      printf 'host: GREEN — the host measured zero residue, verdict FRESH%s' "$via";;
    cached)     printf 'host: GREEN — the host reported zero residue, verdict CACHED (%ss old, within the %ss bound)%s' "$age" "$maxage" "$via";;
    stale)      printf 'host: STAGED — the host verdict is CACHED and STALE (%ss old, past the %ss bound); a stale measurement is not a current proof%s' "$age" "$maxage" "$via";;
    measured)   printf 'host: RED — the host measured RESIDUE; survivors named below%s' "$via";;
    unsupported) printf "host: STAGED — the host does not support host-op '%s' yet (feat-04/#315 not deployed) — the expected BP7 pre-deploy state, not an alarm%s" "$HOST_VERB" "$via";;
    unfiled)    printf 'host: STAGED — could not file a ticket on %s (no credential, no bus, or no producer); nothing was measured' "$CONTROL_SLUG";;
    timeout)    printf 'host: STAGED — no host verdict within %ss; the wait is bounded so this can never hang a caller%s' "$TICKET_TIMEOUT" "$via";;
    noverdict)  printf 'host: STAGED — the ticket completed but carries no parseable `immutability-probe: GREEN|RED` verdict%s' "$via";;
    failed)     printf 'host: STAGED — the host op FAILED without reporting a measurement%s' "$via";;
    badmaxage)  printf 'host: STAGED — IMMUT_HOST_MAX_AGE is not a number, so a cached verdict cannot be aged%s' "$via";;
    *)          printf 'host: STAGED — the host verdict could not be read%s' "$via";;
  esac
}

# ---- observation + cycle helpers -------------------------------------------------------------------

snap(){ "$WITNESS" snapshot "$1"; }

# list_trees → the throwaway trees that exist right now (the kill-9 leak's staging ground).
list_trees(){ ls -d "$THROWAWAY_ROOT/$THROWAWAY_PREFIX".* 2>/dev/null | LC_ALL=C sort; }

# run_cycle <logfile> → one REAL build-and-teardown cycle, EXIT trap allowed to fire normally. rc = the
# build's rc. Output is kept off stdout so stdout stays the machine-readable report.
run_cycle(){
  FD_STALE_MIN="$STALE_MIN" "$BUILDER" -c "$CTX" >>"$1" 2>&1
}

# first_new_tree <existing-list> → the first throwaway tree that is NOT in <existing-list>, or rc 1.
# An explicit membership test, not `comm`: the existing list is routinely EMPTY on a clean box, and an
# empty operand makes set-difference tools compare against a single blank line instead of nothing.
first_new_tree(){
  local existing="$1" t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case $'\n'"$existing"$'\n' in *$'\n'"$t"$'\n'*) continue;; esac
    printf '%s\n' "$t"; return 0
  done < <(list_trees)
  return 1
}

# kill_group <pid> → SIGKILL the cycle and everything it spawned, so NO trap can run anywhere in it.
# Job control puts the background cycle in its own process group; if that is unavailable the fallback
# kills the leader's children then the leader (a plain `kill $pid` would leave `cp`/`podman` orphaned
# and still writing into the tree we are about to snapshot).
kill_group(){
  local p="$1"
  kill -9 -- -"$p" 2>/dev/null || { pkill -9 -P "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; }
}

# ---- THE DEV HALF ----------------------------------------------------------------------------------
# Sets DEV_VERDICT + DEV_REPORT (the detail lines, printed under line 1).

DEV_VERDICT="STAGED"; DEV_REPORT=""; DEV_RESIDUE=""; DEV_CLEAN_N="?"; DEV_BUILD_RC="?"
say(){ DEV_REPORT="${DEV_REPORT}${DEV_REPORT:+$'\n'}$1"; }

# The probe's OWN scratch files — reaped on exit. NOTHING a cycle left behind is ever on this list:
# tidying a cycle's residue would destroy the only evidence this probe exists to collect.
SCRATCH=()
scratch_cleanup(){ [ "${#SCRATCH[@]}" -gt 0 ] && rm -f "${SCRATCH[@]}" 2>/dev/null; return 0; }
trap scratch_cleanup EXIT

dev_half(){
  local log b0 a0 b1 a1 a2 before_trees
  local build_rc clean_out clean_rc clean_v clean_n
  local kill_out kill_rc kill_n staged_trees staged_n
  local reap_out reap_rc reap_v survivors survivor_n t old
  local bpid waited found

  # -- preflight: every input must be real, or this is a harness error (rc 2), never a verdict.
  [ -x "$WITNESS" ] || { warn "witness not executable: $WITNESS (feat-01 / #312)"; return 2; }
  [ -x "$BUILDER" ] || { warn "throwaway builder not executable: $BUILDER"; return 2; }
  [ -d "$CTX" ]     || { warn "build context is not a directory: $CTX"; return 2; }
  [ -f "$CTX/Containerfile" ] || { warn "no Containerfile in context: $CTX"; return 2; }

  log="$(mktemp "$TMPD/immut-probe-build.XXXXXX")" || { warn "mktemp failed"; return 2; }
  b0="$(mktemp "$TMPD/immut-probe-snap.XXXXXX")" && a0="$(mktemp "$TMPD/immut-probe-snap.XXXXXX")" \
    && b1="$(mktemp "$TMPD/immut-probe-snap.XXXXXX")" && a1="$(mktemp "$TMPD/immut-probe-snap.XXXXXX")" \
    && a2="$(mktemp "$TMPD/immut-probe-snap.XXXXXX")" || { warn "mktemp failed"; return 2; }
  SCRATCH+=( "$b0" "$a0" "$b1" "$a1" "$a2" )   # the build log is KEPT: the report names it

  # ================= ARM 1: the clean cycle — the trap's advertised behaviour ========================
  snap "$b0" || { warn "BEFORE snapshot failed"; return 2; }
  run_cycle "$log"; build_rc=$?
  snap "$a0" || { warn "AFTER snapshot failed"; return 2; }
  clean_out="$("$WITNESS" diff "$b0" "$a0")"; clean_rc=$?
  clean_v="$(residue_verdict "$clean_rc")"
  clean_n="$(residue_count "$clean_out")"
  say "$(printf '  cycle clean  : build rc=%s · residue %s → %s' "$build_rc" "$clean_n" "$clean_v")"
  if [ "$clean_v" != GREEN ]; then
    DEV_RESIDUE="$(residue_names "$clean_out")"
  fi

  # ================= ARM 2: the kill-9 cycle — the trap-LESS leak path ==============================
  # Killed the moment its throwaway tree exists: that is BEFORE `podman build` can tag anything, so the
  # leak is deterministically tree-class and no half-built candidate is stranded in the engine.
  snap "$b1" || { warn "kill-9 BEFORE snapshot failed"; return 2; }
  before_trees="$(list_trees)"
  set -m                                     # own process group per job, so the whole cycle can be killed
  run_cycle "$log" &
  bpid=$!
  set +m
  waited=0; found=""
  while [ "$waited" -lt "$((KILL_WAIT * 20))" ]; do
    found="$(first_new_tree "$before_trees")"
    [ -n "$found" ] && break
    kill -0 "$bpid" 2>/dev/null || break     # the cycle finished before we could catch it
    sleep 0.05; waited=$((waited + 1))
  done
  kill_group "$bpid"
  wait "$bpid" 2>/dev/null
  snap "$a1" || { warn "kill-9 AFTER snapshot failed"; return 2; }
  kill_out="$("$WITNESS" diff "$b1" "$a1")"; kill_rc=$?
  kill_n="$(residue_count "$kill_out")"
  staged_trees="$(residue_trees "$kill_out")"
  staged_n="$(printf '%s\n' "$staged_trees" | grep -c .)"

  # ================= ARM 3: the reap arm — the sweeper's own code path ==============================
  if [ "$kill_rc" = 2 ]; then
    reap_v="STAGED"
    say "  cycle kill-9 : SKIP — the witness could not compare the kill-9 snapshots"
  elif [ "$staged_n" -eq 0 ]; then
    # No tree leak staged ⇒ nothing to prove reaped. Never a vacuous GREEN. What DID leak is named by
    # class rather than left as a bare number: this arm can only age a TREE's timestamp, so residue in
    # any other class is real, is still on the box, and is outside what this arm may claim to have
    # proven — a reader must not have to guess which of those a lone count meant.
    reap_v="STAGED"
    if [ "$kill_n" -eq 0 ]; then
      say "  cycle kill-9 : SKIP — nothing was leaked to reap (the cycle finished before it could be killed?)"
    else
      say "$(printf '  cycle kill-9 : SKIP — %s leaked, none of it a throwaway tree (classes: %s) — this arm can age only a tree, so their reap is unproven here' \
              "$kill_n" "$(printf '%s\n' "$kill_out" | sed -n 's/^RESIDUE \([a-z]*\) .*/\1/p' | LC_ALL=C sort -u | paste -sd, -)")"
    fi
  else
    # Age the probe's OWN leak past the sweeper's threshold — its documented precondition. Nothing else
    # on the box is this old, so the next cycle's sweep can reach this leak and provably nothing else.
    old=$(( $(date +%s) - (STALE_MIN + 1440) * 60 ))
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      touch -d "@$old" "$t" 2>/dev/null || warn "could not age staged leak: $t"
    done <<< "$staged_trees"

    run_cycle "$log"                          # the sweeper runs at the START of this build
    snap "$a2" || { warn "reap AFTER snapshot failed"; return 2; }
    reap_out="$("$WITNESS" diff "$b1" "$a2")"; reap_rc=$?
    if [ "$reap_rc" = 2 ]; then
      reap_v="STAGED"
      say "  cycle kill-9 : SKIP — the witness could not compare the reap snapshots"
    else
      # Which of the STAGED leaks are still there? Only the trees the probe aged are asserted; anything
      # else the kill-9 cycle left is reported above but is not this arm's claim to make.
      survivors=""
      while IFS= read -r t; do
        [ -n "$t" ] || continue
        printf '%s\n' "$reap_out" | grep -qF "RESIDUE tree $t" && survivors="${survivors}${t}"$'\n'
      done <<< "$staged_trees"
      survivor_n="$(printf '%s' "$survivors" | grep -c . )"
      reap_v="$(reap_verdict "$staged_n" "$survivor_n")"
      say "$(printf '  cycle kill-9 : staged %s tree leak(s) (residue %s) · %s survived the next build → %s' \
              "$staged_n" "$kill_n" "$survivor_n" "$reap_v")"
      if [ "$reap_v" = RED ]; then
        DEV_RESIDUE="${DEV_RESIDUE}${DEV_RESIDUE:+$'\n'}$(printf '%s' "$survivors" | sed 's/^/RESIDUE tree /')"
      fi
    fi
  fi

  say "$(printf '  build log    : %s' "$log")"
  DEV_VERDICT="$(overall_verdict "$clean_v" "$reap_v")"
  DEV_CLEAN_N="$clean_n"; DEV_BUILD_RC="$build_rc"
  return 0
}

# ---- THE HOST HALF — dev-DRIVEN, host-EXECUTED (#316) ----------------------------------------------
# Sets HOST_VERDICT + HOST_REPORT (the reason line) + HOST_RESIDUE (the survivors a RED must name).

HOST_VERDICT="STAGED"; HOST_REPORT=""; HOST_RESIDUE=""

# host_comments <issue-number> → every comment body on the ticket, newest LAST. Read-only.
host_comments(){
  "$GH" issue view "$1" --repo "$CONTROL_SLUG" --json comments -q '.comments[].body' 2>/dev/null
}

host_half(){
  local errf out err rc url num comment fold verdict slug age

  # -- R16 OPERATING SCOPE: filing is an ACTION against the control repo. Fail closed, one loud line.
  # Any non-zero rc (127 for a missing reader included) refuses — the fleet-wide reader-rc discipline.
  if ! "$REPO_SCOPE" check "$CONTROL_REPO" >/dev/null 2>&1; then
    HOST_VERDICT="STAGED"
    HOST_REPORT="$(printf 'host: STAGED — R16 SCOPE: control repo %s is outside the confirmed operating scope, or the scope read failed; NO ticket filed' "$CONTROL_SLUG")"
    warn "R16 SCOPE refused $CONTROL_SLUG — no immutability-probe ticket filed"
    return 0
  fi

  if [ ! -x "$HOST_TICKET" ]; then
    HOST_VERDICT="STAGED"
    HOST_REPORT="$(host_reason_line unfiled '' '' '')"
    warn "ticket producer not executable: $HOST_TICKET"
    return 0
  fi

  errf="$(mktemp "$TMPD/immut-probe-host.XXXXXX")" || { warn "mktemp failed"; return 2; }
  SCRATCH+=( "$errf" )

  # THE ROUND-TRIP. host-ticket.sh --wait files, blocks, and exits 0 DONE / 1 FAILED / 2 timeout. Its
  # own bound is HOST_TICKET_TIMEOUT; the outer `timeout` is a BELT so "can never hang a caller" is a
  # property of THIS file rather than a promise about the callee (rc 124 folds to STAGED timeout).
  out="$(timeout $((TICKET_TIMEOUT + 60)) "$HOST_TICKET" --wait "$HOST_VERB" 2>"$errf")"; rc=$?
  err="$(cat "$errf" 2>/dev/null)"

  # A URL on STDOUT is the proof the ticket was FILED — which is what tells a host-agent FAILED (rc 1,
  # a real verdict) apart from a producer that could not file at all (also rc 1, via its own `die`).
  # Without this the two collapse, and "no credential" would report as a measured host failure.
  url="$(printf '%s\n' "$out" | grep -m1 -E '^https?://[^[:space:]]+$')"
  num="${url##*/}"
  case "$num" in ''|*[!0-9]*) num="";; esac

  comment=""
  if [ -n "$num" ]; then
    comment="$(host_comments "$num")"
    # The producer's own stderr carries a refusal reason when it never got as far as a comment.
    [ -n "$comment" ] || comment="$err"
  else
    comment="$err"
  fi

  fold="$(host_fold "$rc" "$([ -n "$num" ] && echo 1 || echo 0)" "$comment" "$HOST_MAX_AGE")"
  verdict="${fold%% *}"; slug="${fold#* }"
  age="$(host_cached_age "$comment")"

  HOST_VERDICT="$verdict"
  HOST_REPORT="$(host_reason_line "$slug" "$url" "$age" "$HOST_MAX_AGE")"
  if [ "$verdict" = RED ]; then
    HOST_RESIDUE="$(residue_names "$comment")"
    [ -n "$HOST_RESIDUE" ] || HOST_RESIDUE="RESIDUE (the host reported RED but named no survivor line)"
  fi
  return 0
}

# ---- REPORT ----------------------------------------------------------------------------------------

report(){
  local mode="$1" overall
  case "$mode" in
    dev)  overall="$(overall_verdict "$DEV_VERDICT")"
          printf 'immutability-probe: %s dev=%s\n' "$overall" "$DEV_VERDICT";;
    host) overall="$(overall_verdict "$HOST_VERDICT")"
          printf 'immutability-probe: %s host=%s\n' "$overall" "$HOST_VERDICT";;
    *)    overall="$(overall_verdict "$DEV_VERDICT" "$HOST_VERDICT")"
          printf 'immutability-probe: %s dev=%s host=%s\n' "$overall" "$DEV_VERDICT" "$HOST_VERDICT";;
  esac
  if [ "$mode" != host ]; then
    [ -n "$DEV_REPORT" ] && printf '%s\n' "$DEV_REPORT"
    [ -n "$DEV_RESIDUE" ] && printf '%s\n' "$DEV_RESIDUE"
    printf 'dev: %s — %s residue (image/tree/container/mount) · cycle build rc=%s\n' \
      "$DEV_VERDICT" "${DEV_CLEAN_N:-?}" "${DEV_BUILD_RC:-?}"
  fi
  if [ "$mode" != dev ]; then
    [ -n "$HOST_REPORT" ] && printf '%s\n' "$HOST_REPORT"
    [ -n "$HOST_RESIDUE" ] && printf '%s\n' "$HOST_RESIDUE"
  fi
  verdict_rc "$overall"
}

# ---- DISPATCH (only when executed directly; sourcing exposes the pure helpers) ----------------------
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then return 0 2>/dev/null || true; fi

selftest(){
  local p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }

  echo "== residue_verdict (the witness's diff rc IS the comparison; unusable input is never GREEN) =="
  ck "rc 0 → GREEN"            "$(residue_verdict 0)" "GREEN"
  ck "rc 1 → RED"              "$(residue_verdict 1)" "RED"
  ck "rc 2 → ERROR"            "$(residue_verdict 2)" "ERROR"
  ck "empty rc → ERROR"        "$(residue_verdict '')" "ERROR"

  echo "== reap_verdict (nothing staged is never a pass) =="
  ck "nothing staged → STAGED" "$(reap_verdict 0 0)" "STAGED"
  ck "staged + reaped → GREEN" "$(reap_verdict 2 0)" "GREEN"
  ck "staged + survivor → RED" "$(reap_verdict 2 1)" "RED"
  ck "non-numeric staged → STAGED" "$(reap_verdict '' 0)" "STAGED"

  echo "== overall_verdict (RED dominates; ERROR folds to RED; else STAGED → PARTIAL) =="
  ck "all green → GREEN"       "$(overall_verdict GREEN GREEN)" "GREEN"
  ck "a staged → PARTIAL"      "$(overall_verdict GREEN STAGED)" "PARTIAL"
  ck "a RED dominates"         "$(overall_verdict GREEN STAGED RED)" "RED"
  ck "ERROR folds to RED"      "$(overall_verdict GREEN ERROR)" "RED"
  ck "empty → GREEN (vacuous)" "$(overall_verdict)" "GREEN"

  echo "== verdict_rc (the exit contract) =="
  verdict_rc GREEN;   ck "GREEN → rc 0"   "$?" "0"
  verdict_rc RED;     ck "RED → rc 1"     "$?" "1"
  verdict_rc PARTIAL; ck "PARTIAL → rc 3" "$?" "3"
  verdict_rc STAGED;  ck "STAGED → rc 3"  "$?" "3"

  echo "== residue line accessors (a report must name survivors verbatim) =="
  local d; d="$(printf 'GONE image aaa old:1\nALLOWED tree /c/fd-dnf/x [A1: …]\nRESIDUE tree /home/core/.cache/fd-throwaway.abc\nRESIDUE image bbb localhost/disposable/x:val-1\n')"
  ck "count counts only RESIDUE" "$(residue_count "$d")" "2"
  ck "names drops GONE/ALLOWED"  "$(residue_names "$d" | head -1)" "RESIDUE tree /home/core/.cache/fd-throwaway.abc"
  ck "trees yields the path"     "$(residue_trees "$d")" "/home/core/.cache/fd-throwaway.abc"
  ck "count on clean output"     "$(residue_count "")" "0"

  echo "== host_verdict_of (the MACHINE-OWNED header decides; prose can never flip it) =="
  ck "a GREEN header"          "$(host_verdict_of 'immutability-probe: GREEN — zero residue')" "GREEN"
  ck "a RED header"            "$(host_verdict_of 'immutability-probe: RED — 2 survivors')" "RED"
  ck "a bold header"           "$(host_verdict_of '**immutability-probe: GREEN**')" "GREEN"
  ck "no header → NONE"        "$(host_verdict_of 'the host agent ran something')" "NONE"
  ck "empty → NONE"            "$(host_verdict_of '')" "NONE"
  # the row that matters: a RED report whose PROSE says GREEN must still read RED (position, not search)
  ck "RED whose prose says GREEN stays RED" \
     "$(host_verdict_of 'immutability-probe: RED — the previous run was GREEN')" "RED"
  # …and a header buried mid-line is not a header (column-0 anchoring, the G2 discipline)
  ck "a quoted header does not count" \
     "$(host_verdict_of 'we saw immutability-probe: GREEN yesterday')" "NONE"

  echo "== host_cached_age (fresh has no age; units are accepted) =="
  ck "fresh → empty"           "$(host_cached_age 'immutability-probe: GREEN')" ""
  ck "bare seconds"            "$(host_cached_age 'immutability-probe: GREEN cached (3600)')" "3600"
  ck "seconds suffix"          "$(host_cached_age 'cached (90s)')" "90"
  ck "minutes"                 "$(host_cached_age 'cached (5m)')" "300"
  ck "hours"                   "$(host_cached_age 'cached (2h)')" "7200"
  ck "days"                    "$(host_cached_age 'cached (1d)')" "86400"

  echo "== unsupported_op_p (the BP7 pre-deploy state is not a residue failure) =="
  unsupported_op_p 'FAILED — unsupported host-op'      && ck "unsupported"  ok ok || ck "unsupported"  no ok
  unsupported_op_p 'unknown host-op immutability-probe'&& ck "unknown op"   ok ok || ck "unknown op"   no ok
  unsupported_op_p 'verb not in the allowlist'         && ck "allowlist"    ok ok || ck "allowlist"    no ok
  unsupported_op_p 'the build left 3 trees behind'     && ck "a real failure is NOT unsupported" no ok || ck "a real failure is NOT unsupported" ok ok

  echo "== host_fold — EVERY ROW of the #316 mapping table (GREEN is reachable from 2 states only) =="
  ck "DONE + fresh GREEN → GREEN" \
     "$(host_fold 0 1 'immutability-probe: GREEN — zero residue' 86400)" "GREEN fresh"
  ck "DONE + cached GREEN within bound → GREEN" \
     "$(host_fold 0 1 'immutability-probe: GREEN cached (3600)' 86400)" "GREEN cached"
  ck "DONE + cached GREEN PAST bound → STAGED (stale is not current proof)" \
     "$(host_fold 0 1 'immutability-probe: GREEN cached (90000)' 86400)" "STAGED stale"
  ck "DONE + cached exactly AT the bound → GREEN (inclusive)" \
     "$(host_fold 0 1 'immutability-probe: GREEN cached (86400)' 86400)" "GREEN cached"
  ck "DONE + RED verdict → RED" \
     "$(host_fold 0 1 'immutability-probe: RED — survivors follow' 86400)" "RED measured"
  ck "DONE + residue lines outrank a GREEN header → RED" \
     "$(host_fold 0 1 'immutability-probe: GREEN'$'\n''RESIDUE tree /x' 86400)" "RED measured"
  ck "DONE + no verdict → STAGED" \
     "$(host_fold 0 1 'the op ran' 86400)" "STAGED noverdict"
  ck "DONE + EMPTY comment → STAGED" \
     "$(host_fold 0 1 '' 86400)" "STAGED noverdict"
  ck "FAILED + residue lines → RED (a measured failure)" \
     "$(host_fold 1 1 'RESIDUE image abc localhost/disposable/x:val-1' 86400)" "RED measured"
  ck "FAILED + RED header → RED" \
     "$(host_fold 1 1 'immutability-probe: RED — could not tear down' 86400)" "RED measured"
  ck "FAILED + unsupported verb → STAGED (BP7 pre-deploy, NOT an alarm)" \
     "$(host_fold 1 1 '**host-agent: FAILED** — unsupported host-op immutability-probe' 86400)" "STAGED unsupported"
  ck "FAILED + a staged reason → STAGED" \
     "$(host_fold 1 1 '**host-agent: FAILED** — the box was busy, deferred' 86400)" "STAGED failed"
  ck "TIMEOUT (rc 2) → STAGED" \
     "$(host_fold 2 1 '' 86400)" "STAGED timeout"
  ck "the outer belt timing out (rc 124) → STAGED" \
     "$(host_fold 124 1 '' 86400)" "STAGED timeout"
  ck "an unreadable rc → STAGED" \
     "$(host_fold 9 1 '' 86400)" "STAGED unreadable"
  ck "could not FILE (rc 1, no ticket) → STAGED, never a measured RED" \
     "$(host_fold 1 0 'gh issue create failed' 86400)" "STAGED unfiled"
  ck "could not file even with residue-looking text → STAGED" \
     "$(host_fold 1 0 'RESIDUE tree /x' 86400)" "STAGED unfiled"
  ck "a non-numeric max-age cannot age a cached verdict → STAGED" \
     "$(host_fold 0 1 'immutability-probe: GREEN cached (10)' 'soon')" "STAGED badmaxage"

  echo "== the CONJUNCTION: rc 0 requires BOTH halves GREEN (the objective's whole claim) =="
  ck "dev GREEN + host GREEN → GREEN" "$(overall_verdict GREEN GREEN)" "GREEN"
  ck "dev GREEN + host RED → RED"     "$(overall_verdict GREEN RED)" "RED"
  ck "dev GREEN + host STAGED → PARTIAL (never GREEN)" "$(overall_verdict GREEN STAGED)" "PARTIAL"
  ck "dev RED + host GREEN → RED"     "$(overall_verdict RED GREEN)" "RED"

  echo; printf 'immutability-probe selftest: %s passed, %s failed\n' "$p" "$f"
  [ "$f" -eq 0 ]
}

case "${1:-all}" in
  --selftest) selftest; exit;;
  dev)  dev_half || exit 2; report dev;;
  host) host_half || exit 2; report host;;
  # BOTH halves. The dev half runs FIRST and its rc does not short-circuit the host round-trip: a
  # RED dev box is still worth knowing the host's state for, and `overall_verdict` is what ANDs them.
  all)  dev_half || exit 2; host_half || exit 2; report all;;
  -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//'; exit 0;;
  *) echo "usage: immutability-probe.sh [all | dev | host | --selftest]" >&2; exit 2;;
esac
