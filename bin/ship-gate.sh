#!/usr/bin/env bash
# ship-gate.sh — R34 SPEC-VS-BUILD SHIP GATE: the independent, adversarial, whole-product review that
# must PASS before an objective may be declared shipped (R30). This is DISTINCT from and ADDITIONAL to
# the per-PR fitness check (R6): R6 grades each change; R34 grades the whole built product at ship.
#
# It reviews the BUILT PRODUCT (the repo at its current main tip = the "shipped aggregate") against the
# CONFIRMED spec, IN ORDER — (1) 00-OBJECTIVES.md, (2) 00-REQUIREMENTS.md (functional + non-functional),
# (3) 00-BUILDPRINCIPLE.md — plus 00-GOVERNANCE.md. A repo the apparatus develops FOR the maintainer
# generally ships none of those four; there the confirmed spec is the OBJECTIVE ISSUE plus the backlog
# tickets that decompose it, and the gate reads that instead. If NEITHER source yields a spec the gate
# REFUSES to review (rc 1) rather than grade a product against nothing — a gate that cannot fail is not
# a gate. The DESIGN (00-DESIGN.md) is the dev's own mutable means
# and is NOT a conformance target (deliberately excluded). The reviewer is a FRESH agent-context (a
# `claude -p` that did not build the product); the verdict LINE is shell-owned (a hallucinated reply
# cannot forge a PASS); it is posted by a DISTINCT identity (the fitness App, != the author); it is
# idempotent (bound to the aggregate sha — a new commit to main forces a fresh review); and it is
# fail-closed (no sanctioned verdict ⇒ nothing on the bus ⇒ objective-status reads not-PASS ⇒ NOT shipped).
#
#   ship-gate.sh [--post] <repo>                   review the current main aggregate; rc 0 verdict
#                                                    extracted (PASS|RETURN), 1 precondition refused,
#                                                    3 reviewer could-not-run / produced no verdict.
#   ship-gate.sh --selftest                          exercise the pure verdict extractor (no gh/model).
#
# The R30 oracle (bin/objective-status.sh) READS this verdict (a commit-comment on the exact main sha)
# and reports SHIPPED only when a PASS is bound to the current aggregate — it never RUNS the gate.
# Auto-invocation (the R30 ship ACTUATOR that runs this when the backlog empties) is a disclosed follow-on.
#
# Covered by ship-gate.test.sh. Control-plane (the ship boundary's prover). MUST be tracked 100755.
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"

# ---- PURE CORE (--selftest covers exactly this) ----------------------------------------------------
# extract_verdict — the shell-owned verdict. Reads ONLY a line that is EXACTLY `SHIP_VERDICT: PASS` or
# `SHIP_VERDICT: RETURN` (leading space tolerated, nothing else on the line). A quoted rubric line, an
# inline mention, or a `<PASS|RETURN>` placeholder yields NOTHING — a garbled/forged reply cannot PASS.
extract_verdict(){
  grep -oE '^[[:space:]]*SHIP_VERDICT:[[:space:]]*(PASS|RETURN)[[:space:]]*$' \
    | grep -oE '(PASS|RETURN)' | tail -1
}

if [ "${1:-}" = "--selftest" ]; then
  f=0
  ck(){ [ "$2" = "$3" ] && printf 'ok   %s\n' "$1" || { printf 'FAIL %s: got [%s] want [%s]\n' "$1" "$2" "$3"; f=1; }; }
  ck "plain PASS"            "$(printf 'SHIP_VERDICT: PASS\n'            | extract_verdict)" "PASS"
  ck "plain RETURN"          "$(printf 'SHIP_VERDICT: RETURN\n'          | extract_verdict)" "RETURN"
  ck "leading space"         "$(printf '   SHIP_VERDICT: PASS\n'         | extract_verdict)" "PASS"
  ck "inline not anchored"   "$(printf 'the SHIP_VERDICT: PASS now\n'    | extract_verdict)" ""
  ck "quoted rubric"         "$(printf 'SHIP_VERDICT: PASS (or RETURN)\n'| extract_verdict)" ""
  ck "placeholder"           "$(printf 'SHIP_VERDICT: <PASS|RETURN>\n'   | extract_verdict)" ""
  ck "last wins"             "$(printf 'SHIP_VERDICT: RETURN\nSHIP_VERDICT: PASS\n' | extract_verdict)" "PASS"
  ck "empty"                 "$(printf ''                                | extract_verdict)" ""
  [ "$f" = 0 ] && echo "ALL SHIP-GATE SELFTESTS PASS" || echo "SHIP-GATE SELFTESTS FAILED"; exit "$f"
fi

# ---- config -----------------------------------------------------------------------------------------
POST=0; [ "${1:-}" = "--post" ] && { POST=1; shift; }
REPO="${1:?usage: ship-gate.sh [--post] <repo>}"; shift || true
SLUG="oso-gato/$REPO"

# TOKEN FERRY FALLBACK — reuse the fitness App's ferried token (the ship-gate verdict is posted by the
# SAME independent identity the fitness reviewer uses; the key never enters the box, only the <=1h token).
if [ -z "${SHIPGATE_GH_TOKEN:-}" ] && [ -r "${FITNESS_ENV_FILE:-$HOME/.config/fitness/env}" ]; then
  _sl_pre="${SHIPGATE_LOGIN:-}"
  . "${FITNESS_ENV_FILE:-$HOME/.config/fitness/env}"
  SHIPGATE_GH_TOKEN="${SHIPGATE_GH_TOKEN:-${FITNESS_GH_TOKEN:-}}"
  [ -n "$_sl_pre" ] && SHIPGATE_LOGIN="$_sl_pre"
fi
SHIPGATE_LOGIN="${SHIPGATE_LOGIN:-oso-gato-fitness-claudebox}"   # the independent reviewer App identity
DEV_LOGIN="${DEV_LOGIN:-oso-gato-nox-claudebox}"                 # the product author identity
SHIP_CLAUDE="${SHIP_CLAUDE:-claude -p}"
SHIP_DOSSIER_CAP="${SHIP_DOSSIER_CAP:-200000}"

log(){ echo "[ship-gate] $*" >&2; }
die(){ log "$*"; exit 1; }

# R16 OPERATING SCOPE (#167): reviewing is an action on a repo — refuse an out-of-scope one first.
REPO_SCOPE="${REPO_SCOPE:-$HERE/repo-scope.sh}"
"$REPO_SCOPE" check "$REPO" \
  || die "repo '$REPO' is outside the maintainer-confirmed operating scope (R16) — refusing to ship-review"

# SEPARATION OF DUTIES — the ship-gate reviewer must NOT be the product author (author never sole judge).
# MAKE-IT-WORK: FITNESS_SAME_IDENTITY=1 drops the DISTINCT-App requirement (the review is still a fresh
# independent AGENT-CONTEXT, but posts under the dev identity). The objective-status reader mirrors this
# same-identity relaxation, so a make-it-work PASS is still read + deduped (no non-closing trap).
if [ "${FITNESS_SAME_IDENTITY:-0}" = 1 ]; then
  SHIPGATE_LOGIN="$DEV_LOGIN"                       # verdict posted + verified under the dev identity
else
  [ -n "$SHIPGATE_LOGIN" ] || die "SHIPGATE_LOGIN unset — a ship-gate verdict needs a DISTINCT reviewer identity (fail-closed)"
  [ "$SHIPGATE_LOGIN" != "$DEV_LOGIN" ] || die "SHIPGATE_LOGIN == author ($DEV_LOGIN) — self-judge is invalid (fail-closed)"
fi

# NO LOCAL CLONE IS REQUIRED. The gate used to die here unless $HOME/<repo> was a git clone, which meant
# it could never run for a repo the apparatus develops but does not keep checked out — ~/e2e-beta has
# never existed, so this line alone made the whole R34 gate unreachable for every customer repo. A
# working tree is also the WRONG source even when present: it can be stale or on another branch, and the
# gate would then grade something other than what shipped. Every product read below is pinned to
# $aggregate_sha and comes from the bus.

# ---- resolve the shipped aggregate (the current main tip) -------------------------------------------
aggregate_sha="$(gh api "repos/$SLUG/branches/main" -q .commit.sha 2>/dev/null)"
[ -n "$aggregate_sha" ] || die "cannot read $SLUG main tip (the shipped aggregate) — refusing (fail-closed)"

# ---- idempotency: the bus is the record ------------------------------------------------------------
# A sanctioned ship-gate comment already on THIS exact aggregate ⇒ reviewed; do not re-run a model.
existing="$(gh api "repos/$SLUG/commits/$aggregate_sha/comments" \
    -q ".[] | select(.user.login==\"$SHIPGATE_LOGIN\" or .user.login==\"${SHIPGATE_LOGIN}[bot]\") | .body" 2>/dev/null \
  | grep -oE '^SHIP GATE: VERDICT (PASS|RETURN) aggregate [0-9a-f]{7,40}' | tail -1)"
if [ -n "$existing" ]; then
  log "$SLUG @ ${aggregate_sha:0:7}: already ship-reviewed ($existing) — idempotent no-op"
  echo "[ship-gate] $existing"
  exit 0
fi

# ---- build the dossier (the built product + the confirmed spec) — cap LOUD (R37) -------------------
# Read the shipped aggregate from the bus, pinned to $aggregate_sha (see the note above).
r(){ gh api "repos/$SLUG/contents/$1?ref=$aggregate_sha" -q .content 2>/dev/null | base64 -d 2>/dev/null; }
manifest="$(gh api "repos/$SLUG/git/trees/$aggregate_sha?recursive=1" \
            -q '.tree[] | select(.type=="blob") | .path' 2>/dev/null)"
ledger="$(gh issue list --repo "$SLUG" --label backlog --state all --json number,title,state,url \
          -q '.[] | "#\(.number) [\(.state)] \(.title)  \(.url)"' 2>/dev/null)"
contract=""
for cf in Containerfile run.sh spin-up.sh .live-gate install.sh entrypoint.sh; do
  case "$manifest" in *"$cf"*) contract="${contract}"$'\n===== '"$cf"$' =====\n'"$(r "$cf")";; esac
done

# THE CONFIRMED SPEC. The apparatus's own repos carry the Trinity docs; a repo it develops FOR the
# maintainer generally does not — e2e-beta carries none of the four. Reading only files therefore handed
# the reviewer four EMPTY headings and asked it to grade conformance against nothing, which cannot RETURN
# for a spec violation and so would rubber-stamp anything. A gate that cannot fail is not a gate.
# So: files when the repo has them, else the objective issue + the backlog tickets that decompose it —
# which IS the confirmed spec for such a repo, and is exactly what the maintainer approved.
spec=""
for sf in 00-OBJECTIVES.md 00-REQUIREMENTS.md 00-BUILDPRINCIPLE.md 00-GOVERNANCE.md; do
  case "$manifest" in *"$sf"*) spec="${spec}"$'\n===== '"$sf"$' =====\n'"$(r "$sf")";; esac
done
if [ -z "${spec//[[:space:]]/}" ]; then
  log "$SLUG ships no Trinity spec docs — sourcing the confirmed spec from the objective issue + backlog"
  spec="$(gh issue list --repo "$SLUG" --state all --search 'OBJECTIVE in:title' \
          --json number,title,body -q '.[] | "===== OBJECTIVE ISSUE #\(.number): \(.title) =====\n\(.body)"' 2>/dev/null)"
  spec="${spec}"$'\n'"$(gh issue list --repo "$SLUG" --label backlog --state all \
          --json number,title,state,body \
          -q '.[] | "===== BACKLOG #\(.number) [\(.state)]: \(.title) =====\n\(.body)"' 2>/dev/null)"
fi
# FAIL-CLOSED: no spec, no gate. An unreadable or genuinely-absent spec must stop the review, never
# produce a PASS the reviewer had no basis to give.
[ -n "${spec//[[:space:]]/}" ] \
  || die "no confirmed spec found for $SLUG (no Trinity docs, no objective issue, no backlog) — refusing to ship-review against an empty spec (fail-closed)"

dossier="# THE CONFIRMED SPEC — grade the product against THIS, in the order given
$spec

NOTE: 00-DESIGN.md is the dev's own MUTABLE MEANS and is NOT a conformance target — do NOT grade against it.

# BUILT PRODUCT — aggregate $aggregate_sha
## file manifest
$manifest
## deploy-contract / entry files
$contract

# SHIPPED-FEATURE LEDGER (closed backlog issues = proven-shipped features + proof links)
$ledger"

trunc_note=""
if [ "${#dossier}" -gt "$SHIP_DOSSIER_CAP" ]; then
  log "dossier ${#dossier} bytes > SHIP_DOSSIER_CAP=$SHIP_DOSSIER_CAP — TRUNCATING (the reviewer is told, and told to RETURN if the hidden part could decide it)"
  trunc_note=" Judged a **TRUNCATED** dossier — first $SHIP_DOSSIER_CAP of ${#dossier} bytes."
  dossier="${dossier:0:$SHIP_DOSSIER_CAP}"$'\n\n[DOSSIER TRUNCATED: you see the first '"$SHIP_DOSSIER_CAP"$' bytes. If what is hidden could change the judgment, RETURN rather than PASS.]'
fi

read -r -d '' PROMPT <<PROMPT_EOF || true
You are an INDEPENDENT, ADVERSARIAL spec-vs-build SHIP reviewer for the oso-gato apparatus. You did NOT
build this product and have NO stake in it shipping. Your job is the R34 whole-product gate: verify the
BUILT PRODUCT conforms, IN ORDER, to (1) the confirmed OBJECTIVE, (2) the functional + non-functional
REQUIREMENTS (R1-R38), (3) the BUILD PRINCIPLES (BP1-BP6). The design (00-DESIGN.md) is the dev's mutable
means and is NOT a conformance target — do not grade against it. Be critical and architecture-aware.

PASS only if the WHOLE product conforms. RETURN if ANY requirement or build principle is violated — name
the specific requirement/principle and the violation. Apply the GOVERNANCE MVP-first severity ruling: a
non-blocking polish gap is a NOTE, not a RETURN; RETURN for a genuine (a) INCORRECT / (b) UNSAFE / (c)
UNTRUE conformance failure of the shipped aggregate.

Think first, then end your reply with EXACTLY ONE line, nothing after it:
SHIP_VERDICT: <PASS or RETURN>

===== DOSSIER =====
$dossier
PROMPT_EOF

log "ship-reviewing $SLUG @ ${aggregate_sha:0:7} (reviewer=$SHIPGATE_LOGIN, prompt ${#PROMPT} bytes)…"

# ---- run the reviewer: prompt on STDIN, reviewer's own rc (pipefail off in the subshell) -----------
errf="$(mktemp -t shipgate-stderr.XXXXXX)" || die "cannot create a temp file for the reviewer's stderr"
trap 'rm -f "$errf"' EXIT
review="$(set +o pipefail; printf '%s' "$PROMPT" | $SHIP_CLAUDE 2>"$errf")"; rc=$?
rerr="$(tail -c 1500 "$errf" 2>/dev/null)"
if [ "$rc" -ne 0 ]; then
  log "reviewer FAILED TO RUN: '$SHIP_CLAUDE' exited $rc — never judged $SLUG @ ${aggregate_sha:0:7}. INFRASTRUCTURE failure, not a verdict."
  [ -n "$rerr" ] && log "  reviewer stderr: $rerr"
  log "posting nothing (fail-closed); objective stays NOT-shipped. rc 3 — caller retries bounded + surfaces."
  exit 3
fi
verdict="$(printf '%s' "$review" | extract_verdict)"
if [ -z "$verdict" ]; then
  log "reviewer produced ${#review} bytes but NO sanctioned SHIP_VERDICT line — not a usable judgment (fail-closed)."
  [ -n "$rerr" ] && log "  reviewer stderr: $rerr"
  exit 3
fi
rationale="$(printf '%s' "$review" | grep -vE '^[[:space:]]*SHIP_VERDICT:' | sed -e 's/[[:space:]]*$//')"

# ---- compose the canonical shell-owned verdict (ASCII line 1; the reader anchors on it) ------------
comment="SHIP GATE: VERDICT $verdict aggregate $aggregate_sha

<sub>R34 independent spec-vs-build ship gate — reviewer \`$SHIPGATE_LOGIN\`, aggregate \`${aggregate_sha:0:7}\`.$trunc_note Ordered objective -> requirements -> build-principles (00-DESIGN.md excluded). Machine-read by \`bin/objective-status.sh\` from LINE 1 ONLY (verdict + FULL aggregate sha).</sub>

<details><summary>rationale</summary>

$rationale
</details>"

echo "[ship-gate] $SLUG @ ${aggregate_sha:0:7} — VERDICT $verdict"
if [ "$POST" != 1 ]; then
  echo "----- DRY-RUN (would post a commit-comment as $SHIPGATE_LOGIN; pass --post) -----"
  printf '%s\n' "$comment"
  exit 0
fi

# ---- post the verdict as a COMMIT COMMENT bound to the exact aggregate sha --------------------------
post_body="$(mktemp)"; printf '%s' "$comment" > "$post_body"; trap 'rm -f "$errf" "$post_body"' EXIT
if [ "${FITNESS_SAME_IDENTITY:-0}" = 1 ]; then
  gh api --method POST "repos/$SLUG/commits/$aggregate_sha/comments" -F body=@"$post_body" >/dev/null 2>&1 \
    && { echo "[ship-gate] posted VERDICT $verdict on $SLUG @ ${aggregate_sha:0:7} as $SHIPGATE_LOGIN (same-identity)"; exit 0; } \
    || die "failed to post ship-gate commit-comment (fail-closed)"
fi
[ -n "${SHIPGATE_GH_TOKEN:-}" ] || die "--post needs SHIPGATE_GH_TOKEN (the fitness App token) to post AS $SHIPGATE_LOGIN (fail-closed)"
GH_TOKEN="$SHIPGATE_GH_TOKEN" gh api --method POST "repos/$SLUG/commits/$aggregate_sha/comments" -F body=@"$post_body" >/dev/null 2>&1 \
  && { echo "[ship-gate] posted VERDICT $verdict on $SLUG @ ${aggregate_sha:0:7} as $SHIPGATE_LOGIN"; exit 0; } \
  || die "failed to post ship-gate commit-comment (fail-closed)"
