#!/usr/bin/env bash
# validate.sh — autonomous in-box candidate validation for the dev loop (repo-agnostic).
# HOST-IMMUTABLE: builds into an ephemeral image tree in the dev box's OWN nested engine
# (never the host live OS/tree); test containers tear down on exit. The CALLER discards the
# candidate image (rmi) after testing — pass DISCARD=1 to have this script do it for you.
# Faithful systemd/live validation stays host-side; in-box gates what's faithful here.
#   T1 build (gate)    : podman build --isolation=chroot + the persistent dnf-cache bind  [+ $BUILD_ARGS]
#                        (same -v …/fd-dnf:/var/cache/libdnf5 build-throwaway.sh + the host gate use,
#                         so T1 reproduces the REAL build env — catches bind-mount-only failures)
#   T2 assembly (gate) : create + export + inspect (entrypoint present, sane size)
#   T3 lint (gate)     : bash -n on every shipped *.sh in the repo
#   T4 smoke (info)    : degraded boot for NON-systemd lineages only; systemd-PID-1 => assembly-only
set -uo pipefail
REPO="${1:?usage: validate.sh <repo-dir> [containerfile] [build|nobuild]}"; FILE="${2:-Containerfile}"; DOBUILD="${3:-build}"
NAME="$(basename "$REPO")"; TAG="localhost/${NAME}:candidate-$(echo "$FILE" | tr -c 'a-zA-Z0-9' - )"; OUT="$(mktemp -d)"; fail=0
DNF_CACHE="${FD_DNF_CACHE:-$HOME/.cache/fd-dnf}"   # persistent dnf cache bound into T1 (matches build-throwaway.sh + the host live-gate)
g(){ printf '  %-22s %s\n' "$1" "$2"; case "$2" in FAIL*|NO-*) fail=1;; esac; }
i(){ printf '  %-22s %s\n' "$1" "$2"; }
SYS=0; grep -qE 'ENTRYPOINT.*(/sbin/init|systemd)|STOPSIGNAL[[:space:]]+SIGRTMIN' "$REPO/$FILE" 2>/dev/null && SYS=1
echo "repo=$NAME file=$FILE systemd-PID-1=$SYS tag=$TAG"

echo "== T1 build (gate) =="
if [ "$DOBUILD" = build ]; then
  mkdir -p "$DNF_CACHE"
  # shellcheck disable=SC2086
  # Bind the persistent dnf cache at /var/cache/libdnf5 — the SAME mount build-throwaway.sh + the host
  # live-gate use — so T1 reproduces the real build env (and catches bind-mount-only failures, e.g. an
  # `rm -rf /var/cache/libdnf5` that fails EBUSY only when the cache is a live mountpoint).
  podman build --isolation=chroot -v "$DNF_CACHE:/var/cache/libdnf5:rw" ${BUILD_ARGS:-} -t "$TAG" -f "$REPO/$FILE" "$REPO" >"$OUT/build.log" 2>&1 \
    && g build PASS || { g build FAIL; tail -20 "$OUT/build.log"; echo "VERDICT: RED (build)"; exit 1; }
else podman image exists "$TAG" && g build SKIP-exists || { g build NO-IMAGE; exit 1; }; fi

echo "== T2 assembly (gate) =="
cid=$(podman create "$TAG" 2>/dev/null)
if [ -n "$cid" ]; then
  podman export "$cid" >"$OUT/rootfs.tar" 2>/dev/null; podman rm -f "$cid" >/dev/null 2>&1
  files=$(tar -tf "$OUT/rootfs.tar" 2>/dev/null); n=$(wc -l <<<"$files")
  [ "$n" -gt 1000 ] && g rootfs-size "PASS($n)" || g rootfs-size FAIL
  grep -qE 'usr/local/bin/entrypoint[^/]*\.sh' <<<"$files" && g entrypoint-present PASS || g entrypoint-present FAIL
else g assembly FAIL; fi

echo "== T3 lint (gate) — every shipped *.sh =="
lf=0; cnt=0
while IFS= read -r s; do cnt=$((cnt+1)); bash -n "$s" 2>>"$OUT/lint.log" || { lf=1; echo "  bad: $s"; }; done < <(find "$REPO" -name '*.sh' -not -path '*/.git/*')
[ $lf = 0 ] && g lint-scripts "PASS($cnt files)" || { g lint-scripts FAIL; tail -10 "$OUT/lint.log"; }

echo "== T4 boot-smoke =="
if [ $SYS = 1 ]; then
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

[ "${DISCARD:-0}" = 1 ] && { podman rmi -f "$TAG" >/dev/null 2>&1; i discard "image tree removed (host-immutable)"; }
echo; echo "VERDICT: $([ $fail = 0 ] && echo GREEN || echo RED)   (gated T1-T3; logs: $OUT)"
exit $fail
