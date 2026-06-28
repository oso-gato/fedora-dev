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
#   Engine + storage:  podman, shadow-utils, fuse-overlayfs, passt, nftables
#   Login + observe:   openssh-server, mosh, tmux, tailscale
#   Box bootstrap:     distrobox, inotify-tools
#   System plumbing:   sudo, procps-ng, glibc-langpack-en, openssl
#   Break-glass:       nano
#
# Everything else the agent uses (claude-code, gh, git, openssh-clients, podman
# CLI client, bubblewrap, socat, host-spawn, rclone) lives INSIDE claudebox —
# see distrobox.ini's additional_packages.
$DNF install \
    podman shadow-utils fuse-overlayfs passt nftables \
    openssh-server mosh tmux tailscale \
    distrobox inotify-tools \
    fail2ban-server rsyslog \
    sudo procps-ng glibc-langpack-en openssl nano

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
[containers]
# No systemd/journald runs in this image, yet podman still DEFAULTS container logs
# to the journald driver (its default whenever it detects a usable systemd journal
# dir — present here even though nothing consumes it). journald logs PLUS the
# file events backend below make `podman logs --follow`/attach unsupported — which
# made the FIRST `distrobox enter` (it follows distrobox-init's output) fail with
# "using --follow with the journald --log-driver but without the journald
# --events-backend (file) is not supported". The assemble retry loop recovered, but
# only after a failed attempt + backoff. k8s-file logs make first-enter clean.
log_driver = "k8s-file"

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

# ---- surface the Tailscale interactive login on remote logins until the node
# is on the tailnet. A fresh state volume has no persisted identity, so the
# one-time browser join has to happen somewhere — and this box has no shell
# without either the public :4444 ssh door or the tailnet. Print the live login
# URL on each interactive login until connected. Runs BEFORE the tmux attach
# below (tmux redraws the screen and would hide it); sorts first by filename.
cat > /etc/profile.d/zz-tailscale-login.sh <<'EOF'
# Show the Tailscale login URL on interactive logins while not yet connected.
# Silent once BackendState=Running (identity persists on the fedora-dev-state
# volume, so this only nags until the one-time join is done).
case $- in *i*) ;; *) return ;; esac
[ -t 0 ] || return
command -v tailscale >/dev/null 2>&1 || return
_ts_state=$(tailscale status --json 2>/dev/null | sed -n 's/.*"BackendState": *"\([^"]*\)".*/\1/p')
if [ -n "$_ts_state" ] && [ "$_ts_state" != "Running" ]; then
    _ts_url=$(tailscale status --json 2>/dev/null | sed -n 's/.*"AuthURL": *"\([^"]*\)".*/\1/p')
    printf '\n\033[1;33m  Tailscale is not connected (state: %s).\033[0m\n' "$_ts_state"
    if [ -n "$_ts_url" ]; then
        printf '     Open this in a browser to join the tailnet (one-time):\n       \033[4m%s\033[0m\n' "$_ts_url"
    else
        printf '     No login URL yet - run:  tailscale up --ssh --hostname=fedora-dev\n'
    fi
    printf '     Tailnet SSH works once you approve it; this notice then disappears.\n\n'
    read -rt 60 -p '     Press Enter to continue to your shell... ' _ts_ack || true
fi
unset _ts_state _ts_url _ts_ack 2>/dev/null || true
EOF

# ---- every interactive remote login lands in the persistent tmux workspace ----
# Each login gets its OWN session inside the shared "main" group: the windows
# (the work) are shared across every client, but each client's geometry and
# redraw state stay INDEPENDENT. That kills the multi-client geometry race —
# under one shared session (window-size=latest) a newly-attaching client of a
# different size forces the shared window to its geometry and paints every other
# client onto a foreign row/column grid, which is the garble seen on Prompt 3 /
# WebSSH and the initial garble on native terminals. Session groups give shared
# windows + per-session size (tmux(1): "Sessions in the same group share the
# same set of windows ... the current and previous window ... remain
# independent"). The per-connection "c<pid>" session self-destroys on disconnect
# (destroy-unattached); the work persists in the detached "main" base session.
cat > /etc/profile.d/zz-tmux-attach.sh <<'EOF'
# ssh + mosh logins each get their own session in the shared "main" group.
case $- in *i*) ;; *) return ;; esac
if [ -z "${TMUX:-}" ] && command -v tmux >/dev/null && { [ -n "${SSH_TTY:-}" ] || [ -t 0 ]; }; then
    tmux has-session -t main 2>/dev/null || tmux new-session -d -s main 2>/dev/null || true
    exec tmux new-session -t main -s "c$$" \; set-option destroy-unattached on
fi
EOF

# ---- tmux server config: multi-device geometry policy + clean co-view ----
# THE CONSTRAINT (verified against tmux 3.6 source + a live multi-client harness):
# a tmux window has exactly ONE size, shared by every client viewing it. You
# cannot render one window at two sizes at once, so differently-sized devices
# co-viewing the SAME tab cannot each see it full-size — that limit is unfixable
# in tmux (one program = one pty = one cell grid). What IS controllable is which
# single size wins and how the size-mismatched client degrades:
#   * A client SMALLER than the window: tmux clips it to a clean viewport that
#     pans to follow the cursor (partial, never garbled).
#   * A client LARGER than the window: tmux paints the content top-left and fills
#     the surplus with `fill-character` (NOT stale garbage — it is actively
#     redrawn every frame; the compiled default is the `·` middle-dot, which is
#     the "screen full of dots / completely garbled" look the operator reported).
# CHOICES:
#   window-size=latest  (DEFAULT) -> the session follows the client that most
#     recently sent INPUT. Type on the Mac and the whole session is Mac-sized;
#     pick up the iPad and type and it rescales to the iPad. Both stay connected
#     (mosh-friendly); the idle device letterboxes/crops cleanly and reclaims
#     full size the instant you touch it. When the active device disconnects the
#     session falls back to whoever remains. This is the seamless device-handoff.
#   fill-character ' ' -> the idle larger device's surplus is BLANK, not `·`.
#   aggressive-resize on -> windows track only the clients whose current window
#     they are, so devices parked on DIFFERENT tabs each get their own full size.
#   client-attached/-resized -> refresh-client forces a full server-driven
#     repaint on every attach/resize so a client that will not self-redraw
#     (xterm.js / WebSSH / mosh) gets a complete clean frame after each rescale.
# SWITCHABLE: prefix+g cycles latest -> smallest -> largest -> latest.
#   smallest = every device always sees the WHOLE session, sized to the smallest
#              connected client (big screens blank-letterbox) — good for watching
#              on a small device while working on a big one.
#   largest  = the biggest connected screen always wins; smaller devices crop.
cat > /etc/tmux.conf <<'EOF'
set -g default-terminal "tmux-256color"
set -g window-size latest
setw -g aggressive-resize on
setw -g fill-character ' '
set-hook -g client-attached 'refresh-client'
set-hook -g client-resized  'refresh-client'
set -g @coview latest

# prefix+g: cycle the multi-device geometry policy (see comment above install).
bind-key g {
  if-shell -F '#{==:#{@coview},latest}' {
    set -g window-size smallest
    set -g @coview smallest
    display-message 'co-view: SMALLEST - every device sees the whole session; big screens blank-letterbox'
  } {
    if-shell -F '#{==:#{@coview},smallest}' {
      set -g window-size largest
      set -g @coview largest
      display-message 'co-view: LARGEST - biggest connected screen wins; smaller devices show a cropped view'
    } {
      set -g window-size latest
      set -g @coview latest
      display-message 'co-view: LATEST - the device you last typed on wins; whole session rescales to it'
    }
  }
  refresh-client -S
}
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
# We install the LEAF `fail2ban-server` (see Base Packages), NOT the `fail2ban`
# metapackage: the metapackage HARD-pulls fail2ban-firewalld->firewalld +
# fail2ban-sendmail->esmtp (an unused firewall + MTA), and install_weak_deps=False
# does NOT block hard Requires. fail2ban-server is the daemon + the nftables ban action;
# it bans via `nftables[type=multiport]` (the `nft` binary; nftables is a base package). This
# image is nft-only — tailscaled programs its rules via the nftables Netlink API (no binary
# needed) and netavark defaults to nftables on Fedora 41+, so no iptables is installed.
# fail2ban watches /var/log/secure (rsyslog writes there from sshd's AUTHPRIV
# facility), bans IPs that fail too many key-auth attempts via nftables.
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
banaction = nftables[type=multiport]

[sshd]
enabled = true
port = 22
logpath = /var/log/secure
EOF

dnf clean all
rm -rf /var/cache/dnf
# /var/cache/libdnf5 is bind-mounted as the PERSISTENT dnf package cache during
# cache-backed builds (the host live-gate's build-candidate.sh + in-box
# bin/build-throwaway.sh both pass -v $HOME/.cache/fd-dnf:/var/cache/libdnf5). Unlinking
# that mountpoint fails with "Device or resource busy" — the RED that blocked EVERY
# fedora-dev live-gate build — and wiping its contents would destroy the persistent
# cache. So only remove it on a PLAIN build (e.g. the --no-cache CI base build) where it
# is genuine image-layer bloat; skip it when it is a bind-mount (its content never enters
# the image layer anyway). Detected via /proc/self/mounts — no extra deps, verified to
# work under both default and --isolation=chroot builds.
grep -q ' /var/cache/libdnf5 ' /proc/self/mounts || rm -rf /var/cache/libdnf5
