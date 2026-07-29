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

# stub gh: aggregate sha + search (no existing announcement) + record `issue create`.
# The two objective-candidate queries are distinguished the way the real ones differ — the LABEL query
# carries `--label`, the fuzzy TITLE query carries `in:title` — so a fixture can serve each independently
# and the shell-side strict-prefix filter is genuinely exercised. Both answer TSV `<n>\t<title>\t<labels>`.
# order.log records create/close INTERLEAVED, so the test can assert WHICH HAPPENED FIRST.
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"branches/main"*)  printf '%s' "\${FAKE_SHA:-$SHA}" ;;
  *"search/issues"*)  cat "\${FAKE_SEARCH:-/dev/null}" 2>/dev/null ;;
  *"issue create"*)   [ "\${GH_CREATE_FAIL:-0}" = 1 ] && exit 1
                      echo "created" >> "$ROOT/created.log"; echo "create" >> "$ROOT/order.log" ;;
  *"issue close"*)    [ "\${GH_CLOSE_FAIL:-0}" = 1 ] && exit 1
                      echo "closed \$3" >> "$ROOT/closed.log"; echo "close \$3" >> "$ROOT/order.log" ;;
  *"issue list"*"in:title"*) [ "\${GH_LIST_FAIL:-0}" = 1 ] && exit 1
                      cat "\${FAKE_OBJ_TITLE:-/dev/null}" 2>/dev/null ;;
  *"issue list"*"--label"*)  [ "\${GH_LIST_FAIL:-0}" = 1 ] && exit 1
                      cat "\${FAKE_OBJ_LABEL:-/dev/null}" 2>/dev/null ;;
esac
exit 0
EOF
chmod +x "$BIN/gh"

# candidate fixtures (TSV rows exactly as `gh issue list --json number,title,labels -q … | @tsv` yields)
OBJ_ROW=$'1\tOBJECTIVE: a minimal status-page image\t'
ANN_ROW=$'9\tSHIPPED: e2e-alpha objective @ aaaaaaa\tshipped'
printf '%s\n' "$OBJ_ROW"                > "$ROOT/obj.tsv"          # the objective alone
printf '%s\n%s\n' "$ANN_ROW" "$OBJ_ROW" > "$ROOT/obj+ann.tsv"      # announcement RANKED FIRST, objective second
printf '%s\n' "$ANN_ROW"                > "$ROOT/ann-only.tsv"     # only our own announcement
printf '%s\n2\tOBJECTIVE: something else entirely\t\n' "$OBJ_ROW" > "$ROOT/two-obj.tsv"  # two genuine objectives
printf '210\tSTEP-10 scope cutover MUST gate on <sid>.objective provenance\t\n' \
                                        > "$ROOT/collateral.tsv"   # a real fedora-dev search hit

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
  : > "$ROOT/gate.log"; : > "$ROOT/created.log"; : > "$ROOT/closed.log"; : > "$ROOT/order.log"
  rm -f "$ROOT/oracle.n"
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
run ORACLE_STATUS=SHIPPED FAKE_OBJ_TITLE="$ROOT/obj.tsv"
{ announced && closed; } && ok "the ship was announced AND the objective ticket closed" || no "announced but left the objective OPEN"
grep -q '^closed 1$' "$ROOT/closed.log" && ok "closed the objective the bus reported (#1)" || no "closed the wrong issue: $(cat "$ROOT/closed.log")"

echo "== an objective found only by the intake LABEL (free-form title) is closed too =="
# bin/intake-file.sh files every objective under $INTAKE_LABEL with a free-form title, so a title rule
# alone would never close the objectives the apparatus's own front door produces.
rm -rf "$ROOT/state"
printf '4\tAdd a status endpoint\tobjective,approved\n' > "$ROOT/by-label.tsv"
run ORACLE_STATUS=SHIPPED FAKE_OBJ_LABEL="$ROOT/by-label.tsv"
grep -q '^closed 4$' "$ROOT/closed.log" && ok "closed the label-identified objective (#4)" || no "missed it: $(cat "$ROOT/closed.log")"

echo "== THE SELF-COLLISION: the actuator's OWN announcement must never be the ticket it closes =="
# `OBJECTIVE in:title` matches the word anywhere and returns RELEVANCE order, and the announcement
# (`SHIPPED: <repo> objective @ <sha>`, left OPEN) contains it. Taking `.[0]` closed the SHIP RECORD,
# logged "CLOSED objective issue #N", wrote the done-marker — and left the objective OPEN.
rm -rf "$ROOT/state"
run ORACLE_STATUS=SHIPPED FAKE_OBJ_TITLE="$ROOT/obj+ann.tsv"
grep -q '^closed 1$' "$ROOT/closed.log" && ok "closed the OBJECTIVE (#1), not the announcement" || no "closed [$(cat "$ROOT/closed.log")] — the announcement outranked the objective"
grep -q '^closed 9$' "$ROOT/closed.log" && no "CLOSED ITS OWN SHIP ANNOUNCEMENT (#9)" || ok "the announcement (#9) was never closed"
# …and the belt holds on the OTHER route too. The two filters guard different paths and neither alone is
# sufficient: the strict title prefix screens the fuzzy SEARCH, objective_pick screens whatever reaches the
# candidate list by any means (the LABEL query, which has no title rule to lean on).
rm -rf "$ROOT/state"
run ORACLE_STATUS=SHIPPED FAKE_OBJ_LABEL="$ROOT/ann-only.tsv"
{ announced && ! closed; } && ok "an announcement alone is closeable by neither route" || no "closed [$(cat "$ROOT/closed.log")]"
rm -rf "$ROOT/state"
run ORACLE_STATUS=SHIPPED FAKE_OBJ_LABEL="$ROOT/ann-only.tsv" FAKE_OBJ_TITLE="$ROOT/obj.tsv"
grep -q '^closed 1$' "$ROOT/closed.log" && ok "announcement first in the candidate list → still closes #1" || no "closed [$(cat "$ROOT/closed.log")]"

echo "== ORDER: the objective is closed BEFORE the announcement exists to collide with it =="
rm -rf "$ROOT/state"
run ORACLE_STATUS=SHIPPED FAKE_OBJ_TITLE="$ROOT/obj.tsv"
[ "$(head -1 "$ROOT/order.log")" = "close 1" ] && ok "close precedes create" || no "create-then-close: $(tr '\n' ' ' < "$ROOT/order.log")"

echo "== COLLATERAL: an unrelated ticket merely CONTAINING the word is never closed =="
# Live on fedora-dev this search returns #210 ("…<sid>.objective provenance…") — an ordinary feature
# ticket that `.[0]` would have closed with a SHIPPED comment.
rm -rf "$ROOT/state"
run ORACLE_STATUS=SHIPPED FAKE_OBJ_TITLE="$ROOT/collateral.tsv"
{ announced && ! closed && [ "$RC" = 0 ]; } && ok "a fuzzy-match-only ticket is left alone" || no "closed a bystander: $(cat "$ROOT/closed.log")"

echo "== AMBIGUOUS: two identified objectives ⇒ refuse to guess, retry (never a coin-flip close) =="
rm -rf "$ROOT/state"
run ORACLE_STATUS=SHIPPED FAKE_OBJ_TITLE="$ROOT/two-obj.tsv"
{ ! closed && [ "$RC" = 0 ]; } && ok "nothing closed, rc 0 (loop unaffected)" || no "closed one anyway: $(cat "$ROOT/closed.log")"
[ -z "$(ls "$ROOT/state" 2>/dev/null)" ] && ok "no done-marker — it retries once a human resolves it" || no "sealed the ambiguity behind a marker"
printf '%s' "$OUT" | grep -q 'AMBIGUOUS\|refusing to guess' && ok "the refusal names the candidates" || no "silent refusal: $OUT"

echo "== an UNREADABLE candidate list is not 'nothing to close' (that would lose the close) =="
rm -rf "$ROOT/state"
run ORACLE_STATUS=SHIPPED GH_LIST_FAIL=1
{ ! closed && [ "$RC" = 0 ]; } && ok "unreadable → nothing closed, rc 0" || no "acted on an unreadable list (rc=$RC)"
[ -z "$(ls "$ROOT/state" 2>/dev/null)" ] && ok "no done-marker — the close retries next tick" || no "a transient API failure permanently lost the close"

echo "== no OPEN objective to close ⇒ still a clean ship (not an error) =="
rm -rf "$ROOT/state"
run ORACLE_STATUS=SHIPPED
{ announced && ! closed && [ "$RC" = 0 ]; } && ok "nothing to close → announced, rc 0" || no "a missing objective ticket broke the ship (rc=$RC)"

echo "== a FAILED close defers the done-marker, so the next tick retries the close =="
rm -rf "$ROOT/state"
run ORACLE_STATUS=SHIPPED FAKE_OBJ_TITLE="$ROOT/obj.tsv" GH_CLOSE_FAIL=1
[ "$RC" = 0 ] && ok "failed close → rc 0 (never stalls the loop)" || no "a failed close broke the tick (rc=$RC)"
[ -z "$(ls "$ROOT/state" 2>/dev/null)" ] && ok "no done-marker written — the close retries next tick" || no "marker written despite an unclosed objective"

echo "== MUTATIONS RUN IN-SUITE: the rows above must BITE, not pass vacuously =="
# The pre-fix suite answered every `issue list` with a bare number, so the ranking and the self-collision
# were stubbed out of existence and the defect could not be seen. These restore the defect mechanically
# against the SAME fixtures and demand it reappear.
MUT="$ROOT/mut"; mkdir -p "$MUT"; MUTSUT="$MUT/ship-actuator.sh"
mutate(){ # <sed-expr> <name> → rc 0 if the copy genuinely changed
  cp "$SUT" "$MUTSUT"; sed -i "$1" "$MUTSUT"
  cmp -s "$SUT" "$MUTSUT" && { no "mutation '$2' changed nothing (VACUOUS — the row proves nothing)"; return 1; }
  return 0
}
runmut(){ : > "$ROOT/created.log"; : > "$ROOT/closed.log"; : > "$ROOT/order.log"; rm -rf "$ROOT/state"
  env PATH="$BIN:$PATH" HOME="$ROOT/home" STATE="$ROOT/state" AUTONOMY_RUNS_DIR="$ROOT/runs" \
      OBJECTIVE_STATUS="$BIN/oracle" SHIP_GATE="$BIN/gate" "$@" bash "$MUTSUT" e2e-alpha >/dev/null 2>&1; }

# M1 — restore the relevance-ranked `.[0]` pick (drop the deterministic sort AND objective_pick), against
# a candidate list where the announcement comes first, exactly as an opaque ranker may order it.
if mutate 's% sort -t".*" -k1,1n | objective_pick "\$SHIP_ANNOUNCE_LABEL"% head -1%' 'relevance .[0]'; then
  runmut ORACLE_STATUS=SHIPPED FAKE_OBJ_LABEL="$ROOT/ann-only.tsv" FAKE_OBJ_TITLE="$ROOT/obj.tsv"
  grep -q '^closed 9$' "$ROOT/closed.log" \
    && ok "M1: the ranker closes the ANNOUNCEMENT (#9) — the self-collision row discriminates" \
    || no "M1: the defect did not reappear ([$(cat "$ROOT/closed.log")]) — the collision row may be vacuous"
fi

# M2 — neutralize the strict-prefix re-check, so the fuzzy search's own results are trusted.
if mutate 's/index(\$2,p)==1/1/' 'trust the fuzzy search'; then
  runmut ORACLE_STATUS=SHIPPED FAKE_OBJ_TITLE="$ROOT/collateral.tsv"
  grep -q '^closed 210$' "$ROOT/closed.log" \
    && ok "M2: a bystander ticket (#210) is closed — the collateral row discriminates" \
    || no "M2: the defect did not reappear ([$(cat "$ROOT/closed.log")]) — the collateral row may be vacuous"
fi

echo; echo "ship-actuator: $pass passed, $fail failed"; [ "$fail" = 0 ]
