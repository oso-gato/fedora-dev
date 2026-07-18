#!/usr/bin/env bash
# supervise-enter-race.test.sh — proves the entrypoint.sh poller/deadman supervise loops survive the
# distrobox-enter RESTART RACE: `distrobox enter` re-runs a `podman logs -f` follow for the
# container_setup_done sentinel (distrobox-enter:702/734/756) ONLY when the box is not already running,
# and that follow can HANG FOREVER after a restart when the sentinel is missed — wedging the loop and
# forcing manual recovery (observed 2026-07-14). The fix is a `box_ready` bounded readiness probe
# (`timeout … distrobox enter -- true`) gating the long-running enter.
#
# This drives a REPLICA of the loop's one-iteration decision against a STUB `distrobox` (BOX_STATE
# fixture: up = enter succeeds; down = enter HANGS) with the REAL coreutils `timeout`, so the bounded
# behaviour is exercised, not asserted. A DRIFT GUARD pins the replica to the real entrypoint.sh guard.
#   bash supervise-enter-race.test.sh  → exit 0 = all rows pass. No GitHub/network/real podman.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ENTRYPOINT="$HERE/entrypoint.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; kill %1 %2 2>/dev/null' EXIT
fail=0
ck(){ if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

# ── stub `distrobox`: models `enter claudebox -- <cmd>` under a BOX_STATE fixture (up|down|starting) ──
#   enter claudebox -- true          → the readiness probe.  down ⇒ HANG (exec sleep); up ⇒ exit 0;
#                                       starting ⇒ the probe STARTS the box (writes 'up' to STATE_FILE,
#                                       modelling distrobox's podman-start + setup-wait completing) ⇒ exit 0
#   enter claudebox -- bash -lc ...   → the real service enter. records that it ran; down ⇒ also HANG
# A STATE_FILE (when set) overrides BOX_STATE, so a `starting` probe leaves the box `up` for the real enter.
# `exec sleep` on the hang path makes the sleep `timeout`'s DIRECT child, so timeout reaps it (no orphan).
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/distrobox" <<'STUB'
#!/usr/bin/env bash
state="${BOX_STATE:-up}"
[ -n "${STATE_FILE:-}" ] && [ -s "$STATE_FILE" ] && state="$(cat "$STATE_FILE")"
if [ "$1" = enter ] && [ "$2" = claudebox ] && [ "$3" = -- ]; then
    shift 3
    case "$*" in
        true)
            case "$state" in
                down)     exec sleep 30 ;;
                starting) printf up > "${STATE_FILE:?}"; exit 0 ;;   # probe starts the box + setup completes
                *)        exit 0 ;;
            esac ;;
        *)  printf '%s\n' "$*" >> "${REAL_ENTER_MARKER:?}"; [ "$state" = down ] && exec sleep 30; exit 0 ;;
    esac
fi
exit 0
STUB
chmod +x "$BIN/distrobox"
export PATH="$BIN:$PATH"          # stub distrobox wins; REAL /usr/bin/timeout is untouched

# box_ready is a BYTE-FOR-BYTE replica of the entrypoint.sh guard (drift-guarded below).
box_ready() { timeout -k 10 "${PROBE_TIMEOUT:-120}" distrobox enter claudebox -- true >/dev/null 2>&1; }
# iter: ONE iteration of the supervise while-body (the fixed shape shared by both loops).
iter() {
    if box_ready; then
        distrobox enter claudebox -- bash -lc "exec /svc" || true
    else
        echo "[test] claudebox not enterable — retrying" >&2
    fi
}

# ── Row 1: box UP → probe succeeds → the real (long-running) enter RUNS ───────────────────────────────
REAL_ENTER_MARKER="$TMP/m1"; : > "$REAL_ENTER_MARKER"
BOX_STATE=up PROBE_TIMEOUT=5 REAL_ENTER_MARKER="$REAL_ENTER_MARKER" iter >/dev/null 2>&1
ck "box up: probe passes → real enter runs" '[ -s "$REAL_ENTER_MARKER" ]'

# ── Row 1b: LIVENESS — box was DOWN but the probe STARTS it + completes setup → the SAME iteration then
#    runs the real enter via the fast path (the mechanism the fix actually rests on) ───────────────────
REAL_ENTER_MARKER="$TMP/m1b"; : > "$REAL_ENTER_MARKER"
SF="$TMP/state1b"; : > "$SF"
t0=$SECONDS
BOX_STATE=starting STATE_FILE="$SF" PROBE_TIMEOUT=5 REAL_ENTER_MARKER="$REAL_ENTER_MARKER" iter >/dev/null 2>&1
dt=$((SECONDS - t0))
ck "liveness: probe starts a down box → real enter runs same iteration" '[ -s "$REAL_ENTER_MARKER" ]'
ck "liveness: and it fast-paths (bounded, no wait)" '[ "$dt" -lt 12 ]'

# ── Row 2: box DOWN (setup hangs) → probe is KILLED → real enter SKIPPED, loop does NOT hang ─────────
REAL_ENTER_MARKER="$TMP/m2"; : > "$REAL_ENTER_MARKER"
t0=$SECONDS
BOX_STATE=down PROBE_TIMEOUT=2 REAL_ENTER_MARKER="$REAL_ENTER_MARKER" iter >/dev/null 2>&1
dt=$((SECONDS - t0))
ck "box down: real enter SKIPPED (never launched into the hang)" '[ ! -s "$REAL_ENTER_MARKER" ]'
ck "box down: iteration returns bounded (<12s), never hangs" '[ "$dt" -lt 12 ]'

# ── Row 3: MUTATION — remove the box_ready gate; the real enter is called directly and HANGS on a down
#    box (rc 124 under an outer timeout). Proves the probe is what prevents the unbounded hang. ────────
REAL_ENTER_MARKER="$TMP/m3"; : > "$REAL_ENTER_MARKER"
mutated="$TMP/mutated.sh"
cat > "$mutated" <<'MUT'
distrobox enter claudebox -- bash -lc "exec /svc" || true
MUT
BOX_STATE=down REAL_ENTER_MARKER="$REAL_ENTER_MARKER" timeout -k 5 5 bash "$mutated" >/dev/null 2>&1
rc=$?
ck "mutation (no probe): unguarded enter HANGS (outer timeout fires, rc=124)" '[ "$rc" = 124 ]'
ck "mutation: it did reach the real enter (proves the row is not vacuous)" '[ -s "$REAL_ENTER_MARKER" ]'

# ── Row 4: DRIFT GUARD — the real entrypoint.sh carries the box_ready guard on BOTH supervise loops ───
n="$(grep -cF 'box_ready() { timeout -k 10 "${PROBE_TIMEOUT:-120}" distrobox enter claudebox -- true' "$ENTRYPOINT")"
ck "drift guard: entrypoint.sh carries the box_ready probe on all three loops (poller + deadman + dev-loop; found $n/3)" '[ "$n" = 3 ]'
ck "drift guard: all three loops gate the real enter behind it (if box_ready)" '[ "$(grep -cF "if box_ready; then" "$ENTRYPOINT")" = 3 ]'

echo
[ "$fail" = 0 ] && echo "supervise-enter-race.test.sh: ALL PASS" || echo "supervise-enter-race.test.sh: FAILURES ABOVE"
exit "$fail"
