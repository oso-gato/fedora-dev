#!/usr/bin/env bash
# fedora-dev — DAILY claudebox refresh DECISION. NOT the rebuild itself.
#
# Run by entrypoint.sh's daily-tick supervisor (sleep 86400 loop). Keeps the box
# from drifting even if you never ask for a rebuild — WITHOUT ever interrupting
# live work:
#   * No claude session active  -> start the detached rebuild now.
#   * A claude session IS active -> drop a rebuild.pending marker. The `claude`
#                                   wrapper performs the rebuild the moment you
#                                   next exit (so a refresh that came due while
#                                   you worked happens on quit).
# Detection is via the SHARED session lock the `claude` wrapper holds per session:
# if we can take EXCLUSIVE non-blocking, no session holds the shared lock -> idle.
set -uo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
state="$HOME/.local/state/claudebox"
mkdir -p "$state"

if flock -n -x "$state/session.lock" -c true 2>/dev/null; then
    echo "claudebox daily refresh: idle -> rebuilding now."
    setsid nohup bash /home/core/.local/share/fedora-dev/box-rebuild.sh \
        > "$state/daily-rebuild.log" 2>&1 < /dev/null &
    exit 0
fi
echo "claudebox daily refresh: session active -> deferring; rebuilds when you exit."
: > "$state/rebuild.pending"
