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
# ── stub SEEN_SIDS_SOURCE: the completeness cross-check's "what live sessions EXIST" set. Emits the
#    fixture's distinct non-empty sids (3rd col) — consistent with SESSION_SOURCE when nothing was dropped.
SEEN_STUB="$TMPD/seen"
cat > "$SEEN_STUB" <<'SEENEOF'
#!/usr/bin/env bash
awk -F'\t' '$3!="" && !seen[$3]++ {print $3}' "${SESSION_FIXTURE:?}"
SEENEOF
chmod +x "$SEEN_STUB"
# a SEEN source reporting an EXTRA live session the manifest will NOT contain (the incomplete case)
SEEN_EXTRA="$TMPD/seen-extra"
cat > "$SEEN_EXTRA" <<SEENXEOF
#!/usr/bin/env bash
printf '%s\n' $UUID ffffffff-0000-0000-0000-000000000000
SEENXEOF
chmod +x "$SEEN_EXTRA"
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

# ═══ FILE MODE (R17 approval flow — pairs with fedora-bootstrap v1.2.69) ═════════════════════════════
# A stub gh serves `issue list` (the dedup probe, from $FAKE_OPEN — the value the real -q would emit)
# and RECORDS `issue create` (title/labels/body-file content). A stub repo-scope answers R16 ($SCOPE_OK).
FBIN="$TMPD/fbin"; mkdir -p "$FBIN"
cat > "$FBIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")   printf '%s' "${FAKE_OPEN:-}" ;;
  "issue create")
    prev=''; title=''; bodyf=''
    for a in "$@"; do
      case "$prev" in --title) title="$a";; --body-file) bodyf="$a";; --label) printf 'LABEL:%s\n' "$a" >> "${FILE_REC:?}";; esac
      prev="$a"
    done
    { printf 'TITLE:%s\n' "$title"; cat "$bodyf"; } >> "${FILE_REC:?}"
    [ "${FAKE_CREATE_FAIL:-0}" = 1 ] && { echo boom; exit 1; }
    echo "https://github.com/oso-gato/fedora-bootstrap/issues/99" ;;
  "label create") printf 'LABELCREATE:%s\n' "$3" >> "${FILE_REC:?}" ;;   # record create-on-use attempts
  *) : ;;
esac
exit 0
GHEOF
chmod +x "$FBIN/gh"
printf '#!/usr/bin/env bash\n[ "${SCOPE_OK:-1}" = 1 ] && exit 0 || exit 1\n' > "$FBIN/repo-scope-stub"
chmod +x "$FBIN/repo-scope-stub"
run_file(){ # extra env…  — deliberately does NOT set DEVBOX_MANIFEST_V2: the FILING path must default v2
            # ON itself (incident 2026-07-19: env-dependent v2 filed a v1 cwd-scoped manifest live — a
            # multi-tenant collapse for sessions sharing one cwd; the sid row below proves the default)
  FILE_REC="$TMPD/file-rec"; : > "$FILE_REC"; export FILE_REC
  SESSION_SOURCE="$STUB" SEEN_SIDS_SOURCE="$SEEN_STUB" REPO_SCOPE="$FBIN/repo-scope-stub" PATH="$FBIN:$PATH" \
    env "$@" bash "$SUT" file >"$TMPD/file-out" 2>"$TMPD/file-err"; FRC=$?
}
body_rec(){ sed -n '/^TITLE:/,$p' "$FILE_REC" | sed 1d; }   # the created body (after the TITLE line)

echo "── file: files the approval ticket (title + both labels + mention + parseable manifest) ──"
fixture "main\t/home/core\t$UUID\n"
run_file
check "file: rc 0"                              '[ "$FRC" = 0 ]'
check "file: title is APPROVAL REQUIRED"        'grep -q "^TITLE:🔴 APPROVAL REQUIRED: rebuild-devbox fedora-dev" "$FILE_REC"'
check "file: host-task label"                   'grep -q "^LABEL:host-task$" "$FILE_REC"'
check "file: rebuild-approval label"            'grep -q "^LABEL:rebuild-approval$" "$FILE_REC"'
check "file: approved label CREATED (tappable)" 'grep -q "^LABELCREATE:approved$" "$FILE_REC"'
check "file: approved NOT applied at filing"    '! grep -q "^LABEL:approved$" "$FILE_REC"'
check "file: body line-1 is the exact op"       '[ "$(body_rec | head -1)" = "host-op: rebuild-devbox fedora-dev" ]'
check "file: @mention present (phone push)"     'body_rec | grep -q -- "@oso-gato"'
check "file: approved-label one-tap instruction" 'body_rec | grep -q "approved.*label"'
check "file: manifest parses via the executor"  'body_rec | exec_parse_manifest >/dev/null'
check "file: manifest carries the sid — v2 BY DEFAULT (env unset; the 2026-07-19 incident row)" '[ "$(body_rec | exec_parse_manifest)" = "$(printf "main\t/home/core\t%s" "$UUID")" ]'
check "file: URL printed on stdout"             'grep -q "issues/99" "$TMPD/file-out"'

echo "── file: explicit DEVBOX_MANIFEST_V2=0 still forces v1 (the override survives) ──"
run_file DEVBOX_MANIFEST_V2=0
check "file: v2=0 → v1 3-field manifest"        '[ "$(body_rec | exec_parse_manifest)" = "$(printf "main\t/home/core")" ]'

echo "── file: IDEMPOTENT — an OPEN rebuild ticket ⇒ NO second filing (rc 0, no create) ──"
run_file FAKE_OPEN='88'
check "file: dedup rc 0"                        '[ "$FRC" = 0 ]'
check "file: dedup did NOT create"              '[ ! -s "$FILE_REC" ]'
check "file: dedup names the existing ticket"   'grep -q "already exists (#88)" "$TMPD/file-err"'

echo "── file: R16 out-of-scope control repo ⇒ REFUSED (rc 1, no create) ──"
run_file SCOPE_OK=0
check "file: scope refuse rc 1"                 '[ "$FRC" = 1 ]'
check "file: scope refuse did NOT create"       '[ ! -s "$FILE_REC" ]'

echo "── file: a failed create ⇒ rc 1 (the poller keeps the flag + retries) ──"
run_file FAKE_CREATE_FAIL=1
check "file: create-failure rc 1"               '[ "$FRC" = 1 ]'

echo "── file: COMPLETENESS — a live session the manifest OMITS ⇒ REFUSE (rc 1, no create), names the omitted sid ──"
fixture "main\t/home/core\t$UUID\n"
run_file SEEN_SIDS_SOURCE="$SEEN_EXTRA"
check "file: incomplete rc 1"                   '[ "$FRC" = 1 ]'
check "file: incomplete did NOT create"         '[ ! -s "$FILE_REC" ]'
check "file: incomplete names the omitted sid"  'grep -q "ffffffff-0000-0000-0000-000000000000" "$TMPD/file-err"'
check "file: incomplete says REFUSING"          'grep -qi "REFUSING to file" "$TMPD/file-err"'

echo "── MUTATION: neutralize the completeness guard ⇒ the SAME omission FILES (proves the guard bites) ──"
sed 's|if \[ -n "${missing// /}" \]; then|if false; then|' "$SUT" > "$TMPD/mut-incomplete.sh"
check "mutation applied (non-vacuous)"          '! cmp -s "$SUT" "$TMPD/mut-incomplete.sh"'
fixture "main\t/home/core\t$UUID\n"
FILE_REC="$TMPD/file-rec"; : > "$FILE_REC"; export FILE_REC
SESSION_SOURCE="$STUB" SEEN_SIDS_SOURCE="$SEEN_EXTRA" REPO_SCOPE="$FBIN/repo-scope-stub" PATH="$FBIN:$PATH" \
  bash "$TMPD/mut-incomplete.sh" file >"$TMPD/file-out" 2>"$TMPD/file-err"; FRC=$?
check "mutation: incomplete now FILES (guard neutralized)" '[ "$FRC" = 0 ] && [ -s "$FILE_REC" ]'

echo "── file: AMBIGUITY (#226) — a NO-SID session sharing a cwd with another ⇒ REFUSE (rc 1, no create) ──"
fixture "s-ebcfa847\t/home/core\t$UUID\ns-p2128\t/home/core\t\n"
run_file
check "file: ambiguous rc 1"                    '[ "$FRC" = 1 ]'
check "file: ambiguous did NOT create"          '[ ! -s "$FILE_REC" ]'
check "file: ambiguous names the shared cwd"    'grep -q "/home/core" "$TMPD/file-err"'
check "file: ambiguous says REFUSING"           'grep -qi "REFUSING to file" "$TMPD/file-err"'
check "file: ambiguous cites --continue"        'grep -q -- "--continue" "$TMPD/file-err"'

echo "── file: a LONE no-sid session on a UNIQUE cwd is NOT ambiguous ⇒ FILES (guard does not over-refuse) ──"
fixture "main\t/home/core\t$UUID\ns-p9\t/root\t\n"
run_file
check "file: lone-nosid rc 0"                   '[ "$FRC" = 0 ]'
check "file: lone-nosid created"                '[ -s "$FILE_REC" ]'

echo "── MUTATION: neutralize the ambiguity guard ⇒ the SAME shared-cwd manifest FILES (proves the guard bites) ──"
sed 's|if \[ -n "${ambig// /}" \]; then|if false; then|' "$SUT" > "$TMPD/mut-ambig.sh"
check "ambig-mutation applied (non-vacuous)"    '! cmp -s "$SUT" "$TMPD/mut-ambig.sh"'
fixture "s-ebcfa847\t/home/core\t$UUID\ns-p2128\t/home/core\t\n"
FILE_REC="$TMPD/file-rec"; : > "$FILE_REC"; export FILE_REC
SESSION_SOURCE="$STUB" SEEN_SIDS_SOURCE="$SEEN_STUB" REPO_SCOPE="$FBIN/repo-scope-stub" PATH="$FBIN:$PATH" \
  bash "$TMPD/mut-ambig.sh" file >"$TMPD/file-out" 2>"$TMPD/file-err"; FRC=$?
check "ambig-mutation: shared-cwd now FILES (guard neutralized)" '[ "$FRC" = 0 ] && [ -s "$FILE_REC" ]'

# ═══ POLLER WIRING — rebuild_request_tick (flag-fired one-shot, R9-gated) ════════════════════════════
POLLER="$HERE/bin/pr-poller.sh"
if [ -f "$POLLER" ]; then
  printf '#!/usr/bin/env bash\necho "file $*" >> "${RR_REC:?}"\nexit "${RR_RC:-0}"\n' > "$FBIN/rr-rec"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FBIN/gh-quiet"
  chmod +x "$FBIN/rr-rec" "$FBIN/gh-quiet"
  run_tick(){ # <flag-present 0|1> extra env…
    local fp="$1"; shift
    local phome; phome="$TMPD/ph-$RANDOM$RANDOM"; mkdir -p "$phome/bin"
    cp "$FBIN/gh-quiet" "$phome/bin/gh"
    RR_REC="$phome/rr.rec"; : > "$RR_REC"; export RR_REC
    FLAG="$phome/requested"; [ "$fp" = 1 ] && : > "$FLAG"
    env HOME="$phome" PATH="$phome/bin:$PATH" POLLER_REPOS=fedora-dev POLLER_ARMED=0 \
        HOST_REFRESH_EVERY=0 RECONCILE_EVERY=0 DEV_LOOP_LAUNCH_EVERY=0 REBUILD_REQUEST_EVERY=1 \
        REBUILD_REQUEST_SCRIPT="$FBIN/rr-rec" REBUILD_REQUEST_FLAG="$FLAG" \
        REPO_SCOPE="$HERE/bin/repo-scope.sh" "$@" \
        bash "$POLLER" --once >"$phome/out" 2>&1
    TOUT="$phome/out"
  }
  echo "── poller: flag present → files ONCE + consumes the flag ──"
  run_tick 1 FLEET_HALT=true
  check "tick: filed"                           'grep -q "^file file" "$RR_REC"'
  check "tick: flag consumed"                   '[ ! -e "$FLAG" ]'
  echo "── poller: NO flag → nothing runs ──"
  run_tick 0 FLEET_HALT=true
  check "tick: no flag, no filing"              '[ ! -s "$RR_REC" ]'
  echo "── poller: R9 HALT → skipped, flag KEPT ──"
  run_tick 1 FLEET_HALT=false
  check "tick: halted → no filing"              '[ ! -s "$RR_REC" ]'
  check "tick: halted → flag kept"              '[ -e "$FLAG" ]'
  check "tick: halted → says so"                'grep -q "rebuild-request: R9 HALT" "$TOUT"'
  echo "── poller: filing FAILS → flag KEPT for retry ──"
  run_tick 1 FLEET_HALT=true RR_RC=1
  check "tick: failed filing ran"               'grep -q "^file file" "$RR_REC"'
  check "tick: failed filing keeps the flag"    '[ -e "$FLAG" ]'
else
  echo "  skip poller wiring rows (bin/pr-poller.sh not beside the test)"
fi

echo
[ "$fail" = 0 ] && echo "rebuild-request.test.sh: ALL PASS" || echo "rebuild-request.test.sh: FAILURES ABOVE"
exit "$fail"
