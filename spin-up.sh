#!/usr/bin/env bash
# spin-up.sh — the interactive "spin-up container" wizard for fedora-dev.
# ============================================================================
# Mirrors the fleet spin-up pattern (see fedora-desktop/spin-up.sh) so the VPS
# claudebox follows ONE consistent flow across the fleet: ASK for the Tailscale
# auth key, then hand off to run.sh. run.sh stays the NON-interactive deploy
# contract (env-driven) — a scripted/host-claudebox deploy can set the same env
# and call run.sh directly; this wizard just gathers the answer interactively.
#
# TAILNET JOIN — ask, with a website-login fallback (Principle 5: the key is read
# at the prompt, exported only to the child run.sh, never written here):
#   * key provided  -> UNATTENDED join (tailscale up --auth-key=…), no browser.
#   * blank          -> the entrypoint falls back to the interactive WEB-LOGIN
#                       join and prints a login.tailscale.com URL to
#                       `podman logs -f fedora-dev` (one-time per state volume).
set -euo pipefail
cd "$(dirname "$0")"
[ -x ./run.sh ] || { echo "spin-up: ./run.sh not found/executable in $(pwd)" >&2; exit 1; }

# --- prompt helper (prompt -> stderr so $() captures only the value) ---
ask() {  # ask "<prompt>" ["<default>"]
  local p="$1" d="${2:-}" v
  read -r -p "$p${d:+ [$d]}: " v </dev/tty
  printf '%s' "${v:-$d}"
}

echo "=== fedora-dev spin-up ===" >&2
# Honor an env-supplied TS_AUTHKEY (scripted deploy); otherwise ASK. Blank = web-login fallback.
TS_AUTHKEY="${TS_AUTHKEY:-$(ask 'Tailscale auth key (tskey-…; blank = interactive web-login join)' '')}"
IMAGE="${IMAGE:-$(ask 'Image ref' 'localhost/fedora-dev:latest')}"

if [ -n "$TS_AUTHKEY" ]; then
  echo "  -> UNATTENDED tailnet join (TS_AUTHKEY supplied)." >&2
else
  echo "  -> No key: after launch, open the login.tailscale.com URL from 'podman logs -f fedora-dev'" >&2
  echo "     (one-time per fedora-dev-state volume; the node then re-joins silently on every restart)." >&2
fi
[ "$(ask 'Spin up fedora-dev now? (y/n)' y)" = y ] || { echo "aborted (nothing launched)" >&2; exit 0; }

export TS_AUTHKEY IMAGE
exec ./run.sh
