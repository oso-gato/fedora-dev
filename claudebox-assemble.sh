#!/usr/bin/env bash
# fedora-dev — assemble (or RE-assemble) the claudebox Distrobox.
#
# Called by:
#   * entrypoint.sh on FIRST BOOT (when no .assembled marker exists)
#   * box-rebuild.sh on every rebuild (after `distrobox rm -f claudebox`)
#
# Runs as `core` (uid 1000). Reads the LIVE spec from /home/core/.local/share/fedora-dev/
# — a git clone seeded from the baked-image copy and persisted on the home volume.
# Idempotent: re-running re-pulls, re-installs, re-applies bridges + policy.
set -euo pipefail
[ "$(id -u)" = "1000" ] || {
    echo "claudebox-assemble.sh must run as core (uid 1000)" >&2; exit 1
}

# ASSEMBLE_LIVE is a TEST SEAM only (assemble-stamp.test.sh drives this real script
# against a fixture spec + stub podman/distrobox); production callers never set it.
LIVE="${ASSEMBLE_LIVE:-/home/core/.local/share/fedora-dev}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

cd "$LIVE"

# Health-honesty marker (#11). claudebox-assemble.sh is the SINGLE entry for every
# assemble path (entrypoint first boot, the `claude` wrapper self-heal, box-rebuild),
# so an EXIT trap here is the one authoritative place to reflect THIS run's outcome:
#   non-zero exit (any failure / `set -e` abort) -> write .assemble-failed
#   clean exit                                   -> clear it
# The container health cmd keys off `! test -e .assemble-failed`, so a half-assembled
# box reads UNHEALTHY, while a normal IN-PROGRESS assemble (marker absent) stays
# healthy — no false-unhealthy during the slow first boot (cf. fedora-dev.container).
# Keyed on FAILURE (not on the .assembled success marker on purpose): .assembled
# persists on the home volume, so a FAILED re-assemble/rebuild would still read
# healthy off a stale success marker — the failure marker cannot.
STATE="$HOME/.local/state/claudebox"
mkdir -p "$STATE"
_assemble_finish() {
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        rm -f "$STATE/.assemble-failed"
    else
        printf '%s assemble exited rc=%s — see first-assemble.log\n' \
            "$(date -u +%FT%TZ 2>/dev/null || date)" "$rc" > "$STATE/.assemble-failed"
    fi
}
trap _assemble_finish EXIT

# Robust teardown: distrobox/podman `rm -f` can fail to evict a box wedged in
# podman's `stopping` state. In this nested-rootless setup, crun's SIGKILL may not
# reap the container init within the stop timeout (`rm -f` reports "given PID did
# not die within timeout"), leaving podman's recorded state desynced from the live
# conmon+init. A swallowed failure there is fatal downstream: `assemble create`
# (replace=false) then reports "claudebox already exists" and never recreates the
# box, and `distrobox enter` fails with "container ... state improper". So: try the
# normal removal, VERIFY it actually worked, and if not, SIGKILL the conmon+init
# PIDs directly (a parent-namespace SIGKILL is unblockable and succeeds where
# crun's did not), reconcile state, and re-verify — failing LOUDLY rather than
# assembling against a leftover.
force_destroy_box() {
    local name=claudebox
    distrobox rm -f "$name"  >/dev/null 2>&1 || true
    podman rm -f -t 0 "$name" >/dev/null 2>&1 || true
    podman container exists "$name" || return 0

    echo ">> box '$name' did not remove cleanly — escalating (SIGKILL conmon/init)…" >&2
    local ipid cpid
    ipid=$(podman inspect "$name" --format '{{.State.Pid}}'       2>/dev/null || true)
    cpid=$(podman inspect "$name" --format '{{.State.ConmonPid}}' 2>/dev/null || true)
    [ -n "${ipid:-}" ] && [ "$ipid" != 0 ] && kill -9 "$ipid" 2>/dev/null || true
    [ -n "${cpid:-}" ] && [ "$cpid" != 0 ] && kill -9 "$cpid" 2>/dev/null || true
    podman container cleanup "$name" >/dev/null 2>&1 || true
    podman rm -f -t 0 "$name"        >/dev/null 2>&1 || true

    if podman container exists "$name"; then
        echo "FATAL: could not destroy wedged box '$name' — refusing to assemble" \
             "against a leftover (would hit 'already exists' / 'container state improper')." >&2
        return 1
    fi
}

# Self-recovery: remove any partial-state box from a prior failed assemble.
# `distrobox.ini` has `replace=false`, so `assemble create` REFUSES to overwrite
# an existing box. Without this rm, ANY partial failure (a network hiccup mid
# dnf install, etc.) loops forever — entrypoint restarts, eager assemble retries,
# `create` refuses because the partial box is still there. This rm makes assemble
# fully recoverable on every retry. (box-rebuild.sh's own rm becomes redundant
# but harmless.)
echo ">> ensure clean slate (rm any prior partial-state box)…"
force_destroy_box

echo "==== assemble: distrobox assemble create --file $LIVE/distrobox.ini ===="
# Defense-in-depth (the REAL fix is box-rebuild.sh running THIS script with fd 9 closed):
# close fd 9 on the box-CREATING commands so that if any future caller ever execs into this
# script while holding the box-rebuild.lock on fd 9, the long-lived nested box still cannot
# inherit that exclusive lock (which wedges box-rebuild.lock open forever and hangs every
# later rebuild). `9>&-` is harmless when fd 9 is already closed — the normal path.
distrobox assemble create --file "$LIVE/distrobox.ini" 9>&-

echo ">> first enter: triggers distrobox-init (dnf install claude-code from latest"
echo "   channel + git + gh + openssh-clients + podman + sandbox deps + rclone) —"
echo "   this can take ~2-5 minutes on first run"
# Retry the first enter — it kicks off the in-box dnf install of claude-code +
# tools from Anthropic + Fedora repos. A transient DNS/repo hiccup here would
# otherwise leave the box half-installed and the .assembled marker untouched,
# trapping us in a retry loop the next boot wouldn't recover from (covered above).
ok=0
for attempt in 1 2 3; do
    if distrobox enter claudebox -- true 9>&-; then
        ok=1
        break
    fi
    echo ">> first-enter attempt $attempt failed, retrying in $((attempt*10))s"
    sleep $((attempt*10))
done
[ "$ok" = 1 ] || {
    echo "FATAL: distrobox enter -- true failed 3 times — box install incomplete" >&2
    force_destroy_box || true
    exit 1
}

# Guard: the post-assemble steps below read the live spec at /run/host$LIVE as the
# box's container-root (via `podman exec`). Fail LOUDLY now if that bind-mounted path
# isn't reachable from inside the box — so we never half-stamp it.
podman exec claudebox test -r "/run/host$LIVE/claudebox-init.sh" || {
    echo "FATAL: claudebox cannot read the live spec at /run/host$LIVE — check that" \
         "/home/core/.local/share/fedora-dev is traversable+readable inside the box." >&2
    exit 1
}

echo "==== post-assemble: host bridges (CONTAINER_HOST + in-box claudebox-rebuild) ===="
# Wire the box's host bridges + stamp policy AS REAL CONTAINER-ROOT via `podman exec`
# (it enters the box as uid 0), NOT `distrobox enter -- sudo`.
#
# Why not sudo: this box runs in a PRIVATE userns (distrobox --userns keep-id,
# nested rootless), so podman must id-shift the image into the box's uid range. The
# chown-free path (idmapped mounts) is kernel-forbidden for unprivileged users, so
# podman id-shifts via chown(2) — which clears the setuid bit. /usr/bin/sudo lands
# as mode 0111 owned by the mapped user, so `sudo`
# fails ("must be owned by uid 0 and have the setuid bit set") and, under `set -e`,
# this used to abort assemble BEFORE the policy stamp + the .assembled marker —
# leaving the box without its CONTAINER_HOST bridge or enterprise policy. `podman
# exec` is real container-root, needs no setuid, and is just as quote-safe (only a
# path + a numeric uid cross the boundary). In-box sudo stays non-functional by
# construction; break-glass into the box is `podman exec -u 0 claudebox …` from
# fedora-dev (mirrors fedora-dev's own key-only/no-sudo posture).
podman exec claudebox bash "/run/host$LIVE/claudebox-init.sh" "$(id -u)"

echo "==== post-assemble: stamp enterprise policy into the box ===="
podman exec claudebox mkdir -p /etc/claude-code
# Assemble the law: per-box header + <!--FLEET-CORE--> marker replaced by fleet-core.md
# (fleet-core.md = THE FLEET + THE SELF-SUSTAINING APPARATUS, mastered in fedora-dev).
# Both files are in the SAME live clone ($LIVE), so no network fetch is needed here.
_law=$(mktemp /tmp/assembled-law-XXXXXX)
sed -e "/<!--FLEET-CORE-->/r ${LIVE}/policy/fleet-core.md" \
    -e "/<!--FLEET-CORE-->/d" \
    "${LIVE}/policy/CLAUDE.md" > "$_law"
podman exec claudebox cp "/run/host${_law}" /etc/claude-code/CLAUDE.md
podman exec claudebox cp \
    "/run/host$LIVE/policy/managed-settings.json" /etc/claude-code/managed-settings.json
# mktemp creates 0600 and in-box cp carries the SOURCE mode onto a new dest (an
# EXISTING dest keeps whatever mode it already had) — so without an explicit mode the
# root-owned law lands unreadable by the session user: stamped, fresh mtime, and
# completely INERT (observed live 2026-07-13, #175). Root ownership is the point (the
# agent must not edit its own law); world-readable is the function (it must LOAD it).
podman exec claudebox chmod 644 \
    /etc/claude-code/CLAUDE.md /etc/claude-code/managed-settings.json

echo "==== post-assemble: verify the stamp is loadable by the session user (#175) ===="
# 'Stamped' means READABLE AND CURRENT as the uid that loads it — not 'a file exists'.
# Read the law back AS core and compare it byte-for-byte against what was just
# assembled; any failure (permission denied, truncation, stale content) aborts BEFORE
# the .assembled marker, and the EXIT trap surfaces it as .assemble-failed (#11).
if ! podman exec --user core claudebox cat /etc/claude-code/CLAUDE.md | cmp -s - "$_law"; then
    echo "FATAL: /etc/claude-code/CLAUDE.md is unreadable as core or does not match" \
         "the assembled law — the stamp would be INERT (#175)." >&2
    rm -f "$_law"
    exit 1
fi
rm -f "$_law"
podman exec --user core claudebox test -r /etc/claude-code/managed-settings.json || {
    echo "FATAL: /etc/claude-code/managed-settings.json is unreadable as core (#175)." >&2
    exit 1
}

# UNSHACKLED (P0, 2026-07-11): the gate-push PreToolUse hook is RETIRED — policy/hooks/ no longer
# exists and managed-settings.json registers no PreToolUse hook (merge safety = the require-PR
# server ruleset + the `Bash(gh pr merge:*)` deny + the poller's two independent gates). Remove any
# hooks dir a PREVIOUS stamp left behind so already-deployed boxes converge to the hook-free state
# on their next rebuild (an unregistered leftover is inert, but dead guard code invites confusion).
echo "==== post-assemble: remove retired PreToolUse hooks (unshackle) ===="
podman exec claudebox rm -rf /etc/claude-code/hooks

# Mark assembled — entrypoint's first-boot guard checks this. The _assemble_finish
# EXIT trap clears any .assemble-failed on this clean exit (health reads healthy).
touch "$STATE/.assembled"

echo "==== claudebox READY: claude-code on latest channel + bridges + policy ===="
echo "   Run 'claude' from a tmux shell to start working."
