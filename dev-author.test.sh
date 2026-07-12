#!/usr/bin/env bash
# dev-author.test.sh — MOCK end-to-end dry-run of bin/dev-author.sh with ZERO GitHub / network / model.
#
# The author's load-bearing safety is its CONTROL FLOW: guard → isolate → bounded author → RECONCILE
# with current main → in-box gate → hand off (push + draft PR + ready + label + ONE shipped-confirmation
# comment on the issue, R5 audit loop), with a BLOCKED path that surfaces a dev-task question and opens
# NO PR. We exercise all of it by STUBBING gh, claude and validate.sh on PATH and asserting the exact
# sequence of calls each case makes — while NOTHING touches GitHub and the "author" is a scripted stub.
#
# THE FIXTURE IS REAL GIT (#150). A stale base cannot be EXPRESSED against a toy repo, so each case gets
# a REAL bare `origin`, a REAL clone, and the REAL bin/fresh-tree.sh — and the branch is REALLY pushed.
# `git` is intercepted only to LOG pushes (it still performs them), so the assertions can read ORIGIN's
# own refs: after a clean stale-base run, origin/main must be an ANCESTOR of the pushed branch — i.e.
# the PR is mergeable AT THE MOMENT IT IS OPENED, which is the whole requirement. The `claude` stub
# MOVES origin/main mid-run (as a concurrent PR merging really does), which is precisely the window the
# defect lived in: dev-author cut its tree at start, took ~11 min, and #147 merged inside that window.
#
# MUTATION-CHECKED: deleting the reconcile step (4b) from bin/dev-author.sh makes BOTH stale-base cases
# fail — the clean one pushes a branch main is not an ancestor of, and the conflicting one opens a PR
# that can never merge. (Both mutations were run.)
#
# Run:  bash dev-author.test.sh   → exit 0 = all cases pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
AUTHOR="$HERE/bin/dev-author.sh"
[ -f "$AUTHOR" ] || { echo "FATAL: bin/dev-author.sh not found"; exit 2; }
[ -f "$HERE/bin/fresh-tree.sh" ] || { echo "FATAL: bin/fresh-tree.sh not found"; exit 2; }
command -v git >/dev/null || { echo "FATAL: git required"; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
export REALGIT="$(command -v git)"
# the branch dev-author derives from (issue 42, title "Add a thing") — pinned so origin can be read
BRANCH="feat/42-add-a-thing"

# ---- stub gh: serve a per-case issue, log every mutating call, never touch GitHub. -----------------
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
sub="${1:-} ${2:-}"
case "$sub" in
  "issue view")
    case "$*" in
      *"--json body"*)
        printf '%s' "${FAKE_BODY:-Do the thing.}";;
      *"--json state,labels,title"*)
        # emit the three comma-operator lines dev-author reads: state, backlog(0/1), title
        bk=0; case "${FAKE_LABELS:-backlog}" in *backlog*) bk=1;; esac
        printf '%s\n%s\n%s\n' "${FAKE_STATE:-OPEN}" "$bk" "${FAKE_TITLE:-Add a thing}";;
      *) printf '{}';;
    esac ;;
  "pr list")   printf '%s' "${FAKE_PRLIST:-}";;                 # empty = no existing PR
  "pr create") printf 'PRCREATE %s\n' "$*" >> "$GH_LOG"; printf 'https://github.com/oso-gato/%s/pull/999\n' "${FAKE_REPO:-fedora-dev}";;
  "pr ready")  printf 'PRREADY %s\n' "$*" >> "$GH_LOG";;
  "pr edit")   printf 'PREDIT %s\n' "$*" >> "$GH_LOG";;
  "issue comment") printf 'ISSUECOMMENT %s\n' "$*" >> "$GH_LOG";;
  *)           printf 'GH %s\n' "$*" >> "$GH_LOG";;
esac
exit 0
EOF

# ---- stub git: REAL git, but every push is LOGGED (and still performed, against the real origin). --
cat > "$BIN/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  [ "\$a" = push ] && { printf 'GITPUSH %s\n' "\$*" >> "\$GH_LOG"; break; }
done
exec "$REALGIT" "\$@"
EOF

# ---- move-main.sh: ANOTHER PR merges to main WHILE the author is running (the #150 window). --------
# Uses REALGIT directly: this is a third party, not the author — its push must not appear in GH_LOG,
# so the "the author pushed only its own branch / pushed nothing" assertions stay honest.
cat > "$ROOT/move-main.sh" <<'EOF'
#!/usr/bin/env bash
set -e
"$REALGIT" -C "$MOVER" fetch -q origin
"$REALGIT" -C "$MOVER" checkout -q -B main origin/main
case "$1" in
  clean)    printf 'unrelated work\n' > "$MOVER/other";;   # a different file → rebases cleanly
  conflict) printf 'main-side rewrite\n' > "$MOVER/f";;    # the SAME file the author edits → conflict
esac
"$REALGIT" -C "$MOVER" add -A
"$REALGIT" -C "$MOVER" commit -qm "another PR merged while the author was running"
"$REALGIT" -C "$MOVER" push -q origin main
EOF

# ---- stub claude: the "author". Per FAKE_AUTHOR: commit+DONE / block / no-op. ----------------------
# It runs with CWD = the worktree (dev-author cd's in), so it commits there when asked. FAKE_MAIN_MOVE
# makes main move DURING the run — the concurrent-merge window the reconcile exists to survive.
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
# args: -p "<prompt>"   (we ignore the prompt; behavior is env-driven)
case "${FAKE_AUTHOR:-done}" in
  done)    echo change >> f; git add -A >/dev/null 2>&1; git commit -qm "impl" >/dev/null 2>&1;
           echo "did the work"; echo "AUTHOR_DONE: implement the thing";;
  blocked) echo "AUTHOR_BLOCKED: the issue needs a product decision";;
  noop)    echo "thought about it, changed nothing";;   # no commit, no sentinel → no-progress
esac
[ -n "${FAKE_MAIN_MOVE:-}" ] && bash "$MOVE_MAIN" "$FAKE_MAIN_MOVE"
exit 0
EOF

# ---- stub validate.sh: PASS unless FAKE_VALIDATE=RED. ----------------------------------------------
cat > "$BIN/validate.sh" <<'EOF'
#!/usr/bin/env bash
printf 'VALIDATE %s\n' "$*" >> "$GH_LOG"
[ "${FAKE_VALIDATE:-GREEN}" = GREEN ]
EOF
chmod +x "$BIN"/* "$ROOT/move-main.sh"

pass=0; fail=0; n=0

# a REAL bare origin + clone + mover clone, in a fresh fake HOME — one per case.
setup_case(){
  n=$((n+1)); CASE="$ROOT/c$n"; mkdir -p "$CASE"
  ORIGIN="$CASE/origin.git"; HOMEDIR="$CASE/home"; GH_LOG="$CASE/gh.log"; : > "$GH_LOG"
  WTDIR="$CASE/wt"
  "$REALGIT" init -q --bare -b main "$ORIGIN"
  local s="$CASE/seed"
  "$REALGIT" init -q -b main "$s"
  "$REALGIT" -C "$s" config user.email t@t; "$REALGIT" -C "$s" config user.name t
  printf 'base\n' > "$s/f"; "$REALGIT" -C "$s" add -A; "$REALGIT" -C "$s" commit -qm base
  "$REALGIT" -C "$s" remote add origin "$ORIGIN"; "$REALGIT" -C "$s" push -q origin main
  BASE_MAIN="$("$REALGIT" -C "$s" rev-parse HEAD)"
  mkdir -p "$HOMEDIR/repos"
  CLONE="$HOMEDIR/repos/fedora-dev"; MOVER="$CASE/mover"
  "$REALGIT" clone -q "$ORIGIN" "$CLONE"; "$REALGIT" clone -q "$ORIGIN" "$MOVER"
  local c; for c in "$CLONE" "$MOVER"; do
    "$REALGIT" -C "$c" config user.email claudebox@fedora-dev.local
    "$REALGIT" -C "$c" config user.name claudebox
  done
}

run_author(){ # <env…> — drives the REAL dev-author with the REAL fresh-tree against the real origin
  # shellcheck disable=SC2086
  env $1 PATH="$BIN:$PATH" HOME="$HOMEDIR" GH_LOG="$GH_LOG" FD_WORKTREES="$WTDIR" \
      MOVER="$MOVER" MOVE_MAIN="$ROOT/move-main.sh" FAKE_REPO=fedora-dev \
      AUTHOR_CLAUDE="claude -p" FRESH_TREE="$HERE/bin/fresh-tree.sh" VALIDATE="$BIN/validate.sh" \
      bash "$AUTHOR" fedora-dev 42 > "$CASE/out.log" 2>&1
}

ck(){ [ "$1" = 1 ] && return 0; fail=$((fail+1)); printf '  FAIL %s: %s\n' "$DESC" "$2"; OK=0; }
gl(){    ck "$(grep -q "$1" "$GH_LOG" && echo 1 || echo 0)" "${2:-missing [$1] in the gh log}"; }
notgl(){ ck "$(grep -q "$1" "$GH_LOG" && echo 0 || echo 1)" "${2:-wrongly did [$1]}"; }
origin_sha(){ "$REALGIT" -C "$ORIGIN" rev-parse -q --verify "refs/heads/$1" 2>/dev/null; }
done_case(){ [ "$OK" = 1 ] && { pass=$((pass+1)); printf '  ok   %s\n' "$DESC"; }; }

# the full hand-off, asserted the same way in every shipping case
shipped(){
  gl '^PRCREATE'  "no PR created"
  gl '^PRREADY'   "PR not marked ready"
  gl 'live-validate' "not labelled live-validate"
  gl '^GITPUSH'   "no push"
  gl '^VALIDATE'  "in-box validate not run"
  gl '^ISSUECOMMENT.*dev-author → shipped:.*pull/999' "no shipped confirmation (with PR URL) on the issue"
  ck "$([ "$(grep -c '^ISSUECOMMENT' "$GH_LOG")" -eq 1 ] && echo 1 || echo 0)" "expected exactly one issue comment (the shipped confirmation)"
}
# a not-DONE outcome: a question on the issue, and NOTHING shipped
questioned(){
  gl '^ISSUECOMMENT' "no BLOCKED/question comment on the issue"
  notgl '^PRCREATE'  "opened a PR when it should have surfaced a question"
  notgl '^GITPUSH'   "pushed a branch on a not-shipped outcome"
  notgl 'dev-author → shipped' "shipped confirmation on a not-shipped outcome"
}

echo "== happy path: author DONE + in-box GREEN → push + draft PR + ready + live-validate label =="
DESC="authored feature reaches the pipeline"; OK=1
setup_case; run_author "FAKE_AUTHOR=done FAKE_VALIDATE=GREEN"
shipped; gl 'draft'
ck "$([ "$(origin_sha "$BRANCH")" != "" ] && echo 1 || echo 0)" "the branch never reached origin"
done_case

# ===================================================================================================
# #150 — THE STALE BASE. main moves WHILE the bounded author runs (a concurrent PR merging: exactly
# what #147 did to #149). The PR must be MERGEABLE AT THE MOMENT IT IS OPENED, or not opened at all.
# ===================================================================================================
echo "== STALE BASE (clean): main moved mid-run → rebased onto CURRENT main → the PR is mergeable =="
DESC="a PR opened after main moved is still mergeable (rebased, work preserved)"; OK=1
setup_case; run_author "FAKE_AUTHOR=done FAKE_VALIDATE=GREEN FAKE_MAIN_MOVE=clean"
shipped
NEWMAIN="$(origin_sha main)"
ck "$([ "$NEWMAIN" != "$BASE_MAIN" ] && echo 1 || echo 0)" "fixture broken: main did not actually move"
# THE HEADLINE ASSERTION: current main is an ANCESTOR of what we pushed ⇒ the PR can merge. Without the
# reconcile the branch still hangs off the OLD main and this fails.
ck "$("$REALGIT" -C "$ORIGIN" merge-base --is-ancestor "$NEWMAIN" "$(origin_sha "$BRANCH")" && echo 1 || echo 0)" \
   "the pushed branch is NOT based on current main — the PR is unmergeable at the moment it was opened"
# and the reconcile PRESERVED both sides: the author's change AND main's landed work
ck "$("$REALGIT" -C "$ORIGIN" show "refs/heads/$BRANCH:f" | grep -q change && echo 1 || echo 0)" \
   "the rebase lost the author's own work"
ck "$("$REALGIT" -C "$ORIGIN" show "refs/heads/$BRANCH:other" >/dev/null 2>&1 && echo 1 || echo 0)" \
   "the branch does not carry main's landed work — it would revert another PR"
# the in-box gate must judge the RECONCILED tree, not the pre-rebase one
ck "$(grep -q '^VALIDATE' "$GH_LOG" && echo 1 || echo 0)" "in-box validate did not run"
done_case

echo "== STALE BASE (conflicting): main moved into a real collision → question on the issue, NO PR =="
DESC="an unmergeable stale-base PR is never opened — it surfaces instead"; OK=1
setup_case; run_author "FAKE_AUTHOR=done FAKE_VALIDATE=GREEN FAKE_MAIN_MOVE=conflict"
questioned
gl 'ISSUECOMMENT.*moved while this feature was being authored' "the question does not say the base moved"
ck "$([ -z "$(origin_sha "$BRANCH")" ] && echo 1 || echo 0)" "a known-unmergeable branch was pushed to origin"
ck "$([ "$(origin_sha main)" != "$BASE_MAIN" ] && echo 1 || echo 0)" "fixture broken: main did not actually move"
done_case

echo "== BLOCKED: author cannot implement → dev-task question on the ISSUE, NO PR =="
DESC="explicit AUTHOR_BLOCKED surfaces"; OK=1
setup_case; run_author "FAKE_AUTHOR=blocked"
questioned; gl 'needs a decision'
done_case

echo "== no-progress: author commits nothing, no sentinel → surfaced, NO PR =="
DESC="no-commit is surfaced not shipped"; OK=1
setup_case; run_author "FAKE_AUTHOR=noop"
questioned
done_case

echo "== in-box RED: author commits but validate.sh fails → surfaced, NO PR, NO push =="
DESC="in-box RED blocks the push"; OK=1
setup_case; run_author "FAKE_AUTHOR=done FAKE_VALIDATE=RED"
questioned
ck "$([ -z "$(origin_sha "$BRANCH")" ] && echo 1 || echo 0)" "an in-box RED branch reached origin"
done_case

echo "== guards: closed / non-backlog / already-PR'd issues are never authored =="
DESC="closed issue → skip"; OK=1
setup_case; run_author "FAKE_STATE=CLOSED FAKE_AUTHOR=done"
notgl '^PRCREATE' "opened a PR on a closed issue"; done_case

DESC="non-backlog issue → skip"; OK=1
setup_case; run_author "FAKE_LABELS=bug FAKE_AUTHOR=done"
notgl '^PRCREATE' "opened a PR on a non-backlog issue"; done_case

DESC="existing PR → skip"; OK=1
setup_case; run_author "FAKE_PRLIST=17 FAKE_AUTHOR=done"
notgl '^PRCREATE' "re-authored an issue that already has a PR"; done_case

echo
echo "dev-author-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
