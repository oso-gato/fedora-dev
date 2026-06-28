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

# ── claude-code SELF-UPDATE LOCKOUT + SELF-HEAL — the update contract for this box ──
#
# claude-code is a package-managed dnf RPM at /usr/bin/claude (vendor-(b), Anthropic's
# `latest` channel). It is refreshed ONLY by the box rebuild (`distrobox assemble`
# re-runs `dnf install`), NEVER by claude-code updating itself in place. The RPM's own
# `claude update` already declines ("managed by a package manager"), BUT `claude
# install` / the in-session auto-update cycle installs a NATIVE build into the home
# volume: it drops a launcher at ~/.local/bin/claude which — because ~/.local/bin is
# FIRST on PATH — SHADOWS the RPM for any bare `claude`, and the native build is
# self-managing (its auto-updater runs: "it builds"). Worse, the native build lives on
# the persistent home volume, so it SURVIVES every box rebuild: the rebuild "completes
# the claudebox build" yet the shadowing native build stays the active `claude` and
# keeps trying (and failing) to self-update — the box becomes un-fixable by rebuild.
# Two reinforcing guards close this off (deliberately placed LAST, after the critical
# host bridges above, and written to be NON-FATAL so nothing here can abort assemble):
#
#   (1) LOCKOUT — disable every in-session update path so no native build is ever
#       planted. The UNIVERSAL layer is the policy-tier `env` in managed-settings.json,
#       which EVERY claude process reads from the fixed managed path (login + non-login
#       shells, bare `claude`, `claude -p`, sub-agents, MCP). This /etc/profile.d export
#       is the belt for login shells (the host `bin/claude` wrapper enters via `bash
#       -lc`, sourcing it before claude starts). DISABLE_UPDATES blocks `claude
#       update`/`claude install`/the background cycle; DISABLE_AUTOUPDATER is the
#       canonical background-checker off-switch. Neither touches dnf — the rebuild's
#       `dnf install` still upgrades claude-code normally.
#   (2) SELF-HEAL — strip any native-build shadow already on the home volume (a box
#       poisoned before this fix) so the package-managed /usr/bin/claude always wins.
#       Best-effort + content-signatured: only the UNAMBIGUOUS native artifacts go — a
#       launcher symlink that RESOLVES into the native store (absolute OR relative), the
#       native version store (identified by its `versions/` subdir, so a future RPM that
#       repurposes ~/.local/share/claude isn't wiped), and any resulting dangling
#       launcher symlink. A real (non-symlink) ~/.local/bin/claude is always preserved.
cat > /etc/profile.d/20-claude-no-selfupdate.sh <<'EOF'
# claudebox: claude-code is package-managed (dnf RPM); it is updated ONLY by the box
# rebuild. Block every in-session self-update path so a self-managing native build can
# never be planted at ~/.local/bin/claude to shadow /usr/bin/claude on the home volume.
export DISABLE_UPDATES=1
export DISABLE_AUTOUPDATER=1
EOF
chmod 0644 /etc/profile.d/20-claude-no-selfupdate.sh || true

box_home="$(getent passwd "$host_uid" | cut -d: -f6)" || box_home=""
[ -n "${box_home:-}" ] || box_home="/home/core"
store="${XDG_DATA_HOME:-$box_home/.local/share}/claude"
launcher="$box_home/.local/bin/claude"
healed=0
# (a) launcher symlink whose RESOLVED target lands inside the native store (catches
#     absolute and relative symlinks; readlink -f is empty/non-matching otherwise).
if [ -L "$launcher" ]; then
    res="$(readlink -f "$launcher" 2>/dev/null || true)"
    case "$res" in "$store"/*) rm -f "$launcher" 2>/dev/null && healed=1 || true ;; esac
fi
# (b) the native version store itself (the self-managing build), signed by versions/.
if [ -d "$store/versions" ]; then rm -rf "$store" 2>/dev/null && healed=1 || true; fi
# (c) a now-DANGLING ~/.local/bin/claude symlink (e.g. a relative link into the store
#     we just removed) — safe to drop; a real file is never a dangling symlink.
if [ -L "$launcher" ] && [ ! -e "$launcher" ]; then rm -f "$launcher" 2>/dev/null && healed=1 || true; fi
[ "$healed" = 1 ] && echo "claudebox: self-healed a stale native claude shadow off the home volume" || true
