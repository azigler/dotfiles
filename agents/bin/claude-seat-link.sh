#!/usr/bin/env bash
#
# claude-seat-link.sh — wire a SECOND Claude seat to share everything with the
# primary seat EXCEPT its credential.
#
# Why this exists
# ---------------
# `CLAUDE_CONFIG_DIR=~/.claude-work` relocates the ENTIRE config tree, not just
# the credential. A seat created that way inherits nothing: no CLAUDE.md, no
# skills (so `--cmd "/pulse tick"` cannot resolve), no hooks (so no 🧠/✅/🔔 tmux
# glyphs), no `remoteControlAtStartup` (invisible to the Harness app), and its
# transcripts + memory land in a tree the vault sync does not cover.
#
# This is the INVERSE of the tick-jail (`~/.claude-tick`), which isolates on
# purpose because it handles untrusted web content. A work seat is a seat
# identity, not a sandbox: the ONLY thing that should diverge is who you are.
#
# Usage
# -----
#   claude-seat-link.sh [SEAT_DIR] [--dry-run]
#
#   SEAT_DIR   defaults to $HOME/.claude-work
#   DOTFILES   env override for the dotfiles checkout (default $HOME/dotfiles)
#   CLAUDE_HOME_SEAT  env override for the primary seat (default $HOME/.claude)
#
# Idempotent and re-runnable — run it again for a third seat, or after a
# `sync.sh claude`. Pre-existing real files/dirs are hardlink-merged into the
# shared tree and then archived as `<name>.pre-seat-link.<ts>`; nothing is
# deleted.
#
set -euo pipefail

SEAT="${HOME}/.claude-work"
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -*) echo "unknown flag: $arg" >&2; exit 2 ;;
        *) SEAT="${arg%/}" ;;
    esac
done

HOME_SEAT="${CLAUDE_HOME_SEAT:-$HOME/.claude}"
DOTFILES="${DOTFILES:-$HOME/dotfiles}"
TS="$(date +%Y%m%d-%H%M%S)"

# --- what is SHARED (symlinked) -------------------------------------------
# name  ->  target
declare -a DOTFILES_LINKS=(
    "CLAUDE.md|$DOTFILES/agents/AGENTS.md"        # the always-loaded global tier
    "skills|$DOTFILES/agents/skills"              # without this, /pulse cannot resolve
    "hooks|$DOTFILES/agents/hooks"                # tmux glyphs, lint, guards
    "agents|$DOTFILES/claude/agents"              # subagent definitions
    "statusline.sh|$DOTFILES/claude/statusline.sh"
    "settings.json|$DOTFILES/claude/settings.json" # hooks + statusLine + remoteControl
)

# Runtime state shared with the primary seat. Every one of these is keyed by
# session UUID (or is account-independent), so two seats cannot collide.
declare -a SHARED_DIRS=(
    projects         # transcripts AND memory/ — the tree the vault sync covers
    todos            # session-UUID keyed
    file-history     # session-UUID keyed; edit-undo belongs with its transcript
    plans            # plan-mode artifacts are work product, not identity
    plugins          # capability parity, same as skills
    shell-snapshots  # timestamp+nonce keyed; one cleanup regime
    session-env      # session-UUID keyed
    tasks            # background-task state, id-keyed
    teams            # agent-teams state, id-keyed
    cache            # CLI changelog; account-independent
)

declare -a SHARED_FILES=(
    settings.local.json   # per-machine permission grants; the tick-jail ro-binds this too
)

# --- what stays SEAT-LOCAL (never touched) ---------------------------------
# .credentials.json  the seat itself
# .claude.json       account identity + per-project hasTrustDialogAccepted
# backups/           backups OF the seat-local .claude.json
# history.jsonl      interactive prompt recall; a scheduled seat would only
#                    pollute it with "/pulse tick" lines, and two appenders on
#                    one 4 MB file buys nothing
# sessions/          keyed by PID, and PIDs recycle across seats
# statsig/ telemetry/ debug/   per-account feature-gate + analytics caches;
#                    sharing could serve one account the other's gate state

# coreutils >= 9.3 warns that `cp -n` is non-portable and wants --update=none.
# Probe once rather than eating the warning with 2>/dev/null.
if cp --help | grep -q -- '--update\['; then
    NOCLOBBER=(--update=none)
else
    NOCLOBBER=(-n)
fi

say() { printf '%s\n' "$*"; }
run() { if [ "$DRY_RUN" = 1 ]; then say "   [dry-run] $*"; else "$@"; fi; }

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
[ "$SEAT" != "$HOME_SEAT" ] || fail "SEAT and primary seat are the same path ($SEAT)"
[ -d "$HOME_SEAT" ] || fail "primary seat $HOME_SEAT does not exist"
[ -d "$DOTFILES" ] || fail "dotfiles checkout $DOTFILES does not exist"

# A fresh seat needs skipDangerousModePermissionPrompt to get past the
# bypass-permissions dialog. If the SHARED settings.json lacks it, replacing a
# local settings.json that HAS it strands the seat at a first-run prompt whose
# only symptom is `bounced-not-ready`.
SHARED_SETTINGS="$DOTFILES/claude/settings.json"
[ -f "$SHARED_SETTINGS" ] || fail "$SHARED_SETTINGS missing"
if command -v jq >/dev/null; then
    [ "$(jq -r '.skipDangerousModePermissionPrompt // false' "$SHARED_SETTINGS")" = "true" ] \
        || fail "$SHARED_SETTINGS lacks skipDangerousModePermissionPrompt:true — the seat would hang at the bypass dialog"
else
    grep -q '"skipDangerousModePermissionPrompt"[[:space:]]*:[[:space:]]*true' "$SHARED_SETTINGS" \
        || fail "$SHARED_SETTINGS lacks skipDangerousModePermissionPrompt:true"
fi

say "seat:     $SEAT"
say "primary:  $HOME_SEAT"
say "dotfiles: $DOTFILES"
[ "$DRY_RUN" = 1 ] && say "MODE:     dry-run (no changes)"
say ""

run mkdir -p "$SEAT"

# --- helpers ---------------------------------------------------------------
same_target() {  # $1 linkname, $2 wanted target
    [ -L "$1" ] || return 1
    [ "$(readlink -f -- "$1" || true)" = "$(readlink -f -- "$2" || true)" ]
}

archive() {  # move a real file/dir aside, never delete
    local p="$1"
    run mv -- "$p" "$p.pre-seat-link.$TS"
    say "   archived  -> $(basename -- "$p").pre-seat-link.$TS"
}

link_entry() {  # $1 linkname (absolute), $2 target (absolute)
    local ln_="$1" tgt="$2"
    if same_target "$ln_" "$tgt"; then
        say "  ok    $(basename -- "$ln_")"
        return
    fi
    if [ -L "$ln_" ]; then
        run rm -- "$ln_"
    elif [ -e "$ln_" ]; then
        archive "$ln_"
    fi
    run ln -s -- "$tgt" "$ln_"
    say "  LINK  $(basename -- "$ln_")  ->  $tgt"
}

merge_and_link_dir() {  # $1 seat dir name, target is $HOME_SEAT/<name>
    local name="$1"
    local seat_dir="$SEAT/$name" tgt="$HOME_SEAT/$name"

    if [ ! -d "$tgt" ] && [ ! -L "$tgt" ]; then
        run mkdir -p "$tgt"
    fi

    if same_target "$seat_dir" "$tgt"; then
        say "  ok    $name/"
        return
    fi

    if [ -L "$seat_dir" ]; then
        run rm -- "$seat_dir"
    elif [ -d "$seat_dir" ]; then
        if [ -n "$(ls -A -- "$seat_dir")" ]; then
            # HARDLINK-merge, no-clobber. Hardlinks matter: a LIVE session holds
            # an open fd on its transcript inode, so linking (rather than
            # copying) means its in-flight appends keep showing up at the shared
            # path. Falls back to a plain copy across filesystems.
            if [ "$DRY_RUN" = 1 ]; then
                say "   [dry-run] hardlink-merge $seat_dir/. -> $tgt/"
            elif cp -al "${NOCLOBBER[@]}" -- "$seat_dir/." "$tgt/"; then
                say "   merged    $name/ -> $tgt/ (hardlinks, no-clobber)"
            else
                cp -a "${NOCLOBBER[@]}" -- "$seat_dir/." "$tgt/"
                say "   merged    $name/ -> $tgt/ (copy, no-clobber)"
            fi
        fi
        archive "$seat_dir"
    elif [ -e "$seat_dir" ]; then
        archive "$seat_dir"
    fi

    run ln -s -- "$tgt" "$seat_dir"
    say "  LINK  $name/  ->  $tgt"
}

# --- wire it ---------------------------------------------------------------
say "== dotfiles-managed config (identical to the primary seat) =="
for spec in "${DOTFILES_LINKS[@]}"; do
    link_entry "$SEAT/${spec%%|*}" "${spec#*|}"
done

say ""
say "== shared runtime state =="
for name in "${SHARED_DIRS[@]}"; do
    merge_and_link_dir "$name"
done
for name in "${SHARED_FILES[@]}"; do
    if [ -e "$HOME_SEAT/$name" ]; then
        link_entry "$SEAT/$name" "$HOME_SEAT/$name"
    else
        say "  skip  $name (absent in $HOME_SEAT)"
    fi
done

say ""
say "== seat-local (untouched) =="
for name in .credentials.json .claude.json backups history.jsonl sessions statsig telemetry debug; do
    if [ -L "$SEAT/$name" ]; then
        say "  ⚠️  $name is a SYMLINK — it must be seat-local; not modified, but check it"
    elif [ -e "$SEAT/$name" ]; then
        say "  keep  $name"
    else
        say "  --    $name (absent; Claude will create it)"
    fi
done

if [ ! -e "$SEAT/.credentials.json" ]; then
    say ""
    say "NOTE: $SEAT/.credentials.json is absent — run"
    say "      CLAUDE_CONFIG_DIR=$SEAT claude   and log in as the seat's account."
fi

say ""
say "done."
