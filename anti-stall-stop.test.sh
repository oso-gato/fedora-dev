#!/usr/bin/env bash
# anti-stall-stop.test.sh — proves bin/anti-stall-stop.sh is a FAIL-OPEN nudge that can NEVER trap a
# session AND that the stop is decided by FACTS, never by the SHAPE of the message (#279): a factual
# status report carrying no check-in signature and no sentinel is the SAME stop as "want me to proceed?"
# and is blocked the same way while work remains — that adaptation is precisely how the first cut was
# routed around. Also: a declared DONE/BLOCKED is VERIFIED against the R30 ship oracle (#25), an unchecked
# standing-work-plan item is itself a fact that forbids a stop, and a BLOCKED: naming the loop's own work
# ("waiting for a gate") is refused even when the oracle is silent. Drives the REAL hook with fixture
# Stop-hook JSON on stdin + a fixture transcript .jsonl + a STUB oracle (ANTI_STALL_ORACLE), asserting
# BLOCK ({"decision":"block"} on stdout) vs ALLOW (empty stdout, exit 0). Mutations run in-suite prove the
# gates bite. No gh/network/model. `bash anti-stall-stop.test.sh` → exit 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/bin/anti-stall-stop.sh"
[ -f "$SUT" ] || { echo "FATAL: bin/anti-stall-stop.sh not found"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
SID="11111111-2222-3333-4444-555555555555"; KEY="$SID"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n       out=<<%s>> rc=%s\n' "$1" "${OUT:-}" "${RC:-?}"; }

# mktx <text> -> writes a transcript fixture whose LAST assistant message is <text>; echoes its path.
mktx(){ local f; f="$(mktemp -p "$ROOT")"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"go build it"}}' > "$f"
  python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":sys.argv[1]}]}}))' "$1" >> "$f"
  printf '%s' "$f"; }

# mkoracle <STATUS> [NEXT] [REASON] [OPEN_PLAN_ITEMS] [PLAN_ISSUE] -> an executable stub oracle emitting
# that STATUS block (the ANTI_STALL_ORACLE seam). Ignores args; the hook calls it `bash <stub> --status`.
mkoracle(){ local f; f="$(mktemp -p "$ROOT")"
  { echo '#!/usr/bin/env bash'
    printf "printf 'STATUS: %%s\\\\n' %q\n" "$1"
    [ -n "${2:-}" ] && printf "printf 'NEXT: %%s\\\\n' %q\n" "$2"
    printf "printf 'REASON: %%s\\\\n' %q\n" "${3:-test-reason}"
    printf "printf 'OPEN_PLAN_ITEMS: %%s\\\\n' %q\n" "${4:-0}"
    [ -n "${5:-}" ] && printf "printf 'PLAN_ISSUE: %%s\\\\n' %q\n" "$5"
  } > "$f"; chmod +x "$f"; printf '%s' "$f"; }

# run <transcript> [env=val...] : pipe a Stop-hook payload; capture stdout+rc. FD_INTERACTIVE is SCRUBBED
# from the inherited env (this suite runs INSIDE an FD_INTERACTIVE=1 box) so only rows that pass it are
# interactive; a later assignment in "$@" still wins over the -u.
run(){ local tx="$1"; shift
  local sd; sd="$(mktemp -d -p "$ROOT")"
  OUT="$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":%s}' "$SID" "$tx" "${SHA:-false}" \
        | env -u FD_INTERACTIVE ANTI_STALL_STATE_DIR="${STATE_OVERRIDE:-$sd}" "$@" bash "$SUT" 2>/dev/null)"; RC=$?
}
blocked(){ printf '%s' "$OUT" | grep -q '"decision": "block"'; }
allowed(){ [ -z "$OUT" ] && [ "$RC" = 0 ]; }
reason_has(){ printf '%s' "$OUT" | grep -q "$1"; }

OPEN_ORACLE="$(mkoracle OPEN 'drive PR #233: read its host live-gate verdict' 'open PRs remain')"
SHIP_ORACLE="$(mkoracle SHIPPED '' 'the whole objective is shipped')"
INDET_ORACLE="$(mkoracle INDETERMINATE '' 'no bound objective')"
# a SHIPPED ship-verdict whose standing work plan still carries unchecked [ ]/[~] items (#279 rule 1)
PLAN_ORACLE="$(mkoracle SHIPPED '' 'the whole objective is shipped' 4 274)"

echo "== --selftest (the pure decision core) =="
# assert the SELFTEST RAN (its own summary line), not merely that the script exited 0 — a script with no
# --selftest at all would silently satisfy a bare rc check, and CI's selftest sweep would report a pass.
SELF="$(bash "$SUT" --selftest 2>/dev/null </dev/null)"; SRC=$?
{ [ "$SRC" = 0 ] && printf '%s' "$SELF" | grep -q 'anti-stall-stop selftest: .* 0 failed'; } \
  && ok "pure-core selftest runs and passes" || no "pure-core selftest missing or FAILED"

echo "== an interactive check-in stall (no sentinel) → BLOCK (signature path) =="
run "$(mktx 'I built the parser. Want me to proceed with the next step?')" FD_INTERACTIVE=1 ANTI_STALL_ORACLE=/nonexistent
{ blocked && [ "$RC" = 0 ]; } && ok "stall blocks with a continue nudge" || no "stall did not block"

echo "== DONE + oracle SHIPPED → ALLOW (a genuine ship is honoured) =="
run "$(mktx 'All shipped and proven live.
DONE: durable fix merged and deployed.')" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$SHIP_ORACLE"
allowed && ok "DONE+SHIPPED allows" || no "DONE+SHIPPED did not allow"

echo "== DONE + oracle OPEN → BLOCK (FALSE-DONE — the load-bearing new behaviour) =="
run "$(mktx 'I pushed the PR; the host will validate it.
DONE: my tier is finished.')" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$OPEN_ORACLE"
{ blocked && reason_has 'drive PR #233'; } && ok "false-DONE blocks with the drive action" || no "false-DONE was not blocked/steered"

echo "== BLOCKED + oracle OPEN → BLOCK (FALSE-BLOCKED — the tier excuse) =="
run "$(mktx 'This needs the host to run the live-gate.
BLOCKED: the host must validate this candidate.')" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$OPEN_ORACLE"
{ blocked && reason_has 'live-validate'; } && ok "false-BLOCKED (tier) blocks" || no "false-BLOCKED was not blocked"

echo "== BLOCKED + oracle INDETERMINATE → ALLOW (a genuine decision the oracle cannot contradict) =="
run "$(mktx 'A real fork only you can call.
BLOCKED: drop VNC for grd, or keep both?')" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$INDET_ORACLE"
allowed && ok "BLOCKED+INDETERMINATE allows" || no "BLOCKED+INDETERMINATE did not allow"

echo "== DONE + oracle INDETERMINATE → ALLOW (fail-open on the oracle's silence) =="
run "$(mktx 'Wrapped up.
DONE: objective met.')" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$INDET_ORACLE"
allowed && ok "DONE+INDETERMINATE allows" || no "DONE+INDETERMINATE did not allow"

echo "== DONE + oracle UNAVAILABLE (missing binary) → ALLOW (fail-open; never trap on infra) =="
run "$(mktx 'Wrapped up.
DONE: objective met.')" FD_INTERACTIVE=1 ANTI_STALL_ORACLE=/nonexistent/oracle
allowed && ok "DONE+unavailable-oracle allows" || no "DONE+unavailable did not allow"

echo "== #279 THE LOAD-BEARING ROW: a FACTUAL STATUS REPORT (no signature, no sentinel) + work remains =="
echo "==             → BLOCK. The first cut allowed exactly this, and the model routed around it. =="
run "$(mktx 'The build is green; the digest is sha256:abc and the container is healthy. PR #233 is pushed and the poller has it.')" \
    FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$OPEN_ORACLE"
{ blocked && reason_has 'Wording is not what decides this' && reason_has 'drive PR #233'; } \
  && ok "an unworded stop blocks on the FACT, with the drive action" \
  || no "a status report escaped the gate — the #279 defect is back"

echo "== the SAME report, oracle INDETERMINATE → ALLOW (fail-open: silence never traps) =="
run "$(mktx 'The build is green; the digest is sha256:abc and the container is healthy.')" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$INDET_ORACLE"
allowed && ok "silent oracle + plain answer allows" || no "a plain answer was nudged on an oracle that said nothing"

echo "== the SAME report, oracle UNAVAILABLE → ALLOW (fail-open on infra) =="
run "$(mktx 'The build is green; the digest is sha256:abc and the container is healthy.')" FD_INTERACTIVE=1 ANTI_STALL_ORACLE=/nonexistent/oracle
allowed && ok "unavailable oracle + plain answer allows" || no "an unavailable oracle wrongly nudged"

echo "== #279 rule 1: ship-verdict SHIPPED but the standing work plan has [ ] items → BLOCK =="
run "$(mktx 'Everything I picked up is merged and deployed.')" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$PLAN_ORACLE"
{ blocked && reason_has 'standing work plan' && reason_has '#274'; } \
  && ok "an unchecked plan item blocks the stop and names the plan" || no "unchecked plan items did not block"

echo "== #279 rule 1: a DONE: over the same unchecked plan → BLOCK (the sentinel is not the authority) =="
run "$(mktx 'Wrapped up.
DONE: everything I picked up shipped.')" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$PLAN_ORACLE"
{ blocked && reason_has 'declared DONE'; } && ok "false-DONE over an open plan blocks" || no "false-DONE over an open plan escaped"

echo "== #279 rule 2: BLOCKED: naming the LOOP'S OWN WORK → BLOCK even when the oracle is SILENT =="
run "$(mktx 'Pushed it.
BLOCKED: waiting for the host live-gate to post its verdict.')" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$INDET_ORACLE"
{ blocked && reason_has 'does not name a maintainer DECISION'; } \
  && ok "\"waiting for a gate\" is refused as a blocker" || no "a non-decision blocker was honoured"

echo "== #279 rule 2: \"letting the queue drain\" is likewise not a blocker =="
run "$(mktx 'Six PRs are open.
BLOCKED: letting the merge queue drain before I continue.')" FD_INTERACTIVE=1 ANTI_STALL_ORACLE=/nonexistent/oracle
blocked && ok "\"letting the queue drain\" is refused" || no "queue-drain was honoured as a blocker"

echo "== a GENUINE maintainer decision is still honoured on a silent oracle (no over-blocking) =="
run "$(mktx 'A real fork.
BLOCKED: ship unsigned images, or add cosign back first?')" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$INDET_ORACLE"
allowed && ok "a named decision still stops the session" || no "a genuine decision was wrongly blocked"

echo "== END-TO-END: the REAL hook against the REAL oracle (no stub between them) → the plan tooth bites =="
# BP9 "validate at the REAL execution boundary": every row above stubs the oracle, so none of them would
# notice the hook and the oracle disagreeing about the KV grammar. Here the REAL bin/objective-status.sh
# runs against a minimal gh stub whose ONLY content is an open work plan: with no backlog and no PRs the
# oracle calls its own ship verdict INDETERMINATE, so the plan fact is the one thing that can block.
E2E="$ROOT/e2e"; mkdir -p "$E2E/bin"
cat > "$E2E/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"in:title"*) printf '@@PLAN 274 STANDING WORK PLAN — enterprise autonomous loop\n- [x] STEP 1\n- [ ] STEP 4\n- [~] STEP 5\n' ;;
  *) : ;;                       # empty backlog, empty PR list, no ship-gate comment
esac
exit 0
STUB
chmod +x "$E2E/bin/gh"
run "$(mktx 'Status: STEP 3 merged and deployed.')" FD_INTERACTIVE=1 \
    ANTI_STALL_ORACLE="$HERE/bin/objective-status.sh" OBJECTIVE_REPO=fedora-dev PATH="$E2E/bin:$PATH"
{ blocked && reason_has 'standing work plan' && reason_has '#274'; } \
  && ok "hook + oracle agree end-to-end: 2 unchecked plan items block the stop" \
  || no "the real hook and the real oracle disagree (KV contract drift)"

echo "== over-CAP with an UNDECLARED stop + work remaining → ALLOW (the bound covers the new path too) =="
SDu="$(mktemp -d -p "$ROOT")"; printf '3 %s\n' "$(date +%s)" > "$SDu/$KEY.nudge"
STATE_OVERRIDE="$SDu" run "$(mktx 'Status: the build is green and PR #233 is open.')" \
    FD_INTERACTIVE=1 ANTI_STALL_CAP=3 ANTI_STALL_ORACLE="$OPEN_ORACLE"
allowed && ok "over-CAP releases the undeclared block — no trap" || no "the undeclared path can TRAP a session"

echo "== FD_INTERACTIVE unset (headless claude -p) → ALLOW (never touch bounded headless runs) =="
run "$(mktx 'I built the parser. Want me to proceed?')" ANTI_STALL_ORACLE="$OPEN_ORACLE"
allowed && ok "headless (no FD_INTERACTIVE) allows" || no "headless run was nudged"

echo "== stop_hook_active=true → ALLOW (belt anti-trap: already in a hook continuation) =="
SHA=true run "$(mktx 'I built it. Should I continue?')" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$OPEN_ORACLE"; SHA=
allowed && ok "stop_hook_active allows" || no "stop_hook_active did not allow"

echo "== over-CAP with a FALSE-DONE+OPEN → ALLOW (anti-trap bounds the ORACLE block too) =="
SDc="$(mktemp -d -p "$ROOT")"; printf '3 %s\n' "$(date +%s)" > "$SDc/$KEY.nudge"
STATE_OVERRIDE="$SDc" run "$(mktx 'still going.
DONE: tier finished.')" FD_INTERACTIVE=1 ANTI_STALL_CAP=3 ANTI_STALL_ORACLE="$OPEN_ORACLE"
allowed && ok "over-CAP allows even a verified false-DONE (bound reached — no trap)" || no "over-CAP oracle block did not release — TRAP RISK"

echo "== a stale streak (older than WINDOW) is treated FRESH → BLOCK =="
SD3="$(mktemp -d -p "$ROOT")"; printf '3 100\n' > "$SD3/$KEY.nudge"   # last_ts=100 (ancient)
STATE_OVERRIDE="$SD3" run "$(mktx 'Back again. Want me to proceed?')" FD_INTERACTIVE=1 ANTI_STALL_CAP=3 ANTI_STALL_WINDOW=600 ANTI_STALL_ORACLE=/nonexistent
blocked && ok "stale streak resets and blocks a fresh stall" || no "stale streak did not reset"

echo "== malformed stdin JSON → ALLOW (fail-open) =="
OUT="$(printf 'not json at all' | env -u FD_INTERACTIVE ANTI_STALL_STATE_DIR="$ROOT/s" FD_INTERACTIVE=1 bash "$SUT" 2>/dev/null)"; RC=$?
allowed && ok "malformed stdin allows" || no "malformed stdin did not allow"

echo "== missing transcript → ALLOW (fail-open) =="
run "$ROOT/does-not-exist.jsonl" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$OPEN_ORACLE"
allowed && ok "missing transcript allows" || no "missing transcript did not allow"

echo "== MUTATION: neutralize the CAP bound → an over-CAP session now BLOCKS (proves the bound allows) =="
MUT="$ROOT/mut-cap.sh"; sed 's/if \[ "\$cnt" -ge "\$CAP" \]; then/if false; then/' "$SUT" > "$MUT"; chmod +x "$MUT"
if ! cmp -s "$SUT" "$MUT"; then
  SDm="$(mktemp -d -p "$ROOT")"; printf '3 %s\n' "$(date +%s)" > "$SDm/$KEY.nudge"
  OUT="$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$SID" "$(mktx 'Want me to proceed?')" \
        | env -u FD_INTERACTIVE ANTI_STALL_STATE_DIR="$SDm" FD_INTERACTIVE=1 ANTI_STALL_CAP=3 ANTI_STALL_ORACLE=/nonexistent bash "$MUT" 2>/dev/null)"; RC=$?
  blocked && ok "mutant blocks over-CAP ⇒ the real bound row discriminates" || no "cap-mutation vacuous"
else no "cap mutation VACUOUS (sed changed nothing)"; fi

echo "== MUTATION: neutralize the oracle-OPEN check → a verified false-DONE now ALLOWS (proves the oracle blocks) =="
MUT2="$ROOT/mut-oracle.sh"; sed 's/^\[ "\$OS_STATUS" = OPEN \] && WORK=open$/false \&\& WORK=open/' "$SUT" > "$MUT2"; chmod +x "$MUT2"
if ! cmp -s "$SUT" "$MUT2"; then
  OUT="$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$SID" "$(mktx 'pushed it.
DONE: tier finished.')" | env -u FD_INTERACTIVE ANTI_STALL_STATE_DIR="$ROOT/s2" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$OPEN_ORACLE" bash "$MUT2" 2>/dev/null)"; RC=$?
  allowed && ok "mutant allows a false-DONE ⇒ the real oracle-OPEN check is what blocks" || no "oracle-verification mutation vacuous"
else no "oracle mutation VACUOUS (sed changed nothing)"; fi

echo "== MUTATION (#279): neutralize the UNDECLARED arm → a factual status report ALLOWS again =="
MUT4="$ROOT/mut-undeclared.sh"; sed "s/^      \*)       printf 'oracle-UNDECLARED';;.*$/      *)       return;;/" "$SUT" > "$MUT4"; chmod +x "$MUT4"
if ! cmp -s "$SUT" "$MUT4"; then
  OUT="$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$SID" \
        "$(mktx 'The build is green; the digest is sha256:abc and the container is healthy.')" \
        | env -u FD_INTERACTIVE ANTI_STALL_STATE_DIR="$ROOT/s4" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$OPEN_ORACLE" bash "$MUT4" 2>/dev/null)"; RC=$?
  allowed && ok "mutant allows the unworded stop ⇒ the UNDECLARED arm is what closes the #279 hole" || no "UNDECLARED mutation vacuous"
else no "UNDECLARED mutation VACUOUS (sed changed nothing)"; fi

echo "== MUTATION (#279 rule 1): neutralize the work-plan tooth → an open plan no longer blocks =="
MUT5="$ROOT/mut-plan.sh"; sed 's/^  case "\$OS_PLAN" in .*WORK=plan;; esac$/  :/' "$SUT" > "$MUT5"; chmod +x "$MUT5"
if ! cmp -s "$SUT" "$MUT5"; then
  OUT="$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$SID" \
        "$(mktx 'Everything I picked up is merged and deployed.')" \
        | env -u FD_INTERACTIVE ANTI_STALL_STATE_DIR="$ROOT/s5" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$PLAN_ORACLE" bash "$MUT5" 2>/dev/null)"; RC=$?
  allowed && ok "mutant allows over an open plan ⇒ the plan fact is what blocks" || no "work-plan mutation vacuous"
else no "work-plan mutation VACUOUS (sed changed nothing)"; fi

echo "== MUTATION (#279 rule 2): make every blocker a decision → \"waiting for a gate\" is honoured =="
MUT6="$ROOT/mut-blocker.sh"; sed 's/^  printf .%s. "\$t" | grep -qE "\$NONDECISION_RE" && { printf 0; return; }$/  :/' "$SUT" > "$MUT6"; chmod +x "$MUT6"
if ! cmp -s "$SUT" "$MUT6"; then
  OUT="$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$SID" "$(mktx 'Pushed it.
BLOCKED: waiting for the host live-gate to post its verdict.')" \
        | env -u FD_INTERACTIVE ANTI_STALL_STATE_DIR="$ROOT/s6" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$INDET_ORACLE" bash "$MUT6" 2>/dev/null)"; RC=$?
  allowed && ok "mutant honours a non-decision blocker ⇒ the classifier is what refuses it" || no "blocker-classifier mutation vacuous"
else no "blocker-classifier mutation VACUOUS (sed changed nothing)"; fi

echo "== MUTATION: neutralize DONE detection → the DONE-specific steer is lost (routes as UNDECLARED) =="
MUT3="$ROOT/mut-decl.sh"; sed "s/grep -qE '\^\[\[:space:\]\]\*DONE:' && DECL=DONE/grep -qE 'ZZZ_NEVER' \&\& DECL=DONE/" "$SUT" > "$MUT3"; chmod +x "$MUT3"
if ! cmp -s "$SUT" "$MUT3"; then
  # BOTH block — the FACT decides either way, which IS #279. The discriminator is which reason is fed back.
  OUT="$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$SID" "$(mktx 'pushed it.
DONE: tier finished.')" | env -u FD_INTERACTIVE ANTI_STALL_STATE_DIR="$ROOT/s3" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$OPEN_ORACLE" bash "$MUT3" 2>/dev/null)"; RC=$?
  { blocked && ! reason_has 'declared DONE'; } \
    && ok "mutant loses the DONE-specific steer ⇒ the real detection routes DONE to its own verdict" \
    || no "DONE-detection mutation vacuous"
else no "DONE-detection mutation VACUOUS (sed changed nothing)"; fi

echo; echo "anti-stall-stop: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
