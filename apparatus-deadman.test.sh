#!/usr/bin/env bash
# apparatus-deadman.test.sh — MOCK end-to-end suite for bin/apparatus-deadman.sh (R18 liveness deadman).
#
# REAL where it matters, stub only the boundary:
#   * a REAL bare origin + working clone you can set BEHIND / AHEAD / DIRTY (the git facts are real git);
#   * a REAL backgrounded process whose cmdline IS `bash …/pr-poller.sh --watch` (the "genuine poller")
#     + a REAL DECOY (`pr-poller.sh --watch` as a bare argv[0], no script path) — the self-match axis is
#     exercised against actual /proc, not asserted;
#   * a REAL poller-log file whose mtime is aged with `touch -d`;
#   * `gh` STUBBED to RECORD every create/edit/comment/close/search (no network).
#
# Asserts: each of the 4 anomalies fires with the right reason · all-healthy ⇒ ZERO gh writes · dedup
# (two anomalies ⇒ ONE issue, updated) · healthy-after-anomaly ⇒ cleared + closed · the SELF-MATCH decoy
# does NOT trip poller-alive · the deadman NEVER writes the clone (HEAD + status unchanged after a check)
# · an unreadable signal surfaces ONLY after the consecutive bound. In-suite MUTATION-CHECKS (grep-verified
# non-vacuous, since cmp/diff are forbidden): neutralize the lag gate ⇒ merged-not-live stops firing;
# neutralize the self-match exclusion ⇒ the decoy trips it.
#
#   bash apparatus-deadman.test.sh   → exit 0 = all rows pass. No GitHub / network / model.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/bin/apparatus-deadman.sh"
ROOT="$(mktemp -d)"
export GH_CALLS="$ROOT/gh.calls"
export GH_SEARCH_RESULT=""
export DEADMAN_REPO="oso-gato/fedora-bootstrap"
# DO NOT WRITE THE PRODUCTION EVIDENCE FILE — see the same guard in apparatus-respond.test.sh. $DEADMAN_LOG
# defaults to the box's real ~/.local/state/apparatus-deadman/deadman.log (#273), so an un-neutered suite
# run interleaves fixture ANOMALY/SURFACE/CLEARED lines into the record used to judge the watchdog's real
# behaviour. The NON-COLON `${DEADMAN_LOG-…}` makes an exported EMPTY value a genuine disable; stderr keeps
# every line, and no row here asserts on the file.
export DEADMAN_LOG=""

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
GENUINE_PID=""; DECOY_PID=""

cleanup(){ stop_procs; rm -rf "$ROOT"; }
stop_procs(){
  [ -n "$GENUINE_PID" ] && kill "$GENUINE_PID" 2>/dev/null; wait "$GENUINE_PID" 2>/dev/null
  [ -n "$DECOY_PID" ]   && kill "$DECOY_PID"   2>/dev/null; wait "$DECOY_PID"   2>/dev/null
  GENUINE_PID=""; DECOY_PID=""
}
trap cleanup EXIT

# ── fixtures ──────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$ROOT/stub" "$ROOT/fakebin"
cat > "$ROOT/stub/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
case "${1:-}" in
  api)   [ -n "${GH_SEARCH_RESULT:-}" ] && [ -f "$GH_SEARCH_RESULT" ] && cat "$GH_SEARCH_RESULT"; exit 0;;
  issue) case "${2:-}" in create) echo "https://github.com/${DEADMAN_REPO:-x/y}/issues/4242";; esac; exit 0;;
esac
exit 0
EOF
chmod +x "$ROOT/stub/gh"
export PATH="$ROOT/stub:$PATH"

# The box runs a REAL `pr-poller.sh --watch`, and /proc is shared, so the fixture poller is named
# `fake-poller.sh` and every dm() passes DEADMAN_POLLER_NAME=fake-poller.sh — the deadman then matches
# ONLY the fixture, never the live poller. A fake poller whose cmdline stays `bash …/fake-poller.sh
# --watch` (two statements defeat bash's last-command exec optimization, so the bash process — not an
# exec'd sleep — is the one holding the path).
POLLER_NAME="fake-poller.sh"
cat > "$ROOT/fakebin/$POLLER_NAME" <<'EOF'
#!/bin/bash
sleep 100000 &
wait
EOF
chmod +x "$ROOT/fakebin/$POLLER_NAME"

start_genuine(){ bash "$ROOT/fakebin/$POLLER_NAME" --watch & GENUINE_PID=$!; sleep 0.25; }
# a "similarly-named process": the bare pattern as argv[0], a real sleep — NOT the poller
start_decoy(){ bash -c 'exec -a "fake-poller.sh --watch" sleep 100000' & DECOY_PID=$!; sleep 0.25; }

git_q(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
new_origin_and_clone(){   # $1 = dir stem → creates $1.git (bare origin, main=seed) + $1 (clone at seed)
  local stem="$1"
  git init -q --bare "$stem.git"
  git clone -q "$stem.git" "$stem" 2>/dev/null
  ( cd "$stem" && git -c user.email=t@t -c user.name=t checkout -q -b main 2>/dev/null
    echo seed > seed.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm seed
    git push -q origin main )
}
advance_origin(){   # $1 = dir stem → add one commit to origin/main WITHOUT touching the clone
  local p="$ROOT/pusher.$RANDOM"
  git clone -q "$1.git" "$p" 2>/dev/null
  ( cd "$p" && git checkout -q main 2>/dev/null
    echo "adv $RANDOM" > adv.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm adv
    git push -q origin HEAD:main )
  rm -rf "$p"
}

# freshstate → a clean state dir for a scenario; agelog → set the poller-log mtime.
freshstate(){ local d="$ROOT/state.$RANDOM"; mkdir -p "$d"; printf '%s' "$d"; }
agelog(){ touch -d "@$(( $(date +%s) - ${2:-1000} ))" "$1"; }     # $1=log $2=age-seconds (default 1000)
freshlog(){ : > "$1"; touch "$1"; }

# no_gh_writes → true when EVERY recorded gh call is on the READ allowlist below.
#
# The quiet-when-healthy contract is "the deadman does not FILE/UPDATE/COMMENT/CLOSE an issue unless an
# anomaly stands" — it was written as "the calls file is empty" because the deadman made no gh READS at
# all. The work-progress axis (R18 idle-with-work-pending) adds one: it must read the open-PR state to
# tell a loop that is MOVING from one that is merely RUNNING, and that read happens on every check by
# design. So the row asserts the contract itself rather than the old proxy.
#
# IT IS AN INVERTED ALLOWLIST, NOT A WRITE-DENYLIST. The first cut denied `issue create|edit|comment|
# close` — which is every write the deadman makes TODAY, and therefore reads as sufficient. But the
# invariant being defended is the fleet's deepest one: THE WATCHDOG NEVER MERGES. A denylist grants
# every verb nobody thought to enumerate, so a future `pr merge`, `pr comment`, `api -X POST`, `label
# create` or `pr edit --add-label` from this process would pass the row silently — the sieve shape the
# ANTI-THEATER doctrine rejects. An allowlist fails the other way: a genuinely new READ trips the row
# once and is added deliberately, which is the correct amount of friction for widening what a watchdog
# may do. (It did exactly that on its first run: it surfaced the transitive `gh api
# /installation/repositories` that repo-scope.sh makes on the healthy path — a read the old denylist
# would never have shown anyone.)
#
# THE THREE ALLOWED SHAPES, each a READ and nothing else:
#   `api -X GET …`  the deadman's own issue search (explicit GET)
#   `api /…`        a path with NO -X ⇒ gh's default method is GET (repo-scope's App enumeration).
#                   Deliberately anchored on the leading slash so `api -X POST /repos/…` does NOT match.
#   `pr list …`     the work-progress axis reading open-PR state
# Anything else — including every `pr`/`issue`/`label` MUTATION verb — fails the row.
no_gh_writes(){ ! grep -qvE '^(api -X GET |api /|pr list )' "$GH_CALLS" 2>/dev/null; }

# dm → run one --check with scenario env; captures OUT + RC. Common knobs default here, override via env.
# DEADMAN_POLLER_NAME=fake-poller.sh keeps the deadman blind to the box's REAL running pr-poller.sh.
dm(){   # args: KEY=VAL … (extra env)
  OUT="$(env "$@" \
    DEADMAN_REPO="$DEADMAN_REPO" DEADMAN_TITLE="APPARATUS LIVENESS DEADMAN" \
    DEADMAN_POLLER_NAME="$POLLER_NAME" DEADMAN_GIT_TIMEOUT=15 DEADMAN_GH_TIMEOUT=15 \
    bash "$SCRIPT" --check 2>>"$ROOT/deadman.stderr")"
  RC=$?
}

# ── ANOMALY 1 — MERGED-NOT-LIVE (clean clone behind past the lag grace) ─────────────────────────────
echo "== the four anomalies =="
S="$ROOT/mnl"; new_origin_and_clone "$S"; advance_origin "$S"; ST="$(freshstate)"; : > "$GH_CALLS"
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=1
{ echo "$OUT" | grep -q MERGED_NOT_LIVE && [ "$RC" != 0 ] && grep -q '^issue create' "$GH_CALLS"; } \
  && ok "MERGED_NOT_LIVE fires on a clean behind clone + opens an issue" \
  || bad "MERGED_NOT_LIVE" "rc=$RC out=[$OUT] calls=[$(cat "$GH_CALLS")]"

# ── ANOMALY 2 — SELF-REFRESH BLOCKED (behind AND dirty ⇒ never ff) ──────────────────────────────────
S="$ROOT/srb"; new_origin_and_clone "$S"; advance_origin "$S"; echo dirt > "$S/dirty.txt"; ST="$(freshstate)"; : > "$GH_CALLS"
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=99
{ echo "$OUT" | grep -q SELF_REFRESH_BLOCKED && echo "$OUT" | grep -q 'dirty.txt' && [ "$RC" != 0 ]; } \
  && ok "SELF_REFRESH_BLOCKED fires immediately on a dirty+behind clone, naming the dirty path" \
  || bad "SELF_REFRESH_BLOCKED" "rc=$RC out=[$OUT]"

# ── ANOMALY 3 — POLLER FROZEN (alive but log mtime stale) ───────────────────────────────────────────
S="$ROOT/frz"; new_origin_and_clone "$S"; ST="$(freshstate)"; LOG="$ROOT/frozen.log"; freshlog "$LOG"; agelog "$LOG" 1000
: > "$GH_CALLS"; start_genuine
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=1 DEADMAN_POLLER_LOG="$LOG" DEADMAN_SWEEP_MAX=300
{ echo "$OUT" | grep -q POLLER_FROZEN && [ "$RC" != 0 ]; } \
  && ok "POLLER_FROZEN fires when a live poller's log has not advanced" \
  || bad "POLLER_FROZEN" "rc=$RC out=[$OUT]"
stop_procs

# ── ANOMALY 4 — POLLER DOWN (no --watch process at all) ─────────────────────────────────────────────
S="$ROOT/down"; new_origin_and_clone "$S"; ST="$(freshstate)"; : > "$GH_CALLS"
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=1 DEADMAN_POLLER_LOG="$ROOT/none.log"
{ echo "$OUT" | grep -q POLLER_DOWN && [ "$RC" != 0 ]; } \
  && ok "POLLER_DOWN fires when no pr-poller.sh --watch process exists" \
  || bad "POLLER_DOWN" "rc=$RC out=[$OUT]"

# ── ALL-HEALTHY ⇒ ZERO gh writes ────────────────────────────────────────────────────────────────────
echo "== quiet-when-healthy, dedup, clear =="
S="$ROOT/ok"; new_origin_and_clone "$S"; ST="$(freshstate)"; LOG="$ROOT/ok.log"; freshlog "$LOG"
: > "$GH_CALLS"; start_genuine
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=1 DEADMAN_POLLER_LOG="$LOG" DEADMAN_SWEEP_MAX=300
{ [ "$RC" = 0 ] && echo "$OUT" | grep -q '^HEALTHY' && no_gh_writes; } \
  && ok "all-healthy (current clone, live poller, fresh log) ⇒ rc 0 and ZERO gh writes" \
  || bad "healthy-quiet" "rc=$RC out=[$OUT] calls=[$(cat "$GH_CALLS")]"
stop_procs

# ── DEDUP — two anomalies ⇒ ONE issue, UPDATED (never a second create) ──────────────────────────────
S="$ROOT/dup"; new_origin_and_clone "$S"; advance_origin "$S"; ST="$(freshstate)"; : > "$GH_CALLS"
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=1
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=1
c_create="$(grep -c '^issue create' "$GH_CALLS")"; c_edit="$(grep -c '^issue edit' "$GH_CALLS")"
{ [ "$c_create" = 1 ] && [ "$c_edit" -ge 1 ]; } \
  && ok "dedup: two anomalies ⇒ exactly ONE create + an in-place update (edit)" \
  || bad "dedup" "creates=$c_create edits=$c_edit calls=[$(cat "$GH_CALLS")]"

# ── HEALTHY-AFTER-ANOMALY ⇒ cleared + closed ────────────────────────────────────────────────────────
S="$ROOT/clr"; new_origin_and_clone "$S"; advance_origin "$S"; ST="$(freshstate)"; : > "$GH_CALLS"
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=1   # anomaly → creates 4242
git_q "$S" pull -q origin main 2>/dev/null    # operator/supervisor fixes it: clone catches up
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=1   # now healthy
{ [ "$RC" = 0 ] && grep -q '^issue comment 4242' "$GH_CALLS" && grep -q '^issue close 4242' "$GH_CALLS"; } \
  && ok "healthy-after-anomaly ⇒ posts a cleared comment + closes the issue" \
  || bad "clear-on-heal" "rc=$RC calls=[$(cat "$GH_CALLS")]"

# ── SELF-MATCH — the decoy does NOT trip poller-alive ───────────────────────────────────────────────
echo "== self-match safety =="
S="$ROOT/decoy"; new_origin_and_clone "$S"; ST="$(freshstate)"; : > "$GH_CALLS"
start_decoy   # a bare-string look-alike, NO genuine poller running
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=1 DEADMAN_POLLER_LOG="$ROOT/none.log"
{ echo "$OUT" | grep -q POLLER_DOWN; } \
  && ok "the SELF-MATCH decoy does NOT fool poller-alive (POLLER_DOWN still fires)" \
  || bad "self-match-decoy" "the decoy was mistaken for the poller — out=[$OUT]"
stop_procs

# ── THE DEADMAN NEVER WRITES THE CLONE (HEAD + status unchanged after a check) ──────────────────────
echo "== read-only: the deadman never writes the clone =="
S="$ROOT/ro"; new_origin_and_clone "$S"; advance_origin "$S"; echo dirt > "$S/dirty.txt"; ST="$(freshstate)"
head_before="$(git -C "$S" rev-parse HEAD)"; status_before="$(git -C "$S" status --porcelain)"
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=1
head_after="$(git -C "$S" rev-parse HEAD)"; status_after="$(git -C "$S" status --porcelain)"
{ [ "$head_before" = "$head_after" ] && [ "$status_before" = "$status_after" ]; } \
  && ok "clone HEAD + working-tree status are BYTE-IDENTICAL after a check (no pull/merge/checkout)" \
  || bad "read-only" "HEAD $head_before→$head_after  status changed"

# ── UNREADABLE surfaces ONLY after the consecutive bound ────────────────────────────────────────────
echo "== fail-toward-surfacing: unreadable only after the bound =="
S="$ROOT/unr"; new_origin_and_clone "$S"; git -C "$S" remote set-url origin /nonexistent/nope.git
ST="$(freshstate)"; : > "$GH_CALLS"
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_UNREADABLE_MAX=2   # check 1
r1_rc="$RC"; r1_cv=0; echo "$OUT" | grep -q CANNOT_VERIFY && r1_cv=1
r1_empty=1; no_gh_writes || r1_empty=0                                                        # no gh write on the blip
dm DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_UNREADABLE_MAX=2   # check 2 → bound
{ [ "$r1_cv" = 0 ] && [ "$r1_rc" = 0 ] && [ "$r1_empty" = 1 ] \
  && echo "$OUT" | grep -q CANNOT_VERIFY && [ "$RC" != 0 ] && grep -q '^issue create' "$GH_CALLS"; } \
  && ok "one unreadable check stays quiet (no gh); the SECOND (>= bound) surfaces CANNOT_VERIFY" \
  || bad "unreadable-bound" "check1 rc=$r1_rc cv=$r1_cv empty=$r1_empty ; check2 rc=$RC out=[$OUT]"

# ── MUTATION-CHECK 1 — neutralize the lag gate ⇒ merged-not-live stops firing ───────────────────────
echo "== work-progress axis: PARKED work is filtered OUT of the fingerprint (the WIRING) =="
# --selftest already proves work_drivable DECIDES correctly. It cannot prove work_fingerprint CALLS it,
# and a correct pure core wired to nothing is the exact defect this apparatus has shipped before. These
# rows drive the real --work-fingerprint seam against a stub `gh pr list` and read the emitted lines.
cat > "$ROOT/stub/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
case "${1:-} ${2:-}" in
  "pr list") cat "${FAKE_PRS:-/dev/null}" 2>/dev/null; exit 0;;
esac
case "${1:-}" in
  api)   [ -n "${GH_SEARCH_RESULT:-}" ] && [ -f "$GH_SEARCH_RESULT" ] && cat "$GH_SEARCH_RESULT"; exit 0;;
  issue) case "${2:-}" in create) echo "https://github.com/${DEADMAN_REPO:-x/y}/issues/4242";; esac; exit 0;;
esac
exit 0
EOF
chmod +x "$ROOT/stub/gh"
export FAKE_PRS="$ROOT/prs.txt"
fp(){ : > "$GH_CALLS"; WFP="$(DEADMAN_WORK_REPOS=e2e-beta bash "$SCRIPT" --work-fingerprint 2>/dev/null)"; }

printf '%s\n' 'e2e-beta#9 abc123def456 0 live-validate' > "$FAKE_PRS"; fp
{ echo "$WFP" | grep -q 'e2e-beta#9'; } \
  && ok "a drivable PR IS in the fingerprint (the axis still sees real work)" \
  || bad "fp-drivable" "wfp=[$WFP]"

# The false-fire the axis would otherwise commit: a PR correctly held for the maintainer is static for
# as long as the human takes, so left in the fingerprint it would SIGTERM a healthy poller after 45 min
# and then page the very person being waited on.
printf '%s\n' 'e2e-beta#9 abc123def456 0 maintainer-merge' > "$FAKE_PRS"; fp
{ [ -z "$WFP" ]; } \
  && ok "an R1 maintainer-merge PR is FILTERED OUT (no false stall on work waiting by design)" \
  || bad "fp-parked-r1" "wfp=[$WFP]"

printf '%s\n' 'e2e-beta#9 abc 0 escalate' 'e2e-beta#10 def 1 live-validate' > "$FAKE_PRS"; fp
{ ! echo "$WFP" | grep -q '#9' && echo "$WFP" | grep -q '#10'; } \
  && ok "mixed: the escalated PR drops out, the drivable one stays" \
  || bad "fp-mixed" "wfp=[$WFP]"

printf '%s\n' 'e2e-beta#9 abc 0 apparatus-blocked,live-validate' > "$FAKE_PRS"; fp
{ [ -z "$WFP" ]; } \
  && ok "a parked label anywhere in the list parks the PR" || bad "fp-parked-multi" "wfp=[$WFP]"

printf '%s\n' 'e2e-beta#9 abc123def456 0 ' > "$FAKE_PRS"; fp
{ echo "$WFP" | grep -q 'e2e-beta#9'; } \
  && ok "an UNLABELLED PR survives the filter (it is drivable, and the trailing-space field is empty)" \
  || bad "fp-unlabelled" "wfp=[$WFP]"

# A GitHub label may legally contain SPACES — a stock repo ships `good first issue` and `help wanted`.
# Reading only the LAST space-separated field would see "issue" here and miss the parked label entirely.
printf '%s\n' 'e2e-beta#9 abc 0 awaiting-maintainer,good first issue' > "$FAKE_PRS"; fp
{ [ -z "$WFP" ]; } \
  && ok "a parked label survives a SPACE-containing sibling label (fields, not last-token)" \
  || bad "fp-spacey-label" "wfp=[$WFP]"

# MUTATION: neutralize the filter in a copy and the parked PR must reappear — otherwise the rows above
# pass for some reason other than the filter.
MUTD="$ROOT/dm-mut.sh"
sed 's|^    work_drivable "\$_l" "\$parked" && printf|    true "$_l" "$parked" \&\& printf|' "$SCRIPT" > "$MUTD"
if ! grep -q '^    true "\$_l" "\$parked" && printf' "$MUTD" || ! bash -n "$MUTD" 2>/dev/null; then
  bad "fp-mutation-vacuous" "the sed did not neutralize the filter"
else
  cp "$MUTD" "$HERE/bin/.dm-mut-tmp.sh"; chmod +x "$HERE/bin/.dm-mut-tmp.sh"   # needs its bin/ siblings
  printf '%s\n' 'e2e-beta#9 abc 0 maintainer-merge' > "$FAKE_PRS"
  MW="$(DEADMAN_WORK_REPOS=e2e-beta bash "$HERE/bin/.dm-mut-tmp.sh" --work-fingerprint 2>/dev/null)"
  rm -f "$HERE/bin/.dm-mut-tmp.sh"
  { echo "$MW" | grep -q 'e2e-beta#9'; } \
    && ok "MUTATION BITES: without the filter the parked PR is back in the fingerprint (false-fire restored)" \
    || bad "fp-mutation-no-bite" "mutant wfp=[$MW]"
fi

echo "== mutation-checks (grep-verified non-vacuous) =="
CP="$ROOT/mut-lag.sh"
sed 's/\[ "\$lag_streak" -ge "\$lag_max" \]/[ "$lag_streak" -ge 999999 ]/' "$SCRIPT" > "$CP"; chmod +x "$CP"
if grep -qF '[ "$lag_streak" -ge 999999 ]' "$CP" && ! grep -qF '[ "$lag_streak" -ge 999999 ]' "$SCRIPT"; then
  S="$ROOT/mut1"; new_origin_and_clone "$S"; advance_origin "$S"; ST="$(freshstate)"
  # baseline: the ORIGINAL fires
  OUT_o="$(env DEADMAN_CLONE="$S" DEADMAN_STATE="$(freshstate)" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=1 \
             DEADMAN_REPO="$DEADMAN_REPO" bash "$SCRIPT" --check 2>/dev/null)"
  # mutant: merged-not-live must STOP firing
  OUT_m="$(env DEADMAN_CLONE="$S" DEADMAN_STATE="$ST" DEADMAN_EXPECT_POLLER=0 DEADMAN_LAG_MAX=1 \
             DEADMAN_REPO="$DEADMAN_REPO" bash "$CP" --check 2>/dev/null)"
  { echo "$OUT_o" | grep -q MERGED_NOT_LIVE && ! echo "$OUT_m" | grep -q MERGED_NOT_LIVE; } \
    && ok "neutralizing the lag gate makes MERGED_NOT_LIVE stop firing (row is non-vacuous)" \
    || bad "mutation-lag" "orig=[$OUT_o] mutant=[$OUT_m]"
else
  bad "mutation-lag" "the sed did not change the copy — vacuous"
fi

# ── MUTATION-CHECK 2 — neutralize the self-match exclusion ⇒ the decoy trips it ─────────────────────
CP2="$ROOT/mut-self.sh"
# the self-match guard now lives in poller_pids (the ONE detector poller_alive + the responder share);
# neutralize its slash-anchor exactly as before, just on the printf-emitting line.
sed 's#\*/\$DEADMAN_POLLER_NAME\*--watch\*) printf#*$DEADMAN_POLLER_NAME*--watch*) printf#' "$SCRIPT" > "$CP2"; chmod +x "$CP2"
if grep -qF '*$DEADMAN_POLLER_NAME*--watch*) printf' "$CP2" && ! grep -qF '*$DEADMAN_POLLER_NAME*--watch*) printf' "$SCRIPT"; then
  S="$ROOT/mut2"; new_origin_and_clone "$S"; freshlog "$ROOT/mut2.log"; : > "$GH_CALLS"
  start_decoy   # decoy running, NO genuine poller
  OUT_o="$(env DEADMAN_CLONE="$S" DEADMAN_STATE="$(freshstate)" DEADMAN_EXPECT_POLLER=1 \
             DEADMAN_POLLER_NAME="$POLLER_NAME" DEADMAN_POLLER_LOG="$ROOT/mut2.log" DEADMAN_SWEEP_MAX=300 \
             DEADMAN_REPO="$DEADMAN_REPO" bash "$SCRIPT" --check 2>/dev/null)"   # original: decoy ignored ⇒ POLLER_DOWN
  OUT_m="$(env DEADMAN_CLONE="$S" DEADMAN_STATE="$(freshstate)" DEADMAN_EXPECT_POLLER=1 \
             DEADMAN_POLLER_NAME="$POLLER_NAME" DEADMAN_POLLER_LOG="$ROOT/mut2.log" DEADMAN_SWEEP_MAX=300 \
             DEADMAN_REPO="$DEADMAN_REPO" bash "$CP2" --check 2>/dev/null)"       # mutant: decoy counted alive ⇒ no POLLER_DOWN
  stop_procs
  { echo "$OUT_o" | grep -q POLLER_DOWN && ! echo "$OUT_m" | grep -q POLLER_DOWN; } \
    && ok "neutralizing the slash-anchored self-match guard lets the decoy trip poller-alive (non-vacuous)" \
    || bad "mutation-self" "orig=[$OUT_o] mutant=[$OUT_m]"
else
  bad "mutation-self" "the sed did not change the copy — vacuous"
fi

echo
echo "apparatus-deadman.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
