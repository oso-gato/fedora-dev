#!/usr/bin/env bash
# Fleet guard-parity check — the single source of truth for "what must stay IDENTICAL across every
# claudebox repo", and the alarm that makes guard drift impossible to miss.
#
# WHY THIS EXISTS: each box's claudebox spec is necessarily SELF-CONTAINED — fedora-dev bakes its spec
# into the image AND clones it at runtime with an OFFLINE seeded fallback, so a git submodule / shared
# clone would break that offline path. That forces the shared guard payload to be DUPLICATED per repo:
#   * policy/managed-settings.json — the agent deny-list (incl. the `gh pr merge` interactive-merge
#     block) + the claude-code self-update `env` lockout + bypass/mode/allowManaged;
#   * claudebox-init.sh — the claude-code self-update lockout (/etc/profile.d/20-claude-no-selfupdate.sh)
#     + the native-build-shadow self-heal (fedora-dev PR #45);
#   * distrobox.ini — the claude-code PROVENANCE (official `latest` channel, gpgcheck, signing key).
# Duplication invites SILENT drift: PR #45 added the self-update lockout to fedora-dev, but it was
# MISSING from BOTH fedora-bootstrap AND fedora-desktop — found only by a manual cross-repo audit.
#
# This check makes that drift LOUD and AUTOMATIC: a guard fix that lands in one repo FAILS this check
# for every repo that has not caught up, so it can never again be silently forgotten. It is the
# pragmatic "one source of truth" for a self-contained-repo fleet — it does not PHYSICALLY merge the
# copies (that would break the offline path); it ENFORCES that they stay identical, achieving the same
# end ("drift can't recur") at far lower blast radius than a cross-repo auto-sync.
#
# Run by .github/workflows/fleet-guard-parity.yml (daily + on push/PR + manual dispatch); also runnable
# locally. All fleet repos are PUBLIC → raw fetch, no auth, built-in token only.
set -uo pipefail

# fedora-dev is the CANONICAL anchor (the develop·build·merge hub); the other pair box must match it.
# THE APPARATUS IS EXACTLY THE HOST/DEVBOX PAIR (maintainer ruling 2026-07-20) — fedora-desktop is a
# separate workstream, no longer part of the apparatus fleet, so its guard payload is not checked here.
REPOS=(fedora-dev fedora-bootstrap)
# PARITY_RAW is the FETCH-BASE seam: every payload is read from "$RAW/<repo>/$REF/<path>". Pointing it at
# a `file://` base lets residue-parity.test.sh drive this REAL script over fixture repos with no network
# (curl reads file:// and still fails non-zero on an absent file, so participation behaves identically).
RAW="${PARITY_RAW:-https://raw.githubusercontent.com/oso-gato}"
REF="${PARITY_REF:-main}"
# PRE-MERGE self-overlay: on `pull_request` the CI checks out the PR HEAD, but every repo (including
# the one being changed) was fetched from raw@main — so a PR that DRIFTS its OWN guard payload was
# compared main-vs-main and passed, catching drift only AFTER merge (post-merge alarm, not a gate).
# Set PARITY_SELF=<repo> (+ optional PARITY_SELF_DIR, default .) to read THAT repo's payload from the
# local checkout (the PR head) instead of raw@main, so the PR's own drift fails the check pre-merge.
# Unset (push / schedule) => pure raw@main across all repos, unchanged.
SELF="${PARITY_SELF:-}"; SELF_DIR="${PARITY_SELF_DIR:-.}"
fail=0
hr(){ printf '\n== %s ==\n' "$*"; }
bad(){ printf '  \342\234\227 %s\n' "$*"; fail=1; }
ok(){  printf '  \342\234\223 %s\n' "$*"; }
note(){ printf '  \302\267 %s\n' "$*"; }
fetch(){
  if [ -n "$SELF" ] && [ "$1" = "$SELF" ]; then cat "$SELF_DIR/$2" 2>/dev/null   # PR head, local
  else curl -fsSL "$RAW/$1/$REF/$2" 2>/dev/null; fi                              # others, raw@REF
}
# Strictly raw@REF, never the self-overlay — the lockstep escape below needs the canon as it exists at
# $REF, not as this PR proposes it.
fetch_main(){ curl -fsSL "$RAW/$1/$REF/$2" 2>/dev/null; }

# ====================================================================================================
# CHECK 7 PAYLOAD — the RESIDUE WITNESS (fedora-dev#318, feat-04 of objective #310)
# ====================================================================================================
# WHY THIS IS HERE AND NOT A SCRIPT OF ITS OWN: one parity enforcer, one place to look. The witness is
# duplicated for exactly the reason the guard payload above is — each claudebox repo must stay
# self-contained (the offline seeded-no-git path forbids a submodule or a shared clone), so
# fedora-dev:bin/residue-witness.sh and fedora-bootstrap:residue-witness.sh are two copies of one
# standard. Drift here is invisible BY DESIGN: a host witness that quietly stops enumerating one class,
# or grows one extra allowlist entry, still exits 0 forever — a softer bar wearing a GREEN, i.e. the
# unmeasured-evidence failure objective #310 was filed against. The objective's words: *"Both boxes,
# same standard … the host is held to the same bar as the dev box, not a lower one for being the thing
# under protection."*
#
# WHY A STRUCTURED COMPARISON AND NOT A HASH (CHECK 1's shape): the two copies legitimately DIFFER —
# each box observes ITS OWN anchors (the dev box's live spec clone and nested-engine graph store are not
# the host's paths). A byte/hash gate would be a permanent false RED, and a check that cries wolf gets
# switched off. So what is compared is the STANDARD, in the issue's own order:
#   1. the residue CLASS SET      — a class enumerated on one box and not the other is a lower bar
#   2. the ALLOWLIST              — what each copy admits as intentional persistence, entry by entry;
#                                   a difference is drift UNLESS that entry declares itself box-specific
#   3. the VERDICT/EXIT CONTRACT  — the rc mapping + the machine-read output grammar (feat-05 parses the
#                                   host's output, so a renamed token or a moved field breaks it)
# Everything else (prose, comment wording, the anchor paths themselves) is deliberately NOT gated; the
# residual is DISCLOSED by a non-gating normalized-code report rather than implied away.
#
# EXTRACTION CONTRACT — the shapes a copy must keep so the standard can be READ (a port that breaks one
# of these reads as UNREADABLE, which is a FAILURE, never a pass: a read that failed must never be the
# thing that relaxes a guard):
#   * one `enumerate_<class>()` function per residue class, at column 0, and a `printf '<class>\t…`
#     emission for it (a class is counted only when it is BOTH declared and emitted — a declared-but-
#     gutted enumerator is not an enumerated class);
#   * `allow_rule(){` at column 0, each rule a one-line `case "$x" in <patterns>) printf '<ID>: <why>'`
#     (the ID + the PATTERNS are the bar; the <why> prose is not compared);
#   * `residue_of(){` and `negative_control(){` at column 0, with their verdict rc on the SAME line as
#     the verdict they report (`printf 'negative-control: PROVEN…'; return 0`);
#   * a top-level `case … in` dispatch listing the verbs.
witness_path(){
  case "$1" in
    fedora-dev)       printf 'bin/residue-witness.sh';;   # dev box: under bin/ with the rest of the loop
    fedora-bootstrap) printf 'residue-witness.sh';;       # host: repo root, as the host's scripts live
    *)                return 1;;                          # unknown repo => no mapping, never a guess
  esac
}
# A PARITY-EXEMPT marker only exempts the copy it lives in, so the box token must name THAT box —
# otherwise a copy could exempt itself by writing someone else's name.
box_aliases(){
  case "${1%@*}" in
    fedora-dev)       printf 'dev|devbox|fedora-dev';;
    fedora-bootstrap) printf 'host|bootstrap|fedora-bootstrap';;
    *)                printf '%s' "${1%@*}";;
  esac
}
sset(){ printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u; }

# wit_fn_body <fn>  (stdin: witness source) → that function's body, definition line to its column-0 `}`.
# Scoping every extraction to the owning function is what keeps the selftest's own fixture printfs (and
# any header comment DOCUMENTING the marker grammar) out of the compared sets.
wit_fn_body(){ awk -v fn="$1" 'index($0, fn "()")==1 {f=1} f{print} f && /^\}/{exit}'; }

# wit_classes  (stdin: witness source) → sorted residue class names that are BOTH declared and emitted.
wit_classes(){
  local src declared emitted
  src="$(cat)"
  declared="$(printf '%s\n' "$src" | grep -oE '^enumerate_[a-z]+\(\)' | sed 's/^enumerate_//; s/()$//' | LC_ALL=C sort -u)"
  emitted="$(printf '%s\n' "$src" | grep -oE "printf '[a-z]+\\\\t" | sed "s/^printf '//; s/\\\\t\$//" | LC_ALL=C sort -u)"
  LC_ALL=C comm -12 <(printf '%s\n' "$declared") <(printf '%s\n' "$emitted") | grep -v '^[[:space:]]*$'
}

# wit_allow  (stdin: allow_rule body) → "<ID> <guard-patterns>" per rule, sorted. The PATTERNS are in the
# key on purpose: the same ID broadened to admit more is a LOWER BAR that an ID-only compare would miss.
# A rule whose shape cannot be read keys as UNREADABLE-RULE-SHAPE so it can never compare equal.
wit_allow(){
  local l id pat
  grep -E "printf '[A-Z][0-9]+: " | while IFS= read -r l; do
    id="$(printf '%s\n' "$l" | sed -E "s/^.*printf[[:space:]]*'([A-Z][0-9]+):.*/\1/")"
    pat="$(printf '%s\n' "$l" | sed -nE "s/^.*[[:space:]]in[[:space:]]+(.*)\)[[:space:]]*printf[[:space:]]*'[A-Z][0-9]+:.*/\1/p")"
    printf '%s %s\n' "$id" "${pat:-UNREADABLE-RULE-SHAPE}"
  done | LC_ALL=C sort -u
}

# wit_markers <alias-ere>  (stdin: allow_rule body) → one tab-separated record per PARITY-EXEMPT marker:
#   OK<TAB><ID><TAB><justification>   a well-formed marker for THIS box, attached to an allowlist rule
#   EMPTY<TAB><ID>                    ... carrying no justification (an exemption must state its reason)
#   FOREIGN<TAB><box><TAB><ID>        ... naming a different box than the copy it lives in
#   MALFORMED<TAB><lineno>            a PARITY-EXEMPT mention that does not match the marker grammar
#   ORPHAN<TAB><box>                  a marker attached to no rule — it exempts nothing
# A marker attaches to the rule on its own line, or to the first rule below the CONTIGUOUS comment block
# it sits in (i.e. the rule's own comment block — how the canonical file is written).
wit_markers(){
  awk -v alias="$1" -v q="'" '
    function emit(b, j, id) {
      if (b !~ "^(" alias ")$") { print "FOREIGN\t" b "\t" id; return }
      if (j == "")              { print "EMPTY\t" id; return }
      print "OK\t" id "\t" j
    }
    function parse(line) {
      if (line !~ /PARITY-EXEMPT\([A-Za-z][A-Za-z0-9-]*\)[ \t]*:/) return 0
      M_BOX = line;  sub(/^.*PARITY-EXEMPT\(/, "", M_BOX); sub(/\).*$/, "", M_BOX)
      M_JUST = line; sub(/^.*PARITY-EXEMPT\([A-Za-z][A-Za-z0-9-]*\)[ \t]*:/, "", M_JUST)
      gsub(/^[ \t]+/, "", M_JUST); gsub(/[ \t]+$/, "", M_JUST)
      return 1
    }
    BEGIN { entry = "printf " q "[A-Z][0-9]+: " }
    {
      isc = ($0 ~ /^[ \t]*#/); has = ($0 ~ /PARITY-EXEMPT/)
      if (isc) {
        if (!prevc) { pb = ""; pj = "" }                      # a NEW comment block starts here
        if (has) { if (parse($0)) { pb = M_BOX; pj = M_JUST } else print "MALFORMED\t" NR }
        prevc = 1; next
      }
      prevc = 0; tb = ""; tj = ""
      if (has) { if (parse($0)) { tb = M_BOX; tj = M_JUST } else print "MALFORMED\t" NR }
      if ($0 ~ entry) {
        id = $0; sub(/^.*printf[ \t]*/, "", id); sub(/^./, "", id); sub(/:.*$/, "", id)
        if (tb != "") emit(tb, tj, id); else if (pb != "") emit(pb, pj, id)
      } else if (pb != "") print "ORPHAN\t" pb
      pb = ""; pj = ""
    }
    END { if (pb != "") print "ORPHAN\t" pb }
  '
}

# wit_contract  (stdin: witness source) → the machine-read verdict/exit contract, one fact per line.
# These four facts are what feat-05 (and any operator) actually reads off a witness run.
wit_contract(){
  local src body
  src="$(cat)"
  body="$(printf '%s\n' "$src" | wit_fn_body residue_of)"
  { # the diff output GRAMMAR — token + field shape, e.g. `RESIDUE %s %s\n`
    printf '%s\n' "$body" | grep -oE "printf '[A-Z]+[^']*'" | sed "s/^/grammar /"
    # the diff rc mapping (clean / residue / unusable input)
    printf '%s\n' "$body" | grep -oE '(rc=[0-9]+|return [0-9]+)' | sed 's/^/diff-rc /'
    # the negative-control verdict -> rc mapping (PROVEN=0 / BLIND=1 / UNPROVEN=3)
    printf '%s\n' "$src" | grep -oE "negative-control: [A-Z]+.*; return [0-9]+" \
      | sed -E "s/negative-control: ([A-Z]+).*; return ([0-9]+)/verdict \1=\2/"
    # the dispatch VERB set — a copy that ships no --negative-control is an UNPROVEN witness, i.e. a
    # lower bar, however well its enumerators match.
    printf '%s\n' "$src" | awk '/^case .* in$/{f=1;next} f && /^esac/{exit} f{print}' \
      | sed -E 's/^[[:space:]]*([^)]*)\).*/verb \1/'
  } | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u
}

# wit_findings <canon-src> <follower-src> <canon-name> <follower-name>
#   prints one finding per line; NO output == the two copies hold the SAME standard (rc 0).
wit_findings(){
  local csrc="$1" fsrc="$2" cn="$3" fn="$4"
  local cc fc cbody fbody ca fa cx fx cco fco cids fids calias falias id pat out=""
  add(){ out="${out}${1}"$'\n'; }

  # ---- 1. THE RESIDUE CLASS SET ---------------------------------------------------------------------
  cc="$(printf '%s\n' "$csrc" | wit_classes)"; fc="$(printf '%s\n' "$fsrc" | wit_classes)"
  if [ -z "$cc" ] || [ -z "$fc" ]; then
    add "residue class set UNREADABLE ($cn: $(sset "$cc" | wc -l | tr -d ' ') classes, $fn: $(sset "$fc" | wc -l | tr -d ' ')) — expected enumerate_<class>() at column 0 plus its printf '<class>\\t… emission"
  else
    while read -r id; do [ -n "$id" ] && add "$fn does NOT enumerate the '$id' residue class that $cn does — a class missing on one box is a LOWER BAR, and its witness still exits 0 forever"; done \
      < <(LC_ALL=C comm -23 <(sset "$cc") <(sset "$fc"))
    while read -r id; do [ -n "$id" ] && add "$fn enumerates an EXTRA residue class '$id' that $cn does not — port it to $cn so both boxes are held to one standard"; done \
      < <(LC_ALL=C comm -13 <(sset "$cc") <(sset "$fc"))
  fi

  # ---- 2. THE INTENTIONAL-PERSISTENCE ALLOWLIST -----------------------------------------------------
  cbody="$(printf '%s\n' "$csrc" | wit_fn_body allow_rule)"
  fbody="$(printf '%s\n' "$fsrc" | wit_fn_body allow_rule)"
  calias="$(box_aliases "$cn")"; falias="$(box_aliases "$fn")"
  # the SHORT alias, so a finding can name the exact token to write rather than a <box> placeholder a
  # porter would have to guess at (or copy literally, which is then just another malformed marker).
  local ctok="${calias%%|*}" ftok="${falias%%|*}"
  ca="$(printf '%s\n' "$cbody" | wit_allow)"; fa="$(printf '%s\n' "$fbody" | wit_allow)"
  cx="$(printf '%s\n' "$cbody" | wit_markers "$calias")"
  fx="$(printf '%s\n' "$fbody" | wit_markers "$falias")"
  if [ -z "$cbody" ] || [ -z "$fbody" ]; then
    add "allow_rule() UNREADABLE in $([ -z "$cbody" ] && printf '%s ' "$cn"; [ -z "$fbody" ] && printf '%s' "$fn") — the allowlist is the bar; a copy whose allowlist cannot be read is never treated as matching"
  fi
  # marker HYGIENE, per copy and independent of the set diff: an exemption is a claim, and a claim with
  # no reason (or with someone else's box on it) is not a claim.
  local kind a b who out_src out_who
  for who in c f; do
    [ "$who" = c ] && { out_src="$cx"; out_who="$cn"; } || { out_src="$fx"; out_who="$fn"; }
    while IFS=$'\t' read -r kind a b; do
      case "$kind" in
        EMPTY)     add "$out_who: the PARITY-EXEMPT marker on allowlist rule ${a:-?} carries NO justification — an exemption must state its reason";;
        FOREIGN)   add "$out_who: PARITY-EXEMPT($a) on rule ${b:-?} names a DIFFERENT box than the copy it lives in — a marker only exempts its own copy";;
        MALFORMED) add "$out_who: line $a mentions PARITY-EXEMPT but not in the marker grammar '# PARITY-EXEMPT(<box>): <justification>'";;
        ORPHAN)    add "$out_who: a PARITY-EXEMPT($a) marker is attached to no allowlist rule — it exempts nothing";;
      esac
    done < <(sset "$out_src")
  done
  printf '%s\n%s\n' "$ca" "$fa" | grep -q 'UNREADABLE-RULE-SHAPE' && \
    add "an allowlist rule does not match the one-line grammar \`case \"\$x\" in <patterns>) printf '<ID>: <why>'\` — its bar cannot be read, so it cannot be compared"
  cco="$(LC_ALL=C comm -23 <(sset "$ca") <(sset "$fa"))"   # in canon only
  fco="$(LC_ALL=C comm -13 <(sset "$ca") <(sset "$fa"))"   # in follower only
  cids="$(printf '%s\n' "$cco" | awk 'NF{print $1}' | LC_ALL=C sort -u)"
  fids="$(printf '%s\n' "$fco" | awk 'NF{print $1}' | LC_ALL=C sort -u)"
  exempted(){ printf '%s\n' "$1" | grep -qF "$(printf 'OK\t%s\t' "$2")"; }
  # (a) the SAME id admitting a DIFFERENT pattern — same label, different bar. Each side must declare its
  #     own variant box-specific, or the boxes are simply allowing different things.
  while read -r id; do
    [ -n "$id" ] || continue
    exempted "$cx" "$id" && exempted "$fx" "$id" && continue
    pat="$(printf '%s\n' "$fco" | awk -v i="$id" '$1==i{$1="";sub(/^ /,"");print;exit}')"
    add "allowlist rule $id ADMITS A DIFFERENT PATTERN on $fn ($pat) than on $cn — same id, different bar; if that is genuinely box-specific, mark it '# PARITY-EXEMPT($ctok): <why>' in $cn AND '# PARITY-EXEMPT($ftok): <why>' in $fn"
  done < <(LC_ALL=C comm -12 <(printf '%s\n' "$cids") <(printf '%s\n' "$fids"))
  # (b) an EXTRA rule on the follower — the issue's headline case: an unmarked extra entry is a lower bar
  while read -r id; do
    [ -n "$id" ] || continue
    exempted "$fx" "$id" && continue
    pat="$(printf '%s\n' "$fco" | awk -v i="$id" '$1==i{$1="";sub(/^ /,"");print;exit}')"
    add "$fn has an EXTRA allowlist rule $id ($pat) that $cn does not — an UNMARKED extra allowlist entry is a LOWER BAR; port it to $cn, or mark it '# PARITY-EXEMPT($ftok): <why>' in $fn's copy"
  done < <(LC_ALL=C comm -13 <(printf '%s\n' "$cids") <(printf '%s\n' "$fids"))
  # (c) a canon rule MISSING on the follower. Stricter, not softer — but still a different standard, so
  #     it must be declared dev-specific rather than silently diverge.
  while read -r id; do
    [ -n "$id" ] || continue
    exempted "$cx" "$id" && continue
    add "$cn allowlist rule $id is MISSING from $fn — the lists must differ only by entries declared box-specific; mark it '# PARITY-EXEMPT($ctok): <why>' in $cn or port it to $fn"
  done < <(LC_ALL=C comm -23 <(printf '%s\n' "$cids") <(printf '%s\n' "$fids"))

  # ---- 3. THE VERDICT / EXIT CONTRACT ---------------------------------------------------------------
  local ct ft
  ct="$(printf '%s\n' "$csrc" | wit_contract)"; ft="$(printf '%s\n' "$fsrc" | wit_contract)"
  if [ -z "$ct" ] || [ -z "$ft" ]; then
    add "verdict/exit contract UNREADABLE in $([ -z "$ct" ] && printf '%s ' "$cn"; [ -z "$ft" ] && printf '%s' "$fn") — expected residue_of()/negative_control() at column 0 with each verdict's rc on its own line"
  else
    while read -r id; do [ -n "$id" ] && add "verdict/exit contract DRIFT: $fn is MISSING '$id' — feat-05 parses the host's output and rc, so a moved field or a changed code breaks it"; done \
      < <(LC_ALL=C comm -23 <(sset "$ct") <(sset "$ft"))
    while read -r id; do [ -n "$id" ] && add "verdict/exit contract DRIFT: $fn ADDS '$id' that $cn does not have"; done \
      < <(LC_ALL=C comm -13 <(sset "$ct") <(sset "$ft"))
  fi

  printf '%s' "$out" | grep -v '^[[:space:]]*$'
  [ -z "$(printf '%s' "$out" | grep -v '^[[:space:]]*$')" ]
}

# wit_exempt_count <repo> <src> [<repo> <src> …] → how many VALID box-specific exemptions the compared
# copies declare (the number the "N exempt, justified" report line states).
wit_exempt_count(){
  local n=0 c
  while [ "$#" -ge 2 ]; do
    c="$(printf '%s\n' "$2" | wit_fn_body allow_rule | wit_markers "$(box_aliases "$1")" | grep -c '^OK')"
    n=$(( n + ${c:-0} )); shift 2
  done
  printf '%s' "$n"
}

# ---- SELFTEST — the pure residue-parity core, on fixture witness copies ----------------------------
# No network, no repo state: it builds a canonical fixture witness carrying every shape the extraction
# contract requires, then drifts a COPY of it one way at a time and asserts each drift is caught. The
# end-to-end drive of this whole script (over fixture repos, via PARITY_RAW) lives in
# residue-parity.test.sh; this covers the decision core in every environment.
parity_selftest(){
  local pass=0 fails=0 d cfix hfix out rc
  ck(){ if [ "$2" = "$3" ]; then printf '  PASS: %s\n' "$1"; pass=$((pass+1))
        else printf '  FAIL: %s (got=%s want=%s)\n' "$1" "$2" "$3"; fails=$((fails+1)); fi; }
  ins_after(){ local f="$1" m="$2" l="$3" t x; t="$(mktemp)"
    while IFS= read -r x; do printf '%s\n' "$x"; case "$x" in *"$m"*) printf '%s\n' "$l";; esac; done < "$f" > "$t"; mv "$t" "$f"; }
  rewrite_line(){ local f="$1" m="$2" l="$3" t x; t="$(mktemp)"
    while IFS= read -r x; do case "$x" in *"$m"*) printf '%s\n' "$l";; *) printf '%s\n' "$x";; esac; done < "$f" > "$t"; mv "$t" "$f"; }
  del_line(){ local f="$1" m="$2" t x; t="$(mktemp)"
    while IFS= read -r x; do case "$x" in *"$m"*) ;; *) printf '%s\n' "$x";; esac; done < "$f" > "$t"; mv "$t" "$f"; }
  # findings against the canonical fixture; rc 0 = same standard
  fnd(){ out="$(wit_findings "$(cat "$cfix")" "$(cat "$1")" fedora-dev fedora-bootstrap)"; rc=$?; }

  d="$(mktemp -d "${TMPDIR:-/tmp}/parity-selftest.XXXXXX")" || { echo "mktemp failed"; return 2; }
  cfix="$d/canon"; hfix="$d/host"
  cat > "$cfix" <<'FIXTURE'
#!/usr/bin/env bash
# A fixture witness: minimal, but carrying every shape the extraction contract requires.
enumerate_image(){ printf 'image\t%s\n' "$1"; }
enumerate_tree(){ printf 'tree\t%s\t%s\n' "$1" "$2"; }
enumerate_container(){ printf 'container\t%s\n' "$1"; }
enumerate_mount(){ printf 'mount\t%s\n' "$1"; }
allow_rule(){
  local class key
  case "$class" in
    tree)
      # A1 — the persistent dnf package cache
      case "$key" in "$DNF_CACHE"|"$DNF_CACHE"/*) printf 'A1: persistent dnf package cache'; return 0;; esac
      ;;
    mount)
      # A3 — the home volume itself
      case "$key" in "$H") printf 'A3: home volume mount'; return 0;; esac
      ;;
  esac
  return 1
}
residue_of(){
  local rc=0
  printf 'GONE %s %s\n' "$1" "$2"
  printf 'ALLOWED %s %s [%s]\n' "$1" "$2" "$3"
  printf 'RESIDUE %s %s\n' "$1" "$2"
  rc=1
  return 2
}
negative_control(){
  printf 'negative-control: BLIND\n'; return 1
  printf 'negative-control: UNPROVEN\n'; return 3
  printf 'negative-control: PROVEN\n'; return 0
}
case "${1:-}" in
  snapshot) ;;
  diff) ;;
  --negative-control) ;;
  --selftest) ;;
esac
FIXTURE

  # -- the extractors read the fixture's standard
  ck "wit_classes finds all four classes" "$(wit_classes < "$cfix" | tr '\n' ' ')" "container image mount tree "
  ck "wit_allow keys a rule by id AND pattern" \
     "$(wit_fn_body allow_rule < "$cfix" | wit_allow | tr '\n' ';')" \
     'A1 "$DNF_CACHE"|"$DNF_CACHE"/*;A3 "$H";'
  ck "wit_contract reads the verdict rc map" \
     "$(wit_contract < "$cfix" | grep '^verdict ' | tr '\n' ' ')" \
     "verdict BLIND=1 verdict PROVEN=0 verdict UNPROVEN=3 "
  ck "wit_contract reads the diff output grammar" \
     "$(wit_contract < "$cfix" | grep -c '^grammar ')" "3"
  ck "wit_contract reads the dispatch verbs" \
     "$(wit_contract < "$cfix" | grep -c '^verb ')" "4"

  # -- IDENTICAL copies hold the same standard
  cp "$cfix" "$hfix"; fnd "$hfix"
  ck "identical copies: no findings" "$rc|$out" "0|"

  # -- the host DROPS a residue class (the objective's headline drift: a lower bar wearing a GREEN)
  cp "$cfix" "$hfix"; del_line "$hfix" 'enumerate_mount()'
  fnd "$hfix"
  ck "a dropped class is DRIFT" "$rc" "1"
  ck "and the finding NAMES the class" "$(printf '%s\n' "$out" | grep -c "'mount'")" "1"

  # -- the host adds an UNMARKED allowlist entry
  cp "$cfix" "$hfix"
  ins_after "$hfix" "A1: persistent" \
    "      case \"\$key\" in \"\$H/.cache\"/*) printf 'A5: anything under the cache'; return 0;; esac"
  fnd "$hfix"
  ck "an UNMARKED extra allowlist entry is DRIFT" "$rc" "1"
  ck "and the finding names the rule + calls it a lower bar" \
     "$(printf '%s\n' "$out" | grep -c 'EXTRA allowlist rule A5.*LOWER BAR')" "1"

  # -- the same entry, DECLARED box-specific with a justification, is allowed
  cp "$cfix" "$hfix"
  ins_after "$hfix" "A1: persistent" \
    "      # PARITY-EXEMPT(host): the host keeps its own image pull cache under this root
      case \"\$key\" in \"\$H/.cache\"/*) printf 'A5: anything under the cache'; return 0;; esac"
  fnd "$hfix"
  ck "a justified PARITY-EXEMPT entry is accepted" "$rc|$out" "0|"
  ck "and it is counted as an exemption" \
     "$(wit_exempt_count fedora-bootstrap "$(cat "$hfix")")" "1"

  # -- an exemption with NO justification is not an exemption
  cp "$cfix" "$hfix"
  ins_after "$hfix" "A1: persistent" \
    "      # PARITY-EXEMPT(host):
      case \"\$key\" in \"\$H/.cache\"/*) printf 'A5: anything under the cache'; return 0;; esac"
  fnd "$hfix"
  ck "an EMPTY justification is DRIFT" "$rc" "1"
  ck "and the finding says the exemption states no reason" \
     "$(printf '%s\n' "$out" | grep -c 'NO justification')" "1"

  # -- a marker naming the OTHER box exempts nothing (else a copy could exempt itself by proxy)
  cp "$cfix" "$hfix"
  ins_after "$hfix" "A1: persistent" \
    "      # PARITY-EXEMPT(dev): wrong box on the host's own copy
      case \"\$key\" in \"\$H/.cache\"/*) printf 'A5: anything under the cache'; return 0;; esac"
  fnd "$hfix"
  ck "a marker naming a DIFFERENT box is DRIFT" "$rc" "1"
  ck "and the finding says so" "$(printf '%s\n' "$out" | grep -c 'DIFFERENT box')" "1"

  # -- the SAME id, BROADENED: an id-only compare would miss this; the pattern is in the key so it bites
  cp "$cfix" "$hfix"
  rewrite_line "$hfix" "A1: persistent" \
    "      case \"\$key\" in \"\$DNF_CACHE\"|\"\$H\"/*) printf 'A1: persistent dnf package cache'; return 0;; esac"
  fnd "$hfix"
  ck "the same id admitting MORE is DRIFT" "$rc" "1"
  ck "and the finding says same id, different bar" \
     "$(printf '%s\n' "$out" | grep -c 'A1 ADMITS A DIFFERENT PATTERN')" "1"

  # -- a canon rule MISSING on the host: stricter, but still a different standard, so it must be declared
  cp "$cfix" "$hfix"; del_line "$hfix" "A3: home volume mount"
  fnd "$hfix"
  ck "a canon rule missing on the host is DRIFT" "$rc" "1"
  ck "and the finding names it" "$(printf '%s\n' "$out" | grep -c 'rule A3 is MISSING')" "1"

  # -- the rc mapping feat-05 parses
  cp "$cfix" "$hfix"
  rewrite_line "$hfix" "UNPROVEN" "  printf 'negative-control: UNPROVEN\\n'; return 0"
  fnd "$hfix"
  ck "a changed verdict rc is DRIFT" "$rc" "1"
  ck "and the finding names the changed fact" \
     "$(printf '%s\n' "$out" | grep -c "verdict UNPROVEN=3")" "1"
  cp "$cfix" "$hfix"
  rewrite_line "$hfix" "printf 'RESIDUE" "  printf 'RESIDUE %s\\n' \"\$1\""
  fnd "$hfix"
  ck "a changed RESIDUE output grammar is DRIFT" "$rc" "1"

  # -- a witness shipping no --negative-control is an UNPROVEN witness, i.e. a lower bar
  cp "$cfix" "$hfix"; del_line "$hfix" "--negative-control)"
  fnd "$hfix"
  ck "a missing --negative-control verb is DRIFT" "$rc" "1"

  # -- FAIL-CLOSED: a copy whose standard cannot be READ never compares equal
  printf '#!/usr/bin/env bash\necho hi\n' > "$hfix"; fnd "$hfix"
  ck "an unreadable copy is DRIFT, not a pass" "$rc" "1"
  ck "and it says the class set was unreadable" \
     "$(printf '%s\n' "$out" | grep -c 'class set UNREADABLE')" "1"

  # -- DRIFT GUARD: the SHIPPED canonical witness must satisfy the extraction contract this check
  # depends on. Without this row, a refactor of residue-witness.sh could make every copy "unreadable"
  # and the only symptom would be a red parity check nobody could explain.
  if [ -r "$SELF_DIR/bin/residue-witness.sh" ]; then
    ck "the shipped canon enumerates 4 classes" \
       "$(wit_classes < "$SELF_DIR/bin/residue-witness.sh" | wc -l | tr -d ' ')" "4"
    ck "the shipped canon's allowlist is readable" \
       "$(wit_fn_body allow_rule < "$SELF_DIR/bin/residue-witness.sh" | wit_allow | grep -c 'UNREADABLE-RULE-SHAPE')" "0"
    ck "the shipped canon's contract is readable" \
       "$(wit_contract < "$SELF_DIR/bin/residue-witness.sh" | grep -c '^verdict ')" "3"
    ck "the shipped canon compares equal to itself" \
       "$(wit_findings "$(cat "$SELF_DIR/bin/residue-witness.sh")" "$(cat "$SELF_DIR/bin/residue-witness.sh")" fedora-dev fedora-bootstrap; printf '%s' $?)" "0"
  else
    printf '  note: %s/bin/residue-witness.sh not readable here — canon drift-guard rows skipped\n' "$SELF_DIR"
  fi

  rm -rf "$d"
  printf 'selftest: %s passed, %s failed\n' "$pass" "$fails"
  [ "$fails" -eq 0 ]
}

case "${1:-}" in --selftest) parity_selftest; exit $?;; esac

# Participation: a repo is in scope iff it actually ships the claudebox guard payload.
parts=()
for r in "${REPOS[@]}"; do
  if fetch "$r" claudebox-init.sh >/dev/null && fetch "$r" policy/managed-settings.json >/dev/null; then
    parts+=("$r")
  else
    printf 'skip %s — no claudebox payload (no claudebox-init.sh / managed-settings.json)\n' "$r"
  fi
done
printf 'participating claudebox repos @ %s%s: %s\n' "$REF" "${SELF:+ (self=$SELF from PR head)}" "${parts[*]}"
[ "${#parts[@]}" -ge 2 ] || { echo "fewer than 2 claudebox repos — nothing to compare"; exit 0; }
canon="${parts[0]}"

# CHECK 1 — policy/managed-settings.json byte-identical fleet-wide. The deny-list (incl. the
# `gh pr merge` interactive-merge block), the env lockout, and
# disableBypassPermissionsMode/defaultMode/allowManaged* are fleet INVARIANTS. (Per-box policy
# divergence lives in CLAUDE.md role docs — NOT in managed-settings.json.)
hr "CHECK 1: policy/managed-settings.json byte-parity (canonical: $canon)"
csum="$(fetch "$canon" policy/managed-settings.json | sha256sum | cut -d' ' -f1)"
# LOCKSTEP: the self-overlay is incoherent when SELF *is* the canon. It asks "does the canon match the
# canon?" (trivially yes) and then requires the FOLLOWERS to match a canon that DOES NOT EXIST YET —
# so a canonical PR that changes this payload can never pass, and neither can the follower PR that
# would resolve it (its head cannot match a canon@main that has not moved). Both halves of every
# lockstep control-plane change were therefore unmergeable, from either side, forever. Observed
# 2026-07-29: fedora-dev#296 and fedora-bootstrap#307 deadlocked against each other on exactly this.
# fedora-dev does not "drift from" canon; it DEFINES it. So when the canonical repo's own PR proposes a
# NEW payload, followers are measured against the canon they can actually be expected to match — canon
# @main — and the porting debt is REPORTED rather than treated as drift. This establishes an order
# (canon lands first, followers follow) instead of a deadlock.
cmain="$csum"
if [ "$SELF" = "$canon" ]; then
  # Strictly the PRE-merge canon. An unreadable fetch keeps $csum, i.e. the old strict behaviour: a read
  # that failed must never be the thing that RELAXES a guard.
  m="$(curl -fsSL "$RAW/$canon/$REF/policy/managed-settings.json" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  [ -n "$m" ] && [ "$m" != "$(printf '' | sha256sum | cut -d' ' -f1)" ] && cmain="$m"
fi
for r in "${parts[@]}"; do
  s="$(fetch "$r" policy/managed-settings.json | sha256sum | cut -d' ' -f1)"
  if [ "$r" = "$canon" ]; then ok "$r matches $canon"
  elif [ "$s" = "$csum" ]; then ok "$r matches $canon"
  elif [ "$s" = "$cmain" ]; then
    ok "$r matches $canon@$REF — this PR proposes a NEW canon; $r must port it (its own PR passes once this lands)"
  else bad "$r managed-settings.json DIFFERS from $canon"; fi
done

# CHECK 2 — claude-code self-update LOCKOUT present in every box (the PR #45 invariant). Semantic
# grep, so it is robust to each box's legitimate comment/channel divergence.
hr "CHECK 2: claude-code self-update lockout (#45) present in every box"
for r in "${parts[@]}"; do
  init="$(fetch "$r" claudebox-init.sh)"; ms="$(fetch "$r" policy/managed-settings.json)"
  miss=()
  grep -q '20-claude-no-selfupdate'                  <<<"$init" || miss+=("profile.d writer")
  grep -q 'DISABLE_UPDATES=1'                        <<<"$init" || miss+=("DISABLE_UPDATES export")
  grep -q 'DISABLE_AUTOUPDATER=1'                    <<<"$init" || miss+=("DISABLE_AUTOUPDATER export")
  grep -q 'self-healed a stale native claude shadow' <<<"$init" || miss+=("native-shadow self-heal")
  grep -q '"DISABLE_UPDATES"'                        <<<"$ms"   || miss+=("managed-settings env leg")
  [ "${#miss[@]}" -eq 0 ] && ok "$r has the full #45 lockout + self-heal" \
                          || bad "$r MISSING #45 leg(s): ${miss[*]}"
done

# CHECK 3 — claude-code PROVENANCE parity: every box installs from the SAME official Anthropic `latest`
# channel with gpgcheck on and the SAME signing key. A box drifting to a different/insecure channel is
# a supply-chain risk.
hr "CHECK 3: claude-code provenance (channel + gpgcheck + signing key) parity"
prov(){ grep -oE 'downloads\.claude\.ai/claude-code/rpm/latest|downloads\.claude\.ai/keys/claude-code\.asc|gpgcheck=1' <<<"$1" | sort -u | tr '\n' '|'; }
cprov="$(prov "$(fetch "$canon" distrobox.ini)")"
for r in "${parts[@]}"; do
  ini="$(fetch "$r" distrobox.ini)"; p="$(prov "$ini")"
  grep -q 'gpgcheck=1'             <<<"$ini" || bad "$r distrobox.ini: claude-code repo not gpgcheck=1"
  grep -q 'claude-code/rpm/latest' <<<"$ini" || bad "$r distrobox.ini: not on the official latest channel"
  [ "$p" = "$cprov" ] && ok "$r provenance matches $canon" || bad "$r provenance DIFFERS from $canon ($p)"
done

# CHECK 4 — B-mode assembly in effect fleet-wide: fleet-core.md present in $canon (the master);
# per-box policy/CLAUDE.md deltas carry the <!--FLEET-CORE--> marker and NO stale THE FLEET
# section heading. A repo missing the marker or still carrying the section is drifted back to
# the old vendored-identical model (A), which means its stamp will not assemble correctly.
hr "CHECK 4: fleet-core.md in $canon; per-box deltas carry marker + no stale THE FLEET section"
fc="$(fetch "$canon" policy/fleet-core.md)"
[ -n "$fc" ] && ok "$canon policy/fleet-core.md present ($(printf '%s' "$fc" | wc -c) bytes)" \
             || bad "$canon policy/fleet-core.md MISSING or empty — fleet-core.md must live in $canon"
for r in "${parts[@]}"; do
  delta="$(fetch "$r" policy/CLAUDE.md)"
  printf '%s\n' "$delta" | grep -q '<!--FLEET-CORE-->' \
      && ok  "$r policy/CLAUDE.md has <!--FLEET-CORE--> marker" \
      || bad "$r policy/CLAUDE.md MISSING <!--FLEET-CORE--> marker"
  printf '%s\n' "$delta" | grep -q '^## THE FLEET' \
      && bad "$r policy/CLAUDE.md still has THE FLEET section heading (should be in fleet-core.md only)" \
      || ok  "$r policy/CLAUDE.md delta: no stale THE FLEET section"
done

# CHECK 6 — the PROBLEM-SOLVING DOCTRINE is present, delimited, and un-diluted in the canon fleet-core.md
# (the single source every box fetches + stamps FIRST into /etc/claude-code/CLAUDE.md). Because
# fleet-core.md is single-source, there is no per-box copy to drift — but a silent deletion / dilution
# of the doctrine block itself is exactly what this catches. Assert: the <!--DOCTRINE-->…<!--/DOCTRINE-->
# block exists, is closed, carries the heading + all SIX numbered mandates, and stays SHORT (brevity is
# the anti-dilution property — the doctrine is a creed, not an essay; padding it out is dilution).
hr "CHECK 6: PROBLEM-SOLVING DOCTRINE present + delimited + all 6 mandates + not bloated (canon: $canon)"
open_n="$(printf '%s\n' "$fc" | grep -c '<!--DOCTRINE-->')"
close_n="$(printf '%s\n' "$fc" | grep -c '<!--/DOCTRINE-->')"
if [ "$open_n" = 1 ] && [ "$close_n" = 1 ]; then ok "doctrine block delimited (one <!--DOCTRINE-->/<!--/DOCTRINE--> pair)"
else bad "doctrine block markers wrong (open=$open_n close=$close_n) — must be exactly one delimited block"; fi
block="$(printf '%s\n' "$fc" | awk '/<!--DOCTRINE-->/{f=1} f{print} /<!--\/DOCTRINE-->/{f=0}')"
printf '%s\n' "$block" | grep -q 'PROBLEM-SOLVING DOCTRINE' \
  && ok "doctrine heading present" || bad "doctrine heading MISSING"
mand_n="$(printf '%s\n' "$block" | grep -cE '^[0-9]+\. ')"
[ "$mand_n" -ge 6 ] && ok "doctrine carries $mand_n mandates (>=6)" \
                    || bad "doctrine has only $mand_n mandates — the six mandates must all be present (dilution/deletion?)"
blk_lines="$(printf '%s\n' "$block" | wc -l | tr -d ' ')"
[ "$blk_lines" -le 40 ] && ok "doctrine is lean ($blk_lines lines <= 40 — stays salient)" \
                        || bad "doctrine bloated to $blk_lines lines (>40) — brevity is the anti-dilution rule; tighten it"

# CHECK 5 — the gate-push hook stays RETIRED fleet-wide (UNSHACKLE, 2026-07-11).
# The interactive gate-push PreToolUse hook was removed as the per-iteration human click the
# autonomy objective forbids (merge safety = the require-PR ruleset + the `gh pr merge` deny +
# the poller's two independent gates). This check replaces the old terminal-verb assertion with
# its inverse: NO fleet repo may still ship (or resurrect) policy/hooks/gate-push.sh. While a
# repo has not yet merged its unshackle port, this stays RED — the drift alarm working as
# intended, pointing at exactly which repo still carries the retired hook.
# Failure posture: fetch() failing (network) is indistinguishable from "absent" — acceptable here
# because participation (above) already proved this repo reachable this run, and the check guards
# against RESURRECTION (a wrongly-ok transient pass self-heals on the next daily run).
hr "CHECK 5: gate-push hook retired — no repo ships policy/hooks/gate-push.sh"
for r in "${parts[@]}"; do
  if fetch "$r" policy/hooks/gate-push.sh >/dev/null; then
    bad "$r still ships policy/hooks/gate-push.sh — the retired interactive gate must not return (or the repo's unshackle port has not merged yet)"
  else
    ok "$r ships no gate-push hook (unshackled)"
  fi
done

# CHECK 7 — the RESIDUE WITNESS holds the SAME standard on both boxes (objective #310, feat-04).
# See the CHECK 7 PAYLOAD block near the top for what is compared and why it is structured, not hashed.
hr "CHECK 7: residue-witness.sh — same residue STANDARD on both boxes (canonical: $canon)"
declare -A WSRC=()
wparts=(); wmiss=()
for r in "${parts[@]}"; do
  wp="$(witness_path "$r")" || { wmiss+=("$r (no path mapping)"); continue; }
  wsrc="$(fetch "$r" "$wp")"
  if [ -n "$wsrc" ]; then WSRC["$r"]="$wsrc"; wparts+=("$r"); else wmiss+=("$r ($wp absent)"); fi
done
[ "${#wmiss[@]}" -eq 0 ] || printf '  [skip] no residue witness shipped yet by: %s\n' "${wmiss[*]}"
if [ "${#wparts[@]}" -lt 2 ] || [ -z "${WSRC[$canon]:-}" ]; then
  # NOT a pass dressed as one, and not a silent one either: the copies land in separate PRs (feat-01 in
  # $canon, feat-03 on the host), so this check must be landable BEFORE both exist and must start
  # enforcing by itself as each arrives. The skip names exactly who is missing, above.
  printf '  [skip] fewer than 2 copies of the witness to compare (need %s + a follower) — this check\n' "$canon"
  printf '         starts enforcing automatically as each copy lands; nothing is asserted about parity yet.\n'
else
  # LOCKSTEP ESCAPE — the CHECK 1 precedent, same reasoning, same fail direction. When the CANONICAL
  # repo's own PR proposes a NEW standard, the follower @main cannot match it yet, and the follower's
  # porting PR cannot match a canon that has not landed — a mutual deadlock, observed for real on this
  # repo (#296 vs bootstrap#307). So when SELF is the canon, a follower that matches canon@$REF is
  # reported as PORTING DEBT and an ORDER is established (canon lands, follower follows) instead.
  wcmain=""
  [ "$SELF" = "$canon" ] && wcmain="$(fetch_main "$canon" "$(witness_path "$canon")")"
  for r in "${wparts[@]}"; do
    [ "$r" = "$canon" ] && continue
    findings="$(wit_findings "${WSRC[$canon]}" "${WSRC[$r]}" "$canon" "$r")"
    if [ -z "$findings" ]; then
      nclass="$(printf '%s\n' "${WSRC[$canon]}" | wit_classes | wc -l | tr -d ' ')"
      nexempt="$(wit_exempt_count "$canon" "${WSRC[$canon]}" "$r" "${WSRC[$r]}")"
      ok "residue-witness.sh: $nclass/$nclass classes match ($r vs $canon)"
      ok "allowlist parity ($nexempt exempt, justified)"
      ok "verdict contract matches"
    elif [ -n "$wcmain" ] && wit_findings "$wcmain" "${WSRC[$r]}" "$canon@$REF" "$r" >/dev/null; then
      ok "$r matches $canon@$REF — this PR proposes a NEW witness standard; $r must port it (its own PR passes once this lands)"
    else
      while IFS= read -r wline; do [ -n "$wline" ] && bad "$wline"; done <<<"$findings"
    fi
    # NON-GATING disclosure of everything checks 1-3 do NOT cover. Deliberately not a gate: the two
    # boxes legitimately differ in their observation anchors, so normalized code-equality would be a
    # permanent false RED. Reporting the residual keeps it VISIBLE instead of implying coverage.
    ndiff="$(diff <(printf '%s\n' "${WSRC[$canon]}" | grep -vE '^[[:space:]]*#' | sed -e 's/^[[:space:]]*//' -e '/^$/d') \
                  <(printf '%s\n' "${WSRC[$r]}"      | grep -vE '^[[:space:]]*#' | sed -e 's/^[[:space:]]*//' -e '/^$/d') \
             | grep -c '^[<>]')"
    note "beyond the compared standard: $ndiff normalized code line(s) differ between $canon and $r (informational — each box observes its own anchors; not gated)"
  done
fi

hr "VERDICT"
if [ "$fail" = 0 ]; then
  echo "GREEN — shared claude-code guard payload is consistent across: ${parts[*]}"
else
  echo "RED — guard DRIFT detected (see the failures above). A guard fix landed in one repo but not"
  echo "the flagged one(s). Port the missing/diverged guard to each flagged repo, then re-run."
fi
exit "$fail"
