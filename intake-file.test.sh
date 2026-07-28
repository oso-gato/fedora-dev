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
