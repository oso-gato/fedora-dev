#!/usr/bin/env bash
# dev-author.test.sh — MOCK end-to-end dry-run of bin/dev-author.sh with ZERO GitHub / network / model.
#
# The author's load-bearing safety is its CONTROL FLOW: guard → isolate → bounded author → in-box gate
# → hand off (push + draft PR + ready + label), with a BLOCKED path that surfaces a dev-task question and
# opens NO PR. We exercise all of it by STUBBING gh, git, claude, fresh-tree.sh, and validate.sh on PATH
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
    # honor --json state / -q .title / -q .body; default returns the JSON blob
    case "$*" in
      *"-q .title"*) printf '%s' "${FAKE_TITLE:-Add a thing}";;
      *"-q .body"*)  printf '%s' "${FAKE_BODY:-Do the thing.}";;
      *)             printf '{"state":"%s","title":"%s","body":"%s","labels":[]}' "${FAKE_STATE:-OPEN}" "${FAKE_TITLE:-Add a thing}" "b";;
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
cat > "$BIN/fresh-tree.sh" <<EOF
#!/usr/bin/env bash
wt="$ROOT/wt-\$RANDOM"; mkdir -p "\$wt"
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
# args: -p "<prompt>"   (we ignore the prompt; behavior is env-driven)
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
run(){ # <desc> <env-assignments> <expect: PRCREATE|ISSUECOMMENT|NONE> <extra-grep-or-"">
  local desc="$1" envs="$2" expect="$3" extra="${4:-}"
  local home="$ROOT/home-$RANDOM"; mkdir -p "$home"
  export HOME="$home" GH_LOG="$home/gh.log"; : > "$GH_LOG"
  export FAKE_REPO=fedora-dev
  # shellcheck disable=SC2086
  env $envs PATH="$BIN:$PATH" AUTHOR_CLAUDE="claude -p" \
      FRESH_TREE="$BIN/fresh-tree.sh" VALIDATE="$BIN/validate.sh" \
      bash "$AUTHOR" fedora-dev 42 >/dev/null 2>&1 || true
  local ok=1 log; log="$(tr '\n' '|' < "$GH_LOG")"
  case "$expect" in
    PRCREATE)     grep -q '^PRCREATE'    "$GH_LOG" || { ok=0; echo "  FAIL $desc: no PR created"; }
                  grep -q '^PRREADY'     "$GH_LOG" || { ok=0; echo "  FAIL $desc: PR not marked ready"; }
                  grep -q 'live-validate' "$GH_LOG" || { ok=0; echo "  FAIL $desc: not labelled live-validate"; }
                  grep -q '^GITPUSH'     "$GH_LOG" || { ok=0; echo "  FAIL $desc: no push"; }
                  grep -q '^VALIDATE'    "$GH_LOG" || { ok=0; echo "  FAIL $desc: in-box validate not run"; }
                  grep -q '^ISSUECOMMENT' "$GH_LOG" && { ok=0; echo "  FAIL $desc: unexpected BLOCKED comment"; } ;;
    ISSUECOMMENT) grep -q '^ISSUECOMMENT' "$GH_LOG" || { ok=0; echo "  FAIL $desc: no BLOCKED comment on issue"; }
                  grep -q '^PRCREATE'    "$GH_LOG" && { ok=0; echo "  FAIL $desc: opened a PR when it should have blocked"; } ;;
    NONE)         grep -q '^PRCREATE'    "$GH_LOG" && { ok=0; echo "  FAIL $desc: opened a PR when it should have skipped"; } ;;
  esac
  [ -n "$extra" ] && { grep -q "$extra" "$GH_LOG" || { ok=0; echo "  FAIL $desc: missing [$extra]"; }; }
  if [ "$ok" = 1 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$desc"; else fail=$((fail+1)); fi
}

echo "== happy path: author DONE + in-box GREEN → push + draft PR + ready + live-validate label =="
run "authored feature reaches the pipeline" "FAKE_AUTHOR=done FAKE_VALIDATE=GREEN" PRCREATE draft

echo "== BLOCKED: author cannot implement → dev-task question on the ISSUE, NO PR =="
run "explicit AUTHOR_BLOCKED surfaces" "FAKE_AUTHOR=blocked" ISSUECOMMENT 'needs a decision'

echo "== no-progress: author commits nothing, no sentinel → surfaced, NO PR =="
run "no-commit is surfaced not shipped" "FAKE_AUTHOR=noop" ISSUECOMMENT

echo "== in-box RED: author commits but validate.sh fails → surfaced, NO PR, NO push =="
run "in-box RED blocks the push" "FAKE_AUTHOR=done FAKE_VALIDATE=RED" ISSUECOMMENT
# and prove it did NOT push in that case:
echo "== guard: a closed issue is never authored =="
run "closed issue → skip" "FAKE_STATE=CLOSED FAKE_AUTHOR=done" NONE
echo "== guard: an issue with an existing open PR is never re-authored =="
run "existing PR → skip" "FAKE_PRLIST=17 FAKE_AUTHOR=done" NONE

echo
echo "dev-author-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
