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
#   ISSUE_STATE(OPEN|CLOSED) · ANCHOR(0|1 → a prior 'reconcile → closed:' comment on the ISSUE — the
#     per-ref dedup anchor; a PR-level mark cannot say WHICH of N refs it attests to) ·
#   ISSUE_LABELS(default 'backlog'; the gate requires it so a stray number cannot close a PR) ·
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
    # $REFS = the tickets this PR declares (default one, the pre-existing single-ref shape).
    if [ "${HAS_TRAILER:-1}" = 1 ]; then
      for _n in ${REFS-400}; do body="${body}Backlog-ticket: #${_n}\n"; done
    fi
    printf '500\tdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\t2026-07-18T12:00:00Z\t%s\n' "$body"
    ;;
  "pr view")
    case "$*" in
      *"--json comments"*)
        [ "${HOST_GREEN:-1}" = 1 ] && echo "Host live-gate (Gate B): VERDICT GREEN — fedora-dev @ deadbeef"
        ;;
      *"--json files"*) printf '%s\n' "${FILES:-bin/x.sh}";;
    esac ;;
  # issue_facts: state \t prior-close \t labels. The ANCHOR moved from the PR to the ISSUE, so the
  # prior-close flag is now a property of the issue being closed, not of the PR that closed it.
  "issue view") printf '%s\t%s\t%s\n' "${ISSUE_STATE:-OPEN}" "${ANCHOR:-0}" "${ISSUE_LABELS-backlog}";;
  # `-` (not `:-`): an explicitly EMPTY PUB is "no run for this commit", which is what publish_applicable_p
  # then has to disambiguate. `:-` would fold that scenario back into a successful run.
  "run list")   echo "${PUB-success}";;
  "api "*)
    # git-trees read for publish_applicable_p: line 1 is .truncated, then one path per line. `-` (not `:-`)
    # so an explicitly EMPTY TREE_PATHS means "a tree with no paths", not "the default tree".
    echo "${TREE_TRUNCATED:-false}"
    printf '%s\n' ${TREE_PATHS-.github/workflows/build.yml bin/x.sh}
    ;;
  # record the ACTUAL issue closed ($3), not a hardcoded one — N refs mean N distinct closes.
  # The close and the proof comment are now SEPARATE calls (close first, so a failed close can
  # never leave an anchor on an open issue). Record both: `closed()` reads the CLOSE lines,
  # `says()` reads the COMMENT body — what the posted proof record actually asserts.
  # FAITHFUL to real gh: `issue close --comment` posts the COMMENT FIRST and then closes. Modelling
  # that ordering is the whole point — it is what leaves an anchor on a still-OPEN issue when the
  # close fails, and a stub that skipped it would let the strand row pass vacuously.
  "issue close")
    case "$*" in *--comment*) echo "COMMENT $3 :: $*" >> "$CLOSED";; esac
    [ "${CLOSE_FAIL:-0}" = 1 ] && exit 1
    echo "CLOSE $3 :: $*" >> "$CLOSED";;
  "issue comment") echo "COMMENT $3 :: $*" >> "$CLOSED";;
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
closed(){ grep -q "^CLOSE ${1:-400} " "$CLOSED"; }
ncloses(){ grep -c '^CLOSE ' "$CLOSED"; }
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

echo "== A DEPLOYED WORKLOAD (fedora-desktop) → NOT closed, however green CI is =="
# THE BLOCKER'S INVERSION, driven through the REAL scan rather than --selftest, because the defect was in
# what the live path CLOSES: fedora-desktop is in bin/host-refresh.sh's WORKLOADS — the apparatus files
# `redeploy fedora-desktop` tickets for it and that signal demonstrably works (`redeploy fedora-dev` #255
# → `host-agent: DONE`) — so an instance exists and the merge is NOT delivered until the host redeploys.
# Keying the carve-out on the fedora-bootstrap SLUG sorted this genuine "not yet" as "never", closing the
# ticket the instant CI published: "merged ≠ live", the exact pattern this actuator exists to kill.
run "$SCRIPT" SCOPE_REPO=fedora-desktop HOST_GREEN=1 PUB=success FILES=bin/x.sh ISSUE_STATE=OPEN ANCESTOR=1
closed && no "closed a deployed workload's ticket before the host redeploy delivered it" || ok "deployed workload → WAIT, not closed"
# …and an IMAGE-baked change to it (the class that MOST needs the redeploy) likewise.
run "$SCRIPT" SCOPE_REPO=fedora-desktop HOST_GREEN=1 PUB=success FILES=Containerfile ISSUE_STATE=OPEN ANCESTOR=1
closed && no "closed an image-baked workload change with no redeploy read-back" || ok "workload image-baked → WAIT, not closed"
# The unblock this PR exists for must SURVIVE the fix: a repo the apparatus only DEVELOPS still closes.
run "$SCRIPT" SCOPE_REPO=e2e-beta HOST_GREEN=1 PUB=success FILES=Containerfile ISSUE_STATE=OPEN ANCESTOR=1
closed && ok "developed-only repo still closes (NA did not become a blanket wait)" || no "the NA unblock regressed into a permanent wait"

echo "== DRIFT GUARD: reconcile's deploy set == host-refresh's WORKLOADS + CONTROL_REPO =="
# One fact, enumerated in two files: the repos the apparatus deploys. host-refresh.sh decides WHERE a
# redeploy/apply ticket is filed; reconcile.sh decides whether a missing read-back is "not yet" or
# "never". They must name the same repos — a workload added to one and not the other silently restores
# this PR's defect for that repo. Read out of BOTH files so the pair cannot drift unnoticed.
rd="$(sed -n "s/^RECONCILE_DEPLOYED_DEFAULT='\(.*\)'.*/\1/p" "$SCRIPT" | head -1)"
hw="$(sed -n 's/^WORKLOADS="${HOST_REFRESH_WORKLOADS-\(.*\)}".*/\1/p' "$HERE/bin/host-refresh.sh" | head -1)"
hc="$(sed -n 's/^CONTROL_REPO="${HOST_REFRESH_CONTROL_REPO-\(.*\)}".*/\1/p' "$HERE/bin/host-refresh.sh" | head -1)"
srt(){ printf '%s\n' $1 | sort | tr '\n' ' '; }
if [ -z "$rd" ] || [ -z "$hw" ] || [ -z "$hc" ]; then
  no "drift guard VACUOUS (read reconcile=[$rd] workloads=[$hw] control=[$hc])"
elif [ "$(srt "$rd")" = "$(srt "$hw $hc")" ]; then
  ok "deploy sets agree ($(srt "$rd"))"
else
  no "deploy sets DRIFTED: reconcile=[$(srt "$rd")] host-refresh=[$(srt "$hw $hc")]"
fi

echo "== MUTATION: fedora-desktop dropped from the deploy set → the workload closes again =="
# The pre-fix defect exactly: a deployed workload missing from the set reads NA and closes on CI alone.
MUTD="$ROOT/reconcile-nodesktop.sh"
sed "s/^RECONCILE_DEPLOYED_DEFAULT=.*/RECONCILE_DEPLOYED_DEFAULT='fedora-dev fedora-bootstrap'/" "$SCRIPT" > "$MUTD"
if ! grep -qF "RECONCILE_DEPLOYED_DEFAULT='fedora-dev fedora-bootstrap'" "$MUTD"; then
  no "deploy-set mutation VACUOUS (sed did not change the copy)"
else
  run "$MUTD" SCOPE_REPO=fedora-desktop HOST_GREEN=1 PUB=success FILES=bin/x.sh ISSUE_STATE=OPEN ANCESTOR=1
  closed && ok "mutant: workload wrongly closed ⇒ the deployed-workload rows discriminate" || no "mutant did not close (the workload rows would not bite)"
fi

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


echo "== A FAILED CLOSE MUST LEAVE NO ANCHOR (the permanent-strand class, found by adversarial review) =="
# `gh issue close --comment` posts the comment and THEN closes. A close that fails after the comment
# landed leaves the issue OPEN carrying its own anchor, so the next scan reads prior=1 on an OPEN issue
# and answers SKIP:reopened-or-half-closed — PERMANENTLY, unrecoverable without a human. Closing first,
# as a separate call, makes an anchor impossible unless the close really happened.
run "$SCRIPT" REFS='400 401' HOST_GREEN=1 PUB=success FILES=bin/x.sh ANCESTOR=1 CLOSE_FAIL=1
{ [ "$(ncloses)" = 0 ] && ! grep -q '^COMMENT ' "$CLOSED"; } \
  && ok "failed close writes NO proof comment ⇒ no anchor ⇒ the ref retries" \
  || no "a failed close still wrote an anchor: $(tr '\n' '|' <"$CLOSED")"
grep -q 'close FAILED' "$ROOT/out" && ok "and it says so in the log" || no "silent close failure"

echo "== MULTI-TICKET: a superseding PR closes EVERY ticket it declares (the e2e-beta #15 shape) =="
# #15 delivered #2, #3 AND #6 after #9/#10 were closed unmerged, but declared only #6 — so #2 and #3
# were delivered and permanently unclaimable, and drivable could never reach 0.
run "$SCRIPT" REFS='400 401 402' HOST_GREEN=1 PUB=success FILES=bin/x.sh ANCESTOR=1
{ closed 400 && closed 401 && closed 402 && [ "$(ncloses)" = 3 ]; } \
  && ok "all three declared tickets closed (3 closes, no more)" \
  || no "multi-ref close: got $(ncloses) closes — $(tr '\n' '|' <"$CLOSED")"

echo "== a ref the gate REFUSES must not block its siblings =="
# ISSUE_LABELS is global in this harness, so refuse ALL of them: the point is that a refusal is per-ref
# and silent-safe, never a close.
run "$SCRIPT" REFS='400 401' HOST_GREEN=1 PUB=success FILES=bin/x.sh ANCESTOR=1 ISSUE_LABELS=''
{ [ "$(ncloses)" = 0 ]; } && ok "unlabelled refs close nothing (a stray number cannot close a PR)" \
  || no "closed something unlabelled: $(tr '\n' '|' <"$CLOSED")"

echo "== the per-ref anchor: an ISSUE already stamped is skipped, not re-closed =="
run "$SCRIPT" REFS='400 401' HOST_GREEN=1 PUB=success FILES=bin/x.sh ANCESTOR=1 ANCHOR=1
{ [ "$(ncloses)" = 0 ]; } && ok "prior per-issue anchor ⇒ no re-close (reopened issues stay open)" \
  || no "re-closed an anchored issue: $(tr '\n' '|' <"$CLOSED")"

echo "== MUTATION RUN IN-SUITE: restore the first-match-only parser ⇒ only ref 1 closes =="
MUT1="$ROOT/reconcile-mut1.sh"
sed 's@^backlog_refs(){@backlog_refs(){ printf "%s\\n" "$1" | grep -oiE "^Backlog-ticket:[[:space:]]*#[0-9]+" | head -1 | grep -oE "[0-9]+"; return; @' "$SCRIPT" > "$MUT1"
if ! grep -q 'head -1 | grep -oE "\[0-9\]+"; return;' "$MUT1"; then
  no "first-only mutation VACUOUS (sed did not change the copy)"
else
  run "$MUT1" REFS='400 401 402' HOST_GREEN=1 PUB=success FILES=bin/x.sh ANCESTOR=1
  { closed 400 && ! closed 401 && ! closed 402; } \
    && ok "mutant: only the FIRST ref closes ⇒ the multi-ticket rows discriminate" \
    || no "mutant did not reproduce the first-ref-only defect (closes=$(ncloses))"
fi

echo
echo "reconcile.test: $pass passed, $fail failed"
[ "$fail" = 0 ]
