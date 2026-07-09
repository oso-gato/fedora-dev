#!/usr/bin/env bash
# poller-service.sh — supervise the dev-side PR poller (bin/pr-poller.sh) as a headless IN-BOX service.
#
# WHY IN-BOX: the poller's REVIEW/FIX steps spawn `claude -p`, and `claude` lives in the claudebox
# (Distrobox), NOT the fedora-dev base where entrypoint.sh runs. So entrypoint.sh launches THIS wrapper
# inside the box (`distrobox enter claudebox -- poller-service.sh`), gated on POLLER_ENABLED.
#
# WHY A PLAIN-SHELL SERVICE (not the interactive agent): here there is no Claude Code → no gate-push
# hook, no permission classifier → the deterministic auto-merge path (POLLER_ARMED=1) actually executes.
# The interactive agent is deliberately gated FROM these actions; the dumb, gate-checked service is the
# sanctioned autonomous-merge path. DISARMED by default — arming (POLLER_ARMED=1) is the #96 Tier-A flip.
#
# Env: this wrapper passes its whole environment through to pr-poller.sh. entrypoint.sh forwards
# POLLER_ARMED + FITNESS_LOGIN into the box across the distrobox boundary (`distrobox enter` does not
# inherit the base env); POLLER_REPO, POLL_INTERVAL, FITNESS_SAME_IDENTITY use their in-box defaults.
# This wrapper only adds readiness-waiting + restart-on-death.
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
STATE="$HOME/.local/state/claudebox"
LOGDIR="$HOME/.local/state/pr-poller"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/service.log"
log(){ echo "[$(date -u +%FT%TZ 2>/dev/null || date)] poller-service: $*" | tee -a "$LOG" >&2; }

# 1) The box must be ASSEMBLED — the REVIEW/FIX steps need `claude` + `gh`, present only post-assemble.
log "waiting for claudebox assembly (.assembled)…"
until [ -e "$STATE/.assembled" ]; do sleep 10; done

# 2) The standing GitHub credential must be wired (entrypoint mints + installs it; 40-min refresh).
#    Either gh's own auth or the git credential store proves it landed on the home volume.
log "waiting for the standing GitHub credential…"
until gh auth status >/dev/null 2>&1 || [ -s "$HOME/.git-credentials" ]; do sleep 10; done

log "up — repo=${POLLER_REPO:-fedora-dev} armed=${POLLER_ARMED:-0} interval=${POLL_INTERVAL:-60}s same-identity=${FITNESS_SAME_IDENTITY:-1}"

# 3) Run the watch loop (pr-poller.sh holds its own flock singleton). Restart on unexpected exit so a
#    transient failure (network blip, API 5xx) self-heals; bounded backoff so a hard-fail can't spin.
while :; do
  "$HERE/pr-poller.sh" --watch
  rc=$?
  log "pr-poller --watch exited (rc=$rc) — restarting in 30s"
  sleep 30
done
