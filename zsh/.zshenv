# Sourced by EVERY zsh — including the non-login, non-interactive shell that
# `ssh host "cmd"` gets, which is the one remote automation actually runs in.
# Keep it cheap and strictly additive; never clobber $PATH.

# Guarded: an absent ~/.cargo/env used to error on every shell on a box
# without rustup.
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# Per-host NON-interactive env — the .zshenv-tier twin of the
# `.$(hostname -s).zsh` hook that .zshrc uses for interactive shells.
# ${HOST%%.*} rather than $(hostname -s): this file runs on every single zsh
# invocation, and a fork per shell is a cost worth not paying. zsh sets HOST
# itself, so the two agree.
[ -f "$HOME/.${HOST%%.*}.zshenv" ] && . "$HOME/.${HOST%%.*}.zshenv"

# kecb (2026-08-09): DROP AN INHERITED ATTRIBUTION HEADER BLOCK.
#
# THE DEFECT, measured 19:23Z. claude-identity-wrapper.sh sets
# ANTHROPIC_CUSTOM_HEADERS per LAUNCH — but Claude Code EXPORTS it to its own
# children, so every Bash-tool shell inside a session inherits its parent's
# `X-Tap`. `env CLAUDE_CONFIG_DIR=~/.claude-secondary claude -p …` from such a
# shell invokes the BINARY (a shell function is not inherited by `env`), so the
# wrapper never runs, the request BILLS to secondary, and the stale ambient
# header confidently attributes it to the other account. Silent cross-billing —
# the one thing the tap system exists to prevent — from an idiom already
# documented as wrong in ~/.zig-computer.zshenv's lb-claude note.
#
# THE FIX IS NEGATIVE, and deliberately so: an attribution claim must bind to
# the effective CLAUDE_CONFIG_DIR of the process making the request, and an
# inherited one cannot. So it is DROPPED here, in the file every zsh sources —
# including the non-interactive Bash-tool shell, which is where the poison
# lives. A bypassed launch then sends no header and logs as `unknown`: visibly
# unattributed, which is recoverable, instead of confidently wrong, which is
# not. Nothing is lost: the wrapper recomputes the block on every launch.
#
# Scoped by OUR marker (`X-Tap: `) so a header block someone set deliberately
# for another purpose survives. Cheap: one pattern test, no forks.
case "${ANTHROPIC_CUSTOM_HEADERS-}" in
  *"X-Tap: "*) unset ANTHROPIC_CUSTOM_HEADERS ;;
esac

# n3b6 (2026-08-09): AGENTS_ROOT — where the live agent tier resolves, derived
# from the ~/.agents indirection when it holds real tier content (the 860z
# cutover), else the pre-split repo path. Cheap: two stats, no forks on the
# happy path except the readlink.
if [ -e "$HOME/.agents/agents/AGENTS.md" ]; then
  export AGENTS_ROOT="$(readlink -f "$HOME/.agents" 2>/dev/null)/agents"
else
  export AGENTS_ROOT="$HOME/dotfiles/agents"
fi
