#!/usr/bin/env bash
# validate.sh — autonomous in-box candidate validation for the dev loop.
# GATING tiers are the ones that are FAITHFUL + reliable at the dev box's nesting depth.
# Live boot validation is intentionally NOT gated here: the nested engine can only run a
# container in a degraded shared-net/shared-pid mode (own-netns => ping_group_range RO;
# own-pidns => mount proc denied), which is non-representative AND tears down unreliably.
# Faithful live validation belongs on the host (own namespaces) — the existing post-merge
# container-refresh health-gate + auto-rollback. Here we gate what we CAN trust in-box.
#   T1 build    (gate) : podman build --isolation=chroot
#   T2 assembly (gate) : create + export + inspect expected files
#   T3 lint     (gate) : bash -n on shipped shell scripts
#   T4 smoke    (info) : best-effort degraded boot, never gates the verdict
set -uo pipefail
REPO="${1:?usage: validate.sh <repo-dir> [containerfile] [build|nobuild]}"; FILE="${2:-Containerfile}"; DOBUILD="${3:-build}"
NAME="$(basename "$REPO")"; TAG="localhost/${NAME}:candidate"; OUT="$(mktemp -d)"; fail=0
g(){ printf '  %-22s %s\n' "$1" "$2"; case "$2" in FAIL*|NO-*) fail=1;; esac; }   # gating
i(){ printf '  %-22s %s\n' "$1" "$2"; }                                          # informational

echo "== T1 build (gate) =="
if [ "$DOBUILD" = build ]; then
  podman build --isolation=chroot -t "$TAG" -f "$REPO/$FILE" "$REPO" >"$OUT/build.log" 2>&1 \
    && g build PASS || { g build FAIL; tail -15 "$OUT/build.log"; echo "VERDICT: RED (build)"; exit 1; }
else podman image exists "$TAG" && g build SKIP-exists || { g build NO-IMAGE; exit 1; }; fi

echo "== T2 assembly (gate) =="
cid=$(podman create "$TAG" 2>/dev/null)
if [ -n "$cid" ]; then
  podman export "$cid" >"$OUT/rootfs.tar" 2>/dev/null; podman rm -f "$cid" >/dev/null 2>&1
  files=$(tar -tf "$OUT/rootfs.tar" 2>/dev/null); n=$(wc -l <<<"$files")
  [ "$n" -gt 1000 ] && g rootfs-size "PASS($n)" || g rootfs-size FAIL
  grep -q 'usr/local/bin/entrypoint.sh' <<<"$files" && g entrypoint-present PASS || g entrypoint-present FAIL
  mkdir -p "$OUT/x"; tar -C "$OUT/x" -xf "$OUT/rootfs.tar" usr/local/bin/entrypoint.sh 2>/dev/null
else g assembly FAIL; fi

echo "== T3 lint (gate) =="
if [ -f "$OUT/x/usr/local/bin/entrypoint.sh" ]; then
  bash -n "$OUT/x/usr/local/bin/entrypoint.sh" 2>"$OUT/lint.log" && g lint-entrypoint PASS || { g lint-entrypoint FAIL; cat "$OUT/lint.log"; }
fi

echo "== T4 boot-smoke (info only — degraded; faithful live = host) =="
sn="vsmoke-$$"
if podman run -d --replace --name "$sn" --network=host --pid=host --cap-add SYS_ADMIN --device /dev/fuse \
     --security-opt label=disable -e TS_AUTHKEY="" "$TAG" >/dev/null 2>&1; then
  for x in 1 2 3 4 5; do podman ps --filter name="$sn" --filter status=running -q | grep -q . || break; sleep 6; done
  st=$(podman ps -a --filter name="$sn" --format '{{.Status}}'); i smoke-stays-up "${st:-gone}"
  podman exec "$sn" test -S /run/user/1000/podman/podman.sock 2>/dev/null && i smoke-podman-socket up || i smoke-podman-socket "n/a"
  podman kill -s KILL "$sn" >/dev/null 2>&1; podman rm -f -t 0 "$sn" >/dev/null 2>&1
else i smoke "launch-skipped"; fi

echo; echo "VERDICT: $([ $fail = 0 ] && echo GREEN || echo RED)   (gated on T1-T3; logs: $OUT)"
exit $fail
