#!/usr/bin/env bash
# mt-foundation.test.sh — the multi-session foundation suite (R3/R26/R27/R28): drives the REAL
# bin/session-registry.sh CLI as subprocesses against REAL flock, REAL /proc liveness and a TEMP
# SCOPE_REGISTRY_DIR. No GitHub / network / model — `gh` is never touched (the registry calls none).
#
# THE E2E-ISO DEMO (asserted step by step): two live sessions declare DISJOINT scopes and both stand;
# a session that reaches for a repo a LIVE peer already holds is DENIED (R28); neither session can see
# the other's scope; and when a holder DIES its repo is freed by `reap` so the once-denied claim then
# succeeds — proving liveness (not a lease/timeout) is what gates a claim.
#
# LIVENESS is REAL: each session's holder is a genuine backgrounded `sleep` whose pid is fed as
# SESSION_HOLDER_PID, so the registry records that pid's true /proc starttime; killing it makes
# ll_proc_start go empty and lock_verdict return TAKEOVER_DEAD — the exact mechanism reap keys on.
#
# MUTATION-CHECK (the F4 discriminator): step 2's deny rests ENTIRELY on the R28 overlap check in
# `register`. The suite RESTORES the mutation mechanically and runs it in-suite — a copy of the three
# libs with `overlaps` neutralized to always-disjoint — and asserts that against the SAME fixture the
# once-denied claim now SUCCEEDS. So if the overlap check were ever removed, step 2 would stop biting
# and this row would fail as vacuous. (The sed must genuinely change the copy, else the row is void.)
#
# Run:  bash bin/mt-foundation.test.sh   → exit 0 = all pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REG="$HERE/session-registry.sh"
[ -f "$REG" ] || { echo "FATAL: bin/session-registry.sh not found"; exit 2; }
command -v flock >/dev/null || { echo "FATAL: flock required"; exit 2; }

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

TMP="$(mktemp -d)"; HOLDERS=""
trap 'kill $HOLDERS >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
export SCOPE_REGISTRY_DIR="$TMP/registry"

# detach the holder's std fds — else the backgrounded sleep inherits the $(…) command-sub pipe and
# the capture blocks for the full 300 s waiting for an EOF that never comes.
live_holder(){ sleep 300 </dev/null >/dev/null 2>&1 & local p=$!; HOLDERS="$HOLDERS $p"; printf '%s' "$p"; }

# ===================================================================================================
echo "== E2E-ISO: two live sessions, disjoint scopes, a live-overlap deny, and a reap-frees-a-dead-holder =="

HPA="$(live_holder)"; HPB="$(live_holder)"

# --- step 1: two live sessions register DISJOINT scopes → both succeed ---
if SESSION_HOLDER_PID="$HPA" bash "$REG" register A fedora-desktop >/dev/null; then ok "step1: register A fedora-desktop"; else bad "step1: register A failed"; fi
if SESSION_HOLDER_PID="$HPB" bash "$REG" register B e2e-alpha    >/dev/null; then ok "step1: register B e2e-alpha";    else bad "step1: register B failed"; fi

# --- step 2: B reaches for A's repo while A is LIVE → DENIED (R28) ---
if SESSION_HOLDER_PID="$HPB" bash "$REG" register B fedora-desktop >/dev/null 2>&1; then
  bad "step2: B claimed fedora-desktop while live A holds it — R28 deny missing"
else
  ok "step2: B DENIED fedora-desktop (intersects live A)"
fi

# --- step 3: neither session sees the other's scope ---
[ "$(bash "$REG" resolve A)" = fedora-desktop ] && ok "step3: resolve A = fedora-desktop" || bad "step3: resolve A wrong ('$(bash "$REG" resolve A)')"
[ "$(bash "$REG" resolve B)" = e2e-alpha ]      && ok "step3: resolve B = e2e-alpha (deny did not mutate B)" || bad "step3: resolve B wrong ('$(bash "$REG" resolve B)')"

# --- step 4: A's holder dies → reap frees fedora-desktop → B's claim now SUCCEEDS ---
kill "$HPA" 2>/dev/null; wait "$HPA" 2>/dev/null || true
bash "$REG" reap >/dev/null
[ -z "$(bash "$REG" resolve A)" ] && ok "step4: reap released dead A's claim" || bad "step4: A's claim survived the reap"
[ "$(bash "$REG" list | wc -l)" = 1 ] && ok "step4: list shows only the surviving live session" || bad "step4: list did not drop the reaped session"
if SESSION_HOLDER_PID="$HPB" bash "$REG" register B fedora-desktop >/dev/null; then ok "step4: B now claims fedora-desktop (freed by reap)"; else bad "step4: B still denied after reap"; fi
[ "$(bash "$REG" resolve B)" = fedora-desktop ] && ok "step4: B's scope replaced with fedora-desktop" || bad "step4: B scope not replaced"

# ===================================================================================================
echo "== MUTATION-CHECK: neutralizing the R28 overlap check makes step 2 STOP biting (would-succeed) =="
# Copy the three libs so the mutant still finds its siblings, then flatten `overlaps` to always-disjoint.
MUTDIR="$TMP/mut"; mkdir -p "$MUTDIR"
cp "$HERE/lock-lib.sh" "$HERE/session-id.sh" "$HERE/session-registry.sh" "$MUTDIR/"
sed -i 's/^overlaps(){.*/overlaps(){ return 1; }/' "$MUTDIR/session-registry.sh"
if cmp -s "$HERE/session-registry.sh" "$MUTDIR/session-registry.sh"; then
  bad "mutation: the sed changed NOTHING — this row is vacuous"
else
  ok "mutation: overlaps neutralized in the copy"
  MREG="$MUTDIR/session-registry.sh"
  export SCOPE_REGISTRY_DIR="$TMP/mreg"
  HPC="$(live_holder)"
  SESSION_HOLDER_PID="$HPC" bash "$MREG" register A fedora-desktop >/dev/null
  if SESSION_HOLDER_PID="$HPC" bash "$MREG" register B fedora-desktop >/dev/null 2>&1; then
    ok "mutation: with the overlap check gone, the once-denied claim SUCCEEDS (step 2's deny bites)"
  else
    bad "mutation: the claim was still denied — the R28 check is not the thing gating step 2"
  fi
  export SCOPE_REGISTRY_DIR="$TMP/registry"
fi

echo
echo "mt-foundation: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
