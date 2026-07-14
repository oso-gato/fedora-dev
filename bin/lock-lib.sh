#!/usr/bin/env bash
# lock-lib.sh — the LIVENESS-LOCK adjudication library (R26), extracted VERBATIM from bin/pr-poller.sh
# so more than one actuator can share the ONE proven identity+adjudication contract instead of each
# re-deriving it (the multi-session foundation: bin/session-id.sh + bin/session-registry.sh source it).
#
# THE CONTRACT (unchanged from #173's LOCK LIVENESS): a held flock proves only that SOME fd is alive on
# this kernel — NOT that the recorded holder still runs. So a holder RECORDS its identity and a
# contender ADJUDICATES the record. Identity = pid + kernel boot-id + /proc starttime, tagged with a
# box GENERATION token (the claudebox `.assembled` marker) so an orphan of a torn-down box is
# distinguishable from a healthy peer. The pure adjudicator `lock_verdict` DEFERs only to a
# POSITIVELY-confirmed live, same-generation holder; every doubt is a TAKEOVER_* (fail toward START).
#
# SOURCEABLE — sourcing defines the functions and does NOTHING else (no I/O, no globals mutated, no
# shell options clobbered); run directly with --selftest to exercise the pure core.
#
# EXPORTS:
#   ll_boot_id                → the kernel boot-id (empty if unreadable). Per-boot; pid+starttime are
#                               per-boot coordinates, so a record from a previous boot names nothing now.
#   ll_proc_start <pid>       → /proc/<pid> starttime (stat field 22); EMPTY when no such process — the
#                               liveness token AND the anti-masquerade token (a recycled pid wears a
#                               different starttime).
#   ll_box_gen                → the box-generation token (inode.mtime of POLLER_BOX_GEN_FILE, or the
#                               POLLER_BOX_GEN env seam). Empty/unreadable ⇒ generation-neutral.
#   lock_verdict <rec> <boot> <nowstart> <gen>
#                             → DEFER | TAKEOVER_NORECORD | TAKEOVER_BOOT | TAKEOVER_DEAD |
#                               TAKEOVER_RECYCLED | TAKEOVER_GENERATION (the pure adjudicator, verbatim).
#
# ENV SEAMS (kept identical to pr-poller.sh so the extraction is faithful):
#   POLLER_BOX_GEN_FILE  the generation marker (default the claudebox `.assembled` marker).
#   POLLER_BOX_GEN       injects the generation token directly (test seam).

# Harden options ONLY when executed directly — sourcing must not clobber the parent's `set -e`
# (the bin/gh-app-provision.sh sourceable-library precedent).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then set -uo pipefail; fi

# the box-GENERATION marker: every claudebox assemble `touch`es the .assembled marker, so its
# inode.mtime names the box incarnation a process belongs to. Missing/unreadable (tests, running
# outside the box) degrades to generation-neutral — never a takeover cause on its own.
: "${POLLER_BOX_GEN_FILE:=$HOME/.local/state/claudebox/.assembled}"

# ll_boot_id — the kernel boot-id (empty if unreadable). [pr-poller.sh boot_id(), verbatim body]
ll_boot_id(){ cat /proc/sys/kernel/random/boot_id 2>/dev/null || :; }

# ll_box_gen — the box-generation token. [pr-poller.sh box_gen(), verbatim body]
ll_box_gen(){
  if [ -n "${POLLER_BOX_GEN:-}" ]; then printf '%s' "$POLLER_BOX_GEN"; return 0; fi   # test seam
  stat -c '%i.%Y' "$POLLER_BOX_GEN_FILE" 2>/dev/null || :
}

# ll_proc_start <pid> — starttime (field 22 of /proc/<pid>/stat) of a live pid; EMPTY when no such
# process. Parsed AFTER the last ')' — comm may contain spaces/parens, so counting whitespace fields
# from the front is wrong. [pr-poller.sh proc_start(), verbatim body]
ll_proc_start(){ # <pid>
  local s
  s="$(cat "/proc/${1:-0}/stat" 2>/dev/null)" || return 0
  s="${s##*) }"; set -- $s
  printf '%s' "${20:-}"
}

# lock_verdict <record-line> <current-boot-id> <holder-starttime-now|""> <current-box-generation>
#   -> DEFER | TAKEOVER_NORECORD | TAKEOVER_BOOT | TAKEOVER_DEAD | TAKEOVER_RECYCLED | TAKEOVER_GENERATION
# THE LOCK-LIVENESS ADJUDICATION (#173), copied VERBATIM from bin/pr-poller.sh. A held flock proves
# only that SOME process/FD is alive somewhere on this kernel — NOT that the recorded holder runs. So
# the record the HOLDER wrote is adjudicated:
#   * DEFER — the ONLY verdict that yields: the recorded process is POSITIVELY confirmed live (same
#     kernel boot, pid exists, starttime matches — pid+starttime+boot uniquely name a process, so a
#     recycled pid cannot masquerade) AND not provably from a previous box generation.
#   * TAKEOVER_NORECORD — no/garbled record; a record that cannot CONFIRM a live holder confirms
#     nothing → the caller starts (fail toward START; a silently dead holder is unrecoverable).
#   * TAKEOVER_BOOT — recorded before a different kernel boot: pid+starttime are per-boot coordinates.
#   * TAKEOVER_DEAD / TAKEOVER_RECYCLED — the recorded process is gone (pid missing, or the pid now
#     wears a DIFFERENT starttime: a stranger reused it).
#   * TAKEOVER_GENERATION — alive, but recorded under a previous BOX generation: an orphan of a
#     torn-down box; the caller may TERM exactly this class (its target provably IS the recorded holder).
# Generation ambiguity (either side unrecorded/unreadable, written as '-') is NEUTRAL — by that point
# liveness is already POSITIVELY confirmed, so deferring is the safe direction. PURE + selftested.
lock_verdict(){
  local rec="$1" boot="$2" nowstart="$3" gen="$4"
  local rpid rboot rstart rgen _rest
  read -r rpid rboot rstart rgen _rest <<<"$rec"
  # '-' is the writer's explicit empty-field placeholder (the record is whitespace-framed, so a truly
  # empty field would silently shift its neighbours into the wrong columns)
  [ "${rboot:-}" = "-" ] && rboot=""; [ "${rstart:-}" = "-" ] && rstart=""; [ "${rgen:-}" = "-" ] && rgen=""
  case "${rpid:-}" in ''|*[!0-9]*) printf 'TAKEOVER_NORECORD'; return;; esac
  case "${rstart:-}" in ''|*[!0-9]*) printf 'TAKEOVER_NORECORD'; return;; esac
  [ -n "${rboot:-}" ] || { printf 'TAKEOVER_NORECORD'; return; }
  [ "$rboot" = "$boot" ] || { printf 'TAKEOVER_BOOT'; return; }
  [ -n "$nowstart" ] || { printf 'TAKEOVER_DEAD'; return; }
  case "$nowstart" in *[!0-9]*) printf 'TAKEOVER_DEAD'; return;; esac   # garbled read confirms nothing
  # /proc starttime FLUTTERS ±1 clock tick between reads of the SAME process (measured on this kernel:
  # the boottime→clock_t conversion rounds differently read-to-read), so an EXACT match would misjudge
  # a genuinely live holder as a recycled pid sporadically. Compare with a ±2-tick tolerance: a truly
  # recycled pid differs by the whole gap between the dead poller's start and the stranger's —
  # seconds-to-months, never ticks.
  local d=$(( nowstart - rstart )); [ "$d" -lt 0 ] && d=$(( -d ))
  [ "$d" -le 2 ] || { printf 'TAKEOVER_RECYCLED'; return; }
  if [ -n "$rgen" ] && [ -n "$gen" ] && [ "$rgen" != "$gen" ]; then printf 'TAKEOVER_GENERATION'; return; fi
  printf 'DEFER'
}

# ---- SELFTEST (direct-execution only) --------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = "--selftest" ]; then
  fail=0
  # lock_verdict truth table — reused VERBATIM from bin/pr-poller.sh's --selftest so the extracted copy
  # is pinned to the original's asserted behaviour.
  lk(){ local got; got="$(lock_verdict "$2" "$3" "$4" "$5")"; [ "$got" = "$6" ] && echo "ok: $1" || { echo "FAIL: $1 — lock_verdict('$2','$3','$4','$5')=$got want $6"; fail=1; }; }
  lk "live same-gen holder → defer"          '123 b1 777 g1' b1 777 g1 DEFER
  lk "dead holder (pid gone) → take"         '123 b1 777 g1' b1 ''  g1 TAKEOVER_DEAD
  lk "recycled pid (starttime moved) → take" '123 b1 777 g1' b1 999 g1 TAKEOVER_RECYCLED
  lk "starttime read-flutter +1 → still live" '123 b1 777 g1' b1 778 g1 DEFER
  lk "starttime read-flutter -2 → still live" '123 b1 777 g1' b1 775 g1 DEFER
  lk "past the flutter tolerance → take"     '123 b1 777 g1' b1 780 g1 TAKEOVER_RECYCLED
  lk "previous kernel boot → take"           '123 b0 777 g1' b1 777 g1 TAKEOVER_BOOT
  lk "previous box generation → take"        '123 b1 777 g0' b1 777 g1 TAKEOVER_GENERATION
  lk "gen unrecorded THERE → liveness rules" '123 b1 777 -'  b1 777 g1 DEFER
  lk "gen unreadable HERE → liveness rules"  '123 b1 777 g1' b1 777 '' DEFER
  lk "empty record (bare-flock era) → take"  ''              b1 ''  g1 TAKEOVER_NORECORD
  lk "garbage record → take"                 'not a record'  b1 ''  g1 TAKEOVER_NORECORD
  lk "placeholder starttime → take"          '123 b1 - g1'   b1 777 g1 TAKEOVER_NORECORD
  lk "dead beats generation in the verdict"  '123 b1 777 g0' b1 ''  g1 TAKEOVER_DEAD

  # ll_proc_start: non-empty for a live self, empty for an impossible pid.
  self_start="$(ll_proc_start "$$")"
  [ -n "$self_start" ] && echo "ok: ll_proc_start(self) is non-empty ($self_start)" \
    || { echo "FAIL: ll_proc_start(self) was empty — a live process must report a starttime"; fail=1; }
  case "$self_start" in *[!0-9]*) echo "FAIL: ll_proc_start(self) is not numeric ($self_start)"; fail=1;; esac
  dead_start="$(ll_proc_start 999999999)"   # a pid past pid_max → /proc entry cannot exist
  [ -z "$dead_start" ] && echo "ok: ll_proc_start(impossible pid) is empty" \
    || { echo "FAIL: ll_proc_start(impossible pid) was non-empty ($dead_start)"; fail=1; }

  # ll_boot_id present on any Linux kernel; ll_box_gen honours the POLLER_BOX_GEN seam verbatim.
  [ -n "$(ll_boot_id)" ] && echo "ok: ll_boot_id is non-empty" \
    || { echo "FAIL: ll_boot_id was empty"; fail=1; }
  [ "$(POLLER_BOX_GEN=genXYZ ll_box_gen)" = genXYZ ] && echo "ok: ll_box_gen honours the POLLER_BOX_GEN seam" \
    || { echo "FAIL: ll_box_gen ignored the POLLER_BOX_GEN seam"; fail=1; }

  [ "$fail" = 0 ] && echo "ALL LOCK-LIB SELFTESTS PASS" || echo "LOCK-LIB SELFTESTS FAILED"
  exit "$fail"
fi
