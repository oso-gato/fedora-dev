#!/usr/bin/env bash
# session-scope-seed.sh <sid> — a session's launch-time SCOPE BINDER (R16/R27; the self-sustaining
# multi-tenancy piece). bin/claude calls it at EVERY launch/resume, with the session's holder pid in
# SESSION_HOLDER_PID (the long-lived bin/claude wrapper's $$, alive for the whole session). It does
# exactly one of:
#   * REFRESH — a persisted registry entry exists → rewrite its liveness coords to this holder. A
#     RESUMED session (new pid, same sid) keeps its durable scope, and the fresh coords stop a later
#     register()/reap from freeing a still-held scope. This is what makes scope survive every rebuild.
#   * SELF-SEED — NO entry, but a declared objective config
#     (${SCOPE_REGISTRY_DIR}/<sid>.objective = ONE line '<repo> <objective-doc-path>') → transcribe it
#     (repos DERIVED from the confirmed objective, sha resolved from the clone — the agent transcribes,
#     never authorizes). A one-time first-launch declaration; thereafter the entry persists + refreshes.
#   * NO-OP — undeclared session → nothing; it runs on the ceiling (and the SCOPE_SESSION layer fails it
#     closed if any actuator sets SCOPE_SESSION — safe).
#
# FAIL-SAFE BY CONTRACT: every path degrades to a no-op on any error and NEVER blocks a launch
# (bin/claude calls it `|| true`). No network; runs at the fedora-dev BASE level. Overridable seams:
# SCOPE_REGISTRY_CLI / REPO_SCOPE_CLI / SCOPE_REGISTRY_DIR (the test drives the REAL scripts via these).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REG="${SCOPE_REGISTRY_CLI:-$HERE/session-registry.sh}"
RS="${REPO_SCOPE_CLI:-$HERE/repo-scope.sh}"
OBJDIR="${SCOPE_REGISTRY_DIR:-$HOME/.local/state/scope-registry}"

sid="${1:-}"; [ -n "$sid" ] || { echo "session-scope-seed: needs <sid>" >&2; exit 2; }
key="${sid//[^A-Za-z0-9._-]/_}"

# 1) a persisted entry → refresh its liveness (holder = SESSION_HOLDER_PID, inherited from bin/claude).
if [ -n "$(bash "$REG" resolve "$sid" 2>/dev/null)" ]; then
  bash "$REG" refresh "$sid" 2>/dev/null || true
  exit 0
fi

# 2) no entry, but a declared objective → self-seed by transcribing it.
obj="$OBJDIR/$key.objective"
if [ -f "$obj" ]; then
  repo=""; path=""
  read -r repo path _ < "$obj" 2>/dev/null || true
  if [ -n "$repo" ] && [ -n "$path" ]; then
    bash "$RS" transcribe --objective "$repo $path" "$sid" 2>/dev/null || true
  fi
fi
exit 0
