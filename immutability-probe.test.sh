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
# TWO PARTS, AND WHY THE GUARD IS SHAPED THIS WAY:
#   PART A    needs nothing but bash: the probe's pure contract through the CLI (verdict fold, exit
#             codes, the STAGED host half) and the MECHANICAL no-tidy scans. It runs EVERYWHERE, so a
#             genuine regression in any of it still exits 1 on a host that cannot run the rest.
#   PARTS B-D need a real engine, and they say so in THREE separate voices — the witness, a reachable
#             engine, and an engine that can actually COMPLETE the probe's own throwaway build cycle.
#             Off such a host they skip by NAME (`SKIP: <reason>`, exit 77 — the contract
#             .github/workflows/tests.yml honours), never quietly.
#
# WHY THE THIRD REQUIREMENT EXISTS, MEASURED NOT REASONED. The first cut guarded on `podman info` alone
# and was WRONG about what its own rows needed: on the GitHub runner (CI run 30523619416) `podman info`
# succeeds, so nothing skipped — and 13 rows failed for ONE environmental reason, because the real
# `build-throwaway.sh -c <ctx>` cycle every measured row depends on exits NON-ZERO there. A guard that
# names a condition its rows do not actually need is the same "excuse wider than the reason" the
# workflow's own header forbids. So this guard RUNS one real cycle and reads its rc rather than
# reasoning about which engine can host one, and it reports the engine's own error when it cannot.
#
# AND THE LEAK STAND-INS BUILD THEIR OWN IMAGE. They used to re-tag whatever `podman images` listed
# first — a HIDDEN environmental requirement: on a fresh engine that list is EMPTY, the injection
# silently no-ops, and the RED rows then assert against a builder that leaked nothing. The suite now
# builds a tiny OFFLINE fixture image of its own (Principle 2: it fetches nothing), so the detection
# rows keep biting on every host where the probe itself can run.
#
# THE INJECTIONS ARE REVERSED BY THIS FILE, precisely and by name — never by a glob. The probe itself
# must not tidy (that is its contract, asserted below), so the test owns its own leaks: it records each
# artifact it injected and removes exactly those on exit, with `podman untag <ref> <ref>` in the
# TWO-argument form (the one-argument form removes every name that image has, which would destroy a
# pre-existing tag — the witness's own hard-won note).
#
#   bash immutability-probe.test.sh  -> exit 0 = all rows pass · 77 = PARTS B-D unrunnable here (PART A
#                                       ran and passed) · 1 = a real failure, never excused as a skip.
# No GitHub, no network, no model; builds are local-only and offline. Run after touching the probe.
set -uo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
PROBE="$REPO/bin/immutability-probe.sh"
WITNESS="$REPO/bin/residue-witness.sh"
BUILDER="$REPO/bin/build-throwaway.sh"

TMP="$(mktemp -d)"
LEAK_REF="localhost/disposable/immut-probe-test:leak-$$"
FIX_REF="localhost/immut-probe-test/fixture:$$"
FIX_ID=""
TREE_LOG="$TMP/leaked-trees"
REF_LOG="$TMP/leaked-refs"
: > "$TREE_LOG"; : > "$REF_LOG"

# Reverse EXACTLY what this file injected: the tags by name, and only the tree paths the stand-in
# recorded. A glob over the throwaway root would reap a CONCURRENT build's in-flight tree.
cleanup(){
    podman untag "$LEAK_REF" "$LEAK_REF" >/dev/null 2>&1
    while IFS= read -r r; do [ -n "$r" ] && podman untag "$r" "$r" >/dev/null 2>&1; done < "$REF_LOG"
    while IFS= read -r d; do [ -n "$d" ] && rm -rf "$d"; done < "$TREE_LOG"
    # The fixture image is this suite's OWN: built here, from content carrying this pid, so its id is
    # unique to this run and carries no other name. Untag it, then remove the now-nameless id —
    # removing by id is safe ONLY because nothing else can share it.
    if [ -n "$FIX_ID" ]; then
        podman untag "$FIX_REF" "$FIX_REF" >/dev/null 2>&1
        podman rmi -f "$FIX_ID" >/dev/null 2>&1
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got=[$2] want=[$3])"; fail=$((fail+1)); fi; }
ckc(){ if printf '%s' "$2" | grep -qF "$3"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (output did not contain [$3])"; fail=$((fail+1)); fi; }
ckn(){ if printf '%s' "$2" | grep -qF "$3"; then echo "  FAIL: $1 (output wrongly contained [$3])"; fail=$((fail+1)); else echo "  PASS: $1"; pass=$((pass+1)); fi; }

# A tiny, fully OFFLINE build context: `FROM scratch` + a COPY. It pulls nothing and runs no RUN step,
# so the healthy row is a real build-and-teardown cycle that costs about a second. (Plain files — no
# engine — so the guard below can use it as the context of its own pre-flight cycle.)
CTX="$TMP/ctx"; mkdir -p "$CTX"
printf 'FROM scratch\nCOPY payload /payload\n' > "$CTX/Containerfile"
echo "immutability-probe test payload" > "$CTX/payload"

run_probe(){ timeout 240 bash "$@" 2>/dev/null; }

# ==== A. PURE / STRUCTURAL — no engine, no build. RUNS EVERYWHERE ===================================
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

# ==== CAPABILITY GUARD FOR PARTS B-D ================================================================
# Each requirement is named for ITSELF, so the excuse can never be wider than the reason for it. PART A
# has already run: a real regression above exits 1 here and is never laundered into a skip.
skip(){
    printf '\nimmutability-probe.test.sh: %s passed, %s failed (PART A only)\n' "$pass" "$fail"
    if [ "$fail" -ne 0 ]; then
        echo "PART A FAILED — a real regression is reported, never excused as a skip"
        exit 1
    fi
    printf 'SKIP: %s PART A ran and passed.\n' "$1"
    exit 77
}

#   * the WITNESS — the probe delegates EVERY observation to bin/residue-witness.sh (feat-01, #312).
#     Without it the probe has no eyes and every engine row would fail for that one reason, none of
#     them a regression. (The pure verdict fold is covered regardless: the workflow discovers
#     `bin/immutability-probe.sh --selftest` independently of this file.)
[ -x "$WITNESS" ] || skip "PARTS B-D need bin/residue-witness.sh (feat-01, #312) — the probe delegates every observation to it and can measure nothing without it."

#   * the ENGINE — probe the ENGINE, not the binary: `command -v podman` succeeding proves nothing
#     (CI run 30417457651 printed "container engine available: 1" and still failed).
podman info >/dev/null 2>&1 || skip "PARTS B-D need a usable podman engine (podman info failed) — every measured row runs a REAL throwaway build."

#   * A COMPLETABLE CYCLE — the requirement `podman info` does NOT imply, and the one the runner
#     actually fails. FD_STALE_MIN is pinned high exactly as the probe pins it, so this pre-flight's
#     own sweep can never reach a concurrent build's in-flight artifacts. Its bound sits BELOW the
#     workflow's own 120s per-file bound (a cycle here costs ~2s): an engine slow enough to exceed it
#     must SKIP by name, not be killed mid-file and reported as a failure.
PRE_LOG="$TMP/preflight-build.log"
FD_STALE_MIN=525600 timeout 60 bash "$BUILDER" -c "$CTX" >"$PRE_LOG" 2>&1; pre_rc=$?
[ "$pre_rc" -eq 0 ] || skip "PARTS B-D need an engine that can COMPLETE the probe's own throwaway cycle; \`build-throwaway.sh -c <ctx>\` exited $pre_rc here — $(tail -1 "$PRE_LOG" 2>/dev/null | tr -d '\r' | cut -c1-200)."

# ---- fixtures needing the engine -------------------------------------------------------------------

# The image the leak stand-ins re-tag: built HERE, offline, from content carrying this pid. Unique
# content ⇒ a unique image id that shares no name with anything on the box — and deliberately NOT the
# same content the probe's own cycle builds, since an id shared with a disposable tag would put the
# real builder's teardown `rmi -f` on this fixture (the multi-name hazard the probe's header records).
FIXCTX="$TMP/fixctx"; mkdir -p "$FIXCTX"
printf 'FROM scratch\nCOPY payload /payload\n' > "$FIXCTX/Containerfile"
printf 'immutability-probe leak fixture %s\n' "$$" > "$FIXCTX/payload"
FIX_ID="$(podman build -q --isolation=chroot -t "$FIX_REF" -f "$FIXCTX/Containerfile" "$FIXCTX" 2>/dev/null)"
[ -n "$FIX_ID" ] || skip "PARTS B-D need to build a tiny offline fixture image for the leak stand-ins to re-tag; a FROM-scratch \`podman build\` produced no image id here."

# A stand-in builder whose TEARDOWN IS BROKEN in the IMAGE class: it tags a disposable candidate exactly
# as the real builder does and never removes it. Idempotent, so only the first cycle leaks — which keeps
# the leak in the CLEAN arm alone and leaves the kill-9 arm with nothing staged (correctly STAGED).
cat > "$TMP/leaky-image-build.sh" <<'EOF'
#!/usr/bin/env bash
podman tag "$FIX_REF" "$LEAK_REF" >/dev/null 2>&1 || exit 1
exit 0
EOF

# As above but leaking a DISTINCT tag on every call, so the kill-9 cycle leaks something real that is
# NOT a tree. That is the one case the reap arm cannot assert (it can age a tree's timestamp, nothing
# else), and it must say which class it is rather than leave a bare count for a reader to guess at.
cat > "$TMP/leaky-image-unique-build.sh" <<'EOF'
#!/usr/bin/env bash
ref="${LEAK_REF}-$(date +%s%N)"
podman tag "$FIX_REF" "$ref" >/dev/null 2>&1 || exit 1
printf '%s\n' "$ref" >> "$REF_LOG"
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
       LEAK_REF="$LEAK_REF" FIX_REF="$FIX_REF" run_probe "$PROBE" dev)"; rc_img=$?
ck "an image leak makes the dev half RED (rc 1)" "$rc_img" "1"
ckc "line 1 reports RED" "$(printf '%s' "$out" | head -1)" "immutability-probe: RED dev=RED"
ckc "the survivor is named verbatim" "$out" "RESIDUE image"
ckc "the survivor is named by its reference" "$out" "$LEAK_REF"
IMG_RED_OUT="$out"

# The reap arm can age a TREE and nothing else, so a kill-9 leak in another class must be DISCLOSED by
# class, not reduced to a bare count — and must never be folded into a GREEN it did not prove.
out="$(IMMUT_PROBE_CTX="$CTX" IMMUT_PROBE_BUILD="$TMP/leaky-image-unique-build.sh" IMMUT_PROBE_KILL_WAIT=5 \
       LEAK_REF="$LEAK_REF" FIX_REF="$FIX_REF" REF_LOG="$REF_LOG" run_probe "$PROBE" dev)"; rc=$?
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
           IMMUT_PROBE_KILL_WAIT=5 LEAK_REF="$LEAK_REF" FIX_REF="$FIX_REF" run_probe "$MUT" dev)"; rc=$?
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
