#!/usr/bin/env bash
# check-build-parity.sh — assert the Tier-1 (in-box) build invocations carry the SAME parity-critical
# flags as the Tier-2 host build, so an in-box GREEN reliably predicts a host GREEN. Motivating bug
# (#53): validate.sh's build LACKED the dnf-cache bind that build-throwaway.sh + the host's
# build-candidate.sh have — so a bind-mount-only failure built GREEN in-box but RED at the host,
# wasting a round-trip. This makes that parity a CHECKED contract instead of a silent assumption.
#
# PARITY-CRITICAL (must be in EVERY `podman build`):
#   * the dnf-cache bind      (`-v …:/var/cache/libdnf5:rw`)
#   * the download-cache bind (`-v …:/var/cache/fd-dl:rw`) — the pinned-asset cache the fetch contract
#     resolves (bin/fd-fetch.sh, #320). A NEW build-time bind repeats #53 unless this check knows about
#     it, which is why it is listed here in the same change that introduces it.
#   * `BUILD_ARGS` forwarding (so per-repo `--build-arg`s reach the build identically at both tiers).
# JUSTIFIED DIVERGENCE (NOT a parity violation): `--isolation=chroot` is REQUIRED in-box (the nested
# engine can't mount /proc at depth) and ABSENT on the host top-level engine. The cache binds, not the
# isolation, are the thing that must match — that is exactly what bit us.
#
# DIRECTION MATTERS — and it decides the exit code, because the two directions are different bugs:
#   * A TIER-1 build missing a bind the TIER-2 host build HAS ⇒ the #53 FALSE GREEN: the failure is
#     invisible in-box and only surfaces after a host round-trip. That is hard DRIFT, rc 1, and
#     validate.sh's T0b FAILS on it.
#   * The two TIER-1 builds DISAGREEING with each other ⇒ the same class (whichever lacks it validates a
#     different build) — hard DRIFT, rc 1.
#   * A TIER-1 bind the TIER-2 host build has NOT ADOPTED YET ⇒ the host build re-downloads a pinned
#     asset that was already cached in-box. Slower at the host; NOT a false GREEN, because the fetch
#     contract falls back to fetching and the build still succeeds. That is reported as DRIFT by name
#     with rc 3 — never folded into "OK" — and validate.sh reports it as PENDING without gating, so a
#     disclosed pending sibling cannot wedge every in-box validation in the fleet.
# Today rc 3 has exactly one instance: the /var/cache/fd-dl bind, whose host half (fedora-bootstrap's
# build-candidate.sh) is the sibling feature. When that lands, this reports PARITY: OK and rc 0.
#
# Run it after touching ANY build invocation. fedora-bootstrap (the Tier-2 reference) is checked when
# its clone is present; otherwise the two in-box builds are still checked against each other.
set -uo pipefail
fail=0; pending=0

# Per-axis presence, recorded per file so the DIRECTION can be folded after all three are read.
declare -A HAS_DNF=() HAS_DL=() SEEN=()

# has_bind <file> <in-build-path> → rc 0 iff a NON-COMMENT line carries an actual `-v <src>:<path>` flag.
# It must read CODE, not prose: a bare `grep -qE '/var/cache/…'` over the whole file is satisfied by a
# COMMENT that merely mentions the path — measured here, not imagined, when the mutation row that deletes
# the real bind still reported it "present" because the header documenting it survived. A parity check
# that a docstring can satisfy is not a check. (This is also why both binds name their in-build path
# LITERALLY at the `podman build` call site rather than through a variable.)
has_bind(){
  grep -v '^[[:space:]]*#' "$1" | grep -qE -- "-v[[:space:]]+\"?[^\"[:space:]]*:$2(:[a-z,]+)?\"?"
}

check(){ local label="$1" f="$2"
  [ -f "$f" ] || { echo "  [skip] $label: $f not present"; return; }
  grep -qE '(^|[^#].*)podman build' "$f" || { echo "  [skip] $label: no 'podman build' in $f"; return; }
  SEEN["$label"]=1
  if has_bind "$f" /var/cache/libdnf5; then HAS_DNF["$label"]=1; echo "  [ok]    $label: dnf-cache bind present"
  else HAS_DNF["$label"]=0; echo "  [DRIFT] $label: NO /var/cache/libdnf5 bind — a bind-mount-only failure passes in-box but REDs at the host"; fail=1; fi
  if has_bind "$f" /var/cache/fd-dl; then HAS_DL["$label"]=1; echo "  [ok]    $label: download-cache bind present (pinned-asset fetch contract, #320)"
  else HAS_DL["$label"]=0; fi
  if grep -qE 'BUILD_ARGS' "$f"; then echo "  [ok]    $label: BUILD_ARGS forwarded"
  else echo "  [warn]  $label: BUILD_ARGS not forwarded (a per-repo --build-arg may be dropped)"; fi
}
echo "== build-parity check — Tier-1 (in-box) must match Tier-2 (host) on the cache binds + BUILD_ARGS =="
D="${FD_DEV:-$HOME/repos/fedora-dev}"; B="${FD_BOOTSTRAP:-$HOME/repos/fedora-bootstrap}"
# prefer THIS tree's own copies for the dev-box scripts (so the check reflects the edits under review)
HERE="$(dirname "$(readlink -f "$0")")"
T1A="build-throwaway (T1)"; T1B="validate.sh   (T1)"; T2="build-candidate (T2 host)"
check "$T1A" "$HERE/build-throwaway.sh"
check "$T1B" "$HERE/validate.sh"
check "$T2"  "$B/build-candidate.sh"

# ---- fold the download-cache axis by DIRECTION (see the header) -------------------------------------
t1_missing=""
for l in "$T1A" "$T1B"; do
  [ "${SEEN[$l]:-0}" = 1 ] || continue
  [ "${HAS_DL[$l]:-0}" = 1 ] || t1_missing="$t1_missing$l; "
done
if [ -n "$t1_missing" ]; then
  # A Tier-1 build without the bind validates a DIFFERENT build than its sibling (and than the host,
  # once the host half lands): the #53 shape. Hard drift.
  echo "  [DRIFT] NO /var/cache/fd-dl bind in: ${t1_missing%; } — Tier-1 must carry it (bin/fd-fetch.sh resolves that path in-build)"
  fail=1
elif [ "${SEEN[$T2]:-0}" = 1 ] && [ "${HAS_DL[$T2]:-0}" != 1 ]; then
  echo "  [DRIFT] $T2: NO /var/cache/fd-dl bind — the Tier-2 host half of the pinned-download cache (#320) has NOT landed;"
  echo "          a host build re-downloads a pinned asset the in-box build served from cache. Bandwidth gap, NOT a false GREEN"
  echo "          (the fetch contract falls back to fetching). Fix: add the bind to fedora-bootstrap's build-candidate.sh."
  pending=1
fi

if [ "$fail" != 0 ]; then echo "PARITY: DRIFT"; exit 1; fi
if [ "$pending" != 0 ]; then echo "PARITY: DRIFT (Tier-2 host half pending: /var/cache/fd-dl)"; exit 3; fi
echo "PARITY: OK"
exit 0
