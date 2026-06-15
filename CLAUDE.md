# fedora-dev — instructions for Claude Code (repo-editing guide)

BEFORE ANY CHANGE: read README.md. The **Build Principles**, **Base Packages**,
and **Box Packages** tables are BINDING — follow verbatim, no exceptions without
an explicit user waiver recorded in the relevant Packages table. Every added or
removed package must update the matching table row in the same commit.

This repo has TWO layers, each with its own cadence and source of truth:

- **fedora-dev base image** — Containerfile + install.sh + entrypoint.sh + bin/
  wrappers + the baked seed at /usr/local/share/fedora-dev/. Rebuilt **monthly**
  by CI on the 15th. Changes here flow: edit → PR → merge → CI build → GHCR →
  host-side refresh recreates the running container.

- **claudebox (in-container)** — `distrobox.ini` + `claudebox-init.sh` +
  `box-rebuild.sh` + `claudebox-daily.sh` + `claudebox-assemble.sh` +
  `policy/CLAUDE.md` + `policy/managed-settings.json`. The runtime source is
  the LIVE git clone at `/home/core/.local/share/fedora-dev/`, NOT the baked
  seed. Rebuilt **daily** in-container plus on-demand. Changes here flow:
  edit (in the live clone) → PR → merge → next rebuild applies.

The PROPOSE-AND-COMMIT discipline is binding for the in-box agent: durable
changes only via PR, never via ad-hoc installs in a running box (those vanish
on rebuild by design).

Image-specific notes: no systemd inside — the entrypoint+pgrep+kill-0 watchdog
supervises sshd, tailscaled, the rootless podman API socket, the inotify
rebuild-flag watcher, and the daily-tick loop. mosh bootstraps over sshd; tmux
auto-attach via `/etc/profile.d/zz-tmux-attach.sh`. Subuid `core:10000:55000`,
fuse-overlayfs, XDG_RUNTIME_DIR fix.

Validate per principle 9 before declaring success.
