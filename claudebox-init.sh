#!/usr/bin/env bash
# fedora-dev — claudebox host bridges. Runs as the BOX's OWN root, NOT fedora-dev's.
#
# Invoked from claudebox-assemble.sh, post-assemble, as:
#   podman exec claudebox bash /run/host<repo>/claudebox-init.sh <host-uid>
#
# Why this is a script and not distrobox.ini init_hooks: distrobox-create embeds
# init_hooks as `-- '<hook>'` (single-quoted) and re-evals the whole create command
# ON THE HOST, so any quote in the hook breaks out of that wrapper and the body runs
# as the unprivileged HOST user (Permission denied writing /etc, /usr/local/bin).
# distrobox-assemble has the mirror-image trap for double quotes. Driving the bridges
# from here — over the same proven `podman exec` (container-root) channel that stamps the
# policy — sends only a path + a numeric uid across the boundary, so there's nothing
# left to detonate. Idempotent: re-running just rewrites the file + the wrapper.
set -euo pipefail
host_uid="${1:?usage: claudebox-init.sh <host-uid>}"
case "$host_uid" in (''|*[!0-9]*)
    echo "claudebox-init.sh: host-uid must be numeric, got '$host_uid'" >&2; exit 1 ;;
esac

# podman inside the box drives FEDORA-DEV's rootless engine through its API socket,
# which distrobox bind-mounts at /run/user/<host_uid>/podman/podman.sock. Export it
# for every login shell — this is the entire build/validate bridge.
printf 'export CONTAINER_HOST=unix:///run/user/%s/podman/podman.sock\n' "$host_uid" \
    > /etc/profile.d/10-host-podman.sh
chmod 0644 /etc/profile.d/10-host-podman.sh

# In-box `claudebox-rebuild`: how Claude (or anyone in the box) asks fedora-dev to
# destroy + recreate this box. The in-box agent has no host systemd access — its
# ONLY channel is a flag file in the shared HOME, which fedora-dev's inotify watcher
# sees across the bind mount. Writing the flag ends THIS session shortly (fedora-dev
# tears the box down) and rebuilds with fresh image + latest Claude Code.
cat > /usr/local/bin/claudebox-rebuild <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/.local/state/claudebox"
: > "$HOME/.local/state/claudebox/rebuild.request"
echo "⟳ claudebox rebuild requested. This session will end shortly and the box will"
echo "  rebuild in the background (~2-5 min: fresh image + latest Claude Code from"
echo "  the latest channel). Reconnect with: claude"
EOF
chmod 0755 /usr/local/bin/claudebox-rebuild

# NOTE: deliberately NO systemctl/journalctl/loginctl/flatpak host-exec shims. They
# route through host-spawn, which calls org.freedesktop.Flatpak.Development.HostCommand
# on the session bus — a method only flatpak-session-helper provides, and its unit is
# PartOf=graphical-session.target, which never starts on a headless, linger-only
# fedora-dev. By design the agent drives fedora-dev's container engine via
# CONTAINER_HOST (above), not host systemd, and real fedora-dev/host changes go
# through propose-and-commit. CONTAINER_HOST is the one bridge and it is socket-based.

echo "claudebox bridge: CONTAINER_HOST -> fedora-dev rootless podman socket (uid ${host_uid})."
