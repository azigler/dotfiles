#!/bin/bash
# Shared helpers for the PreToolUse/PostToolUse Bash hooks.
# Source via:  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/hook-helpers.sh"

# command_skeleton <command>
#   Blank the CONTENTS of quoted strings so command-VERB matching sees the
#   command STRUCTURE, not argument text. Without this, hooks that grep the
#   raw command mis-match verbs that appear inside quoted arguments — e.g.
#   `git commit -m "... && git commit ..."` or `... && br close X` inside a
#   commit message, or git/br verbs inside an `echo '{json...}'` test payload.
#   Those false-matches have repeatedly blocked legitimate commands.
#
#   Use the skeleton for STRUCTURE/verb detection (is this a `git push`? a
#   `br close <id>`? does it commit a pulse-ledger?). Keep the RAW command
#   when you intentionally inspect argument CONTENT (e.g. the `Bead:` trailer
#   or a gitmoji, which live inside the -m message).
#
#   Not a full shell parser: it blanks single- and double-quoted spans, which
#   defeats the substring false-matches we actually hit. Escaped quotes and
#   quote-nesting are not handled (rare in agent-issued commands); a missed
#   strip only risks the pre-existing false-match, never a new wrong block.
command_skeleton() {
  printf '%s' "$1" | sed -E "s/'[^']*'/''/g; s/\"[^\"]*\"/\"\"/g"
}
