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
[ "${COLLECT_ONLY:-0}" = 1 ] || [ -x ./run.sh ] || { echo "spin-up: ./run.sh not found/executable in $(pwd)" >&2; exit 1; }

# --- prompt helper (prompt -> stderr so $() captures only the value) ---
ask() {  # ask "<prompt>" ["<default>"]
  local p="$1" d="${2:-}" v
  read -r -p "$p${d:+ [$d]}: " v </dev/tty
  printf '%s' "${v:-$d}"
}

echo "=== fedora-dev spin-up ===" >&2
# Honor an env-supplied TS_AUTHKEY (scripted deploy); otherwise ASK. Blank = web-login fallback.
TS_AUTHKEY="${TS_AUTHKEY:-$(ask 'Tailscale auth key (tskey-…; blank = interactive web-login join)' '')}"
IMAGE="${IMAGE:-$(ask 'Image ref (host deploy = ghcr.io; localhost/ = in-box self-validation only)' 'ghcr.io/oso-gato/fedora-dev:latest')}"

# --- optional STANDING GitHub App credential (paste -> podman secret; never a file) ---
# Same model as TS_AUTHKEY: the key is pasted at the prompt and streams straight into
# podman's secret store. The container mints a <=1h installation token from it
# (bin/gh-app-auth.sh) so the in-box dev loop never stops for auth. Honors an env-supplied
# GH_APP_ID (scripted / collect-mode) and skips the prompt then.
. ./bin/gh-app-provision.sh
GH_APP_SECRET="${GH_APP_SECRET:-}"
if [ -z "${GH_APP_ID:-}" ] && [ "$(ask 'Provision a standing GitHub App credential now (paste the key)? — DEFAULT y: the autonomous loop needs a standing identity; "n" = fall back to your existing/later gh auth login (y/n)' y)" = y ]; then
  prompt_github_app gh_app_key || { echo "spin-up: GitHub App provisioning failed" >&2; exit 1; }
  GH_APP_SECRET=gh_app_key
fi

# COLLECT-ONLY: a host orchestrator (day0.sh) drives this wizard to gather fedora-dev's OWN
# answers + create its podman secret (as the invoking rootless user) WITHOUT launching — so
# day0 never duplicates fedora-dev's questions. Emit the resolved env as `export` lines for
# the caller to capture (eval), then stop.
if [ "${COLLECT_ONLY:-0}" = 1 ]; then
  printf 'export TS_AUTHKEY=%q IMAGE=%q GH_APP_ID=%q GH_APP_INSTALLATION_ID=%q GH_APP_SECRET=%q\n' \
    "${TS_AUTHKEY:-}" "$IMAGE" "${GH_APP_ID:-}" "${GH_APP_INSTALLATION_ID:-}" "${GH_APP_SECRET:-}"
  echo "spin-up: collect-only — answers gathered, secret '${GH_APP_SECRET:-<none>}' ready; NOT launching." >&2
  exit 0
fi

if [ -n "$TS_AUTHKEY" ]; then
  echo "  -> UNATTENDED tailnet join (TS_AUTHKEY supplied)." >&2
else
  echo "  -> No key: after launch, open the login.tailscale.com URL from 'podman logs -f fedora-dev'" >&2
  echo "     (one-time per fedora-dev-state volume; the node then re-joins silently on every restart)." >&2
fi
[ "$(ask 'Spin up fedora-dev now? (y/n)' y)" = y ] || { echo "aborted (nothing launched)" >&2; exit 0; }

export TS_AUTHKEY IMAGE GH_APP_ID GH_APP_INSTALLATION_ID GH_APP_SECRET
exec ./run.sh
