#!/bin/bash
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name')
DIR=$(echo "$input" | jq -r '.workspace.current_dir')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')

# Persist the official context % per session so hooks can read it —
# hook payloads don't carry context_window; only the statusline gets
# it. stop-context-guard.sh reads this file on Stop (dotfiles-lb6,
# pulse wave 4). /tmp is fine: live sessions re-render constantly.
SESSION_ID=$(echo "$input" | jq -r '.session_id // empty')
if [ -n "$SESSION_ID" ]; then
    PCT_DIR="${CONTEXT_GUARD_STATE_DIR:-/tmp/claude-context-pct}"
    mkdir -p "$PCT_DIR" 2>/dev/null
    printf '%s\n' "$PCT" > "$PCT_DIR/$SESSION_ID" 2>/dev/null
fi

# Reader #2 for the tmux lexicon SSoT (written by agents/hooks/tmux-status.sh
# to /tmp/claude-lexicon/<session_id>): surface the working/ready/needs-you
# glyph here too. Degrade silently to nothing when the file is absent (fresh
# session, non-tmux, or before the first hook event) — never error.
LEXICON=""
if [ -n "$SESSION_ID" ]; then
    LEX_DIR="${CLAUDE_LEXICON_STATE_DIR:-/tmp/claude-lexicon}"
    LEX_FILE="$LEX_DIR/$SESSION_ID"
    if [ -f "$LEX_FILE" ]; then
        LEX_TOKEN=$(cat "$LEX_FILE" 2>/dev/null)
        LEX_LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")/../agents/hooks/lib/lexicon-map.sh"
        if [ -n "$LEX_TOKEN" ] && [ -f "$LEX_LIB" ]; then
            # shellcheck source=../agents/hooks/lib/lexicon-map.sh
            . "$LEX_LIB"
            LEXICON=$(lexicon_glyph "$LEX_TOKEN")
        fi
    fi
fi

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'

# Pick bar color based on context usage
if [ "$PCT" -ge 90 ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

FILLED=$((PCT / 10)); EMPTY=$((10 - FILLED))
BAR="[$(printf "%${FILLED}s" | tr ' ' '#')$(printf "%${EMPTY}s" | tr ' ' '-')]"

MINS=$((DURATION_MS / 60000)); SECS=$(((DURATION_MS % 60000) / 1000))

# Git info
GIT_INFO=""
if git rev-parse --git-dir > /dev/null 2>&1; then
    BRANCH=$(git branch --show-current 2>/dev/null)
    STAGED=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
    MODIFIED=$(git diff --numstat 2>/dev/null | wc -l | tr -d ' ')

    GIT_STATUS=""
    [ "$STAGED" -gt 0 ] && GIT_STATUS="${GREEN}+${STAGED}${RESET}"
    [ "$MODIFIED" -gt 0 ] && GIT_STATUS="${GIT_STATUS}${YELLOW}~${MODIFIED}${RESET}"

    GIT_INFO=" | 📮 $BRANCH $GIT_STATUS"
fi

# Repo link (plain URL, auto-clickable in most terminals)
REPO_LINK=""
REMOTE=$(git remote get-url origin 2>/dev/null | sed 's/git@github.com:/https:\/\/github.com\//' | sed 's/\.git$//')
if [ -n "$REMOTE" ]; then
    REPO_LINK=" | 🔗 ${REMOTE}"
fi

COST_FMT=$(printf '$%.2f' "$COST")

# Line 1: Lexicon state, model, directory, git branch, repo link
printf '%b' "${LEXICON}${CYAN}[$MODEL]${RESET} 📁 ${DIR##*/}${GIT_INFO}${REPO_LINK}\n"

# Line 2: Context bar, cost, duration
printf '%b' "${BAR_COLOR}${BAR}${RESET} ${PCT}% | ${YELLOW}${COST_FMT}${RESET} | 🕰️  ${MINS}m ${SECS}s\n"
