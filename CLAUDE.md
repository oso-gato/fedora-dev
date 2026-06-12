# fedora-dev — instructions for Claude Code

Objective: run Claude Code to build container images; ssh/mosh + tmux is how you reach and
keep the session (every interactive login auto-attaches tmux session "main").

BEFORE ANY CHANGE: read README.md. The "Build Principles" table is BINDING —
follow it verbatim, no exceptions without an explicit user waiver recorded in
the Packages table. Every added/removed package must update the Packages table
in the same commit. Validate per principle 9 before declaring success.

Image-specific: no systemd inside — entrypoint+pgrep watchdog pattern. Nested
podman: subuid core:10000:55000, fuse-overlayfs, XDG_RUNTIME_DIR fix. mosh bootstraps over sshd; tmux auto-attach via /etc/profile.d/zz-tmux-attach.sh.
