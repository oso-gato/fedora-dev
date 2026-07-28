#!/usr/bin/env bash
# repo-labels.sh — THE LABEL CONTRACT: one declared schema for every label the apparatus applies or
# reads, with conformance validation, idempotent establishment, and a drift audit.
#
# WHY THIS EXISTS (the 2026-07-27 E2E-A finding): `live-validate` did not exist in a newly-enrolled
# repo, so `gh pr edit --add-label` failed SILENTLY, six authored PRs carried no labels, the host never
# gated them, and the poller logged `host=NONE ⇒ NOOP` 1,142 times over 12 hours without one alarm.
# Worse, the stall detector watches PRs LABELLED live-validate — so it was structurally blind to the
# one failure that occurred. The cost was not the missing label; it was that NOTHING DECLARED that the
# label had to exist. Each script carried its own default string and nobody owned the set.
#
# THIS IS THE FIRST LINE OF DEFENCE. A label that is missing, misnamed, or invented off-schema is
# caught HERE — before work is attempted — instead of surfacing as a silent no-op hours later.
#
#   repo-labels.sh check <repo>    rc 0 iff every REQUIRED label exists on <repo>; lists what is missing
#   repo-labels.sh ensure <repo>   idempotently CREATE any missing label (safe to run every time)
#   repo-labels.sh audit           scan bin/*.sh for label literals that are NOT in this registry (drift)
#   repo-labels.sh list            print the registry
#   repo-labels.sh --selftest      exercise the pure conformance core (no gh / network)
#
# NAMING RULES (what "conforms" means — enforced by label_ok, not by convention):
#   * lowercase kebab-case only: ^[a-z][a-z0-9-]*$ — no capitals, spaces, underscores or punctuation.
#     Capitals are the specific trap: GitHub label matching is case-SENSITIVE on create, so `Backlog`
#     and `backlog` are two different labels and the pipeline would half-work.
#   * 2..40 characters, no leading/trailing/doubled hyphen.
# Covered by repo-labels.test.sh. Control-plane (the pipeline's own vocabulary).
set -uo pipefail

# ---- THE REGISTRY — the single source of truth. name|colour|role|description ------------------------
# role: APPLY = the apparatus puts it on;  READ = the apparatus reads it and must understand it.
# Adding a label ANYWHERE in bin/ without adding it here is drift and `audit` fails on it.
REGISTRY="$(cat <<'EOF'
backlog|0e8a16|APPLY|A planned feature issue the authoring loop may pick up (R2)
live-validate|1d76db|APPLY|Enrolls a PR in the host live-gate — the gating pipeline's entry point (R4)
shipped|5319e7|APPLY|The objective was declared shipped autonomously by the ship actuator (R40)
maintainer-merge|5319e7|APPLY|Touches the confirmed spec — maintainer merges it, never the loop (R1)
apparatus-blocked|b60205|APPLY|Bounded auto-recovery is exhausted; a human is genuinely needed
host-task|fbca04|APPLY|A ticket addressed to the host agent over the bus (R5)
escalate|d93f0b|READ|A genuine maintainer decision — removes the item from the drivable set
needs-decision|d93f0b|READ|Synonym of escalate, honoured by the ship oracle
blocked|d93f0b|READ|Work cannot proceed; not drivable by the loop
awaiting-maintainer|d93f0b|READ|Parked pending the maintainer; not drivable by the loop
EOF
)"

# ---- PURE CORE (--selftest covers exactly this) ----------------------------------------------------
# label_ok <name> → rc 0 iff the name conforms to the naming rules above.
label_ok(){
  local n="${1-}"
  [ -n "$n" ] || return 1
  [ "${#n}" -ge 2 ] && [ "${#n}" -le 40 ] || return 1
  printf '%s' "$n" | grep -qE '^[a-z][a-z0-9]*(-[a-z0-9]+)*$' || return 1
  return 0
}
# registry_names → every declared label name, one per line.
registry_names(){ printf '%s\n' "$REGISTRY" | awk -F'|' 'NF{print $1}'; }
# registry_field <name> <n> → the nth field for a registered label (empty if unregistered).
registry_field(){ printf '%s\n' "$REGISTRY" | awk -F'|' -v n="$1" -v f="$2" '$1==n{print $f}'; }
# is_registered <name> → rc 0 iff declared here.
is_registered(){ registry_names | grep -qxF "${1-}"; }

if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"; else f=$((f+1)); printf '  FAIL %s want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  y(){ label_ok "$1" && echo 1 || echo 0; }
  echo "== label_ok — conformance is ENFORCED, not a convention =="
  ck "plain lowercase"        "$(y backlog)" "1"
  ck "kebab-case"             "$(y live-validate)" "1"
  ck "digits allowed"         "$(y e2e-gate2)" "1"
  ck "CAPITALS rejected"      "$(y Backlog)" "0"
  ck "mixed case rejected"    "$(y liveValidate)" "0"
  ck "space rejected"         "$(y 'live validate')" "0"
  ck "underscore rejected"    "$(y live_validate)" "0"
  ck "leading hyphen rejected"  "$(y -backlog)" "0"
  ck "trailing hyphen rejected" "$(y backlog-)" "0"
  ck "doubled hyphen rejected"  "$(y live--validate)" "0"
  ck "empty rejected"         "$(y '')" "0"
  ck "single char rejected"   "$(y b)" "0"
  echo "== the registry itself must conform (it is the schema; it cannot be exempt) =="
  bad=""; for n in $(registry_names); do label_ok "$n" || bad="$bad $n"; done
  ck "every registered label conforms" "${bad:-none}" "none"
  ck "registry is non-empty"  "$( [ "$(registry_names | grep -c .)" -ge 8 ] && echo yes || echo no )" "yes"
  ck "live-validate declared" "$(is_registered live-validate && echo yes || echo no)" "yes"
  ck "unknown not declared"   "$(is_registered not-a-real-label && echo yes || echo no)" "no"
  echo; echo "repo-labels selftest: $p passed, $f failed"; [ "$f" -eq 0 ]; exit
fi

ORG="${ORG:-oso-gato}"
log(){ echo "repo-labels: $*" >&2; }

case "${1:-}" in
  list) printf '%s\n' "$REGISTRY" | awk -F'|' 'NF{printf "%-22s %-6s %s\n",$1,$3,$4}'; exit 0 ;;

  check)
    REPO="${2:?usage: repo-labels.sh check <repo>}"
    have="$(gh label list --repo "$ORG/$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null)" || {
      log "cannot read labels on $ORG/$REPO (unreadable — NOT the same as 'none missing')"; exit 3; }
    missing=""
    for n in $(registry_names); do printf '%s\n' "$have" | grep -qxF "$n" || missing="$missing $n"; done
    if [ -n "$missing" ]; then log "$ORG/$REPO MISSING:${missing}"; exit 1; fi
    log "$ORG/$REPO: all $(registry_names | grep -c .) required labels present"; exit 0 ;;

  ensure)
    REPO="${2:?usage: repo-labels.sh ensure <repo>}"
    have="$(gh label list --repo "$ORG/$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null)" || {
      log "cannot read labels on $ORG/$REPO — not establishing blind (fail-closed)"; exit 3; }
    made=0 failed=""
    for n in $(registry_names); do
      printf '%s\n' "$have" | grep -qxF "$n" && continue
      if gh label create "$n" --repo "$ORG/$REPO" --color "$(registry_field "$n" 2)" \
           --description "$(registry_field "$n" 4)" >/dev/null 2>&1; then
        made=$((made+1)); log "created '$n' on $ORG/$REPO"
      else failed="$failed $n"; fi
    done
    [ "$made" = 0 ] && [ -z "$failed" ] && log "$ORG/$REPO: already conformant (nothing to create)"
    [ -n "$failed" ] && { log "$ORG/$REPO: could NOT create:${failed}"; exit 1; }
    exit 0 ;;

  audit)
    # DRIFT GUARD: a label literal used in bin/ that this registry does not declare. Mirrors the
    # doc-dry-audit discipline — the vocabulary has ONE home, and a script inventing its own is caught.
    HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
    found="$(grep -rhE -- '--add-label|--label ' "$HERE"/*.sh 2>/dev/null | grep -vE '^[[:space:]]*#' \
             | grep -oE -- '--add-label ([a-zA-Z][a-zA-Z0-9_-]*)|--label "?([a-z][a-z0-9-]{2,30})"?' \
             | sed -E 's/^--(add-)?label "?//; s/"$//' | sort -u | grep -vE '^\$' )"
    drift=""
    for n in $found; do is_registered "$n" || drift="$drift $n"; done
    if [ -n "$drift" ]; then
      log "LABEL DRIFT — used in bin/ but not declared in the registry:${drift}"
      log "add it to REGISTRY (with a role + description) or stop using it — the vocabulary has one home"
      exit 1
    fi
    log "no label drift — every label used in bin/ is declared"; exit 0 ;;

  *) echo "usage: repo-labels.sh {check|ensure|audit|list|--selftest} [repo]" >&2; exit 2 ;;
esac
