#!/usr/bin/env bash
# spin-up.sh — the interactive "spin-up container" wizard for fedora-dev.
# ============================================================================
# Mirrors the fleet spin-up pattern (see fedora-bootstrap/spin-up.sh) so the VPS
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

# --- prompt helper (prompt -> the TERMINAL so $() captures only the value) ---
# TERMINAL: /dev/tty by default; SPINUP_TTY overrides it. day0's root layer su's into the
# operating user with stdin=/dev/null, and util-linux `su` then DETACHES the controlling
# terminal (TIOCSTI hardening) — /dev/tty is ENXIO in that layer (verified live 2026-07-07:
# every day0 question silently ate its default, then FATAL'd once the flow went fail-loud).
# The root layer therefore ferries the real tty DEVICE down as SPINUP_TTY (ACL-granted for
# the setup duration); reading the device directly needs no controlling terminal.
SPINUP_TTY="${SPINUP_TTY:-/dev/tty}"
ask() {  # ask "<prompt>" ["<default>"]  — no terminal => LOUDLY take the default
  local p="$1" d="${2:-}" v=""
  if { : <"$SPINUP_TTY"; } 2>/dev/null; then
    printf '%s%s: ' "$p" "${d:+ [$d]}" >"$SPINUP_TTY"
    IFS= read -r v <"$SPINUP_TTY" || v=""
  else
    echo "spin-up: no terminal ($SPINUP_TTY) — taking default '${d:-<blank>}' for: $p" >&2
  fi
  printf '%s' "${v:-$d}"
}

echo "=== fedora-dev spin-up ===" >&2

# --- box identity: which HOST this dev box pairs with -------------------------------
# Resolved FIRST so every prompt below can NAME the box it provisions (operator ask —
# same treatment as the GitHub App banners).
# One fedora-dev image, two possible homes. The name becomes BOTH the container hostname
# and the tailnet node name (run.sh --hostname + the entrypoint's tailscale --hostname).
# AUTO-SELECTED from the HOST's hostname (day0's host phase 1/7 sets it — hostnamectl,
# cloud-init reversion disabled — before this user-layer wizard ever runs):
#   erebus (VPS)      -> nox
#   strix  (homelab)  -> nyx
# Env-supplied BOX_HOSTNAME (scripted) wins; an UNRECOGNIZED host falls back to the ask.
if [ -z "${BOX_HOSTNAME:-}" ]; then
  _host="$(hostname -s 2>/dev/null || echo unknown)"
  case "$_host" in
    erebus) BOX_HOSTNAME=nox; echo "  -> host '$_host' -> box hostname 'nox' (VPS pairing, auto)" >&2 ;;
    strix)  BOX_HOSTNAME=nyx; echo "  -> host '$_host' -> box hostname 'nyx' (homelab pairing, auto)" >&2 ;;
    *)
      echo "NOTICE: host '$_host' is not a known pairing (erebus->nox, strix->nyx auto-select" >&2
      echo "        elsewhere) — enter this box's hostname (becomes the container hostname AND" >&2
      echo "        the tailnet node name)." >&2
      BOX_HOSTNAME="$(ask 'Hostname (RFC-1123: lowercase a-z 0-9 and hyphen, no leading/trailing hyphen, <=63 chars)' '')"
      case "$BOX_HOSTNAME" in
        ''|-*|*-|*[!a-z0-9-]*) echo "spin-up: FATAL — invalid hostname '$BOX_HOSTNAME'" >&2; exit 1 ;;
      esac
      [ "${#BOX_HOSTNAME}" -le 63 ] || { echo "spin-up: FATAL — hostname '$BOX_HOSTNAME' exceeds 63 characters" >&2; exit 1; }
      echo "  -> box hostname: $BOX_HOSTNAME" >&2 ;;
  esac
fi

# Honor an env-supplied TS_AUTHKEY (scripted deploy); otherwise ASK. Blank = web-login fallback.
echo "── Tailscale key for THE DEV BOX '$BOX_HOSTNAME' (fedora-dev) ───────────────────────" >&2
echo "   Joins the tailnet as node '$BOX_HOSTNAME'. NOT the host's join (that happened in the" >&2
echo "   host phase); a REUSABLE key may be the same one — a one-off key needs a fresh one." >&2
TS_AUTHKEY="${TS_AUTHKEY:-$(ask "Tailscale auth key for '$BOX_HOSTNAME' (tskey-…; blank = interactive web-login join)" '')}"
IMAGE="${IMAGE:-$(ask 'Image ref (host deploy = ghcr.io; localhost/ = in-box self-validation only)' 'ghcr.io/oso-gato/fedora-dev:latest')}"

# --- optional STANDING GitHub App credential (paste -> podman secret; never a file) ---
# Same model as TS_AUTHKEY: the key is pasted at the prompt and streams straight into
# podman's secret store. The container mints a <=1h installation token from it
# (bin/gh-app-auth.sh) so the in-box dev loop never stops for auth. Honors an env-supplied
# GH_APP_ID (scripted / collect-mode) and skips the prompt then.
. ./bin/gh-app-provision.sh
GHA_TTY="$SPINUP_TTY"; GHA_IN="$SPINUP_TTY"   # provision lib prompts on the same terminal
GH_APP_SECRET="${GH_APP_SECRET:-}"
echo "── GitHub App credential for THE DEV BOX '$BOX_HOSTNAME' (fedora-dev) ──────────────" >&2
echo "   This is the box's PR-AUTHORING identity (the 'devbox' App — Contents+Workflows R/W)." >&2
echo "   NOT the host's App: the host (live-gate verdicts) uses its own, DIFFERENT App." >&2
# ALREADY-PROVISIONED GUARD — mirrors the host App's guard (fedora-bootstrap setup-user.sh): if a prior
# run already stored the credential, REUSE it silently rather than re-prompting. Without this a setup.sh
# RE-RUN re-asks for the DEV BOX PEM every time (its own guard has no already-provisioned check), and a
# wrong answer FATALs the whole user layer (set -e) or, declined, strips a credential that is already in
# place. Reuse needs BOTH the podman secret AND the persisted PUBLIC ids; setting GH_APP_ID here makes the
# `-z GH_APP_ID` prompt below skip cleanly and the COLLECT_ONLY emit re-carries the ids to the Quadlet.
GH_APP_DEV_ENV="${GH_APP_DEV_ENV:-$HOME/.config/gh-app-dev.env}"
if [ -z "${GH_APP_ID:-}" ] && command -v podman >/dev/null 2>&1 \
   && podman secret exists gh_app_key 2>/dev/null && [ -r "$GH_APP_DEV_ENV" ]; then
  # shellcheck disable=SC1090
  . "$GH_APP_DEV_ENV"                 # restores GH_APP_ID + GH_APP_INSTALLATION_ID (public integers only)
  GH_APP_SECRET=gh_app_key
  echo "  -> DEV BOX App credential already provisioned (podman secret 'gh_app_key' + $GH_APP_DEV_ENV); reusing — NOT re-pasting." >&2
fi
if [ -z "${GH_APP_ID:-}" ] && [ "$(ask "Provision the DEV BOX ('$BOX_HOSTNAME') App credential now (paste the key)? — DEFAULT y: the autonomous loop needs it; \"n\" = fall back to gh auth login (y/n)" y)" = y ]; then
  # The paste NEEDS a terminal — fail with the remedy, not a cryptic read error.
  { : <"$SPINUP_TTY"; } 2>/dev/null || { echo "spin-up: FATAL — App provisioning needs a terminal ($SPINUP_TTY unreadable). Run interactively, or supply GH_APP_ID/GH_APP_INSTALLATION_ID/GH_APP_SECRET via env (scripted path)." >&2; exit 1; }
  prompt_github_app gh_app_key || { echo "spin-up: GitHub App provisioning failed" >&2; exit 1; }
  GH_APP_SECRET=gh_app_key
  # Persist the PUBLIC ids (0600) so a later setup.sh re-run reuses the secret without re-pasting (guard
  # above). Only App ID + Installation ID (public integers) are written — never the PEM (that stays in
  # podman's secret store). Best-effort: a write failure only means the next run re-prompts.
  mkdir -p "$(dirname "$GH_APP_DEV_ENV")" 2>/dev/null || true
  ( umask 077; printf 'GH_APP_ID=%s\nGH_APP_INSTALLATION_ID=%s\n' "${GH_APP_ID:-}" "${GH_APP_INSTALLATION_ID:-}" >"$GH_APP_DEV_ENV" ) 2>/dev/null \
    || echo "spin-up: warning — could not persist ids to $GH_APP_DEV_ENV (a later re-run will re-prompt)" >&2
fi

# COLLECT-ONLY: a host orchestrator (day0.sh) drives this wizard to gather fedora-dev's OWN
# answers + create its podman secret (as the invoking rootless user) WITHOUT launching — so
# day0 never duplicates fedora-dev's questions. Emit the resolved env as `export` lines for
# the caller to capture (eval), then stop.
if [ "${COLLECT_ONLY:-0}" = 1 ]; then
  printf 'export TS_AUTHKEY=%q IMAGE=%q BOX_HOSTNAME=%q GH_APP_ID=%q GH_APP_INSTALLATION_ID=%q GH_APP_SECRET=%q\n' \
    "${TS_AUTHKEY:-}" "$IMAGE" "$BOX_HOSTNAME" "${GH_APP_ID:-}" "${GH_APP_INSTALLATION_ID:-}" "${GH_APP_SECRET:-}"
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

export TS_AUTHKEY IMAGE BOX_HOSTNAME GH_APP_ID GH_APP_INSTALLATION_ID GH_APP_SECRET
exec ./run.sh
