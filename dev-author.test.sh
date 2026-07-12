#!/usr/bin/env bash
# dev-author.test.sh — MOCK end-to-end dry-run of bin/dev-author.sh with ZERO GitHub / network / model.
#
# The author's load-bearing safety is its CONTROL FLOW: guard → isolate → bounded author → in-box gate
# → hand off (push + draft PR + ready + label + ONE shipped-confirmation comment on the issue, R5 audit
# loop), with a BLOCKED path that surfaces a dev-task question and opens NO PR. We exercise all of it by STUBBING gh, git, claude, fresh-tree.sh, and validate.sh on PATH
# and asserting the exact sequence of calls each case makes — while NOTHING touches GitHub, and the
# "author" is a scripted stub, so no real model runs. Runs on a plain runner (no podman, no gh, no net).
#
# Run:  bash dev-author.test.sh   → exit 0 = all cases pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
AUTHOR="$HERE/bin/dev-author.sh"
[ -f "$AUTHOR" ] || { echo "FATAL: bin/dev-author.sh not found"; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

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

# ---- stub fresh-tree.sh: make a real tiny git repo worktree so 'git rev-parse' works honestly. -----
# FAKE_WT=unenterable SUCCEEDS (rc 0) and prints a REAL, EXISTING directory that cannot be ENTERED —
# the one isolation failure dev-author's `-d`/rc guards let through, where the whole isolation rests on
# the `cd` in front of the model run. See the WORKTREE UNENTERABLE row.
cat > "$BIN/fresh-tree.sh" <<EOF
#!/usr/bin/env bash
wt="$ROOT/wt-\$RANDOM"; mkdir -p "\$wt"
if [ "\${FAKE_WT:-ok}" = unenterable ]; then chmod 000 "\$wt"; printf '%s\n' "\$wt"; exit 0; fi
git -C "\$wt" init -q; git -C "\$wt" config user.email t@t; git -C "\$wt" config user.name t
echo base > "\$wt/f"; git -C "\$wt" add -A; git -C "\$wt" commit -qm base
printf '%s\n' "\$wt"
EOF

# ---- stub validate.sh: PASS unless FAKE_VALIDATE=RED. ----------------------------------------------
cat > "$BIN/validate.sh" <<'EOF'
#!/usr/bin/env bash
printf 'VALIDATE %s\n' "$*" >> "$GH_LOG"
[ "${FAKE_VALIDATE:-GREEN}" = GREEN ]
EOF

# ---- stub claude: the "author". Per FAKE_AUTHOR: commit+DONE / block / no-op. ----------------------
# It runs with CWD = the worktree (dev-author cd's in), so it commits there when asked.
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
# FAITHFUL TRANSPORT (#155): the real `claude -p` takes its prompt ON STDIN — an argv prompt past
# MAX_ARG_STRLEN (131072 bytes) cannot even EXEC, and this one carries an unbounded ISSUE BODY — and it
# drains stdin to EOF. Record what actually arrived, and on which channel; the PROMPT row below asserts
# on it, so restoring the argv form in bin/dev-author.sh empties this file and FAILS the suite.
printf 'PROMPT %s\n' "$(cat | tr '\n' ' ')" >> "$GH_LOG"
printf 'CLAUDEARGV %s\n' "$*" >> "$GH_LOG"
case "${FAKE_AUTHOR:-done}" in
  done)    echo change >> f; git add -A >/dev/null 2>&1; git commit -qm "impl" >/dev/null 2>&1;
           echo "did the work"; echo "AUTHOR_DONE: implement the thing";;
  blocked) echo "AUTHOR_BLOCKED: the issue needs a product decision";;
  noop)    echo "thought about it, changed nothing";;   # no commit, no sentinel → no-progress
esac
exit 0
EOF

# ---- stub git push ONLY (real git for everything else) via a wrapper that intercepts 'push'. -------
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = push ] && { printf 'GITPUSH %s\n' "$*" >> "$GH_LOG"; exit 0; }; done
exec /usr/bin/git "$@"
EOF
chmod +x "$BIN"/*

pass=0; fail=0
run(){ # <desc> <env-assignments> <expect: PRCREATE|ISSUECOMMENT|NONE> <extra-grep-or-""> <absent-grep-or-"">
  local desc="$1" envs="$2" expect="$3" extra="${4:-}" absent="${5:-}"
  local home="$ROOT/home-$RANDOM"; mkdir -p "$home"
  export HOME="$home" GH_LOG="$home/gh.log"; : > "$GH_LOG"
  export FAKE_REPO=fedora-dev
  # THE CALLER'S CWD IS A REAL GIT REPO — a stand-in for the SHARED CLONE dev-loop drives this from.
  # dev-author is always invoked from SOMEWHERE, and if its `cd` into the isolated worktree ever stops
  # guarding the model run, the model lands HERE and commits (it is told to implement and commit). So
  # the caller's cwd is a repo whose HEAD is asserted UNMOVED after every row — the shared-clone leak
  # (policy/CLAUDE.md, 2026-06-28) becomes a test failure instead of a silent corruption. It is not
  # hypothetical: running this suite against the pre-fix script from the repo root committed the tester's
  # OWN working tree onto its OWN branch. A test must never be able to do that to the tree it validates.
  local caller="$home/caller-clone"; mkdir -p "$caller"
  git init -q "$caller"; git -C "$caller" config user.email t@t; git -C "$caller" config user.name t
  echo seed > "$caller/seed"; git -C "$caller" add -A; git -C "$caller" commit -qm seed
  local caller_head; caller_head="$(git -C "$caller" rev-parse HEAD)"
  # shellcheck disable=SC2086
  ( cd "$caller" && env $envs PATH="$BIN:$PATH" AUTHOR_CLAUDE="claude -p" \
      FRESH_TREE="$BIN/fresh-tree.sh" VALIDATE="$BIN/validate.sh" \
      bash "$AUTHOR" fedora-dev 42 ) >/dev/null 2>&1 || true
  local ok=1
  [ "$(git -C "$caller" rev-parse HEAD)" = "$caller_head" ] \
    || { ok=0; echo "  FAIL $desc: the author COMMITTED IN THE CALLER'S CWD — the shared-clone leak; its isolation cd is not a guard"; }
  case "$expect" in
    PRCREATE)     grep -q '^PRCREATE'    "$GH_LOG" || { ok=0; echo "  FAIL $desc: no PR created"; }
                  grep -q '^PRREADY'     "$GH_LOG" || { ok=0; echo "  FAIL $desc: PR not marked ready"; }
                  grep -q 'live-validate' "$GH_LOG" || { ok=0; echo "  FAIL $desc: not labelled live-validate"; }
                  grep -q '^GITPUSH'     "$GH_LOG" || { ok=0; echo "  FAIL $desc: no push"; }
                  grep -q '^VALIDATE'    "$GH_LOG" || { ok=0; echo "  FAIL $desc: in-box validate not run"; }
                  # R5 audit loop: EXACTLY ONE issue comment — the shipped confirmation carrying the PR URL.
                  grep -q '^ISSUECOMMENT.*dev-author → shipped:.*pull/999' "$GH_LOG" \
                                                          || { ok=0; echo "  FAIL $desc: no shipped confirmation (with PR URL) on the issue"; }
                  [ "$(grep -c '^ISSUECOMMENT' "$GH_LOG")" -eq 1 ] \
                                                          || { ok=0; echo "  FAIL $desc: expected exactly one issue comment (the shipped confirmation)"; }
                  # #155 TRANSPORT: the prompt reaches the model ON STDIN, and NOTHING but the flags
                  # rides argv — a single argv arg is capped at MAX_ARG_STRLEN (131072 bytes) and this
                  # prompt carries an unbounded issue body, so the argv form is a latent E2BIG (the
                  # exec fails, the author never runs). Restore it and BOTH of these rows fail.
                  grep -q '^PROMPT .*AUTHOR_DONE' "$GH_LOG" \
                                                          || { ok=0; echo "  FAIL $desc: the author prompt did not reach the model on STDIN"; }
                  grep -qx 'CLAUDEARGV -p' "$GH_LOG" \
                                                          || { ok=0; echo "  FAIL $desc: the prompt rode ARGV — E2BIG past 128 KiB (#155)"; } ;;
    ISSUECOMMENT) grep -q '^ISSUECOMMENT' "$GH_LOG" || { ok=0; echo "  FAIL $desc: no BLOCKED comment on issue"; }
                  grep -q '^PRCREATE'    "$GH_LOG" && { ok=0; echo "  FAIL $desc: opened a PR when it should have blocked"; }
                  # a not-DONE outcome must NEVER push a branch — the reviewer's headline assertion.
                  grep -q '^GITPUSH'     "$GH_LOG" && { ok=0; echo "  FAIL $desc: pushed a branch on a not-DONE outcome"; }
                  # the shipped confirmation belongs ONLY to a successful hand-off — never these paths.
                  grep -q 'dev-author → shipped' "$GH_LOG" && { ok=0; echo "  FAIL $desc: shipped confirmation on a not-shipped outcome"; } ;;
    NONE)         grep -q '^PRCREATE'    "$GH_LOG" && { ok=0; echo "  FAIL $desc: opened a PR when it should have skipped"; } ;;
  esac
  [ -n "$extra" ] && { grep -q "$extra" "$GH_LOG" || { ok=0; echo "  FAIL $desc: missing [$extra]"; }; }
  [ -n "$absent" ] && { grep -q "$absent" "$GH_LOG" && { ok=0; echo "  FAIL $desc: log wrongly contains [$absent]"; }; }
  if [ "$ok" = 1 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$desc"; else fail=$((fail+1)); fi
  return 0
}

echo "== happy path: author DONE + in-box GREEN → push + draft PR + ready + live-validate label =="
run "authored feature reaches the pipeline" "FAKE_AUTHOR=done FAKE_VALIDATE=GREEN" PRCREATE draft

echo "== BLOCKED: author cannot implement → dev-task question on the ISSUE, NO PR =="
run "explicit AUTHOR_BLOCKED surfaces" "FAKE_AUTHOR=blocked" ISSUECOMMENT 'needs a decision'

echo "== no-progress: author commits nothing, no sentinel → surfaced, NO PR =="
run "no-commit is surfaced not shipped" "FAKE_AUTHOR=noop" ISSUECOMMENT

echo "== in-box RED: author commits but validate.sh fails → surfaced, NO PR, NO push =="
run "in-box RED blocks the push" "FAKE_AUTHOR=done FAKE_VALIDATE=RED" ISSUECOMMENT
echo "== guard: a closed issue is never authored =="
run "closed issue → skip" "FAKE_STATE=CLOSED FAKE_AUTHOR=done" NONE
echo "== guard: a non-backlog-labelled issue is never authored =="
run "non-backlog issue → skip" "FAKE_LABELS=bug FAKE_AUTHOR=done" NONE
echo "== guard: an issue with an existing open PR is never re-authored =="
run "existing PR → skip" "FAKE_PRLIST=17 FAKE_AUTHOR=done" NONE

# ---------------------------------------------------------------------------------------------------
# THE `cd` INTO THE WORKTREE IS A FAIL-CLOSED GUARD. dev-author already refuses a fresh-tree that FAILS
# (rc≠0 / empty path), so the only isolation failure that can reach the model is a worktree that exists
# but cannot be ENTERED — and there the isolation is the `cd` alone. `cd "$WT" && set +o pipefail;
# <pipeline>` does NOT hold it: `&&` binds to `set` alone and the `;` ends the list, so the model runs
# ANYWAY in the CALLER'S cwd — under dev-loop, the SHARED CLONE — told to implement and `git commit`.
# That is the 2026-06-28 cross-branch-leak hazard policy/CLAUDE.md names by date. Drop the brace group
# from bin/dev-author.sh and this row fails: the model runs (a PROMPT line appears) and, worse, it
# commits in whatever tree the driver happened to be standing in.
echo "== worktree unenterable: the cd is FAIL-CLOSED — NO model runs outside its own worktree =="
UNENT="$ROOT/unenterable-probe"; mkdir -p "$UNENT"; chmod 000 "$UNENT"
if ( cd "$UNENT" ) 2>/dev/null; then   # as root, chmod cannot make a dir unenterable — the row cannot bite
  echo "  SKIP running as root — a chmod-000 dir is still enterable"
else
  run "an unenterable worktree runs NO model, opens NO PR, and says the author never ran" \
      "FAKE_WT=unenterable FAKE_AUTHOR=done" ISSUECOMMENT 'never run' '^PROMPT'
fi
chmod 755 "$UNENT"

echo
echo "dev-author-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
