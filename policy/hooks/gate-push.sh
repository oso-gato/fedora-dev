#!/usr/bin/env bash
# fedora-dev — PROMOTION-GATE PreToolUse hook  (Bash matcher)
# ============================================================================
# Stamped into the claudebox at /etc/claude-code/hooks/gate-push.sh by
# claudebox-assemble.sh, alongside managed-settings.json which wires it as a
# MANAGED PreToolUse hook on the Bash tool. Because it is a *managed* hook and
# the box runs with `allowManagedHooksOnly: true`, the agent cannot remove,
# shadow, or disable it from project/user settings.
#
# JOB (see policy/CLAUDE.md "THE PROMOTION GATE → MECHANICAL ENFORCEMENT"):
#   A blocking hook is the BUILT backstop behind the clickable promotion gate.
#   It routes any push/merge that could mutate the remote `main` (or merge a
#   PR) to an interactive ASK that only Arthur can answer in-session, while
#   letting routine FEATURE-BRANCH work run autonomously. It overrides even an
#   allow permission rule (a blocking hook fires regardless of the permission
#   verdict), so a pre-allowlisted command cannot walk around it.
#
# REFSPEC-AWARE PROMOTION GATE (the discriminator):
#   `git push` is NOT blanket-blocked. A push is treated as SAFE (falls through
#   silently → the agent pushes autonomously) IFF it carries at least one
#   EXPLICIT refspec after the remote AND every DESTINATION ref is an explicit
#   non-`main`, non-`HEAD`, non-tag branch. Anything that could land on `main`
#   — `main` / `refs/heads/main` as a destination, a `HEAD`/HEAD-relative
#   destination (ambiguous default), a `refs/tags/*` destination, a bare
#   `git push` / `git push <remote>` with NO refspec (default-branch push),
#   `--all` / `--mirror` / `--tags` whole-repo pushes, or anything the parser
#   cannot confidently decompose — is UNSAFE → ASK. FAIL CLOSED: any ambiguity
#   resolves toward ASK. The merge verbs (gh pr merge / gh pr create --merge|
#   --squash|--rebase|--auto / gh api …merge…) ALWAYS ASK — never refspec-parsed.
#
# FAIL CLOSED — the load-bearing property. Claude Code does NOT bundle `jq`, and
#   the docs say a hook that errors on a missing tool FAILS OPEN (non-zero exit
#   other than 2 → tool proceeds). So this hook must NOT depend on jq for its
#   decision: it isolates the candidate command from the raw stdin payload with
#   pure bash parameter expansion (jq is only an optional fast-path). The SAFE
#   refspec relaxation is attempted ONLY when the command was CLEANLY isolated;
#   if isolation is uncertain, any detected push/merge resolves to ASK. The deny
#   verdict (kept for any future hard-deny) is a hand-written JSON string AND
#   exit 2, neither of which needs jq.
#
# WHY exit 2 AND structured deny JSON: per the Claude Code hook contract, exit 2
#   is the unconditional hard-stop (stderr shown to Claude, tool blocked, JSON
#   ignored). We ALSO print a `permissionDecision: "deny"` block so the reason
#   renders cleanly on harnesses that parse stdout first. Either path blocks.
#   The ACTIVE verdict for a flagged push/merge is `ask` (defer to Arthur); the
#   exit-2 `deny` path is retained for any hard-deny a future rule may add.
#
# SCOPE — what is routed to ASK (any of these in the candidate Bash command):
#   * git push that targets `main` / HEAD / a tag / no-explicit-refspec / whole-
#     repo (--all/--mirror/--tags), or that cannot be parsed   (see refspec rule)
#   * gh pr merge                      (merging a PR)
#   * gh pr create ... --merge|--squash|--rebase|--auto  (auto-merge on create)
#   * gh api .../merges  | .../merge   (REST/GraphQL merge: PR & branch merge)
#   * a wrapper invocation (`bash X` / `sh X` / `source X` / `. X`) whose target
#     SCRIPT CONTAINS any push or merge verb — so a push can't hide inside a
#     one-off script to dodge the matcher. WRAPPER CONTENTS ARE FAIL-CLOSED:
#     ANY `git push` (of any kind) OR merge verb inside a scanned script → ASK.
#     Script contents are deliberately NOT refspec-parsed (a script is opaque
#     control flow; refspec-relaxing it would be unsound) — so a feature push
#     issued directly is autonomous, but the same push hidden in a wrapper asks.
#
# APPROVAL = a per-action interactive ASK, answered by Arthur in THIS session.
#   On a flagged push/merge the hook returns permissionDecision:"ask" → Claude
#   Code shows Arthur a discrete clickable allow/deny for THAT exact command, in
#   the fedora-dev session, and proceeds only on his click. The agent CANNOT
#   answer its own prompt: managed-settings.json sets disableBypassPermissionsMode
#   + allowManagedPermissionRulesOnly + allowManagedHooksOnly, so no bypass /
#   self-added allow-rule / self-registered hook can satisfy it.
#
# RESIDUAL CEILING (no in-box hook closes this — documented, not papered over):
#   PreToolUse hooks do NOT fire under `claude -p` (headless) — anthropics/claude-code
#   #40506 — so a maliciously-injected agent that spawns `claude -p` bypasses THIS hook.
#   Hard containment of a HOSTILE in-box agent is Arthur's in-session click + managed-settings
#   (allowManagedHooksOnly + allowManagedPermissionRulesOnly + disableBypassPermissionsMode);
#   server-side branch protection is intentionally NOT enabled for this single-operator fleet.
#   This gate stops the realistic case: the agent merging to `main` without Arthur's explicit
#   in-session click, while keeping feature-branch pushes autonomous.
# ============================================================================
set -uo pipefail

# ----------------------------------------------------------------------------
# read the hook stdin payload (raw text — NO jq dependency)
# ----------------------------------------------------------------------------
payload="$(cat 2>/dev/null || true)"

# Empty payload → nothing to gate; fall through.
[ -n "$payload" ] || exit 0

# ----------------------------------------------------------------------------
# isolate the candidate command (NO jq dependency)
# ----------------------------------------------------------------------------
# `clean=1` means we isolated the command exactly (so the SAFE refspec
# relaxation may run). `clean=0` means we are scanning a looser text and MUST
# fail closed: any detected push/merge → ASK, never the safe path.
cmd=""
clean=0

# Optional fast-path: if jq exists, use it for an exact isolation.
if command -v jq >/dev/null 2>&1; then
    cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
    [ -n "$cmd" ] && clean=1
fi

# No-jq path: extract the "command" string field with pure bash parameter
# expansion. JSON-escaped inner quotes appear as \" in the raw payload, so we
# stash them under a placeholder, cut at the FIRST bare (value-terminating)
# quote, restore, then unescape. This is robust to additional fields after
# `command` (e.g. a `description`) — unlike a greedy sed — and needs no jq.
if [ "$clean" -eq 0 ]; then
    case "$payload" in
        *'"command":"'*)
            rest="${payload#*\"command\":\"}"
            rest="${rest//\\\"/$'\x01'}"   # \"  → SOH placeholder
            cmd="${rest%%\"*}"             # cut at first unescaped quote
            cmd="${cmd//$'\x01'/\"}"       # restore inner quotes
            cmd="${cmd//\\\\/\\}"          # \\  → \
            cmd="${cmd//\\n/ }"            # \n  → space
            cmd="${cmd//\\t/ }"            # \t  → space
            cmd="${cmd//\\\//\/}"          # \/  → /
            clean=1
            ;;
        *)
            # Could not locate the command field — scan a lightly-unescaped form
            # of the WHOLE payload and fail closed (no safe-push relaxation).
            cmd="$(printf '%s' "$payload" \
                | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g' -e 's/\\n/ /g' -e 's/\\t/ /g')"
            clean=0
            ;;
    esac
fi

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------

# deny(reason): structured deny JSON (exit-0 path) + hard-stop (exit 2). Retained
# for any future hard-deny rule; the current rules all use ask(). No jq.
deny() {
    local reason="$1" esc
    esc="$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$esc"
    printf 'PROMOTION GATE: %s\n' "$reason" >&2
    exit 2
}

# ask(reason): structured ASK JSON (exit 0) — routes to Claude Code's interactive
# permission prompt so Arthur clicks allow/deny on THIS exact command, in-session.
# Hand-written JSON (no jq). This is NOT exit 2 (that is a hard deny); `ask`
# defers the decision to the human, and the agent cannot answer its own prompt
# (see the managed-lockdown note in the header).
ask() {
    local reason="$1" esc
    esc="$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$esc"
    exit 0
}

# normalize_cmd(text): strip git/gh OPTION noise so the SUBCOMMAND verb becomes
# adjacent to the tool name, AND so a `git push`'s refspec tokens are the only
# non-option words left after the remote. Defeats the adjacency-evasion (GATE-02)
# where a flag VALUE token (`git -c key=val push`, `gh --repo o/r pr merge`) pushed
# the verb out of reach. Over-stripping AFTER the verb is harmless — refspec dst
# parsing reads the surviving (non-dash) tokens, and the scan fails CLOSED.
normalize_cmd() {
    printf '%s' "$1" | sed -E '
        s/[[:space:]]+-(c|C|R|H|X|o)[[:space:]]+[^[:space:]]+/ /g
        s/[[:space:]]+--(repo|git-dir|work-tree|field|raw-field|method|header|hostname|jq|template|cache)[[:space:]]+[^[:space:]]+/ /g
        s/[[:space:]]+--[A-Za-z0-9-]+=[^[:space:]]+/ /g
        s/[[:space:]]+-[A-Za-z0-9-]+/ /g
        s/[[:space:]]+/ /g'
}

# has_git_push(text): true iff TEXT contains a `git push` verb (any form).
has_git_push() {
    local text; text="$(normalize_cmd "$1")"
    printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_./-])git([[:space:]]+-[^[:space:]]+)*[[:space:]]+push([[:space:]"};&|]|$)'
}

# scan_merge_verbs(raw): true iff RAW contains a blocked MERGE verb (NOT a push).
# The flag-bearing checks read the RAW text since normalize strips the very flags
# they look for. Used on the direct command AND (via scan_text) on wrapper scripts.
scan_merge_verbs() {
    local raw="$1" text
    text="$(normalize_cmd "$raw")"
    # gh pr merge
    printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_./-])gh[[:space:]]+pr[[:space:]]+merge([[:space:]"};&|]|$)' && return 0
    # gh pr create … --merge|--squash|--rebase|--auto  (auto-merge on create)
    printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_./-])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' \
        && printf '%s' "$raw" | grep -Eq -- '--(merge|squash|rebase|auto)([[:space:]="};&|]|$)' && return 0
    # gh api … ANY merge — REST (/merges, /pulls/<n>/merge) AND GraphQL
    # (mergePullRequest / mergeBranch). Broad on purpose; fail closed.
    printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_./-])gh[[:space:]]+api([[:space:]]|$)' \
        && printf '%s' "$raw" | grep -Eqi 'merge' && return 0
    return 1
}

# scan_text(text): true iff TEXT contains ANY blocked push OR merge verb. Used for
# WRAPPER-script contents only — FAIL CLOSED: it does NOT refspec-parse, so any
# git push of any kind inside a scanned script trips it.
scan_text() {
    local raw="$1"
    has_git_push "$raw" && return 0
    scan_merge_verbs "$raw" && return 0
    return 1
}

# is_safe_push(raw): true iff RAW is a `git push` that is SAFE to run autonomously
# — at least one EXPLICIT refspec after the remote, every DESTINATION an explicit
# non-main, non-HEAD, non-tag branch. FAIL CLOSED: any ambiguity → false (→ ASK).
is_safe_push() {
    local raw="$1" text after remote tok dst

    # whole-repo pushes are never "feature-safe" (normalize strips these flags,
    # so test the RAW text).
    printf '%s' "$raw" | grep -Eq -- '(^|[^[:alnum:]_-])--(all|mirror|tags)([[:space:]=]|$)' && return 1
    # command substitution → opaque; fail closed.
    printf '%s' "$raw" | grep -Eq '[`]|\$\(' && return 1

    # The refspec relaxation runs ONLY on a SINGLE, fully-literal push command.
    # Fail closed (→ ASK) on ANY character this parser cannot faithfully resolve to
    # a literal refspec — the conservative allow-set is exactly what a real push needs
    # ([A-Za-z0-9._/:+ -]). This single guard kills two evasions at once:
    #   * shell separators/chains (; & |) → `git push origin main && git push origin
    #     feat/x` can't hide a main push past the last-push isolation below;
    #   * quoting/escaping/variables ('" \ $) → `git push origin "main"`,
    #     `git push origin ma''in`, `X=main git push origin $X` can't de-tokenize into
    #     `main` after we compare the raw literal destination.
    printf '%s' "$raw" | grep -Eq '[^A-Za-z0-9._/:+ -]' && return 1
    # belt-and-suspenders: never relax a command carrying more than one `git push`.
    [ "$(printf '%s' "$raw" | grep -oE '(^|[^[:alnum:]_./-])git[[:space:]]+push' | wc -l)" -le 1 ] || return 1

    text="$(normalize_cmd "$raw")"
    # isolate everything after the (last) `git push`, then stop at any shell
    # separator so a chained second command can't smuggle in refspecs.
    after="$(printf '%s' "$text" | sed -E 's/^.*git[[:space:]]+push//')"
    after="${after%%[;&|]*}"

    # tokenize without glob expansion
    set -f
    # shellcheck disable=SC2086
    set -- $after
    set +f

    [ "$#" -ge 1 ] || return 1     # nothing after push (bare `git push`) → unsafe
    remote="$1"; shift
    [ "$#" -ge 1 ] || return 1     # remote but NO refspec token → unsafe

    for tok in "$@"; do
        tok="${tok#+}"                       # strip a leading force-marker '+'
        case "$tok" in
            *:*) dst="${tok##*:}";;          # src:dst  → part after the LAST ':'
            *)   dst="$tok";;                # bare name → the name itself
        esac
        [ -n "$dst" ] || return 1            # empty destination → ambiguous
        case "$dst" in
            main|refs/heads/main) return 1;; # would land on main
            HEAD|HEAD*)           return 1;; # HEAD or HEAD-relative (ambiguous)
            refs/tags/*)          return 1;; # a tag destination
        esac
    done
    return 0
}

# ----------------------------------------------------------------------------
# 1) MERGE verbs in the candidate command → always ASK (never refspec-parsed).
# ----------------------------------------------------------------------------
if scan_merge_verbs "$cmd"; then
    ask "fedora-dev wants to MERGE (gh pr merge / --merge|--squash|--rebase|--auto / gh api merge). This is THE merge to main. Approve ONLY if you (Arthur) intend it; review the PR/diff first. (A free-text 'yes' is not this click — you must allow this prompt.)"
fi

# ----------------------------------------------------------------------------
# 2) git push in the candidate command → REFSPEC-AWARE.
#    Safe feature-branch push (and only when the command was cleanly isolated)
#    falls through silently. Anything main-targeting / ambiguous → ASK.
# ----------------------------------------------------------------------------
if has_git_push "$cmd"; then
    if [ "$clean" -eq 1 ] && is_safe_push "$cmd"; then
        exit 0
    fi
    ask "fedora-dev wants to push to a remote that could touch main (or the target could not be parsed). Approve ONLY if you (Arthur) intend a main-targeting push; review the command first. Feature-branch pushes with an explicit non-main refspec run without asking."
fi

# ----------------------------------------------------------------------------
# 3) WRAPPER evasion: `bash X` / `sh X` / `source X` / `. X` whose target script
#    contains a push/merge. FAIL CLOSED — script contents are NOT refspec-parsed:
#    ANY git push OR merge verb inside a scanned script → ASK.
# ----------------------------------------------------------------------------
# Extract the token following each interpreter/source invocation, then strip
# surrounding quotes AND any trailing JSON/shell punctuation. The leading anchor
# accepts start-of-line, a shell separator (`;&|`), whitespace, OR a quote.
scripts="$(printf '%s' "$cmd" \
    | grep -Eo '(^|[;&|"'"'"'[:space:]])(bash|sh|zsh|source|\.)[[:space:]]+[^;&|[:space:]]+' \
    | sed -E 's/.*(bash|sh|zsh|source|\.)[[:space:]]+//' \
    | tr -d '"'"'"'' \
    | sed -E 's/[]},;)`]+$//' 2>/dev/null || true)"
if [ -n "$scripts" ]; then
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        if [ -r "$s" ] && [ -f "$s" ]; then
            if scan_text "$(cat "$s" 2>/dev/null || true)"; then
                ask "fedora-dev wants to run a wrapper script that contains a git push or merge verb. Wrapper contents are not refspec-parsed (fail closed). Approve ONLY if you (Arthur) intend it; inspect the script first."
            fi
        fi
    done <<EOF
$scripts
EOF
fi

# ----------------------------------------------------------------------------
# 4) Not a flagged push/merge → normal permission flow.
# ----------------------------------------------------------------------------
exit 0
