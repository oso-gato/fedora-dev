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

LIVE=/home/core/.local/share/fedora-dev
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

cd "$LIVE"

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
distrobox assemble create --file "$LIVE/distrobox.ini"

echo ">> first enter: triggers distrobox-init (dnf install claude-code from latest"
echo "   channel + git + gh + openssh-clients + podman + sandbox deps + rclone) —"
echo "   this can take ~2-5 minutes on first run"
# Retry the first enter — it kicks off the in-box dnf install of claude-code +
# tools from Anthropic + Fedora repos. A transient DNS/repo hiccup here would
# otherwise leave the box half-installed and the .assembled marker untouched,
# trapping us in a retry loop the next boot wouldn't recover from (covered above).
ok=0
for attempt in 1 2 3; do
    if distrobox enter claudebox -- true; then
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
podman exec claudebox cp \
    "/run/host$LIVE/policy/CLAUDE.md" /etc/claude-code/CLAUDE.md
podman exec claudebox cp \
    "/run/host$LIVE/policy/managed-settings.json" /etc/claude-code/managed-settings.json

# Stamp the managed PreToolUse hooks too. managed-settings.json wires
# /etc/claude-code/hooks/gate-push.sh as a Bash PreToolUse hook with
# allowManagedHooksOnly:true — so the hook script MUST exist at that path or the
# managed hook can't run (and a missing PreToolUse hook fails OPEN, defeating the
# promotion gate). Copy the whole policy/hooks/ tree, normalise perms to 0755 so
# each *.sh is executable regardless of the source/transport mode, and FAIL LOUDLY
# if the gate hook didn't land (rather than boot a box whose gate is silently
# absent). Hidden files (e.g. .gitkeep) are skipped by the *.sh chmod glob.
echo "==== post-assemble: stamp managed PreToolUse hooks into the box ===="
podman exec claudebox mkdir -p /etc/claude-code/hooks
podman exec claudebox cp -a \
    "/run/host$LIVE/policy/hooks/." /etc/claude-code/hooks/
podman exec claudebox bash -c 'chmod 0755 /etc/claude-code/hooks/*.sh 2>/dev/null || true'
podman exec claudebox test -x /etc/claude-code/hooks/gate-push.sh || {
    echo "FATAL: promotion-gate hook /etc/claude-code/hooks/gate-push.sh missing or" \
         "not executable after stamp — refusing to leave the box without its gate." >&2
    exit 1
}

# Mark assembled — entrypoint's first-boot guard checks this.
touch "$HOME/.local/state/claudebox/.assembled"

echo "==== claudebox READY: claude-code on latest channel + bridges + policy ===="
echo "   Run 'claude' from a tmux shell to start working."
