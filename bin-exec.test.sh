#!/usr/bin/env bash
# bin-exec.test.sh — every bin/*.sh MUST be git-tracked executable (mode 100755).
#
# WHY: the poller, entrypoint and services invoke these scripts by DIRECT EXEC (`"$SCRIPT" --once`,
# `exec .../dev-loop-service.sh`) — a non-executable script fails at runtime with "Permission denied".
# It shipped for real: bin/reconcile.sh (#216) and bin/dev-loop-service.sh (#214) were committed 100644
# — the reconciler could never run, and arming the authoring loop would have died at the entrypoint exec.
# NEITHER the unit tests (which invoke via `bash <script>`, mode-agnostic) NOR the host live-gate (opt-in
# services don't run in its smoke) NOR the fitness diff (mode changes are near-invisible) caught it. This
# guard closes that gap: a mode regression on ANY bin/*.sh fails here.
#
# bash bin-exec.test.sh  → exit 0 = all executable.
set -uo pipefail
cd "$(dirname "$0")"
bad=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  # authoritative: the GIT-TRACKED mode (a local `chmod` that was never committed must not pass).
  bad="$(git ls-files -s 'bin/*.sh' | awk '$1!="100755"{print $4}')"
else
  # non-git checkout (e.g. a tarball build context): fall back to the filesystem exec bit.
  for f in bin/*.sh; do [ -x "$f" ] || bad="$bad$f"$'\n'; done
fi
if [ -n "${bad//[$'\n\t ']/}" ]; then
  echo "FAIL: bin/*.sh scripts NOT tracked executable (100755) — direct-exec will 'Permission denied':"
  printf '  %s\n' $bad
  exit 1
fi
n="$(git ls-files 'bin/*.sh' 2>/dev/null | wc -l)"
echo "ok — all ${n:-?} bin/*.sh are executable (100755)"
