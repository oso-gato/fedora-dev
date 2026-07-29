#!/usr/bin/env bash
# dev-loop-service.sh — supervise the dev-side AUTONOMOUS AUTHORING loop (bin/dev-loop.sh) as a headless
# IN-BOX service. The FRONT-HALF counterpart to poller-service.sh (which supervises the merge back-half):
# this is what closes the human out of the per-feature AUTHORING loop (apparatus R3). dev-loop.sh
# enumerates the OPEN backlog-labelled feature issues the planner produced and runs dev-author over each —
# isolating a worktree, implementing with a bounded `claude -p`, gating in-box, and opening a
# `live-validate` PR that the existing host-live-gate → fitness → poller pipeline ships. This wrapper
# writes NO author/validate/merge logic; it only KEEPS THE AUTHORING LOOP RUNNING, exactly as
# poller-service.sh keeps pr-poller running. Until this existed, the whole front-half (dev-plan/dev-author/
# dev-loop) was built and tested but run by NOTHING — the "arm-less authoring loop" gap.
#
# WHY IN-BOX: dev-author spawns `claude -p` to implement the feature, and `claude` lives in the claudebox
# (Distrobox), NOT the fedora-dev base where entrypoint.sh runs. entrypoint.sh launches THIS wrapper
# inside the box (`distrobox enter claudebox -- dev-loop-service.sh`), gated on DEV_LOOP_ENABLED.
#
# WHY A PLAIN-SHELL SERVICE (not the interactive agent): the interactive agent is deliberately gated FROM
# autonomous authoring (as from merging); the dumb, gate-checked service is the sanctioned autonomous
# authoring path. It acts ONLY on the planner's backlog-labelled issues, and every PR it opens still faces
# the host live-gate + an INDEPENDENT fitness review before the poller can merge it — so an enabled loop is
# fenced by the SAME two independent gates that fence the merge, PLUS the R9 fleet HALT and R16 scope that
# dev-loop.sh reads at the top of every pass, PLUS dev-author's bounded per-run timeout and MAX_PER_PASS
# cap. ARMED BY DEFAULT (2026-07-18) — the entrypoint gate defaults ON, so the loop SELF-ARMS with the
# apparatus: once the self-refresh deploys the new entrypoint, authoring starts with NO host action. A
# host-set OPT-IN flag would be a deploy-CONFIG the self-refresh CANNOT set (it deploys the image +
# live-clone, never the host quadlet env), so a default-off flag would force a MANUAL host arm —
# contradicting "self-arming = no more manual host actions". Set DEV_LOOP_ENABLED=0 to disable; R9 fleet
# HALT is the emergency stop (no redeploy needed). Same trust level as the already-armed poller — authoring
# produces PRs the SAME two gates (host live-gate + fitness) decide.
#
# MULTI-REPO — THIS wrapper's own job. pr-poller.sh iterates the scoped repos INSIDE its own sweep, so
# poller-service.sh need not; dev-loop.sh is single-repo (one pass over one repo's backlog), so THIS
# wrapper is the multi-repo supervisor: each cycle it re-reads the R16 actionable set (repo-scope.sh list —
# the SAME set the poller sweeps, re-read every cycle because a confirmed merge can change scope) and runs
# ONE dev-loop.sh pass per scoped repo. This is the ONE place the authoring loop's repo set is decided, and
# it is NEVER a hardcoded default (the #165 scope-leak lesson): repo-scope.sh is fail-closed (unreadable ⇒
# only the apparatus's own two repos; empty ⇒ nothing), and a non-zero rc yields an EMPTY list here, so a
# cycle authors NOTHING rather than guessing a default.
#
# LIVENESS-ADJUDICATED SINGLETON (#173-grade). This service now has TWO launchers — entrypoint.sh (on a
# box built from an image carrying the launch block) AND the self-refreshing poller's dev_loop_launch_tick
# (the SELF-ARM path: the poller is CLONE-side, so it reaches a running box with NO rebuild). Two launchers
# means a double-launch is routine, so a dedup is now warranted. It is NOT a naive `flock -n || exit`: that
# reintroduces the #173 dead-holder-blocks-forever bug (a box recreate orphans the holder; the fresh
# service reads the corpse as a healthy peer and exits — four silent hours, 2026-07-13). Instead the holder
# records its pid in a pidfile and a contender ADJUDICATES liveness (service_live): a peer defers a start
# ONLY when the recorded pid is positively live AND its /proc cmdline still names this script (so a dead or
# a RECYCLED pid never blocks a start). FAIL DIRECTION: liveness in doubt ⇒ START (a brief double-run is a
# cheap no-op — dev-author's per-(repo,issue) idempotency marker + "is there already an open PR?" guard
# make a duplicate author run harmless; the singleton only spares the wasted model runs). The pidfile is
# reclaimed on clean EXIT only when it still holds OUR pid, so a race-loser never unlinks the winner's.
#
# FAIL-SAFE: a dev-loop pass that fails is logged and the NEXT repo / NEXT cycle proceeds (one stuck repo
# never wedges the rest). Best-effort + self-restarting (entrypoint's supervise loop restarts a death), and
# OUTSIDE the hard watchdog — its death must never take the container down (the poller's discipline).
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
STATE="$HOME/.local/state/claudebox"
LOGDIR="$HOME/.local/state/dev-loop"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/service.log"
PIDFILE="${PIDFILE:-$LOGDIR/service.pid}"
log(){ echo "[$(date -u +%FT%TZ 2>/dev/null || date)] dev-loop-service: $*" | tee -a "$LOG" >&2; }

# service_live — is a DIFFERENT, verified dev-loop-service instance currently holding the pidfile? The
# #173 discipline: never trust a bare marker. Require the recorded pid to (a) be a number, (b) not be us,
# (c) be ALIVE (kill -0), and (d) actually BE a dev-loop-service (its /proc/<pid>/cmdline still names this
# script) — so a DEAD holder or a RECYCLED pid wearing the old number reads as NOT live and never blocks a
# start. Probes the SPECIFIC recorded pid, never a `pgrep -f dev-loop-service` string-match across all
# procs (the process-pattern-self-match trap: a broad match would hit this very check and the poller's own
# `dev-loop-service.sh --is-live` launch probe). Used by the startup singleton guard AND by the poller
# (via --is-live) to decide whether to launch.
service_live(){
  local p
  p="$(cat "$PIDFILE" 2>/dev/null)" || return 1
  case "$p" in ''|*[!0-9]*) return 1;; esac
  [ "$p" != "$$" ] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'dev-loop-service\.sh' || return 1
  return 0
}

DEV_LOOP="${DEV_LOOP:-$HERE/dev-loop.sh}"
REPO_SCOPE="${REPO_SCOPE:-$HERE/repo-scope.sh}"
LOOP_INTERVAL="${LOOP_INTERVAL:-300}"   # seconds between authoring cycles (authoring cadence — each pass may spawn bounded model runs; NOT the poller's 10s)

# scoped_repos — the R16 actionable set, re-read EVERY cycle (scope can change through a confirmed merge).
# Fail-closed BY repo-scope.sh's own contract; a non-zero rc (a missing/unreadable reader included) yields
# an EMPTY list here, so a cycle authors nothing rather than guessing a default (the #165 leak class).
scoped_repos(){ "$REPO_SCOPE" list 2>/dev/null || true; }

# one_cycle — run ONE dev-loop pass per scoped repo. The repo list rides FD 3 (the pr-poller/dev-loop
# idiom): dev-loop → dev-author → `claude -p` DRAINS any stdin it inherits, so feeding the list on FD 0
# would let the first author swallow the rest of the repo list; FD 3 is immune, and dev-loop is ALSO run
# with stdin closed and FD 3 closed. Exposed as --one-cycle so dev-loop-service.test.sh drives the real
# per-repo dispatch without the readiness waits or the endless supervise loop.
one_cycle(){
  local repo n=0
  while IFS= read -r repo <&3; do
    [ -n "$repo" ] || continue
    n=$((n+1))
    log "authoring pass → $repo"
    # CAPTURE WHAT IT DECIDED, not merely that it ran. The child's stdout/stderr were inherited from
    # this service, and since the supervisor entered via `distrobox enter` (rather than the poller's
    # `setsid … >>LOG 2>&1`) they went nowhere. MEASURED 2026-07-29: service.log lines 4291-29496 —
    # 25,206 lines over 10 days — are ONLY `authoring pass → <repo>` heartbeats. Not one `skipped`,
    # `authored`, or `BLOCKED`. The authoring half passed over the maintainer's open tickets every ~5.5
    # minutes for ten days and NOBODY, human or machine, could see what it concluded about any of them.
    # A loop that cannot say what it decided cannot be debugged, and its silence reads as inactivity.
    if "$DEV_LOOP" "$repo" </dev/null 3<&- >>"$LOG" 2>&1; then
      log "authoring pass → $repo: done"
    else
      log "dev-loop pass for $repo failed (continuing to the next repo/cycle)"
    fi
  done 3<<EOF
$(scoped_repos)
EOF
  [ "$n" -gt 0 ] || log "R16 scope yielded NO repos this cycle — authoring nothing (fail-closed; not guessing a default)"
}
case "${1:-}" in
  --one-cycle) one_cycle; exit 0;;
  --is-live)   service_live; exit $?;;   # poller launch-probe (#173-adjudicated liveness of the holder)
esac

# SINGLETON (liveness-adjudicated, #173) — with two launchers (entrypoint + the self-refreshing poller),
# a double-launch is routine; if a verified peer already holds the loop, this launch exits cleanly. Checked
# BEFORE the readiness waits (no point waiting for assembly when a peer is already cycling). A race that
# slips two past here is a cheap no-op (dev-author idempotency); a dead/recycled holder never blocks.
if service_live; then
  log "a live dev-loop-service (pid $(cat "$PIDFILE" 2>/dev/null)) already holds the loop — this launch exits (singleton)"
  exit 0
fi
echo "$$" > "$PIDFILE"
# reclaim the pidfile on clean exit ONLY while it still names US — a race-loser must never unlink the
# winner's record (the winner overwrote it with its own pid).
trap 'p="$(cat "$PIDFILE" 2>/dev/null)"; [ "$p" = "$$" ] && rm -f "$PIDFILE" 2>/dev/null; :' EXIT

# 1) box ASSEMBLED — dev-author needs `claude` + `gh`, present only post-assemble.
log "waiting for claudebox assembly (.assembled)…"
until [ -e "$STATE/.assembled" ]; do sleep 10; done
# 2) the standing GitHub credential must be wired (dev-author opens PRs).
log "waiting for the standing GitHub credential…"
until gh auth status >/dev/null 2>&1 || [ -s "$HOME/.git-credentials" ]; do sleep 10; done

log "up — interval=${LOOP_INTERVAL}s scope-reader=$REPO_SCOPE (R9 fleet HALT + R16 scope gate every pass, inside dev-loop.sh)"
while :; do
  one_cycle
  sleep "$LOOP_INTERVAL"
done
