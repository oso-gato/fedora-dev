#!/usr/bin/env bash
# poller-anomaly-repair.test.sh — R39/#278 ANOMALY → BOUNDED SELF-REPAIR, end to end, with ZERO
# GitHub / network / model.
#
# WHY THIS EXISTS: the first cut of #278 landed `anomaly_route` + `surface_or_repair` with a green
# `--selftest` and ZERO CALL SITES — a pure core that no sweep could ever reach, so the running poller
# behaved byte-identically to before while the PR claimed the unanticipated tail now self-repairs. A
# selftest of the pure router CANNOT see that nothing calls it. So this suite refuses to test the router:
# it drives the REAL sweep (`pr-poller.sh --once`) end to end and asserts THE MODEL ACTUALLY RAN on an
# anomaly — the one fact the pure-core layer is structurally blind to.
#
# HOW IT BITES — real where it must be: a REAL bare origin + REAL clone + the REAL bin/fresh-tree.sh, so
# the isolation, the push and the origin-side landing check are REAL git. Only `gh` (serves one aged,
# live-validate-labelled, host=NONE PR) and `claude` (records WHERE it ran and what prompt it got) are
# stubbed. The MUTATION row un-wires the call site — restoring exactly the shipped-dead-code state — and
# demands the model then never runs: that row is what makes every other row mean something.
#
# Run:  bash poller-anomaly-repair.test.sh   → exit 0 = all rows pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
POLLER="$HERE/bin/pr-poller.sh"
[ -f "$POLLER" ] || { echo "FATAL: bin/pr-poller.sh not found"; exit 2; }
command -v git >/dev/null || { echo "FATAL: git required"; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# ---- stub gh: ONE open PR, NO host/fitness verdict (host=NONE → plan()=NOOP), with a controllable
# ---- head-commit date so the R18 stall clock can be driven past its bound.
# ----
# ---- The row is SIX tab-separated fields, matching the poller's real list query exactly. That framing
# ---- is part of what is under test: `IFS=$'\t' read` collapses runs of tabs, so `labels` — empty on
# ---- most real PRs, and empty in every enrolment row below — must be LAST or it slides the fields
# ---- after it one slot left. Note `${FAKE_LABELS-…}` (not `:-`): an explicitly EMPTY FAKE_LABELS must
# ---- mean "no labels", which is the whole unenrolled fixture, while unset still means labelled.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    case "$*" in
      *"--state merged"*) : ;;                                   # retire pass: nothing merged
      *"--state open"*)   printf '%s\t%s\t%s\t%s\t%s\t%s\n' 1 "$FAKE_REF" "$FAKE_SHA" \
                            "${FAKE_AUTHOR:-oso-gato-nox-claudebox}" "${FAKE_DRAFT:-false}" \
                            "${FAKE_LABELS-live-validate}";;
    esac ;;
  "pr view") : ;;                                                # no verdict comments at all → host=NONE
  "api "*)   case "$*" in *"/commits/"*) printf '%s\n' "$FAKE_COMMIT_DATE";; esac ;;
  "pr comment") printf 'SURFACE %s\n' "$*" >> "$FIX_LOG";;
  "issue create") printf 'ISSUE %s\n' "$*" >> "$FIX_LOG";;
  "pr edit")
    printf 'PREDIT %s\n' "$*" >> "$FIX_LOG"
    # ENROLL_FAIL models the two ways a label add fails for real: `always` = no label-write on the repo
    # (a credential fact), `until-create` = the label does not exist YET (a brand-new repo — the miss
    # that cost 12 silent hours), so the add succeeds only once `gh label create` has run.
    case "${ENROLL_FAIL:-}" in
      always)       exit 1 ;;
      until-create) [ -f "${LABEL_CREATED:-/nonexistent}" ] || exit 1 ;;
    esac ;;
  "label create") printf 'LABELCREATE %s\n' "$*" >> "$FIX_LOG"; : > "${LABEL_CREATED:-/dev/null}" ;;
  *) printf 'GH %s\n' "$*" >> "$FIX_LOG";;
esac
exit 0
EOF

# ---- stub claude: the "fixer". Records WHERE it ran + the prompt it was handed (ON STDIN, as the real
# ---- `claude -p` takes it), then commits — so a repair that reaches it produces a REAL landed commit.
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
prompt="$(cat)"
{ printf 'FIXERCWD %s\n'    "$PWD"
  printf 'FIXERHEAD %s\n'   "$(git rev-parse HEAD 2>/dev/null)"
  printf 'FIXERPROMPT %s\n' "$(printf '%s' "$prompt" | tr '\n' ' ')"
} >> "$FIX_LOG"
echo repaired >> f; git add -A >/dev/null 2>&1; git commit -qm "repair the stuck pipeline" >/dev/null 2>&1
echo "repaired it"
exit 0
EOF
chmod +x "$BIN"/*

pass=0; fail=0; n=0
ck(){ [ "$1" = 1 ] && return 0; fail=$((fail+1)); printf '  FAIL %s: %s\n' "$DESC" "$2"; OK=0; }
done_case(){ [ "$OK" = 1 ] && { pass=$((pass+1)); printf '  ok   %s\n' "$DESC"; }; }

setup_case(){
  n=$((n+1)); CASE="$ROOT/c$n"; mkdir -p "$CASE"
  ORIGIN="$CASE/origin.git"; HOMEDIR="$CASE/home"; FIX_LOG="$CASE/fix.log"; : > "$FIX_LOG"
  git init -q --bare -b main "$ORIGIN"
  local s="$CASE/seed"
  git init -q -b main "$s"; git -C "$s" config user.email t@t; git -C "$s" config user.name t
  echo base > "$s/f"; git -C "$s" add -A; git -C "$s" commit -qm base
  git -C "$s" remote add origin "$ORIGIN"; git -C "$s" push -q origin main
  MAIN_SHA="$(git -C "$s" rev-parse HEAD)"
  git -C "$s" checkout -q -b feat/x; echo work > "$s/g"; git -C "$s" add -A; git -C "$s" commit -qm work
  git -C "$s" push -q origin feat/x
  SHA="$(git -C "$s" rev-parse HEAD)"                 # the head that is STUCK with no host verdict
  mkdir -p "$HOMEDIR/repos" "$HOMEDIR/.local/share"
  CLONE="$HOMEDIR/repos/fedora-dev"
  git clone -q "$ORIGIN" "$CLONE"
  git clone -q "$ORIGIN" "$HOMEDIR/.local/share/fedora-dev"
  local c; for c in "$CLONE" "$HOMEDIR/.local/share/fedora-dev"; do
    git -C "$c" config user.email claudebox@fedora-dev.local; git -C "$c" config user.name claudebox
  done
  STATEDIR="$HOMEDIR/.local/state/pr-poller"; mkdir -p "$STATEDIR"
  # $STATE is ONE dir shared across the 13-repo sweep, so these markers are REPO-QUALIFIED — a bare
  # `<pr>` made fedora-desktop#100 and any other repo's #100 the same file. DERIVED from the repo the
  # harness sweeps, not hardcoded, so a future rename cannot silently desync this suite again.
  MK_REPAIR="repair-fedora-dev-1-stalled.n"
  MK_ENROLLED="enrolled-fedora-dev-1.done"
  MK_ENROLL_N="enroll-fedora-dev-1.n"
  WTDIR="$CASE/wt"
  LABEL_CREATED="$CASE/label-created"
}

sweep(){ # <script> [env…]
  local script="$1"; shift
  env PATH="$BIN:$PATH" HOME="$HOMEDIR" FIX_LOG="$FIX_LOG" FD_WORKTREES="$WTDIR" \
      POLLER_REPOS=fedora-dev POLLER_REPO=fedora-dev POLLER_ARMED=0 FIXER_TIMEOUT=60 \
      POLLER_FIXER="claude -p" FLEET_HALT=true FAKE_REF=feat/x FAKE_SHA="$SHA" \
      FAKE_COMMIT_DATE="$OLD" LABEL_CREATED="$LABEL_CREATED" "$@" \
      bash "$script" --once > "$CASE/out.log" 2>&1
}

ran(){    grep -q '^FIXERCWD' "$FIX_LOG"; }
stalled_surfaced(){ grep -q 'SURFACE.*\[stalled\]' "$FIX_LOG"; }
origin_sha(){ git -C "$ORIGIN" rev-parse "refs/heads/$1" 2>/dev/null; }
enrolled(){ grep -q 'PREDIT.*--add-label live-validate' "$FIX_LOG"; }

OLD="$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

# ===================================================================================================
echo "== REPAIR: an aged stuck head reaches the FIXER — not the maintainer (the #278 defect) =="
DESC="a live sweep on an anomaly actually RUNS the model and lands a repair"; OK=1
setup_case
sweep "$POLLER" POLLER_REPAIR_MAX=3
ck "$(ran && echo 1 || echo 0)" "THE MODEL NEVER RAN — surface_or_repair is unreachable from the sweep (the exact defect #278 exists to remove)"
ck "$(grep -q 'FIXERPROMPT.*PIPELINE ITSELF reached a state it has no rule for' "$FIX_LOG" && echo 1 || echo 0)" "the fixer was not given the ANOMALY framing (cause=ANOMALY prompt branch unreached)"
ck "$(grep -qx "FIXERHEAD $SHA" "$FIX_LOG" && echo 1 || echo 0)" "the fixer's tree was not on the PR's stuck head ($SHA)"
ck "$([ "$(sed -n 's/^FIXERCWD //p' "$FIX_LOG" | head -1)" != "$CLONE" ] && echo 1 || echo 0)" "the fixer ran in the SHARED CLONE — isolation is not optional"
ck "$(stalled_surfaced && echo 0 || echo 1)" "it surfaced [stalled] to the human anyway — repair must come FIRST, not alongside"
ck "$([ "$(origin_sha feat/x)" != "$SHA" ] && echo 1 || echo 0)" "origin/feat/x did NOT advance — the repair never landed"
ck "$([ "$(origin_sha main)" = "$MAIN_SHA" ] && echo 1 || echo 0)" "origin/main moved — a repair must NEVER touch main"
ck "$(grep -q 'ANOMALY.*\[stalled\] repair attempt 1/3' "$CASE/out.log" && echo 1 || echo 0)" "the repair attempt was not logged with its budget"
ck "$([ "$(cat "$STATEDIR/$MK_REPAIR" 2>/dev/null)" = 1 ] && echo 1 || echo 0)" "the repair budget was not charged (an uncharged budget never escalates)"
done_case

echo "== ESCALATE: the budget is SPENT → the human, and no further model run is spent =="
DESC="a spent repair budget escalates to the maintainer instead of churning the model"; OK=1
setup_case
printf '3' > "$STATEDIR/$MK_REPAIR"
sweep "$POLLER" POLLER_REPAIR_MAX=3
ck "$(ran && echo 0 || echo 1)" "the model ran despite a spent budget — the bound does not bind"
ck "$(stalled_surfaced && echo 1 || echo 0)" "a spent budget did not reach the human at all (the PR is now stranded silently)"
ck "$(grep -q 'attempted bounded self-repair' "$FIX_LOG" && echo 1 || echo 0)" "the escalation does not tell the human repair was tried first"
ck "$([ "$(origin_sha feat/x)" = "$SHA" ] && echo 1 || echo 0)" "origin moved on an escalation"
done_case

echo "== INFRA: repair disabled (POLLER_REPAIR_MAX=0) → straight to the human, no model =="
DESC="POLLER_REPAIR_MAX=0 restores the old surface-only behaviour exactly"; OK=1
setup_case
sweep "$POLLER" POLLER_REPAIR_MAX=0
ck "$(ran && echo 0 || echo 1)" "the model ran with repair DISABLED"
ck "$(stalled_surfaced && echo 1 || echo 0)" "with repair disabled the anomaly reached nobody — it must still surface"
done_case

# ===================================================================================================
# UNENROLLED-PR SELF-HEAL (#278 task 5). The host live-gate discovers work by the `live-validate` label
# and by nothing else, so an unlabelled PR is not "waiting" — it is unreachable, forever, in silence.
# ===================================================================================================
echo "== SELF-HEAL: an UNLABELLED dev-authored PR enrols itself =="
DESC="an unenrolled dev PR gets the live-validate label added, with no human involved"; OK=1
setup_case
sweep "$POLLER" POLLER_REPAIR_MAX=3 FAKE_LABELS=
ck "$(enrolled && echo 1 || echo 0)" "the PR was NEVER enrolled — an unlabelled PR can never be verdicted, so it stays invisible to the gate forever (the exact #271/#277/bootstrap#283 stall)"
ck "$(grep -q 'SELF-HEAL.*enrolled in the host live-gate' "$CASE/out.log" && echo 1 || echo 0)" "the self-heal was not logged — a silent repair is indistinguishable from the silence it replaced"
ck "$([ -f "$STATEDIR/$MK_ENROLLED" ] && echo 1 || echo 0)" "no one-shot marker written — without it the loop re-adds a label a human may have deliberately removed"
ck "$(grep -q 'SURFACE' "$FIX_LOG" && echo 0 || echo 1)" "it bothered the maintainer with something it could fix itself"
ck "$(ran && echo 0 || echo 1)" "it summoned the MODEL to add a label — run_fixer commits code in a worktree; it cannot label anything"
done_case

echo "== SELF-HEAL is ONE SHOT: we heal an omission, we do not fight a decision =="
DESC="a second sweep does not re-add a label that was removed after we enrolled it"; OK=1
setup_case
: > "$STATEDIR/$MK_ENROLLED"                    # we already enrolled this PR once
sweep "$POLLER" POLLER_REPAIR_MAX=3 FAKE_LABELS=
ck "$(enrolled && echo 0 || echo 1)" "it re-enrolled an already-enrolled PR — the label is gone because somebody removed it, and re-adding it every 30s is the loop arguing with a human"
done_case

# The form gh ACTUALLY renders for the identity that authors every PR this self-heal exists for. A raw
# `=` against DEV_LOGIN matches none of them, so without normalisation the feature ships green and DEAD —
# which is #278's own defect. This row is the one that catches that, and it is not hypothetical: it is
# why bin/objective-status.sh already carries the same two-line normalisation.
echo "== SELF-HEAL normalises the App author form: 'app/<login>' is the dev login =="
DESC="an App-rendered author (app/… and [bot]) still enrols — else the feature is dead on arrival"; OK=1
setup_case
sweep "$POLLER" POLLER_REPAIR_MAX=3 FAKE_LABELS= FAKE_AUTHOR="app/oso-gato-nox-claudebox"
ck "$(enrolled && echo 1 || echo 0)" "the app/-prefixed author did not match DEV_LOGIN, so NO App-authored PR would ever self-enrol — the feature would be green, wired, and inert"
setup_case
sweep "$POLLER" POLLER_REPAIR_MAX=3 FAKE_LABELS= FAKE_AUTHOR="oso-gato-nox-claudebox[bot]"
ck "$(enrolled && echo 1 || echo 0)" "the [bot]-suffixed author form did not match DEV_LOGIN"
done_case

echo "== SELF-HEAL is DEV-SCOPED: a foreign contributor's PR is never touched =="
DESC="an unlabelled PR authored by someone else is left alone"; OK=1
setup_case
sweep "$POLLER" POLLER_REPAIR_MAX=3 FAKE_LABELS= FAKE_AUTHOR=some-human
ck "$(enrolled && echo 0 || echo 1)" "it enrolled a PR the loop does not own — labelling a stranger's PR into an autonomous merge pipeline is not ours to do"
done_case

echo "== SELF-HEAL skips DRAFTS: dev-author opens draft → ready → label, so a draft is mid-authoring =="
DESC="a draft dev PR is not enrolled out from under its author"; OK=1
setup_case
sweep "$POLLER" POLLER_REPAIR_MAX=3 FAKE_LABELS= FAKE_DRAFT=true
ck "$(enrolled && echo 0 || echo 1)" "it enrolled a DRAFT — that races dev-author's own R3 draft→ready→label handoff"
done_case

echo "== SELF-HEAL creates the label on use: the miss that cost 12 SILENT hours =="
DESC="a repo that does not carry the label yet gets it created, then the PR enrols"; OK=1
setup_case
sweep "$POLLER" POLLER_REPAIR_MAX=3 FAKE_LABELS= ENROLL_FAIL=until-create
ck "$(grep -q 'LABELCREATE.*live-validate' "$FIX_LOG" && echo 1 || echo 0)" "it never tried to CREATE the missing label — \`gh pr edit --add-label\` hard-fails on an unknown label, which is precisely the 12-hour stall"
ck "$(enrolled && echo 1 || echo 0)" "the retry behind the create never ran, so a brand-new repo can still never enrol a PR"
ck "$([ -f "$STATEDIR/$MK_ENROLLED" ] && echo 1 || echo 0)" "create-on-use succeeded but was not recorded as enrolled"
done_case

echo "== SELF-HEAL bounded: a PERMANENT label-write failure reaches the human, and not the model =="
DESC="an un-addable label escalates as enroll-infra after its bounded attempts"; OK=1
setup_case
sweep "$POLLER" POLLER_REPAIR_MAX=3 POLLER_ENROLL_MAX=1 FAKE_LABELS= ENROLL_FAIL=always
ck "$(grep -q 'SURFACE.*\[enroll-infra\]' "$FIX_LOG" && echo 1 || echo 0)" "a permanently un-enrollable PR reached nobody — it would re-try at sweep cadence forever, silently (R4)"
ck "$(ran && echo 0 || echo 1)" "it summoned the model to fix a credential fact — anomaly_route's *infra* family exists to stop exactly this"
ck "$([ -f "$STATEDIR/$MK_ENROLLED" ] && echo 0 || echo 1)" "it marked a FAILED enrolment as done, which would suppress every future retry"
ck "$([ "$(cat "$STATEDIR/$MK_ENROLL_N" 2>/dev/null)" = 1 ] && echo 1 || echo 0)" "the failure counter was not charged, so the bound can never be reached"
done_case

echo "== SELF-HEAL does not fire on a transient blip =="
DESC="a first failure under a bound of 3 retries quietly instead of paging the maintainer"; OK=1
setup_case
sweep "$POLLER" POLLER_REPAIR_MAX=3 POLLER_ENROLL_MAX=3 FAKE_LABELS= ENROLL_FAIL=always
ck "$(grep -q 'SURFACE' "$FIX_LOG" && echo 0 || echo 1)" "one transient API blip paged the maintainer — the bound exists so a blip self-heals on the next sweep"
ck "$([ "$(cat "$STATEDIR/$MK_ENROLL_N" 2>/dev/null)" = 1 ] && echo 1 || echo 0)" "the attempt was not counted toward the bound"
done_case

echo "== MUTATION: un-wire the enrolment call site → the label is never added =="
DESC="mutation: dropping the enroll_pr call restores the silent unlabelled NOOP"; OK=1
EMUTBIN="$ROOT/emutbin"; rm -rf "$EMUTBIN"; cp -a "$HERE/bin" "$EMUTBIN"
EMUT="$EMUTBIN/pr-poller.sh"
# #305 moved the enrol into a `case` arm on unenrolled_action, so the old whole-line sed no longer
# matches. Target the call itself, wherever it sits — and the vacuity guard below still proves it bit.
sed 's/enroll_pr "$pr" "$ref" "$sha" || true/: ;/' "$POLLER" > "$EMUT"
chmod +x "$EMUT"
# grep -F for the same reason the row below uses it: these literals carry `$`, which BRE would mangle.
if grep -qF 'enroll_pr "$pr" "$ref" "$sha" || true' "$EMUT"; then
  ck 0 "mutation VACUOUS — the enrol call site did not change shape (sed matched nothing), so this row proves nothing"
else
  setup_case
  sweep "$EMUT" POLLER_REPAIR_MAX=3 FAKE_LABELS=
  ck "$(enrolled && echo 0 || echo 1)" "the un-wired mutant STILL enrolled the PR — so the SELF-HEAL row above is not testing the call site"
fi
done_case

echo "== MUTATION: un-wire the call site (the shipped dead-code state) → the model must never run =="
DESC="mutation: reverting the call site to plain surface() makes the repair unreachable"; OK=1
# The mutant must sit BESIDE the real siblings: pr-poller.sh resolves repo-scope.sh / fresh-tree.sh /
# auto-merge.sh relative to its OWN dirname, so a mutant dropped in a bare tmpdir fails the R16 scope
# read and SKIPS the repo — a sweep that never happens would satisfy "the model did not run" for the
# wrong reason and make this row vacuous. Copy bin/, mutate the copy in place (poller-rebase.test.sh).
MUTBIN="$ROOT/mutbin"; rm -rf "$MUTBIN"; cp -a "$HERE/bin" "$MUTBIN"
MUT="$MUTBIN/pr-poller.sh"
# grep -F, NOT plain grep: GNU grep's BRE does not match these `$`-bearing literals, so an unanchored
# `grep -q` here would report "pattern absent" even when the sed matched nothing — a vacuity guard that
# always says "not vacuous" is not a guard. (Observed while writing this row.)
sed 's/surface_or_repair "$pr" "$ref" "$sha" "stalled"/surface "$pr" "$sha" "stalled"/' "$POLLER" > "$MUT"
chmod +x "$MUT"
if grep -qF 'surface_or_repair "$pr" "$ref" "$sha" "stalled"' "$MUT" \
   || ! grep -qF 'surface "$pr" "$sha" "stalled"' "$MUT"; then
  ck 0 "mutation VACUOUS — the stalled call site did not change shape (sed matched nothing), so this row proves nothing"
else
  setup_case
  sweep "$MUT" POLLER_REPAIR_MAX=3
  ck "$(ran && echo 0 || echo 1)" "the un-wired mutant STILL ran the model — the wiring is not what routes to repair, so the REPAIR row above is not testing the call site"
  ck "$(stalled_surfaced && echo 1 || echo 0)" "the un-wired mutant did not surface either (fixture broken: the anomaly never fired)"
fi
done_case

echo; echo "poller-anomaly-repair: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
