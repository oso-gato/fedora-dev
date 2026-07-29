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
  echo; echo "ship-actuator selftest: $p passed, $f failed"; [ "$f" -eq 0 ]; exit
fi

# ---- config -----------------------------------------------------------------------------------------
REPO="${1:?usage: ship-actuator.sh <repo> | --selftest}"
ORG="${ORG:-oso-gato}"; SLUG="$ORG/$REPO"
OBJECTIVE_STATUS="${OBJECTIVE_STATUS:-$HERE/objective-status.sh}"
SHIP_GATE="${SHIP_GATE:-$HERE/ship-gate.sh}"
SHIP_ANNOUNCE_LABEL="${SHIP_ANNOUNCE_LABEL:-shipped}"
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

# CLOSE THE OBJECTIVE TICKET. Announcing a ship while the objective issue stays OPEN is the same
# "merged ≠ done" dishonesty the reconciler exists to prevent, one level up: the bus would carry a SHIPPED
# notice and an open objective at the same time, and the open ticket is what a reader believes. rc 0 when
# it closed OR when there was nothing open to close; rc 1 only on a real failure, so the caller can defer
# the done-marker and retry. Idempotent: it searches OPEN objectives, so a re-tick finds none.
close_objective(){
  local n
  n="$(gh issue list --repo "$SLUG" --state open --search 'OBJECTIVE in:title' \
       --json number -q '.[0].number' 2>/dev/null)"
  [ -n "$n" ] || { log "$SLUG: no OPEN objective issue to close — nothing to do"; return 0; }
  if gh issue close "$n" --repo "$SLUG" --comment "**Objective SHIPPED — closed autonomously (R40).**

- **Aggregate:** \`$sha\`
- **R30 completion:** no drivable work remains — every backlog ticket closed on observed proof.
- **R34 ship gate:** an independent adversarial spec-vs-build review PASSED this exact aggregate.

Closed by \`bin/ship-actuator.sh\` on the same evidence as the ship announcement. No human declared this
finished — a run only a human can declare finished is not an autonomous run." >/dev/null 2>&1; then
    log "$SLUG: CLOSED objective issue #$n @ ${sha:0:7}"; return 0
  fi
  log "$SLUG: could not close objective issue #$n — the ship stands; deferring the marker so this retries"
  return 1
}

title="SHIPPED: $REPO objective @ ${sha:0:7}"
if gh api -X GET search/issues -f q="repo:$SLUG in:title \"$title\"" -q '.items[0].number' 2>/dev/null | grep -q '[0-9]'; then
  log "$SLUG: a ship announcement for ${sha:0:7} already exists — reconciling the objective ticket"
  close_objective && : > "$marker"
  exit 0
fi

body="**The objective is SHIPPED — declared autonomously (R40), with no human sign-off.**

- **Aggregate:** \`$sha\`
- **R30 completion:** no drivable work remains (backlog closed with proof links; no open dev PRs).
- **R34 ship gate:** an independent, adversarial spec-vs-build review PASSED this aggregate — verified
  against the objective, then the requirements, then the build principles.

$(printf '%s\n' "$status_block" | sed 's/^/    /')

<sub>bin/ship-actuator.sh (R40) — the loop closed its own objective. No human noticed completion or
triggered this; a run only a human can declare finished is not an autonomous run.</sub>"

if gh issue create --repo "$SLUG" --title "$title" --body "$body" --label "$SHIP_ANNOUNCE_LABEL" >/dev/null 2>&1 \
   || gh issue create --repo "$SLUG" --title "$title" --body "$body" >/dev/null 2>&1; then
  log "$SLUG @ ${sha:0:7}: SHIP ANNOUNCED on the bus"
  close_objective && : > "$marker"
else
  log "$SLUG: announce post FAILED — no marker written, retrying next tick"; exit 0
fi

# Ledger (best-effort; a proof run must never die on a ledger write).
if mkdir -p "$AUTONOMY_RUNS_DIR" 2>/dev/null; then
  { printf '# SHIPPED — %s @ %s\n\n' "$SLUG" "$sha"
    printf 'Declared autonomously by bin/ship-actuator.sh (R40) at %s UTC.\n\n' "$(date -u +%FT%TZ 2>/dev/null)"
    printf '%s\n' "$status_block"
  } > "$AUTONOMY_RUNS_DIR/shipped-$REPO-$(date -u +%Y-%m-%d-%H%M%S 2>/dev/null).md" 2>/dev/null \
    || log "ledger write failed (non-fatal)"
fi
exit 0
