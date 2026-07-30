#!/usr/bin/env bash
# asset-cache.test.sh — proves bin/asset-cache.sh actually BOUNDS the dev box's asset caches (#321), and
# that every unreadable signal KEEPS the cache instead of dropping it.
#
# THE AXIS. A GC is one of the few components where a green pure-core test is nearly worthless: the whole
# risk lives in what it DELETES. `--selftest` covers the decisions; nothing there can tell you the age
# arm walked the right glob, that the LRU walk evicted the OLDEST rather than the newest, that a shared
# cache stayed put while one repo still had drivable work, or that a missing directory was skipped rather
# than acted on. So every row here drives the REAL script against REAL directories with REAL
# find/du/rm/mtimes, and asserts on the files that survive.
#
# WHAT IS STUBBED, AND WHY EXACTLY THOSE TWO. The ship ORACLE and the SCOPE reader are stubbed because
# they are GitHub reads (`gh`), and a test that needed the live objective state could assert nothing
# deterministic. `podman` is stubbed because the image arm's job is to REMOVE IMAGES, and this suite runs
# on a live box carrying a running apparatus — a real destructive prune here would be the test damaging
# the thing it validates. Everything the stub cannot prove — that the query shapes it emulates are the
# ones podman actually answers — is pinned by PART F, which runs the REAL engine READ-ONLY.
#
# FIVE MUTATIONS RUN IN-SUITE, each vacuity-guarded (a sed that changed nothing FAILS the row rather than
# passing over an unmutated file): neutralize the shared-release fold → a cache releases while a repo
# still has drivable work; neutralize the missing-dir skip → the pass acts on a cache that is not there;
# neutralize the LRU sort → the NEWEST entry is evicted instead of the oldest; neutralize the in-use
# refusal check → an image a build is holding is reported as reaped; neutralize the age gate → a file
# inside its age cap is pruned.
#
# bash asset-cache.test.sh → exit 0 = all rows pass. No GitHub/network/model, and NO destructive podman
# command at any point. Run after touching the registry, any arm, or the release rule.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/bin/asset-cache.sh"
WRAP="$HERE/bin/build-throwaway.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

# ---- fixtures --------------------------------------------------------------------------------------
FIX="$TMP/fix"; mkdir -p "$FIX"
PODLOG="$FIX/podman.log"

# The stub ORACLE speaks the R30 oracle's real KV contract. Per-repo scenario file: "<STATUS> <DRIVABLE>".
# No file ⇒ INDETERMINATE (what the real oracle emits with no anchor). ORACLE_RC forces a hard failure.
cat > "$FIX/oracle.sh" <<'EOF'
#!/usr/bin/env bash
[ "${ORACLE_RC:-0}" = 0 ] || exit "$ORACLE_RC"
[ "${1:-}" = "--status" ] || exit 2
repo="${2:-}"
if [ -r "$ORACLE_DIR/$repo" ]; then read -r st dr < "$ORACLE_DIR/$repo"
else st=INDETERMINATE; dr='?'; fi
printf 'STATUS: %s\nREPO: %s\nDRIVABLE: %s\nREASON: stub\n' "$st" "$repo" "$dr"
EOF

# The stub SCOPE reader — `list` only, which is all the GC uses.
cat > "$FIX/scope.sh" <<'EOF'
#!/usr/bin/env bash
[ "${SCOPE_RC:-0}" = 0 ] || exit "$SCOPE_RC"
[ "${1:-}" = "list" ] || exit 2
cat "$SCOPE_LIST" 2>/dev/null || true
EOF

# The stub PODMAN. Records every invocation, serves the two image listings from fixtures, refuses `rmi`
# for anything named in $FIX/inuse (podman's real behaviour for an image a container holds — measured:
# rc 2, "image is in use by a container"), and answers `system df` from a fixture.
cat > "$FIX/podman.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$PODLOG"
case "${1:-} ${2:-}" in
  "images "*|"images")
    if printf '%s\n' "$*" | grep -q -- '--sort=created'; then cat "$FIXD/images-floor" 2>/dev/null
    else cat "$FIXD/images-aged" 2>/dev/null; fi; exit 0;;
  "image prune") cat "$FIXD/prune-out" 2>/dev/null; exit 0;;   # real prune prints the ids it removed
  "image inspect")
    ref="${!#}"
    case "$*" in
      *Created.Unix*) date +%s; exit 0;;                     # young ⇒ the orphan sweeper reaps nothing
      *) sed -n "s|^$ref \(.*\)$|\1|p" "$FIXD/sizes" 2>/dev/null | head -1 | grep . || echo 0; exit 0;;
    esac;;
  "system df") cat "$FIXD/df.json" 2>/dev/null; exit 0;;
  "rmi "*)
    ref="${!#}"
    grep -qxF "$ref" "$FIXD/inuse" 2>/dev/null && { echo "Error: image is in use by a container" >&2; exit 2; }
    echo "untagged $ref" >> "$PODLOG.rmi"; exit 0;;
esac
exit 0
EOF
chmod +x "$FIX/oracle.sh" "$FIX/scope.sh" "$FIX/podman.sh"

: > "$FIX/inuse"; : > "$FIX/sizes"; : > "$FIX/images-aged"; : > "$FIX/images-floor"; : > "$FIX/prune-out"
echo '[{"Type":"Images","RawSize":1,"Size":"1B"}]' > "$FIX/df.json"

# reset_case <name> — a clean world per row: fresh cache dirs, fresh cost-cache, fresh podman log.
CASE=""
reset_case(){
  CASE="$TMP/$1"; rm -rf "$CASE"; mkdir -p "$CASE/home" "$CASE/state"
  : > "$PODLOG"; : > "$PODLOG.rmi"
  ORACLE_DIR="$CASE/oracle"; mkdir -p "$ORACLE_DIR"
  SCOPE_LIST="$CASE/scope.list"; : > "$SCOPE_LIST"
}

# GC [extra env…] — run the REAL library's one pass against this row's world.
GC(){
  env HOME="$CASE/home" \
      FD_DNF_CACHE="$CASE/dnf" FD_GIT_CACHE="$CASE/git" \
      FD_IMAGE_STORE="$CASE/store" AC_STATE="$CASE/state" \
      AC_ORACLE="$FIX/oracle.sh" AC_SCOPE="$FIX/scope.sh" AC_PODMAN="$FIX/podman.sh" \
      ORACLE_DIR="$ORACLE_DIR" SCOPE_LIST="$SCOPE_LIST" PODLOG="$PODLOG" FIXD="$FIX" \
      "$@"
}
# GCLIB [env…] — the common form: run the real script's --gc with this row's overrides.
GCLIB(){ GC "$@" bash "$LIB" --gc; }

mkfile(){ mkdir -p "$(dirname "$1")"; head -c "${3:-1024}" /dev/zero > "$1"; touch -d "$2" "$1"; }
mkdir_aged(){ mkdir -p "$1"; head -c "${3:-1024}" /dev/zero > "$1/blob"; touch -d "$2" "$1/blob" "$1"; }
have(){ [ -e "$1" ]; }

echo "===== PART A — the AGE and SIZE arms, against real dirs and real mtimes ====="

echo "== age-prune fires PAST the age cap, and the glob keeps dnf METADATA (pre-existing behaviour) =="
reset_case a1
mkfile "$CASE/dnf/old.rpm" "20 days ago"
mkfile "$CASE/dnf/new.rpm" "1 day ago"
mkfile "$CASE/dnf/repomd.xml" "20 days ago"
out="$(GCLIB FD_DNF_CACHE_MAX_AGE_DAYS=10 FD_DNF_CACHE_CAP_MB=999999 2>&1)"; rc=$?
{ ! have "$CASE/dnf/old.rpm" && have "$CASE/dnf/new.rpm" && [ "$rc" = 0 ]; } \
  && ok "aged rpm pruned, fresh rpm kept (rc 0)" || no "age arm wrong (rc=$rc)" "$out"
have "$CASE/dnf/repomd.xml" \
  && ok "dnf METADATA survives — the arm walks '*.rpm' only" || no "metadata was pruned (glob regression)"
grep -q 'gc: dnf age-prune old.rpm (>240h)' <<<"$out" \
  && ok "the prune is REPORTED with its cap" || no "no age-prune report line" "$out"

echo "== ...and NOT before it: the same fixture inside a wider cap loses nothing =="
reset_case a2
mkfile "$CASE/dnf/old.rpm" "20 days ago"
mkfile "$CASE/dnf/new.rpm" "1 day ago"
out="$(GCLIB FD_DNF_CACHE_MAX_AGE_DAYS=30 FD_DNF_CACHE_CAP_MB=999999 2>&1)"; rc=$?
{ have "$CASE/dnf/old.rpm" && have "$CASE/dnf/new.rpm" && [ "$rc" = 0 ]; } \
  && ok "nothing pruned inside the age cap (rc 0)" || no "pruned inside the cap (rc=$rc)" "$out"
grep -q 'age-prune' <<<"$out" && no "reported a prune it did not make" "$out" || ok "silent when nothing is due"

echo "== LRU size-evict brings the dir UNDER the cap and evicts OLDEST-FIRST =="
reset_case a3
mkfile "$CASE/dnf/a-oldest.rpm" "3 days ago" 1048576
mkfile "$CASE/dnf/b-middle.rpm" "2 days ago" 1048576
mkfile "$CASE/dnf/c-newest.rpm" "1 day ago"  1048576
out="$(GCLIB FD_DNF_CACHE_MAX_AGE_DAYS=3650 FD_DNF_CACHE_CAP_MB=2 2>&1)"; rc=$?
{ ! have "$CASE/dnf/a-oldest.rpm" && have "$CASE/dnf/b-middle.rpm" && have "$CASE/dnf/c-newest.rpm"; } \
  && ok "the OLDEST was evicted; the two newest kept" || no "LRU order wrong (rc=$rc)" "$out$(ls "$CASE/dnf")"
now_kb="$(du -sk "$CASE/dnf" | cut -f1)"
[ "$now_kb" -le $((2*1024)) ] && ok "dir is now UNDER the ${now_kb}K ≤ 2048K cap" \
  || no "still over cap after the size arm (${now_kb}K)" "$out"

echo "== a registry entry whose dir DOES NOT EXIST is skipped SILENTLY (never an error) =="
reset_case a4
mkfile "$CASE/dnf/x.rpm" "1 day ago"          # only the dnf dir exists; git/store do not
out="$(GCLIB FD_DNF_CACHE_MAX_AGE_DAYS=3650 FD_DNF_CACHE_CAP_MB=999999 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "rc 0 with two of three caches absent" || no "non-zero rc on absent dirs (rc=$rc)" "$out"
grep -Eq 'git|images' <<<"$out" && no "an absent cache was mentioned — not a silent skip" "$out" \
  || ok "absent caches produce NO output at all"
[ ! -s "$PODLOG" ] && ok "the absent image store means podman was never invoked" \
  || no "podman was called for a store dir that does not exist" "$(cat "$PODLOG")"
# The skip must be a SKIP, not an absence: the registry still declares all three.
[ "$(GC bash "$LIB" --registry | grep -c .)" = 3 ] \
  && ok "the registry still DECLARES all three caches (skipped ≠ undeclared)" || no "registry lost an entry"
# The download cache is bounded by bin/fd-fetch.sh (it owns that content-addressed format), NOT by a
# row here. A re-added row would silently bound nothing on a flat cache and would fight fd-fetch over
# the same FD_DL_CACHE_CAP_GB knob, so its ABSENCE is the assertion. fd-fetch.test.sh D1 proves the
# bound is still enforced from build-throwaway.sh's sweep.
[ -z "$(GC bash "$LIB" --registry | awk -F'|' '$1=="dl"')" ] \
  && ok "no dl row — bin/fd-fetch.sh owns the download cache's bound" || no "a dl registry row is back"

echo "===== PART B — the PROJECT-COMPLETION bound (stubbed ship oracle) ====="

echo "== a PER-REPO entry releases on THAT repo's SHIPPED — and not on a sibling's =="
reset_case b1
mkdir_aged "$CASE/git/e2e-alpha" "1 day ago"
mkdir_aged "$CASE/git/e2e-beta"  "1 day ago"
echo "SHIPPED 0" > "$ORACLE_DIR/e2e-alpha"
echo "OPEN 3"    > "$ORACLE_DIR/e2e-beta"
out="$(GCLIB FD_GIT_CACHE_MAX_AGE_DAYS=3650 FD_GIT_CACHE_CAP_MB=999999 2>&1)"; rc=$?
{ ! have "$CASE/git/e2e-alpha" && have "$CASE/git/e2e-beta" && [ "$rc" = 0 ]; } \
  && ok "the SHIPPED repo's subtree dropped; the OPEN sibling's untouched" \
  || no "per-repo release wrong (rc=$rc)" "$out$(ls "$CASE/git" 2>&1)"
grep -q 'gc: git completion-release e2e-alpha/' <<<"$out" \
  && ok "the release names the repo and its reason" || no "no completion-release report" "$out"

echo "== a SHARED entry does NOT release while ANY in-scope repo has DRIVABLE>0 =="
# Observable: a 10-day-old rpm sits INSIDE the steady 45d cap but OUTSIDE the 7d cold floor. It survives
# iff the shared cache was held.
reset_case b2
mkfile "$CASE/dnf/warm.rpm" "10 days ago"
printf 'e2e-alpha\ne2e-beta\n' > "$SCOPE_LIST"
echo "SHIPPED 0" > "$ORACLE_DIR/e2e-alpha"
echo "SHIPPED 2" > "$ORACLE_DIR/e2e-beta"      # shipped-looking, but still 2 drivable
out="$(GCLIB 2>&1)"; rc=$?
{ have "$CASE/dnf/warm.rpm" && [ "$rc" = 0 ]; } \
  && ok "one repo with drivable work HOLDS the shared cache (rc 0)" || no "released with work open (rc=$rc)" "$out"
grep -q 'COMPLETION-RELEASE' <<<"$out" && no "claimed a release it must not take" "$out" \
  || ok "no release claimed"

echo "== ...and DOES release — to a tighter COLD FLOOR, not a wholesale drop — when every repo is done =="
reset_case b3
mkfile "$CASE/dnf/warm.rpm" "10 days ago"
mkfile "$CASE/dnf/fresh.rpm" "1 hour ago"
printf 'e2e-alpha\ne2e-beta\n' > "$SCOPE_LIST"
echo "SHIPPED 0" > "$ORACLE_DIR/e2e-alpha"
echo "SHIPPED 0" > "$ORACLE_DIR/e2e-beta"
out="$(GCLIB 2>&1)"; rc=$?
{ ! have "$CASE/dnf/warm.rpm" && [ "$rc" = 0 ]; } \
  && ok "the cold floor (7d) now applies where the steady cap (45d) did not" || no "no release (rc=$rc)" "$out"
have "$CASE/dnf/fresh.rpm" \
  && ok "a BOUNDED release: the fresh entry survives, it is not an rm -rf" || no "release emptied the cache"
grep -q 'dnf COMPLETION-RELEASE' <<<"$out" \
  && ok "the release is announced with the floor it applied" || no "release not announced" "$out"

echo "== every unreadable completion signal releases NOTHING and still returns rc 0 =="
b_hold(){ # <name> <label> [env…]
  local n="$1" label="$2"; shift 2
  reset_case "$n"
  mkfile "$CASE/dnf/warm.rpm" "10 days ago"
  printf 'e2e-alpha\n' > "$SCOPE_LIST"
  echo "SHIPPED 0" > "$ORACLE_DIR/e2e-alpha"
  local out rc; out="$(GCLIB "$@" 2>&1)"; rc=$?
  { have "$CASE/dnf/warm.rpm" && [ "$rc" = 0 ] && ! grep -q COMPLETION-RELEASE <<<"$out"; } \
    && ok "$label → nothing released, rc 0" || no "$label released or failed (rc=$rc)" "$out"
}
b_hold b4 "INDETERMINATE verdict" ORACLE_DIR="$TMP/b4/empty-oracle"
b_hold b5 "oracle exits non-zero" ORACLE_RC=1
b_hold b6 "oracle absent (unexecutable path)" AC_ORACLE="$TMP/nope/oracle.sh"
b_hold b7 "scope reader exits non-zero" SCOPE_RC=1
b_hold b8 "scope reader absent" AC_SCOPE="$TMP/nope/scope.sh"
reset_case b9
mkfile "$CASE/dnf/warm.rpm" "10 days ago"
: > "$SCOPE_LIST"                                   # readable but EMPTY: no repo reported
echo "SHIPPED 0" > "$ORACLE_DIR/e2e-alpha"
out="$(GCLIB 2>&1)"; rc=$?
{ have "$CASE/dnf/warm.rpm" && [ "$rc" = 0 ]; } \
  && ok "an EMPTY scope is not 'the fleet shipped' → nothing released, rc 0" || no "empty scope released (rc=$rc)" "$out"
# The age+size arms must keep working while the completion arm is skipped — a held release must not
# disarm the other two bounds.
reset_case b10
mkfile "$CASE/dnf/ancient.rpm" "100 days ago"
out="$(GCLIB ORACLE_RC=1 2>&1)"; rc=$?
{ ! have "$CASE/dnf/ancient.rpm" && [ "$rc" = 0 ]; } \
  && ok "age+size still enforced when the oracle is broken (nothing becomes unbounded)" \
  || no "a broken oracle disarmed the age bound (rc=$rc)" "$out"

echo "== the cost cache is HOLD-ONLY: a stale RELEASE is never acted on =="
reset_case b11
mkfile "$CASE/dnf/warm.rpm" "10 days ago"
printf 'e2e-alpha\n' > "$SCOPE_LIST"
echo "OPEN 1" > "$ORACLE_DIR/e2e-alpha"
GCLIB >/dev/null 2>&1                                    # writes a HOLD
[ "$(cat "$CASE/state/shared.verdict" 2>/dev/null)" = "HOLD" ] \
  && ok "a HOLD verdict is cached (the cheap, non-destructive answer)" || no "no HOLD cached"
printf 'RELEASE\n' > "$CASE/state/shared.verdict"        # forge a fresh RELEASE
out="$(GCLIB 2>&1)"
have "$CASE/dnf/warm.rpm" \
  && ok "a cached RELEASE is RE-VERIFIED against the oracle, and held" || no "acted on a cached RELEASE" "$out"

echo "===== PART C — the image/layer STORE bound (stub podman; no destructive call anywhere) ====="

img_case(){ # sets up a store dir + the two listings
  reset_case "$1"; mkdir -p "$CASE/store"
  printf 'e2e-alpha\n' > "$SCOPE_LIST"; echo "OPEN 1" > "$ORACLE_DIR/e2e-alpha"
}

echo "== the DANGLING reap is AGE-FLOORED, so a concurrent build's layers are out of range =="
img_case c1
GCLIB FD_STORE_MIN_AGE_MIN=720 >/dev/null 2>&1
grep -q 'image prune -f --filter until=720m' "$PODLOG" \
  && ok "dangling prune carries --filter until=<floor> (unlike the host's blanket form)" \
  || no "dangling prune missing or unfloored" "$(cat "$PODLOG")"
grep -q 'prune -a' "$PODLOG" && no "a blanket 'prune -a' was issued (Principle 10)" || ok "no blanket prune -a"
grep -q 'no-cache' "$PODLOG" && no "--no-cache appeared in a churn sweep" || ok "no --no-cache"
# `prune` exits 0 with nothing to do, so the report must key on WHAT IT REMOVED, not on its rc —
# otherwise every build of every day announces a dangling-prune that never happened.
img_case c1b
out="$(GCLIB FD_STORE_MIN_AGE_MIN=720 2>&1)"
grep -q 'dangling-prune' <<<"$out" && no "claimed a dangling-prune while removing nothing" "$out" \
  || ok "removed nothing → claims nothing"
img_case c1c
printf 'sha256:aaa\nsha256:bbb\n' > "$FIX/prune-out"
out="$(GCLIB FD_STORE_MIN_AGE_MIN=720 2>&1)"
grep -q 'dangling-prune: 2 layer(s) older than 720m' <<<"$out" \
  && ok "removed 2 → reports exactly 2" || no "the real prune count is not reported" "$out"
: > "$FIX/prune-out"

echo "== AGED UNUSED images are reaped BY REFERENCE with a NON-FORCED rmi =="
img_case c2
printf 'localhost/old-a:1\nlocalhost/old-b:2\n' > "$FIX/images-aged"
GCLIB FD_STORE_MAX_AGE_H=1440 >/dev/null 2>&1
{ grep -q 'untagged localhost/old-a:1' "$PODLOG.rmi" && grep -q 'untagged localhost/old-b:2' "$PODLOG.rmi"; } \
  && ok "both aged references removed" || no "aged images not reaped" "$(cat "$PODLOG")"
grep -q 'rmi -f' "$PODLOG" && no "used a FORCED rmi — an in-use image would be destroyed" \
  || ok "the rmi is NON-FORCED (an in-use image can refuse)"
grep -q 'until=1440h' "$PODLOG" && ok "the listing is bound to the store age cap" || no "no age-capped listing"
: > "$FIX/images-aged"

echo "== an image a build is HOLDING survives the reap and is reported, not silently dropped =="
img_case c3
printf 'registry.fedoraproject.org/fedora:44\nlocalhost/cold:1\n' > "$FIX/images-aged"
printf 'registry.fedoraproject.org/fedora:44\n' > "$FIX/inuse"
out="$(GCLIB FD_STORE_MAX_AGE_H=1440 2>&1)"
grep -q 'untagged registry.fedoraproject.org/fedora:44' "$PODLOG.rmi" \
  && no "the in-use base image was reported reaped" || ok "the in-use base image is NOT reaped"
grep -q 'untagged localhost/cold:1' "$PODLOG.rmi" \
  && ok "the genuinely cold image beside it IS reaped (the arm still works)" || no "cold image survived too"
grep -q 'in use or undeletable — kept' <<<"$out" \
  && ok "the refusal is REPORTED" || no "the skip was silent" "$out"
: > "$FIX/inuse"; : > "$FIX/images-aged"

echo "== the operator protect-list keeps a reference, and <none> is left to the dangling arm =="
img_case c4
printf 'ghcr.io/oso-gato/keepme:latest\nlocalhost/go:1\n<none>:<none>\n' > "$FIX/images-aged"
out="$(GCLIB FD_STORE_MAX_AGE_H=1440 FD_STORE_PROTECT=ghcr.io/oso-gato/keepme 2>&1)"
grep -q 'keepme' "$PODLOG.rmi" && no "a protect-listed reference was removed" || ok "protect-listed reference kept"
grep -q 'protect-listed — kept' <<<"$out" && ok "the protection is reported" || no "protection unreported" "$out"
grep -q '<none>' "$PODLOG.rmi" && no "tried to rmi a <none> reference" || ok "<none> left to the dangling arm"
grep -q 'untagged localhost/go:1' "$PODLOG.rmi" || no "the unprotected image was not reaped"
: > "$FIX/images-aged"

echo "== the SIZE arm: only over cap, oldest-first, and bounded per pass =="
img_case c5
# 300 MiB raw store, cap 100 MiB ⇒ need ~200 MiB. Listing is newest-first (podman's own order).
echo '[{"Type":"Images","RawSize":314572800,"Size":"300MB"}]' > "$FIX/df.json"
printf 'localhost/n1:new\nlocalhost/n2:mid\nlocalhost/n3:old\n' > "$FIX/images-floor"
printf 'localhost/n1:new 104857600\nlocalhost/n2:mid 104857600\nlocalhost/n3:old 104857600\n' > "$FIX/sizes"
out="$(GCLIB FD_STORE_CAP_MB=100 2>&1)"
[ "$(head -1 "$PODLOG.rmi")" = "untagged localhost/n3:old" ] \
  && ok "eviction starts at the OLDEST (the listing is reversed into LRU order)" \
  || no "did not start with the oldest" "$(cat "$PODLOG.rmi")"
[ "$(grep -c . "$PODLOG.rmi")" = 2 ] \
  && ok "it stops once under cap (2 of 3 evicted), it does not empty the store" \
  || no "wrong eviction count" "$(cat "$PODLOG.rmi")"
grep -q "n1:new" "$PODLOG.rmi" && no "the NEWEST image was evicted" || ok "the newest image survives"
grep -q 'store 300M > cap 100M' <<<"$out" && ok "the overage is reported with both numbers" || no "no size report" "$out"
# the eviction bound caps a single pass
img_case c6
echo '[{"Type":"Images","RawSize":314572800,"Size":"300MB"}]' > "$FIX/df.json"
printf 'localhost/n1:new\nlocalhost/n2:mid\nlocalhost/n3:old\n' > "$FIX/images-floor"
out="$(GCLIB FD_STORE_CAP_MB=100 FD_STORE_EVICT_MAX=1 2>&1)"
{ [ "$(grep -c . "$PODLOG.rmi")" = 1 ] && grep -q 'eviction bound 1 reached' <<<"$out"; } \
  && ok "FD_STORE_EVICT_MAX bounds the pass and says the next one continues" \
  || no "eviction bound not honoured" "$out$(cat "$PODLOG.rmi")"

echo "== an UNDER-cap store evicts nothing; an UNREADABLE size evicts nothing and still rc 0 =="
img_case c7
echo '[{"Type":"Images","RawSize":1048576,"Size":"1MB"}]' > "$FIX/df.json"
printf 'localhost/n1:new\n' > "$FIX/images-floor"
out="$(GCLIB FD_STORE_CAP_MB=100 2>&1)"; rc=$?
{ [ ! -s "$PODLOG.rmi" ] && [ "$rc" = 0 ]; } && ok "under cap → no eviction (rc 0)" || no "evicted under cap" "$out"
img_case c8
echo 'not json at all' > "$FIX/df.json"
out="$(GCLIB FD_STORE_CAP_MB=1 2>&1)"; rc=$?
{ [ ! -s "$PODLOG.rmi" ] && [ "$rc" = 0 ] && grep -q 'store size unreadable' <<<"$out"; } \
  && ok "unreadable store size → no eviction, rc 0, and it says so" || no "acted on an unreadable size (rc=$rc)" "$out"
echo '[{"Type":"Images","RawSize":1,"Size":"1B"}]' > "$FIX/df.json"; : > "$FIX/images-floor"; : > "$FIX/sizes"

echo "===== PART D — the wrapper: one pass, exit 0, and a missing GC never breaks a build ====="

echo "== build-throwaway.sh --sweep-only enforces every bound in one pass and exits 0 =="
reset_case d1
mkdir -p "$CASE/store" "$CASE/bin"
mkfile "$CASE/dnf/ancient.rpm" "100 days ago"
mkdir_aged "$CASE/git/e2e-alpha" "1 day ago"
echo "SHIPPED 0" > "$ORACLE_DIR/e2e-alpha"
printf 'e2e-alpha\n' > "$SCOPE_LIST"
ln -s "$FIX/podman.sh" "$CASE/bin/podman"          # the wrapper's own sweep calls `podman` by name
out="$(GC PATH="$CASE/bin:$PATH" bash "$WRAP" --sweep-only 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "--sweep-only exits 0" || no "--sweep-only rc=$rc" "$out"
{ ! have "$CASE/dnf/ancient.rpm" && ! have "$CASE/git/e2e-alpha"; } \
  && ok "one pass enforced the dnf AGE bound and the per-repo COMPLETION release" \
  || no "a bound was not enforced in the sweep" "$out"
grep -q 'image prune' "$PODLOG" && ok "and the image-store bound ran in the same pass" || no "image bound skipped" "$(cat "$PODLOG")"

echo "== a missing GC library WARNS loudly and still exits 0 — a build is never blocked by it (R39) =="
reset_case d2
mkdir -p "$CASE/iso" "$CASE/bin"
cp "$WRAP" "$CASE/iso/build-throwaway.sh"          # no sibling asset-cache.sh beside it
ln -s "$FIX/podman.sh" "$CASE/bin/podman"
out="$(GC PATH="$CASE/bin:$PATH" bash "$CASE/iso/build-throwaway.sh" --sweep-only 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && grep -q 'NO cache bound is being enforced' <<<"$out"; } \
  && ok "rc 0 with a loud, specific warning" || no "missing library not handled (rc=$rc)" "$out"

echo "===== PART E — mutations run in-suite (each must genuinely change the copy) ====="

mutate(){ # <name> <sed-expr> <must-appear> → prints the mutant path, or empty if the sed was vacuous
  local n="$1" expr="$2" needle="$3"
  local m="$TMP/mut-$n.sh"          # a separate `local`: bash expands a whole command line BEFORE it
                                    # assigns, so `local n=$1 m=…$n…` would read an unset n (set -u).
  sed "$expr" "$LIB" > "$m"
  # `-e` is load-bearing: several needles begin with `-` and would otherwise be read as grep options.
  if cmp -s "$m" "$LIB" || ! grep -qF -e "$needle" "$m"; then printf ''; else printf '%s' "$m"; fi
}

echo "== neutralize the shared-release fold → a cache releases while a repo still has drivable work =="
M="$(mutate shared 's/^ac_shared_release(){/ac_shared_release(){ printf RELEASE; return;/' 'printf RELEASE; return;')"
if [ -z "$M" ]; then no "mutation VACUOUS (ac_shared_release not neutralized)"; else
  reset_case e1
  mkfile "$CASE/dnf/warm.rpm" "10 days ago"
  printf 'e2e-alpha\ne2e-beta\n' > "$SCOPE_LIST"
  echo "SHIPPED 0" > "$ORACLE_DIR/e2e-alpha"; echo "OPEN 5" > "$ORACLE_DIR/e2e-beta"
  GC bash "$M" --gc >/dev/null 2>&1
  have "$CASE/dnf/warm.rpm" \
    && no "mutant still HELD ⇒ the B2 row would not discriminate" \
    || ok "mutant releases with work still open ⇒ the fold is what holds the shared cache"
fi

echo "== neutralize the missing-dir skip → the pass acts on a cache that is not there =="
M="$(mutate skip 's/if \[ ! -d "\$dir" \]; then continue; fi/if false; then continue; fi/' 'if false; then continue; fi')"
if [ -z "$M" ]; then no "mutation VACUOUS (missing-dir skip not neutralized)"; else
  reset_case e2                                     # no store dir created
  GC bash "$M" --gc >/dev/null 2>&1
  [ -s "$PODLOG" ] \
    && ok "mutant invokes podman for an absent store ⇒ the skip is what prevents it" \
    || no "mutant did not act on the absent cache ⇒ the A4 row would not discriminate"
fi

echo "== neutralize the LRU order → the NEWEST entry is evicted instead of the oldest =="
M="$(mutate lru 's/-printf .%T@\\t%s\\t%p\\n. 2>\/dev\/null | sort -rn/-printf "%T@\\t%s\\t%p\\n" 2>\/dev\/null | sort -n/' 'sort -n)')"
if [ -z "$M" ]; then no "mutation VACUOUS (the file arm's sort was not reversed)"; else
  reset_case e3
  mkfile "$CASE/dnf/a-oldest.rpm" "3 days ago" 1048576
  mkfile "$CASE/dnf/b-middle.rpm" "2 days ago" 1048576
  mkfile "$CASE/dnf/c-newest.rpm" "1 day ago"  1048576
  # env BEFORE the command — `GC` forwards "$@" to `env`, so a trailing assignment would become an ARG.
  GC FD_DNF_CACHE_MAX_AGE_DAYS=3650 FD_DNF_CACHE_CAP_MB=2 bash "$M" --gc >/dev/null 2>&1
  { ! have "$CASE/dnf/c-newest.rpm" && have "$CASE/dnf/a-oldest.rpm"; } \
    && ok "mutant evicts the NEWEST ⇒ the oldest-first row discriminates on that sort" \
    || no "mutant did not invert the order ⇒ the A3 row may pass vacuously" "$(ls "$CASE/dnf")"
fi

echo "== neutralize the in-use refusal → an image a build is holding is reported reaped =="
M="$(mutate inuse 's/rmi "$ref"/rmi -f "$ref"/' 'rmi -f "$ref"')"
if [ -z "$M" ]; then no "mutation VACUOUS (the non-forced rmi was not changed)"; else
  img_case e4
  printf 'registry.fedoraproject.org/fedora:44\n' > "$FIX/images-aged"
  printf 'registry.fedoraproject.org/fedora:44\n' > "$FIX/inuse"
  GC FD_STORE_MAX_AGE_H=1440 bash "$M" --gc >/dev/null 2>&1
  grep -q 'rmi -f' "$PODLOG" \
    && ok "mutant FORCES the removal ⇒ the C3 survival row rests on the rmi being non-forced" \
    || no "mutant did not force ⇒ the C3 row may pass vacuously" "$(cat "$PODLOG")"
  : > "$FIX/inuse"; : > "$FIX/images-aged"
fi

echo "== neutralize the age gate → a file well inside its age cap is pruned =="
M="$(mutate age 's/-mmin +"\$age_min" -print0/-mmin +0 -print0/' '-mmin +0 -print0')"
if [ -z "$M" ]; then no "mutation VACUOUS (the age gate was not neutralized)"; else
  reset_case e5
  mkfile "$CASE/dnf/new.rpm" "1 day ago"
  GC FD_DNF_CACHE_MAX_AGE_DAYS=3650 FD_DNF_CACHE_CAP_MB=999999 bash "$M" --gc >/dev/null 2>&1
  have "$CASE/dnf/new.rpm" \
    && no "mutant kept it ⇒ the A2 row would not discriminate" \
    || ok "mutant prunes inside the cap ⇒ the age gate is what spares a fresh file"
fi

echo "===== PART F — the stub cannot drift from podman: the REAL engine, READ-ONLY ====="
# Every query shape the stub emulates is asserted against the live engine here. Nothing destructive runs:
# these are three list/report calls. If there is no usable engine, these rows are announced as skipped by
# name (PARTS A-E already ran, so this file must NOT exit 77 — a real regression above must still fail).
if podman info >/dev/null 2>&1; then
  podman images --filter "until=1440h" --format '{{.Repository}}:{{.Tag}}' >/dev/null 2>&1 \
    && ok "real engine accepts --filter until=<h> (the aged-unused listing)" || no "until=<h> filter rejected"
  podman images --sort=created --filter "until=720m" --format '{{.Repository}}:{{.Tag}}' >/dev/null 2>&1 \
    && ok "real engine accepts --sort=created with --filter until=<m> (the LRU listing)" || no "sort/until rejected"
  # The RawSize extraction is the exact pipeline the size arm runs — pinned end to end, not by eyeball.
  raw="$(podman system df --format json 2>/dev/null | tr ',' '\n' | sed -n 's/.*"RawSize":\([0-9]\+\).*/\1/p' | head -1)"
  case "${raw:-x}" in ''|*[!0-9]*) no "the size arm's RawSize parse yields no number against the real engine" "$raw";;
    *) ok "the size arm's RawSize parse yields a number from the real engine (${raw}B)";; esac
  podman image prune --help 2>/dev/null | grep -q -- '--filter' \
    && ok "real 'image prune' accepts --filter (the age-floored dangling reap)" || no "prune --filter unsupported"
else
  echo "  note: real-engine parity rows skipped — no usable podman here (PARTS A-E ran in full)"
fi

echo; echo "asset-cache.test: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
