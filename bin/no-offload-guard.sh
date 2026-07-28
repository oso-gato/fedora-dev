#!/usr/bin/env bash
# no-offload-guard.sh — a Claude Code **Stop hook** that refuses to let the agent hand the maintainer a
# command the agent can run itself.
#
# WHY THIS EXISTS. Arthur's standing rule is "if you can run it why ask me?" — and the agent breaks it
# repeatedly. On 2026-07-28 the loop had been dead for six days; the agent diagnosed it, then asked Arthur
# to type `claudebox-rebuild` — a command sitting on the agent's OWN PATH, whose watcher needed no
# credential and no permission. Worse, that command was PROVABLY INERT against the fault (box-rebuild.sh
# has no reap step, and a rebuild had already run that morning leaving the orphans untouched), while the
# repair that DID work — reaping two hung processes — was never attempted. The ask was both outsourced
# and wrong.
#
# WHY A HOOK AND NOT A MEMORY. Four memory files documented the very capabilities the agent forgot
# (self-refresh armed, R17 resume proven, rebuild-devbox shipped, "never offload runnable actions"). It
# consulted none of them. Memory-as-reminder has now failed 4/4 on this exact class. A note the agent must
# CHOOSE to read is the same architecture as a stall nobody notices: the information exists and nothing
# forces anyone to see it. So this is deterministic machinery, not a resolution to try harder.
#
# WHAT IT DOES. At the turn-end yield it scans the outgoing message for a LINE THAT BEGINS with `! ` —
# this box's documented convention for handing a shell command to the human. If that line's leading token
# RESOLVES TO AN EXECUTABLE ON THIS BOX'S PATH, the stop is BLOCKED with the resolved path quoted back.
#
# THE ASK FORM IS ANCHORED TO LINE START, and that anchor is the whole discrimination. Matching `! `
# ANYWHERE on a line collides head-on with ordinary English: `All green! test coverage is at 100%` yields
# the token `test`, which resolves at /usr/bin/test, and the guard fires on a status report. Six realistic
# messages did exactly that (`Done! time …`, `It works! true …`, `Nice catch! kill …`, `Deployed! echo …`,
# `Shipped it! more …`). A deliberate hand-over is written on its own line; a prose exclamation never is.
# Leading whitespace and a wrapping markdown code span are stripped first, so an indented ask and the
# ``! claudebox-rebuild`` form are both still seen.
#
# EFFICACY BOUND (stated because it limits what this catches): only the `! ` form is visible to the guard.
# An offload phrased as plain English — "could you run claudebox-rebuild" — is NOT caught. This stops the
# deliberate hand-over convention from being used without examination; it is not a general prose detector.
#
# THE ESCAPE HATCH IS NAMING THE OBSTACLE, and it is deliberately easy. A message that states a concrete
# permission/technical denial ("the classifier denied `kill`", "permission denied", "not permitted") is
# ALLOWED — because a genuine denial IS a legitimate reason to hand a command over, and on 2026-07-28 the
# agent hit exactly that (kill was denied three times, and only a human grant unblocked it). The guard's
# target is the UNEXAMINED ask, never the honest blocked one. It asks a single question the agent must
# answer before the message leaves: did you try it, and what exactly stopped you?
#
# ── FAIL-OPEN BY CONSTRUCTION (a trapped session is strictly worse than a bad ask). EVERY uncertainty
#    ALLOWS: unparseable input, missing/oversized transcript, no python3, unreadable state, any error, or
#    a self-timeout. A malformed block-output is a no-op to claude-code, so even a wrong hook API is safe.
# ── ANTI-TRAP BOUND: a per-session consecutive-block counter caps at NO_OFFLOAD_CAP, then ALLOWS and
#    resets — so a stop is always reachable even if the agent cannot phrase itself past the guard.
# ── NEVER BLOCKS ON: a command that does NOT resolve here (nothing to run), a command name mentioned in
#    prose — including after a mid-sentence exclamation, which is NOT the ask form — or a message that
#    already names a denial.
#
# Contract: reads the Stop-hook JSON on stdin (session_id, transcript_path, stop_hook_active). To BLOCK it
# prints {"decision":"block","reason":"…"} on stdout and exits 0; to ALLOW it exits 0 with no output.
# Registered as a MANAGED Stop hook alongside anti-stall-stop.sh (they are independent: anti-stall governs
# WHETHER stopping is legitimate, this governs WHAT the stopping message may ask of the human).
# Covered by no-offload-guard.test.sh. **Control-plane (agent stop-behaviour).**
set -uo pipefail

# hard self-timeout — a wedged hook must never delay a turn. Fail-OPEN both ways: `exec` has replaced this
# shell by the time timeout fires, so a TIMED-OUT hook exits 124 having printed nothing, which claude-code
# reads as ALLOW; the `|| exit 0` catches the other case, an exec that never happened (no timeout binary).
if [ -z "${NO_OFFLOAD_REEXEC:-}" ]; then
  NO_OFFLOAD_REEXEC=1 exec timeout "${NO_OFFLOAD_TIMEOUT:-8}" bash "$0" "$@" || exit 0
fi

NO_OFFLOAD_CAP="${NO_OFFLOAD_CAP:-2}"
NO_OFFLOAD_STATE="${NO_OFFLOAD_STATE:-$HOME/.local/state/no-offload-guard}"
# Words that prove the agent named a concrete obstacle. Generous ON PURPOSE — a false ALLOW costs one bad
# ask; a false BLOCK traps a session that may be genuinely stuck.
# NB: NO apostrophes in this default. Inside a ${VAR:-word} default bash treats a single quote as a
# quote opener even within double quotes, and the resulting parse error surfaces ~50 lines later.
# "can.t run" covers both "cannot run" and "can't run" without one.
NO_OFFLOAD_DENIAL_RE="${NO_OFFLOAD_DENIAL_RE:-denied|denial|classifier|permission|not permitted|refus|blocked by|cannot run|can.t run|no access|unauthori}"

_BT="$(printf '\140')"   # a literal backtick; see the note in extract_asks for why it cannot be inline

# ---- PURE CORE (--selftest covers exactly this) ----------------------------------------------------
# offload_verdict <offending-cmds> <has-denial:0|1> <blocks-so-far> <cap> → BLOCK | ALLOW
# BLOCK only when there is a REAL runnable command AND no obstacle was named AND we are under the cap.
offload_verdict(){
  local cmds="${1-}" denial="${2-}" n="${3-}" cap="${4-}"
  [ -n "${cmds// /}" ] || { printf 'ALLOW\n'; return 0; }   # nothing runnable was asked for
  [ "$denial" = 1 ] && { printf 'ALLOW\n'; return 0; }      # an obstacle was named — a legitimate ask
  case "$n" in ''|*[!0-9]*) printf 'ALLOW\n'; return 0 ;; esac
  case "$cap" in ''|*[!0-9]*) printf 'ALLOW\n'; return 0 ;; esac
  [ "$n" -ge "$cap" ] && { printf 'ALLOW\n'; return 0; }    # anti-trap: a stop is always reachable
  printf 'BLOCK\n'
}

# extract_asks <text> → the leading token of each `! <cmd>` handed to the human, one per line.
# ONLY a line that BEGINS with '! ': that is this box's documented convention for "type this yourself", so
# it is a deliberate ask. Matching mid-line would swallow ordinary prose (see THE ASK FORM IS ANCHORED, top).
extract_asks(){
  printf '%s\n' "${1-}" | while IFS= read -r line; do
    # leading whitespace and a wrapping code span are decoration, not content: an indented ask and the
    # ``! cmd`` form must still be seen.
    while :; do
      case "$line" in
        [[:space:]]*) line="${line#?}" ;;
        "$_BT"*)      line="${line#"$_BT"}" ;;
        *) break ;;
      esac
    done
    case "$line" in
      '! '*) : ;;
      *) continue ;;
    esac
    # take the first whitespace-delimited token after the anchor
    local rest="${line#'! '}"
    local tok="${rest%%[[:space:]]*}"
    # NB: the backtick MUST come from a variable. Written inline inside a ${...} expansion bash opens a
    # command substitution even when backslash-escaped, and the parse error surfaces many lines later.
    # STRIP THE OPENING BACKTICK FIRST: a markdown code span is the most natural way to hand a command
    # over, and taking the trailing one first wipes `cmd` to empty — the ask then sails through unseen.
    tok="${tok#${_BT}}"; tok="${tok%%${_BT}*}"
    [ -n "$tok" ] || continue
    case "$tok" in
      -*) continue ;;
    esac
    case "$tok" in
      */*) tok="${tok##*/}" ;;
    esac
    printf '%s\n' "$tok"
  done
}

# resolve_cmd <name> → the ABSOLUTE path it runs from on this box, or nothing.
# `type -P` searches PATH only. `command -v` would answer a bare `test`/`kill`/`echo` for the shell
# BUILTIN, so the block message could claim a command "resolves at kill" — a path that is not a path.
# type -P still finds /usr/bin/kill, so nothing catchable is lost; only the bogus rendering is.
resolve_cmd(){
  local p; p="$(type -P -- "${1-}" 2>/dev/null)" || return 0
  case "$p" in /*) printf '%s\n' "$p" ;; esac
}

# has_denial <text> → 1 if the message names a concrete obstacle
has_denial(){
  printf '%s' "${1-}" | grep -qiE "$NO_OFFLOAD_DENIAL_RE" && printf 1 || printf 0
}

if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"; else f=$((f+1)); printf '  FAIL %s want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  echo "== verdict — block ONLY an unexamined ask for something runnable =="
  ck "THE 2026-07-28 ASK: runnable, no obstacle named" "$(offload_verdict 'claudebox-rebuild' 0 0 2)" "BLOCK"
  ck "obstacle named -> allowed (the honest blocked ask)" "$(offload_verdict 'kill' 1 0 2)" "ALLOW"
  ck "nothing runnable asked -> allow"       "$(offload_verdict '' 0 0 2)" "ALLOW"
  ck "whitespace only -> allow"              "$(offload_verdict '   ' 0 0 2)" "ALLOW"
  echo "== anti-trap — a stop must ALWAYS be reachable =="
  ck "under cap blocks"                      "$(offload_verdict 'gh' 0 1 2)" "BLOCK"
  ck "at cap allows"                         "$(offload_verdict 'gh' 0 2 2)" "ALLOW"
  ck "over cap allows"                       "$(offload_verdict 'gh' 0 9 2)" "ALLOW"
  ck "unreadable counter -> allow"           "$(offload_verdict 'gh' 0 x 2)" "ALLOW"
  ck "unreadable cap -> allow"               "$(offload_verdict 'gh' 0 0 x)" "ALLOW"
  echo "== extraction — a LINE BEGINNING '! ', never a mid-sentence exclamation =="
  ck "plain ask"            "$(extract_asks '! claudebox-rebuild')" "claudebox-rebuild"
  ck "ask inside a paragraph" "$(extract_asks 'Run this to pick it up:

! claudebox-rebuild

then reconnect.')" "claudebox-rebuild"
  ck "indented ask still counts"       "$(extract_asks '    ! claudebox-rebuild')" "claudebox-rebuild"
  ck "path is reduced to its basename" "$(extract_asks '! /usr/local/bin/claudebox-rebuild')" "claudebox-rebuild"
  ck "args are dropped"     "$(extract_asks '! kill -TERM 3320 951')" "kill"
  echo "-- a markdown code span is the natural hand-over shape; it must not wipe the token --"
  ck "backticked command"   "$(extract_asks '! `claudebox-rebuild`')" "claudebox-rebuild"
  ck "code span wrapping the whole ask" "$(extract_asks '`! claudebox-rebuild`')" "claudebox-rebuild"
  echo "-- PROSE MUST NEVER BE AN ASK: each of these resolves as a command if matched mid-line --"
  ck "prose mention is NOT an ask" "$(extract_asks 'the claudebox-rebuild command exists')" ""
  ck "bare bang with no command"   "$(extract_asks 'that is exciting!')" ""
  ck "exclamation then 'test'"  "$(extract_asks 'All green! test coverage is at 100% and the PR is up.')" ""
  ck "exclamation then 'time'"  "$(extract_asks 'Fixed and merged! time to move on to the next issue.')" ""
  ck "exclamation then 'true'"  "$(extract_asks 'It works! true to the original design, nothing else changed.')" ""
  ck "exclamation then 'kill'"  "$(extract_asks 'Nice catch! kill the branch when you get a chance.')" ""
  ck "exclamation then 'echo'"  "$(extract_asks 'Deployed! echo of the old behaviour is gone now.')" ""
  ck "exclamation then 'more'"  "$(extract_asks 'Shipped it! more detail in the PR body.')" ""
  echo "== resolution — only a REAL path on this box, so the quoted-back path is never a lie =="
  ck "a shell keyword is not an executable" "$(resolve_cmd 'if')" ""
  ck "an unknown name resolves to nothing"  "$(resolve_cmd 'this-command-does-not-exist-anywhere')" ""
  echo "== denial detection — generous on purpose (a false trap is worse than a false pass) =="
  ck "classifier denial"    "$(has_denial 'the classifier denied kill')" "1"
  ck "permission wording"   "$(has_denial 'Permission for this action was denied')" "1"
  ck "cannot run wording"   "$(has_denial 'I cannot run this myself')" "1"
  ck "no obstacle named"    "$(has_denial 'please run this for me')" "0"
  echo; echo "no-offload-guard selftest: $p passed, $f failed"; [ "$f" -eq 0 ]; exit
fi

# ---- I/O — every path fails OPEN ------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || exit 0
payload="$(cat 2>/dev/null)" || exit 0
[ -n "$payload" ] || exit 0

# already inside a hook-driven continuation ⇒ allow (second belt against a loop)
printf '%s' "$payload" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true' && exit 0

tp="$(printf '%s' "$payload" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("transcript_path",""))
except Exception: print("")' 2>/dev/null)" || exit 0
[ -n "$tp" ] && [ -r "$tp" ] || exit 0

sid="$(printf '%s' "$payload" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("session_id",""))
except Exception: print("")' 2>/dev/null)" || exit 0

# last assistant text block from the JSONL transcript
msg="$(python3 -c '
import json,sys
p=sys.argv[1]; last=""
try:
    with open(p, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line=line.strip()
            if not line: continue
            try: o=json.loads(line)
            except Exception: continue
            if o.get("type")!="assistant": continue
            c=o.get("message",{}).get("content",[])
            if isinstance(c,list):
                t="".join(b.get("text","") for b in c if isinstance(b,dict) and b.get("type")=="text")
                if t.strip(): last=t
    print(last[-6000:])
except Exception:
    print("")
' "$tp" 2>/dev/null)" || exit 0
[ -n "$msg" ] || exit 0

denial="$(has_denial "$msg")"

# keep only asks that ACTUALLY resolve on this box — an unrunnable name is not an offload
offending=""
while IFS= read -r c; do
  [ -n "$c" ] || continue
  path="$(resolve_cmd "$c")"
  [ -n "$path" ] || continue
  # entries are stored as `cmd|path`, so the dedup must match that shape — testing for " $c " never fires
  case " $offending " in *" $c|"*) : ;; *) offending="$offending $c|$path" ;; esac
done <<EOF
$(extract_asks "$msg")
EOF
offending="${offending# }"

mkdir -p "$NO_OFFLOAD_STATE" 2>/dev/null || exit 0
sid="${sid//[^A-Za-z0-9._-]/_}"          # it becomes a filename — keep it a basename, whatever arrives
cf="$NO_OFFLOAD_STATE/${sid:-nosid}.n"
n=0; [ -f "$cf" ] && n="$(cat "$cf" 2>/dev/null || echo 0)"
case "$n" in ''|*[!0-9]*) n=0 ;; esac

if [ "$(offload_verdict "$offending" "$denial" "$n" "$NO_OFFLOAD_CAP")" != BLOCK ]; then
  rm -f "$cf" 2>/dev/null
  exit 0
fi
printf '%s' "$((n+1))" > "$cf" 2>/dev/null

first="${offending%% *}"; cmd="${first%%|*}"; where="${first##*|}"
python3 - "$cmd" "$where" <<'PY' 2>/dev/null || exit 0
import json,sys
cmd, where = sys.argv[1], sys.argv[2]
print(json.dumps({"decision":"block","reason":(
 f"SELF-SERVICE VIOLATION: you are asking the maintainer to run `{cmd}`, which resolves at {where} "
 "on this box — you can run it yourself.\n\n"
 "Arthur's standing rule is \"if you can run it why ask me?\". On 2026-07-28 this exact ask "
 "(`claudebox-rebuild`) cost six days of a dead loop: the command was on your PATH, it was PROVABLY "
 "INERT against the fault, and the repair that worked was never attempted.\n\n"
 "Do ONE of these before stopping:\n"
 f"  1. RUN `{cmd}` yourself and report the real result; or\n"
 "  2. If it is the wrong remedy, say so and name what you tried INSTEAD; or\n"
 "  3. If something genuinely stops you, state the EXACT command and the EXACT error "
 "(\"the classifier denied `kill -TERM 3320`\") — naming a concrete obstacle is always accepted.\n\n"
 "Also check first whether the apparatus already does this itself (self-refresh applies merged code; "
 "the poller's lock logic takes over a previous-generation holder; the deadman TERMs a wedged poller). "
 "Handing over a command you never tried is the failure this guard exists to stop.")}))
PY
exit 0
