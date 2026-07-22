#!/usr/bin/env bash
# anti-stall-stop.sh — a Claude Code **Stop hook**: the interactive analog of the headless loop's
# "no ask path". The autonomous machinery (dev-author / pr-poller → `claude -p`) CANNOT stall — a
# would-be prompt becomes a denial it adapts around. An INTERACTIVE session is the opposite: it can end a
# turn with a check-in ("want me to proceed?") — OR with a confident FALSE-DONE ("DONE — my tier is
# finished; the host must validate this") — mid-objective, far below the doctrine's stop-ONLY-on-SHIP-or-
# genuine-BLOCK bar. Doctrine-as-text (willpower) does not fix a model disposition; a STRUCTURAL forcing
# function does. This hook fires at the turn-end yield and BLOCKS a false stop two ways:
#   (a) a CHECK-IN with no declared stop → the stall SIGNATURE (gate 2) blocks it with a "path is decided,
#       continue" nudge (the automated form of the human typing "why are you stopping").
#   (b) a DECLARED `DONE:`/`BLOCKED:` sentinel is NO LONGER honoured on FORM alone — it is VERIFIED against
#       the R30 SHIP ORACLE (bin/objective-status.sh, an external GitHub-derived FACT). A `DONE:` while
#       DRIVABLE open work remains, or a `BLOCKED:` whose "blocker" is DEV-drivable (a live-validate
#       round-trip — host-GATED is NOT host-OWNED), is a FALSE stop: BLOCKED with the EXACT next drive
#       action. The oracle's teeth rest SOLELY on the FACT (STATUS: OPEN); its silence never traps.
# The stop is honoured (allowed) only when the oracle confirms SHIPPED, or cannot speak (INDETERMINATE /
# unavailable ⇒ fall back to the heuristic), or the anti-trap CAP is reached — so a stop is always reachable.
#
# ── FAIL-OPEN BY CONSTRUCTION (a trapped session is strictly WORSE than a stall). EVERY uncertainty ALLOWS
#    the stop (exit 0, no block): unparseable input, missing/oversized transcript, no python3, unreadable/
#    unwritable state, or ANY error. A malformed block-output is a no-op to claude-code (allow), so even a
#    wrong hook API is safe — the worst case is "the nudge does nothing", never a trap.
# ── ANTI-TRAP BOUND: a per-session, time-windowed consecutive-nudge counter caps runaway at CAP nudges,
#    then ALLOWS (surfacing to the human) + resets. `stop_hook_active` is a second belt (already in a
#    hook-driven continuation ⇒ allow).
# ── TWO BLOCK PATHS (both require gate 1 + under CAP):
#    · SENTINEL path (gate 3) — the message carries a `^DONE:`/`^BLOCKED:`/`^NEEDS-DECISION:` sentinel: the
#      R30 oracle is consulted. STATUS: OPEN (drivable work remains) ⇒ BLOCK with the exact next drive
#      action; SHIPPED / INDETERMINATE / oracle-unavailable ⇒ ALLOW (honour the deliberate stop, reset).
#    · SIGNATURE path (gate 2) — NO sentinel, but a CHECK-IN / permission-seeking SIGNATURE in the tail ⇒
#      BLOCK with the generic "path is decided, continue" nudge. A plain answer (no signature) ⇒ ALLOW.
#    gate 1 = FD_INTERACTIVE=1 (set only by bin/claude, so headless `claude -p` is never touched).
#
# Contract: reads the Stop-hook JSON on stdin (session_id, transcript_path, stop_hook_active). To BLOCK it
# prints {"decision":"block","reason":"…"} on stdout and exits 0; to ALLOW it exits 0 with no output.
# Registered as a MANAGED Stop hook (allowManagedHooksOnly makes user/project hooks inert). Covered by
# anti-stall-stop.test.sh. **Control-plane (agent stop-behaviour).**
set -uo pipefail

# a hard self-timeout so a wedged hook can never delay the turn — fail-OPEN (allow) if we ever re-exec.
# 12s budget accommodates the bounded R30 oracle consult (its own ANTI_STALL_ORACLE_TIMEOUT within).
if [ -z "${ANTI_STALL_REEXEC:-}" ]; then
  ANTI_STALL_REEXEC=1 exec timeout "${ANTI_STALL_TIMEOUT:-12}" bash "$0" "$@" || exit 0
fi

allow(){ exit 0; }                                   # ALLOW the stop (the safe direction)
# the R30 ship oracle (overridable for the test): consulted to VERIFY a declared DONE/BLOCKED sentinel.
HERE="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" 2>/dev/null && pwd)" || HERE=""
ORACLE="${ANTI_STALL_ORACLE:-${HERE:+$HERE/}objective-status.sh}"
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

# gate 3 — a DECLARED stop (^DONE:/^BLOCKED:/^NEEDS-DECISION:) is VERIFIED against the R30 ship oracle,
# NOT honoured on FORM alone. THE LOAD-BEARING CHANGE: the sentinel used to be a costume that ended the
# turn regardless of truth; now the FACT decides. The oracle's teeth rest SOLELY on STATUS: OPEN (drivable
# work positively remains); every other answer (SHIPPED / INDETERMINATE / unavailable) HONOURS the stop —
# the oracle can strengthen the gate but never trap on its own silence.
MODE=""; OS_NEXT=""; OS_REASON=""; DECL=""
printf '%s\n' "$LAST" | grep -qE '^[[:space:]]*DONE:' && DECL=DONE
[ -z "$DECL" ] && printf '%s\n' "$LAST" | grep -qE '^[[:space:]]*(BLOCKED|NEEDS-DECISION):' && DECL=BLOCKED
if [ -n "$DECL" ]; then
  osout=""
  [ -n "$ORACLE" ] && [ -x "$ORACLE" ] && \
    osout="$(OBJECTIVE_SID="$SID" timeout "${ANTI_STALL_ORACLE_TIMEOUT:-6}" bash "$ORACLE" --status 2>/dev/null)" || osout="${osout:-}"
  OS_STATUS="$(printf '%s\n' "$osout" | sed -n 's/^STATUS: *//p' | head -1)"
  OS_NEXT="$(printf '%s\n' "$osout"   | sed -n 's/^NEXT: *//p'   | head -1)"
  OS_REASON="$(printf '%s\n' "$osout" | sed -n 's/^REASON: *//p' | head -1)"
  if [ "$OS_STATUS" = OPEN ]; then
    MODE="oracle-$DECL"     # a FALSE stop the oracle caught → BLOCK (CAP-bounded), skipping the signature gate
  else
    # SHIPPED / INDETERMINATE / oracle-unavailable ⇒ honour the deliberate stop (fail-open; never trap) + reset
    [ -n "$SID" ] && { key="${SID//[^A-Za-z0-9._-]/_}"; sd="${ANTI_STALL_STATE_DIR:-$HOME/.local/state/anti-stall}"; mkdir -p "$sd" 2>/dev/null && printf '0 0\n' > "$sd/$key.nudge" 2>/dev/null; }
    allow
  fi
fi

# gate 2 — NO sentinel: the stall SIGNATURE (a check-in / permission-seeking / pause in the TAIL). A
# heuristic with a BENIGN fail direction (miss ⇒ prior behaviour; false-hit ⇒ one bounded nudge) — NOT a
# security sieve; it targets the agent's own stall expression so a normal answer is never nudged.
if [ -z "$MODE" ]; then
  TAIL="$(printf '%s' "$LAST" | tail -c 900)"
  STALL_RE='(want me to|shall i[^a-z]|should i[^a-z]|do you want|would you like|let me know|standing by|awaiting your|ready to proceed|proceed\?|continue\?|go ahead\?|pause here|pausing here|hold off|before i (proceed|continue|start|begin)|on your (word|go|approval|confirmation)|or (should|shall) i|which (should|would) i|want me to (proceed|continue)|let you review|for you to review|shall i)'
  printf '%s' "$TAIL" | grep -qiE "$STALL_RE" || allow
  MODE="signature"
fi

# ── it IS a false stop (oracle-verified false-DONE/BLOCKED, or a bare check-in). Apply the windowed
#    anti-trap bound, then BLOCK with the mode-appropriate reason. ──
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

# BLOCK + feed back the mode-appropriate reason. For an oracle-verified false stop the reason names the
# FACT (drivable open work) + the EXACT next drive action; for a bare check-in it is the generic nudge.
FD_MODE="$MODE" FD_OS_NEXT="$OS_NEXT" FD_OS_REASON="$OS_REASON" "$PY" -c '
import json,os
mode=os.environ.get("FD_MODE","signature")
nxt=os.environ.get("FD_OS_NEXT","").strip()
why=os.environ.get("FD_OS_REASON","").strip()
if mode=="oracle-DONE":
    reason=(
     "Stop-hook (anti-stall / R30): you declared DONE, but the ship oracle finds the objective is NOT "
     "shipped — "+(why or "drivable open work remains")+". A stop is honoured ONLY when the WHOLE objective "
     "SHIPS (oracle STATUS: SHIPPED — every feature proven live, the assembled product deployed), never on "
     "\"my tier is finished\". This is DEV-owned work; host-GATED is not host-OWNED. NEXT: "
     +(nxt or "drive the remaining open PRs/backlog to merged.")+" Continue now — do not stop."
    )
elif mode=="oracle-BLOCKED":
    reason=(
     "Stop-hook (anti-stall / R30): you declared BLOCKED, but the ship oracle finds DEV-drivable open work "
     "still remains — "+(why or "open PRs/backlog you own")+". \"Host-gated / another-box-tier / needs a "
     "rehearsal\" is NOT a maintainer decision — you DRIVE the live-validate round-trip yourself (the host "
     "EXECUTES your ticket; it does not OWN the work). A genuine BLOCK is honoured only when no drivable "
     "work is left. NEXT: "+(nxt or "drive the remaining work to merged.")+" Continue now — do not stop."
    )
else:
    reason=(
     "Stop-hook (anti-stall): you ended a turn seeking permission / checking in, but named no stop reason. "
     "You may stop ONLY by NAMING one, and it is VERIFIED: end your FINAL message with  DONE: <summary>  "
     "only when the WHOLE objective is SHIPPED (proven live), or  BLOCKED: <the specific maintainer "
     "decision>  only when a real roadblock needs the maintainer AND no drivable work is left. Otherwise "
     "the path is DECIDED and yours to build — do NOT ask permission: continue now (build → validate → "
     "iterate). Host-gated validation is DEV-owned: drive the live-validate round-trip; do not hand it off."
    )
print(json.dumps({"decision":"block","reason":reason}))
' 2>/dev/null || allow
exit 0
