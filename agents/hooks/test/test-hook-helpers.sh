#!/bin/bash
# Test for lib/hook-helpers.sh — the `command_skeleton` shell lexer.
#
# Hook test convention (see test-worktree-guard.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line
#
# command_skeleton is the SHARED helper every structure-matching Bash hook
# runs the command through, so a defect here is a fleet-wide false block (or,
# worse, a fleet-wide missed block). It used to be two sed substitutions that
# paired quote characters; dotfiles-vo3t and dotfiles-aj83 are two symptoms of
# that not being shell lexing. These cases pin the lexer's contract:
#
#   DATA is removed   — string-literal contents, comments, heredoc bodies
#   CODE is preserved — verbs, flags, operators, command substitutions
#
# Both halves matter: over-stripping hides a real violation from the gate,
# under-stripping blocks a legitimate command and teaches agents to route
# around the hook.

set -u

# shellcheck source=../lib/hook-helpers.sh
source "$(cd "$(dirname "$0")/.." && pwd)/lib/hook-helpers.sh"

PASS=0
FAIL=0
FAILED_NAMES=()

# skel <name> <input> <expected-exact-output>
skel() {
  local name=$1 in=$2 want=$3 got
  got=$(command_skeleton "$in")
  if [ "$got" != "$want" ]; then
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name"$'\n'"      want: $(printf '%q' "$want")"$'\n'"      got:  $(printf '%q' "$got")")
    return
  fi
  PASS=$((PASS + 1))
}

# has <name> <input> <substring that MUST survive into the skeleton>
has() {
  local name=$1 in=$2 want=$3 got
  got=$(command_skeleton "$in")
  case "$got" in
    *"$want"*) PASS=$((PASS + 1)) ;;
    *)
      FAIL=$((FAIL + 1))
      FAILED_NAMES+=("$name (missing $(printf '%q' "$want") in $(printf '%q' "$got"))")
      ;;
  esac
}

# hasnt <name> <input> <substring that must NOT survive>
hasnt() {
  local name=$1 in=$2 nope=$3 got
  got=$(command_skeleton "$in")
  case "$got" in
    *"$nope"*)
      FAIL=$((FAIL + 1))
      FAILED_NAMES+=("$name (leaked $(printf '%q' "$nope") in $(printf '%q' "$got"))")
      ;;
    *) PASS=$((PASS + 1)) ;;
  esac
}

# --- quoting: contents are data, delimiters are structure ------------------

skel "single-quoted contents blanked" \
  "git commit -m 'git add -A is forbidden'" \
  "git commit -m ''"

skel "double-quoted contents blanked" \
  'git commit -m "git add -A is forbidden"' \
  'git commit -m ""'

# dotfiles-aj83: `\"` inside a double-quoted string used to mis-pair the
# blanking span, exposing everything after it. The agent's workaround was to
# write commit messages containing no quote characters at all.
hasnt "aj83: escaped quotes do not expose later text" \
  'git commit -m "he said \"do it\" then br close x-1"' \
  "br close"

hasnt "aj83: three quotes in one argument do not expose later text" \
  'git commit -m "the 5\" rule; br close x-1 stays inert"' \
  "br close"

# An UNBALANCED quote runs to end of input, exactly as bash reads it. Nothing
# is hidden that could actually run: bash refuses to parse the command at all.
skel "unbalanced quote blanks the remainder" \
  'git commit -m "unterminated br close x-1' \
  'git commit -m "'

skel "single quotes inside double quotes are literal" \
  "echo \"it's fine\" && git push" \
  'echo "" && git push'

skel "double quotes inside single quotes are literal" \
  "echo 'say \"hi\"' && git push" \
  "echo '' && git push"

# --- comments: dotfiles-vo3t ----------------------------------------------

# THE headline case: /commit SKILL.md:71 documents this line, and the hook
# used to refuse it because the WARNING contains the flag.
skel "vo3t: the documented /commit line survives, its warning does not" \
  'git add <specific-files>                       # NEVER git add -A' \
  'git add <specific-files>                       '

skel "comment on its own line is dropped" \
  '# never git add -A
git status' \
  '
git status'

# A `#` only opens a comment at the START OF A WORD — `x/#frag` is not one.
has "hash mid-word is not a comment" \
  'curl https://example.com/p#frag && git push' \
  'git push'

hasnt "hash inside a double-quoted string is not a comment" \
  'echo "# git add -A" && git status' \
  "git add"

hasnt "hash inside a single-quoted string is not a comment" \
  "echo '# git add -A' && git status" \
  "git add"

has "a real comment does not swallow the NEXT line" \
  'git status   # careful here
git push' \
  'git push'

# --- heredocs: body is data, not code -------------------------------------

hasnt "heredoc body is not scanned as commands" \
  "cat > notes.md <<'EOF'
Never run git add -A in this repo.
EOF" \
  "git add"

hasnt "unquoted-delimiter heredoc body is not scanned either" \
  "cat > notes.md <<EOF
Never run git add -A in this repo.
EOF" \
  "git add"

hasnt "<<- heredoc strips leading tabs when matching the terminator" \
  "cat <<-EOF
	git add -A
	EOF" \
  "git add"

has "code AFTER the heredoc terminator is still code" \
  "cat > x.md <<'EOF'
body
EOF
git push" \
  "git push"

has "redirection on the heredoc's own line is still code" \
  "cat <<EOF > out.txt
body
EOF" \
  "> out.txt"

hasnt "two heredocs on one line consume two bodies" \
  "cat <<A <<B
git add -A
A
git add --all
B" \
  "git add"

# `<<<` is a here-STRING: its operand is an ordinary quotable word. Reading
# the trailing `<<` as a heredoc would swallow the rest of the command.
skel "here-string is not a heredoc" \
  'grep x <<< "git add -A"' \
  'grep x <<< ""'

# --- command substitution: still code, and still blockable ----------------

# The old skeleton left `$(` glued to the verb, so no hook's `(^|[[:space:]...])`
# boundary ever matched — `$(git add -A)` was silently ALLOWED. Padding the
# substitution boundary is what makes that position blockable.
has "cmdsub interior gets a word boundary" \
  'echo $(git add -A)' \
  ' git add -A '

has "backtick substitution interior gets a word boundary" \
  'echo `git add -A`' \
  ' git add -A '

has "cmdsub inside a double-quoted string is still code" \
  'echo "prefix $(git add -A) suffix"' \
  ' git add -A '

has "nested cmdsub survives" \
  'echo $(echo $(git add --all))' \
  ' git add --all '

# Arithmetic and parameter expansion are NOT command contexts; copying them
# through verbatim can only over-report, never hide.
skel "arithmetic expansion is copied verbatim" \
  'echo $((1<<3)) && git push' \
  'echo $((1<<3)) && git push'

skel "parameter expansion is copied verbatim" \
  'git add ${FILES}' \
  'git add ${FILES}'

# --- structure that must survive untouched --------------------------------

skel "operators and flags survive" \
  'a && b ; c | d || e' \
  'a && b ; c | d || e'

skel "empty input yields empty output" '' ''

has "backslash-escaped quote outside quotes survives" \
  'echo \" && git push' \
  'git push'

# --- Summary ---

TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi

echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED_NAMES[@]}"; do
  echo "  - $n"
done
exit 1
