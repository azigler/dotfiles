#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "$(pwd)/${BASH_SOURCE[0]}")")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/.backup/$(date +%Y%m%d%H%M%S)"
cd $SCRIPT_DIR

# THE AGENT TIER IS NOT IN THIS REPO. This is the public tier — program
# configuration. The agent tier (instruction file, skills, hooks, schedulers)
# lives in a separate repository and is resolved through ONE symlink,
# `~/.agents`, installed by ./bootstrap-agents.sh.
#
# Bare existence of the symlink is NOT enough (~/.agents once held an unrelated
# skill-lock), so this is a CONTENT-marker test. Every agent-tier line below
# goes through sync_agent_source, which is a silent no-op when no tier is
# installed: a machine with only these dotfiles syncs its configs cleanly and
# simply has no harness.
AGENT_BRAIN="$HOME/.agents"
if [ -e "$AGENT_BRAIN/claude/settings.json" ] && [ -e "$AGENT_BRAIN/agents/AGENTS.md" ]; then
    HAS_AGENT_TIER=1
else
    HAS_AGENT_TIER=0
fi

# Back up and remove a file or directory.
#   $1: The file or directory to back up.
back_up_and_remove() {
    local to_back_up=$1
    local back_up_to="$BACKUP_DIR$1"
    if [ -e "$to_back_up" ]; then
        mkdir -p "$back_up_to"
        cp -r "$to_back_up" "$back_up_to"
        if [ $? -ne 0 ]; then
            echo "❌ Error: Failed to copy $to_back_up to $back_up_to"
            exit 1
        fi
        rm -rf "$to_back_up"
        echo " ↳ $to_back_up backed up to $back_up_to and deleted"
    fi
}

# Sync a source file or directory to a destination.
#   $1: The source file or directory.
#   $2: The destination to back up and replace with a symlink.
sync_source() {
    local sync_from=$1
    local sync_to=$2
    if [ ! -e "$sync_from" ]; then
        echo "❌ Error: $sync_from does not exist"
        return
    fi
    echo "🗄️ Synchronizing $sync_from to $sync_to..."
    back_up_and_remove "$sync_to"
    mkdir -p "$(dirname "$sync_to")"
    ln -s "$sync_from" "$sync_to"
    if [ $? -ne 0 ]; then
        echo "❌ Error: Failed to create symlink to $sync_to directory"
        exit 1
    fi

}

# Sync an AGENT-TIER source. Identical to sync_source when a tier is installed;
# a silent no-op when none is. Without this, a fresh clone of the public tier
# printed a wall of "does not exist" errors for sources that are deliberately
# absent — indistinguishable from a real failure.
sync_agent_source() {
    [ "$HAS_AGENT_TIER" -eq 1 ] || return 0
    sync_source "$1" "$2"
}

# Sync a source file into a root-owned destination outside $HOME (currently
# only Codex's managed/admin config layer at /etc/codex/config.toml,
# dotfiles-tihhn). Unlike sync_source, this never touches the destination's
# own content afterward — the whole point is a layer Codex reads but never
# writes, so plain `ln -sfn` under sudo is enough; there is no live state at
# that path to back up.
#
# Privilege is probed, never assumed: a host with no passwordless sudo (or a
# non-interactive run) must not hang on a password prompt, and a failure here
# must not abort the rest of `sync` — the codex target has other, unrelated
# steps after this call, and so does every target after "codex" in the case
# statement. So this WARNS and returns (not exits) on any failure.
sync_privileged_source() {
    local sync_from=$1
    local sync_to=$2
    if [ ! -e "$sync_from" ]; then
        echo "❌ Error: $sync_from does not exist"
        return
    fi
    if ! sudo -n true 2>/dev/null; then
        echo "⚠️  No passwordless sudo — skipping $sync_to. Run by hand: sudo ln -sfn $sync_from $sync_to"
        return
    fi
    echo "🔒 Synchronizing $sync_from to $sync_to (sudo)..."
    if ! sudo mkdir -p "$(dirname "$sync_to")"; then
        echo "⚠️  Error: sudo mkdir -p $(dirname "$sync_to") failed — skipping $sync_to"
        return
    fi
    if ! sudo ln -sfn "$sync_from" "$sync_to"; then
        echo "⚠️  Error: failed to create symlink to $sync_to — skipping"
        return
    fi
}

sync() {
    local dir=$1
    case ${dir} in
        "alacritty")
            sync_source "$SCRIPT_DIR/alacritty" "$HOME/.config/alacritty"
            ;;
        "bash")
            [[ ! -f "$SCRIPT_DIR/bash/.$(hostname -s).bashrc" ]] || sync_source "$SCRIPT_DIR/bash/.$(hostname -s).bashrc" "$HOME/.$(hostname -s).bashrc"
            sync_source "$SCRIPT_DIR/bash/.bash_aliases" "$HOME/.bash_aliases"
            sync_source "$SCRIPT_DIR/bash/.bash_login" "$HOME/.bash_login"
            sync_source "$SCRIPT_DIR/bash/.bash_logout" "$HOME/.bash_logout"
            sync_source "$SCRIPT_DIR/bash/.bash_profile" "$HOME/.bash_profile"
            sync_source "$SCRIPT_DIR/bash/.bashrc" "$HOME/.bashrc"
            sync_source "$SCRIPT_DIR/bash/.inputrc" "$HOME/.inputrc"
            sync_source "$SCRIPT_DIR/bash/.profile" "$HOME/.profile"
            ;;
        "blightmud")
            # Plugins live under .local/share/blightmud/ (per Blightmud's plugin dir)
            sync_source "$SCRIPT_DIR/blightmud/autoload_plugins.ron" "$HOME/.local/share/blightmud/autoload_plugins.ron"
            [[ ! -d "$SCRIPT_DIR/blightmud/plugins" ]] || sync_source "$SCRIPT_DIR/blightmud/plugins" "$HOME/.local/share/blightmud/plugins"
            # Per-server configs + dispatcher live under .config/blightmud/
            sync_source "$SCRIPT_DIR/blightmud/config.lua" "$HOME/.config/blightmud/config.lua"
            sync_source "$SCRIPT_DIR/blightmud/cod.lua" "$HOME/.config/blightmud/cod.lua"
            sync_source "$SCRIPT_DIR/blightmud/chatmud.lua" "$HOME/.config/blightmud/chatmud.lua"
            sync_source "$SCRIPT_DIR/blightmud/cf.lua" "$HOME/.config/blightmud/cf.lua"
            sync_source "$SCRIPT_DIR/blightmud/ifmud.lua" "$HOME/.config/blightmud/ifmud.lua"
            sync_source "$SCRIPT_DIR/blightmud/dw.lua" "$HOME/.config/blightmud/dw.lua"
            sync_source "$SCRIPT_DIR/blightmud/cthulhumud.lua" "$HOME/.config/blightmud/cthulhumud.lua"
            sync_source "$SCRIPT_DIR/blightmud/servers.ron" "$HOME/.config/blightmud/servers.ron"
            sync_source "$SCRIPT_DIR/blightmud/settings.ron" "$HOME/.config/blightmud/settings.ron"
            # .env.local stays local (passwords) — never symlinked, never committed
            ;;
        "borders")
            sync_source "$SCRIPT_DIR/borders/bordersrc" "$HOME/.config/borders/bordersrc"
            ;;
        "bun")
            sync_source "$SCRIPT_DIR/bun/.bunfig.toml" "$HOME/.bunfig.toml"
            ;;
        "biome")
            sync_source "$SCRIPT_DIR/biome/biome.json" "$HOME/.config/biome/biome.json"
            ;;
        "cargo")
            sync_source "$SCRIPT_DIR/cargo/config.toml" "$HOME/.cargo/config.toml"
            ;;
        "claude")
            sync_agent_source "$AGENT_BRAIN/claude/settings.json" "$HOME/.claude/settings.json"
            sync_agent_source "$AGENT_BRAIN/claude/agents" "$HOME/.claude/agents"
            sync_agent_source "$AGENT_BRAIN/agents/hooks" "$HOME/.claude/hooks"
            sync_agent_source "$AGENT_BRAIN/agents/skills" "$HOME/.claude/skills"
            sync_agent_source "$AGENT_BRAIN/agents/AGENTS.md" "$HOME/.claude/CLAUDE.md"
            sync_agent_source "$AGENT_BRAIN/claude/statusline.sh" "$HOME/.claude/statusline.sh"
            ;;
        "codex")
            # Tracked policy lives in the managed/admin layer, which Codex
            # reads but never writes to (dotfiles-tihhn) — see
            # codex/managed_config.toml for the probe + verification,
            # including a live precedence proof (System beats User).
            sync_privileged_source "$SCRIPT_DIR/codex/managed_config.toml" "/etc/codex/config.toml"
            # $HOME/.codex/config.toml is Codex's own writable layer (project
            # trust_level entries, [tui] state) and sync.sh must not manage
            # its content — copying tracked POLICY keys into it would win
            # forever, since User outranks System. One-time migration: if a
            # prior run of this script (pre-dotfiles-tihhn) left the old
            # tracked symlink in place, extract ONLY the Codex-written keys
            # ([projects.*], [tui]) into a plain file via
            # codex/migrate-user-config.py, dropping every policy key and
            # every [projects.*] entry that is scratch junk (/tmp, or a path
            # that no longer exists).
            #
            # The symlink may be DANGLING by the time this runs: merging
            # dotfiles-tihhn deletes codex/config.toml (renamed to
            # managed_config.toml), so `readlink -f` no longer resolves.
            # Fall back to git history for the pre-deletion content, and
            # fail loud — never silently skip — if neither source exists.
            if [ -L "$HOME/.codex/config.toml" ]; then
                OLD_CODEX_CONFIG=""
                CODEX_MIGRATE_TMP=""
                RESOLVED="$(readlink -f "$HOME/.codex/config.toml" 2>/dev/null)"
                if [ -n "$RESOLVED" ] && [ -e "$RESOLVED" ]; then
                    OLD_CODEX_CONFIG="$RESOLVED"
                else
                    DELETE_SHA="$(git -C "$SCRIPT_DIR" log -1 --format=%H -- codex/config.toml 2>/dev/null)"
                    CODEX_MIGRATE_TMP="$(mktemp)"
                    if [ -n "$DELETE_SHA" ] && git -C "$SCRIPT_DIR" show "${DELETE_SHA}^:codex/config.toml" >"$CODEX_MIGRATE_TMP" 2>/dev/null && [ -s "$CODEX_MIGRATE_TMP" ]; then
                        OLD_CODEX_CONFIG="$CODEX_MIGRATE_TMP"
                    else
                        rm -f "$CODEX_MIGRATE_TMP"
                    fi
                fi
                if [ -z "$OLD_CODEX_CONFIG" ]; then
                    echo "❌ Error: $HOME/.codex/config.toml is a dangling symlink and its pre-deletion content can't be found (target gone, no git history for codex/config.toml either). Recover it by hand — see MIGRATION.md — before re-running sync.sh codex."
                    exit 1
                fi
                echo "🔓 Converting $HOME/.codex/config.toml from tracked symlink to a plain Codex-owned file (policy keys + scratch [projects.*] junk dropped)..."
                rm -f "$HOME/.codex/config.toml"
                if ! python3 "$SCRIPT_DIR/codex/migrate-user-config.py" "$OLD_CODEX_CONFIG" "$HOME/.codex/config.toml"; then
                    echo "❌ Error: migration of $HOME/.codex/config.toml failed"
                    exit 1
                fi
                [ -n "$CODEX_MIGRATE_TMP" ] && rm -f "$CODEX_MIGRATE_TMP"
            fi
            sync_agent_source "$AGENT_BRAIN/agents/skills" "$HOME/.codex/skills"
            sync_agent_source "$AGENT_BRAIN/agents/AGENTS.md" "$HOME/.codex/AGENTS.md"
            ;;
        "copilot")
            sync_source "$SCRIPT_DIR/copilot/config.json" "$HOME/.copilot/config.json"
            ;;
        "cursor")
            if command -v cursor >/dev/null 2>&1; then
                [[ ! -f "$SCRIPT_DIR/cursor/install_extensions.sh" ]] || sh "$SCRIPT_DIR/cursor/install_extensions.sh"
            fi
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sync_source "$SCRIPT_DIR/cursor/settings.json" "/Users/$USER/Library/Application Support/Cursor/User/settings.json"
            fi
            sync_source "$SCRIPT_DIR/cursor/cli-config.json" "$HOME/.cursor/cli-config.json"
            sync_source "$SCRIPT_DIR/cursor/hooks.json" "$HOME/.cursor/hooks.json"
            sync_agent_source "$AGENT_BRAIN/agents/hooks" "$HOME/.cursor/hooks"
            sync_agent_source "$AGENT_BRAIN/agents/skills" "$HOME/.cursor/skills"
            ;;
        "direnv")
            sync_source "$SCRIPT_DIR/direnv" "$HOME/.config/direnv"
            sync_source "$SCRIPT_DIR/direnv/.direnvrc" "$HOME/.direnvrc"
            ;;
        "editorconfig")
            sync_source "$SCRIPT_DIR/editorconfig/.editorconfig" "$HOME/.editorconfig"
            ;;
        "frida")
            # Opt-in RE tier (re/README.md). frida-tools lives in ~/.venvs/re,
            # installed by re.setup.sh — nothing here puts it on PATH.
            sync_source "$SCRIPT_DIR/frida" "$HOME/.config/frida"
            ;;
        "gdb")
            # Shared by gdb AND gdb-multiarch: keep target-specific setup out
            # of it (see the file's own header).
            sync_source "$SCRIPT_DIR/gdb/.gdbinit" "$HOME/.gdbinit"
            ;;
        "gemini")
            sync_source "$SCRIPT_DIR/gemini/settings.json" "$HOME/.gemini/settings.json"
            sync_agent_source "$AGENT_BRAIN/agents/hooks" "$HOME/.gemini/hooks"
            sync_agent_source "$AGENT_BRAIN/agents/skills" "$HOME/.gemini/skills"
            sync_agent_source "$AGENT_BRAIN/agents/AGENTS.md" "$HOME/.gemini/GEMINI.md"
            ;;
        "golangci-lint")
            sync_source "$SCRIPT_DIR/golangci-lint/.golangci.yml" "$HOME/.config/golangci-lint/.golangci.yml"
            ;;
        "gh")
            sync_source "$SCRIPT_DIR/gh/config.yml" "$HOME/.config/gh/config.yml"
            # gpg.program is machine-local (Mac brew vs Linux system) — write
            # to ~/.gitconfig.local (included by the tracked .gitconfig) so the
            # tracked file stays portable.
            _gpg="$(command -v gpg)"
            [[ -n "$_gpg" ]] && git config --file "$HOME/.gitconfig.local" gpg.program "$_gpg"
            unset _gpg
            ;;
        "git")
            sync_source "$SCRIPT_DIR/git/.gitconfig" "$HOME/.gitconfig"
            sync_source "$SCRIPT_DIR/git/ignore" "$HOME/.config/git/ignore"
            ;;
        "gnupg")
            sync_source "$SCRIPT_DIR/gnupg/common.conf" "$HOME/.gnupg/common.conf"
            sync_source "$SCRIPT_DIR/gnupg/gpg.conf" "$HOME/.gnupg/gpg.conf"
            # pinentry-mac is macOS-only, and so is brew. Unguarded, this line
            # ran on Linux too and wrote a literal
            #   pinentry-program /bin/pinentry-mac
            # (brew not found -> empty prefix) into a gpg-agent.conf that then
            # points at a binary which will never exist on the box.
            if [[ "$OSTYPE" == "darwin"* ]] && command -v brew >/dev/null; then
                echo "pinentry-program $(brew --prefix)/bin/pinentry-mac" > "$HOME/.gnupg/gpg-agent.conf"
            fi
            ;;
        "nix")
            sync_source "$SCRIPT_DIR/nix/nix.conf" "$HOME/.config/nix/nix.conf"
            ;;
        "npm")
            sync_source "$SCRIPT_DIR/npm/.npmrc" "$HOME/.npmrc"
            ;;
        "radare2")
            # Read on EVERY r2 invocation, including scripted `r2 -q -c` runs.
            sync_source "$SCRIPT_DIR/radare2" "$HOME/.config/radare2"
            ;;
        "ranger")
            sync_source "$SCRIPT_DIR/ranger" "$HOME/.config/ranger"
            ;;
        "ripgrep")
            sync_source "$SCRIPT_DIR/ripgrep/.ripgreprc" "$HOME/.ripgreprc"
            ;;
        "ruff")
            sync_source "$SCRIPT_DIR/ruff/ruff.toml" "$HOME/.config/ruff/ruff.toml"
            ;;
        "sketchybar")
            sync_source "$SCRIPT_DIR/sketchybar" "$HOME/.config/sketchybar"
            ;;
        "skhd")
            sync_source "$SCRIPT_DIR/skhd" "$HOME/.config/skhd"
            sync_source "$SCRIPT_DIR/skhd/skhdrc" "$HOME/.skhdrc"
            ;;
        "ssh")
            if [[ ! -f "$HOME/.ssh/local" && -f "$HOME/.ssh/config" && ! -L "$HOME/.ssh/config" ]]; then
                mv "$HOME/.ssh/config" "$HOME/.ssh/local"
            fi
            sync_source "$SCRIPT_DIR/ssh/config" "$HOME/.ssh/config"
            if [[ -L "$HOME/.ssh/config" && ! -f "$HOME/.ssh/local" ]]; then
                touch "$HOME/.ssh/local"
            fi
            ;;
        "tmux")
            sync_source "$SCRIPT_DIR/tmux/tmux.conf" "$HOME/.tmux.conf"
            sync_source "$SCRIPT_DIR/tmux/start.sh" "$HOME/.local/share/tmux/start.sh"
            sync_source "$SCRIPT_DIR/tmux/plugins" "$HOME/.tmux/plugins"
            # Linux: own the tmux server from the user manager rather than from
            # whichever login session happened to start it. Symlink ONLY —
            # enabling and starting the unit restarts the server and kills every
            # existing session, so that stays a deliberate manual step:
            #   systemctl --user daemon-reload
            #   systemctl --user enable tmux.service   # boot-time ownership
            #   systemctl --user start  tmux.service   # takes effect now (disruptive)
            if [[ "$OSTYPE" == "linux-gnu"* ]] && command -v systemctl >/dev/null; then
                sync_source "$SCRIPT_DIR/tmux/tmux.service" "$HOME/.config/systemd/user/tmux.service"
            fi
            ;;
        "ts4")
            source "$SCRIPT_DIR/ts4/sync.sh" "${@:2}"
            ;;
        "uv")
            sync_source "$SCRIPT_DIR/uv/uv.toml" "$HOME/.config/uv/uv.toml"
            ;;
        "vim")
            sync_source "$SCRIPT_DIR/vim" "$HOME/.vim"
            sync_source "$SCRIPT_DIR/vim/vimrc" "$HOME/.vimrc"
            ;;
        "vscode")
            if command -v code >/dev/null 2>&1; then
                [[ ! -f "$SCRIPT_DIR/vscode/install_extensions.sh" ]] || sh "$SCRIPT_DIR/vscode/install_extensions.sh"
            fi
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sync_source "$SCRIPT_DIR/vscode/settings.json" "$HOME/Library/Application Support/Code/User/settings.json"
            elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
                sync_source "$SCRIPT_DIR/vscode/settings.json" "$HOME/.config/Code/User/settings.json"
            fi
            ;;
        "yabai")
            sync_source "$SCRIPT_DIR/yabai/yabairc" "$HOME/.config/yabai/yabairc"
            sync_source "$SCRIPT_DIR/yabai/yabairc" "$HOME/.yabairc"
            ;;
        "zsh")
            sync_source "$SCRIPT_DIR/zsh/ohmyzsh" "$HOME/.oh-my-zsh"
            [[ ! -f "$SCRIPT_DIR/zsh/.$(hostname -s).zsh" ]] || sync_source "$SCRIPT_DIR/zsh/.$(hostname -s).zsh" "$HOME/.$(hostname -s).zsh"
            # Per-host NON-interactive env (the .zshenv tier). Without this the
            # fleet-wide zsh/.zshenv silently reverts a box's remote-automation
            # PATH every time sync runs.
            [[ ! -f "$SCRIPT_DIR/zsh/.$(hostname -s).zshenv" ]] || sync_source "$SCRIPT_DIR/zsh/.$(hostname -s).zshenv" "$HOME/.$(hostname -s).zshenv"
            sync_source "$SCRIPT_DIR/zsh/.zlogin" "$HOME/.zlogin"
            sync_source "$SCRIPT_DIR/zsh/.zlogout" "$HOME/.zlogout"
            sync_source "$SCRIPT_DIR/zsh/.zprofile" "$HOME/.zprofile"
            sync_source "$SCRIPT_DIR/zsh/.zshenv" "$HOME/.zshenv"
            sync_source "$SCRIPT_DIR/zsh/.zshrc" "$HOME/.zshrc"
            sync_source "$SCRIPT_DIR/zsh/.p10k.zsh" "$HOME/.p10k.zsh"
            sync_source "$SCRIPT_DIR/zsh/.antigen" "$HOME/.antigen"
            ;;
    esac
}

if [ -n "$1" ]; then
    sync "$@"
    echo "Ran sync.sh for $1"
else
    for dir in */ .*/; do
        sync "${dir%/}"
    done
    # The loop above iterates over DIRECTORIES IN THIS REPO, and the `claude`
    # arm no longer has one — the agent tier is external. Without this line a
    # plain `./sync.sh` on a machine that HAS a tier would silently skip the
    # whole ~/.claude wiring while every other agent-aware arm (codex, cursor,
    # gemini — all of which still have a directory here) kept working.
    # No-op when no tier is installed; sync_agent_source sees to that.
    sync claude
fi
