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

# Self-recovery: remove any partial-state box from a prior failed assemble.
# `distrobox.ini` has `replace=false`, so `assemble create` REFUSES to overwrite
# an existing box. Without this rm, ANY partial failure (a network hiccup mid
# dnf install, etc.) loops forever — entrypoint restarts, eager assemble retries,
# `create` refuses because the partial box is still there. This rm makes assemble
# fully recoverable on every retry. (box-rebuild.sh's own rm becomes redundant
# but harmless.)
echo ">> ensure clean slate (rm any prior partial-state box)…"
distrobox rm -f claudebox >/dev/null 2>&1 || true

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
    distrobox rm -f claudebox >/dev/null 2>&1 || true
    exit 1
}

# Guard: the box's root maps to THIS user (uid 1000) via keep-id, so the steps below
# can only read the spec at /run/host$LIVE if that path is traversable+readable by
# this user. /home/core (mode 0755 by default) and ~/.local/share (also 0755) are
# fine, but fail LOUDLY here if a user has tightened them.
distrobox enter claudebox -- test -r "/run/host$LIVE/claudebox-init.sh" || {
    echo "FATAL: claudebox cannot read the live spec at /run/host$LIVE — check that" \
         "/home/core/.local/share/fedora-dev is traversable+readable by uid 1000." >&2
    exit 1
}

echo "==== post-assemble: host bridges (CONTAINER_HOST + in-box claudebox-rebuild) ===="
# Wire the box's host bridges. The `sudo` here is the CONTAINER's own root (distrobox
# grants it passwordless inside the box), NOT fedora-dev's root. We pass only a path
# + our numeric uid across the boundary, so nothing here can detonate quote-eval.
distrobox enter claudebox -- sudo bash "/run/host$LIVE/claudebox-init.sh" "$(id -u)"

echo "==== post-assemble: stamp enterprise policy into the box ===="
distrobox enter claudebox -- sudo mkdir -p /etc/claude-code
distrobox enter claudebox -- sudo cp \
    "/run/host$LIVE/policy/CLAUDE.md" /etc/claude-code/CLAUDE.md
distrobox enter claudebox -- sudo cp \
    "/run/host$LIVE/policy/managed-settings.json" /etc/claude-code/managed-settings.json

# Mark assembled — entrypoint's first-boot guard checks this.
touch "$HOME/.local/state/claudebox/.assembled"

echo "==== claudebox READY: claude-code on latest channel + bridges + policy ===="
echo "   Run 'claude' from a tmux shell to start working."
