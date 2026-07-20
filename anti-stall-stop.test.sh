#!/usr/bin/env bash
# anti-stall-stop.test.sh — proves bin/anti-stall-stop.sh is a FAIL-OPEN nudge that can NEVER trap a
# session AND that a declared DONE/BLOCKED sentinel is VERIFIED against the R30 ship oracle, not honoured
# on FORM (the #25 load-bearing change). Drives the REAL hook with fixture Stop-hook JSON on stdin + a
# fixture transcript .jsonl + a STUB oracle (ANTI_STALL_ORACLE), asserting BLOCK ({"decision":"block"} on
# stdout) vs ALLOW (empty stdout, exit 0). Mutations run in-suite prove the gates bite. No gh/network/model.
# `bash anti-stall-stop.test.sh` → exit 0.
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

# mkoracle <STATUS> [NEXT] [REASON] -> an executable stub oracle emitting that STATUS block (the ANTI_STALL_
# ORACLE seam). Ignores args; the hook calls it `bash <stub> --status`.
mkoracle(){ local f; f="$(mktemp -p "$ROOT")"
  { echo '#!/usr/bin/env bash'
    printf "printf 'STATUS: %%s\\\\n' %q\n" "$1"
    [ -n "${2:-}" ] && printf "printf 'NEXT: %%s\\\\n' %q\n" "$2"
    printf "printf 'REASON: %%s\\\\n' %q\n" "${3:-test-reason}"
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

echo "== a plain answer with NO check-in signature, NO sentinel → ALLOW (never nag a normal turn) =="
run "$(mktx 'The build is green; the digest is sha256:abc and the container is healthy.')" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$OPEN_ORACLE"
allowed && ok "no-signature answer allows" || no "a plain answer was wrongly nudged"

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
MUT2="$ROOT/mut-oracle.sh"; sed 's/if \[ "\$OS_STATUS" = OPEN \]; then/if false; then/' "$SUT" > "$MUT2"; chmod +x "$MUT2"
if ! cmp -s "$SUT" "$MUT2"; then
  OUT="$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$SID" "$(mktx 'pushed it.
DONE: tier finished.')" | env -u FD_INTERACTIVE ANTI_STALL_STATE_DIR="$ROOT/s2" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$OPEN_ORACLE" bash "$MUT2" 2>/dev/null)"; RC=$?
  allowed && ok "mutant allows a false-DONE ⇒ the real oracle-OPEN check is what blocks" || no "oracle-verification mutation vacuous"
else no "oracle mutation VACUOUS (sed changed nothing)"; fi

echo "== MUTATION: neutralize DONE detection → a DONE-only false stop escapes to gate 2 and ALLOWS =="
MUT3="$ROOT/mut-decl.sh"; sed "s/grep -qE '\^\[\[:space:\]\]\*DONE:' && DECL=DONE/grep -qE 'ZZZ_NEVER' \&\& DECL=DONE/" "$SUT" > "$MUT3"; chmod +x "$MUT3"
if ! cmp -s "$SUT" "$MUT3"; then
  # a DONE-only message (no check-in signature): real → oracle OPEN → BLOCK; mutant → DECL unset → gate 2 no-signature → ALLOW
  OUT="$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$SID" "$(mktx 'pushed it.
DONE: tier finished.')" | env -u FD_INTERACTIVE ANTI_STALL_STATE_DIR="$ROOT/s3" FD_INTERACTIVE=1 ANTI_STALL_ORACLE="$OPEN_ORACLE" bash "$MUT3" 2>/dev/null)"; RC=$?
  allowed && ok "mutant allows (DONE unseen ⇒ no oracle consult) ⇒ the real DONE-detection routes to the oracle" || no "DONE-detection mutation vacuous"
else no "DONE-detection mutation VACUOUS (sed changed nothing)"; fi

echo; echo "anti-stall-stop: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
