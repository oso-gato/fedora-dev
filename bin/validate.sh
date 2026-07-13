#!/usr/bin/env bash
# validate.sh — autonomous in-box candidate validation for the dev loop (repo-agnostic).
# HOST-IMMUTABLE: builds into an ephemeral image tree in the dev box's OWN nested engine
# (never the host live OS/tree); test containers tear down on exit. The CALLER discards the
# candidate image (rmi) after testing — pass DISCARD=1 to have this script do it for you.
# Faithful systemd/live validation stays host-side; in-box gates what's faithful here.
#   T0 .live-gate (gate): lint the in-repo `.live-gate` contract via bin/lint-live-gate.sh (the host's
#                        VENDORED lg_load + sanity checks) — catches contract bugs at Tier-1 BEFORE the
#                        host round-trip (unexpanded $_GD_* cross-ref / non-absolute SECRET_MOUNT / a
#                        publish flag in the fence / an lg_load-rejected contract). No-op if no .live-gate.
#   T0b build-parity(gate): bin/check-build-parity.sh — assert T1's build carries the SAME dnf-cache
#                        bind + BUILD_ARGS as the host Tier-2 build, so an in-box GREEN predicts a host
#                        GREEN (bug #53). Now GATED, not a manual afterthought.
#   T1 build (gate)    : podman build --isolation=chroot + the persistent dnf-cache bind  [+ $BUILD_ARGS]
#                        (same -v …/fd-dnf:/var/cache/libdnf5 build-throwaway.sh + the host gate use,
#                         so T1 reproduces the REAL build env — catches bind-mount-only failures).
#                        NON-IMAGE repos (#180): a repo with no root Containerfile is a repo with NO
#                        image, not a build failure — the DEFAULTED target resolves root Containerfile,
#                        else the repo's own .live-gate CFILE (fedora-bootstrap's shellgate =>
#                        Containerfile.livegate), else T1/T2/T4 are SKIPPED with the reason stated.
#   T2 assembly (gate) : inspect (a startup process is DECLARED: Entrypoint or Cmd) + create + export
#                        (sane size; the fleet entrypoint*.sh file only when the source tree ships one)
#   T3 lint (gate)     : bash -n on every shipped *.sh in the repo
#   T4 smoke (info)    : degraded boot for NON-systemd lineages only; systemd-PID-1 => assembly-only
set -uo pipefail
REPO="${1:?usage: validate.sh <repo-dir> [containerfile] [build|nobuild]}"; FILE="${2:-}"; DOBUILD="${3:-build}"
BIN="$(dirname "$(readlink -f "$0")")"
# BUILD-TARGET RESOLUTION (#180): an EXPLICIT 2nd arg is honoured verbatim (a missing file is a build
# FAIL — unchanged, so a broken IMAGE repo can never hide behind a skip). A DEFAULTED probe resolves
# the repo's own shape instead of assuming an image repo: root Containerfile -> build it; else a
# parseable .live-gate whose first target's CFILE exists -> build THAT (resolved by the SAME vendored
# lg_load the host uses, via lint-live-gate.sh --cfile — the repo already says how it wants to be
# built; never a hardcoded second filename convention); else NON-IMAGE: T1/T2/T4 are SKIPPED (visibly,
# with the reason — "no image to build" must never read as "the image failed to build") while
# T0/T0b/T3 still gate. Before this, the unconditional Containerfile default RED'd EVERY dev-author
# run in fedora-bootstrap — the loop was structurally unable to author in the host repo.
NOIMAGE=0; NOIMAGE_WHY=""
if [ -z "$FILE" ]; then
  if [ -f "$REPO/Containerfile" ]; then FILE=Containerfile
  elif cf="$(bash "$BIN/lint-live-gate.sh" --cfile "$REPO" 2>/dev/null)" && [ -n "$cf" ] && [ -f "$REPO/$cf" ]; then
    FILE="$cf"
  else
    NOIMAGE=1
    if [ -f "$REPO/.live-gate" ]; then NOIMAGE_WHY="no root Containerfile and the .live-gate resolves no buildable target here (T0 lints the contract itself)"
    else NOIMAGE_WHY="no root Containerfile and no .live-gate — a non-image repo ships nothing to build"; fi
  fi
fi
NAME="$(basename "$REPO")"; OUT="$(mktemp -d)"; fail=0
TAG=""; [ "$NOIMAGE" = 0 ] && TAG="localhost/${NAME}:candidate-$(echo "$FILE" | tr -c 'a-zA-Z0-9' - )"
DNF_CACHE="${FD_DNF_CACHE:-$HOME/.cache/fd-dnf}"   # persistent dnf cache bound into T1 (matches build-throwaway.sh + the host live-gate)
g(){ printf '  %-22s %s\n' "$1" "$2"; case "$2" in FAIL*|NO-*) fail=1;; esac; }
i(){ printf '  %-22s %s\n' "$1" "$2"; }
SYS=0; [ -n "$FILE" ] && grep -qE 'ENTRYPOINT.*(/sbin/init|systemd)|STOPSIGNAL[[:space:]]+SIGRTMIN' "$REPO/$FILE" 2>/dev/null && SYS=1
echo "repo=$NAME file=${FILE:-(none)} systemd-PID-1=$SYS tag=${TAG:-(none)}"

echo "== T0 .live-gate contract (gate) =="
LINT="$BIN/lint-live-gate.sh"
if [ -f "$LINT" ]; then
  if bash "$LINT" "$REPO" >"$OUT/livegate.log" 2>&1; then g live-gate PASS; else g live-gate FAIL; sed 's/^/    /' "$OUT/livegate.log"; fi
else i live-gate "skipped (lint-live-gate.sh not adjacent)"; fi

echo "== T0b build-parity (gate) =="
# WIRE-IN: the build-parity contract (Tier-1 build invocations carry the same dnf-cache bind +
# BUILD_ARGS as the Tier-2 host build) is now GATED here, not left to an agent remembering to run
# bin/check-build-parity.sh by hand. It bit us once (#53: an in-box GREEN that RED'd at the host on a
# bind-mount-only failure). check-build-parity.sh exits non-zero on real drift and skips gracefully
# when the host reference clone is absent (still checking the two in-box builds against each other), so
# it is safe to gate on unconditionally.
CBP="$BIN/check-build-parity.sh"
if [ -f "$CBP" ]; then
  if bash "$CBP" >"$OUT/parity.log" 2>&1; then g build-parity PASS; else g build-parity FAIL; sed 's/^/    /' "$OUT/parity.log"; fi
else i build-parity "skipped (check-build-parity.sh not adjacent)"; fi

echo "== T1 build (gate) =="
if [ "$NOIMAGE" = 1 ]; then
  # SKIPPED, not passed and not failed (#180): the tier line says so out loud, so an operator can
  # tell "no image to build" from "the image failed to build" at a glance.
  i build "SKIPPED — $NOIMAGE_WHY"
elif [ "$DOBUILD" = build ]; then
  mkdir -p "$DNF_CACHE"
  # shellcheck disable=SC2086
  # Bind the persistent dnf cache at /var/cache/libdnf5 — the SAME mount build-throwaway.sh + the host
  # live-gate use — so T1 reproduces the real build env (and catches bind-mount-only failures, e.g. an
  # `rm -rf /var/cache/libdnf5` that fails EBUSY only when the cache is a live mountpoint).
  podman build --isolation=chroot -v "$DNF_CACHE:/var/cache/libdnf5:rw" ${BUILD_ARGS:-} -t "$TAG" -f "$REPO/$FILE" "$REPO" >"$OUT/build.log" 2>&1 \
    && g build PASS || { g build FAIL; tail -20 "$OUT/build.log"; echo "VERDICT: RED (build)"; exit 1; }
else podman image exists "$TAG" && g build SKIP-exists || { g build NO-IMAGE; exit 1; }; fi

echo "== T2 assembly (gate) =="
if [ "$NOIMAGE" = 1 ]; then
  i assembly "SKIPPED — no image was built (non-image repo; see T1)"
else
  # REPO-AGNOSTIC startup check (#160): a correct image DECLARES a startup process — podman inspect
  # shows a non-empty .Config.Entrypoint OR .Config.Cmd (CMD-only is correct; NEITHER cannot start —
  # and podman 5's `create` still happily creates such a container, so this inspect is the only
  # thing standing between a no-startup image and a GREEN). The old unconditional rootfs grep for
  # usr/local/bin/entrypoint*.sh was the fedora-dev-family CONVENTION, not a correctness property:
  # it RED'd a legitimately minimal CMD-only image whose build/lint/smoke all passed (e2e-alpha,
  # 2026-07-12) and wedged the E2E-A run on a validator opinion.
  start=$(podman inspect --format '{{len .Config.Entrypoint}}+{{len .Config.Cmd}}' "$TAG" 2>/dev/null)
  if [ -n "$start" ] && [ "$start" != "0+0" ]; then g startup-process "PASS(entrypoint+cmd argv counts $start)"
  else g startup-process "FAIL(image declares NO startup process — .Config.Entrypoint AND .Config.Cmd are both empty; set ENTRYPOINT or CMD in $FILE)"; fi
  cid=$(podman create "$TAG" 2>/dev/null)
  if [ -n "$cid" ]; then
    podman export "$cid" >"$OUT/rootfs.tar" 2>/dev/null; podman rm -f "$cid" >/dev/null 2>&1
    files=$(tar -tf "$OUT/rootfs.tar" 2>/dev/null); n=$(wc -l <<<"$files")
    [ "$n" -gt 1000 ] && g rootfs-size "PASS($n)" || g rootfs-size FAIL
    # FLEET CONVENTION, now CONDITIONAL (#160): only a tree that SHIPS entrypoint*.sh sources (the
    # fedora-dev family) must carry /usr/local/bin/entrypoint*.sh in the image — a fleet image that
    # LOST its entrypoint is a real regression; a repo without the convention is never held to it.
    if [ -n "$(find "$REPO" -name 'entrypoint*.sh' -not -path '*/.git/*' -print -quit 2>/dev/null)" ]; then
      grep -qE 'usr/local/bin/entrypoint[^/]*\.sh' <<<"$files" && g entrypoint-present PASS \
        || g entrypoint-present "FAIL(tree ships entrypoint*.sh but the image carries no /usr/local/bin/entrypoint*.sh — fleet-convention regression; COPY it into the image)"
    else i entrypoint-present "skipped (tree ships no entrypoint*.sh — the startup-process check governs)"; fi
  else g assembly FAIL; fi
fi

echo "== T3 lint (gate) — every shipped *.sh =="
lf=0; cnt=0
while IFS= read -r s; do cnt=$((cnt+1)); bash -n "$s" 2>>"$OUT/lint.log" || { lf=1; echo "  bad: $s"; }; done < <(find "$REPO" -name '*.sh' -not -path '*/.git/*')
[ $lf = 0 ] && g lint-scripts "PASS($cnt files)" || { g lint-scripts FAIL; tail -10 "$OUT/lint.log"; }

echo "== T4 boot-smoke =="
if [ "$NOIMAGE" = 1 ]; then
  i smoke "skipped (no image — non-image repo)"
elif [ $SYS = 1 ]; then
  i smoke "skipped (systemd-PID-1 — faithful live = host)"
else
  sn="vsmoke-$$"
  if podman run -d --replace --name "$sn" --network=host --pid=host --cap-add SYS_ADMIN --device /dev/fuse \
       --security-opt label=disable "$TAG" >/dev/null 2>&1; then
    for x in 1 2 3 4 5; do podman ps --filter name="$sn" --filter status=running -q | grep -q . || break; sleep 6; done
    i smoke-stays-up "$(podman ps -a --filter name="$sn" --format '{{.Status}}' || echo gone)"
    podman kill -s KILL "$sn" >/dev/null 2>&1; podman rm -f -t 0 "$sn" >/dev/null 2>&1
  else i smoke launch-skipped; fi
fi

[ "${DISCARD:-0}" = 1 ] && [ "$NOIMAGE" = 0 ] && { podman rmi -f "$TAG" >/dev/null 2>&1; i discard "image tree removed (host-immutable)"; }
GATED="gated T0/T0b/T1-T3"; [ "$NOIMAGE" = 1 ] && GATED="gated T0/T0b/T3 — T1/T2/T4 SKIPPED (non-image repo)"
echo; echo "VERDICT: $([ $fail = 0 ] && echo GREEN || echo RED)   ($GATED; logs: $OUT)"
exit $fail
