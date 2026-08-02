#!/bin/bash
# PreToolUse (Bash): shared-working-tree guard (explore-igrd).
#
# THE HAZARD. A `/pulse` tick is, by design, a real interactive session in the
# PROJECT ROOT — that is how it gets a durable tmux window and the full
# harness. Worktree isolation covers subagents, the writers we expect; it does
# not cover the SCHEDULER. So the one writer nobody isolated is the one that
# arrives unannounced, on a timer, while you are mid-operation, editing the
# same checkout and committing to the same branch.
#
# Observed live 2026-08-01 14:00 UTC in ~/explore: the digest tick's unstaged
# source captures made an interactive orchestrator's `git pull --rebase` fail,
# and the reflex fix would have taken a running loop's 6 modified + 11
# untracked files out from under it, mid-write, silently.
#
# WHY A GATE AND NOT JUST A DOC. Measured in a scratch repo (two clones, one
# holding another writer's unstaged WIP):
#
#   remote moved; the other writer has an UNRELATED unstaged file
#     git pull --rebase    -> rc 128  "cannot pull with rebase: unstaged changes"
#     git pull --no-rebase -> rc 0    remote absorbed, their WIP INTACT
#   remote touches the SAME file the other writer is editing
#     git pull --no-rebase -> rc 1    refuses, their content still on disk
#
# merge fails SAFELY · rebase fails OBSTRUCTIVELY · stash fails DESTRUCTIVELY.
# The only one of the three that "succeeds" is the one that destroys, and
# rebase's refusal is exactly what tempts you toward stash. `git status` shows
# dirty files with no hint that another PROCESS owns them, and the stash never
# errors — so nothing in git warns you. Hence a hook.
#
# WHAT IT BLOCKS — the WHOLE-TREE destructive verbs, and only while another
# writer is genuinely in flight in THIS repo:
#   git stash / stash push / stash save   (no pathspec)
#   git reset --hard
#   git checkout . | checkout -- .        (and git restore ., restore -- .)
#   git clean -f*                         (no pathspec)
#   git pull --rebase / git rebase        ONLY when autostash is in play —
#                                         that is `stash` with no error at all
# A PATH-SCOPED form of any of these is always allowed: `git stash push --
# <your-files>`, `git clean -fd -- <dir>`, `git checkout -- <file>`. Same
# register and same escape hatch as pre-commit-checks.sh's `git add -A` block:
# refuse the blunderbuss, name the precise alternative.
#
# DELIBERATELY NOT BLOCKED: a plain `git pull --rebase` with no autostash.
# It fails obstructively (rc 128) rather than destructively, and — measured —
# an UNTRACKED-only dirty tree does not stop a rebase at all, so blocking it
# would refuse commands that were going to work. The reflex it provokes is
# what this hook catches, one step later.
#
# HOW "another writer is active" IS DETECTED — and what was DISPROVED.
# The obvious detector, "is a pulse-*.service active in `systemctl --user`",
# DOES NOT WORK, measured: pulse-*.service units are Type=oneshot tmux
# INJECTIONS. pulse-digest.service fired at 14:00:21 and was `inactive dead`
# seconds later, while the tick it woke did not finish until 14:20:53. The
# service is dead for the entire window in which the hazard exists.
#
# So two detectors, both reading state the fleet already maintains — no new
# producer, no advisory file for nobody to consume:
#
#   A. IN-FLIGHT TICK (the observed case). From the harnessd manifest: a loop
#      declared for THIS repo whose timer fired recently and whose ledger has
#      no row since that fire is, by definition, still running. This is the
#      same inference pulse-stall-reconcile.py makes, with the same bounds:
#      give up after grace_minutes + 30 (past that the tick is stalled, not
#      running, and the reconciler writes the row that clears it), and skip a
#      fire already recorded as a BOUNCE (pulse-inject deliberately typed
#      nothing — no tick ever started).
#
#   B. RUNNING JOB. A Type=oneshot user service currently `activating` whose
#      ExecStart/WorkingDirectory lives in this repo — e.g.
#      zettel-refresh.service, a real ~3-minute writer in ~/explore. Keyed on
#      `activating` + oneshot on purpose: every long-running daemon
#      (harnessd, hevyd, lb-fleet…) also has an ExecStart inside its own repo
#      and would otherwise false-positive forever in that repo.
#
# PRECISION MATTERS MORE THAN COVERAGE HERE. A guard that fires when no tick
# is running trains people to work around it, and a worked-around guard is
# worse than none. So it also requires the working tree to be DIRTY: with a
# clean tree these verbs destroy nothing, and `git stash` is already a no-op.
# Net effect: the block is possible only inside the minutes a tick is actually
# mid-run in this repo — the exact hazard window — and it self-clears.
#
# Fails OPEN (exit 0) whenever it cannot establish an active writer: no
# manifest, no jq, no systemd, unreadable ledger. This gate exists to catch a
# narrow, provable collision; a gate that blocked on "I don't know" would be
# refusing every stash on every machine that has no harness.
#
# Exit 2 = block the command and feed the reason to the agent.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

_STG_LIBDIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib"
source "$_STG_LIBDIR/hook-helpers.sh" 2>/dev/null
[ -r "$_STG_LIBDIR/portable.sh" ] && . "$_STG_LIBDIR/portable.sh"
if declare -F command_skeleton >/dev/null; then
  SKEL=$(command_skeleton "$COMMAND" 2>/dev/null)
else
  SKEL=""
fi
[ -z "$SKEL" ] && SKEL="$COMMAND"

# Cheap pre-filter: if no destructive verb is even mentioned, get out before
# any git/systemd work. This hook runs on EVERY Bash call.
echo "$SKEL" | grep -qE '(^|[[:space:];&|(`])git([[:space:]]|$)' || exit 0
echo "$SKEL" | grep -qE 'stash|reset|checkout|restore|clean|rebase' || exit 0

MANIFEST=${HARNESS_MANIFEST:-$HOME/harnessd/refs/harness-manifest.json}
BOUNCES=${HARNESS_PULSE_BOUNCES:-$HOME/.local/state/harness/pulse-bounces.jsonl}
# Head-room on top of a loop's declared grace before a fire stops counting as
# "in flight" and starts counting as stalled — the same margin
# pulse-stall-reconcile.py uses before it writes the `stalled` row that
# resolves the fire for good. Overridable so the test suite can exercise the
# bound without waiting out a real 90-minute grace.
STALL_MARGIN_MINUTES=${HARNESS_STALL_MARGIN_MINUTES:-30}
case "$STALL_MARGIN_MINUTES" in ''|*[!0-9-]*) STALL_MARGIN_MINUTES=30 ;; esac
US=$'\x1f'   # field separator for the manifest walk: NOT IFS-whitespace, so
             # an empty field (a `ledger_row: null` pin) cannot collapse and
             # shift every column after it.

# --- session cwd (same block every Bash PreToolUse hook uses) ---------------
JSON_CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
if [ -n "$JSON_CWD" ]; then
  CWD=$(cd "$JSON_CWD" 2>/dev/null && pwd -P)
  [ -z "$CWD" ] && CWD="$JSON_CWD"
else
  CWD=$(pwd -P)
fi
[ -d "$CWD" ] || CWD=$(pwd -P)

# Strip one layer of matching surrounding quotes. A token that was fully
# quoted in the source arrives as the EMPTY pair `""` (command_skeleton blanks
# quoted CONTENTS by design), which unquotes to "" and marks it unresolvable.
stg_unquote() {
  local v=$1
  case "$v" in
    '"'*'"') v=${v#\"}; v=${v%\"} ;;
    "'"*"'") v=${v#\'}; v=${v%\'} ;;
  esac
  printf '%s' "$v"
}

# Timestamps arrive in three shapes — systemd's LastTriggerUSec ("Sat
# 2026-08-01 14:00:21 PDT"), a ledger row's ISO-8601 `ts`, and a bounce
# record's `ts` — and every window decision below is a comparison between two
# of them. This used to be `date -d "$1" +%s 2>/dev/null`, which is GNU-only:
# on BSD it prints nothing, every caller's `[ -n "$x" ] || continue` fires, and
# the hook concludes there is NO WRITER — the permissive answer — for a reason
# that never appears anywhere (dotfiles-5vz2).
#
# The parse now comes from lib/portable.sh. This hook's documented posture is
# fail-OPEN (see the header: it must not refuse every stash on a machine with
# no harness), so a parse failure ANNOUNCES rather than blocks. That is the
# other half of the class rule — fail closed OR say something; never quietly
# take the permissive branch on an error you swallowed.
epoch_of() {
  local out
  if out=$(_p_epoch "$1"); then printf '%s\n' "$out"; return 0; fi
  echo "pre-shared-tree-guard: could not parse the timestamp \"$1\" — this repo's" >&2
  echo "  in-flight-writer check is degraded and the destructive-verb gate is OPEN." >&2
  return 1
}

# --- detector A: a declared loop of THIS repo, fired and not yet reported ---
# Echoes a one-line description of the in-flight loop, or nothing.
inflight_tick() {
  local repo=$1
  command -v jq >/dev/null 2>&1 || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  [ -r "$MANIFEST" ] || return 0

  local now proj timer ledger row grace rp fire_h fire age_min lpath newest nts b bts
  now=$(date +%s)
  while IFS=$US read -r proj timer ledger row grace; do
    [ -n "$timer" ] || continue
    # Manifest paths are absolute; compare resolved forms so a symlinked
    # project dir doesn't silently miss.
    rp=$(cd "$proj" 2>/dev/null && pwd -P) || continue
    [ "$rp" = "$repo" ] || continue

    fire_h=$(systemctl --user show "$timer.timer" -p LastTriggerUSec --value 2>/dev/null)
    [ -n "$fire_h" ] || continue
    fire=$(epoch_of "$fire_h")
    [ -n "$fire" ] || continue

    case "$grace" in ''|*[!0-9]*) grace=90 ;; esac
    age_min=$(( (now - fire) / 60 ))
    [ "$age_min" -lt 0 ] && continue
    [ "$age_min" -gt $(( grace + STALL_MARGIN_MINUTES )) ] && continue

    # A bounced fire means the tick never started (the window was 🔔-blocked
    # and pulse-inject deliberately typed nothing) — self-healing, not a
    # writer. Same carve-out pulse-stall-reconcile.py makes.
    if [ -r "$BOUNCES" ]; then
      b=$(jq -r --arg l "$timer" 'select(.loop==$l) | .ts' "$BOUNCES" 2>/dev/null | tail -1)
      if [ -n "$b" ]; then
        bts=$(epoch_of "$b")
        if [ -n "$bts" ] && [ "$bts" -ge "$fire" ]; then continue; fi
      fi
    fi

    # Has the loop reported since the fire? Its own ledger row is the receipt.
    lpath=$ledger
    case "$lpath" in /*) ;; *) lpath="$rp/$lpath" ;; esac
    [ -r "$lpath" ] || continue
    if [ -z "$row" ]; then
      # ledger_row:null means MATCH ANY ROW (one timer, many rows).
      newest=$(tail -n 200 "$lpath" | jq -r 'select(type=="object") | .ts // empty' 2>/dev/null | tail -1)
    else
      newest=$(tail -n 200 "$lpath" | jq -r --arg r "$row" 'select(type=="object") | select(.row==$r) | .ts // empty' 2>/dev/null | tail -1)
    fi
    if [ -n "$newest" ]; then
      nts=$(epoch_of "$newest")
      if [ -n "$nts" ] && [ "$nts" -ge "$fire" ]; then continue; fi   # already reported
    fi

    printf '%s (fired %s; no `%s` row in %s since)' \
      "$timer" "$fire_h" "${row:-any}" "$ledger"
    return 0
  done < <(jq -r --arg us "$US" '
      .projects[]? | .path as $p | (.loops[]? |
        [$p, (.timer // ""), (.ledger // ""), (.ledger_row // ""),
         ((.grace_minutes // 90) | tostring)] | join($us))' "$MANIFEST" 2>/dev/null)
  return 0
}

# --- detector B: a oneshot user job currently running out of THIS repo ------
running_job() {
  local repo=$1 unit props utype wd uexec
  command -v systemctl >/dev/null 2>&1 || return 0
  while read -r unit _; do
    [ -n "$unit" ] || continue
    props=$(systemctl --user show "$unit" -p Type -p WorkingDirectory -p ExecStart 2>/dev/null)
    utype=$(printf '%s\n' "$props" | sed -n 's/^Type=//p')
    [ "$utype" = "oneshot" ] || continue
    wd=$(printf '%s\n' "$props" | sed -n 's/^WorkingDirectory=//p')
    uexec=$(printf '%s\n' "$props" | sed -n 's/^ExecStart=//p')
    # WorkingDirectory is matched EXACTLY as well as by prefix: a unit whose
    # cwd IS the repo root reports `/home/ubuntu/dotfiles` with no trailing
    # slash, so a lone `*"$repo/"*` substring test misses the commonest shape
    # there is. (Found by the live positive control, which reported a clean
    # exit 0 with a real writer genuinely running — the suite's own
    # detector-B fixture happened to exercise only the ExecStart path.)
    case "$wd" in
      "$repo"|"$repo"/*)
        printf '%s (a oneshot job whose WorkingDirectory is this repo)' "$unit"
        return 0 ;;
    esac
    case "$uexec" in
      *"$repo/"*)
        printf '%s (a oneshot job running a script from this repo)' "$unit"
        return 0 ;;
    esac
  done < <(systemctl --user list-units --type=service --state=activating \
             --no-legend --plain 2>/dev/null)
  return 0
}

WRITER=""
WRITER_FOR=""
active_writer() {
  local repo=$1
  if [ "$WRITER_FOR" != "$repo" ]; then
    WRITER_FOR=$repo
    WRITER=$(inflight_tick "$repo")
    [ -z "$WRITER" ] && WRITER=$(running_job "$repo")
  fi
  [ -n "$WRITER" ]
}

tree_dirty() {
  [ -n "$(git -C "$1" status --porcelain 2>/dev/null | head -1)" ]
}

# $1 = the verb as the agent typed it, $2 = the precise alternative
block() {
  local verb=$1 alt=$2
  cat >&2 <<EOF
Blocked: \`$verb\` acts on the WHOLE working tree, and another writer is
mid-run in this repo right now.

  repo:   $REPO
  writer: $WRITER

A pulse tick is a real session in the project root — same checkout, same
branch — so its in-flight edits are indistinguishable from yours in
\`git status\`. These verbs do not error on them; they consume them.

Do this instead:
  * $alt
  * to absorb a moved remote, MERGE — never rebase, never stash:
      git fetch origin && git merge --no-edit origin/<branch>
    (measured: merge absorbs the remote with the other writer's WIP intact;
     \`pull --rebase\` refuses on ANY unrelated dirty file; \`stash\` "succeeds"
     by taking their work)
  * if that merge refuses ("local changes would be overwritten"), the remote
    genuinely touches the other writer's files. STOP AND WAIT — that is a
    real conflict between two writers, not a tree to be cleaned.

This clears by itself: the writer above is expected to finish and log its
ledger row. See ~/dotfiles/agents/AGENTS.md, "Two writers, one working tree".
EOF
  exit 2
}

# --- walk the command ------------------------------------------------------
REPO=""
while IFS= read -r SEG; do
  set -f
  # shellcheck disable=SC2206  # deliberate word-split of a blanked skeleton
  TOKS=($SEG)
  set +f
  [ "${#TOKS[@]}" -ge 2 ] || continue

  # `cd <dir> && git stash` — the repo at risk is the one the command WALKS
  # INTO, not the one the session started in.
  if [ "${TOKS[0]}" = "cd" ]; then
    V=$(stg_unquote "${TOKS[1]}")
    if [ -n "$V" ]; then
      NEWCWD=$( cd "$CWD" 2>/dev/null && cd "$V" 2>/dev/null && pwd -P )
      [ -n "$NEWCWD" ] && CWD=$NEWCWD
    fi
    continue
  fi
  [ "${TOKS[0]}" = "git" ] || continue

  # --- git's GLOBAL options, up to the subcommand ---
  GITDIR=""; SUB=""
  i=1; n=${#TOKS[@]}
  while [ "$i" -lt "$n" ]; do
    T=${TOKS[$i]}
    case "$T" in
      -C)  GITDIR=$(stg_unquote "${TOKS[$((i + 1))]:-}"); i=$((i + 2)) ;;
      -c|--git-dir|--work-tree|--namespace|--exec-path|--config-env) i=$((i + 2)) ;;
      -*)  i=$((i + 1)) ;;
      *)   SUB=$T; i=$((i + 1)); break ;;
    esac
  done
  [ -n "$SUB" ] || continue
  case "$SUB" in stash|reset|checkout|restore|clean|pull|rebase) ;; *) continue ;; esac

  # Resolve the repo this segment would act on.
  BASEDIR=$CWD
  if [ -n "$GITDIR" ]; then
    BASEDIR=$( cd "$CWD" 2>/dev/null && cd "$GITDIR" 2>/dev/null && pwd -P )
    [ -n "$BASEDIR" ] || continue
  fi
  REPO=$( cd "$BASEDIR" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null )
  [ -n "$REPO" ] || continue

  # --- the subcommand's own arguments ---
  # OPERANDS counts non-flag arguments (a pathspec, a branch, a commit).
  # An operand blanked by command_skeleton (a quoted "$F") still COUNTS as a
  # pathspec: the agent scoped the command, we just cannot read the value.
  # AUTOSTASH is TRI-STATE: "" = not named on the command line (consult the
  # config), 1 = --autostash, 0 = --no-autostash (an explicit override that
  # must beat a config saying otherwise).
  OPERANDS=0; HARD=0; AUTOSTASH=""; FORCE=0; DOT=0
  STAGED_ONLY=0; WORKTREE_FLAG=0; REBASE=0; SUBVERB=""; FIRST=1
  while [ "$i" -lt "$n" ]; do
    T=${TOKS[$i]}; i=$((i + 1))
    case "$T" in
      --) FIRST=0; continue ;;
      --hard) HARD=1; continue ;;
      --autostash) AUTOSTASH=1; continue ;;
      --no-autostash) AUTOSTASH=0; continue ;;
      --rebase|--rebase=*) REBASE=1; continue ;;
      --staged|--cached) STAGED_ONLY=1; continue ;;
      -W|--worktree) WORKTREE_FLAG=1; continue ;;
      -m|--message|-S|--source|--exec|--onto|--strategy|-s|-X|--strategy-option)
        i=$((i + 1)); continue ;;                        # flag + its value
      --force) [ "$SUB" = "clean" ] && FORCE=1; continue ;;
      --*) continue ;;
      -*) case "$SUB" in
            clean) case "$T" in *f*) FORCE=1 ;; esac ;;
          esac
          continue ;;
    esac
    V=$(stg_unquote "$T")
    if [ "$SUB" = "stash" ] && [ "$FIRST" = 1 ]; then
      SUBVERB=$V; FIRST=0; continue
    fi
    FIRST=0
    OPERANDS=$((OPERANDS + 1))
    [ "$V" = "." ] && DOT=1
  done

  VERB="git $SUB"; ALT=""
  case "$SUB" in
    stash)
      case "$SUBVERB" in
        ""|push|save)
          [ "$OPERANDS" -gt 0 ] && continue
          VERB="git stash${SUBVERB:+ $SUBVERB}"
          ALT="if you must set aside YOUR OWN files, name them: git stash push -- <your-paths>" ;;
        *) continue ;;   # pop/apply/list/show/drop/branch/clear touch the stash, not the tree
      esac ;;
    reset)
      [ "$HARD" = 1 ] || continue
      VERB="git reset --hard"
      ALT="revert only what you changed: git checkout -- <your-paths> (or git restore -- <your-paths>)" ;;
    checkout|restore)
      [ "$DOT" = 1 ] || continue
      if [ "$SUB" = "restore" ] && [ "$STAGED_ONLY" = 1 ] && [ "$WORKTREE_FLAG" = 0 ]; then
        continue   # --staged only rewrites the index; the worktree is untouched
      fi
      VERB="git $SUB ."
      ALT="name the files you want reverted: git $SUB -- <your-paths>" ;;
    clean)
      [ "$FORCE" = 1 ] || continue
      [ "$OPERANDS" -gt 0 ] && continue
      VERB="git clean -f"
      ALT="scope it to a path: git clean -fd -- <your-dir>" ;;
    pull|rebase)
      # `git pull --rebase` / `git rebase` are destructive here only when
      # autostash is in play — and then they ARE a stash, with no error at
      # all. `rebase.autoStash` is unset fleet-wide (checked 2026-08-01, repo
      # AND global scope) and must stay that way; this branch is what notices
      # if anyone "fixes" the rebase friction by enabling it.
      [ "$AUTOSTASH" = 0 ] && continue        # --no-autostash: explicitly off
      if [ "$AUTOSTASH" != 1 ]; then
        # Not named on the command line — only a config can switch it on.
        # Which config depends on whether this pull rebases or merges;
        # `git pull --autostash` on the merge path stashes just as hard.
        KEY=rebase.autoStash
        if [ "$SUB" = "pull" ] && [ "$REBASE" = 0 ]; then
          PR=$( cd "$REPO" 2>/dev/null && git config --bool --get pull.rebase 2>/dev/null )
          [ "$PR" = "true" ] || KEY=merge.autoStash
        fi
        CFG=$( cd "$REPO" 2>/dev/null && git config --bool --get "$KEY" 2>/dev/null )
        [ "$CFG" = "true" ] || continue
      fi
      VERB="git $SUB (autostash is on)"
      ALT="absorb the remote with a PLAIN merge: git fetch origin && git merge --no-edit origin/<branch> — and leave rebase.autoStash / merge.autoStash UNSET. Autostash is the worst possible fix for rebase friction: it turns the obstructive command into the destructive one, with no prompt and no error. It is unset at repo AND global scope fleet-wide and must stay that way" ;;
  esac

  tree_dirty "$REPO" || continue
  active_writer "$REPO" || continue
  block "$VERB" "$ALT"
done < <(printf '%s\n' "$SKEL" | tr ';&|`()<>' '\n\n\n\n\n\n\n\n')

exit 0
