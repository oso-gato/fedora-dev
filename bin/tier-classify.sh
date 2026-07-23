#!/usr/bin/env bash
# tier-classify.sh — classify a change as Tier A / B / C per 00-GOVERNANCE.md Authority & boundary + fleet-core.md control-plane class.
#
# THE decision the whole fitness gate routes on: does this change need Arthur's click (Tier A), or may
# fedora-dev auto-merge it (Tier B/C)? Pure function of the CHANGED FILE PATHS — no network, no merge
# power. Prints exactly one of: A | B | C, and a one-line reason to stderr.
#
#   Tier A = the control-plane class (fleet-core.md) + the live-gate fence + host-apply-without-rollback
#            + 00-GOVERNANCE.md + secrets/identity + hard-to-undo. → Arthur's click + adversarial review.
#   Tier C = the change touches ONLY docs/comments (*.md, LICENSE) AND nothing Tier-A.  → auto-merge.
#   Tier B = everything else (reversible, non-boundary).                                 → auto-merge.
# Precedence: ANY Tier-A path ⇒ A (even if other files are docs). Else all-docs ⇒ C. Else B.
#
# Usage:
#   tier-classify.sh <file> [file...]                 # classify an explicit file list
#   tier-classify.sh --pr <repo> <pr-number>          # classify a GitHub PR's changed files (needs gh)
#   git -C <repo> diff --name-only main...HEAD | tier-classify.sh --stdin
#
# The Tier-A path patterns ARE the boundary definition Arthur owns — edit them here (itself a Tier-A
# change) to move a category across the line.
set -uo pipefail

# ---- Tier-A path patterns (case-glob; matched against each changed path) ----------------------------
# Keep in sync with 00-GOVERNANCE.md Authority & boundary + fleet-core.md control-plane class. Anything a hijacked agent
# would target to weaken its own leash, anything that mutates the live host without auto-rollback, or
# anything hard to undo.
is_tier_a_path(){
  case "$1" in
    # --- control-plane class (fleet-core.md) ---
    policy/*|*/policy/*) return 0;;                                   # policy/** (law, hooks, sudoers, managed-settings)
    *managed-settings.json) return 0;;
    *gate-push.sh|*gate-push.test.sh) return 0;;                      # the merge/push gate
    .github/workflows/*|*/.github/workflows/*) return 0;;            # CI (publishes/signs/has secrets)
    *.container) return 0;;                                           # Quadlet — how the host runs a workload (privilege/mounts)
    *sudoers*) return 0;;
    *sync-authorized-keys.sh|*key-sync*) return 0;;                   # trust root (SSH keys)
    *box-rebuild.sh|*box-assemble.sh|*claudebox-assemble.sh|*claudebox-init.sh) return 0;;  # box machinery
    # --- the live-gate FENCE + host-apply (mutates the live host, no auto-rollback) ---
    *validate-candidate.sh|*live-gate-run.sh|*live-gate-watch.sh|*build-candidate.sh) return 0;;  # the fence / gate
    *gvisor-setup.sh) return 0;;                                      # installs a runtime binary on the host
    setup.sh|setup-host.sh|setup-user.sh|*/setup.sh|*/setup-host.sh|*/setup-user.sh) return 0;;   # ROOT host-apply
    day0.sh|*/day0.sh|entrypoint.sh|*/entrypoint.sh|entrypoint-*.sh|*/entrypoint-*.sh) return 0;;  # PID-1 / host bring-up
    # --- the constitution + binding law docs + secrets/identity ---
    00-GOVERNANCE.md|*/00-GOVERNANCE.md) return 0;;
    CLAUDE.md|*/CLAUDE.md) return 0;;                                 # binding Build Principles + provenance (class-c) law
    fleet-core.md|*/fleet-core.md) return 0;;                         # stamped in-box law (also under policy/, belt+braces)
    *gh-app-auth.sh|*gh-app-provision.sh) return 0;;                  # standing-credential minter (identity)
    run.sh*|*/run.sh*) return 0;;                                     # deploy contract (+ .grd lineage twins)
    # --- FAIL-CLOSED CATCH-ALL (the key inversion): auto-merge is EARNED, not the default. Anything
    # EXECUTABLE or DEPLOYABLE is Tier A unless a human proved it safe — because a filename allowlist
    # misses every NEW control-plane file (a hijacked agent naming a host script `refresh-helper.sh`
    # would otherwise auto-merge). Covers systemd units, all shell scripts, Quadlets, image defs,
    # installers, provisioners — the classes the review found slipping to B.
    *.service|*.timer|*.mount|*.socket|*.path|*.target) return 0;;    # systemd units run as root (= host-apply)
    *.sh|*/bin/*) return 0;;                                          # ANY shell script / anything under a bin/ dir
    Containerfile|Containerfile.*|*/Containerfile|*/Containerfile.*) return 0;;  # image definition (base/pkgs/USER)
    *.container) return 0;;                                           # (already above; explicit)
    *) return 1;;
  esac
}
# Auto-mergeable ONLY if provably inert: docs/comments + a tight set of non-executable config. Anything
# not here AND not Tier-A is still Tier B, but the fail-closed catch-all above means executables never
# reach that branch — so B is genuinely low-risk (inert config), C is docs.
is_doc_path(){ case "$1" in *.md|*/LICENSE|LICENSE|*.txt) return 0;; *) return 1;; esac; }

# ---- gather the file list -------------------------------------------------------------------------
# Portable read (no `mapfile` — that is bash 4+; a bash-3.2 host must not silently mis-gather).
files=()
if [ "${1:-}" = "--pr" ]; then
  repo="${2:?--pr needs <repo> <pr>}"; pr="${3:?--pr needs <repo> <pr>}"
  while IFS= read -r line; do files+=( "$line" ); done \
    < <(gh pr view "$pr" --repo "oso-gato/$repo" --json files -q '.files[].path' 2>/dev/null)
  [ "${#files[@]}" -gt 0 ] || { echo "tier-classify: could not read PR files (gh)" >&2; exit 2; }
elif [ "${1:-}" = "--stdin" ]; then
  # `|| [ -n "$line" ]` keeps the FINAL line when the stream lacks a terminating newline (read
  # fills the var but returns nonzero at EOF; a plain `while read` silently DROPS that line — a
  # caller feeding a command-substituted variable would lose its last path, and a ONE-path input
  # would classify from zero paths). Fail-closed depends on reading every path; harden here so
  # every present and future caller inherits the fix.
  while IFS= read -r line || [ -n "$line" ]; do files+=( "$line" ); done
else
  files=( "$@" )
fi
[ "${#files[@]}" -gt 0 ] || { echo "tier-classify: no files given" >&2; exit 2; }

# ---- classify -------------------------------------------------------------------------------------
a_hit=""; all_docs=1
for f in "${files[@]}"; do
  f="${f%$'\r'}"; f="${f#./}"                    # strip CRLF + leading ./ so neither dodges a pattern
  [ -n "$f" ] || continue
  if is_tier_a_path "$f"; then a_hit="$f"; break; fi
  is_doc_path "$f" || all_docs=0
done

if [ -n "$a_hit" ]; then
  echo "Tier A (boundary): '$a_hit' is control-plane / fence / host-apply / constitution — Arthur's click + adversarial review" >&2
  echo A
elif [ "$all_docs" = 1 ]; then
  echo "Tier C (docs only): every changed file is docs/comments — fedora-dev auto-merges" >&2
  echo C
else
  echo "Tier B (reversible, non-boundary): fedora-dev auto-merges under the fitness gate" >&2
  echo B
fi
