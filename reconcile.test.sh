#!/usr/bin/env bash
# reconcile.test.sh — proves bin/reconcile.sh's PROOF-GATED CLOSURE (task #19): a backlog issue is closed
# ONLY when the WHOLE proof chain holds (merged + host GREEN + CI published + live read-back), and NEVER
# on merge alone. Drives the REAL `reconcile.sh --once` against a scenario-driven stub `gh` + stub `git`
# (the live-clone ancestor check) + stub `repo-scope`. Each scenario flips ONE link and asserts close vs.
# no-close. MUTATION RUN IN-SUITE: neutralize close_decision to always CLOSE → the CI-PENDING scenario
# then wrongly closes (proving the proof-gate is what withholds closure, not the plumbing). No real
# GitHub/network/model.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/bin/reconcile.sh"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
CLOSED="$ROOT/closed.log"

# stub repo-scope: list → $SCOPE_REPO (fedora-dev unless a row needs another repo, e.g. to reach the
# live-read-back-N/A branch, which is repo-slug-routed); check → always in scope.
cat > "$BIN/repo-scope.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in list) echo "${SCOPE_REPO:-fedora-dev}";; check) exit 0;; *) exit 0;; esac
EOF
chmod +x "$BIN/repo-scope.sh"

# stub gh — answers each subcommand from scenario env. ONE merged PR #500 → Backlog-ticket: #400.
#   HAS_TRAILER(1) · HOST_GREEN(1|0) · PUB(success|pending|failure|'') · FILES(bin/x.sh|Containerfile) ·
#   ISSUE_STATE(OPEN|CLOSED) · ANCHOR(0|1 → a prior 'reconcile → closed:' comment on the PR) ·
#   TREE_PATHS(the git-trees listing publish_applicable_p reads; omit build.yml → the publish link is N/A) ·
#   TREE_TRUNCATED(false|true).
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
CLOSED="$CLOSED"
EOF
cat >> "$BIN/gh" <<'EOF'
sub="${1:-} ${2:-}"
case "$sub" in
  "pr list")
    body="Autonomously authored.\n"
    [ "${HAS_TRAILER:-1}" = 1 ] && body="${body}Backlog-ticket: #400\n"
    printf '500\tdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\t2026-07-18T12:00:00Z\t%s\n' "$body"
    ;;
  "pr view")
    case "$*" in
      *"--json comments"*)
        [ "${ANCHOR:-0}" = 1 ] && echo "reconcile → closed: prior"
        [ "${HOST_GREEN:-1}" = 1 ] && echo "Host live-gate (Gate B): VERDICT GREEN — fedora-dev @ deadbeef"
        ;;
      *"--json files"*) printf '%s\n' "${FILES:-bin/x.sh}";;
    esac ;;
  "issue view") echo "${ISSUE_STATE:-OPEN}";;
  # `-` (not `:-`): an explicitly EMPTY PUB is "no run for this commit", which is what publish_applicable_p
  # then has to disambiguate. `:-` would fold that scenario back into a successful run.
  "run list")   echo "${PUB-success}";;
  "api "*)
    # git-trees read for publish_applicable_p: line 1 is .truncated, then one path per line. `-` (not `:-`)
    # so an explicitly EMPTY TREE_PATHS means "a tree with no paths", not "the default tree".
    echo "${TREE_TRUNCATED:-false}"
    printf '%s\n' ${TREE_PATHS-.github/workflows/build.yml bin/x.sh}
    ;;
  "issue close") echo "CLOSE 400 :: $*" >> "$CLOSED";;
  "pr comment")  : ;;   # PR stamp — recorded implicitly by the close row
esac
exit 0
EOF
chmod +x "$BIN/gh"

# stub git — merge-base --is-ancestor returns per ANCESTOR (the live-clone read-back). Anything else ok.
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"merge-base --is-ancestor"*) [ "${ANCESTOR:-1}" = 1 ] && exit 0 || exit 1;;
  *) exit 0;;
esac
EOF
chmod +x "$BIN/git"

# a real .git dir so reconcile.sh's `[ -d "$DEV_CLONE/.git" ]` passes; the stub git answers the ancestor Q.
mkdir -p "$ROOT/clone/.git"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n       closed=[%s]\n' "$1" "$(tr '\n' '|' <"$CLOSED")"; }
run(){ # <script> [env=val ...]
  local sc="$1"; shift
  : > "$CLOSED"
  env PATH="$BIN:$PATH" REPO_SCOPE="$BIN/repo-scope.sh" DEV_CLONE="$ROOT/clone" ORG=oso-gato \
      RECONCILE_MAX_AGE=99999999999 "$@" bash "$sc" --once >"$ROOT/out" 2>&1
}
closed(){ grep -q '^CLOSE 400' "$CLOSED"; }
says(){   grep -qF -- "$1" "$CLOSED"; }   # what the POSTED closing comment actually asserts

echo "== FULL proof chain (merged+green+published+live/CLONE) → CLOSE =="
run "$SCRIPT" HOST_GREEN=1 PUB=success FILES=bin/x.sh ISSUE_STATE=OPEN ANCESTOR=1
closed && ok "all links hold → issue #400 CLOSED with proof" || no "did not close a fully-proven issue"
# The links that WERE taken must still be claimed — the honesty fix must not blanket-N/A a real proof.
says 'CI `build.yml` published' && ok "taken CI link is reported as published" || no "a taken CI link stopped being claimed"
says 'live read-back OK (CLONE class)' && ok "taken live link is reported OK" || no "a taken live link stopped being claimed"

echo "== CI PENDING → NOT closed (the core: never close before the artifact exists) =="
run "$SCRIPT" HOST_GREEN=1 PUB=in_progress FILES=bin/x.sh ISSUE_STATE=OPEN ANCESTOR=1
closed && no "closed on a PENDING publish (proof-gate broken)" || ok "CI pending → not closed"

echo "== no HOST GREEN → NOT closed =="
run "$SCRIPT" HOST_GREEN=0 PUB=success FILES=bin/x.sh ISSUE_STATE=OPEN ANCESTOR=1
closed && no "closed without a host GREEN verdict" || ok "no host green → not closed"

echo "== IMAGE-baked change (live read-back is the disclosed follow-up) → NOT closed =="
run "$SCRIPT" HOST_GREEN=1 PUB=success FILES=Containerfile ISSUE_STATE=OPEN ANCESTOR=1
closed && no "closed an image-baked change without a host-deploy read-back" || ok "image-baked → WAIT, not closed"

echo "== live read-back FALSE (box has not run the merge yet) → NOT closed =="
run "$SCRIPT" HOST_GREEN=1 PUB=success FILES=bin/x.sh ISSUE_STATE=OPEN ANCESTOR=0
closed && no "closed before the merge is live in the running clone" || ok "not-yet-live → not closed"

echo "== issue already CLOSED → no double-close =="
run "$SCRIPT" HOST_GREEN=1 PUB=success FILES=bin/x.sh ISSUE_STATE=CLOSED ANCESTOR=1
closed && no "acted on an already-closed issue" || ok "already-closed → no-op"

echo "== dedup anchor present → skip =="
run "$SCRIPT" HOST_GREEN=1 PUB=success FILES=bin/x.sh ISSUE_STATE=OPEN ANCESTOR=1 ANCHOR=1
closed && no "re-closed despite the reconcile anchor" || ok "anchor present → skipped"

echo "== no Backlog-ticket trailer → ignored =="
run "$SCRIPT" HAS_TRAILER=0 HOST_GREEN=1 PUB=success FILES=bin/x.sh ISSUE_STATE=OPEN ANCESTOR=1
closed && no "closed a PR that claims no backlog ticket" || ok "no trailer → ignored"

echo "== N/A PUBLISH → closes, and the comment says the link was N/A (never 'published') =="
# No run for this commit AND no build.yml in the tree at it: nothing will ever publish it. The close is
# correct; asserting "CI published" on it would be a false proof in this actuator's permanent audit record
# (and its dedup anchor, so never rewritten). Fires on every close the N/A semantics unblock.
run "$SCRIPT" HOST_GREEN=1 PUB='' TREE_PATHS='bin/x.sh README.md' FILES=bin/x.sh ISSUE_STATE=OPEN ANCESTOR=1
closed && ok "publish N/A → still closed (the link genuinely cannot be taken)" || no "N/A publish did not close"
says 'CI: N/A' && ok "comment reports the publish link as N/A" || no "comment does not report the N/A publish link"
says 'published' && no "comment claims 'published' on a commit that publishes nothing" || ok "comment never claims published"

echo "== N/A LIVE READ-BACK → closes, and the comment says the link was N/A (never 'read-back OK') =="
# Any repo but fedora-dev: the dev box holds no readable deployed checkout, so no read-back is takeable.
run "$SCRIPT" SCOPE_REPO=e2e-beta HOST_GREEN=1 PUB=success FILES=bin/x.sh ISSUE_STATE=OPEN ANCESTOR=1
closed && ok "live N/A → still closed" || no "N/A live read-back did not close"
says 'live read-back: N/A' && ok "comment reports the live link as N/A" || no "comment does not report the N/A live link"
says 'read-back OK' && no "comment claims 'read-back OK' for a read-back never taken" || ok "comment never claims read-back OK"

echo "== MUTATION: blanket proof text restored → the N/A-publish comment wrongly claims 'published' =="
MUTP="$ROOT/reconcile-blanket.sh"
# NB no backticks in the injected text: it lands inside double quotes in the mutant, where they would be
# command substitution rather than the markdown the real comment carries.
sed 's/^proof_summary(){/proof_summary(){ echo "host live-gate GREEN, CI published, live read-back OK"; return;/' "$SCRIPT" > "$MUTP"
if ! grep -q 'proof_summary(){ echo' "$MUTP"; then
  no "blanket mutation VACUOUS (sed did not change the copy)"
else
  run "$MUTP" HOST_GREEN=1 PUB='' TREE_PATHS='bin/x.sh README.md' FILES=bin/x.sh ISSUE_STATE=OPEN ANCESTOR=1
  says 'published' && ok "mutant: N/A close claims 'published' ⇒ the honest-report rows discriminate" || no "mutant did not restore the false claim (the N/A rows would not bite)"
fi

echo "== MUTATION: close_decision always CLOSE → the CI-PENDING scenario must then WRONGLY close =="
MUT="$ROOT/reconcile-mut.sh"
sed 's/^close_decision(){/close_decision(){ echo CLOSE; return;/' "$SCRIPT" > "$MUT"
if ! grep -q 'close_decision(){ echo CLOSE; return;' "$MUT"; then
  no "mutation VACUOUS (sed did not change the copy)"
else
  run "$MUT" HOST_GREEN=1 PUB=in_progress FILES=bin/x.sh ISSUE_STATE=OPEN ANCESTOR=1
  closed && ok "mutant: pending-CI issue wrongly closed ⇒ the real CI-PENDING row discriminates" || no "mutant did not close (the proof-gate row would not bite)"
fi

echo; echo "reconcile.test: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
