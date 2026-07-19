#!/usr/bin/env bash
# back-pressure.test.sh — the R39 / gap-10 (fedora-dev#208) shared-resource back-pressure suite.
#
# Drives the REAL bin/back-pressure.sh end-to-end and asserts BOTH caller channels — the stdout verdict
# token AND the exit-code gate (0 ADMIT / 10 WAIT / 20 SATURATED / 2 usage) — plus the R37 SATURATION
# SIGNAL (a WAIT/SATURATED verdict is never silent: a named reason lands on stderr), plus `live-sessions`
# read from a REAL temp R27 registry with REAL backgrounded holders (the mt-foundation idiom).
#
# THE STARVATION GUARANTEE is the point: at N=2 a session AT its fair share is held (WAIT) even while its
# peer sits idle, so the peer's share is always available — no tenant starves another. At N=1 the lone
# tenant gets the WHOLE budget and only ever saturates at true exhaustion ("non-blocking now").
#
# MUTATION-CHECK (the discriminator): the WAIT decision rests entirely on the fair-share cap
# (BP-FAIRSHARE-CAP). The suite RESTORES the mutation mechanically in-suite — a copy of the script whose
# cap condition can never fire — and asserts that against the SAME fixture a session over its share now
# ADMITs instead of WAITing. So if the cap were ever removed, the WAIT rows would stop biting and this row
# would fail as vacuous. (The sed must genuinely change the copy, else the row is void.)
#
# Run:  bash back-pressure.test.sh   → exit 0 = all pass.  No GitHub / network / model.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BP="$HERE/bin/back-pressure.sh"
REG="$HERE/bin/session-registry.sh"
[ -f "$BP" ] || { echo "FATAL: bin/back-pressure.sh not found"; exit 2; }
command -v flock >/dev/null || { echo "FATAL: flock required"; exit 2; }

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# run <script> decide-args… → sets $OUT (stdout), $ERR (stderr), $RC (exit code).
run(){ local s="$1"; shift; local e; e="$(mktemp)"; OUT="$(bash "$s" "$@" 2>"$e")"; RC=$?; ERR="$(cat "$e")"; rm -f "$e"; }

# ck_decide <name> <expect-token> <expect-rc> -- <decide args…>
ck_decide(){
  local name="$1" tok="$2" rc="$3"; shift 3; [ "$1" = "--" ] && shift
  run "$BP" decide "$@"
  local first="${OUT%% *}"
  if [ "$first" = "$tok" ] && [ "$RC" = "$rc" ]; then ok "$name (→ $tok rc=$rc)"
  else bad "$name — want [$tok rc=$rc] got [${first:-<none>} rc=$RC]"; fi
}

TMP="$(mktemp -d)"; HOLDERS=""
trap 'kill $HOLDERS >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
live_holder(){ sleep 300 </dev/null >/dev/null 2>&1 & local p=$!; HOLDERS="$HOLDERS $p"; printf '%s' "$p"; }

# ===================================================================================================
echo "== rc contract + verdict token (mirrors fleet-halt.sh's 0/10/20 discipline) =="
ck_decide "N=1: empty budget"            ADMIT     0  -- 4 1 0 0
ck_decide "N=1: nearly full"             ADMIT     0  -- 4 1 3 3
ck_decide "N=1: whole budget exhausted"  SATURATED 20 -- 4 1 4 4
ck_decide "N=2: idle session, slack"     ADMIT     0  -- 4 2 0 0
ck_decide "N=2: under share, slack"      ADMIT     0  -- 4 2 2 1
ck_decide "N=2: AT fair share (peer idle → held)" WAIT 10 -- 4 2 2 2
ck_decide "N=2: global budget exhausted" SATURATED 20 -- 4 2 4 2
ck_decide "oversub N=5 b3: session at 1-unit share" WAIT 10 -- 3 5 2 1
ck_decide "oversub N=5 b3: global full"   SATURATED 20 -- 3 5 3 0
ck_decide "bad: zero budget → usage err"  ""        2  -- 0 2 0 0
ck_decide "bad: non-numeric total"        ""        2  -- 4 2 x 0

echo "== R37 saturation SIGNAL — a capped/exhausted verdict is NEVER silent (stderr carries the reason) =="
run "$BP" decide 4 2 4 2 "App REST budget"
{ printf '%s' "$ERR" | grep -qi 'SATURATED' && printf '%s' "$ERR" | grep -qi 'R37'; } \
  && ok "SATURATED emits a signal on stderr naming R37" || bad "SATURATED signal missing/incomplete: [$ERR]"
printf '%s' "$ERR" | grep -q 'App REST budget' \
  && ok "SATURATED signal names the resource label" || bad "SATURATED signal did not name the resource"
run "$BP" decide 4 2 2 2 validator
{ printf '%s' "$ERR" | grep -qi 'WAIT' && printf '%s' "$ERR" | grep -qi 'fair share'; } \
  && ok "WAIT emits a fair-share back-pressure signal on stderr" || bad "WAIT signal missing: [$ERR]"
run "$BP" decide 4 2 1 0 validator
[ -z "$ERR" ] && ok "ADMIT is silent (no needless signal on the go path)" || bad "ADMIT should not signal: [$ERR]"

echo "== fair-share (max(1, budget/n)) =="
[ "$(bash "$BP" fair-share 4 2)" = 2 ]  && ok "fair-share 4 2 = 2" || bad "fair-share 4 2 wrong"
[ "$(bash "$BP" fair-share 4 1)" = 4 ]  && ok "fair-share 4 1 = 4 (lone tenant → whole budget)" || bad "fair-share 4 1 wrong"
[ "$(bash "$BP" fair-share 3 5)" = 1 ]  && ok "fair-share 3 5 = 1 (over-subscription floor)" || bad "fair-share 3 5 wrong"
bash "$BP" fair-share 0 2 >/dev/null 2>&1 && bad "fair-share of a zero budget should error" || ok "fair-share 0 2 → usage error"

echo "== live-sessions — real R27 registry, real holders (fail-safe → 1 when empty) =="
export SCOPE_REGISTRY_DIR="$TMP/reg"
[ "$(bash "$BP" live-sessions)" = 1 ] && ok "empty registry → N=1 (fail-safe toward progress)" || bad "empty registry did not clamp to 1"
if [ -f "$REG" ]; then
  HPA="$(live_holder)"; HPB="$(live_holder)"
  SESSION_HOLDER_PID="$HPA" bash "$REG" register sidA repo-one >/dev/null
  SESSION_HOLDER_PID="$HPB" bash "$REG" register sidB repo-two >/dev/null
  [ "$(bash "$BP" live-sessions)" = 2 ] && ok "two live sessions → N=2" || bad "live-sessions did not count 2 live sessions"
  # end-to-end: a session holding its fair share of a budget-4 resource across the 2 live sessions is held
  run "$BP" decide 4 "$(bash "$BP" live-sessions)" 2 2 validator
  [ "${OUT%% *}" = WAIT ] && [ "$RC" = 10 ] && ok "compose: decide over live N=2 back-pressures a fair-share hog" || bad "compose decide wrong (${OUT%% *} rc=$RC)"
  kill "$HPA" 2>/dev/null; wait "$HPA" 2>/dev/null || true
  bash "$REG" reap >/dev/null
  [ "$(bash "$BP" live-sessions)" = 1 ] && ok "a dead holder is reaped → N back to 1" || bad "live-sessions did not drop the reaped session"
else
  bad "bin/session-registry.sh missing — cannot exercise live-sessions"
fi

# ===================================================================================================
echo "== MUTATION-CHECK: neutralizing the fair-share cap makes a fair-share hog STOP being held =="
MUT="$TMP/back-pressure.mut.sh"
cp "$BP" "$MUT"
# The WAIT decision is exactly `[ "$session" -ge "$fs" ]` (tagged BP-FAIRSHARE-CAP). Flatten it so the cap
# can never fire; a session over its share must then ADMIT instead of WAIT.
sed -i 's/if \[ "\$session" -ge "\$fs" \]; then printf '\''WAIT'\''; return; fi/if [ "$session" -ge 999999999 ]; then printf '\''WAIT'\''; return; fi/' "$MUT"
if cmp -s "$BP" "$MUT"; then
  bad "mutation: the sed changed NOTHING — this row is vacuous"
else
  ok "mutation: fair-share cap neutralized in the copy"
  run "$MUT" decide 4 2 2 2 validator            # a fair-share hog against the mutant
  [ "${OUT%% *}" = ADMIT ] && [ "$RC" = 0 ] \
    && ok "mutation: with the cap gone, the fair-share hog ADMITs (the WAIT rows bite)" \
    || bad "mutation: hog was still held (${OUT%% *} rc=$RC) — the cap is not what gates WAIT"
  # the global budget cap is independent of the fair-share cap — it must still fire on the mutant
  run "$MUT" decide 4 2 4 2 validator
  [ "${OUT%% *}" = SATURATED ] && [ "$RC" = 20 ] \
    && ok "mutation: the global SATURATED cap is independent and still fires" \
    || bad "mutation: SATURATED cap broke unexpectedly (${OUT%% *} rc=$RC)"
fi

echo
echo "back-pressure.test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
