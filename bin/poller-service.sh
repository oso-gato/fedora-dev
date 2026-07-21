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
# sanctioned autonomous-merge path. ARMED by default (gate-free objective — no human approves the shipment);
# the merge-trust boundary is the two distinct App-identity gates, not a human arm. POLLER_ARMED=0 is a
# deliberate dry-run soak (the #96 explicit Tier-A arm is retired, pre-ZERO-GATE).
#
# Env: this wrapper passes its whole environment through to pr-poller.sh. entrypoint.sh forwards
# POLLER_ARMED + FITNESS_LOGIN into the box across the distrobox boundary (`distrobox enter` does not
# inherit the base env); POLLER_REPO, POLL_INTERVAL, FITNESS_SAME_IDENTITY use their in-box defaults.
# This wrapper only adds readiness-waiting + restart-on-death + the SELF-REFRESH reload (#162).
#
# SELF-REFRESH (#162): when pr-poller.sh detects (at a safe point) that origin/<branch> has fast-forwarded
# past the code it runs, it EXITS POLLER_RELOAD_RC. THIS supervisor then ff-pulls the shared live clone
# and relaunches pr-poller.sh --watch on the NEW code — so the running poller deploys its OWN merged
# machinery with no human `git pull` + bounce. The flock singleton survives (the old poller fully exited,
# freeing its lock, before the new one starts), and FAIL-SAFE TOWARD PROGRESS holds: a failed fetch or a
# dirty/diverged clone leaves the clone untouched and relaunches the CURRENT code. The supervisor itself
# is NOT re-exec'd — a poller-service.sh change still takes effect on the next box bounce; the poller and
# every bin/*.sh it invokes (the bulk of the machinery) reload here.
#
# LOCK LIVENESS (#173): pr-poller adjudicates its own flock singleton (a dead or previous-box-generation
# holder is taken over, never deferred to) and a genuine deferral exits POLLER_DEFER_RC — this loop names
# that rc for what it is instead of logging a healthy-looking `rc=0` restart forever (the 2026-07-13
# incident: a box recreate left an orphan holding the lock; four hours of zero sweeps, zero signal).
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
STATE="$HOME/.local/state/claudebox"
LOGDIR="$HOME/.local/state/pr-poller"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/service.log"
log(){ echo "[$(date -u +%FT%TZ 2>/dev/null || date)] poller-service: $*" | tee -a "$LOG" >&2; }

# ── SELF-REFRESH (#162) config + the ONLY writer of the clone ────────────────────────────────────────
POLLER_RELOAD_RC="${POLLER_RELOAD_RC:-90}"               # SHARED CONTRACT with bin/pr-poller.sh
# LOCK LIVENESS (#173): the rc pr-poller exits when it DEFERS to another lock holder — never 0, so a
# deferral can never again read as a healthy no-op (2026-07-13: four hours of `exited (rc=0) —
# restarting in 30s` while the singleton was dead). SHARED CONTRACT with bin/pr-poller.sh.
POLLER_DEFER_RC="${POLLER_DEFER_RC:-91}"
SELF_REFRESH_CLONE="${SELF_REFRESH_CLONE:-$(dirname "$HERE")}"  # bin/ sits inside the clone
SELF_REFRESH_REMOTE="${SELF_REFRESH_REMOTE:-origin}"
SELF_REFRESH_BRANCH="${SELF_REFRESH_BRANCH:-main}"
SELF_REFRESH_FETCH_TIMEOUT="${SELF_REFRESH_FETCH_TIMEOUT:-60}"

# self_refresh_pull — fast-forward ONLY advance the live clone to origin/<branch>, logging old→new (req
# 5). This is the ONLY writer of the clone (req 4 — the supervisor re-pulls + relaunches). NEVER a rebase
# or a non-ff merge: `--ff-only` REFUSES a dirty/diverged tree, and that refusal is FAIL-SAFE (log it,
# relaunch the CURRENT code — a human edited it; not clobbering). Idempotent — an already-current clone
# advances to a silent no-op.
self_refresh_pull(){
  local clone="$SELF_REFRESH_CLONE"
  [ -d "$clone/.git" ] || { log "self-refresh: no git clone at $clone — relaunching current code"; return 0; }
  local before after
  before="$(git -C "$clone" rev-parse HEAD 2>/dev/null)"
  if ! timeout "$SELF_REFRESH_FETCH_TIMEOUT" git -C "$clone" fetch -q "$SELF_REFRESH_REMOTE" 2>>"$LOG"; then
    log "self-refresh: fetch FAILED during reload — relaunching current code (${before:0:7}); fail-safe toward progress"
    return 0
  fi
  if git -C "$clone" merge --ff-only "$SELF_REFRESH_REMOTE/$SELF_REFRESH_BRANCH" >>"$LOG" 2>&1; then
    after="$(git -C "$clone" rev-parse HEAD 2>/dev/null)"
    if [ "$before" != "$after" ]; then
      log "self-refresh: clone advanced ${before:0:7} → ${after:0:7} — relaunching poller on the new code"
    else
      log "self-refresh: clone already current (${after:0:7}) — relaunching"
    fi
  else
    log "self-refresh: fast-forward REFUSED (dirty or diverged clone) — leaving clone at ${before:0:7}, relaunching current code (fail-safe; a human edited it — not clobbering)"
  fi
}

# Test seam (#162): run ONE ff-pull and exit — lets poller-selfrefresh.test.sh drive the REAL pull
# against a real clone without the readiness waits or the supervise loop.
case "${1:-}" in
  --self-refresh-pull) self_refresh_pull; exit 0;;
esac

# 1) The box must be ASSEMBLED — the REVIEW/FIX steps need `claude` + `gh`, present only post-assemble.
log "waiting for claudebox assembly (.assembled)…"
until [ -e "$STATE/.assembled" ]; do sleep 10; done

# 2) The standing GitHub credential must be wired (entrypoint mints + installs it; 40-min refresh).
#    Either gh's own auth or the git credential store proves it landed on the home volume.
log "waiting for the standing GitHub credential…"
until gh auth status >/dev/null 2>&1 || [ -s "$HOME/.git-credentials" ]; do sleep 10; done

log "up — repo=${POLLER_REPO:-fedora-dev} armed=${POLLER_ARMED:-1} interval=${POLL_INTERVAL:-10}s same-identity=${FITNESS_SAME_IDENTITY:-1} self-refresh-clone=$SELF_REFRESH_CLONE"

# 3) Run the watch loop (pr-poller.sh holds its own flock singleton).
#    - A SELF-REFRESH exit (#162, POLLER_RELOAD_RC) means "ff-pull my clone + relaunch me on the new
#      code" → an IMMEDIATE relaunch (nothing failed, so no backoff).
#    - Any OTHER exit is an unexpected death → bounded backoff so a transient failure (network blip, API
#      5xx) self-heals without spinning.
while :; do
  "$HERE/pr-poller.sh" --watch
  rc=$?
  if [ "$rc" = "$POLLER_RELOAD_RC" ]; then
    log "pr-poller requested a self-refresh reload (rc=$rc) — ff-pulling the clone + relaunching on the new code"
    self_refresh_pull
    continue
  fi
  if [ "$rc" = "$POLLER_DEFER_RC" ]; then
    # #173 — NOT a healthy no-op: another --watch holds the lock. poller.log carries the holder
    # adjudication and the deferral count; a dead or previous-generation holder is TAKEN OVER (never
    # deferred to), and a persistent streak surfaces its own question. Retry on the same cadence —
    # 30 s is also the recovery latency once the live holder exits.
    log "pr-poller DEFERRED to a live lock holder (rc=$rc) — the singleton did NOT start; see poller.log for the adjudication. Retrying in 30s"
    sleep 30
    continue
  fi
  log "pr-poller --watch exited (rc=$rc) — restarting in 30s"
  sleep 30
done
