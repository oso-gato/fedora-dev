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
#   repo-labels.sh audit           scan bin/*.sh for labels NOT in this registry (drift); resolves $VARs
#   repo-labels.sh prune <repo> [--commit] [--force]
#                                  DELETE every label on <repo> this registry does not declare for it.
#                                  DRY-RUN by default; an off-registry label that is IN USE is HELD
#                                  unless --force (deleting strips it from those items).
#   repo-labels.sh list            print the registry
#   repo-labels.sh parked          print the labels that take an item OUT of the drivable set
#   repo-labels.sh --selftest      exercise the pure conformance core (no gh / network)
#
# NAMING RULES (what "conforms" means — enforced by label_ok, not by convention):
#   * lowercase kebab-case only: ^[a-z][a-z0-9-]*$ — no capitals, spaces, underscores or punctuation.
#     Capitals are the specific trap: GitHub label matching is case-SENSITIVE on create, so `Backlog`
#     and `backlog` are two different labels and the pipeline would half-work.
#   * 2..40 characters, no leading/trailing/doubled hyphen.
# Covered by repo-labels.test.sh. Control-plane (the pipeline's own vocabulary).
set -uo pipefail

# ---- THE REGISTRY — the single source of truth. name|colour|role|description[|PARKED][|CONTROL] ------
# role: APPLY = the apparatus puts it on;  READ = the apparatus reads it and must understand it.
# Adding a label ANYWHERE in bin/ without adding it here is drift and `audit` fails on it.
#
# THE 5TH FIELD — `PARKED` — marks a label that takes an item OUT OF THE DRIVABLE SET: the loop is not
# supposed to move it, because a human owns its next step. It is deliberately ORTHOGONAL to the role
# column (a PARKED label may be one the apparatus APPLIES — `maintainer-merge` is the R1 hold the loop
# puts on itself — or one it merely READS), which is why it needs its own field rather than being
# inferred from `READ`. It exists because a watchdog that measures PROGRESS must know the difference
# between work that is STUCK and work that is WAITING BY DESIGN: without it, a PR sitting correctly on
# `maintainer-merge` produces an unchanging fingerprint forever and the deadman eventually SIGTERMs a
# perfectly healthy poller and wakes the maintainer — the exact outcome the work-progress axis exists to
# prevent. Consumers read it via `parked` so the set has ONE home (the whole point of this file).
REGISTRY="$(cat <<'EOF'
backlog|0e8a16|APPLY|A planned feature issue the authoring loop may pick up (R2)
live-validate|1d76db|APPLY|Enrolls a PR in the host live-gate — the gating pipeline's entry point (R4)
shipped|5319e7|APPLY|The objective was declared shipped autonomously by the ship actuator (R40)
maintainer-merge|5319e7|APPLY|Touches the confirmed spec — maintainer merges it, never the loop (R1)|PARKED
apparatus-blocked|b60205|APPLY|Bounded auto-recovery is exhausted; a human is genuinely needed|PARKED
host-task|fbca04|APPLY|A ticket addressed to the host agent over the bus (R5)
host-done|0e8a16|APPLY|The host agent completed this ticket (bus outcome)||CONTROL
host-failed|b60205|APPLY|The host agent could not complete this ticket (bus outcome)||CONTROL
objective|5319e7|APPLY|A drafted objective awaiting the maintainer's 'approved' tap (R31 intake)
approved|0e8a16|READ|The MAINTAINER's confirmation — the one human act that authorises planning (R1)
rebuild-approval|fbca04|APPLY|A rebuild ticket awaiting the maintainer's 'approved' tap (R17)|PARKED|CONTROL
halt|b60205|READ|FLEET HALT — freeze every sweeper. Maintainer-only, on the control issue (R9)||CONTROL
escalate|d93f0b|READ|A genuine maintainer decision — removes the item from the drivable set|PARKED
needs-decision|d93f0b|READ|Synonym of escalate, honoured by the ship oracle|PARKED
blocked|d93f0b|READ|Work cannot proceed; not drivable by the loop|PARKED
awaiting-maintainer|d93f0b|READ|Parked pending the maintainer; not drivable by the loop|PARKED
EOF
)"

# The CONTROL repo — the one repo whose machinery owns the host bus + approval vocabulary. Declared HERE,
# above the pure core, because the scope filter is part of that core and `--selftest` must be able to
# override it without reaching the I/O section (ORG is still set further down, next to its first use).
CONTROL_REPO="${LABELS_CONTROL_REPO:-fedora-bootstrap}"

# ---- PURE CORE (--selftest covers exactly this) ----------------------------------------------------
# label_ok <name> → rc 0 iff the name conforms to the naming rules above.
label_ok(){
  local n="${1-}"
  [ -n "$n" ] || return 1
  [ "${#n}" -ge 2 ] && [ "${#n}" -le 40 ] || return 1
  printf '%s' "$n" | grep -qE '^[a-z][a-z0-9]*(-[a-z0-9]+)*$' || return 1
  return 0
}
# THE 6TH FIELD — `CONTROL` — scopes a label to the CONTROL repo only (the host's bus + approval
# vocabulary). It exists because the registry is applied PER REPO by `check`/`ensure`/`prune`, so a flat
# set would demand `host-done`/`host-failed`/`rebuild-approval`/`halt` on every tenant repo — `check`
# would fail everywhere and `ensure` would litter each repo with four labels nothing there ever reads.
# The maintainer's standing instruction is a SMALL controlled set per repo, so a label that only one
# repo's machinery touches must not appear in the other's picker. Empty = every repo in scope.
#
# registry_names [repo] → declared label names, one per line. With a repo, only those in scope FOR it:
# every unscoped label, plus the CONTROL-scoped ones when that repo IS the control repo. Without a repo
# it lists the whole vocabulary (what `audit` grades against — drift is drift wherever it appears).
registry_names(){
  local repo="${1-}"
  if [ -z "$repo" ]; then printf '%s\n' "$REGISTRY" | awk -F'|' 'NF{print $1}'; return; fi
  printf '%s\n' "$REGISTRY" | awk -F'|' -v r="$repo" -v c="$CONTROL_REPO" \
    'NF && ($6=="" || ($6=="CONTROL" && r==c)) {print $1}'
}
# registry_field <name> <n> → the nth field for a registered label (empty if unregistered).
registry_field(){ printf '%s\n' "$REGISTRY" | awk -F'|' -v n="$1" -v f="$2" '$1==n{print $f}'; }
# is_registered <name> → rc 0 iff declared here.
is_registered(){ registry_names | grep -qxF "${1-}"; }
# label_defaults — stdin: shell source. stdout: `VAR|value` for every label-ish variable whose DEFAULT is
# declared inline, i.e. `SOMETHING_LABEL="${OVERRIDE:-value}"`. A comma-separated default (ESCALATE_LABELS)
# yields one line PER name, because the audit grades names and a list is not one.
#
# WHY THIS EXISTS: `audit` used to end its pipeline with `grep -vE '^\$'`, which threw away EVERY variable
# reference — so `--label "$APPROVED_LABEL"` was found and then deliberately discarded. Six labels the
# apparatus genuinely applies or reads (approved · objective · halt · rebuild-approval · host-done ·
# host-failed) were therefore invisible to the drift guard, and it reported "no label drift" over a
# six-label hole. Measured 2026-07-30: registry declared 10, code used 16, audit said clean. A guard that
# cannot see the majority of its own subject is worse than none, because it is TRUSTED.
label_defaults(){
  grep -hoE '[A-Za-z_]*LABELS?="\$\{[A-Za-z_]+:-[^}"]+\}"' \
    | sed -E 's/^([A-Za-z_]+)="\$\{[A-Za-z_]+:-(.*)\}"$/\1|\2/' \
    | awk -F'|' 'NF==2{n=split($2,a,","); for(i=1;i<=n;i++){gsub(/^[ \t]+|[ \t]+$/,"",a[i]); if(a[i]!="") print $1"|"a[i]}}' \
    | sort -u
}
# resolve_token <token> <defaults-block> → the concrete label name(s) the token denotes, one per line.
# A bare literal resolves to itself. A `$VAR` / `"$VAR"` resolves through the defaults block. A variable
# with NO declared default resolves to NOTHING and is reported by the caller as UNRESOLVABLE — never
# silently dropped, which is exactly the failure being fixed here.
resolve_token(){
  local t="${1-}" defs="${2-}"
  t="${t#\"}"; t="${t%\"}"
  case "$t" in
    '$'*|'${'*)
      local v="${t#\$}"; v="${v#\{}"; v="${v%\}}"
      printf '%s\n' "$defs" | awk -F'|' -v v="$v" '$1==v{print $2}'
      ;;
    *) printf '%s\n' "$t" ;;
  esac
}
# parked_names → every label that takes an item OUT of the drivable set (the 5th field), one per line.
# Read by the deadman's work-progress axis so "waiting by design" is never mistaken for "stuck".
parked_names(){ printf '%s\n' "$REGISTRY" | awk -F'|' '$5=="PARKED"{print $1}'; }

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
  echo "== the PARKED set — 'waiting by design' must never be read as 'stuck' =="
  inpk(){ parked_names | grep -qxF "$1" && echo yes || echo no; }
  ck "escalate is parked"            "$(inpk escalate)" "yes"
  ck "needs-decision is parked"      "$(inpk needs-decision)" "yes"
  ck "blocked is parked"             "$(inpk blocked)" "yes"
  ck "awaiting-maintainer is parked" "$(inpk awaiting-maintainer)" "yes"
  ck "maintainer-merge is parked (the R1 hold the loop puts on ITSELF)" "$(inpk maintainer-merge)" "yes"
  ck "apparatus-blocked is parked (already surfaced; a restart cannot help)" "$(inpk apparatus-blocked)" "yes"
  # The other direction is the one that would silently DISABLE the work-progress axis: if an ordinary
  # in-flight label were parked, every live PR would be filtered out, the fingerprint would be empty and
  # the deadman would go permanently quiet — an axis that reports healthy because it is looking at nothing.
  ck "live-validate NOT parked (it IS the drivable state)" "$(inpk live-validate)" "no"
  ck "backlog NOT parked"     "$(inpk backlog)" "no"
  ck "shipped NOT parked"     "$(inpk shipped)" "no"
  ck "every parked label is registered" \
     "$( bad2=""; for n in $(parked_names); do is_registered "$n" || bad2="$bad2 $n"; done; echo "${bad2:-none}" )" "none"

  echo "== label_defaults: the variable defaults the old audit threw away =="
  _src='APPROVED_LABEL="${APPROVED_LABEL:-approved}"
INTAKE_LABEL="${INTAKE_LABEL:-objective}"
ESCALATE_LABELS="${ESCALATE_LABELS:-escalate,needs-decision,blocked}"
NOT_A_LABEL_VAR="${FOO:-bar}"
LABEL="${HOST_TICKET_LABEL:-host-task}"'
  ck "a plain default is harvested"      "$(printf '%s\n' "$_src" | label_defaults | grep '^APPROVED_LABEL|')" "APPROVED_LABEL|approved"
  ck "a differently-named override"      "$(printf '%s\n' "$_src" | label_defaults | grep '^INTAKE_LABEL|')" "INTAKE_LABEL|objective"
  ck "a bare LABEL= is harvested"        "$(printf '%s\n' "$_src" | label_defaults | grep '^LABEL|')" "LABEL|host-task"
  ck "a comma list becomes ONE ROW EACH" "$(printf '%s\n' "$_src" | label_defaults | grep -c '^ESCALATE_LABELS|')" "3"
  ck "a non-label variable is ignored"   "$(printf '%s\n' "$_src" | label_defaults | grep -c 'NOT_A_LABEL_VAR')" "0"

  echo "== resolve_token: a \$VAR resolves; an UNDECLARED one resolves to NOTHING (never silently kept) =="
  _defs="$(printf '%s\n' "$_src" | label_defaults)"
  ck "a bare literal is itself"        "$(resolve_token 'backlog' "$_defs")" "backlog"
  ck "a quoted \$VAR resolves"         "$(resolve_token '"$APPROVED_LABEL"' "$_defs")" "approved"
  ck "an unquoted \$VAR resolves"      "$(resolve_token '$INTAKE_LABEL' "$_defs")" "objective"
  ck "a \${braced} \$VAR resolves"      "$(resolve_token '"${LABEL}"' "$_defs")" "host-task"
  # sorted, not source-ordered: label_defaults ends in `sort -u` so a duplicate default cannot inflate
  # the set. Order is not part of the contract — membership is — so the row asserts the SET.
  ck "a multi-value var yields all"    "$(resolve_token '$ESCALATE_LABELS' "$_defs" | sort | tr '\n' ' ')" "blocked escalate needs-decision "
  ck "an UNDECLARED var resolves to nothing" "$(resolve_token '"$MYSTERY_LABEL"' "$_defs")" ""

  echo "== the CONTROL scope keeps a repo's picker small =="
  ck "control-only labels are OUT of a tenant's set" \
     "$(LABELS_CONTROL_REPO=fedora-bootstrap; registry_names fedora-dev | grep -cE '^(host-done|host-failed|rebuild-approval|halt)$')" "0"
  ck "…and IN the control repo's set" \
     "$(registry_names fedora-bootstrap | grep -cE '^(host-done|host-failed|rebuild-approval|halt)$')" "4"
  ck "the unscoped core is in BOTH"    \
     "$(registry_names fedora-dev | grep -cE '^(backlog|live-validate|objective|approved)$')" "4"
  ck "no repo requires more than the whole vocabulary" \
     "$([ "$(registry_names fedora-bootstrap | grep -c .)" -le "$(registry_names | grep -c .)" ] && echo ok)" "ok"
  echo; echo "repo-labels selftest: $p passed, $f failed"; [ "$f" -eq 0 ]; exit
fi

ORG="${ORG:-oso-gato}"
log(){ echo "repo-labels: $*" >&2; }

case "${1:-}" in
  list) printf '%s\n' "$REGISTRY" | awk -F'|' 'NF{printf "%-22s %-6s %-7s %s\n",$1,$3,($5=="PARKED"?"PARKED":"-"),$4}'; exit 0 ;;

  # The non-drivable set, for consumers that must tell "stuck" from "waiting by design". Pure + local
  # (no gh, no network), so a caller on the watchdog's hot path can read it on every check for free.
  parked) parked_names; exit 0 ;;

  check)
    REPO="${2:?usage: repo-labels.sh check <repo>}"
    have="$(gh label list --repo "$ORG/$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null)" || {
      log "cannot read labels on $ORG/$REPO (unreadable — NOT the same as 'none missing')"; exit 3; }
    missing=""
    for n in $(registry_names "$REPO"); do printf '%s\n' "$have" | grep -qxF "$n" || missing="$missing $n"; done
    if [ -n "$missing" ]; then log "$ORG/$REPO MISSING:${missing}"; exit 1; fi
    log "$ORG/$REPO: all $(registry_names "$REPO" | grep -c .) labels required FOR THIS REPO are present"; exit 0 ;;

  ensure)
    REPO="${2:?usage: repo-labels.sh ensure <repo>}"
    # R16 OPERATING SCOPE — `ensure` is a WRITE actuator (it creates labels on a repo), and R16 rule 4 is
    # "every actuator checks scope before acting", not "every actuator whose caller happens to have
    # checked". Its one caller today (dev-author.sh) does check first, so this is defence in depth — but
    # a scope check that lives only in the caller is one refactor away from being absent, which is
    # precisely how #165 reached a foreign repo. Fail-closed: any non-zero reader rc (127 included) is a
    # refusal, and SCOPE_SESSION (if the caller exported one) narrows this to the same declared scope.
    HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
    REPO_SCOPE="${REPO_SCOPE:-$HERE/repo-scope.sh}"
    "$REPO_SCOPE" check "$REPO" 2>/dev/null || {
      log "R16 SCOPE: '$REPO' is outside the operating scope — creating NO labels on it"; exit 4; }
    have="$(gh label list --repo "$ORG/$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null)" || {
      log "cannot read labels on $ORG/$REPO — not establishing blind (fail-closed)"; exit 3; }
    made=0 failed=""
    for n in $(registry_names "$REPO"); do
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
    # DRIFT GUARD: a label used in bin/ that this registry does not declare.
    # The vocabulary has ONE home, and a script inventing its own is caught here.
    # Variable references are now RESOLVED through their declared defaults instead of discarded — see
    # label_defaults for what that filter was hiding.
    HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
    src="$(cat "$HERE"/*.sh 2>/dev/null | grep -vE '^[[:space:]]*#')"
    defs="$(printf '%s\n' "$src" | label_defaults)"
    toks="$(printf '%s\n' "$src" \
             | grep -oE -- '--add-label ("?\$\{?[A-Za-z_]+\}?"?|[a-zA-Z][a-zA-Z0-9_-]*)|--label ("?\$\{?[A-Za-z_]+\}?"?|"?[a-z][a-z0-9-]{2,30}"?)' \
             | sed -E 's/^--(add-)?label //' | sort -u)"
    drift="" unresolved=""
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      names="$(resolve_token "$t" "$defs")"
      if [ -z "$names" ]; then
        # A variable with no declared default. Report it — a token we cannot resolve is precisely the
        # thing the old `grep -v '^\$'` swallowed, and silence here is how the hole reopens.
        case "$t" in *'$'*) unresolved="$unresolved $t";; esac
        continue
      fi
      while IFS= read -r n; do
        [ -n "$n" ] || continue
        # A dynamically-built name (host-$st) cannot be graded statically; its concrete forms are
        # declared in the registry (host-done/host-failed) and the construction is flagged, not ignored.
        case "$n" in *'$'*) unresolved="$unresolved $n"; continue;; esac
        is_registered "$n" || drift="$drift $n"
      done <<EOF
$names
EOF
    done <<EOF
$toks
EOF
    drift="$(printf '%s' "$drift" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
    unresolved="$(printf '%s' "$unresolved" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
    rc=0
    if [ -n "${drift// /}" ]; then
      log "LABEL DRIFT — used in bin/ but not declared in the registry:${drift}"
      log "add it to REGISTRY (with a role + description) or stop using it — the vocabulary has one home"
      rc=1
    fi
    [ -n "${unresolved// /}" ] && log "NOTE — label tokens that cannot be graded statically:${unresolved} (declare their concrete forms in the registry)"
    [ "$rc" = 0 ] && log "no label drift — every label used in bin/ is declared ($(registry_names | grep -c .) in the registry)"
    exit "$rc" ;;

  prune)
    # PRUNE — delete every label on <repo> that this registry does NOT declare for it. The maintainer's
    # standing instruction is a SMALL controlled set per repo ("I don't want to see all those other label
    # choices"), and until this existed the cleanup was a hand-run loop that nothing could repeat.
    #
    # DESTRUCTIVE, so it is DRY-RUN BY DEFAULT and needs `--commit` to act (the auto-merge.sh idiom).
    # Deleting a label also STRIPS IT from every issue and PR carrying it, so an off-registry label that
    # is IN USE is HELD, listed, and left alone unless `--force` is also given: losing a maintainer's
    # historical triage is not a tidy-up, and a prune that quietly does it would be a worse defect than
    # the clutter it removes. Registry labels are NEVER candidates, whatever the flags.
    REPO="${2:?usage: repo-labels.sh prune <repo> [--commit] [--force]}"; shift 2 || true
    COMMIT=0; FORCE=0
    for a in "$@"; do case "$a" in --commit) COMMIT=1;; --force) FORCE=1;; esac; done
    HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
    REPO_SCOPE="${REPO_SCOPE:-$HERE/repo-scope.sh}"
    "$REPO_SCOPE" check "$REPO" 2>/dev/null || {
      log "R16 SCOPE: '$REPO' is outside the operating scope — deleting NOTHING on it"; exit 4; }
    have="$(gh label list --repo "$ORG/$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null)" || {
      log "cannot read labels on $ORG/$REPO — not pruning blind (fail-closed)"; exit 3; }
    keep="$(registry_names "$REPO")"
    del=0 held=0 failed=""
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      printf '%s\n' "$keep" | grep -qxF "$n" && continue          # registered for this repo → never touched
      used="$(gh api "repos/$ORG/$REPO/issues?labels=$(printf '%s' "$n" | sed 's/ /%20/g')&state=all&per_page=100" \
                -q 'length' 2>/dev/null)"
      case "$used" in ''|*[!0-9]*) used=UNKNOWN;; esac
      if [ "$used" = UNKNOWN ]; then
        log "HOLD '$n' — could not read its usage; not deleting on an unreadable count (fail-closed)"; held=$((held+1)); continue
      fi
      if [ "$used" -gt 0 ] && [ "$FORCE" = 0 ]; then
        log "HOLD '$n' — off-registry but IN USE on $used item(s); --force to delete anyway (it would be stripped from them)"
        held=$((held+1)); continue
      fi
      if [ "$COMMIT" = 0 ]; then
        log "WOULD DELETE '$n' (off-registry, $used item(s))"; del=$((del+1)); continue
      fi
      if gh label delete "$n" --repo "$ORG/$REPO" --yes >/dev/null 2>&1; then
        log "deleted '$n' from $ORG/$REPO ($used item(s) affected)"; del=$((del+1))
      else failed="$failed $n"; fi
    done <<EOF
$have
EOF
    [ -n "${failed// /}" ] && { log "$ORG/$REPO: could NOT delete:${failed}"; exit 1; }
    if [ "$COMMIT" = 0 ]; then
      log "$ORG/$REPO: DRY RUN — $del would be deleted, $held held. Re-run with --commit to act."
    else
      log "$ORG/$REPO: pruned $del, held $held"
    fi
    exit 0 ;;

  *) echo "usage: repo-labels.sh {check|ensure|audit|prune|list|parked|--selftest} [repo] [--commit] [--force]" >&2; exit 2 ;;
esac
