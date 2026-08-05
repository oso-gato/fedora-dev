#!/usr/bin/env bash
# residue-parity.test.sh — proves CHECK 7 of bin/fleet-guard-parity.sh actually CATCHES residue-witness
# drift between the two boxes (fedora-dev#318, feat-04 of objective #310).
#
# WHY AN END-TO-END SUITE AND NOT JUST THE --selftest: the pure comparison core is covered by
# `bin/fleet-guard-parity.sh --selftest`, and a green pure core is exactly the evidence that has shipped
# wired-shut dead code in this repo before (#278: a router with a passing selftest and ZERO call sites).
# What a selftest is structurally blind to is whether the SCRIPT reaches the comparison at all — whether
# the witness is fetched, at the right per-repo PATH, whether a drift makes the WHOLE CHECK exit non-zero,
# and whether an absent copy skips instead of failing. So every row here drives the REAL script over a
# REAL fixture fleet and asserts its EXIT CODE, the thing CI acts on.
#
# THE FIXTURE FLEET IS REAL WHERE IT COUNTS. `PARITY_RAW` repoints the fetch base at a `file://` tree
# laid out exactly as raw.githubusercontent serves it (`<repo>/<ref>/<path>`), so `fetch()`, the per-repo
# witness_path mapping and the participation logic are the shipped ones — not stubs. The non-residue
# payload (managed-settings / claudebox-init / distrobox.ini / policy) is copied from THIS repo into both
# fixture repos, so CHECKS 1-6 pass and the rc under test is CHECK 7's alone; a row asserting rc 0 would
# otherwise be unfalsifiable, and a row asserting rc 1 could pass for the wrong reason entirely.
#
# MUTATION RUN IN-SUITE (BP8): the class-set comparison is mechanically neutralized in a COPY of the
# script and the dropped-`mount` fixture must then WRONGLY PASS — proving the comparison is what bites,
# not the surrounding plumbing. The sed must genuinely change the copy, else the row reports itself
# vacuous and fails.
#
# `bash residue-parity.test.sh` → exit 0 = all rows pass · 77 = cannot run here (no curl).
# No GitHub, no network, no model, no container engine.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$ROOT/bin/fleet-guard-parity.sh"

command -v curl >/dev/null 2>&1 || {
  echo "SKIP: curl is required — the parity script fetches every payload through it (file:// here)"
  exit 77
}
[ -r "$SCRIPT" ] || { echo "cannot read $SCRIPT"; exit 1; }
[ -r "$ROOT/bin/residue-witness.sh" ] || { echo "cannot read $ROOT/bin/residue-witness.sh"; exit 1; }

pass=0; fails=0
ck(){ if [ "$2" = "$3" ]; then printf '  PASS: %s\n' "$1"; pass=$((pass+1))
      else printf '  FAIL: %s (got=%s want=%s)\n' "$1" "$2" "$3"; fails=$((fails+1)); fi; }
# PRESENCE, not a count: a single drift legitimately yields more than one finding line (a contract change
# is reported as both a MISSING and an ADDED fact), so counting would make correct output fail the row.
has(){ if printf '%s\n' "$OUT" | grep -qF "$1"; then echo 1; else echo 0; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/residue-parity.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT

# ---- fixture fleet ---------------------------------------------------------------------------------
# A two-repo tree in raw.githubusercontent's own layout, with the witness at each repo's REAL path
# (fedora-dev: bin/residue-witness.sh · fedora-bootstrap: residue-witness.sh) so the path mapping is
# exercised rather than assumed.
mkfleet(){
  local f="$1" r
  rm -rf "$f"
  for r in fedora-dev fedora-bootstrap; do
    mkdir -p "$f/$r/main/policy" "$f/$r/main/bin"
    cp "$ROOT/claudebox-init.sh"            "$f/$r/main/claudebox-init.sh"
    cp "$ROOT/policy/managed-settings.json" "$f/$r/main/policy/managed-settings.json"
    cp "$ROOT/policy/CLAUDE.md"             "$f/$r/main/policy/CLAUDE.md"
    cp "$ROOT/distrobox.ini"                "$f/$r/main/distrobox.ini"
  done
  cp "$ROOT/policy/fleet-core.md"   "$f/fedora-dev/main/policy/fleet-core.md"
  cp "$ROOT/bin/residue-witness.sh" "$f/fedora-dev/main/bin/residue-witness.sh"
  cp "$ROOT/bin/residue-witness.sh" "$f/fedora-bootstrap/main/residue-witness.sh"
}
HOSTW(){ printf '%s/fedora-bootstrap/main/residue-witness.sh' "$1"; }

# ---- drift helpers (textual, so a fixture stays a plausible file) -----------------------------------
ins_after(){ local f="$1" m="$2" l="$3" t x; t="$(mktemp)"
  while IFS= read -r x; do printf '%s\n' "$x"; case "$x" in *"$m"*) printf '%s\n' "$l";; esac; done < "$f" > "$t"; mv "$t" "$f"; }
rewrite_line(){ local f="$1" m="$2" l="$3" t x; t="$(mktemp)"
  while IFS= read -r x; do case "$x" in *"$m"*) printf '%s\n' "$l";; *) printf '%s\n' "$x";; esac; done < "$f" > "$t"; mv "$t" "$f"; }
del_line(){ local f="$1" m="$2" t x; t="$(mktemp)"
  while IFS= read -r x; do case "$x" in *"$m"*) ;; *) printf '%s\n' "$x";; esac; done < "$f" > "$t"; mv "$t" "$f"; }
del_fn(){ local f="$1" fn="$2" t; t="$(mktemp)"
  awk -v fn="$fn" 'index($0, fn "()")==1 {d=1} d { if (/^\}/) d=0; next } {print}' "$f" > "$t"; mv "$t" "$f"; }

# run <fixture-dir> [script] → $OUT, $RC. PARITY_SELF empty => every payload comes from the fixture base.
run(){ local f="$1" s="${2:-$SCRIPT}"
  OUT="$(PARITY_RAW="file://$f" PARITY_SELF= PARITY_SELF_DIR="$f/fedora-dev/main" bash "$s" 2>&1)"; RC=$?; }

printf '== residue-witness parity (CHECK 7) ==\n'

# -- ROW 1: IDENTICAL copies => GREEN, with the three report lines the issue's acceptance names.
F="$WORK/identical"; mkfleet "$F"; run "$F"
ck "identical copies: rc 0" "$RC" "0"
ck "  reports the class-set match"     "$(has '✓ residue-witness.sh: 4/4 classes match')" "1"
ck "  reports allowlist parity"        "$(has '✓ allowlist parity (0 exempt, justified)')" "1"
ck "  reports the verdict contract"    "$(has '✓ verdict contract matches')" "1"
ck "  and the run is GREEN overall"    "$(has 'GREEN —')" "1"

# -- ROW 2: the host stops enumerating the `mount` class. THE headline drift: its witness still exits 0
# forever, so nothing but a parity check can see it.
F="$WORK/dropclass"; mkfleet "$F"
del_fn "$(HOSTW "$F")" enumerate_mount
del_line "$(HOSTW "$F")" 'enumerate_mount "$pre"'
run "$F"
ck "a dropped residue class: rc 1" "$RC" "1"
ck "  the message NAMES the class"  "$(has "does NOT enumerate the 'mount' residue class")" "1"
ck "  and the run is RED overall"   "$(has 'RED — guard DRIFT')" "1"

# -- ROW 3: an UNMARKED extra allowlist entry on the host = a lower bar.
F="$WORK/unmarked"; mkfleet "$F"
ins_after "$(HOSTW "$F")" "A1: persistent dnf" \
  "      case \"\$key\" in \"\$H/.cache\"/*) printf 'A5: anything under the cache'; return 0;; esac"
run "$F"
ck "an UNMARKED extra allowlist entry: rc 1" "$RC" "1"
ck "  named as an extra rule + a lower bar" "$(has 'EXTRA allowlist rule A5')" "1"

# -- ROW 4: the SAME entry, declared box-specific with a justification => GREEN, and counted.
F="$WORK/marked"; mkfleet "$F"
ins_after "$(HOSTW "$F")" "A1: persistent dnf" \
  "      # PARITY-EXEMPT(host): the host's own image pull cache lives under this root, the dev box has none
      case \"\$key\" in \"\$H/.cache\"/*) printf 'A5: anything under the cache'; return 0;; esac"
run "$F"
ck "a justified PARITY-EXEMPT(host) entry: rc 0" "$RC" "0"
ck "  and it is reported as an exemption" "$(has '✓ allowlist parity (1 exempt, justified)')" "1"

# -- ROW 5: an exemption with an EMPTY justification is not an exemption.
F="$WORK/nojust"; mkfleet "$F"
ins_after "$(HOSTW "$F")" "A1: persistent dnf" \
  "      # PARITY-EXEMPT(host):
      case \"\$key\" in \"\$H/.cache\"/*) printf 'A5: anything under the cache'; return 0;; esac"
run "$F"
ck "an EMPTY justification: rc 1" "$RC" "1"
ck "  the message says the exemption states no reason" "$(has 'carries NO justification')" "1"

# -- ROW 6: the host changes the rc mapping feat-05 parses.
F="$WORK/rcmap"; mkfleet "$F"
rewrite_line "$(HOSTW "$F")" "negative-control: UNPROVEN" \
  "  printf 'negative-control: UNPROVEN — every injected class was detected\\n'; return 0"
run "$F"
ck "a changed verdict rc mapping: rc 1" "$RC" "1"
ck "  named as a verdict/exit contract drift" "$(has 'verdict/exit contract DRIFT')" "1"

# -- ROW 7: the host copy is ABSENT (the state on main until feat-03 lands). This PR must be landable on
# its own and must START ENFORCING as the copies arrive, so an absent copy is a LOUD skip, not a RED.
F="$WORK/absent"; mkfleet "$F"; rm -f "$(HOSTW "$F")"; run "$F"
ck "the host copy absent: rc 0 (landable before feat-03)" "$RC" "0"
ck "  the skip NAMES who is missing" "$(has '[skip] no residue witness shipped yet by: fedora-bootstrap')" "1"
ck "  and says nothing is asserted yet" "$(has 'nothing is asserted about parity yet')" "1"
ck "  no parity claim is printed"     "$(has '✓ residue-witness.sh:')" "0"

# -- ROW 8: the PRE-MERGE self-overlay, on the side the objective actually worries about. A HOST PR that
# quietly widens its OWN allowlist must fail BEFORE merge, not after — the whole reason
# PARITY_SELF/PARITY_SELF_DIR exists. Both repos are clean at raw@main; only the local checkout (the
# "PR head") carries the drift, so nothing but the overlay can see it.
F="$WORK/selfdrift"; mkfleet "$F"
HEAD_DIR="$WORK/prhead-host"; rm -rf "$HEAD_DIR"; cp -r "$F/fedora-bootstrap/main" "$HEAD_DIR"
ins_after "$HEAD_DIR/residue-witness.sh" "A1: persistent dnf" \
  "      case \"\$key\" in \"\$H\"/*) printf 'A9: the PR head quietly widens the allowlist'; return 0;; esac"
OUT="$(PARITY_RAW="file://$F" PARITY_SELF=fedora-bootstrap PARITY_SELF_DIR="$HEAD_DIR" bash "$SCRIPT" 2>&1)"; RC=$?
ck "a host PR drifting its OWN copy: rc 1 PRE-merge" "$RC" "1"
ck "  and the added rule is named"  "$(has 'EXTRA allowlist rule A9')" "1"

# -- ROW 8b: the LOCKSTEP ESCAPE, and its bound. When the CANON's own PR proposes a NEW standard, the
# follower @main cannot match it yet and the follower's porting PR cannot match a canon that has not
# landed — the mutual deadlock CHECK 1 documents from a real incident (#296 vs bootstrap#307). So this is
# reported as PORTING DEBT, establishing an order, rather than deadlocking both halves forever. It is a
# NAMED pass, never a silent one, and it is BOUNDED: it fires only while the follower matches canon@main.
F="$WORK/canonmoves"; mkfleet "$F"
HEAD_DIR="$WORK/prhead-dev"; rm -rf "$HEAD_DIR"; cp -r "$F/fedora-dev/main" "$HEAD_DIR"
ins_after "$HEAD_DIR/bin/residue-witness.sh" "A1: persistent dnf" \
  "      case \"\$key\" in \"\$H/.newthing\"/*) printf 'A9: a new rule this PR proposes for BOTH boxes'; return 0;; esac"
OUT="$(PARITY_RAW="file://$F" PARITY_SELF=fedora-dev PARITY_SELF_DIR="$HEAD_DIR" bash "$SCRIPT" 2>&1)"; RC=$?
ck "the canon proposing a NEW standard: rc 0 (no deadlock)" "$RC" "0"
ck "  reported as porting debt, by name" "$(has 'proposes a NEW witness standard')" "1"
# The escape must NOT cover a host that is ALREADY drifted: same canon PR, but the host has also dropped
# a class, so it matches neither the PR head NOR canon@main.
del_fn "$(HOSTW "$F")" enumerate_mount
del_line "$(HOSTW "$F")" 'enumerate_mount "$pre"'
OUT="$(PARITY_RAW="file://$F" PARITY_SELF=fedora-dev PARITY_SELF_DIR="$HEAD_DIR" bash "$SCRIPT" 2>&1)"; RC=$?
ck "  the escape does NOT cover an already-drifted host: rc 1" "$RC" "1"
ck "  and that drift is still named" "$(has "does NOT enumerate the 'mount' residue class")" "1"

# -- ROW 9: MUTATION — neutralize the class-set comparison; the dropped-`mount` fixture must WRONGLY
# PASS. Without this, ROW 2 could be passing on some other tooth entirely.
MUT="$WORK/mutant.sh"
sed 's|^wit_classes(){$|wit_classes(){ cat >/dev/null; echo container; echo image; echo mount; echo tree; return 0; }\nwit_classes_neutralized(){|' \
  "$SCRIPT" > "$MUT"
if cmp -s "$SCRIPT" "$MUT"; then
  ck "MUTATION: the sed genuinely changed the script" "vacuous" "changed"
else
  ck "MUTATION: the sed genuinely changed the script" "changed" "changed"
  bash -n "$MUT" && ck "MUTATION: the mutant still parses" "0" "0" || ck "MUTATION: the mutant still parses" "1" "0"
  F="$WORK/mut-dropclass"; mkfleet "$F"
  del_fn "$(HOSTW "$F")" enumerate_mount
  del_line "$(HOSTW "$F")" 'enumerate_mount "$pre"'
  run "$F" "$MUT"
  ck "MUTATION: with the class-set comparison neutralized, the dropped class WRONGLY passes" "$RC" "0"
  # The same fixture, through the real script — asserted here beside the mutant so the two rc's sit in
  # one place and the difference is attributable to the comparison alone.
  run "$F"
  ck "MUTATION: the real script catches that same fixture" "$RC" "1"
fi

printf '\n=== residue-parity: %s passed, %s failed ===\n' "$pass" "$fails"
[ "$fails" -eq 0 ]
