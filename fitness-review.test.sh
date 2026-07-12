#!/usr/bin/env bash
# fitness-review.test.sh — the FITNESS GATE's TRANSPORT + FAILURE-HONESTY suite (#155). ZERO GitHub /
# network / model.
#
# WHY THIS EXISTS: bin/fitness-review.sh handed the reviewer its prompt as ONE argv argument. Linux caps
# a SINGLE argv argument at MAX_ARG_STRLEN (32 pages = 131072 bytes) — independently of the far larger
# total ARG_MAX — so any PR whose prompt crossed ~128 KiB failed to EXEC with E2BIG and the reviewer
# NEVER RAN (measured in-box: #154, 141078 diff bytes). Its stderr was discarded, so the harness then
# blamed the MODEL ("produced no sanctioned FITNESS_VERDICT line") for a failure of its own transport,
# and the poller re-attempted it every 10 s, forever, in silence. Three defects, one door.
#
# HOW IT BITES — the fixture is real where it must be:
#   * The prompt sizes are REAL: rows drive the REAL bin/fitness-review.sh with a diff big enough that
#     an argv prompt CANNOT EXEC on this kernel. The reviewer is a stub that asserts on the bytes it
#     ACTUALLY RECEIVED (head + tail sentinels, byte count, and which CHANNEL they came on) — not a mock
#     that never exercises the transport.
#   * MUTATION ROW, RUN IN-SUITE: the argv form is mechanically restored (a sed on a copy, which must
#     genuinely change the file, else the row fails as vacuous) and the mutant is EXECUTED. It must
#     produce NO verdict and leave the reviewer's inbox EMPTY. Restoring the argv form fails this suite.
#   * The three failure events (could-not-exec / non-zero exit / ran-but-no-verdict) are asserted to
#     produce THREE DIFFERENT log lines, each carrying the reviewer's own stderr — a harness that says
#     "the reviewer produced no verdict" when the reviewer never ran is lying to its operator.
#   * The poller's REVIEW arm is driven for real (bin/pr-poller.sh --once, twice) against a scripted
#     reviewer outcome: rc 3 must SURFACE the cause and PARK the head; rc 1 (a retryable precondition)
#     must do NEITHER — the discriminator that proves the park is bound to the un-runnable reviewer and
#     not to "any failure".
#
# Run:  bash fitness-review.test.sh   → exit 0 = all rows pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FITNESS="$HERE/bin/fitness-review.sh"
POLLER="$HERE/bin/pr-poller.sh"
[ -f "$FITNESS" ] || { echo "FATAL: bin/fitness-review.sh not found"; exit 2; }
[ -f "$POLLER" ]  || { echo "FATAL: bin/pr-poller.sh not found"; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
SHA=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee          # a full 40-hex head, as the gates bind to
MAXARG=$(( $(getconf PAGESIZE) * 32 ))                # the ceiling the old transport hit: 131072

pass=0; fail=0
ck(){ [ "$1" = 1 ] && return 0; fail=$((fail+1)); printf '  FAIL %s: %s\n' "$DESC" "$2"; OK=0; }
done_case(){ [ "$OK" = 1 ] && { pass=$((pass+1)); printf '  ok   %s\n' "$DESC"; }; }

# ---- stub gh: serve one PR + a diff of our choosing; log every outward write. Never touches GitHub. --
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr diff"*)          cat "$DIFF_FILE";;
  *"--json author"*)    printf 'someone-else\n';;
  *"--json headRefOid"*) printf '%s\n' "$FAKE_SHA";;
  *"--json title"*)     printf 'a change\n';;
  *"--json body"*)      printf 'the PR body\n';;
  *"pr comment"*)       printf 'POSTED %s\n' "$*" >> "$ACT_LOG";;
  *)                    printf 'GH %s\n' "$*" >> "$ACT_LOG";;
esac
exit 0
EOF

# ---- stub reviewer: records the prompt it ACTUALLY received, and on WHICH channel. -----------------
# This is the whole point: it asserts on the transport, not on a mock of it.
cat > "$BIN/reviewer" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$*" > "$RECV_ARGV"
case "${FAKE_REVIEWER:-pass}" in
  crash)   # exits WITHOUT draining stdin — proves $rc is the REVIEWER's own (7), not a printf SIGPIPE
           # (141) masquerading as it. A real auth failure looks exactly like this.
           echo "gh-auth: token expired; not logged in" >&2; exit 7;;
esac
cat > "$RECV"                                   # the real `claude -p` reads its prompt from stdin
case "${FAKE_REVIEWER:-pass}" in
  pass)      echo "Q1 fine. Q2 fine. Q3 fine."; echo "FITNESS_VERDICT: PASS";;
  noverdict) echo "I read it and I am honestly not sure what to say here.";;
  silent)    : ;;                               # exits 0, says NOTHING at all
esac
exit 0
EOF
chmod +x "$BIN"/*

# gen_diff <total-bytes> <file> — an EXACTLY-sized fake diff, sentinel-bracketed so a row can prove the
# FIRST and the LAST byte both reached the reviewer (i.e. nothing was silently dropped or truncated).
gen_diff(){
  local n="$1" f="$2" h='DIFFHEAD_SENTINEL' t='DIFFTAIL_SENTINEL'
  { printf '%s\n' "$h"; head -c "$(( n - ${#h} - ${#t} - 2 ))" /dev/zero | tr '\0' x; printf '%s\n' "$t"; } > "$f"
  [ "$(wc -c < "$f")" -eq "$n" ] || { echo "FATAL: fixture is not $n bytes"; exit 2; }
}

# review <script> [env…] — run a fitness harness (the real one, or a mutant) in DRY-RUN on the fixture.
review(){
  local script="$1"; shift
  RECV="$CASE/received.txt"; RECV_ARGV="$CASE/received-argv.txt"; : > "$RECV"; : > "$RECV_ARGV"
  # shellcheck disable=SC2086
  env PATH="$BIN:$PATH" HOME="$CASE/home" ACT_LOG="$ACT_LOG" DIFF_FILE="$DIFF" FAKE_SHA="$SHA" \
      RECV="$RECV" RECV_ARGV="$RECV_ARGV" \
      FITNESS_CLAUDE="reviewer -p" FITNESS_LOGIN=fit-bot LG_HOST_LOGIN= "$@" \
      bash "$script" fedora-dev 1 > "$CASE/out.log" 2> "$CASE/err.log"
  RC=$?
}
setup_case(){ CASE="$ROOT/c$RANDOM"; mkdir -p "$CASE/home"; ACT_LOG="$CASE/act.log"; : > "$ACT_LOG"
              DIFF="$CASE/diff.txt"; }
got_bytes(){ wc -c < "$RECV" | tr -d ' '; }
saw(){    ck "$(grep -q "$1" "$CASE/err.log" "$CASE/out.log" && echo 1 || echo 0)" "the harness never said [$1]"; }
notsaw(){ ck "$(grep -q "$1" "$CASE/err.log" "$CASE/out.log" && echo 0 || echo 1)" "the harness wrongly said [$1]"; }
posted_nothing(){ ck "$(grep -q '^POSTED' "$ACT_LOG" && echo 0 || echo 1)" "it POSTED a comment on a failed review — the gate must stay NONE (fail-closed)"; }

# ===================================================================================================
echo "== TRANSPORT: a prompt LARGER than MAX_ARG_STRLEN reaches the reviewer INTACT and is reviewed =="
DESC="a 150000-byte diff (>128 KiB: the argv ceiling) is actually reviewed"; OK=1
setup_case; gen_diff 150000 "$DIFF"
review "$FITNESS"
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)" "the harness did not succeed (rc=$RC) — the reviewer never got its prompt"
ck "$([ "$(got_bytes)" -gt "$MAXARG" ] && echo 1 || echo 0)" "the reviewer received $(got_bytes) bytes, not more than MAX_ARG_STRLEN ($MAXARG) — this row would not have caught the defect"
ck "$(grep -q DIFFHEAD_SENTINEL "$RECV" && echo 1 || echo 0)" "the START of the diff never reached the reviewer"
ck "$(grep -q DIFFTAIL_SENTINEL "$RECV" && echo 1 || echo 0)" "the END of the diff never reached the reviewer (silently truncated)"
ck "$(grep -qx '\-p' "$RECV_ARGV" && echo 1 || echo 0)" "the prompt rode ARGV ($(wc -c < "$RECV_ARGV") bytes of it) — that is the E2BIG defect"
saw 'VERDICT PASS'
done_case

echo "== THE CAP SITS BELOW THE CEILING IT PROTECTS: the transport carries the FULL default cap =="
DESC="a diff at the DEFAULT FITNESS_DIFF_CAP is carried whole, un-truncated"; OK=1
setup_case
# read the shipped default out of the script — the row and the default can never drift apart
CAP="$(sed -n 's/^FITNESS_DIFF_CAP="\${FITNESS_DIFF_CAP:-\([0-9]*\)}"$/\1/p' "$FITNESS")"
ck "$([ -n "$CAP" ] && echo 1 || echo 0)" "could not read the shipped FITNESS_DIFF_CAP default"
gen_diff "$CAP" "$DIFF"
review "$FITNESS"                                   # NB: FITNESS_DIFF_CAP deliberately unset → the default
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)" "a diff at the DEFAULT cap ($CAP) could not be reviewed (rc=$RC) — the cap is above the ceiling the transport can carry"
ck "$([ "$(got_bytes)" -ge "$CAP" ] && echo 1 || echo 0)" "the reviewer received only $(got_bytes) of the $CAP-byte cap"
ck "$(grep -q DIFFTAIL_SENTINEL "$RECV" && echo 1 || echo 0)" "the last byte of a cap-sized diff never arrived"
notsaw 'TRUNCATING'
done_case

echo "== MUTATION: restore the argv form → E2BIG, no verdict, the reviewer never even runs =="
DESC="the argv-passing form makes this suite FAIL (the mutation is run, not asserted)"; OK=1
setup_case; gen_diff 150000 "$DIFF"
MUT="$CASE/fitness-argv.sh"
sed 's@set +o pipefail; printf .%s. "$PROMPT" | $FITNESS_CLAUDE @$FITNESS_CLAUDE "$PROMPT" @' "$FITNESS" > "$MUT"
ck "$(cmp -s "$FITNESS" "$MUT" && echo 0 || echo 1)" "the mutation changed NOTHING — this row is vacuous and proves nothing"
review "$MUT"
ck "$([ "$RC" != 0 ] && echo 1 || echo 0)" "the argv form produced a verdict — the transport ceiling is not being exercised"
ck "$([ "$(got_bytes)" -eq 0 ] && echo 1 || echo 0)" "the argv form somehow delivered the prompt — the fixture is not past MAX_ARG_STRLEN"
notsaw 'VERDICT PASS'
posted_nothing
done_case

echo "== HONESTY 1/3: the reviewer CANNOT RUN (non-zero exit) → says so, with ITS stderr; never 'no verdict' =="
DESC="an exec/auth failure is reported as a failure TO RUN, carrying the reviewer's own stderr"; OK=1
setup_case; gen_diff 20000 "$DIFF"
review "$FITNESS" FAKE_REVIEWER=crash
ck "$([ "$RC" = 3 ] && echo 1 || echo 0)" "rc=$RC, want 3 (the 'reviewer could not produce a verdict' class the poller must SURFACE)"
saw 'FAILED TO RUN'
saw 'exited 7'                                      # the REVIEWER's own rc — not a printf SIGPIPE (141)
saw 'token expired'                                 # its stderr is REPORTED, never discarded
notsaw 'no sanctioned FITNESS_VERDICT line'         # the lie this change exists to stop telling
posted_nothing
done_case

echo "== HONESTY 2/3: the reviewer RAN, exited 0, said NOTHING → a THIRD, distinct line =="
DESC="an empty reply is not confused with a failure to run"; OK=1
setup_case; gen_diff 20000 "$DIFF"
review "$FITNESS" FAKE_REVIEWER=silent
ck "$([ "$RC" = 3 ] && echo 1 || echo 0)" "rc=$RC, want 3"
saw 'NO OUTPUT AT ALL'
notsaw 'FAILED TO RUN'
posted_nothing
done_case

echo "== HONESTY 3/3: the reviewer RAN and replied, but emitted no verdict token =="
DESC="a real reply without a verdict is reported as exactly that"; OK=1
setup_case; gen_diff 20000 "$DIFF"
review "$FITNESS" FAKE_REVIEWER=noverdict
ck "$([ "$RC" = 3 ] && echo 1 || echo 0)" "rc=$RC, want 3"
saw 'NO sanctioned FITNESS_VERDICT line'
notsaw 'FAILED TO RUN'; notsaw 'NO OUTPUT AT ALL'
posted_nothing
done_case

echo "== TRUNCATION IS EXPLICIT: the reviewer is TOLD it is judging a partial diff, and the verdict says so =="
DESC="a truncated diff is announced — in the log, in the prompt, and on the verdict comment"; OK=1
setup_case; gen_diff 20000 "$DIFF"
review "$FITNESS" FITNESS_DIFF_CAP=5000
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)" "the harness failed (rc=$RC)"
saw 'TRUNCATING'                                                    # the OPERATOR is told
ck "$(grep -q 'DIFF TRUNCATED' "$RECV" && echo 1 || echo 0)" "the REVIEWER was handed a truncated diff and never told — it could PASS on code it never saw"
ck "$(grep -q 'ESCALATE' "$RECV" && echo 1 || echo 0)" "the reviewer was not told to ESCALATE when the hidden part decides it"
ck "$(grep -q 'TRUNCATED' "$CASE/out.log" && echo 1 || echo 0)" "the posted verdict does not disclose that it judged a partial diff"
# NON-GOAL GUARD: the verdict grammar and the line-1 sha-binding (G2) are untouched by all of this.
ck "$(grep -qx "Fitness review: VERDICT PASS — head $SHA" "$CASE/out.log" && echo 1 || echo 0)" "line 1 of the verdict comment changed — the grammar/sha-binding is a NON-GOAL and must be byte-stable"
done_case

# ===================================================================================================
# The poller's REVIEW arm: a reviewer that cannot run must SURFACE, not spin (#155 R4 / #150 R4).
# ===================================================================================================
cat > "$BIN/gh-poller" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    case "$*" in
      *"--state merged"*) : ;;
      *"--state open"*)   printf '%s\t%s\t%s\n' 1 feat/x "$FAKE_SHA";;
    esac ;;
  "pr view")
    case "$*" in
      *host-bot*)        printf '**Host live-gate (Gate B): VERDICT GREEN** — fedora-dev @ %s\n' "$FAKE_SHA";;
      *fit-bot*)         : ;;                               # no fitness verdict yet → plan()=REVIEW
      *"--json files"*)  printf 'README.md\n';;
    esac ;;
  # flattened to ONE line: a surfaced question is multi-line (it quotes the reviewer's stderr), and the
  # rows below assert BOTH the ask and its cause — and COUNT the questions (one per head, not per sweep).
  "pr comment") printf 'SURFACE %s\n' "$(printf '%s' "$*" | tr '\n' ' ')" >> "$ACT_LOG";;
  *)            printf 'GH %s\n' "$*" >> "$ACT_LOG";;
esac
exit 0
EOF
cat > "$BIN/fitness-stub" <<'EOF'
#!/usr/bin/env bash
printf 'FITNESSRUN %s\n' "$*" >> "$ACT_LOG"
echo "[fitness] reviewer FAILED TO RUN: 'claude -p' exited 126 — Argument list too long" >&2
exit "${FAKE_FITRC:-3}"
EOF
chmod +x "$BIN"/*

poller_sweep(){ # runs one --once sweep against the same fake HOME (state persists across sweeps)
  env PATH="$BIN:$PATH" HOME="$CASE/home" ACT_LOG="$ACT_LOG" FAKE_SHA="$SHA" \
      POLLER_REPOS=fedora-dev POLLER_REPO=fedora-dev POLLER_ARMED=0 \
      LG_HOST_LOGIN=host-bot FITNESS_LOGIN=fit-bot FITNESS_REVIEW="$BIN/fitness-stub" \
      FAKE_FITRC="$1" bash "$POLLER" --once >> "$CASE/out.log" 2>&1
}
setup_poller_case(){ setup_case; cp "$BIN/gh-poller" "$BIN/gh"; }
restore_gh(){ :; }   # each case re-copies the stub it needs
runs(){ grep -c '^FITNESSRUN' "$ACT_LOG" 2>/dev/null || true; }

echo "== R4: a reviewer that cannot run SURFACES the real cause — ONCE — and the head is PARKED =="
DESC="an un-runnable review surfaces and stops; it does not re-spin every sweep"; OK=1
setup_poller_case
poller_sweep 3
poller_sweep 3                                        # a second sweep: the silent-spin the defect caused
ck "$(grep -q '^SURFACE.*could not produce a verdict' "$ACT_LOG" && echo 1 || echo 0)" "the poller never surfaced the failed review — it would spin at sweep cadence with no signal"
ck "$(grep -q '^SURFACE.*Argument list too long' "$ACT_LOG" && echo 1 || echo 0)" "the surfaced question does not carry the reviewer's REAL cause (its stderr)"
ck "$([ "$(grep -c '^SURFACE' "$ACT_LOG")" -eq 1 ] && echo 1 || echo 0)" "the poller surfaced $(grep -c '^SURFACE' "$ACT_LOG") times — a question must be asked once per head, not per sweep"
ck "$([ "$(runs)" -eq 1 ] && echo 1 || echo 0)" "the reviewer was re-run $(runs) times — an un-runnable review must NOT re-spend a bounded model run every sweep"
ck "$(grep -q 'acted, parked' "$CASE/out.log" && echo 1 || echo 0)" "the head was not parked after the question was surfaced"
done_case

echo "== DISCRIMINATOR: a RETRYABLE precondition (rc 1) neither surfaces NOR parks — it retries =="
DESC="the park is bound to the un-runnable reviewer (rc 3), not to 'any failure'"; OK=1
setup_poller_case
poller_sweep 1
poller_sweep 1
ck "$(grep -q '^SURFACE' "$ACT_LOG" && echo 0 || echo 1)" "a retryable precondition surfaced a question to a human — that is noise, not signal"
ck "$([ "$(runs)" -eq 2 ] && echo 1 || echo 0)" "the reviewer ran $(runs) times, want 2 — a retryable refusal must be retried next sweep"
done_case

echo
echo "fitness-review: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
