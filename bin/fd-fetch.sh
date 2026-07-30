#!/usr/bin/env bash
# fd-fetch.sh — the CACHE-AWARE PINNED FETCH: serve a pinned vendor download from a local
# content-addressed cache instead of re-fetching it on every build (fedora-dev#320, objective #311).
#
# WHY IT EXISTS — a MEASURED defect, not a suspicion. Two consecutive builds in the dev box's own
# nested engine (2026-07-30) of:
#
#     FROM registry.fedoraproject.org/fedora-minimal:44
#     ADD https://github.com/FreeRDP/FreeRDP/archive/refs/tags/3.14.0.tar.gz /tmp/frdp.tar.gz
#
#   | build | podman says                    | bytes actually pulled (eth0 rx delta) |
#   |-------|--------------------------------|---------------------------------------|
#   | 1     | STEP 2/2: ADD …                | 10 432 KiB                            |
#   | 2     | --> Using cache e6e77588d5f3   | 10 413 KiB                            |
#
# Buildah reports a layer-cache HIT on `ADD <url>` and STILL transfers the whole file: it downloads the
# URL in order to compute the cache key, then throws the bytes away. So for every pinned vendor asset in
# the fleet the layer cache buys NOTHING for bandwidth, and no "a cache mechanism exists" assertion would
# ever have caught that — only the byte measurement did (which is exactly what objective #311 asks for).
#
# THE CONTRACT (this is what replaces `ADD <url>` for a PINNED asset):
#
#     RUN fd-fetch.sh <https-url> <sha256> <dest>        # inside a build (cache bound at /var/cache/fd-dl)
#     bin/fd-fetch.sh --prefetch <https-url> <sha256>    # host-side, populate the cache ahead of a build
#
# PROVENANCE IS STRENGTHENED, NOT LOOSENED (Build Principle 2 / the class-(c) grades). The pin is
# verified FAIL-CLOSED on EVERY path, the cache included:
#   * a MISS fetches once over TLS, verifies the sha256 BEFORE publishing anything, and on a mismatch
#     publishes NOTHING and leaves <dest> ABSENT (the build fails; a poisoned byte can never be cached);
#   * a HIT re-hashes the cached bytes against the key before serving them, so a corrupted or tampered
#     cache entry is REMOVED and re-fetched rather than trusted (a cache is not a trust boundary);
#   * a non-https URL, or a "sha256" that is not 64 hex chars, is refused BEFORE any byte moves.
# It is therefore strictly stronger than the `ADD <url>` it replaces (which verifies nothing at all) and
# than a bare `curl -fsSL` (which verifies only the TLS channel, never the artifact).
#
# CACHE RESOLUTION — in order, first match wins:
#   1. $FD_DL_CACHE            an explicit caller always wins (host-side prefetch, the GC, the tests).
#   2. /var/cache/fd-dl        the FIXED build-time bind path (bin/build-throwaway.sh + bin/validate.sh
#                              bind $HOME/.cache/fd-dl there, alongside the dnf package cache).
#   3. $HOME/.cache/fd-dl      the dev box's own cache, for host-side use outside a build.
#   ...else NO-CACHE MODE: a verified fetch straight to <dest>, nothing published, said out loud.
#
# INVARIANT — fd-fetch NEVER CREATES A CACHE DIRECTORY (only `--prefetch` does, an explicit host-side
# op). That ONE rule is what keeps a build with no bind — the CI base build, the monthly `--no-cache`
# rebuild — from writing cache entries INTO AN IMAGE LAYER: no directory ⇒ NO-CACHE mode ⇒ a plain
# verified fetch. The mount's owner creates the directory; a build never conjures one.
#
# BOUNDS (BP10 storage-safety — the cache is the one PERSISTENT thing here, so it is bounded by this
# script, not by hope): `--gc` age-prunes entries unused for more than FD_DL_CACHE_MAX_AGE_DAYS, then
# LRU-evicts to FD_DL_CACHE_CAP_GB, then reaps stale partial downloads. Age-then-LRU is the same shape
# as build-throwaway.sh's gc_dnf_cache(), and it is CALLED from that script's sweep_orphans() /
# `--sweep-only` path, so every throwaway build enforces the bound. Both caps read LAST-USE time (a HIT
# touches its entry), so a hot pin is never aged out and a pin nobody has wanted for 45 days goes.
#
# VERBS / EXIT CODES:
#   fd-fetch.sh <url> <sha256> <dest>   fetch-or-serve. rc 0 = <dest> is in place and verified;
#                                       rc 1 = FAIL-CLOSED (bad pin / fetch failed / hash mismatch);
#                                       rc 2 = usage.
#   fd-fetch.sh --prefetch <url> <sha256>   populate the cache only (no <dest>).
#   fd-fetch.sh --gc                    enforce the bounds (age → LRU → stale partials).
#   fd-fetch.sh --cache-dir             print the resolved cache dir (empty line = NO-CACHE mode).
#   fd-fetch.sh --selftest              exercise the pure core (no network, no engine, no cache).
#
# ENV: FD_DL_CACHE · FD_DL_CACHE_CAP_GB (10) · FD_DL_CACHE_MAX_AGE_DAYS (45) · FD_DL_STALE_MIN (720,
#      partial-download reap age) · FD_DL_CACHE_CAP_BYTES (exact byte cap; overrides the GB cap — how
#      the test exercises LRU without a 10 GB fixture) · FD_FETCH_CONNECT_TIMEOUT · FD_FETCH_MAX_TIME.
#
# Covered by fd-fetch.test.sh (miss publishes once · hit serves with ZERO fetches · mismatch publishes
# nothing and leaves <dest> absent · corrupt entry self-heals · age-prune + LRU-evict + partial reap ·
# the build-throwaway.sh call site actually fires). MUST be tracked 100755.
set -uo pipefail

BUILD_CACHE="/var/cache/fd-dl"                       # the FIXED in-build bind path (see the parity check)
# $HOME is read at CALL time, not load time, so the resolution is testable and a caller that re-homes
# itself (the selftest, a prefetch under a different user) resolves the cache it actually has.
home_cache(){ printf '%s' "${HOME:-/root}/.cache/fd-dl"; }
PART=".part-"                                        # partial-download prefix: never a valid cache key,
                                                     # so a partial can never be mistaken for an entry
MAX_AGE_DAYS="${FD_DL_CACHE_MAX_AGE_DAYS:-45}"
STALE_MIN="${FD_DL_STALE_MIN:-720}"
CAP_GB="${FD_DL_CACHE_CAP_GB:-10}"
case "$CAP_GB" in ''|*[!0-9]*) CAP_GB=10;; esac      # a garbled cap must not disable the bound
CAP_BYTES="${FD_DL_CACHE_CAP_BYTES:-$(( CAP_GB * 1024 * 1024 * 1024 ))}"
case "$CAP_BYTES" in ''|*[!0-9]*) CAP_BYTES=$(( CAP_GB * 1024 * 1024 * 1024 ));; esac

say(){ printf 'fd-fetch: %s\n' "$*"; }
err(){ printf 'fd-fetch: %s\n' "$*" >&2; }
die(){ err "$*"; exit 1; }
usage(){ sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//'; exit "${1:-0}"; }

# ---- PURE CORE (--selftest covers exactly these) ---------------------------------------------------

# cache_key <sha256> → the cache FILENAME for a pin: the sha256 normalised to lowercase hex.
# Content-addressed, so a version bump is a NEW entry and a re-pinned same-content asset is a HIT.
# rc 1 unless the argument is EXACTLY 64 hex chars — which is also the PATH-TRAVERSAL guard, since this
# string becomes a filename under the cache dir (a "sha" of `../../etc/passwd` must resolve nowhere).
cache_key(){
  local s="${1:-}"
  s="$(printf '%s' "$s" | tr 'A-F' 'a-f')"
  case "$s" in ''|*[!0-9a-f]*) return 1;; esac
  [ "${#s}" -eq 64 ] || return 1
  printf '%s' "$s"
}

# hash_ok <expected> <actual> → rc 0 iff both are non-empty and equal, case-insensitively.
# An EMPTY side is never a match: "could not hash it" must never read as "it verified".
hash_ok(){
  local a="${1:-}" b="${2:-}"
  [ -n "$a" ] && [ -n "$b" ] || return 1
  a="$(printf '%s' "$a" | tr 'A-F' 'a-f')"; b="$(printf '%s' "$b" | tr 'A-F' 'a-f')"
  [ "$a" = "$b" ]
}

# cache_decision <cache-file> → HIT | MISS. HIT only for a NON-EMPTY regular file: a zero-byte entry is
# the shape a truncated write leaves, and serving it would fail the hash check anyway.
cache_decision(){ if [ -f "${1:-}" ] && [ -s "${1:-}" ]; then printf 'HIT'; else printf 'MISS'; fi; }

# url_tls_ok <url> → rc 0 only for https://. BP2 requires a pinned artifact to arrive over TLS from the
# vendor's own canonical channel; a plain-http or file:// "pin" is refused before any byte moves.
url_tls_ok(){ case "${1:-}" in https://?*) return 0;; *) return 1;; esac; }

# over_cap <bytes> <cap-bytes> → rc 0 iff the cache is over its size cap. Non-numeric input is NOT over
# cap (an unreadable size must not trigger a blind eviction sweep).
over_cap(){
  local b="${1:-}" c="${2:-}"
  case "$b" in ''|*[!0-9]*) return 1;; esac
  case "$c" in ''|*[!0-9]*) return 1;; esac
  [ "$b" -gt "$c" ]
}

# ---- cache dir + hashing + transport ---------------------------------------------------------------

# is_mount <dir> → rc 0 iff <dir> is a live mount point, read from /proc/self/mounts (the same mechanism
# install.sh already relies on to tell a bound /var/cache/libdnf5 from a plain directory — verified to
# work under both default and `--isolation=chroot` builds). An UNREADABLE /proc/self/mounts answers YES:
# the caller only uses this to decide whether a cache is real, and refusing a usable cache because we
# could not read /proc would trade a working build for tidiness.
is_mount(){
  local d="${1:-}"
  [ -r /proc/self/mounts ] || return 0
  grep -q " ${d} " /proc/self/mounts
}

# resolve_cache → the cache dir to use, or EMPTY for NO-CACHE mode. NEVER creates it (see INVARIANT).
resolve_cache(){
  if [ -n "${FD_DL_CACHE:-}" ]; then printf '%s' "$FD_DL_CACHE"; return 0; fi
  # The build path counts only when it is actually BOUND. An empty /var/cache/fd-dl left in an image
  # layer (a previous build's mountpoint) is a directory, not a cache — publishing into it would put
  # cache entries in the image, which is the one thing the INVARIANT above exists to prevent.
  if [ -d "$BUILD_CACHE" ] && is_mount "$BUILD_CACHE"; then printf '%s' "$BUILD_CACHE"; return 0; fi
  if [ -d "$(home_cache)" ]; then home_cache; return 0; fi
  printf ''
}

# sha256_of <file> → the file's sha256, or rc 1 if nothing on this box can compute one (fail-closed:
# an unhashable file is never published and never served).
sha256_of(){
  local f="${1:-}" out=""
  if command -v sha256sum >/dev/null 2>&1; then out="$(sha256sum -- "$f" 2>/dev/null)"
  elif command -v openssl >/dev/null 2>&1; then out="$(openssl dgst -sha256 -r -- "$f" 2>/dev/null)"
  else err "no sha256sum and no openssl — cannot verify a pin on this box"; return 1; fi
  out="${out%% *}"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# fetch_to <url> <out> → the ONE place a byte crosses the network. TLS-only, bounded, no retries beyond
# a couple of transient ones. Resolved via PATH so a test can stand a recorder in front of it.
fetch_to(){
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 --retry 2 \
         --connect-timeout "${FD_FETCH_CONNECT_TIMEOUT:-20}" --max-time "${FD_FETCH_MAX_TIME:-900}" \
         -o "$out" -- "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --https-only -O "$out" -- "$url"
  else
    err "neither curl nor wget is available — cannot fetch $url"; return 1
  fi
}

# put_dest <verified-src> <dest> → land <dest> ATOMICALLY from ALREADY-VERIFIED bytes: stage beside the
# destination, then rename. So a failure leaves NO partial <dest> and never clobbers an existing one —
# the fail-closed half of "a mismatch leaves <dest> absent".
put_dest(){
  local src="$1" dest="$2" d t
  d="$(dirname -- "$dest")"
  mkdir -p -- "$d" || { err "cannot create destination dir: $d"; return 1; }
  t="$(mktemp "$d/.fd-fetch.XXXXXX" 2>/dev/null)" || { err "cannot stage into $d"; return 1; }
  if ! cp -- "$src" "$t"; then rm -f -- "$t"; err "copy into $d failed"; return 1; fi
  chmod 0644 -- "$t" 2>/dev/null
  if ! mv -f -- "$t" "$dest"; then rm -f -- "$t"; err "rename into place failed: $dest"; return 1; fi
}

# ---- the contract ----------------------------------------------------------------------------------

# do_fetch <url> <sha256> [dest]   (no dest = --prefetch: populate the cache, land nothing)
do_fetch(){
  local url="$1" sha="$2" dest="${3:-}" key cache cf actual tmp src rc
  key="$(cache_key "$sha")" \
    || die "not a sha256 pin: '$sha' (need exactly 64 hex chars) — refusing to fetch $url"
  url_tls_ok "$url" \
    || die "not an https:// URL: '$url' — a pinned asset must come over TLS from the vendor's own channel (BP2)"
  cache="$(resolve_cache)"
  cf=""; [ -n "$cache" ] && cf="$cache/$key"

  # ---- HIT: serve from the cache, but VERIFY the cached bytes first (a cache is not a trust boundary).
  if [ -n "$cf" ] && [ "$(cache_decision "$cf")" = HIT ]; then
    actual="$(sha256_of "$cf")"
    if hash_ok "$key" "$actual"; then
      if [ -n "$dest" ]; then put_dest "$cf" "$dest" || die "cache HIT but could not land $dest"; fi
      touch -- "$cf" 2>/dev/null || true   # LRU: last-USE time. A root-owned entry may refuse the
                                           # touch (harmless — it only loses this hit's LRU refresh).
      say "HIT ${key:0:12}… → ${dest:-(cache only)} — 0 bytes fetched ($url)"
      return 0
    fi
    err "CORRUPT cache entry ${key:0:12}… (content hashes $actual) — removing it and re-fetching"
    rm -f -- "$cf"
  fi

  # ---- MISS: fetch ONCE, verify, and only then publish. Stage inside the cache dir when we have one,
  # so the publish is an atomic same-filesystem rename (a half-written entry can never be served).
  if [ -n "$cache" ]; then tmp="$(mktemp "$cache/$PART.XXXXXX" 2>/dev/null)"
  else tmp="$(mktemp "${TMPDIR:-/tmp}/fd-fetch.XXXXXX" 2>/dev/null)"; fi
  [ -n "$tmp" ] || die "cannot stage a download (cache=${cache:-none})"

  say "MISS ${key:0:12}… — fetching $url"
  # The transport's OWN rc is captured directly: inside `if ! cmd; then`, `$?` is the negation's status
  # (0), so reporting it there would print "rc=0" on every failed fetch — a log line that lies about the
  # thing it exists to report.
  fetch_to "$url" "$tmp"; rc=$?
  if [ "$rc" -ne 0 ]; then rm -f -- "$tmp"; err "fetch FAILED (transport rc=$rc): $url"; exit 1; fi

  actual="$(sha256_of "$tmp")"
  if ! hash_ok "$key" "$actual"; then
    rm -f -- "$tmp"
    die "SHA256 MISMATCH for $url
       expected $key
       got      ${actual:-<could not hash>}
       nothing published to the cache, ${dest:-<no dest>} NOT written — re-pin after re-checking the source (BP4)"
  fi

  src="$tmp"
  if [ -n "$cf" ]; then
    chmod 0644 -- "$tmp" 2>/dev/null
    if mv -f -- "$tmp" "$cf"; then src="$cf"; say "published ${key:0:12}… into $cache"
    else err "could not publish into $cache — serving this fetch directly (bounds unaffected)"; fi
  else
    say "no cache directory ($BUILD_CACHE not bound, $(home_cache) absent) — verified fetch, nothing published"
  fi

  if [ -n "$dest" ]; then
    if ! put_dest "$src" "$dest"; then
      [ "$src" = "$tmp" ] && rm -f -- "$tmp"
      die "verified $url but could not land $dest"
    fi
    say "OK $dest (sha256 verified)"
  fi
  [ "$src" = "$tmp" ] && rm -f -- "$tmp"
  return 0
}

# ---- the bound (called from build-throwaway.sh's sweep_orphans() / --sweep-only) --------------------
# AGE-prune first, then LRU size-prune, then reap stale partials — the same shape and order as
# gc_dnf_cache(): drop genuinely-stale entries by AGE, then, if still over the SIZE cap, evict the
# least-recently-used until under it. Both read LAST-USE time (a HIT touches its entry).
gc_cache(){
  local cache now path bn age cur_kb running _t sz
  cache="$(resolve_cache)"
  if [ -z "$cache" ] || [ ! -d "$cache" ]; then say "gc: no download cache present — nothing to bound"; return 0; fi
  now="$(date +%s)"

  # (a) AGE prune: entries unused for more than MAX_AGE_DAYS days.
  while IFS= read -r path; do
    bn="$(basename -- "$path")"
    cache_key "$bn" >/dev/null || continue          # only ever prune real entries, never a live partial
    rm -f -- "$path" && say "gc: age-prune $bn (unused >${MAX_AGE_DAYS}d)"
  done < <(find "$cache" -maxdepth 1 -type f -mtime +"$MAX_AGE_DAYS" 2>/dev/null)

  # (b) SIZE prune: LRU-evict newest-first past the cap.
  # An unreadable size reads as 0, which over_cap treats as "not over cap" — a size it could not measure
  # must never trigger an eviction sweep.
  cur_kb="$(du -sk -- "$cache" 2>/dev/null | cut -f1)"; cur_kb="${cur_kb:-0}"
  if over_cap "$(( cur_kb * 1024 ))" "$CAP_BYTES"; then
    say "gc: cache $(( cur_kb / 1024 ))M > cap $(( CAP_BYTES / 1024 / 1024 ))M — LRU-evicting least-recently-used entries"
    running=0
    while IFS=$'\t' read -r _t sz path; do
      bn="$(basename -- "$path")"
      cache_key "$bn" >/dev/null || continue
      running=$(( running + sz ))
      if [ "$running" -gt "$CAP_BYTES" ]; then rm -f -- "$path" && say "gc: size-prune $bn"; fi
    done < <(find "$cache" -maxdepth 1 -type f -printf '%T@\t%s\t%p\n' 2>/dev/null | sort -rn)
  fi

  # (c) reap STALE PARTIALS: a kill-9 mid-fetch leaves a .part-* file. It can never be served (its name
  # is not a valid key), so it is pure residue on the home volume — BP10's storage-safety rule. Age-
  # bounded, so a CONCURRENT in-flight download is never pulled out from under a running build.
  for path in "$cache/$PART"*; do
    [ -f "$path" ] || continue
    age=$(( (now - $(stat -c %Y -- "$path" 2>/dev/null || echo "$now")) / 60 ))
    if [ "$age" -ge "$STALE_MIN" ]; then
      rm -f -- "$path" && say "gc: reap stale partial $(basename -- "$path") (${age}m old)"
    fi
  done
}

# ---- CLI -------------------------------------------------------------------------------------------
case "${1:-}" in
  --selftest) ;;                                   # handled below
  --gc)       gc_cache; exit 0;;
  --cache-dir) resolve_cache; echo; exit 0;;
  --prefetch)
    [ $# -eq 3 ] || { err "usage: fd-fetch.sh --prefetch <https-url> <sha256>"; exit 2; }
    # the ONE place a cache dir is created: an explicit host-side op, never a build.
    c="$(resolve_cache)"; [ -n "$c" ] || c="$(home_cache)"
    mkdir -p -- "$c" || die "cannot create cache dir: $c"
    FD_DL_CACHE="$c" do_fetch "$2" "$3" ""; exit $?;;
  -h|--help)  usage 0;;
  '')         usage 2;;
  -*)         err "unknown option: $1"; exit 2;;
  *)
    [ $# -eq 3 ] || { err "usage: fd-fetch.sh <https-url> <sha256> <dest>"; exit 2; }
    do_fetch "$1" "$2" "$3"; exit $?;;
esac

# ---- SELFTEST (pure core only: no network, no cache, no engine) -------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  p=0; f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  rcof(){ "$@" >/dev/null 2>&1; printf '%s' $?; }
  SHA_A="$(printf 'a%.0s' $(seq 64))"   # 64 × 'a' — a syntactically valid pin
  echo "== cache_key: content-addressed, normalised, and the path-traversal guard =="
  ck "64 hex passes through"              "$(cache_key "$SHA_A")" "$SHA_A"
  ck "UPPERCASE normalises to lowercase"  "$(cache_key "$(printf 'A%.0s' $(seq 64))")" "$SHA_A"
  ck "63 chars → rc 1"                    "$(rcof cache_key "$(printf 'a%.0s' $(seq 63))")" "1"
  ck "65 chars → rc 1"                    "$(rcof cache_key "$(printf 'a%.0s' $(seq 65))")" "1"
  ck "empty → rc 1"                       "$(rcof cache_key '')" "1"
  ck "non-hex ('g') → rc 1"               "$(rcof cache_key "${SHA_A:0:63}g")" "1"
  ck "a PATH is not a key → rc 1"         "$(rcof cache_key '../../etc/passwd')" "1"
  ck "a slash inside 64 chars → rc 1"     "$(rcof cache_key "${SHA_A:0:32}/${SHA_A:33:31}")" "1"
  echo "== hash_ok: an EMPTY side is never a match ('could not hash' ≠ 'it verified') =="
  ck "equal → rc 0"                       "$(rcof hash_ok "$SHA_A" "$SHA_A")" "0"
  ck "case-insensitive equal → rc 0"      "$(rcof hash_ok "$SHA_A" "$(printf 'A%.0s' $(seq 64))")" "0"
  ck "different → rc 1"                   "$(rcof hash_ok "$SHA_A" "${SHA_A:0:63}b")" "1"
  ck "empty actual → rc 1"                "$(rcof hash_ok "$SHA_A" '')" "1"
  ck "empty expected → rc 1"              "$(rcof hash_ok '' "$SHA_A")" "1"
  ck "both empty → rc 1"                  "$(rcof hash_ok '' '')" "1"
  echo "== cache_decision: only a NON-EMPTY regular file is a HIT =="
  d="$(mktemp -d)"; : >"$d/empty"; printf 'x' >"$d/full"; mkdir "$d/adir"
  ck "non-empty file → HIT"               "$(cache_decision "$d/full")" "HIT"
  ck "zero-byte file → MISS"              "$(cache_decision "$d/empty")" "MISS"
  ck "absent → MISS"                      "$(cache_decision "$d/nope")" "MISS"
  ck "a directory → MISS"                 "$(cache_decision "$d/adir")" "MISS"
  ck "empty arg → MISS"                   "$(cache_decision '')" "MISS"
  rm -rf "$d"
  echo "== url_tls_ok: TLS-only, refused before any byte moves =="
  ck "https → rc 0"                       "$(rcof url_tls_ok 'https://example.com/x.tgz')" "0"
  ck "http → rc 1"                        "$(rcof url_tls_ok 'http://example.com/x.tgz')" "1"
  ck "file:// → rc 1"                     "$(rcof url_tls_ok 'file:///tmp/x.tgz')" "1"
  ck "bare https:// with no host → rc 1"  "$(rcof url_tls_ok 'https://')" "1"
  ck "empty → rc 1"                       "$(rcof url_tls_ok '')" "1"
  echo "== over_cap: an UNREADABLE size is never 'over cap' (no blind eviction sweep) =="
  ck "over → rc 0"                        "$(rcof over_cap 2048 1024)" "0"
  ck "exactly at cap → rc 1"              "$(rcof over_cap 1024 1024)" "1"
  ck "under → rc 1"                       "$(rcof over_cap 1 1024)" "1"
  ck "non-numeric size → rc 1"            "$(rcof over_cap x 1024)" "1"
  ck "empty size → rc 1"                  "$(rcof over_cap '' 1024)" "1"
  ck "non-numeric cap → rc 1"             "$(rcof over_cap 2048 x)" "1"
  echo "== resolve_cache: explicit wins, and NOTHING is ever created =="
  d="$(mktemp -d)"
  ck "FD_DL_CACHE wins"                   "$(FD_DL_CACHE="$d/x" resolve_cache)" "$d/x"
  ck "absent defaults → NO-CACHE (empty)" "$(FD_DL_CACHE='' HOME="$d" resolve_cache)" ""
  ck "…and it created nothing"            "$([ -e "$d/.cache" ] && echo created || echo none)" "none"
  mkdir -p "$d/.cache/fd-dl"
  ck "existing \$HOME cache is used"      "$(FD_DL_CACHE='' HOME="$d" resolve_cache)" "$d/.cache/fd-dl"
  rm -rf "$d"
  echo; echo "fd-fetch selftest: $p passed, $f failed"
  [ "$f" -eq 0 ]; exit
fi
