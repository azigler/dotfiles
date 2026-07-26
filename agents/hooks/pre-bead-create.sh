#!/bin/bash
# PreToolUse (Bash): the ENTRY gate on bead creation — the counterpart to
# pre-bead-close.sh's exit gate.
#
# WHY THIS EXISTS (2026-07-26 beads-lifecycle audit, fleet-wide, ~1,900 beads).
# The fleet had a gate at the exit and nothing at the entry, and the backlog
# behaved exactly the way a system with free intake and a taxed outflow does:
# net open beads went +10/month in February to +353 in July, 515 open. The
# mechanism is not laziness — it is where the cost lands. 74% of `br create`
# calls carried no -d, so a bead is born owing a `## Acceptance Criteria`
# heading, and that debt is collected months later from whoever tries to CLOSE
# it, with the least context of anyone. 278 of 515 open beads (54%) currently
# fail `br lint` and cannot be closed without first being rewritten.
#
# This hook charges the specification cost to the author, at the moment it is
# cheapest — they have the context right now. It demands EXACTLY what
# `br lint` (and therefore the close gate) will demand for the bead's type, no
# more, via the shared bead_required_headings table. A bead created through
# this gate is closeable by construction.
#
# COVERAGE. `br create` and `br q` (quick capture, defaults to type=task), in
# any command shape — chains, loops, substitutions — matched off the command
# SKELETON so prose that merely mentions `br create` is never blocked.
# `br create -f/--file` is refused outright: verified against br 0.2.16, bulk
# markdown import uses `## <title>` as the ISSUE DELIMITER and drops `###`
# subsections from the body entirely, so a bulk-imported bead physically cannot
# carry the template and is born un-closable. It has never been used in this
# fleet's transcript history (0 real invocations), so refusing it costs
# nothing and shuts the obvious bypass.
#
# ESCAPE HATCH: append  # allow-thin-bead  to the command. Deliberate: this
# repo's own standing lesson is that a gate with no valve trains agents to
# route around it, and a valve that appears verbatim in the command is
# *greppable* — a future audit can measure how often it is used, which is
# exactly what could not be measured about the bypass this hook replaces.
#
# Fails OPEN (a broken gate must never block all Bash), and exits 0 whenever
# the shared lexer is unavailable — a missed thin bead is far cheaper than
# blocking every command that mentions the words.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# Escape hatch, read off the RAW command (the skeleton strips comments).
case "$COMMAND" in *"# allow-thin-bead"*) exit 0 ;; esac

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/hook-helpers.sh" 2>/dev/null
type command_skeleton >/dev/null 2>&1 || exit 0
type bead_required_headings >/dev/null 2>&1 || exit 0
SKEL=$(command_skeleton "$COMMAND" 2>/dev/null) || exit 0
[ -z "$SKEL" ] && exit 0

# Fast bail: no bead creation anywhere in the executable structure.
echo "$SKEL" | grep -qE '(^|[;&|[:space:]])br[[:space:]]+(create|q)([[:space:]]|$)' || exit 0

# Segment the SKELETON (not the raw command) on && || ; | and newlines. The
# skeleton has string-literal contents and heredoc bodies removed, so this
# cannot fragment a description body that happens to contain those characters
# — the same reason pre-bash-stderr-guard.sh segments the skeleton.
SEGMENTS=$(printf '%s\n' "$SKEL" | sed -E 's/&&/\n/g; s/\|\|/\n/g; s/;/\n/g; s/\|/\n/g')

VERB_RE='(^|[;&|[:space:]])br[[:space:]]+(create|q)([[:space:]]|$)'
BULK=0
MISSING_D=0
NEEDED=""

while IFS= read -r SEG; do
  echo "$SEG" | grep -qE "$VERB_RE" || continue

  # `--help` / `--dry-run` create nothing.
  echo "$SEG" | grep -qE '(^|[[:space:]])(-h|--help|--dry-run)([[:space:]]|=|$)' && continue

  if echo "$SEG" | grep -qE '(^|[[:space:]])(-f|--file)([[:space:]]|=|$)'; then
    BULK=1
    continue
  fi

  if ! echo "$SEG" | grep -qE '(^|[[:space:]])(-d|--description|--body)([[:space:]]|=|$)'; then
    MISSING_D=1
    continue
  fi

  # Type: unquoted values survive the skeleton. If the segment carries a
  # -t/--type whose value was QUOTED (and therefore blanked), the type is
  # unknown — require nothing rather than risk a false block on a type `br`
  # does not template at all. No -t at all means `br`'s default, task.
  BTYPE=$(echo "$SEG" | grep -oE '(^|[[:space:]])(-t|--type)[[:space:]=]+[A-Za-z][A-Za-z0-9_-]*' \
    | head -1 | sed -E 's/.*(-t|--type)[[:space:]=]+//')
  if [ -z "$BTYPE" ]; then
    if echo "$SEG" | grep -qE '(^|[[:space:]])(-t|--type)([[:space:]]|=|$)'; then
      continue   # quoted/opaque type — unknowable, so demand nothing
    fi
    BTYPE=task
  fi

  NEEDED="$NEEDED$(bead_required_headings "$BTYPE")
"
done <<< "$SEGMENTS"

# An explicitly EMPTY description is a missing one — and this check has to read
# the RAW command, because the skeleton blanks every quoted value, so `-d ""`
# and `-d "a real body"` are the same string there. (Checking it against the
# skeleton was the first version of this hook and it blocked every valid
# multi-line -d — caught before install.)
if printf '%s' "$COMMAND" \
   | grep -qE "(^|[[:space:]])(-d|--description|--body)[[:space:]=]*(\"\"|'')([[:space:]]|$)"; then
  MISSING_D=1
fi

# Do the section check against the RAW command: the description lives inside a
# string literal or heredoc, which is precisely what the skeleton removes.
# Matching is a case-insensitive phrase match because that is what `br lint`
# itself does (verified 0.2.16: `### Acceptance Criteria`, a trailing colon,
# lowercase, and a bare unhashed phrase all satisfy it). Matching stricter than
# `br` would block beads the close gate would happily accept.
MISSING_SECTIONS=""
while IFS= read -r H; do
  [ -z "$H" ] && continue
  case "$MISSING_SECTIONS" in *"$H"*) continue ;; esac
  printf '%s' "$COMMAND" | grep -qiF "$H" || MISSING_SECTIONS="$MISSING_SECTIONS$H
"
done <<< "$NEEDED"

[ "$BULK" -eq 0 ] && [ "$MISSING_D" -eq 0 ] && [ -z "$MISSING_SECTIONS" ] && exit 0

{
  echo "[bead-create gate] This creates a bead that cannot later be closed."
  echo ""

  if [ "$BULK" -eq 1 ]; then
    echo "  \`br create -f/--file\` (bulk markdown import) is refused."
    echo "  Verified against br 0.2.16: the bulk format uses '## <title>' as the"
    echo "  ISSUE DELIMITER and drops '###' subsections from the body, so a"
    echo "  bulk-imported bead physically cannot carry '## Acceptance Criteria'"
    echo "  and is born failing \`br lint\` — i.e. un-closable. Create the beads"
    echo "  one at a time with -d instead."
    echo ""
  fi

  if [ "$MISSING_D" -eq 1 ]; then
    echo "  Missing -d/--description. Every bead needs one at CREATE time — a"
    echo "  bead born empty hands its specification cost to whoever closes it"
    echo "  months from now, with none of the context you have right now."
    echo ""
  fi

  if [ -n "$MISSING_SECTIONS" ]; then
    echo "  The description is missing the section(s) \`br lint\` requires for"
    echo "  this issue type, which is what the close gate will check:"
    printf '%s' "$MISSING_SECTIONS" | sed 's/^/    ## /'
    echo ""
  fi

  cat <<'MSG'
  Shape that works:

    br create -t task -p 2 "scope: title" -d "$(cat <<'EOF'
    ## Context
    <why this exists>

    ## Acceptance Criteria
    - [ ] <concrete deliverable>
    EOF
    )"

  ⚠ THE LEADING-DASH TRAP: a -d value whose FIRST characters are "- " is
    parsed by clap as a flag —  error: unexpected argument '- ' found.
    Two forms that work: bind the value with '=' (  -d="- [ ] x"  ), or open
    the description with a heading (  ## Context  ) as above.

  Per type (verified br 0.2.16 — every other type templates nothing):
    task, feature -> ## Acceptance Criteria
    bug           -> ## Steps to Reproduce + ## Acceptance Criteria
    epic          -> ## Success Criteria

  For a genuine quick capture where this is wrong, append  # allow-thin-bead
  to the command. See /beads ("Mandatory: every bead has a description").
MSG
} >&2
exit 2
