#!/usr/bin/env bash
# intake-file.sh — THE ORDER DESK'S FILING CLERK: validate a drafted objective and file it as a GitHub
# issue the autonomous loop can actually act on.
#
# WHY THIS EXISTS (STEP 2 of the standing work plan, oso-gato/fedora-dev#274).
# The apparatus had ~11,000 lines of delivery and guard machinery and NO FRONT DOOR. R31 specifies a
# conversational intake and had ZERO lines implemented; `dev-plan.sh` — the first machine in the chain —
# refuses anything without a hand-written issue carrying a hand-applied maintainer approval. So 4,400
# lines of brakes were built around an entrance nobody built, and the maintainer (a non-programmer) had
# no way in except to write specs himself.
#
# THE DIVISION OF LABOUR, and it is the whole point:
#   * THE AGENT interviews the maintainer, DRAFTS the specification INCLUDING the acceptance criteria,
#     and shows it to him. He JUDGES it; he never AUTHORS it. Judging a criterion is easy for a
#     non-programmer; authoring one is the skill he does not have and should not need.
#   * THIS SCRIPT is the deterministic half: it refuses to file a spec the loop cannot act on, then
#     files it. No model, no judgement — a checklist with an exit code.
#   * THE MAINTAINER confirms with ONE tap. He must: `dev-plan.sh` resolves WHO applied the approval
#     and binds that actor to a maintainer role, so the agent cannot self-authorise an objective. That
#     is the correct trust boundary (R1: confirming the spec is a human act) and this script does not
#     try to route around it — it files the issue ASSIGNED to him so it lands in his GitHub app.
#
# THE LABEL IS THE GATE, AND IT MUST NOT BE `backlog` (fitness RETURN on d339476 — the defect this
# script shipped with). `backlog` is not "a ticket to look at": it is the label `dev-loop.sh` sweeps and
# hands STRAIGHT to `dev-author.sh`, which implements it, opens a PR, labels it `live-validate` and lets
# the poller auto-merge it. Filing an un-confirmed objective under it therefore routes PAST R1 entirely —
# the maintainer's `approved` tap is never consulted, because the only component that checks it
# (`dev-plan.sh`) is not in that path at all. So an intake objective is filed under its OWN label
# ($INTAKE_LABEL, default `objective`), which the feature author deliberately does not sweep, and
# `dev-loop.sh`'s PLAN ARM is what carries an `approved`-labelled objective to `dev-plan.sh`. Nothing is
# built from this issue until a MAINTAINER taps `approved`; the label is the gate, and that is the point.
#
# R16 SCOPE — the belt IS wired, at the CEILING layer, and the layer choice is the deliberate part.
# (This paragraph previously justified omitting the belt by asserting that with no `policy/scope.conf`
# the reader "fails closed to the apparatus's OWN two repos", refusing exactly the tenant repos the
# front door serves. That was FALSE, and the fitness gate returned 8ffd4d4 for it: `scope.conf` is
# RETIRED and unread — `repo-scope.sh` enumerates the App INSTALLATION, so it ALLOWS tenant repos.
# Measured: `repo-scope.sh check fedora-desktop` → rc 0. There was no obstacle to route around.)
#
# WHICH LAYER, AND WHY NOT THE PER-SESSION ONE. `repo-scope.sh` has two: the App-install CEILING (what
# the maintainer authorised by installing the App) and — only when $SCOPE_SESSION is set — a per-SESSION
# narrowing to that session's already-declared objective. This actuator pins the session layer INERT
# (SCOPE_SESSION empty) and checks the CEILING alone, because THE FRONT DOOR EXISTS TO ACCEPT A *NEW*
# OBJECTIVE — which is by definition not in the current session's declared scope. Engaging the session
# layer would refuse every intake from an ordinary conversation: measured, an undeclared session is
# DENIED every repo (SESSION_UNDECLARED, rc 3), so copying `dev-plan.sh`'s CLAUDE_SESSION_ID-derivation
# block verbatim would have broken the front door for real — the failure the old rationale wrongly
# blamed on scope.conf. The ceiling is the boundary that actually applies here, and it bites: an
# out-of-scope repo is rc 3 and nothing is composed or filed.
#
# The App-install boundary is also the structural backstop — the credential cannot reach a repo it is
# not installed on — so the belt is defence in depth, refusing EARLY and by NAME instead of as a `gh`
# error after the body is built. Narrowing intake to a session's own declared scope, once every session
# is objective-backed, is a real follow-up; it is named as one, not used as a reason to skip the belt.
#
# THE LOAD-BEARING VALIDATION IS THE ACCEPTANCE COMMAND. An issue without one leaves "looks done" as the
# only completion signal, which puts a human at the end of every iteration. Measured across ~9,900 agent
# runs: 45-48% of ALL failures were false claims of completion where nothing independent could check;
# where an independent process COULD check, that fell to 3%. So: no runnable check, no ticket.
#
#   intake-file.sh --check <spec.md>            validate only; rc 0 = fileable, rc 1 = incomplete (says why)
#   intake-file.sh --file <spec.md> --repo <r>  validate, then file the issue (assigned, labelled)
#   intake-file.sh --selftest                   exercise the pure core; no network
#   rc: 0 filed/fileable · 1 the SPEC is incomplete (or the create failed) · 2 usage · 4 the REPO is
#       out of R16 scope (a distinct code: the spec is fine, the destination is not)
#
# SPEC FORMAT (what the agent drafts — see the skill for how it is elicited):
#   # <title: one verb, one deliverable>
#   ## Objective        — the OUTCOME wanted, in the maintainer's own words (see OUTCOME NOT METHOD)
#   ## Scope            — what is IN
#   ## Out of scope     — what is deliberately NOT in, plus a `Ruled out: <option> — <why>` line
#   ## Acceptance       — at least one line starting `$ ` : an exact command a machine can run,
#                          PLUS an `observed:` line recording that it was seen FAILING (see RED FIRST)
#   ## Delivered means  — exactly `merged` or `running`. Which one changes what "shipped" may mean.
#   ## How              — the approach: autonomy, when to come back, and `Stop after <N> attempts`.
#                          ONLY what differs from standing law — capped at $HOW_MAX lines, because a
#                          restatement of the law makes copies that rot out of step with it.
#   ## Notes            — optional
#
# THE THREE ADDITIONS, AND WHY EACH ONE EARNS A REFUSAL (maintainer's design session, 2026-07-30).
#
# DELIVERED MEANS — the hollow-ship fix. `objective-status.sh` used to treat a missing acceptance probe as
# ship evidence ("the emptiness of backlog+PRs is the ship evidence"). For plain code that is correct:
# merged IS delivered. For anything that must RUN it let the loop declare victory over software that was
# never once executed — which is precisely the maintainer's standing complaint ("you keep telling me
# something is merged, but every time I refresh the host it goes nowhere"). The objective now states which
# it is, and `running` makes the probe MANDATORY: absent ⇒ unfinished work. One word, and "shipped" stops
# being a synonym for "the ticket list is empty".
#
# RED FIRST — the acceptance check must be recorded as SEEN FAILING before work starts. Without a measured
# starting point nothing can tell "I fixed it" from "it already worked", and the loop's own fitness rubric
# already calls a test that passes against the pre-fix code UNTRUE. The same rule belongs on the objective:
# a criterion that is green on day zero is not a criterion, it is a description of the present.
#
# HOW — the approach was the one thing with nowhere to live. Everything about WHAT was required; nothing
# carried how autonomously to work, or when a fork is the maintainer's to call rather than the agent's.
# Deliberately scoped to the DELTA from standing law: re-typing "don't touch the host" into every objective
# makes copies that rot out of step with the law they duplicate.
#
# OUTCOME NOT METHOD is guidance, not a check — no validator can tell an outcome from a method. It is
# enforced in the interview (see the skill), because an objective naming its own mechanism silently
# forbids the pivot that doctrine mandate 4 requires: "add a reload to service X" can never discover that
# the right answer was to delete service X.
#
# FAIL DIRECTION: this REFUSES rather than files a weak ticket. A vague ticket does not fail loudly — it
# produces confident wrong work and a stalled loop, which is far more expensive than a refusal here.
set -uo pipefail

ORG="${ORG:-oso-gato}"
# The intake label — see THE LABEL IS THE GATE above. It MUST NOT be the author loop's $BACKLOG_LABEL
# (`backlog`): that one is swept straight into autonomous implementation, and this issue has not been
# confirmed by anybody yet.
INTAKE_LABEL="${INTAKE_LABEL:-objective}"
APPROVED_LABEL="${APPROVED_LABEL:-approved}"
MAINTAINER="${MAINTAINER:-oso-gato}"

# ---- PURE CORE (--selftest covers exactly this) ----------------------------------------------------
# spec_verdict <has_title> <n_accept_cmds> <n_clarify_markers> <has_scope> <has_outofscope>
#              [delivered] [has_how] [has_baseline] → READY | the reason
# Order matters: report the FIRST missing thing so the agent gets one clear instruction, not a list.
# The three trailing arguments default to the values that PASS, so a caller that has not been taught the
# new sections is not silently refused — but this script's own I/O layer always supplies them.
spec_verdict(){
  local title="${1-}" cmds="${2-}" clar="${3-}" scope="${4-}" oos="${5-}" \
        delivered="${6-merged}" how="${7-1}" baseline="${8-1}" \
        ruledout="${9-1}" stopafter="${10-2}" howlen="${11-1}"
  local HOW_MAX="${HOW_MAX:-15}"
  case "$cmds" in ''|*[!0-9]*) printf 'INCOMPLETE: acceptance-command count unreadable\n'; return 1 ;; esac
  case "$clar" in ''|*[!0-9]*) printf 'INCOMPLETE: clarification-marker count unreadable\n'; return 1 ;; esac
  [ "$delivered" = unreadable ] && { printf 'INCOMPLETE: could not read the ## Delivered means section\n'; return 1; }
  [ "$baseline" = unreadable ]  && { printf 'INCOMPLETE: could not read the ## Acceptance section\n'; return 1; }
  [ "$ruledout" = unreadable ]  && { printf 'INCOMPLETE: could not read the ## Out of scope section\n'; return 1; }
  [ "$stopafter" = unreadable ] && { printf 'INCOMPLETE: could not read the ## How section\n'; return 1; }
  [ "$title" = 1 ] || { printf 'INCOMPLETE: no title line (# <one verb, one deliverable>)\n'; return 1; }
  [ "$clar" -eq 0 ] || { printf 'INCOMPLETE: %s unresolved [NEEDS CLARIFICATION] marker(s) — the interview is not finished\n' "$clar"; return 1; }
  [ "$cmds" -ge 1 ] || { printf 'INCOMPLETE: no acceptance command — add at least one line starting "$ " that a machine can run to prove the work is done\n'; return 1; }
  [ "$baseline" = 1 ] || { printf 'INCOMPLETE: the acceptance check was never seen FAILING — run it now and add a line to ## Acceptance like "observed: FAILS today (<what it printed>)". A check that already passes proves nothing was built\n'; return 1; }
  [ "$scope" = 1 ] || { printf 'INCOMPLETE: no ## Scope section\n'; return 1; }
  [ "$oos" = 1 ] || { printf 'INCOMPLETE: no ## Out of scope section — an unbounded ticket invites scope creep the agent cannot detect\n'; return 1; }
  case "$delivered" in
    merged|running) : ;;
    MISSING) printf 'INCOMPLETE: no ## Delivered means section — write exactly "merged" (the work is done when it is on main) or "running" (it is only done when it actually runs). This decides whether an absent acceptance probe may count as shipped\n'; return 1 ;;
    *) printf 'INCOMPLETE: ## Delivered means says "%s" — it must be exactly "merged" or "running"\n' "$delivered"; return 1 ;;
  esac
  [ "$how" = 1 ] || { printf 'INCOMPLETE: no ## How section — record the approach: how autonomously to work, what should bring the agent back to the maintainer, and the stop-after-repeated-failure limit. Only what DIFFERS from standing law\n'; return 1; }
  [ "$ruledout" = 1 ] || { printf 'INCOMPLETE: ## Out of scope records nothing that was RULED OUT — add a line like "Ruled out: <the option he turned down> — <why>". An unrecorded rejection gets re-proposed as a fresh idea weeks later. If he genuinely rejected nothing, write "Ruled out: nothing — he accepted the first shape"\n'; return 1; }
  case "$stopafter" in
    MISSING) printf 'INCOMPLETE: ## How sets no attempt limit — add a line like "Stop after 2 attempts at the same failure." The loop cannot bound itself: its generic no-progress stop is keyed on the SAME failure repeating, and a retry that fails in a NEW way every round never trips it (observed: seven review+fix rounds on one PR)\n'; return 1 ;;
    *[!0-9]*) printf 'INCOMPLETE: the attempt limit in ## How is not a number ("%s")\n' "$stopafter"; return 1 ;;
    0) printf 'INCOMPLETE: an attempt limit of 0 would stop before the first try\n'; return 1 ;;
  esac
  case "$howlen" in
    ''|*[!0-9]*) printf 'INCOMPLETE: could not measure the ## How section\n'; return 1 ;;
  esac
  [ "$howlen" -le "$HOW_MAX" ] || { printf 'INCOMPLETE: ## How is %s lines — it should be the DELTA from standing law, not a restatement of it (max %s). Rules already in /etc/claude-code/CLAUDE.md do not belong here: the copies rot out of step with the law they duplicate, and they bury the one line that was actually specific to this work\n' "$howlen" "$HOW_MAX"; return 1; }
  printf 'READY\n'; return 0
}

# count_accept_cmds <file> → number of `$ ` command lines inside the ## Acceptance section only.
# Scoped to the section ON PURPOSE: a `$ ` example elsewhere in the prose is illustration, not a check.
# UNREADABLE IS NOT ZERO. Both counters emit the literal `unreadable` when they cannot actually count,
# which spec_verdict rejects — the header's "never file on missing evidence" and the selftest's refusal
# rows are then true of the I/O layer too, not just of the pure core. (Emitting 0 was fail-OPEN: an
# unreadable spec would have read as "no clarification markers", i.e. as a clean interview.)
count_accept_cmds(){
  local f="${1-}" in=0 n=0 line
  [ -r "$f" ] || { printf 'unreadable'; return; }
  while IFS= read -r line; do
    case "$line" in
      '## Acceptance'*) in=1; continue ;;
      '## '*) [ "$in" = 1 ] && in=0; continue ;;
    esac
    [ "$in" = 1 ] || continue
    case "$line" in
      '$ '*) n=$((n+1)) ;;
      '    $ '*|'  $ '*) n=$((n+1)) ;;
    esac
  done < "$f"
  printf '%s' "$n"
}

has_section(){ grep -qiE "^##[[:space:]]+$2([[:space:]]|$)" "$1" 2>/dev/null && printf 1 || printf 0; }
has_title(){   grep -qE '^#[[:space:]]+\S' "$1" 2>/dev/null && printf 1 || printf 0; }
# NB: `grep -c` PRINTS 0 and EXITS 1 when there is no match, so a naive `|| printf 0` emits "0\n0" —
# non-numeric, which the pure core correctly rejects as unreadable and which refused every clean spec.
# Caught only by running a real file through it; the selftest passed because it hand-fed the counts.
count_clarify(){
  local n rc
  n="$(grep -c 'NEEDS CLARIFICATION' "$1" 2>/dev/null)"; rc=$?
  # rc 0 = matched, 1 = no match (a real count of 0), anything else = grep could not read the file.
  [ "$rc" -le 1 ] || { printf 'unreadable'; return; }
  case "$n" in ''|*[!0-9]*) printf 'unreadable'; return ;; esac
  printf '%s' "$n"
}

# delivered_value <file> → merged | running | MISSING | <the word actually written> | unreadable
# Accepts BOTH shapes a maintainer might write: `## Delivered means: running`, or the value on the line
# beneath the heading. UNREADABLE IS NOT MISSING — the pure core rejects each with its own message.
delivered_value(){
  local f="${1-}" v
  [ -r "$f" ] || { printf 'unreadable'; return; }
  v="$(awk '
    function firstword(s){ gsub(/^[[:space:]]+/,"",s); sub(/[[:space:]].*$/,"",s); gsub(/[^A-Za-z]/,"",s); return tolower(s) }
    /^##[[:space:]]+[Dd]elivered[[:space:]]+[Mm]eans/ {
      h=$0; sub(/^[^:]*/,"",h); sub(/^:[[:space:]]*/,"",h)
      if (h ~ /[^[:space:]]/) { print firstword(h); exit }
      sec=1; next
    }
    /^##[[:space:]]/ { sec=0; next }
    sec && $0 ~ /[^[:space:]]/ { print firstword($0); exit }
  ' "$f" 2>/dev/null)"
  printf '%s' "${v:-MISSING}"
}

# has_baseline <file> → 1 if ## Acceptance records the check was SEEN FAILING, 0 if not, unreadable if
# the file cannot be read. RED FIRST (see the header): a criterion that is already green on day zero
# cannot distinguish work that was done from work that was never needed.
has_baseline(){
  local f="${1-}" in=0 line low
  [ -r "$f" ] || { printf 'unreadable'; return; }
  while IFS= read -r line; do
    case "$line" in
      '## Acceptance'*) in=1; continue ;;
      '## '*) [ "$in" = 1 ] && in=0; continue ;;
    esac
    [ "$in" = 1 ] || continue
    low="$(printf '%s' "$line" | tr 'A-Z' 'a-z')"
    case "$low" in *observed:*fail*) printf 1; return ;; esac
  done < "$f"
  printf 0
}

# section_lines <file> <section-name> → count of NON-BLANK lines inside that `## ` section, or unreadable.
section_lines(){
  local f="${1-}" want="${2-}" in=0 n=0 line low
  [ -r "$f" ] || { printf 'unreadable'; return; }
  low="$(printf '%s' "$want" | tr 'A-Z' 'a-z')"
  while IFS= read -r line; do
    case "$(printf '%s' "$line" | tr 'A-Z' 'a-z')" in
      "## $low"|"## $low "*) in=1; continue ;;
      '## '*) [ "$in" = 1 ] && in=0; continue ;;
    esac
    [ "$in" = 1 ] || continue
    case "$line" in ''|[[:space:]]) continue ;; esac
    [ -n "${line//[[:space:]]/}" ] && n=$((n+1))
  done < "$f"
  printf '%s' "$n"
}

# has_ruled_out <file> → 1 if ## Out of scope records a REJECTED option, 0 if not, unreadable if unread.
# WHY IT IS REQUIRED: the session throws off options the maintainer turns down. Unrecorded, they get
# re-proposed as fresh ideas weeks later, and he has to re-decide something he already decided. The
# loop already demands the agent show ITS discarded options (DoD item 4); his are worth more.
# "Nothing was ruled out" is a legitimate answer — it just has to be written down as one.
has_ruled_out(){
  local f="${1-}" in=0 line
  [ -r "$f" ] || { printf 'unreadable'; return; }
  while IFS= read -r line; do
    case "$line" in
      '## Out of scope'*|'## out of scope'*) in=1; continue ;;
      '## '*) [ "$in" = 1 ] && in=0; continue ;;
    esac
    [ "$in" = 1 ] || continue
    case "$(printf '%s' "$line" | tr 'A-Z' 'a-z')" in
      *ruled\ out:*) printf 1; return ;;
    esac
  done < "$f"
  printf 0
}

# stop_after <file> → the attempt limit written in ## How, MISSING if none, unreadable if unread.
# WHY A NUMBER AND NOT PROSE: the loop's generic no-progress stop cannot fire, because each retry
# fails with a NEW signature and "no progress" is keyed on repetition. Observed 2026-07-12: seven
# review+fix rounds on one PR, each costing a full model review AND a full model fix. A COUNT of
# attempts is the only bound that survives a failure that reinvents itself every round.
stop_after(){
  local f="${1-}" in=0 line n
  [ -r "$f" ] || { printf 'unreadable'; return; }
  while IFS= read -r line; do
    case "$line" in
      '## How'*|'## how'*) in=1; continue ;;
      '## '*) [ "$in" = 1 ] && in=0; continue ;;
    esac
    [ "$in" = 1 ] || continue
    n="$(printf '%s' "$line" | tr 'A-Z' 'a-z' | sed -n 's/.*stop after[^0-9]*\([0-9][0-9]*\).*/\1/p')"
    [ -n "$n" ] && { printf '%s' "$n"; return; }
  done < "$f"
  printf 'MISSING'
}

# objective_names_a_path <file> → 1 if ## Objective mentions a file path or script name.
# ADVISORY ONLY, never a refusal. An objective that names its own mechanism ("add a reload to
# bin/x.sh") silently forbids the pivot doctrine mandate 4 requires — but no validator can reliably
# tell an outcome from a method, and a false refusal here would block legitimate work. So this
# prints a note for the drafter to reconsider and returns nothing to the gate.
objective_names_a_path(){
  local f="${1-}" in=0 line
  [ -r "$f" ] || { printf 0; return; }
  while IFS= read -r line; do
    case "$line" in
      '## Objective'*|'## objective'*) in=1; continue ;;
      '## '*) [ "$in" = 1 ] && in=0; continue ;;
    esac
    [ "$in" = 1 ] || continue
    case "$line" in
      *.sh*|*.py*|*.js*|*.ts*|*bin/*|*'()'*) printf 1; return ;;
    esac
  done < "$f"
  printf 0
}

if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"; else f=$((f+1)); printf '  FAIL %s\n       want=[%s]\n       got =[%s]\n' "$1" "$3" "$2"; fi; }
  v(){ spec_verdict "$@" 2>/dev/null | head -1; }
  echo "== a complete spec files =="
  ck "all sections + one command" "$(v 1 1 0 1 1)" "READY"
  ck "several commands"           "$(v 1 3 0 1 1)" "READY"
  echo "== THE LOAD-BEARING RULE: no runnable check, no ticket =="
  ck "zero acceptance commands is refused" \
     "$(v 1 0 0 1 1 | cut -c1-30)" "INCOMPLETE: no acceptance comm"
  echo "== an unfinished interview cannot be filed =="
  ck "one unresolved marker blocks"  "$(v 1 1 1 1 1 | cut -c1-24)" "INCOMPLETE: 1 unresolved"
  ck "markers outrank a missing cmd" "$(v 1 0 2 1 1 | cut -c1-24)" "INCOMPLETE: 2 unresolved"
  echo "== structural requirements =="
  ck "no title"        "$(v 0 1 0 1 1 | cut -c1-22)" "INCOMPLETE: no title l"
  ck "no scope"        "$(v 1 1 0 0 1 | cut -c1-25)" "INCOMPLETE: no ## Scope s"
  ck "no out-of-scope" "$(v 1 1 0 1 0 | cut -c1-26)" "INCOMPLETE: no ## Out of s"
  echo "== DELIVERED MEANS: the one word that stops 'shipped' meaning 'the ticket list is empty' =="
  ck "merged is accepted"   "$(v 1 1 0 1 1 merged  1 1)" "READY"
  ck "running is accepted"  "$(v 1 1 0 1 1 running 1 1)" "READY"
  ck "missing section blocks" "$(v 1 1 0 1 1 MISSING 1 1 | grep -o 'no ## Delivered means section')" "no ## Delivered means section"
  ck "any other word blocks"  "$(v 1 1 0 1 1 someday 1 1 | grep -o 'says "someday"')" 'says "someday"'
  echo "== RED FIRST: a check never seen failing is not a check =="
  ck "no observed-failing line blocks" "$(v 1 1 0 1 1 merged 1 0 | grep -o 'never seen FAILING')" "never seen FAILING"
  echo "== HOW: the approach had nowhere to live until now =="
  ck "no ## How section blocks" "$(v 1 1 0 1 1 merged 0 1 | cut -c1-30)" "INCOMPLETE: no ## How section "
  echo "== RULED OUT: an unrecorded rejection gets re-proposed as a fresh idea =="
  ck "a recorded rejection passes"  "$(v 1 1 0 1 1 merged 1 1 1 2 1)" "READY"
  ck "nothing recorded blocks"      "$(v 1 1 0 1 1 merged 1 1 0 2 1 | grep -o 'records nothing that was RULED OUT')" "records nothing that was RULED OUT"
  echo "== STOP AFTER N: the only bound that survives a failure which reinvents itself =="
  ck "a limit of 2 passes"          "$(v 1 1 0 1 1 merged 1 1 1 2 1)" "READY"
  ck "a limit of 1 passes"          "$(v 1 1 0 1 1 merged 1 1 1 1 1)" "READY"
  ck "no limit blocks"              "$(v 1 1 0 1 1 merged 1 1 1 MISSING 1 | grep -o 'sets no attempt limit')" "sets no attempt limit"
  ck "a non-number blocks"          "$(v 1 1 0 1 1 merged 1 1 1 lots 1 | grep -o 'is not a number')" "is not a number"
  ck "zero attempts blocks"         "$(v 1 1 0 1 1 merged 1 1 1 0 1 | grep -o 'stop before the first try')" "stop before the first try"
  echo "== HOW IS A DELTA, NOT A RULEBOOK (restated law rots out of step with the law) =="
  ck "a short How passes"           "$(v 1 1 0 1 1 merged 1 1 1 2 6)"  "READY"
  ck "exactly at the cap passes"    "$(v 1 1 0 1 1 merged 1 1 1 2 15)" "READY"
  ck "a restated rulebook blocks"   "$(v 1 1 0 1 1 merged 1 1 1 2 40 | grep -o 'should be the DELTA from standing law')" "should be the DELTA from standing law"
  ck "unmeasurable How blocks"      "$(v 1 1 0 1 1 merged 1 1 1 2 x | grep -o 'could not measure')" "could not measure"
  echo "== fail-safe: the new readers REFUSE on an unreadable section, never pass =="
  ck "unreadable out-of-scope" "$(v 1 1 0 1 1 merged 1 1 unreadable 2 1 | grep -o 'could not read the ## Out of scope')" "could not read the ## Out of scope"
  ck "unreadable how"          "$(v 1 1 0 1 1 merged 1 1 1 unreadable 1 | grep -o 'could not read the ## How')" "could not read the ## How"
  echo "== the new checks do not fire before the old ones (first missing thing wins) =="
  ck "missing title outranks them all"  "$(v 0 0 0 0 0 MISSING 0 0 | cut -c1-22)" "INCOMPLETE: no title l"
  ck "unresolved markers outrank them"  "$(v 1 1 2 1 1 MISSING 0 0 | cut -c1-24)" "INCOMPLETE: 2 unresolved"
  ck "a missing command outranks them"  "$(v 1 0 0 1 1 MISSING 0 0 | cut -c1-30)" "INCOMPLETE: no acceptance comm"
  echo "== the readers work on REAL files, not just hand-fed counts =="
  _t="$(mktemp -d)"
  printf '# T\n## Delivered means: running\n' > "$_t/a.md"
  ck "delivered_value: heading-line form" "$(delivered_value "$_t/a.md")" "running"
  printf '# T\n## Delivered means\n\nmerged\n\n## Notes\n' > "$_t/b.md"
  ck "delivered_value: next-line form"    "$(delivered_value "$_t/b.md")" "merged"
  printf '# T\n## Objective\nx\n' > "$_t/c.md"
  ck "delivered_value: no section"        "$(delivered_value "$_t/c.md")" "MISSING"
  ck "delivered_value: unreadable file"   "$(delivered_value /nonexistent/spec.md)" "unreadable"
  printf '# T\n## Acceptance\n$ true\nobserved: FAILS today (exit 1)\n' > "$_t/d.md"
  ck "has_baseline: records a failure"    "$(has_baseline "$_t/d.md")" "1"
  printf '# T\n## Acceptance\n$ true\n' > "$_t/e.md"
  ck "has_baseline: no record"            "$(has_baseline "$_t/e.md")" "0"
  printf '# T\n## Notes\nobserved: FAILS\n## Acceptance\n$ true\n' > "$_t/f.md"
  ck "has_baseline: only inside ## Acceptance" "$(has_baseline "$_t/f.md")" "0"
  ck "has_baseline: unreadable file"      "$(has_baseline /nonexistent/spec.md)" "unreadable"
  printf '# T\n## Out of scope\n- no emails\n- Ruled out: a cron job — too fragile\n' > "$_t/g.md"
  ck "has_ruled_out: records a rejection" "$(has_ruled_out "$_t/g.md")" "1"
  printf '# T\n## Out of scope\n- no emails\n' > "$_t/h.md"
  ck "has_ruled_out: nothing recorded"    "$(has_ruled_out "$_t/h.md")" "0"
  printf '# T\n## Notes\nRuled out: x\n## Out of scope\n- y\n' > "$_t/i.md"
  ck "has_ruled_out: only inside the section" "$(has_ruled_out "$_t/i.md")" "0"
  ck "has_ruled_out: unreadable file"     "$(has_ruled_out /nonexistent/spec.md)" "unreadable"
  printf '# T\n## How\nWork autonomously.\nStop after 2 attempts at the same failure.\n' > "$_t/j.md"
  ck "stop_after: reads the number"       "$(stop_after "$_t/j.md")" "2"
  printf '# T\n## How\nstop after 3 tries\n' > "$_t/k.md"
  ck "stop_after: case and wording vary"  "$(stop_after "$_t/k.md")" "3"
  printf '# T\n## How\nWork autonomously.\n' > "$_t/l.md"
  ck "stop_after: no limit written"       "$(stop_after "$_t/l.md")" "MISSING"
  printf '# T\n## How\nx\n## Notes\nStop after 9 attempts\n' > "$_t/m.md"
  ck "stop_after: only inside ## How"     "$(stop_after "$_t/m.md")" "MISSING"
  ck "stop_after: unreadable file"        "$(stop_after /nonexistent/spec.md)" "unreadable"
  printf '# T\n## How\na\n\nb\n   \nc\n' > "$_t/n.md"
  ck "section_lines: blanks do not count" "$(section_lines "$_t/n.md" How)" "3"
  ck "section_lines: absent section is 0" "$(section_lines "$_t/n.md" Nope)" "0"
  ck "section_lines: unreadable file"     "$(section_lines /nonexistent/spec.md How)" "unreadable"
  printf '# T\n## Objective\nMake bin/dev-loop-service.sh reload.\n' > "$_t/o.md"
  ck "advisory: spots a named mechanism"  "$(objective_names_a_path "$_t/o.md")" "1"
  printf '# T\n## Objective\nThe authoring half must run merged code.\n' > "$_t/p.md"
  ck "advisory: an outcome is not flagged" "$(objective_names_a_path "$_t/p.md")" "0"
  rm -rf "$_t"
  echo "== fail-safe: unreadable counts REFUSE (never file on missing evidence) =="
  ck "unreadable cmd count"     "$(v 1 x 0 1 1 | cut -c1-24)" "INCOMPLETE: acceptance-c"
  ck "unreadable marker count"  "$(v 1 1 x 1 1 | cut -c1-26)" "INCOMPLETE: clarification-"
  # …and the I/O layer actually EMITS that unreadable token, so the rows above are reachable in real
  # life rather than only from hand-fed arguments. (They were not: both counters used to answer 0.)
  ck "count_clarify on an unreadable file"     "$(count_clarify /nonexistent/spec.md)" "unreadable"
  ck "count_accept_cmds on an unreadable file" "$(count_accept_cmds /nonexistent/spec.md)" "unreadable"
  echo "== the intake label is NOT the label the feature author sweeps (fitness RETURN, d339476) =="
  ck "INTAKE_LABEL default is not 'backlog'" "$INTAKE_LABEL" "objective"
  echo; echo "intake-file selftest: $p passed, $f failed"; [ "$f" -eq 0 ]; exit
fi

log(){ echo "intake: $*" >&2; }

MODE=""; SPEC=""; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; SPEC="${2:-}"; shift 2 ;;
    --file)  MODE=file;  SPEC="${2:-}"; shift 2 ;;
    --repo)  REPO="${2:-}"; shift 2 ;;
    *) echo "usage: intake-file.sh {--check <spec.md> | --file <spec.md> --repo <repo>} | --selftest" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] && [ -r "$SPEC" ] || { echo "usage: intake-file.sh {--check <spec.md> | --file <spec.md> --repo <repo>} | --selftest" >&2; exit 2; }

verdict="$(spec_verdict "$(has_title "$SPEC")" "$(count_accept_cmds "$SPEC")" "$(count_clarify "$SPEC")" \
                        "$(has_section "$SPEC" Scope)" "$(has_section "$SPEC" 'Out of scope')" \
                        "$(delivered_value "$SPEC")" "$(has_section "$SPEC" How)" "$(has_baseline "$SPEC")" \
                        "$(has_ruled_out "$SPEC")" "$(stop_after "$SPEC")" "$(section_lines "$SPEC" How)")"
rc=$?
if [ "$rc" -ne 0 ]; then
  log "REFUSED — $verdict"
  log "the spec is not yet something the loop can act on; finish the interview and re-check"
  exit 1
fi
log "spec is READY ($(count_accept_cmds "$SPEC") acceptance command(s), delivered=$(delivered_value "$SPEC"), stop after $(stop_after "$SPEC") attempt(s))"
# ADVISORY, never a refusal (see objective_names_a_path): an objective that names its own mechanism
# forbids the pivot that doctrine mandate 4 requires. Only the drafter can judge whether it really has.
if [ "$(objective_names_a_path "$SPEC")" = 1 ]; then
  log "NOTE: ## Objective names a file or script. If that is the METHOD rather than the OUTCOME, rewrite it as the outcome wanted — an objective that specifies its own mechanism cannot be solved a better way. Not blocking; file it if the mechanism is genuinely the point."
fi
[ "$MODE" = check ] && exit 0

[ -n "$REPO" ] || { log "--file needs --repo"; exit 2; }

# R16 SCOPE BELT (see the header for WHICH layer and why). CEILING-ONLY: $SCOPE_SESSION is pinned EMPTY
# for this one call so the per-session narrowing stays inert — a NEW objective is never inside the
# current session's declared scope, and engaging that layer would refuse every intake from an ordinary
# undeclared conversation. Any non-zero rc (a missing reader's 127 included) REFUSES: fail-closed, and
# placed before the title/body are composed so an out-of-scope repo creates nothing at all.
REPO_SCOPE="${REPO_SCOPE:-$(dirname "$(readlink -f "$0")")/repo-scope.sh}"
SCOPE_SESSION="" "$REPO_SCOPE" check "$REPO" 2>/dev/null \
  || { log "R16 SCOPE: '$REPO' is outside the apparatus's operating scope — the App is not installed on it, so the maintainer has not authorised work there. Refusing to file; nothing was created."; exit 4; }

title="$(grep -m1 -E '^#[[:space:]]+' "$SPEC" | sed -E 's/^#[[:space:]]+//')"
body="$(cat "$SPEC")"
bodyfile="$(mktemp)"
{
  printf '%s\n\n---\n\n' "$body"
  printf '<sub>Drafted conversationally with the maintainer and filed by `intake-file.sh` (R31). '
  printf 'Validated: has a title, a bounded scope, and at least one **runnable acceptance command**; '
  printf 'no unresolved clarification markers.</sub>\n\n'
  printf '**@%s — this is waiting on you.** Nothing is built from this issue until you apply the `%s` label.\n' \
         "$MAINTAINER" "$APPROVED_LABEL"
  printf 'It is filed as `%s`, which the feature author does not sweep; the one tap is what hands it to the planner\n' "$INTAKE_LABEL"
  printf '(`dev-plan.sh` decomposes it into feature tickets, which the loop then implements, gates and ships).\n'
  printf 'The agent deliberately cannot self-approve: `dev-plan.sh` resolves WHO applied the label and binds that actor to a maintainer role.\n'
} > "$bodyfile"

# CREATE-ON-USE the intake label (the dev-plan.sh / host-ticket.sh precedent): `gh issue create --label`
# HARD-FAILS on a label the repo does not carry, and `$INTAKE_LABEL` is deliberately NOT one of the
# labels the fleet already uses — so without this, the very first intake into any repo fails outright.
gh label create "$INTAKE_LABEL" --repo "$ORG/$REPO" --color 5319e7 \
   --description "a drafted objective awaiting the maintainer's '$APPROVED_LABEL' tap (R31 intake)" \
   --force >/dev/null 2>&1 || true

url="$(gh issue create --repo "$ORG/$REPO" --title "$title" --body-file "$bodyfile" \
        --label "$INTAKE_LABEL" --assignee "$MAINTAINER" 2>&1)" || {
  log "FAILED to file the issue: $url"; rm -f "$bodyfile"; exit 1; }
rm -f "$bodyfile"
log "FILED: $url"
log "next: the maintainer applies the '$APPROVED_LABEL' label — dev-loop's plan arm then hands it to dev-plan.sh, which decomposes it into backlog feature issues. Until that tap, nothing acts on it."
printf '%s\n' "$url"
