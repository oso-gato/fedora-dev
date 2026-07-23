#!/bin/bash
# Deploy fedora-dev (rootless podman). NEVER hand-roll podman run:
# this carries the runtime --health-cmd (OCI images drop Containerfile
# HEALTHCHECK), the tun/fuse devices, the restart policy, AND the port
# publishes for public-IP key-auth ssh (4444) + public mosh (61001-62000/udp).
#
#   [TS_AUTHKEY=tskey-…] [IMAGE=…] ./run.sh   (non-interactive; env-driven)
#   ./spin-up.sh                               (interactive: ASKS for TS_AUTHKEY,
#                                               blank = web-login join, then runs this)
#
# v1.1.9: sshd is key-only (keys synced from github.com/oso-gato.keys at
# every container start). NO CORE_PASSWORD required; honored if set, but
# the new sshd config (PasswordAuthentication=no) makes it inert. Public
# ssh on host:4444 → container:22 (key auth); mosh public on UDP 61001-62000.
# Tailscale SSH (tailnet, keyless) remains the primary path.
set -eu
IMAGE="${IMAGE:-localhost/fedora-dev:latest}"

# Optional STANDING GitHub credential (so the in-box dev loop never stops for auth):
#   GH_APP_ID + GH_APP_INSTALLATION_ID + ONE of:
#     GH_APP_SECRET=<podman-secret-name>  (preferred; the paste-based spin-up.sh path), OR
#     GH_APP_KEY_FILE=<path to the App private-key PEM>  (bind a file), OR
#     GH_TOKEN=<static token>.
# Either way the key lands read-only in tmpfs at /run/secrets/gh_app_key (never persisted to
# the image or the home volume); the App ID / Installation ID are public.
gh_args=()
[ -n "${GH_APP_ID:-}" ]              && gh_args+=( -e "GH_APP_ID=${GH_APP_ID}" )
[ -n "${GH_APP_INSTALLATION_ID:-}" ] && gh_args+=( -e "GH_APP_INSTALLATION_ID=${GH_APP_INSTALLATION_ID}" )
[ -n "${GH_TOKEN:-}" ]               && gh_args+=( -e "GH_TOKEN=${GH_TOKEN}" )
[ -n "${GH_APP_KEY_FILE:-}" ]        && gh_args+=( -v "${GH_APP_KEY_FILE}:/run/secrets/gh_app_key:ro" )
# The DEV key is read by `core` (uid 1000) via `runuser -u core` in the entrypoint, so the mount
# MUST be owned by core (uid=1000,gid=1000) for owner-only 0400 to stay readable; a bare 0400
# (owner uid 0) would EACCES the core reader and break dev auth.
[ -n "${GH_APP_SECRET:-}" ]          && gh_args+=( --secret "${GH_APP_SECRET},type=mount,target=gh_app_key,uid=1000,gid=1000,mode=0400" )

# Optional FITNESS-REVIEW App credential (the fleet-wide independent reviewer identity —
# DISTINCT from the dev App above; auto-merge.sh rejects a self-authored verdict):
#   GH_APP_FITNESS_ID + GH_APP_FITNESS_INSTALLATION_ID + ONE of:
#     GH_APP_FITNESS_SECRET=<podman-secret-name>  (preferred; e.g. gh_app_key_fitness), OR
#     GH_APP_FITNESS_KEY_FILE_HOST=<path to the fitness App private-key PEM>  (bind a file).
# The key lands read-only in tmpfs at /run/secrets/gh_app_key_fitness; the entrypoint mints a
# <=1h token from it and ferries ONLY the token to the home volume (the key never enters the
# box). FITNESS_LOGIN overrides the fleet default bot login (oso-gato-fitness-claudebox).
[ -n "${GH_APP_FITNESS_ID:-}" ]              && gh_args+=( -e "GH_APP_FITNESS_ID=${GH_APP_FITNESS_ID}" )
[ -n "${GH_APP_FITNESS_INSTALLATION_ID:-}" ] && gh_args+=( -e "GH_APP_FITNESS_INSTALLATION_ID=${GH_APP_FITNESS_INSTALLATION_ID}" )
[ -n "${FITNESS_LOGIN:-}" ]                  && gh_args+=( -e "FITNESS_LOGIN=${FITNESS_LOGIN}" )
[ -n "${GH_APP_FITNESS_KEY_FILE_HOST:-}" ]   && gh_args+=( -v "${GH_APP_FITNESS_KEY_FILE_HOST}:/run/secrets/gh_app_key_fitness:ro" )
# The FITNESS key is read ONLY by PID-1 root (the entrypoint ferry + its 40-min refresh), so owner-root
# 0400 is intended: root reads it, and the nested claudebox (a separate userns, uid 0 unmapped) cannot —
# keeping the independent reviewer's key invisible in-box (the author≠judge boundary). No uid= here.
[ -n "${GH_APP_FITNESS_SECRET:-}" ]          && gh_args+=( --secret "${GH_APP_FITNESS_SECRET},type=mount,target=gh_app_key_fitness,mode=0400" )

# TS_AUTHKEY (the day-0 unattended tailnet-join key) is delivered as a MOUNTED podman secret FILE, NOT
# an env var: `-e TS_AUTHKEY=` lands in the container's persistent environment, which distrobox
# re-materialises as `--env=TS_AUTHKEY=<key>` on the argv of EVERY `distrobox enter`/`podman exec`
# (world-readable via /proc/<pid>/cmdline). The mount keeps it off both the env and every argv; the
# entrypoint reads /run/secrets/ts-authkey and joins via tailscale's `--auth-key=file:` prefix. The
# secret name matches the deployed Quadlet's (setup-user.sh creates the same `fedora-dev-ts-authkey`).
ts_args=()
if [ -n "${TS_AUTHKEY:-}" ]; then
    printf '%s' "$TS_AUTHKEY" | podman secret create --replace fedora-dev-ts-authkey - >/dev/null
    ts_args+=( --secret "fedora-dev-ts-authkey,type=mount,target=ts-authkey,mode=0400" )
fi

podman run -d --name fedora-dev \
    --hostname "${BOX_HOSTNAME:-fedora-dev}" \
    --restart=always \
    --cap-add NET_ADMIN \
    --cap-add SYS_ADMIN \
    --device /dev/net/tun \
    --device /dev/fuse \
    --security-opt label=disable \
    "${ts_args[@]}" \
    -e POLLER_ENABLED="${POLLER_ENABLED:-}" \
    -e POLLER_ARMED="${POLLER_ARMED:-}" \
    -e DEV_LOOP_ENABLED="${DEV_LOOP_ENABLED:-}" \
    -e DEVBOX_MANIFEST_V2="${DEVBOX_MANIFEST_V2:-1}" \
    -e FITNESS_SAME_IDENTITY="${FITNESS_SAME_IDENTITY:-}" \
    "${gh_args[@]}" \
    -v fedora-dev-home:/home/core \
    -v fedora-dev-state:/var/lib/tailscale \
    -p 4444:22 \
    -p 61001-62000:61001-62000/udp \
    --health-cmd 'pgrep -x sshd && pgrep -x tailscaled && test -S /run/user/1000/podman/podman.sock && ! test -e /home/core/.local/state/claudebox/.assemble-failed' \
    --health-interval 30s --health-retries 3 \
    "$IMAGE"

echo "Started. If no TS_AUTHKEY was given: podman logs -f fedora-dev and open"
echo "the ACTION REQUIRED login.tailscale.com link (one-time per state volume)."
echo "Connect:"
echo "  ssh -p 4444 core@<public-ip>     (key auth — keys from github.com/oso-gato.keys)"
echo "  ssh core@<tailnet-ip>            (Tailscale SSH, keyless)"
echo "  mosh -p 61001:62000 --ssh='ssh -p 4444' core@<public-ip>   (or via tailnet — UDP range avoids host mosh)"
echo "All paths land in tmux session 'main'."
