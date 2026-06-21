#!/usr/bin/env bash
# fedora-desktop — PROMOTION-GATE PreToolUse hook  (Bash matcher)
# ============================================================================
# Stamped into the claudebox at /etc/claude-code/hooks/gate-push.sh by
# claudebox-assemble.sh, alongside managed-settings.json which wires it as a
# MANAGED PreToolUse hook on the Bash tool. Because it is a *managed* hook and
# the box runs with `allowManagedHooksOnly: true`, the agent cannot remove,
# shadow, or disable it from project/user settings.
#
# JOB (see policy/CLAUDE.md "THE PROMOTION GATE → MECHANICAL ENFORCEMENT"):
#   A blocking hook is the BUILT backstop behind the clickable promotion gate.
#   It DENIES any push / merge that would mutate a remote `main` or merge a PR,
#   UNLESS a fresh one-shot approval marker — written by the clickable decision
#   flow on Arthur's explicit approval — is present. It overrides even an allow
#   permission rule (a blocking hook fires regardless of the permission verdict),
#   so a pre-allowlisted `git push` cannot walk around it.
#
# FAIL CLOSED — the load-bearing property. Claude Code does NOT bundle `jq`, and
#   the docs say a hook that errors on a missing tool FAILS OPEN (non-zero exit
#   other than 2 → tool proceeds). So this hook must NOT depend on jq for its
#   decision: it reads the raw stdin payload as TEXT and scans it (jq is used
#   only as an optional fast-path to isolate the command; if jq is absent we
#   scan the whole payload, which still contains the command string). The deny
#   verdict is emitted as a hand-written JSON string AND as exit 2, neither of
#   which needs jq. Any parse uncertainty resolves toward BLOCKING.
#
# WHY exit 2 AND structured deny JSON: per the Claude Code hook contract, exit 2
#   is the unconditional hard-stop (stderr shown to Claude, tool blocked, JSON
#   ignored). We ALSO print a `permissionDecision: "deny"` block so the reason
#   renders cleanly on harnesses that parse stdout first. Either path blocks.
#
# SCOPE — what it blocks (any of these in the candidate Bash command):
#   * git push                         (any remote/branch — pushing a `main`)
#   * gh pr merge                      (merging a PR)
#   * gh pr create ... --merge|--auto  (auto-merge on create)
#   * gh api .../merges  | .../merge   (REST merge: PR merge & branch merge)
#   * a wrapper invocation (`bash X` / `sh X` / `source X` / `. X`) whose target
#     SCRIPT CONTAINS a push/merge — so a push can't hide inside a one-off
#     script to dodge the matcher.
#
# EXEMPT (never blocked, no marker needed):
#   * the vault git-sync push — `git -C <vaultpath> push ...` — the automatic,
#     history-preserving vault mirror (policy/CLAUDE.md "VAULT & WIKI" +
#     "EXCEPTIONS"). Narrowly recognised by the `-C <vault>` form, so the
#     exemption can't be reused as a blanket `git push` allow.
#
# APPROVAL MARKER (one-shot, freshness-gated):
#   ~/.local/state/claudebox/merge-approved
#   The clickable promotion-gate flow `touch`es it immediately before performing
#   the approved push; the hook CONSUMES it (deletes it) so it authorises exactly
#   one push/merge. Markers older than $MARKER_TTL are ignored and removed — a
#   leftover from a past approval can't authorise a new push.
# ============================================================================
set -uo pipefail

# --- state dir + one-shot approval marker -----------------------------------
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claudebox"
MARKER="$STATE_DIR/merge-approved"
MARKER_TTL=120          # seconds; an approval older than this is stale

# --- the vault clone path the git-sync pushes (exempt). Override via env. -----
VAULT_DIR="${VAULT_PATH:-/home/core/obsidian/2nd-brain}"

# ----------------------------------------------------------------------------
# read the hook stdin payload (raw text — NO jq dependency)
# ----------------------------------------------------------------------------
payload="$(cat 2>/dev/null || true)"

# Empty payload → nothing to gate; fall through.
[ -n "$payload" ] || exit 0

# Optional fast-path: if jq exists, isolate just the command for tighter
# matching. If not, fall back to a lightly-unescaped form of the WHOLE payload
# (still contains the command string verbatim). Either way `scan_text` runs over
# text that includes the command, so the decision never depends on jq.
cmd=""
if command -v jq >/dev/null 2>&1; then
    cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
fi
if [ -z "$cmd" ]; then
    # jq absent OR not the expected shape: unescape common JSON sequences so a
    # `\"` / `\\` / `\n` inside the embedded command doesn't hide a verb, then
    # scan the whole payload. (Over-broad on purpose: fail toward blocking.)
    cmd="$(printf '%s' "$payload" \
        | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g' -e 's/\\n/ /g' -e 's/\\t/ /g')"
fi

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------

# deny(reason): structured deny JSON (exit-0 path) + hard-stop (exit 2).
# JSON is hand-written (no jq) so the block holds even with jq absent. The
# reason is escaped minimally for JSON safety.
deny() {
    local reason="$1" esc
    esc="$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$esc"
    printf 'PROMOTION GATE: %s\n' "$reason" >&2
    exit 2
}

# marker_fresh(): true iff the one-shot approval marker exists AND is younger
# than MARKER_TTL. CONSUMES (deletes) the marker either way → strictly one-shot.
marker_fresh() {
    [ -f "$MARKER" ] || return 1
    local now mtime age
    now="$(date +%s 2>/dev/null || echo 0)"
    mtime="$(stat -c %Y "$MARKER" 2>/dev/null || echo 0)"
    age=$(( now - mtime ))
    rm -f "$MARKER" 2>/dev/null || true        # consume regardless of freshness
    [ "$age" -ge 0 ] && [ "$age" -le "$MARKER_TTL" ]
}

# is_vault_sync_push(): true iff the command is the narrow, exempt vault push,
# i.e. `git -C <VAULT_DIR> ... push ...`. We REQUIRE the `-C <vaultpath>` form so
# a bare `git push` (cwd-relative) is NEVER auto-exempted.
is_vault_sync_push() {
    local c vesc
    c="$(printf '%s' "$cmd" | tr '\n' ' ')"
    # escape regex metacharacters in VAULT_DIR. NOTE: do NOT escape '/', it is
    # not special in grep -E and escaping it triggers "stray \ before /".
    vesc="$(printf '%s' "$VAULT_DIR" | sed 's/[][\.*^$]/\\&/g')"
    printf '%s' "$c" | grep -Eq '(^|[^[:alnum:]_])git([[:space:]]+-[^[:space:]]+)*[[:space:]]+-C[[:space:]]+'"$vesc"'([[:space:]/"]|$)' \
        && printf '%s' "$c" | grep -Eq '(^|[^[:alnum:]_])push([[:space:]"}]|$)'
}

# scan_text(text): true iff TEXT contains any blocked push/merge verb.
# Used on the command/payload AND on wrapper-script contents.
scan_text() {
    local text="$1"
    # Trailing terminator classes below deliberately include the JSON delimiters
    # `"` and `}` as well as whitespace/EOL: in the fail-closed (no-jq) path the
    # verb is matched inside the raw payload, where it is immediately followed by
    # the closing `"}}` of the JSON. Without these, the no-jq path would MISS a
    # verb at end-of-command and fail OPEN. With them it still fails closed.
    # git push  (allow intervening flags incl. `-C <dir>`)
    printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_./-])git([[:space:]]+-[^[:space:]]+|[[:space:]]+-C[[:space:]]+[^[:space:]]+)*[[:space:]]+push([[:space:]"};&|]|$)' && return 0
    # gh pr merge
    printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_./-])gh[[:space:]]+pr[[:space:]]+merge([[:space:]"};&|]|$)' && return 0
    # gh pr create ... --merge|--squash|--rebase|--auto  (auto-merge on create)
    printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_./-])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' \
        && printf '%s' "$text" | grep -Eq -- '--(merge|squash|rebase|auto)([[:space:]="};&|]|$)' && return 0
    # gh api ... /merges  OR  .../pulls/<n>/merge   (REST merge endpoints)
    printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_./-])gh[[:space:]]+api([[:space:]]|$)' \
        && printf '%s' "$text" | grep -Eq '/(merges|merge)([[:space:]?#"'"'"'};&|]|$)' && return 0
    return 1
}

# ----------------------------------------------------------------------------
# 1) VAULT SYNC EXEMPTION — allow the narrow `git -C <vault> push`, no marker.
#    (Only meaningful when jq isolated a real command; on the payload-scan
#    fallback the `-C <vault>` form is still matched if present.)
# ----------------------------------------------------------------------------
if is_vault_sync_push; then
    exit 0
fi

# ----------------------------------------------------------------------------
# 2) DIRECT push/merge in the candidate command/payload?
# ----------------------------------------------------------------------------
blocked=0
scan_text "$cmd" && blocked=1

# ----------------------------------------------------------------------------
# 3) WRAPPER evasion: `bash X` / `sh X` / `source X` / `. X` whose target script
#    contains a push/merge. Extract candidate script paths and scan contents.
# ----------------------------------------------------------------------------
if [ "$blocked" -eq 0 ]; then
    # Extract the token following each interpreter/source invocation, then strip
    # surrounding quotes AND any trailing JSON/shell punctuation (`"`, `}`, `,`,
    # `;`, `)`). The trailing-trim matters on the no-jq fallback, where `cmd` is
    # the raw payload and the captured token would otherwise be e.g.
    # `/tmp/ship.sh"}}` and fail the `-r` readability test — silently disabling
    # wrapper-evasion detection. Trimming makes the path resolve so we can scan
    # the target script's contents.
    # Leading anchor accepts start-of-line, a shell separator (`;&|`), whitespace,
    # OR a quote (`"`/`'`) — the quote case is the no-jq fallback, where the
    # interpreter token sits right after the JSON `"command":"` opening quote.
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
                    blocked=1
                    break
                fi
            fi
        done <<EOF
$scripts
EOF
    fi
fi

# ----------------------------------------------------------------------------
# 4) Not a push/merge → normal permission flow.
# ----------------------------------------------------------------------------
[ "$blocked" -eq 0 ] && exit 0

# ----------------------------------------------------------------------------
# 5) It IS a push/merge. Allow ONLY with a fresh one-shot approval marker.
# ----------------------------------------------------------------------------
if marker_fresh; then
    exit 0
fi

deny "Push/merge blocked by the promotion gate. This mutates a remote branch or merges a PR, which requires Arthur's explicit clickable approval. Present the change as a discrete decision; on approval the flow writes a one-shot marker at $MARKER (fresh < ${MARKER_TTL}s) and re-runs. (The vault git-sync 'git -C <vault> push' is exempt and needs no marker.)"
