#!/bin/bash
# test-lb-granola-publish-guard.sh — regression suite for lb-granola-publish-guard.sh.
#
# Guards dotfiles-1o9t: eleven commits of Granola corpus stayed local for eight
# days while the hourly unit reported success, because the only thing that ever
# touched the remote was a push that only ran when something was staged.
#
# Hermetic: every fixture is a local bare repo used as `origin`. Nothing here
# reaches the network, github, or zig-computer.
#
# The three cases that carry the bead, and which must never be deleted:
#   S3  local ahead + remote UNCHANGED, heal off -> NON-ZERO. The plain assert.
#   S8  STALE TRACKING REF, remote genuinely ahead -> still detected. This is the
#       `ls-remote`-not-`@{u}` acceptance criterion, and the ONLY case that fails
#       if someone "simplifies" the check to rev-list @{u}..HEAD.
#   S6  conflicting divergence -> NON-ZERO, no merge left in progress, HEAD
#       unmoved. A refused merge is two writers conflicting, not a tree to clean.
#
# Usage: bash agents/scheduler/test-lb-granola-publish-guard.sh   (exit 0 = pass)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# Overridable so a mutant copy can be run through the same suite. A green suite
# is not evidence that a guard bites; only a mutant that dies is.
SCRIPT="${LBGPG_SCRIPT:-$HERE/lb-granola-publish-guard.sh}"
ROOT_T=$(mktemp -d "${TMPDIR:-/tmp}/lbgpg.XXXXXX")
PASS=0; FAIL=0

cleanup() { rm -rf "$ROOT_T"; }
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

eq() { # eq <desc> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 -- got [$2], wanted [$3]"; fi
}
has() { # has <desc> <haystack> <needle>
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 -- expected to find: $3" ;; esac
}
hasnt() { # hasnt <desc> <haystack> <needle>
  case "$2" in *"$3"*) bad "$1 -- did NOT expect: $3" ;; *) ok "$1" ;; esac
}

gc() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }

# A fresh fixture: bare origin + a clone at $ROOT_T/<name>/work, one base commit.
fixture() {
  # Two statements on purpose: `local n=$1 d="$ROOT_T/$n"` expands EVERY word
  # before it assigns any of them, so `$n` is unset there and `set -u` kills the
  # subshell — quietly, since the caller only sees an empty path.
  local n=$1
  local d="$ROOT_T/$n"
  rm -rf "$d"; mkdir -p "$d"
  git init -q --bare "$d/origin.git"
  git init -q -b main "$d/work"
  mkdir -p "$d/work/data"
  echo base > "$d/work/data/base.txt"
  echo 'var/' > "$d/work/.gitignore"        # as in the real corpus: var/ is not tracked
  gc "$d/work" add data/base.txt .gitignore
  gc "$d/work" commit -qm base
  gc "$d/work" remote add origin "$d/origin.git"
  gc "$d/work" push -q origin main
  gc "$d/work" branch --set-upstream-to=origin/main main >/dev/null
  echo "$d"
}

# A second writer with its own clone of the same origin.
second_writer() { # <fixture dir> <file> <content>
  local d=$1
  [ -d "$d/other" ] || git clone -q "$d/origin.git" "$d/other"
  gc "$d/other" fetch -q origin
  gc "$d/other" checkout -q main
  gc "$d/other" reset -q --hard origin/main
  printf '%s\n' "$3" > "$d/other/$2"
  gc "$d/other" add "$2"
  gc "$d/other" commit -qm "other: $2"
  gc "$d/other" push -q origin main
}

run() { # run <fixture dir> [env assignments...] -> sets OUT / RC
  local d=$1; shift
  OUT=$(env LB_GRANOLA_ROOT="$d/work" \
            LBG_GUARD_STAMP="$d/stamp" \
            LBG_GUARD_LOCK_WAIT=5 \
            LBG_GUARD_NET_TIMEOUT=30 \
            GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
            GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
            "$@" bash "$SCRIPT" 2>&1)
  RC=$?
}

origin_tip() { git -C "$1/origin.git" rev-parse refs/heads/main; }
local_tip()  { git -C "$1/work" rev-parse HEAD; }

echo "== lb-granola-publish-guard.sh =="

# --- S1: already in sync -----------------------------------------------------
D=$(fixture s1)
run "$D"
eq  "S1 in-sync exits 0" "$RC" 0
has "S1 says published"  "$OUT" "LBG_PUBLISH_GUARD=ok"
[ -s "$D/stamp" ] && ok "S1 writes the verified-publish stamp" || bad "S1 stamp missing"

# --- S2: local ahead, heal ON -> pushes and passes ---------------------------
D=$(fixture s2)
echo more > "$D/work/data/a.txt"; gc "$D/work" add data/a.txt; gc "$D/work" commit -qm "granola: 1 delivery"
BEFORE=$(origin_tip "$D")
run "$D"
eq  "S2 heal pushes, exits 0" "$RC" 0
eq  "S2 origin advanced to local HEAD" "$(origin_tip "$D")" "$(local_tip "$D")"
hasnt "S2 origin did not stay put" "$(origin_tip "$D")" "$BEFORE"

# --- S3: local ahead, heal OFF -> the plain assert must FAIL ------------------
D=$(fixture s3)
echo more > "$D/work/data/a.txt"; gc "$D/work" add data/a.txt; gc "$D/work" commit -qm "granola: 1 delivery"
BEFORE=$(origin_tip "$D")
run "$D" LBG_GUARD_HEAL=0
eq  "S3 unpushed commit with heal off exits non-zero" "$RC" 1
has "S3 names the failure" "$OUT" "is not on origin"
has "S3 emits the failed result line" "$OUT" "LBG_PUBLISH_GUARD=failed"
eq  "S3 assert-only never wrote to the remote" "$(origin_tip "$D")" "$BEFORE"

# --- S4: non-conflicting divergence -> merge + push --------------------------
D=$(fixture s4)
second_writer "$D" "data/theirs.txt" "theirs"
echo mine > "$D/work/data/mine.txt"; gc "$D/work" add data/mine.txt; gc "$D/work" commit -qm "granola: 1 delivery"
MINE=$(local_tip "$D")
run "$D"
eq  "S4 divergence self-heals, exits 0" "$RC" 0
has "S4 says it merged" "$OUT" "merging"
eq  "S4 origin now has our commit" \
    "$(git -C "$D/work" merge-base --is-ancestor "$MINE" "$(origin_tip "$D")" && echo yes)" "yes"
[ -f "$D/work/data/theirs.txt" ] && ok "S4 kept the other writer's file" || bad "S4 lost the other writer's file"

# --- S5: purely behind -> not a publish failure, and it catches up -----------
D=$(fixture s5)
second_writer "$D" "data/theirs.txt" "theirs"
run "$D"
eq  "S5 behind-only exits 0" "$RC" 0
eq  "S5 fast-forwarded to origin" "$(local_tip "$D")" "$(origin_tip "$D")"

# --- S6: CONFLICTING divergence -> loud failure, corpus untouched ------------
D=$(fixture s6)
second_writer "$D" "data/clash.txt" "theirs"
echo mine > "$D/work/data/clash.txt"; gc "$D/work" add data/clash.txt; gc "$D/work" commit -qm "granola: 1 delivery"
MINE=$(local_tip "$D")
BEFORE=$(origin_tip "$D")
run "$D"
eq  "S6 refused merge exits non-zero" "$RC" 1
has "S6 says the merge was refused" "$OUT" "REFUSED"
eq  "S6 HEAD is exactly where it was" "$(local_tip "$D")" "$MINE"
eq  "S6 left no merge in progress" \
    "$(git -C "$D/work" rev-parse -q --verify MERGE_HEAD >/dev/null && echo mid-merge || echo clean)" "clean"
eq  "S6 did not push over the other writer" "$(origin_tip "$D")" "$BEFORE"
# It must STOP, not push-and-fail: a mutant that only downgrades the refused
# merge to a warning still exits non-zero (the rejected push does it) and is
# otherwise invisible. The cause reported to the journal is the whole value here.
hasnt "S6 never even attempts a push" "$OUT" "pushing main"
eq  "S6 working tree is clean" "$(git -C "$D/work" status --porcelain)" ""

# --- S7: the banned verbs are not in the script ------------------------------
# AGENTS.md's measurement: stash "succeeds" by silently taking the other writer's
# work. A future edit reaching for one of these is the regression this catches.
BODY=$(grep -vE '^\s*#' "$SCRIPT")
for verb in 'stash' 'reset --hard' 'rebase' 'push --force' 'force-with-lease'; do
  case "$BODY" in
    *"$verb"*) bad "S7 script contains a banned verb: $verb" ;;
    *)         ok  "S7 no '$verb' in executable lines" ;;
  esac
done

# --- S8: a STALE TRACKING REF must not fool it -------------------------------
# The acceptance criterion in the bead. origin/main is forced to look identical
# to HEAD while the real remote has moved on; @{u} therefore reports "in sync"
# and only ls-remote knows better.
D=$(fixture s8)
second_writer "$D" "data/theirs.txt" "theirs"
echo mine > "$D/work/data/mine.txt"; gc "$D/work" add data/mine.txt; gc "$D/work" commit -qm "granola: 1 delivery"
MINE=$(local_tip "$D")
gc "$D/work" update-ref refs/remotes/origin/main "$MINE"     # the lie
eq  "S8 the stale tracking ref really does claim in-sync" \
    "$(git -C "$D/work" rev-list --count '@{u}..HEAD')" "0"
run "$D" LBG_GUARD_HEAL=0
eq  "S8 ls-remote sees through the stale tracking ref" "$RC" 1
has "S8 reports the real remote tip" "$OUT" "$(origin_tip "$D")"

# --- S9: remote unreachable, INSIDE the grace -> degraded but green -----------
D=$(fixture s9)
date +%s > "$D/stamp"
gc "$D/work" remote set-url origin "$ROOT_T/does-not-exist.git"
run "$D" LBG_GUARD_GRACE_SEC=10800
eq  "S9 unreachable remote inside grace exits 0" "$RC" 0
has "S9 says degraded, not ok" "$OUT" "LBG_PUBLISH_GUARD=degraded"

# --- S10: remote unreachable, PAST the grace -> red --------------------------
D=$(fixture s10)
echo 1 > "$D/stamp"        # epoch 1970: as stale as it gets
gc "$D/work" remote set-url origin "$ROOT_T/does-not-exist.git"
run "$D" LBG_GUARD_GRACE_SEC=10800
eq  "S10 unreachable past grace exits non-zero" "$RC" 1
has "S10 explains why" "$OUT" "remote unreachable"

# --- S11: never verified + unreachable -> red on the first tick --------------
D=$(fixture s11)
gc "$D/work" remote set-url origin "$ROOT_T/does-not-exist.git"
run "$D"
eq  "S11 no stamp + unreachable exits non-zero" "$RC" 1

# --- S12: detached HEAD -> red -----------------------------------------------
D=$(fixture s12)
gc "$D/work" checkout -q --detach HEAD
run "$D"
eq  "S12 detached HEAD exits non-zero" "$RC" 1
has "S12 names the detachment" "$OUT" "detached HEAD"

# --- S13: the branch does not exist on the remote at all ---------------------
D=$(fixture s13)
git -C "$D/origin.git" update-ref -d refs/heads/main
run "$D" LBG_GUARD_HEAL=0
eq  "S13 absent remote branch with heal off exits non-zero" "$RC" 1
has "S13 says the branch is absent" "$OUT" "branch absent"
run "$D"
eq  "S13 heal recreates the remote branch, exits 0" "$RC" 0
eq  "S13 origin now matches local" "$(origin_tip "$D")" "$(local_tip "$D")"

# --- S14: the commit lock is honoured ----------------------------------------
# `lb-granola commit` holds var/commit.lock with flock(2) around add/commit/push.
# Merging underneath it is the one thing this guard must never do.
D=$(fixture s14)
mkdir -p "$D/work/var"; : > "$D/work/var/commit.lock"
flock "$D/work/var/commit.lock" sleep 8 &
HOLDER=$!
sleep 0.5
run "$D" LBG_GUARD_LOCK_WAIT=1
eq  "S14 refuses to run while commit.lock is held" "$RC" 1
has "S14 says which lock"  "$OUT" "commit.lock"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# --- S15: a repo path that is not a git repo ---------------------------------
D=$(fixture s15)
run "$D" LB_GRANOLA_ROOT="$ROOT_T/nope"
eq  "S15 non-repo exits non-zero" "$RC" 1
has "S15 says so" "$OUT" "not a git repository"

echo
printf 'lb-granola-publish-guard: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
