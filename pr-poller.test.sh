#!/usr/bin/env bash
# pr-poller.test.sh — MOCK end-to-end drive of the REAL sweep in bin/pr-poller.sh, focused on the
# RED-FIXER's isolation + landing contract (#148). ZERO GitHub, zero network, zero model.
#
# WHY THIS EXISTS: run_fixer() shipped with two defects and had ZERO coverage — `--selftest` only
# exercises the pure core (plan/verdict/supersede), which is exactly how (1) a fixer running in the
# SHARED LIVE CLONE and (2) a fixer whose landing was never verified both got through. So this drives
# the ACTUAL sweep — `pr-poller.sh --once` — with stubs on PATH (à la dev-author.test.sh) and asserts
# the OUTCOMES, against REAL git: a real bare `origin`, a real clone, a real `fresh-tree.sh` worktree.
# The push and the origin read-back are therefore honest, not simulated.
#
# WHAT EACH CASE PINS (the fixer's whole contract):
#   landed        the model ran in an ISOLATED worktree cut from the PR's OWN head, the HARNESS pushed
#                 (explicit feature refspec), origin actually advanced, the shared clone never moved
#   blocked       model said FIXER_BLOCKED    → surfaced, nothing pushed
#   no-commit     model committed nothing     → surfaced, nothing pushed (never a silent "finished")
#   tree-failed   no clone / fresh-tree fails → surfaced, the fixer NEVER RAN (no shared-clone fallback)
#   push-failed   push returns non-zero       → surfaced, nothing landed
#   did-not-land  push returns 0 but origin never moved → surfaced as NOT-LANDED, never as success
#   head-moved    the branch moved past the gated sha → skipped, un-gated head is not fixed
#   every path    the throwaway worktree is reaped (Principle 10)
#
# MUTATION-CHECKED (the point of the exercise): the final section restores each defect in a COPY of the
# poller and re-runs this whole suite against it, asserting it FAILS. A test that passes against the
# pre-fix code is worth nothing — so this file proves, on every run, that it bites.
#
# Run:  bash pr-poller.test.sh   → exit 0 = all cases pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
POLLER="${POLLER_UNDER_TEST:-$HERE/bin/pr-poller.sh}"
[ -f "$POLLER" ] || { echo "FATAL: $POLLER not found"; exit 2; }
G="$(command -v git)" || { echo "FATAL: git is required"; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
REF="feat/mock"                      # the PR's own head ref — never main, per the fixer's guard

# ---- stub gh: serves ONE open PR carrying a host RED verdict bound to its head sha. ----------------
# gh's own `-q` jq already reduces `--json comments` to the trusted bot's LINE-1 headers bound to the
# sha, so the stub emits that RESULT directly (the sweep's line-1/sha binding is auto-merge.sh's G2
# territory and is not what this file tests).
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    case "$*" in
      *"--state merged"*) : ;;                                   # retire pass: no merged PRs
      *"--state open"*)   printf '%s\t%s\t%s\n' 1 "$FAKE_REF" "$FAKE_SHA";;
    esac ;;
  "pr view")
    case "$*" in
      *"--json comments"*) printf 'Host live-gate (Gate B): VERDICT %s — fedora-dev @ %s\n' "${FAKE_HOST:-RED}" "$FAKE_SHA";;
    esac ;;
  "pr comment") printf 'PRCOMMENT %s\n' "$*" >> "$GH_LOG";;
  *)            printf 'GH %s\n' "$*" >> "$GH_LOG";;
esac
exit 0
EOF

# ---- stub git: REAL git, except `push` — which FAKE_PUSH turns into a hard failure (rc 1) or a ------
# SILENT NO-OP (rc 0, nothing lands): the two shapes the landing verification exists to catch.
cat > "$BIN/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = push ]; then
    printf 'GITPUSH %s\n' "\$*" >> "\$GH_LOG"
    case "\${FAKE_PUSH:-real}" in
      fail) exit 1;;
      noop) exit 0;;
    esac
    break
  fi
done
exec $G "\$@"
EOF

# ---- stub fixer (the "model"): records WHERE it was run — the isolation assertion — then acts. ------
cat > "$BIN/fixer" <<EOF
#!/usr/bin/env bash
{ printf 'FIXER_CWD %s\n'    "\$PWD"
  printf 'FIXER_HEAD %s\n'   "\$($G rev-parse HEAD 2>/dev/null)"
  printf 'FIXER_BRANCH %s\n' "\$($G rev-parse --abbrev-ref HEAD 2>/dev/null)"; } >> "\$GH_LOG"
printf '%s\n' "\$*" > "\$FIXER_PROMPT"
case "\${FAKE_FIXER:-commit}" in
  commit)  echo fixed >> fix.txt; $G add -A >/dev/null 2>&1; $G commit -qm 'fix: mock' >/dev/null 2>&1
           echo "fixed it";;
  blocked) echo "FIXER_BLOCKED: the approach is wrong";;
  noop)    echo "thought about it, changed nothing";;
esac
exit 0
EOF
chmod +x "$BIN"/*

pass=0; fail=0
ok(){  pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
logs(){   grep -qF "$1" "$PLOG"   2>/dev/null && ok "$2" || bad "$2 — poller.log lacks [$1]"; }
nologs(){ grep -qF "$1" "$PLOG"   2>/dev/null && bad "$2 — poller.log has [$1]" || ok "$2"; }
ghas(){   grep -qF "$1" "$GH_LOG" 2>/dev/null && ok "$2" || bad "$2 — gh.log lacks [$1]"; }
gnot(){   grep -qF "$1" "$GH_LOG" 2>/dev/null && bad "$2 — gh.log has [$1]" || ok "$2"; }
eq(){ [ "$1" = "$2" ] && ok "$3" || bad "$3 — want [$2] got [$1]"; }
ne(){ [ "$1" != "$2" ] && ok "$3" || bad "$3 — unchanged [$1]"; }

# The SHARED LIVE CLONE the poller itself runs from, checked out on main — exactly the production
# shape (~/.local/share/<repo>) and the tree the 2026-06-28 incident says the fixer must never touch.
setup(){ # <tag>
  HOME="$ROOT/h-$1"; export HOME
  ORIGIN="$HOME/origin.git"; CLONE="$HOME/.local/share/fedora-dev"; SEED="$ROOT/seed-$1"
  mkdir -p "$HOME/.local/share"
  $G init -q --bare -b main "$ORIGIN"
  $G init -q -b main "$SEED"
  $G -C "$SEED" config user.email t@t; $G -C "$SEED" config user.name tester
  printf 'base\n' > "$SEED/README.md"
  $G -C "$SEED" add -A; $G -C "$SEED" commit -qm base
  $G -C "$SEED" remote add origin "$ORIGIN"; $G -C "$SEED" push -q origin main
  $G -C "$SEED" checkout -q -b "$REF"
  printf 'work\n' > "$SEED/feature.txt"
  $G -C "$SEED" add -A; $G -C "$SEED" commit -qm feature; $G -C "$SEED" push -q origin "$REF"
  $G clone -q "$ORIGIN" "$CLONE"
  $G -C "$CLONE" config user.email t@t; $G -C "$CLONE" config user.name tester
  SHA="$($G -C "$CLONE" rev-parse "origin/$REF")"          # the head the sweep gates on
  GH_LOG="$HOME/gh.log"; : > "$GH_LOG"
  PROMPT="$HOME/prompt.txt"; : > "$PROMPT"
  PLOG="$HOME/.local/state/pr-poller/poller.log"
}
advance_origin(){ printf 'more\n' >> "$SEED/feature.txt"; $G -C "$SEED" add -A
                  $G -C "$SEED" commit -qm more >/dev/null; $G -C "$SEED" push -q origin "$REF"; }

run_sweep(){ # <env assignments…>
  CLONE_HEAD="$($G -C "$CLONE" rev-parse HEAD 2>/dev/null)"
  CLONE_BRANCH="$($G -C "$CLONE" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  env "$@" PATH="$BIN:$PATH" HOME="$HOME" \
      POLLER_REPOS=fedora-dev POLLER_REPO=fedora-dev POLLER_ARMED=0 \
      FAKE_SHA="$SHA" FAKE_REF="$REF" GH_LOG="$GH_LOG" FIXER_PROMPT="$PROMPT" \
      POLLER_FIXER="$BIN/fixer" FIXER_TIMEOUT=60 \
      bash "$POLLER" --once >/dev/null 2>&1
  ORIGIN_AFTER="$($G -C "$ORIGIN" rev-parse "refs/heads/$REF" 2>/dev/null)"
}
# the 2026-06-28 incident, asserted: the tree the poller runs from is never moved by the fixer.
clone_intact(){
  eq "$($G -C "$CLONE" rev-parse HEAD 2>/dev/null)"             "$CLONE_HEAD"   "$1: shared clone's HEAD never moved"
  eq "$($G -C "$CLONE" rev-parse --abbrev-ref HEAD 2>/dev/null)" "$CLONE_BRANCH" "$1: shared clone still on its own branch"
}
tree_reaped(){ [ -z "$(ls -A "$HOME/.cache/fd-worktrees" 2>/dev/null)" ] \
  && ok "$1: throwaway worktree reaped" || bad "$1: worktree left behind"; }

echo "== the pure core still passes (no regression to plan()/verdicts/supersede) =="
bash "$POLLER" --selftest >/dev/null 2>&1 && ok "--selftest" || bad "--selftest"

echo "== LANDED: isolated worktree on the PR's own head → model commits → HARNESS pushes → verified =="
setup landed; run_sweep FAKE_FIXER=commit
logs "FIX LANDED"                          "landed: reported as LANDED"
ne   "$ORIGIN_AFTER" "$SHA"                "landed: origin/$REF actually advanced"
ghas "FIXER_CWD $HOME/.cache/fd-worktrees/" "landed: the model ran in an ISOLATED worktree"
gnot "FIXER_CWD $CLONE"                    "landed: the model did NOT run in the shared live clone"
ghas "FIXER_HEAD $SHA"                     "landed: the worktree was cut from the PR's OWN head (not main)"
ghas "FIXER_BRANCH $REF"                   "landed: … checked out on the PR's own branch"
ghas "GITPUSH"                             "landed: the HARNESS performed the push"
ghas "HEAD:refs/heads/$REF"                "landed: … scoped to an explicit feature refspec"
gnot "PRCOMMENT"                           "landed: nothing surfaced to a human"
grep -qF "do NOT 'git push'" "$PROMPT" && ok "landed: the model is told NOT to push" \
                                       || bad "landed: the prompt does not forbid pushing"
clone_intact landed; tree_reaped landed

echo "== BLOCKED: the model declares it cannot proceed → surfaced, nothing pushed =="
setup blocked; run_sweep FAKE_FIXER=blocked
logs "FIX BLOCKED"          "blocked: reported as BLOCKED"
nologs "FIX LANDED"         "blocked: never reported as landed"
eq "$ORIGIN_AFTER" "$SHA"   "blocked: origin/$REF untouched"
gnot "GITPUSH"              "blocked: nothing pushed"
ghas "PRCOMMENT"            "blocked: surfaced for a human"
ghas "the approach is wrong" "blocked: … carrying the model's reason"
clone_intact blocked; tree_reaped blocked

echo "== NO-COMMIT: the model commits nothing and declares no block → surfaced, never a silent OK =="
setup nocommit; run_sweep FAKE_FIXER=noop
logs "FIX NO-COMMIT"        "no-commit: reported as NO-COMMIT"
nologs "FIX LANDED"         "no-commit: never reported as landed"
eq "$ORIGIN_AFTER" "$SHA"   "no-commit: origin/$REF untouched"
gnot "GITPUSH"              "no-commit: nothing pushed"
ghas "PRCOMMENT"            "no-commit: surfaced honestly"
tree_reaped nocommit

echo "== TREE-FAILED (no clone): isolation impossible → FAIL CLOSED, the fixer never runs =="
setup noclone; rm -rf "$CLONE"; CLONE_HEAD=""; CLONE_BRANCH=""
run_sweep FAKE_FIXER=commit
logs "FIX TREE-FAILED"      "no-clone: reported as TREE-FAILED"
gnot "FIXER_CWD"            "no-clone: NO shared-clone fallback — the fixer was never spawned"
gnot "GITPUSH"              "no-clone: nothing pushed"
ghas "PRCOMMENT"            "no-clone: surfaced"
eq "$ORIGIN_AFTER" "$SHA"   "no-clone: origin/$REF untouched"

echo "== TREE-FAILED (worktree creation fails): same fail-closed outcome =="
setup treefail; run_sweep FAKE_FIXER=commit FRESH_TREE=/bin/false
logs "FIX TREE-FAILED"      "tree-fail: reported as TREE-FAILED"
gnot "FIXER_CWD"            "tree-fail: the fixer was never spawned"
gnot "GITPUSH"              "tree-fail: nothing pushed"
ghas "PRCOMMENT"            "tree-fail: surfaced"
clone_intact treefail; tree_reaped treefail

echo "== PUSH-FAILED: the model committed but the push failed → surfaced, nothing landed =="
setup pushfail; run_sweep FAKE_FIXER=commit FAKE_PUSH=fail
logs "FIX PUSH-FAILED"      "push-fail: reported as PUSH-FAILED"
nologs "FIX LANDED"         "push-fail: never reported as landed"
eq "$ORIGIN_AFTER" "$SHA"   "push-fail: origin/$REF untouched"
ghas "PRCOMMENT"            "push-fail: surfaced"
tree_reaped pushfail

echo "== DID-NOT-LAND: push exits 0 but origin never moved → NOT-LANDED (the push rc is not proof) =="
setup notland; run_sweep FAKE_FIXER=commit FAKE_PUSH=noop
logs "FIX NOT-LANDED"       "not-landed: the landing is VERIFIED against origin, not assumed"
nologs "FIX LANDED"         "not-landed: a silent no-op is never reported as success"
eq "$ORIGIN_AFTER" "$SHA"   "not-landed: origin/$REF untouched"
ghas "PRCOMMENT"            "not-landed: surfaced honestly"
tree_reaped notland

echo "== HEAD-MOVED: the branch advanced past the gated sha → skip; the new head re-gates itself =="
setup headmoved; advance_origin
NEWSHA="$($G -C "$ORIGIN" rev-parse "refs/heads/$REF")"
run_sweep FAKE_FIXER=commit
logs "FIX SKIP-HEAD-MOVED"  "head-moved: an un-gated head is not fixed"
gnot "FIXER_CWD"            "head-moved: the fixer was never spawned"
gnot "GITPUSH"              "head-moved: nothing pushed"
gnot "PRCOMMENT"            "head-moved: not surfaced (it is not a failure)"
eq "$ORIGIN_AFTER" "$NEWSHA" "head-moved: origin/$REF left exactly as the pusher left it"
tree_reaped headmoved

# ---- MUTATION CHECK — restore each defect in a COPY and prove this suite FAILS against it. ---------
if [ "${POLLER_MUTANT:-0}" = 0 ]; then
  echo
  echo "== MUTATION CHECK: with either #148 defect restored, this suite MUST fail =="
  mutn=0
  mutate(){ # <desc> <sed-expr applied to the poller>
    mutn=$((mutn+1)); local d="$ROOT/mut$mutn"
    mkdir -p "$d"; cp "$HERE"/bin/*.sh "$d/"          # siblings too: $HERE resolves inside the copy
    sed -E -i "$2" "$d/pr-poller.sh"
    if cmp -s "$d/pr-poller.sh" "$POLLER"; then
      bad "mutation [$1] did not apply — the sed no longer matches the shipped code; FIX THIS TEST"
      return
    fi
    if POLLER_MUTANT=1 POLLER_UNDER_TEST="$d/pr-poller.sh" bash "$0" >/dev/null 2>&1
      then bad "mutation [$1] still PASSES — these tests do not bite"
      else ok  "mutation [$1] is CAUGHT"
    fi
  }
  mutate "defect 1: the fixer runs in the SHARED CLONE again" \
         's|cd "\$wt" && timeout|cd "$HOME/.local/share/$POLLER_REPO" \&\& timeout|'
  mutate "defect 2: the origin landing verification is dropped" \
         's|\[ "\$remote" != "\$head" \]|false|'
fi

echo
echo "pr-poller-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
