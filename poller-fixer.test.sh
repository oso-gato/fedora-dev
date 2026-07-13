#!/usr/bin/env bash
# poller-fixer.test.sh — MOCK end-to-end dry-run of bin/pr-poller.sh's RED→FIX arm (#152), with ZERO
# GitHub / network / model.
#
# WHY THIS EXISTS: run_fixer had ZERO coverage — the --selftest block only ever exercised the pure core,
# which is exactly how it shipped with BOTH #152 defects (the model handed the SHARED live clone, and a
# landing the poller never checked but cheerfully reported as "new head (if pushed)"). So this test
# drives the REAL sweep (`pr-poller.sh --once`) and asserts the OUTCOMES, not the internals.
#
# HOW IT BITES — the fixture is real where it must be:
#   * a REAL bare `origin` + REAL clones + the REAL bin/fresh-tree.sh, so the push and the
#     ls-remote landing check are REAL git against a real remote. `git` is intercepted ONLY to LIE
#     about a push (rc 0, pushed nothing) or to fail one — the two ways a landing silently doesn't happen.
#   * BOTH pre-#152 shared-clone paths (~/repos/<repo> AND ~/.local/share/<repo>) exist in the fake
#     HOME, so restoring the old `cd $HOME/.local/share/$POLLER_REPO` genuinely runs the model there —
#     and every case asserts the fixer's CWD was an isolated worktree on the PR's gated head, and that
#     both shared clones are left untouched on main. That mutation FAILS this test.
#   * dropping the origin-side landing verification makes the "push lied" case report LANDED. That
#     mutation FAILS this test too (both mutations were run against these cases; each one fails).
#
# Run:  bash poller-fixer.test.sh   → exit 0 = all cases pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
POLLER="$HERE/bin/pr-poller.sh"
[ -f "$POLLER" ] || { echo "FATAL: bin/pr-poller.sh not found"; exit 2; }
command -v git >/dev/null || { echo "FATAL: git required"; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
REALGIT="$(command -v git)"

# ---- stub gh: serve one open RED PR + the host's verdict/body. Never touches GitHub. ---------------
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    case "$*" in
      *"--state merged"*) : ;;                                    # retire pass: nothing merged
      *"--state open"*)   printf '%s\t%s\t%s\n' 1 "$FAKE_REF" "$FAKE_SHA";;
    esac ;;
  "pr view")
    case "$*" in
      # the FIX-reason fetch (its jq carries "VERDICT RED"): the host's FULL comment body
      *"VERDICT RED"*)  printf '**Host live-gate (Gate B): VERDICT RED** — fedora-dev @ %s\n\nCandidate log (tail):\n  install.sh: line 3: boom: command not found\n' "$FAKE_SHA";;
      # the ROUTING fetch: line 1 only, sha-bound
      *"--json comments"*) printf '**Host live-gate (Gate B): VERDICT RED** — fedora-dev @ %s\n' "$FAKE_SHA";;
    esac ;;
  "pr comment") printf 'SURFACE %s\n' "$*" >> "$FIX_LOG";;
  *)            printf 'GH %s\n' "$*" >> "$FIX_LOG";;
esac
exit 0
EOF

# ---- stub git: REAL git, except a push may be told to LIE (rc 0, nothing pushed) or to FAIL. -------
# The lying push is the whole point of requirement 3: a push's exit code is NOT evidence it landed.
cat > "$BIN/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = push ]; then
    printf 'GITPUSH %s\n' "\$*" >> "\$FIX_LOG"
    case "\${FAKE_PUSH:-real}" in
      fail)   exit 1 ;;   # the push errors out
      silent) exit 0 ;;   # the push LIES: rc 0, but origin never moves
    esac
    break
  fi
done
exec "$REALGIT" "\$@"
EOF

# ---- stub claude: the "fixer". Records WHERE it ran (the isolation assertion) then acts per case. --
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
# FAITHFUL TRANSPORT (#155): the real `claude -p` takes its prompt ON STDIN — an argv prompt past
# MAX_ARG_STRLEN (131072 bytes) cannot even EXEC — and drains it to EOF. Reading it from stdin here is
# what makes the FIXERPROMPT row BITE on the transport: restore the argv form in bin/pr-poller.sh and
# the recorded prompt is EMPTY, so `isolated()`'s prompt assertion FAILS.
prompt="$(cat)"
{ printf 'FIXERCWD %s\n' "$PWD"
  printf 'FIXERBRANCH %s\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  printf 'FIXERHEAD %s\n'   "$(git rev-parse HEAD 2>/dev/null)"
  printf 'FIXERARGV %s\n'   "$*"
  printf 'FIXERPROMPT %s\n' "$(printf '%s' "$prompt" | tr '\n' ' ')"
} >> "$FIX_LOG"
case "${FAKE_FIXER:-commit}" in
  commit)  echo fixed >> f; git add -A >/dev/null 2>&1; git commit -qm "fix the boom" >/dev/null 2>&1
           echo "fixed the build";;
  blocked) echo "FIXER_BLOCKED: the approach in the PR is wrong; needs a decision";;
  noop)    echo "looked at it, changed nothing";;      # no commit, no sentinel
esac
exit 0
EOF
chmod +x "$BIN"/*

pass=0; fail=0; n=0
ck(){ [ "$1" = 1 ] && return 0; fail=$((fail+1)); printf '  FAIL %s: %s\n' "$DESC" "$2"; OK=0; }

# Build a fresh fixture per case: bare origin + feature branch + BOTH shared clones in a fake HOME.
setup_case(){
  n=$((n+1)); CASE="$ROOT/c$n"; mkdir -p "$CASE"
  ORIGIN="$CASE/origin.git"; HOMEDIR="$CASE/home"; FIX_LOG="$CASE/fix.log"; : > "$FIX_LOG"
  git init -q --bare -b main "$ORIGIN"
  local s="$CASE/seed"
  git init -q -b main "$s"; git -C "$s" config user.email t@t; git -C "$s" config user.name t
  echo base > "$s/f"; git -C "$s" add -A; git -C "$s" commit -qm base
  git -C "$s" remote add origin "$ORIGIN"; git -C "$s" push -q origin main
  MAIN_SHA="$(git -C "$s" rev-parse HEAD)"
  git -C "$s" checkout -q -b "$1"; echo work > "$s/g"; git -C "$s" add -A; git -C "$s" commit -qm work
  git -C "$s" push -q origin "$1"
  SHA="$(git -C "$s" rev-parse HEAD)"          # the head the gate judged
  # BOTH pre-#152 shared-clone locations, so the old `cd` target really exists (mutation bites).
  mkdir -p "$HOMEDIR/repos" "$HOMEDIR/.local/share"
  CLONE="$HOMEDIR/repos/fedora-dev"; LIVECLONE="$HOMEDIR/.local/share/fedora-dev"
  git clone -q "$ORIGIN" "$CLONE"; git clone -q "$ORIGIN" "$LIVECLONE"
  # per-repo identity, as the real clones carry (HOME is faked, so there is no global gitconfig);
  # a worktree inherits its clone's config, which is what lets the fixer commit in there.
  local c; for c in "$CLONE" "$LIVECLONE"; do
    git -C "$c" config user.email claudebox@fedora-dev.local; git -C "$c" config user.name claudebox
  done
  WTDIR="$CASE/wt"; WT="$WTDIR/fedora-dev__$(printf '%s' "$1" | tr '/' '-')"
}

sweep(){ # <ref> <sha-the-poller-thinks-is-head> [env…]
  local ref="$1" sha="$2"; shift 2
  # FLEET_HALT=true pins the R9 gate OPEN (#151) so every row below tests what it means to test; the
  # HALTED row overrides it with FLEET_HALT=false (later env assignments win) to pin the gate SHUT.
  # shellcheck disable=SC2086
  env PATH="$BIN:$PATH" HOME="$HOMEDIR" FIX_LOG="$FIX_LOG" FD_WORKTREES="$WTDIR" \
      POLLER_REPOS=fedora-dev POLLER_REPO=fedora-dev POLLER_ARMED=0 FIXER_TIMEOUT=60 \
      POLLER_FIXER="claude -p" FLEET_HALT=true FAKE_REF="$ref" FAKE_SHA="$sha" "$@" \
      bash "$POLLER" --once > "$CASE/out.log" 2>&1
}

origin_sha(){ git -C "$ORIGIN" rev-parse "refs/heads/$1" 2>/dev/null; }
clone_intact(){ # both shared clones must still sit on main at the base commit — never mutated
  local c
  for c in "$CLONE" "$LIVECLONE"; do
    [ "$(git -C "$c" rev-parse --abbrev-ref HEAD)" = main ] || return 1
    [ "$(git -C "$c" rev-parse HEAD)" = "$MAIN_SHA" ]       || return 1
  done
}
# invariants every single case must hold, whatever the outcome
common(){
  ck "$(clone_intact && echo 1 || echo 0)" "a shared clone was mutated (HEAD moved off main) — the fixer must never run there"
  ck "$([ ! -d "$WT" ] && echo 1 || echo 0)" "the throwaway worktree was not reaped (Principle 10): $WT"
  ck "$(grep -q '(if pushed)' "$CASE/out.log" && echo 0 || echo 1)" "the log still shrugs '(if pushed)' — the landing must be known, not guessed"
}
# the model ran ONLY in an isolated worktree, on the PR's gated head
isolated(){
  local cwd; cwd="$(sed -n 's/^FIXERCWD //p' "$FIX_LOG" | head -1)"
  ck "$([ -n "$cwd" ] && echo 1 || echo 0)" "the fixer never ran"
  ck "$([ "$cwd" != "$CLONE" ] && [ "$cwd" != "$LIVECLONE" ] && echo 1 || echo 0)" "the fixer ran in a SHARED CLONE ($cwd) — isolation is not optional"
  ck "$([ "$cwd" = "$WT" ] && echo 1 || echo 0)" "the fixer did not run in the isolated worktree (cwd=$cwd want=$WT)"
  ck "$(grep -qx "FIXERHEAD $SHA" "$FIX_LOG" && echo 1 || echo 0)" "the fixer's tree was not on the PR's GATED head ($SHA)"
  ck "$(grep -qx "FIXERBRANCH $FAKE_REF" "$FIX_LOG" && echo 1 || echo 0)" "the fixer's tree was not on the PR's branch ($FAKE_REF)"
  ck "$(grep -q "FIXERPROMPT.*Do NOT 'git push'" "$FIX_LOG" && echo 1 || echo 0)" "the model was not told the harness owns the push — ON STDIN (an argv prompt would be EMPTY here, and past 131072 bytes would not even exec: #155)"
  # …and the prompt reached it ONLY on stdin: nothing but the flags may ride argv (#155). A prompt in
  # argv is a latent E2BIG — the fixer's prompt carries a gate's own findings and grows with them.
  ck "$(grep -qx 'FIXERARGV -p' "$FIX_LOG" && echo 1 || echo 0)" "the prompt (or anything else) rode ARGV: $(sed -n 's/^FIXERARGV //p' "$FIX_LOG" | head -1 | cut -c1-60)"
}
never_ran(){ ck "$(grep -q '^FIXERCWD' "$FIX_LOG" && echo 0 || echo 1)" "the model RAN when the harness could not isolate/gate it — it must attempt no fix"; }
no_push(){   ck "$(grep -q '^GITPUSH' "$FIX_LOG" && echo 0 || echo 1)" "something pushed on a non-landing outcome"; }
surfaced(){  ck "$(grep -q '^SURFACE' "$FIX_LOG" && echo 1 || echo 0)" "a non-landing outcome did not surface honestly"; }
logs(){      ck "$(grep -q "$1" "$CASE/out.log" && echo 1 || echo 0)" "log does not report [$1]"; }
notlogs(){   ck "$(grep -q "$1" "$CASE/out.log" && echo 0 || echo 1)" "log wrongly reports [$1]"; }
done_case(){ [ "$OK" = 1 ] && { pass=$((pass+1)); printf '  ok   %s\n' "$DESC"; }; }

# ===================================================================================================
echo "== LANDED: model commits in the worktree → the HARNESS pushes → origin verified advanced =="
DESC="a real fix lands and is reported as landed"; OK=1
setup_case feat/x; FAKE_REF=feat/x
sweep feat/x "$SHA" FAKE_FIXER=commit
isolated; common
logs 'FIXER LANDED'
ck "$([ "$(origin_sha feat/x)" != "$SHA" ] && echo 1 || echo 0)" "origin/feat/x did NOT advance — nothing actually landed"
ck "$(grep -q "GITPUSH.*HEAD:refs/heads/feat/x" "$FIX_LOG" && echo 1 || echo 0)" "the harness did not push the feature ref explicitly"
ck "$(git -C "$ORIGIN" rev-parse refs/heads/main >/dev/null 2>&1 && [ "$(origin_sha main)" = "$MAIN_SHA" ] && echo 1 || echo 0)" "origin/main moved — the fixer must NEVER touch main"
done_case

echo "== NOT LANDED: the push LIES (rc 0, origin never moves) → verification against ORIGIN catches it =="
DESC="a push that reports success but lands nothing is NOT reported as landed"; OK=1
setup_case feat/x; FAKE_REF=feat/x
sweep feat/x "$SHA" FAKE_FIXER=commit FAKE_PUSH=silent
isolated; common
logs 'FIXER DID NOT LAND'; notlogs 'FIXER LANDED'; surfaced
ck "$([ "$(origin_sha feat/x)" = "$SHA" ] && echo 1 || echo 0)" "fixture broken: origin moved on a silent push"
done_case

echo "== PUSH FAILED: the push errors → the fix did not land, and the poller says so =="
DESC="a failed push is surfaced, never called a success"; OK=1
setup_case feat/x; FAKE_REF=feat/x
sweep feat/x "$SHA" FAKE_FIXER=commit FAKE_PUSH=fail
isolated; common
logs 'FIXER PUSH FAILED'; notlogs 'FIXER LANDED'; surfaced
ck "$([ "$(origin_sha feat/x)" = "$SHA" ] && echo 1 || echo 0)" "origin advanced despite a failed push"
done_case

echo "== BLOCKED: the model declares it cannot fix → surfaced, nothing pushed =="
DESC="an explicit FIXER_BLOCKED surfaces and pushes nothing"; OK=1
setup_case feat/x; FAKE_REF=feat/x
sweep feat/x "$SHA" FAKE_FIXER=blocked
isolated; common; no_push; surfaced
logs 'FIXER BLOCKED'; notlogs 'FIXER LANDED'
ck "$([ "$(origin_sha feat/x)" = "$SHA" ] && echo 1 || echo 0)" "origin moved on a BLOCKED fixer"
done_case

echo "== NO COMMIT: the model commits nothing → surfaced as no-commit, nothing pushed =="
DESC="a fixer that commits nothing is distinguishable, not a silent success"; OK=1
setup_case feat/x; FAKE_REF=feat/x
sweep feat/x "$SHA" FAKE_FIXER=noop
isolated; common; no_push; surfaced
logs 'FIXER NO-COMMIT'; notlogs 'FIXER LANDED'
done_case

echo "== UN-GATED HEAD: the branch moved after the sweep read it → skip; no model, no push =="
DESC="a head the gate never judged is never fixed"; OK=1
setup_case feat/x; FAKE_REF=feat/x
STALE="$SHA"                                        # what the sweep believes the head is
git -C "$CASE/seed" commit -q --allow-empty -m "someone else pushed"; git -C "$CASE/seed" push -q origin feat/x
NEW="$(git -C "$CASE/seed" rev-parse HEAD)"
sweep feat/x "$STALE" FAKE_FIXER=commit
common; never_ran; no_push
logs 'BRANCH MOVED'; notlogs 'FIXER LANDED'
ck "$([ "$(origin_sha feat/x)" = "$NEW" ] && echo 1 || echo 0)" "origin/feat/x was overwritten — the poller must not touch an un-gated head"
done_case

echo "== LIVE-CLONE FALLBACK: only ~/.local/share/<repo> exists → still a WORKTREE off it, never IN it =="
DESC="the fallback clone is isolated FROM, not worked IN"; OK=1
setup_case feat/x; FAKE_REF=feat/x
rm -rf "$CLONE"                                     # force clone_for onto the live spec clone
sweep feat/x "$SHA" FAKE_FIXER=commit
logs 'FIXER LANDED'
ck "$([ "$(origin_sha feat/x)" != "$SHA" ] && echo 1 || echo 0)" "the fix did not land via the fallback clone"
# the live clone is the tree the POLLER ITSELF runs from — a worktree off it must leave its HEAD on main
ck "$([ "$(git -C "$LIVECLONE" rev-parse --abbrev-ref HEAD)" = main ] && [ "$(git -C "$LIVECLONE" rev-parse HEAD)" = "$MAIN_SHA" ] && echo 1 || echo 0)" "the live clone's HEAD moved — a worktree must never disturb the tree the poller runs from"
ck "$(grep -qx "FIXERCWD $WT" "$FIX_LOG" && echo 1 || echo 0)" "the fixer did not run in the isolated worktree"
ck "$([ ! -d "$WT" ] && echo 1 || echo 0)" "the throwaway worktree was not reaped"
done_case

# ---------------------------------------------------------------------------------------------------
# R9 FLEET HALT (#151): the switch is read at the TOP of every tick, BEFORE any model run — a halted
# sweep is OBSERVE-ONLY: it still logs the routing decision (the operator sees the queue) but spawns no
# fixer, pushes nothing, posts nothing. FLEET_HALT=false stands in for every non-GO outcome at once
# (HALT, PAUSE, a dead checker: rc ≠ 0 is the whole contract). This row is the mutation detector
# requirement 8 demands for THIS sweeper: delete the halt check from sweep()/sweep_repo() and it fails
# (the fixer runs and the RED PR is acted on under HALT).
echo "== R9 FLEET HALT (#151): a HALTED tick is OBSERVE-ONLY — no fixer, no push, no comment =="
DESC="a fleet HALT spawns no model run on a RED PR (observed, logged, untouched)"; OK=1
setup_case feat/x; FAKE_REF=feat/x
sweep feat/x "$SHA" FAKE_FIXER=commit FLEET_HALT=false
common; never_ran; no_push
ck "$(grep -q '^SURFACE' "$FIX_LOG" && echo 0 || echo 1)" "a HALTED sweep posted a comment — observe-only must write nothing"
logs 'FLEET HALT'                                    # the tick says it is halted…
logs 'HALTED — FIX not taken'                        # …and logs the decision it did NOT act on
notlogs 'FIXER LANDED'
ck "$([ "$(origin_sha feat/x)" = "$SHA" ] && echo 1 || echo 0)" "origin/feat/x moved during a HALTED sweep"
done_case

echo "== FRESH-TREE FAILS: fail-closed — no isolation ⇒ NO fix attempted (no shared-clone fallback) =="
DESC="an un-isolatable fix is refused, not run in the shared clone"; OK=1
setup_case feat/x; FAKE_REF=feat/ghost                 # origin has no such ref → fresh-tree.sh exits 2
sweep feat/ghost "$SHA" FAKE_FIXER=commit
common; never_ran; no_push; surfaced
logs 'FRESH-TREE FAILED'; notlogs 'FIXER LANDED'
done_case

# ---------------------------------------------------------------------------------------------------
# AN UNENTERABLE WORKTREE IS NOT ISOLATION — and it must be refused BY NAME. This is the isolation
# failure `-d` cannot see: the tree EXISTS, so the fresh-tree guard passes, and everything downstream
# rests on the `cd` in front of the model run. Two things must hold, and each has its own assertion:
#   * the model MUST NOT RUN. `cd "$wt" && set +o pipefail; <pipeline>` does NOT guarantee that — `&&`
#     binds to `set` ALONE and the `;` ends the list, so the pipeline runs even when the cd FAILED, in
#     the POLLER'S OWN cwd (a shared clone), told to commit: the 2026-06-28 cross-branch-leak hazard,
#     re-opened by a bash-precedence slip, in the merge path.
#   * the refusal must name its REAL cause. Before this fix the poller reached its branch-moved check
#     first (`git -C` cannot read an unenterable tree either), so it parked the PR on a bogus "the
#     branch moved" and surfaced NOTHING — safe, but lying about why. `notlogs 'BRANCH MOVED'` +
#     `surfaced` are the discriminators: the pre-fix script fails both.
#   * and the tree must still be REAPED. Refusing to USE a worktree is not a licence to LEAVE it on the
#     home volume: "reaped on EVERY path" (Principle 10) has no exception for the paths that refuse.
#     The first cut of this refusal returned before the reap — it leaked one tree per unenterable head,
#     forever, while the file above still claimed every path reaps. Asserted, not claimed.
echo "== WORKTREE UNENTERABLE: refuse by name — no model, no push, and the TRUE cause reported =="
DESC="a worktree that exists but cannot be entered runs NO model and is refused by its real cause"; OK=1
setup_case feat/x; FAKE_REF=feat/x
BADWT="$CASE/unenterable"; mkdir -p "$BADWT"; chmod 000 "$BADWT"
# Fixture check: as root, chmod cannot make a dir unenterable, and the row would pass vacuously.
if ( cd "$BADWT" ) 2>/dev/null; then
  chmod 755 "$BADWT"
  printf '  SKIP %s: running as root — a chmod-000 dir is still enterable, so this row cannot bite\n' "$DESC"
else
  # a fresh-tree that SUCCEEDS (rc 0, prints a real, EXISTING dir) — so only enterability is in question
  printf '#!/usr/bin/env bash\nprintf %%s "%s"\n' "$BADWT" > "$BIN/fresh-tree-bad.sh"; chmod +x "$BIN/fresh-tree-bad.sh"
  sweep feat/x "$SHA" FAKE_FIXER=commit FRESH_TREE="$BIN/fresh-tree-bad.sh"
  never_ran; no_push; surfaced
  ck "$(clone_intact && echo 1 || echo 0)" "a shared clone was MUTATED — the model ran in the caller's cwd because the cd was not a guard"
  ck "$([ "$(origin_sha feat/x)" = "$SHA" ] && echo 1 || echo 0)" "origin/feat/x moved — something was pushed from an un-isolated run"
  logs 'FRESH-TREE FAILED'                       # refused for what it IS: no usable isolated worktree
  notlogs 'BRANCH MOVED'                         # …not for what it merely LOOKS like from `git -C`
  notlogs 'FIXER NO-COMMIT'; notlogs 'FIXER LANDED'
  ck "$([ ! -d "$BADWT" ] && echo 1 || echo 0)" "the REFUSED worktree was left behind — every path reaps (Principle 10), including the ones that refuse to use the tree"
  chmod 755 "$BADWT" 2>/dev/null || true         # (a reaped tree is gone; this only matters if it leaked)
  done_case
fi

echo
echo "poller-fixer-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
