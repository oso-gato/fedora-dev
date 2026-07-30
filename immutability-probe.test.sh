#!/usr/bin/env bash
# immutability-probe.test.sh — proves bin/immutability-probe.sh MEASURES residue rather than asserting
# its absence (fedora-dev#313, feat-02 of objective #310).
#
# THE AXIS UNDER TEST is the one a --selftest is structurally blind to: a probe whose comparison is
# broken prints GREEN on a box carrying residue, and a green pure-core fold cannot tell you that. So the
# engine rows drive the REAL probe against a REAL throwaway build, and the RED rows INJECT a leak and
# demand the probe both FAIL and NAME the survivor. The MUTATION row then neutralizes the comparison and
# requires the RED case to stop being RED — proving the comparison is what decides, not the plumbing.
#
# WHAT IS STUBBED, AND WHAT DELIBERATELY IS NOT. The SUBJECT is the probe's measurement logic; the thing
# MEASURED is the builder. So the leak rows stand in a deliberately BROKEN builder (one whose teardown
# never runs) — that is the defect being detected, and it cannot be produced by the real builder without
# editing it, which #313 forbids. The healthy row uses the REAL builder AND the REAL witness resolved by
# their DEFAULT paths, so the production resolution every other row overrides is still executed here.
#
# THE INJECTIONS ARE REVERSED BY THIS FILE, precisely and by name — never by a glob. The probe itself
# must not tidy (that is its contract, asserted below), so the test owns its own leaks: it records each
# artifact it injected and removes exactly those on exit, with `podman untag <ref> <ref>` in the
# TWO-argument form (the one-argument form removes every name that image has, which would destroy a
# pre-existing tag — the witness's own hard-won note).
set -uo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
PROBE="$REPO/bin/immutability-probe.sh"
WITNESS="$REPO/bin/residue-witness.sh"

# CAPABILITY GUARD — exit 77 = SKIP, the contract .github/workflows/tests.yml honours (it prints this
# reason by name in the log and the step summary). TWO distinct requirements, each named for itself so
# the excuse is never wider than the reason for it:
#   * the WITNESS — this probe delegates every observation to bin/residue-witness.sh (feat-01, #312).
#     Until that lands on main the probe has no eyes here and every engine row would fail for that one
#     reason, none of them a regression. The pure verdict fold is covered regardless: the workflow
#     discovers `bin/immutability-probe.sh --selftest` independently of this file.
#   * the ENGINE — every engine row runs a REAL `podman build`. Probe the ENGINE, not the binary:
#     `command -v podman` succeeding proves nothing (CI run 30417457651 printed "container engine
#     available: 1" and still failed), whereas `podman info` exercises it.
[ -x "$WITNESS" ] || {
    echo "SKIP: bin/residue-witness.sh (feat-01, #312) is not present — the probe delegates every observation to it and can measure nothing without it"
    exit 77
}
podman info >/dev/null 2>&1 || {
    echo "SKIP: no usable podman engine (podman info failed) — every measured row runs a REAL throwaway build"
    exit 77
}

TMP="$(mktemp -d)"
LEAK_REF="localhost/disposable/immut-probe-test:leak-$$"
TREE_LOG="$TMP/leaked-trees"
REF_LOG="$TMP/leaked-refs"
: > "$TREE_LOG"; : > "$REF_LOG"

# Reverse EXACTLY what this file injected: the tag by name, and only the tree paths the stand-in
# recorded. A glob over the throwaway root would reap a CONCURRENT build's in-flight tree.
cleanup(){
    podman untag "$LEAK_REF" "$LEAK_REF" >/dev/null 2>&1
    while IFS= read -r r; do [ -n "$r" ] && podman untag "$r" "$r" >/dev/null 2>&1; done < "$REF_LOG"
    while IFS= read -r d; do [ -n "$d" ] && rm -rf "$d"; done < "$TREE_LOG"
    rm -rf "$TMP"
}
trap cleanup EXIT

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got=[$2] want=[$3])"; fail=$((fail+1)); fi; }
ckc(){ if printf '%s' "$2" | grep -qF "$3"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (output did not contain [$3])"; fail=$((fail+1)); fi; }
ckn(){ if printf '%s' "$2" | grep -qF "$3"; then echo "  FAIL: $1 (output wrongly contained [$3])"; fail=$((fail+1)); else echo "  PASS: $1"; pass=$((pass+1)); fi; }

# ---- fixtures --------------------------------------------------------------------------------------

# A tiny, fully OFFLINE build context: `FROM scratch` + a COPY. It pulls nothing and runs no RUN step,
# so the healthy row is a real build-and-teardown cycle that costs about a second.
CTX="$TMP/ctx"; mkdir -p "$CTX"
printf 'FROM scratch\nCOPY payload /payload\n' > "$CTX/Containerfile"
echo "immutability-probe test payload" > "$CTX/payload"

# A stand-in builder whose TEARDOWN IS BROKEN in the IMAGE class: it tags a disposable candidate exactly
# as the real builder does and never removes it. Idempotent, so only the first cycle leaks — which keeps
# the leak in the CLEAN arm alone and leaves the kill-9 arm with nothing staged (correctly STAGED).
cat > "$TMP/leaky-image-build.sh" <<'EOF'
#!/usr/bin/env bash
img="$(podman images --format '{{.ID}}' 2>/dev/null | sort -u | head -1)"
[ -n "$img" ] || exit 0
podman tag "$img" "$LEAK_REF" >/dev/null 2>&1
exit 0
EOF

# As above but leaking a DISTINCT tag on every call, so the kill-9 cycle leaks something real that is
# NOT a tree. That is the one case the reap arm cannot assert (it can age a tree's timestamp, nothing
# else), and it must say which class it is rather than leave a bare count for a reader to guess at.
cat > "$TMP/leaky-image-unique-build.sh" <<'EOF'
#!/usr/bin/env bash
img="$(podman images --format '{{.ID}}' 2>/dev/null | sort -u | head -1)"
[ -n "$img" ] || exit 0
ref="${LEAK_REF}-$(date +%s%N)"
podman tag "$img" "$ref" >/dev/null 2>&1 && printf '%s\n' "$ref" >> "$REF_LOG"
exit 0
EOF

# A stand-in builder whose TEARDOWN IS BROKEN in the TREE class: it creates a throwaway tree where the
# real one does and never removes it, recording the path so this file can reverse exactly that.
cat > "$TMP/leaky-tree-build.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$HOME/.cache"
d="$(mktemp -d "$HOME/.cache/fd-throwaway.XXXXXX")" || exit 1
printf '%s\n' "$d" >> "$TREE_LOG"
exit 0
EOF
chmod +x "$TMP/leaky-image-build.sh" "$TMP/leaky-image-unique-build.sh" "$TMP/leaky-tree-build.sh"

run_probe(){ timeout 240 bash "$@" 2>/dev/null; }

# ==== A. PURE / STRUCTURAL — no engine, no build ====================================================
echo "== A. pure contract =="

out="$(bash "$PROBE" --selftest 2>&1)"; rc=$?
ck "--selftest exits 0" "$rc" "0"
ckc "--selftest actually ran its rows" "$out" "immutability-probe selftest:"

out="$(bash "$PROBE" bogus-verb 2>&1)"; rc=$?
ck "an unknown verb is a harness error (rc 2)" "$rc" "2"

out="$(bash "$PROBE" host 2>&1)"; rc=$?
ck "host-only exits 3 (STAGED is never a pass)" "$rc" "3"
ckc "host half discloses STAGED" "$out" "host: STAGED — not yet measured"
ckn "host half never claims GREEN" "$out" "host: GREEN"

# IT MEASURES, IT DOES NOT TIDY. The probe's contract forbids reaping between a cycle and its AFTER
# snapshot; a sweep verb appearing in this file is the whole feature quietly inverted. `rm -f` on its
# own scratch snapshots is allowed and is the only removal it may hold.
ck "probe holds no image-removal verb"  "$(grep -c 'podman rmi' "$PROBE")" "0"
ck "probe holds no recursive removal"   "$(grep -c 'rm -rf' "$PROBE")" "0"
ck "probe never invokes the sweeper"    "$(grep -c -- '--sweep-only' "$PROBE")" "0"

# ==== B. THE HEALTHY CYCLE — real builder, real witness, both at their DEFAULT paths =================
echo "== B. a real build-and-teardown cycle leaves nothing =="

out="$(IMMUT_PROBE_CTX="$CTX" IMMUT_PROBE_KILL_WAIT=60 run_probe "$PROBE" dev)"; rc=$?
ck "dev half exits 0 on a healthy box" "$rc" "0"
ckc "line 1 is the machine-readable verdict" "$(printf '%s' "$out" | head -1)" "immutability-probe: GREEN dev=GREEN"
ckc "the clean cycle is zero-residue" "$out" "residue 0 → GREEN"
ckc "the acceptance line names all four classes" "$out" "dev: GREEN — 0 residue (image/tree/container/mount)"
ckc "the build rc is reported separately from the residue verdict" "$out" "cycle build rc=0"
ckc "the kill-9 leak was staged and reaped by the next build" "$out" "survived the next build → GREEN"
ckn "a healthy dev half names no survivor" "$out" "RESIDUE "

out="$(IMMUT_PROBE_CTX="$CTX" IMMUT_PROBE_KILL_WAIT=60 run_probe "$PROBE")"; rc=$?
ck "both halves exit 3 while the host half is unmeasured" "$rc" "3"
ck "line 1 discloses each half" "$(printf '%s' "$out" | head -1)" "immutability-probe: PARTIAL dev=GREEN host=STAGED"
ckn "an unmeasured half is never reported GREEN" "$out" "host=GREEN"

# ==== C. AN INJECTED LEAK IS CAUGHT AND NAMED ========================================================
echo "== C. injected residue is detected, not smoothed over =="

out="$(IMMUT_PROBE_CTX="$CTX" IMMUT_PROBE_BUILD="$TMP/leaky-image-build.sh" IMMUT_PROBE_KILL_WAIT=5 \
       LEAK_REF="$LEAK_REF" run_probe "$PROBE" dev)"; rc_img=$?
ck "an image leak makes the dev half RED (rc 1)" "$rc_img" "1"
ckc "line 1 reports RED" "$(printf '%s' "$out" | head -1)" "immutability-probe: RED dev=RED"
ckc "the survivor is named verbatim" "$out" "RESIDUE image"
ckc "the survivor is named by its reference" "$out" "$LEAK_REF"
IMG_RED_OUT="$out"

# The reap arm can age a TREE and nothing else, so a kill-9 leak in another class must be DISCLOSED by
# class, not reduced to a bare count — and must never be folded into a GREEN it did not prove.
out="$(IMMUT_PROBE_CTX="$CTX" IMMUT_PROBE_BUILD="$TMP/leaky-image-unique-build.sh" IMMUT_PROBE_KILL_WAIT=5 \
       LEAK_REF="$LEAK_REF" REF_LOG="$REF_LOG" run_probe "$PROBE" dev)"; rc=$?
ck "a non-tree kill-9 leak still makes the dev half RED" "$rc" "1"
ckc "the unassertable class is named, not left as a count" "$out" "none of it a throwaway tree (classes: image)"
ckn "and it is never claimed as reaped" "$out" "survived the next build → GREEN"

out="$(IMMUT_PROBE_CTX="$CTX" IMMUT_PROBE_BUILD="$TMP/leaky-tree-build.sh" IMMUT_PROBE_KILL_WAIT=5 \
       TREE_LOG="$TREE_LOG" run_probe "$PROBE" dev)"; rc=$?
ck "a tree leak makes the dev half RED (rc 1)" "$rc" "1"
ckc "the leaked tree is named" "$out" "RESIDUE tree $HOME/.cache/fd-throwaway."
# The reap arm is the one that asserts the SWEEPER's own code path. A builder that never sweeps must
# make it RED — otherwise the arm would be reporting on a reap that never happened.
ckc "the reap arm reports the survivor of the next build" "$out" "survived the next build → RED"

# ==== D. MUTATION — neutralize the comparison; the RED case must stop being RED ======================
# (BP8. Run in-suite, and the sed must genuinely change the copy or the row proves nothing.)
echo "== D. mutation: the comparison is what decides =="

MUT="$TMP/mutant-probe.sh"
cp "$PROBE" "$MUT"
sed -i "s/^    1) printf 'RED';;/    1) printf 'GREEN';;/" "$MUT"
if cmp -s "$PROBE" "$MUT"; then
    echo "  FAIL: mutation was VACUOUS — the sed matched nothing, so this row proves nothing"
    fail=$((fail+1))
else
    echo "  PASS: mutation genuinely changed residue_verdict's RED arm"
    pass=$((pass+1))
    # The mutant must resolve the same witness the real probe does; it lives outside bin/.
    out="$(IMMUT_PROBE_WITNESS="$WITNESS" IMMUT_PROBE_CTX="$CTX" IMMUT_PROBE_BUILD="$TMP/leaky-image-build.sh" \
           IMMUT_PROBE_KILL_WAIT=5 LEAK_REF="$LEAK_REF" run_probe "$MUT" dev)"; rc=$?
    ckn "with the comparison neutralized the leak stops being RED" "$out" "dev=RED"
    ckn "and the survivor is no longer named" "$out" "RESIDUE image"
    if [ "$rc" != "$rc_img" ]; then
        echo "  PASS: the mutant's rc differs from the real probe's ($rc vs $rc_img)"; pass=$((pass+1))
    else
        echo "  FAIL: the mutant exits exactly as the real probe does — the comparison decides nothing"; fail=$((fail+1))
    fi
fi

echo
echo "immutability-probe.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
