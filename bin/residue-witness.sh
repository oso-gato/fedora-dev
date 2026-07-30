#!/usr/bin/env bash
# residue-witness.sh — an INDEPENDENT, READ-ONLY witness for build residue.
# (fedora-dev#312 — feat-01 of objective #310 "prove both boxes stay immutable, and keep proving it".)
#
# WHY THIS IS ITS OWN COMPONENT. The objective rules out one thing explicitly: *"asserting immutability
# from the code that implements it — a teardown trap cannot be its own witness, and the two shipped
# objectives that closed on unmeasured evidence are why."* Every residue verdict in that objective rests
# on ONE component — an observer that enumerates live system state from OUTSIDE the teardown machinery
# and is itself PROVEN able to see residue. A probe whose witness is blind always exits 0, which is
# exactly the unmeasured-evidence failure the objective names. So this file ships with its own
# detection proof (`--negative-control`) and nothing else in the objective may be believed before it.
#
# INDEPENDENCE — STRUCTURAL, NOT ASSERTED. This file sources, calls and imports NOTHING from the
# teardown/sweeper machinery it is a witness over (the throwaway build helper and its orphan sweeper /
# dnf-cache GC, the validation harness). It has no siblings at all: it observes the SYSTEM — podman's
# own object lists, procfs, the filesystem — never the implementation's bookkeeping. Those components
# are referred to DESCRIPTIVELY here and nowhere by name, and the sweeping/reaping verbs are likewise
# never spelled — so the issue's mechanical independence scan comes back EMPTY, in code AND in comments,
# with no comment-stripping needed to read its result. `residue-witness.test.sh` (row A2) runs that
# scan verbatim and asserts it is empty; rows A3/A4 scan the CODE for imports and removal verbs.
#
# READ-ONLY — A WITNESS THAT CLEANS UP LAUNDERS THE EVIDENCE. No enumerator and no diff path contains a
# removal verb. The ONE exception is `negctl_cleanup`, which removes exactly the four artifacts
# `--negative-control` itself injected — each named with this process's own pid — using the narrowest
# verb for each: `podman untag <ref> <ref>` (the two-argument form: the single-argument form removes ALL
# of that image's names, which would destroy a pre-existing tag — verified), `podman container rm` on a
# container this run created, and `rmdir`, which CANNOT recurse, so a mistargeted path can never destroy
# a tree. The test asserts every removal verb in this file lives inside that one function.
#
# THE FOUR RESIDUE CLASSES (exactly the objective's list; each enumerated independently):
#   image      every image that exists now, keyed by image ID + reference — ONE LINE PER TAG, so a
#              re-tag of an already-present image is a new line (that is how the negative control's
#              injection is visible at all). Enumerated across ALL repositories, deliberately NOT
#              narrowed to the disposable namespace the throwaway builder happens to use — a candidate
#              tagged anywhere else is still residue. `podman images` (not `-a`): intermediate build
#              layers ARE the layer cache, a deliberate persistent INPUT (see A4), and listing them
#              would put that input into the residue class wholesale.
#   tree       entries under the throwaway/scratch roots: $HOME/.cache/fd-throwaway.*,
#              $TMPDIR/fd-throwaway.*, $HOME/.cache/fd-worktrees/*, $FD_THROWAWAY_TMPDIR/*
#   container  every container, running or exited (`podman ps -a`), keyed by ID + name
#   mount      mount entries from /proc/self/mountinfo AND from the rootless build namespace, keyed by
#              namespace + mountpoint + source, so a leaked overlay/fuse-overlayfs/bind mount from a
#              killed build is visible
#
# DETERMINISM IS A CONTRACT, NOT A HOPE. Two snapshots of an idle box must be byte-identical, so no
# volatile field enters a line: no container STATUS ("Up 2 days" → "Stopping (starting)"), no image
# size or relative-created text, no mount id/parent-id/options. Existence is the residue fact; state is
# not. Output is `LC_ALL=C sort -u`ed — a snapshot is a SET of lines, so `diff` is exact set difference.
#
# VERBS
#   snapshot [file]        write the sorted snapshot to <file> (default stdout)
#   diff <before> <after>  residue = in <after>, absent from <before>, minus the allowlist.
#                          rc 0 = zero residue · 1 = residue found · 2 = unusable input.
#                          Lines that DISAPPEARED print as `GONE …` and never affect rc — a build's own
#                          start-of-run orphan sweep legitimately removes things.
#   --negative-control     THE DETECTION PROOF: inject one artifact of each class, snapshot, assert the
#                          witness REPORTS each, then remove the injections under an EXIT trap.
#                          rc 0 = all four DETECTED · 1 = a class was NOT detected (the witness is
#                          BLIND — the serious one) · 3 = no blindness but ≥1 class could not be
#                          injected here, disclosed as `SKIP <class> — <reason>`. An unproven class is
#                          never a silent pass (a witness with an unproven class is not a proven
#                          witness), which is why SKIP is non-zero.
#   --selftest             pure-core checks (diff/allowlist/mountinfo parsing) on fixture snapshot
#                          files; no engine, no network, no write outside $TMPDIR.
#
# ENV: HOME · TMPDIR · FD_DNF_CACHE · FD_THROWAWAY_TMPDIR (the same knobs the throwaway builder reads,
#      so the witness looks where the implementation actually puts things — read here, never written).
#
# Covered by residue-witness.test.sh (real engine injections + a mutation per class enumerator).
set -uo pipefail

# ---- observation anchors (resolved once; env-overridable exactly as production reads them) ----------
H="${HOME:-}"
TMPD="${TMPDIR:-/tmp}"
DNF_CACHE="${FD_DNF_CACHE:-$H/.cache/fd-dnf}"
THROWAWAY_DIR="${FD_THROWAWAY_TMPDIR:-$H/.cache/fd-throwaway}"
WORKTREES="$H/.cache/fd-worktrees"
LIVE_SPEC="$H/.local/share/fedora-dev"
GRAPH_STORE="$H/.local/share/containers/storage"
TAB=$'\t'

warn(){ printf 'residue-witness: %s\n' "$*" >&2; }

# ---- PURE CORE (--selftest covers exactly these) ---------------------------------------------------

# A snapshot line is `<class>\t<key>[\t<detail>]`. The key is what a residue report names; the detail is
# context that must be as stable as the key (it is part of the compared line).
snap_class(){ printf '%s' "${1%%"$TAB"*}"; }
snap_key(){ local r="${1#*"$TAB"}"; printf '%s' "${r%%"$TAB"*}"; }

# mount_entry <ns> <mountinfo-fields…> → a `mount` snapshot line, or rc 1 if the line is not parseable.
# /proc/self/mountinfo is: id parent major:minor root mountpoint options [optional-fields…] - fstype
# source super-options. The optional-field COUNT VARIES (shared:1 master:2 propagate_from:3 unbindable),
# so fstype/source can only be found relative to the "-" separator — a fixed field index silently reads
# an option string as the source on any shared mount. The scan starts at index 6 (0-based), past the six
# fixed fields, since no fixed field can be a bare "-" (paths are absolute, ids numeric).
# Volatile fields (ids, options) are deliberately dropped: see DETERMINISM above.
mount_entry(){
  local ns="$1"; shift
  local -a f=( "$@" )
  local i sep=-1
  for (( i=6; i<${#f[@]}; i++ )); do
    if [ "${f[$i]}" = "-" ]; then sep=$i; break; fi
  done
  [ "$sep" -ge 0 ] || return 1
  local mp="${f[4]:-}" fstype="${f[$((sep+1))]:-}" src="${f[$((sep+2))]:-}"
  [ -n "$mp" ] && [ -n "$src" ] || return 1
  printf 'mount\t%s %s %s\t%s\n' "$ns" "$mp" "$src" "$fstype"
}

# allow_rule <line> → prints the rule id + why, rc 0, IFF the line is INTENTIONAL PERSISTENCE.
#
# THE INTENTIONAL-PERSISTENCE ALLOWLIST — applied ONLY in `diff`, never in `snapshot` (a snapshot is
# the observation; laundering it would destroy the record). Anything NOT on this list which appears
# during a cycle and survives it is residue. The list is short, individually justified, and deliberately
# holds NO pattern that swallows a class wholesale (`localhost/*`, `$HOME/.cache/*`) — A4 is the worked
# example: it admits the layer store's OWN mount and still reports a per-container `…/overlay/<id>/merged`
# leak, which is precisely the residue this class exists to catch.
#
# Note what needs NO entry: everything already present is excluded by construction (residue is what is
# NEW in `after`), and the image + container classes have no entry at all — a new image or a new
# container surviving a cycle is never intended.
allow_rule(){
  local line="$1" class key mp
  class="$(snap_class "$line")"; key="$(snap_key "$line")"
  case "$class" in
    tree)
      # A1 — the persistent dnf RPM package cache: BP5's ONE durable input (a bind dir, never a layer),
      # created on demand by the throwaway builder. Kept ACROSS disposal by design.
      case "$key" in "$DNF_CACHE"|"$DNF_CACHE"/*) printf 'A1: persistent dnf package cache (BP5 durable input)'; return 0;; esac
      # A2 — the live spec clone on the home volume: the objective's out-of-scope carve-out ("the dev
      # box's home volume … persists deliberately; the live spec clone lives there").
      case "$key" in "$LIVE_SPEC"|"$LIVE_SPEC"/*) printf 'A2: live spec clone (home volume, out of scope)'; return 0;; esac
      # A1/A2 are DEFENSIVE: neither path sits under a throwaway root today, so the tree enumerator
      # cannot currently emit them. They are declared so a deployment that points FD_THROWAWAY_TMPDIR
      # or FD_DNF_CACHE at a shared root can never have its durable input reported as residue.
      ;;
    mount)
      mp="${key#* }"; mp="${mp%% *}"     # key = "<ns> <mountpoint> <source>"; mountinfo escapes spaces
      # A3 — the home volume itself (and its /run/host twin, the same device seen through the
      # distrobox bind): the objective's explicit out-of-scope persistence.
      case "$mp" in "$H"|"/run/host$H") printf 'A3: home volume mount (out of scope)'; return 0;; esac
      # A4 — the podman graph/layer store's OWN mount, and ONLY that exact mountpoint. The layer cache
      # is a deliberate persistent INPUT (Principle 10), and podman mounts the store lazily, so it can
      # legitimately appear mid-cycle. A per-container `…/overlay/<id>/merged` is NOT covered.
      case "$mp" in "$GRAPH_STORE"/overlay|"/run/host$GRAPH_STORE"/overlay) printf 'A4: podman layer store own mount (persistent input)'; return 0;; esac
      ;;
  esac
  return 1
}

# residue_of <before> <after> → prints GONE/ALLOWED/RESIDUE lines; rc 0 = no residue · 1 = residue.
# Inputs are re-sorted defensively so a hand-written fixture cannot silently mis-compare (comm needs
# sorted input, and an unsorted file yields a WRONG answer rather than an error).
# ALLOWED lines are PRINTED, never dropped silently: an allowlist that hides what it suppressed is a
# laundering machine, and the point of this file is that its evidence can be read.
residue_of(){
  local b="${1:-}" a="${2:-}" line rule rc=0
  if [ ! -r "$b" ] || [ ! -r "$a" ]; then warn "diff: need two readable snapshot files"; return 2; fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf 'GONE %s %s\n' "$(snap_class "$line")" "$(snap_key "$line")"
  done < <(LC_ALL=C comm -23 <(LC_ALL=C sort -u "$b") <(LC_ALL=C sort -u "$a"))
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if rule="$(allow_rule "$line")"; then
      printf 'ALLOWED %s %s [%s]\n' "$(snap_class "$line")" "$(snap_key "$line")" "$rule"
      continue
    fi
    printf 'RESIDUE %s %s\n' "$(snap_class "$line")" "$(snap_key "$line")"
    rc=1
  done < <(LC_ALL=C comm -13 <(LC_ALL=C sort -u "$b") <(LC_ALL=C sort -u "$a"))
  return "$rc"
}

# ---- ENUMERATORS — one per class, each reading the SYSTEM, each independent of the others -----------
# Each writes raw (unsorted) snapshot lines. A class whose source is unreachable emits NOTHING and warns
# on stderr — never a fabricated line, and never a silent claim of emptiness.

enumerate_image(){
  local out
  out="$(podman images --format '{{.ID}} {{.Repository}}:{{.Tag}}' 2>/dev/null)" \
    || { warn "image class: podman images failed — class NOT observed"; return 0; }
  printf '%s\n' "$out" | while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    printf 'image\t%s\n' "$ref"
  done
}

enumerate_tree(){
  local p t
  for p in "$H/.cache/fd-throwaway".* "$TMPD/fd-throwaway".* "$WORKTREES"/* "$THROWAWAY_DIR"/*; do
    # No nullglob: an unmatched glob arrives literally and is filtered by the existence test.
    [ -e "$p" ] || [ -L "$p" ] || continue
    if   [ -L "$p" ]; then t=link
    elif [ -d "$p" ]; then t=dir
    elif [ -f "$p" ]; then t=file
    else t=other; fi
    printf 'tree\t%s\t%s\n' "$p" "$t"
  done
}

enumerate_container(){
  local out
  out="$(podman ps -a --format '{{.ID}} {{.Names}}\t{{.Image}}' 2>/dev/null)" \
    || { warn "container class: podman ps failed — class NOT observed"; return 0; }
  printf '%s\n' "$out" | while IFS= read -r row; do
    [ -n "$row" ] || continue
    printf 'container\t%s\n' "$row"
  done
}

# userns_mountinfo [pre] → /proc/self/mountinfo AS SEEN INSIDE the rootless build namespace, with an
# optional shell snippet run in that same namespace first.
#
# WHY A PRE-HOOK EXISTS, AND WHY IT IS A FUNCTION ARGUMENT AND NOT AN ENV SEAM: a rootless bind mount
# exists ONLY inside the namespace that made it (it dies with that namespace — which is also why the
# negative control's mount injection cannot leak). So the ONLY way to prove this enumerator can see a
# leaked mount is to inject one inside the very namespace it reads. `--negative-control` passes the
# snippet as an argument from inside this file; nothing external can set it.
#
# `set -e` in front is load-bearing: if the injection FAILS, the read must produce NOTHING, so the
# caller can tell "could not inject here" (→ SKIP) apart from "injected and the witness missed it"
# (→ BLIND). Two mechanisms are tried in order: `podman unshare` (correct wherever the engine is local
# — e.g. the host) then util-linux `unshare --user --map-root-user --mount` (the in-box path: with
# CONTAINER_HOST set, podman is a REMOTE client and refuses `unshare` outright). Output is required to
# be non-empty as well as rc 0, so a mechanism that half-succeeds cannot double up with the fallback.
userns_mountinfo(){
  local pre="${1:-}" script out
  script="set -e; ${pre:+$pre; }cat /proc/self/mountinfo"
  if out="$(podman unshare sh -c "$script" 2>/dev/null)" && [ -n "$out" ]; then
    printf '%s\n' "$out"; return 0
  fi
  if out="$(unshare --user --map-root-user --mount sh -c "$script" 2>/dev/null)" && [ -n "$out" ]; then
    printf '%s\n' "$out"; return 0
  fi
  return 1
}

enumerate_mount(){
  local pre="${1:-}" out
  local -a fields
  while read -r -a fields; do
    [ "${#fields[@]}" -gt 0 ] || continue
    mount_entry self "${fields[@]}"
  done < /proc/self/mountinfo
  if out="$(userns_mountinfo "$pre")"; then
    while read -r -a fields; do
      [ "${#fields[@]}" -gt 0 ] || continue
      mount_entry userns "${fields[@]}"
    done <<< "$out"
  else
    warn "mount class: no rootless build namespace reachable — userns half NOT observed"
  fi
}

# ---- SNAPSHOT --------------------------------------------------------------------------------------

snapshot_lines(){
  local pre="${1:-}"
  enumerate_image
  enumerate_tree
  enumerate_container
  enumerate_mount "$pre"
}

# snapshot <file|-> [pre] → the sorted, unique snapshot. LC_ALL=C so the byte order is the same in any
# locale (a snapshot compared across environments must not depend on collation).
snapshot(){
  local out="${1:--}" pre="${2:-}"
  if [ "$out" = "-" ]; then
    snapshot_lines "$pre" | LC_ALL=C sort -u
  else
    snapshot_lines "$pre" | LC_ALL=C sort -u > "$out" || { warn "cannot write snapshot: $out"; return 2; }
  fi
}

# ---- NEGATIVE CONTROL — the detection proof --------------------------------------------------------
# Injects one artifact of each class, snapshots, and asserts the witness REPORTS it. Without this, a
# blind witness is indistinguishable from a clean box: both print nothing and exit 0.

NC_TAGREF=""; NC_CNAME=""; NC_TREEDIR=""; NC_MNTROOT=""; NC_A=""; NC_B=""; NC_BEFORE=""; NC_AFTER=""

# THE ONLY REMOVAL PATH IN THIS FILE. It touches exactly the artifacts this process created, each
# named with this process's pid, and it cannot recurse: `rmdir` fails on a non-empty directory rather
# than destroying it, and `podman untag` is given the two-argument form so it removes OUR reference and
# not every name the image has. Fires on success, failure and signals.
negctl_cleanup(){
  local rc=$?
  [ -n "$NC_TAGREF" ]  && podman untag "$NC_TAGREF" "$NC_TAGREF" >/dev/null 2>&1
  [ -n "$NC_CNAME" ]   && podman container rm "$NC_CNAME" >/dev/null 2>&1
  [ -n "$NC_TREEDIR" ] && rmdir "$NC_TREEDIR" 2>/dev/null
  [ -n "$NC_A" ]       && rmdir "$NC_A" 2>/dev/null
  [ -n "$NC_B" ]       && rmdir "$NC_B" 2>/dev/null
  [ -n "$NC_MNTROOT" ] && rmdir "$NC_MNTROOT" 2>/dev/null
  [ -n "$NC_BEFORE" ]  && rm -f "$NC_BEFORE"
  [ -n "$NC_AFTER" ]   && rm -f "$NC_AFTER"
  exit "$rc"
}

negative_control(){
  local img="" pre="" blind=0 skipped=0 new
  trap negctl_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  NC_BEFORE="$(mktemp "$TMPD/residue-negctl-before.XXXXXX")" || { warn "mktemp failed"; return 2; }
  NC_AFTER="$(mktemp "$TMPD/residue-negctl-after.XXXXXX")"   || { warn "mktemp failed"; return 2; }

  snapshot "$NC_BEFORE" || return 2

  # -- inject: image (a new REFERENCE on a tiny already-present image — no pull, no bytes, and the
  #    untag restores the image's names exactly). Also supplies the container injection's image.
  img="$(podman images --format '{{.ID}}' 2>/dev/null | LC_ALL=C sort -u | head -1)"
  if [ -n "$img" ]; then
    NC_TAGREF="localhost/disposable/negctl:witness-probe-$$"   # pid-scoped: never another run's object
    podman tag "$img" "$NC_TAGREF" >/dev/null 2>&1 || { NC_TAGREF=""; }
  fi

  # -- inject: tree (an EMPTY dir under a throwaway root, so rmdir suffices to reverse it)
  NC_TREEDIR="$H/.cache/fd-throwaway.negctl-$$"
  mkdir -p "$NC_TREEDIR" 2>/dev/null || NC_TREEDIR=""

  # -- inject: container (created, NEVER started)
  if [ -n "$img" ]; then
    NC_CNAME="negctl-witness-$$"
    podman create --name "$NC_CNAME" "$img" true >/dev/null 2>&1 || NC_CNAME=""
  fi

  # -- inject: mount (a bind INSIDE the rootless namespace the enumerator reads — see userns_mountinfo).
  #    Deliberately NOT under a throwaway root, so it cannot also register as a `tree` line and blur
  #    which class detected what.
  NC_MNTROOT="$(mktemp -d "$TMPD/residue-negctl-mnt.XXXXXX" 2>/dev/null)" || NC_MNTROOT=""
  if [ -n "$NC_MNTROOT" ] && mkdir "$NC_MNTROOT/src" "$NC_MNTROOT/dst" 2>/dev/null; then
    NC_A="$NC_MNTROOT/src"; NC_B="$NC_MNTROOT/dst"
    pre="mount --bind '$NC_A' '$NC_B'"
  fi

  snapshot "$NC_AFTER" "$pre" || return 2
  new="$(LC_ALL=C comm -13 <(LC_ALL=C sort -u "$NC_BEFORE") <(LC_ALL=C sort -u "$NC_AFTER"))"

  # -- assert each class. DETECTED = the witness reported OUR injection. NOT DETECTED = the witness is
  #    BLIND to that class (rc 1). SKIP = it could not be injected here, disclosed (rc 3) — never a
  #    silent pass, because a witness with an unproven class is not a proven witness.
  local report
  report(){ printf '%s\n' "$1"; }

  if [ -z "$img" ]; then
    report "SKIP image — no local image to re-tag (needs one already-present image; nothing is pulled)"
    skipped=1
  elif [ -z "$NC_TAGREF" ]; then
    report "SKIP image — podman tag failed (no reachable engine?)"
    skipped=1
  elif printf '%s\n' "$new" | grep -qF "${TAB}${img} ${NC_TAGREF}"; then
    report "DETECTED image"
  else
    report "NOT DETECTED image — the witness did not report $NC_TAGREF"
    blind=1
  fi

  if [ -z "$NC_TREEDIR" ]; then
    report "SKIP tree — could not create a throwaway dir under $H/.cache"
    skipped=1
  elif printf '%s\n' "$new" | grep -qF "tree${TAB}${NC_TREEDIR}${TAB}"; then
    report "DETECTED tree"
  else
    report "NOT DETECTED tree — the witness did not report $NC_TREEDIR"
    blind=1
  fi

  if [ -z "$NC_CNAME" ]; then
    report "SKIP container — podman create failed${img:+ from image $img} (engine unreachable, or this engine refuses an image declaring no startup process)"
    skipped=1
  elif printf '%s\n' "$new" | grep -qF " ${NC_CNAME}${TAB}"; then
    report "DETECTED container"
  else
    report "NOT DETECTED container — the witness did not report $NC_CNAME"
    blind=1
  fi

  # The mount discrimination: with `set -e` inside the namespace, a failed injection yields NO userns
  # lines at all — so zero userns lines means "could not inject / no namespace" (SKIP), while userns
  # lines present WITHOUT ours means the enumerator genuinely missed a live mount (BLIND).
  if [ -z "$pre" ]; then
    report "SKIP mount — could not stage a bind source/target under $TMPD"
    skipped=1
  elif ! grep -q "^mount${TAB}userns " "$NC_AFTER"; then
    report "SKIP mount — no rootless build namespace could bind-mount here (podman unshare + unshare both unusable)"
    skipped=1
  elif printf '%s\n' "$new" | grep -qF "mount${TAB}userns ${NC_B} "; then
    report "DETECTED mount"
  else
    report "NOT DETECTED mount — the witness did not report the bind at $NC_B"
    blind=1
  fi

  if [ "$blind" = 1 ]; then
    printf 'negative-control: BLIND — at least one class was injected and NOT seen\n'; return 1
  fi
  if [ "$skipped" = 1 ]; then
    printf 'negative-control: UNPROVEN — every injected class was detected, but a class could not be injected here (see SKIP above)\n'; return 3
  fi
  printf 'negative-control: PROVEN — all four classes injected and detected\n'; return 0
}

# ---- SELFTEST — the pure core, on fixture snapshot files -------------------------------------------

selftest(){
  local pass=0 fail=0 d out rc
  ck(){ if [ "$2" = "$3" ]; then printf '  PASS: %s\n' "$1"; pass=$((pass+1))
        else printf '  FAIL: %s (got=%s want=%s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

  d="$(mktemp -d "$TMPD/residue-selftest.XXXXXX")" || { echo "mktemp failed"; return 2; }

  # -- mountinfo parsing: the separator scan is the whole point (optional fields shift fstype/source)
  # shellcheck disable=SC2086
  set -- 36 35 98:0 / /mnt rw,noatime - ext3 /dev/root rw
  ck "mount_entry plain line" "$(mount_entry self "$@")" "$(printf 'mount\tself /mnt /dev/root\text3')"
  set -- 1340 625 0:59 /a /b rw,relatime shared:1 master:2 - overlay overlay rw,lowerdir=x
  ck "mount_entry with optional fields" "$(mount_entry userns "$@")" "$(printf 'mount\tuserns /b overlay\toverlay')"
  set -- 36 35 98:0 / /mnt rw,noatime ext3 /dev/root
  mount_entry self "$@" >/dev/null 2>&1; ck "mount_entry rejects a line with no separator" "$?" "1"

  # -- line accessors
  ck "snap_class" "$(snap_class "$(printf 'tree\t/x\tdir')")" "tree"
  ck "snap_key"   "$(snap_key   "$(printf 'tree\t/x\tdir')")" "/x"
  ck "snap_key without detail" "$(snap_key "$(printf 'image\tabc localhost/x:1')")" "abc localhost/x:1"

  # -- diff: a new line is residue; an identical pair is silent; a vanished line never affects rc
  printf 'image\taaa localhost/keep:1\n' > "$d/before"
  printf 'image\taaa localhost/keep:1\nimage\tbbb localhost/disposable/x:val-1\n' > "$d/after"
  out="$(residue_of "$d/before" "$d/after")"; rc=$?
  ck "diff rc on residue" "$rc" "1"
  ck "diff names the residue" "$out" "RESIDUE image bbb localhost/disposable/x:val-1"
  out="$(residue_of "$d/before" "$d/before")"; rc=$?
  ck "diff rc on a clean pair" "$rc" "0"
  ck "diff is silent on a clean pair" "$out" ""
  out="$(residue_of "$d/after" "$d/before")"; rc=$?
  ck "a vanished line does not affect rc" "$rc" "0"
  ck "a vanished line is reported as GONE" "$out" "GONE image bbb localhost/disposable/x:val-1"

  # -- unsorted input must still compare correctly (comm on unsorted input answers WRONGLY, silently)
  printf 'image\tzzz localhost/z:1\nimage\taaa localhost/keep:1\n' > "$d/unsorted"
  out="$(residue_of "$d/before" "$d/unsorted")"; rc=$?
  ck "unsorted fixture still diffs correctly" "$rc|$out" "1|RESIDUE image zzz localhost/z:1"

  # -- allowlist: applied in diff only, and it must not swallow a class wholesale
  local save_dnf="$DNF_CACHE" save_spec="$LIVE_SPEC" save_store="$GRAPH_STORE" save_h="$H"
  DNF_CACHE="/fixture/home/.cache/fd-dnf"; LIVE_SPEC="/fixture/home/.local/share/fedora-dev"
  GRAPH_STORE="/fixture/home/.local/share/containers/storage"; H="/fixture/home"
  : > "$d/empty"
  printf 'tree\t%s/x.rpm\tfile\n' "$DNF_CACHE" > "$d/a1"
  out="$(residue_of "$d/empty" "$d/a1")"; rc=$?
  ck "A1 dnf cache is allowlisted" "$rc" "0"
  ck "A1 says what it suppressed" "${out%% [*}" "ALLOWED tree $DNF_CACHE/x.rpm"
  printf 'tree\t%s/CLAUDE.md\tfile\n' "$LIVE_SPEC" > "$d/a2"
  residue_of "$d/empty" "$d/a2" >/dev/null; ck "A2 live spec clone is allowlisted" "$?" "0"
  printf 'mount\tself %s /dev/sda3\tbtrfs\n' "$H" > "$d/a3"
  residue_of "$d/empty" "$d/a3" >/dev/null; ck "A3 home volume mount is allowlisted" "$?" "0"
  printf 'mount\tself /run/host%s /dev/sda3\tbtrfs\n' "$H" > "$d/a3b"
  residue_of "$d/empty" "$d/a3b" >/dev/null; ck "A3 covers the /run/host twin" "$?" "0"
  printf 'mount\tself %s/overlay /dev/sda3\tbtrfs\n' "$GRAPH_STORE" > "$d/a4"
  residue_of "$d/empty" "$d/a4" >/dev/null; ck "A4 layer store own mount is allowlisted" "$?" "0"
  # THE LOAD-BEARING ROW: A4 must NOT swallow a leaked per-container overlay under the same root.
  printf 'mount\tuserns %s/overlay/deadbeef/merged overlay\toverlay\n' "$GRAPH_STORE" > "$d/leak"
  out="$(residue_of "$d/empty" "$d/leak")"; rc=$?
  ck "A4 does NOT swallow a leaked overlay merged mount" \
     "$rc|$out" "1|RESIDUE mount userns $GRAPH_STORE/overlay/deadbeef/merged overlay"
  # a tree under a throwaway root is never allowlisted, whatever its name
  printf 'tree\t%s/.cache/fd-throwaway.abc\tdir\n' "$H" > "$d/tleak"
  residue_of "$d/empty" "$d/tleak" >/dev/null; ck "a throwaway tree is never allowlisted" "$?" "1"
  # no image/container allowlist exists — a new one is always residue
  printf 'image\tccc localhost/anything:1\n' > "$d/ileak"
  residue_of "$d/empty" "$d/ileak" >/dev/null; ck "image class has no allowlist" "$?" "1"
  printf 'container\tddd somename\tlocalhost/x:1\n' > "$d/cleak"
  residue_of "$d/empty" "$d/cleak" >/dev/null; ck "container class has no allowlist" "$?" "1"
  DNF_CACHE="$save_dnf"; LIVE_SPEC="$save_spec"; GRAPH_STORE="$save_store"; H="$save_h"

  # -- diff refuses an unusable input rather than reporting a clean box
  residue_of "$d/before" "$d/does-not-exist" >/dev/null 2>&1
  ck "diff rc on an unreadable snapshot" "$?" "2"

  rm -f "$d"/*; rmdir "$d"
  printf 'selftest: %s passed, %s failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

# ---- dispatch --------------------------------------------------------------------------------------

usage(){
  sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//'
  exit "${1:-0}"
}

case "${1:-}" in
  snapshot)           shift; snapshot "${1:--}";;
  diff)               shift; residue_of "${1:-}" "${2:-}";;
  --negative-control) negative_control;;
  --selftest)         selftest;;
  -h|--help|"")       usage 0;;
  *)                  warn "unknown verb: $1"; usage 2;;
esac
