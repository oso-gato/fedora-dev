#!/usr/bin/env bash
# ship-actuator.test.sh — drives the REAL bin/ship-actuator.sh (R40) with a stubbed R30 oracle, a
# stubbed R34 gate and a stubbed gh. No network / no model. bash ship-actuator.test.sh → exit 0.
#
# Proves the actuator: runs the gate ONLY when the gate is the last missing piece; announces ONCE per
# shipped aggregate; leaves the objective OPEN on a RETURN (the gate sends it back); and — the property
# that matters most under R39 — NEVER blocks or fails the loop, whatever breaks underneath it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/bin/ship-actuator.sh"
[ -f "$SUT" ] || { echo "FATAL: bin/ship-actuator.sh not found"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

SHA=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee

# stub gh: aggregate sha + search (no existing announcement) + record `issue create`
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"branches/main"*)  printf '%s' "\${FAKE_SHA:-$SHA}" ;;
  *"search/issues"*)  cat "\${FAKE_SEARCH:-/dev/null}" 2>/dev/null ;;
  *"issue create"*)   [ "\${GH_CREATE_FAIL:-0}" = 1 ] && exit 1; echo "created" >> "$ROOT/created.log" ;;
  *"issue close"*)    [ "\${GH_CLOSE_FAIL:-0}" = 1 ] && exit 1; echo "closed \$3" >> "$ROOT/closed.log" ;;
  *"issue list"*)     printf '%s' "\${FAKE_OBJECTIVE:-}" ;;   # the OPEN objective issue number, if any
esac
exit 0
EOF
chmod +x "$BIN/gh"

# stub oracle: emits the KV block from \$ORACLE_STATUS/\$ORACLE_DRIVABLE/\$ORACLE_SG; flips to SHIPPED
# on the SECOND read when \$ORACLE_FLIP=1 (models a PASS landing between the two reads).
cat > "$BIN/oracle" <<EOF
#!/usr/bin/env bash
n=\$(cat "$ROOT/oracle.n" 2>/dev/null || echo 0); echo \$((n+1)) > "$ROOT/oracle.n"
[ "\${ORACLE_UNREADABLE:-0}" = 1 ] && exit 1
st="\${ORACLE_STATUS:-OPEN}"
[ "\${ORACLE_FLIP:-0}" = 1 ] && [ "\$n" -ge 1 ] && st=SHIPPED
printf 'STATUS: %s\nREPO: e2e-alpha\nDRIVABLE: %s\nPROBE: ABSENT\nSHIP_GATE: %s\nREASON: t\n' \\
  "\$st" "\${ORACLE_DRIVABLE:-0}" "\${ORACLE_SG:-PENDING}"
EOF
chmod +x "$BIN/oracle"

# stub gate: records that it RAN; exits \$GATE_RC
cat > "$BIN/gate" <<EOF
#!/usr/bin/env bash
echo "gate-ran \$*" >> "$ROOT/gate.log"; exit "\${GATE_RC:-0}"
EOF
chmod +x "$BIN/gate"

run(){ # extra env…
  : > "$ROOT/gate.log"; : > "$ROOT/created.log"; : > "$ROOT/closed.log"; rm -f "$ROOT/oracle.n"
  OUT="$(env PATH="$BIN:$PATH" HOME="$ROOT/home" STATE="$ROOT/state" AUTONOMY_RUNS_DIR="$ROOT/runs" \
      OBJECTIVE_STATUS="$BIN/oracle" SHIP_GATE="$BIN/gate" "$@" bash "$SUT" e2e-alpha 2>&1)"; RC=$?
}
ran(){ [ -s "$ROOT/gate.log" ]; }
announced(){ [ -s "$ROOT/created.log" ]; }

echo "== pure core =="
bash "$SUT" --selftest >/dev/null 2>&1 && ok "--selftest exits 0" || no "pure-core selftest failed"

echo "== drivable work remains ⇒ WAIT: the gate must NOT run (it costs a model run) =="
run ORACLE_STATUS=OPEN ORACLE_DRIVABLE=3 ORACLE_SG=PENDING
{ ! ran && ! announced && [ "$RC" = 0 ]; } && ok "drivable work → no gate, no announce, rc 0" || no "acted while work remained (rc=$RC)"

echo "== backlog empty + gate PENDING ⇒ RUN the R34 gate =="
run ORACLE_STATUS=OPEN ORACLE_DRIVABLE=0 ORACLE_SG=PENDING
ran && ok "the gate was invoked (--post)" || no "the gate was NOT invoked when it was the last missing piece"
grep -q -- '--post e2e-alpha' "$ROOT/gate.log" && ok "invoked as '--post <repo>'" || no "wrong gate invocation: $(cat "$ROOT/gate.log")"

echo "== gate RETURNs (oracle still OPEN) ⇒ objective stays OPEN, nothing announced =="
run ORACLE_STATUS=OPEN ORACLE_DRIVABLE=0 ORACLE_SG=PENDING GATE_RC=0
{ ran && ! announced && [ "$RC" = 0 ]; } && ok "RETURN → no announcement, loop continues (R34 sends it back)" || no "announced despite no PASS"

echo "== gate PASSes (oracle flips to SHIPPED) ⇒ ANNOUNCE the ship, once =="
run ORACLE_STATUS=OPEN ORACLE_DRIVABLE=0 ORACLE_SG=PENDING ORACLE_FLIP=1
{ ran && announced; } && ok "gate ran and the ship was ANNOUNCED on the bus" || no "PASS did not produce an announcement"
[ -n "$(ls "$ROOT/runs" 2>/dev/null)" ] && ok "a dated ledger entry was written" || no "no ledger entry"

echo "== IDEMPOTENT: a re-tick on the same shipped aggregate is silent =="
OUT="$(env PATH="$BIN:$PATH" HOME="$ROOT/home" STATE="$ROOT/state" AUTONOMY_RUNS_DIR="$ROOT/runs" \
    OBJECTIVE_STATUS="$BIN/oracle" SHIP_GATE="$BIN/gate" ORACLE_STATUS=SHIPPED bash "$SUT" e2e-alpha 2>&1)"
[ "$(grep -c created "$ROOT/created.log")" = 1 ] && ok "second tick did NOT re-announce (marker-gated)" || no "re-announced the same aggregate"

echo "== R39 FAIL-SAFE: nothing underneath can stall or fail the loop =="
run ORACLE_UNREADABLE=1
{ [ "$RC" = 0 ] && ! ran; } && ok "unreadable oracle → rc 0, no action" || no "unreadable oracle broke the tick (rc=$RC)"
run ORACLE_STATUS=OPEN ORACLE_DRIVABLE=0 ORACLE_SG=PENDING GATE_RC=3
{ [ "$RC" = 0 ] && ! announced; } && ok "gate infra-failure (rc 3) → rc 0, nothing announced, retries next tick" || no "a failed gate broke the tick (rc=$RC)"
run ORACLE_STATUS=SHIPPED GH_CREATE_FAIL=1
{ [ "$RC" = 0 ]; } && ok "failed announce → rc 0 (no marker, so it retries)" || no "a failed announce broke the tick (rc=$RC)"
run ORACLE_STATUS=SHIPPED GH_CREATE_FAIL=1
announced && no "marker was written despite a failed post (the ship would be lost)" || ok "no marker on failure — the announcement is not lost"

echo "== the OBJECTIVE TICKET is CLOSED, not merely announced =="
# Announcing a ship while the objective issue stays open leaves the bus carrying a SHIPPED notice and an
# open objective at once — and the open ticket is what a reader believes.
closed(){ [ -s "$ROOT/closed.log" ]; }
rm -rf "$ROOT/state"
run ORACLE_STATUS=SHIPPED FAKE_OBJECTIVE=1
{ announced && closed; } && ok "the ship was announced AND the objective ticket closed" || no "announced but left the objective OPEN"
grep -q '^closed 1$' "$ROOT/closed.log" && ok "closed the objective the bus reported (#1)" || no "closed the wrong issue: $(cat "$ROOT/closed.log")"

echo "== no OPEN objective to close ⇒ still a clean ship (not an error) =="
rm -rf "$ROOT/state"
run ORACLE_STATUS=SHIPPED
{ announced && ! closed && [ "$RC" = 0 ]; } && ok "nothing to close → announced, rc 0" || no "a missing objective ticket broke the ship (rc=$RC)"

echo "== a FAILED close defers the done-marker, so the next tick retries the close =="
rm -rf "$ROOT/state"
run ORACLE_STATUS=SHIPPED FAKE_OBJECTIVE=1 GH_CLOSE_FAIL=1
[ "$RC" = 0 ] && ok "failed close → rc 0 (never stalls the loop)" || no "a failed close broke the tick (rc=$RC)"
[ -z "$(ls "$ROOT/state" 2>/dev/null)" ] && ok "no done-marker written — the close retries next tick" || no "marker written despite an unclosed objective"

echo; echo "ship-actuator: $pass passed, $fail failed"; [ "$fail" = 0 ]
