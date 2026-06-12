#!/bin/bash
# Deploy fedora-dev (rootless podman). NEVER hand-roll podman run:
# this carries the runtime --health-cmd (OCI images drop Containerfile
# HEALTHCHECK), the tun/fuse devices, and the restart policy.
#
#   CORE_PASSWORD='…' [TS_AUTHKEY=tskey-…] [IMAGE=…] ./run.sh
set -eu
: "${CORE_PASSWORD:?set CORE_PASSWORD (login password for core over ssh/mosh)}"
IMAGE="${IMAGE:-localhost/fedora-dev:latest}"

podman run -d --name fedora-dev \
    --restart=always \
    --cap-add NET_ADMIN \
    --device /dev/net/tun \
    --device /dev/fuse \
    --security-opt label=disable \
    -e CORE_PASSWORD="${CORE_PASSWORD}" \
    -e TS_AUTHKEY="${TS_AUTHKEY:-}" \
    -v fedora-dev-home:/home/core \
    -v fedora-dev-state:/var/lib/tailscale \
    --health-cmd 'pgrep -x sshd && pgrep -x tailscaled' \
    --health-interval 30s --health-retries 3 \
    "$IMAGE"

echo "Started. If no TS_AUTHKEY was given: podman logs -f fedora-dev and open"
echo "the ACTION REQUIRED login.tailscale.com link (one-time per state volume)."
echo "Connect: ssh core@<tailnet-ip>  or  mosh core@<tailnet-ip>  (lands in tmux)"
echo "Ports 22/2022 are tailnet-only — never publish them with -p."
