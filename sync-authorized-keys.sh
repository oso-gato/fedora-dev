#!/usr/bin/env bash
# Authorize ONLY the operator's allowlisted SSH public keys for the RUNNING user.
#
# fedora-dev's public door is key-only ssh on host :4444 -> container :22. This
# script is the GATE on that door: it pulls the operator's published keys from
# github.com/<user>.keys and authorizes ONLY the ones whose SHA256 fingerprint
# matches the in-image ALLOWLIST below, tagging each with
# environment="LOGIN_KEY=<name>" so a login is attributable to the device/key.
# The fingerprint allowlist IS the access policy: ANY OTHER key on the GitHub
# account is ignored. This mirrors the host's sync-authorized-keys.sh — the
# fleet posture is identical on both public doors. GitHub supplies the key
# material (no keys in this repo, BUILD PRINCIPLE 5); this script is the filter.
#
# Invoked by entrypoint.sh at every container start as the target user
# (`runuser -u core -- bash /usr/local/bin/sync-authorized-keys.sh`). The home
# volume persists ~/.ssh/authorized_keys across rebuilds + container recreations.
#
# DEFENSIVE — never locks the operator out: a failed/empty fetch or zero
# allowlist matches leaves the existing (home-volume-cached) authorized_keys
# UNTOUCHED, so a brief GitHub outage is survivable; keyless Tailscale SSH
# remains the recovery path regardless.
set -euo pipefail

GH_USER="${GH_KEYS_USER:-oso-gato}"
SSH_DIR="$HOME/.ssh"
AK="$SSH_DIR/authorized_keys"
NEW="$SSH_DIR/.authorized_keys.new"

# ALLOWLIST: a SHORT, uniquely-identifying slice of each key's SHA256 fingerprint
# -> LOGIN_KEY label. Fingerprints derive from the PUBLIC keys (not secret); we
# store only a fragment — enough to match, minimal to expose. Each fragment is a
# prefix of the base64 fingerprint and matches the first characters GitHub shows
# in Settings -> SSH keys. Enrol a device: add its fragment + name here and the
# next container start re-syncs. Any key whose fingerprint doesn't match a
# fragment is ignored. KEEP IN LOCKSTEP with the host's sync-authorized-keys.sh.
label_for() {
    case "${1#SHA256:}" in
        lzwcN0O7*) printf 'oSo' ;;
        ozn1vY4/*) printf 'Alchemist' ;;
        Kc4nBP37*) printf 'Fatima' ;;
        *) return 1 ;;                                  # not on the allowlist
    esac
}

install -d -m 700 "$SSH_DIR"
raw="$(mktemp)"; trap 'rm -f "$raw" "$NEW"' EXIT

if ! curl -fsSL --retry 3 --max-time 15 "https://github.com/${GH_USER}.keys" -o "$raw"; then
    echo "[ssh-keys] WARN: fetch of github.com/${GH_USER}.keys failed — authorized_keys left unchanged" >&2
    exit 0
fi

: > "$NEW"; chmod 600 "$NEW"
n=0
while IFS= read -r key; do
    [ -n "$key" ] || continue
    fp="$(printf '%s\n' "$key" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}')" || fp=""
    [ -n "$fp" ] || continue                            # skip non-key lines
    slice="${fp#SHA256:}"; slice="SHA256:${slice:0:8}..."   # log only a small portion
    if name="$(label_for "$fp")"; then
        printf 'environment="LOGIN_KEY=%s" %s\n' "$name" "$key" >> "$NEW"
        echo "[ssh-keys]   + $name ($slice)"
        n=$((n + 1))
    else
        echo "[ssh-keys]   - $slice is not on the allowlist — ignored" >&2
    fi
done < "$raw"

if [ "$n" -lt 1 ]; then
    echo "[ssh-keys] WARN: no allowlisted keys at github.com/${GH_USER}.keys — authorized_keys left unchanged" >&2
    exit 0
fi

mv -f "$NEW" "$AK"           # rename WITHIN ~/.ssh (preserves dir perms/labels)
# Best-effort SELinux relabel where restorecon exists (no-op in this
# label-disabled container; kept for fleet parity with the host).
command -v restorecon >/dev/null 2>&1 && restorecon -F "$AK" 2>/dev/null || true
echo "[ssh-keys] authorized $n allowlisted key(s) from github.com/${GH_USER}.keys, tagged via LOGIN_KEY"
