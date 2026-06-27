#!/usr/bin/env bash
# build-throwaway.sh — standardized in-box THROWAWAY candidate build for the dev loop.
#
# Wraps the dev box's by-hand candidate build so every churn iteration:
#   * runs in fedora-dev's OWN nested engine (CONTAINER_HOST socket) under the required
#     `--isolation=chroot` (a default-isolation RUN step can't mount /proc at this depth);
#   * reuses the SAME persistent dnf package/metadata cache ($HOME/.cache/fd-dnf →
#     /var/cache/libdnf5) AND the podman LAYER cache on the home volume — so a re-build
#     re-downloads NOTHING and reuses cached layers (the cache is the persistent INPUT;
#     the candidate image is the disposable OUTPUT);
#   * tags the output `localhost/disposable/<name>:val-<sha-or-rand>` — NEVER pushed;
#   * TEARS DOWN on EXIT (trap): rmi the disposable tag + rm any temp tree WE created,
#     firing on success / failure / most signals (INT/TERM/HUP). The LAYER cache and the
#     dnf cache SURVIVE the rmi (verified: rmi of the tag leaves the build cache on the
#     home volume) — that is the churn-balance: discard the candidate, keep the cache.
#   * SWEEPS orphans first (stale `localhost/disposable/*` images + orphan temp trees),
#     so a kill-9 that skipped the trap on a previous run doesn't leak on the home volume.
#
# PROVENANCE (Build Principle 2): this only ever builds the repo's OWN Containerfile in
# the caller-provided context — it adds NO repos, NO source-loosening --build-arg, and does
# NOT edit the Containerfile. It NEVER writes into the context (podman build reads it), so
# the IMMUTABLE live tree is untouched; for work that must DIFFER from the live tree pass
# `-c <srcdir>` and the helper bolts on a SEPARATE TEMPORARY tree on the WRITABLE home
# volume, builds there, and reaps it on teardown.
#
# Usage:
#   build-throwaway.sh [opts] <context-dir>
#   build-throwaway.sh -c <srcdir-to-copy> [opts]      # build a throwaway COPY of srcdir
#   build-throwaway.sh --sweep-only                    # reap orphans and exit
#
# Options:
#   -f <Containerfile>   Containerfile path (default: <context>/Containerfile)
#   -n <name>            disposable name component (default: basename of context/srcdir)
#   -t <suffix>          tag suffix (default: git short-sha of context, else random)
#   -c <srcdir>          copy srcdir → a fresh throwaway tree, build that (reaped on exit)
#   -k                   keep the disposable image (skip the rmi teardown; temp tree still reaped)
#   --sweep-only         run the orphan sweeper and exit (no build)
#   -h                   this help
#
# Env knobs:
#   FD_DNF_CACHE  persistent dnf cache dir   (default: $HOME/.cache/fd-dnf)
#   FD_STALE_MIN  orphan age threshold, mins (default: 720 = 12h)
#   FD_DNF_CACHE_CAP_GB        dnf cache SIZE cap, GB; LRU-prune RPMs over it  (default: 15)
#   FD_DNF_CACHE_MAX_AGE_DAYS  dnf cache AGE cap, days; prune RPMs older than  (default: 45)
#   BUILD_ARGS    extra args forwarded verbatim to `podman build` (e.g. --build-arg X=Y)
set -uo pipefail

DNF_CACHE="${FD_DNF_CACHE:-$HOME/.cache/fd-dnf}"
DNF_CAP_GB="${FD_DNF_CACHE_CAP_GB:-15}"
DNF_MAX_AGE_DAYS="${FD_DNF_CACHE_MAX_AGE_DAYS:-45}"
DISPOSABLE_NS="localhost/disposable"
TMP_PREFIX="fd-throwaway"
TMP_ROOT="$HOME/.cache"                 # throwaway trees live on the WRITABLE home volume
STALE_MIN="${FD_STALE_MIN:-720}"

FILE=""; NAME=""; SUFFIX=""; COPY_SRC=""; KEEP=0; SWEEP_ONLY=0

die(){ echo "build-throwaway: $*" >&2; exit 2; }
usage(){ sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//'; exit "${1:-0}"; }

# ---- orphan sweeper: reap stale disposable images + orphan throwaway trees ------------
# Age-bounded so a concurrent in-flight build (recent) is never reaped; handles the kill-9
# leak path where a prior run's EXIT trap never fired.
sweep_orphans(){
  local now img ts age d
  now=$(date +%s)
  # List disposable image IDs, then read the epoch via `podman image inspect` PER ID. `.Created.Unix`
  # is a valid time.Time method under `inspect`, but NOT in a `podman images` list --format (there
  # `.Created` is relative text → the template errors rc=125 and the reap silently no-ops). This
  # mirrors the proven host throwaway-sweep.sh pattern (list IDs → image inspect each).
  while read -r img; do
    [ -n "$img" ] || continue
    ts="$(podman image inspect -f '{{.Created.Unix}}' "$img" 2>/dev/null)" || continue
    case "$ts" in ''|*[!0-9]*) continue;; esac          # need a numeric epoch to age-gate
    age=$(( (now - ts) / 60 ))
    if [ "$age" -ge "$STALE_MIN" ]; then
      podman rmi -f "$img" >/dev/null 2>&1 && echo "sweep: rmi stale image $img (${age}m old)"
    fi
  done < <(podman images --filter "reference=$DISPOSABLE_NS/*" --format '{{.ID}}' 2>/dev/null | sort -u)
  for d in "$TMP_ROOT/$TMP_PREFIX".* "${TMPDIR:-/tmp}/$TMP_PREFIX".*; do
    [ -d "$d" ] || continue
    age=$(( (now - $(stat -c %Y "$d" 2>/dev/null || echo "$now")) / 60 ))
    if [ "$age" -ge "$STALE_MIN" ]; then
      rm -rf "$d" 2>/dev/null && echo "sweep: rm orphan tree $d (${age}m old)"
    fi
  done
  gc_dnf_cache
}

# ---- bound the persistent dnf package cache: AGE-prune (>MAX_AGE_DAYS) FIRST, then SIZE-prune ------
# Same caps as the host throwaway-sweep.sh: the dnf bind cache ($DNF_CACHE → /var/cache/libdnf5) is the
# ONE thing kept across throwaway disposal, so it must be bounded. Order is deliberate: drop genuinely-
# stale RPMs by AGE first, THEN — if still over the SIZE cap — LRU-evict the oldest remaining until under
# cap. Age-then-size keeps the freshest churn RPMs hot. Both caps are overridable env (see header).
gc_dnf_cache(){
  [ -d "$DNF_CACHE" ] || return 0
  local cap_bytes cur_kb running _t sz path
  # (a) AGE prune: RPMs last modified more than FD_DNF_CACHE_MAX_AGE_DAYS days ago.
  while IFS= read -r -d '' path; do
    rm -f "$path" 2>/dev/null && echo "gc: dnf age-prune $(basename "$path") (>${DNF_MAX_AGE_DAYS}d)"
  done < <(find "$DNF_CACHE" -type f -name '*.rpm' -mtime +"$DNF_MAX_AGE_DAYS" -print0 2>/dev/null)
  # (b) SIZE prune: if still over the cap, LRU-evict oldest RPMs until the total is <= cap.
  cap_bytes=$(( DNF_CAP_GB * 1024 * 1024 * 1024 ))
  cur_kb="$(du -sk "$DNF_CACHE" 2>/dev/null | cut -f1)"; cur_kb="${cur_kb:-0}"
  if [ $(( cur_kb * 1024 )) -gt "$cap_bytes" ]; then
    echo "gc: dnf cache $(( cur_kb / 1024 ))M > cap ${DNF_CAP_GB}G — LRU-pruning oldest RPMs"
    running=0
    # newest first; once the running total passes the cap, every older RPM is pruned.
    while IFS=$'\t' read -r _t sz path; do
      running=$(( running + sz ))
      if [ "$running" -gt "$cap_bytes" ]; then
        rm -f "$path" 2>/dev/null && echo "gc: dnf size-prune $(basename "$path")"
      fi
    done < <(find "$DNF_CACHE" -type f -name '*.rpm' -printf '%T@\t%s\t%p\n' 2>/dev/null | sort -rn)
  fi
}

# ---- teardown: discard THIS run's candidate + temp tree; cache survives ---------------
TAG=""; SELF_TMP=""
teardown(){
  local rc=$?
  if [ -n "$TAG" ] && [ "$KEEP" != 1 ]; then
    podman rmi -f "$TAG" >/dev/null 2>&1 && echo "teardown: rmi $TAG (layer + dnf cache retained)"
  elif [ -n "$TAG" ]; then
    echo "teardown: kept $TAG (-k)"
  fi
  [ -n "$SELF_TMP" ] && [ -d "$SELF_TMP" ] && rm -rf "$SELF_TMP" 2>/dev/null && echo "teardown: rm $SELF_TMP"
  exit "$rc"
}
trap teardown EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ---- args ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -f) FILE="${2:?}"; shift 2;;
    -n) NAME="${2:?}"; shift 2;;
    -t) SUFFIX="${2:?}"; shift 2;;
    -c) COPY_SRC="${2:?}"; shift 2;;
    -k) KEEP=1; shift;;
    --sweep-only) SWEEP_ONLY=1; shift;;
    -h|--help) usage 0;;
    --) shift; break;;
    -*) die "unknown option: $1";;
    *) break;;
  esac
done

sweep_orphans
[ "$SWEEP_ONLY" = 1 ] && exit 0

# ---- resolve context (caller-provided, or a fresh throwaway COPY of -c srcdir) --------
if [ -n "$COPY_SRC" ]; then
  [ -d "$COPY_SRC" ] || die "copy source not a directory: $COPY_SRC"
  SELF_TMP="$(mktemp -d "$TMP_ROOT/$TMP_PREFIX.XXXXXX")" || die "mktemp failed"
  cp -a "$COPY_SRC/." "$SELF_TMP/" || die "copy into throwaway tree failed"
  CTX="$SELF_TMP"
  : "${NAME:=$(basename "$COPY_SRC")}"
else
  CTX="${1:-}"; [ -n "$CTX" ] || usage 2
  [ -d "$CTX" ] || die "context not a directory: $CTX"
  : "${NAME:=$(basename "$CTX")}"
fi

: "${FILE:=$CTX/Containerfile}"
[ -f "$FILE" ] || die "Containerfile not found: $FILE"

# tag suffix: git short-sha of the context if it is a repo, else random
if [ -z "$SUFFIX" ]; then
  SUFFIX="$(git -C "$CTX" rev-parse --short HEAD 2>/dev/null)" || SUFFIX=""
  [ -n "$SUFFIX" ] || SUFFIX="r$(date +%s)$RANDOM"
fi
# sanitize name/suffix into a legal tag
NAME="$(printf '%s' "$NAME" | tr -c 'a-zA-Z0-9._-' - )"
SUFFIX="$(printf '%s' "$SUFFIX" | tr -c 'a-zA-Z0-9._-' - )"
TAG="$DISPOSABLE_NS/$NAME:val-$SUFFIX"

mkdir -p "$DNF_CACHE"

echo "build-throwaway: tag=$TAG file=$FILE ctx=$CTX dnf-cache=$DNF_CACHE"
echo "build-throwaway: $([ -n "$SELF_TMP" ] && echo 'throwaway COPY tree (live tree untouched)' || echo 'caller context (read-only by podman build)')"

# ---- the build: persistent dnf cache + persistent layer cache, chroot isolation ------
# shellcheck disable=SC2086
podman build \
  --isolation=chroot \
  -v "$DNF_CACHE:/var/cache/libdnf5:rw" \
  ${BUILD_ARGS:-} \
  -t "$TAG" \
  -f "$FILE" \
  "$CTX"
rc=$?

if [ "$rc" -eq 0 ]; then echo "build-throwaway: BUILD OK ($TAG) — discarding candidate on exit, cache persists"
else echo "build-throwaway: BUILD FAILED (rc=$rc)"; fi
exit "$rc"
