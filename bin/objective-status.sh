#!/usr/bin/env bash
# objective-status.sh — the R30 WHOLE-OBJECTIVE SHIP ORACLE: an EXTERNAL, read-only FACT source that
# answers, for the session's bound objective, "is there DRIVABLE OPEN WORK, or is the objective SHIPPED?"
#
# WHY THIS EXISTS (the durable fix for the interactive-driver FALSE-STOP, #25): every prior anti-stall
# defence trusted a MODEL-AUTHORED signal. The Stop hook honoured any `DONE:`/`BLOCKED:` sentinel by its
# FORM, never its TRUTH — so the exact failure the maintainer hit recurs: the agent pushes a PR, reaches
# the host-gate boundary, declares "DONE — my tier is finished / the host must validate this" and stops,
# mid-objective. Doctrine text cannot bind that disposition. A FACT can. This oracle is that fact: the
# stop-gate VERIFIES a self-declared DONE/BLOCKED against it, so a false-DONE with drivable work still open
# is BLOCKED with the EXACT next drive action, and a false-BLOCKED-on-"another-box's-tier" is refused —
# host-GATED work is DEV-OWNED (you DRIVE the `live-validate` round-trip; the host EXECUTES your ticket).
#
# THE FACTS (all GitHub/clone-derived — NO local state; the reconcile.sh/host-refresh.sh precedent):
#   * OPEN BACKLOG  — `backlog`-labelled OPEN issues in the bound repo (dev-plan filed them, one per
#     feature; a CLOSED backlog issue is a PROOF-shipped feature — reconcile.sh closes it only on the
#     full merge+host-GREEN+CI-published+live chain). ANY open one ⇒ unshipped, drivable (author it).
#   * OPEN DEV PRs  — OPEN PRs authored by $DEV_LOGIN, not carrying an escalation label. Each is DEV-
#     drivable (label `live-validate` → read the verdict → iterate RED→GREEN → the poller merges). This
#     is the signal that nails the maintainer's complaint: a pushed-but-unmerged PR is NOT "done".
#   * ACCEPTANCE PROBE (optional) — a side-effect-free command the objective declares
#     ($OBJECTIVE_ACCEPTANCE, else <objective-doc-dir>/objective-acceptance.sh if executable). It guards
#     the "off-backlog work reads SHIPPED" false-positive: DECLARED-and-FAILING ⇒ OPEN even with an empty
#     backlog. ABSENT ⇒ the emptiness of backlog+PRs is the ship evidence (a probe is not required to ship).
#
# VERDICT (pure `classify`): OPEN iff drivable≥1 OR probe FAILs · SHIPPED iff drivable=0 AND probe∈{PASS,
# ABSENT} AND the objective left evidence it existed (a backlog EVER, or a passing probe) · INDETERMINATE
# otherwise (no anchor / unreadable GitHub / zero evidence). The gate treats INDETERMINATE as "the oracle
# adds nothing here" and FALLS BACK to its heuristic — it NEVER traps on the oracle's silence (fail-open).
#
#   objective-status.sh --status [<repo>]   emit the STATUS block (KV, newline-framed) for the bound repo
#   objective-status.sh --selftest          exercise the pure core (no gh / git / network)
#
# ENV: ORG (oso-gato) · DEV_LOGIN (oso-gato-nox-claudebox) · BACKLOG_LABEL (backlog) · OBJECTIVE_REPO or
#      $1 or the session anchor ($SCOPE_REGISTRY_DIR/<sid>.objective line1 field1; sid from OBJECTIVE_SID/
#      CLAUDE_SESSION_ID) · ESCALATE_LABELS (escalate,needs-decision,blocked,awaiting-maintainer) ·
#      OBJECTIVE_ACCEPTANCE (probe path) · OS_PROBE_TIMEOUT (20). FAIL-CLOSED to INDETERMINATE on any
#      unreadable input. Covered by objective-status.test.sh. **Control-plane (ship-recognition oracle).**
set -uo pipefail

ORG="${ORG:-oso-gato}"
DEV_LOGIN="${DEV_LOGIN:-oso-gato-nox-claudebox}"
BACKLOG_LABEL="${BACKLOG_LABEL:-backlog}"
ESCALATE_LABELS="${ESCALATE_LABELS:-escalate,needs-decision,blocked,awaiting-maintainer}"
OS_PROBE_TIMEOUT="${OS_PROBE_TIMEOUT:-20}"
SCOPE_REGISTRY_DIR="${SCOPE_REGISTRY_DIR:-$HOME/.local/state/scope-registry}"

log(){ echo "objective-status: $*" >&2; }

# ---- PURE CORE (no I/O) — exercised by --selftest --------------------------------------------------

# pr_drivable <author> <dev_login> <labels-csv> → 1 iff an OPEN dev PR is DEV-drivable (mine, not escalated
# to a maintainer). A pushed-but-unmerged PR of MINE is drivable work — labelling live-validate, reading
# the verdict, iterating RED→GREEN are all MY move, never "another box's tier". Only an explicit escalation
# label (a genuine maintainer decision) removes it from the drivable set.
pr_drivable(){
  local author="$1" me="$2" labels="$3" l
  [ -n "$me" ] && [ "$author" = "$me" ] || { printf 0; return; }
  local IFS=,
  for l in $ESCALATE_LABELS; do
    [ -n "$l" ] || continue
    printf '%s' ",$labels," | grep -qF ",$l," && { printf 0; return; }   # escalated ⇒ not drivable
  done
  printf 1
}

# classify <drivable-count> <probe:PASS|FAIL|ABSENT> <ever-backlog:0|1> → SHIPPED | OPEN | INDETERMINATE.
#   OPEN         — positive drivable work remains, OR a declared probe FAILs (the assembled objective does
#                  not yet work). This is the anti-false-stop teeth.
#   SHIPPED       — nothing drivable AND the probe does not fail AND the objective left ship evidence
#                  (a backlog existed, or the probe positively passed). Requiring evidence closes the
#                  "empty backlog + no probe reads vacuously SHIPPED" hole (that returns INDETERMINATE).
#   INDETERMINATE — the oracle cannot speak (no evidence the objective was ever decomposed and no probe);
#                  the gate then uses its heuristic — the oracle never TRAPS on its own silence.
classify(){
  local drivable="$1" probe="$2" ever="$3"
  case "$drivable" in ''|*[!0-9]*) echo INDETERMINATE; return;; esac
  [ "$probe" = FAIL ] && { echo OPEN; return; }
  [ "$drivable" -ge 1 ] && { echo OPEN; return; }
  if [ "$probe" = PASS ] || [ "$ever" = 1 ]; then echo SHIPPED; else echo INDETERMINATE; fi
}

# next_action <open-backlog:0|1> <first-backlog#> <first-drivable-pr#> <first-pr-has-live-validate:0|1>
#   → the ONE-LINE exact next DRIVE action the gate injects into a false-DONE/false-BLOCKED block.
next_action(){
  local ob="$1" bkl="$2" pr="$3" lv="$4"
  if [ "$ob" = 1 ] && [ -n "$bkl" ]; then
    printf 'author + ship backlog issue #%s (implement → push a branch → label it `live-validate` → drive the host verdict to GREEN → the poller merges).' "$bkl"
  elif [ -n "$pr" ]; then
    if [ "$lv" = 1 ]; then
      printf 'drive PR #%s: read its host live-gate verdict — RED ⇒ fix + re-push, GREEN ⇒ it merges on fitness PASS (address a fitness RETURN). This is DEV-owned; do not hand it off.' "$pr"
    else
      printf 'drive PR #%s: label it `live-validate`, then iterate the host round-trip RED→GREEN yourself (host-EXECUTED is not host-OWNED).' "$pr"
    fi
  else
    printf 'the acceptance probe fails — the assembled objective does not yet work; fix it before declaring DONE.'
  fi
}

# ---- SELFTEST --------------------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  echo "== pr_drivable (mine + not escalated) =="
  ck "my PR, no labels → drivable"        "$(pr_drivable oso-gato-nox-claudebox oso-gato-nox-claudebox 'live-validate')" "1"
  ck "my PR, escalated → not drivable"    "$(pr_drivable oso-gato-nox-claudebox oso-gato-nox-claudebox 'live-validate,escalate')" "0"
  ck "my PR, needs-decision → not"        "$(pr_drivable oso-gato-nox-claudebox oso-gato-nox-claudebox 'needs-decision')" "0"
  ck "someone else's PR → not mine"       "$(pr_drivable arthur oso-gato-nox-claudebox '')" "0"
  ck "empty dev-login proves nothing"     "$(pr_drivable oso-gato-nox-claudebox '' 'live-validate')" "0"
  ck "substring not a false escalate"     "$(pr_drivable oso-gato-nox-claudebox oso-gato-nox-claudebox 'blockeder')" "1"
  echo "== classify (SHIPPED / OPEN / INDETERMINATE) =="
  ck "drivable work → OPEN"               "$(classify 2 ABSENT 1)" "OPEN"
  ck "probe FAIL, empty backlog → OPEN"   "$(classify 0 FAIL 0)" "OPEN"
  ck "none + backlog existed → SHIPPED"   "$(classify 0 ABSENT 1)" "SHIPPED"
  ck "none + probe PASS → SHIPPED"        "$(classify 0 PASS 0)" "SHIPPED"
  ck "none + no evidence → INDETERMINATE" "$(classify 0 ABSENT 0)" "INDETERMINATE"
  ck "non-numeric → INDETERMINATE"        "$(classify '' ABSENT 1)" "INDETERMINATE"
  ck "probe FAIL wins over evidence"      "$(classify 0 FAIL 1)" "OPEN"
  echo "== next_action (the exact drive step) =="
  ck "open backlog → author it"           "$(next_action 1 41 '' 0 | grep -o 'author + ship backlog issue #41')" "author + ship backlog issue #41"
  ck "labelled PR → read the verdict"     "$(next_action 0 '' 233 1 | grep -o 'drive PR #233: read its host')" "drive PR #233: read its host"
  ck "unlabelled PR → label live-validate" "$(next_action 0 '' 233 0 | grep -o 'label it `live-validate`')" "label it \`live-validate\`"
  ck "no work → probe failure"            "$(next_action 0 '' '' 0 | grep -o 'acceptance probe fails')" "acceptance probe fails"
  echo; echo "objective-status selftest: $p passed, $f failed"; [ "$f" -eq 0 ]; exit
fi

# ---- LIVE PATH -------------------------------------------------------------------------------------
[ "${1:-}" = "--status" ] || { echo "usage: objective-status.sh --status [<repo>] | --selftest" >&2; exit 2; }
shift || true

emit(){ # <status> <reason> [next]
  printf 'STATUS: %s\n' "$1"
  printf 'REPO: %s\n' "${REPO:-}"
  printf 'OPEN_BACKLOG: %s\n' "${open_backlog:-?}"
  printf 'OPEN_DEV_PRS: %s\n' "${drivable:-?}"
  printf 'DRIVABLE: %s\n' "${drivable_total:-?}"
  printf 'PROBE: %s\n' "${probe:-ABSENT}"
  [ -n "${3:-}" ] && printf 'NEXT: %s\n' "$3"
  printf 'REASON: %s\n' "$2"
}

# resolve the bound repo: arg > OBJECTIVE_REPO > session anchor. Anchor line 1 = "<repo> <objective-doc>".
REPO="${1:-${OBJECTIVE_REPO:-}}"
OBJDOC=""
if [ -z "$REPO" ]; then
  sid="${OBJECTIVE_SID:-${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}"
  if [ -n "$sid" ]; then
    key="${sid//[^A-Za-z0-9._-]/_}"; anchor="$SCOPE_REGISTRY_DIR/$key.objective"
    [ -r "$anchor" ] && read -r REPO OBJDOC _ < "$anchor" 2>/dev/null || true
  fi
fi
[ -n "$REPO" ] || { emit INDETERMINATE "no bound objective (no repo arg, no OBJECTIVE_REPO, no session anchor) — the oracle cannot speak"; exit 0; }
SLUG="$ORG/$REPO"

# FACT 1 — open backlog issues (drivable: author them). Fail-closed: an unreadable list ⇒ INDETERMINATE.
bkl_nums="$(gh issue list --repo "$SLUG" --label "$BACKLOG_LABEL" --state open --limit 200 --json number -q '.[].number' 2>/dev/null)" \
  || { emit INDETERMINATE "cannot read $SLUG open $BACKLOG_LABEL issues (fail-closed)"; exit 0; }
open_backlog="$(printf '%s' "$bkl_nums" | grep -c '[0-9]' || true)"
first_backlog="$(printf '%s\n' "$bkl_nums" | grep -m1 '[0-9]' || true)"
# ever-backlog: was this objective EVER decomposed? (all-state count ≥ 1 ⇒ ship evidence exists)
ever_backlog=0
all_bkl="$(gh issue list --repo "$SLUG" --label "$BACKLOG_LABEL" --state all --limit 1 --json number -q '.[].number' 2>/dev/null)"
[ -n "$all_bkl" ] && ever_backlog=1

# FACT 2 — open dev PRs (drivable: drive to GREEN/merge). One call carries author + labels.
prs="$(gh pr list --repo "$SLUG" --state open --limit 100 --json number,author,labels \
        -q '.[] | "\(.number)\t\(.author.login)\t\([.labels[].name]|join(","))"' 2>/dev/null)" \
  || { emit INDETERMINATE "cannot read $SLUG open PRs (fail-closed)"; exit 0; }
drivable=0; first_pr=""; first_pr_lv=0
while IFS=$'\t' read -r n author labels; do
  [ -n "$n" ] || continue
  # gh renders an app author as "app/<login>"; normalise so DEV_LOGIN matches.
  author="${author#app/}"; author="${author%\[bot\]}"
  if [ "$(pr_drivable "$author" "$DEV_LOGIN" "$labels")" = 1 ]; then
    drivable=$((drivable+1))
    if [ -z "$first_pr" ]; then
      first_pr="$n"
      printf '%s' ",$labels," | grep -qF ",live-validate," && first_pr_lv=1
    fi
  fi
done <<<"$prs"

drivable_total=$(( open_backlog + drivable ))

# FACT 3 — the optional acceptance probe (side-effect-free; declared → enforced, absent → not required).
probe=ABSENT; probe_path="${OBJECTIVE_ACCEPTANCE:-}"
if [ -z "$probe_path" ] && [ -n "$OBJDOC" ]; then
  cand="$(dirname "$OBJDOC")/objective-acceptance.sh"
  [ -x "$cand" ] && probe_path="$cand"
fi
if [ -n "$probe_path" ] && [ -x "$probe_path" ]; then
  if timeout "$OS_PROBE_TIMEOUT" "$probe_path" >/dev/null 2>&1; then probe=PASS; else probe=FAIL; fi
elif [ -n "$probe_path" ]; then
  log "declared acceptance probe '$probe_path' is not executable — treating as ABSENT"
fi

verdict="$(classify "$drivable_total" "$probe" "$ever_backlog")"
case "$verdict" in
  OPEN)
    next="$(next_action "$( [ "$open_backlog" -ge 1 ] && echo 1 || echo 0 )" "$first_backlog" "$first_pr" "$first_pr_lv")"
    emit OPEN "drivable open work remains: $open_backlog open $BACKLOG_LABEL issue(s) + $drivable open dev PR(s); probe=$probe — the objective is NOT shipped" "$next"
    ;;
  SHIPPED)
    emit SHIPPED "no drivable open work; probe=$probe; ship evidence present — the whole objective is shipped"
    ;;
  *)
    emit INDETERMINATE "no drivable open work but no ship evidence (backlog never decomposed, no acceptance probe) — the oracle cannot certify a ship"
    ;;
esac
exit 0
