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

alias claude='claude --dangerously-skip-permissions'
#alias copilot='bun run copilot'
#alias codex='bun run codex'
#alias gemini='bun run gemini'
alias cursor='agent'
#alias vercel='bun run vercel'

if [ -f "$HOME/.secrets" ]; then
    source "$HOME/.secrets"
fi

# --- Tailscale tailnet SSH aliases (zig-zone) ---
# `tailscale ip -4 <host>` is a tailnet-internal lookup that bypasses DNS —
# works on macOS regardless of which Tailscale variant is installed (the
# headless brew formula can't do MagicDNS; this still works).
# Fallback to bare hostname if tailscale isn't installed or the lookup fails.
alias ssh-zig='ssh ubuntu@$(tailscale ip -4 zig-computer 2>/dev/null || echo zig-computer)'
alias ssh-pico='ssh pico@$(tailscale ip -4 pico 2>/dev/null || echo pico)'

# --- Claude Code <-> agentgateway routing toggle (the kill switch) ---
# Routes Claude Code through the pico agentgateway o11y/gov plane, or back to
# direct-to-Anthropic. Claude Code reads ANTHROPIC_BASE_URL at LAUNCH, so RESTART
# your CC session after toggling for it to take effect.
#   cc-gw     -> route CC through the pico gateway (observe/govern the traffic)
#   cc-direct -> restore direct-to-Anthropic (KILL SWITCH: use if pico/gateway is down)
#   cc-route  -> show current routing without changing it
# Each toggle prints the resulting settings.json .env block to prove the change.
CC_SETTINGS="$HOME/.claude/settings.json"
CC_GW_URL="http://100.72.47.4:17017/claude"

cc-gw ()
{
	[ -f "$CC_SETTINGS" ] || echo '{}' > "$CC_SETTINGS"
	local tmp; tmp=$(mktemp)
	jq --arg u "$CC_GW_URL" '.env = ((.env // {}) + {ANTHROPIC_BASE_URL: $u})' "$CC_SETTINGS" > "$tmp" && command mv "$tmp" "$CC_SETTINGS"
	echo "→ Claude Code routed through pico agentgateway ($CC_GW_URL). RESTART CC to apply."
	jq '.env' "$CC_SETTINGS"
}

cc-direct ()
{
	[ -f "$CC_SETTINGS" ] || { echo "no $CC_SETTINGS — already direct"; return; }
	local tmp; tmp=$(mktemp)
	jq 'del(.env.ANTHROPIC_BASE_URL)' "$CC_SETTINGS" > "$tmp" && command mv "$tmp" "$CC_SETTINGS"
	echo "→ Claude Code restored to direct-to-Anthropic (kill switch). RESTART CC to apply."
	jq '.env' "$CC_SETTINGS"
}

cc-route ()
{
	jq -r '.env.ANTHROPIC_BASE_URL // "direct (no ANTHROPIC_BASE_URL set)"' "$CC_SETTINGS" 2>/dev/null \
		| sed 's/^/Claude Code routing: /'
}

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
