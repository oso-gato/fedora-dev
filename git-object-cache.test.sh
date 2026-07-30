#!/usr/bin/env bash
# git-object-cache.test.sh — proves `bin/git-object-cache.sh` fetches a repo's history ONCE and that the
# clones it hands out are SELF-CONTAINED against its own eviction. (fedora-dev#319, objective #311.)
#
# THE AXIS UNDER TEST is not "does the script run" — it is the two properties a caller's correctness
# depends on, each of which fails SILENTLY if wrong:
#   (1) THE OBJECTS COME FROM LOCAL DISK. A cache that quietly re-fetches saves nothing while looking
#       identical from the outside (same clone, same history, same exit code). So the object source is
#       proven the only unambiguous way available offline: the origin is MOVED AWAY and the clone is
#       taken again. If it still carries the full history, the objects cannot have come from anywhere
#       but the mirror. That row needs no counter, no filesystem assumption and no network.
#   (2) THE CLONE SURVIVES EVICTION OF ITS MIRROR. This cache is bounded, so a clone that BORROWS
#       objects (an `objects/info/alternates` link, what `--reference` without `--dissociate` leaves)
#       is a clone that becomes corrupt weeks later, on a GC run, far from anything that looks causal.
#       So a clone is taken, its mirror is EVICTED, and its history must still be whole and fsck-clean.
#
# EVERYTHING IS DRIVEN AGAINST REAL GIT AND REAL LOCAL `file://` ORIGINS — no stub, no network. A stubbed
# git would assert what the stub was told (BP8), and every claim here is a claim about git's actual local
# transport, packfile reuse and alternates behaviour.
#
# PART B — THE rx_bytes MEASUREMENT, AND EXACTLY WHAT IT PROVES. The feature's acceptance asks for the
# interface `rx_bytes` delta across a second clone to sit below a stated noise floor, and that is what
# PART B measures (floor: 128 KiB, printed with the observed value). Its LIMIT is stated rather than
# dressed up, per the ANTI-THEATER doctrine: against a `file://` fixture the counter cannot move by
# construction, so this row does NOT prove the https path is delta-only — what it DOES catch is a
# regression that makes this code path open ANY network connection (a remote helper, a submodule fetch,
# an LFS smudge would all move it), and the delta-only property of the real path is git's own protocol
# guarantee, exercised here by the DELTA-REFRESH row (the mirror's original packfile survives a refresh
# that brings in a new commit — a re-fetch of the history would replace it). The claim "the objects came
# from the mirror" rests on the origin-removed row above, which is exact.
#
# MUTATIONS RUN IN-SUITE (BP8 — four). Each neutralizes ONE guarantee in a COPY and demands the matching
# row change its answer; each sed is vacuity-guarded, so a sed that stopped matching FAILS the row
# instead of passing over an unmutated file.
#
#   bash git-object-cache.test.sh   -> exit 0 = all rows pass · 77 = PART B unrunnable here (PART A ran)
# No GitHub, no network, no model. Run after touching the cache helper, its GC, or either call site.
set -uo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
SUT="$REPO/bin/git-object-cache.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/goctest.XXXXXX")" || exit 2
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then printf '  PASS: %s\n' "$1"; pass=$((pass+1))
      else printf '  FAIL: %s\n        got=[%s]\n       want=[%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
ok(){ printf '  PASS: %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL: %s — %s\n' "$1" "$2"; fail=$((fail+1)); }

[ -f "$SUT" ] || { echo "missing subject: $SUT"; exit 2; }

ORIGINS="$TMP/origins"
CACHE="$TMP/cache"

# ---- fixture: a REAL bare origin with real history, reachable only over file:// --------------------
mkorigin(){ # mkorigin <owner> <name> [<blob-kib>]
  local owner="$1" name="$2" kib="${3:-4}" o="$ORIGINS/$1/$2.git" w="$TMP/w-$1-$2"
  git init -q --bare "$o"
  git -C "$o" symbolic-ref HEAD refs/heads/main       # a real GitHub origin advertises a live HEAD
  git init -q "$w"; git -C "$w" config user.email t@t; git -C "$w" config user.name t
  head -c "$(( kib * 1024 ))" /dev/urandom > "$w/blob.bin"
  printf 'seed\n' > "$w/README.md"
  git -C "$w" add -A; git -C "$w" commit -qm seed; git -C "$w" branch -M main
  git -C "$w" remote add origin "file://$o"; git -C "$w" push -q origin main
  printf '%s\n' "$o"
}
addcommit(){ # addcommit <owner> <name> <text>
  local w="$TMP/w-$1-$2"
  printf '%s\n' "$3" >> "$w/README.md"
  git -C "$w" add -A; git -C "$w" commit -qm "$3" >/dev/null; git -C "$w" push -q origin main
}
# run the subject with the fixture env; $GOC_ENV adds per-row overrides
goc(){ # shellcheck disable=SC2086
  env FD_GIT_CACHE="$CACHE" FD_GIT_ORIGIN_BASE="file://$ORIGINS/" ${GOC_ENV:-} bash "$SUT" "$@"
}
packinodes(){ find "$1/objects/pack" -name '*.pack' -printf '%i\n' 2>/dev/null | sort; }

mkorigin oso-gato alpha 64 >/dev/null 2>&1 || { echo "FATAL: could not build the fixture origin"; exit 2; }

echo "== PART A: the cache's guarantees, against real git and real file:// origins =="

# --- A1: it parses, and its OWN --selftest runs rows and passes. Asserting only the rc would pass
# against a script that has no --selftest at all, so the summary line is demanded too.
bash -n "$SUT" 2>/dev/null; ck "A1 bin/git-object-cache.sh parses" "$?" "0"
st="$(bash "$SUT" --selftest 2>&1)"; st_rc=$?
ck "A1 --selftest rc" "$st_rc" "0"
ck "A1 --selftest actually ran rows" \
   "$(printf '%s\n' "$st" | grep -c '^selftest: [1-9][0-9]* passed, 0 failed$')" "1"

# --- A2: the actuator convention — git-tracked EXECUTABLE. A 644 actuator dies at the direct exec its
# callers use ("Permission denied"), which has shipped twice (bin-exec.test.sh's reason for existing).
mode="$(git -C "$REPO" ls-files -s -- bin/git-object-cache.sh 2>/dev/null | awk '{print $1}')"
ck "A2 the helper is tracked 100755" "${mode:-untracked}" "100755"

# --- A3: FIRST ensure creates the mirror, and it holds the origin's history.
out="$(goc ensure oso-gato/alpha 2>/dev/null)"; rc=$?
ck "A3 first ensure rc + path" "$rc|$out" "0|$CACHE/oso-gato-alpha.git"
git -C "$CACHE/oso-gato-alpha.git" rev-parse --git-dir >/dev/null 2>&1
ck "A3 the mirror is a real git dir" "$?" "0"
ck "A3 the mirror carries the origin's head" \
   "$(git -C "$CACHE/oso-gato-alpha.git" rev-parse refs/heads/main 2>/dev/null)" \
   "$(git -C "$ORIGINS/oso-gato/alpha.git" rev-parse refs/heads/main)"

# --- A4: the SECOND ensure is DELTA-ONLY. The proof is packfile identity: `git remote update` fetches
# only the new objects, so the pack holding the ALREADY-MIRRORED history is still there, same inode. A
# re-clone (the behaviour this feature removes) would build a fresh pack set and drop that inode.
pack_before="$(packinodes "$CACHE/oso-gato-alpha.git")"
dir_before="$(stat -c %i "$CACHE/oso-gato-alpha.git")"
addcommit oso-gato alpha second
out="$(goc ensure oso-gato/alpha 2>/dev/null)"; rc=$?
ck "A4 second ensure rc" "$rc" "0"
ck "A4 the mirror picked up the new commit" \
   "$(git -C "$CACHE/oso-gato-alpha.git" rev-parse refs/heads/main 2>/dev/null)" \
   "$(git -C "$ORIGINS/oso-gato/alpha.git" rev-parse refs/heads/main)"
if [ -z "$pack_before" ]; then
  no "A4 the refresh is delta-only" "the fresh mirror had no packfile to compare — the row is VACUOUS"
elif printf '%s\n' "$(packinodes "$CACHE/oso-gato-alpha.git")" | grep -qxF "$pack_before"; then
  ok "A4 the refresh is delta-only (the original packfile survives, same inode)"
else no "A4 the refresh is delta-only" "the original pack inode is gone — the history was re-fetched"; fi
ck "A4 the mirror was refreshed in place, not recreated" "$(stat -c %i "$CACHE/oso-gato-alpha.git")" "$dir_before"

# --- A5: clone → a usable, SELF-CONTAINED clone pointing at the origin URL.
out="$(goc clone oso-gato/alpha "$TMP/c1" 2>/dev/null)"; rc=$?
ck "A5 clone rc + path" "$rc|$out" "0|$TMP/c1"
ck "A5 no alternates link into the cache" \
   "$([ -e "$TMP/c1/.git/objects/info/alternates" ] && echo linked || echo self-contained)" "self-contained"
ck "A5 origin is the origin URL, not the mirror path" \
   "$(git -C "$TMP/c1" remote get-url origin 2>/dev/null)" "file://$ORIGINS/oso-gato/alpha.git"
ck "A5 the history matches the origin" \
   "$(git -C "$TMP/c1" rev-parse HEAD 2>/dev/null)" \
   "$(git -C "$ORIGINS/oso-gato/alpha.git" rev-parse refs/heads/main)"
ck "A5 the working tree is checked out" "$([ -f "$TMP/c1/README.md" ] && echo yes || echo no)" "yes"
ck "A5 the whole history is present, not a shallow slice" \
   "$(git -C "$TMP/c1" rev-list --count HEAD 2>/dev/null)" \
   "$(git -C "$ORIGINS/oso-gato/alpha.git" rev-list --count refs/heads/main)"

# --- A6: THE LOAD-BEARING ROW. Evict the mirror the clone came from; the clone must be untouched.
GOC_ENV="FD_GIT_CACHE_CAP_BYTES=0" goc gc >/dev/null 2>&1
ck "A6 the mirror was evicted" \
   "$([ -d "$CACHE/oso-gato-alpha.git" ] && echo present || echo evicted)" "evicted"
ck "A6 the clone still carries its whole history after eviction" \
   "$(git -C "$TMP/c1" rev-list --count HEAD 2>/dev/null)" \
   "$(git -C "$ORIGINS/oso-gato/alpha.git" rev-list --count refs/heads/main)"
git -C "$TMP/c1" fsck --no-progress --no-dangling >/dev/null 2>&1
ck "A6 the clone is fsck-clean after eviction (it owns its objects)" "$?" "0"

# --- A7: AGE-prune removes the aged mirror AND NOTHING ELSE.
rm -rf "$CACHE"
mkorigin oso-gato beta 8 >/dev/null 2>&1
goc ensure oso-gato/alpha >/dev/null 2>&1
goc ensure oso-gato/beta  >/dev/null 2>&1
touch -d '90 days ago' "$CACHE/oso-gato-beta.git"
out="$(GOC_ENV="FD_GIT_CACHE_MAX_AGE_DAYS=45" goc gc 2>/dev/null)"
ck "A7 the aged mirror is age-pruned" \
   "$([ -d "$CACHE/oso-gato-beta.git" ] && echo present || echo pruned)" "pruned"
ck "A7 the fresh mirror is untouched" \
   "$([ -d "$CACHE/oso-gato-alpha.git" ] && echo present || echo pruned)" "present"
printf '%s\n' "$out" | grep -q 'age-prune.*oso-gato-beta.git'
ck "A7 the eviction is announced, naming the mirror" "$?" "0"

# --- A8: LRU order — over the SIZE cap, the OLDEST goes and the NEWEST stays. The GB knob has no value
# between 0 and "bigger than any fixture", so the byte seam is what makes ORDER observable at all.
goc ensure oso-gato/beta >/dev/null 2>&1
touch -d '2 days ago' "$CACHE/oso-gato-beta.git"      # older, but nowhere near the age cap
touch "$CACHE/oso-gato-alpha.git"                     # newest
s_new=$(( $(du -sk "$CACHE/oso-gato-alpha.git" | cut -f1) * 1024 ))
s_old=$(( $(du -sk "$CACHE/oso-gato-beta.git"  | cut -f1) * 1024 ))
cap=$(( s_new + s_old / 2 ))                          # room for the newest alone, not for both
out="$(GOC_ENV="FD_GIT_CACHE_MAX_AGE_DAYS=3650 FD_GIT_CACHE_CAP_BYTES=$cap" goc gc 2>/dev/null)"
ck "A8 the OLDEST mirror is LRU-evicted" \
   "$([ -d "$CACHE/oso-gato-beta.git" ] && echo present || echo evicted)" "evicted"
ck "A8 the NEWEST mirror survives" \
   "$([ -d "$CACHE/oso-gato-alpha.git" ] && echo present || echo evicted)" "present"
printf '%s\n' "$out" | grep -q 'size-prune.*oso-gato-beta.git'
ck "A8 the LRU eviction is announced, naming the mirror" "$?" "0"

# --- A9: an orphan mirror-in-progress (a clone killed before its move) is reaped on the same clock as
# the throwaway sweeper's other orphans — and an IN-FLIGHT one is never reaped out from under itself.
mkdir -p "$CACHE/oso-gato-gamma.git.incoming.999" "$CACHE/oso-gato-delta.git.incoming.998"
touch -d '2 days ago' "$CACHE/oso-gato-gamma.git.incoming.999"
GOC_ENV="FD_STALE_MIN=720" goc gc >/dev/null 2>&1
ck "A9 a stale mirror-in-progress is reaped" \
   "$([ -d "$CACHE/oso-gato-gamma.git.incoming.999" ] && echo present || echo reaped)" "reaped"
ck "A9 a fresh mirror-in-progress is left alone" \
   "$([ -d "$CACHE/oso-gato-delta.git.incoming.998" ] && echo present || echo reaped)" "present"
rm -rf "$CACHE/oso-gato-delta.git.incoming.998"

# --- A10: the refusals. Every one of these must be a plain rc≠0 that leaves NOTHING behind, because the
# caller's contract is "fall through to the full clone" — a half-written cache entry would poison it.
before="$(ls -A "$CACHE" | sort)"
for bad in "oso-gato" "a/b/c" "../etc" "oso-gato/.." "oso gato/x" ""; do
  goc ensure "$bad" >/dev/null 2>&1
  [ "$?" -eq 0 ] && { no "A10 unusable slug '$bad' refused" "it returned rc 0"; continue; }
  ok "A10 unusable slug '$bad' is refused"
done
ck "A10 no refusal touched the cache" "$(ls -A "$CACHE" | sort)" "$before"
mkdir -p "$TMP/occupied"; printf 'mine\n' > "$TMP/occupied/keep"
goc clone oso-gato/alpha "$TMP/occupied" >/dev/null 2>&1
ck "A10 a non-empty destination is refused, untouched" \
   "$?|$(cat "$TMP/occupied/keep")|$(ls -A "$TMP/occupied" | tr '\n' ' ')" "1|mine|keep "
goc ensure oso-gato/nosuchrepo >/dev/null 2>&1
ck "A10 an unreachable origin is rc 1 with no half-mirror left" \
   "$?|$(ls -Ad "$CACHE"/oso-gato-nosuchrepo* 2>/dev/null | wc -l)" "1|0"

# --- A11: MEASURED OBJECT SOURCE. With the origin GONE, a clone that still carries the full history can
# only have taken its objects from the local mirror. Exact, and independent of filesystem and network.
rm -rf "$CACHE" "$TMP/c2"
goc ensure oso-gato/alpha >/dev/null 2>&1
want="$(git -C "$ORIGINS/oso-gato/alpha.git" rev-list --count refs/heads/main)"
mv "$ORIGINS/oso-gato/alpha.git" "$ORIGINS/oso-gato/alpha.git.away"
err="$(goc clone oso-gato/alpha "$TMP/c2" 2>&1 >/dev/null)"; rc=$?
ck "A11 the clone succeeds with the origin gone" "$rc" "0"
ck "A11 and carries the WHOLE history — the objects came from the mirror" \
   "$(git -C "$TMP/c2" rev-list --count HEAD 2>/dev/null)" "$want"
printf '%s\n' "$err" | grep -q 'delta fetch.*FAILED'
ck "A11 the failed delta fetch is reported, not hidden (fail-soft, said out loud)" "$?" "0"
mv "$ORIGINS/oso-gato/alpha.git.away" "$ORIGINS/oso-gato/alpha.git"

# --- A12: the SHIPPED default origin base is GitHub. The whole suite runs on the file:// seam, so
# without this row the default could drift to anything and every row above would still pass.
grep -q 'ORIGIN_BASE="\${FD_GIT_ORIGIN_BASE:-https://github.com/}"' "$SUT"
ck "A12 the default origin base is https://github.com/" "$?" "0"

# --- A13: THE GC IS WIRED TO MACHINERY THAT ALREADY RUNS. A bound nothing enforces is not a bound, and
# a pure --selftest cannot see an uncalled call site (#278). So the REAL sweeper is driven and must
# evict a real aged mirror. HOME is fixtured: the sweeper also reaps throwaway trees under $HOME/.cache.
SWEEP="$REPO/bin/build-throwaway.sh"
if [ -x "$SWEEP" ]; then
  rm -rf "$CACHE"; goc ensure oso-gato/alpha >/dev/null 2>&1
  touch -d '90 days ago' "$CACHE/oso-gato-alpha.git"
  mkdir -p "$TMP/fakehome/.cache"
  env HOME="$TMP/fakehome" FD_GIT_CACHE="$CACHE" FD_GIT_CACHE_MAX_AGE_DAYS=45 \
      bash "$SWEEP" --sweep-only >/dev/null 2>&1
  ck "A13 the throwaway sweeper enforces the git-cache bound" \
     "$([ -d "$CACHE/oso-gato-alpha.git" ] && echo present || echo evicted)" "evicted"
  grep -q 'gc_git_cache' "$SWEEP"; ck "A13 the sweeper calls the git-cache GC by name" "$?" "0"
else no "A13 the throwaway sweeper is wired" "bin/build-throwaway.sh is missing or not executable"; fi

# --- A14: the NEXT STAGE still works on the clone this cache produced. fresh-tree.sh's fetch-then-
# worktree behaviour must not regress: it needs a real origin remote and a resolvable origin/main.
FT="$REPO/bin/fresh-tree.sh"
if [ -x "$FT" ]; then
  rm -rf "$CACHE" "$TMP/c3"; goc clone oso-gato/alpha "$TMP/c3" >/dev/null 2>&1
  wt="$(env FD_WORKTREES="$TMP/wt" FD_BASE_REF=origin/main bash "$FT" "$TMP/c3" test/319 2>/dev/null)"
  ck "A14 fresh-tree cuts a worktree off the cached clone" \
     "$([ -n "$wt" ] && [ -d "$wt" ] && echo yes || echo no)" "yes"
  [ -n "$wt" ] && ck "A14 the worktree sits on origin/main" \
     "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" "$(git -C "$TMP/c3" rev-parse origin/main)"
  [ -n "$wt" ] && git -C "$TMP/c3" worktree remove --force "$wt" 2>/dev/null
else no "A14 fresh-tree still works on a cached clone" "bin/fresh-tree.sh is missing or not executable"; fi

# ============================ MUTATIONS — each row above must bite ============================
mutate(){ # mutate <name> <sed-expr> <must-appear-in-copy> → prints the mutant path, or nothing
  local name="$1" expr="$2" needle="$3" m
  m="$TMP/mut-$name.sh"
  sed "$expr" "$SUT" > "$m" || return 1
  if cmp -s "$SUT" "$m" || ! grep -qF -- "$needle" "$m"; then
    no "MUTATION $name" "the sed did not change the copy — the row would be VACUOUS"; return 1
  fi
  chmod +x "$m"; printf '%s\n' "$m"
}
mgoc(){ local m="$1"; shift; # shellcheck disable=SC2086
  env FD_GIT_CACHE="$CACHE" FD_GIT_ORIGIN_BASE="file://$ORIGINS/" ${GOC_ENV:-} bash "$m" "$@"; }

echo "== MUTATION 1: clone with --shared → the self-containment guard must REFUSE =="
# The guard only earns its place if it fires. Make the clone BORROW objects and it must be rejected
# outright (rc 1, nothing left behind) rather than handed to a caller as a fragile clone.
if m="$(mutate shared 's@git clone --quiet "\$mirror" "\$dest"@git clone --quiet --shared "$mirror" "$dest"@' '--shared "$mirror"')"; then
  rm -rf "$CACHE" "$TMP/m1"
  mgoc "$m" clone oso-gato/alpha "$TMP/m1" >/dev/null 2>&1
  ck "M1 a borrowed-objects clone is refused, leaving nothing behind" \
     "$?|$([ -e "$TMP/m1" ] && echo leaked || echo clean)" "1|clean"
fi

echo "== MUTATION 2: --shared AND the guard neutralized → eviction DESTROYS the clone (A6's inverse) =="
# This is what A6 is protecting against, made real: a clone that borrows its objects loses its history
# when the cache it borrowed from is evicted. If this row does not break, A6 proves nothing.
# (the `@` delimiter is deliberate: with `|` as the delimiter, an escaped literal pipe collides with
#  GNU sed's BRE alternation operator, and the expression silently stops matching.)
if m="$(mutate borrow \
        's@git clone --quiet "\$mirror" "\$dest"@git clone --quiet --shared "$mirror" "$dest"@; s@\[ -e "\$alt/objects/info/alternates" \]@[ -e /nonexistent-alternates ]@' \
        '/nonexistent-alternates')"; then
  rm -rf "$CACHE" "$TMP/m2"
  mgoc "$m" clone oso-gato/alpha "$TMP/m2" >/dev/null 2>&1
  if [ -e "$TMP/m2/.git/objects/info/alternates" ]; then
    GOC_ENV="FD_GIT_CACHE_CAP_BYTES=0" mgoc "$m" gc >/dev/null 2>&1
    n="$(git -C "$TMP/m2" rev-list --count HEAD 2>/dev/null)"
    ck "M2 the borrowing clone LOSES its history when the mirror is evicted" "${n:-broken}" "broken"
  else no "M2 the borrowing clone loses its history" "the mutant produced no alternates link — VACUOUS"; fi
fi

echo "== MUTATION 3: neutralize the age-prune arm → the aged mirror survives its cap =="
if m="$(mutate noage 's@^  done < <(mirror_ages | prune_age_list "\$MAX_AGE_DAYS" "\$now")@  done < <(:)@' 'done < <(:)')"; then
  rm -rf "$CACHE"; mgoc "$m" ensure oso-gato/alpha >/dev/null 2>&1
  touch -d '90 days ago' "$CACHE/oso-gato-alpha.git"
  GOC_ENV="FD_GIT_CACHE_MAX_AGE_DAYS=45" mgoc "$m" gc >/dev/null 2>&1
  ck "M3 without the age arm the aged mirror is never pruned (A7 bites)" \
     "$([ -d "$CACHE/oso-gato-alpha.git" ] && echo present || echo pruned)" "present"
fi

echo "== MUTATION 4: reverse the LRU order → the WRONG mirror is evicted (A8 bites) =="
# Oldest-first instead of newest-first evicts the HOT mirror and keeps the cold one: the same bytes
# freed, the opposite cache. Nothing but an ordering assertion can see this.
if m="$(mutate lru 's|-k1,1rn|-k1,1n|' '-k1,1n')"; then
  rm -rf "$CACHE"
  mgoc "$m" ensure oso-gato/alpha >/dev/null 2>&1
  mgoc "$m" ensure oso-gato/beta  >/dev/null 2>&1
  touch -d '2 days ago' "$CACHE/oso-gato-beta.git"; touch "$CACHE/oso-gato-alpha.git"
  s_new=$(( $(du -sk "$CACHE/oso-gato-alpha.git" | cut -f1) * 1024 ))
  s_old=$(( $(du -sk "$CACHE/oso-gato-beta.git"  | cut -f1) * 1024 ))
  GOC_ENV="FD_GIT_CACHE_MAX_AGE_DAYS=3650 FD_GIT_CACHE_CAP_BYTES=$(( s_new + s_old / 2 ))" \
    mgoc "$m" gc >/dev/null 2>&1
  ck "M4 oldest-first evicts the NEWEST mirror and keeps the oldest" \
     "$([ -d "$CACHE/oso-gato-alpha.git" ] && echo kept || echo evicted)|$([ -d "$CACHE/oso-gato-beta.git" ] && echo kept || echo evicted)" \
     "evicted|kept"
fi

# ============================ PART B — the rx_bytes measurement ============================
# See the header for exactly what this row does and does not prove.
NOISE_FLOOR=131072      # 128 KiB — the stated floor
rx_total(){ local f v s=0 n=0
  for f in /sys/class/net/*/statistics/rx_bytes; do
    [ -r "$f" ] || continue
    read -r v < "$f" 2>/dev/null || continue
    case "$v" in ''|*[!0-9]*) continue;; esac
    s=$(( s + v )); n=$(( n + 1 ))
  done
  [ "$n" -gt 0 ] || return 1
  printf '%s\n' "$s"
}
echo
if ! rx_total >/dev/null 2>&1; then
  echo "== PART B: SKIPPED — no readable interface counters =="
  printf '\ngit-object-cache: %s passed, %s failed (PART B not run)\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] || exit 1
  echo "SKIP: no readable /sys/class/net/*/statistics/rx_bytes — the rx_bytes measurement cannot run here"
  exit 77
fi
echo "== PART B: MEASURED — a second clone receives no bytes over any interface =="
rm -rf "$CACHE" "$TMP/b1" "$TMP/b2"
goc clone oso-gato/alpha "$TMP/b1" >/dev/null 2>&1   # cold: mirror created, history fetched ONCE
rm -rf "$TMP/b1"                                      # the clone is thrown away; the mirror is not
rx0="$(rx_total)"
goc clone oso-gato/alpha "$TMP/b2" >/dev/null 2>&1   # warm: this is the clone under measurement
rc=$?
rx1="$(rx_total)"
delta=$(( rx1 - rx0 ))
printf '  measured: rx_bytes delta across the second clone = %s B (floor %s B)\n' "$delta" "$NOISE_FLOOR"
ck "B1 the second clone succeeded" "$rc" "0"
ck "B1 it carries the whole history" \
   "$(git -C "$TMP/b2" rev-list --count HEAD 2>/dev/null)" \
   "$(git -C "$ORIGINS/oso-gato/alpha.git" rev-list --count refs/heads/main)"
if [ "$delta" -ge 0 ] && [ "$delta" -lt "$NOISE_FLOOR" ]; then
  ok "B1 the rx_bytes delta is below the stated noise floor"
else no "B1 the rx_bytes delta is below the stated noise floor" "delta=$delta B (floor $NOISE_FLOOR B)"; fi

printf '\ngit-object-cache: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
