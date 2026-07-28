#!/usr/bin/env bash
# anomaly-repair.test.sh — the R39 anomaly router's I/O layer (surface_or_repair).
#
# The pure routing decision is covered by `pr-poller.sh --selftest`. THIS covers the layer that
# actually spends the budget and picks the door, because that is where the 2026-07-27 behaviour
# really lives: an unanticipated state must try bounded SELF-REPAIR and reach a human only when
# repair is inapplicable or spent. run_fixer/surface are stubbed — no network, no worktree, no model.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
STATE="$(mktemp -d)"; POLLER_REPAIR_MAX=3; SLUG=oso-gato/test-repo
eval "$(sed -n '/^anomaly_route(){/,/^}/p' "$HERE/pr-poller.sh")"
eval "$(sed -n '/^surface_or_repair(){/,/^}/p' "$HERE/pr-poller.sh")"
log(){ :; }
run_fixer(){ echo "REPAIR->fixer(cause=$4)"; }
surface(){ echo "SURFACE->human($3)"; }
p=0; f=0
ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); echo "  ok   $1"; else f=$((f+1)); echo "  FAIL $1 got=[$2] want=[$3]"; fi; }
R="REPAIR->fixer(cause=ANOMALY)"

echo "== THE 12-HOUR STALL, REPLAYED — an unenrolled PR repairs itself, and reaches a human LAST =="
ck "attempt 1 repairs"       "$(surface_or_repair 9 feat/x abc123 unenrolled 'no label')" "$R"
ck "attempt 2 repairs"       "$(surface_or_repair 9 feat/x abc123 unenrolled 'no label')" "$R"
ck "attempt 3 repairs"       "$(surface_or_repair 9 feat/x abc123 unenrolled 'no label')" "$R"
ck "4th ESCALATES to human"  "$(surface_or_repair 9 feat/x abc123 unenrolled 'no label')" "SURFACE->human(unenrolled)"
ck "and STAYS escalated"     "$(surface_or_repair 9 feat/x abc123 unenrolled 'no label')" "SURFACE->human(unenrolled)"

echo "== budgets are PER ANOMALY KIND — one stuck state must not eat another's attempts =="
ck "a different kind has its own budget" "$(surface_or_repair 9 feat/x abc123 stalled 'no verdict')" "$R"
ck "a different PR has its own budget"   "$(surface_or_repair 8 feat/y abc123 unenrolled 'no label')" "$R"

echo "== SAFETY — the paths that must NEVER self-repair =="
ck "no branch ref -> human (nothing to commit to)" "$(surface_or_repair 9 '' abc123 stalled 'x')" "SURFACE->human(stalled)"
ck "repair machinery broken -> human"              "$(surface_or_repair 9 feat/x abc123 infra 'no clone')" "SURFACE->human(infra)"
ck "a refusal is not repairable"                   "$(surface_or_repair 9 feat/x abc123 refused 'scope')" "SURFACE->human(refused)"
ck "a trust event is not repairable"               "$(surface_or_repair 9 feat/x abc123 trust 'identity')" "SURFACE->human(trust)"

echo "== the kill switch restores the OLD behaviour exactly =="
POLLER_REPAIR_MAX=0
ck "repair disabled -> human" "$(surface_or_repair 7 feat/z def456 stalled 'x')" "SURFACE->human(stalled)"

rm -rf "$STATE"
echo; echo "anomaly-repair: $p passed, $f failed"; [ "$f" -eq 0 ]
