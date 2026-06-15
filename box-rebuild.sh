#!/usr/bin/env bash
# fedora-dev — full claudebox rebuild (destroy + recreate from the LIVE manifest).
#
# Triggered by one of three paths, all converge here (run detached via setsid nohup
# so this script OUTLIVES the box it tears down):
#   1. Daily-tick supervisor in entrypoint.sh -> claudebox-daily.sh (if idle).
#   2. In-box `claudebox-rebuild` writes ~/.local/state/claudebox/rebuild.request
#      -> entrypoint.sh's inotify watcher fires this script.
#   3. Host-shell `claudebox-rebuild` (the wrapper at /usr/local/bin/claudebox-rebuild)
#      starts this script directly and tails the log.
#
# The rebuild = drop the box, then re-run claudebox-assemble.sh: a fresh
# `distrobox assemble create` re-pulls the base image and reinstalls the LATEST-channel
# claude-code + tools from Anthropic's repo, then re-applies the host bridges
# (claudebox-init.sh) + Claude policy. Your Claude login/credentials SURVIVE — they
# live in the shared HOME (the fedora-dev home volume), not the disposable box.
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
LIVE=/home/core/.local/share/fedora-dev
state="$HOME/.local/state/claudebox"
mkdir -p "$state"

# Self-serialize: if another box-rebuild.sh is already running (e.g. the daily
# tick fired at the same moment as an inotify-driven in-box request), exit
# cleanly rather than racing on `distrobox assemble create`. Bootstrap relied
# on systemd's single-unit serialization; without systemd we self-lock.
exec 9<>"$state/box-rebuild.lock"
flock -n 9 || {
    echo "[box-rebuild] another rebuild is already in progress — exiting"
    exit 0
}

# Any rebuild satisfies a deferred daily refresh — clear the marker so the `claude`
# wrapper's exit hook won't re-fire it.
rm -f "$state/rebuild.pending" 2>/dev/null || true

echo ">> claudebox rebuild: removing the existing box (force) …"
distrobox rm -f claudebox >/dev/null 2>&1 || true

echo ">> claudebox rebuild: re-running assemble from live spec at $LIVE …"
exec bash "$LIVE/claudebox-assemble.sh"
