#!/usr/bin/env bash
# Test for demesne-sync.sh — the re-sync mechanism and the identity gate for
# the agent-brain split cutover (dotfiles-lg1z).
#
# HERMETIC, except where it says otherwise. Every case builds its own src/dest
# fixture pair under $WORK; the real ~/dotfiles and ~/demesne are read by
# exactly two cases (22 and 23, the rule-2 as-committed checks) and written by
# none. The seams are DEMESNE_SYNC_SRC / DEMESNE_SYNC_DEST — the script's
# defaults are never allowed to apply to a case that writes.
#
# THE FIXTURES USE THE REAL, COMMITTED EXCLUSION LIST. DEMESNE_SYNC_EXCLUDE_FILE
# is overridden only by the three cases that are ABOUT a malformed list (16,17).
# That is deliberate: cases 5 and 8 pass only if `__pycache__`, `*.pyc` and
# `.ruff_cache` are really in demesne-sync.exclude, so deleting a line from the
# committed list turns this suite red. The list is data, and data can rot —
# same posture as test-pico-health.sh case 20.
#
# MEASURED mutant -> failing cases (2026-08-09; re-measure if you change a case,
# and do not write this map from memory):
#
#   M1  every exclusion pattern replaced by a never-matching one -> 5 8 16 17
#   M2  --delete widened to the whole tree (one rsync)           -> 6 21
#
# That map is EXECUTABLE, not a comment: mutate-demesne-sync.sh applies both and
# asserts each dies on exactly the cases named here. tools/githooks/pre-commit
# runs both.
#
# Convention matches the other agents/scheduler suites: executable bash, non-zero
# exit = failure, PASS/FAIL summary on the last line.

set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/demesne-sync.sh"
REAL_EXCLUDE="$HERE/demesne-sync.exclude"

PASS=0
FAIL=0
FAILED_NAMES=()
ok() {
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$1")
  printf '  FAIL %s\n     -> %s\n' "$1" "${2:-}"
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-demesne-sync.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

[ -f "$SCRIPT" ] || { echo "MISSING: $SCRIPT"; exit 2; }
[ -f "$REAL_EXCLUDE" ] || { echo "MISSING: $REAL_EXCLUDE"; exit 2; }

# --- fixture helpers -------------------------------------------------------

# mkpair <name> — a matching src/dest brain pair. Identical by construction, so
# any case that wants drift has to introduce it explicitly.
mkpair() {
  local n=$1 root="$WORK/$1" side
  for side in src dest; do
    mkdir -p "$root/$side/agents/sub" "$root/$side/refs" "$root/$side/claude" \
             "$root/$side/zsh" "$root/$side/tmux"
    printf 'agent tier\n' > "$root/$side/agents/a.sh"
    printf 'nested\n'      > "$root/$side/agents/sub/b.md"
    printf 'reference\n'   > "$root/$side/refs/r.md"
    printf '{"k":1}\n'     > "$root/$side/claude/settings.json"
    printf 'env tier\n'    > "$root/$side/zsh/.zshenv"
    printf 'mux tier\n'    > "$root/$side/tmux/.tmux.conf"
  done
  printf '%s' "$root"
}

# run <src> <dest> [args…] — invoke the script, capture stdout+stderr and rc.
# OUT and RC are the assertion surface; LAST is the contract line.
run() {
  local src=$1 dest=$2
  shift 2
  OUT=$(DEMESNE_SYNC_SRC="$src" DEMESNE_SYNC_DEST="$dest" bash "$SCRIPT" "$@" 2>&1)
  RC=$?
  LAST=$(printf '%s\n' "$OUT" | grep -E '^DEMESNE_(SYNC|GATE)_RESULT=' | tail -1)
  return 0
}

# gitfix <dir> — turn a fixture dir into a committed git repo. --no-verify
# because a fixture must not inherit whatever hooksPath the real clone set.
gitfix() {
  local d=$1
  git -C "$d" init -q -b main
  git -C "$d" add -A -- . >/dev/null
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --no-verify -m fixture >/dev/null
}

# --- 1 -- usage ------------------------------------------------------------
OUT=$(bash "$SCRIPT" --help 2>&1); RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'Usage: demesne-sync.sh'; then
  ok "1 --help exits 0 and prints usage"
else
  bad "1 --help exits 0 and prints usage" "rc=$RC out=$OUT"
fi

OUT=$(bash "$SCRIPT" --nonsense 2>&1); RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'unknown option'; then
  ok "1b an unknown option is rejected"
else
  bad "1b an unknown option is rejected" "rc=$RC"
fi

# --- 2 -- the gate over identical trees ------------------------------------
R=$(mkpair identical)
run "$R/src" "$R/dest" --gate
if [ "$RC" -eq 0 ] && [ "$LAST" = "DEMESNE_GATE_RESULT=IDENTICAL dirs=5 entries=0" ]; then
  ok "2 identical trees: gate exits 0 with IDENTICAL entries=0"
else
  bad "2 identical trees: gate exits 0 with IDENTICAL entries=0" "rc=$RC last=$LAST"
fi

# --- 3 -- REAL DRIFT: a file on one side only ------------------------------
# The plain case the gate exists for: work landed in dotfiles and never reached
# demesne. exit 10 is the code a caller branches on, and the drift is LISTED —
# a gate that says "no" without saying what is the one nobody acts on.
R=$(mkpair drift)
printf 'brand new hook\n' > "$R/src/agents/new-hook.sh"
printf 'changed\n' > "$R/src/refs/r.md"
run "$R/src" "$R/dest" --gate
if [ "$RC" -eq 10 ] &&
   [ "$LAST" = "DEMESNE_GATE_RESULT=DRIFT dirs=5 entries=2" ] &&
   printf '%s' "$OUT" | grep -q 'new-hook.sh' &&
   printf '%s' "$OUT" | grep -q 'r.md'; then
  ok "3 drift: gate exits 10, entries=2, and NAMES both entries"
else
  bad "3 drift: gate exits 10, entries=2, and NAMES both entries" "rc=$RC last=$LAST"
fi

# --- 4 -- and the sync closes it -------------------------------------------
run "$R/src" "$R/dest"
SYNC_LAST=$LAST; SYNC_RC=$RC
run "$R/src" "$R/dest" --gate
if [ "$SYNC_RC" -eq 0 ] && printf '%s' "$SYNC_LAST" | grep -q '^DEMESNE_SYNC_RESULT=OK dirs=5 changed=' &&
   [ "$RC" -eq 0 ] && [ "$LAST" = "DEMESNE_GATE_RESULT=IDENTICAL dirs=5 entries=0" ] &&
   [ "$(cat "$R/dest/refs/r.md")" = "changed" ] &&
   [ -f "$R/dest/agents/new-hook.sh" ]; then
  ok "4 sync closes the drift: gate goes 10 -> 0 and the content really landed"
else
  bad "4 sync closes the drift" "sync=$SYNC_LAST gate rc=$RC last=$LAST"
fi

# --- 5 -- CACHE-ONLY DRIFT IS NOT DRIFT (M1's target) ----------------------
# The state lg1z was filed for. Both trees carry bytecode and test-runner caches
# that nobody syncs, so a gate that sees them can never read empty — and a gate
# that can never pass is a gate nobody runs. Every path here is in the REAL
# committed exclusion list; deleting a line from it turns this case red.
R=$(mkpair cacheonly)
mkdir -p "$R/dest/agents/__pycache__" "$R/dest/refs/.ruff_cache" "$R/src/agents/sub/__pycache__" \
         "$R/src/claude/.pytest_cache" "$R/dest/agents/sub/node_modules/dep"
printf 'x\n' > "$R/dest/agents/__pycache__/mod.cpython-313.pyc"
printf 'x\n' > "$R/dest/refs/.ruff_cache/CACHEDIR.TAG"
printf 'x\n' > "$R/src/agents/sub/__pycache__/other.cpython-313.pyc"
printf 'x\n' > "$R/src/claude/.pytest_cache/lastfailed"
printf 'x\n' > "$R/dest/agents/sub/node_modules/dep/index.js"
printf 'x\n' > "$R/src/agents/loose.pyc"
run "$R/src" "$R/dest" --gate
if [ "$RC" -eq 0 ] && [ "$LAST" = "DEMESNE_GATE_RESULT=IDENTICAL dirs=5 entries=0" ]; then
  ok "5 cache-only drift is invisible to the gate (6 excluded paths, both sides)"
else
  bad "5 cache-only drift is invisible to the gate" "rc=$RC last=$LAST out=$(printf '%s' "$OUT" | head -20)"
fi

# --- 6 -- DEMESNE-ONLY CONTENT OUTSIDE THE SUBTREE SURVIVES (M2's target) --
# demesne has its own life — docs/, audits/, CLAUDE.md, the host-service dirs
# the seed copied. --delete is scoped per synced directory precisely so none of
# it is reachable. A single whole-tree `rsync --delete "$SRC/" "$DEST/"` would
# be shorter and would take all of it, silently, on the first run.
R=$(mkpair preserve)
mkdir -p "$R/dest/docs" "$R/dest/audits" "$R/dest/tailscale"
printf 'demesne doc\n'   > "$R/dest/docs/keep.md"
printf 'audit\n'         > "$R/dest/audits/2026-08-09.md"
printf 'private ident\n' > "$R/dest/CLAUDE.md"
printf 'acl\n'           > "$R/dest/tailscale/acl.jsonc"
printf 'new\n'           > "$R/src/agents/new.sh"
run "$R/src" "$R/dest"
SURVIVED=1
for f in docs/keep.md audits/2026-08-09.md CLAUDE.md tailscale/acl.jsonc; do
  [ -f "$R/dest/$f" ] || SURVIVED=0
done
if [ "$RC" -eq 0 ] && [ "$SURVIVED" -eq 1 ] &&
   [ "$(cat "$R/dest/docs/keep.md")" = "demesne doc" ] &&
   [ -f "$R/dest/agents/new.sh" ]; then
  ok "6 demesne-only content OUTSIDE the synced dirs survives a --delete sync"
else
  bad "6 demesne-only content OUTSIDE the synced dirs survives a --delete sync" \
      "rc=$RC survived=$SURVIVED last=$LAST"
fi

# --- 7 -- …but INSIDE the subtree, --delete is supposed to bite ------------
# The converse discipline. Case 6 alone would pass on a sync that never deletes
# anything, and a sync that never deletes cannot produce identity: a file
# removed from dotfiles has to leave demesne too, or the gate stays red forever.
R=$(mkpair deletes-inside)
printf 'stale\n' > "$R/dest/agents/removed-upstream.sh"
run "$R/src" "$R/dest"
if [ "$RC" -eq 0 ] && [ ! -e "$R/dest/agents/removed-upstream.sh" ]; then
  ok "7 a dest-only file INSIDE a synced dir is deleted (identity needs this)"
else
  bad "7 a dest-only file INSIDE a synced dir is deleted" "rc=$RC still=$(ls "$R/dest/agents")"
fi

# --- 8 -- excluded receiver-side files are PROTECTED from --delete ---------
# rsync only deletes excluded files on the receiver when --delete-excluded is
# passed, and it must never be: demesne runs its own test suites, so its own
# __pycache__ is legitimately its own. Together with case 7 this pins the exact
# deletion scope.
R=$(mkpair protect-excluded)
mkdir -p "$R/dest/agents/__pycache__"
printf 'local build\n' > "$R/dest/agents/__pycache__/local.cpython-313.pyc"
run "$R/src" "$R/dest"
if [ "$RC" -eq 0 ] && [ -f "$R/dest/agents/__pycache__/local.cpython-313.pyc" ]; then
  ok "8 the receiver's own excluded files are NOT deleted by the sync"
else
  bad "8 the receiver's own excluded files are NOT deleted" "rc=$RC"
fi

# --- 9 -- DIRTY DESTINATION: refuse ----------------------------------------
# The two-writers doctrine, across repos. A dirty ~/demesne means another
# process owns files there right now; rsync --delete would take that work with
# no diff and no undo. The refusal must also be INERT — the pending source
# change must not have half-landed before the check ran.
R=$(mkpair dirty)
gitfix "$R/dest"
printf 'another writer was here\n' > "$R/dest/agents/a.sh"
printf 'upstream\n' > "$R/src/agents/incoming.sh"
run "$R/src" "$R/dest"
if [ "$RC" -eq 2 ] && [ "$LAST" = "DEMESNE_SYNC_RESULT=REFUSED reason=dest-dirty" ] &&
   [ "$(cat "$R/dest/agents/a.sh")" = "another writer was here" ] &&
   [ ! -e "$R/dest/agents/incoming.sh" ]; then
  ok "9 a dirty destination is REFUSED (exit 2) and nothing was written"
else
  bad "9 a dirty destination is REFUSED and nothing was written" "rc=$RC last=$LAST"
fi

# --- 9b -- a CLEAN git destination syncs normally --------------------------
# Without this, case 9 would also pass on a script that refuses every git
# destination, which is a brick rather than a guard.
git -C "$R/dest" checkout -q -- agents/a.sh
run "$R/src" "$R/dest"
if [ "$RC" -eq 0 ] && printf '%s' "$LAST" | grep -q '^DEMESNE_SYNC_RESULT=OK' &&
   [ -f "$R/dest/agents/incoming.sh" ]; then
  ok "9b the same destination, now clean, syncs normally"
else
  bad "9b the same destination, now clean, syncs normally" "rc=$RC last=$LAST"
fi

# --- 10 -- a non-git destination says so out loud --------------------------
R=$(mkpair nongit)
run "$R/src" "$R/dest"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'not a git work tree'; then
  ok "10 a non-git destination is synced, and the missing check is stated"
else
  bad "10 a non-git destination is synced, and the missing check is stated" "rc=$RC"
fi

# --- 11 -- ONE WAY. The source is never written ----------------------------
# There is no reverse mode and there must be no accidental one: dest-only
# content inside the subtree must not travel back up.
R=$(mkpair oneway)
printf 'dest invention\n' > "$R/dest/agents/dest-only.sh"
printf 'dest edit\n' > "$R/dest/refs/r.md"
BEFORE=$(cd "$R/src" && find . -type f -exec sha256sum {} + | sort)
run "$R/src" "$R/dest"
AFTER=$(cd "$R/src" && find . -type f -exec sha256sum {} + | sort)
if [ "$RC" -eq 0 ] && [ "$BEFORE" = "$AFTER" ]; then
  ok "11 one way: the source tree is byte-identical before and after a sync"
else
  bad "11 one way: the source tree is byte-identical before and after a sync" "rc=$RC"
fi

# --- 12 -- --dry-run, both modes, changes nothing --------------------------
R=$(mkpair dryrun)
printf 'incoming\n' > "$R/src/agents/incoming.sh"
run "$R/src" "$R/dest" --dry-run
D1_RC=$RC; D1_LAST=$LAST
run "$R/src" "$R/dest" --gate --dry-run
if [ "$D1_RC" -eq 0 ] && printf '%s' "$D1_LAST" | grep -q '^DEMESNE_SYNC_RESULT=DRYRUN dirs=5 changed=' &&
   [ ! -e "$R/dest/agents/incoming.sh" ] &&
   [ "$RC" -eq 0 ] && [ "$LAST" = "DEMESNE_GATE_RESULT=DRYRUN dirs=5" ] &&
   printf '%s' "$OUT" | grep -q 'would run: diff -rq'; then
  ok "12 --dry-run in both modes exits 0, writes nothing, and reports DRYRUN"
else
  bad "12 --dry-run in both modes" "sync rc=$D1_RC last=$D1_LAST / gate rc=$RC last=$LAST"
fi

# --- 13 -- preflight refusals ----------------------------------------------
R=$(mkpair preflight)
run "$R/src" "$R/nope" --gate
P1=$([ "$RC" -eq 1 ] && printf '%s' "$LAST" | grep -q 'ERROR reason=dest-missing' && echo 1 || echo 0)
run "$R/src" "$R/src"
P2=$([ "$RC" -eq 1 ] && printf '%s' "$LAST" | grep -q 'ERROR reason=src-equals-dest' && echo 1 || echo 0)
mkdir -p "$R/src/inner"
run "$R/src" "$R/src/inner"
P3=$([ "$RC" -eq 1 ] && printf '%s' "$LAST" | grep -q 'ERROR reason=dest-inside-src' && echo 1 || echo 0)
if [ "$P1$P2$P3" = "111" ]; then
  ok "13 preflight refuses: dest-missing, src-equals-dest, dest-inside-src"
else
  bad "13 preflight refuses the three unsafe root pairings" "p1=$P1 p2=$P2 p3=$P3 last=$LAST"
fi

# --- 14 -- a malformed exclusion list is fatal, in BOTH modes --------------
# A slashed pattern means one thing to rsync and another to `diff -x`, which is
# exactly the two-lists drift the single-file design exists to prevent. Better
# to refuse than to run a sync and a gate that disagree.
R=$(mkpair badlist)
printf 'a/b\n' > "$WORK/slashed.exclude"
OUT=$(DEMESNE_SYNC_SRC="$R/src" DEMESNE_SYNC_DEST="$R/dest" \
      DEMESNE_SYNC_EXCLUDE_FILE="$WORK/slashed.exclude" bash "$SCRIPT" --gate 2>&1); RC=$?
B1=$([ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'DEMESNE_GATE_RESULT=ERROR reason=bad-exclusion-list' && echo 1 || echo 0)
printf '# only a comment\n\n' > "$WORK/empty.exclude"
OUT=$(DEMESNE_SYNC_SRC="$R/src" DEMESNE_SYNC_DEST="$R/dest" \
      DEMESNE_SYNC_EXCLUDE_FILE="$WORK/empty.exclude" bash "$SCRIPT" 2>&1); RC=$?
B2=$([ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'DEMESNE_SYNC_RESULT=ERROR reason=bad-exclusion-list' && echo 1 || echo 0)
OUT=$(DEMESNE_SYNC_SRC="$R/src" DEMESNE_SYNC_DEST="$R/dest" \
      DEMESNE_SYNC_EXCLUDE_FILE="$WORK/nosuch.exclude" bash "$SCRIPT" 2>&1); RC=$?
B3=$([ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'reason=bad-exclusion-list' && echo 1 || echo 0)
if [ "$B1$B2$B3" = "111" ]; then
  ok "14 a slashed / empty / missing exclusion list is fatal in both modes"
else
  bad "14 a malformed exclusion list is fatal" "slashed=$B1 empty=$B2 missing=$B3"
fi

# --- 15 -- the committed exclusion list is DATA, and data can rot ----------
# The convention arm of tools/githooks/pre-commit gates scripts, not data files
# — so without this case a line deleted from demesne-sync.exclude ("it was
# noisy") would be gated on nothing while every hole it opens is invisible.
EX_PATTERNS=$(sed 's/#.*//' "$REAL_EXCLUDE" | awk 'NF { print $1 }')
EX_N=$(printf '%s' "$EX_PATTERNS" | grep -c .)
EX_SLASHED=$(printf '%s\n' "$EX_PATTERNS" | grep '/' || true)
EX_DUPES=$(printf '%s\n' "$EX_PATTERNS" | sort | uniq -d)
EX_EXTRA=$(sed 's/#.*//' "$REAL_EXCLUDE" | awk 'NF > 1 { print }')
EX_MISSING=""
for p in '__pycache__' '.ruff_cache' '.pytest_cache' 'node_modules' '*.pyc' '.DS_Store'; do
  printf '%s\n' "$EX_PATTERNS" | grep -qxF "$p" || EX_MISSING="$EX_MISSING $p"
done
if [ "$EX_N" -ge 6 ] && [ -z "$EX_SLASHED" ] && [ -z "$EX_DUPES" ] &&
   [ -z "$EX_EXTRA" ] && [ -z "$EX_MISSING" ]; then
  ok "15 the committed demesne-sync.exclude parses: $EX_N patterns, all six required present"
else
  bad "15 the committed demesne-sync.exclude parses" \
      "n=$EX_N missing=[$EX_MISSING] slashed=[$EX_SLASHED] dupes=[$EX_DUPES] extra=[$EX_EXTRA]"
fi

# --- 16 -- THE BLINDNESS CHECK: an exclusion may not hide tracked content --
# Every exclusion is a hole in the gate. If the list ever grows a pattern that
# matches real, tracked brain content, the gate reads IDENTICAL over content it
# never compared — the worst possible failure, because it is a PASS.
R=$(mkpair shadow)
mkdir -p "$R/src/agents/vendor/node_modules"
printf 'real tracked content\n' > "$R/src/agents/vendor/node_modules/lib.js"
gitfix "$R/src"
run "$R/src" "$R/dest" --gate
S1=$([ "$RC" -eq 2 ] && printf '%s' "$LAST" | grep -q 'ERROR reason=exclusion-shadows-tracked-file' && echo 1 || echo 0)
run "$R/src" "$R/dest"
S2=$([ "$RC" -eq 2 ] && printf '%s' "$LAST" | grep -q 'REFUSED reason=exclusion-shadows-tracked-file' && echo 1 || echo 0)
if [ "$S1$S2" = "11" ]; then
  ok "16 an exclusion that hides TRACKED source content refuses, in both modes"
else
  bad "16 an exclusion that hides TRACKED source content refuses" "gate=$S1 sync=$S2 last=$LAST"
fi

# --- 17 -- …but tracked-AND-gitignored is debris, not content --------------
# Found live on the first run of the real gate: three .pyc blobs have been
# tracked in ~/dotfiles since 15d271c despite that repo's own .gitignore. A path
# the source repo itself declares ignored is exactly the generated matter the
# list exists to skip; refusing on it would make the gate unrunnable over an
# accident. Warn every run, never block.
R=$(mkpair debris)
# The tests/ dir exists on BOTH sides — only the __pycache__ under it is
# one-sided, so anything this case reports is about the exclusion, not about a
# directory that happens to be missing.
mkdir -p "$R/src/agents/tests/__pycache__" "$R/dest/agents/tests"
printf 'case\n' > "$R/src/agents/tests/t.sh"
printf 'case\n' > "$R/dest/agents/tests/t.sh"
printf '__pycache__/\n*.pyc\n' > "$R/src/.gitignore"
printf 'bytecode\n' > "$R/src/agents/tests/__pycache__/t.cpython-313.pyc"
git -C "$R/src" init -q -b main
git -C "$R/src" add -A -- . >/dev/null
git -C "$R/src" add -f -- agents/tests/__pycache__/t.cpython-313.pyc >/dev/null
git -C "$R/src" -c user.email=t@t -c user.name=t commit -q --no-verify -m fixture >/dev/null
run "$R/src" "$R/dest" --gate
if [ "$RC" -eq 0 ] && [ "$LAST" = "DEMESNE_GATE_RESULT=IDENTICAL dirs=5 entries=0" ] &&
   printf '%s' "$OUT" | grep -q 'TRACKED-BUT-GITIGNORED'; then
  ok "17 tracked-but-gitignored debris warns loudly and does NOT block the gate"
else
  bad "17 tracked-but-gitignored debris warns and does not block" "rc=$RC last=$LAST"
fi

# --- 18 -- the contract line is the LAST stdout line on EVERY path ---------
# A caller greps the last line and never parses prose (the demesne-freeze.sh
# verdict discipline). A path that prints its verdict and then keeps talking is
# a path whose result is silently unreadable.
R=$(mkpair contract)
printf 'x\n' > "$R/src/agents/n.sh"
CONTRACT_BAD=""
for args in "--gate" "--gate --dry-run" "--dry-run" ""; do
  # shellcheck disable=SC2086
  RAW=$(DEMESNE_SYNC_SRC="$R/src" DEMESNE_SYNC_DEST="$R/dest" bash "$SCRIPT" $args 2>/dev/null)
  TAIL=$(printf '%s\n' "$RAW" | tail -1)
  case "$TAIL" in
    DEMESNE_SYNC_RESULT=*|DEMESNE_GATE_RESULT=*) ;;
    *) CONTRACT_BAD="$CONTRACT_BAD [${args:-<sync>} -> $TAIL]" ;;
  esac
done
RAW=$(DEMESNE_SYNC_SRC="$R/src" DEMESNE_SYNC_DEST="$WORK/absent" bash "$SCRIPT" 2>/dev/null)
TAIL=$(printf '%s\n' "$RAW" | tail -1)
case "$TAIL" in DEMESNE_SYNC_RESULT=ERROR*) ;; *) CONTRACT_BAD="$CONTRACT_BAD [error-path -> $TAIL]" ;; esac
if [ -z "$CONTRACT_BAD" ]; then
  ok "18 every terminal path ends with its DEMESNE_*_RESULT= line on stdout"
else
  bad "18 every terminal path ends with its contract line" "$CONTRACT_BAD"
fi

# --- 19 -- the synced set is the brain, and only the brain ----------------
# Derived from dotfiles-agent-brain-split-ezeu's own count, WIDENED 2026-08-10
# by zsh + tmux (dotfiles-gu0o's structural half: the agent tier's suites and
# harnesses assert against both — mutate-tap-failover M8 mutates zsh/.zshenv,
# test-hall asserts tmux/ bindings — and a demesne that cannot self-verify its
# gate blocked two real carries in one night). Widening it widens what
# --delete may touch; narrowing it takes a directory out of the gate the
# cutover depends on. Either way it is a decision, not an edit.
DECL=$(grep -n '^SYNCED_DIRS=' "$SCRIPT")
if [ "$DECL" = "$(printf '%s' "$DECL" | grep -F 'SYNCED_DIRS=(agents refs claude zsh tmux)')" ] && [ -n "$DECL" ]; then
  ok "19 the synced set is exactly (agents refs claude zsh tmux)"
else
  bad "19 the synced set is exactly (agents refs claude zsh tmux)" "$DECL"
fi

# --- 20 -- a second sync is a no-op ---------------------------------------
# Convergence: if a clean re-run kept finding work to do, the gate would flap
# and "identical" would mean nothing.
R=$(mkpair converge)
printf 'x\n' > "$R/src/agents/n.sh"
run "$R/src" "$R/dest"
run "$R/src" "$R/dest"
if [ "$RC" -eq 0 ] && [ "$LAST" = "DEMESNE_SYNC_RESULT=OK dirs=5 changed=0" ]; then
  ok "20 an immediate second sync reports changed=0"
else
  bad "20 an immediate second sync reports changed=0" "rc=$RC last=$LAST"
fi

# --- 21 -- rsync failure is reported, not swallowed ------------------------
# Not a permission fixture: `rsync -a` preserves the source's modes, so it
# simply chmods an unwritable destination dir back and carries on — the first
# version of this case passed a broken assertion for that reason. A destination
# path that is a FILE where a synced directory belongs cannot be repaired that
# way, and it is the shape a half-finished hand-copy leaves behind.
R=$(mkpair rsyncfail)
printf 'x\n' > "$R/src/agents/n.sh"
rm -rf "$R/dest/refs"
printf 'not a directory\n' > "$R/dest/refs"
run "$R/src" "$R/dest"
if [ "$RC" -eq 1 ] && printf '%s' "$LAST" | grep -q '^DEMESNE_SYNC_RESULT=ERROR reason=rsync-failed:refs'; then
  ok "21 an rsync failure names the directory and exits 1"
else
  bad "21 an rsync failure names the directory and exits 1" "rc=$RC last=$LAST"
fi

# --- 22 -- THE GATE COMMAND, AS COMMITTED (this repo's rule 2) -------------
# The example in demesne-sync.sh's header is what an operator copies at the
# cutover, so it is executable and it gets executed — extracted from the object
# DB (index blob first, so the very commit that introduces it is gated too;
# HEAD otherwise) and run as those exact bytes, never retyped. Skipped only
# where there is no object DB to read: the mutation harness runs this suite
# from a temp dir outside any repo.
REL="agents/scheduler/demesne-sync.sh"
if git -C "$HERE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then  # allow-suppress
  TOP=$(git -C "$HERE" rev-parse --show-toplevel)
  BLOB=""
  if git -C "$TOP" cat-file -e ":$REL" 2>/dev/null; then BLOB=":$REL"      # allow-suppress
  elif git -C "$TOP" cat-file -e "HEAD:$REL" 2>/dev/null; then BLOB="HEAD:$REL"  # allow-suppress
  fi
  if [ -z "$BLOB" ]; then
    bad "22 the header's gate example runs as committed" "neither the index nor HEAD holds $REL"
  else
    git -C "$TOP" show "$BLOB" > "$WORK/committed-demesne-sync.sh"
    awk '/GATE-EXAMPLE-BEGIN/{f=1;next} /GATE-EXAMPLE-END/{f=0} f{sub(/^# ?/,""); print}' \
      "$WORK/committed-demesne-sync.sh" > "$WORK/gate-example.sh"
    if [ ! -s "$WORK/gate-example.sh" ]; then
      bad "22 the header's gate example runs as committed" "the GATE-EXAMPLE block extracted EMPTY"
    else
      EX_OUT=$(cd "$TOP" && bash "$WORK/gate-example.sh" 2>&1); EX_RC=$?
      EX_VERDICT=$(printf '%s\n' "$EX_OUT" | grep -E '^DEMESNE_GATE_RESULT=' | tail -1)
      EX_ECHO=$(printf '%s\n' "$EX_OUT" | grep -E '^gate exit=' | tail -1)
      # Both 0 (identical) and 10 (drift) are correct gate outcomes; what is
      # under test is that the committed bytes RUN and yield the contract.
      if { [ "$EX_RC" -eq 0 ] || [ "$EX_RC" -eq 10 ]; } &&
         printf '%s' "$EX_VERDICT" | grep -qE '^DEMESNE_GATE_RESULT=(IDENTICAL|DRIFT) ' &&
         [ -n "$EX_ECHO" ]; then
        ok "22 the header's gate example runs as committed ($EX_VERDICT, $EX_ECHO)"
      else
        bad "22 the header's gate example runs as committed" "rc=$EX_RC verdict=[$EX_VERDICT] echo=[$EX_ECHO]"
      fi
    fi
  fi
else
  ok "22 the header's gate example — SKIPPED, no object DB here (mutation-harness run)"
fi

# --- 23 -- the script this repo ships is executable and syntactically sound -
if [ -x "$SCRIPT" ] && bash -n "$SCRIPT"; then
  ok "23 demesne-sync.sh is executable and parses"
else
  bad "23 demesne-sync.sh is executable and parses" "exec=$([ -x "$SCRIPT" ] && echo y || echo n)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf 'PASS %d/%d\n' "$PASS" "$((PASS + FAIL))"
  exit 0
fi
printf 'FAILED:\n'
for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
printf 'FAIL %d/%d\n' "$FAIL" "$((PASS + FAIL))"
exit 1
