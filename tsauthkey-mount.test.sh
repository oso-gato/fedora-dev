#!/usr/bin/env bash
# tsauthkey-mount.test.sh — the TS_AUTHKEY tailnet-join key is carried as a MOUNTED podman secret file,
# never as a persistent container env var (drift-guard for the audit 2026-07-22 finding #6).
#
# WHY: run.sh once passed `-e TS_AUTHKEY=<key>`, which lands in the container's persistent environment;
# distrobox re-materialises that as `--env=TS_AUTHKEY=<key>` on the argv of EVERY `distrobox enter` /
# `podman exec` (world-readable via /proc/<pid>/cmdline). The fix delivers the key as a `type=mount`
# secret (a file at /run/secrets/ts-authkey) and the entrypoint joins via tailscale's `--auth-key=file:`
# prefix — off the env AND off every argv. This static guard fails if a future edit reverts either half.
#
# bash tsauthkey-mount.test.sh  → exit 0 = all assertions pass.
set -uo pipefail
cd "$(dirname "$0")"
fails=0
ck() { if [ "$2" -eq 0 ]; then printf 'ok   — %s\n' "$1"; else printf 'FAIL — %s\n' "$1"; fails=$((fails+1)); fi; }

# (1) run.sh delivers TS_AUTHKEY as a type=mount secret, and does NOT pass it as a persistent env var.
ck "run.sh mounts fedora-dev-ts-authkey (type=mount,target=ts-authkey)" \
   "$(grep -Eq 'fedora-dev-ts-authkey,type=mount,target=ts-authkey' run.sh; echo $?)"
ck "run.sh does NOT pass TS_AUTHKEY as a container env var (-e TS_AUTHKEY=)" \
   "$(! grep -vE '^[[:space:]]*#' run.sh | grep -Eq -- '-e[[:space:]]+"?TS_AUTHKEY='; echo $?)"

# (2) The entrypoint reads the mounted file and joins via --auth-key=file:, never a bare env on argv.
ck "entrypoint reads the mounted secret /run/secrets/ts-authkey" \
   "$(grep -Fq '/run/secrets/ts-authkey' entrypoint.sh; echo $?)"
ck "entrypoint joins via tailscale --auth-key=file: (key off argv)" \
   "$(grep -Fq -- '--auth-key="file:' entrypoint.sh; echo $?)"
ck "entrypoint does NOT put the raw key on tailscale's argv (--auth-key=\"\$TS_AUTHKEY\")" \
   "$(! grep -Eq -- '--auth-key="\$\{?TS_AUTHKEY' entrypoint.sh; echo $?)"

# (3) The Quadlet template ships the mount form (so the host's deployed sed produces a mount).
ck "fedora-dev.container template is type=mount,target=ts-authkey (not type=env)" \
   "$(grep -Eq 'Secret=fedora-dev-ts-authkey,type=mount,target=ts-authkey' fedora-dev.container; echo $?)"
ck "fedora-dev.container ships no legacy type=env,target=TS_AUTHKEY line" \
   "$(! grep -Eq 'ts-authkey,type=env,target=TS_AUTHKEY' fedora-dev.container; echo $?)"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails assertion(s) failed"; exit 1; fi
echo "ok — TS_AUTHKEY is a mounted secret file, off the container env and off every argv"
