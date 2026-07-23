#!/usr/bin/env bash
# ship-gate.test.sh — drives the REAL bin/ship-gate.sh with a stubbed `claude` (the reviewer), a stubbed
# `gh` (the bus), and a throwaway git fixture clone. No network / no model. bash ship-gate.test.sh → 0.
#
# Proves: the shell-owned verdict cannot be forged (extractor selftest); a RETURN/PASS reviewer reply
# yields the canonical `SHIP GATE: VERDICT <v> aggregate <sha>` line; fail-closed when the reviewer
# cannot run or emits no verdict; SoD refuses a self-judge; and an already-reviewed aggregate no-ops
# WITHOUT re-running the model (idempotency).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/bin/ship-gate.sh"
[ -f "$SUT" ] || { echo "FATAL: bin/ship-gate.sh not found"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
pass=0; fail=0
ck(){ [ "$2" = 1 ] && { pass=$((pass+1)); printf '  ok   %s\n' "$1"; } || { fail=$((fail+1)); printf '  FAIL %s: %s\n' "$1" "$3"; }; }

# --- fixture clone: a real git repo with the confirmed-spec docs + a deploy-contract file ------------
CLONE="$ROOT/clone"; mkdir -p "$CLONE"
git -C "$CLONE" init -q
git -C "$CLONE" config user.email t@t; git -C "$CLONE" config user.name t
for d in 00-OBJECTIVES 00-REQUIREMENTS 00-BUILDPRINCIPLE 00-GOVERNANCE; do printf '# %s\ndummy\n' "$d" > "$CLONE/$d.md"; done
printf 'FROM scratch\n' > "$CLONE/Containerfile"
git -C "$CLONE" add -A; git -C "$CLONE" commit -qm init
SHA="$(git -C "$CLONE" rev-parse HEAD)"

# --- stub gh: branches/main → SHA; commits/<sha>/comments → $GH_COMMENTS_F; issue list → ledger; POST record
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"branches/main"*)          printf '%s' "$SHA" ;;                       # -q .commit.sha equiv
  *"commits/"*"/comments"*"POST"*|*"--method POST"*"/comments"*) echo "posted" >> "\$SHIPTEST_POSTS" ;;
  *"commits/"*"/comments"*)   cat "\${GH_COMMENTS_F:-/dev/null}" 2>/dev/null ;;
  *"issue list"*)             printf '#1 [CLOSED] a feature  https://x/1\n' ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/repo-scope.sh"; chmod +x "$BIN/repo-scope.sh"   # in-scope

# --- stub claude (the reviewer): emits $REVIEW, exits $RCODE; touches a sentinel so we can prove it RAN
mkreviewer(){ # <reply> <rc>
  { printf '#!/usr/bin/env bash\ntouch "%s"\n' "$ROOT/reviewer.ran"
    printf 'cat >/dev/null\n'                        # drain the prompt on stdin (avoid SIGPIPE)
    printf 'printf %s %q\n' '%s\\n' "$1"
    printf 'exit %s\n' "$2"; } > "$BIN/claude"; chmod +x "$BIN/claude"
}
run(){ # extra env… — drives the REAL ship-gate dry-run; captures OUT + RC
  rm -f "$ROOT/reviewer.ran"; : > "$ROOT/posts.log"
  OUT="$(env PATH="$BIN:$PATH" REPO_SCOPE="$BIN/repo-scope.sh" REPO_CLONE="$CLONE" \
      SHIP_CLAUDE="claude" SHIPTEST_POSTS="$ROOT/posts.log" FITNESS_ENV_FILE=/nonexistent "$@" \
      bash "$SUT" e2e-alpha --clone "$CLONE" 2>&1)"; RC=$?
}
line1(){ printf '%s\n' "$OUT" | grep -m1 '^SHIP GATE: VERDICT'; }

echo "== extractor selftest (the shell-owned, unforgeable verdict) =="
bash "$SUT" --selftest >/dev/null 2>&1; ck "ship-gate --selftest exits 0" "$([ $? = 0 ] && echo 1)" "extractor selftest failed"

echo "== a RETURN reply yields the canonical RETURN verdict bound to the aggregate =="
mkreviewer 'SHIP_VERDICT: RETURN' 0
run SHIPGATE_LOGIN=oso-gato-fitness-claudebox
ck "dry-run rc 0"                    "$([ "$RC" = 0 ] && echo 1)" "rc=$RC"
ck "line 1 = SHIP GATE VERDICT RETURN aggregate <sha>" "$([ "$(line1)" = "SHIP GATE: VERDICT RETURN aggregate $SHA" ] && echo 1)" "got [$(line1)]"

echo "== a PASS reply yields the canonical PASS verdict =="
mkreviewer 'thinking...
SHIP_VERDICT: PASS' 0
run SHIPGATE_LOGIN=oso-gato-fitness-claudebox
ck "line 1 = SHIP GATE VERDICT PASS aggregate <sha>" "$([ "$(line1)" = "SHIP GATE: VERDICT PASS aggregate $SHA" ] && echo 1)" "got [$(line1)]"

echo "== fail-closed: reviewer cannot run (rc!=0) → exit 3, NOTHING composed =="
mkreviewer 'SHIP_VERDICT: PASS' 3
run SHIPGATE_LOGIN=oso-gato-fitness-claudebox
ck "reviewer-infra-failure exits 3"       "$([ "$RC" = 3 ] && echo 1)" "rc=$RC"
ck "no SHIP GATE line composed on infra failure" "$([ -z "$(line1)" ] && echo 1)" "leaked [$(line1)]"

echo "== fail-closed: reviewer emits garbage (no verdict) → exit 3 =="
mkreviewer 'I could not decide, sorry.' 0
run SHIPGATE_LOGIN=oso-gato-fitness-claudebox
ck "no-verdict exits 3"                    "$([ "$RC" = 3 ] && echo 1)" "rc=$RC"

echo "== SoD: reviewer identity == author → refuse (rc 1) =="
mkreviewer 'SHIP_VERDICT: PASS' 0
run SHIPGATE_LOGIN=oso-gato-nox-claudebox DEV_LOGIN=oso-gato-nox-claudebox
ck "self-judge refused rc 1"               "$([ "$RC" = 1 ] && echo 1)" "rc=$RC"

echo "== idempotency: an existing PASS on THIS aggregate → no-op, model NOT re-run =="
printf 'SHIP GATE: VERDICT PASS aggregate %s\n' "$SHA" > "$ROOT/existing.txt"
mkreviewer 'SHIP_VERDICT: RETURN' 0     # would flip it if it ran — prove it does NOT run
run SHIPGATE_LOGIN=oso-gato-fitness-claudebox GH_COMMENTS_F="$ROOT/existing.txt"
ck "idempotent no-op exits 0"              "$([ "$RC" = 0 ] && echo 1)" "rc=$RC"
ck "the reviewer model was NOT re-run"     "$([ ! -f "$ROOT/reviewer.ran" ] && echo 1)" "the model re-ran on an already-reviewed aggregate"

echo
echo "ship-gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
