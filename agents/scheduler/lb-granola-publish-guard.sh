#!/usr/bin/env bash
# lb-granola-publish-guard.sh — assert the corpus is actually ON THE REMOTE, and
# fail the calling systemd unit when it is not.
#
# WHY THIS EXISTS (dotfiles-1o9t, 2026-08-05). Eight days and eleven commits of
# Granola deliveries sat local-only on zig-computer while `lb-granola-commit`
# reported success every hour. marketing-vps pushed to lb-granola on 2026-07-28
# 22:05; from that moment every `git push` from zig was rejected non-fast-forward.
#
# THE BINARY DOES NOT SWALLOW THAT ERROR — that part of the original diagnosis is
# wrong, and the correction matters because it is what tells you where the fix
# belongs. internal/gitcommit/commit.go returns the push error, main.go exits 1,
# and the journal has the red run to prove it:
#
#   Aug 05 19:29:45 lb-granola-commit[1346719]: lb-granola: git push (commit is
#       local and safe): exit status 1: ! [rejected] main -> main (fetch first)
#   Aug 05 19:29:45 systemd[1487]: lb-granola-commit.service: Main process
#       exited, code=exited, status=1/FAILURE
#
# What actually failed is the OPPOSITE of a swallow — it is a red that erases
# itself. `commit` only reaches the push when something is staged, so the very
# next hourly tick with no new delivery took the `nothing staged; no-op` early
# return, never touched the remote, ran `check` (whose C3 asserts data/ is
# COMMITTED, not PUBLISHED), and exited 0. `systemctl --user --failed` was empty
# again inside the hour, and the timer was green for eight days over a backlog
# that never moved. A oneshot unit has exactly one bit of state and the next
# success overwrites it; an invariant that is only evaluated on the ticks that
# have work is not an invariant.
#
# So this runs on EVERY tick, including the no-op ones, and it compares against
# `git ls-remote` — the network — not against `@{u}`. A stale tracking ref is not
# a weaker check, it is a DIFFERENT and wrong one: it reports whatever the last
# fetch happened to see, and during the 2026-08-05 audit it produced a phantom
# unpushed commit on an unrelated repo. The remote's answer is the only one that
# means published.
#
# IT HEALS THE ORDINARY CASE AND ONLY THE ORDINARY CASE. Two writers landing on
# one branch is a merge, so this fetches, merges --no-edit, and pushes. A merge
# that REFUSES is a conflict between writers, not a tree to clean (AGENTS.md,
# "Two writers, one working tree"): the merge is aborted so the corpus is left
# exactly as it was found, and the unit goes red and STAYS red every hour until a
# human resolves it. There is no `stash`, no `reset --hard`, no `rebase` and no
# `--force` anywhere in this file, and none may be added: the measured failure of
# `stash` here is that it "succeeds" by taking the other writer's work.
#
# THE ONE TOLERATED FAILURE IS AN UNREACHABLE REMOTE, and it is tolerated on a
# clock. `ls-remote` failing means we do not KNOW whether the corpus is published
# — which is not the same fact as knowing it is not — and a desktop that loses
# DNS for ten minutes should not train anyone to ignore this alarm (the unit's own
# header: an alarm that cries wolf hourly is worse than no alarm). So an
# unreachable remote is a warning until LBG_GUARD_GRACE_SEC has elapsed since the
# last VERIFIED publish, and a failure after. Every other unhappy path fails on
# the first tick.
#
# Usage:  lb-granola-publish-guard.sh [--repo PATH]
#
#   Env:
#     LB_GRANOLA_ROOT       corpus repo (default ~/linearb/lb-granola); --repo wins
#     LBG_GUARD_REMOTE      git remote name (default origin)
#     LBG_GUARD_HEAL        1 = fetch+merge+push before asserting (default 1)
#                           0 = assert only; never writes to the remote
#     LBG_GUARD_GRACE_SEC   unreachable-remote tolerance in seconds (default 10800)
#     LBG_GUARD_STAMP       last-verified-published stamp file
#     LBG_GUARD_LOCK_WAIT   seconds to wait for var/commit.lock (default 300)
#     LBG_GUARD_NET_TIMEOUT seconds per network git call (default 120)
#
# Exit 0 = every local commit is on the remote (or the remote is unreachable and
# still inside the grace window). Any non-zero exit is the unit going red.
set -uo pipefail

# An hourly unattended unit must never sit on a credential prompt: that turns a
# loud failure into a hung one, which is the same defect this file exists to fix.
export GIT_TERMINAL_PROMPT=0

REPO="${LB_GRANOLA_ROOT:-$HOME/linearb/lb-granola}"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --repo=*) REPO="${1#--repo=}"; shift ;;
    -h|--help) sed -n '1,80p' "$0"; exit 0 ;;
    *) echo "publish-guard: unknown argument: $1" >&2; exit 2 ;;
  esac
done

REMOTE="${LBG_GUARD_REMOTE:-origin}"
HEAL="${LBG_GUARD_HEAL:-1}"
GRACE="${LBG_GUARD_GRACE_SEC:-10800}"
LOCK_WAIT="${LBG_GUARD_LOCK_WAIT:-300}"
NET_TIMEOUT="${LBG_GUARD_NET_TIMEOUT:-120}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lb-granola"
STAMP="${LBG_GUARD_STAMP:-$STATE_DIR/publish-guard.stamp}"

say()  { printf 'publish-guard: %s\n' "$*"; }
warn() { printf 'publish-guard: %s\n' "$*" >&2; }
die() {
  printf 'publish-guard: FAIL — %s\n' "$*" >&2
  printf 'publish-guard: LBG_PUBLISH_GUARD=failed repo=%s remote=%s\n' "$REPO" "$REMOTE" >&2
  exit 1
}

g() { git -C "$REPO" "$@"; }
gnet() { timeout "$NET_TIMEOUT" git -C "$REPO" "$@"; }

[ -n "$REPO" ] || die "no repo path"
g rev-parse --git-dir >/dev/null 2>&1 || die "$REPO is not a git repository"

BRANCH=$(g symbolic-ref --quiet --short HEAD)
[ -n "$BRANCH" ] || die "detached HEAD in $REPO — commits here are on no branch and cannot be published"

# --- serialise with `lb-granola commit` ------------------------------------
# The binary takes var/commit.lock with LOCK_EX|LOCK_NB around the whole
# add/commit/push. flock(1) and Go's syscall.Flock are the same flock(2) lock, so
# taking it here means this guard can never merge underneath a running commit.
# ExecStartPre/ExecStartPost are sequential with ExecStart, so this cannot
# deadlock against its own unit; the wait is for a human running `commit` by hand.
LOCKFILE="$REPO/var/commit.lock"
if command -v flock >/dev/null 2>&1; then
  mkdir -p "$REPO/var" && touch "$LOCKFILE" || die "cannot create $LOCKFILE"
  exec 9>>"$LOCKFILE"
  if ! flock -w "$LOCK_WAIT" 9; then
    die "var/commit.lock held for more than ${LOCK_WAIT}s — another commit is stuck"
  fi
else
  warn "flock(1) not found; proceeding without the commit lock"
fi

# --- the remote's answer, from the network ---------------------------------
# stderr goes to its own file rather than into the captured stdout: ssh banners
# and "Permanently added ... to the list of known hosts" would otherwise land in
# line 1 and be parsed as a sha.
ERRF=$(mktemp) || die "mktemp failed"
trap 'rm -f "$ERRF"' EXIT

remote_tip() { # -> sha on stdout, empty if the branch does not exist there
  gnet ls-remote "$REMOTE" "refs/heads/$BRANCH" 2>"$ERRF" | awk 'NR==1{print $1}'
}

REMOTE_REACHABLE=1
REMOTE_SHA=""
if LS_OUT=$(gnet ls-remote "$REMOTE" "refs/heads/$BRANCH" 2>"$ERRF"); then
  REMOTE_SHA=$(printf '%s\n' "$LS_OUT" | awk 'NR==1{print $1}')
else
  REMOTE_REACHABLE=0
  LS_ERR=$(cat "$ERRF")
fi

if [ "$REMOTE_REACHABLE" -eq 0 ]; then
  # Unknown, not unpublished — see the header. Grace runs from the last VERIFIED
  # publish, so a remote that stays unreachable turns red on its own.
  now=$(date +%s)
  last=0
  [ -f "$STAMP" ] && last=$(awk 'NR==1{print $1+0}' "$STAMP")
  age=$((now - last))
  warn "remote $REMOTE unreachable: $(printf '%s' "$LS_ERR" | tr '\n' ' ')"
  if [ "$last" -gt 0 ] && [ "$age" -lt "$GRACE" ]; then
    warn "last verified publish was ${age}s ago, inside the ${GRACE}s grace — not failing yet"
    say "LBG_PUBLISH_GUARD=degraded reason=unreachable age=${age}s"
    exit 0
  fi
  die "remote unreachable and the last verified publish was ${age}s ago (grace ${GRACE}s). The corpus may be unpublished and nothing can prove otherwise."
fi

LOCAL_SHA=$(g rev-parse HEAD) || die "cannot resolve HEAD"

published() { # every local commit is reachable from the remote tip?
  local r=$1
  [ -n "$r" ] || return 1
  [ "$LOCAL_SHA" = "$r" ] && return 0
  g cat-file -e "$r^{commit}" 2>/dev/null || return 1   # allow-suppress: existence probe
  g merge-base --is-ancestor "$LOCAL_SHA" "$r"
}

stamp_ok() {
  mkdir -p "$(dirname "$STAMP")" && date +%s >"$STAMP" || warn "could not write stamp $STAMP"
  say "$BRANCH published at $LOCAL_SHA (remote $REMOTE_SHA)"
  say "LBG_PUBLISH_GUARD=ok repo=$REPO branch=$BRANCH"
  exit 0
}

if published "$REMOTE_SHA"; then
  # Nothing of ours is unpublished. If we are merely BEHIND, catch up now: no
  # data is at risk, but the next `lb-granola commit` push would be rejected and
  # the unit would flap red for one tick over a divergence we could see coming.
  # Best effort — a dirty tree makes this refuse, and behind is not a failure.
  if [ "$HEAL" = "1" ] && [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
    if g merge --ff-only "$REMOTE_SHA" >/dev/null 2>"$ERRF"; then
      LOCAL_SHA=$(g rev-parse HEAD)
      say "fast-forwarded to $REMOTE/$BRANCH ($LOCAL_SHA)"
    else
      warn "behind $REMOTE/$BRANCH and could not fast-forward: $(tr '\n' ' ' <"$ERRF")"
    fi
  fi
  stamp_ok
fi

# --- unpublished. Heal the ordinary divergence, or fail loudly. -------------
if [ "$HEAL" != "1" ]; then
  die "$BRANCH local $LOCAL_SHA is not on $REMOTE (remote tip ${REMOTE_SHA:-<branch absent>}) and healing is disabled"
fi

if ! FETCH_OUT=$(gnet fetch --quiet "$REMOTE" "$BRANCH" 2>&1); then
  # The branch simply not existing on the remote is not a fetch failure worth
  # dying on here — the push below is what creates it.
  [ -n "$REMOTE_SHA" ] && die "git fetch $REMOTE $BRANCH failed: $(printf '%s' "$FETCH_OUT" | tr '\n' ' ')"
fi

if [ -n "$REMOTE_SHA" ] && ! g merge-base --is-ancestor "$REMOTE_SHA" "$LOCAL_SHA"; then
  # The remote has work we do not. Merge — never rebase, never stash, never reset.
  say "diverged from $REMOTE/$BRANCH; merging $REMOTE_SHA"
  if ! MERGE_OUT=$(g merge --no-edit "$REMOTE_SHA" 2>&1); then
    if g rev-parse -q --verify MERGE_HEAD >/dev/null; then
      # Leave the corpus exactly as found: a half-merged tree would break the
      # next hourly `git add data/` in a much less legible way than this does.
      g merge --abort
      warn "merge aborted; the working tree is back to $LOCAL_SHA"
    fi
    die "merge of $REMOTE/$BRANCH REFUSED — two writers genuinely conflict, this is not a tree to clean. Resolve by hand on the box: $(printf '%s' "$MERGE_OUT" | tr '\n' ' ')"
  fi
  LOCAL_SHA=$(g rev-parse HEAD)
fi

say "pushing $BRANCH -> $REMOTE ($LOCAL_SHA)"
if ! PUSH_OUT=$(gnet push "$REMOTE" "$BRANCH" 2>&1); then
  die "git push $REMOTE $BRANCH failed: $(printf '%s' "$PUSH_OUT" | tr '\n' ' ')"
fi

# --- prove it against the remote, again --------------------------------------
# `git push` exiting 0 is not proof; the same reasoning as /commit's ls-remote
# check. A second writer can land between the merge and here, in which case being
# BEHIND is fine — what must hold is that nothing of ours is missing up there.
REMOTE_SHA=$(remote_tip)
LOCAL_SHA=$(g rev-parse HEAD)
if ! published "$REMOTE_SHA"; then
  gnet fetch --quiet "$REMOTE" "$BRANCH" 2>"$ERRF" || warn "re-fetch failed: $(tr '\n' ' ' <"$ERRF")"
  published "$REMOTE_SHA" || die "after push, local $LOCAL_SHA is still not on $REMOTE (remote tip ${REMOTE_SHA:-<branch absent>})"
fi
stamp_ok
