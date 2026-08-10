#!/usr/bin/env bash
# immutability-probe.test.sh — proves bin/immutability-probe.sh MEASURES residue rather than asserting
# its absence (fedora-dev#313, feat-02 of objective #310) AND that it exits 0 ONLY when BOTH boxes
# measured zero residue (fedora-dev#316, feat-05 — the change that makes the objective's acceptance
# command mean what it says).
#
# THE AXIS UNDER TEST is the one a --selftest is structurally blind to: a probe whose comparison is
# broken prints GREEN on a box carrying residue, and a green pure-core fold cannot tell you that. So the
# engine rows drive the REAL probe against a REAL throwaway build, and the RED rows INJECT a leak and
# demand the probe both FAIL and NAME the survivor. The MUTATION rows then neutralize the deciding
# expression and require the RED case to stop being RED — proving the comparison (and, for #316, the
# CONJUNCTION) is what decides, not the plumbing.
#
# WHAT IS STUBBED, AND WHAT DELIBERATELY IS NOT. The SUBJECT is the probe's measurement + fold logic; the
# thing MEASURED is the builder (dev half) and the host (host half). So the leak rows stand in a
# deliberately BROKEN builder (one whose teardown never runs) — that is the defect being detected, and it
# cannot be produced by the real builder without editing it, which #313 forbids. The healthy row uses the
# REAL builder AND the REAL witness resolved by their DEFAULT paths, so the production resolution every
# other row overrides is still executed here. The HOST rows stub the BUS (a fake host-ticket.sh + a fake
# gh + a fake repo-scope.sh) because the host half's whole job is to drive that bus and fold what comes
# back: with no host on the other end, the bus outcome IS the input under test. Every host row is
# OFFLINE.
#
# THE PARTS, AND WHY THE GUARD IS SHAPED THIS WAY:
#   PARTS A/E/F need nothing but bash: the probe's pure contract through the CLI, the MECHANICAL no-tidy
#             and no-host-op scans, the whole #316 host-bus mapping table over the fake bus, and the
#             conjunction mutation. They run EVERYWHERE, so a genuine regression in any of them still
#             exits 1 on a host that cannot run the rest. They are placed BEFORE the capability guard
#             for exactly that reason (the residue-witness.test.sh pattern).
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
#   bash immutability-probe.test.sh  -> exit 0 = all rows pass · 77 = PARTS B-D unrunnable here (the
#                                       offline parts ran and passed) · 1 = a real failure, never
#                                       excused as a skip.
# No GitHub, no network, no model; builds are local-only and offline. Run after touching the probe or
# its host fold.
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
# THE HAYSTACK IS NEVER PIPED, AND THAT IS A CORRECTNESS FIX, NOT A STYLE ONE. `printf … | grep -q`
# looks equivalent and is not: `grep -q` exits AT the match, so if the writer has not finished by then it
# takes SIGPIPE, and the `set -o pipefail` above makes the whole pipeline rc 141 even though the string
# is PRESENT. Whether the writer finishes first is a RACE — the structural rows below feed the WHOLE
# probe (~47KB, match at ~byte 10k) through these helpers, which is small enough to fit the 64KB pipe
# buffer but large enough that stdio splits it across a dozen writes, so it comes down to scheduling.
#
# THE EVIDENCE, and it is deliberately not mine alone: the fitness reviewer of the previous head
# reproduced it on this file's own rows — 21 BAD of 40 runs of ONE such row, two back-to-back full-suite
# runs scoring 82/0 then 81/1, and 1 of 8 offline-only runs exiting 1 instead of 77. Re-measured HERE on
# an idle devbox the piped form scored 0 of 40, which is the point rather than a rebuttal: this is a
# defect that passes locally and reds the gate under load, and tests.yml fails the job on any rc but 0
# or 77, so it would be an intermittently red gate on EVERY fedora-dev PR. In ckc it mis-scores a PASS
# as a FAIL; in ckn — worse — it would score a real hit as a silent PASS.
#
# A here-string has no pipe and no writer to kill, so the failure mode is structurally ABSENT rather than
# made less likely, and the rc can only ever be grep's own answer about the haystack.
ckc(){ if grep -qF "$3" <<<"$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (output did not contain [$3])"; fail=$((fail+1)); fi; }
ckn(){ if grep -qF "$3" <<<"$2"; then echo "  FAIL: $1 (output wrongly contained [$3])"; fail=$((fail+1)); else echo "  PASS: $1"; pass=$((pass+1)); fi; }

# A tiny, fully OFFLINE build context: `FROM scratch` + a COPY. It pulls nothing and runs no RUN step,
# so the healthy row is a real build-and-teardown cycle that costs about a second. (Plain files — no
# engine — so the guard below can use it as the context of its own pre-flight cycle.)
CTX="$TMP/ctx"; mkdir -p "$CTX"
printf 'FROM scratch\nCOPY payload /payload\n' > "$CTX/Containerfile"
echo "immutability-probe test payload" > "$CTX/payload"

run_probe(){ timeout 240 bash "$@" 2>/dev/null; }

# ---- the BUS fakes (host half, #316) ----------------------------------------------------------------
# Three seams, each defaulted to production in the probe and driven here by env. NO network anywhere.

# host-ticket.sh: prints the ticket URL on STDOUT (the probe's proof it was FILED) and exits with the
# bus outcome (0 DONE / 1 FAILED / 2 timeout). FAKE_TICKET_URL unset = "could not file at all".
cat > "$TMP/fake-host-ticket.sh" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_TICKET_STDERR:-}" ] && printf '%s\n' "$FAKE_TICKET_STDERR" >&2
[ -n "${FAKE_TICKET_URL:-}" ] && printf '%s\n' "$FAKE_TICKET_URL"
exit "${FAKE_TICKET_RC:-0}"
EOF

# gh: serves ONLY the probe's read-only comment fetch. The EMPTY-comment case is its own mapping row
# below, and what gives that row its bite is that it SETS the variable explicitly — not the parameter
# form: with an empty default `${FAKE_COMMENT-}` and `${FAKE_COMMENT:-}` are identical, so claiming the
# `-` is load-bearing here would be a rationale for nothing (it is load-bearing in reconcile.test.sh,
# whose defaults are NON-empty; that is the distinction).
cat > "$TMP/fake-gh" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${FAKE_COMMENT-}"
EOF

# repo-scope.sh: the R16 gate. rc 0 = in scope (the default), non-zero = refused/unreadable.
cat > "$TMP/fake-repo-scope.sh" <<'EOF'
#!/usr/bin/env bash
exit "${FAKE_SCOPE_RC:-0}"
EOF
chmod +x "$TMP/fake-host-ticket.sh" "$TMP/fake-gh" "$TMP/fake-repo-scope.sh"

TICKET_URL="https://github.com/oso-gato/fedora-bootstrap/issues/4242"

# Drive the REAL probe's host half over the fake bus. Every host row goes through this, so no row can
# accidentally reach the real producer, the real gh, or the network.
host_probe(){
    IMMUT_PROBE_HOST_TICKET="$TMP/fake-host-ticket.sh" \
    IMMUT_PROBE_GH="$TMP/fake-gh" \
    IMMUT_PROBE_REPO_SCOPE="$TMP/fake-repo-scope.sh" \
    "$@" timeout 60 bash "$PROBE" host 2>&1
}

# ==== A. PURE / STRUCTURAL — no engine, no build, no bus. RUNS EVERYWHERE ===========================
echo "== A. pure contract =="

out="$(bash "$PROBE" --selftest 2>&1)"; rc=$?
ck "--selftest exits 0" "$rc" "0"
ckc "--selftest actually ran its rows" "$out" "immutability-probe selftest:"
# the selftest must actually cover the host fold, not just the feat-02 core it started as
ckc "--selftest covers the #316 mapping table" "$out" "host_fold"

out="$(bash "$PROBE" bogus-verb 2>&1)"; rc=$?
ck "an unknown verb is a harness error (rc 2)" "$rc" "2"

# IT MEASURES, IT DOES NOT TIDY. The probe's contract forbids reaping between a cycle and its AFTER
# snapshot; a sweep verb appearing in this file is the whole feature quietly inverted. `rm -f` on its
# own scratch snapshots is allowed and is the only removal it may hold.
ck "probe holds no image-removal verb"  "$(grep -c 'podman rmi' "$PROBE")" "0"
ck "probe holds no recursive removal"   "$(grep -c 'rm -rf' "$PROBE")" "0"
ck "probe never invokes the sweeper"    "$(grep -c -- '--sweep-only' "$PROBE")" "0"

# THE NON-GOAL, PINNED (#316): the host half is dev-DRIVEN and host-EXECUTED. A fallback that reached
# out and measured the host FROM HERE would be the dev box performing a host operation — the one thing
# the ticket bus exists to prevent — and a nested-engine reading of a different engine is not evidence
# about the host anyway. Scanned on CODE ONLY (comments blanked) so the sentence explaining the rule
# cannot trip the rule.
probe_code="$(sed 's/^[[:space:]]*#.*$//' "$PROBE")"
ck "no ssh fallback to the host"      "$(grep -cE '\bssh\b' <<<"$probe_code")" "0"
ck "no remote podman fallback"        "$(grep -c 'CONTAINER_HOST' <<<"$probe_code")" "0"
# and the production seams really do default to the siblings (every host row below overrides them)
probe_src="$(cat "$PROBE")"
ckc "host-ticket defaults to the sibling producer" "$probe_src" 'IMMUT_PROBE_HOST_TICKET:-$HERE/host-ticket.sh'
ckc "the scope reader defaults to the sibling"     "$probe_src" 'IMMUT_PROBE_REPO_SCOPE:-$HERE/repo-scope.sh'

# ==== E. THE HOST HALF — every row of the #316 mapping table, over a FAKE bus ========================
# The table this asserts (host-ticket result → host half → overall):
#   DONE + GREEN fresh              → GREEN   → rc 0
#   DONE + GREEN cached, in bound   → GREEN   → rc 0 (disclosed `cached`)
#   DONE + GREEN cached, past bound → STAGED  → rc 3
#   FAILED + residue lines          → RED     → rc 1 (survivors echoed)
#   FAILED + unsupported host-op    → STAGED  → rc 3 (BP7 pre-deploy, NOT an alarm)
#   FAILED + a staged reason        → STAGED  → rc 3
#   timeout / no verdict / empty    → STAGED  → rc 3
#   could not file / scope refused  → STAGED  → rc 3
echo "== E. the host half over the ticket bus =="

out="$(FAKE_TICKET_RC=0 FAKE_TICKET_URL="$TICKET_URL" \
       FAKE_COMMENT='**host-agent: DONE** — probe ran
immutability-probe: GREEN — zero residue on erebus' host_probe env)"; rc=$?
ck "DONE + a fresh GREEN verdict → rc 0" "$rc" "0"
ck "line 1 reports the host GREEN" "$(printf '%s' "$out" | head -1)" "immutability-probe: GREEN host=GREEN"
ckc "the verdict's PROVENANCE is printed (the ticket URL)" "$out" "$TICKET_URL"
ckc "and its freshness is stated" "$out" "verdict FRESH"

out="$(FAKE_TICKET_RC=0 FAKE_TICKET_URL="$TICKET_URL" \
       FAKE_COMMENT='immutability-probe: GREEN cached (3600)' host_probe env)"; rc=$?
ck "DONE + a cached GREEN inside the age bound → rc 0" "$rc" "0"
ckc "the cache is DISCLOSED, never silent" "$out" "CACHED (3600s old, within the 86400s bound)"

# NAMED ASSERTION (#316 acceptance): a stale cached verdict is rc 3, never rc 0.
out="$(FAKE_TICKET_RC=0 FAKE_TICKET_URL="$TICKET_URL" \
       FAKE_COMMENT='immutability-probe: GREEN cached (90000)' host_probe env)"; rc=$?
ck "a STALE cached verdict → rc 3 (NOT rc 0)" "$rc" "3"
ckc "line 1 stages the host half" "$(printf '%s' "$out" | head -1)" "host=STAGED"
ckc "and says why it is not current proof" "$out" "STALE"
ckn "a stale verdict is never reported GREEN" "$out" "host=GREEN"

# a tighter bound makes a formerly-fresh cached verdict stale — the bound is what decides, not the text
out="$(FAKE_TICKET_RC=0 FAKE_TICKET_URL="$TICKET_URL" IMMUT_HOST_MAX_AGE=60 \
       FAKE_COMMENT='immutability-probe: GREEN cached (3600)' host_probe env)"; rc=$?
ck "IMMUT_HOST_MAX_AGE is what ages a cached verdict" "$rc" "3"

# NAMED ASSERTION (#316 acceptance): a host RED is rc 1 AND echoes the residue lines.
out="$(FAKE_TICKET_RC=1 FAKE_TICKET_URL="$TICKET_URL" \
       FAKE_COMMENT='**host-agent: FAILED** — residue survived
RESIDUE tree /home/core/.cache/fd-throwaway.hostleak
RESIDUE image deadbeef localhost/disposable/x:val-9' host_probe env)"; rc=$?
ck "FAILED carrying residue lines → rc 1 (a MEASURED red)" "$rc" "1"
ck "line 1 reports the host RED" "$(printf '%s' "$out" | head -1)" "immutability-probe: RED host=RED"
ckc "the host's survivors are echoed dev-side (tree)"  "$out" "RESIDUE tree /home/core/.cache/fd-throwaway.hostleak"
ckc "the host's survivors are echoed dev-side (image)" "$out" "RESIDUE image deadbeef"

# NAMED ASSERTION (#316 acceptance): an unsupported verb is rc 3, never rc 0, and never an alarm.
out="$(FAKE_TICKET_RC=1 FAKE_TICKET_URL="$TICKET_URL" \
       FAKE_COMMENT='**host-agent: FAILED** — unsupported host-op: immutability-probe' host_probe env)"; rc=$?
ck "an UNSUPPORTED host-op → rc 3 (NOT rc 0)" "$rc" "3"
ckn "…and NOT rc 1 — an undeployed consumer is not a residue failure" "$rc" "1"
ckc "it names the pre-deploy state rather than crying wolf" "$out" "not deployed"
ckc "and marks it the expected state, not an alarm" "$out" "not an alarm"
ckn "an unmeasured host half is never GREEN" "$out" "host=GREEN"

out="$(FAKE_TICKET_RC=1 FAKE_TICKET_URL="$TICKET_URL" \
       FAKE_COMMENT='**host-agent: FAILED** — the workload was busy, deferred' host_probe env)"; rc=$?
ck "FAILED with a staged reason → rc 3" "$rc" "3"
ckc "and it says the op failed without measuring" "$out" "FAILED without reporting a measurement"

# NAMED ASSERTION (#316 acceptance): a timeout is rc 3, never rc 0.
out="$(FAKE_TICKET_RC=2 FAKE_TICKET_URL="$TICKET_URL" FAKE_COMMENT='' host_probe env)"; rc=$?
ck "a bus TIMEOUT → rc 3 (NOT rc 0)" "$rc" "3"
ckc "the timeout path is explicit, so a caller can never hang" "$out" "no host verdict within"
ckn "a timeout is never GREEN" "$out" "host=GREEN"

out="$(FAKE_TICKET_RC=0 FAKE_TICKET_URL="$TICKET_URL" FAKE_COMMENT='' host_probe env)"; rc=$?
ck "DONE but an EMPTY comment → rc 3" "$rc" "3"
ckc "…and it says the verdict was unparseable" "$out" "no parseable"

out="$(FAKE_TICKET_RC=0 FAKE_TICKET_URL="$TICKET_URL" \
       FAKE_COMMENT='**host-agent: DONE** — did a thing' host_probe env)"; rc=$?
ck "DONE with NO verdict header → rc 3" "$rc" "3"
ckn "an absent verdict is never invented as GREEN" "$out" "host=GREEN"

# rc 1 with NO ticket URL is host-ticket's own `die` — could not file. It must NOT read as a host FAILED.
out="$(FAKE_TICKET_RC=1 FAKE_TICKET_STDERR='host-ticket: gh issue create failed' host_probe env)"; rc=$?
ck "could not FILE (no bus/credential) → rc 3, not a measured RED" "$rc" "3"
ckc "it says nothing was measured" "$out" "nothing was measured"
ckn "an unfiled ticket is never a host RED" "$out" "host=RED"

out="$(FAKE_SCOPE_RC=1 FAKE_TICKET_RC=0 FAKE_TICKET_URL="$TICKET_URL" \
       FAKE_COMMENT='immutability-probe: GREEN' host_probe env)"; rc=$?
ck "an R16 scope refusal → rc 3, fail-closed BEFORE filing" "$rc" "3"
ckc "and it says so in one loud line" "$out" "R16 SCOPE"
ckn "a scope-refused run never reports GREEN" "$out" "host=GREEN"

# a missing producer is the same class as an unfiled ticket — STAGED, never a verdict
out="$(IMMUT_PROBE_HOST_TICKET="$TMP/does-not-exist.sh" IMMUT_PROBE_GH="$TMP/fake-gh" \
       IMMUT_PROBE_REPO_SCOPE="$TMP/fake-repo-scope.sh" timeout 60 bash "$PROBE" host 2>&1)"; rc=$?
ck "a MISSING ticket producer → rc 3" "$rc" "3"
ckn "…and never GREEN" "$out" "host=GREEN"

# ==== F. MUTATION — the AND is what decides, not the dev half alone ==================================
# (#316 acceptance, BP8. Offline: the probe returns early when SOURCED, exposing report() and the two
# half-verdict globals, so the CONJUNCTION can be driven directly with no engine and no bus.)
echo "== F. mutation: rc 0 requires BOTH halves =="

both(){ ( . "$PROBE"; DEV_VERDICT="$1"; HOST_VERDICT="$2"; HOST_REPORT="host: $2"; report all ); }

out="$(both GREEN GREEN)"; rc=$?
ck "dev GREEN + host GREEN → rc 0" "$rc" "0"
ck "line 1 names both halves" "$(printf '%s' "$out" | head -1)" "immutability-probe: GREEN dev=GREEN host=GREEN"

out="$(both GREEN RED)"; rc_conj=$?
ck "dev GREEN + host RED → rc 1 (the dev half alone cannot pass it)" "$rc_conj" "1"
out="$(both GREEN STAGED)"; rc=$?
ck "dev GREEN + host STAGED → rc 3" "$rc" "3"

MUT2="$TMP/mutant-conjunction.sh"
cp "$PROBE" "$MUT2"
sed -i 's/overall_verdict "$DEV_VERDICT" "$HOST_VERDICT"/overall_verdict "$DEV_VERDICT"/' "$MUT2"
if cmp -s "$PROBE" "$MUT2"; then
    echo "  FAIL: conjunction mutation was VACUOUS — the sed matched nothing, so this row proves nothing"
    fail=$((fail+1))
else
    echo "  PASS: mutation genuinely dropped the host half from the overall fold"
    pass=$((pass+1))
    mout="$( ( . "$MUT2"; DEV_VERDICT=GREEN; HOST_VERDICT=RED; HOST_REPORT="host: RED"; report all ) )"; mrc=$?
    if [ "$mrc" != "$rc_conj" ]; then
        echo "  PASS: with the conjunction neutralized a host RED stops failing the probe ($mrc vs $rc_conj)"; pass=$((pass+1))
    else
        echo "  FAIL: the mutant exits exactly as the real probe does — the AND decides nothing"; fail=$((fail+1))
    fi
    ck "the mutant wrongly reports GREEN overall" "$(printf '%s' "$mout" | head -1 | cut -d' ' -f2)" "GREEN"
fi

# ==== CAPABILITY GUARD FOR PARTS B-D ================================================================
# Each requirement is named for ITSELF, so the excuse can never be wider than the reason for it. The
# OFFLINE parts (A/E/F) have already run: a real regression above exits 1 here and is never laundered
# into a skip.
skip(){
    printf '\nimmutability-probe.test.sh: %s passed, %s failed (offline parts A/E/F only)\n' "$pass" "$fail"
    if [ "$fail" -ne 0 ]; then
        echo "FAILED in the offline parts — a real regression is reported, never excused as a skip"
        exit 1
    fi
    printf 'SKIP: %s The offline parts A/E/F ran and passed.\n' "$1"
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
# A stand-in builder that does NOTHING — the cheap dev half for the conjunction row in B2, where the
# subject is the HOST verdict's effect on the fold and a second 15s real cycle would buy nothing.
cat > "$TMP/noop-build.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/leaky-image-build.sh" "$TMP/leaky-image-unique-build.sh" "$TMP/leaky-tree-build.sh" "$TMP/noop-build.sh"

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

# ==== B2. THE OBJECTIVE'S ACCEPTANCE COMMAND — both halves, end to end ===============================
# The dev half is REAL (real builder, real witness, real engine); the HOST half is real code driven over
# the fake bus, because feat-04 (#315) is not deployed to erebus yet. This is the acceptance command's
# SHAPE proven end to end — the live run against a deployed host consumer is what feat-04 unlocks.
echo "== B2. rc 0 when BOTH halves measure zero residue =="

out="$(IMMUT_PROBE_CTX="$CTX" IMMUT_PROBE_KILL_WAIT=60 \
       IMMUT_PROBE_HOST_TICKET="$TMP/fake-host-ticket.sh" IMMUT_PROBE_GH="$TMP/fake-gh" \
       IMMUT_PROBE_REPO_SCOPE="$TMP/fake-repo-scope.sh" \
       FAKE_TICKET_RC=0 FAKE_TICKET_URL="$TICKET_URL" \
       FAKE_COMMENT='immutability-probe: GREEN — zero residue on erebus' \
       run_probe "$PROBE")"; rc=$?
ck "both halves GREEN → rc 0" "$rc" "0"
ck "line 1 is the objective's acceptance line" "$(printf '%s' "$out" | head -1)" \
   "immutability-probe: GREEN dev=GREEN host=GREEN"
ckc "the host verdict's provenance is printed" "$out" "$TICKET_URL"

# …and a RED host must fail the run through that SAME dispatch. This row uses a CHEAP no-op stand-in
# builder rather than a second real cycle: a real-builder run costs ~15s and the row above already
# proves the dispatch reaches host_half, while part F pins the exact GREEN+RED fold. What is left to
# prove here is only that a host RED survives the real `all` path — which a no-op dev half shows just as
# well (it yields dev=PARTIAL, so the RED can have come from nowhere but the host).
out="$(IMMUT_PROBE_CTX="$CTX" IMMUT_PROBE_BUILD="$TMP/noop-build.sh" IMMUT_PROBE_KILL_WAIT=5 \
       IMMUT_PROBE_HOST_TICKET="$TMP/fake-host-ticket.sh" IMMUT_PROBE_GH="$TMP/fake-gh" \
       IMMUT_PROBE_REPO_SCOPE="$TMP/fake-repo-scope.sh" \
       FAKE_TICKET_RC=1 FAKE_TICKET_URL="$TICKET_URL" \
       FAKE_COMMENT='RESIDUE tree /home/core/.cache/fd-throwaway.hostleak' \
       run_probe "$PROBE")"; rc=$?
ck "a RED host fails the whole probe → rc 1" "$rc" "1"
ckc "line 1 keeps both halves legible" "$(printf '%s' "$out" | head -1)" "immutability-probe: RED dev=PARTIAL host=RED"
ckc "the host's survivor is named in the dev-side output" "$out" "RESIDUE tree /home/core/.cache/fd-throwaway.hostleak"

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
