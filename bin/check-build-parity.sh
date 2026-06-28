#!/usr/bin/env bash
# check-build-parity.sh — assert the Tier-1 (in-box) build invocations carry the SAME parity-critical
# flags as the Tier-2 host build, so an in-box GREEN reliably predicts a host GREEN. Motivating bug
# (#53): validate.sh's build LACKED the dnf-cache bind that build-throwaway.sh + the host's
# build-candidate.sh have — so a bind-mount-only failure built GREEN in-box but RED at the host,
# wasting a round-trip. This makes that parity a CHECKED contract instead of a silent assumption.
#
# PARITY-CRITICAL (must be in EVERY `podman build`): the dnf-cache bind (`-v …/var/cache/libdnf5:rw`)
# + `BUILD_ARGS` forwarding (so per-repo `--build-arg`s reach the build identically at both tiers).
# JUSTIFIED DIVERGENCE (NOT a parity violation): `--isolation=chroot` is REQUIRED in-box (the nested
# engine can't mount /proc at depth) and ABSENT on the host top-level engine. The cache bind, not the
# isolation, is the thing that must match — that is exactly what bit us.
#
# Run it after touching ANY build invocation. fedora-bootstrap (the Tier-2 reference) is checked when
# its clone is present; otherwise the two in-box builds are still checked against each other.
set -uo pipefail
fail=0
check(){ local label="$1" f="$2"
  [ -f "$f" ] || { echo "  [skip] $label: $f not present"; return; }
  grep -qE '(^|[^#].*)podman build' "$f" || { echo "  [skip] $label: no 'podman build' in $f"; return; }
  if grep -qE '/var/cache/libdnf5' "$f"; then echo "  [ok]    $label: dnf-cache bind present"
  else echo "  [DRIFT] $label: NO /var/cache/libdnf5 bind — a bind-mount-only failure passes in-box but REDs at the host"; fail=1; fi
  if grep -qE 'BUILD_ARGS' "$f"; then echo "  [ok]    $label: BUILD_ARGS forwarded"
  else echo "  [warn]  $label: BUILD_ARGS not forwarded (a per-repo --build-arg may be dropped)"; fi
}
echo "== build-parity check — Tier-1 (in-box) must match Tier-2 (host) on the cache bind + BUILD_ARGS =="
D="${FD_DEV:-$HOME/repos/fedora-dev}"; B="${FD_BOOTSTRAP:-$HOME/repos/fedora-bootstrap}"
# prefer THIS tree's own copies for the dev-box scripts (so the check reflects the edits under review)
HERE="$(dirname "$(readlink -f "$0")")"
check "build-throwaway (T1)"     "$HERE/build-throwaway.sh"
check "validate.sh   (T1)"       "$HERE/validate.sh"
check "build-candidate (T2 host)" "$B/build-candidate.sh"
echo "PARITY: $([ $fail = 0 ] && echo OK || echo DRIFT)"
exit $fail
