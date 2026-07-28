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

echo "== a markdown code span is the natural hand-over shape and must still be caught =="
ck "backticked command is BLOCKED" \
   "$(run 'Please run:

! `gh` --version')" "BLOCK"
ck "code span wrapping the whole ask is BLOCKED" \
   "$(run 'Please run:

`! gh --version`')" "BLOCK"

echo "== must never block ordinary messages =="
ck "no ask at all"                 "$(run 'The loop is healthy and merging normally.')" "ALLOW"
ck "prose naming a command"        "$(run 'The gh CLI is what the poller uses to reach GitHub.')" "ALLOW"
ck "an ask that does NOT resolve here" \
   "$(run 'Please run:

! this-command-does-not-exist-anywhere --flag')" "ALLOW"
ck "an exclamation is not an ask"  "$(run 'That worked!')" "ALLOW"
# THE ROWS THAT MAKE THAT HEADING TRUE. Every one of these is a realistic turn-end message whose word
# after the exclamation resolves on this box (test/time/true/kill/echo/more all sit in /usr/bin), so a
# guard matching '! ' anywhere on the line fires on all six. The heading claimed this property; only the
# end-of-string 'That worked!' row exercised it, which is the one shape that cannot collide.
ck "exclamation then 'test'" "$(run 'All green! test coverage is at 100% and the PR is up.')" "ALLOW"
ck "exclamation then 'time'" "$(run 'Fixed and merged! time to move on to the next issue.')" "ALLOW"
ck "exclamation then 'true'" "$(run 'It works! true to the original design, nothing else changed.')" "ALLOW"
ck "exclamation then 'kill'" "$(run 'Nice catch! kill the branch when you get a chance.')" "ALLOW"
ck "exclamation then 'echo'" "$(run 'Deployed! echo of the old behaviour is gone now.')" "ALLOW"
ck "exclamation then 'more'" "$(run 'Shipped it! more detail in the PR body.')" "ALLOW"

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

echo "== MUTATION RUN IN-SUITE — prove the LINE-START ANCHOR is what spares prose =="
# Mechanically restore the un-anchored match ('! ' anywhere on the line) on a COPY and re-run the same
# prose message through it. If it does not BLOCK, the ALLOW rows above are passing for some other reason
# and this suite is not testing the discrimination it claims to.
MUT="$TMP/mutant.sh"
sed -e "s/^      '! '\*) : ;;/      *'! '*) : ;;/" \
    -e "s/local rest=\"\${line#'! '}\"/local rest=\"\${line#*'! '}\"/" "$GUARD" > "$MUT"
if cmp -s "$GUARD" "$MUT"; then
  f=$((f+1)); printf '  FAIL mutation is VACUOUS — the sed changed nothing; the anchor moved\n'
else
  mrun(){ local tr="$TMP/m$RANDOM.jsonl"
    python3 - "$tr" "$1" <<'PY'
import json,sys
open(sys.argv[1],"w",encoding="utf-8").write(json.dumps({
  "type":"assistant","message":{"content":[{"type":"text","text":sys.argv[2]}]}})+"\n")
PY
    local out; out="$(printf '{"session_id":"mut%s","transcript_path":"%s","stop_hook_active":false}' "$RANDOM" "$tr" \
          | bash "$MUT" 2>/dev/null)"
    case "$out" in *'"block"'*) printf 'BLOCK' ;; *) printf 'ALLOW' ;; esac; }
  ck "un-anchored match BLOCKS a plain status report (the defect)" \
     "$(mrun 'Nice catch! kill the branch when you get a chance.')" "BLOCK"
  ck "the anchored guard still catches the real ask" \
     "$(run 'Please run:

! gh --version')" "BLOCK"
fi

echo; echo "no-offload-guard e2e: $p passed, $f failed"; [ "$f" -eq 0 ]
