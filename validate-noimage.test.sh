#!/usr/bin/env bash
# validate-noimage.test.sh — a repo with no root Containerfile is a NON-IMAGE repo, not a build
# failure (#180).
#
# The defect (reproduced live 2026-07-13): validate.sh defaulted its build tier to a root
# Containerfile, so oso-gato/fedora-bootstrap — which ships Containerfile.livegate + a .live-gate
# contract, no root Containerfile — RED'd `the specified Containerfile … does not exist` on EVERY
# dev-author run, BEFORE a PR existed. The loop was structurally incapable of authoring in the host
# repo (all five host tickets blocked, R17's executor #134 included). Same class as #160: a
# fleet-shaped assumption baked into a harness whose own header says "repo-agnostic".
#
# Rows drive the REAL bin/validate.sh (byte-identical copy in a bare dir — the out-of-scope T0b
# adjacency tier skips as info; lint-live-gate.sh is copied ADJACENT because the fix consumes its
# --cfile resolver) against REAL offline `FROM scratch` builds in the nested engine:
#   1. non-image repo (no root Containerfile, no .live-gate) -> GREEN; T1/T2/T4 VISIBLY skipped with
#      the reason; lint still runs (skip != pass, skip != fail)
#   2. the same repo shape + one broken *.sh                 -> RED (lint still GATES a non-image repo)
#   3. IMAGE repo whose Containerfile is genuinely broken    -> RED via build FAIL (the discriminator:
#      a real build failure must NEVER become a skip)
#   4. .live-gate declaring CFILE_shellgate=Containerfile.livegate (the fedora-bootstrap shape)
#                                                            -> built from the CONTRACT's file, GREEN
#   5. an EXPLICITLY named missing containerfile arg         -> RED (the skip covers only the
#      DEFAULTED probe; an explicit ask is honoured verbatim)
#   6. MUTATION, RUN IN-SUITE: the unconditional root-Containerfile default is mechanically RESTORED
#      (a sed that must genuinely change the copy, else the row fails as vacuous) -> the non-image
#      repo goes RED again (the #180 defect resurrected; proves row 1 discriminates).
# No GitHub/network/model; podman builds are local-only (no pulls, no RUN steps).
#   bash validate-noimage.test.sh   -> exit 0 = all rows pass
set -uo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
VSH_SRC="$REPO/bin/validate.sh"
LLG_SRC="$REPO/bin/lint-live-gate.sh"
podman info >/dev/null 2>&1 || { echo "FATAL: no podman engine reachable — this suite drives REAL scratch builds (CONTAINER_HOST)"; exit 1; }
TMP=$(mktemp -d)
# DISCARD=1 reaps each candidate on validate.sh's own exit; the trap is belt-and-braces for an interrupted run
trap 'podman rmi -f localhost/ni-contract:candidate-Containerfile-livegate- localhost/ni-broken-img:candidate-Containerfile- >/dev/null 2>&1; rm -rf "$TMP"' EXIT
pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got=$2 want=$3)"; fail=$((fail+1)); fi; }

mkdir -p "$TMP/vbin"; cp "$VSH_SRC" "$TMP/vbin/validate.sh"; cp "$LLG_SRC" "$TMP/vbin/lint-live-gate.sh"
VSH="$TMP/vbin/validate.sh"

# shared filler so rootfs-size (>1000 entries) PASSes in the image rows and a verdict is attributable
# ONLY to the check under test
FILLER="$TMP/filler"; mkdir -p "$FILLER"
for i in $(seq 1 1200); do : > "$FILLER/f$i"; done

seq_n=0
run_v(){ # $1=validate.sh under test  $2=repo dir  [$3=explicit containerfile arg]  -> sets RC + OUTF
  seq_n=$((seq_n+1)); OUTF="$TMP/out-$seq_n-$(basename "$2").log"
  if [ $# -ge 3 ]; then DISCARD=1 FD_DNF_CACHE="$TMP/dnf" bash "$1" "$2" "$3" build >"$OUTF" 2>&1; RC=$?
  else                  DISCARD=1 FD_DNF_CACHE="$TMP/dnf" bash "$1" "$2"            >"$OUTF" 2>&1; RC=$?; fi
}
has(){ grep -qE "$1" "$OUTF" && echo yes || echo no; }

# -- fixtures ---------------------------------------------------------------------------------------
R_PLAIN="$TMP/ni-plain"; mkdir -p "$R_PLAIN"                       # the fedora-bootstrap CLASS: scripts, no image
printf '#!/usr/bin/env bash\ntrue\n' > "$R_PLAIN/tool.sh"
printf '# a non-image repo\n'        > "$R_PLAIN/README.md"

R_BADLINT="$TMP/ni-badlint"; mkdir -p "$R_BADLINT"                 # same shape, one broken script
printf '#!/usr/bin/env bash\ntrue\n' > "$R_BADLINT/tool.sh"
printf '#!/usr/bin/env bash\nif true; then\n' > "$R_BADLINT/broken.sh"

R_BROKEN="$TMP/ni-broken-img"; mkdir -p "$R_BROKEN/root"; cp "$FILLER"/f* "$R_BROKEN/root/"
printf 'FROM scratch\nCOPY does-not-exist /x\n' > "$R_BROKEN/Containerfile"   # a REAL build failure

R_LG="$TMP/ni-contract"; mkdir -p "$R_LG/root"; cp "$FILLER"/f* "$R_LG/root/"  # the fedora-bootstrap SHAPE
printf 'FROM scratch\nCOPY root/ /\nCMD ["/f1"]\n' > "$R_LG/Containerfile.livegate"
printf 'LIVE_GATE_TARGETS=shellgate\nCFILE_shellgate=Containerfile.livegate\n' > "$R_LG/.live-gate"

echo "== row 1: a non-image repo (no root Containerfile, no .live-gate) is GREEN with T1/T2/T4 visibly SKIPPED =="
run_v "$VSH" "$R_PLAIN"
ck "verdict GREEN (rc=0)"                                     "$RC" 0
ck "build SKIPPED, visibly"                                   "$(has 'build +SKIPPED')" yes
ck "the skip line states the reason (non-image repo)"         "$(has 'non-image repo ships nothing to build')" yes
ck "build is NOT reported PASS (skip != silent pass)"         "$(has 'build +PASS')" no
ck "assembly SKIPPED, visibly"                                "$(has 'assembly +SKIPPED')" yes
ck "smoke skipped (no image)"                                 "$(has 'smoke +skipped \(no image')" yes
ck "lint still RAN and PASSed"                                "$(has 'lint-scripts +PASS')" yes
ck "the verdict line names what was skipped"                  "$(has 'T1/T2/T4 SKIPPED \(non-image repo\)')" yes

echo "== row 2: lint still GATES a non-image repo (a broken *.sh makes it RED) =="
run_v "$VSH" "$R_BADLINT"
ck "verdict RED (rc=1)"                                       "$RC" 1
ck "lint-scripts FAIL (the RED is lint ALONE)"                "$(has 'lint-scripts +FAIL')" yes
ck "build still SKIPPED (never counted as the failure)"       "$(has 'build +SKIPPED')" yes

echo "== row 3: an IMAGE repo whose Containerfile is genuinely broken still goes RED (never a skip) =="
run_v "$VSH" "$R_BROKEN"
ck "verdict RED (rc=1)"                                       "$RC" 1
ck "build FAIL (a real build failure stays a failure)"        "$(has 'build +FAIL')" yes
ck "build was NOT skipped"                                    "$(has 'build +SKIPPED')" no

echo "== row 4: a .live-gate naming its build target (the fedora-bootstrap shape) is built from THAT file =="
run_v "$VSH" "$R_LG"
ck "verdict GREEN (rc=0)"                                     "$RC" 0
ck "the CONTRACT's file was resolved (file=Containerfile.livegate)" "$(has 'file=Containerfile\.livegate')" yes
ck "build PASS (the declared target genuinely built)"         "$(has 'build +PASS')" yes
ck "assembly ran (startup-process PASS)"                      "$(has 'startup-process +PASS')" yes
ck "live-gate contract lint PASS (T0 still gates it)"         "$(has 'live-gate +PASS')" yes

echo "== row 5: an EXPLICITLY named missing containerfile still FAILs (the skip covers only the DEFAULTED probe) =="
run_v "$VSH" "$R_PLAIN" Containerfile
ck "verdict RED (rc=1)"                                       "$RC" 1
ck "build FAIL (an explicit ask is honoured verbatim)"        "$(has 'build +FAIL')" yes

echo "== row 6 (MUTATION, run in-suite): restore the unconditional root-Containerfile default -> the non-image repo must go RED =="
MUT="$TMP/vbin-mut"; mkdir -p "$MUT"; cp "$LLG_SRC" "$MUT/lint-live-gate.sh"
sed 's/FILE="\${2:-}"/FILE="\${2:-Containerfile}"/' "$VSH" > "$MUT/validate.sh"
ck "the mutation genuinely changed the copy (not vacuous)"    "$(cmp -s "$VSH" "$MUT/validate.sh" && echo same || echo differs)" differs
run_v "$MUT/validate.sh" "$R_PLAIN"
ck "the non-image repo goes RED again (row 1 discriminates)"  "$RC" 1
ck "via the resurrected unconditional build FAIL"             "$(has 'build +FAIL')" yes
ck "nothing was skipped (the pre-#180 behaviour restored)"    "$(has 'build +SKIPPED')" no

echo "-----"; echo "validate-noimage: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
