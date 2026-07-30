#!/usr/bin/env bash
# bandwidth-probe.test.sh — proves bin/bandwidth-probe.sh REPORTS RED for every reason #322 names, and
# GREEN for exactly one combination. (fedora-dev#322, of objective #311.)
#
# THE AXIS UNDER TEST is what a --selftest is structurally blind to: the pure core can fold verdicts
# perfectly while the LIVE path never reaches it with the right values — a class silently dropped, a
# control never run, a host half assumed. So these rows drive the REAL script end to end and assert the
# verdict AND the machine-readable KV block a consumer would parse.
#
# THREE PARTS — named here as the file actually orders them:
#   PART A  the verdict + KV rows, driven against a world this suite fully controls.
#   PART B  the in-suite mutations: the same controlled world, one gate neutralized per row.
#   PART C  the production path, gated on its own three requirements and skipped BY NAME otherwise.
#
# WHY A COUNTER SEAM, AND WHAT IT DOES NOT EXCUSE. Every interesting row needs an EXACT byte figure —
# "this class pulled 50,000 bytes on build 2" — and the real signal is a kernel counter on a box that is
# never silent. Asserting against it would make the suite a coin toss. So PARTS A-B substitute a file the
# suite owns (`BW_RX_PATH`) and a stub builder that bumps it by a controlled amount: no engine, no
# network, no flake, and every branch reachable. PART C then runs the probe on its REAL default counter,
# REAL builder and REAL negative control, because a seam that EVERY row overrides would leave the
# production resolution untested — which is the hazard bin/seam-audit.sh exists to name.
#
# WHAT IS DELIBERATELY NOT STUBBED. The subject is the probe's own measurement and fold, so the probe is
# always the real file. PARTS A-B stub only what they must control (the counter, the builder, the ticket
# bus); PART C stubs nothing at all.
#
#   bash bandwidth-probe.test.sh -> exit 0 = all rows pass · 77 = PART C unrunnable here (PARTS A-B ran
#                                   and passed) · 1 = a real failure, never excused as a skip.
# No GitHub, no model. PARTS A-B need neither network nor an engine; PART C needs both and says so.
set -uo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
PROBE="$REPO/bin/bandwidth-probe.sh"
BUILDER="$REPO/bin/build-throwaway.sh"
FIXTURES="$REPO/probe-fixtures/bandwidth"

TMP="$(mktemp -d)"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got=[$2] want=[$3])"; fail=$((fail+1)); fi; }
ckc(){ if printf '%s' "$2" | grep -qF "$3"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (output did not contain [$3])"; fail=$((fail+1)); fi; }
ckn(){ if printf '%s' "$2" | grep -qF "$3"; then echo "  FAIL: $1 (output wrongly contained [$3])"; fail=$((fail+1)); else echo "  PASS: $1"; pass=$((pass+1)); fi; }

# ---- the controllable world PART A drives the probe against ----------------------------------------
FX="$TMP/fx"; mkdir -p "$FX/ospkg" "$FX/baseimg"
printf 'FROM scratch\n' > "$FX/ospkg/Containerfile"
printf 'FROM scratch\n' > "$FX/baseimg/Containerfile"
# NOTE: no gitobj/ and no langdep/ here. Their absence is what the SKIPPED rows exercise, and it also
# guarantees PART A never reaches a `git clone` — the suite's no-network claim is structural.

# A stub builder standing exactly where bin/build-throwaway.sh stands: it "downloads" by advancing the
# counter the probe reads, by a per-arm amount the row chooses. `-n <name>` is how the probe labels each
# arm, so the stub can move a different number of bytes for the control than for a class.
cat > "$TMP/stub-build" <<'EOF'
#!/usr/bin/env bash
n=""
while [ $# -gt 0 ]; do case "$1" in -n) n="${2:-}"; shift 2;; *) shift;; esac; done
b=0
case "$n" in
  bw-control) b="${BUMP_CONTROL:-0}";;
  bw-ospkg)   b="${BUMP_OSPKG:-0}";;
  bw-baseimg) b="${BUMP_BASEIMG:-0}";;
esac
printf '%s\n' "$(( $(cat "$BW_RX_PATH") + b ))" > "$BW_RX_PATH"
exit "${BUMP_RC:-0}"
EOF

# A stub ticket bus. The probe asks --mine first (reuse an open ticket) then --wait (file one).
cat > "$TMP/stub-ticket" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --mine)    exit 0;;                                   # nothing of ours is open
  --wait)    printf '%s\n' "${STUB_HOST_MSG:-stub bus}"; exit "${STUB_HOST_RC:-1}";;
  --outcome) printf '%s\n' "${STUB_HOST_MSG:-stub bus}"; exit "${STUB_HOST_RC:-1}";;
esac
exit 1
EOF
chmod +x "$TMP/stub-build" "$TMP/stub-ticket"

# Each case gets a FRESH counter file and a FRESH TMPDIR, so residue is attributable to that run alone.
#
# new_case IS CALLED BY THE PARENT, NOT BY run_case. Every row reads the probe's output through
# `out="$(run_case …)"`, which is a SUBSHELL — a case directory chosen in there never reaches the
# parent, and the residue rows below would then inspect an empty path and PASS having looked at
# nothing. (They did exactly that until this was split out: a vacuous green in the suite whose subject
# is vacuous greens.) The parent picks the path first, so the assertions afterwards are real.
CASE_TMP=""; CASE_N=0
new_case(){
  CASE_N=$((CASE_N+1)); CASE_TMP="$TMP/case.$CASE_N"
  mkdir -p "$CASE_TMP"; printf '1000\n' > "$CASE_TMP/rx"
}

# run_case <probe> <classes> <bump-ospkg> <bump-control> <host-rc> [extra-env…] → the probe's output.
run_case(){
  local probe="$1" classes="$2" bospkg="$3" bctl="$4" hrc="$5"; shift 5
  env BW_RX_PATH="$CASE_TMP/rx" BW_FIXTURES="$FX" BW_BUILD="$TMP/stub-build" \
      BW_HOST_TICKET="$TMP/stub-ticket" BW_CLASSES="$classes" \
      BW_FLOOR_WINDOW=1 BW_FLOOR_SAMPLES=1 BW_FLOOR_MIN=1000 \
      BUMP_OSPKG="$bospkg" BUMP_BASEIMG=0 BUMP_CONTROL="$bctl" STUB_HOST_RC="$hrc" \
      TMPDIR="$CASE_TMP" "$@" timeout 90 bash "$probe" 2>&1
}

# ==== A. THE FIVE VERDICT COMBINATIONS #322 NAMES ===================================================
echo "== A. pure contract =="

out="$(bash "$PROBE" --selftest 2>&1)"; rc=$?
ck  "--selftest exits 0" "$rc" "0"
ckc "--selftest actually ran its rows" "$out" "bandwidth-probe selftest:"
ckn "--selftest performs no build" "$out" "build-throwaway"

out="$(bash "$PROBE" bogus-verb 2>&1)"; rc=$?
ck "an unknown verb is a harness error (rc 2), never a verdict" "$rc" "2"

echo "== A. the one GREEN combination: every class zero + a detecting control + a host that reported =="
new_case; out="$(run_case "$PROBE" "ospkg baseimg" 0 50000 0)"; rc=$?
ck  "all-zero + DETECTS + host ZERO exits 0" "$rc" "0"
ckc "VERDICT is GREEN"        "$out" "VERDICT: GREEN"
ckc "line 1 summarises both halves" "$(printf '%s' "$out" | head -1)" "bandwidth-probe: GREEN dev=GREEN host=ZERO"
ckc "the KV block names each class" "$out" "CLASS_OSPKG: ZERO"
ckc "the control is reported every run" "$out" "CONTROL: DETECTS"
ckc "the host half is reported"   "$out" "HOST: ZERO"
ckc "the floor is stated, not hidden" "$out" "FLOOR: "

# THE INSTRUMENT IS NAMED, AND THE NAME DISCRIMINATES. PART C asserts a production run did NOT fall back
# to this seam. That row can only mean something if the report actually SAYS which counter was read — so
# these rows prove the field is printed and that it carries the seam whenever the seam is what was used.
# Without them, PART C's `ckn` would be asserting the absence of a string the probe never emits: a row
# that cannot fail, in the suite whose whole subject is rows that cannot fail.
ckc "the report names the counter it read"      "$out" "counter      : "
ckc "a seam run says so in that very field"     "$out" "[(BW_RX_PATH seam)]"
ckc "and names the seam file it read"           "$out" "$CASE_TMP/rx"
GREEN_TMP="$CASE_TMP"

echo "== A. a NON-ZERO build-2 for any class ⇒ RED =="
new_case; out="$(run_case "$PROBE" "ospkg baseimg" 50000 50000 0)"; rc=$?
ck  "a class that pulled on build 2 exits non-zero" "$rc" "1"
ckc "VERDICT is RED"                "$out" "VERDICT: RED"
ckc "the offending class is named NONZERO" "$out" "CLASS_OSPKG: NONZERO"
ckc "its byte figures are reported, not just a verdict" "$out" "CLASS_OSPKG: NONZERO 50000 50000"
ckn "a sibling class is not tarred with it" "$out" "CLASS_BASEIMG: NONZERO"

echo "== A. a SKIPPED class ⇒ RED, never a pass (silence is not evidence of zero bytes) =="
new_case; out="$(run_case "$PROBE" "ospkg baseimg langdep" 0 50000 0)"; rc=$?
ck  "an unmeasurable class blocks exit 0" "$rc" "1"
ckc "VERDICT is RED"           "$out" "VERDICT: RED"
ckc "the class says it was skipped" "$out" "CLASS_LANGDEP: SKIPPED"
ckc "and says so in words too"      "$out" "SKIPPED (no langdep asset in the fixture)"
ckn "a SKIPPED class is never reported ZERO" "$out" "CLASS_LANGDEP: ZERO"

echo "== A. a BLIND negative control ⇒ RED (a probe that cannot fail is not evidence) =="
new_case; out="$(run_case "$PROBE" "ospkg baseimg" 0 0 0)"; rc=$?
ck  "a control that saw nothing blocks exit 0" "$rc" "1"
ckc "VERDICT is RED"        "$out" "VERDICT: RED"
ckc "the control is BLIND"  "$out" "CONTROL: BLIND"
ckc "and the run says its zeros mean nothing" "$out" "its zeros mean nothing"

echo "== A. an UNAVAILABLE host half ⇒ RED (it must not pass by ignoring the half it cannot reach) =="
new_case; out="$(run_case "$PROBE" "ospkg baseimg" 0 50000 1)"; rc=$?
ck  "a FAILED host ticket blocks exit 0" "$rc" "1"
ckc "VERDICT is RED"          "$out" "VERDICT: RED"
ckc "the host half is UNAVAILABLE" "$out" "HOST: UNAVAILABLE"
ckc "and names it in words"        "$out" "host half unavailable"
ckn "an unreached half is never reported ZERO" "$out" "HOST: ZERO"

# The distinction the header insists on: "could not be reached" is not the same claim as "pulled bytes".
ckn "an unavailable host is not reported as having pulled bytes" "$out" "HOST: NONZERO"

echo "== A. a fixture that FAILED to build is ERROR, never ZERO =="
new_case; out="$(run_case "$PROBE" "ospkg" 0 50000 0 env BUMP_RC=7)"; rc=$?
ck  "a failed fixture blocks exit 0" "$rc" "1"
ckc "the class reports ERROR"  "$out" "CLASS_OSPKG: ERROR"
ckn "a failed build is never ZERO" "$out" "CLASS_OSPKG: ZERO"

echo "== A. BW_HOST=skip still blocks exit 0, and files nothing =="
new_case; out="$(run_case "$PROBE" "ospkg baseimg" 0 50000 0 env BW_HOST=skip)"; rc=$?
ck  "skipping the host half is still RED" "$rc" "1"
ckc "it discloses that it did not measure" "$out" "BW_HOST=skip"

echo "== A. residue: the probe reaps its own scratch on every path (Principle 10) =="
# The GREEN run's TMPDIR was its own; only the deliberate build log may remain there.
ck "no scratch tree survives a run" "$(ls -d "$GREEN_TMP"/bw-probe.* 2>/dev/null | wc -l | tr -d ' ')" "0"
ck "the build log is the one retained artifact" \
   "$(ls "$GREEN_TMP"/bw-probe-build.* 2>/dev/null | wc -l | tr -d ' ')" "1"

# A run killed mid-flight must leave nothing either — the trap covers INT/TERM/HUP, and requirement 6
# names them, so it is exercised rather than trusted.
SIG_TMP="$TMP/sigcase"; mkdir -p "$SIG_TMP"; printf '1000\n' > "$SIG_TMP/rx"
env BW_RX_PATH="$SIG_TMP/rx" BW_FIXTURES="$FX" BW_BUILD="$TMP/stub-build" BW_HOST=skip \
    BW_CLASSES="ospkg" BW_FLOOR_WINDOW=8 BW_FLOOR_SAMPLES=3 TMPDIR="$SIG_TMP" \
    bash "$PROBE" dev >/dev/null 2>&1 &
sigpid=$!
sleep 2
kill -TERM "$sigpid" 2>/dev/null
wait "$sigpid" 2>/dev/null; sigrc=$?
ck "SIGTERM exits 143 (the trap ran)" "$sigrc" "143"
ck "and leaves no scratch tree" "$(ls -d "$SIG_TMP"/bw-probe.* 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "== A. structural: it redirects caches, it never prunes them =="
# #322 requirement 6. The probe may point FD_DNF_CACHE at an empty dir; it must never empty, prune or
# sweep the real one, and must never defeat the caching it exists to measure with --no-cache.
ck "no --no-cache anywhere"            "$(grep -c -- '--no-cache' "$PROBE")" "0"
ck "never invokes the orphan sweeper"  "$(grep -c -- '--sweep-only' "$PROBE")" "0"
ck "no image removal verb"             "$(grep -c 'podman rmi' "$PROBE")" "0"
# Exactly one recursive removal, and it is the scratch-root teardown inside cleanup().
ck "exactly one recursive removal"     "$(grep -c 'rm -rf' "$PROBE")" "1"
ck "and it targets only its own scratch root" \
   "$(grep 'rm -rf' "$PROBE" | grep -c 'SCRATCH_ROOT')" "1"
# FD_DNF_CACHE may only ever be ASSIGNED (redirected), never handed to a removal.
ck "FD_DNF_CACHE is only ever redirected" \
   "$(grep 'FD_DNF_CACHE' "$PROBE" | grep -cE 'rm |find |prune')" "0"

echo "== A. the KV block is a stable grammar a consumer can parse =="
new_case; out="$(run_case "$PROBE" "ospkg baseimg langdep" 0 50000 0)"
for k in CLASS_OSPKG CLASS_BASEIMG CLASS_LANGDEP FLOOR CONTROL HOST VERDICT; do
    ckc "KV carries $k" "$out" "$k: "
done
# Every KV line must be `KEY: value` at column 0 — no prose leaking into the machine-readable block.
badkv="$(printf '%s' "$out" | grep -E '^(CLASS_[A-Z]+|FLOOR|CONTROL|HOST|VERDICT):' | grep -cvE '^[A-Z_]+: [A-Za-z0-9 ._-]+$')"
ck "no KV line carries prose" "$badkv" "0"

# ==== B. MUTATIONS — each gate must be what decides, not the plumbing around it =====================
# (BP8. Run in-suite, and each sed must genuinely change the copy or the row proves nothing.)
echo "== B. mutations =="

mutate(){   # mutate <name> <sed-expr> <classes> <bump-ospkg> <bump-control> <host-rc> <want-absent>
    local name="$1" expr="$2" classes="$3" bo="$4" bc="$5" hrc="$6" want="$7"
    local mut="$TMP/mutant.$RANDOM.sh" o
    cp "$PROBE" "$mut"; sed -i "$expr" "$mut"
    if cmp -s "$PROBE" "$mut"; then
        echo "  FAIL: $name — mutation was VACUOUS (the sed matched nothing), so this row proves nothing"
        fail=$((fail+1)); return
    fi
    echo "  PASS: $name — mutation genuinely changed the copy"; pass=$((pass+1))
    new_case; o="$(run_case "$mut" "$classes" "$bo" "$bc" "$hrc")"
    ckn "  ^ with it neutralized, the run no longer reports $want" "$o" "$want"
}

# 1. The SKIPPED arm is what makes an unmeasurable class block exit 0.
mutate "SKIPPED arm" "s/ABSENT)  printf 'SKIPPED'/ABSENT)  printf 'ZERO'/" \
       "ospkg baseimg langdep" 0 50000 0 "VERDICT: RED"

# 2. The control gate is what makes a blind run RED. Neutralized, a control that saw nothing passes.
mutate "control gate" "/\[ \"\$control\" = DETECTS \]/s/.*/  :/" \
       "ospkg baseimg" 0 0 0 "VERDICT: RED"

# 3. The host gate is what stops the probe passing on the half it cannot reach.
mutate "host gate" "/\[ \"\$host\" = ZERO \]/s/.*/  :/" \
       "ospkg baseimg" 0 50000 1 "VERDICT: RED"

# 4. The byte comparison itself — neutralized, a class that demonstrably pulled reads ZERO.
mutate "byte comparison" "s/if \[ \"\$b\" -le \"\$f\" \]; then printf 'ZERO'; else printf 'NONZERO'; fi/printf 'ZERO'/" \
       "ospkg baseimg" 50000 50000 0 "CLASS_OSPKG: NONZERO"

# 5. The empty-class-list guard: "nothing was measured" must never fold to a pass.
MUT5="$TMP/mutant5.sh"; cp "$PROBE" "$MUT5"
sed -i '/\[ "\$n" -gt 0 \]/s/.*/  :/' "$MUT5"
if cmp -s "$PROBE" "$MUT5"; then
    echo "  FAIL: vacuous-guard mutation was VACUOUS"; fail=$((fail+1))
else
    echo "  PASS: vacuous-guard mutation genuinely changed the copy"; pass=$((pass+1))
    # An EMPTY class list is the only configuration that reaches this guard: with even one class the
    # per-class loop already decides. (An all-SKIPPED list does NOT reach it — SKIPPED is caught by the
    # loop — which is why this row passes an empty BW_CLASSES and why the probe reads that variable
    # with `-` rather than `:-`.) The real probe must call "measured nothing" RED; the mutant is what
    # would call it GREEN, on a run in which not one byte was ever compared.
    new_case; real_out="$(run_case "$PROBE" "" 0 50000 0)"
    new_case; mut_out="$(run_case "$MUT5" "" 0 50000 0)"
    ckc "  ^ the real probe calls a measured-nothing run RED" "$real_out" "VERDICT: RED"
    ckn "  ^ neutralized, it stops calling it RED"            "$mut_out" "VERDICT: RED"
    ckc "  ^ and the mutant really does go GREEN having measured nothing" "$mut_out" "VERDICT: GREEN"
fi

# ==== CAPABILITY GUARD FOR PART C ===================================================================
# Each requirement is named for ITSELF, so the excuse is never wider than the reason. PART A/B have
# already run: a real regression above exits 1 here and is never laundered into a skip.
skip(){
    printf '\nbandwidth-probe.test.sh: %s passed, %s failed (PARTS A-B only)\n' "$pass" "$fail"
    if [ "$fail" -ne 0 ]; then
        echo "PARTS A-B FAILED — a real regression is reported, never excused as a skip"
        exit 1
    fi
    printf 'SKIP: %s PARTS A-B ran and passed.\n' "$1"
    exit 77
}

#   * an ENGINE — probe the engine, not the binary (`command -v podman` succeeding proves nothing).
podman info >/dev/null 2>&1 || skip "PART C needs a usable podman engine (podman info failed) — it runs the probe's REAL build path."

#   * a COMPLETABLE CYCLE — the requirement `podman info` does not imply, and the one a GitHub runner
#     actually fails. Measured on the runner for the sibling probe: podman info succeeds and
#     `build-throwaway.sh -c <ctx>` still exits non-zero, so guarding on the engine alone excuses nothing.
PRECTX="$TMP/prectx"; mkdir -p "$PRECTX"
printf 'FROM scratch\nCOPY payload /payload\n' > "$PRECTX/Containerfile"
printf 'bandwidth-probe preflight %s\n' "$$" > "$PRECTX/payload"
FD_STALE_MIN=525600 timeout 60 bash "$BUILDER" -c "$PRECTX" -n bw-preflight >"$TMP/pre.log" 2>&1; pre_rc=$?
[ "$pre_rc" -eq 0 ] || skip "PART C needs an engine that can COMPLETE a throwaway cycle; \`build-throwaway.sh -c <ctx>\` exited $pre_rc here — $(tail -1 "$TMP/pre.log" 2>/dev/null | tr -d '\r' | cut -c1-160)."

#   * NETWORK to the git remote — PART C's negative control performs a REAL download, which is the
#     whole point of running it. Without a reachable remote the control cannot fire and the row would
#     fail for an environmental reason, not a regression.
GITREMOTE="$(git -C "$REPO" remote get-url origin 2>/dev/null)"
[ -n "$GITREMOTE" ] && timeout 30 git ls-remote --exit-code "$GITREMOTE" HEAD >/dev/null 2>&1 \
    || skip "PART C needs a reachable git remote (its negative control performs a real download); \`git ls-remote\` to '${GITREMOTE:-<none>}' failed here."

# ==== C. THE REAL PATH — real counter, real builder, real control, nothing stubbed ==================
# The row PART A cannot give: it resolves the DEFAULT kernel counter via the default route, drives the
# REAL bin/build-throwaway.sh over the REAL repo fixtures, and fires the REAL negative control. Kept to
# the cheapest class (baseimg is served from the local layer store; ospkg's dnf step is not needed to
# prove the production wiring) so the row stays well inside the workflow's per-file bound.
echo "== C. the production path, unstubbed =="
CTMP="$TMP/realcase"; mkdir -p "$CTMP"
out="$(env BW_CLASSES="baseimg" BW_HOST=skip BW_FLOOR_WINDOW=1 BW_FLOOR_SAMPLES=2 TMPDIR="$CTMP" \
       timeout 180 bash "$PROBE" dev 2>&1)"; rc=$?

ckc "the real counter was resolved and read"  "$out" "noise floor  :"
# The pair that makes the production resolution observable: the report must NAME a kernel counter under
# /sys/class/net (resolved from the default route), and must NOT name the seam. PART A pins that this
# field really is printed and really does carry the seam when the seam is used, so this row can fail.
ckc "and the report names that REAL kernel counter" "$out" "/sys/class/net/"
ckn "it did not fall back to the test seam"   "$out" "BW_RX_PATH seam"
ckc "the real base-image class was measured"  "$out" "CLASS_BASEIMG: "
ckc "the REAL negative control fired"         "$out" "CONTROL: DETECTS"
ckc "and it names what it did to fire"        "$out" "fresh clone into an empty tree"
ck  "a dev half with a detecting control and a zero class exits 0" "$rc" "0"
ckc "VERDICT is GREEN for that class"         "$out" "VERDICT: GREEN"

# The residue claim, on the real builder rather than a stub.
ck "the real path leaves no scratch tree" "$(ls -d "$CTMP"/bw-probe.* 2>/dev/null | wc -l | tr -d ' ')" "0"
ck "and no disposable tag" \
   "$(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -c 'disposable/bw-')" "0"

echo
echo "bandwidth-probe.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
