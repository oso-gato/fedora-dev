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

# --- fixture: the SHIPPED AGGREGATE is read from the BUS at a pinned sha, never from a working tree ---
# (ship-gate used to require $HOME/<repo> to be a git clone, which made it unreachable for every repo the
# apparatus develops but does not keep checked out. There is no fixture clone any more, by design.)
SHA=0123456789abcdef0123456789abcdef01234567
MANIFEST_F="$ROOT/manifest.txt"
printf '00-OBJECTIVES.md\n00-REQUIREMENTS.md\n00-BUILDPRINCIPLE.md\n00-GOVERNANCE.md\nContainerfile\n' > "$MANIFEST_F"
: > "$ROOT/empty.txt"

# --- stub gh (the bus): tree → manifest; contents → base64 blob; comments → $GH_COMMENTS_F; POST record.
# The two `issue list` shapes are distinguished by the fields asked for: `state,url` is the shipped-feature
# LEDGER, `state,body` is the SPEC fallback — so a test can starve the spec without starving the ledger.
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"branches/main"*)          printf '%s' "$SHA" ;;                       # -q .commit.sha equiv
  *"git/trees/"*)             cat "\${SHIPTEST_MANIFEST:-$MANIFEST_F}" 2>/dev/null ;;
  *"contents/"*)              printf 'confirmed spec text\n' | base64 -w0 ;;
  *"commits/"*"/comments"*"POST"*|*"--method POST"*"/comments"*) echo "posted" >> "\$SHIPTEST_POSTS" ;;
  *"commits/"*"/comments"*)   cat "\${GH_COMMENTS_F:-/dev/null}" 2>/dev/null ;;
  *"OBJECTIVE in:title"*)     cat "\${SHIPTEST_OBJECTIVE:-/dev/null}" 2>/dev/null ;;
  *"state,body"*)             cat "\${SHIPTEST_BACKLOG_SPEC:-/dev/null}" 2>/dev/null ;;
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
  OUT="$(env PATH="$BIN:$PATH" REPO_SCOPE="$BIN/repo-scope.sh" \
      SHIP_CLAUDE="claude" SHIPTEST_POSTS="$ROOT/posts.log" FITNESS_ENV_FILE=/nonexistent "$@" \
      bash "$SUT" e2e-alpha 2>&1)"; RC=$?
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

echo "== no local clone is needed: the aggregate is read from the bus =="
# The whole suite above already proves this (no clone exists anywhere in this fixture), but state it
# explicitly: ~/e2e-alpha must NOT be required, because it is exactly what made the gate unreachable.
mkreviewer 'SHIP_VERDICT: PASS' 0
run SHIPGATE_LOGIN=oso-gato-fitness-claudebox HOME="$ROOT/nonexistent-home"
ck "runs with no clone on disk"      "$([ "$RC" = 0 ] && echo 1)" "rc=$RC — still clone-dependent"
ck "the reviewer actually ran"       "$([ -f "$ROOT/reviewer.ran" ] && echo 1)" "reviewer never ran"

echo "== FAIL-CLOSED: an EMPTY confirmed spec REFUSES the review (a gate that cannot fail is not a gate) =="
# A repo with no Trinity docs, no objective issue and no backlog bodies. Previously the reviewer was
# handed four empty headings and asked to grade conformance against nothing — it could not RETURN for a
# spec violation, so it would rubber-stamp anything.
mkreviewer 'SHIP_VERDICT: PASS' 0
run SHIPGATE_LOGIN=oso-gato-fitness-claudebox SHIPTEST_MANIFEST="$ROOT/empty.txt"
# Assert the REASON, not just the rc: the pre-fix gate also exited 1 here, but for the unrelated missing
# -clone precondition. A test that passes against the pre-fix code proves nothing.
ck "empty spec refuses (rc 1)"       "$([ "$RC" = 1 ] && echo 1)" "rc=$RC — reviewed against an empty spec"
ck "…and refuses FOR THAT REASON"    "$(printf '%s' "$OUT" | grep -qi 'no confirmed spec' && echo 1)" "died for another reason: $(printf '%s' "$OUT" | tail -1)"
ck "the model was NOT run"           "$([ ! -f "$ROOT/reviewer.ran" ] && echo 1)" "the model judged an empty spec"
ck "no verdict composed"             "$([ -z "$(line1)" ] && echo 1)" "leaked [$(line1)]"

echo "== a repo with NO Trinity docs sources its spec from the objective issue + backlog =="
# This is the e2e-beta shape: the confirmed spec lives on the bus, not in the tree.
printf '===== OBJECTIVE ISSUE #1: a minimal status-page image =====\nserve 200 on /\n' > "$ROOT/objective.txt"
mkreviewer 'SHIP_VERDICT: PASS' 0
run SHIPGATE_LOGIN=oso-gato-fitness-claudebox SHIPTEST_MANIFEST="$ROOT/empty.txt" \
    SHIPTEST_OBJECTIVE="$ROOT/objective.txt"
ck "objective-issue spec is accepted" "$([ "$RC" = 0 ] && echo 1)" "rc=$RC"
ck "the reviewer ran against it"      "$([ -f "$ROOT/reviewer.ran" ] && echo 1)" "reviewer never ran"
ck "verdict bound to the aggregate"   "$([ "$(line1)" = "SHIP GATE: VERDICT PASS aggregate $SHA" ] && echo 1)" "got [$(line1)]"

echo
echo "ship-gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
