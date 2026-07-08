#!/usr/bin/env bash
# Regression test for the assemble-health marker (#11).
#
# Guards the invariant that a HALF-ASSEMBLED box reads UNHEALTHY while a normal
# IN-PROGRESS first-boot assemble stays healthy — and that the two copies of the
# health predicate (fedora-dev.container HealthCmd + run.sh --health-cmd) stay in
# sync. Exercises the ACTUAL shipped artifacts (the verbatim EXIT trap from
# claudebox-assemble.sh + the exact --health-cmd string), never a paraphrase.
#
# Run after touching the health cmd, the assemble marker, or the trap:
#   bash health-marker.test.sh   -> exit 0 = all rows pass
set -uo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1 ($2)"; pass=$((pass+1)); else echo "FAIL: $1 (got=$2 want=$3)"; fail=$((fail+1)); fi; }

# ---- 0. the two predicate copies must be byte-identical -----------------------
Q=$(grep -oP '(?<=^HealthCmd=).*' "$REPO/fedora-dev.container")
R=$(grep -oP "(?<=--health-cmd ')[^']*" "$REPO/run.sh")
ck "quadlet HealthCmd == run.sh --health-cmd" "$([ "$Q" = "$R" ] && echo same || echo drift)" same
# and both must actually carry the failure-marker clause
ck "predicate carries the .assemble-failed clause" \
   "$(printf '%s' "$R" | grep -q '! test -e /home/core/.local/state/claudebox/.assemble-failed' && echo yes || echo no)" yes

# ---- 1. the verbatim _assemble_finish EXIT trap ------------------------------
TRAP_BLOCK=$(sed -n '/^STATE="\$HOME\/.local\/state\/claudebox"/,/^trap _assemble_finish EXIT$/p' "$REPO/claudebox-assemble.sh")
[ -n "$TRAP_BLOCK" ] || { echo "FAIL: could not extract trap block from claudebox-assemble.sh"; exit 1; }
run_trap() {  # $1 = simulated exit code ; echoes present|absent
  local home; home=$(mktemp -d)
  HOME="$home" bash -c "set -euo pipefail; $TRAP_BLOCK; exit $1" >/dev/null 2>&1
  [ -e "$home/.local/state/claudebox/.assemble-failed" ] && echo present || echo absent
  rm -rf "$home"
}
ck "trap: non-zero exit writes .assemble-failed" "$(run_trap 1)" present
ck "trap: clean exit leaves none"                "$(run_trap 0)" absent
home=$(mktemp -d); mkdir -p "$home/.local/state/claudebox"; : > "$home/.local/state/claudebox/.assemble-failed"
HOME="$home" bash -c "set -euo pipefail; $TRAP_BLOCK; exit 0" >/dev/null 2>&1
ck "trap: clean exit CLEARS a stale marker (self-heal)" \
   "$([ -e "$home/.local/state/claudebox/.assemble-failed" ] && echo present || echo absent)" absent
rm -rf "$home"

# ---- 2. the exact shipped health predicate across marker states --------------
# Neutralise the liveness probes to isolate the new clause; repoint the marker dir.
TMP=$(mktemp -d)
PRED=$(printf '%s' "$R" \
  | sed -e 's#pgrep -x sshd#true#' -e 's#pgrep -x tailscaled#true#' \
        -e 's#test -S /run/user/1000/podman/podman.sock#true#' \
        -e "s#/home/core/.local/state/claudebox#$TMP#")
health() { sh -c "$PRED"; local rc=$?; [ "$rc" -ne 0 ] && rc=1; echo "$rc"; }
: > "$TMP/.assembled"; rm -f "$TMP/.assemble-failed";       ck "assemble SUCCEEDED -> healthy"            "$(health)" 0
rm -f "$TMP/.assembled" "$TMP/.assemble-failed";            ck "assemble IN-PROGRESS -> healthy"          "$(health)" 0
: > "$TMP/.assemble-failed";                                ck "assemble FAILED -> unhealthy"             "$(health)" 1
: > "$TMP/.assembled"; : > "$TMP/.assemble-failed";         ck "FAILED w/ stale .assembled -> unhealthy"  "$(health)" 1
rm -rf "$TMP"

echo "-----"; echo "PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
