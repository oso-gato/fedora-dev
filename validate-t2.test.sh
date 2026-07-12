#!/usr/bin/env bash
# validate-t2.test.sh — T2 asserts the repo-agnostic OUTCOME, not the fleet convention (#160).
#
# The defect (observed live on the R14 E2E-A proving run, 2026-07-12): T2's unconditional rootfs
# grep for usr/local/bin/entrypoint*.sh — a fedora-dev-family CONVENTION — turned a correct,
# minimal, CMD-only image RED (build PASS, lint PASS, smoke Up) and wedged the E2E run on a
# validator opinion. The fix: T2 gates on "the image DECLARES a startup process" (podman inspect:
# non-empty .Config.Entrypoint OR .Config.Cmd), and holds the entrypoint*.sh path only against a
# tree that SHIPS one. podman 5's `create` happily creates a container from a no-startup image
# (probed: rc=0), so the inspect check is the ONLY thing standing between such an image and GREEN.
#
# Rows drive the REAL bin/validate.sh (a byte-identical copy in a bare dir, so the out-of-scope
# T0/T0b adjacency tiers skip as info) against REAL offline `FROM scratch` builds in the nested
# engine — the transport under test is podman's actual inspect/create/export semantics, so a stub
# would prove nothing about the template the check rides on:
#   1. CMD-only image, no entrypoint*.sh in tree       -> GREEN; startup-process PASS; fleet check skipped
#   2. NEITHER Entrypoint nor Cmd                      -> RED; startup-process FAIL names the remedy
#   3. fleet tree (ships entrypoint.sh), image LOST it -> RED; entrypoint-present FAIL names the path
#   4. fleet tree + image carries it                   -> GREEN (the convention still bites when present)
#   5. MUTATION, RUN IN-SUITE: the unconditional path-grep is mechanically RESTORED (a sed that
#      must genuinely change the copy, else the row fails as vacuous) -> the CMD-only repo goes
#      RED. Proves row 1 discriminates against the pre-#160 script.
# No GitHub/network/model; podman does local scratch builds only (no pulls, no RUN steps).
#   bash validate-t2.test.sh   -> exit 0 = all rows pass
set -uo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
VSH_SRC="$REPO/bin/validate.sh"
podman info >/dev/null 2>&1 || { echo "FATAL: no podman engine reachable — this suite drives REAL scratch builds (CONTAINER_HOST)"; exit 1; }
TMP=$(mktemp -d)
# DISCARD=1 reaps each candidate on validate.sh's own exit; the trap is belt-and-braces for an interrupted run
trap 'podman rmi -f localhost/t2-cmd-only:candidate-Containerfile- localhost/t2-no-start:candidate-Containerfile- localhost/t2-fleet-lost:candidate-Containerfile- localhost/t2-fleet-ok:candidate-Containerfile- >/dev/null 2>&1; rm -rf "$TMP"' EXIT
pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got=$2 want=$3)"; fail=$((fail+1)); fi; }

mkdir -p "$TMP/vbin"; cp "$VSH_SRC" "$TMP/vbin/validate.sh"; VSH="$TMP/vbin/validate.sh"

# shared filler so rootfs-size (>1000 entries) PASSes and a RED is attributable ONLY to the check under test
FILLER="$TMP/filler"; mkdir -p "$FILLER"
for i in $(seq 1 1200); do : > "$FILLER/f$i"; done

mkrepo(){ # $1=name  $2=Containerfile body  $3=ship entrypoint.sh in TREE (0|1)  $4=ship it in root/usr/local/bin (0|1)
  local d="$TMP/$1"; mkdir -p "$d/root"; cp "$FILLER"/f* "$d/root/"
  [ "$4" = 1 ] && { mkdir -p "$d/root/usr/local/bin"; printf '#!/usr/bin/env bash\ntrue\n' > "$d/root/usr/local/bin/entrypoint.sh"; }
  [ "$3" = 1 ] && printf '#!/usr/bin/env bash\ntrue\n' > "$d/entrypoint.sh"
  printf '%s\n' "$2" > "$d/Containerfile"
  echo "$d"
}
seq_n=0
run_v(){ # $1=validate.sh under test  $2=repo dir  -> sets RC + OUTF
  seq_n=$((seq_n+1)); OUTF="$TMP/out-$seq_n-$(basename "$2").log"
  DISCARD=1 FD_DNF_CACHE="$TMP/dnf" bash "$1" "$2" Containerfile build >"$OUTF" 2>&1; RC=$?
}
has(){ grep -qE "$1" "$OUTF" && echo yes || echo no; }

R_CMD=$(mkrepo t2-cmd-only 'FROM scratch
COPY root/ /
CMD ["/f1"]' 0 0)
R_NONE=$(mkrepo t2-no-start 'FROM scratch
COPY root/ /' 0 0)
R_LOST=$(mkrepo t2-fleet-lost 'FROM scratch
COPY root/ /
CMD ["/f1"]' 1 0)
R_OK=$(mkrepo t2-fleet-ok 'FROM scratch
COPY root/ /
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]' 1 1)

echo "== row 1: a CMD-only image with no entrypoint*.sh in the tree is CORRECT -> GREEN (the E2E-A defect) =="
run_v "$VSH" "$R_CMD"
ck "verdict GREEN (rc=0)"                                   "$RC" 0
ck "startup-process PASS (CMD alone declares a startup)"    "$(has 'startup-process +PASS')" yes
ck "the fleet path check is NOT imposed (skipped as info)"  "$(has 'entrypoint-present +skipped')" yes
ck "no entrypoint-present FAIL anywhere"                    "$(has 'entrypoint-present +FAIL')" no

echo "== row 2: an image with NEITHER Entrypoint nor Cmd cannot start -> RED, and the line says why =="
run_v "$VSH" "$R_NONE"
ck "verdict RED (rc=1)"                                     "$RC" 1
ck "startup-process FAIL"                                   "$(has 'startup-process +FAIL')" yes
ck "the FAIL line names the remedy (set ENTRYPOINT or CMD)" "$(has 'set ENTRYPOINT or CMD')" yes
ck "rootfs-size PASS (the RED is the startup check ALONE)"  "$(has 'rootfs-size +PASS')" yes

echo "== row 3: a fleet-convention tree whose image LOST /usr/local/bin/entrypoint*.sh -> RED =="
run_v "$VSH" "$R_LOST"
ck "verdict RED (rc=1)"                                     "$RC" 1
ck "startup-process PASS (declaring CMD is not the defect)" "$(has 'startup-process +PASS')" yes
ck "entrypoint-present FAIL (the convention still bites)"   "$(has 'entrypoint-present +FAIL')" yes
ck "the FAIL line names the expected path"                  "$(has 'usr/local/bin/entrypoint')" yes

echo "== row 4: a fleet-convention tree whose image CARRIES the entrypoint -> GREEN =="
run_v "$VSH" "$R_OK"
ck "verdict GREEN (rc=0)"                                   "$RC" 0
ck "entrypoint-present PASS"                                "$(has 'entrypoint-present +PASS')" yes
ck "startup-process PASS (ENTRYPOINT declares a startup)"   "$(has 'startup-process +PASS')" yes

echo "== row 5 (MUTATION, run in-suite): restore the unconditional path-grep -> the CMD-only row must go RED =="
MUT="$TMP/vbin-mut"; mkdir -p "$MUT"
sed '/find "$REPO" -name .entrypoint/s/.*/  if true; then/' "$VSH" > "$MUT/validate.sh"
ck "the mutation genuinely changed the copy (not vacuous)"  "$(cmp -s "$VSH" "$MUT/validate.sh" && echo same || echo differs)" differs
run_v "$MUT/validate.sh" "$R_CMD"
ck "the CMD-only repo now goes RED (row 1 discriminates)"   "$RC" 1
ck "via the restored unconditional entrypoint-present FAIL" "$(has 'entrypoint-present +FAIL')" yes
ck "while startup-process still PASSes (the RED is the grep ALONE)" "$(has 'startup-process +PASS')" yes

echo "-----"; echo "validate-t2: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
