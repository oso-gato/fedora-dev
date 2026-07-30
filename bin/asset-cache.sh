#!/usr/bin/env bash
# asset-cache.sh — the DEV BOX'S UNIFORM BOUNDED-CACHE GC (#321, the bound half of objective #311).
#
# WHY THIS EXISTS. #311 rules out an unbounded cache BY NAME: it "would serve this objective while
# quietly breaking immutability". Before this file the dev box bounded exactly ONE of its caches — the
# dnf RPM bind-cache, age-then-LRU, correct — and left the largest one with no ceiling at all. The
# podman image/layer store was swept only for `localhost/disposable/*` tags past FD_STALE_MIN; there was
# no dangling reap, no store age cap and no size cap. MEASURED on nox 2026-07-30, before this change:
#
#     podman system df →  Images 750 total, 4 ACTIVE, 76.82 GB, 74.39 GB RECLAIMABLE (97%)
#
# 97% of the single biggest thing on the home volume was garbage. The host has had this ceiling since
# v1.2.53 (throwaway-sweep.sh steps 5+6); the dev box did not. And NO cache on either box was bounded by
# PROJECT COMPLETION — only by age and size — so a cache warmed for an objective that shipped months ago
# was indistinguishable from one warming the work in flight.
#
# WHAT THIS IS. ONE registry-driven GC over EVERY dev-box asset cache, each entry carrying THREE bounds:
#
#     AGE         drop entries not touched within the entry's age cap.
#     SIZE        if still over the entry's size cap, LRU-evict oldest-first until under it.
#     COMPLETION  when the project(s) a cache serves are SHIPPED, tighten to a cold floor / drop that
#                 project's working set (see THE RELEASE RULE).
#
# THE REGISTRY IS THE CONTRACT (ac_registry). One table, one row per cache, nine fields:
#
#     name | kind | dir | cap_mb | age_h | glob | scope | rel_cap_mb | rel_age_h
#
# The registry's units are MiB and HOURS — ONE unit per axis, across every kind. The operator-facing
# knobs keep their documented coarse form (`*_CAP_GB`, `*_MAX_AGE_DAYS`) and are converted here; a
# `*_CAP_MB` knob overrides its GB sibling for fine control, and is what asset-cache.test.sh sets so the
# LRU arm can be proven against megabyte fixtures instead of multi-gigabyte ones.
#
# A row whose `dir` DOES NOT EXIST IS SKIPPED SILENTLY, never an error — so this ships today bounding
# what exists today (fd-dnf + the image store) and picks the sibling caches up automatically when they
# land. That skip is also why the registry can DECLARE the layout the siblings must ship: fd-git and
# fd-dl are declared `tree`+`repo`, i.e. "immediate subdirectories keyed by repo name"
# (<cache>/<repo>/…), which is what makes a per-repo completion release addressable at all. If a sibling
# lands a different layout, its registry ROW is the one place that changes.
#
# THREE KINDS, because granularity is not a detail — it is correctness:
#   * file  — prune matching FILES (fd-dnf: `*.rpm` ONLY, so dnf METADATA is never pruned; that is the
#             pre-existing behaviour and it is preserved, not re-derived).
#   * tree  — prune immediate SUBDIRECTORIES. A git mirror is the reason this kind exists: file-level
#             LRU inside a bare repo would delete live objects and CORRUPT the mirror. Whole subtree or
#             nothing.
#   * image — the podman image/layer store, which has no files to walk: podman's own dangling reap +
#             aged-unused reap + an LRU size arm (see ac_gc_images).
#
# THE RELEASE RULE (a design decision, stated so a reviewer can see it rather than infer it):
#   * A PER-REPO entry (that repo's git mirror; downloads keyed to its build) is released when THAT
#     REPO'S objective reads SHIPPED. Release = drop `<dir>/<repo>` — that project's working set, and
#     nothing else. Every other repo's subtree survives untouched.
#   * A SHARED entry (dnf RPMs, base images — warmed by EVERY project) is released only when NO in-scope
#     repo has drivable work: STATUS=SHIPPED and DRIVABLE=0 for every repo `repo-scope.sh list` reports.
#     Releasing a shared cache on ONE project's completion would re-download for the projects still
#     running — the exact cost this objective exists to remove.
#   * RELEASE IS A TIGHTER CEILING, NEVER A WHOLESALE `rm -rf`. A shared cache has no per-project working
#     set to identify, so the only bounded release available to it is to re-run the SAME age+size arms
#     against the entry's COLD-FLOOR caps (rel_age_h / rel_cap_gb). The host's current wholesale
#     `rm -rf "$DNF_CACHE"` is the sibling feature's defect to fix and is deliberately NOT copied here.
#
# FAIL DIRECTION — TOWARD KEEPING THE CACHE, ALWAYS. An unreadable oracle, an absent `gh`, a missing
# scope reader, an INDETERMINATE verdict, a timeout: NO RELEASE. The age and size arms still run, so
# nothing becomes unbounded; only the completion arm is skipped, and it says so. An unreadable signal can
# never trigger a wholesale drop. AND THE GC NEVER EXITS NON-ZERO (asset_cache_gc always returns 0): it
# runs inside EVERY throwaway build, so a GC that could fail would be a way for the loop to stall (R39).
#
# THE ORACLE IS READ AT MOST ONCE PER TTL, AND ONLY A `HOLD` IS CACHED. The completion fact needs
# `objective-status.sh --status <repo>` per in-scope repo — several `gh` calls each, which at build
# cadence would be dozens of API calls per build. So a folded verdict is cached under
# $AC_STATE for AC_COMPLETION_TTL_MIN (60) — but the cache is honoured ONLY when it says HOLD (the
# NON-destructive verdict). A cached RELEASE is always re-verified fresh before anything is dropped, so
# the expensive read is paid exactly when we are about to act, and a stale RELEASE can never evict a
# cache that new work has started warming. This is a COST cache, not a decision record: it fails toward
# HOLD, and a wiped box simply re-reads GitHub.
#
# BASE-IMAGE PROTECTION IS STRUCTURAL, NOT A NAME LIST — and the name list would be actively WRONG.
# MEASURED on nox: `podman images --filter until=1440h` returns exactly `registry.fedoraproject.org/
# fedora:42` and `fedora-minimal:42` — SUPERSEDED bases left by the 42→44 bump, which are precisely what
# the age reap must remove, while `fedora:44` (the live pin) is what it must spare. Both match any
# sensible `registry.fedoraproject.org/fedora` prefix, so a prefix protect-list would either strand the
# garbage or shield it. What protects a base in USE is structural and measured:
#   (a) removal is NON-FORCED `podman rmi <ref>` — measured: an image referenced by ANY container, even
#       a merely-created one, refuses with rc 2 and is skipped (`image is in use by a container`);
#   (b) `podman image prune` is run WITHOUT `--external`, whose own --help defines it as "remove images
#       even when they are used by external containers (e.g., by BUILD containers)" — so by default an
#       in-flight `podman build`'s base is spared;
#   (c) the SIZE arm never considers anything younger than FD_STORE_MIN_AGE_MIN (default = FD_STALE_MIN,
#       12h), so a candidate a concurrent build is about to run is out of range by construction;
#   (d) the age ceiling itself bounds the residual cost to what the host already accepts: a
#       still-current base costs AT MOST ONE re-pull per FD_STORE_MAX_AGE_H window, never per churn
#       iteration.
# FD_STORE_PROTECT remains as an operator escape hatch (space-separated globs, matched against the
# reference, implicit trailing `*`) and is EMPTY by default for the reason above.
#
# PRINCIPLE 10 ("NEVER --no-cache/prune during churn") IS HONOURED, not bent: this runs NO `--no-cache`
# and NO blanket prune. Every image arm is age-floored past any plausible in-flight build and skips
# in-use images, so what it removes during churn is only what churn cannot be using — superseded
# digests, bumped bases, dangling cruft. The monthly clean `--no-cache` rebuild is untouched and remains
# the one time everything is pulled fresh (#311 non-goal).
#
# THE PRE-EXISTING DNF BEHAVIOUR IS PRESERVED, MEASURED — not asserted. The old `gc_dnf_cache` was
# extracted from the pre-change build-throwaway.sh and run against fixtures identical to this
# implementation's: age-only (45d cap, 50d/3d/1d RPMs + a metadata file) and size-only (1G cap,
# 3×400M RPMs) both left the BYTE-IDENTICAL survivor set. TWO divergences exist, both deliberate:
#
#   1. PRECISION. The registry's age unit is HOURS everywhere (one unit, one table), so the file arm uses
#      `find -mmin +$((age_h*60))` where the old code used `-mtime +45`. `-mtime +45` truncates to whole
#      24h units and so actually prunes at age >= 46 days; `-mmin` prunes at exactly the configured
#      boundary. The KNOB is unchanged (FD_DNF_CACHE_MAX_AGE_DAYS is still days, ×24 here) and the
#      ALGORITHM is unchanged (age-then-LRU, `*.rpm` only) — only the boundary is now exact.
#   2. A CAP OF 0 NO LONGER MEANS "EMPTY THE CACHE". Measured on the old code: `FD_DNF_CACHE_CAP_GB=0`
#      made `cur > 0` trivially true and the LRU walk then pruned EVERY RPM — one explicit zero wiped the
#      whole cache. `ac_over_cap` treats a non-positive or garbled cap as "no cap configured" and prunes
#      NOTHING, because an unusable bound must never authorize an eviction (bin/stop-release.sh's
#      #270 lesson, mirrored: an unreadable bound read as 0 is what turned `age > bound` permanently
#      true and SIGTERMed a healthy poller). Every realistic cap (>= 1G) behaves identically.
#
# SOURCEABLE. Sourcing defines functions and resolves knobs; it performs NO I/O and drops no files. The
# CLI below is `${BASH_SOURCE[0]}` = `$0` guarded (bin/stop-release.sh's precedent, and load-bearing:
# build-throwaway.sh sources this and has its own flags, so an unguarded `$1` test would fire on the
# CALLER'S argv).
#
#   asset-cache.sh --gc          run ONE full bounded-GC pass over the registry (always rc 0)
#   asset-cache.sh --registry    print the RESOLVED registry (operator/debug; no I/O on the caches)
#   asset-cache.sh --selftest    exercise the pure core (no podman / gh / network / filesystem)
#
# ENV KNOBS (all overridable; defaults chosen to bound without surprising):
#   FD_DNF_CACHE / FD_DNF_CACHE_CAP_GB / FD_DNF_CACHE_MAX_AGE_DAYS   pre-existing, unchanged (15G / 45d)
#   FD_DNF_CACHE_REL_CAP_GB / FD_DNF_CACHE_REL_AGE_DAYS   dnf COLD FLOOR once released      (2G / 7d)
#   FD_GIT_CACHE / FD_GIT_CACHE_CAP_GB / FD_GIT_CACHE_MAX_AGE_DAYS   sibling git mirrors    (5G / 45d)
#   FD_DL_CACHE  / FD_DL_CACHE_CAP_GB  / FD_DL_CACHE_MAX_AGE_DAYS    sibling downloads      (5G / 45d)
#   <ANY>_CAP_MB          overrides its _CAP_GB sibling (fine-grained; what the test suite uses)
#   FD_IMAGE_STORE        podman store dir, existence-checked only   (default ~/.local/share/containers)
#   FD_STORE_MAX_AGE_H    reap UNUSED images older than this         (default 1440h = 60d, host parity)
#   FD_STORE_CAP_GB       image-store SIZE cap                       (default 60; measured 76.8G/97%
#                                                                     reclaimable, 150G free)
#   FD_STORE_REL_CAP_GB / FD_STORE_REL_AGE_H   image COLD FLOOR once released          (10G / 168h = 7d)
#   FD_STORE_MIN_AGE_MIN  floor no image arm may cross    (default $FD_STALE_MIN, else 720 = 12h)
#   FD_STORE_EVICT_MAX    max images the SIZE arm evicts per pass    (default 200 — a bounded pass)
#   FD_STORE_PROTECT      operator protect globs                     (default EMPTY — see above)
#   AC_STATE              cost-cache dir            (default $HOME/.local/state/asset-cache)
#   AC_COMPLETION_TTL_MIN HOLD cache TTL, minutes                    (default 60)
#   AC_ORACLE / AC_SCOPE  the R30 ship oracle + the R16 scope reader (default the siblings here)
#   AC_ORACLE_TIMEOUT     per-repo oracle timeout, seconds           (default 20)
#   AC_COMPLETION         0 disables the completion arm entirely     (default 1; age+size still run)
#
# COVERAGE: the pure core by `--selftest`; the file/tree arms, the registry skip, the release rule and
# every fail direction end-to-end by asset-cache.test.sh (real dirs, real find/du, stubbed oracle +
# stubbed podman, plus one read-only real-engine row pinning the query shapes).
# Control-plane (the dev box's cache ceiling). MUST be tracked 100755.

AC_SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ---- knobs → the registry's resolved values --------------------------------------------------------
AC_DNF_CACHE="${FD_DNF_CACHE:-$HOME/.cache/fd-dnf}"
AC_DNF_CAP_MB="${FD_DNF_CACHE_CAP_MB:-$(( ${FD_DNF_CACHE_CAP_GB:-15} * 1024 ))}"
AC_DNF_AGE_H=$(( ${FD_DNF_CACHE_MAX_AGE_DAYS:-45} * 24 ))
AC_DNF_REL_CAP_MB="${FD_DNF_CACHE_REL_CAP_MB:-$(( ${FD_DNF_CACHE_REL_CAP_GB:-2} * 1024 ))}"
AC_DNF_REL_AGE_H=$(( ${FD_DNF_CACHE_REL_AGE_DAYS:-7} * 24 ))

AC_GIT_CACHE="${FD_GIT_CACHE:-$HOME/.cache/fd-git}"
AC_GIT_CAP_MB="${FD_GIT_CACHE_CAP_MB:-$(( ${FD_GIT_CACHE_CAP_GB:-5} * 1024 ))}"
AC_GIT_AGE_H=$(( ${FD_GIT_CACHE_MAX_AGE_DAYS:-45} * 24 ))

AC_DL_CACHE="${FD_DL_CACHE:-$HOME/.cache/fd-dl}"
AC_DL_CAP_MB="${FD_DL_CACHE_CAP_MB:-$(( ${FD_DL_CACHE_CAP_GB:-5} * 1024 ))}"
AC_DL_AGE_H=$(( ${FD_DL_CACHE_MAX_AGE_DAYS:-45} * 24 ))

AC_IMAGE_STORE="${FD_IMAGE_STORE:-$HOME/.local/share/containers}"
AC_STORE_CAP_MB="${FD_STORE_CAP_MB:-$(( ${FD_STORE_CAP_GB:-60} * 1024 ))}"
AC_STORE_AGE_H="${FD_STORE_MAX_AGE_H:-1440}"
AC_STORE_REL_CAP_MB="${FD_STORE_REL_CAP_MB:-$(( ${FD_STORE_REL_CAP_GB:-10} * 1024 ))}"
AC_STORE_REL_AGE_H="${FD_STORE_REL_AGE_H:-168}"
AC_STORE_MIN_AGE_MIN="${FD_STORE_MIN_AGE_MIN:-${FD_STALE_MIN:-720}}"
AC_STORE_EVICT_MAX="${FD_STORE_EVICT_MAX:-200}"
AC_STORE_PROTECT="${FD_STORE_PROTECT:-}"

AC_STATE="${AC_STATE:-$HOME/.local/state/asset-cache}"
AC_COMPLETION_TTL_MIN="${AC_COMPLETION_TTL_MIN:-60}"
AC_ORACLE="${AC_ORACLE:-$AC_SELF_DIR/objective-status.sh}"
AC_SCOPE="${AC_SCOPE:-$AC_SELF_DIR/repo-scope.sh}"
AC_ORACLE_TIMEOUT="${AC_ORACLE_TIMEOUT:-20}"
AC_COMPLETION="${AC_COMPLETION:-1}"
AC_PODMAN="${AC_PODMAN:-podman}"

# Action lines go to STDOUT (an operator and the tests read them; the pre-existing dnf GC did the same);
# diagnostics — every skip, every held release, every unreadable signal — go to STDERR.
ac_say(){ echo "gc: $*"; }
ac_log(){ echo "asset-cache: $*" >&2; }

# ---- THE REGISTRY ---------------------------------------------------------------------------------
# name|kind|dir|cap_mb|age_h|glob|scope|rel_cap_mb|rel_age_h      (`-` = not applicable to this kind)
ac_registry(){
  cat <<EOF
dnf|file|$AC_DNF_CACHE|$AC_DNF_CAP_MB|$AC_DNF_AGE_H|*.rpm|shared|$AC_DNF_REL_CAP_MB|$AC_DNF_REL_AGE_H
images|image|$AC_IMAGE_STORE|$AC_STORE_CAP_MB|$AC_STORE_AGE_H|-|shared|$AC_STORE_REL_CAP_MB|$AC_STORE_REL_AGE_H
git|tree|$AC_GIT_CACHE|$AC_GIT_CAP_MB|$AC_GIT_AGE_H|*|repo|-|-
dl|tree|$AC_DL_CACHE|$AC_DL_CAP_MB|$AC_DL_AGE_H|*|repo|-|-
EOF
}

# ---- PURE CORE (no I/O) — exercised by --selftest --------------------------------------------------

# ac_repo_release <status> <drivable> → RELEASE iff the repo's objective is SHIPPED with nothing
# drivable left. EVERYTHING else HOLDS: OPEN, INDETERMINATE, an empty/garbled field, an unreadable
# count. `classify` already makes SHIPPED imply drivable=0, so requiring both is a belt, not a change.
ac_repo_release(){
  local status="${1:-}" drivable="${2:-}"
  [ "$status" = "SHIPPED" ] || { printf 'HOLD'; return; }
  case "$drivable" in ''|*[!0-9]*) printf 'HOLD'; return;; esac
  [ "$drivable" -eq 0 ] && printf 'RELEASE' || printf 'HOLD'
}

# ac_shared_release <verdict…> → RELEASE iff there is AT LEAST ONE verdict and EVERY one is RELEASE.
# An EMPTY list is HOLD, deliberately: "no repo reported" is an unreadable scope, not a shipped fleet —
# reading it as "nothing has drivable work" would release every shared cache the moment the scope reader
# broke, which is the wholesale-drop-on-an-unreadable-signal the fail direction forbids.
ac_shared_release(){
  local v seen=0
  [ "$#" -gt 0 ] || { printf 'HOLD'; return; }
  for v in "$@"; do
    [ -n "$v" ] || continue
    seen=$((seen+1))
    [ "$v" = "RELEASE" ] || { printf 'HOLD'; return; }
  done
  [ "$seen" -gt 0 ] && printf 'RELEASE' || printf 'HOLD'
}

# ac_protected <ref> [globs…] → rc 0 iff the reference matches an operator protect glob (implicit
# trailing `*`, so `ghcr.io/oso-gato/x` covers every tag of it). Empty list protects nothing.
ac_protected(){
  local ref="${1:-}" pat
  shift || true
  [ -n "$ref" ] || return 1
  for pat in "$@"; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    case "$ref" in $pat*) return 0;; esac
  done
  return 1
}

# ac_over_cap <current-kb> <cap-mb> → rc 0 iff current EXCEEDS the cap. A garbled size or a
# non-positive cap is NOT over cap: an unreadable measurement must never authorize an eviction.
ac_over_cap(){
  local cur="${1:-}" cap="${2:-}"
  case "$cur" in ''|*[!0-9]*) return 1;; esac
  case "$cap" in ''|*[!0-9]*) return 1;; esac
  [ "$cap" -gt 0 ] || return 1
  [ "$cur" -gt $(( cap * 1024 )) ]
}

# ac_effective_caps <released> <cap_mb> <age_h> <rel_cap_mb> <rel_age_h> → "<cap_mb> <age_h>" to apply.
# THIS is the shared release, mechanically: a released shared cache is re-bounded against its COLD-FLOOR
# caps instead of being dropped. A `-`/garbled floor falls back to the steady cap (never to 0, which
# would empty the cache — the inverse of a bounded release).
ac_effective_caps(){
  local released="${1:-}" cap="${2:-}" age="${3:-}" rcap="${4:-}" rage="${5:-}"
  if [ "$released" = "RELEASE" ]; then
    case "$rcap" in ''|*[!0-9]*) rcap="$cap";; esac
    case "$rage" in ''|*[!0-9]*) rage="$age";; esac
    printf '%s %s' "$rcap" "$rage"
  else
    printf '%s %s' "$cap" "$age"
  fi
}

# ---- COMPLETION SIGNAL (live reads; every failure path HOLDS) --------------------------------------

# ac_oracle_verdict <repo> → RELEASE|HOLD, from the R30 ship oracle. Anything unreadable → HOLD.
ac_oracle_verdict(){
  local repo="$1" out status drivable
  [ -x "$AC_ORACLE" ] || { ac_log "ship oracle not executable ($AC_ORACLE) — completion HELD for $repo"; printf 'HOLD'; return; }
  out="$(timeout "$AC_ORACLE_TIMEOUT" "$AC_ORACLE" --status "$repo" 2>/dev/null)" || {
    ac_log "ship oracle unreadable for $repo (rc≠0 / timeout) — completion HELD"; printf 'HOLD'; return; }
  status="$(printf '%s\n' "$out" | sed -n 's/^STATUS: *//p' | head -1)"
  drivable="$(printf '%s\n' "$out" | sed -n 's/^DRIVABLE: *//p' | head -1)"
  local v; v="$(ac_repo_release "$status" "$drivable")"
  [ "$v" = "RELEASE" ] || ac_log "completion HELD for $repo (STATUS=${status:-unreadable} DRIVABLE=${drivable:-unreadable})"
  printf '%s' "$v"
}

# ac_cached_verdict <key> <compute-fn> [args…] → RELEASE|HOLD, honouring the HOLD-ONLY TTL cache.
# A fresh cached HOLD is reused (the cheap, non-destructive answer). A cached RELEASE is IGNORED and
# recomputed, so nothing is ever dropped on a stale read.
ac_cached_verdict(){
  local key="$1"; shift
  local f="$AC_STATE/$key.verdict" now mt age v
  if [ -r "$f" ]; then
    v="$(head -1 "$f" 2>/dev/null)"
    now="$(date +%s 2>/dev/null)"; mt="$(stat -c %Y "$f" 2>/dev/null)"
    case "${now:-x}${mt:-x}" in *x*) age="";; *) age=$(( (now - mt) / 60 ));; esac
    if [ "$v" = "HOLD" ] && [ -n "$age" ] && [ "$age" -lt "$AC_COMPLETION_TTL_MIN" ]; then
      printf 'HOLD'; return
    fi
  fi
  v="$("$@")"
  mkdir -p "$AC_STATE" 2>/dev/null && printf '%s\n' "$v" > "$f" 2>/dev/null
  printf '%s' "$v"
}

# ac_shared_verdict → RELEASE iff EVERY in-scope repo reads SHIPPED with DRIVABLE=0.
ac_shared_verdict(){
  local repos v verdicts=()
  [ -x "$AC_SCOPE" ] || { ac_log "scope reader not executable ($AC_SCOPE) — shared completion HELD"; printf 'HOLD'; return; }
  repos="$("$AC_SCOPE" list 2>/dev/null)" || { ac_log "scope unreadable (rc≠0) — shared completion HELD"; printf 'HOLD'; return; }
  while read -r r; do
    [ -n "$r" ] || continue
    verdicts+=("$(ac_oracle_verdict "$r")")
  done <<EOF
$repos
EOF
  v="$(ac_shared_release "${verdicts[@]+"${verdicts[@]}"}")"
  [ "$v" = "RELEASE" ] || ac_log "shared completion HELD (${#verdicts[@]} in-scope repo(s); a shared cache releases only when NONE has drivable work)"
  printf '%s' "$v"
}

# ac_entry_release <scope> → the SHARED verdict, or HOLD for a per-repo entry (whose release is
# per-subtree, decided in ac_release_repo_subtrees, not by one fleet-wide verdict).
ac_entry_release(){
  [ "${AC_COMPLETION:-1}" = 1 ] || { printf 'HOLD'; return; }
  [ "${1:-}" = "shared" ] || { printf 'HOLD'; return; }
  ac_cached_verdict shared ac_shared_verdict
}

# ---- THE THREE ARMS -------------------------------------------------------------------------------

# ac_gc_files <label> <dir> <glob> <age_h> <cap_mb> — AGE-prune first, then LRU SIZE-prune. This IS the
# pre-existing gc_dnf_cache algorithm, generalized over (dir, glob, caps): drop genuinely-stale files by
# age, then — only if still over the size cap — walk newest-first and prune everything past the cap, so
# the freshest churn inputs stay hot.
ac_gc_files(){
  local label="$1" dir="$2" glob="$3" age_h="$4" cap_mb="$5"
  local age_min=$(( age_h * 60 )) cap_bytes cur_kb running _t sz path
  while IFS= read -r -d '' path; do
    rm -f "$path" 2>/dev/null && ac_say "$label age-prune $(basename "$path") (>${age_h}h)"
  done < <(find "$dir" -type f -name "$glob" -mmin +"$age_min" -print0 2>/dev/null)
  cur_kb="$(du -sk "$dir" 2>/dev/null | cut -f1)"; cur_kb="${cur_kb:-0}"
  ac_over_cap "$cur_kb" "$cap_mb" || return 0
  cap_bytes=$(( cap_mb * 1024 * 1024 ))
  ac_say "$label cache $(( cur_kb / 1024 ))M > cap ${cap_mb}M — LRU-pruning oldest"
  running=0
  while IFS=$'\t' read -r _t sz path; do
    running=$(( running + sz ))
    if [ "$running" -gt "$cap_bytes" ]; then
      rm -f "$path" 2>/dev/null && ac_say "$label size-prune $(basename "$path")"
    fi
  done < <(find "$dir" -type f -name "$glob" -printf '%T@\t%s\t%p\n' 2>/dev/null | sort -rn)
}

# ac_gc_trees <label> <dir> <age_h> <cap_mb> — the same age-then-LRU shape at SUBDIRECTORY granularity.
# A git mirror or a per-repo download set is an ALL-OR-NOTHING unit: pruning files inside one would
# corrupt it, so the unit here is the immediate subdirectory and its mtime is the LRU key.
ac_gc_trees(){
  local label="$1" dir="$2" age_h="$3" cap_mb="$4"
  local age_min=$(( age_h * 60 )) cap_bytes cur_kb running _t sub sz
  while IFS= read -r -d '' sub; do
    rm -rf "$sub" 2>/dev/null && ac_say "$label age-prune $(basename "$sub")/ (>${age_h}h)"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -mmin +"$age_min" -print0 2>/dev/null)
  cur_kb="$(du -sk "$dir" 2>/dev/null | cut -f1)"; cur_kb="${cur_kb:-0}"
  ac_over_cap "$cur_kb" "$cap_mb" || return 0
  cap_bytes=$(( cap_mb * 1024 * 1024 ))
  ac_say "$label cache $(( cur_kb / 1024 ))M > cap ${cap_mb}M — LRU-pruning oldest subtrees"
  running=0
  while IFS=$'\t' read -r _t sub; do
    [ -d "$sub" ] || continue
    sz="$(du -sk "$sub" 2>/dev/null | cut -f1)"; sz=$(( ${sz:-0} * 1024 ))
    running=$(( running + sz ))
    if [ "$running" -gt "$cap_bytes" ]; then
      rm -rf "$sub" 2>/dev/null && ac_say "$label size-prune $(basename "$sub")/"
    fi
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@\t%p\n' 2>/dev/null | sort -rn)
}

# ac_release_repo_subtrees <label> <dir> — THE PER-REPO COMPLETION RELEASE. For each immediate
# subdirectory named after a repo whose objective reads SHIPPED, drop THAT subtree and nothing else. A
# subdir we cannot get a verdict for is left alone (fail toward keeping); a subdir that is not a repo we
# track is likewise left to the age/size arms. This is what "bounded release" means at the per-repo
# granularity: the completed project's working set goes, every other project's stays.
ac_release_repo_subtrees(){
  local label="$1" dir="$2" sub name v
  [ "${AC_COMPLETION:-1}" = 1 ] || return 0
  while IFS= read -r -d '' sub; do
    name="$(basename "$sub")"
    v="$(ac_cached_verdict "repo-$name" ac_oracle_verdict "$name")"
    [ "$v" = "RELEASE" ] || continue
    rm -rf "$sub" 2>/dev/null && ac_say "$label completion-release $name/ (its objective reads SHIPPED)"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
}

# ac_gc_images <label> <age_h> <cap_mb> — bound the podman image/layer store. THREE arms, all age-floored
# past any plausible in-flight build (see BASE-IMAGE PROTECTION in the header) and all non-forced:
#   (a) DANGLING build-layer cruft (host throwaway-sweep.sh step 5 parity) — but UNLIKE the host's
#       blanket form this one carries `--filter until=<floor>`, so a CONCURRENT build's intermediate
#       layers are out of range. Dangling images are untagged, so no tagged base can be in this set.
#   (b) AGED UNUSED images (host step 6's ceiling). The host runs the blanket
#       `podman image prune -a -f --filter until=…`; this enumerates the aged references and removes
#       them ONE BY ONE with a NON-FORCED `rmi`, which buys two things the blanket form cannot: an
#       in-use image REFUSES (measured rc 2) instead of relying on prune's running-container-only
#       sparing, and the operator protect-list is applicable at all. Removing by REFERENCE (not ID) is
#       deliberate — measured: `rmi <ref>` on a multi-tagged image UNTAGS only, so a shared base loses
#       just the stale name.
#   (c) SIZE cap, LRU. Only over cap, only past the floor, oldest-first, bounded by FD_STORE_EVICT_MAX.
#       The reclaimed total is ESTIMATED by subtracting each removed image's own `.Size` from podman's
#       RawSize, which double-counts shared layers — so the pass under-reclaims rather than over-evicts
#       and the next pass re-measures. Approximate and CONVERGENT, deliberately, because re-measuring
#       via `podman system df` after every eviction costs ~0.9s each (measured) and this runs per build.
ac_gc_images(){
  local label="$1" age_h="$2" cap_mb="$3"
  local floor="$AC_STORE_MIN_AGE_MIN" ref raw need evicted sz pruned n
  # (a) dangling, age-floored. `prune` exits 0 with nothing to do, so the COUNT of ids it printed — not
  # its rc — is what decides whether anything is reported: a sweeper that announced a "dangling-prune"
  # on every build would be claiming an action it usually did not take.
  pruned="$("$AC_PODMAN" image prune -f --filter "until=${floor}m" 2>/dev/null)"
  n="$(printf '%s' "$pruned" | grep -c .)"
  [ "${n:-0}" -gt 0 ] && ac_say "$label dangling-prune: $n layer(s) older than ${floor}m"
  # (b) aged unused.
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in *'<none>'*) continue;; esac          # dangling — arm (a) owns those
    # shellcheck disable=SC2086
    if ac_protected "$ref" $AC_STORE_PROTECT; then
      ac_log "$label: $ref is protect-listed — kept"; continue
    fi
    # if/else, not `A && B || C`: C must report ONLY an rmi refusal. Under the `||` form a failing
    # `ac_say` (a closed stdout) would print "in use" about an image that was in fact removed — and the
    # in-use/kept line is exactly what an operator reads to see a base image was spared.
    if "$AC_PODMAN" rmi "$ref" >/dev/null 2>&1; then
      ac_say "$label age-prune $ref (>${age_h}h, unused)"
    else
      ac_log "$label: $ref in use or undeletable — kept"
    fi
  done < <("$AC_PODMAN" images --filter "until=${age_h}h" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)
  # (c) size cap.
  raw="$("$AC_PODMAN" system df --format json 2>/dev/null \
        | tr ',' '\n' | sed -n 's/.*"RawSize":\([0-9]\+\).*/\1/p' | head -1)"
  case "${raw:-x}" in ''|*[!0-9]*) ac_log "$label: store size unreadable — size cap not applied this pass"; return 0;; esac
  ac_over_cap $(( raw / 1024 )) "$cap_mb" || return 0
  need=$(( raw - cap_mb * 1024 * 1024 ))
  ac_say "$label store $(( raw / 1024 / 1024 ))M > cap ${cap_mb}M — LRU-evicting oldest unused images"
  evicted=0
  # podman's `created` sort is NEWEST-first (measured), so `tac` yields LRU order.
  while IFS= read -r ref; do
    [ "$need" -gt 0 ] || break
    [ "$evicted" -lt "$AC_STORE_EVICT_MAX" ] || { ac_log "$label: eviction bound ${AC_STORE_EVICT_MAX} reached — next pass continues"; break; }
    [ -n "$ref" ] || continue
    case "$ref" in *'<none>'*) continue;; esac
    # shellcheck disable=SC2086
    ac_protected "$ref" $AC_STORE_PROTECT && continue
    sz="$("$AC_PODMAN" image inspect -f '{{.Size}}' "$ref" 2>/dev/null)"
    case "${sz:-x}" in ''|*[!0-9]*) sz=0;; esac
    if "$AC_PODMAN" rmi "$ref" >/dev/null 2>&1; then
      need=$(( need - sz )); evicted=$(( evicted + 1 ))
      ac_say "$label size-evict $ref"
    fi
  done < <("$AC_PODMAN" images --sort=created --filter "until=${floor}m" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | tac)
}

# ---- THE ONE PASS ---------------------------------------------------------------------------------
# Walks the registry and enforces all three bounds per entry. ALWAYS returns 0 — it runs inside every
# throwaway build and must never become a way for the loop to stall (R39).
asset_cache_gc(){
  local name kind dir cap age glob scope rcap rage released eff
  while IFS='|' read -r name kind dir cap age glob scope rcap rage; do
    [ -n "${name:-}" ] || continue
    if [ ! -d "$dir" ]; then continue; fi          # a registry entry with no dir is SKIPPED, silently
    released="$(ac_entry_release "$scope")"
    eff="$(ac_effective_caps "$released" "$cap" "$age" "$rcap" "$rage")"
    read -r cap age <<EOF
$eff
EOF
    [ "$released" = "RELEASE" ] && ac_say "$name COMPLETION-RELEASE: no in-scope repo has drivable work — re-bounding to the cold floor (${cap}M / ${age}h)"
    case "$kind" in
      file)  ac_gc_files  "$name" "$dir" "$glob" "$age" "$cap";;
      tree)  ac_release_repo_subtrees "$name" "$dir"
             ac_gc_trees  "$name" "$dir" "$age" "$cap";;
      image) ac_gc_images "$name" "$age" "$cap";;
      *)     ac_log "unknown cache kind '$kind' for entry '$name' — skipped";;
    esac
  done < <(ac_registry)
  return 0
}

# ---- CLI (BASH_SOURCE-guarded: build-throwaway.sh sources this and owns its own argv) --------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --gc) asset_cache_gc; exit 0;;
    --registry) ac_registry; exit 0;;
    --selftest) : ;;
    *) echo "usage: asset-cache.sh --gc | --registry | --selftest" >&2; exit 2;;
  esac

  p=0; f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }

  echo "== ac_repo_release: only a SHIPPED objective with nothing drivable releases =="
  ck "SHIPPED + 0 drivable → RELEASE"     "$(ac_repo_release SHIPPED 0)" "RELEASE"
  ck "SHIPPED but 2 drivable → HOLD"      "$(ac_repo_release SHIPPED 2)" "HOLD"
  ck "OPEN → HOLD"                        "$(ac_repo_release OPEN 0)" "HOLD"
  ck "INDETERMINATE → HOLD"               "$(ac_repo_release INDETERMINATE 0)" "HOLD"
  ck "empty status → HOLD"                "$(ac_repo_release '' 0)" "HOLD"
  ck "unreadable drivable ('?') → HOLD"   "$(ac_repo_release SHIPPED '?')" "HOLD"
  ck "empty drivable → HOLD"              "$(ac_repo_release SHIPPED '')" "HOLD"

  echo "== ac_shared_release: a shared cache releases only when EVERY repo says so =="
  ck "all RELEASE → RELEASE"              "$(ac_shared_release RELEASE RELEASE RELEASE)" "RELEASE"
  ck "one HOLD anywhere → HOLD"           "$(ac_shared_release RELEASE HOLD RELEASE)" "HOLD"
  ck "first HOLD → HOLD"                  "$(ac_shared_release HOLD RELEASE)" "HOLD"
  ck "single RELEASE → RELEASE"           "$(ac_shared_release RELEASE)" "RELEASE"
  # An unreadable scope yields NO verdicts. That must never read as "the whole fleet shipped".
  ck "NO repos reported → HOLD"           "$(ac_shared_release)" "HOLD"
  ck "only empty strings → HOLD"          "$(ac_shared_release '' '')" "HOLD"

  echo "== ac_over_cap (kb vs cap in MiB): unreadable size / unusable cap never authorizes an eviction =="
  ck "2M used vs 1M cap → over"           "$(ac_over_cap 2048 1 && echo over || echo under)" "over"
  ck "exactly at cap → under"             "$(ac_over_cap 1024 1 && echo over || echo under)" "under"
  ck "one KiB over → over"                "$(ac_over_cap 1025 1 && echo over || echo under)" "over"
  ck "unreadable size → under"            "$(ac_over_cap '' 1 && echo over || echo under)" "under"
  ck "garbled size → under"               "$(ac_over_cap x 1 && echo over || echo under)" "under"
  ck "cap 0 → under (no cap configured)"  "$(ac_over_cap $((9*1024*1024)) 0 && echo over || echo under)" "under"
  ck "garbled cap → under"                "$(ac_over_cap $((9*1024*1024)) x && echo over || echo under)" "under"

  echo "== ac_effective_caps: a release TIGHTENS to the cold floor, it never empties the cache =="
  ck "HOLD → the steady caps"             "$(ac_effective_caps HOLD 15360 1080 2048 168)" "15360 1080"
  ck "RELEASE → the cold floor"           "$(ac_effective_caps RELEASE 15360 1080 2048 168)" "2048 168"
  ck "RELEASE, floor '-' → steady caps"   "$(ac_effective_caps RELEASE 15360 1080 - -)" "15360 1080"
  ck "RELEASE, garbled floor → steady"    "$(ac_effective_caps RELEASE 15360 1080 x x)" "15360 1080"

  echo "== ac_protected: an operator glob covers every tag; an empty list protects nothing =="
  ck "prefix glob matches a tag"          "$(ac_protected ghcr.io/oso-gato/x:latest ghcr.io/oso-gato/x && echo yes || echo no)" "yes"
  ck "non-matching ref"                   "$(ac_protected localhost/y:1 ghcr.io/oso-gato/x && echo yes || echo no)" "no"
  ck "empty list protects nothing"        "$(ac_protected localhost/y:1 && echo yes || echo no)" "no"
  ck "second glob in the list matches"    "$(ac_protected a/b:1 x/y a/b && echo yes || echo no)" "yes"

  echo "== the registry: four declared caches, nine fields each, the two sibling rows per-repo =="
  ck "registry row count"                 "$(ac_registry | grep -c .)" "4"
  ck "every row has 9 fields"             "$(ac_registry | awk -F'|' '{print NF}' | sort -u | tr -d '\n')" "9"
  ck "dnf glob is *.rpm only (metadata kept)" "$(ac_registry | awk -F'|' '$1=="dnf"{print $6}')" "*.rpm"
  ck "dnf scope is shared"                "$(ac_registry | awk -F'|' '$1=="dnf"{print $7}')" "shared"
  ck "images scope is shared"             "$(ac_registry | awk -F'|' '$1=="images"{print $7}')" "shared"
  ck "git scope is repo"                  "$(ac_registry | awk -F'|' '$1=="git"{print $7}')" "repo"
  ck "dl scope is repo"                   "$(ac_registry | awk -F'|' '$1=="dl"{print $7}')" "repo"
  ck "dnf age cap = 45d in hours"         "$(ac_registry | awk -F'|' '$1=="dnf"{print $5}')" "1080"
  ck "image age cap = host's 1440h"       "$(ac_registry | awk -F'|' '$1=="images"{print $5}')" "1440"
  ck "dnf size cap = 15G in MiB"          "$(ac_registry | awk -F'|' '$1=="dnf"{print $4}')" "15360"
  ck "image size cap = 60G in MiB"        "$(ac_registry | awk -F'|' '$1=="images"{print $4}')" "61440"
  # A *_CAP_MB knob must beat its *_CAP_GB sibling — this is the seam the test suite drives.
  ck "FD_DNF_CACHE_CAP_MB overrides GB" \
     "$(FD_DNF_CACHE_CAP_MB=7 FD_DNF_CACHE_CAP_GB=15 bash "$0" --registry | awk -F'|' '$1=="dnf"{print $4}')" "7"

  echo; echo "asset-cache selftest: $p passed, $f failed"
  [ "$f" -eq 0 ]; exit
fi
