#!/usr/bin/env bash
# orphan-reaper — kill processes that outlive the worktree/scratchpad they
# were started in.
#
# WHY (dotfiles-415c, 2026-08-09). Worktree removal deletes the TREE; nothing
# reaps the PROCESSES a builder started inside it. A sweep on 2026-08-09 found
# 42 of them at once: hevyd-c9h's orphan (13 days old, wildcard-bound,
# hammering a real API on a stale key) plus 41 node preview servers (~57MB
# each, ~2.2GB total) rooted in deleted `.claude/worktrees/*` and scratchpad
# dirs, some 6 days old. Builders legitimately start servers to test; the leak
# is structural, not a builder mistake, so the fix is a reaper, not a rule.
#
# THE SAFETY PROPERTY THIS SCRIPT EXISTS TO PRESERVE:
#   the sweep NEVER matches a LIVE (non-deleted) worktree cwd.
# A worktree still on disk may be mid-build; killing into it is the opposite
# of what this script is for. Only two predicates ever select a pid for the
# full sweep:
#   (a) cwd is under .claude/worktrees/ AND the underlying dir is (deleted)
#   (b) cwd is under a .../scratchpad/... dir, live OR deleted — scratchpad
#       content is ephemeral working space by design, so a process still
#       running there after its owning session is gone is orphaned regardless
#       of whether the directory itself has been cleaned up yet.
# --worktree mode (see below) is the one deliberate exception, and it is
# scoped to a single named path, not the general sweep.
#
# USAGE
#   orphan-reaper.sh [--dry-run] [--grace SECS] [--floor PID]
#       Full sweep of /proc against predicates (a)/(b) above.
#   orphan-reaper.sh --worktree PATH [--dry-run] [--grace SECS] [--floor PID]
#       Kill only processes whose cwd is PATH or under it (deleted or not).
#       For the merge-cleanup sequence: run this BEFORE `git worktree remove`
#       so nothing is left holding the directory open when it is deleted.
#
# Emits one JSON line per reap to $ORPHAN_REAPER_LEDGER
# (default ~/.local/share/fleet-health/reaper.jsonl): {ts,pid,age,comm,cwd}.
# Last stdout line is always: ORPHAN_REAPER_RESULT=<clean|reaped:N>
#
# Exit codes: 0 clean/reaped-successfully, 1 a killed pid survived SIGKILL
# (real problem, surfaced), 2 usage error. Reaping itself is NOT treated as a
# failure state (unlike restart-loop-check.sh's exit 10) — clearing an orphan
# is normal maintenance, not an alarm condition; the ledger is the record.
#
# ORPHAN_REAPER_SCOPE_PREFIX (env, optional): when set, the full sweep ALSO
# requires the candidate cwd to be under this prefix. Undocumented in normal
# operation (the timer runs unscoped, against the whole machine) — this
# exists so the test suite can run a REAL full sweep without touching any
# process outside its own throwaway fixture tree.
set -uo pipefail

DRY_RUN=0
WORKTREE_TARGET=""
SCOPE_PREFIX="${ORPHAN_REAPER_SCOPE_PREFIX:-}"
GRACE="${ORPHAN_REAPER_GRACE:-10}"
FLOOR="${ORPHAN_REAPER_PID_FLOOR:-300}"
LEDGER="${ORPHAN_REAPER_LEDGER:-$HOME/.local/share/fleet-health/reaper.jsonl}"

usage() {
  cat <<'EOF'
orphan-reaper.sh [--dry-run] [--grace SECS] [--floor PID]
orphan-reaper.sh --worktree PATH [--dry-run] [--grace SECS] [--floor PID]
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --worktree)
      [ $# -ge 2 ] || { echo "orphan-reaper: --worktree needs a PATH" >&2; usage >&2; exit 2; }
      WORKTREE_TARGET=$2; shift 2 ;;
    --grace)
      [ $# -ge 2 ] || { echo "orphan-reaper: --grace needs SECS" >&2; usage >&2; exit 2; }
      GRACE=$2; shift 2 ;;
    --floor)
      [ $# -ge 2 ] || { echo "orphan-reaper: --floor needs a PID" >&2; usage >&2; exit 2; }
      FLOOR=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "orphan-reaper: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- self/ancestor exclusion -----------------------------------------------
# Never reap our own pid or anything in our ancestor chain (the shell, tmux
# pane, ssh session, or systemd service that launched us). /proc/PID/stat's
# comm field can contain spaces and parens, so extract PPID from AFTER the
# last ')' rather than naive field-splitting.
get_ppid() {
  local stat_content rest
  stat_content=$(cat "/proc/$1/stat" 2>/dev/null) || { echo ""; return; }
  rest=${stat_content##*) }
  printf '%s\n' "$rest" | awk '{print $2}'
}

EXCLUDED=" $$ "
_p=$$
while [ "$_p" -gt 1 ] 2>/dev/null; do
  _ppid=$(get_ppid "$_p")
  case "$_ppid" in ''|*[!0-9]*) break ;; esac
  EXCLUDED="$EXCLUDED $_ppid "
  _p=$_ppid
done

is_excluded() { case "$EXCLUDED" in *" $1 "*) return 0 ;; *) return 1 ;; esac }

# --- cwd predicates ----------------------------------------------------------
is_deleted_cwd() { case "$1" in *' (deleted)') return 0 ;; *) return 1 ;; esac }
clean_cwd() { case "$1" in *' (deleted)') printf '%s' "${1% (deleted)}" ;; *) printf '%s' "$1" ;; esac }

match_worktree_deleted() { case "$1" in */.claude/worktrees/*) return 0 ;; *) return 1 ;; esac }
match_scratchpad() { case "$1" in */scratchpad|*/scratchpad/*) return 0 ;; *) return 1 ;; esac }

path_under() {
  local clean=$1 target=$2
  case "$clean" in "$target"|"$target"/*) return 0 ;; *) return 1 ;; esac
}

# --- ledger + reap -----------------------------------------------------------
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

REAPED=0
CANDIDATES=0

reap_pid() {
  local pid=$1 cwd=$2
  local comm start_epoch now age
  comm=$(cat "/proc/$pid/comm" 2>/dev/null); comm=${comm:-unknown}
  start_epoch=$(stat -c %Y "/proc/$pid" 2>/dev/null) || start_epoch=""
  now=$(date +%s)
  if [ -n "$start_epoch" ]; then age=$(( now - start_epoch )); else age=-1; fi

  CANDIDATES=$((CANDIDATES + 1))

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY-RUN would reap pid=%s age=%ss comm=%s cwd=%s\n' "$pid" "$age" "$comm" "$cwd"
    return 0
  fi

  kill -TERM "$pid" 2>/dev/null || true
  local waited=0
  while [ "$waited" -lt "$GRACE" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    sleep 1
  fi

  # Verify the negation: the pid must actually be gone. A KILL that does not
  # take (zombie stuck in uninterruptible sleep, PID reused mid-check) must be
  # visible, not swallowed as a quiet success.
  if kill -0 "$pid" 2>/dev/null; then
    echo "WARN: pid $pid survived SIGKILL (cwd=$cwd)" >&2
    return 1
  fi

  mkdir -p "$(dirname "$LEDGER")"
  printf '{"ts":"%s","pid":%s,"age":%s,"comm":"%s","cwd":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pid" "$age" "$(json_escape "$comm")" "$(json_escape "$cwd")" \
    >> "$LEDGER"
  printf 'REAPED pid=%s age=%ss comm=%s cwd=%s\n' "$pid" "$age" "$comm" "$cwd"
  REAPED=$((REAPED + 1))
  return 0
}

SURVIVORS=0

for pid_path in /proc/[0-9]*; do
  pid=${pid_path#/proc/}
  case "$pid" in *[!0-9]*) continue ;; esac
  [ "$pid" -lt "$FLOOR" ] && continue
  is_excluded "$pid" && continue

  cwd_raw=$(readlink "$pid_path/cwd" 2>/dev/null) || continue
  [ -n "$cwd_raw" ] || continue
  clean=$(clean_cwd "$cwd_raw")

  if [ -n "$WORKTREE_TARGET" ]; then
    path_under "$clean" "$WORKTREE_TARGET" || continue
  else
    [ -z "$SCOPE_PREFIX" ] || path_under "$clean" "$SCOPE_PREFIX" || continue
    deleted=0
    is_deleted_cwd "$cwd_raw" && deleted=1
    matched=0
    [ "$deleted" -eq 1 ] && match_worktree_deleted "$clean" && matched=1
    match_scratchpad "$clean" && matched=1
    [ "$matched" -eq 1 ] || continue
  fi

  reap_pid "$pid" "$cwd_raw" || SURVIVORS=$((SURVIVORS + 1))
done

if [ "$CANDIDATES" -eq 0 ]; then
  echo "ORPHAN_REAPER_RESULT=clean"
  exit 0
fi

echo "ORPHAN_REAPER_RESULT=reaped:$CANDIDATES"
[ "$SURVIVORS" -eq 0 ] || exit 1
exit 0
