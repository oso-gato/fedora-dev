#!/usr/bin/env bash
# pr-poller.sh — the DEV-SIDE POLLER / wake-up mechanism (GOVERNANCE §5 / #93 Step 5).
#
# The host is already autonomous: it live-gates a labelled PR and posts a GREEN/RED verdict on its own
# timer. This closes the DEV-side gap — a supervised, PLAIN-SHELL (NO Claude in the loop) watcher on
# fedora-dev that reacts to each new host verdict:
#
#   RED   → spawn a BOUNDED headless `claude -p` that iterates and pushes a fix to the FEATURE branch
#           (the new head SHA re-triggers the host gate). The dev pushes fixes — NEVER the host, NEVER
#           main; the fixer holds NO merge step. NO FIXED ITERATION CAP: it loops until GREEN or until
#           it stops making progress (same failure signature twice / the fixer reports BLOCKED), which
#           is SURFACED as a decision — never a quiet quit (doctrine mandate 6).
#   GREEN → run the independent fitness harness (bin/fitness-review.sh); then the merge decision:
#           Tier A → present to Arthur (never auto); Tier B/C + fitness PASS → bin/auto-merge.sh.
#
# SAFE BY DEFAULT — DISARMED: the GREEN→merge path calls auto-merge.sh in --dry-run (prints the
# DECISION, merges nothing) UNLESS POLLER_ARMED=1. Arming (flipping to --commit) is the LAST step and a
# Tier-A change gated on Arthur's click (#96) — building the poller changes nothing until armed. And
# auto-merge.sh itself re-checks all three gates fail-closed, so a stale plan can never mis-merge.
#
# The poller has NO merge credential of its own: it only OBSERVES, spawns a feature-branch fixer, and
# delegates the merge to the dumb, gate-checked auto-merge.sh. It cannot be prompt-injected — it runs no
# model; the only model it spawns is the disposable fixer, whose prompt forbids merge/main.
#
# Usage:
#   pr-poller.sh --once                # one sweep of all open PRs, then exit (cron / manual / testing)
#   pr-poller.sh --watch               # supervised loop (singleton via flock), sweeps every $POLL_INTERVAL
#   pr-poller.sh --selftest            # exercise the pure plan()/verdict extractors (no network/model)
#
# Config (env):
#   POLLER_REPO       repo to watch (default: fedora-dev — the poller watches its OWN repo's PRs)
#   LG_HOST_LOGIN     host bot login whose verdict is trusted (default: oso-gato-erebus-claudebox[bot])
#   FITNESS_LOGIN     fitness bot login (passed through to fitness-review.sh + auto-merge.sh)
#   POLLER_ARMED      1 → GREEN+B/C+PASS actually merges (auto-merge --commit). Default 0 (dry-run).
#   POLL_INTERVAL     seconds between --watch sweeps (default 60, matching the host watcher cadence)
#   POLLER_FIXER      headless fixer command (default: claude -p). Overridable for testing.
#   FIXER_TIMEOUT     max seconds for ONE fixer run (default 1800). Bounds a single iteration, not the
#                     count of iterations.
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"

# ===================================================================================================
# PURE decision core — no I/O, exercised by --selftest.
# ===================================================================================================

# extract the newest host live-gate verdict (GREEN|RED) from a blob of host-bot comment bodies on stdin.
host_verdict(){ grep -oE 'Host live-gate \(Gate B\): VERDICT (GREEN|RED)' | grep -oE '(GREEN|RED)$' | tail -1; }
# extract the newest fitness verdict (PASS|RETURN|ESCALATE) from fitness-bot comment bodies on stdin.
fitness_verdict(){ grep -oE 'Fitness review: VERDICT (PASS|RETURN|ESCALATE)' | grep -oE '(PASS|RETURN|ESCALATE)$' | tail -1; }

# plan <host:GREEN|RED|NONE> <tier:A|B|C|""> <fitness:PASS|RETURN|ESCALATE|NONE> <armed:0|1>
#   -> NOOP | FIX | REVIEW | MERGE | MERGE_DRYRUN | PRESENT
# The single source of truth for "given the gates, what does the poller DO". Fail-closed toward the
# human: any ambiguity (unknown tier, no host verdict) resolves to NOOP or PRESENT, never to a merge.
plan(){
  local host="$1" tier="$2" fit="$3" armed="$4"
  case "$host" in
    RED)  echo FIX; return;;                          # host says broken → iterate a fix
    GREEN) : ;;                                        # fall through to the merge decision
    *)    echo NOOP; return;;                          # no host verdict yet (NONE) → wait
  esac
  case "$tier" in
    A) echo PRESENT; return;;                          # Tier A NEVER auto-merges — Arthur's click
    B|C) : ;;
    *) echo PRESENT; return;;                          # unknown/unclassifiable tier → human (fail-closed)
  esac
  case "$fit" in
    NONE)     echo REVIEW;   return;;                  # GREEN but not yet fitness-reviewed → review it
    PASS)     [ "$armed" = 1 ] && echo MERGE || echo MERGE_DRYRUN; return;;
    RETURN)   echo FIX;      return;;                  # fitness wants rework → back to the developer
    ESCALATE) echo PRESENT;  return;;                  # fitness defers to Arthur
    *)        echo PRESENT;  return;;                  # unknown fitness token → human (fail-closed)
  esac
}

if [ "${1:-}" = "--selftest" ]; then
  fail=0
  ck(){ local got; got="$(plan "$2" "$3" "$4" "$5")"; [ "$got" = "$6" ] && echo "ok: $1" || { echo "FAIL: $1 — plan($2,$3,$4,$5)=$got want $6"; fail=1; }; }
  ck "no verdict"         NONE  B   NONE 0 NOOP
  ck "red"                RED   B   NONE 0 FIX
  ck "red ignores tier"   RED   A   PASS 1 FIX
  ck "green tierA"        GREEN A   PASS 1 PRESENT
  ck "green B unreviewed" GREEN B   NONE 0 REVIEW
  ck "green C unreviewed" GREEN C   NONE 0 REVIEW
  ck "green B pass armed" GREEN B   PASS 1 MERGE
  ck "green B pass disarm" GREEN B  PASS 0 MERGE_DRYRUN
  ck "green C pass armed" GREEN C   PASS 1 MERGE
  ck "green B return"     GREEN B   RETURN 1 FIX
  ck "green B escalate"   GREEN B   ESCALATE 1 PRESENT
  ck "green unknown tier" GREEN ""  PASS 1 PRESENT
  ck "green unknown fit"  GREEN B   WAT  1 PRESENT
  vg(){ local got; got="$(printf '%s' "$2" | host_verdict)"; [ "$got" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 — got '$got' want '$3'"; fail=1; }; }
  vg "host green"  'Host live-gate (Gate B): VERDICT GREEN'                                 GREEN
  vg "host latest" $'…VERDICT RED\nHost live-gate (Gate B): VERDICT GREEN'                   GREEN
  vg "host none"   'some unrelated comment'                                                 ""
  fv(){ local got; got="$(printf '%s' "$2" | fitness_verdict)"; [ "$got" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 — got '$got' want '$3'"; fail=1; }; }
  fv "fit pass"    'Fitness review: VERDICT PASS'                                           PASS
  fv "fit latest"  $'Fitness review: VERDICT RETURN\nFitness review: VERDICT PASS'          PASS
  [ "$fail" = 0 ] && echo "ALL POLLER SELFTESTS PASS" || echo "POLLER SELFTESTS FAILED"
  exit "$fail"
fi

# ===================================================================================================
# I/O layer — the real sweep.
# ===================================================================================================
POLLER_REPO="${POLLER_REPO:-fedora-dev}"
SLUG="oso-gato/$POLLER_REPO"
# login MUST be the GraphQL form (no `[bot]` suffix) — that is what `gh pr view --json comments`
# returns and what auto-merge.sh matches against. REST's `.user.login` adds `[bot]`; do NOT use it.
LG_HOST_LOGIN="${LG_HOST_LOGIN:-oso-gato-erebus-claudebox}"
FITNESS_LOGIN="${FITNESS_LOGIN:-}"
POLLER_ARMED="${POLLER_ARMED:-0}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
POLLER_FIXER="${POLLER_FIXER:-claude -p}"
FIXER_TIMEOUT="${FIXER_TIMEOUT:-1800}"
STATE="$HOME/.local/state/pr-poller"; mkdir -p "$STATE"
LOG="$STATE/poller.log"
log(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG" >&2; }

# Surface a decision to Arthur WITHOUT merging: a single idempotent comment per (pr,sha,kind). The
# poller never clicks — it makes the human touchpoint visible and stops churning.
surface(){ # <pr> <sha> <kind> <message>
  local pr="$1" sha="$2" kind="$3" msg="$4" m="$STATE/surfaced-${pr}-${sha}-${kind}.done"
  [ -f "$m" ] && return 0
  log "SURFACE $SLUG#$pr @ ${sha:0:7} [$kind]: $msg"
  gh pr comment "$pr" --repo "$SLUG" --body "**Poller → Arthur [$kind]:** $msg"$'\n\n<sub>dev-side poller (Step 5); no merge taken — needs your decision.</sub>' >/dev/null 2>&1 && : > "$m"
}

# Spawn ONE bounded fixer iteration on a RED (or fitness-RETURN) PR. Feature-branch only, no merge.
run_fixer(){ # <pr> <headref> <sha> <reason>
  local pr="$1" ref="$2" sha="$3" reason="$4"
  local sig; sig="$(printf '%s' "$reason" | tr -cd '[:alnum:]' | tail -c 40)"
  local sigfile="$STATE/fixsig-${pr}.last" prev=""; [ -f "$sigfile" ] && prev="$(cat "$sigfile")"
  # PROGRESS-BASED STOP (not a count cap): if we already ran a fixer for THIS exact failure signature
  # and the head has NOT advanced past what we fixed, we are not making progress → surface, don't churn.
  local lastfixed="$STATE/fixed-${pr}.sha"; local lf=""; [ -f "$lastfixed" ] && lf="$(cat "$lastfixed")"
  if [ "$sig" = "$prev" ] && [ "$sha" = "$lf" ]; then
    surface "$pr" "$sha" "blocked" "the same failure persists after a fix attempt (no progress) — a human decision is needed. Reason: ${reason:0:400}"
    return 0
  fi
  printf '%s' "$sig" > "$sigfile"; printf '%s' "$sha" > "$lastfixed"
  log "FIX $SLUG#$pr @ ${sha:0:7} ref=$ref — spawning bounded fixer (timeout ${FIXER_TIMEOUT}s)"
  local prompt
  read -r -d '' prompt <<FIX_EOF || true
You are the fedora-dev RED-fix iteration for PR $SLUG#$pr (branch: $ref). The host live-gate returned a
problem. Your ONE job: make a MINIMAL, correct fix and push it to the FEATURE branch '$ref' so the host
re-gates. HARD RULES: work only on '$ref'; NEVER merge, NEVER push or target main, NEVER touch the merge
gate. If you cannot fix it (need a decision, missing access, or the approach is wrong), do NOT guess —
end your reply with a line 'FIXER_BLOCKED: <one-line reason>' and push nothing. Otherwise fix, commit,
and push to '$ref'. The failure the host reported:

$reason
FIX_EOF
  local out; out="$(cd "$HOME/.local/share/$POLLER_REPO" 2>/dev/null && timeout "$FIXER_TIMEOUT" $POLLER_FIXER "$prompt" 2>&1)"
  local blocked; blocked="$(printf '%s' "$out" | grep -oE '^FIXER_BLOCKED:.*' | head -1)"
  if [ -n "$blocked" ]; then
    surface "$pr" "$sha" "blocked" "fixer reported BLOCKED — ${blocked#FIXER_BLOCKED:}"
  else
    log "fixer finished for $SLUG#$pr — new head (if pushed) will re-gate on the host's next sweep"
  fi
}

sweep(){
  log "sweep: $SLUG open PRs (armed=$POLLER_ARMED)"
  local prs; prs="$(gh pr list --repo "$SLUG" --state open --json number,headRefName,headRefOid 2>/dev/null)"
  [ -n "$prs" ] || { log "no open PRs / list failed"; return 0; }
  local n; n="$(printf '%s' "$prs" | grep -oE '"number":[0-9]+' | grep -oE '[0-9]+')"
  local pr
  for pr in $n; do
    local ref sha comments host tier fit action
    ref="$(gh pr view "$pr" --repo "$SLUG" --json headRefName -q .headRefName 2>/dev/null)"
    sha="$(gh pr view "$pr" --repo "$SLUG" --json headRefOid -q .headRefOid 2>/dev/null)"
    [ -n "$sha" ] || { log "#$pr: no head sha — skip"; continue; }
    # newest host verdict authored by the trusted host bot ONLY (ignore anyone else) at/for this PR.
    comments="$(gh pr view "$pr" --repo "$SLUG" --json comments \
                -q ".comments[] | select(.author.login==\"$LG_HOST_LOGIN\") | .body" 2>/dev/null)"
    host="$(printf '%s' "$comments" | host_verdict)"; host="${host:-NONE}"
    # dedup: act on each (pr,sha,host-verdict) at most once for the terminal actions; REVIEW/FIX manage
    # their own re-entry (fitness marker; progress signature), so only gate the whole sweep-action here.
    local done="$STATE/acted-${pr}-${sha}-${host}.done"
    tier="$(gh pr view "$pr" --repo "$SLUG" --json files -q '.files[].path' 2>/dev/null | "$HERE/tier-classify.sh" --stdin 2>/dev/null)"; tier="${tier:-A}"
    fit="NONE"
    if [ -n "$FITNESS_LOGIN" ]; then
      fit="$(gh pr view "$pr" --repo "$SLUG" --json comments \
             -q ".comments[] | select(.author.login==\"$FITNESS_LOGIN\") | .body" 2>/dev/null | fitness_verdict)"; fit="${fit:-NONE}"
    fi
    action="$(plan "$host" "$tier" "$fit" "$POLLER_ARMED")"
    log "#$pr ${sha:0:7} host=$host tier=$tier fitness=$fit ⇒ $action"
    case "$action" in
      NOOP) : ;;
      FIX)
        local reason; reason="$(printf '%s' "$comments" | grep -A3 'VERDICT RED' | tail -3)"
        run_fixer "$pr" "$ref" "$sha" "${reason:-host live-gate RED; see the host verdict comment on the PR}"
        ;;
      REVIEW)
        [ -f "$done" ] && continue
        log "#$pr GREEN + unreviewed → running fitness harness"
        FITNESS_LOGIN="$FITNESS_LOGIN" LG_HOST_LOGIN="$LG_HOST_LOGIN" "$HERE/fitness-review.sh" --post "$POLLER_REPO" "$pr" \
          && log "#$pr fitness posted — next sweep routes on it" \
          || log "#$pr fitness harness declined/failed (fail-closed: no PASS ⇒ no merge)"
        ;;
      MERGE|MERGE_DRYRUN)
        [ -f "$done" ] && continue
        local flag=""; [ "$action" = MERGE ] && flag="--commit"
        log "#$pr GREEN+B/C+PASS → auto-merge.sh $flag"
        LG_HOST_LOGIN="$LG_HOST_LOGIN" FITNESS_LOGIN="$FITNESS_LOGIN" "$HERE/auto-merge.sh" $flag "$POLLER_REPO" "$pr" | tee -a "$LOG"
        : > "$done"
        ;;
      PRESENT)
        surface "$pr" "$sha" "review" "GREEN PR needs your decision (tier=$tier, fitness=$fit). Present for a clickable merge — the poller does not auto-merge this."
        : > "$done"
        ;;
    esac
  done
}

case "${1:-}" in
  --once) sweep;;
  --watch)
    exec 9>"$STATE/poller.lock"
    flock -n 9 || { echo "another pr-poller --watch holds the lock; exiting" >&2; exit 0; }
    trap 'log "poller stopping (signal)"; exit 0' TERM INT HUP
    log "pr-poller --watch up (repo=$SLUG interval=${POLL_INTERVAL}s armed=$POLLER_ARMED)"
    while :; do sweep || log "sweep error (continuing)"; sleep "$POLL_INTERVAL"; done
    ;;
  *) echo "usage: pr-poller.sh --once | --watch | --selftest" >&2; exit 2;;
esac
