#!/usr/bin/env bash
# no-offload-guard.test.sh — END-TO-END cover for the Stop hook: a real JSONL transcript + a real
# Stop-hook JSON payload on stdin, asserting the actual block/allow decision.
#
# The pure core is covered by `no-offload-guard.sh --selftest`. THIS covers the I/O layer, because that is
# where the behaviour really lives: does it recognise the ask, does it resolve the command on PATH, does
# it honour a named obstacle, and does it FAIL OPEN on every kind of broken input. A guard that traps a
# session is strictly worse than the bad ask it prevents, so the fail-open rows are the load-bearing ones.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
GUARD="$HERE/no-offload-guard.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export NO_OFFLOAD_STATE="$TMP/state"

p=0; f=0
ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"; else f=$((f+1)); printf '  FAIL %s want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }

# run <name> <assistant-message> [session] -> BLOCK | ALLOW
run(){
  local msg="$1" sid="${2:-s$RANDOM}" tr="$TMP/t$RANDOM.jsonl"
  python3 - "$tr" "$msg" <<'PY'
import json,sys
open(sys.argv[1],"w",encoding="utf-8").write(json.dumps({
  "type":"assistant","message":{"content":[{"type":"text","text":sys.argv[2]}]}})+"\n")
PY
  local out
  out="$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$sid" "$tr" \
        | bash "$GUARD" 2>/dev/null)"
  case "$out" in *'"block"'*) printf 'BLOCK' ;; *) printf 'ALLOW' ;; esac
}

echo "== THE 2026-07-28 FAILURE — handing over a command that is on our own PATH =="
ck "asking for a resolvable command is BLOCKED" \
   "$(run 'Run this to fix it:

! gh --version

That should sort it.')" "BLOCK"

echo "== the escape hatch: naming a concrete obstacle is ALWAYS accepted =="
ck "a named denial is ALLOWED" \
   "$(run 'I tried it myself and the classifier denied `gh`. Please run:

! gh --version')" "ALLOW"
ck "permission wording is ALLOWED" \
   "$(run 'Permission for this action was denied, so please run:

! gh --version')" "ALLOW"

echo "== must never block ordinary messages =="
ck "no ask at all"                 "$(run 'The loop is healthy and merging normally.')" "ALLOW"
ck "prose naming a command"        "$(run 'The gh CLI is what the poller uses to reach GitHub.')" "ALLOW"
ck "an ask that does NOT resolve here" \
   "$(run 'Please run:

! this-command-does-not-exist-anywhere --flag')" "ALLOW"
ck "an exclamation is not an ask"  "$(run 'That worked!')" "ALLOW"

echo "== ANTI-TRAP — a stop must always be reachable =="
sid="capped$$"
ck "1st offload blocked"  "$(run 'do it:

! gh --version' "$sid")" "BLOCK"
ck "2nd offload blocked"  "$(run 'do it:

! gh --version' "$sid")" "BLOCK"
ck "3rd hits the cap and ALLOWS" "$(run 'do it:

! gh --version' "$sid")" "ALLOW"

echo "== FAIL OPEN on every broken input (a trapped session is worse than a bad ask) =="
one(){ local out; out="$(printf '%s' "$1" | bash "$GUARD" 2>/dev/null)"; case "$out" in *'"block"'*) printf 'BLOCK';; *) printf 'ALLOW';; esac; }
ck "empty stdin"           "$(one '')" "ALLOW"
ck "not JSON"              "$(one 'this is not json at all')" "ALLOW"
ck "missing transcript"    "$(one '{"session_id":"x","transcript_path":"/nonexistent/nope.jsonl"}')" "ALLOW"
ck "stop_hook_active=true" "$(one '{"session_id":"x","transcript_path":"/etc/hostname","stop_hook_active":true}')" "ALLOW"

echo; echo "no-offload-guard e2e: $p passed, $f failed"; [ "$f" -eq 0 ]
