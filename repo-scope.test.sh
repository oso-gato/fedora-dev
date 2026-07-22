#!/usr/bin/env bash
# repo-scope.test.sh — the R16 OPERATING-SCOPE suite (#167 → #239), with ZERO GitHub / network / model.
#
# WHY THIS EXISTS: on 2026-07-13 the apparatus operated on a repo outside its authorized scope and NO
# layer stopped it — a one-line PR (#165) enrolled `knowledge-desktop` into the poller's hardcoded
# sweep default, the host gate passed it (it builds), the fitness gate passed it (nothing in Q1/Q2/Q3
# encoded WHICH repos the apparatus may act on), the poller merged it, swept the foreign repo, pushed
# a bot commit onto its feature branch and squash-merged its PR. This suite proves that class is dead.
#
# THE SCOPE MODEL (#239): the operating scope IS the App INSTALLATION — the apparatus acts on exactly
# the repos its GitHub App is installed on (whatever access the maintainer configured; no allowlist,
# no scope.conf, no hardcoded repo names). bin/repo-scope.sh enumerates the installation via
# `gh api /installation/repositories` (cached), and falls CLOSED to the apparatus's own two repos
# ($SCOPE_OWN) when the enumeration is unreadable OR empty (the App is always installed on ≥ its own
# repos, so an empty enumeration means the API failed). The suite drives that model end-to-end:
#   * a readable enumeration decides scope on membership; an out-of-scope repo is a loud DENY (rc 3);
#   * an UNREADABLE / EMPTY enumeration freezes foreign-repo action while the apparatus's own repos
#     continue (the rule-4 fail direction);
#   * the poller's sweep list DERIVES from the enumeration (never a hardcoded default);
#   * fitness refuses to review an out-of-scope repo, and every other actuator (auto-merge, dev-plan,
#     dev-loop, dev-author, host-ticket, host-refresh) refuses one with NO action taken on it;
#   * MUTATION-CHECK: neutralize the poller's sweep scope-gate and the foreign repo gets swept
#     (the pre-#167 behaviour), proving the real row discriminates.
#
# HOW IT BITES: only `gh` and the reviewer are stubbed (the gh stub RECORDS every call — the "no
# action" rows assert on what was actually asked of GitHub, EXCLUDING the scope-enumeration read
# itself, which is a scope CHECK, not an action); the scripts under test are the REAL ones, run in
# place; the scope enumeration rides the reader's SCOPE_ENUM env (the stub cats it, one bare repo
# name per line) with SCOPE_CACHE_TTL=0 so each call re-reads the stub.
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

# ---- stub gh: RECORDS every call (the no-action assertions read this), answers the minimum. ---------
# The scope-enumeration endpoint (/installation/repositories) is answered from SCOPE_ENUM (one bare
# repo name per line) — this is how the reader learns the App's installed repo set under test.
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
      *"/installation/repositories"*) cat "${SCOPE_ENUM:-/dev/null}" 2>/dev/null; exit 0;;
      *"/comments"*)   cat "${COMMENTS_TSV:-/dev/null}" 2>/dev/null; exit "${COMMENTS_RC:-0}";;
      *"/permission"*) s="$*"; u="${s##*collaborators/}"; u="${u%%/permission*}"
                       cat "${ROLE_DIR:?}/$u" 2>/dev/null; exit 0;;
    esac; exit 0;;
  "pr comment") printf 'POSTED %s\n' "$*" >> "$GH_LOG"; exit 0;;
esac
exit 0
EOF

# ---- stub reviewer: proves whether the MODEL was consulted. ----------------------------------------
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
  SCOPE_FIX="$CASE/scope.enum"                          # the App-install enumeration, one repo/line
}
gh_names(){ grep -c "$1" "$GH_LOG" 2>/dev/null || true; }   # how many recorded gh calls name a string

# a DIRECT reader call, wired to the STUB gh + a given enumeration fixture (no run_env). The stub gh
# needs PATH + GH_LOG; the reader needs SCOPE_ENUM + a per-case cache with TTL 0 (re-read every call).
sread(){ env PATH="$BIN:$PATH" GH_LOG="$GH_LOG" SCOPE_ENUM="$1" \
             SCOPE_CACHE="$CASE/scache" SCOPE_CACHE_TTL=0 bash "$SCOPE" "${@:2}"; }

# run an actuator with the common fixture env. Usage: run_env [extra env…] -- cmd args…
run_env(){
  local envs=()
  while [ "${1:-}" != "--" ]; do envs+=("$1"); shift; done
  shift
  env PATH="$BIN:$PATH" HOME="$CASE/home" GH_LOG="$GH_LOG" FAKE_SHA="$SHA" \
      DIFF_FILE="$DIFF" RECV="$RECV" RAN="$RAN" ROLE_DIR="$CASE/roles" \
      SCOPE_ENUM="$SCOPE_FIX" SCOPE_CACHE="$CASE/scache" SCOPE_CACHE_TTL=0 \
      "${envs[@]}" "$@" > "$CASE/out.log" 2> "$CASE/err.log"
  RC=$?
}
out_has(){    ck "$(grep -q "$1" "$CASE/out.log" && echo 1 || echo 0)" "stdout lacks [$1]"; }
out_hasnt(){  ck "$(grep -q "$1" "$CASE/out.log" && echo 0 || echo 1)" "stdout wrongly has [$1]"; }
err_has(){    ck "$(grep -q "$1" "$CASE/err.log" && echo 1 || echo 0)" "stderr lacks [$1]"; }
log_has(){    ck "$(grep -q "$1" "$CASE/out.log" "$CASE/err.log" && echo 1 || echo 0)" "no channel says [$1]"; }
# "no ACTION taken" — the scope-enumeration READ is a check, not an action, so it is EXCLUDED.
gh_untouched(){
  local other; other="$(grep -v '/installation/repositories' "$GH_LOG" 2>/dev/null || true)"
  ck "$([ -z "$other" ] && echo 1 || echo 0)" "gh was called (beyond the scope-enumeration read) on an out-of-scope refusal: $(printf '%s' "$other" | head -3 | tr '\n' ' ')"
}

# ===================================================================================================
echo "== the reader's own selftest (pure core: norm/parse/member/decide/session helpers) =="
DESC="repo-scope.sh --selftest passes"; OK=1
bash "$SCOPE" --selftest > "$ROOT/selftest.log" 2>&1 \
  || { OK=0; fail=$((fail+1)); printf '  FAIL %s:\n' "$DESC"; tail -5 "$ROOT/selftest.log"; }
done_case

echo "== reader contract: rc 0 is the ONLY go; DENY is loud; the fallback is OWN-repos-only =="
DESC="check answers the contract on a readable enumeration"; OK=1
setup_case
printf 'fedora-dev\nwl-two\n' > "$SCOPE_FIX"
sread "$SCOPE_FIX" check fedora-dev 2>/dev/null;         ck "$([ $? = 0 ] && echo 1 || echo 0)" "in-scope rc != 0"
sread "$SCOPE_FIX" check oso-gato/wl-two 2>/dev/null;    ck "$([ $? = 0 ] && echo 1 || echo 0)" "owner/-form not normalized"
sread "$SCOPE_FIX" check knowledge-desktop 2>"$CASE/deny.err"; rc=$?
ck "$([ "$rc" = 3 ] && echo 1 || echo 0)" "out-of-scope rc=$rc want 3"
ck "$(grep -q 'DENY' "$CASE/deny.err" && echo 1 || echo 0)" "the DENY is silent"
ck "$([ "$(sread "$SCOPE_FIX" list 2>/dev/null | tr '\n' ' ')" = 'fedora-dev wl-two ' ] && echo 1 || echo 0)" "list does not echo the enumeration"
done_case

DESC="unreadable enumeration: OWN repos continue, everything else freezes (rule-4 fail direction)"; OK=1
setup_case
sread "$CASE/absent" check fedora-dev 2>"$CASE/own.err";       ck "$([ $? = 0 ] && echo 1 || echo 0)" "own repo frozen under fallback"
ck "$(grep -q 'WARN' "$CASE/own.err" && echo 1 || echo 0)" "the fallback allow is silent — the operator must see the degraded mode"
sread "$CASE/absent" check fedora-bootstrap 2>/dev/null;       ck "$([ $? = 0 ] && echo 1 || echo 0)" "control repo frozen under fallback"
sread "$CASE/absent" check fedora-desktop 2>/dev/null; rc=$?
ck "$([ "$rc" = 4 ] && echo 1 || echo 0)" "a normally-in-scope but non-own repo ran under an unreadable enumeration (rc=$rc want 4)"
ck "$([ "$(sread "$CASE/absent" list 2>/dev/null | tr '\n' ' ')" = 'fedora-dev fedora-bootstrap ' ] && echo 1 || echo 0)" "the fallback list is not exactly the own repos"
done_case

DESC="an EMPTY enumeration is UNREADABLE → fall closed to OWN (the App is always installed on ≥ its own repos)"; OK=1
# BEHAVIOR CHANGE (#239): with scope.conf gone, an empty enumeration cannot mean "the maintainer
# emptied the scope" — the App is always installed on at least its own repos, so an empty result is
# an API failure. It therefore falls CLOSED to SCOPE_OWN (own repos continue), NOT "deny everything".
setup_case
printf '# nothing enumerable\n' > "$SCOPE_FIX"          # parses to zero names → treated as unreadable
sread "$SCOPE_FIX" check fedora-dev 2>/dev/null; rc=$?
ck "$([ "$rc" = 0 ] && echo 1 || echo 0)" "an empty enumeration froze the own repo too (rc=$rc want 0 — fallback to OWN)"
ck "$([ "$(sread "$SCOPE_FIX" list 2>/dev/null | tr '\n' ' ')" = 'fedora-dev fedora-bootstrap ' ] && echo 1 || echo 0)" "an empty enumeration's list is not the own-repo fallback"
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

DESC="unreadable enumeration: own repos continue, the foreign repo freezes — through the REAL poller"; OK=1
setup_case
run_env SCOPE_ENUM="$CASE/absent" FLEET_HALT=true POLLER_ARMED=0 \
        POLLER_REPOS="fedora-dev knowledge-desktop" -- bash "$POLLER" --once
ck "$([ "$(gh_names 'repo oso-gato/fedora-dev')" -ge 1 ] && echo 1 || echo 0)" "the own repo froze too — the loop must keep shipping itself"
ck "$([ "$(gh_names 'knowledge-desktop')" = 0 ] && echo 1 || echo 0)" "the foreign repo was swept under an unreadable enumeration"
ck "$([ "$(grep -c "R16 SCOPE: repo 'knowledge-desktop'" "$CASE/err.log")" = 1 ] && echo 1 || echo 0)" "want exactly one loud line"
done_case

DESC="no POLLER_REPOS set → the sweep list DERIVES from the enumeration (not a hardcoded default)"; OK=1
setup_case
printf 'fedora-dev\nwl-two\n' > "$SCOPE_FIX"
run_env FLEET_HALT=true POLLER_ARMED=0 -- bash "$POLLER" --once
ck "$([ "$(gh_names 'repo oso-gato/fedora-dev')" -ge 1 ] && echo 1 || echo 0)" "enumerated repo 1 not swept"
ck "$([ "$(gh_names 'repo oso-gato/wl-two')" -ge 1 ] && echo 1 || echo 0)" "enumerated repo 2 not swept — the default is not derived from the enumeration"
ck "$([ "$(gh_names 'repo oso-gato/fedora-desktop')" = 0 ] && echo 1 || echo 0)" "fedora-desktop swept while NOT in the enumeration — a hardcoded default is still alive"
ck "$([ "$(gh_names 'repo oso-gato/fedora-bootstrap')" = 0 ] && echo 1 || echo 0)" "fedora-bootstrap swept while NOT in the enumeration — a hardcoded default is still alive"
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
echo "== FITNESS refuses to REVIEW an out-of-scope repo at all (rule 4) =="
# REPO_SCOPE is pinned to the real reader; LG_HOST_LOGIN= skips the GREEN precheck (offline);
# FITNESS_LOGIN is a distinct bot so SoD passes; dry-run, so nothing may ever be POSTED.
fitness_env(){ run_env REPO_SCOPE="$SCOPE" FITNESS_CLAUDE="reviewer -p" FITNESS_LOGIN=fit-bot LG_HOST_LOGIN= "$@"; }
DESC="fitness refuses to REVIEW an out-of-scope repo at all (rule 4)"; OK=1
setup_case; printf 'fedora-dev\n' > "$SCOPE_FIX"
fitness_env -- bash "$FITNESS" knowledge-desktop 1
ck "$([ "$RC" = 1 ] && echo 1 || echo 0)" "rc=$RC want 1 (retryable precondition)"
err_has 'outside the maintainer-confirmed operating scope'
ck "$([ ! -f "$RAN" ] && echo 1 || echo 0)" "the reviewer ran on a foreign repo"
gh_untouched
done_case

# ===================================================================================================
echo "== EVERY OTHER ACTUATOR refuses an out-of-scope repo with NO action taken on it (rule 4) =="
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
