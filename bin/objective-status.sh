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
#   * THE STANDING WORK PLAN (#279) — the OPEN issue whose title starts with $PLAN_TITLE ("STANDING WORK
#     PLAN"), discovered BY TITLE, never by a hardcoded number (the bin/fleet-halt.sh precedent). Its
#     unchecked `- [ ]` / `- [~]` items are reported as OPEN_PLAN_ITEMS + PLAN_ISSUE. **This fact is
#     REPORTED, not folded into the verdict**: an unchecked box is a reason not to STOP, not a proof the
#     built product is unshipped — folding it into `drivable` would let one stale checkbox freeze
#     bin/ship-actuator.sh out of ever closing an objective. The anti-stall Stop hook reads the KV
#     directly; every other consumer reads STATUS and is untouched by this fact.
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
# The standing work plan is discovered BY TITLE PREFIX (fleet-halt.sh's control-issue precedent) — it
# carries no label of its own. Set PLAN_TITLE='' to switch the fact off entirely.
PLAN_TITLE="${PLAN_TITLE-STANDING WORK PLAN}"   # `-` not `:-`: an EXPLICIT empty value must disable it
OS_PROBE_TIMEOUT="${OS_PROBE_TIMEOUT:-20}"
SCOPE_REGISTRY_DIR="${SCOPE_REGISTRY_DIR:-$HOME/.local/state/scope-registry}"
# The R34 ship-gate reviewer identity (== the independent fitness App). Its commit-comment on the current
# main sha is the unforgeable ship-gate verdict this oracle reads (it never RUNS the gate — ship-gate.sh
# does). In make-it-work mode (FITNESS_SAME_IDENTITY=1) the gate posts under the dev identity, so FACT 4
# accepts DEV_LOGIN too — mirroring the same-identity relaxation fitness/auto-merge already accept.
SHIPGATE_LOGIN="${SHIPGATE_LOGIN:-oso-gato-fitness-claudebox}"

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

# classify <drivable-count> <probe:PASS|FAIL|ABSENT> <ever-backlog:0|1> [shipgate:PASS|PENDING] →
#   SHIPPED | OPEN | INDETERMINATE.
#   OPEN         — positive drivable work remains, OR a declared probe FAILs, OR the objective is otherwise
#                  would-be-shipped but the R34 SPEC-VS-BUILD ship gate has NOT passed the current aggregate
#                  (shipgate != PASS). This is the anti-false-stop teeth AND the R34 close-gate.
#   SHIPPED       — nothing drivable AND the probe does not fail AND ship evidence exists (backlog existed
#                  or probe PASS) AND an independent R34 ship-gate PASS is bound to THIS aggregate. The
#                  objective closes ONLY with that independent PASS — the author is never its own sole judge.
#   INDETERMINATE — the oracle cannot speak (no evidence the objective was ever decomposed and no probe).
classify(){
  local drivable="$1" probe="$2" ever="$3" shipgate="${4:-}"
  case "$drivable" in ''|*[!0-9]*) echo INDETERMINATE; return;; esac
  [ "$probe" = FAIL ] && { echo OPEN; return; }
  [ "$drivable" -ge 1 ] && { echo OPEN; return; }
  if [ "$probe" = PASS ] || [ "$ever" = 1 ]; then
    # would-be SHIPPED — R34: close ONLY with an independent ship-gate PASS bound to this aggregate.
    # RETURN, a stale-sha PASS, none, or an unreadable verdict all keep the loop iterating (fail-closed).
    if [ "$shipgate" = PASS ]; then echo SHIPPED; else echo OPEN; fi
  else
    echo INDETERMINATE
  fi
}

# plan_unchecked <required-title-prefix>  (stdin: an "@@PLAN <number> <title>" header line followed by
# that issue's body, repeated) → "<unchecked-item-count> <first-issue-number-carrying-one>".
# `- [ ]` and `- [~]` count as unchecked; `- [x]` does not. The title prefix is re-checked HERE because
# GitHub's issue search is fuzzy and the discovery of the standing work plan must not be.
plan_unchecked(){
  awk -v want="${1-}" '
    index($0,"@@PLAN ")==1 {
      cur=""; rest=substr($0,8)
      num=rest; sub(/[^0-9].*$/,"",num)
      title=rest; sub(/^[0-9]+[[:space:]]*/,"",title)
      if (want != "" && index(title,want)==1) cur=num
      next
    }
    cur!="" && /^[[:space:]]*[-*][[:space:]]+\[[ ~]\]/ { n++; if (first=="") first=cur }
    END { printf "%d %s\n", n+0, first }
  '
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
  echo "== classify (SHIPPED / OPEN / INDETERMINATE) — R34 ship-gate gates the close =="
  ck "drivable work → OPEN"               "$(classify 2 ABSENT 1)" "OPEN"
  ck "probe FAIL, empty backlog → OPEN"   "$(classify 0 FAIL 0)" "OPEN"
  ck "backlog + ship-gate PASS → SHIPPED" "$(classify 0 ABSENT 1 PASS)" "SHIPPED"
  ck "probe PASS + ship-gate PASS → SHIPPED" "$(classify 0 PASS 0 PASS)" "SHIPPED"
  ck "backlog + NO ship-gate → OPEN (R34)"   "$(classify 0 ABSENT 1)" "OPEN"
  ck "backlog + ship-gate RETURN → OPEN"     "$(classify 0 ABSENT 1 RETURN)" "OPEN"
  ck "drivable work beats a stale PASS"      "$(classify 2 ABSENT 1 PASS)" "OPEN"
  ck "none + no evidence → INDETERMINATE" "$(classify 0 ABSENT 0)" "INDETERMINATE"
  ck "non-numeric → INDETERMINATE"        "$(classify '' ABSENT 1)" "INDETERMINATE"
  ck "probe FAIL wins over evidence"      "$(classify 0 FAIL 1 PASS)" "OPEN"
  echo "== plan_unchecked (the standing work plan — reported, never folded into the verdict) =="
  planfeed(){ printf '%s\n' \
    '@@PLAN 274 STANDING WORK PLAN — enterprise autonomous loop' \
    '- [x] STEP 1 — wire the tests into CI' \
    '- [ ] STEP 4 — the clock' \
    '- [~] STEP 5 — delete the self-watching'; }
  ck "counts [ ] and [~], not [x]"  "$(planfeed | plan_unchecked 'STANDING WORK PLAN')" "2 274"
  ck "all checked → none open"      "$(printf '%s\n' '@@PLAN 274 STANDING WORK PLAN' '- [x] done' | plan_unchecked 'STANDING WORK PLAN')" "0 "
  ck "a fuzzy-search non-match is ignored" \
     "$(printf '%s\n' '@@PLAN 9 Rewrite the STANDING WORK PLAN parser' '- [ ] not the plan' | plan_unchecked 'STANDING WORK PLAN')" "0 "
  ck "empty feed → none"            "$(printf '' | plan_unchecked 'STANDING WORK PLAN')" "0 "
  ck "no title configured → off"    "$(planfeed | plan_unchecked '')" "0 "
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
  printf 'SHIP_GATE: %s\n' "${shipgate:-N/A}"
  printf 'OPEN_PLAN_ITEMS: %s\n' "${plan_items:-0}"
  [ -n "${plan_issue:-}" ] && printf 'PLAN_ISSUE: %s\n' "$plan_issue"
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

# FACT 2b — THE STANDING WORK PLAN (#279). REPORTED (OPEN_PLAN_ITEMS / PLAN_ISSUE), never folded into
# `drivable_total`: see the header — an unchecked box is a reason not to STOP, not a proof the built
# product is unshipped, and folding it in would let one stale checkbox freeze ship-actuator forever.
# Discovered BY TITLE (fleet-halt.sh's precedent), strict-prefix re-checked because issue search is fuzzy.
# FAIL DIRECTION: an unreadable/absent plan reports 0 — the anti-stall gate simply loses this extra tooth
# (it can only ADD teeth, never remove them), and no verdict is ever fabricated from a failed read.
plan_items=0; plan_issue=""
if [ -n "$PLAN_TITLE" ]; then
  plan_raw="$(gh issue list --repo "$SLUG" --state open --search "$PLAN_TITLE in:title" --limit 5 \
               --json number,title,body -q '.[] | "@@PLAN \(.number) \(.title)\n\(.body)"' 2>/dev/null)" || plan_raw=""
  read -r plan_items plan_issue <<<"$(printf '%s\n' "$plan_raw" | plan_unchecked "$PLAN_TITLE")"
  case "$plan_items" in ''|*[!0-9]*) plan_items=0; plan_issue="";; esac
fi

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

# FACT 4 — the R34 SPEC-VS-BUILD SHIP GATE verdict, bound to the CURRENT shipped aggregate (main tip).
# Read-only: this oracle never RUNS the gate (bin/ship-gate.sh does) — it only reads the recorded fact.
# PASS iff an unforgeable SHIPGATE_LOGIN commit-comment on the exact current main sha reads VERDICT PASS
# (a stale-sha PASS, a RETURN, none, or an unreadable read ⇒ PENDING — fail-closed toward NOT-shipping).
# Only consulted when the objective is otherwise would-be-shipped (cheap: 2 gh calls, backlog-empty only).
shipgate=PENDING; aggregate_sha=""
if [ "$drivable_total" -eq 0 ] && { [ "$probe" = PASS ] || [ "$ever_backlog" = 1 ]; }; then
  aggregate_sha="$(gh api "repos/$SLUG/branches/main" -q .commit.sha 2>/dev/null || true)"
  if [ -n "$aggregate_sha" ]; then
    # In make-it-work mode the gate posts under the dev identity — accept it too (mirrors fitness).
    sg_logins="$SHIPGATE_LOGIN"
    [ "${FITNESS_SAME_IDENTITY:-0}" = 1 ] && sg_logins="$SHIPGATE_LOGIN $DEV_LOGIN"
    sg_line=""
    for _lg in $sg_logins; do
      sg_line="$(gh api "repos/$SLUG/commits/$aggregate_sha/comments" \
         -q ".[] | select(.user.login==\"$_lg\" or .user.login==\"${_lg}[bot]\") | .body" 2>/dev/null \
         | grep -oE '^SHIP GATE: VERDICT (PASS|RETURN) aggregate [0-9a-f]{7,40}' | tail -1)"
      [ -n "$sg_line" ] && break
    done
    sg_verdict="$(printf '%s' "$sg_line" | grep -oE 'VERDICT (PASS|RETURN)' | awk '{print $2}')"
    sg_sha="$(printf '%s' "$sg_line" | grep -oE 'aggregate [0-9a-f]{7,40}' | awk '{print $2}')"
    [ "$sg_verdict" = PASS ] && [ -n "$sg_sha" ] && [ "$sg_sha" = "$aggregate_sha" ] && shipgate=PASS
  fi
fi

verdict="$(classify "$drivable_total" "$probe" "$ever_backlog" "$shipgate")"
case "$verdict" in
  OPEN)
    # would-be-shipped (no drivable work, probe not failing, ship evidence) but the R34 ship gate has
    # not PASSed the current aggregate — the one OPEN case whose ONLY remaining step is the ship gate.
    if [ "$drivable_total" -eq 0 ] && [ "$probe" != FAIL ] && { [ "$probe" = PASS ] || [ "$ever_backlog" = 1 ]; }; then
      next="run the R34 spec-vs-build ship gate — 'bin/ship-gate.sh --post $REPO' — an independent review (objective→requirements→build-principles) must PASS the built product bound to main@${aggregate_sha:0:7} before the objective can close; current ship-gate=$shipgate."
      emit OPEN "all backlog features shipped and probe=$probe, but the R34 SPEC-VS-BUILD ship gate has NOT passed the current aggregate (ship-gate=$shipgate) — the objective is NOT closed (R34)" "$next"
    else
      next="$(next_action "$( [ "$open_backlog" -ge 1 ] && echo 1 || echo 0 )" "$first_backlog" "$first_pr" "$first_pr_lv")"
      emit OPEN "drivable open work remains: $open_backlog open $BACKLOG_LABEL issue(s) + $drivable open dev PR(s); probe=$probe — the objective is NOT shipped" "$next"
    fi
    ;;
  SHIPPED)
    emit SHIPPED "no drivable open work; probe=$probe; ship evidence present; R34 ship-gate PASS bound to main@${aggregate_sha:0:7} — the whole objective is shipped"
    ;;
  *)
    emit INDETERMINATE "no drivable open work but no ship evidence (backlog never decomposed, no acceptance probe) — the oracle cannot certify a ship"
    ;;
esac
exit 0
