#!/bin/bash
# fedora-dev PID 1 (root). Starts:
#   * sshd (key-only; keys = all of github.com/oso-gato.keys; mosh rides on it; tailscale --ssh is the keyless tailnet door)
#   * tailscaled (+ tailscale up, unattended via TS_AUTHKEY or interactive banner)
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
# Key-only sshd auth. Fetch ALL keys published on the GitHub account each boot,
# cache on the home volume. The GitHub account is the single trust root — every
# key on github.com/oso-gato.keys is the operator's own and authorized as-is (no
# in-image allowlist; key trust is managed centrally on the account).
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

# ---- sshd: reachable on container :22 (host publishes public :4444 via Quadlet) ----
# Key-only. No fail2ban / rsyslog: there is no password to brute-force on this
# door, so a jail bought nothing.
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
    # Tailnet node name = the container hostname (run.sh --hostname / Quadlet HostName —
    # the BOX_HOSTNAME pairing choice: nox = VPS/erebus, nyx = homelab/strix).
    # uname -n, NOT $(hostname): the image ships no `hostname` binary (verified live on nox —
    # the substitution was silently EMPTY and the join only worked because tailscale falls
    # back to deriving the name from the OS hostname). uname is coreutils, always present.
    until tailscale up --ssh --auth-key="${TS_AUTHKEY}" --hostname="$(uname -n)"; do
        echo "[tailscale] up failed, retrying in 5s"; sleep 5
    done
    echo "==== TAILNET JOINED ===="
else
    (
        until tailscale up --ssh --hostname="$(uname -n)" 2>&1 | sed 's/^/[tailscale] /'; do
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

# ---- provision a STANDING GitHub credential (non-interactive, auto-rotating) ---
# Lets the autonomous dev loop (git push / gh pr create / label) run without ever
# stopping for auth. Preferred: a GitHub App installation token (gh-app-auth.sh mints
# it fresh from the App private key — <=1h, repo-scoped, ON DEMAND for git so nothing
# is persisted; the box's gh CLI gets a hosts.yml refreshed on a tick below). Fallback:
# a static $GH_TOKEN. The key/token enters ONLY at runtime (Build Principle 5 — never a
# layer). No credential -> the box still boots unauthenticated (operator can auth by
# hand); propose-and-commit just needs one. Runs as core (its ~/.config holds the auth).
if [ -n "${GH_APP_ID:-}" ] && { [ -n "${GH_APP_PRIVATE_KEY:-}" ] || [ -r "${GH_APP_PRIVATE_KEY_FILE:-/run/secrets/gh_app_key}" ]; }; then
    if runuser -u core -- env HOME=/home/core \
            GH_APP_ID="${GH_APP_ID}" \
            GH_APP_INSTALLATION_ID="${GH_APP_INSTALLATION_ID:-}" \
            GH_APP_PRIVATE_KEY="${GH_APP_PRIVATE_KEY:-}" \
            GH_APP_PRIVATE_KEY_FILE="${GH_APP_PRIVATE_KEY_FILE:-/run/secrets/gh_app_key}" \
            bash /usr/local/bin/gh-app-auth.sh install; then
        echo "[gh-auth] standing GitHub App credential provisioned"
    else
        echo "[gh-auth] App credential provisioning FAILED — continuing unauthenticated"
    fi
elif [ -n "${GH_TOKEN:-}" ]; then
    runuser -u core -- env HOME=/home/core GH_TOKEN="${GH_TOKEN}" bash -c '
        mkdir -p ~/.config/gh
        [ -f ~/.config/gh/config.yml ] || printf "version: 1\ngit_protocol: https\n" > ~/.config/gh/config.yml
        printf "github.com:\n    users:\n        x-access-token:\n            oauth_token: %s\n    git_protocol: https\n    oauth_token: %s\n    user: x-access-token\n" "$GH_TOKEN" "$GH_TOKEN" > ~/.config/gh/hosts.yml
        chmod 600 ~/.config/gh/hosts.yml
        git config --global credential.helper store
        printf "https://x-access-token:%s@github.com\n" "$GH_TOKEN" > ~/.git-credentials
        chmod 600 ~/.git-credentials' \
        && echo "[gh-auth] provisioned from static GH_TOKEN" \
        || echo "[gh-auth] GH_TOKEN provisioning failed — continuing unauthenticated"
else
    echo "[gh-auth] no standing credential supplied — running unauthenticated (fail-safe). A persisted gh login on the home volume (if any) is used as-is; otherwise run 'gh auth login' once inside the box — it persists across rebuilds and is used automatically. The App path is OPTIONAL."
fi

# ---- FITNESS-REVIEW token ferry (independent reviewer identity; optional) ----
# The independent fitness harness (bin/fitness-review.sh, run IN-BOX) must post its
# verdict AS the fleet-wide fitness App — an identity DISTINCT from this box's dev
# App, or auto-merge.sh rejects the verdict as self-review. The fitness App PRIVATE
# KEY stays at the BASE layer (/run/secrets/gh_app_key_fitness, tmpfs — NOT visible
# in-box, verified empirically); only a <=1h INSTALLATION token is ferried to a
# 0600 home-volume file the box can read. Same minter as the dev App (gh-app-auth.sh
# is env-parameterized; `token` mode is read-only — it never touches the dev
# identity's git/gh wiring). Runs AS ROOT (the secret mount is root-readable); only
# the short-lived token ever lands in core's home. Best-effort: no key/ID -> no
# ferry -> fitness-review.sh refuses fail-closed (no PASS => no auto-merge).
fitness_ferry() {
    [ -n "${GH_APP_FITNESS_ID:-}" ] || return 0
    [ -r "${GH_APP_FITNESS_KEY_FILE:-/run/secrets/gh_app_key_fitness}" ] || return 0
    local tok
    tok="$(GH_APP_ID="${GH_APP_FITNESS_ID}" \
           GH_APP_INSTALLATION_ID="${GH_APP_FITNESS_INSTALLATION_ID:-}" \
           GH_APP_PRIVATE_KEY="" \
           GH_APP_PRIVATE_KEY_FILE="${GH_APP_FITNESS_KEY_FILE:-/run/secrets/gh_app_key_fitness}" \
           bash /usr/local/bin/gh-app-auth.sh token)" \
        || { echo "[fitness-auth] fitness token mint FAILED — ferry skipped (fail-closed: no fitness verdicts)"; return 1; }
    install -d -m 0700 -o core -g core /home/core/.config/fitness
    ( umask 077; printf 'FITNESS_LOGIN=%s\nFITNESS_GH_TOKEN=%s\n' \
        "${FITNESS_LOGIN:-oso-gato-fitness}" "$tok" > /home/core/.config/fitness/env )
    chown core:core /home/core/.config/fitness/env
    echo "[fitness-auth] fitness token ferried to ~core/.config/fitness/env (<=1h; refreshed on the 40-min tick)"
}
fitness_ferry || true

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
    # Self-heal: if GitHub is reachable now (and we may now hold a credential),
    # CONVERT the seed to a real clone instead of parking for a human. This removes
    # the dead-end an offline first boot used to leave (propose-and-commit was blocked
    # until the agent ran CONVERT-TO-GIT.md by hand). A later reachable boot heals it.
    if timeout 20 git ls-remote https://github.com/oso-gato/fedora-dev HEAD >/dev/null 2>&1; then
        echo "[live-spec] seeded-no-git + GitHub reachable -> self-healing to a real clone"
        bak="${live}.heal-bak.$(date +%s)"
        if mv "$live" "$bak" \
           && timeout 120 git clone --depth 1 https://github.com/oso-gato/fedora-dev "$live" 2>/dev/null; then
            ( cd "$live" \
              && git config --local user.email "claudebox@fedora-dev.local" \
              && git config --local user.name  "claudebox" )
            rm -rf "$bak"
            echo "[live-spec] self-heal OK (seed backed up then removed; clone is authoritative)"
        elif [ -e "$bak" ]; then
            # the seed was moved aside (mv ok, clone failed) -> restore it
            rm -rf "$live" 2>/dev/null || true
            mv "$bak" "$live" 2>/dev/null || true
            echo "[live-spec] self-heal failed; restored the seed, staying seeded-no-git"
        else
            # mv itself failed -> $live is still the untouched seed, leave it
            echo "[live-spec] self-heal failed before backup; seed untouched, staying seeded-no-git"
        fi
    else
        echo "[live-spec] seeded-no-git; GitHub still unreachable — staying seeded (self-heals next reachable boot)"
    fi
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

# ---- supervised: GitHub App token refresh (gh CLI hosts.yml) ---------------
# App installation tokens expire in <=1h. The git credential helper mints fresh per
# op (nothing to refresh there), but the box's `gh` CLI reads a static hosts.yml — so
# re-mint it every 40 min. No-op unless an App credential is configured. Best-effort
# (not in the watchdog): a miss only staleness-expires the gh token until next boot;
# git keeps working on demand.
if [ -n "${GH_APP_ID:-}" ] && { [ -n "${GH_APP_PRIVATE_KEY:-}" ] || [ -r "${GH_APP_PRIVATE_KEY_FILE:-/run/secrets/gh_app_key}" ]; }; then
    runuser -u core -- env HOME=/home/core \
        GH_APP_ID="${GH_APP_ID}" \
        GH_APP_INSTALLATION_ID="${GH_APP_INSTALLATION_ID:-}" \
        GH_APP_PRIVATE_KEY="${GH_APP_PRIVATE_KEY:-}" \
        GH_APP_PRIVATE_KEY_FILE="${GH_APP_PRIVATE_KEY_FILE:-/run/secrets/gh_app_key}" \
        bash -c 'while sleep 2400; do bash /usr/local/bin/gh-app-auth.sh install >/dev/null 2>&1 || true; done' &
fi

# ---- supervised: fitness token refresh (same <=1h expiry, same cadence) -----
# Best-effort like the dev tick (not in the watchdog): a miss only staleness-expires
# the ferried fitness token until the next tick/boot; fitness-review.sh fails closed
# on a dead token (no PASS => no auto-merge). The subshell inherits fitness_ferry().
if [ -n "${GH_APP_FITNESS_ID:-}" ] && [ -r "${GH_APP_FITNESS_KEY_FILE:-/run/secrets/gh_app_key_fitness}" ]; then
    ( while sleep 2400; do fitness_ferry >/dev/null 2>&1 || true; done ) &
fi

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
    kill -0 "$podman_sock_pid"  2>/dev/null     || { echo "podman socket died";    exit 1; }
    kill -0 "$watcher_pid"      2>/dev/null     || { echo "rebuild watcher died";  exit 1; }
    kill -0 "$tick_pid"         2>/dev/null     || { echo "daily tick died";       exit 1; }
done
