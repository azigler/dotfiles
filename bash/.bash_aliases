# Brew aliases
if [[ "$OSTYPE" == "darwin"* ]]; then
	alias abrew="/opt/homebrew/bin/brew"
	alias ibrew="arch -x86_64 /usr/local/bin/brew"
fi

# For .profile prompt
alias cpu="grep 'cpu ' /proc/stat | awk '{usage=(\$2+\$4)*100/(\$2+\$4+\$5)} END {print usage}' | awk '{printf(\"%.1f\n\", \$1)}'"
alias da="date '+%a %b %d 󰃭 %T %p'"

# Information aliases
alias topcpu="/bin/ps -eo pcpu,pid,user,args | sort -k 1 -r | head -10"
alias folders="du -h --max-depth=1"
alias mountedinfo="df -hT"
alias checkcommand="type -t"
alias openports='ss -nape --inet'
alias logs="sudo find /var/log -type f -exec file {} \; | grep 'text' | cut -d' ' -f1 | sed -e's/:$//g' | grep -v '[0-9]$' | xargs tail -f"
alias countfiles="for t in files links directories; do echo \`find . -type \${t:0:1} | wc -l\` \$t; done 2> /dev/null"

# Navigation aliases
alias bd='cd "$OLDPWD"'
alias rmd='/bin/rm  --recursive --force --verbose '
alias home='cd ~'
alias cd..='cd ..'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'

up ()
{
	local d=""
	limit=$1
	for ((i=1 ; i <= limit ; i++))
		do
			d=$d/..
		done
	d=$(echo $d | sed 's/^\///')
	if [ -z "$d" ]; then
		d=..
	fi
	cd $d
}

# ls command aliases
alias ls="ls -aFh --color=always"
alias la='ls -Alh' # show hidden files
alias lx='ls -lXBh' # sort by extension
alias lk='ls -lSrh' # sort by size
alias lc='ls -lcrh' # sort by change time
alias lu='ls -lurh' # sort by access time
alias lr='ls -lRh' # recursive ls
alias lt='ls -ltrh' # sort by date
alias lm='ls -alh |more' # pipe through 'more'
alias lw='ls -xAh' # wide listing format
alias ll='ls -Fls' # long listing format
alias labc='ls -lap' # alphabetical sort
alias lf="ls -l | egrep -v '^d'" # files only
alias ldir="ls -l | egrep '^d'" # directories only

# chmod command aliases
alias mx='chmod a+x'
alias 000='chmod -R 000'
alias 644='chmod -R 644'
alias 666='chmod -R 666'
alias 755='chmod -R 755'
alias 777='chmod -R 777'

# openssl command aliases
alias sha1='openssl sha1'
alias sha256='openssl sha256'

# Search aliases
alias h="history | grep "
alias p="ps aux | grep "
alias f="find . | grep "

ftext ()
{
	grep -iIHrn --color=always "$1" . | less -r
}

# Better defaults
alias dir="ls -C -b"
alias vdir="ls -l -b"
alias grep="grep --color=auto"
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -iv'
alias mkdir='mkdir -p'
alias ps='ps auxf'
alias ping='ping -c 10'
alias less='less -R'
alias cls='clear'
alias apt-get='sudo apt-get'
alias multitail='multitail --no-repeat -c'
alias freshclam='sudo freshclam'
alias vi='vim'
alias svi='sudo vi'
alias vis='vim "+set si"'

cd ()
{
	if [ -n "$1" ]; then
		builtin cd "$@"
	else
		builtin cd ~
	fi
}

trim()
{
	local var=$@
	var="${var#"${var%%[![:space:]]*}"}"
	var="${var%"${var##*[![:space:]]}"}"
	echo -n "$var"
}

# Durable-session-identity wrapper (P1, explore-qmsy): defines a claude() function
# that stamps a per-session attribution header (X-Session-Identity: session:window) so
# the agentgateway can attribute each LLM call to the durable tmux window. Preserves
# --dangerously-skip-permissions, passes args through, fails open, SUBSCRIPTION-SAFE
# (custom header only, never a gateway credential). Falls back to the plain alias if
# the wrapper file is missing.
if [ -f "$HOME/dotfiles/agents/lib/claude-identity-wrapper.sh" ]; then
  . "$HOME/dotfiles/agents/lib/claude-identity-wrapper.sh"
else
  alias claude='claude --dangerously-skip-permissions'
fi
#alias copilot='bun run copilot'
#alias codex='bun run codex'
#alias gemini='bun run gemini'
alias cursor='agent'
# goose ALWAYS runs the untrusted local model, so it always runs jailed (low-model-trust
# confinement, explore-qe32). To run goose UNjailed, call the binary directly: ~/.local/bin/goose
if [ -x "$HOME/explore/tools/goose-jail/goose-jailed.sh" ]; then
  alias goose="$HOME/explore/tools/goose-jail/goose-jailed.sh"
fi
#alias vercel='bun run vercel'

if [ -f "$HOME/.secrets" ]; then
    source "$HOME/.secrets"
fi

# Machine-local server aliases (UNTRACKED, per-box: e.g. `zig-computer` ->
# ssh to the box). Guarded, so this is a no-op on any machine without the
# file — which is why it costs upstream nothing to keep.
#
# This line was DROPPED in the 723-commit fast-forward on 2026-08-01 (the
# local version of this file sourced it; origin's sourced ~/.secrets instead,
# and the migration between them was flagged and then never done). Losing it
# undefined `zig-computer`, so sketchybar's hook clicked open an Alacritty
# window that ran `zsh -lic zig-computer`, failed, and closed instantly. The
# breakage surfaced two layers away from the file that caused it.
if [ -f "$HOME/.servers.bash_aliases" ]; then
    source "$HOME/.servers.bash_aliases"
fi

# --- Tailscale tailnet SSH aliases (zig-zone) ---
# `tailscale ip -4 <host>` is a tailnet-internal lookup that bypasses DNS —
# works on macOS regardless of which Tailscale variant is installed (the
# headless brew formula can't do MagicDNS; this still works).
# Fallback to bare hostname if tailscale isn't installed or the lookup fails.
alias ssh-zig='ssh ubuntu@$(tailscale ip -4 zig-computer 2>/dev/null || echo zig-computer)'
alias ssh-pico='ssh pico@$(tailscale ip -4 pico 2>/dev/null || echo pico)'

# --- Claude Code LLM routing ---
# The cc-gw / cc-direct / cc-route toggle lived here until 2026-07-28. It wrote
# ANTHROPIC_BASE_URL into ~/.claude/settings.json, which is now the WRONG home:
# that file is fleet-wide, and the gateway is reachable from some machines and
# not others (marketing-vps could not reach pico's tailnet address at all, and every
# claude call there failed while the config looked fine).
#
# Routing is now per-host and ON by default where it works, via the .zshenv tier —
# and, since 2026-07-29, ALSO re-derived at launch by the claude() wrapper below.
# The .zshenv tier alone was a shell-START-time setting: the harness's durable tmux
# panes hold zsh processes older than the move, so they never sourced it and every
# claude launched from them bypassed the gateway. Pico's request log went blind on
# 2026-07-28 with nothing to alarm on it. The wrapper reads the same per-host file
# per invocation, which makes the setting shell-age-independent.
#     zsh/.zig-computer.zshenv   exports ANTHROPIC_BASE_URL
#     zsh/.metis.zshenv          exports ANTHROPIC_BASE_URL
#     zsh/.marketing-vps.zshenv  DOES too, since 2026-08-03 — that box is not a
#                                tailnet peer, so it reaches pico through a chained
#                                ssh -L kept alive by claude-gateway-tunnel.timer
# zsh/.zshenv sources ~/.${HOST%%.*}.zshenv; sync.sh links the matching one.
#
# The two things the old toggle also carried, and where they went:
#   - ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5[1m] — still set fleet-wide in
#     claude/settings.json. Harmless on a host with no gateway, and load-bearing
#     on one with it (behind a custom base URL, CC will not auto-upgrade to 1M
#     and a RESUMED session comes back at 200k — dotfiles-w1r).
#   - cc-direct as an ESCAPE HATCH, for when the gateway's o11y body-size limit
#     503s a huge request (context compaction is the usual victim). Replacement,
#     in the shell you are about to launch from:
#         CC_NO_GATEWAY=1 claude
#     (`unset ANTHROPIC_BASE_URL && claude` was the form until 2026-07-29 and no
#     longer bypasses anything — the wrapper re-derives the value. CC_NO_GATEWAY is
#     checked first.) For a lasting bypass, comment out the export in the per-host
#     .zshenv.

# --- goose through the pico agentgateway (local model + omni MCP) ---
# Runs goose with its OpenAI provider pointed at the gateway's local-model route
# (:15003 -> pico ollama). The omni MCP endpoint (:15001) is wired in goose's
# ~/.config/goose/config.yaml. Scoped to the goose invocation only (doesn't touch
# global OPENAI_* for other tools). Pick the model with GOOSE_MODEL (qwen3-coder:30b
# does tool-calling well; small models fumble it). goose presents its virtual key
# (sk-goose, from ~/.secrets) as OPENAI_API_KEY so its LLM calls are attributed to
# "goose"; the omni MCP header (~/.config/goose/config.yaml) carries the same key for
# tool scoping. Usage: goose-gw run -t "..."
alias goose-gw='OPENAI_API_KEY="$GATEWAY_GOOSE_KEY" OPENAI_HOST=http://100.72.47.4:15003 goose'
