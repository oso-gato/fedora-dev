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

# stub repo-scope: list → just fedora-dev; check → always in scope.
cat > "$BIN/repo-scope.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in list) echo fedora-dev;; check) exit 0;; *) exit 0;; esac
EOF
chmod +x "$BIN/repo-scope.sh"

# stub gh — answers each subcommand from scenario env. ONE merged PR #500 → Backlog-ticket: #400.
#   HAS_TRAILER(1) · HOST_GREEN(1|0) · PUB(success|pending|failure|'') · FILES(bin/x.sh|Containerfile) ·
#   ISSUE_STATE(OPEN|CLOSED) · ANCHOR(0|1 → a prior 'reconcile → closed:' comment on the PR).
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
  "run list")   echo "${PUB:-success}";;
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

echo "== FULL proof chain (merged+green+published+live/CLONE) → CLOSE =="
run "$SCRIPT" HOST_GREEN=1 PUB=success FILES=bin/x.sh ISSUE_STATE=OPEN ANCESTOR=1
closed && ok "all links hold → issue #400 CLOSED with proof" || no "did not close a fully-proven issue"

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
