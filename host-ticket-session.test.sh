#!/usr/bin/env bash
# host-ticket-session.test.sh — the PROOF of multi-session ticket ISOLATION (R3): each claudebox session
# files its OWN host-validation tickets, STAMPED with its session name, and can read back ONLY its own
# tickets — never another session's. Drives the REAL bin/host-ticket.sh (and, through it, the REAL
# bin/session-id.sh minter) — no GitHub / network / model.
#
# HOW IT BITES — only `gh` is stubbed, with a mock that MODELS the issue store (a temp dir):
#   * `issue create`  → auto-numbers, records the --title and --body-file body.
#   * `issue list  --json number,title,body` → returns ALL issues as `<num>\t<title>\t<stamp>` (the
#     stamp lifted from each body's `host-session:` line) — it does NOT filter by session; the SID
#     filter under test lives in host-ticket.sh, so the stub emits everyone's tickets and the tool
#     must pick out its own. (gh's embedded jq shapes this in production; the stub, having no system
#     jq, emits the same shape directly — the host-refresh.test.sh "answers at gh's -q level" pattern.)
#   * `issue view <n> --json body|comments` → returns one issue's body / its comments' first lines.
#   Sessions are driven through the REAL env seam CLAUDE_CODE_SESSION_ID (session-id.sh source (2)), so
#   the test exercises the production SID path, not a back-door override.
#
# THE MUTATION-CHECK (req 5): a copy of host-ticket.sh has its SID compare NEUTRALIZED (a sed that
# genuinely changes it — asserted by grep, since diffutils/cmp are off-limits) and A's `--mine` must
# THEN wrongly show B's ticket — proving the compare, not the mock, is what enforces isolation.
#
# Run:  bash host-ticket-session.test.sh   → exit 0 = all rows pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HTICKET="$HERE/bin/host-ticket.sh"
[ -f "$HTICKET" ] || { echo "FATAL: bin/host-ticket.sh not found"; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; STORE="$ROOT/store"; mkdir -p "$BIN" "$STORE"

# two session identities (the real claude-code shape: a UUID). Sanitized == verbatim (hyphens are safe).
A='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
B='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'

# ---- stub gh: MODELS the issue store under $STORE (no jq — emits gh's -q output shape directly) ------
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "label create") exit 0;;
  "issue create")
    title=""; bodyfile=""; prev=""
    for a in "$@"; do
      case "$prev" in --title) title="$a";; --body-file) bodyfile="$a";; esac
      prev="$a"
    done
    c="$STORE/.counter"; n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$c"
    printf '%s' "$title" > "$STORE/$n.title"
    cat "$bodyfile"       > "$STORE/$n.body"
    echo "https://github.com/oso-gato/fedora-bootstrap/issues/$n"
    exit 0;;
  "issue list")
    # EVERY open issue as `<num>\t<title>\t<its host-session stamp>` — no session filtering here.
    for bf in "$STORE"/*.body; do
      [ -e "$bf" ] || continue
      num="$(basename "$bf" .body)"
      title="$(cat "$STORE/$num.title" 2>/dev/null)"
      stamp="$(grep -m1 '^host-session: ' "$bf" 2>/dev/null | sed 's/^host-session: //' | tr -d '\r')"
      printf '%s\t%s\t%s\n' "$num" "$title" "$stamp"
    done
    exit 0;;
  "issue view")
    num="$3"
    case "$*" in
      *"--json comments"*) cat "$STORE/$num.comments" 2>/dev/null;;   # each line = a comment's 1st line
      *"--json body"*)     cat "$STORE/$num.body"     2>/dev/null;;
    esac
    exit 0;;
esac
exit 0
EOF
chmod +x "$BIN/gh"

pass=0; fail=0
ck(){ if [ "$1" = 1 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$2"; \
      else fail=$((fail+1)); printf '  FAIL %s\n' "$2"; fi; }

TARGET="$HTICKET"
# run host-ticket.sh AS session <uuid>: real CLAUDE_CODE_SESSION_ID path; the two direct seams unset so
# only the production source can decide the SID. Captures stdout→OUT, stderr→ERRF, status→RC.
ERRF="$ROOT/err"
run_ht(){ local sid="$1"; shift
  OUT="$(env -u CLAUDE_SESSION_ID -u HOST_SESSION_ID CLAUDE_CODE_SESSION_ID="$sid" \
             PATH="$BIN:$PATH" STORE="$STORE" \
             REPO_SCOPE="$HERE/bin/repo-scope.sh" SESSION_ID_LIB="$HERE/bin/session-id.sh" \
             bash "$TARGET" "$@" 2>"$ERRF")"; RC=$?; }
bodyline1(){ head -1 "$STORE/$1.body" 2>/dev/null; }

# ===================================================================================================
echo "== 1+2: each session files a ticket STAMPED with its own SID; line 1 stays the consumer's grammar =="
run_ht "$A" redeploy fedora-dev
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)" "A: file redeploy fedora-dev rc=$RC (want 0)"
ck "$([ "$(bodyline1 1)" = 'host-op: redeploy fedora-dev' ] && echo 1 || echo 0)" \
   "issue #1 line 1 is byte-identical 'host-op: redeploy fedora-dev' (host consumer parses only this)"
ck "$(grep -qx "host-session: $A" "$STORE/1.body" && echo 1 || echo 0)" \
   "issue #1 body carries the whole line 'host-session: $A'"
ck "$([ "$(sed -n '2p' "$STORE/1.body")" = "host-session: $A" ] && echo 1 || echo 0)" \
   "the stamp is on LINE 2, immediately after line 1 (not buried in the footer)"

run_ht "$B" redeploy fedora-desktop
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)" "B: file redeploy fedora-desktop rc=$RC (want 0)"
ck "$(grep -qx "host-session: $B" "$STORE/2.body" && echo 1 || echo 0)" "issue #2 body carries 'host-session: $B'"

echo "== CROSS-INVOCATION STABILITY: a SECOND ticket from A stamps IDENTICALLY (the property it all rests on) =="
run_ht "$A" redeploy fedora-dev
ck "$([ "$(sed -n '2p' "$STORE/3.body")" = "host-session: $A" ] && echo 1 || echo 0)" \
   "A's separate host-ticket.sh invocation produced the SAME SID stamp on #3 as on #1 (stable across calls)"

# ===================================================================================================
echo "== 3: --mine shows ONLY the calling session's tickets — never another's =="
run_ht "$A" --mine
mine_A="$OUT"
ck "$(printf '%s\n' "$mine_A" | grep -qE '^1'$'\t' && echo 1 || echo 0)"      "A --mine lists #1 (A's)"
ck "$(printf '%s\n' "$mine_A" | grep -qE '^3'$'\t' && echo 1 || echo 0)"      "A --mine lists #3 (A's second)"
ck "$(printf '%s\n' "$mine_A" | grep -qE '^2'$'\t' && echo 0 || echo 1)"      "A --mine does NOT list #2 (B's) — isolation holds"

run_ht "$B" --mine
mine_B="$OUT"
ck "$(printf '%s\n' "$mine_B" | grep -qE '^2'$'\t' && echo 1 || echo 0)"      "B --mine lists #2 (B's)"
ck "$(printf '%s\n' "$mine_B" | grep -qE '^(1|3)'$'\t' && echo 0 || echo 1)"  "B --mine does NOT list #1/#3 (A's)"

# ===================================================================================================
echo "== 4: --outcome ENFORCES ownership — refuses another session's ticket, reads its own =="
run_ht "$A" --outcome 2                       # #2 is B's
ck "$([ "$RC" = 3 ] && echo 1 || echo 0)"     "A --outcome 2 (B's) refused with rc=$RC (want 3)"
ck "$([ -z "$OUT" ] && echo 1 || echo 0)"     "A --outcome 2 printed NO outcome to stdout ('$OUT')"
ck "$(grep -q "belongs to session $B, not $A" "$ERRF" && echo 1 || echo 0)" \
   "A --outcome 2 emitted the loud refusal naming the owning session"

printf '**host-agent: DONE** — redeploy ok\n' > "$STORE/1.comments"   # the host posts its verdict on #1
run_ht "$A" --outcome 1                        # #1 is A's own
ck "$([ "$RC" = 0 ] && echo 1 || echo 0)"     "A --outcome 1 (own, DONE) rc=$RC (want 0)"
ck "$([ "$OUT" = done ] && echo 1 || echo 0)" "A --outcome 1 printed 'done' ('$OUT')"

# a not-yet-answered own ticket → exit 2 (matches --wait's 'no verdict yet' contract)
run_ht "$A" --outcome 3
ck "$([ "$RC" = 2 ] && echo 1 || echo 0)"     "A --outcome 3 (own, no verdict yet) rc=$RC (want 2)"

# B reaching for A's ticket is refused symmetrically
run_ht "$B" --outcome 1
ck "$([ "$RC" = 3 ] && echo 1 || echo 0)"     "B --outcome 1 (A's) refused with rc=$RC (want 3)"

# ===================================================================================================
echo "== 5: MUTATION-CHECK — neutralize the SID compare → A's --mine WRONGLY shows B's #2 =="
MUT="$ROOT/host-ticket-mut.sh"; cp "$HTICKET" "$MUT"
# make the filter accept ANY stamped ticket (drop the '= $SID' binding); a genuine change, grep-verified.
sed -i 's/\[ "\$stamp" = "\$SID" \]/[ -n "\$stamp" ]/' "$MUT"
ck "$(grep -q '\[ "\$stamp" = "\$SID" \]' "$MUT" && echo 0 || echo 1)" "the sed removed the real compare (not vacuous)"
ck "$(grep -q '\[ -n "\$stamp" \]' "$MUT" && echo 1 || echo 0)"        "the sed installed the neutralized compare"
TARGET="$MUT"
run_ht "$A" --mine
ck "$(printf '%s\n' "$OUT" | grep -qE '^2'$'\t' && echo 1 || echo 0)" \
   "with the compare neutralized, A --mine NOW leaks B's #2 — proving the compare is what enforces isolation"
TARGET="$HTICKET"

echo
echo "host-ticket-session: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
