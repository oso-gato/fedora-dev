#!/usr/bin/env bash
# intake-file.test.sh — drives the REAL bin/intake-file.sh against a stub `gh` and asserts the one
# property the front door cannot get wrong: WHICH LABEL IT FILES UNDER.
#
# WHY THIS EXISTS. The filer shipped filing every drafted objective as `backlog` — and `backlog` is not
# an inbox, it is the label `bin/dev-loop.sh` sweeps and hands straight to `bin/dev-author.sh`, which
# implements it, opens a PR and lets the poller auto-merge it. An UNCONFIRMED objective therefore became
# merged code while the issue body it was filed with told the maintainer his `approved` tap was what
# started the loop. The pure `--selftest` could not see any of it: the validator was correct, and the
# defect was one word in a `gh issue create` argument. So this suite tests the ARGUMENTS, not the
# verdict — and the MUTATION at the end restores that one word to prove the rows discriminate.
#
# No GitHub, no network, no model: `gh` is a stub that records its argv.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FILER="$HERE/bin/intake-file.sh"
LOOP="$HERE/bin/dev-loop.sh"
TEMPLATE="$HERE/.github/ISSUE_TEMPLATE/agent-task.yml"
[ -f "$FILER" ] || { echo "FATAL: bin/intake-file.sh not found"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
      else fail=$((fail+1)); printf '  FAIL %s\n       got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }

# gh stub — records every invocation's argv, one line per call, and answers `issue create` with a URL.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
  "issue create") [ -n "${FAKE_CREATE_FAILS:-}" ] && { echo "could not add label: 'objective' not found"; exit 1; }
                  echo "https://github.com/oso-gato/fedora-dev/issues/777" ;;
  "label create") [ -n "${FAKE_LABEL_FAILS:-}" ] && exit 1 ;;
esac
exit 0
EOF
chmod +x "$BIN/gh"

# repo-scope stub — the R16 belt's ONE seam. Records the $SCOPE_SESSION it was called with (the layer
# assertion below) and denies exactly $SCOPE_DENY_REPO. Driven through the filer's REPO_SCOPE override
# so the rows are deterministic: unstubbed, the real reader would answer from the live App installation
# (and `fedora-dev` would pass only by accident, as one of the apparatus's OWN repos).
SCOPE_STUB="$ROOT/repo-scope-stub.sh"
cat > "$SCOPE_STUB" <<'EOF'
#!/usr/bin/env bash
printf 'session=[%s] argv=[%s]\n' "${SCOPE_SESSION-<unset>}" "$*" >> "$SCOPE_LOG"
[ "${2:-}" = "${SCOPE_DENY_REPO:-}" ] && { echo "repo-scope: DENY: $2" >&2; exit 3; }
exit 0
EOF
chmod +x "$SCOPE_STUB"
export REPO_SCOPE="$SCOPE_STUB" SCOPE_LOG="$ROOT/scope.log"; : > "$SCOPE_LOG"

# A complete, fileable spec — everything the validator demands, so any refusal below is about the FILING.
SPEC="$ROOT/spec.md"
cat > "$SPEC" <<'EOF'
# Export invoices as CSV

## Objective
People keep asking finance for invoice data by email. They should be able to get it themselves.

## Scope
- A button on the invoice list that downloads the current filtered view

## Out of scope
- Scheduled or emailed exports

## Acceptance
$ npm test -- invoice-export

Expected: exits 0.
EOF

# file <desc> — run the REAL filer in --file mode against the stub and capture its rc.
run_file(){ export GH_LOG="$ROOT/gh-$RANDOM.log"; : > "$GH_LOG"
            PATH="$BIN:$PATH" bash "${FILER_SCRIPT:-$FILER}" --file "$SPEC" --repo fedora-dev >/dev/null 2>&1; }
# create_args — the argv of the `gh issue create` call (empty if it never happened).
create_args(){ grep -m1 '^issue create' "$GH_LOG" || true; }
label_of(){ printf '%s' "$1" | sed -n 's/.*--label \([^ ]*\).*/\1/p'; }

echo "== the filer files under a label the AUTHOR LOOP DOES NOT SWEEP (the R1 bypass this closes) =="
run_file; rc=$?
ck "a complete spec is filed" "$rc" "0"
ARGS="$(create_args)"
ck "…via gh issue create" "$([ -n "$ARGS" ] && echo yes || echo no)" "yes"
FILED_LABEL="$(label_of "$ARGS")"
ck "…labelled 'objective'" "$FILED_LABEL" "objective"
ck "…and NOT 'backlog' — that label goes straight to dev-author → PR → auto-merge" \
   "$([ "$FILED_LABEL" = backlog ] && echo BYPASS || echo gated)" "gated"
ck "…assigned to the maintainer so it reaches his GitHub app" \
   "$(printf '%s' "$ARGS" | grep -c -- '--assignee oso-gato')" "1"

echo "== CREATE-ON-USE: the label is created BEFORE the issue that needs it (gh hard-fails otherwise) =="
ck "gh label create was called for the intake label" \
   "$(grep -c '^label create objective' "$GH_LOG")" "1"
ck "…and it ran BEFORE the issue create" \
   "$(grep -m1 -e '^label create' -e '^issue create' "$GH_LOG" | awk '{print $1}')" "label"

echo "== the label the filer uses is the label the plan arm looks for (one contract, two files) =="
if [ -f "$LOOP" ]; then
  loop_intake="$(sed -n 's/^INTAKE_LABEL="\${INTAKE_LABEL:-\([^}]*\)}"/\1/p' "$LOOP" | head -1)"
  loop_backlog="$(sed -n 's/^BACKLOG_LABEL="\${BACKLOG_LABEL:-\([^}]*\)}"/\1/p' "$LOOP" | head -1)"
  ck "bin/dev-loop.sh's plan arm looks for exactly what the filer files" "$loop_intake" "$FILED_LABEL"
  ck "…and that is NOT the label it authors from" \
     "$([ -n "$loop_backlog" ] && [ "$loop_intake" != "$loop_backlog" ] && echo distinct || echo SAME)" "distinct"
fi

echo "== the hand-filing form carries the same gate (it is the same front door) =="
if [ -f "$TEMPLATE" ]; then
  tmpl="$(sed -n 's/^labels: \[\"\([^\"]*\)\".*/\1/p' "$TEMPLATE" | head -1)"
  ck ".github/ISSUE_TEMPLATE/agent-task.yml labels a hand-filed ticket 'objective'" "$tmpl" "$FILED_LABEL"
fi

echo "== an INCOMPLETE spec files NOTHING (the refusal is not a formality) =="
VAGUE="$ROOT/vague.md"; printf '# Make the app better\n\nIt feels slow.\n' > "$VAGUE"
export GH_LOG="$ROOT/gh-vague.log"; : > "$GH_LOG"
PATH="$BIN:$PATH" bash "$FILER" --file "$VAGUE" --repo fedora-dev >/dev/null 2>&1
ck "a spec with no acceptance command is refused" "$?" "1"
ck "…and no issue was created" "$(grep -c '^issue create' "$GH_LOG")" "0"

echo "== a failed create is reported, not swallowed =="
export FAKE_CREATE_FAILS=1
run_file; ck "a create failure exits non-zero" "$([ $? -ne 0 ] && echo nonzero || echo zero)" "nonzero"
unset FAKE_CREATE_FAILS

echo "== the issue body tells the maintainer the TRUTH about what happens next =="
run_file >/dev/null
BODY_FILE_ARG="$(create_args)"
ck "the body is passed as a file (never inline argv)" \
   "$(printf '%s' "$BODY_FILE_ARG" | grep -c -- '--body-file')" "1"
# The body itself is composed in-process; assert on the literals the script writes, which is what the
# maintainer actually reads. The old text promised "the autonomous loop takes it from here" while the
# loop had ALREADY taken it — the claim and the label must agree.
ck "it names the approval tap as the thing that starts the work" \
   "$(grep -c 'until you apply the `%s` label' "$FILER")" "1"
ck "it no longer claims the loop takes over on filing" \
   "$(grep -c 'the autonomous loop takes it from here' "$FILER")" "0"

echo "== R16 SCOPE BELT: an out-of-scope repo files NOTHING (fitness RETURN on 8ffd4d4) =="
# The header used to justify OMITTING this belt by asserting the reader fails closed to the apparatus's
# own two repos without policy/scope.conf. That was false — scope.conf is retired and the reader
# enumerates the App installation, so tenant repos are ALLOWED (verified against the real reader:
# `check fedora-desktop` → rc 0, `check <uninstalled>` → rc 3). The belt is now wired; these rows are
# what keep it wired.
export GH_LOG="$ROOT/gh-scope.log"; : > "$GH_LOG"; : > "$SCOPE_LOG"
SCOPE_DENY_REPO=someone-elses-repo PATH="$BIN:$PATH" \
  bash "$FILER" --file "$SPEC" --repo someone-elses-repo >/dev/null 2>&1
ck "an out-of-scope repo is refused with the distinct scope rc" "$?" "4"
ck "…and NO issue was created" "$(grep -c '^issue create' "$GH_LOG")" "0"
ck "…and not even the label was created (the belt runs before anything is composed)" \
   "$(grep -c '^label create' "$GH_LOG")" "0"
ck "the belt actually consulted the scope reader" "$(grep -c 'argv=\[check someone-elses-repo\]' "$SCOPE_LOG")" "1"

echo "== …while an IN-SCOPE repo still files normally (the belt does not refuse the front door) =="
export GH_LOG="$ROOT/gh-inscope.log"; : > "$GH_LOG"; : > "$SCOPE_LOG"
SCOPE_DENY_REPO=someone-elses-repo PATH="$BIN:$PATH" \
  bash "$FILER" --file "$SPEC" --repo fedora-desktop >/dev/null 2>&1
ck "a tenant repo the App is installed on is filed" "$?" "0"
ck "…as an objective" "$(label_of "$(create_args)")" "objective"

echo "== the belt checks the CEILING, not the per-session layer (an undeclared session must still file) =="
# repo-scope has two layers; the per-session one narrows to a session's ALREADY-declared objective and
# answers SESSION_UNDECLARED (rc 3) for an ordinary conversation — which would refuse every intake, since
# a NEW objective is by definition not in the current session's scope. The filer therefore pins
# SCOPE_SESSION empty for this call. Verified against the real reader: with SCOPE_SESSION set to an
# unregistered id, `check fedora-desktop` → rc 3; with it empty → rc 0.
ck "the filer calls the reader with SCOPE_SESSION pinned empty" \
   "$(grep -c 'session=\[\] ' "$SCOPE_LOG")" "1"
ck "…even when a real session id is present in the environment" \
   "$(: > "$SCOPE_LOG"; SCOPE_SESSION=deadbeef-0000-0000-0000-000000000000 PATH="$BIN:$PATH" \
        bash "$FILER" --file "$SPEC" --repo fedora-desktop >/dev/null 2>&1; grep -c 'session=\[\] ' "$SCOPE_LOG")" "1"

echo "== a MISSING scope reader refuses (fail-closed: rc 127 is never a go) =="
export GH_LOG="$ROOT/gh-noreader.log"; : > "$GH_LOG"
REPO_SCOPE="$ROOT/no-such-reader.sh" PATH="$BIN:$PATH" \
  bash "$FILER" --file "$SPEC" --repo fedora-dev >/dev/null 2>&1
ck "an unreadable/missing scope reader refuses" "$?" "4"
ck "…and files nothing" "$(grep -c '^issue create' "$GH_LOG")" "0"

# --- MUTATION, RUN IN-SUITE. Neutralize the belt so it always allows. The out-of-scope repo must then
# --- be FILED — proving the rows above are carried by the belt and not by the stub refusing on its own.
echo "== MUTATION: with the scope belt neutralized, an out-of-scope objective is filed =="
MUTS="$ROOT/mut-scope-intake-file.sh"
sed 's|^SCOPE_SESSION="" "\$REPO_SCOPE" check "\$REPO" 2>/dev/null \\$|SCOPE_SESSION="" true \\|' "$FILER" > "$MUTS"
if cmp -s "$FILER" "$MUTS"; then
  ck "the scope mutation sed genuinely changed the filer (else this row proves nothing)" no yes
else
  ck "the scope mutation sed genuinely changed the filer (else this row proves nothing)" yes yes
fi
export GH_LOG="$ROOT/gh-mutscope.log"; : > "$GH_LOG"
SCOPE_DENY_REPO=someone-elses-repo PATH="$BIN:$PATH" \
  bash "$MUTS" --file "$SPEC" --repo someone-elses-repo >/dev/null 2>&1
ck "mutant: the out-of-scope objective IS filed" "$(grep -c '^issue create' "$GH_LOG")" "1"

# --- MUTATION, RUN IN-SUITE. Restore the one word: INTAKE_LABEL defaulting to `backlog`. Every guard
# --- above must then report the bypass — proving these rows are carried by the label the filer really
# --- passes to gh, and not by the harness. The sed must genuinely change the copy, else the row is
# --- vacuous.
echo "== MUTATION: with INTAKE_LABEL back to 'backlog', the filer routes past the maintainer again =="
MUT="$ROOT/mut-intake-file.sh"
sed 's|^INTAKE_LABEL="${INTAKE_LABEL:-objective}"$|INTAKE_LABEL="${INTAKE_LABEL:-backlog}"|' "$FILER" > "$MUT"
if cmp -s "$FILER" "$MUT"; then
  ck "the mutation sed genuinely changed the filer (else this row proves nothing)" no yes
else
  ck "the mutation sed genuinely changed the filer (else this row proves nothing)" yes yes
fi
FILER_SCRIPT="$MUT" run_file
MUT_LABEL="$(label_of "$(create_args)")"
ck "mutant: the objective is filed straight onto the author loop's backlog" "$MUT_LABEL" "backlog"
ck "…which is exactly the bypass the real filer must not have" \
   "$([ "$MUT_LABEL" = "$FILED_LABEL" ] && echo same || echo differs)" "differs"

echo
echo "intake-file: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
