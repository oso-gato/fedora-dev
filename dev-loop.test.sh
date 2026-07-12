#!/usr/bin/env bash
# dev-loop.test.sh — MOCK dry-run of bin/dev-loop.sh: stubs gh + dev-author on PATH and asserts the
# driver enumerates the backlog and invokes the author once per issue, continuing past a stuck one —
# plus the invariants that actually carry the design: an in-flight skip costs NO cap slot (so the tail of
# the backlog is never starved), an issue that surfaced a question is PARKED rather than re-asked, and —
# the point of the no-local-state rewrite — that parking is DERIVED FROM THE BUS, so it survives a box
# that is killed and wiped (spec #135 R14's E2E-KILL: resume from the bus alone).
#
# THE STUB MODELS THE BUS, NOT A SHORTCUT. GitHub's comment stream is the state, so the fake gh keeps a
# per-issue comment STORE: the fake dev-author POSTS its dev-task question into it exactly as the real
# surface_blocked() does (same machine-owned line-1 anchor, same App identity), and `gh issue list` serves
# each issue's NEWEST comment back to the driver. A stub that just answered "parked: yes/no" would prove
# nothing about the derivation — this one makes the driver re-read its own question off the bus.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOOP="$HERE/bin/dev-loop.sh"
AUTHOR="$HERE/bin/dev-author.sh"
[ -f "$LOOP" ] || { echo "FATAL: bin/dev-loop.sh not found"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
export DEV_LOGIN="${DEV_LOGIN:-oso-gato-nox-claudebox}"

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
      else fail=$((fail+1)); printf '  FAIL %s\n       got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }

# --- CONTRACT WITH dev-author (the whole park gate rests on it) --------------------------------------
# The park state is derived from the line-1 anchor of dev-author's BLOCKED comment. dev-loop hard-codes
# that anchor, so a REWORD on the author side would silently un-park every blocked issue and set the loop
# re-asking the same question forever. Pin all three copies together: the literal below must still be in
# bin/dev-author.sh, and the mock BELOW posts exactly it — so the PARKED rows fail the moment either side
# drifts. (Same lockstep discipline as health-marker.test.sh's two health predicates.)
ANCHOR='**dev-author → needs a decision (BLOCKED):**'
echo "== the anchor dev-loop parks on is the one dev-author actually posts =="
if [ -f "$AUTHOR" ]; then
  grep -qF -- "$ANCHOR" "$AUTHOR" && ck "bin/dev-author.sh still emits the line-1 BLOCKED anchor" yes yes \
                                  || ck "bin/dev-author.sh still emits the line-1 BLOCKED anchor" no yes
else
  ck "bin/dev-author.sh present to check the anchor against" missing present
fi
grep -qF -- 'dev-author → needs a decision' "$LOOP" \
  && ck "bin/dev-loop.sh parks on that same anchor" yes yes \
  || ck "bin/dev-loop.sh parks on that same anchor" no yes

# --- gh stub: the BUS ---------------------------------------------------------------------------------
# `issue list --json number,comments` → one TSV row per backlog issue: number, NEWEST comment's author,
# NEWEST comment's line 1 (empty fields when the issue has no comments) — the exact shape the real jq
# emits. STORE/<n> is the issue's comment stream, appended to by whoever "comments".
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "issue list")
    for n in ${FAKE_BACKLOG:-}; do
      f="$STORE/$n"
      if [ -s "$f" ]; then tail -1 "$f" | sed "s|^|$n\t|"; else printf '%s\t\t\n' "$n"; fi
    done ;;
  *) : ;;
esac
exit 0
EOF
# dev-author stub — mirrors the REAL (rc, stdout, comment) contract the driver depends on:
#   FAKE_AUTHOR_SKIP list → guard no-op: rc 0, NOTHING on stdout, no comment (already authored / PR in flight)
#   FAKE_AUTHOR_FAIL      → rc 4: BLOCKED — and, like the real surface_blocked(), it POSTS the question
#   FAKE_AUTHOR_RC=<n>:<rc> → issue <n> exits <rc>. The REAL dev-author calls surface_blocked() on rc 3
#                           (worktree), 7 (push) and 8 (PR-create) too, not just 4|5|6 — so the stub posts
#                           a question for ALL of those. rc 2 (unreadable issue) is the ONE code that fails
#                           closed BEFORE it can comment: it posts NOTHING, and so must never park.
#   FAKE_POST_FAILS       → rc 4 but the comment POST fails (best-effort, as in the real script): no
#                           question lands on the bus ⇒ the issue must be RE-OFFERED, never stranded.
#   otherwise             → AUTHORED: rc 0 + the PR URL on stdout (its only stdout emission)
cat > "$BIN/dev-author.sh" <<'EOF'
#!/usr/bin/env bash
printf 'AUTHOR %s %s\n' "$1" "$2" >> "$AUTHOR_LOG"
post_question(){   # what surface_blocked() does: one comment, line 1 = the machine-owned anchor
  [ -n "${FAKE_POST_FAILS:-}" ] && return 0
  printf '%s\t%s the author run could not finish.\n' "$DEV_LOGIN" "$ANCHOR" >> "$STORE/$2"
}
for s in ${FAKE_AUTHOR_SKIP:-}; do [ "$2" = "$s" ] && exit 0; done
for m in ${FAKE_AUTHOR_RC:-}; do
  if [ "$2" = "${m%%:*}" ]; then
    rc="${m##*:}"
    case "$rc" in 3|4|5|6|7|8) post_question "$@";; esac   # rc 2 posts nothing — fail-closed before it can
    exit "$rc"
  fi
done
if [ "$2" = "${FAKE_AUTHOR_FAIL:-}" ]; then post_question "$@"; exit 4; fi
printf 'https://github.com/oso-gato/fedora-dev/pull/%s\n' "$((900 + $2))"
exit 0
EOF
chmod +x "$BIN"/*
export ANCHOR

# fresh — a clean BUS (empty comment stores) + author log + default fakes for an INDEPENDENT scenario.
fresh(){
  export AUTHOR_LOG="$ROOT/author-$RANDOM.log"; : > "$AUTHOR_LOG"
  export STORE="$ROOT/bus-$RANDOM"; rm -rf "$STORE"; mkdir -p "$STORE"
  export FAKE_BACKLOG="" FAKE_AUTHOR_FAIL="" FAKE_AUTHOR_SKIP="" FAKE_AUTHOR_RC="" FAKE_POST_FAILS=""
  unset MAX_PER_PASS
}
# reply <issue> <login> — a REPLY lands on the issue AFTER the question: the answer that un-parks it.
reply(){ printf '%s\t%s\n' "$2" "thanks — scope it to one probe." >> "$STORE/$1"; }
# drive — run ONE pass and assert exactly which issues the author was INVOKED for. Successive drive()
# calls WITHOUT fresh() are successive passes over the same BUS (that is how parking is proven).
drive(){ # <desc> <expected-author-invocations, space-separated>
  local desc="$1" want="$2"
  : > "$AUTHOR_LOG"
  PATH="$BIN:$PATH" DEV_AUTHOR="$BIN/dev-author.sh" bash "$LOOP" fedora-dev >/dev/null 2>&1 || true
  local got; got="$(awk '{print $3}' "$AUTHOR_LOG" | sort -n | tr '\n' ' ' | sed 's/ $//')"
  ck "$desc" "$got" "$want"
}

echo "== one pass authors every backlog issue, in order =="
fresh; FAKE_BACKLOG=$'7\n3\n12'
drive "drains the backlog" "3 7 12"

echo "== a stuck (non-zero) author does NOT wedge the rest =="
fresh; FAKE_BACKLOG=$'3\n7\n12'; FAKE_AUTHOR_FAIL=7
drive "continues past a BLOCKED issue" "3 7 12"

echo "== empty backlog → no author invocations =="
fresh
drive "empty backlog is a no-op" ""

echo "== MAX_PER_PASS caps the AUTHOR RUNS (defer, not drop) =="
fresh; FAKE_BACKLOG=$'1\n2\n3\n4'; export MAX_PER_PASS=2
drive "caps to MAX_PER_PASS" "1 2"

# --- STARVATION (a defect this closes): dev-author leaves an authored issue OPEN and still backlog-
# --- labelled while its PR is in flight, and no-ops on it. If the cap TRUNCATED the enumeration, those
# --- in-flight issues would eat the whole cap every pass and the TAIL would never be authored at all —
# --- permanent starvation, not deferral. The cap must count RUNS SPAWNED, so a skip costs no slot.
echo "== in-flight (already-authored) issues cost NO cap slot — the tail is reached, not starved =="
fresh; FAKE_BACKLOG=$'1\n2\n3\n4\n5\n6\n7\n8'; FAKE_AUTHOR_SKIP="1 2 3"; export MAX_PER_PASS=2
drive "skips don't burn the cap; 4+5 still authored" "1 2 3 4 5"
unset MAX_PER_PASS

# --- PARKING, DERIVED FROM THE BUS. A BLOCKED author posts a dev-task question ON THE ISSUE. Re-running
# --- the author every pass would re-spend a bounded model run, re-ask the same question into noise, and
# --- (counting toward the cap) hold a slot forever. The question itself is the record: while it is the
# --- NEWEST comment, the issue is parked. Nothing is written locally — pass 2 re-reads it off the bus.
echo "== an issue that surfaced a question is PARKED, not re-asked next pass =="
fresh; FAKE_BACKLOG=$'3\n7\n12'; FAKE_AUTHOR_FAIL=7
drive "pass 1: 7 goes BLOCKED → the question lands on the issue" "3 7 12"
drive "pass 2: 7 is PARKED — the question is still the newest comment" "3 12"

echo "== a REPLY on the issue un-parks it (defers, never drops) =="
reply 7 arthur   # a human answers the question — now the newest comment is theirs
drive "pass 3: 7 is re-offered" "3 7 12"

# --- R14 E2E-KILL: "both boxes killed mid-work, resume from the bus alone". The park fact lives ONLY on
# --- GitHub, so a wiped box must behave identically. Pass 2 below runs against a BRAND-NEW empty HOME —
# --- every local marker dir the box could ever have had is gone — and 7 must STILL be parked. Against the
# --- marker-based design this row fails outright (state lost ⇒ re-author ⇒ a re-spent model run and a
# --- duplicate question on every blocked ticket).
echo "== E2E-KILL (R14): a WIPED box still parks — the record is on the bus, not on disk =="
fresh; FAKE_BACKLOG=$'3\n7\n12'; FAKE_AUTHOR_FAIL=7
drive "pass 1 (box A): 7 surfaces a question" "3 7 12"
WIPED="$ROOT/wiped-home-$RANDOM"; mkdir -p "$WIPED"
HOME="$WIPED" drive "pass 2 (box wiped, fresh HOME): 7 is STILL parked" "3 12"
# …and the driver must have persisted NOTHING to disk to achieve that.
ck "the wiped HOME is still empty — the driver writes no local state" \
   "$(find "$WIPED" -mindepth 1 | wc -l | tr -d ' ')" "0"

# --- IDENTITY (auto-merge G2 discipline). The anchor is machine-owned: on a PUBLIC repo, a stranger who
# --- pastes it into a comment must NOT be able to freeze a feature out of the backlog forever. Only the
# --- dev box's own App identity can park. Against a login-blind implementation this row fails.
echo "== a STRANGER pasting the anchor cannot park an issue (only \$DEV_LOGIN can) =="
fresh; FAKE_BACKLOG=$'3\n7\n12'
printf '%s\t%s not really.\n' "randomer" "$ANCHOR" >> "$STORE/7"
drive "7 is authored anyway — a forged marker is inert" "3 7 12"

# --- THE rc-3/7/8 BLIND SPOT: dev-author ALSO posts a question (surface_blocked) when the worktree (3),
# --- the push (7) or the PR create (8) fails — and because it writes its .done marker only AFTER a
# --- successful PR create, such an issue stays open, unmarked and PR-less, so its guard says ACT again.
# --- Left as RETRY, a persistent push/PR-create failure — lost credential, branch protection, issues
# --- disabled — re-spends a full bounded `claude -p` run and re-posts the IDENTICAL question every
# --- LOOP_INTERVAL, forever. These rows park them like any other surfaced question.
echo "== rc 3|7|8 ALSO post a question (surface_blocked) — they PARK too, they do not spin =="
for rc in 3 7 8; do
  fresh; FAKE_BACKLOG=$'3\n7\n12'; FAKE_AUTHOR_RC="7:$rc"
  drive "rc$rc pass 1: 7 surfaces a question" "3 7 12"
  drive "rc$rc pass 2: 7 is PARKED — no model run re-spent, no question re-asked" "3 12"
done

# --- rc 2 is the ONE code that posts NOTHING (dev-author cannot even read the issue → fail-closed before
# --- it can comment). Nothing lands on the bus, so nothing parks it: it must RETRY, or a ticket nobody
# --- was ever told about would be stranded forever.
echo "== rc 2 posts no question — it must RETRY (parking it would strand a silent ticket) =="
fresh; FAKE_BACKLOG=$'3\n7\n12'; FAKE_AUTHOR_RC="7:2"
drive "rc2 pass 1: 7 is attempted" "3 7 12"
drive "rc2 pass 2: 7 is retried, NOT parked" "3 7 12"

# --- The comment post is BEST-EFFORT in the real dev-author (it logs a WARN and carries on). If it FAILED,
# --- no question reached the bus and no human was ever told — so the issue must be RE-OFFERED, not parked.
# --- The old marker design parked it regardless: the feature was silently dropped with nobody informed.
echo "== a question that FAILED to post does not park (fail-safe: re-ask, never strand) =="
fresh; FAKE_BACKLOG=$'3\n7\n12'; FAKE_AUTHOR_FAIL=7; export FAKE_POST_FAILS=1
drive "pass 1: 7 goes BLOCKED but the comment never lands" "3 7 12"
drive "pass 2: 7 is re-offered — nothing on the bus says a question is open" "3 7 12"
unset FAKE_POST_FAILS

echo
echo "dev-loop-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
