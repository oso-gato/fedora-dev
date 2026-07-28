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

# ---- stub gh: ONE open PR, live-validate-labelled, NO host/fitness verdict (host=NONE → plan()=NOOP),
# ---- with a controllable head-commit date so the R18 stall clock can be driven past its bound.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    case "$*" in
      *"--state merged"*) : ;;                                   # retire pass: nothing merged
      *"--state open"*)   printf '%s\t%s\t%s\t%s\n' 1 "$FAKE_REF" "$FAKE_SHA" "${FAKE_LABELS:-live-validate}";;
    esac ;;
  "pr view") : ;;                                                # no verdict comments at all → host=NONE
  "api "*)   case "$*" in *"/commits/"*) printf '%s\n' "$FAKE_COMMIT_DATE";; esac ;;
  "pr comment") printf 'SURFACE %s\n' "$*" >> "$FIX_LOG";;
  "issue create") printf 'ISSUE %s\n' "$*" >> "$FIX_LOG";;
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
  WTDIR="$CASE/wt"
}

sweep(){ # <script> [env…]
  local script="$1"; shift
  env PATH="$BIN:$PATH" HOME="$HOMEDIR" FIX_LOG="$FIX_LOG" FD_WORKTREES="$WTDIR" \
      POLLER_REPOS=fedora-dev POLLER_REPO=fedora-dev POLLER_ARMED=0 FIXER_TIMEOUT=60 \
      POLLER_FIXER="claude -p" FLEET_HALT=true FAKE_REF=feat/x FAKE_SHA="$SHA" \
      FAKE_COMMIT_DATE="$OLD" "$@" \
      bash "$script" --once > "$CASE/out.log" 2>&1
}

ran(){    grep -q '^FIXERCWD' "$FIX_LOG"; }
stalled_surfaced(){ grep -q 'SURFACE.*\[stalled\]' "$FIX_LOG"; }
origin_sha(){ git -C "$ORIGIN" rev-parse "refs/heads/$1" 2>/dev/null; }

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
ck "$([ "$(cat "$STATEDIR/repair-1-stalled.n" 2>/dev/null)" = 1 ] && echo 1 || echo 0)" "the repair budget was not charged (an uncharged budget never escalates)"
done_case

echo "== ESCALATE: the budget is SPENT → the human, and no further model run is spent =="
DESC="a spent repair budget escalates to the maintainer instead of churning the model"; OK=1
setup_case
printf '3' > "$STATEDIR/repair-1-stalled.n"
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
