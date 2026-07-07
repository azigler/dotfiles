#!/bin/bash
# PreToolUse (Bash): guard against blanket stderr suppression on commands whose
# errors are SIGNAL, not noise. A suppressed failure reads as an empty result
# ("no data") instead of the error it actually was.
#
# Blocks (exit 2) ONLY when a state-changing / output-bearing verb (git config/
# commit/push/…, curl, wget, db clients, migrations, systemctl, docker) is paired
# with 2>/dev/null | >/dev/null 2>&1 | &>/dev/null IN THE SAME command segment.
# Everything else (command -v, git rev-parse, tmux has-session, [ -f … ], etc.)
# stays quiet — those are legit exit-code-only probes.
#
# Escape hatch: append  # allow-suppress  to the command to intentionally suppress.
# Fails OPEN (a broken guard must never block all Bash).
#
# Origin: 2026-07-07 — a sandbox test's `git config --global … >/dev/null 2>&1`
# silently clobbered the machine git identity. This is the mechanical enforcement
# of ~/.claude/CLAUDE.md "Don't blanket-suppress stderr" (a rule the model kept
# skipping because the reflex fires at command-write time, deep in subagents).

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# escape hatch
case "$COMMAND" in *"# allow-suppress"*) exit 0 ;; esac

SUPPRESS_RE='2>[[:space:]]*/dev/null|&>[[:space:]]*/dev/null|>[[:space:]]*/dev/null[[:space:]]+2>&1|2>&1[[:space:]]*>[[:space:]]*/dev/null'

# fast bail: no stderr suppression anywhere
echo "$COMMAND" | grep -Eq "$SUPPRESS_RE" || exit 0

# state-changing / output-bearing verbs where a silent failure is genuinely harmful.
# Deliberately EXCLUDES read/probe git subcommands (rev-parse, show-ref, cat-file,
# diff, status, log) — those are the legit exit-code-only checks.
RISKY_RE='(^|[[:space:];&|(])(git[[:space:]]+(config|commit|push|clone|fetch|pull|merge|rebase|reset|remote|tag|branch[[:space:]]+-[dD])|curl|wget|psql|mysql|mysqldump|sqlite3|mongo|redis-cli|alembic|prisma|migrate|flyway|systemctl|service|docker[[:space:]]+(run|build|push|compose))([[:space:]]|$)'

# split into segments on && || ; | and newlines; flag a segment that has BOTH
# a risky verb AND suppression (avoids cross-segment false positives).
SEGMENTS=$(printf '%s\n' "$COMMAND" | sed -E 's/&&/\n/g; s/\|\|/\n/g; s/;/\n/g; s/\|/\n/g')
FLAGGED=""
while IFS= read -r seg; do
  [ -z "$seg" ] && continue
  if echo "$seg" | grep -Eq "$SUPPRESS_RE" && echo "$seg" | grep -Eq "$RISKY_RE"; then
    FLAGGED="$(echo "$seg" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    break
  fi
done <<< "$SEGMENTS"

[ -z "$FLAGGED" ] && exit 0

cat >&2 <<MSG
[stderr-guard] This command suppresses stderr on a state-changing / output-bearing command, which hides real failures — a silent error then reads as "no data" instead of the error it actually was:

  ${FLAGGED}

Do one of:
  - Drop the suppression and read the actual output + errors.
  - Filter ONLY the known-noise line, keeping the rest + the exit code:
       cmd 2> >(grep -vF 'KNOWN NOISE' >&2)
  - If suppression is genuinely intended (a pure existence/probe check where only
    the exit code matters), append  # allow-suppress  to the command.

(Global rule: ~/.claude/CLAUDE.md "Don't blanket-suppress stderr". A sandbox test
doing exactly this clobbered the machine git identity on 2026-07-07.)
MSG
exit 2
