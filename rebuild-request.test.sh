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
UUID2=ebcfa847-31d1-4a2d-9ecc-ad0f7e2ebbfa                     # a SECOND valid UUID (dedup row)

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
# run_manifest drives the producer with the v2 rollout gate ENABLED (the feature under test). A separate
# runner leaves it at its safe default (OFF) to prove a valid sid still degrades to v1 then.
run_manifest(){ SESSION_SOURCE="$STUB" DEVBOX_MANIFEST_V2=1 bash "$SUT" manifest; }
run_manifest_v2off(){ SESSION_SOURCE="$STUB" bash "$SUT" manifest; }

# ── Row 1: happy path — a tenant WITH a session-id + an ephemeral; 4-field parses, ephemeral dropped ──
fixture "main\t/home/core\t$UUID\nc999\t/home/core\t\n"
out="$(run_manifest)"; parsed="$(printf '%s\n' "$out" | exec_parse_manifest)"; rc=$?
check "with-sid: executor parses rc=0"          '[ "$rc" = 0 ]'
check "with-sid: 4-field line (name cwd sid)"   '[ "$parsed" = "$(printf "main\t/home/core\t%s" "$UUID")" ]'
check "with-sid: ephemeral c999 excluded"       '! printf "%s" "$out" | grep -q c999'

# ── Row 1c: DEDUP by sid (2026-07-19) — one tenant has MULTIPLE `claude --resume <sid>` procs, so the ──
# raw source double-counts. dedup_by_sid collapses same-sid lines to ONE (else the executor reports
# "restored N/N" for N/2 real sessions — an untrue count). A NO-SID line has no dedup key → passes through.
fixture "s-a\t/home/core\t$UUID\ns-a\t/home/core\t$UUID\ns-b\t/r/b\t$UUID2\ns-a\t/home/core\t$UUID\ns-p7\t/r/p7\t\ns-p8\t/r/p8\t\n"
out="$(run_manifest)"; printf '%s\n' "$out" | exec_parse_manifest >/dev/null; rc=$?
check "dedup: executor parses rc=0"             '[ "$rc" = 0 ]'
check "dedup: 3 same-sid procs → ONE line"      '[ "$(printf "%s" "$out" | grep -c "^session s-a ")" = 1 ]'
check "dedup: the other sid survives once"      '[ "$(printf "%s" "$out" | grep -c "^session s-b ")" = 1 ]'
check "dedup: both NO-SID lines pass through"   '[ "$(printf "%s" "$out" | grep -cE "^session s-p[78] ")" = 2 ]'
check "dedup: exactly 4 session lines total"    '[ "$(printf "%s" "$out" | grep -c "^session ")" = 4 ]'
# MUTATION — remove the dedup stage; the 3 same-sid procs must then LEAK as 3 lines (the untrue count).
cp "$SUT" "$TMPD/mutdd.sh"
sed -i 's/| dedup_by_sid |/| cat |/' "$TMPD/mutdd.sh"
check "dedup-mutation genuinely changed the copy" '! cmp -s "$SUT" "$TMPD/mutdd.sh"'
out="$(SESSION_SOURCE="$STUB" DEVBOX_MANIFEST_V2=1 bash "$TMPD/mutdd.sh" manifest)"
check "dedup-mutation: same-sid now leaks 3 lines" '[ "$(printf "%s" "$out" | grep -c "^session s-a ")" = 3 ]'

# ── Row 1b: v2 rollout gate DEFAULT OFF — a valid sid still emits v1 (safe against a pre-#143 executor) ─
fixture "main\t/home/core\t$UUID\n"
out="$(run_manifest_v2off)"; parsed="$(printf '%s\n' "$out" | exec_parse_manifest)"; rc=$?
check "v2-off: executor parses rc=0"            '[ "$rc" = 0 ]'
check "v2-off: valid sid degraded to v1"        '[ "$parsed" = "$(printf "main\t/home/core")" ]'

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

# ── Row 4: an unsafe cwd (space) AND a non-allowlisted name are each SKIPPED; the safe tenant survives ─
fixture "main\t/home/core\t$UUID\nwork\t/bad path\t$UUID\nbad name\t/home/x\t$UUID\n"
out="$(run_manifest)"; parsed="$(printf '%s\n' "$out" | exec_parse_manifest)"; rc=$?
check "skip: executor parses rc=0"              '[ "$rc" = 0 ]'
check "skip: only the safe tenant, 4-field"     '[ "$parsed" = "$(printf "main\t/home/core\t%s" "$UUID")" ]'

# ── Row 5: > DEVBOX_MAX_SESSIONS → producer caps at 32, executor accepts (never the >MAX rc=2) ────────
# DISTINCT sids per tenant (each real session has a UNIQUE UUID) — so dedup_by_sid keeps all 33 and the
# CAP trims to 32. (A same-sid fixture would be ONE session post-dedup, making the cap test vacuous — and
# it proves the pipeline order: dedup BEFORE the cap, so the cap counts DISTINCT sessions, not raw procs.)
: > "$TMPD/big"; for i in $(seq 1 33); do printf 's%s\t/home/core\t%08x-34ab-4e41-be19-ba4210469eb6\n' "$i" "$i" >> "$TMPD/big"; done
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
out="$(SESSION_SOURCE="$STUB" DEVBOX_MANIFEST_V2=1 bash "$TMPD/mut.sh" manifest)"; printf '%s\n' "$out" | exec_parse_manifest >/dev/null; rc=$?
check "mutation: executor now REJECTS (rc=2)"   '[ "$rc" = 2 ]'

# ── Row 7b: MUTATION — neutralize the CWD guard; an unsafe cwd (space) now LEAKS and the executor ─────
#    REJECTS the whole ticket (rc=2). Proves valid_cwd bites (independent of the sid guard; no v2 needed).
cp "$SUT" "$TMPD/mutcwd.sh"
sed -i 's/if ! valid_cwd "$cwd"/if ! true/' "$TMPD/mutcwd.sh"
check "cwd-mutation genuinely changed the copy"  '! cmp -s "$SUT" "$TMPD/mutcwd.sh"'
fixture 'main\t/bad path\t\n'
out="$(SESSION_SOURCE="$STUB" bash "$TMPD/mutcwd.sh" manifest)"; printf '%s\n' "$out" | exec_parse_manifest >/dev/null; rc=$?
check "cwd-mutation: executor now REJECTS (rc=2)" '[ "$rc" = 2 ]'

# ── Row 8: default (request) mode composes a body whose line 1 is the op + a 4-field manifest parses ──
fixture "main\t/home/core\t$UUID\n"
REBUILD_REQUEST_OUT="$TMPD/body.md" SESSION_SOURCE="$STUB" DEVBOX_MANIFEST_V2=1 bash "$SUT" >/dev/null 2>&1
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
