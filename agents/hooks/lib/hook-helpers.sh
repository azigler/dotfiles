#!/bin/bash
# Shared helpers for the PreToolUse/PostToolUse Bash hooks.
# Source via:  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/hook-helpers.sh"

# command_skeleton <command>
#   Reduce a shell command to its EXECUTABLE STRUCTURE so hooks can match on
#   the commands a call would actually run, and never on text that merely
#   *mentions* a command. Everything that is data rather than code — string
#   literal contents, comments, heredoc bodies — is removed; everything that
#   is code — verbs, flags, operators, command substitutions — is kept.
#
#   Use the skeleton for STRUCTURE/verb detection (is this a `git push`? a
#   `br close <id>`? does it commit a pulse-ledger?). Keep the RAW command
#   when you intentionally inspect argument CONTENT (e.g. the `Bead:` trailer
#   or a gitmoji, which live inside the -m message).
#
#   WHY A LEXER AND NOT REGEXES (dotfiles-vo3t / dotfiles-aj83). This used to
#   be two sed substitutions that paired quote characters. That is not shell
#   lexing, and it failed in three ways that each produced a FALSE BLOCK on a
#   legitimate command:
#     * comments were read as commands, so `git add <files>   # NEVER git add
#       -A` — the line /commit itself documents — was refused BY ITS OWN
#       WARNING;
#     * heredoc bodies were read as commands, so writing prose about a rule
#       tripped the rule;
#     * `\"` inside a double-quoted string mis-paired the blanking span, so an
#       odd number of quotes left later text exposed and a `br close` inside a
#       commit message was seen as a real `br close`.
#   Three separate agents worked AROUND this hook rather than trusting it. A
#   gate that trains its users to route around it has stopped being a gate, so
#   the approach — not the instances — is what got replaced.
#
#   WHAT IT MODELS (a single left-to-right pass with a context stack):
#     'single quotes'   contents dropped, delimiters kept       -> ''
#     "double quotes"   contents dropped, but $( ) / ` ` / ${ } inside are
#                       CODE and are kept and descended into
#     \x                backslash escapes, incl. \" inside double quotes
#     # comment         only when it starts a word (unquoted, after a blank or
#                       an operator) — `curl x/#frag` is not a comment
#     <<EOF / <<-'EOF'  body dropped up to the terminator; <<< is a here-string
#                       and is NOT a heredoc
#     $( ) and ` `      descended into, and their boundaries are padded with a
#                       space so a verb at the head of a substitution has the
#                       same word boundary as one after `&&` — `$(git add -A)`
#                       must stay blockable
#     $(( )) and ${ }   copied verbatim (arithmetic / parameter expansion are
#                       not command contexts; copying can only over-report)
#
#   UNBALANCED QUOTES are treated as quoted-to-end-of-input, which blanks the
#   remainder. That cannot hide a real command from the gate: bash would
#   refuse to parse the command anyway, so nothing runs. (This is the
#   deliberate resolution of dotfiles-aj83's "fail loud?" question — a hook
#   that fails loud on a string the shell will reject is just a second, less
#   informative error.)
#
#   KNOWN LIMITS, both deliberate:
#     * a QUOTED PATHSPEC is invisible ( `git commit "refs/pulse-ledger.jsonl"
#       -m ...` blanks to `""` ), because preserving argument text is precisely
#       what caused the false blocks above. Consumers that need argument
#       CONTENT must read $COMMAND, not the skeleton. (dotfiles-aj83's second
#       instance; the pulse-ledger gate's primary staged-file discovery path is
#       unaffected.)
#     * a heredoc body PIPED INTO A SHELL ( `bash <<EOF … EOF` ) is code, and
#       dropping the body hides it. That is accepted: this is an accident gate,
#       not a sandbox — anyone writing that is already past `base64 -d | bash`
#       — and the body was only ever "visible" as a side effect of not lexing.
#       Zero false blocks on ordinary commands is worth more than a guard
#       against a bypass nobody reaches by accident.
#
#   Fail-safe: if awk is missing or errors, this prints nothing and callers
#   fall back to the raw command (the old over-matching behavior) — a miss
#   never turns into a missed block.
# bead_required_headings <issue-type>
#   Echo, one per line, the template sections `br lint` demands in a bead's
#   DESCRIPTION BODY for that issue type. Empty output = `br` templates nothing
#   for the type, so no heading is required.
#
#   This is the ONE place the fleet records what `br lint` actually wants, so
#   the entry gate (pre-bead-create.sh) and the exit gate (pre-bead-close.sh)
#   cannot drift apart. A bead that satisfies this on create is closeable by
#   construction — which is the whole point of gating creation (the exit-only
#   gate is what let 278 of 515 open beads accumulate un-closable, per the
#   2026-07-26 beads-lifecycle audit).
#
#   VERIFIED against br 0.2.16 by creating one bead of every type with an empty
#   body in a scratch store and reading `br lint --status all`:
#     task, feature  -> ## Acceptance Criteria
#     bug            -> ## Steps to Reproduce + ## Acceptance Criteria
#     epic           -> ## Success Criteria
#     spec, decision, study, note, test, impl, chore, and every other type
#                    -> nothing (br applies no template)
#   Re-run that probe before trusting this on a newer br.
bead_required_headings() {
  case "${1:-task}" in
    task|feature) printf '%s\n' 'Acceptance Criteria' ;;
    bug)          printf '%s\n' 'Steps to Reproduce' 'Acceptance Criteria' ;;
    epic)         printf '%s\n' 'Success Criteria' ;;
    *)            : ;;
  esac
}

command_skeleton() {
  printf '%s' "$1" | LC_ALL=C awk '
  { buf = buf $0 "\n" }
  END {
    q  = "\047"        # single quote  (kept out of the shell-quoted program)
    dq = "\042"        # double quote
    n  = length(buf)
    out = ""
    depth = 0          # context stack: q / dq / "(" cmdsub / "`" backtick sub
    hn = 0             # queued heredocs awaiting their body
    prev = ""          # previous INPUT char seen in a command context
    i = 1

    while (i <= n) {
      c = substr(buf, i, 1)
      top = (depth > 0) ? stack[depth] : ""

      # ---- inside single quotes: everything is literal --------------------
      if (top == q) {
        if (c == q) { out = out q; depth--; prev = q }
        i++
        continue
      }

      # ---- inside double quotes: literal, EXCEPT expansions ---------------
      if (top == dq) {
        if (c == "\\") {
          nx = substr(buf, i + 1, 1)
          if (nx == "$" || nx == dq || nx == "\\" || nx == "`" || nx == "\n") { i += 2; continue }
          i++
          continue
        }
        if (c == dq) { out = out dq; depth--; prev = dq; i++; continue }
        if (c == "`") { depth++; stack[depth] = "`"; out = out "` "; prev = "("; i++; continue }
        if (c == "$" && substr(buf, i + 1, 1) == "(" && substr(buf, i + 2, 1) == "(") { i = copy_arith(i); prev = ")"; continue }
        if (c == "$" && substr(buf, i + 1, 1) == "(") { depth++; stack[depth] = "("; out = out "$( "; prev = "("; i += 2; continue }
        if (c == "$" && substr(buf, i + 1, 1) == "{") { i = copy_braced(i); prev = "}"; continue }
        i++
        continue
      }

      # ---- command context (top level, $( ), or ` `) ----------------------
      if (c == "\\") { out = out substr(buf, i, 2); prev = "\\"; i += 2; continue }
      if (c == q)  { depth++; stack[depth] = q;  out = out q;  prev = q;  i++; continue }
      if (c == dq) { depth++; stack[depth] = dq; out = out dq; prev = dq; i++; continue }
      if (c == "`") {
        if (top == "`") { depth--; out = out " `" } else { depth++; stack[depth] = "`"; out = out "` " }
        prev = ")"
        i++
        continue
      }
      if (c == ")" && top == "(") { depth--; out = out " )"; prev = ")"; i++; continue }
      if (c == "$" && substr(buf, i + 1, 1) == "(" && substr(buf, i + 2, 1) == "(") { i = copy_arith(i); prev = ")"; continue }
      if (c == "$" && substr(buf, i + 1, 1) == "(") { depth++; stack[depth] = "("; out = out "$( "; prev = "("; i += 2; continue }
      if (c == "$" && substr(buf, i + 1, 1) == "{") { i = copy_braced(i); prev = "}"; continue }

      # a # only opens a comment at the START OF A WORD
      if (c == "#" && word_start(prev)) {
        while (i <= n && substr(buf, i, 1) != "\n") i++
        continue
      }

      # <<< is a here-string (its operand is an ordinary, quotable word), so it
      # must be consumed WHOLE — otherwise the trailing << reads as a heredoc
      # and swallows the rest of the command as body.
      if (c == "<" && substr(buf, i + 1, 1) == "<" && substr(buf, i + 2, 1) == "<") { out = out "<<<"; prev = "<"; i += 3; continue }
      # <<WORD / <<-WORD queue a heredoc
      if (c == "<" && substr(buf, i + 1, 1) == "<") { i = queue_heredoc(i); prev = "H"; continue }

      if (c == "\n") {
        out = out "\n"
        i++
        if (hn > 0) i = eat_heredoc_bodies(i)
        prev = "\n"
        continue
      }

      out = out c
      prev = c
      i++
    }
    printf "%s", out
  }

  # A word boundary in an unquoted command context.
  function word_start(p) {
    return (p == "" || p == " " || p == "\t" || p == "\n" || p == ";" || p == "&" || p == "|" || p == "(" || p == ")" || p == "<" || p == ">")
  }

  # $(( ... )) — arithmetic, not a command context. Copy through verbatim.
  function copy_arith(k,   d, ch) {
    out = out "$(("
    k += 3
    d = 2
    while (k <= n && d > 0) {
      ch = substr(buf, k, 1)
      if (ch == "(") d++
      else if (ch == ")") d--
      out = out ch
      k++
    }
    return k
  }

  # ${ ... } — parameter expansion, not a command context. Copy verbatim.
  function copy_braced(k,   d, ch) {
    out = out "${"
    k += 2
    d = 1
    while (k <= n && d > 0) {
      ch = substr(buf, k, 1)
      if (ch == "{") d++
      else if (ch == "}") d--
      out = out ch
      k++
    }
    return k
  }

  # Record a pending heredoc and emit its operator + bare delimiter.
  function queue_heredoc(k,   strip, dl, ch) {
    k += 2
    strip = 0
    if (substr(buf, k, 1) == "-") { strip = 1; k++ }
    while (k <= n && (substr(buf, k, 1) == " " || substr(buf, k, 1) == "\t")) k++
    dl = ""
    while (k <= n) {
      ch = substr(buf, k, 1)
      if (ch == q)  { k++; while (k <= n && substr(buf, k, 1) != q)  { dl = dl substr(buf, k, 1); k++ } ; k++; continue }
      if (ch == dq) { k++; while (k <= n && substr(buf, k, 1) != dq) { dl = dl substr(buf, k, 1); k++ } ; k++; continue }
      if (ch == "\\") { k++; dl = dl substr(buf, k, 1); k++; continue }
      if (ch == " " || ch == "\t" || ch == "\n" || ch == ";" || ch == "&" || ch == "|" || ch == "<" || ch == ">" || ch == "(" || ch == ")") break
      dl = dl ch
      k++
    }
    out = out "<<" dl
    if (dl != "") { hn++; hd[hn] = dl; hs[hn] = strip }
    return k
  }

  # Skip every queued heredoc BODY (data, never code); keep the terminator.
  function eat_heredoc_bodies(k,   e, line, t, j) {
    while (hn > 0) {
      while (k <= n) {
        e = index(substr(buf, k), "\n")
        if (e == 0) { line = substr(buf, k); k = n + 1 } else { line = substr(buf, k, e - 1); k += e }
        t = line
        if (hs[1]) { while (substr(t, 1, 1) == "\t") t = substr(t, 2) }
        if (t == hd[1]) { out = out t "\n"; break }
      }
      for (j = 1; j < hn; j++) { hd[j] = hd[j + 1]; hs[j] = hs[j + 1] }
      hn--
    }
    return k
  }
  '
}
