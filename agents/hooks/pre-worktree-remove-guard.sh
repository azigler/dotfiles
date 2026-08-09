#!/bin/bash
# PreToolUse (Bash): REFUSE `git worktree remove` while a LIVE agent still owns
# the tree.
#
# THE INCIDENT (2026-08-09, dotfiles-3135). The orchestrator dispatched a
# 3-task batch agent, watched task 1's commit merge cleanly, and swept the
# worktree in the cleanup pass — `git worktree remove --force --force` ran
# against a LIVE agent that was mid-task-2. The agent's fully-verified diff for
# that task (built, mutation-tested 5/5, not yet committed) was destroyed, and
# every subsequent tool call it made failed with "isolation worktree appears to
# have been removed". The removal itself printed nothing and exited 0. Two root
# causes: cleanup keyed on "branch merged" rather than "agent completed" (the
# doctrine half, fixed in AGENTS.md), and NOTHING refused the removal of a tree
# with a live owner. This hook is that mechanism.
#
# THIS IS THE INVERSE OF agents/bin/orphan-reaper.sh, deliberately built on the
# same /proc cwd-scan idiom: the reaper kills processes whose tree is GONE, this
# guard protects processes whose tree is ABOUT TO GO. Same readlink /proc/<pid>/cwd
# scan, same self/ancestor exclusion, same path_under predicate — read them
# together, and change them together.
#
#   ONE DELIBERATE DIVERGENCE FROM THE REAPER: the ' (deleted)' suffix is NOT a
#   signal here. For the reaper it means "the tree this process lived in is gone,
#   so the process is orphaned". Pre-removal the target tree still EXISTS, so a
#   deleted-suffix cwd underneath it means some SUBDIRECTORY was removed — which
#   says nothing at all about whether the process is doing live work. Deleted and
#   non-deleted cwds are therefore both candidates and both classified the same
#   way, which is the conservative reading.
#
# WHAT IT CATCHES
#   Any Bash command whose executable SKELETON contains `worktree remove` —
#   `git worktree remove`, `git -C <repo> worktree remove`, any flag order,
#   inside a && chain, a loop body, or a command substitution. Matching the bare
#   `worktree remove` pair (rather than requiring a literal leading `git`) is the
#   cheap way to also catch a git alias that spells the subcommand out.
#
# WHAT IT DOES NOT CATCH — say it plainly, because a guard whose gaps are
# undocumented gets trusted for things it never did:
#   * `rm -rf <worktree>` and friends. Nothing here inspects rm. (The isolation
#     guard, pre-tool-use-require-isolation.sh, covers part of that surface for
#     Write/Edit, not for rm.)
#   * A git alias whose NAME hides the subcommand — `git wtrm <path>`, where
#     `wtrm = worktree remove` lives in .gitconfig. Resolving that means reading
#     every reachable gitconfig from a PreToolUse hook; the trivial half (an
#     alias written out longhand at the call site) is caught, the rest is not.
#   * A removal performed by a SCRIPT the agent invokes (`bash cleanup.sh`).
#     Same scope rule as pre-tmux-kill-guard.sh: this hook reads the literal
#     command text handed to the Bash tool, never the files it runs.
#   * A path built from a variable or a glob (`git worktree remove "$WT"`). The
#     hook cannot expand it, so it FAILS OPEN and says so on stderr.
#   * macOS. There is no /proc; the scan is impossible, so the hook fails open
#     with a one-line note.
#
# CLASSIFY BEFORE BLOCKING — the second half of the bead, and the half that
# decides whether this guard survives contact with real cleanup. A guard that
# blocks on a stale pane shell gets routed around within a week (see the
# hook-helpers.sh header for the three agents who did exactly that to the
# stderr guard), and then it protects nothing.
#
#   DEBRIS — allowed, with a note. A process is debris only if ALL THREE hold:
#     (1) its comm is a shell or a tmux process ($DEBRIS_COMMS below) — the two
#         things a finished agent leaves behind;
#     (2) it has burned less than $WORKTREE_GUARD_DEBRIS_CPU_TICKS of CPU in its
#         WHOLE life (default 200 ticks = 2s at 100 Hz). Measured on this box, a
#         tmux server 30 days old had used 12 ticks, so the threshold is roomy
#         for a genuinely idle process and unreachable for one doing work;
#     (3) it has NO descendant that is itself non-debris — a shell running a
#         build is the shell plus the build, and the build is what matters. The
#         descendant walk covers children ANYWHERE, not only children whose cwd
#         is under the target, because `cd /elsewhere && make` is still this
#         shell's live work.
#
#   LIVE — blocked. Everything else, by construction: node/claude, python, git,
#   cargo, an unknown comm, a shell above the CPU floor, a shell with a working
#   child. The asymmetry is intentional and is the whole safety argument —
#   misjudging live work as debris costs verified, uncommitted work (it already
#   did, once); misjudging debris as live costs one `orphan-reaper.sh --worktree`
#   run. Unknown therefore resolves to LIVE.
#
#   NOT MEASURED, and why: "recent" CPU rather than cumulative. Sampling twice
#   with a sleep between is the only honest way to measure it, and a PreToolUse
#   hook that sleeps taxes every cleanup on the machine. Cumulative CPU can only
#   OVER-report liveness relative to recent CPU, and over-reporting is the safe
#   direction here, so the cheap test is also the conservative one.
#
# FAIL OPEN, LOUDLY. stop-context-guard.sh fails CLOSED when it cannot read an
# mtime, and is right to: there its permissive branch (release the warning) is
# the one that loses work, so an unreadable input must not take it. Here the
# polarity is reversed — the restrictive branch blocks EVERY worktree cleanup on
# the machine, fleet-wide, including the cleanup that would fix the hook. A
# broken guard that wedges all cleanup is a worse outcome than a missed block on
# an unparseable command, which is why an unresolvable path, an unreadable /proc,
# or a missing jq exits 0. What it must never do is fail open SILENTLY: every
# degraded path announces itself on stderr, so "the guard passed" and "the guard
# could not look" never read the same.
#
# OVERRIDE. WORKTREE_REMOVE_OVERRIDE_LIVE=1, and it must appear IN THE COMMAND
# ITSELF (`WORKTREE_REMOVE_OVERRIDE_LIVE=1 git worktree remove …`). The hook does
# NOT consult its own environment: an exported variable would silently disarm the
# guard for a whole session, which is how a deliberate one-time override becomes
# a permanent hole. When it fires, the hook allows the removal and says loudly on
# stderr exactly whose live work is being discarded.
#
# Behavior:
#   - exit 0 = allow the tool call (silently when there is nothing to protect)
#   - exit 2 = BLOCK and surface stderr to the agent
#
# Test:    agents/hooks/test/test-pre-worktree-remove-guard.sh
# Mutants: agents/hooks/test/mutate-worktree-remove-guard.sh

set -uo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)  # allow-suppress
[ -z "$COMMAND" ] && exit 0

# --- detection: match on the SKELETON, never on prose -----------------------
# Same rationale and same helper as pre-tmux-kill-guard.sh: a commit message or
# a bead body that MENTIONS `git worktree remove` must never be treated as one.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/hook-helpers.sh" 2>/dev/null  # allow-suppress
if ! type command_skeleton >/dev/null 2>&1 || ! SKEL=$(command_skeleton "$COMMAND"); then
  SKEL="$COMMAND"   # fail toward over-matching: never a missed detection
fi

echo "$SKEL" | grep -Eq '\bworktree[[:space:]]+remove\b' || exit 0

announce() { echo "[worktree-remove-guard] $*" >&2; }

# --- target extraction ------------------------------------------------------
# extract_targets <text> -> one line per `worktree remove` occurrence, holding
# that occurrence's first non-flag argument (empty line = no path given).
# Tokens are stripped of trailing shell punctuation (`;` `&` `|` `)`) so
# `... && git worktree remove /path;` tokenizes the same as the bare form.
extract_targets() {
  printf '%s\n' "$1" | awk '
    function norm(s) { sub(/[;&|()]+$/, "", s); return s }
    {
      for (i = 1; i <= NF; i++) {
        if (norm($i) != "worktree") continue
        if ((i + 1) > NF || norm($(i + 1)) != "remove") continue
        p = ""
        for (j = i + 2; j <= NF; j++) {
          t = norm($j)
          if (t == "" || t == "--") continue
          if (substr(t, 1, 1) == "-") continue
          p = t
          break
        }
        print p
      }
    }'
}

strip_quotes() {
  local s=$1
  s=${s#[\"\']}
  s=${s%[\"\']}
  printf '%s' "$s"
}

mapfile -t SKEL_TARGETS < <(extract_targets "$SKEL")
mapfile -t RAW_TARGETS  < <(extract_targets "$COMMAND")

if [ "${#SKEL_TARGETS[@]}" -eq 0 ]; then
  announce "matched \`worktree remove\` but could not locate the invocation — FAILING OPEN (allowing) without a live-process check."
  exit 0
fi

# The hook's own cwd is not the tool call's cwd; relative targets resolve
# against the payload's.
PAYLOAD_CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)  # allow-suppress
[ -n "$PAYLOAD_CWD" ] || PAYLOAD_CWD=$PWD

RESOLVED=()
UNRESOLVED=0
for idx in "${!SKEL_TARGETS[@]}"; do
  t=${SKEL_TARGETS[$idx]}
  # A quoted literal is blanked to "" by the skeleton (it is argument CONTENT,
  # which the skeleton deliberately drops — see lib/hook-helpers.sh). Fall back
  # to the RAW command for that occurrence, but ONLY when the two extractions
  # agree on how many occurrences there are: if they disagree, some of the raw
  # hits are prose and the indices no longer line up, and guessing which is
  # which is worse than saying so.
  case "$t" in
    ''|'""'|"''")
      if [ "${#RAW_TARGETS[@]}" -eq "${#SKEL_TARGETS[@]}" ]; then
        t=$(strip_quotes "${RAW_TARGETS[$idx]}")
      else
        t=""
      fi
      ;;
  esac
  case "$t" in
    ''|*'$'*|*'`'*|*'*'*|*'?'*)
      UNRESOLVED=$((UNRESOLVED + 1)); continue ;;
  esac
  case "$t" in
    /*) abs=$t ;;
    *)  abs="$PAYLOAD_CWD/$t" ;;
  esac
  # /proc cwd links are PHYSICAL paths, so the target must be physical too or
  # path_under compares apples to symlinks.
  if phys=$(cd "$abs" 2>/dev/null && pwd -P); then   # allow-suppress
    RESOLVED+=("$phys")
  else
    UNRESOLVED=$((UNRESOLVED + 1))
  fi
done

if [ "$UNRESOLVED" -gt 0 ]; then
  announce "could not resolve $UNRESOLVED of ${#SKEL_TARGETS[@]} worktree path(s) in this command (variable, glob, or a path that does not exist)."
  announce "FAILING OPEN for those: no live-process check was performed. If an agent may still be working in that tree, wait for its completion notification before removing it (dotfiles-3135)."
fi
[ "${#RESOLVED[@]}" -gt 0 ] || exit 0

if [ ! -d /proc ]; then
  announce "no /proc on this platform — the live-owner scan is impossible. FAILING OPEN; nothing was checked."
  exit 0
fi

# --- the /proc scan (orphan-reaper.sh's idiom, inverted) --------------------
#
# THE SCAN IS FORK-FREE ON PURPOSE, and that is a hook-latency decision, not a
# style one. The reaper runs once on a timer and can afford `cat`/`readlink` per
# pid; this runs INSIDE a tool call, in front of a human, on a machine with ~400
# processes. Measured here before the rewrite: 400 `cat /proc/PID/stat` +
# 400 `readlink /proc/PID/cwd` = 7.0s wall (5.4s of it sys, i.e. fork/exec).
# The same information via a builtin `read <` per pid plus ONE `ls -l` over the
# whole cwd glob is 0.19s — a 35x cut, and the difference between a guard people
# keep and a guard people rip out.
#
# `declare -A` needs bash 4+, which macOS's system bash (3.2) is not — hence its
# placement AFTER the `[ -d /proc ]` gate above, which already exits on every
# platform that could get here with an old bash.
declare -A PPID_OF CPU_OF COMM_OF KIDS_OF CWD_OF

CAND_LIVE=""      # "pid|comm|cwd" records, newline separated
CAND_DEBRIS=""

path_under() { case "$1" in "$2"|"$2"/*) return 0 ;; *) return 1 ;; esac }

CPU_FLOOR=${WORKTREE_GUARD_DEBRIS_CPU_TICKS:-200}

DEBRIS_COMMS=' tmux tmux:_server tmux:_client sh bash zsh dash fish ksh login su '
is_debris_comm() {
  local c=${1// /_}
  case "$DEBRIS_COMMS" in *" $c "*) return 0 ;; *) return 1 ;; esac
}

# pass 1 — the process table. /proc/PID/stat gives comm, ppid and CPU in one
# read; comm may contain spaces and parens, so it is taken between the FIRST '('
# and the LAST ') ' (orphan-reaper.sh's reason, same construction).
SCANNED=0
for pid_path in /proc/[0-9]*; do
  pid=${pid_path#/proc/}
  case "$pid" in *[!0-9]*) continue ;; esac
  read -r stat_line 2>/dev/null < "$pid_path/stat" || continue   # allow-suppress
  tmp=${stat_line#*(}
  comm=${tmp%) *}
  rest=${stat_line##*) }
  read -ra F <<< "$rest"
  ppid=${F[1]:-0}
  PPID_OF[$pid]=$ppid
  COMM_OF[$pid]=$comm
  CPU_OF[$pid]=$(( ${F[11]:-0} + ${F[12]:-0} ))
  KIDS_OF[$ppid]="${KIDS_OF[$ppid]:-} $pid"
  SCANNED=$((SCANNED + 1))
done

if [ "$SCANNED" -eq 0 ]; then
  announce "scanned /proc and found no readable processes at all — that is a broken scan, not an empty machine. FAILING OPEN; nothing was checked."
  exit 0
fi

# pass 2 — the cwd map, in ONE fork. `ls -l` prints `<path>/cwd -> <target>` for
# every link it can read and a Permission-denied line for the rest (other users'
# processes, which we could not have read anyway). That specific noise is
# filtered rather than blanket-suppressed (this repo's rule 3), so a REAL ls
# failure still reaches the agent.
CWD_LINES=$(ls -l /proc/[0-9]*/cwd 2> >(grep -vE "(Permission denied|No such file or directory|cannot (access|open|read))" >&2))
CWD_SEEN=0
while IFS= read -r l; do
  case "$l" in *"/proc/"*"/cwd -> "*) ;; *) continue ;; esac
  head=${l%%"/cwd -> "*}
  pid=${head##*/proc/}
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  CWD_OF[$pid]=${l#*"/cwd -> "}
  CWD_SEEN=$((CWD_SEEN + 1))
done <<< "$CWD_LINES"

# Fallback: no `ls`, or an `ls` whose long format is not this one. Correct but
# ~3s on a busy machine — better slow than blind, and it announces nothing
# because nothing was missed.
if [ "$CWD_SEEN" -eq 0 ]; then
  for pid in "${!PPID_OF[@]}"; do
    link=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue   # allow-suppress
    [ -n "$link" ] && CWD_OF[$pid]=$link
  done
fi

# Never consider our own pid or our ancestor chain — the shell that invoked the
# removal is frequently rooted in the tree's parent, and the hook inherits that
# cwd. Same construction as orphan-reaper.sh, off the table built above.
EXCLUDED=" $$ "
_p=$$
while [ "$_p" -gt 1 ]; do
  _pp=${PPID_OF[$_p]:-}
  case "$_pp" in ''|*[!0-9]*) break ;; esac
  EXCLUDED="$EXCLUDED $_pp "
  _p=$_pp
done
is_excluded() { case "$EXCLUDED" in *" $1 "*) return 0 ;; *) return 1 ;; esac }

# has_working_descendant <pid> — true if ANY descendant (at any depth, with any
# cwd) is not itself debris-shaped. A shell is only debris when the whole subtree
# below it is: `cd /elsewhere && make` is still this shell's live work.
has_working_descendant() {
  local queue next kid seen=" "
  queue=${KIDS_OF[$1]:-}
  while [ -n "${queue// /}" ]; do
    next=""
    for kid in $queue; do
      case "$seen" in *" $kid "*) continue ;; esac
      seen="$seen$kid "
      if ! is_debris_comm "${COMM_OF[$kid]:-unknown}" \
         || [ "${CPU_OF[$kid]:-0}" -ge "$CPU_FLOOR" ]; then
        return 0
      fi
      next="$next ${KIDS_OF[$kid]:-}"
    done
    queue=$next
  done
  return 1
}

for target in "${RESOLVED[@]}"; do
  for pid in $(printf '%s\n' "${!CWD_OF[@]}" | sort -n); do
    is_excluded "$pid" && continue
    cwd_raw=${CWD_OF[$pid]}
    # The ' (deleted)' suffix is stripped for the path comparison but KEPT in
    # the record: unlike the reaper, deletedness is not a liveness signal here
    # (see the header) — it is just noise in front of the path we must match.
    clean=${cwd_raw% (deleted)}
    path_under "$clean" "$target" || continue

    comm=${COMM_OF[$pid]:-unknown}
    cpu=${CPU_OF[$pid]:-0}
    rec="$pid|$comm|$cwd_raw"
    if is_debris_comm "$comm" && [ "$cpu" -lt "$CPU_FLOOR" ] && ! has_working_descendant "$pid"; then
      CAND_DEBRIS+="$rec"$'\n'
    else
      CAND_LIVE+="$rec"$'\n'
    fi
  done
done

# --- verdict ----------------------------------------------------------------
fmt() { printf '%s' "$1" | while IFS='|' read -r p c w; do
          [ -n "$p" ] && printf '    pid %-8s %-16s cwd %s\n' "$p" "$c" "$w"
        done; }

if [ -z "$CAND_LIVE" ]; then
  if [ -n "$CAND_DEBRIS" ]; then
    announce "reapable debris is rooted in this worktree — NOT blocking, this is the reaper's job:"
    fmt "$CAND_DEBRIS" >&2
    announce "Per the AGENTS.md cleanup sequence, run this FIRST so nothing holds the directory open:"
    announce "    agents/bin/orphan-reaper.sh --worktree ${RESOLVED[0]}"
  fi
  exit 0
fi

# Live work found. The override is honored only when it is IN this command.
if echo "$SKEL" | grep -q 'WORKTREE_REMOVE_OVERRIDE_LIVE=' \
   && echo "$COMMAND" | grep -Eq 'WORKTREE_REMOVE_OVERRIDE_LIVE=["'"'"']?1["'"'"']?'; then
  {
    echo "############################################################"
    echo "# [worktree-remove-guard] OVERRIDE ACCEPTED — DISCARDING LIVE WORK."
    echo "# WORKTREE_REMOVE_OVERRIDE_LIVE=1 was given, so this removal is"
    echo "# proceeding against a tree that a LIVE process still owns. Any"
    echo "# uncommitted diff in it is about to be destroyed and is NOT"
    echo "# recoverable from git. The processes being overridden:"
    printf '%s' "$CAND_LIVE" | while IFS='|' read -r p c w; do
      [ -n "$p" ] && printf '#     pid %-8s %-16s cwd %s\n' "$p" "$c" "$w"
    done
    echo "# This is the dotfiles-3135 incident, entered deliberately."
    echo "############################################################"
  } >&2
  exit 0
fi

{
  echo "[worktree-remove-guard] BLOCKED: this worktree has a LIVE owner."
  echo
  printf '%s' "$CAND_LIVE" | while IFS='|' read -r p c w; do
    [ -n "$p" ] && printf '    pid %-8s %-16s cwd %s\n' "$p" "$c" "$w"
  done
  if [ -n "$CAND_DEBRIS" ]; then
    echo
    echo "  (also present, but reapable debris, not the reason for this block:)"
    printf '%s' "$CAND_DEBRIS" | while IFS='|' read -r p c w; do
      [ -n "$p" ] && printf '    pid %-8s %-16s cwd %s\n' "$p" "$c" "$w"
    done
  fi
  cat <<'MSG'

THE INCIDENT THIS PREVENTS (dotfiles-3135, 2026-08-09). A 3-task batch agent
had its worktree force-removed mid-task-2, because cleanup keyed on "task 1's
branch merged" rather than "the agent finished". Its fully-verified,
mutation-tested, UNCOMMITTED diff was destroyed — git could not recover it,
because it was never committed — and every later call it made died with
"isolation worktree appears to have been removed". The removal exited 0 and
printed nothing.

A merged branch is NOT a finished agent. Batch agents commit incrementally,
so those two signals routinely diverge.

TWO LEGITIMATE WAYS FORWARD:

  1. WAIT for the agent's completion notification, then remove. This is
     almost always the right answer; the tree costs nothing while you wait.

  2. If you know the processes above are NOT doing work you need — put the
     override in the command itself and accept the loss:

       WORKTREE_REMOVE_OVERRIDE_LIVE=1 git worktree remove --force --force <path>

     The variable is read from the COMMAND, never from the environment, so it
     cannot be exported once and silently disarm this guard for the session.

If what is actually in there is leftover debris (an idle shell, a stale tmux
server), it would not have blocked — the guard classifies those and allows.
Something above is holding real work.
MSG
} >&2
exit 2
