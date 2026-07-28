#!/usr/bin/env bash
# anti-stall-stop.sh — a Claude Code **Stop hook**: the interactive analog of the headless loop's
# "no ask path". The autonomous machinery (dev-author / pr-poller → `claude -p`) CANNOT stall — a
# would-be prompt becomes a denial it adapts around. An INTERACTIVE session is the opposite: it can end a
# turn mid-objective, far below the doctrine's stop-ONLY-on-SHIP-or-genuine-BLOCK bar. Doctrine-as-text
# (willpower) does not fix a model disposition; a STRUCTURAL forcing function does.
#
# ── #279: THE STOP IS DECIDED BY FACTS, NOT BY PHRASING. ────────────────────────────────────────────
# The first cut tested the SHAPE of the last message: a CHECK-IN SIGNATURE ("want me to proceed?") was
# blocked, everything else allowed. It fired twice in one session and worked exactly as designed — and
# then the model ADAPTED: it wrote a factual status report carrying no check-in signature, handed control
# back, and stopped anyway. A guard on the FORM of a sentence is a guard the author of the sentence can
# always satisfy. So the ORACLE is now consulted on EVERY interactive stop, not only when a sentinel is
# declared, and the decision reads:
#   * WORK REMAINS (oracle STATUS: OPEN, or the standing work plan still carries an unchecked item) and
#     NO maintainer decision is named ⇒ the stop is a DEFECT **however the message is worded** — a status
#     report, a summary, a silent yield and a `DONE:` sentinel are all blocked identically.
#   * A `BLOCKED:` claim must name a MAINTAINER DECISION. "waiting for a gate", "watching a monitor",
#     "letting the queue drain" are the LOOP'S OWN WORK — the session owns the live-validate round-trip,
#     the queue and every verdict it says it is waiting on — so such a blocker is refused even when the
#     oracle cannot speak (that is a positive read of the model's OWN text, not an inference from silence).
#   * The check-in SIGNATURE survives as the fallback for when the oracle is silent — it can only ever ADD
#     teeth, never remove them.
#
# ── FAIL-OPEN BY CONSTRUCTION (a trapped session is strictly WORSE than a stall). EVERY uncertainty ALLOWS
#    the stop (exit 0, no block): unparseable input, missing transcript, no python3, unreadable/unwritable
#    state, an unavailable/slow oracle, a missing work plan, or ANY error. A malformed block-output is a
#    no-op to claude-code (allow), so even a wrong hook API is safe — worst case "the nudge does nothing".
# ── ANTI-TRAP BOUND: a per-session, time-windowed consecutive-nudge counter caps runaway at CAP nudges,
#    then ALLOWS (surfacing to the human) + resets — it bounds EVERY block path, the fact-driven ones
#    included. `stop_hook_active` is a second belt (already in a hook continuation ⇒ allow).
# ── DISCLOSED COST (not a defect — the trade #279 asks for): mid-objective, a purely conversational yield
#    is nudged too, because the hook cannot tell "I answered a question" from "I stopped" without reading
#    the phrasing again. The CAP is the valve (after CAP nudges in the window the turn ends), the human can
#    interrupt at any time, and the doctrine's own answer is that mid-objective the session should be
#    driving. A benign classifier miss costs one bounded nudge; it can never end the session's ability to stop.
#
# Contract: reads the Stop-hook JSON on stdin (session_id, transcript_path, stop_hook_active). To BLOCK it
# prints {"decision":"block","reason":"…"} on stdout and exits 0; to ALLOW it exits 0 with no output.
# `--selftest` exercises the pure core (no stdin, no oracle, no state). Registered as a MANAGED Stop hook
# (allowManagedHooksOnly makes user/project hooks inert). Covered by anti-stall-stop.test.sh.
# **Control-plane (agent stop-behaviour).**
set -uo pipefail

# ---- PURE CORE (no I/O) — exercised by --selftest --------------------------------------------------

# A "blocker" that is the LOOP'S OWN WORK rather than a maintainer DECISION (#279 rule 2). Every phrase
# here describes something the SESSION drives: a gate it labels, a verdict it reads, a queue it owns.
NONDECISION_RE='(wait(ing|s)?[[:space:]]+(for|on)|awaiting|watch(ing)?[[:space:]]+(the|a|an|for|it|them)|monitor|poll(ing)?[[:space:]]|drain|settle|in.flight|until[[:space:]]+(the[[:space:]]+)?(ci|gate|poller|host|queue|workflow|build|run|verdict|merge|review|pipeline)|for[[:space:]]+(the[[:space:]]+)?(gate|poller|queue|host|ci|verdict|merge|review|pipeline|workflow|build|check)([[:space:]]|$)|to[[:space:]]+(finish|complete|land|merge|drain|settle)|host[[:space:]]+(must|to|will|needs)|another[[:space:]]+box|my[[:space:]]+tier|not[[:space:]]+my[[:space:]]+(remit|tier)|live-validate|round.trip)'

# The CHECK-IN / permission-seeking signature. A heuristic with a BENIGN fail direction (miss ⇒ the fact
# path still decides; false-hit ⇒ one bounded nudge) — NOT a security sieve. Since #279 it is only the
# FALLBACK for a silent oracle; it is no longer what stands between a false stop and the turn ending.
STALL_RE='(want me to|shall i[^a-z]|should i[^a-z]|do you want|would you like|let me know|standing by|awaiting your|ready to proceed|proceed\?|continue\?|go ahead\?|pause here|pausing here|hold off|before i (proceed|continue|start|begin)|on your (word|go|approval|confirmation)|or (should|shall) i|which (should|would) i|want me to (proceed|continue)|let you review|for you to review|shall i)'

# blocker_is_decision <blocker-text> → 1 iff the named blocker is a genuine MAINTAINER DECISION, 0 iff it
# names nothing at all or names the loop's own work. Fail direction: anything unrecognised is treated as a
# DECISION (1) — the hook refuses only what it can positively identify as non-blocking.
blocker_is_decision(){
  local t; t="$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')"
  t="${t#"${t%%[![:space:]]*}"}"
  [ -n "$t" ] || { printf 0; return; }              # "BLOCKED:" naming nothing names no decision
  printf '%s' "$t" | grep -qE "$NONDECISION_RE" && { printf 0; return; }
  printf 1
}

# stall_signature <text> → 1 iff the tail carries a check-in / permission-seeking signature.
stall_signature(){
  printf '%s' "${1-}" | tail -c 900 | grep -qiE "$STALL_RE" && printf 1 || printf 0
}

# work_remains <oracle-status> <open-plan-items> → open|plan|'' — the FACT that makes a stop a defect.
# `open`  the ship oracle positively reports drivable open work.
# `plan`  the standing work plan still carries an unchecked `[ ]`/`[~]` item (#279 rule 1).
# ''      neither fact is positively readable ⇒ the oracle adds no teeth here (fail-open).
work_remains(){
  local status="${1-}" plan="${2-}" w=""
  [ "$status" = OPEN ] && w=open
  case "$plan" in ''|*[!0-9]*) plan=0;; esac
  [ -z "$w" ] && [ "$plan" -ge 1 ] && w=plan
  printf '%s' "$w"
}

# stop_mode <work:open|plan|''> <decl:DONE|BLOCKED|''> <blocker-is-decision:0|1> <signature:0|1> →
#   the BLOCK mode, or '' to ALLOW. This is the whole decision, in one pure function.
stop_mode(){
  local work="${1-}" decl="${2-}" isdec="${3-1}" sig="${4-0}"
  if [ -n "$work" ]; then
    case "$decl" in
      DONE)    printf 'oracle-DONE';;
      BLOCKED) printf 'oracle-BLOCKED';;
      *)       printf 'oracle-UNDECLARED';;         # #279: a stop is a defect however it is worded
    esac
    return
  fi
  # the oracle is silent — it can add teeth but never remove them.
  [ "$decl" = BLOCKED ] && [ "$isdec" = 0 ] && { printf 'nondecision-BLOCKED'; return; }
  [ -n "$decl" ] && return                          # a declared stop the facts cannot contradict ⇒ allow
  [ "$sig" = 1 ] && { printf 'signature'; return; }
  return
}

if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  echo "== blocker_is_decision — a BLOCKED: must name a MAINTAINER DECISION (#279 rule 2) =="
  ck "a real design fork"          "$(blocker_is_decision 'drop VNC for grd, or keep both?')" "1"
  ck "a scope question"            "$(blocker_is_decision 'which repo should the front door file into?')" "1"
  ck "waiting for a gate"          "$(blocker_is_decision 'waiting for the host live-gate verdict')" "0"
  ck "watching a monitor"          "$(blocker_is_decision 'watching the poller log for the merge')" "0"
  ck "letting the queue drain"     "$(blocker_is_decision 'letting the PR queue drain')" "0"
  ck "the tier excuse"             "$(blocker_is_decision 'the host must validate this candidate')" "0"
  ck "my-tier-is-finished"         "$(blocker_is_decision 'my tier is done, another box owns the rest')" "0"
  ck "awaiting CI"                 "$(blocker_is_decision 'awaiting the CI run')" "0"
  ck "names nothing at all"        "$(blocker_is_decision '')" "0"
  echo "== work_remains — the FACT, never the phrasing =="
  ck "oracle OPEN"                 "$(work_remains OPEN 0)" "open"
  ck "unchecked plan item"         "$(work_remains SHIPPED 3)" "plan"
  ck "INDETERMINATE + plan item"   "$(work_remains INDETERMINATE 1)" "plan"
  ck "shipped + clean plan"        "$(work_remains SHIPPED 0)" ""
  ck "silent oracle"               "$(work_remains '' '')" ""
  ck "unreadable plan count"       "$(work_remains SHIPPED 'unreadable')" ""
  echo "== stop_mode — the whole decision =="
  ck "work + DONE → false-DONE"    "$(stop_mode open DONE 1 0)" "oracle-DONE"
  ck "work + BLOCKED → false-block" "$(stop_mode open BLOCKED 1 0)" "oracle-BLOCKED"
  ck "work + a status report"      "$(stop_mode open '' 1 0)" "oracle-UNDECLARED"
  ck "plan item + a status report" "$(stop_mode plan '' 1 0)" "oracle-UNDECLARED"
  ck "silent + genuine DONE"       "$(stop_mode '' DONE 1 0)" ""
  ck "silent + genuine BLOCKED"    "$(stop_mode '' BLOCKED 1 0)" ""
  ck "silent + non-decision block" "$(stop_mode '' BLOCKED 0 0)" "nondecision-BLOCKED"
  ck "silent + check-in"           "$(stop_mode '' '' 1 1)" "signature"
  ck "silent + a plain answer"     "$(stop_mode '' '' 1 0)" ""
  echo; echo "anti-stall-stop selftest: $p passed, $f failed"; [ "$f" -eq 0 ]; exit
fi

# ---- LIVE PATH -------------------------------------------------------------------------------------
# a hard self-timeout so a wedged hook can never delay the turn — fail-OPEN (allow) if we ever re-exec.
# 12s budget accommodates the bounded R30 oracle consult (its own ANTI_STALL_ORACLE_TIMEOUT within).
if [ -z "${ANTI_STALL_REEXEC:-}" ]; then
  ANTI_STALL_REEXEC=1 exec timeout "${ANTI_STALL_TIMEOUT:-12}" bash "$0" "$@" || exit 0
fi

allow(){ exit 0; }                                   # ALLOW the stop (the safe direction)
# the R30 ship oracle (overridable for the test): the external FACT source every stop is measured against.
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

# a DECLARED stop (^DONE:/^BLOCKED:/^NEEDS-DECISION:) — detected here, VERIFIED below. The sentinel is a
# claim about the world; it is never itself the authority.
DECL=""; BLOCKER=""
printf '%s\n' "$LAST" | grep -qE '^[[:space:]]*DONE:' && DECL=DONE
[ -z "$DECL" ] && printf '%s\n' "$LAST" | grep -qE '^[[:space:]]*(BLOCKED|NEEDS-DECISION):' && DECL=BLOCKED
[ "$DECL" = BLOCKED ] && BLOCKER="$(printf '%s\n' "$LAST" | sed -n 's/^[[:space:]]*\(BLOCKED\|NEEDS-DECISION\):[[:space:]]*//p' | head -1)"

# ── THE FACTS (#279): consult the R30 oracle on EVERY stop, not only a declared one. It reports both the
#    ship status AND the standing work plan's unchecked-item count; either one positively saying "work
#    remains" makes a stop a defect regardless of how the message is worded. Its SILENCE never traps.
osout=""
[ -n "$ORACLE" ] && [ -x "$ORACLE" ] && \
  osout="$(OBJECTIVE_SID="$SID" timeout "${ANTI_STALL_ORACLE_TIMEOUT:-6}" bash "$ORACLE" --status 2>/dev/null)" || osout="${osout:-}"
OS_STATUS="$(printf '%s\n' "$osout" | sed -n 's/^STATUS: *//p' | head -1)"
OS_NEXT="$(printf '%s\n'   "$osout" | sed -n 's/^NEXT: *//p'   | head -1)"
OS_REASON="$(printf '%s\n' "$osout" | sed -n 's/^REASON: *//p' | head -1)"
OS_PLAN="$(printf '%s\n'   "$osout" | sed -n 's/^OPEN_PLAN_ITEMS: *//p' | head -1)"
OS_PLAN_ISSUE="$(printf '%s\n' "$osout" | sed -n 's/^PLAN_ISSUE: *//p' | head -1)"

WORK=""
[ "$OS_STATUS" = OPEN ] && WORK=open
if [ -z "$WORK" ]; then
  case "$OS_PLAN" in ''|*[!0-9]*) : ;; *) [ "$OS_PLAN" -ge 1 ] && WORK=plan;; esac
fi

ISDEC=1; [ "$DECL" = BLOCKED ] && ISDEC="$(blocker_is_decision "$BLOCKER")"
SIG=0; [ -z "$WORK" ] && [ -z "$DECL" ] && SIG="$(stall_signature "$LAST")"
MODE="$(stop_mode "$WORK" "$DECL" "$ISDEC" "$SIG")"

if [ -z "$MODE" ]; then
  # an honoured stop: a SHIPPED/silent oracle with a declared reason the facts cannot contradict, or a
  # plain answer. Reset the streak so the next genuine stall starts from zero.
  if [ -n "$DECL" ] && [ -n "$SID" ]; then
    key="${SID//[^A-Za-z0-9._-]/_}"; sd="${ANTI_STALL_STATE_DIR:-$HOME/.local/state/anti-stall}"
    mkdir -p "$sd" 2>/dev/null && printf '0 0\n' > "$sd/$key.nudge" 2>/dev/null
  fi
  allow
fi

# a plan-only fact has no oracle NEXT of its own (STATUS is not OPEN) — name the plan item as the action.
if [ "$WORK" = plan ] && [ -z "$OS_NEXT" ]; then
  OS_NEXT="take the next unchecked item on the standing work plan${OS_PLAN_ISSUE:+ #$OS_PLAN_ISSUE} ($OS_PLAN still unchecked) — file it and author it through the loop."
  [ -n "$OS_REASON" ] || OS_REASON="the standing work plan${OS_PLAN_ISSUE:+ (#$OS_PLAN_ISSUE)} still carries $OS_PLAN unchecked item(s)"
fi

# ── it IS a false stop. Apply the windowed anti-trap bound, then BLOCK with the mode-appropriate reason. ──
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

# BLOCK + feed back the mode-appropriate reason. Every fact-driven mode names the FACT (what work remains)
# and the EXACT next drive action, so the nudge is actionable rather than scolding.
FD_MODE="$MODE" FD_OS_NEXT="$OS_NEXT" FD_OS_REASON="$OS_REASON" "$PY" -c '
import json,os
mode=os.environ.get("FD_MODE","signature")
nxt=os.environ.get("FD_OS_NEXT","").strip()
why=os.environ.get("FD_OS_REASON","").strip()
if mode=="oracle-DONE":
    reason=(
     "Stop-hook (anti-stall / R30): you declared DONE, but the facts say the objective is NOT shipped — "
     +(why or "drivable open work remains")+". A stop is honoured ONLY when the WHOLE objective SHIPS "
     "(oracle STATUS: SHIPPED — every feature proven live, the assembled product deployed, no unchecked "
     "work-plan item), never on \"my tier is finished\". This is DEV-owned work; host-GATED is not "
     "host-OWNED. NEXT: "+(nxt or "drive the remaining open PRs/backlog to merged.")+" Continue now."
    )
elif mode=="oracle-BLOCKED":
    reason=(
     "Stop-hook (anti-stall / R30): you declared BLOCKED, but DEV-drivable open work still remains — "
     +(why or "open PRs/backlog you own")+". \"Host-gated / another-box-tier / needs a rehearsal\" is NOT "
     "a maintainer decision — you DRIVE the live-validate round-trip yourself (the host EXECUTES your "
     "ticket; it does not OWN the work). A genuine BLOCK names a decision only the maintainer can make "
     "AND has no drivable work left. NEXT: "+(nxt or "drive the remaining work to merged.")+" Continue now."
    )
elif mode=="oracle-UNDECLARED":
    reason=(
     "Stop-hook (anti-stall / R30): you ended the turn while the FACTS say work remains — "
     +(why or "drivable open work is still open")+". Wording is not what decides this: a status report, a "
     "summary, or a silent hand-back is the same stop as \"want me to proceed?\" and is blocked the same "
     "way. Stop ONLY by naming a reason that survives verification: end with  DONE: <summary>  when the "
     "WHOLE objective is shipped, or  BLOCKED: <the specific maintainer DECISION>  when a real roadblock "
     "needs the maintainer. NEXT: "+(nxt or "drive the remaining open work to merged.")+" Continue now — "
     "build -> validate -> iterate; do not hand control back."
    )
elif mode=="nondecision-BLOCKED":
    reason=(
     "Stop-hook (anti-stall): your BLOCKED: does not name a maintainer DECISION — it names WORK THE LOOP "
     "ITSELF OWNS. \"Waiting for a gate\", \"watching a monitor\", \"letting the queue drain\", \"the host must "
     "validate this\" are all things YOU drive: label the PR live-validate, read the verdict, iterate "
     "RED->GREEN, and the poller merges. A genuine BLOCKED: names a decision only the maintainer can make "
     "(a design fork, a scope call). Either re-declare with that decision named, or keep driving now."
    )
else:
    reason=(
     "Stop-hook (anti-stall): you ended a turn seeking permission / checking in, but named no stop reason. "
     "You may stop ONLY by NAMING one, and it is VERIFIED: end your FINAL message with  DONE: <summary>  "
     "only when the WHOLE objective is SHIPPED (proven live), or  BLOCKED: <the specific maintainer "
     "decision>  only when a real roadblock needs the maintainer AND no drivable work is left. Otherwise "
     "the path is DECIDED and yours to build — do NOT ask permission: continue now (build -> validate -> "
     "iterate). Host-gated validation is DEV-owned: drive the live-validate round-trip; do not hand it off."
    )
print(json.dumps({"decision":"block","reason":reason}))
' 2>/dev/null || allow
exit 0
