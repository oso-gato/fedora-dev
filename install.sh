#!/bin/bash
# fedora-dev base-image install. Official sources only:
#   (a) Fedora repos via dnf,
#   (b) the vendor's own dnf repo (tailscale).
# Sources fact-checked live 2026-06-15. Claude Code now lives in claudebox
# (a Distrobox container assembled at runtime) — see distrobox.ini for its
# Anthropic `latest`-channel install.
set -euxo pipefail

DNF="dnf -y --setopt=install_weak_deps=False"

# ---- vendor dnf repos -------------------------------------------------------
# Tailscale (official Fedora repo)
curl -fsSL https://pkgs.tailscale.com/stable/fedora/tailscale.repo \
    -o /etc/yum.repos.d/tailscale.repo

# ---- base packages ----------------------------------------------------------
# Tier breakdown (justified in README.md "Base Packages" table):
#   Engine + storage:  podman, shadow-utils, fuse-overlayfs, passt, iptables-nft,
#                      nftables
#   Login + observe:   openssh-server, mosh, tmux, tailscale
#   Box bootstrap:     distrobox, inotify-tools
#   System plumbing:   sudo, procps-ng, glibc-langpack-en
#   Break-glass:       nano
#
# Everything else the agent uses (claude-code, gh, git, openssh-clients, podman
# CLI client, bubblewrap, socat, host-spawn, rclone) lives INSIDE claudebox —
# see distrobox.ini's additional_packages.
$DNF install \
    podman shadow-utils fuse-overlayfs passt iptables-nft nftables \
    openssh-server mosh tmux tailscale \
    distrobox inotify-tools \
    fail2ban rsyslog \
    sudo procps-ng glibc-langpack-en nano

# ---- defensive: restore file caps on newuidmap/newgidmap --------------------
# shadow-utils' RPM scriptlet sets these caps, BUT they can be lost in some
# podman/overlay storage configurations (security.capability xattrs don't
# always survive layer commits). Without these caps, rootless podman setup of
# a nested userns fails with "newuidmap: write to uid_map failed: Operation
# not permitted". Set them explicitly here in OUR layer + verify in entrypoint
# at runtime as a second defense.
setcap cap_setuid+ep /usr/bin/newuidmap
setcap cap_setgid+ep /usr/bin/newgidmap

# ---- user core (password set at RUNTIME only — never in a layer) -----------
useradd -m -u 1000 -s /bin/bash core
usermod -aG wheel core
# Inner subordinate IDs must fit inside the outer rootless 65536-ID map:
# core=1000 plus 10000..64999 < 65536.
echo "core:10000:55000" > /etc/subuid
echo "core:10000:55000" > /etc/subgid

# ---- nested rootless podman (no systemd inside) -----------------------------
install -d -m 0755 /etc/containers
cat > /etc/containers/containers.conf <<'EOF'
[engine]
cgroup_manager = "cgroupfs"
events_logger = "file"
EOF
cat > /etc/containers/storage.conf <<'EOF'
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "nodev,fsync=0"
EOF
cat > /etc/containers/registries.conf <<'EOF'
unqualified-search-registries = ["registry.fedoraproject.org", "docker.io"]
EOF
# No systemd/PAM session manager: provide XDG_RUNTIME_DIR for rootless podman.
cat > /etc/profile.d/xdg-runtime.sh <<'EOF'
if [ "$(id -u)" = "1000" ]; then
    export XDG_RUNTIME_DIR=/run/user/1000
fi
EOF

# ---- every interactive remote login lands in the persistent tmux session ----
cat > /etc/profile.d/zz-tmux-attach.sh <<'EOF'
# ssh and mosh logins attach to (or create) the shared tmux session "main".
case $- in *i*) ;; *) return ;; esac
if [ -z "${TMUX:-}" ] && command -v tmux >/dev/null && { [ -n "${SSH_TTY:-}" ] || [ -t 0 ]; }; then
    exec tmux new-session -A -s main
fi
EOF

# ---- sshd (key-only; reachable via tailnet :22 AND host-published public :4444)
# Host keys live on the root-owned tailscale state volume (NOT under core's
# home — core owns that tree and could swap keys) and are generated at runtime.
# Public ssh on port 4444 is published by the Quadlet/run.sh; container sshd
# listens on 22. Keys for core are synced from github.com/oso-gato.keys by the
# entrypoint at every container start (cached on the home volume so GitHub
# being briefly unreachable doesn't lock the operator out).
cat > /etc/ssh/sshd_config.d/99-fedora-dev.conf <<'EOF'
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
PermitRootLogin no
AllowUsers core
HostKey /var/lib/tailscale/hostkeys/ssh_host_ed25519_key
# AUTHPRIV so rsyslog captures auth events to /var/log/secure for fail2ban.
SyslogFacility AUTHPRIV
LogLevel VERBOSE
EOF
rm -f /etc/ssh/ssh_host_*_key*   # never ship host keys in a published image

# ---- fail2ban — brute-force mitigation for the public-ssh :4444 path ----
# fail2ban watches /var/log/secure (rsyslog writes there from sshd's AUTHPRIV
# facility), bans IPs that fail too many key-auth attempts via iptables-nft.
# Tailnet CGNAT (100.64.0.0/10) is ignoreip'd — tailnet identity is already
# authenticated by Tailscale; we don't want a misbehaving tailnet device to
# ever land on a banned-IP list.
install -d -m 0755 /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/sshd-fedora-dev.local <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = auto
ignoreip = 127.0.0.1/8 ::1 100.64.0.0/10
banaction = iptables-multiport

[sshd]
enabled = true
port = 22
logpath = /var/log/secure
EOF

dnf clean all
rm -rf /var/cache/dnf /var/cache/libdnf5
