#!/usr/bin/env bash
# rebuild-request.test.sh — MOCK end-to-end test of bin/rebuild-request.sh (the R17 dev-side producer,
# fedora-dev#174). Drives the REAL script against a STUB tmux, and validates every emitted manifest
# through the EXECUTOR'S OWN parse_manifest awk — copied VERBATIM from fedora-bootstrap
# host-agent-watch.sh — so byte-compatibility with the consumer is PROVEN, not asserted. If the executor
# ever changes that grammar, this embedded copy is the parity anchor that must change in lockstep.
#   bash rebuild-request.test.sh  → exit 0 = all rows pass. No GitHub / network / real tmux.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/bin/rebuild-request.sh"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
fail=0
check(){ if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

# ── the executor's REAL parse_manifest (VERBATIM from host-agent-watch.sh) — the byte-compat oracle ──
MANIFEST_BEGIN='%%DEVBOX-MANIFEST-BEGIN%%'
MANIFEST_END='%%DEVBOX-MANIFEST-END%%'
DEVBOX_MAX_SESSIONS=32
exec_parse_manifest(){
  awk -v B="$MANIFEST_BEGIN" -v E="$MANIFEST_END" -v MAX="$DEVBOX_MAX_SESSIONS" '
    BEGIN{ inb=0; seenb=0; n=0; rc=0 }
    { sub(/\r$/,""); t=$0; sub(/^[[:space:]]+/,"",t); sub(/[[:space:]]+$/,"",t) }
    t==B { inb=1; seenb=1; next }
    t==E { if(inb) inb=2; next }
    inb==1 {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($1 != "session" || NF != 3)                        { rc=2; exit }
      if ($2 !~ /^[A-Za-z0-9._-]+$/ || length($2) > 64)      { rc=2; exit }
      if ($3 !~ /^\/[A-Za-z0-9._\/@%+-]*$/ || length($3) > 256) { rc=2; exit }
      if (++n > MAX)                                         { rc=2; exit }
      printf "%s\t%s\n", $2, $3
    }
    END{ if(rc) exit rc; if(!seenb) exit 3; if(inb==1) exit 2; exit 0 }
  '
}

# ── a stub tmux driven by a fixture file (one `name<TAB>cwd` per line) ────────────────────────────────
STUB="$TMPD/tmux"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
FIX="${STUB_TMUX_FIXTURE:?}"
case "$1" in
  list-sessions) cut -f1 "$FIX" ;;
  display-message)
     args=("$@"); t=""
     for ((i=0;i<${#args[@]};i++)); do [ "${args[i]}" = "-t" ] && t="${args[i+1]}"; done
     awk -F'\t' -v s="$t" '$1==s{print $2; exit}' "$FIX" ;;
esac
STUBEOF
chmod +x "$STUB"

fixture(){ printf '%b' "$1" > "$TMPD/fix"; STUB_TMUX_FIXTURE="$TMPD/fix"; export STUB_TMUX_FIXTURE; }
run_manifest(){ TMUX_BIN="$STUB" bash "$SUT" manifest; }

# ── Row 1: happy path — one real session + one ephemeral; manifest parses clean, ephemeral dropped ────
fixture 'main\t/home/core\nc999\t/home/core\n'
out="$(run_manifest)"; parsed="$(printf '%s\n' "$out" | exec_parse_manifest)"; rc=$?
check "happy: executor parses rc=0"            '[ "$rc" = 0 ]'
check "happy: exactly the real session, cwd"   '[ "$parsed" = "$(printf "main\t/home/core")" ]'
check "happy: ephemeral c999 excluded"         '! printf "%s" "$out" | grep -q c999'

# ── Row 2: a session with an unsafe cwd (space) is SKIPPED — the rest survive, ticket not rejected ────
fixture 'main\t/home/core\nwork\t/bad path\n'
out="$(run_manifest)"; parsed="$(printf '%s\n' "$out" | exec_parse_manifest)"; rc=$?
check "bad-cwd: executor still parses rc=0"     '[ "$rc" = 0 ]'
check "bad-cwd: only the safe session emitted"  '[ "$parsed" = "$(printf "main\t/home/core")" ]'

# ── Row 3: a session whose NAME is outside the allowlist is skipped ───────────────────────────────────
fixture 'main\t/home/core\nbad name\t/home/x\n'
out="$(run_manifest)"; parsed="$(printf '%s\n' "$out" | exec_parse_manifest)"; rc=$?
check "bad-name: executor parses rc=0"          '[ "$rc" = 0 ]'
check "bad-name: only the valid session"        '[ "$parsed" = "$(printf "main\t/home/core")" ]'

# ── Row 4: > DEVBOX_MAX_SESSIONS sessions → producer caps at 32, executor accepts (never rejects) ─────
: > "$TMPD/big"; for i in $(seq 1 33); do printf 's%s\t/home/core\n' "$i" >> "$TMPD/big"; done
STUB_TMUX_FIXTURE="$TMPD/big"; export STUB_TMUX_FIXTURE
out="$(run_manifest)"; parsed="$(printf '%s\n' "$out" | exec_parse_manifest)"; rc=$?
check "cap: executor parses rc=0 (not >MAX)"    '[ "$rc" = 0 ]'
check "cap: exactly 32 sessions emitted"        '[ "$(printf "%s\n" "$parsed" | grep -c .)" = 32 ]'

# ── Row 5: only ephemeral sessions → a well-formed EMPTY block (rc=0, zero sessions), never rc=3 ──────
fixture 'c111\t/home/core\nc222\t/home/core\n'
out="$(run_manifest)"; printf '%s\n' "$out" | exec_parse_manifest >/dev/null; rc=$?
check "empty: executor parses rc=0 (well-formed)" '[ "$rc" = 0 ]'
check "empty: zero session lines"                 '[ "$(printf "%s\n" "$out" | grep -c "^session ")" = 0 ]'
check "empty: both sentinels present"             '[ "$(printf "%s\n" "$out" | grep -c "%%DEVBOX-MANIFEST")" = 2 ]'

# ── Row 6: MUTATION — neutralize the cwd guard; the unsafe line now LEAKS and the executor REJECTS ────
#    (the whole ticket, rc=2). Proves Row 2's guard actually bites — and that a leak is catastrophic.
cp "$SUT" "$TMPD/mut.sh"
sed -i 's/if ! valid_cwd "$cwd"; then/if false; then/' "$TMPD/mut.sh"
check "mutation genuinely changed the copy"     '! cmp -s "$SUT" "$TMPD/mut.sh"'
fixture 'main\t/home/core\nwork\t/bad path\n'
out="$(TMUX_BIN="$STUB" bash "$TMPD/mut.sh" manifest)"; printf '%s\n' "$out" | exec_parse_manifest >/dev/null; rc=$?
check "mutation: executor now REJECTS (rc=2)"   '[ "$rc" = 2 ]'

# ── Row 7: default (request) mode composes a full body whose line 1 is the op + manifest parses ──────
fixture 'main\t/home/core\n'
REBUILD_REQUEST_OUT="$TMPD/body.md" TMUX_BIN="$STUB" bash "$SUT" >/dev/null 2>&1
line1="$(head -1 "$TMPD/body.md")"
check "request: body written"                   '[ -s "$TMPD/body.md" ]'
check "request: line 1 is the exact op"         '[ "$line1" = "host-op: rebuild-devbox fedora-dev" ]'
exec_parse_manifest < "$TMPD/body.md" >/dev/null; rc=$?
check "request: body manifest parses rc=0"      '[ "$rc" = 0 ]'
check "request: body manifest has the session"  '[ "$(exec_parse_manifest < "$TMPD/body.md")" = "$(printf "main\t/home/core")" ]'

# ── Row 8: the pure-helper selftest passes ───────────────────────────────────────────────────────────
bash "$SUT" --selftest >/dev/null 2>&1
check "--selftest passes"                       '[ "$?" = 0 ]'

echo
[ "$fail" = 0 ] && echo "rebuild-request.test.sh: ALL PASS" || echo "rebuild-request.test.sh: FAILURES ABOVE"
exit "$fail"
