#!/bin/bash
# PID 1 (root). Starts sshd unconditionally (mosh rides on it), tailscaled with
# TS_AUTHKEY (unattended) or an ACTION-REQUIRED login banner, then supervises.
set -eu

# ---- runtime password (never baked into a layer; container refuses to start
# without it so a published image can never carry a known default) ------------
: "${CORE_PASSWORD:?CORE_PASSWORD must be set (use run.sh)}"
echo "core:${CORE_PASSWORD}" | chpasswd
unset CORE_PASSWORD

# ---- home volume may be empty on first run ----------------------------------
if [ ! -e /home/core/.bashrc ]; then
    cp -rT /etc/skel /home/core
fi
chown core:core /home/core

# ---- rootless podman needs a runtime dir (no systemd/PAM session manager) ---
install -d -m 0700 -o core -g core /run/user/1000

# ---- persistent ssh host keys on the root-owned state volume ----------------
install -d -m 0700 /var/lib/tailscale/hostkeys
if [ ! -f /var/lib/tailscale/hostkeys/ssh_host_ed25519_key ]; then
    ssh-keygen -t ed25519 -N "" -f /var/lib/tailscale/hostkeys/ssh_host_ed25519_key
fi
mkdir -p /run/sshd

# ---- sshd first: reachable even before tailnet auth (mosh rides on sshd) ----
/usr/sbin/sshd

# ---- tailscaled --------------------------------------------------------------
/usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock &
for _ in $(seq 1 30); do
    tailscale status >/dev/null 2>&1 && break
    [ -S /var/run/tailscale/tailscaled.sock ] && break
    sleep 1
done

if [ -n "${TS_AUTHKEY:-}" ]; then
    until tailscale up --ssh --authkey="${TS_AUTHKEY}" --hostname=fedora-dev; do
        echo "[tailscale] up failed, retrying in 5s"; sleep 5
    done
    echo "==== TAILNET JOINED ===="
else
    (
        until tailscale up --ssh --hostname=fedora-dev 2>&1 | sed 's/^/[tailscale] /'; do
            sleep 5
        done
        echo "==== TAILNET JOINED ===="
    ) &
    echo "=================================================================="
    echo " ACTION REQUIRED: open the login.tailscale.com URL printed above"
    echo " (podman logs -f fedora-dev). One-time per tailscale state volume."
    echo "=================================================================="
fi

echo "fedora-dev up: ssh :22 + mosh (UDP 60000-61000), $(podman --version)"

# ---- supervision: exit on service death; outer --restart=always heals -------
while sleep 30; do
    pgrep -x tailscaled >/dev/null || { echo "tailscaled died"; exit 1; }
    pgrep -x sshd       >/dev/null || { echo "sshd died";       exit 1; }
done
