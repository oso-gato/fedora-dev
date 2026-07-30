#!/usr/bin/env bash
# bandwidth-probe.sh — MEASURE the bytes two consecutive builds actually pull, per asset class.
# (fedora-dev#322 — of objective #311 "stop re-downloading assets that have not changed".)
#
# WHAT THIS IS. The objective's acceptance command. #311's acceptance is deliberately a MEASUREMENT and
# not an assertion: *"a check that measures actual bytes pulled across two consecutive builds, rather
# than asserting a cache mechanism exists."* That wording is load-bearing, and the measurement taken
# while planning proves why — a Containerfile `ADD <url>` step reports `--> Using cache <id>` and STILL
# pulls the whole asset on the second build. Reproduced in-box 2026-07-30: a 6 KB `ADD` printed
# `--> Using cache` on build 2 and moved 15,011 bytes across the wire. Any probe that grepped build
# logs for cache hits would have passed that. Only bytes catch it. So the primary signal here is a real
# kernel byte counter; build logs may corroborate and never decide.
#
# THE FOUR CLASSES (#311's list) and how each is driven — see probe-fixtures/bandwidth/README.md:
#   ospkg    OS packages      two builds, each with a UNIQUE CACHEBUST so the LAYER cache is defeated
#                             on purpose and the PERSISTENT dnf package cache is what must supply the
#                             bytes. Without that the layer cache answers for the class and the arm
#                             would go green having never consulted the cache #311 is about.
#   baseimg  base images      two builds, no cachebust — `FROM` consults the local layer/blob store
#                             directly, so build 2 costing nothing IS the measured property.
#   gitobj   git objects      two fresh shallow clones. #311 measured "no cache; every clone is fresh",
#                             so two FRESH clones measure the actual waste; a clone-then-fetch pair
#                             would read ~zero and report a broken class healthy.
#   langdep  language/vendor  no such asset exists in this repo (Principle 2 forbids pip/npm/cargo/gem,
#                             and CLAUDE.md records "Class-(c) artifacts in use: none"), so the arm
#                             reports SKIPPED — which BLOCKS exit 0. Silence must never read as zero.
#
# THE NOISE FLOOR IS MEASURED, NEVER GUESSED. The counter is box-wide and this box is never silent (the
# poller, tailscale, `gh`, headless model runs). So the probe samples IDLE WINDOWS FIRST, derives a
# per-second rate from the WORST of them, scales it to each build's own duration, and compares against
# THAT — not against zero. Every input is printed: the samples, the window, the rate, the slack and the
# derived per-class floor. A threshold nobody can see is a threshold nobody can trust.
#   Measured in-box 2026-07-30 over ten 3 s idle windows: min 4,032 · median 4,994 · max 12,526 bytes
#   (~1.7 KB/s), and separately a burst of 156,228 bytes in 3 s. The noise is bursty, and that is the
#   honest limit of this instrument: an asset SMALLER than the floor cannot be told from box chatter.
#
# WHICH IS EXACTLY WHY THE NEGATIVE CONTROL DECIDES THE VERDICT TOO, and is the property that keeps the
# whole probe honest. Every run performs a download that MUST be seen — the same measurement path, and
# judged against the STRICTEST floor any class in that run was judged at (see control_floor) — with the
# relevant cache redirected to an EMPTY temp dir. If that download clears the bar the instrument
# DETECTS; if the floor has grown large enough to swallow a real download the control reads BLIND and
# the verdict is RED. So a box too noisy to measure reports "I could not measure", never a pass. A probe
# that cannot fail is not evidence.
#
# IT REDIRECTS CACHES, IT NEVER PRUNES THEM. The control points `FD_DNF_CACHE` (or the clone target) at
# a fresh empty temp dir of its own; the real persistent caches are never emptied, aged or pruned, and
# no build here is given the flag that would disable layer caching. Destroying the cache under
# measurement would make the next run's figures meaningless — and the cache is the thing the objective
# exists to keep. (That flag, the sweeper verb and the image-removal verb are named DESCRIPTIVELY here
# and appear nowhere literally, so bandwidth-probe.test.sh's mechanical scan for them reads EMPTY over
# the whole file, comments included — a scan that trips over the very sentence promising restraint
# teaches a reader to distrust the scan. The convention is bin/residue-witness.sh's.)
#
# BOTH BOXES, FAIL-CLOSED. #311 requires all four classes on BOTH boxes. This measures the dev half
# itself and drives the host half over the existing ticket bus (`host-ticket.sh --wait bandwidth-probe`).
# Exit 0 requires both. While the host verb does not exist the ticket comes back FAILED and the probe
# reports `HOST: UNAVAILABLE` and exits non-zero — correct and honest: it must not pass by ignoring the
# half it cannot reach. Repeat runs REUSE an already-open ticket rather than filing one per run
# (`--mine`/`--outcome`), so an acceptance command that may be run often cannot spam the control repo.
# `BW_HOST=skip` measures the dev half without touching the bus and still reports UNAVAILABLE (RED).
#
# PRINCIPLE 10. Fixture builds go through `bin/build-throwaway.sh` (chroot isolation, the persistent dnf
# cache, a disposable `localhost/disposable/*` tag, EXIT-trap teardown). Everything this file creates
# itself — fixture copies, clone targets, the control's empty cache dir, logs — is reaped by its own
# trap on EVERY exit path including INT/TERM/HUP.
#
# OUTPUT / EXIT CONTRACT
#   line 1  bandwidth-probe: <VERDICT> dev=<...> host=<...>      (the house one-line summary)
#   then    a human-readable per-class report
#   then    the machine-readable KV block #322 specifies, consumable as an OBJECTIVE_ACCEPTANCE probe
#           by bin/objective-status.sh with no prose to re-parse:
#             CLASS_OSPKG: <state> <bytes-build-1> <bytes-build-2>     state ZERO|NONZERO|SKIPPED|ERROR
#             CLASS_BASEIMG: …  CLASS_GITOBJ: …  CLASS_LANGDEP: SKIPPED - -
#             FLOOR: <sampled-max-bytes> <window-s> <slack-pct> <min-bytes>
#             CONTROL: DETECTS|BLIND
#             HOST: ZERO|NONZERO|UNAVAILABLE
#             VERDICT: GREEN|RED
#   rc 0 = GREEN (every class zero on build 2, on BOTH boxes, with a detecting control)
#   rc 1 = RED · rc 2 = usage/harness error (never a verdict)
#
#   bandwidth-probe.sh              both halves — #311's acceptance command, no arguments
#   bandwidth-probe.sh dev          the dev half only
#   bandwidth-probe.sh host         the host half only
#   bandwidth-probe.sh --selftest   the pure decision core; no builds, no network, no engine
#
# ENV: BW_FIXTURES · BW_BUILD · BW_HOST_TICKET · BW_HOST (bus|skip) · BW_HOST_TIMEOUT · BW_IFACE ·
#      BW_FLOOR_WINDOW · BW_FLOOR_SAMPLES · BW_FLOOR_SLACK_PCT · BW_FLOOR_MIN · BW_CLASSES · TMPDIR.
#
# Covered by bandwidth-probe.test.sh. Control-plane (the bandwidth boundary's prover).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

FIXTURES="${BW_FIXTURES:-$REPO_ROOT/probe-fixtures/bandwidth}"
BUILDER="${BW_BUILD:-$HERE/build-throwaway.sh}"
HOST_TICKET="${BW_HOST_TICKET:-$HERE/host-ticket.sh}"
HOST_MODE="${BW_HOST:-bus}"
HOST_VERB="bandwidth-probe"
HOST_TIMEOUT="${BW_HOST_TIMEOUT:-300}"
FLOOR_WINDOW="${BW_FLOOR_WINDOW:-3}"          # seconds per idle sample
FLOOR_SAMPLES="${BW_FLOOR_SAMPLES:-5}"        # how many idle windows to sample
FLOOR_SLACK_PCT="${BW_FLOOR_SLACK_PCT:-300}"  # 3x the worst observed idle rate
FLOOR_MIN="${BW_FLOOR_MIN:-131072}"           # 128 KiB — never trust a floor below the observed bursts
# `-`, not `:-`: an EXPLICITLY EMPTY BW_CLASSES means "measure nothing", which roll_up must call RED.
# With `:-` an empty value would silently fall back to the full set, so the one configuration that can
# reach the vacuous-pass guard would be unreachable — and a guard nothing can reach is not a guard.
CLASSES="${BW_CLASSES-ospkg baseimg gitobj langdep}"
TMPD="${TMPDIR:-/tmp}"
OBJECTIVE="#311"

warn(){ printf 'bandwidth-probe: %s\n' "$*" >&2; }

# ---- PURE CORE (--selftest covers exactly these) ---------------------------------------------------

# floor_for <worst-sample-bytes> <window-s> <duration-s> <slack-pct> <min-bytes> → the byte floor a
# build of <duration-s> is allowed to move before it counts as having pulled something.
#
# Integer arithmetic throughout (no bc, no floats): floor = worst * duration * slack% / (window * 100),
# then raised to <min-bytes>. A sub-second build is charged a full second — rounding must never produce
# a floor of zero, which would turn ordinary chatter into a RED.
#
# FAIL DIRECTION: any unusable input yields <min-bytes> rather than 0. A floor of zero on a box that is
# never silent would make every class RED for reasons that have nothing to do with caching — noise, not
# a measurement. Too LOW a floor is caught by the class arms going RED; too HIGH a floor is caught by
# the negative control going BLIND. Both mistakes are visible; neither can produce a silent pass.
floor_for(){
  local worst="${1:-}" window="${2:-}" dur="${3:-}" slack="${4:-}" min="${5:-0}" f
  case "$min" in ''|*[!0-9]*) min=0;; esac
  case "$worst"  in ''|*[!0-9]*) printf '%s' "$min"; return 0;; esac
  case "$window" in ''|*[!0-9]*) printf '%s' "$min"; return 0;; esac
  case "$slack"  in ''|*[!0-9]*) printf '%s' "$min"; return 0;; esac
  case "$dur"    in ''|*[!0-9]*) dur=1;; esac
  [ "$window" -gt 0 ] || { printf '%s' "$min"; return 0; }
  [ "$dur" -ge 1 ] || dur=1
  f=$(( worst * dur * slack / (window * 100) ))
  [ "$f" -lt "$min" ] && f="$min"
  printf '%s' "$f"
}

# bytes_verdict <bytes> <floor> → ZERO | NONZERO | ERROR.
# ZERO means "at or under the measured noise floor", never literally zero — see the header. A
# non-numeric reading is ERROR, never ZERO: "I could not read the counter" must not report as "nothing
# was pulled", which is the unmeasured-evidence failure this objective family exists to end.
bytes_verdict(){
  local b="${1:-}" f="${2:-}"
  case "$b" in ''|*[!0-9]*) printf 'ERROR'; return 0;; esac
  case "$f" in ''|*[!0-9]*) printf 'ERROR'; return 0;; esac
  if [ "$b" -le "$f" ]; then printf 'ZERO'; else printf 'NONZERO'; fi
}

# class_verdict <arm-state> <bytes-build-2> <floor> → ZERO | NONZERO | SKIPPED | ERROR.
#   ABSENT  → SKIPPED  a class with nothing to measure. #322: it must PREVENT exit 0 — silence is not
#                      evidence of zero bytes, and a probe that quietly drops a class it could not
#                      measure is exactly the vacuous pass the objective forbids.
#   FAILED  → ERROR    the fixture build/clone itself failed, so no byte figure means anything.
#   PRESENT → the byte comparison.
class_verdict(){
  case "${1:-}" in
    ABSENT)  printf 'SKIPPED'; return 0;;
    PRESENT) bytes_verdict "${2:-}" "${3:-}"; return 0;;
    *)       printf 'ERROR'; return 0;;
  esac
}

# control_floor <control-own-floor> <largest-class-floor> → the bar the control must clear.
#
# THE STRICTEST BAR ANY CLASS WAS ACTUALLY JUDGED AT, not the control's own. Floors are scaled by each
# measurement's DURATION, so a slow class gets a much larger floor than a fast control: measured in-box
# 2026-07-30, a 6 s ospkg build was judged at 684.6 KiB while the sub-second control was judged at
# 128.0 KiB. Judging the control at its own floor alone would let a ~500 KiB re-download inside that
# class read ZERO while the control still cheerfully reported DETECTS — the self-invalidation property
# this probe's honesty rests on, quietly holed. Making the control clear the WORST bar in the run
# restores it: the control proves detection at the strictness actually applied, or it reads BLIND.
control_floor(){ max_of "${1:-0}" "${2:-0}"; }

# control_verdict <bytes> <floor> → DETECTS | BLIND.
# The negative control performs a download that MUST be visible. DETECTS iff it cleared the floor from
# control_floor above — which is what makes an over-large floor self-reporting: if the floor has grown
# big enough to hide a real download, the control cannot clear it either and the run is RED.
# Anything unreadable or unrun is BLIND (an unproven control is not a proven control).
control_verdict(){
  local b="${1:-}" f="${2:-}"
  case "$b" in ''|*[!0-9]*) printf 'BLIND'; return 0;; esac
  case "$f" in ''|*[!0-9]*) printf 'BLIND'; return 0;; esac
  if [ "$b" -gt "$f" ]; then printf 'DETECTS'; else printf 'BLIND'; fi
}

# host_verdict <ticket-rc> [outcome-text] → ZERO | NONZERO | UNAVAILABLE.
# The bus reports DONE (rc 0) / FAILED (rc 1) / no-response (rc 2). #322: while the host verb does not
# exist the ticket comes back FAILED and that is UNAVAILABLE — "the half could not be reached", which is
# NOT the same claim as "the host pulled bytes", and conflating them would put a measurement on record
# that nobody took. A host half that grows a real verdict can say so in its text; that is read here so
# NONZERO is a reachable state rather than a decorative one in the KV grammar.
host_verdict(){
  local rc="${1:-}" text="${2:-}"
  case "$text" in *NONZERO*|*"VERDICT: RED"*) printf 'NONZERO'; return 0;; esac
  case "$rc" in 0) printf 'ZERO';; *) printf 'UNAVAILABLE';; esac
}

# roll_up <control> <host> <class-verdict…> → GREEN | RED.
# GREEN requires ALL of: a DETECTS control, a ZERO host, and every class ZERO.
# AN EMPTY CLASS LIST IS RED, not GREEN. "Nothing was measured" must never fold to a pass — that is the
# same vacuous-green this probe's whole design is arranged against, and it is the one a naive
# all-of-empty-set fold would produce.
roll_up(){
  local control="${1:-}" host="${2:-}" v n=0
  shift 2 || true
  for v in "$@"; do
    n=$((n+1))
    [ "$v" = ZERO ] || { printf 'RED'; return 0; }
  done
  [ "$n" -gt 0 ]           || { printf 'RED'; return 0; }
  [ "$control" = DETECTS ] || { printf 'RED'; return 0; }
  [ "$host" = ZERO ]       || { printf 'RED'; return 0; }
  printf 'GREEN'
}

# verdict_rc <verdict> → the exit contract: 0 GREEN · 1 everything else.
verdict_rc(){ case "${1:-}" in GREEN) return 0;; *) return 1;; esac }

# max_of <n…> → the largest non-negative integer given, or 0. The floor is derived from the WORST idle
# window rather than the mean: a single burst that the mean would average away is exactly the event
# that would otherwise be charged to a build as if it had pulled an asset.
max_of(){
  local n m=0
  for n in "$@"; do
    case "$n" in ''|*[!0-9]*) continue;; esac
    [ "$n" -gt "$m" ] && m="$n"
  done
  printf '%s' "$m"
}

# human <bytes> → a readable size beside every raw figure. The raw byte count stays authoritative and
# is always printed; this is for the person reading the report, never for a comparison.
human(){
  local b="${1:-0}"
  case "$b" in ''|*[!0-9]*) printf '?'; return 0;; esac
  if   [ "$b" -ge 1048576 ]; then printf '%s.%s MiB' "$((b/1048576))" "$(( (b%1048576)*10/1048576 ))"
  elif [ "$b" -ge 1024 ];    then printf '%s.%s KiB' "$((b/1024))"    "$(( (b%1024)*10/1024 ))"
  else printf '%s B' "$b"; fi
}

# ---- observation -----------------------------------------------------------------------------------

# default_iface → the interface carrying the default route. The counter must be the one the build's
# traffic actually crosses; measured in-box, the engine reached over CONTAINER_HOST shares this
# namespace, so its pulls DO register here (a 6 KB `ADD` moved 14,012 bytes on eth0).
default_iface(){
  [ -n "${BW_IFACE:-}" ] && { printf '%s' "$BW_IFACE"; return 0; }
  ip route show default 2>/dev/null \
    | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# BW_RX_PATH is the TEST SEAM: it substitutes a file the suite controls for the kernel counter, so every
# decision downstream (floor → per-class verdict → control → roll-up → KV → rc) can be driven to an
# exact byte figure with no engine and no network. Production leaves it unset and resolves the real
# counter below — and bandwidth-probe.test.sh keeps one end-to-end row on that real path precisely
# because a seam every row overrides would leave the production resolution untested.
IFACE=""; RX_PATH=""
rx_bytes(){ cat "$RX_PATH" 2>/dev/null; }

resolve_counter(){
  if [ -n "${BW_RX_PATH:-}" ]; then
    IFACE="(BW_RX_PATH seam)"; RX_PATH="$BW_RX_PATH"
  else
    IFACE="$(default_iface)"
    [ -n "$IFACE" ] || { warn "no default-route interface — cannot measure bytes"; return 2; }
    RX_PATH="/sys/class/net/$IFACE/statistics/rx_bytes"
  fi
  [ -r "$RX_PATH" ] || { warn "byte counter not readable: $RX_PATH"; return 2; }
  return 0
}

# measure <logfile> <cmd…> → prints "<bytes> <duration-s> <rc>". The counter is read as close to the
# command as possible on both sides. A counter that fails to read yields a non-numeric byte figure,
# which bytes_verdict turns into ERROR rather than a silent zero.
measure(){
  local log="$1"; shift
  local r0 r1 t0 t1 rc
  r0="$(rx_bytes)"; t0="$(date +%s)"
  "$@" >>"$log" 2>&1; rc=$?
  t1="$(date +%s)"; r1="$(rx_bytes)"
  case "$r0$r1" in ''|*[!0-9]*) printf 'unreadable %s %s' "$((t1-t0))" "$rc"; return 0;; esac
  printf '%s %s %s' "$((r1-r0))" "$((t1-t0))" "$rc"
}

# sample_floor → sets FLOOR_WORST from FLOOR_SAMPLES idle windows, and FLOOR_SAMPLES_RAW for the report.
FLOOR_WORST=0; FLOOR_SAMPLES_RAW=""
sample_floor(){
  local i r0 r1 d samples=()
  for (( i=0; i<FLOOR_SAMPLES; i++ )); do
    r0="$(rx_bytes)"; sleep "$FLOOR_WINDOW"; r1="$(rx_bytes)"
    case "$r0$r1" in ''|*[!0-9]*) continue;; esac
    d=$((r1-r0)); [ "$d" -lt 0 ] && d=0      # a counter wrap must not produce a negative floor
    samples+=( "$d" )
  done
  FLOOR_WORST="$(max_of "${samples[@]+"${samples[@]}"}")"
  FLOOR_SAMPLES_RAW="${samples[*]+${samples[*]}}"
}

# ---- teardown: everything THIS file created, on every exit path (Principle 10) ----------------------
#
# ONE ROOT, CREATED IN THE PARENT SHELL — not a list of paths appended to as they are made. Every class
# arm is read through a command substitution (`$(run_arm …)`), which is a SUBSHELL: a `SCRATCH+=(…)`
# inside one mutates a copy and the parent's trap then reaps an empty list. That is not hypothetical —
# the first cut did exactly this and leaked six throwaway trees across two runs. A single root created
# up front is immune, because the parent already knows the path before any subshell exists.
#
# The build LOG is deliberately NOT under this root: a NONZERO class is diagnosed from it, and the
# report names it. It is the one artifact a run leaves, matching bin/immutability-probe.sh's precedent —
# a file, never an image, container or tree.
SCRATCH_ROOT=""
cleanup(){
  local rc=$?
  [ -n "$SCRATCH_ROOT" ] && [ -d "$SCRATCH_ROOT" ] && rm -rf "$SCRATCH_ROOT" 2>/dev/null
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
SCRATCH_ROOT="$(mktemp -d "$TMPD/bw-probe.XXXXXX" 2>/dev/null)" || SCRATCH_ROOT=""

scratch_dir(){
  local d
  [ -n "$SCRATCH_ROOT" ] || return 1
  d="$(mktemp -d "$SCRATCH_ROOT/s.XXXXXX" 2>/dev/null)" || return 1
  printf '%s' "$d"
}

# ---- the class arms --------------------------------------------------------------------------------
# Each arm prints "<arm-state> <bytes1> <dur1> <bytes2> <dur2>". arm-state is PRESENT (measured),
# ABSENT (no fixture — SKIPPED) or FAILED (the fixture itself did not run — ERROR, never ZERO).

# arm_build <class> [cachebust?] — two throwaway builds of probe-fixtures/bandwidth/<class>.
# `-c` bolts on a separate throwaway COPY tree so the fixture in the live tree is never written to, and
# build-throwaway.sh's own EXIT trap discards the candidate image while the persistent caches survive.
arm_build(){
  # Declared separately, NOT as one `local a=… b=$a`: the shell expands every word of a `local` BEFORE
  # the builtin assigns any of them, so a later name referencing an earlier one reads the OUTER (here
  # unset) value and dies under `set -u`. That bug made all three build arms report ERROR.
  local class="$1" bust="${2:-0}" log="$3"
  local dir="$FIXTURES/$class"
  local m1 m2 b1 d1 r1 b2 d2 r2
  [ -f "$dir/Containerfile" ] && [ -x "$BUILDER" ] || { printf 'ABSENT - - - -'; return 0; }

  if [ "$bust" = 1 ]; then
    m1="$(BUILD_ARGS="--build-arg CACHEBUST=bw-$$-1" measure "$log" "$BUILDER" -c "$dir" -n "bw-$class")"
    m2="$(BUILD_ARGS="--build-arg CACHEBUST=bw-$$-2" measure "$log" "$BUILDER" -c "$dir" -n "bw-$class")"
  else
    m1="$(measure "$log" "$BUILDER" -c "$dir" -n "bw-$class")"
    m2="$(measure "$log" "$BUILDER" -c "$dir" -n "bw-$class")"
  fi
  read -r b1 d1 r1 <<<"$m1"; read -r b2 d2 r2 <<<"$m2"
  if [ "${r1:-1}" != 0 ] || [ "${r2:-1}" != 0 ]; then
    printf 'FAILED %s %s %s %s' "$b1" "$d1" "$b2" "$d2"; return 0
  fi
  printf 'PRESENT %s %s %s %s' "$b1" "$d1" "$b2" "$d2"
}

# git_remote → the clone URL for the gitobj arm: the fixture's own `remote` override if present, else
# this repo's `origin`. Self-contained, and the same asset the apparatus genuinely clones.
git_remote(){
  local f="$FIXTURES/gitobj/remote" u=""
  if [ -f "$f" ]; then
    u="$(grep -v '^[[:space:]]*#' "$f" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1)"
    u="${u%%[[:space:]]*}"
  fi
  [ -n "$u" ] || u="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)"
  printf '%s' "$u"
}

# arm_git <log> — two consecutive FRESH shallow clones into throwaway trees. See gitobj/CLASS.md for
# why two fresh clones rather than clone-then-fetch.
arm_git(){
  local log="$1" url d1 d2 m1 m2 b1 t1 r1 b2 t2 r2
  [ -d "$FIXTURES/gitobj" ] || { printf 'ABSENT - - - -'; return 0; }
  url="$(git_remote)"
  [ -n "$url" ] || { printf 'ABSENT - - - -'; return 0; }
  d1="$(scratch_dir)" && d2="$(scratch_dir)" || { printf 'FAILED - - - -'; return 0; }
  m1="$(measure "$log" git clone --quiet --depth 1 "$url" "$d1/clone")"
  m2="$(measure "$log" git clone --quiet --depth 1 "$url" "$d2/clone")"
  read -r b1 t1 r1 <<<"$m1"; read -r b2 t2 r2 <<<"$m2"
  if [ "${r1:-1}" != 0 ] || [ "${r2:-1}" != 0 ]; then
    printf 'FAILED %s %s %s %s' "$b1" "$t1" "$b2" "$t2"; return 0
  fi
  printf 'PRESENT %s %s %s %s' "$b1" "$t1" "$b2" "$t2"
}

run_arm(){
  case "$1" in
    ospkg)   arm_build ospkg   1 "$2";;
    baseimg) arm_build baseimg 0 "$2";;
    gitobj)  arm_git "$2";;
    *)       arm_build "$1" 0 "$2";;
  esac
}

# ---- THE NEGATIVE CONTROL --------------------------------------------------------------------------
# A download that MUST be seen, measured through the SAME path and judged against the SAME floor.
#
# It REDIRECTS a cache to an empty temp dir; it never empties a real one. Two arms in cost order:
#   gitobj  a fresh shallow clone into a fresh empty tree — MiB-scale and cheap. Its "cache redirected
#           to an empty dir" is the clone target itself, and it keeps working once a git object cache
#           exists (the cache would be redirected too, not consulted).
#   ospkg   FD_DNF_CACHE pointed at an empty temp dir plus a unique CACHEBUST, so dnf must re-fetch
#           metadata and the RPM. Correct but expensive (measured cold: 48,168,228 bytes), so it is the
#           fallback for a box with no git arm rather than the default.
# Neither runnable ⇒ BLIND. An unproven control is not a proven control, and BLIND blocks exit 0.
CONTROL_BYTES=""; CONTROL_ARM=""; CONTROL_DUR=1
negative_control(){
  local log="$1" url d m b t r cache
  url="$(git_remote)"
  if [ -n "$url" ] && [ -d "$FIXTURES/gitobj" ] && d="$(scratch_dir)"; then
    CONTROL_ARM="gitobj (fresh clone into an empty tree)"
    m="$(measure "$log" git clone --quiet --depth 1 "$url" "$d/control")"
    read -r b t r <<<"$m"
    if [ "${r:-1}" = 0 ]; then CONTROL_BYTES="$b"; CONTROL_DUR="${t:-1}"; return 0; fi
  fi
  if [ -f "$FIXTURES/ospkg/Containerfile" ] && [ -x "$BUILDER" ] && cache="$(scratch_dir)"; then
    CONTROL_ARM="ospkg (FD_DNF_CACHE redirected to an empty dir)"
    m="$(FD_DNF_CACHE="$cache/dnf" BUILD_ARGS="--build-arg CACHEBUST=bw-control-$$" \
         measure "$log" "$BUILDER" -c "$FIXTURES/ospkg" -n bw-control)"
    read -r b t r <<<"$m"
    if [ "${r:-1}" = 0 ]; then CONTROL_BYTES="$b"; CONTROL_DUR="${t:-1}"; return 0; fi
  fi
  CONTROL_ARM="none runnable"
  return 0
}

# ---- THE DEV HALF ----------------------------------------------------------------------------------
DEV_VERDICT="RED"; DEV_REPORT=""; CONTROL_VERDICT="BLIND"; KV_CLASSES=""
declare -a CLASS_VERDICTS=()
say(){ DEV_REPORT="${DEV_REPORT}${DEV_REPORT:+$'\n'}$1"; }

dev_half(){
  local log c state b1 d1 b2 d2 v cfloor
  local worst_class_floor=0        # the strictest bar any class was judged at — the control must clear it

  resolve_counter || return 2
  [ -d "$FIXTURES" ] || { warn "fixtures directory missing: $FIXTURES"; return 2; }

  log="$(mktemp "$TMPD/bw-probe-build.XXXXXX")" || { warn "mktemp failed"; return 2; }

  sample_floor
  say "$(printf '  noise floor  : worst %s of %s idle window(s) of %ss [%s] · slack %s%% · min %s' \
          "$(human "$FLOOR_WORST")" "$FLOOR_SAMPLES" "$FLOOR_WINDOW" "${FLOOR_SAMPLES_RAW:-none}" \
          "$FLOOR_SLACK_PCT" "$(human "$FLOOR_MIN")")"

  for c in $CLASSES; do
    read -r state b1 d1 b2 d2 <<<"$(run_arm "$c" "$log")"
    cfloor="$(floor_for "$FLOOR_WORST" "$FLOOR_WINDOW" "$d2" "$FLOOR_SLACK_PCT" "$FLOOR_MIN")"
    v="$(class_verdict "$state" "$b2" "$cfloor")"
    CLASS_VERDICTS+=( "$v" )
    if [ "$v" = SKIPPED ]; then
      say "$(printf '  %-8s     : SKIPPED (no %s asset in the fixture) — blocks exit 0' "$c" "$c")"
      KV_CLASSES="${KV_CLASSES}CLASS_$(printf '%s' "$c" | tr 'a-z' 'A-Z'): SKIPPED - -"$'\n'
    else
      worst_class_floor="$(max_of "$worst_class_floor" "$cfloor")"
      say "$(printf '  %-8s     : build1 %s · build2 %s (floor %s, %ss) → %s' \
              "$c" "$(human "$b1")" "$(human "$b2")" "$(human "$cfloor")" "${d2:-?}" "$v")"
      KV_CLASSES="${KV_CLASSES}CLASS_$(printf '%s' "$c" | tr 'a-z' 'A-Z'): $v ${b1:--} ${b2:--}"$'\n'
    fi
  done

  negative_control "$log"
  cfloor="$(control_floor \
            "$(floor_for "$FLOOR_WORST" "$FLOOR_WINDOW" "$CONTROL_DUR" "$FLOOR_SLACK_PCT" "$FLOOR_MIN")" \
            "$worst_class_floor")"
  CONTROL_VERDICT="$(control_verdict "$CONTROL_BYTES" "$cfloor")"
  say "$(printf '  control      : %s pulled %s vs floor %s (the strictest bar any class was judged at) → %s' \
          "$CONTROL_ARM" "$(human "${CONTROL_BYTES:-0}")" "$(human "$cfloor")" "$CONTROL_VERDICT")"
  [ "$CONTROL_VERDICT" = BLIND ] && \
    say "                 (BLIND = this run could not prove it can see a real download; its zeros mean nothing)"
  say "$(printf '  build log    : %s' "$log")"
  return 0
}

# ---- THE HOST HALF (over the existing ticket bus) ---------------------------------------------------
HOST_VERDICT="UNAVAILABLE"; HOST_DETAIL=""
host_half(){
  local existing out rc
  if [ "$HOST_MODE" = skip ]; then
    HOST_DETAIL="not measured (BW_HOST=skip) — still blocks exit 0"; return 0
  fi
  [ -x "$HOST_TICKET" ] || { HOST_DETAIL="no ticket bus at $HOST_TICKET"; return 0; }

  # Reuse this session's already-open ticket for the verb rather than filing one per run: an acceptance
  # command may be run often, and a fresh issue each time would spam the control repo.
  existing="$("$HOST_TICKET" --mine 2>/dev/null | awk -F'\t' -v v="$HOST_VERB" 'index($2,v){print $1; exit}')"
  if [ -n "$existing" ]; then
    out="$("$HOST_TICKET" --outcome "$existing" 2>&1)"; rc=$?
    HOST_DETAIL="existing ticket #$existing → ${out:-no response yet} (rc $rc)"
  else
    out="$(HOST_TICKET_TIMEOUT="$HOST_TIMEOUT" "$HOST_TICKET" --wait "$HOST_VERB" 2>&1)"; rc=$?
    HOST_DETAIL="filed a $HOST_VERB ticket → rc $rc"
  fi
  HOST_VERDICT="$(host_verdict "$rc" "$out")"
  [ "$HOST_VERDICT" = UNAVAILABLE ] && \
    HOST_DETAIL="$HOST_DETAIL — host half unavailable (the host \`$HOST_VERB\` verb is the sibling fedora-bootstrap feature)"
  return 0
}

# ---- REPORT ----------------------------------------------------------------------------------------
report(){
  local mode="$1" overall
  case "$mode" in
    dev)  overall="$(roll_up "$CONTROL_VERDICT" ZERO "${CLASS_VERDICTS[@]+"${CLASS_VERDICTS[@]}"}")"
          printf 'bandwidth-probe: %s dev=%s\n' "$overall" "$overall";;
    host) overall="$(roll_up DETECTS "$HOST_VERDICT" ZERO)"
          printf 'bandwidth-probe: %s host=%s\n' "$overall" "$HOST_VERDICT";;
    *)    DEV_VERDICT="$(roll_up "$CONTROL_VERDICT" ZERO "${CLASS_VERDICTS[@]+"${CLASS_VERDICTS[@]}"}")"
          overall="$(roll_up "$CONTROL_VERDICT" "$HOST_VERDICT" "${CLASS_VERDICTS[@]+"${CLASS_VERDICTS[@]}"}")"
          printf 'bandwidth-probe: %s dev=%s host=%s\n' "$overall" "$DEV_VERDICT" "$HOST_VERDICT";;
  esac

  if [ "$mode" != host ]; then
    [ -n "$DEV_REPORT" ] && printf '%s\n' "$DEV_REPORT"
  fi
  [ "$mode" != dev ] && printf '  host         : %s — %s\n' "$HOST_VERDICT" "${HOST_DETAIL:-no detail}"

  # ---- the machine-readable KV block (#322) ----
  printf '\n'
  [ "$mode" != host ] && printf '%s' "$KV_CLASSES"
  [ "$mode" != host ] && printf 'FLOOR: %s %s %s %s\n' "$FLOOR_WORST" "$FLOOR_WINDOW" "$FLOOR_SLACK_PCT" "$FLOOR_MIN"
  [ "$mode" != host ] && printf 'CONTROL: %s\n' "$CONTROL_VERDICT"
  [ "$mode" != dev ]  && printf 'HOST: %s\n' "$HOST_VERDICT"
  printf 'VERDICT: %s\n' "$overall"
  verdict_rc "$overall"
}

# ---- DISPATCH (only when executed directly; sourcing exposes the pure helpers) ----------------------
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then return 0 2>/dev/null || true; fi

selftest(){
  local p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }

  echo "== floor_for (integer scaling; an unusable input never yields a floor of 0) =="
  # worst 3000 B per 3 s window = 1000 B/s; over 10 s at 300% slack = 30000 B, above the 1000 B min.
  ck "scales with duration + slack" "$(floor_for 3000 3 10 300 1000)" "30000"
  ck "raised to the minimum"        "$(floor_for 3000 3 1 100 50000)" "50000"
  ck "sub-second charged one second" "$(floor_for 3000 3 0 300 0)"    "3000"
  ck "non-numeric worst → min"      "$(floor_for x 3 10 300 4096)"    "4096"
  ck "zero window → min"            "$(floor_for 3000 0 10 300 4096)" "4096"
  ck "silent box → min"             "$(floor_for 0 3 10 300 4096)"    "4096"

  echo "== bytes_verdict (at-or-under the floor is ZERO; unreadable is never ZERO) =="
  ck "under floor → ZERO"    "$(bytes_verdict 500 1000)"  "ZERO"
  ck "exactly floor → ZERO"  "$(bytes_verdict 1000 1000)" "ZERO"
  ck "over floor → NONZERO"  "$(bytes_verdict 1001 1000)" "NONZERO"
  ck "unreadable → ERROR"    "$(bytes_verdict unreadable 1000)" "ERROR"
  ck "empty → ERROR"         "$(bytes_verdict '' 1000)"   "ERROR"

  echo "== class_verdict (a class with nothing to measure is SKIPPED, never a pass) =="
  ck "absent fixture → SKIPPED" "$(class_verdict ABSENT - -)"          "SKIPPED"
  ck "failed build → ERROR"     "$(class_verdict FAILED 0 1000)"       "ERROR"
  ck "present + quiet → ZERO"   "$(class_verdict PRESENT 10 1000)"     "ZERO"
  ck "present + pulled → NONZERO" "$(class_verdict PRESENT 90000 1000)" "NONZERO"

  echo "== control_verdict (an over-large floor makes the control BLIND — the self-invalidation) =="
  ck "clears the floor → DETECTS" "$(control_verdict 2000000 131072)" "DETECTS"
  ck "floor swallows it → BLIND"  "$(control_verdict 100000 131072)"  "BLIND"
  ck "unrun → BLIND"              "$(control_verdict '' 131072)"      "BLIND"

  echo "== control_floor (the control is judged at the STRICTEST bar any class faced, not its own) =="
  # The measured case: a 6 s class judged at 684.6 KiB while the sub-second control's own floor is
  # 128 KiB. Taking the control's own floor would let a ~500 KiB re-download hide inside that class.
  ck "a slower class raises the bar" "$(control_floor 131072 701030)" "701030"
  ck "own floor wins when it is worse" "$(control_floor 701030 131072)" "701030"
  ck "no classes measured → own floor" "$(control_floor 131072 0)" "131072"
  # And the composition that matters: at the class's bar, a control that only cleared its OWN floor is
  # correctly BLIND — the hole this closes, stated as an executable row rather than a comment.
  ck "a 500 KiB control under a 684 KiB class bar → BLIND" \
     "$(control_verdict 512000 "$(control_floor 131072 701030)")" "BLIND"

  echo "== host_verdict (FAILED is UNAVAILABLE, not a measurement nobody took) =="
  ck "DONE → ZERO"               "$(host_verdict 0)"  "ZERO"
  ck "FAILED → UNAVAILABLE"      "$(host_verdict 1)"  "UNAVAILABLE"
  ck "timeout → UNAVAILABLE"     "$(host_verdict 2)"  "UNAVAILABLE"
  ck "a host reporting non-zero" "$(host_verdict 1 'VERDICT: RED')" "NONZERO"

  echo "== roll_up (both boxes + a detecting control; the empty set is RED, never GREEN) =="
  ck "all zero + detects + host zero → GREEN" "$(roll_up DETECTS ZERO ZERO ZERO ZERO)" "GREEN"
  ck "one NONZERO class → RED"                "$(roll_up DETECTS ZERO ZERO NONZERO)"   "RED"
  ck "one SKIPPED class → RED"                "$(roll_up DETECTS ZERO ZERO SKIPPED)"   "RED"
  ck "one ERROR class → RED"                  "$(roll_up DETECTS ZERO ZERO ERROR)"     "RED"
  ck "a BLIND control → RED"                  "$(roll_up BLIND ZERO ZERO ZERO)"        "RED"
  ck "an UNAVAILABLE host → RED"              "$(roll_up DETECTS UNAVAILABLE ZERO)"    "RED"
  ck "a NONZERO host → RED"                   "$(roll_up DETECTS NONZERO ZERO)"        "RED"
  ck "no classes at all → RED (vacuous)"      "$(roll_up DETECTS ZERO)"                "RED"

  echo "== verdict_rc (the exit contract) =="
  verdict_rc GREEN; ck "GREEN → rc 0" "$?" "0"
  verdict_rc RED;   ck "RED → rc 1"   "$?" "1"

  echo "== max_of (the floor takes the WORST window, so a burst is never averaged away) =="
  ck "picks the largest"      "$(max_of 10 5000 20)" "5000"
  ck "ignores non-numerics"   "$(max_of 10 x 20)"    "20"
  ck "empty → 0"              "$(max_of)"            "0"

  echo; printf 'bandwidth-probe selftest: %s passed, %s failed\n' "$p" "$f"
  [ "$f" -eq 0 ]
}

case "${1:-all}" in
  --selftest) selftest; exit;;
  dev)  dev_half || exit 2; report dev;;
  host) host_half; report host;;
  all)  dev_half || exit 2; host_half; report all;;
  -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//'; exit 0;;
  *) echo "usage: bandwidth-probe.sh [all | dev | host | --selftest]" >&2; exit 2;;
esac
