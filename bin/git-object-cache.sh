#!/usr/bin/env bash
# git-object-cache.sh — a persistent, content-reusing GIT OBJECT CACHE on the home volume, so a repo's
# history crosses the wire ONCE and every later clone of it is materialised from local disk.
# (fedora-dev#319 — a feature of objective #311 "fetch every byte once".)
#
# WHY THIS EXISTS. Objective #311 measured it: git clones had NO cache of any kind on either box — every
# clone was fresh. On this box the cost lands at ONE call site: `bin/dev-author.sh` provisions a missing
# clone with a full network clone, so every repo the maintainer newly brings in scope, and every repo
# whose clone is lost to a box recreate, re-downloads its ENTIRE history. `bin/fresh-tree.sh`'s
# `git fetch origin` was already delta-only — the CLONE, not the fetch, was the hole. Fifty
# feature-author runs against a repo must cost that repo's history once.
#
# THE SHAPE IS THE SAME AS THE dnf PACKAGE CACHE (Principle 10). One durable INPUT on the writable home
# volume; everything built from it stays disposable. A bare mirror per repo is the git analogue of the
# dnf package cache: refreshed with a delta-only `git remote update --prune`, never re-downloaded.
#
# THE CLONE MUST BE SELF-CONTAINED — THE LOAD-BEARING RULE. This cache is BOUNDED and EVICTABLE, so a
# clone that merely POINTS at it (`--reference` / `--shared`, i.e. an `objects/info/alternates` link)
# would be silently CORRUPTED the moment its mirror is age-pruned or LRU-evicted. So the clone is
# materialised FROM the mirror path directly: git's local transport copies (in practice HARDLINKS) the
# object files into the new repo, which is exactly the `--reference … --dissociate` outcome without the
# intermediate window. Hardlinks are safe against eviction BY CONSTRUCTION — git objects are immutable
# and `rm -rf` of the mirror only drops a link, never the data the clone holds (verified: a full-history
# clone survives eviction of the mirror it came from). And the absence of an alternates file is not
# assumed: `clone` CHECKS for one and REFUSES (removing the destination) if it ever appears, so a future
# git that links by default degrades to the caller's fall-through instead of shipping a fragile clone.
#
# FAIL-SOFT BY CONTRACT — IT ONLY EVER HELPS. Every caller of this helper already has a working, if
# expensive, path (a full network clone). So a cache miss, an unreachable origin, an unusable cache dir
# or a corrupt mirror must degrade to that path, never introduce a new failure mode:
#   * a mirror that exists but cannot be REFRESHED is still USED (stale objects are still valid objects;
#     the delta arrives on the next fetch, and `fresh-tree.sh` fetches before it cuts a worktree);
#   * a mirror that cannot be CREATED is a plain rc 1 with nothing on stdout — the caller falls through;
#   * a half-written mirror is never visible: it is built under `<key>.incoming.<pid>` and moved into
#     place only once git succeeded, so a kill -9 can never leave a directory that later reads as valid.
#
# IT BRINGS ITS OWN BOUNDS. Shipped alone this must still never become an unbounded cache, so it carries
# the SAME age-then-size order and the SAME env-knob shape as `gc_dnf_cache()` in build-throwaway.sh:
# drop genuinely-stale mirrors by AGE first, THEN — if still over the SIZE cap — LRU-evict the oldest
# remaining until under cap. Age-then-size keeps the hot repos hot. The GC is called from the sweeper
# that ALREADY RUNS on every throwaway build (build-throwaway.sh's `sweep_orphans`), not from a new
# timer — machinery that already runs is machinery that cannot silently stop running.
#
# USAGE
#   git-object-cache.sh ensure <owner/repo>          # mirror path on stdout; created once, then delta-refreshed
#   git-object-cache.sh clone  <owner/repo> <dest>   # materialise a self-contained clone from the mirror
#   git-object-cache.sh gc                           # enforce this cache's own age + size bounds
#   git-object-cache.sh --selftest                   # pure helpers + a real file:// round trip, no network
#
# ENV KNOBS
#   FD_GIT_CACHE               cache root                      (default: $HOME/.cache/fd-git)
#   FD_GIT_CACHE_CAP_GB        cache SIZE cap, GB              (default: 15)
#   FD_GIT_CACHE_MAX_AGE_DAYS  cache AGE cap, days             (default: 45)
#   FD_STALE_MIN               orphan `.incoming.*` age, mins  (default: 720 = 12h; shared with the
#                              throwaway sweeper's own orphan clock, since it calls this GC)
#   FD_GIT_ORIGIN_BASE         origin URL base                 (default: https://github.com/)
#                              THE TEST SEAM: local `file://` origins make every row network-free.
#   FD_GIT_CACHE_CAP_BYTES     SIZE cap in BYTES, overriding the GB knob. A TEST SEAM: the GB knob has no
#                              value between "0" and "larger than any fixture", so LRU ORDER (evict the
#                              oldest, keep the newest) can only be exercised at byte precision.
#
# Authentication is the box's standing credential, unchanged: a plain https origin URL resolves through
# git's `store` helper as wired by `bin/gh-app-auth.sh install`, so this needs no token of its own and
# writes none (Principle 5).
set -uo pipefail

CACHE="${FD_GIT_CACHE:-$HOME/.cache/fd-git}"
CAP_GB="${FD_GIT_CACHE_CAP_GB:-15}"
MAX_AGE_DAYS="${FD_GIT_CACHE_MAX_AGE_DAYS:-45}"
STALE_MIN="${FD_STALE_MIN:-720}"
ORIGIN_BASE="${FD_GIT_ORIGIN_BASE:-https://github.com/}"

log(){ printf 'git-object-cache: %s\n' "$*" >&2; }
usage(){ sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//'; exit "${1:-0}"; }

# ---- pure: <owner>/<repo> → the mirror's directory NAME (rc 1 on anything unusable) ------------------
# FAIL-CLOSED ON THE SLUG, because this name is concatenated onto a path that is later `rm -rf`'d by the
# GC: a slug carrying `..` or a second slash must never resolve to a directory outside the cache.
cache_key(){
  local slug="${1:-}" owner repo
  case "$slug" in */*) ;; *) return 1;; esac       # exactly one slash…
  case "$slug" in */*/*) return 1;; esac           # …and no more
  owner="${slug%%/*}"; repo="${slug#*/}"; repo="${repo%.git}"
  [ -n "$owner" ] && [ -n "$repo" ] || return 1
  case "$owner$repo" in *[!A-Za-z0-9._-]*) return 1;; esac
  case "$owner" in .|..) return 1;; esac
  case "$repo"  in .|..) return 1;; esac
  printf '%s-%s.git\n' "$owner" "$repo"
}

# ---- pure: <owner>/<repo> → the origin URL (the GitHub URL, or the seam's base) ----------------------
origin_url(){
  local slug="${1:-}" base="$ORIGIN_BASE" owner repo
  cache_key "$slug" >/dev/null || return 1
  case "$base" in */) ;; *) base="$base/";; esac
  owner="${slug%%/*}"; repo="${slug#*/}"; repo="${repo%.git}"
  printf '%s%s/%s.git\n' "$base" "$owner" "$repo"
}

# ---- pure: AGE prune — stdin `<mtime-epoch>\t<path>` → the paths untouched for > <max_days> ----------
# An unreadable mtime is NEVER pruned: this GC's fail direction is to keep a mirror it cannot age.
prune_age_list(){
  local max_days="${1:?}" now="${2:?}" cutoff mt path
  case "$max_days" in ''|*[!0-9]*) return 0;; esac
  cutoff=$(( now - max_days * 86400 ))
  while IFS=$'\t' read -r mt path; do
    [ -n "${path:-}" ] || continue
    case "$mt" in ''|*[!0-9]*) continue;; esac
    [ "$mt" -lt "$cutoff" ] && printf '%s\n' "$path"
  done
  return 0
}

# ---- pure: SIZE prune — stdin `<mtime>\t<size-bytes>\t<path>` → the paths to LRU-evict ---------------
# Identical fold to gc_dnf_cache's: walk NEWEST first, accumulate, and once the running total passes the
# cap every OLDER entry is evicted. So the hot mirrors are the ones that survive.
prune_lru_list(){
  local cap="${1:?}" mt sz path running=0
  case "$cap" in ''|*[!0-9]*) return 0;; esac
  while IFS=$'\t' read -r mt sz path; do
    [ -n "${path:-}" ] || continue
    case "$sz" in ''|*[!0-9]*) sz=0;; esac
    running=$(( running + sz ))
    [ "$running" -gt "$cap" ] && printf '%s\n' "$path"
  done < <(sort -t"$(printf '\t')" -k1,1rn)
  return 0
}

# ---- pure: the effective size cap in bytes (the byte seam wins over the GB knob) ---------------------
cap_bytes(){
  local b="${FD_GIT_CACHE_CAP_BYTES:-}"
  case "$b" in ''|*[!0-9]*) ;; *) printf '%s\n' "$b"; return 0;; esac
  case "$CAP_GB" in ''|*[!0-9]*) printf '%s\n' $(( 15 * 1024 * 1024 * 1024 )); return 0;; esac
  printf '%s\n' $(( CAP_GB * 1024 * 1024 * 1024 ))
}

# ---- the mirrors, as the GC's two input shapes -------------------------------------------------------
mirror_ages(){ # <mtime>\t<path>
  local p
  for p in "$CACHE"/*.git; do
    [ -d "$p" ] || continue
    printf '%s\t%s\n' "$(stat -c %Y "$p" 2>/dev/null || echo '')" "$p"
  done
}
mirror_sizes(){ # <mtime>\t<size-bytes>\t<path>
  local p kb
  for p in "$CACHE"/*.git; do
    [ -d "$p" ] || continue
    kb="$(du -sk "$p" 2>/dev/null | cut -f1)"; kb="${kb:-0}"
    printf '%s\t%s\t%s\n' "$(stat -c %Y "$p" 2>/dev/null || echo 0)" "$(( kb * 1024 ))" "$p"
  done
}

# ---- evict ONE mirror, refusing any path that is not a mirror inside this cache ----------------------
evict(){
  local p="${1:-}" why="${2:-}"
  case "$p" in "$CACHE"/*.git) ;; *) log "refusing to remove a path that is not a mirror in $CACHE: $p"; return 1;; esac
  rm -rf "$p" 2>/dev/null && echo "gc: git $why $(basename "$p")"
}

# ---- ensure: the mirror exists and is as current as the origin lets it be ----------------------------
cmd_ensure(){
  local slug="${1:-}" key mirror url incoming
  key="$(cache_key "$slug")" || { log "refusing an unusable repo slug: '$slug' (want <owner>/<repo>)"; return 1; }
  url="$(origin_url "$slug")" || return 1
  mirror="$CACHE/$key"
  mkdir -p "$CACHE" 2>/dev/null || { log "cannot create the cache root $CACHE"; return 1; }

  if [ -d "$mirror" ] && git -C "$mirror" rev-parse --git-dir >/dev/null 2>&1; then
    if git -C "$mirror" remote update --prune >/dev/null 2>&1; then
      log "mirror refreshed, delta only: $mirror"
    else
      # STALE, NOT BROKEN. The objects already mirrored are still valid objects, and the caller's own
      # fetch closes the gap — discarding them here would re-download the history this cache exists to
      # keep, on exactly the runs where the network is already unhappy.
      log "mirror refresh FAILED for $slug — using the objects already mirrored (may trail origin)"
    fi
  else
    [ -e "$mirror" ] && { log "cache entry for $slug is not a git mirror — rebuilding it"; evict "$mirror" "rebuild" >/dev/null; }
    incoming="$mirror.incoming.$$"
    rm -rf "$incoming" 2>/dev/null
    if git clone --quiet --mirror "$url" "$incoming" >/dev/null 2>&1; then
      # `mv -T` is load-bearing, not style: a PLAIN `mv` into a path that appeared while we were cloning
      # (a concurrent ensure of the same repo — the sweep and the authoring loop run independently) moves
      # our mirror INSIDE theirs as `<mirror>/<key>.incoming.<pid>`, silently corrupting a valid cache
      # entry. `-T` refuses that outright, so the race-LOSER discards its own work and uses the winner's
      # mirror — the objects are identical, and duplicating them buys nothing.
      if mv -T "$incoming" "$mirror" 2>/dev/null; then
        log "mirror created: $mirror (history fetched once, from $url)"
      elif [ -d "$mirror" ] && git -C "$mirror" rev-parse --git-dir >/dev/null 2>&1; then
        rm -rf "$incoming" 2>/dev/null
        log "mirror was installed concurrently by another run — using it: $mirror"
      else
        log "could not install the mirror for $slug at $mirror"; rm -rf "$incoming" 2>/dev/null; return 1
      fi
    else
      rm -rf "$incoming" 2>/dev/null
      log "could not mirror $slug from $url"
      return 1
    fi
  fi

  touch "$mirror" 2>/dev/null    # the LRU stamp the GC ages: last USED, not last written
  printf '%s\n' "$mirror"
}

# ---- clone: a SELF-CONTAINED working clone whose objects came from the local mirror ------------------
cmd_clone(){
  local slug="${1:-}" dest="${2:-}" mirror url alt
  [ -n "$slug" ] && [ -n "$dest" ] || { log "usage: clone <owner/repo> <dest>"; return 2; }
  url="$(origin_url "$slug")" || { log "refusing an unusable repo slug: '$slug'"; return 1; }
  if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
    log "destination exists and is not empty — leaving it alone: $dest"; return 1
  fi
  mirror="$(cmd_ensure "$slug")" || return 1

  # THE LOCAL TRANSPORT: git copies/hardlinks the objects off local disk. No bytes cross the network for
  # history the mirror already holds, and the result owns its objects (see the header's self-containment
  # rule) rather than borrowing them from an evictable cache.
  if ! git clone --quiet "$mirror" "$dest" >/dev/null 2>&1; then
    log "could not materialise a clone of $slug at $dest from $mirror"
    rm -rf "$dest" 2>/dev/null; return 1
  fi
  # SELF-CONTAINMENT, CHECKED NOT ASSUMED (the header's load-bearing rule). git's local transport writes
  # no alternates today; a future default that DID would hand the caller a clone this cache can corrupt
  # by evicting a mirror, so an alternates link — or a destination that is not a repo at all — is a hard
  # refusal that falls through, never a shipped fragile clone. `--absolute-git-dir` sidesteps the
  # relative/absolute ambiguity of `--git-path` (whose answer depends on where it is invoked from).
  alt="$(git -C "$dest" rev-parse --absolute-git-dir 2>/dev/null)"
  if [ -z "$alt" ] || [ -e "$alt/objects/info/alternates" ]; then
    log "REFUSING a clone that is not self-contained (git dir '${alt:-unresolvable}') — this cache is evictable"
    rm -rf "$dest" 2>/dev/null; return 1
  fi

  if ! git -C "$dest" remote set-url origin "$url" >/dev/null 2>&1; then
    log "could not point $dest at $url"; rm -rf "$dest" 2>/dev/null; return 1
  fi
  if git -C "$dest" fetch --quiet --prune origin >/dev/null 2>&1; then
    log "clone served from the local mirror; only the delta came from $url"
  else
    log "clone served from the local mirror; the delta fetch from $url FAILED (may trail origin)"
  fi
  printf '%s\n' "$dest"
}

# ---- gc: AGE-prune whole mirrors first, then LRU-evict while over the SIZE cap -----------------------
cmd_gc(){
  [ -d "$CACHE" ] || return 0
  local now cap cur_kb p
  now="$(date +%s)"; cap="$(cap_bytes)"

  # (a) AGE prune: whole mirrors untouched for more than FD_GIT_CACHE_MAX_AGE_DAYS days.
  while IFS= read -r p; do
    [ -n "$p" ] && evict "$p" "age-prune (>${MAX_AGE_DAYS}d untouched)"
  done < <(mirror_ages | prune_age_list "$MAX_AGE_DAYS" "$now")

  # (b) SIZE prune: if still over the cap, LRU-evict the oldest remaining until the total is <= cap.
  cur_kb="$(du -sk "$CACHE" 2>/dev/null | cut -f1)"; cur_kb="${cur_kb:-0}"
  if [ $(( cur_kb * 1024 )) -gt "$cap" ]; then
    echo "gc: git cache $(( cur_kb / 1024 ))M > cap $(( cap / 1024 / 1024 ))M — LRU-evicting oldest mirrors"
    while IFS= read -r p; do
      [ -n "$p" ] && evict "$p" "size-prune (LRU)"
    done < <(mirror_sizes | prune_lru_list "$cap")
  fi

  # (c) orphan `.incoming.*` trees: a mirror clone killed before its move. Same clock as the throwaway
  # sweeper's other orphans, so an in-flight mirror of a huge repo is never reaped out from under itself.
  for p in "$CACHE"/*.incoming.*; do
    [ -d "$p" ] || continue
    if [ $(( (now - $(stat -c %Y "$p" 2>/dev/null || echo "$now")) / 60 )) -ge "$STALE_MIN" ]; then
      rm -rf "$p" 2>/dev/null && echo "gc: git rm orphan mirror-in-progress $(basename "$p")"
    fi
  done
  return 0
}

# ---- selftest: the pure core, plus a REAL round trip against a local file:// origin ------------------
selftest(){
  local pass=0 fail=0 d out rc
  ck(){ if [ "$2" = "$3" ]; then printf '  PASS: %s\n' "$1"; pass=$((pass+1))
        else printf '  FAIL: %s (got=[%s] want=[%s])\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

  # -- cache_key: the name, and the fail-closed refusals that keep the GC inside its own directory
  ck "cache_key maps a slug to one flat mirror name" "$(cache_key oso-gato/fedora-dev)" "oso-gato-fedora-dev.git"
  ck "cache_key tolerates a .git suffix"             "$(cache_key oso-gato/fedora-dev.git)" "oso-gato-fedora-dev.git"
  cache_key "oso-gato" >/dev/null 2>&1;              ck "cache_key rejects a bare name"    "$?" "1"
  cache_key "a/b/c" >/dev/null 2>&1;                 ck "cache_key rejects two slashes"    "$?" "1"
  cache_key "../etc" >/dev/null 2>&1;                ck "cache_key rejects a traversal"    "$?" "1"
  cache_key "oso-gato/.." >/dev/null 2>&1;           ck "cache_key rejects a .. component" "$?" "1"
  cache_key "oso gato/x" >/dev/null 2>&1;            ck "cache_key rejects whitespace"     "$?" "1"
  cache_key "" >/dev/null 2>&1;                      ck "cache_key rejects empty"          "$?" "1"

  # -- origin_url: the DEFAULT base is the GitHub URL (the acceptance's "origin is the GitHub URL")
  ( unset FD_GIT_ORIGIN_BASE; ORIGIN_BASE="https://github.com/"
    [ "$(origin_url oso-gato/fedora-dev)" = "https://github.com/oso-gato/fedora-dev.git" ] )
  ck "origin_url composes the GitHub URL by default" "$?" "0"
  ( ORIGIN_BASE="file:///tmp/o"    # a base with no trailing slash must still compose one URL
    [ "$(origin_url a/b)" = "file:///tmp/o/a/b.git" ] )
  ck "origin_url normalises a base with no trailing slash" "$?" "0"

  # -- prune_age_list: the cutoff, and the fail-safe on an unreadable mtime
  out="$(printf '%s\t%s\n' 1000 /c/old.git 990000 /c/new.git | prune_age_list 1 1000000)"
  ck "age prune picks only what is past the cap" "$out" "/c/old.git"
  out="$(printf '%s\t%s\n' '' /c/unknown.git | prune_age_list 1 1000000)"
  ck "age prune never prunes an unreadable mtime" "$out" ""
  out="$(printf '%s\t%s\n' 1000 /c/old.git | prune_age_list 0 1000000)"
  ck "age prune with a 0-day cap prunes the aged" "$out" "/c/old.git"

  # -- prune_lru_list: NEWEST survives, and the fold evicts every older entry past the cap
  out="$(printf '%s\t%s\t%s\n' 300 60 /c/new.git 200 60 /c/mid.git 100 60 /c/old.git | prune_lru_list 100)"
  ck "lru keeps the newest and evicts the older past cap" "$out" "$(printf '/c/mid.git\n/c/old.git')"
  out="$(printf '%s\t%s\t%s\n' 300 60 /c/new.git 100 60 /c/old.git | prune_lru_list 1000)"
  ck "lru evicts nothing while under cap" "$out" ""
  out="$(printf '%s\t%s\t%s\n' 300 60 /c/new.git | prune_lru_list 0)"
  ck "lru with a zero cap evicts everything" "$out" "/c/new.git"

  # -- cap_bytes: the byte seam wins; a garbage GB knob falls back to the documented default
  ( FD_GIT_CACHE_CAP_BYTES=4096; [ "$(cap_bytes)" = 4096 ] ); ck "cap_bytes honours the byte seam" "$?" "0"
  ( CAP_GB=2; unset FD_GIT_CACHE_CAP_BYTES; [ "$(cap_bytes)" = "$(( 2 * 1024 * 1024 * 1024 ))" ] )
  ck "cap_bytes converts the GB knob" "$?" "0"
  ( CAP_GB=nonsense; unset FD_GIT_CACHE_CAP_BYTES; [ "$(cap_bytes)" = "$(( 15 * 1024 * 1024 * 1024 ))" ] )
  ck "cap_bytes falls back on a garbage GB knob" "$?" "0"

  # -- a REAL round trip, no network: a local file:// origin, a mirror, a self-contained clone
  d="$(mktemp -d "${TMPDIR:-/tmp}/gocache-selftest.XXXXXX")" || { echo "mktemp failed"; return 2; }
  ( set -e
    git init -q --bare "$d/origins/oso-gato/alpha.git"
    git -C "$d/origins/oso-gato/alpha.git" symbolic-ref HEAD refs/heads/main
    git init -q "$d/w"; git -C "$d/w" config user.email t@t; git -C "$d/w" config user.name t
    echo one > "$d/w/f"; git -C "$d/w" add -A; git -C "$d/w" commit -qm one; git -C "$d/w" branch -M main
    git -C "$d/w" remote add origin "file://$d/origins/oso-gato/alpha.git"; git -C "$d/w" push -q origin main
  ) >/dev/null 2>&1 || { echo "  FAIL: could not build the local fixture origin"; rm -rf "$d"; return 1; }

  CACHE="$d/cache"; ORIGIN_BASE="file://$d/origins/"
  out="$(cmd_ensure oso-gato/alpha 2>/dev/null)"; rc=$?
  ck "ensure creates the mirror" "$rc|$(basename "${out:-none}")" "0|oso-gato-alpha.git"
  out="$(cmd_clone oso-gato/alpha "$d/dest" 2>/dev/null)"; rc=$?
  ck "clone materialises a working clone" "$rc|$out" "0|$d/dest"
  ck "the clone has no alternates link into the cache" \
     "$([ -e "$d/dest/.git/objects/info/alternates" ] && echo linked || echo self-contained)" "self-contained"
  ck "the clone's origin is the origin URL, not the mirror" \
     "$(git -C "$d/dest" remote get-url origin 2>/dev/null)" "file://$d/origins/oso-gato/alpha.git"
  ck "the clone carries the origin's history" \
     "$(git -C "$d/dest" rev-parse HEAD 2>/dev/null)" "$(git -C "$d/w" rev-parse HEAD)"
  cmd_clone oso-gato/nope "$d/dest2" >/dev/null 2>&1
  ck "a missing origin is rc 1 and leaves no clone behind" \
     "$?|$([ -e "$d/dest2" ] && echo leaked || echo clean)" "1|clean"
  rm -rf "$d"

  printf 'selftest: %s passed, %s failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  ensure)     shift; cmd_ensure "${1:-}";;
  clone)      shift; cmd_clone "${1:-}" "${2:-}";;
  gc)         shift; cmd_gc;;
  --selftest) selftest;;
  -h|--help)  usage 0;;
  *)          usage 2;;
esac
