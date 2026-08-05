#!/usr/bin/env bash
# residue-witness.test.sh — proves `bin/residue-witness.sh` is an INDEPENDENT, READ-ONLY witness that
# is DEMONSTRABLY ABLE TO SEE RESIDUE (fedora-dev#312, objective #310).
#
# THE AXIS UNDER TEST. A witness that cannot see is indistinguishable from a clean box: both print
# nothing and exit 0. So the subject here is not "does the script run" but "does each class's enumerator
# actually detect a real artifact of that class" — which is why every PART B row drives the REAL engine
# (real `podman tag` / `podman create`, a real bind mount inside a real user namespace, a real
# /proc/self/mountinfo) and never a stub. A stub would assert what the stub was told (BP8).
#
# TWO PARTS, AND WHY THE SKIP IS SHAPED THIS WAY:
#   PART A  needs nothing but bash: the pure core through the CLI, plus the MECHANICAL guarantees
#           (independence, read-only, the two-argument `podman untag`, pid-scoped injections).
#   PART B  needs a reachable container engine WITH at least one already-present local image — the
#           negative control re-tags an existing image and creates a container from it, and pulls
#           nothing (Principle 2: a test does not fetch artifacts). Off such a host PART B cannot run.
# When PART B cannot run, PART A still RUNS and a genuine PART A regression still exits 1; only then
# does the file exit 77 (`SKIP: <reason>`, the contract .github/workflows/tests.yml honours) so the
# uncovered half is announced by name instead of passing quietly. The pure core is additionally covered
# in every environment by `bin/residue-witness.sh --selftest`, which that workflow runs separately.
#
# MUTATIONS RUN IN-SUITE (BP8 — five, one per class plus a sharp second mount case). Each neutralizes
# ONE class's enumerator in a COPY and demands the negative control stop reporting that class. Each sed
# is vacuity-guarded: if it did not genuinely change the copy, the row FAILS rather than passing over an
# unmutated file (the seam-audit finding class).
#
#   bash residue-witness.test.sh   -> exit 0 = all rows pass · 77 = PART B unrunnable here (PART A ran)
# No GitHub, no network, no model. Run after touching the witness, a class enumerator, or the allowlist.
set -uo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
SUT="$REPO/bin/residue-witness.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/rwtest.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then printf '  PASS: %s\n' "$1"; pass=$((pass+1))
      else printf '  FAIL: %s\n        got=[%s]\n       want=[%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
ok(){ printf '  PASS: %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL: %s — %s\n' "$1" "$2"; fail=$((fail+1)); }

[ -f "$SUT" ] || { echo "missing subject: $SUT"; exit 2; }

# ============================ PART A — no engine required ============================
echo "== PART A: pure core, independence, read-only (no engine) =="

# --- A1: the script parses, and its own --selftest RUNS and passes. Asserting only the rc would pass
# against a script that has no --selftest at all, so the row also demands the summary line it prints.
bash -n "$SUT" 2>/dev/null; ck "A1 bin/residue-witness.sh parses" "$?" "0"
st_out="$(bash "$SUT" --selftest 2>&1)"; st_rc=$?
ck "A1 --selftest rc" "$st_rc" "0"
st_line="$(printf '%s\n' "$st_out" | grep -c '^selftest: [1-9][0-9]* passed, 0 failed$')"
ck "A1 --selftest actually ran rows" "$st_line" "1"

# --- A2: INDEPENDENCE + READ-ONLY, the issue's own mechanically-checkable form, verbatim.
# It must be empty in CODE **and in comments** — the witness names the machinery it must not touch
# descriptively, so a reader of this command's output never has to decide which hits are "functional".
indep="$(grep -nE 'build-throwaway|sweep_orphans|podman rmi|podman rm |rm -rf|umount' "$SUT")"
ck "A2 independence/read-only scan is empty" "$indep" ""

# --- A3/A4 scan the CODE, not the prose. A2 above is deliberately whole-file (it must be empty
# outright); imports and removal CALLS are properties of code, so comment lines are blanked — with the
# LINE NUMBERING PRESERVED, because A4 then needs to locate hits relative to a function's line range.
CODE="$TMP/code-only.sh"
awk '{ if ($0 ~ /^[[:space:]]*#/) print ""; else print }' "$SUT" > "$CODE"

# --- A3: no import of ANY sibling. The witness must observe the system, never the implementation's
# bookkeeping — so it sources nothing and invokes no other script in bin/.
srcs="$(grep -nE '^[[:space:]]*(source|\.)[[:space:]]+' "$CODE")"
ck "A3 sources nothing" "$srcs" ""
sib="$(grep -nE '(\$HERE|\$REPO|bin)/[a-z-]+\.sh' "$CODE")"
ck "A3 invokes no sibling script" "$sib" ""

# --- A4: every removal verb lives inside the ONE cleanup function. A witness that cleans up launders
# the evidence; the negative control's own injections are the single sanctioned exception, and this row
# is what keeps that exception from spreading into an enumerator.
cl_start="$(grep -n '^negctl_cleanup(){' "$CODE" | cut -d: -f1)"
cl_end="$(awk -v s="${cl_start:-0}" 'NR>s && /^}/ {print NR; exit}' "$CODE")"
if [ -z "$cl_start" ] || [ -z "$cl_end" ]; then
  no "A4 removal verbs are confined to negctl_cleanup" "cannot locate negctl_cleanup's body"
else
  stray="$(grep -nE '(^|[^a-z-])(rmdir|rm -f|podman untag|podman container rm)' "$CODE" \
           | awk -F: -v s="$cl_start" -v e="$cl_end" '$1<s || $1>e')"
  # The selftest reaps its own fixture dir, which is legitimate and lives outside the cleanup function.
  stray="$(printf '%s\n' "$stray" | grep -v 'rm -f "\$d"/\*; rmdir "\$d"' | grep -v '^$')"
  ck "A4 removal verbs are confined to negctl_cleanup (+ the selftest's own fixture reap)" "$stray" ""
fi

# --- A5: `podman untag <ref>` with ONE argument removes ALL of that image's names — so cleaning up a
# probe tag that way would DESTROY a pre-existing tag on the same image (verified against the live
# engine). The two-argument form is the only safe one; pin it mechanically.
untag_two="$(grep -c 'podman untag "\$NC_TAGREF" "\$NC_TAGREF"' "$SUT")"
ck "A5 untag uses the two-argument (this-ref-only) form" "$untag_two" "1"

# --- A6: every injected artifact is pid-scoped, so a concurrent witness run and this one can never
# reach each other's objects (the cleanup is only safe because the names cannot collide).
for pat in 'localhost/disposable/negctl:witness-probe-\$\$' 'fd-throwaway.negctl-\$\$' 'negctl-witness-\$\$'; do
  n="$(grep -cE "$pat" "$SUT")"
  ck "A6 injection name is pid-scoped: ${pat//\\/}" "$([ "$n" -ge 1 ] && echo yes || echo no)" "yes"
done

# --- A7: the diff verb through the CLI (not just in-process): residue found, clean pair, unusable input.
printf 'image\taaa localhost/keep:1\n' > "$TMP/before"
printf 'image\taaa localhost/keep:1\nimage\tbbb localhost/disposable/x:val-9\n' > "$TMP/after"
out="$(bash "$SUT" diff "$TMP/before" "$TMP/after")"; rc=$?
ck "A7 diff rc=1 on residue" "$rc" "1"
ck "A7 diff names the survivor" "$out" "RESIDUE image bbb localhost/disposable/x:val-9"
out="$(bash "$SUT" diff "$TMP/before" "$TMP/before")"; rc=$?
ck "A7 idle diff is rc=0 and silent" "$rc|$out" "0|"
bash "$SUT" diff "$TMP/before" "$TMP/nope" >/dev/null 2>&1
ck "A7 unreadable snapshot is rc=2, never a clean verdict" "$?" "2"

# --- A8: snapshot writes to a file AND to stdout, and the two agree (the default-stdout path is the
# one an operator uses first; a file-only test would never execute it).
bash "$SUT" snapshot "$TMP/snap-file" 2>/dev/null; f_rc=$?
bash "$SUT" snapshot > "$TMP/snap-stdout" 2>/dev/null
if [ "$f_rc" -eq 0 ] && cmp -s "$TMP/snap-file" "$TMP/snap-stdout"; then
  ok "A8 snapshot to file == snapshot to stdout"
else
  # Not a failure by itself off an engine (both halves would be equally empty); only a MISMATCH is.
  if [ -s "$TMP/snap-file" ] || [ -s "$TMP/snap-stdout" ]; then
    no "A8 snapshot to file == snapshot to stdout" "the two paths disagree"
  else
    ok "A8 snapshot to file == snapshot to stdout (both empty — no engine here)"
  fi
fi

if [ "$fail" -ne 0 ]; then
  printf '\n=== PART A: %s passed, %s FAILED ===\n' "$pass" "$fail"
  exit 1
fi

# ============================ capability gate for PART B ============================
# Probe the ENGINE and the one input the negative control needs. `command -v podman` proves nothing
# (the GitHub runner ships podman and has no images), so probe what is actually consumed.
FIRST_IMG="$(podman images --format '{{.ID}}' 2>/dev/null | LC_ALL=C sort -u | head -1)"
if ! podman info >/dev/null 2>&1 || [ -z "$FIRST_IMG" ]; then
  printf '\n=== PART A: %s passed, 0 failed ===\n' "$pass"
  printf 'SKIP: PART B needs a reachable container engine WITH >=1 local image — the negative control re-tags an already-present image and creates a container from it, and pulls nothing. PART A ran and passed.\n'
  exit 77
fi

# ============================ PART B — the real engine ============================
echo
echo "== PART B: the detection proof against the REAL engine =="

# --- B1: DETERMINISM. Two snapshots of the same box must be byte-identical, or every later diff is
# noise. This is what forbids status/size/mount-id fields in a line.
bash "$SUT" snapshot "$TMP/d1" 2>/dev/null
bash "$SUT" snapshot "$TMP/d2" 2>/dev/null
if cmp -s "$TMP/d1" "$TMP/d2"; then ok "B1 two snapshots are byte-identical"
else no "B1 two snapshots are byte-identical" "$(diff "$TMP/d1" "$TMP/d2" | head -4 | tr '\n' ' ')"; fi

# GRAMMAR AND THE ONE UNIVERSAL CLASS — deliberately NOT an inventory of this box.
# This row used to demand the snapshot COVER all four classes. That is a fact about the BOX, not about
# the witness: a class the box holds no object of correctly enumerates nothing. Measured on a CI runner
# (fedora-dev run 30537850260) the snapshot read `image,mount` — no container, no throwaway tree — so
# the row turned the repo's own `tests` gate RED for an environmental reason, while every OTHER PART B
# row on that same runner passed, the whole detection proof and all five mutations included. Skipping
# PART B over it would have been worse: it would drop that real coverage for a reason confined to one
# row, which is the "excuse wider than the reason" .github/workflows/tests.yml exists to forbid.
# THE FOUR-CLASS COVERAGE CLAIM BELONGS TO B2, which INJECTS one artifact per class and asserts each is
# DETECTED — strictly stronger than whatever happens to be lying around here, and true on any host that
# can run PART B at all.
# What is environment-INDEPENDENT, and what these rows therefore keep biting on: a snapshot is never
# empty and always covers `mount`, because the witness reads THIS process's own mountinfo and no Linux
# box lacks mounts — so a silently-dead mount enumerator still fails here; and every label must be one
# of the four, so a stray or garbled class can never pass itself off as residue.
ck "B1 the snapshot is non-empty" "$([ -s "$TMP/d1" ] && printf yes || printf no)" "yes"
ck "B1 it covers the one class every box has (mount)" \
   "$(cut -f1 "$TMP/d1" | LC_ALL=C sort -u | grep -c '^mount$')" "1"
ck "B1 every class label is one of the four" \
   "$(cut -f1 "$TMP/d1" | LC_ALL=C sort -u | grep -cvE '^(container|image|mount|tree)$')" "0"
printf '      | classes this box holds: %s — a class it holds none of is not a defect (B2 injects one of each)\n' \
   "$(cut -f1 "$TMP/d1" | LC_ALL=C sort -u | tr '\n' ',' | sed 's/,$//')"

# --- B2: THE NEGATIVE CONTROL — the row this whole feature exists for.
nc_out="$(bash "$SUT" --negative-control 2>&1)"; nc_rc=$?
printf '%s\n' "$nc_out" | sed 's/^/      | /'
ck "B2 negative control rc" "$nc_rc" "0"
for cls in image tree container mount; do
  n="$(printf '%s\n' "$nc_out" | grep -c "^DETECTED $cls$")"
  ck "B2 DETECTED $cls" "$n" "1"
done

# --- B3: it leaves NONE OF ITS OWN artifacts behind. Strictly attributable: every object it injects
# carries `negctl`, so a residue line mentioning that name is unambiguously a cleanup regression.
bash "$SUT" snapshot "$TMP/around-pre" 2>/dev/null
bash "$SUT" --negative-control >/dev/null 2>&1
bash "$SUT" snapshot "$TMP/around-post" 2>/dev/null
around="$(bash "$SUT" diff "$TMP/around-pre" "$TMP/around-post")"; around_rc=$?
mine="$(printf '%s\n' "$around" | grep '^RESIDUE' | grep negctl)"
ck "B3 no negctl artifact survives the negative control" "$mine" ""
# The acceptance's literal form: the whole diff shows zero residue. NOTE ON FLAKES: another actor on
# this box (the poller, a dev-loop build) legitimately leaving an image/container/tree inside this ~4s
# window is a TRUE observation by the witness, not a defect in the cleanup — so this row prints what it
# found, and the row above is the one that attributes it.
if [ "$around_rc" -eq 0 ]; then
  ok "B3 a snapshot/diff around the negative control shows zero residue"
else
  no "B3 a snapshot/diff around the negative control shows zero residue" \
     "residue seen: $(printf '%s\n' "$around" | grep '^RESIDUE' | head -3 | tr '\n' ' ') (if none mention negctl, another actor on this box wrote during the window)"
fi
# and nothing of ours is left in the engine or the filesystem either
ck "B3 no negctl image tag remains" "$(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -c negctl)" "0"
ck "B3 no negctl container remains" "$(podman ps -a --format '{{.Names}}' 2>/dev/null | grep -c negctl)" "0"
ck "B3 no negctl tree remains" "$(ls -d "$HOME"/.cache/fd-throwaway.negctl-* 2>/dev/null | wc -l)" "0"
ck "B3 no negctl temp files remain" "$(ls -d "${TMPDIR:-/tmp}"/residue-negctl-* 2>/dev/null | wc -l)" "0"

# --- B4-B8: MUTATIONS. Neutralize one class's enumerator per copy; that class must stop being
# reported. `mutate <name> <sed-expr>` fails the row itself if the sed changed nothing (a vacuous
# mutation proves nothing and is exactly the seam-audit finding class).
mutate(){
  local tag="$1" expr="$2" copy="$TMP/mut-$tag.sh"
  sed "$expr" "$SUT" > "$copy" || return 1
  if cmp -s "$SUT" "$copy"; then no "mutation $tag" "VACUOUS — the sed changed nothing"; return 1; fi
  chmod +x "$copy"; printf '%s' "$copy"
}
mut_row(){   # <tag> <class> <sed-expr> <want-blind|want-any-nonzero>
  local tag="$1" cls="$2" expr="$3" mode="$4" copy out rc
  copy="$(mutate "$tag" "$expr")" || return
  out="$(bash "$copy" --negative-control 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    no "mutation $tag: neutralized $cls enumerator" "the negative control still passed (rc=0) — the class is not proven by it"
    return
  fi
  if printf '%s\n' "$out" | grep -q "^DETECTED $cls$"; then
    no "mutation $tag: neutralized $cls enumerator" "it still reported DETECTED $cls"
    return
  fi
  if [ "$mode" = blind ] && ! printf '%s\n' "$out" | grep -q "^NOT DETECTED $cls"; then
    no "mutation $tag: neutralized $cls enumerator" "expected a BLIND report, got: $(printf '%s\n' "$out" | grep "$cls" | head -1)"
    return
  fi
  ok "mutation $tag: neutralizing the $cls enumerator makes the negative control FAIL (rc=$rc)"
}

mut_row image     image     's|^enumerate_image(){|enumerate_image(){ return 0;|'     blind
mut_row tree      tree      's|^enumerate_tree(){|enumerate_tree(){ return 0;|'       blind
mut_row container container 's|^enumerate_container(){|enumerate_container(){ return 0;|' blind
# The mount class gets TWO mutations, because its enumerator can fail in two distinguishable ways and
# the witness deliberately tells them apart:
#   (a) the enumerator produces NOTHING -> indistinguishable from "this host cannot bind-mount in a
#       rootless namespace", so it is reported as SKIP (disclosed, unproven) — still non-zero, never a
#       silent pass. That fail direction is the point of the SKIP contract.
#   (b) the enumerator RUNS but its key is blind to the mountpoint -> a real live mount is missed while
#       userns lines exist, which must be reported as NOT DETECTED (blindness).
mut_row mount-silent mount 's|^enumerate_mount(){|enumerate_mount(){ return 0;|'      any
mut_row mount-blind  mount 's|"$ns" "$mp" "$src" "$fstype"|"$ns" MUTANT "$src" "$fstype"|' blind

printf '\n=== residue-witness.test.sh: %s passed, %s failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
