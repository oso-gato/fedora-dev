#!/usr/bin/env bash
# repo-scope.test.sh — the R16 OPERATING-SCOPE suite (#167), with ZERO GitHub / network / model.
#
# WHY THIS EXISTS: on 2026-07-13 the apparatus operated on a repo outside its authorized scope and NO
# layer stopped it — a one-line PR (#165) enrolled `knowledge-desktop` into the poller's hardcoded
# sweep default, the host gate passed it (it builds), the fitness gate passed it (nothing in Q1/Q2/Q3
# encoded WHICH repos the apparatus may act on), the poller merged it, swept the foreign repo, pushed
# a bot commit onto its feature branch and squash-merged its PR. This suite proves that class is dead,
# with the issue's own "tests that bite" (req 7):
#   * a swept repo ABSENT from scope produces ZERO actions and ONE loud log line;
#   * an UNREADABLE scope config freezes foreign-repo action while the apparatus's own repos continue;
#   * a PR adding an unconfirmed repo to scope RETURNs in fitness — DETERMINISTICALLY, the reviewer
#     model never runs (its inbox is asserted EMPTY), while a maintainer-CONFIRMED one proceeds and a
#     non-maintainer's CONFIRMED (the fleet-App case: role `write`) stays inert;
#   * every other actuator (auto-merge, dev-plan, dev-loop, dev-author, host-ticket, host-refresh)
#     refuses an out-of-scope repo with NO gh call recorded at all;
#   * MUTATION-CHECK: restoring the hardcoded-default behavior fails the suite — the poller's sweep
#     scope-gate and the fitness diff-adds detector are each mechanically neutralized (the sed must
#     genuinely change the copy, else the row fails as vacuous) and the foreign repo must then get
#     swept / the unconfirmed expansion must then PASS, proving the real rows discriminate.
#
# HOW IT BITES: only `gh` and the reviewer are stubbed (the gh stub RECORDS every call — the "zero
# actions" rows assert on what was actually asked of GitHub, not on log prose); the scripts under test
# are the REAL ones, run in place; scope fixtures ride the reader's own SCOPE_FILE env.
#
# Run:  bash repo-scope.test.sh   → exit 0 = all rows pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCOPE="$HERE/bin/repo-scope.sh"
POLLER="$HERE/bin/pr-poller.sh"
FITNESS="$HERE/bin/fitness-review.sh"
AUTOMERGE="$HERE/bin/auto-merge.sh"
DEVPLAN="$HERE/bin/dev-plan.sh"
DEVLOOP="$HERE/bin/dev-loop.sh"
DEVAUTHOR="$HERE/bin/dev-author.sh"
HTICKET="$HERE/bin/host-ticket.sh"
HREFRESH="$HERE/bin/host-refresh.sh"
for f in "$SCOPE" "$POLLER" "$FITNESS" "$AUTOMERGE" "$DEVPLAN" "$DEVLOOP" "$DEVAUTHOR" "$HTICKET" "$HREFRESH"; do
  [ -f "$f" ] || { echo "FATAL: $f not found"; exit 2; }
done

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
SHA=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee            # a full 40-hex head (the G2 binding)

pass=0; fail=0; n=0
ck(){ [ "$1" = 1 ] && return 0; fail=$((fail+1)); printf '  FAIL %s: %s\n' "$DESC" "$2"; OK=0; }
done_case(){ [ "$OK" = 1 ] && { pass=$((pass+1)); printf '  ok   %s\n' "$DESC"; }; }

# ---- stub gh: RECORDS every call (the zero-actions assertions read this), answers the minimum. -----
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf 'GH %s\n' "$*" >> "${GH_LOG:?}"
case "${1:-} ${2:-}" in
  "pr list")  exit 0;;                                  # empty lists — a quiet sweep
  "pr view")
    case "$*" in
      *"--json author"*)     printf 'someone-else\n';;
      *"--json headRefOid"*) printf '%s\n' "$FAKE_SHA";;
      *"--json title"*)      printf 'a change\n';;
      *"--json body"*)       printf 'the PR body\n';;
    esac; exit 0;;
  "pr diff")  cat "${DIFF_FILE:?}"; exit 0;;
  "api "*)
    case "$*" in
      *"/comments"*)   cat "${COMMENTS_TSV:-/dev/null}" 2>/dev/null; exit "${COMMENTS_RC:-0}";;
      *"/permission"*) s="$*"; u="${s##*collaborators/}"; u="${u%%/permission*}"
                       cat "${ROLE_DIR:?}/$u" 2>/dev/null; exit 0;;
    esac; exit 0;;
  "pr comment") printf 'POSTED %s\n' "$*" >> "$GH_LOG"; exit 0;;
esac
exit 0
EOF

# ---- stub reviewer: proves whether the MODEL was consulted (the deterministic-RETURN rows). --------
cat > "$BIN/reviewer" <<'EOF'
#!/usr/bin/env bash
cat > "${RECV:?}"
: > "${RAN:?}"
echo "Q1 fine. Q2 fine. Q3 fine."
echo "FITNESS_VERDICT: PASS"
EOF

# ---- author recorder for the dev-loop row ----------------------------------------------------------
cat > "$BIN/author-rec" <<'EOF'
#!/usr/bin/env bash
echo "AUTHOR $*" >> "${AUTHOR_LOG:?}"
exit 0
EOF
chmod +x "$BIN"/*

setup_case(){
  n=$((n+1)); CASE="$ROOT/c$n"; mkdir -p "$CASE/home" "$CASE/roles"
  GH_LOG="$CASE/gh.log"; : > "$GH_LOG"
  RECV="$CASE/reviewer-recv.txt"; RAN="$CASE/reviewer.ran"; : > "$RECV"; rm -f "$RAN"
  DIFF="$CASE/diff.txt"; : > "$DIFF"
  SCOPE_FIX="$CASE/scope.conf"
}
gh_names(){ grep -c "$1" "$GH_LOG" 2>/dev/null || true; }   # how many recorded gh calls name a string

# run an actuator with the common fixture env. Usage: run_env [extra env…] -- cmd args…
run_env(){
  local envs=()
  while [ "${1:-}" != "--" ]; do envs+=("$1"); shift; done
  shift
  env PATH="$BIN:$PATH" HOME="$CASE/home" GH_LOG="$GH_LOG" FAKE_SHA="$SHA" \
      DIFF_FILE="$DIFF" RECV="$RECV" RAN="$RAN" ROLE_DIR="$CASE/roles" \
      SCOPE_FILE="$SCOPE_FIX" "${envs[@]}" "$@" > "$CASE/out.log" 2> "$CASE/err.log"
  RC=$?
}
out_has(){    ck "$(grep -q "$1" "$CASE/out.log" && echo 1 || echo 0)" "stdout lacks [$1]"; }
out_hasnt(){  ck "$(grep -q "$1" "$CASE/out.log" && echo 0 || echo 1)" "stdout wrongly has [$1]"; }
err_has(){    ck "$(grep -q "$1" "$CASE/err.log" && echo 1 || echo 0)" "stderr lacks [$1]"; }
log_has(){    ck "$(grep -q "$1" "$CASE/out.log" "$CASE/err.log" && echo 1 || echo 0)" "no channel says [$1]"; }
gh_untouched(){ ck "$([ -s "$GH_LOG" ] && echo 0 || echo 1)" "gh WAS called on an out-of-scope refusal: $(head -3 "$GH_LOG" 2>/dev/null | tr '\n' ' ')"; }

# ===================================================================================================
echo "== the reader's own selftest (pure core: norm/parse/member/decide/diff-adds) =="
DESC="repo-scope.sh --selftest passes"; OK=1
bash "$SCOPE" --selftest > "$ROOT/selftest.log" 2>&1 \
  || { OK=0; fail=$((fail+1)); printf '  FAIL %s:\n' "$DESC"; tail -5 "$ROOT/selftest.log"; }
done_case

echo "== reader contract: rc 0 is the ONLY go; DENY is loud; the fallback is OWN-repos-only =="
DESC="check answers the contract on a readable config"; OK=1
setup_case
printf 'fedora-dev\nwl-two\n' > "$SCOPE_FIX"
SCOPE_FILE="$SCOPE_FIX" bash "$SCOPE" check fedora-dev 2>/dev/null;         ck "$([ $? = 0 ] && echo 1 || echo 0)" "in-scope rc != 0"
SCOPE_FILE="$SCOPE_FIX" bash "$SCOPE" check oso-gato/wl-two 2>/dev/null;    ck "$([ $? = 0 ] && echo 1 || echo 0)" "owner/-form not normalized"
SCOPE_FILE="$SCOPE_FIX" bash "$SCOPE" check knowledge-desktop 2>"$CASE/deny.err"; rc=$?
ck "$([ "$rc" = 3 ] && echo 1 || echo 0)" "out-of-scope rc=$rc want 3"
ck "$(grep -q 'DENY' "$CASE/deny.err" && echo 1 || echo 0)" "the DENY is silent"
ck "$([ "$(SCOPE_FILE="$SCOPE_FIX" bash "$SCOPE" list 2>/dev/null | tr '\n' ' ')" = 'fedora-dev wl-two ' ] && echo 1 || echo 0)" "list does not echo the config"
done_case

DESC="unreadable config: OWN repos continue, everything else freezes (rule-4 fail direction)"; OK=1
setup_case
SCOPE_FILE="$CASE/absent" bash "$SCOPE" check fedora-dev 2>"$CASE/own.err";       ck "$([ $? = 0 ] && echo 1 || echo 0)" "own repo frozen under fallback"
ck "$(grep -q 'WARN' "$CASE/own.err" && echo 1 || echo 0)" "the fallback allow is silent — the operator must see the degraded mode"
SCOPE_FILE="$CASE/absent" bash "$SCOPE" check fedora-bootstrap 2>/dev/null;       ck "$([ $? = 0 ] && echo 1 || echo 0)" "control repo frozen under fallback"
SCOPE_FILE="$CASE/absent" bash "$SCOPE" check fedora-desktop 2>/dev/null; rc=$?
ck "$([ "$rc" = 4 ] && echo 1 || echo 0)" "a normally-in-scope but non-own repo ran under an unreadable config (rc=$rc want 4)"
ck "$([ "$(SCOPE_FILE="$CASE/absent" bash "$SCOPE" list 2>/dev/null | tr '\n' ' ')" = 'fedora-dev fedora-bootstrap ' ] && echo 1 || echo 0)" "the fallback list is not exactly the own repos"
done_case

DESC="a readable-but-EMPTY config denies EVERYTHING — narrowing is the maintainer's right"; OK=1
setup_case
printf '# emptied on purpose\n' > "$SCOPE_FIX"
SCOPE_FILE="$SCOPE_FIX" bash "$SCOPE" check fedora-dev 2>/dev/null; rc=$?
ck "$([ "$rc" = 3 ] && echo 1 || echo 0)" "an emptied config still allowed the own repo (rc=$rc want 3)"
done_case

DESC="the SHIPPED config pins the confirmed set — and the incident repo, by name, is out"; OK=1
setup_case
ck "$([ "$(bash "$SCOPE" list 2>/dev/null | tr '\n' ' ')" = 'fedora-dev fedora-bootstrap fedora-desktop e2e-alpha ' ] && echo 1 || echo 0)" "policy/scope.conf does not hold exactly the #167-confirmed set"
bash "$SCOPE" check knowledge-desktop 2>/dev/null && ck 0 "knowledge-desktop is IN the shipped scope" || ck 1 x
done_case

# ===================================================================================================
echo "== POLLER: a swept repo absent from scope → ZERO actions, ONE loud line (issue req 7) =="
DESC="the foreign repo is skipped: no gh call names it, exactly one R16 line"; OK=1
setup_case
printf 'fedora-dev\n' > "$SCOPE_FIX"
run_env FLEET_HALT=true POLLER_ARMED=0 POLLER_REPOS="fedora-dev knowledge-desktop" -- bash "$POLLER" --once
ck "$([ "$(gh_names 'repo oso-gato/fedora-dev')" -ge 1 ] && echo 1 || echo 0)" "the in-scope repo was not swept at all"
ck "$([ "$(gh_names 'knowledge-desktop')" = 0 ] && echo 1 || echo 0)" "gh was asked about the FOREIGN repo — that is an action"
ck "$([ "$(grep -c "R16 SCOPE: repo 'knowledge-desktop'" "$CASE/err.log")" = 1 ] && echo 1 || echo 0)" "want exactly ONE loud skip line for the foreign repo"
ck "$(grep -q "R16 SCOPE: repo 'fedora-dev'" "$CASE/err.log" && echo 0 || echo 1)" "the in-scope repo was R16-skipped"
done_case

DESC="unreadable scope config: own repos continue, the foreign repo freezes — through the REAL poller"; OK=1
setup_case
run_env SCOPE_FILE="$CASE/absent" FLEET_HALT=true POLLER_ARMED=0 \
        POLLER_REPOS="fedora-dev knowledge-desktop" -- bash "$POLLER" --once
ck "$([ "$(gh_names 'repo oso-gato/fedora-dev')" -ge 1 ] && echo 1 || echo 0)" "the own repo froze too — the loop must keep shipping itself"
ck "$([ "$(gh_names 'knowledge-desktop')" = 0 ] && echo 1 || echo 0)" "the foreign repo was swept under an unreadable config"
ck "$([ "$(grep -c "R16 SCOPE: repo 'knowledge-desktop'" "$CASE/err.log")" = 1 ] && echo 1 || echo 0)" "want exactly one loud line"
done_case

DESC="no POLLER_REPOS set → the sweep list DERIVES from the config (not the old hardcoded four)"; OK=1
setup_case
printf 'fedora-dev\nwl-two\n' > "$SCOPE_FIX"
run_env FLEET_HALT=true POLLER_ARMED=0 -- bash "$POLLER" --once
ck "$([ "$(gh_names 'repo oso-gato/fedora-dev')" -ge 1 ] && echo 1 || echo 0)" "config repo 1 not swept"
ck "$([ "$(gh_names 'repo oso-gato/wl-two')" -ge 1 ] && echo 1 || echo 0)" "config repo 2 not swept — the default is not derived from the config"
ck "$([ "$(gh_names 'fedora-desktop')" = 0 ] && echo 1 || echo 0)" "fedora-desktop swept while NOT in the config — a hardcoded default is still alive"
ck "$([ "$(gh_names 'fedora-bootstrap')" = 0 ] && echo 1 || echo 0)" "fedora-bootstrap swept while NOT in the config — a hardcoded default is still alive"
done_case

echo "== MUTATION: neutralize the sweep scope-gate → the foreign repo GETS swept (pre-#167 restored) =="
DESC="the poller row discriminates: the mutant sweeps the foreign repo"; OK=1
setup_case
printf 'fedora-dev\n' > "$SCOPE_FIX"
MUTP="$ROOT/poller-mut.sh"
sed 's@if ! "$REPO_SCOPE" check "$_r" 2>/dev/null; then@if false; then@' "$POLLER" > "$MUTP"
ck "$(cmp -s "$POLLER" "$MUTP" && echo 0 || echo 1)" "the sed changed nothing — this mutation row is vacuous"
run_env FLEET_HALT=true POLLER_ARMED=0 POLLER_REPOS="fedora-dev knowledge-desktop" -- bash "$MUTP" --once
ck "$([ "$(gh_names 'repo oso-gato/knowledge-desktop')" -ge 1 ] && echo 1 || echo 0)" "the neutralized gate did NOT sweep the foreign repo — the real row would pass vacuously"
done_case

# ===================================================================================================
# FITNESS — the R16 gate: an unconfirmed scope-expansion PR RETURNs deterministically (req 3 + 7).
# REPO_SCOPE is pinned to the real reader for every row: the mutation row runs a sed-COPY from $ROOT
# where the $HERE-relative default does not exist, and a missing reader is a fail-closed refusal that
# would pass that row vacuously. LG_HOST_LOGIN= skips the GREEN precheck (offline); FITNESS_LOGIN is
# a distinct bot so SoD passes; dry-run, so nothing may ever be POSTED.
# ===================================================================================================
fitness_env(){ run_env REPO_SCOPE="$SCOPE" FITNESS_CLAUDE="reviewer -p" FITNESS_LOGIN=fit-bot LG_HOST_LOGIN= "$@"; }
expansion_diff(){
  cat > "$DIFF" <<'DIFF_EOF'
diff --git a/policy/scope.conf b/policy/scope.conf
--- a/policy/scope.conf
+++ b/policy/scope.conf
@@ -1,4 +1,5 @@
 fedora-dev
 fedora-bootstrap
+knowledge-desktop
DIFF_EOF
}

echo "== FITNESS: an UNCONFIRMED scope expansion RETURNs — the reviewer model never runs =="
DESC="unconfirmed +repo in policy/scope.conf → deterministic RETURN, model not consulted"; OK=1
setup_case; printf 'fedora-dev\n' > "$SCOPE_FIX"; expansion_diff
fitness_env -- bash "$FITNESS" fedora-dev 1
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC want 0 (a verdict WAS produced — the RETURN is the verdict)"
ck "$(grep -qx "Fitness review: VERDICT RETURN — head $SHA" "$CASE/out.log" && echo 1 || echo 0)" "line 1 lost the G2 grammar or the full-sha binding"
ck "$([ ! -f "$RAN" ] && echo 1 || echo 0)" "the reviewer MODEL ran — a structural blocker must not consult a judgment"
out_has 'R16 OPERATING SCOPE'
out_has 'knowledge-desktop'
out_has 'CONFIRMED'                                     # the remediation is spelled out
err_has 'NO maintainer-recorded confirmation'
ck "$([ "$(gh_names '^POSTED')" = 0 ] && echo 1 || echo 0)" "dry-run POSTED something"
done_case

DESC="a MAINTAINER's line-1 CONFIRMED on the PR unlocks the expansion → the model reviews it"; OK=1
setup_case; printf 'fedora-dev\n' > "$SCOPE_FIX"; expansion_diff
printf 'arthur\tCONFIRMED — expand the scope for this objective\n' > "$CASE/comments.tsv"
printf 'admin\n' > "$CASE/roles/arthur"
fitness_env COMMENTS_TSV="$CASE/comments.tsv" -- bash "$FITNESS" fedora-dev 1
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC want 0"
ck "$([ -f "$RAN" ] && echo 1 || echo 0)" "the reviewer never ran on a maintainer-confirmed expansion"
ck "$(grep -qx "Fitness review: VERDICT PASS — head $SHA" "$CASE/out.log" && echo 1 || echo 0)" "the confirmed path did not reach a model verdict"
err_has 'maintainer-confirmed by @arthur'
done_case

DESC="a NON-maintainer's CONFIRMED (fleet-App case: role write) authorizes NOTHING → still RETURN"; OK=1
setup_case; printf 'fedora-dev\n' > "$SCOPE_FIX"; expansion_diff
printf 'nox-claudebox\tCONFIRMED go\n' > "$CASE/comments.tsv"
printf 'write\n' > "$CASE/roles/nox-claudebox"
fitness_env COMMENTS_TSV="$CASE/comments.tsv" -- bash "$FITNESS" fedora-dev 1
ck "$(grep -qx "Fitness review: VERDICT RETURN — head $SHA" "$CASE/out.log" && echo 1 || echo 0)" "an App's CONFIRMED unlocked a scope expansion"
ck "$([ ! -f "$RAN" ] && echo 1 || echo 0)" "the reviewer ran despite the unconfirmed expansion"
err_has 'ignoring line-1 CONFIRMED'
done_case

DESC="an UNREADABLE comment stream reads as unconfirmed (fail-closed) → RETURN"; OK=1
setup_case; printf 'fedora-dev\n' > "$SCOPE_FIX"; expansion_diff
fitness_env COMMENTS_RC=1 -- bash "$FITNESS" fedora-dev 1
ck "$(grep -qx "Fitness review: VERDICT RETURN — head $SHA" "$CASE/out.log" && echo 1 || echo 0)" "an unreadable bus did not fail closed"
ck "$([ ! -f "$RAN" ] && echo 1 || echo 0)" "the reviewer ran on an unverifiable confirmation"
done_case

DESC="a REMOVAL-only scope diff never trips the gate — narrowing needs no ceremony"; OK=1
setup_case; printf 'fedora-dev\n' > "$SCOPE_FIX"
cat > "$DIFF" <<'DIFF_EOF'
--- a/policy/scope.conf
+++ b/policy/scope.conf
@@ -1,3 +1,2 @@
 fedora-dev
-e2e-alpha
 fedora-bootstrap
DIFF_EOF
fitness_env -- bash "$FITNESS" fedora-dev 1
ck "$([ -f "$RAN" ] && echo 1 || echo 0)" "the reviewer never ran on a pure narrowing"
ck "$(grep -qx "Fitness review: VERDICT PASS — head $SHA" "$CASE/out.log" && echo 1 || echo 0)" "narrowing did not flow to a normal model verdict"
done_case

DESC="a MOVED scope line (−x … +x) is net-zero — not an expansion"; OK=1
setup_case; printf 'fedora-dev\n' > "$SCOPE_FIX"
cat > "$DIFF" <<'DIFF_EOF'
--- a/policy/scope.conf
+++ b/policy/scope.conf
@@ -1,3 +1,3 @@
-e2e-alpha
 fedora-dev
+e2e-alpha
DIFF_EOF
fitness_env -- bash "$FITNESS" fedora-dev 1
ck "$([ -f "$RAN" ] && echo 1 || echo 0)" "the reviewer never ran on a reorder"
ck "$(grep -qx "Fitness review: VERDICT PASS — head $SHA" "$CASE/out.log" && echo 1 || echo 0)" "a moved line was treated as an expansion"
done_case

DESC="fitness refuses to REVIEW an out-of-scope repo at all (rule 4)"; OK=1
setup_case; printf 'fedora-dev\n' > "$SCOPE_FIX"; expansion_diff
fitness_env -- bash "$FITNESS" knowledge-desktop 1
ck "$([ "$RC" = 1 ] && echo 1 || echo 0)" "rc=$RC want 1 (retryable precondition)"
err_has 'outside the maintainer-confirmed operating scope'
ck "$([ ! -f "$RAN" ] && echo 1 || echo 0)" "the reviewer ran on a foreign repo"
gh_untouched
done_case

echo "== MUTATION: neutralize the diff-adds detector → the unconfirmed expansion PASSes =="
DESC="the fitness row discriminates: the mutant lets the expansion through to the stub's PASS"; OK=1
setup_case; printf 'fedora-dev\n' > "$SCOPE_FIX"; expansion_diff
MUTF="$ROOT/fitness-mut.sh"
sed 's@^scope_added=.*@scope_added=""@' "$FITNESS" > "$MUTF"
ck "$(cmp -s "$FITNESS" "$MUTF" && echo 0 || echo 1)" "the sed changed nothing — this mutation row is vacuous"
fitness_env -- bash "$MUTF" fedora-dev 1
ck "$([ -f "$RAN" ] && echo 1 || echo 0)" "the neutralized detector still blocked the model — the real row would pass vacuously"
ck "$(grep -qx "Fitness review: VERDICT PASS — head $SHA" "$CASE/out.log" && echo 1 || echo 0)" "the mutant did not PASS the unconfirmed expansion"
done_case

# ===================================================================================================
echo "== EVERY OTHER ACTUATOR refuses an out-of-scope repo with NO gh call at all (rule 4) =="
DESC="auto-merge: out of scope → REFUSE before any gate is read"; OK=1
setup_case; printf 'fedora-dev\n' > "$SCOPE_FIX"
run_env -- bash "$AUTOMERGE" knowledge-desktop 1
ck "$([ "$RC" = 1 ] && echo 1 || echo 0)" "rc=$RC want 1"
out_has 'R16 REFUSE'
gh_untouched
done_case

DESC="auto-merge: an in-scope repo still reaches the two gates (R16 is a gate, not a wall)"; OK=1
setup_case; printf 'fedora-dev\n' > "$SCOPE_FIX"
run_env LG_HOST_LOGIN=host-bot FITNESS_LOGIN=fit-bot -- bash "$AUTOMERGE" fedora-dev 1
out_hasnt 'R16 REFUSE'
out_has 'live-gate='                                    # the normal gate-decision line was reached
done_case

DESC="dev-plan: out of scope → rc 12, nothing read, nothing filed"; OK=1
setup_case; printf 'fedora-dev\n' > "$SCOPE_FIX"
run_env -- bash "$DEVPLAN" knowledge-desktop 9
ck "$([ "$RC" = 12 ] && echo 1 || echo 0)" "rc=$RC want 12"
err_has 'R16 SCOPE'
gh_untouched
done_case

DESC="dev-loop: out of scope → pass refused, the author is never spawned"; OK=1
setup_case; printf 'fedora-dev\n' > "$SCOPE_FIX"
AUTHOR_LOG="$CASE/author.log"; : > "$AUTHOR_LOG"
run_env AUTHOR_LOG="$AUTHOR_LOG" DEV_AUTHOR="$BIN/author-rec" FLEET_HALT=true -- bash "$DEVLOOP" knowledge-desktop
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC want 0 (a refused pass is not a crash)"
err_has 'R16 SCOPE'
ck "$([ -s "$AUTHOR_LOG" ] && echo 0 || echo 1)" "the author recorder WAS invoked on a foreign repo"
gh_untouched
done_case

DESC="dev-author: out of scope → rc 2, nothing read, nothing posted (not even the BLOCKED question)"; OK=1
setup_case; printf 'fedora-dev\n' > "$SCOPE_FIX"
run_env -- bash "$DEVAUTHOR" knowledge-desktop 5
ck "$([ "$RC" = 2 ] && echo 1 || echo 0)" "rc=$RC want 2"
err_has 'R16 SCOPE'
gh_untouched
done_case

DESC="host-ticket: an out-of-scope control repo → no label create, no issue filed"; OK=1
setup_case; printf 'fedora-dev\n' > "$SCOPE_FIX"
run_env HOST_TICKET_REPO=knowledge-desktop -- bash "$HTICKET" redeploy fedora-dev
ck "$([ "$RC" = 1 ] && echo 1 || echo 0)" "rc=$RC want 1"
err_has 'R16 SCOPE'
gh_untouched
done_case

DESC="host-refresh: an out-of-scope workload AND control repo → no scan, no ticket, no question"; OK=1
setup_case; printf 'fedora-dev\n' > "$SCOPE_FIX"
run_env HOST_REFRESH_WORKLOADS="knowledge-desktop" HOST_REFRESH_CONTROL_REPO="knowledge-desktop" \
        -- bash "$HREFRESH" --once
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC want 0 (a skip is not a crash)"
ck "$([ "$(grep -c 'R16 SCOPE' "$CASE/err.log")" = 2 ] && echo 1 || echo 0)" "want one loud line per skipped arm (workload + control)"
gh_untouched
done_case

echo
echo "repo-scope suite: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
