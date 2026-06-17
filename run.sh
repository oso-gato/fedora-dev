#!/bin/bash
# Deploy fedora-dev (rootless podman). NEVER hand-roll podman run:
# this carries the runtime --health-cmd (OCI images drop Containerfile
# HEALTHCHECK), the tun/fuse devices, the restart policy, AND the port
# publishes for public-IP key-auth ssh (4444) + public mosh (61001-62000/udp).
#
#   [TS_AUTHKEY=tskey-…] [IMAGE=…] ./run.sh
#
# v1.1.9: sshd is key-only (keys synced from github.com/oso-gato.keys at
# every container start). NO CORE_PASSWORD required; honored if set, but
# the new sshd config (PasswordAuthentication=no) makes it inert. Public
# ssh on host:4444 → container:22 (key auth); mosh public on UDP 61001-62000.
# Tailscale SSH (tailnet, keyless) remains the primary path.
set -eu
IMAGE="${IMAGE:-localhost/fedora-dev:latest}"

podman run -d --name fedora-dev \
    --restart=always \
    --cap-add NET_ADMIN \
    --device /dev/net/tun \
    --device /dev/fuse \
    --security-opt label=disable \
    -e TS_AUTHKEY="${TS_AUTHKEY:-}" \
    -v fedora-dev-home:/home/core \
    -v fedora-dev-state:/var/lib/tailscale \
    -p 4444:22 \
    -p 61001-62000:61001-62000/udp \
    --health-cmd 'pgrep -x sshd && pgrep -x tailscaled && test -S /run/user/1000/podman/podman.sock' \
    --health-interval 30s --health-retries 3 \
    "$IMAGE"

echo "Started. If no TS_AUTHKEY was given: podman logs -f fedora-dev and open"
echo "the ACTION REQUIRED login.tailscale.com link (one-time per state volume)."
echo "Connect:"
echo "  ssh -p 4444 core@<public-ip>     (key auth — keys from github.com/oso-gato.keys)"
echo "  ssh core@<tailnet-ip>            (Tailscale SSH, keyless)"
echo "  mosh -p 61001:62000 --ssh='ssh -p 4444' core@<public-ip>   (or via tailnet — UDP range avoids host mosh)"
echo "All paths land in tmux session 'main'."
