function __setprompt
{
	# Define colors
	local LIGHTGRAY="\033[0;37m"
	local WHITE="\033[1;37m"
	local BLACK="\033[0;30m"
	local DARKGRAY="\033[1;30m"
	local RED="\033[0;31m"
	local LIGHTRED="\033[1;31m"
	local GREEN="\033[0;32m"
	local LIGHTGREEN="\033[1;32m"
	local BROWN="\033[0;33m"
	local YELLOW="\033[1;33m"
	local BLUE="\033[0;34m"
	local LIGHTBLUE="\033[1;34m"
	local MAGENTA="\033[0;35m"
	local LIGHTMAGENTA="\033[1;35m"
	local CYAN="\033[0;36m"
	local LIGHTCYAN="\033[1;36m"
	local NOCOLOR="\033[0m"

	PS1=""
	
	# Date
	PS1+="\[${DARKGRAY}\](\[${CYAN}\]$(da)${DARKGRAY})\[\]-("

	# CPU
	if [[ "$OSTYPE" == "linux-gnu"* ]]; then
		PS1+="\[${MAGENTA}\]$(cpu)${RED}%${MAGENTA} cpu\[${DARKGRAY}\]:"
	fi
	
	# Jobs
	PS1+="\[${MAGENTA}\]\j jobs"

  # Connections
	if [[ "$OSTYPE" == "linux-gnu"* ]]; then
		PS1+="\[${DARKGRAY}\]:\[${MAGENTA}\]$(awk 'END {print NR}' /proc/net/tcp) conns"
	fi

	PS1+="\[${DARKGRAY}\])-"

	# User and machine
	local SSH_IP=`echo $SSH_CLIENT | awk '{ print $1 }'`
	local SSH2_IP=`echo $SSH2_CLIENT | awk '{ print $1 }'`
	if [ $SSH2_IP ] || [ $SSH_IP ] ; then
		PS1+="(\[${RED}\]\u${MAGENTA}@${RED}\h"
	else
		PS1+="(\[${RED}\]\u"
	fi

	# Number of files in current directory
	PS1+="\[${DARKGRAY}\])-(\[${LIGHTGREEN}\]\$(/bin/ls -A -1 | /usr/bin/wc -l) ${GREEN}files\[${DARKGRAY}\]:"

	# Total size of files in current directory
	PS1+="\[${LIGHTGREEN}\]$(ls -lah | grep -m 1 total | sed 's/total //') ${GREEN}bytes\[${DARKGRAY}\])"

	PS1+="\n"

	# Current directory
	PS1+="\[${BROWN}\]\w "

	PS1+="\[${GREEN}\]>\[${NOCOLOR}\] "

	# PS2 is used to continue a command using the \ character
	PS2="\[${DARKGRAY}\]>\[${NOCOLOR}\] "

	# PS3 is used to enter a number choice in a script
	PS3="Please enter a number from above list: "

	# PS4 is used for tracing a script in debug mode
	PS4="\[${DARKGRAY}\]+\[${NOCOLOR}\] "
}

export PROMPT_COMMAND="__setprompt;$PROMPT_COMMAND"
export PROMPT_COMMAND="history -n;history -w;history -c;history -r;$PROMPT_COMMAND"
