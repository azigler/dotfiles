#!/usr/bin/env bash
# bootstrap-agents.sh — install the AGENT TIER next to these dotfiles.
#
# This repository is the PUBLIC tier: program configuration only (shell, tmux,
# editors, tools). The agent tier — the always-loaded instruction file, the
# skills, the hooks, the schedulers — lives in a SEPARATE, private repository
# and is resolved at runtime through one symlink, `~/.agents`. Everything in
# `sync.sh` that touches the agent tier goes through that symlink, so a machine
# with no agent tier syncs its configs and simply has no harness.
#
# This script is the other half: point it at an agent-tier repository and it
# clones it, wires `~/.agents`, and re-runs the agent arm of `sync.sh`.
#
# THE REPOSITORY IS NOT NAMED HERE, ON PURPOSE. It is required input:
#
#     AGENTS_REPO=owner/repo            ./bootstrap-agents.sh   # via `gh`
#     AGENTS_REPO=git@host:owner/repo   ./bootstrap-agents.sh   # via `git`
#     AGENTS_REPO=https://host/o/r.git  ./bootstrap-agents.sh   # via `git`
#     AGENTS_REPO=/path/to/local/clone  ./bootstrap-agents.sh   # via `git`
#
# The `owner/repo` short form goes through `gh repo clone`, so it works for a
# private repository with no extra credential beyond a `gh` login that can
# already see it — `gh auth status` is checked first and a failure stops here
# rather than at a confusing git error. Any other form is handed to `git clone`
# verbatim.
#
#   AGENTS_DIR   where to clone to. Default: ~/<basename of AGENTS_REPO>.
#
# Idempotent: an existing clone at AGENTS_DIR is reused (never pulled — that is
# the clone owner's decision, not this script's), and an existing `~/.agents`
# already pointing at it is left alone.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() { printf '❌ %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

: "${AGENTS_REPO:?AGENTS_REPO is required — the agent-tier repository to install.
   owner/repo (cloned with gh, works for a private repo), or any git URL or
   local path (cloned with git). Example:
       AGENTS_REPO=owner/repo ./bootstrap-agents.sh}"

# --- where it lands --------------------------------------------------------
_base="${AGENTS_REPO%/}"
_base="${_base##*/}"
_base="${_base%.git}"
[ -n "$_base" ] || die "could not derive a directory name from AGENTS_REPO='$AGENTS_REPO'"
AGENTS_DIR="${AGENTS_DIR:-$HOME/$_base}"

# --- clone -----------------------------------------------------------------
# `owner/repo` ONLY when it is not also a path that exists — a relative path to
# a sibling checkout is a real and useful spelling, and it must not be sent to
# a code host.
clone_with_gh=0
if [ ! -e "$AGENTS_REPO" ] && printf '%s' "$AGENTS_REPO" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    clone_with_gh=1
fi

if [ -e "$AGENTS_DIR/.git" ]; then
    info "↳ reusing the existing clone at $AGENTS_DIR (not pulled)"
elif [ -e "$AGENTS_DIR" ]; then
    die "$AGENTS_DIR exists and is not a git clone. Move it aside, or set AGENTS_DIR."
elif [ "$clone_with_gh" -eq 1 ]; then
    command -v gh >/dev/null || die "AGENTS_REPO='$AGENTS_REPO' is an owner/repo short form, which needs the GitHub CLI (gh). Install gh, or pass a full git URL / local path."
    gh auth status || die "gh is not authenticated — run 'gh auth login' first. (A private agent tier needs a login that can see it.)"
    info "🗄️ Cloning $AGENTS_REPO to $AGENTS_DIR with gh..."
    gh repo clone "$AGENTS_REPO" "$AGENTS_DIR" || die "gh repo clone failed for '$AGENTS_REPO'"
else
    info "🗄️ Cloning $AGENTS_REPO to $AGENTS_DIR with git..."
    git clone "$AGENTS_REPO" "$AGENTS_DIR" || die "git clone failed for '$AGENTS_REPO'"
fi

# --- prove it is an agent tier, not just a directory -----------------------
# The same CONTENT markers sync.sh tests. Bare existence is not enough: a
# ~/.agents that resolves to something without a tier in it is worse than no
# ~/.agents at all, because every agent-tier symlink then points into it.
for marker in agents/AGENTS.md claude/settings.json; do
    [ -e "$AGENTS_DIR/$marker" ] || die "$AGENTS_DIR is missing $marker — that is not an agent tier. Nothing was linked."
done

# --- wire ~/.agents --------------------------------------------------------
LINK="$HOME/.agents"
target="$(cd -- "$AGENTS_DIR" && pwd -P)"
if [ -L "$LINK" ]; then
    current="$(readlink -f "$LINK")"
    if [ "$current" = "$target" ]; then
        info "↳ $LINK already points at $target"
    else
        die "$LINK already points at $current, not $target. Remove it deliberately, then re-run."
    fi
elif [ -e "$LINK" ]; then
    die "$LINK exists and is not a symlink. Move it aside, then re-run."
else
    ln -s "$target" "$LINK" || die "could not create the symlink $LINK"
    info "🔗 $LINK -> $target"
fi

# --- re-run the agent arm of sync.sh ---------------------------------------
# sync.sh resolves the agent tier through ~/.agents, so this is what actually
# puts the harness on disk (~/.claude/{settings.json,hooks,skills,CLAUDE.md}).
# The other agent-aware arms (codex, cursor, gemini) resolve the same way and
# are covered by a plain `./sync.sh`.
info "🗄️ Wiring the harness: ./sync.sh claude"
"$SCRIPT_DIR/sync.sh" claude || die "sync.sh claude failed"

# --- say what landed -------------------------------------------------------
info ""
info "✅ Agent tier installed."
info "   ~/.agents        -> $target"
for p in "$HOME/.claude/CLAUDE.md" "$HOME/.claude/settings.json" "$HOME/.claude/hooks" "$HOME/.claude/skills"; do
    if [ -e "$p" ]; then
        info "   $(printf '%-24s' "${p#"$HOME"/}") ok"
    else
        info "   $(printf '%-24s' "${p#"$HOME"/}") MISSING"
    fi
done
info ""
info "Run './sync.sh' for the remaining agent-aware arms (codex, cursor, gemini)."
