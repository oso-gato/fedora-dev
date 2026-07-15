#!/usr/bin/env bash
# rebuild-request.test.sh — MOCK end-to-end test of bin/rebuild-request.sh (the R17 dev-side producer,
# fedora-dev#174 + the D4/#191 multi-tenant session-id). Drives the REAL script against a STUB session
# source (SESSION_SOURCE seam, emitting `name<TAB>cwd<TAB>sid` fixtures the way enumerate_claude_procs
# does), and validates every emitted manifest through the EXECUTOR'S OWN parse_manifest awk — copied
# VERBATIM from fedora-bootstrap host-agent-watch.sh (post-#143, the 4-field grammar with the
# fixed-width 8-4-4-4-12 UUID 4th field) — so byte-compatibility with the consumer is PROVEN, not
# asserted. If the executor ever changes that grammar, this embedded copy is the cross-repo parity
# anchor that must change in lockstep.
#   bash rebuild-request.test.sh  → exit 0 = all rows pass. No GitHub / network / real processes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/bin/rebuild-request.sh"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
fail=0
check(){ if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }
UUID=0deceee8-34ab-4e41-be19-ba4210469eb6                      # a valid UUID for the fixtures

# ── the executor's REAL parse_manifest (VERBATIM from host-agent-watch.sh, #143) — the byte-compat oracle
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
      if ($1 != "session" || (NF != 3 && NF != 4))           { rc=2; exit }
      if ($2 !~ /^[A-Za-z0-9._-]+$/ || length($2) > 64)      { rc=2; exit }
      if ($3 !~ /^\/[A-Za-z0-9._\/@%+-]*$/ || length($3) > 256) { rc=2; exit }
      if (NF == 4 && $4 !~ /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) { rc=2; exit }
      if (++n > MAX)                                         { rc=2; exit }
      if (NF == 4) printf "%s\t%s\t%s\n", $2, $3, $4
      else         printf "%s\t%s\n",     $2, $3
    }
    END{ if(rc) exit rc; if(!seenb) exit 3; if(inb==1) exit 2; exit 0 }
  '
}

# ── a stub SESSION_SOURCE: emits the fixture verbatim (name<TAB>cwd<TAB>sid), as enumerate_claude_procs would
STUB="$TMPD/source"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
cat "${SESSION_FIXTURE:?}"
STUBEOF
chmod +x "$STUB"
fixture(){ printf '%b' "$1" > "$TMPD/fix"; export SESSION_FIXTURE="$TMPD/fix"; }
run_manifest(){ SESSION_SOURCE="$STUB" bash "$SUT" manifest; }

# ── Row 1: happy path — a tenant WITH a session-id + an ephemeral; 4-field parses, ephemeral dropped ──
fixture "main\t/home/core\t$UUID\nc999\t/home/core\t\n"
out="$(run_manifest)"; parsed="$(printf '%s\n' "$out" | exec_parse_manifest)"; rc=$?
check "with-sid: executor parses rc=0"          '[ "$rc" = 0 ]'
check "with-sid: 4-field line (name cwd sid)"   '[ "$parsed" = "$(printf "main\t/home/core\t%s" "$UUID")" ]'
check "with-sid: ephemeral c999 excluded"       '! printf "%s" "$out" | grep -q c999'

# ── Row 2: a tenant with NO session-id (old bin/claude) → v1 3-field line (cwd-scoped --continue) ─────
fixture 'main\t/home/core\t\n'
out="$(run_manifest)"; parsed="$(printf '%s\n' "$out" | exec_parse_manifest)"; rc=$?
check "no-sid: executor parses rc=0"            '[ "$rc" = 0 ]'
check "no-sid: emits a v1 3-field line"         '[ "$parsed" = "$(printf "main\t/home/core")" ]'

# ── Row 3: a non-UUID sid DEGRADES to v1 (never emit a bad 4th field — the executor would reject all) ─
fixture 'main\t/home/core\tnot-a-uuid\n'
out="$(run_manifest)"; parsed="$(printf '%s\n' "$out" | exec_parse_manifest)"; rc=$?
check "bad-sid: executor still parses rc=0"     '[ "$rc" = 0 ]'
check "bad-sid: degraded to a v1 line"          '[ "$parsed" = "$(printf "main\t/home/core")" ]'

# ── Row 3b: a length-36-but-not-8-4-4-4-12 sid also DEGRADES (executor #143 tightened to fixed-width) ──
fixture 'main\t/home/core\t123456789-abc-4444-5555-123456789012\n'
out="$(run_manifest)"; parsed="$(printf '%s\n' "$out" | exec_parse_manifest)"; rc=$?
check "loose-36 sid: executor rc=0"             '[ "$rc" = 0 ]'
check "loose-36 sid: degraded to v1"            '[ "$parsed" = "$(printf "main\t/home/core")" ]'

# ── Row 4: an unsafe cwd (space) is SKIPPED — the rest (incl. its sid) survive; ephemeral name skipped ─
fixture "main\t/home/core\t$UUID\nwork\t/bad path\t$UUID\nbad name\t/home/x\t$UUID\n"
out="$(run_manifest)"; parsed="$(printf '%s\n' "$out" | exec_parse_manifest)"; rc=$?
check "skip: executor parses rc=0"              '[ "$rc" = 0 ]'
check "skip: only the safe tenant, 4-field"     '[ "$parsed" = "$(printf "main\t/home/core\t%s" "$UUID")" ]'

# ── Row 5: > DEVBOX_MAX_SESSIONS → producer caps at 32, executor accepts (never the >MAX rc=2) ────────
: > "$TMPD/big"; for i in $(seq 1 33); do printf 's%s\t/home/core\t%s\n' "$i" "$UUID" >> "$TMPD/big"; done
export SESSION_FIXTURE="$TMPD/big"
out="$(run_manifest)"; parsed="$(printf '%s\n' "$out" | exec_parse_manifest)"; rc=$?
check "cap: executor parses rc=0 (not >MAX)"    '[ "$rc" = 0 ]'
check "cap: exactly 32 tenants emitted"         '[ "$(printf "%s\n" "$parsed" | grep -c .)" = 32 ]'

# ── Row 6: only ephemeral → a well-formed EMPTY block (rc=0, zero sessions), never the rc=3 missing ───
fixture 'c111\t/home/core\t\nc222\t/home/core\t\n'
out="$(run_manifest)"; printf '%s\n' "$out" | exec_parse_manifest >/dev/null; rc=$?
check "empty: executor parses rc=0"             '[ "$rc" = 0 ]'
check "empty: zero session lines"               '[ "$(printf "%s\n" "$out" | grep -c "^session ")" = 0 ]'
check "empty: both sentinels present"           '[ "$(printf "%s\n" "$out" | grep -c "%%DEVBOX-MANIFEST")" = 2 ]'

# ── Row 7: MUTATION — neutralize the sid VALIDATION; a non-UUID sid now LEAKS a 4-field line and the ──
#    executor REJECTS the WHOLE ticket (rc=2). Proves Row 3's valid_sid guard bites (a leak strands all).
cp "$SUT" "$TMPD/mut.sh"
sed -i 's/\[ -n "$sid" \] && valid_sid "$sid"/[ -n "$sid" ]/' "$TMPD/mut.sh"
check "mutation genuinely changed the copy"     '! cmp -s "$SUT" "$TMPD/mut.sh"'
fixture 'main\t/home/core\tnot-a-uuid\n'
out="$(SESSION_SOURCE="$STUB" bash "$TMPD/mut.sh" manifest)"; printf '%s\n' "$out" | exec_parse_manifest >/dev/null; rc=$?
check "mutation: executor now REJECTS (rc=2)"   '[ "$rc" = 2 ]'

# ── Row 8: default (request) mode composes a body whose line 1 is the op + a 4-field manifest parses ──
fixture "main\t/home/core\t$UUID\n"
REBUILD_REQUEST_OUT="$TMPD/body.md" SESSION_SOURCE="$STUB" bash "$SUT" >/dev/null 2>&1
check "request: body written"                   '[ -s "$TMPD/body.md" ]'
check "request: line 1 is the exact op"         '[ "$(head -1 "$TMPD/body.md")" = "host-op: rebuild-devbox fedora-dev" ]'
exec_parse_manifest < "$TMPD/body.md" >/dev/null; rc=$?
check "request: body manifest parses rc=0"      '[ "$rc" = 0 ]'
check "request: body carries the sid"           '[ "$(exec_parse_manifest < "$TMPD/body.md")" = "$(printf "main\t/home/core\t%s" "$UUID")" ]'

# ── Row 9: the pure-helper selftest passes ───────────────────────────────────────────────────────────
bash "$SUT" --selftest >/dev/null 2>&1
check "--selftest passes"                       '[ "$?" = 0 ]'

echo
[ "$fail" = 0 ] && echo "rebuild-request.test.sh: ALL PASS" || echo "rebuild-request.test.sh: FAILURES ABOVE"
exit "$fail"
