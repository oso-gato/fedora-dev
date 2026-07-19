#!/usr/bin/env bash
# anti-stall-stop.test.sh — proves bin/anti-stall-stop.sh (the interactive anti-stall Stop hook) is a
# STRUCTURAL nudge that is FAIL-OPEN and can NEVER trap a session. Drives the REAL hook with fixture
# Stop-hook JSON on stdin + a fixture transcript .jsonl; asserts BLOCK ({"decision":"block"} on stdout)
# vs ALLOW (empty stdout, exit 0). Two mutations run in-suite prove the safety gates bite. No gh/network/
# model. `bash anti-stall-stop.test.sh` → exit 0.
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
# python builds the JSONL so newlines/quotes in <text> are encoded correctly.
mktx(){ local f; f="$(mktemp -p "$ROOT")"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"go build it"}}' > "$f"
  python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":sys.argv[1]}]}}))' "$1" >> "$f"
  printf '%s' "$f"; }

# run <transcript> [env=val...] : pipe a Stop-hook payload; capture stdout+rc
run(){ local tx="$1"; shift
  local sd; sd="$(mktemp -d -p "$ROOT")"
  OUT="$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":%s}' "$SID" "$tx" "${SHA:-false}" \
        | env ANTI_STALL_STATE_DIR="${STATE_OVERRIDE:-$sd}" "$@" bash "$SUT" 2>/dev/null)"; RC=$?
}
blocked(){ printf '%s' "$OUT" | grep -q '"decision": "block"'; }
allowed(){ [ -z "$OUT" ] && [ "$RC" = 0 ]; }

echo "== an interactive check-in stall → BLOCK =="
run "$(mktx 'I built the parser. Want me to proceed with the next step?')" FD_INTERACTIVE=1
{ blocked && [ "$RC" = 0 ]; } && ok "stall blocks with a continue nudge" || no "stall did not block"

echo "== a DONE sentinel → ALLOW (deliberate stop) =="
run "$(mktx 'All shipped and validated.
DONE: dedup fix merged and proven on real /proc.')" FD_INTERACTIVE=1
allowed && ok "DONE sentinel allows" || no "DONE sentinel did not allow"

echo "== a BLOCKED sentinel → ALLOW (a genuine decision surfaces) =="
run "$(mktx 'This needs your call.
BLOCKED: drop VNC for grd, or keep both?')" FD_INTERACTIVE=1
allowed && ok "BLOCKED sentinel allows" || no "BLOCKED sentinel did not allow"

echo "== a plain answer with NO check-in signature → ALLOW (never nag a normal turn) =="
run "$(mktx 'The build is green; the digest is sha256:abc and the container is healthy.')" FD_INTERACTIVE=1
allowed && ok "no-signature answer allows" || no "a plain answer was wrongly nudged"

echo "== FD_INTERACTIVE unset (headless claude -p) → ALLOW (never touch bounded headless runs) =="
run "$(mktx 'I built the parser. Want me to proceed?')"
allowed && ok "headless (no FD_INTERACTIVE) allows" || no "headless run was nudged"

echo "== stop_hook_active=true → ALLOW (belt anti-trap: already in a hook continuation) =="
SHA=true run "$(mktx 'I built it. Should I continue?')" FD_INTERACTIVE=1; SHA=
allowed && ok "stop_hook_active allows" || no "stop_hook_active did not allow"

echo "== windowed counter ≥ CAP → ALLOW (anti-trap bound; can never trap) =="
SD2="$(mktemp -d -p "$ROOT")"; printf '3 %s\n' "$(date +%s)" > "$SD2/$KEY.nudge"
STATE_OVERRIDE="$SD2" run "$(mktx 'Still here. Want me to proceed?')" FD_INTERACTIVE=1 ANTI_STALL_CAP=3
allowed && ok "over-CAP allows (bound reached)" || no "over-CAP did not allow — TRAP RISK"

echo "== a stale streak (older than WINDOW) is treated FRESH → BLOCK =="
SD3="$(mktemp -d -p "$ROOT")"; printf '3 100\n' > "$SD3/$KEY.nudge"   # last_ts=100 (ancient)
STATE_OVERRIDE="$SD3" run "$(mktx 'Back again. Want me to proceed?')" FD_INTERACTIVE=1 ANTI_STALL_CAP=3 ANTI_STALL_WINDOW=600
blocked && ok "stale streak resets and blocks a fresh stall" || no "stale streak did not reset"

echo "== malformed stdin JSON → ALLOW (fail-open) =="
OUT="$(printf 'not json at all' | env ANTI_STALL_STATE_DIR="$ROOT/s" FD_INTERACTIVE=1 bash "$SUT" 2>/dev/null)"; RC=$?
allowed && ok "malformed stdin allows" || no "malformed stdin did not allow"

echo "== missing transcript → ALLOW (fail-open) =="
run "$ROOT/does-not-exist.jsonl" FD_INTERACTIVE=1
allowed && ok "missing transcript allows" || no "missing transcript did not allow"

echo "== MUTATION: neutralize the CAP bound → an over-CAP session now BLOCKS (proves the bound is what allows) =="
MUT="$ROOT/mut-cap.sh"; sed 's/if \[ "\$cnt" -ge "\$CAP" \]; then/if false; then/' "$SUT" > "$MUT"; chmod +x "$MUT"
if ! cmp -s "$SUT" "$MUT"; then
  SDm="$(mktemp -d -p "$ROOT")"; printf '3 %s\n' "$(date +%s)" > "$SDm/$KEY.nudge"
  OUT="$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$SID" "$(mktx 'Want me to proceed?')" \
        | env ANTI_STALL_STATE_DIR="$SDm" FD_INTERACTIVE=1 ANTI_STALL_CAP=3 bash "$MUT" 2>/dev/null)"; RC=$?
  blocked && ok "mutant blocks over-CAP ⇒ the real bound row discriminates" || no "cap-mutation vacuous"
else no "cap mutation VACUOUS (sed changed nothing)"; fi

echo "== MUTATION: neutralize the sentinel gate → a declared DONE now BLOCKS (proves the sentinel allows) =="
MUT2="$ROOT/mut-sent.sh"; sed "s/(DONE|BLOCKED|NEEDS-DECISION):/ZZZ_NEVER_MATCHES:/" "$SUT" > "$MUT2"; chmod +x "$MUT2"
if ! cmp -s "$SUT" "$MUT2"; then
  # a message with BOTH a check-in signature AND a DONE line: real → allow (sentinel wins); mutant → block
  OUT="$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$SID" "$(mktx 'Want me to proceed?
DONE: objective met.')" | env ANTI_STALL_STATE_DIR="$ROOT/s2" FD_INTERACTIVE=1 bash "$MUT2" 2>/dev/null)"; RC=$?
  blocked && ok "mutant blocks a DONE msg ⇒ the real sentinel row discriminates" || no "sentinel-mutation vacuous"
else no "sentinel mutation VACUOUS (sed changed nothing)"; fi

echo; echo "anti-stall-stop: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
