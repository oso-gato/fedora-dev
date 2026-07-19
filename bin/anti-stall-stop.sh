#!/usr/bin/env bash
# anti-stall-stop.sh — a Claude Code **Stop hook**: the interactive analog of the headless loop's
# "no ask path". The autonomous machinery (dev-author / pr-poller → `claude -p`) CANNOT stall — a
# would-be prompt becomes a denial it adapts around. An INTERACTIVE session is the opposite: it can end a
# turn with a check-in ("want me to proceed? this is a big chunk?") at a threshold far below the doctrine's
# stop-ONLY-on-materially-complete-or-blocked. Doctrine-as-text (willpower) does not fix a model
# disposition; a STRUCTURAL forcing function does. This hook fires exactly at the turn-end yield and, when
# an interactive session tries to stop MID-OBJECTIVE with a check-in and NO declared stop, BLOCKS the stop
# and feeds back a "continue — the path is decided" nudge (the automated form of the human typing "why are
# you stopping"). It teaches the sentinel so the agent can stop DELIBERATELY.
#
# ── FAIL-OPEN BY CONSTRUCTION (a trapped session is strictly WORSE than a stall). EVERY uncertainty ALLOWS
#    the stop (exit 0, no block): unparseable input, missing/oversized transcript, no python3, unreadable/
#    unwritable state, or ANY error. A malformed block-output is a no-op to claude-code (allow), so even a
#    wrong hook API is safe — the worst case is "the nudge does nothing", never a trap.
# ── ANTI-TRAP BOUND: a per-session, time-windowed consecutive-nudge counter caps runaway at CAP nudges,
#    then ALLOWS (surfacing to the human) + resets. `stop_hook_active` is a second belt (already in a
#    hook-driven continuation ⇒ allow).
# ── GATES (ALL required to BLOCK): (1) FD_INTERACTIVE=1 — set only by bin/claude, so headless `claude -p`
#    (which bypasses the wrapper) is never touched; (2) the last assistant message carries a CHECK-IN /
#    permission-seeking / pause SIGNATURE (targets the actual stall, so a normal conversational answer is
#    never nudged); (3) it carries NO `^DONE:` / `^BLOCKED:` sentinel (the deliberate-stop escape hatch);
#    (4) the windowed nudge count is under CAP.
#
# Contract: reads the Stop-hook JSON on stdin (session_id, transcript_path, stop_hook_active). To BLOCK it
# prints {"decision":"block","reason":"…"} on stdout and exits 0; to ALLOW it exits 0 with no output.
# Registered as a MANAGED Stop hook (allowManagedHooksOnly makes user/project hooks inert). Covered by
# anti-stall-stop.test.sh. **Control-plane (agent stop-behaviour).**
set -uo pipefail

# a hard self-timeout so a wedged hook can never delay the turn — fail-OPEN (allow) if we ever re-exec.
if [ -z "${ANTI_STALL_REEXEC:-}" ]; then
  ANTI_STALL_REEXEC=1 exec timeout "${ANTI_STALL_TIMEOUT:-8}" bash "$0" "$@" || exit 0
fi

allow(){ exit 0; }                                   # ALLOW the stop (the safe direction)
PY="$(command -v python3 2>/dev/null)" || allow      # we parse JSON with python3; absent ⇒ allow
[ -n "$PY" ] || allow

# gate 1 — interactive only (bin/claude exports FD_INTERACTIVE=1; headless `claude -p` never does)
[ "${FD_INTERACTIVE:-}" = 1 ] || allow

IN="$(cat 2>/dev/null)" || allow
[ -n "$IN" ] || allow

# extract session_id, transcript_path, stop_hook_active — newline-framed, fail-open to empty
fields="$(printf '%s' "$IN" | "$PY" -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get("session_id",""))
    print(d.get("transcript_path",""))
    print("1" if d.get("stop_hook_active") else "0")
except Exception:
    pass
' 2>/dev/null)" || allow
SID="$(printf '%s' "$fields" | sed -n 1p)"
TP="$(printf '%s'  "$fields" | sed -n 2p)"
SHA="$(printf '%s' "$fields" | sed -n 3p)"

# belt anti-trap: already continuing because of a stop hook ⇒ do not block again
[ "$SHA" = 1 ] && allow

[ -n "$TP" ] && [ -r "$TP" ] || allow                # no readable transcript ⇒ allow

# the last assistant message text (fail-open to empty)
LAST="$(FD_ASTP="$TP" "$PY" -c '
import json,os,sys
tp=os.environ.get("FD_ASTP","")
last=""
try:
    with open(tp,encoding="utf-8",errors="replace") as f:
        for line in f:
            line=line.strip()
            if not line: continue
            try: o=json.loads(line)
            except Exception: continue
            msg=o.get("message") if isinstance(o.get("message"),dict) else o
            if o.get("type")=="assistant" or (isinstance(msg,dict) and msg.get("role")=="assistant"):
                c=msg.get("content")
                if isinstance(c,list):
                    t="".join(b.get("text","") for b in c if isinstance(b,dict) and b.get("type")=="text")
                    if t.strip(): last=t
                elif isinstance(c,str) and c.strip():
                    last=c
    sys.stdout.write(last)
except Exception:
    pass
' 2>/dev/null)" || allow
[ -n "$LAST" ] || allow

# gate 3 — a DECLARED stop is always honoured (the deliberate-stop escape hatch)
printf '%s\n' "$LAST" | grep -qE '^[[:space:]]*(DONE|BLOCKED|NEEDS-DECISION):' && { reset_and_allow=1; }
if [ "${reset_and_allow:-}" = 1 ]; then
  # reset the streak so the next genuine stall starts clean, then allow
  [ -n "$SID" ] && { key="${SID//[^A-Za-z0-9._-]/_}"; sd="${ANTI_STALL_STATE_DIR:-$HOME/.local/state/anti-stall}"; mkdir -p "$sd" 2>/dev/null && printf '0 0\n' > "$sd/$key.nudge" 2>/dev/null; }
  allow
fi

# gate 2 — the stall SIGNATURE: a check-in / permission-seeking / pause in the TAIL of the message.
# A heuristic with a BENIGN fail direction (miss ⇒ prior behaviour; false-hit ⇒ one bounded nudge) — it is
# NOT a security sieve, it targets the agent's own stall expression so a normal answer is never nudged.
TAIL="$(printf '%s' "$LAST" | tail -c 900)"
STALL_RE='(want me to|shall i[^a-z]|should i[^a-z]|do you want|would you like|let me know|standing by|awaiting your|ready to proceed|proceed\?|continue\?|go ahead\?|pause here|pausing here|hold off|before i (proceed|continue|start|begin)|on your (word|go|approval|confirmation)|or (should|shall) i|which (should|would) i|want me to (proceed|continue)|let you review|for you to review|shall i)'
printf '%s' "$TAIL" | grep -qiE "$STALL_RE" || allow

# ── it IS a mid-objective stall. Apply the windowed anti-trap bound, then BLOCK with the nudge. ──
CAP="${ANTI_STALL_CAP:-3}"; WINDOW="${ANTI_STALL_WINDOW:-600}"
sd="${ANTI_STALL_STATE_DIR:-$HOME/.local/state/anti-stall}"
key="${SID//[^A-Za-z0-9._-]/_}"; [ -n "$key" ] || allow
mkdir -p "$sd" 2>/dev/null || allow                  # unwritable state ⇒ allow (never block on doubt)
nf="$sd/$key.nudge"
now="$(date +%s 2>/dev/null)" || allow
cnt=0; last_ts=0
if [ -r "$nf" ]; then read -r cnt last_ts < "$nf" 2>/dev/null || { cnt=0; last_ts=0; }; fi
case "$cnt" in ''|*[!0-9]*) cnt=0;; esac
case "$last_ts" in ''|*[!0-9]*) last_ts=0;; esac
# a streak older than WINDOW is a FRESH stall — start clean (a nudge from an hour ago must not pre-charge)
[ $(( now - last_ts )) -gt "$WINDOW" ] && cnt=0
if [ "$cnt" -ge "$CAP" ]; then
  # ran out the bound: the agent cannot self-continue past this — ALLOW (surface to the human) + reset
  printf '0 0\n' > "$nf" 2>/dev/null || true
  allow
fi
printf '%s %s\n' "$((cnt+1))" "$now" > "$nf" 2>/dev/null || allow

# BLOCK + feed the nudge back to the model. The reason teaches the sentinel so the agent can stop deliberately.
"$PY" -c '
import json,sys
reason=(
 "Stop-hook (anti-stall): you ended a turn seeking permission / checking in, but named no completion or "
 "blocker. Per doctrine you may stop ONLY by NAMING a stop reason. If the objective is materially COMPLETE, "
 "end your FINAL message with a line:  DONE: <one-line objective-met summary>. If you are materially "
 "BLOCKED on a decision only the maintainer can make, end with:  BLOCKED: <the specific decision needed>. "
 "Otherwise the path is DECIDED and yours to build — do NOT ask permission to proceed: continue now "
 "(build → validate → iterate) until the objective is met or you hit a genuine blocker."
)
print(json.dumps({"decision":"block","reason":reason}))
' 2>/dev/null || allow
exit 0
