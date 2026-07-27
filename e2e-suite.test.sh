#!/usr/bin/env bash
# e2e-suite.test.sh — drives the REAL bin/e2e-suite.sh: the pure core (--selftest), the faithful-offline
# iso drill (real session-registry.sh), the anti-theater PARTIAL fold, the honest ledger, the live
# audit path (stub gh), and a MUTATION proving actor_class is load-bearing. No network/model.
# bash e2e-suite.test.sh → exit 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/bin/e2e-suite.sh"
[ -f "$SUT" ] || { echo "FATAL: bin/e2e-suite.sh not found"; exit 2; }
[ -x "$HERE/bin/session-registry.sh" ] || { echo "FATAL: bin/session-registry.sh needed for the iso drill"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

echo "== pure core (--selftest) =="
bash "$SUT" --selftest >/dev/null 2>&1 && ok "e2e-suite --selftest exits 0" || no "pure-core selftest FAILED"

echo "== iso fires GREEN faithful-offline against the REAL session-registry.sh =="
out="$(bash "$SUT" iso 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'GREEN'; } && ok "iso → GREEN, rc 0 (isolation primitive on the real registry)" || no "iso not GREEN (rc=$rc): $out"

echo "== ANTI-THEATER: all → overall PARTIAL (NOT GREEN); staged scenarios block the arm-gate =="
d="$(mktemp -d)"; out="$(AUTONOMY_RUNS_DIR="$d" bash "$SUT" all 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'overall: PARTIAL'; } && ok "all → overall PARTIAL, rc 0 (never masquerades as 5/5 GREEN)" || no "all not PARTIAL (rc=$rc)"
bash "$SUT" guard a >/dev/null 2>&1; [ "$?" = 1 ] && ok "guard a (STAGED) blocks the arm — rc 1" || no "a STAGED scenario armed"
bash "$SUT" guard iso >/dev/null 2>&1; [ "$?" = 0 ] && ok "guard iso (GREEN) arms — rc 0" || no "iso GREEN did not arm"

echo "== LEDGER: all writes a dated ledger; the interaction line is STAGED, never a fabricated count =="
lf="$(ls "$d"/e2e-*.md 2>/dev/null | head -1)"
[ -n "$lf" ] && ok "a dated ledger was written to AUTONOMY_RUNS_DIR" || no "no ledger written"
if [ -n "$lf" ]; then
  grep -q '| iso | GREEN' "$lf"                  && ok "ledger records iso GREEN"                 || no "ledger missing iso GREEN"
  grep -q 'STAGED / NOT COMPUTED' "$lf"          && ok "ledger interaction count is STAGED (anti-theater)" || no "ledger fabricated an interaction count"
  ! grep -qE 'interaction count.*:.*1.*PASS' "$lf" && ok "ledger does NOT claim a computed 1→PASS offline" || no "ledger claimed a computed pass offline"
fi

echo "== LIVE AUDIT (stub gh): 1 human + 1 App bot → 1 human EVENT → PASS; a 2nd human → FAIL =="
# stub gh: emit the -q-extracted 'login<TAB>type' lines from $GH_STREAM (the SUT applies -q; the stub
# short-circuits by emitting exactly what -q would yield).
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *"issues/comments"*) cat "${GH_STREAM:-/dev/null}" 2>/dev/null;; *) : ;; esac
exit 0
EOF
chmod +x "$BIN/gh"
printf 'oso-gato\tUser\noso-gato-nox-claudebox\tUser\n' > "$ROOT/stream1.txt"     # 1 human + 1 App bot
printf 'oso-gato\tUser\narthur2\tUser\noso-gato-nox-claudebox\tUser\n' > "$ROOT/stream2.txt"  # 2 humans + 1 App bot
GH_STREAM="$ROOT/stream1.txt" PATH="$BIN:$PATH" bash "$SUT" audit oso-gato/e2e-alpha >/dev/null 2>&1 \
  && ok "1 human event → PASS (rc 0)" || no "1-human stream did not PASS"
GH_STREAM="$ROOT/stream2.txt" PATH="$BIN:$PATH" bash "$SUT" audit oso-gato/e2e-alpha >/dev/null 2>&1 \
  && no "2-human stream wrongly PASSed" || ok "2 human events → FAIL (rc != 0)"

echo "== R37: an UNREADABLE stream is NOT a count of zero (the e2e-alpha 404 class) =="
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *"issues/comments"*) [ "${GH_UNREADABLE:-0}" = 1 ] && exit 1; cat "${GH_STREAM:-/dev/null}" 2>/dev/null;; *) : ;; esac
exit 0
EOF
chmod +x "$BIN/gh"
UN="$(GH_UNREADABLE=1 PATH="$BIN:$PATH" bash "$SUT" audit oso-gato/gone 2>&1)"; UNRC=$?
{ printf '%s' "$UN" | grep -q 'UNREADABLE' && [ "$UNRC" = 3 ]; } \
  && ok "unreadable stream → says UNREADABLE, rc 3" || no "unreadable stream not surfaced as a fault (rc=$UNRC): $UN"
printf '%s' "$UN" | grep -qE '0 human EVENT' \
  && no "an unreadable repo was reported as a ZERO COUNT — a measurement never made, presented as clean" \
  || ok "no zero-count is printed for a stream that could not be read"

echo "== MUTATION: misclassify the App login as HUMAN → the 1-human stream miscounts to 2 → FAIL =="
MUT="$ROOT/mut.sh"; sed 's/case " \$APPARATUS_LOGINS " in .*printf .APPARATUS.; return;; esac/: # mutant: App logins no longer recognized/' "$SUT" > "$MUT"
if cmp -s "$SUT" "$MUT"; then no "MUTATION vacuous (sed changed nothing)"; else
  ok "mutation neutralized actor_class's apparatus-login match"
  GH_STREAM="$ROOT/stream1.txt" PATH="$BIN:$PATH" bash "$MUT" audit oso-gato/e2e-alpha >/dev/null 2>&1 \
    && no "mutant still PASSed (actor_class not load-bearing)" || ok "mutant FAILs the 1-human stream (actor_class IS load-bearing)"
fi

echo "== DRIFT-PIN: APPARATUS_LOGINS carries all three fleet App identities =="
al="$(grep -m1 '^APPARATUS_LOGINS=' "$SUT")"
for id in DEV_LOGIN LG_HOST_LOGIN FITNESS_LOGIN; do
  printf '%s' "$al" | grep -q "\$$id" && ok "APPARATUS_LOGINS includes \$$id" || no "APPARATUS_LOGINS dropped \$$id"
done

echo; echo "e2e-suite: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
