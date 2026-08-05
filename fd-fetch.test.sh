#!/usr/bin/env bash
# fd-fetch.test.sh — proves the pinned-download cache SERVES without fetching, REFUSES without
# publishing, and stays BOUNDED — and that the two Tier-1 builds and the parity check are actually WIRED
# to it (fedora-dev#320, objective #311).
#
# THE AXIS UNDER TEST is not "does it run" but WHETHER A BYTE MOVED. The defect this feature exists to
# fix was invisible to every "a cache exists" assertion — buildah reports a layer-cache HIT on
# `ADD <url>` and still transfers the whole file (MEASURED: 10 378 KiB pulled under `Using cache
# e17eb17e7b87`, reproduced in-box 2026-07-30). So the rows here assert the FETCH COUNT, not a log line
# claiming a hit: the transport is stubbed by a RECORDER on PATH, and a cache HIT must invoke it ZERO
# times. That stub is also why no row touches the network.
#
# AND WHETHER A GUARD WITHHELD SOMETHING. A cache that publishes unverified bytes is worse than no cache
# — it makes one bad download permanent — so the mismatch rows assert the ABSENCE of three things (no
# cache entry, no partial, no <dest>), and mutation E1 removes the check to prove those absences are the
# guard's doing rather than an accident of the fixture.
#
# WIRING IS TESTED SEPARATELY FROM LOGIC, because a pure core cannot see that nothing calls it (#278's
# first cut shipped a router with zero call sites and a green selftest). PART D drives the REAL
# build-throwaway.sh --sweep-only, the REAL check-build-parity.sh and the REAL validate.sh T0b line.
#
# FIVE MUTATIONS RUN IN-SUITE (BP8), each vacuity-guarded — a sed that did not genuinely change the copy
# FAILS its row rather than passing over an unmutated file:
#   E1 verify-before-publish neutralized → the mismatch fixture publishes a poisoned entry and writes <dest>
#   E2 the HIT arm neutralized           → the zero-fetch row invokes the transport again
#   E3 the age-prune neutralized         → a 60-day-old entry survives the bound
#   E4 the LRU evict neutralized         → an over-cap cache keeps every entry
#   E5 the fd-dl bind removed from a validate.sh copy → parity goes HARD DRIFT (rc 1) and T0b FAILS
#      (the #53 direction must keep biting; only the T2-half-pending direction is allowed to be rc 3)
#
#   bash fd-fetch.test.sh   -> exit 0 = all rows pass
# No GitHub, no network, no model, no container engine (podman is stubbed for the sweep-wiring row).
# Run after touching bin/fd-fetch.sh, either Tier-1 build's binds, or the parity check.
set -uo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
SUT="$REPO/bin/fd-fetch.sh"
BT="$REPO/bin/build-throwaway.sh"
CBP="$REPO/bin/check-build-parity.sh"
VAL="$REPO/bin/validate.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/fdfetch.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then printf '  PASS: %s\n' "$1"; pass=$((pass+1))
      else printf '  FAIL: %s\n        got=[%s]\n       want=[%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
ok(){ printf '  PASS: %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL: %s — %s\n' "$1" "$2"; fail=$((fail+1)); }

for f in "$SUT" "$BT" "$CBP" "$VAL"; do [ -f "$f" ] || { echo "missing subject: $f"; exit 2; }; done

# ---- the transport RECORDER (this is what makes "zero network bytes" a measurement, not a claim) -----
mkdir -p "$TMP/stub"
cat > "$TMP/stub/curl" <<'EOF'
#!/usr/bin/env bash
# stub curl — records the call, then serves $STUB_BODY or fails. No row reaches the network.
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
printf 'curl %s\n' "$*" >> "${STUB_LOG:?stub needs STUB_LOG}"
case "${STUB_MODE:-ok}" in
  fail) exit 22;;
  *)    [ -n "$out" ] || exit 3; cat "${STUB_BODY:?stub needs STUB_BODY}" > "$out";;
esac
EOF
# wget is stubbed too: fd-fetch falls back to it when curl is absent, and an un-recorded fallback would
# let a "zero fetches" row pass while bytes moved on the other transport.
sed 's/^# stub curl/# stub wget/; s/printf .curl /printf '"'"'wget /' "$TMP/stub/curl" > "$TMP/stub/wget"
cat > "$TMP/stub/podman" <<'EOF'
#!/usr/bin/env bash
# stub podman — the sweep-wiring row must not touch the real engine. Answers nothing, successfully.
exit 0
EOF
chmod 755 "$TMP/stub"/*
PATH="$TMP/stub:$PATH"; export PATH

# fixture asset + its real sha256 (computed here, so the rows cannot drift from the bytes)
BODY="$TMP/asset.bin"; printf 'pinned-vendor-asset-v1\n' > "$BODY"
SHA="$(sha256sum "$BODY" | cut -d' ' -f1)"
OTHER="$TMP/other.bin"; printf 'a-DIFFERENT-artifact\n' > "$OTHER"
URL="https://example.invalid/vendor/asset-v1.tar.gz"

# run_fetch <cache-dir|''> <mode> <body> <sha> <dest> [extra env…] — one fetch attempt with a FRESH
# recorder log. Prints "<rc>|<fetch-count>"; stdout+stderr land in $TMP/out.log for message rows.
FETCHES=0; RC=0
run_fetch(){
  local cache="$1" mode="$2" body="$3" sha="$4" dest="$5"; shift 5
  : > "$TMP/fetch.log"
  env STUB_LOG="$TMP/fetch.log" STUB_MODE="$mode" STUB_BODY="$body" FD_DL_CACHE="$cache" "$@" \
      bash "$SUT" "$URL" "$sha" "$dest" >"$TMP/out.log" 2>&1
  RC=$?
  FETCHES="$(wc -l < "$TMP/fetch.log" | tr -d ' ')"
}
entries(){ find "$1" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '; }

echo "== PART A — the contract refuses before any byte moves =="
bash -n "$SUT" 2>/dev/null; ck "A1 bin/fd-fetch.sh parses" "$?" "0"
st="$(bash "$SUT" --selftest 2>&1)"; st_rc=$?
ck "A1 --selftest rc" "$st_rc" "0"
# rc alone would pass against a script with no --selftest at all; demand the summary it prints.
ck "A1 --selftest actually ran rows" \
   "$(printf '%s\n' "$st" | grep -c '^fd-fetch selftest: [1-9][0-9]* passed, 0 failed$')" "1"

C="$TMP/c-refuse"; mkdir -p "$C"
run_fetch "$C" ok "$BODY" "not-a-sha256" "$TMP/d-badpin"
ck "A2 a non-sha256 pin → rc 1, ZERO fetches, no dest" \
   "$RC|$FETCHES|$([ -e "$TMP/d-badpin" ] && echo dest || echo nodest)" "1|0|nodest"
: > "$TMP/fetch.log"
env STUB_LOG="$TMP/fetch.log" STUB_MODE=ok STUB_BODY="$BODY" FD_DL_CACHE="$C" \
    bash "$SUT" "http://example.invalid/asset.tgz" "$SHA" "$TMP/d-http" >/dev/null 2>&1
ck "A3 a non-https URL → rc 1, ZERO fetches, no dest" \
   "$?|$(wc -l < "$TMP/fetch.log" | tr -d ' ')|$([ -e "$TMP/d-http" ] && echo dest || echo nodest)" "1|0|nodest"
ck "A4 neither refusal published anything" "$(entries "$C")" "0"

echo "== PART B — miss fetches once, HIT fetches NOTHING, mismatch publishes nothing =="
C="$TMP/c-main"; mkdir -p "$C"; D="$TMP/dest/asset.tgz"
run_fetch "$C" ok "$BODY" "$SHA" "$D"
ck "B1 MISS: rc 0, fetched exactly ONCE" "$RC|$FETCHES" "0|1"
ck "B1 MISS: <dest> holds the verified bytes" "$(cmp -s "$D" "$BODY" && echo same || echo differs)" "same"
ck "B1 MISS: published under the content key" "$([ -f "$C/$SHA" ] && echo yes || echo no)" "yes"
ck "B1 MISS: exactly one cache entry, no partial left" "$(entries "$C")" "1"

rm -f "$D"
# The transport is set to FAIL for this row: if the HIT arm did not serve it, the row cannot pass at all.
run_fetch "$C" fail "$BODY" "$SHA" "$D"
ck "B2 HIT: rc 0 with ZERO fetches — no bytes crossed the network" "$RC|$FETCHES" "0|0"
ck "B2 HIT: <dest> restored from cache" "$(cmp -s "$D" "$BODY" && echo same || echo differs)" "same"
ck "B2 HIT: said so out loud" "$(grep -c 'HIT .*0 bytes fetched' "$TMP/out.log")" "1"

C2="$TMP/c-mismatch"; mkdir -p "$C2"; D2="$TMP/dest/bad.tgz"
run_fetch "$C2" ok "$OTHER" "$SHA" "$D2"          # the transport serves DIFFERENT bytes than the pin
ck "B3 MISMATCH: rc 1" "$RC" "1"
ck "B3 MISMATCH: <dest> ABSENT" "$([ -e "$D2" ] && echo dest || echo nodest)" "nodest"
ck "B3 MISMATCH: cache is EMPTY — no entry AND no partial" "$(entries "$C2")" "0"
ck "B3 MISMATCH: names both hashes so the pin can be fixed" \
   "$(grep -c 'SHA256 MISMATCH' "$TMP/out.log")" "1"
# A pre-existing <dest> must survive a refused fetch (put_dest never touches it until bytes verify).
printf 'PRIOR\n' > "$TMP/dest/keep.tgz"
run_fetch "$C2" ok "$OTHER" "$SHA" "$TMP/dest/keep.tgz"
ck "B4 MISMATCH never clobbers an existing <dest>" \
   "$RC|$(cat "$TMP/dest/keep.tgz")" "1|PRIOR"

C3="$TMP/c-corrupt"; mkdir -p "$C3"; printf 'CORRUPTED\n' > "$C3/$SHA"; D3="$TMP/dest/heal.tgz"
run_fetch "$C3" ok "$BODY" "$SHA" "$D3"
ck "B5 a CORRUPT entry is not trusted: re-fetched once, healed" "$RC|$FETCHES" "0|1"
ck "B5 the healed entry now hashes to its own name" \
   "$(sha256sum "$C3/$SHA" | cut -d' ' -f1)" "$SHA"
ck "B5 and it said the entry was corrupt" "$(grep -c 'CORRUPT cache entry' "$TMP/out.log")" "1"

# NO-CACHE mode: the CI base build / monthly --no-cache rebuild has no bind. It must still fetch and
# verify — and must NOT create a cache dir, because entries written there would land in an image layer.
H="$TMP/nocache-home"; mkdir -p "$H"
run_fetch "" ok "$BODY" "$SHA" "$TMP/dest/nocache.tgz" HOME="$H"
ck "B6 NO-CACHE: rc 0, fetched once, <dest> verified" \
   "$RC|$FETCHES|$(cmp -s "$TMP/dest/nocache.tgz" "$BODY" && echo same || echo differs)" "0|1|same"
ck "B6 NO-CACHE: created NO cache directory (no image-layer bloat)" \
   "$([ -e "$H/.cache/fd-dl" ] && echo created || echo none)" "none"
if [ -d /var/cache/fd-dl ]; then
  ok "B6 (the 'nothing published' message row is N/A here — /var/cache/fd-dl exists on this box)"
else
  ck "B6 NO-CACHE: disclosed it published nothing" "$(grep -c 'no cache directory' "$TMP/out.log")" "1"
fi

C4="$TMP/c-prefetch"
: > "$TMP/fetch.log"
env STUB_LOG="$TMP/fetch.log" STUB_MODE=ok STUB_BODY="$BODY" FD_DL_CACHE="$C4" \
    bash "$SUT" --prefetch "$URL" "$SHA" >/dev/null 2>&1
ck "B7 --prefetch creates the cache, publishes, lands no dest" \
   "$?|$([ -f "$C4/$SHA" ] && echo pub || echo nopub)|$(entries "$C4")" "0|pub|1"

echo "== PART C — the bound: age-prune, LRU-evict, stale partials (BP10 storage safety) =="
mkcache(){ # a fixture cache: <dir> then <name>:<age-days> pairs (60-byte entries)
  local d="$1"; shift; mkdir -p "$d"
  local spec n a
  for spec in "$@"; do n="${spec%%:*}"; a="${spec##*:}"
    head -c 60 /dev/zero | tr '\0' 'x' > "$d/$n"
    [ "$a" = 0 ] || touch -d "$a days ago" "$d/$n"
  done
}
K1="$(printf '1%.0s' $(seq 64))"; K2="$(printf '2%.0s' $(seq 64))"; K3="$(printf '3%.0s' $(seq 64))"
G="$TMP/c-age"; mkcache "$G" "$K1:60" "$K2:0" "README:60" ".part-.stale:0"
FD_DL_CACHE="$G" bash "$SUT" --gc >"$TMP/gc.log" 2>&1
ck "C1 age-prune removes an entry unused >45d" "$([ -e "$G/$K1" ] && echo kept || echo gone)" "gone"
ck "C1 …and keeps the fresh one"               "$([ -e "$G/$K2" ] && echo kept || echo gone)" "kept"
ck "C1 …and never touches a non-entry file"    "$([ -e "$G/README" ] && echo kept || echo gone)" "kept"
ck "C1 …and leaves a FRESH partial alone (a concurrent in-flight download)" \
   "$([ -e "$G/.part-.stale" ] && echo kept || echo gone)" "kept"

G2="$TMP/c-lru"; mkcache "$G2" "$K1:2" "$K2:1" "$K3:0"
FD_DL_CACHE="$G2" FD_DL_CACHE_CAP_BYTES=100 FD_DL_CACHE_MAX_AGE_DAYS=3650 \
  bash "$SUT" --gc >"$TMP/gc-lru.log" 2>&1
ck "C2 LRU-evict keeps the most-recently-used entry" "$([ -e "$G2/$K3" ] && echo kept || echo gone)" "kept"
ck "C2 …and evicts the least-recently-used ones"     "$([ -e "$G2/$K1" ] || [ -e "$G2/$K2" ] && echo kept || echo gone)" "gone"
ck "C2 …and said why"                                "$(grep -c 'size-prune' "$TMP/gc-lru.log")" "2"

G3="$TMP/c-part"; mkdir -p "$G3"
: > "$G3/.part-.old"; touch -d '2 days ago' "$G3/.part-.old"
: > "$G3/.part-.new"
FD_DL_CACHE="$G3" bash "$SUT" --gc >/dev/null 2>&1
ck "C3 a STALE partial download is reaped (kill-9 residue)" "$([ -e "$G3/.part-.old" ] && echo kept || echo gone)" "gone"
ck "C3 a FRESH partial is not"                              "$([ -e "$G3/.part-.new" ] && echo kept || echo gone)" "kept"
FD_DL_CACHE="$TMP/c-absent" bash "$SUT" --gc >/dev/null 2>&1
ck "C4 --gc on an absent cache is a quiet rc 0" "$?" "0"

echo "== PART D — the WIRING (what a pure core is structurally blind to) =="
# D1: the bound is enforced from build-throwaway.sh's sweeper, so every throwaway build applies it.
G4="$TMP/c-sweep"; mkcache "$G4" "$K1:60" "$K2:0"
BH="$TMP/bthome"; mkdir -p "$BH/.cache"
env HOME="$BH" FD_DL_CACHE="$G4" bash "$BT" --sweep-only >"$TMP/sweep.log" 2>&1
ck "D1 build-throwaway --sweep-only enforces the download-cache bound" \
   "$([ -e "$G4/$K1" ] && echo kept || echo gone)|$([ -e "$G4/$K2" ] && echo kept || echo gone)" "gone|kept"

# D2: both Tier-1 builds bind the cache AND create it (fd-fetch never conjures a cache dir).
for f in "$BT" "$VAL"; do
  b="$(basename "$f")"
  ck "D2 $b binds the cache into the build" \
     "$(grep -cE -- '-v "\$DL_CACHE:/var/cache/fd-dl:rw"' "$f")" "1"
  ck "D2 $b creates it (the mount's owner does)" \
     "$([ "$(grep -cE 'mkdir -p "\$DNF_CACHE" "\$DL_CACHE"' "$f")" -ge 1 ] && echo yes || echo no)" "yes"
done
# The in-build path is written LITERALLY at each call site — a variable target would make the parity
# check unable to read the flag it exists to check (see has_bind's comment there) — so both ends must
# name the SAME path fd-fetch.sh resolves.
ck "D2 …is the one fd-fetch.sh resolves" "$(grep -c 'BUILD_CACHE="/var/cache/fd-dl"' "$SUT")" "1"
ck "D2 a COMMENT alone cannot satisfy the parity check (it reads code, not prose)" \
   "$(printf '#!/bin/bash\n# -v x:/var/cache/fd-dl:rw is documented here\npodman build -t x .\n' > "$TMP/prose.sh"; \
      grep -v '^[[:space:]]*#' "$TMP/prose.sh" | grep -cE -- '-v[[:space:]]+"?[^"[:space:]]*:/var/cache/fd-dl(:[a-z,]+)?"?')" "0"

# D3: the parity check knows the new bind, and its DIRECTION rule holds. A host reference WITH the bind
# is the acceptance's PARITY: OK; a host reference WITHOUT it must say DRIFT rather than pass vacuously.
mkhost(){ mkdir -p "$1"; { echo '#!/usr/bin/env bash'; printf 'podman build ${BUILD_ARGS:-} -v "$FD_DNF_CACHE:/var/cache/libdnf5:rw,z" %s -t x -f y z\n' "$2"; } > "$1/build-candidate.sh"; }
mkhost "$TMP/host-ok" '-v "$FD_DL_CACHE:/var/cache/fd-dl:rw,z"'
mkhost "$TMP/host-pending" ''
out="$(FD_BOOTSTRAP="$TMP/host-ok" bash "$CBP" 2>&1)"; rc=$?
ck "D3 all three carry the bind → PARITY: OK, rc 0" \
   "$rc|$(grep -c '^PARITY: OK$' <<<"$out")" "0|1"
out="$(FD_BOOTSTRAP="$TMP/host-pending" bash "$CBP" 2>&1)"; rc=$?
ck "D3 host half missing → rc 3 (disclosed), never 0" "$rc" "3"
ck "D3 …and it NAMES the drift instead of passing quietly" \
   "$(grep -c 'DRIFT.*build-candidate' <<<"$out")|$(grep -c '^PARITY: DRIFT' <<<"$out")" "1|1"
ck "D3 …and says it is a bandwidth gap, not a false GREEN" \
   "$(grep -c 'NOT a false GREEN' <<<"$out")" "1"

# D4: validate.sh READS that rc — the pending Tier-2 half must not gate every in-box validation.
FR="$TMP/fixrepo"; mkdir -p "$FR"; printf 'FROM scratch\nCMD ["/x"]\n' > "$FR/Containerfile"
out="$(FD_BOOTSTRAP="$TMP/host-pending" bash "$VAL" "$FR" Containerfile nobuild 2>&1)"
ck "D4 T0b reports the pending host half as PENDING, not FAIL" \
   "$(grep -c 'build-parity *PENDING' <<<"$out")|$(grep -c 'build-parity *FAIL' <<<"$out")" "1|0"
out="$(FD_BOOTSTRAP="$TMP/host-ok" bash "$VAL" "$FR" Containerfile nobuild 2>&1)"
ck "D4 …and PASS once the host half is there" "$(grep -c 'build-parity *PASS' <<<"$out")" "1"

echo "== PART E — mutations (each sed must genuinely change the copy, else the row is vacuous) =="
mutate(){ # mutate <src> <dst> <sed-expr> → rc 0 if the copy really differs
  cp "$1" "$2" || return 1
  sed -i "$3" "$2" || return 1
  ! cmp -s "$1" "$2"
}

# E1: the verify-before-publish check is what withholds a poisoned entry — not the fixture.
M="$TMP/m1-fd-fetch.sh"
if mutate "$SUT" "$M" 's|if ! hash_ok "$key" "$actual"; then|if false; then|'; then
  : > "$TMP/fetch.log"; CM="$TMP/c-m1"; mkdir -p "$CM"
  env STUB_LOG="$TMP/fetch.log" STUB_MODE=ok STUB_BODY="$OTHER" FD_DL_CACHE="$CM" \
      bash "$M" "$URL" "$SHA" "$TMP/dest/m1.tgz" >/dev/null 2>&1
  ck "E1 verify neutralized ⇒ a poisoned entry IS published and <dest> written" \
     "$(entries "$CM")|$([ -e "$TMP/dest/m1.tgz" ] && echo dest || echo nodest)" "1|dest"
else no "E1 verify-before-publish mutation" "VACUOUS — the sed changed nothing"; fi

# E2: the HIT arm is what serves the cache — with it gone, the same fixture must go back to the network.
M="$TMP/m2-fd-fetch.sh"
if mutate "$SUT" "$M" 's|= HIT ]; then|= NEVER ]; then|'; then
  : > "$TMP/fetch.log"
  env STUB_LOG="$TMP/fetch.log" STUB_MODE=ok STUB_BODY="$BODY" FD_DL_CACHE="$C" \
      bash "$M" "$URL" "$SHA" "$TMP/dest/m2.tgz" >/dev/null 2>&1
  ck "E2 HIT arm neutralized ⇒ the transport is invoked again (so B2's zero is the cache's doing)" \
     "$(wc -l < "$TMP/fetch.log" | tr -d ' ')" "1"
else no "E2 HIT-arm mutation" "VACUOUS — the sed changed nothing"; fi

# E3 / E4: the two halves of the bound each bite.
M="$TMP/m3-fd-fetch.sh"
if mutate "$SUT" "$M" 's|-mtime +"$MAX_AGE_DAYS"|-mtime +999999|'; then
  G5="$TMP/c-m3"; mkcache "$G5" "$K1:60"
  FD_DL_CACHE="$G5" bash "$M" --gc >/dev/null 2>&1
  ck "E3 age-prune neutralized ⇒ a 60-day-old entry SURVIVES" "$([ -e "$G5/$K1" ] && echo kept || echo gone)" "kept"
else no "E3 age-prune mutation" "VACUOUS — the sed changed nothing"; fi
M="$TMP/m4-fd-fetch.sh"
if mutate "$SUT" "$M" 's|if \[ "$running" -gt "$CAP_BYTES" \]; then|if false; then|'; then
  G6="$TMP/c-m4"; mkcache "$G6" "$K1:2" "$K2:1" "$K3:0"
  FD_DL_CACHE="$G6" FD_DL_CACHE_CAP_BYTES=100 FD_DL_CACHE_MAX_AGE_DAYS=3650 bash "$M" --gc >/dev/null 2>&1
  ck "E4 LRU evict neutralized ⇒ an over-cap cache keeps EVERY entry" "$(entries "$G6")" "3"
else no "E4 LRU-evict mutation" "VACUOUS — the sed changed nothing"; fi

# E5: the #53 direction must still be a HARD failure. A Tier-1 build that lacks a bind the host build
# HAS is the false-GREEN shape — rc 1, and validate.sh's own T0b must FAIL on it.
MB="$TMP/mbin"; mkdir -p "$MB"; cp "$REPO"/bin/*.sh "$MB/" 2>/dev/null
if mutate "$VAL" "$MB/validate.sh" 's|-v "$DL_CACHE:/var/cache/fd-dl:rw" ||'; then
  out="$(FD_BOOTSTRAP="$TMP/host-ok" bash "$MB/check-build-parity.sh" 2>&1)"; rc=$?
  ck "E5 a Tier-1 build missing the bind ⇒ HARD DRIFT rc 1 (the #53 direction still bites)" \
     "$rc|$(grep -c '^PARITY: DRIFT$' <<<"$out")" "1|1"
  out="$(FD_BOOTSTRAP="$TMP/host-ok" bash "$MB/validate.sh" "$FR" Containerfile nobuild 2>&1)"
  ck "E5 …and T0b FAILS on it (rc 1 is never softened to PENDING)" \
     "$(grep -c 'build-parity *FAIL' <<<"$out")|$(grep -c 'build-parity *PENDING' <<<"$out")" "1|0"
else no "E5 Tier-1-bind mutation" "VACUOUS — the sed changed nothing"; fi

printf '\nfd-fetch.test.sh: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
