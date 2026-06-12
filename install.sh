#!/bin/bash
# Build-time install. Official sources only (Fedora repos, vendor dnf repos,
# vendor .rpms). Sources fact-checked live 2026-06-12.
set -euxo pipefail

DNF="dnf -y --setopt=install_weak_deps=False"

# ---- vendor dnf repos -------------------------------------------------------
# Tailscale (official Fedora repo)
curl -fsSL https://pkgs.tailscale.com/stable/fedora/tailscale.repo \
    -o /etc/yum.repos.d/tailscale.repo

# Claude Code (Anthropic official rpm repo)
cat > /etc/yum.repos.d/claude-code.repo <<'EOF'
[claude-code]
name=Claude Code
baseurl=https://downloads.claude.ai/claude-code/rpm/stable
enabled=1
gpgcheck=1
gpgkey=https://downloads.claude.ai/keys/claude-code.asc
EOF

# GitHub CLI (official rpm repo)
curl -fsSL https://cli.github.com/packages/rpm/gh-cli.repo \
    -o /etc/yum.repos.d/gh-cli.repo

# ---- packages ---------------------------------------------------------------
$DNF install \
    podman shadow-utils fuse-overlayfs passt iptables-nft nftables \
    openssh-server openssh-clients \
    tailscale claude-code gh mosh \
    tmux fastfetch git sudo procps-ng glibc-langpack-en less nano

# ---- rclone (developer .rpm) ------------------------------------------------
curl -fsSL "https://downloads.rclone.org/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-amd64.rpm" \
    -o /tmp/rclone.rpm
$DNF install /tmp/rclone.rpm
rm /tmp/rclone.rpm

# ---- user core (password set at RUNTIME only — never in a layer) ----------
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

# ---- sshd (mosh bootstraps over ssh; also the public fallback door) ----------
# Host keys live on the root-owned tailscale state volume (NOT under core's
# home — core owns that tree and could swap keys) and are generated at runtime.
cat > /etc/ssh/sshd_config.d/99-fedora-dev.conf <<'EOF'
PasswordAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
PermitRootLogin no
AllowUsers core
HostKey /var/lib/tailscale/hostkeys/ssh_host_ed25519_key
EOF
rm -f /etc/ssh/ssh_host_*_key*   # never ship host keys in a published image

dnf clean all
rm -rf /var/cache/dnf /var/cache/libdnf5
