#!/usr/bin/env bash
# ship-actuator.sh — R40 AUTONOMOUS SHIP ACTUATOR: the loop closes its OWN objective.
#
# WHY THIS EXISTS: the apparatus could recognize completion but not ACT on it. bin/objective-status.sh
# (the R30 oracle) reports SHIPPED/OPEN and bin/ship-gate.sh (the R34 gate) can judge the built product —
# but NOTHING invoked the gate or announced the result, so a human had to notice the work was finished
# and trigger the last step. An objective only a human can declare finished is not an autonomous run
# (R40). This actuator closes that gap: it watches for "the only remaining step is the ship gate",
# runs it, and announces the ship — with no human in the path.
#
# THE CYCLE (one pass; the poller ticks it):
#   1. READ the R30 oracle for the bound repo (read-only; it never runs the gate itself).
#   2. If the objective is would-be-shipped and the ONLY thing missing is the R34 verdict
#      (STATUS=OPEN, DRIVABLE=0, SHIP_GATE=PENDING) → INVOKE `ship-gate.sh --post`. The gate is
#      idempotent per aggregate sha, so a re-tick costs nothing once a verdict exists.
#   3. Re-read the oracle. If it now reads SHIPPED → ANNOUNCE once per aggregate (a bus issue + a
#      dated ledger line), then stop. A RETURN verdict simply leaves it OPEN and the loop keeps working.
#
# FAIL-SAFE BY CONSTRUCTION (R39 — this must never become a new way for the loop to stall): every
# failure path logs and returns 0. An unreadable oracle, a gate that cannot run, a failed announce —
# none of them block the poller, and none consume the objective. The announce marker is written ONLY
# after a successful post, so a failed announce simply retries next tick.
#
#   ship-actuator.sh <repo>     run one cycle (rc 0 always — see fail-safe above)
#   ship-actuator.sh --selftest exercise the pure decision core (no gh / no model)
#
# ENV: OBJECTIVE_STATUS · SHIP_GATE · SHIP_ANNOUNCE_LABEL · AUTONOMY_RUNS_DIR · STATE
# Covered by ship-actuator.test.sh. Control-plane (the ship boundary's actuator). MUST be tracked 100755.
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"

# ---- PURE CORE (--selftest covers exactly this) ----------------------------------------------------
# decide <status> <drivable> <shipgate> → RUN_GATE | ANNOUNCE | WAIT
#   RUN_GATE — nothing drivable is left and the R34 verdict is the only missing piece: run the gate.
#   ANNOUNCE — the oracle certifies SHIPPED (a PASS bound to this aggregate): announce it, once.
#   WAIT     — anything else: drivable work remains, the oracle cannot speak, or the gate RETURNed.
# Fail-closed toward WAIT: an unparsable input never triggers an action.
decide(){
  local status="${1:-}" drivable="${2:-}" shipgate="${3:-}"
  [ "$status" = SHIPPED ] && { printf 'ANNOUNCE'; return; }
  case "$drivable" in ''|*[!0-9]*) printf 'WAIT'; return;; esac
  if [ "$status" = OPEN ] && [ "$drivable" -eq 0 ] && [ "$shipgate" != PASS ]; then
    printf 'RUN_GATE'; return
  fi
  printf 'WAIT'
}

# objective_pick <announce-label>   (stdin: `<number>\t<title>\t<labels-csv>` candidate rows)
# Chooses the ONE ticket close_objective() may close. Prints `NONE`, `AMBIGUOUS #a #b…`, or `<n>\t<title>`.
#
# WHY THIS IS A FUNCTION AND NOT `-q '.[0].number'`: GitHub issue SEARCH is fuzzy and returns RELEVANCE
# order, so `.[0]` let an opaque ranker decide which ticket the loop closes. Two things then went wrong at
# once: (1) SELF-COLLISION — the actuator's own announcement is titled `SHIPPED: <repo> objective @ <sha>`,
# contains the word "objective", and is left OPEN, so it was a candidate for the very search meant to find
# the objective; picking it closed the SHIP RECORD, logged "CLOSED objective issue #N" (untrue), wrote the
# done-marker and left the objective open — exactly the "a SHIPPED notice and an open objective at once"
# state this actuator exists to prevent. (2) COLLATERAL — `OBJECTIVE in:title` matches the word ANYWHERE,
# case-insensitively: live on fedora-dev it returns #131 (the apparatus spec) and #210 (an ordinary feature
# ticket about `<sid>.objective` provenance), either of which would have been closed with a SHIPPED comment.
#
# So the target must be POSITIVELY IDENTIFIED, never inferred from a ranker, and the pick DETERMINISTIC:
#   * announcements are excluded by BOTH their label and their title shape (belt-and-braces — the announce
#     create falls back to a LABEL-LESS `gh issue create`, so a label-only filter would miss exactly the
#     announcements that fallback produces);
#   * duplicates collapse (the same issue legitimately arrives from both candidate queries);
#   * TWO surviving candidates is AMBIGUOUS ⇒ the caller refuses. Guessing which of a maintainer's tickets
#     to close is not a decision this loop gets to make on a coin-flip.
objective_pick(){
  local ann="${1:-shipped}"
  awk -F'\t' -v ann="$ann" '
    $1 !~ /^[0-9]+$/            { next }                       # malformed row: never a close target
    $2 ~ /^SHIPPED: .* objective @ / { next }                  # our OWN announcement shape
    { lc = "," $3 ","; if (index(lc, "," ann ",")) next }      # …or anything wearing the announce label
    !seen[$1]++                 { k++; num[k]=$1; ttl[$1]=$2 }
    END{
      if (k == 0) { print "NONE"; exit }
      if (k > 1)  { s = "AMBIGUOUS"; for (i=1; i<=k; i++) s = s " #" num[i]; print s; exit }
      printf "%s\t%s\n", num[1], ttl[num[1]]
    }'
}

if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"; else f=$((f+1)); printf '  FAIL %s want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  ck "shipped → announce"              "$(decide SHIPPED 0 PASS)"        "ANNOUNCE"
  ck "shipped wins over odd inputs"    "$(decide SHIPPED x '')"          "ANNOUNCE"
  ck "empty backlog + pending → run"   "$(decide OPEN 0 PENDING)"        "RUN_GATE"
  ck "drivable work → wait"            "$(decide OPEN 2 PENDING)"        "WAIT"
  ck "gate RETURNed (still pending)"   "$(decide OPEN 0 PENDING)"        "RUN_GATE"
  ck "indeterminate → wait"            "$(decide INDETERMINATE 0 PENDING)" "WAIT"
  ck "non-numeric drivable → wait"     "$(decide OPEN '' PENDING)"       "WAIT"
  ck "already PASS but not shipped"    "$(decide OPEN 0 PASS)"           "WAIT"

  # objective_pick — the target the loop is allowed to close.
  OBJ=$'1\tOBJECTIVE: a minimal status-page image\t'
  ANN=$'9\tSHIPPED: e2e-beta objective @ abc1234\t'
  ANNL=$'9\tSHIPPED: e2e-beta objective @ abc1234\tshipped'
  ck "picks the lone objective"        "$(printf '%s\n' "$OBJ"        | objective_pick shipped)" $'1\tOBJECTIVE: a minimal status-page image'
  # THE REGRESSION ROW: the announcement is created OPEN, carries the word "objective", and outranked the
  # objective under relevance order. It must never be the pick, labelled or not.
  ck "announcement never wins"         "$(printf '%s\n%s\n' "$ANN" "$OBJ"  | objective_pick shipped | cut -f1)" "1"
  ck "announcement never wins (label)" "$(printf '%s\n%s\n' "$ANNL" "$OBJ" | objective_pick shipped | cut -f1)" "1"
  ck "announcement alone → NONE"       "$(printf '%s\n' "$ANN"        | objective_pick shipped)" "NONE"
  ck "same issue from both queries"    "$(printf '%s\n%s\n' "$OBJ" "$OBJ"  | objective_pick shipped | cut -f1)" "1"
  ck "two objectives → AMBIGUOUS"      "$(printf '%s\n2\tOBJECTIVE: another\t\n' "$OBJ" | objective_pick shipped)" "AMBIGUOUS #1 #2"
  ck "malformed row ignored"           "$(printf 'x\tnot a number\t\n'     | objective_pick shipped)" "NONE"
  ck "no candidates → NONE"            "$(printf ''                       | objective_pick shipped)" "NONE"
  echo; echo "ship-actuator selftest: $p passed, $f failed"; [ "$f" -eq 0 ]; exit
fi

# ---- config -----------------------------------------------------------------------------------------
REPO="${1:?usage: ship-actuator.sh <repo> | --selftest}"
ORG="${ORG:-oso-gato}"; SLUG="$ORG/$REPO"
OBJECTIVE_STATUS="${OBJECTIVE_STATUS:-$HERE/objective-status.sh}"
SHIP_GATE="${SHIP_GATE:-$HERE/ship-gate.sh}"
SHIP_ANNOUNCE_LABEL="${SHIP_ANNOUNCE_LABEL:-shipped}"
INTAKE_LABEL="${INTAKE_LABEL:-objective}"        # what bin/intake-file.sh files every objective under
OBJECTIVE_TITLE="${OBJECTIVE_TITLE:-OBJECTIVE:}" # the legacy/hand-filed objective's strict title prefix
# DISCLOSED RESIDUAL: identification is deliberately narrow, so a repo whose objective matches NEITHER
# criterion gets the announcement and an honest "nothing identified" log, not a guessed close. Live today:
# e2e-beta#1 ("OBJECTIVE: a minimal status-page…") is identified; fedora-dev#131 ("APPARATUS SPEC:
# autonomous host+dev development loop (the objective)") is NOT — it is hand-filed and predates the intake
# label. The remedy is configuration, not code: apply the `objective` label to it, or set OBJECTIVE_TITLE.
# That is the correct trade — the alternative is a ranker closing whichever ticket happens to rank first.
AUTONOMY_RUNS_DIR="${AUTONOMY_RUNS_DIR:-$HOME/autonomy-runs}"
STATE="${STATE:-$HOME/.local/state/ship-actuator}"; mkdir -p "$STATE" 2>/dev/null || true
log(){ echo "ship-actuator: $*" >&2; }

# read the oracle once; returns the KV block (never fatal — an unreadable oracle just yields WAIT)
status_block="$("$OBJECTIVE_STATUS" --status "$REPO" 2>/dev/null)" || true
kv(){ printf '%s\n' "$status_block" | sed -n "s/^$1: *//p" | head -1; }
st="$(kv STATUS)"; drv="$(kv DRIVABLE)"; sg="$(kv SHIP_GATE)"
[ -n "$st" ] || { log "$SLUG: the R30 oracle said nothing (unreadable) — WAIT (fail-safe, loop unaffected)"; exit 0; }

action="$(decide "$st" "$drv" "$sg")"
log "$SLUG: status=$st drivable=$drv ship-gate=$sg ⇒ $action"

case "$action" in
  WAIT) exit 0 ;;

  RUN_GATE)
    # The objective is would-be-shipped and the R34 verdict is the only missing piece. Run the gate.
    # It is idempotent per aggregate sha (a verdict already there ⇒ no model run), so ticking is cheap.
    # rc 3 = the reviewer could not run (infra) — that is NOT a failure of the objective; log and retry
    # next tick. rc 1 = a refused precondition (scope / SoD). Neither ever blocks the loop.
    if "$SHIP_GATE" --post "$REPO" >&2; then
      log "$SLUG: R34 ship gate ran and recorded a verdict — re-reading the oracle"
    else
      log "$SLUG: R34 ship gate did not produce a verdict (rc $?) — no verdict posted, retrying next tick (R39: bounded, never a stall)"
      exit 0
    fi
    # Re-read: a PASS flips the oracle to SHIPPED; a RETURN leaves it OPEN and the loop keeps working.
    status_block="$("$OBJECTIVE_STATUS" --status "$REPO" 2>/dev/null)" || true
    [ "$(kv STATUS)" = SHIPPED ] || { log "$SLUG: gate did not PASS the aggregate — objective stays OPEN, loop continues (correct: R34 sends it back)"; exit 0; }
    log "$SLUG: gate PASSED — announcing the ship"
    ;;& # fall through to ANNOUNCE

  ANNOUNCE) : ;;
esac

# ---- ANNOUNCE (once per shipped aggregate) ----------------------------------------------------------
# The durable record of an autonomous ship. Marker-gated by the aggregate sha so a re-tick is silent,
# and the marker is written ONLY after a successful post — a failed announce retries, never vanishes.
sha="$(gh api "repos/$SLUG/branches/main" -q .commit.sha 2>/dev/null)"
[ -n "$sha" ] || { log "$SLUG: cannot read the shipped aggregate sha — announce deferred to the next tick"; exit 0; }
marker="$STATE/shipped-${REPO}-${sha}.done"
[ -e "$marker" ] && { log "$SLUG @ ${sha:0:7}: already announced — silent"; exit 0; }

# CANDIDATES — the OPEN tickets that are POSITIVELY identified as this repo's objective. Two independent
# identifications, unioned (an issue legitimately matching both is collapsed by objective_pick):
#   (a) the $INTAKE_LABEL label — what bin/intake-file.sh stamps on every objective it files (the
#       forward-going convention; the title there is free-form, so a title rule alone would miss them);
#   (b) a STRICT $OBJECTIVE_TITLE title prefix, re-checked HERE in shell because issue search is fuzzy —
#       the objective-status.sh $PLAN_TITLE precedent. `OBJECTIVE in:title` matches the
#       word anywhere and case-insensitively, so the remote query is a candidate FETCH, never the decision.
# rc 1 when NEITHER query could be read: a transient API failure must not read as "no objective to close"
# (that would write the done-marker and lose the close forever — the fail-open direction).
objective_candidates(){
  local by_label by_title ok=1
  local jqf='.[] | [(.number|tostring), .title, ([.labels[].name]|join(","))] | @tsv'
  by_label="$(gh issue list --repo "$SLUG" --state open --label "$INTAKE_LABEL" --limit 50 \
              --json number,title,labels -q "$jqf" 2>/dev/null)" && ok=0
  by_title="$(gh issue list --repo "$SLUG" --state open --search "$OBJECTIVE_TITLE in:title" --limit 50 \
              --json number,title,labels -q "$jqf" 2>/dev/null)" && ok=0
  [ "$ok" = 0 ] || return 1
  { printf '%s\n' "$by_label"
    printf '%s\n' "$by_title" | awk -F'\t' -v p="$OBJECTIVE_TITLE" 'index($2,p)==1'
  } | grep -v '^[[:space:]]*$'
  return 0
}

# CLOSE THE OBJECTIVE TICKET. Announcing a ship while the objective issue stays OPEN is the same
# "merged ≠ done" dishonesty the reconciler exists to prevent, one level up: the bus would carry a SHIPPED
# notice and an open objective at the same time, and the open ticket is what a reader believes. rc 0 when
# it closed OR when there was nothing open to close; rc 1 on a real failure, an unreadable candidate list,
# or an AMBIGUOUS one — so the caller defers the done-marker and retries. Idempotent: it reads OPEN
# tickets, so a re-tick finds none. AMBIGUOUS deliberately retries rather than guessing: it costs two
# cheap list calls a tick, names the candidates in the log every time (never a silent stall), and heals
# itself the moment a human resolves the ambiguity.
close_objective(){
  local cands pick n t
  cands="$(objective_candidates)" \
    || { log "$SLUG: cannot read the objective candidates (both queries failed) — deferring the marker so the close retries"; return 1; }
  pick="$(printf '%s\n' "$cands" | sort -t"$(printf '\t')" -k1,1n | objective_pick "$SHIP_ANNOUNCE_LABEL")"
  case "$pick" in
    NONE|'') log "$SLUG: no OPEN issue is positively identified as the objective (label '$INTAKE_LABEL' or title '$OBJECTIVE_TITLE …') — nothing to close"; return 0 ;;
    AMBIGUOUS*) log "$SLUG: ${pick#AMBIGUOUS } are BOTH identified as the objective — refusing to guess which to close; resolve the ambiguity and this closes on the next tick"; return 1 ;;
  esac
  n="${pick%%$'\t'*}"; t="${pick#*$'\t'}"
  if gh issue close "$n" --repo "$SLUG" --comment "**Objective SHIPPED — closed autonomously (R40).**

- **Aggregate:** \`$sha\`
- **R30 completion:** no drivable work remains — every backlog ticket closed on observed proof.
- **R34 ship gate:** an independent adversarial spec-vs-build review PASSED this exact aggregate.

Closed by \`bin/ship-actuator.sh\` on the same evidence as the ship announcement. No human declared this
finished — a run only a human can declare finished is not an autonomous run." >/dev/null 2>&1; then
    log "$SLUG: CLOSED objective issue #$n ($t) @ ${sha:0:7}"; return 0
  fi
  log "$SLUG: could not close objective issue #$n ($t) — the ship stands; deferring the marker so this retries"
  return 1
}

# ---- CLOSE FIRST, THEN ANNOUNCE ---------------------------------------------------------------------
# THE ORDER IS LOAD-BEARING. The announcement is titled `SHIPPED: <repo> objective @ <sha>` and is left
# OPEN, so creating it BEFORE the close made it a live candidate for the very lookup that finds the
# objective. Closing first removes the collision at its source for the fresh path; objective_pick()'s
# filters are the belt for every later tick, where the announcement exists for good.
close_rc=0; close_objective || close_rc=1

body="**The objective is SHIPPED — declared autonomously (R40), with no human sign-off.**

- **Aggregate:** \`$sha\`
- **R30 completion:** no drivable work remains (backlog closed with proof links; no open dev PRs).
- **R34 ship gate:** an independent, adversarial spec-vs-build review PASSED this aggregate — verified
  against the objective, then the requirements, then the build principles.

$(printf '%s\n' "$status_block" | sed 's/^/    /')

<sub>bin/ship-actuator.sh (R40) — the loop closed its own objective. No human noticed completion or
triggered this; a run only a human can declare finished is not an autonomous run.</sub>"

created=0
title="SHIPPED: $REPO objective @ ${sha:0:7}"
if gh api -X GET search/issues -f q="repo:$SLUG in:title \"$title\"" -q '.items[0].number' 2>/dev/null | grep -q '[0-9]'; then
  log "$SLUG: a ship announcement for ${sha:0:7} already exists — reconciling the objective ticket"
elif gh issue create --repo "$SLUG" --title "$title" --body "$body" --label "$SHIP_ANNOUNCE_LABEL" >/dev/null 2>&1 \
  || gh issue create --repo "$SLUG" --title "$title" --body "$body" >/dev/null 2>&1; then
  log "$SLUG @ ${sha:0:7}: SHIP ANNOUNCED on the bus"; created=1
else
  log "$SLUG: announce post FAILED — no marker written, retrying next tick"; exit 0
fi

# The done-marker is the ship's "both halves landed" record: it is written ONLY when the objective ticket
# is settled too, so an unclosed objective retries instead of being sealed behind a silent marker.
[ "$close_rc" = 0 ] || exit 0
: > "$marker"
[ "$created" = 1 ] || exit 0

# Ledger (best-effort; a proof run must never die on a ledger write).
if mkdir -p "$AUTONOMY_RUNS_DIR" 2>/dev/null; then
  { printf '# SHIPPED — %s @ %s\n\n' "$SLUG" "$sha"
    printf 'Declared autonomously by bin/ship-actuator.sh (R40) at %s UTC.\n\n' "$(date -u +%FT%TZ 2>/dev/null)"
    printf '%s\n' "$status_block"
  } > "$AUTONOMY_RUNS_DIR/shipped-$REPO-$(date -u +%Y-%m-%d-%H%M%S 2>/dev/null).md" 2>/dev/null \
    || log "ledger write failed (non-fatal)"
fi
exit 0
