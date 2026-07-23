#!/usr/bin/env bash
# key-perms.test.sh — the two GitHub App private-key mounts are owner-only 0400, tightened
# DIFFERENTLY per their rightful reader (drift-guard for the audit 2026-07-22 finding #5).
#
# WHY: the fitness key at world-readable 0444 let any in-box (uid 1000) process read it and mint a
# fitness token, collapsing the author≠judge merge boundary. The fix is asymmetric and a naive uniform
# `chmod 0400` BREAKS the dev key:
#   * DEV key  (gh_app_key)         — read by `core` (uid 1000) via `runuser -u core` in the entrypoint,
#     so its mount MUST be owned by core: uid=1000,gid=1000,mode=0400 (a bare 0400 owner-root → EACCES).
#   * FITNESS key (gh_app_key_fitness) — read ONLY by PID-1 root (the ferry + its 40-min refresh), so
#     mode=0400 with the DEFAULT owner (root/uid 0) and NO uid=/gid=; that removes the world-read bit and
#     makes it unreadable in the nested (uid-0-unmapped) claudebox userns — restoring author≠judge.
# This static guard fails if a future edit drops the owner/mode or symmetrises the two keys.
#
# bash key-perms.test.sh  → exit 0 = all assertions pass.
set -uo pipefail
cd "$(dirname "$0")"

fails=0
ck() { # ck <description> <condition-rc>
  if [ "$2" -eq 0 ]; then printf 'ok   — %s\n' "$1"
  else printf 'FAIL — %s\n' "$1"; fails=$((fails+1)); fi
}
has()  { grep -Eq -- "$2" "$1"; }   # has <file> <ere>
hasnt(){ ! grep -Eq -- "$2" "$1"; } # hasnt <file> <ere>

# (1) run.sh DEV secret line: owner=core (uid=1000,gid=1000) + mode=0400.
ck "run.sh dev key mount is uid=1000,gid=1000,mode=0400" \
   "$(has run.sh 'target=gh_app_key,uid=1000,gid=1000,mode=0400'; echo $?)"

# (2) run.sh FITNESS secret line: mode=0400, owner left as root (NO uid=/gid= on that line).
ck "run.sh fitness key mount is mode=0400" \
   "$(has run.sh 'target=gh_app_key_fitness,mode=0400'; echo $?)"
ck "run.sh fitness key mount does NOT pin uid/gid (owner must stay root)" \
   "$(! grep -E 'gh_app_key_fitness' run.sh | grep -Eq 'uid=|gid='; echo $?)"

# (3) fedora-dev.container DEV template mirrors the owner-only mount.
ck "fedora-dev.container dev template is uid=1000,gid=1000,mode=0400" \
   "$(has fedora-dev.container 'target=gh_app_key,uid=1000,gid=1000,mode=0400'; echo $?)"

# (4) fedora-dev.container FITNESS template is mode=0400.
ck "fedora-dev.container fitness template is mode=0400" \
   "$(has fedora-dev.container 'target=gh_app_key_fitness,mode=0400'; echo $?)"

# (5) The uid asymmetry the modes depend on: fitness ferry mints AS ROOT (no runuser),
#     while the DEV provision uses `runuser -u core`. Documents why fitness=root-owned, dev=core-owned.
ck "entrypoint dev App is provisioned via 'runuser -u core' (uid-1000 reader)" \
   "$(grep -B6 'gh-app-auth.sh install' entrypoint.sh | grep -q 'runuser -u core'; echo $?)"
ck "entrypoint fitness_ferry mints WITHOUT 'runuser -u core' (root reader)" \
   "$(! awk '/^fitness_ferry\(\)/{f=1} f&&/runuser -u core/{print} /^}/{if(f)exit}' entrypoint.sh | grep -q .; echo $?)"

# (6) The untrue 'verified empirically' invisibility claim was removed (single-line fragment).
ck "entrypoint.sh no longer asserts the bare 'verified empirically'" \
   "$(hasnt entrypoint.sh 'verified empirically'; echo $?)"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails assertion(s) failed"; exit 1; fi
echo "ok — App key mounts are owner-only 0400 (dev=core, fitness=root)"
