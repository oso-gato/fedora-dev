#!/bin/bash
# fedora-dev PID 1 (root). Starts:
#   * rsyslog (collects sshd auth events to /var/log/secure for fail2ban)
#   * sshd (key-only; mosh rides on it; tailscale --ssh is the keyless tailnet door)
#   * tailscaled (+ tailscale up, unattended via TS_AUTHKEY or interactive banner)
#   * fail2ban (watches /var/log/secure, bans brute-force IPs on public :4444)
#   * core's rootless podman API socket (CONTAINER_HOST target for the box)
#   * inotify watcher for in-box claudebox-rebuild flag
#   * daily-tick loop -> claudebox-daily.sh (rebuild if idle, else defer)
#   * eager first-boot claudebox assemble (background)
# Supervises all of them in a pgrep + kill-0 watchdog loop; outer --restart=always
# heals on any death.
set -eu

# Graceful shutdown: when the host's container-refresh.sh `podman stop`s us, we
# get SIGTERM. Propagate it to our process group so sshd closes connections
# cleanly, tailscaled deregisters cleanly, supervised children exit cleanly,
# rather than getting SIGKILLed after the 10-second podman-stop timeout.
trap 'kill -TERM 0 2>/dev/null; exit 0' TERM INT

# CORE_PASSWORD is no longer required (sshd is key-only as of v1.1.9; ssh
# keys synced from github.com/oso-gato.keys below). Ignore the env var if
# set, for backward compatibility with pre-v1.1.9 run.sh callers.
unset CORE_PASSWORD 2>/dev/null || true

# ---- home volume may be empty on first run ----------------------------------
if [ ! -e /home/core/.bashrc ]; then
    cp -rT /etc/skel /home/core
fi
# Recursive chown — non-recursive leaves the cp'd dotfiles root-owned, which
# breaks any non-sudo edit by core inside or outside the box.
chown -R core:core /home/core

# ---- rootless podman needs a runtime dir (no systemd/PAM session manager) ---
install -d -m 0700 -o core -g core /run/user/1000

# ---- defensive: restore newuidmap/newgidmap file caps if overlay stripped them
# Build-time setcap (install.sh) doesn't always survive layer commits in every
# podman storage configuration; the security.capability xattr can be lost. We
# verify + restore at boot. Idempotent: no-op when caps are already present.
for bin in /usr/bin/newuidmap /usr/bin/newgidmap; do
    [ -x "$bin" ] || continue
    if ! getcap "$bin" | grep -q "cap_set"; then
        case "$bin" in
            */newuidmap) setcap cap_setuid+ep "$bin" ;;
            */newgidmap) setcap cap_setgid+ep "$bin" ;;
        esac
        echo "[caps] restored on $bin"
    fi
done

# ---- persistent ssh host keys on the root-owned state volume ----------------
install -d -m 0700 /var/lib/tailscale/hostkeys
if [ ! -f /var/lib/tailscale/hostkeys/ssh_host_ed25519_key ]; then
    ssh-keygen -t ed25519 -N "" -f /var/lib/tailscale/hostkeys/ssh_host_ed25519_key
fi
mkdir -p /run/sshd

# ---- sync core's ssh authorized_keys from github.com/oso-gato.keys ---------
# Key-only sshd auth. Fetch from GitHub each boot, cache on the home volume.
# If GitHub is briefly unreachable AND a cached file exists, keep the cache.
# If GitHub is unreachable AND no cache: public ssh key-auth is closed until
# next reachable sync — Tailscale SSH (keyless) remains the operator's path in.
runuser -u core -- bash -c '
    set -u
    mkdir -p ~/.ssh
    chmod 0700 ~/.ssh
    tmp=$(mktemp)
    if curl -fsSL --max-time 10 https://github.com/oso-gato.keys -o "$tmp" && [ -s "$tmp" ]; then
        mv "$tmp" ~/.ssh/authorized_keys
        chmod 0600 ~/.ssh/authorized_keys
        echo "[ssh-keys] synced from github.com/oso-gato.keys ($(wc -l < ~/.ssh/authorized_keys) keys)"
    else
        rm -f "$tmp"
        if [ -s ~/.ssh/authorized_keys ]; then
            echo "[ssh-keys] GitHub unreachable; keeping cached ~/.ssh/authorized_keys"
        else
            echo "[ssh-keys] WARNING: GitHub unreachable AND no cached keys — public ssh closed; use Tailscale SSH to recover"
        fi
    fi
'

# ---- rsyslog: collect sshd auth events to /var/log/secure (fail2ban reads from there)
/usr/sbin/rsyslogd -n &
rsyslog_pid=$!

# ---- sshd: reachable on container :22 (host publishes public :4444 via Quadlet) ----
/usr/sbin/sshd

# ---- fail2ban: brute-force protection on the public :4444 path ----
# Starts after sshd so the log target exists. fail2ban tolerates a missing
# log file at startup (begins watching once it appears).
fail2ban-server -xf start &
fail2ban_pid=$!

# ---- tailscaled --------------------------------------------------------------
/usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock &
for _ in $(seq 1 30); do
    tailscale status >/dev/null 2>&1 && break
    [ -S /var/run/tailscale/tailscaled.sock ] && break
    sleep 1
done

if [ -n "${TS_AUTHKEY:-}" ]; then
    until tailscale up --ssh --auth-key="${TS_AUTHKEY}" --hostname=fedora-dev; do
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

# ============================================================================
# Box supervisor: live-spec bootstrap + long-running processes + watchdog
# ============================================================================

# State dir for box lifecycle (session lock, rebuild flag, pending marker, logs)
install -d -m 0755 -o core -g core /home/core/.local/state/claudebox
# `install -d -o core` only chowns the LEAF; the intermediates /home/core/.local and
# /home/core/.local/state are left ROOT-owned. The live-spec seed below runs as `core`
# and would then fail to create /home/core/.local/share on a FRESH home
# ("Permission denied" -> `set -u` heredoc errors out / PID 1 exits at ~75s of first
# boot, before sshd/socket are healthy). Own the whole .local tree to core so the
# as-core bootstrap can write into it. (Proven: a fresh disposable boot died exactly
# here until this chown was applied.)
chown -R core:core /home/core/.local

# ---- live-spec bootstrap (first boot only) ---------------------------------
# Clone the fedora-dev repo to /home/core/.local/share/fedora-dev/ — this is the
# LIVE source of truth for distrobox.ini and the box scripts. It persists on the
# home volume across fedora-dev container recreations (which is how mid-cycle
# distrobox.ini edits SURVIVE the monthly base-image refresh).
#
# Fallback: if GitHub is genuinely unreachable after 5 retries, copy files from
# the baked seed WITHOUT git-init. A seeded-no-git state lets the box rebuild,
# the daily tick, and the inotify watcher all keep working (they read files,
# not git). The agent's propose-and-commit cycle is blocked until they convert
# to a real clone — see CONVERT-TO-GIT.md dropped alongside the files.
# (A previous design did `git init && commit` here to fake a clone, but that
# leaves an unrelated-history repo that can't `git pull origin main` cleanly.)
runuser -u core -- bash <<'BOOTSTRAP'
set -u
live=/home/core/.local/share/fedora-dev
seed=/usr/local/share/fedora-dev
mkdir -p "$(dirname "$live")"

if [ -d "$live/.git" ]; then
    echo "[live-spec] git clone already present at $live"
elif [ -f "$live/.seeded-no-git" ]; then
    echo "[live-spec] seeded-no-git state present; agent must convert to clone (see CONVERT-TO-GIT.md)"
else
    cloned=0
    for attempt in 1 2 3 4 5; do
        if git clone --depth 1 https://github.com/oso-gato/fedora-dev "$live" 2>/dev/null; then
            cloned=1; break
        fi
        echo "[live-spec] clone attempt $attempt failed; retrying in $((attempt*5))s"
        sleep $((attempt*5))
    done
    if [ "$cloned" = 1 ]; then
        # Generic per-repo git identity so the agent's first `git commit` doesn't
        # fail with "Author identity unknown". Generic, non-personal — agent can
        # override with their own per-PR. Stays out of layers (principle 5).
        ( cd "$live" \
          && git config --local user.email "claudebox@fedora-dev.local" \
          && git config --local user.name  "claudebox" )
        echo "[live-spec] cloned from GitHub + git identity initialized"
    else
        echo "[live-spec] GitHub unreachable after 5 attempts — seeding files only (no git)"
        mkdir -p "$live"
        cp -rT "$seed" "$live"
        date -Iseconds > "$live/.seeded-no-git"
        cat > "$live/CONVERT-TO-GIT.md" <<'NOTE'
# This live spec was seeded from the baked image because GitHub was
# unreachable at first boot.

The box-rebuild, daily-tick, and inotify-watcher all work in this state —
they read files, not git. What's BLOCKED until you convert: the
propose-and-commit cycle (`git commit` + `gh pr create`).

To convert to a real git clone, ONCE the box has internet to GitHub:

    cd ~/.local/share/fedora-dev
    rm -f .seeded-no-git CONVERT-TO-GIT.md
    git init
    git remote add origin https://github.com/oso-gato/fedora-dev
    git fetch --depth 1 origin main
    git reset --hard origin/main
    git config --local user.email "claudebox@fedora-dev.local"
    git config --local user.name  "claudebox"

After this the propose-and-commit flow works normally.
NOTE
    fi
fi
BOOTSTRAP

# ---- supervised: rootless podman API socket (CONTAINER_HOST target) --------
# The box's `podman` CLI talks to this socket to drive fedora-dev's engine.
# Replaces bootstrap's `systemctl --user enable podman.socket` (no systemd here).
# The socket's parent dir must exist first: `podman system service` binds an
# explicit unix path and does NOT mkdir its parent, so without this the bind
# fails ("no such file or directory"), the socket dies, and the watchdog below
# exits PID 1 — crash-looping the container under Restart=always.
install -d -m 0700 -o core -g core /run/user/1000/podman
runuser -u core -- podman system service --time=0 \
    unix:///run/user/1000/podman/podman.sock &
podman_sock_pid=$!

# ---- supervised: inotify watcher for in-box rebuild flag -------------------
# When Claude inside the box runs `claudebox-rebuild`, it writes a flag to
# ~/.local/state/claudebox/rebuild.request. inotifywait MONITOR mode keeps the
# inotify fd open across events, eliminating the missed-events-between-iterations
# race a `while inotifywait` loop has. box-rebuild.sh self-serializes via flock,
# so a spurious double-fire is safe.
runuser -u core -- bash -c '
mkdir -p /home/core/.local/state/claudebox
inotifywait -m -q -e create /home/core/.local/state/claudebox/ --format "%f" 2>/dev/null \
    | while IFS= read -r fname; do
        [ "$fname" = "rebuild.request" ] || continue
        rm -f /home/core/.local/state/claudebox/rebuild.request
        setsid nohup bash /home/core/.local/share/fedora-dev/box-rebuild.sh \
            > /home/core/.local/state/claudebox/rebuild.log 2>&1 < /dev/null &
    done
' &
watcher_pid=$!

# ---- supervised: daily-tick loop -------------------------------------------
# Wall-clock scheduling at ~04:00 local time — survives container restarts
# (a naive `sleep 86400` would re-base the schedule on every fedora-dev restart,
# so frequent recreations could mean the daily refresh NEVER fires within a day).
# claudebox-daily.sh probes the session lock: idle -> rebuild now,
# active -> drop rebuild.pending (the `claude` wrapper fires it on exit).
runuser -u core -- bash -c '
while true; do
    now=$(date +%s)
    today4=$(date -d "today 04:00" +%s)
    if [ "$today4" -gt "$now" ]; then
        next=$today4
    else
        next=$(date -d "tomorrow 04:00" +%s)
    fi
    sleep $((next - now))
    setsid nohup bash /home/core/.local/share/fedora-dev/claudebox-daily.sh \
        > /home/core/.local/state/claudebox/daily.log 2>&1 < /dev/null &
done
' &
tick_pid=$!

# ---- eager first-boot claudebox assemble (one-shot, background) -----------
# Doesn't block sshd — you can connect immediately; `claude` will tail this if
# you try to enter the box before assemble completes.
runuser -u core -- bash -c '
    if [ ! -e /home/core/.local/state/claudebox/.assembled ]; then
        echo "[first-boot] assembling claudebox in the background..."
        bash /home/core/.local/share/fedora-dev/claudebox-assemble.sh \
            > /home/core/.local/state/claudebox/first-assemble.log 2>&1 < /dev/null \
            && echo "[first-boot] claudebox ready" \
            || echo "[first-boot] assemble FAILED — see ~/.local/state/claudebox/first-assemble.log"
    fi
' &

echo "fedora-dev up: ssh :22 (tailnet) + ssh :4444 (public, key-only) + mosh UDP 61001-62000, $(podman --version)"

# ---- supervision: exit on service death; outer --restart=always heals -------
while sleep 30; do
    pgrep -x tailscaled         >/dev/null 2>&1 || { echo "tailscaled died";       exit 1; }
    pgrep -x sshd               >/dev/null 2>&1 || { echo "sshd died";             exit 1; }
    kill -0 "$rsyslog_pid"      2>/dev/null     || { echo "rsyslogd died";         exit 1; }
    kill -0 "$fail2ban_pid"     2>/dev/null     || { echo "fail2ban-server died";  exit 1; }
    kill -0 "$podman_sock_pid"  2>/dev/null     || { echo "podman socket died";    exit 1; }
    kill -0 "$watcher_pid"      2>/dev/null     || { echo "rebuild watcher died";  exit 1; }
    kill -0 "$tick_pid"         2>/dev/null     || { echo "daily tick died";       exit 1; }
done

# hands-off live-gate demo (no-op) — safe to close.
