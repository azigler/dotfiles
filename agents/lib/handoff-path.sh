#!/bin/bash
# handoff-path.sh — per-window scoping for the /offboard <-> /onboard bracket.
#
# Sourced by the /onboard, /offboard, /pulse skill bash snippets AND by the
# session-end.sh hook, so the path logic lives in ONE place.
#
# Why: the offboard/onboard bracket assumes ONE durable session per project.
# The pulse model breaks that — ~/explore runs >=2 long-lived sessions in
# different tmux windows (the explore-pulse window + the directed-elevate
# window). All three single-slot artifacts then collide: refs/session-handoff.md
# (last writer wins -> the other session re-onboards from the wrong doc),
# .offboard-pending, and .claude/last-offboard-session.
#
# Fix: a project that runs multiple durable sessions OPTS IN by carrying
# refs/.handoff-per-window. Then these helpers scope the three artifacts by a
# per-session KEY. Without the marker, every path is the legacy single-file
# form, so every other (single-session) project is completely untouched.
#
# The key is the tmux WINDOW NAME (glyph-stripped). It is the only identity
# stable across BOTH compaction AND /clear — the session id changes on /clear,
# which would break the pulse model's "re-onboard in the same window from the
# handoff" continuity.
#
# Resolution order (see _handoff_key):
#   1. $TMUX_PANE, TARGETED (`-t "$TMUX_PANE"`) — fast path when the pane env
#      var is present.
#   2. PROCESS-ANCESTRY fallback — Claude Code does NOT propagate $TMUX/$TMUX_PANE
#      into the Bash-tool shell, so even a legitimate FOREGROUND pane-bound
#      session sees an empty $TMUX_PANE (verified 2026-07-13, a fresh post-/clear
#      session in the explore window re-onboarded from elevate's note because of
#      exactly this). The window identity is not actually lost: the pane's shell
#      is a genuine ANCESTOR of this process, so we recover it by walking parent
#      PIDs and matching tmux pane_pids. Robust across /clear (new session, same
#      window) AND env loss.
# NEVER use a bare/untargeted `display-message` — it returns the CLIENT's
# currently-focused window (wherever Andrew happens to be looking), not THIS
# session's own window (verified 2026-06-30). No tmux, or a truly-detached
# session with no pane ancestor -> empty key -> legacy single file.

# Pane/window resolution — including the background-forked-session case where
# $TMUX_PANE is absent (Claude Code's `bg-pty-host --fork-session`) — lives in
# the shared lib tmux-pane-resolve.sh, sibling to this file. Source it robustly
# across bash AND zsh: in bash ${BASH_SOURCE[0]} is this file; in zsh (what
# Claude Code's Bash tool runs) BASH_SOURCE is empty, so we fall to $0, which a
# sourced zsh file sets to its own path.
_handoff_self="${BASH_SOURCE[0]:-$0}"
_handoff_dir="$(cd "$(dirname -- "$_handoff_self")" 2>/dev/null && pwd)"
[ -n "$_handoff_dir" ] && [ -f "$_handoff_dir/tmux-pane-resolve.sh" ] && . "$_handoff_dir/tmux-pane-resolve.sh"
# SEAT resolution (seat-resolve.sh, bead dotfiles-seat-resolve-lib-btti) is
# OPTIONAL here on purpose: if the lib or the roster is absent, every function
# below behaves exactly as it did before seats existed. A shared lib that
# started failing in projects with no roster would be a worse bug than the one
# the seat guard fixes.
[ -n "$_handoff_dir" ] && [ -f "$_handoff_dir/seat-resolve.sh" ] && . "$_handoff_dir/seat-resolve.sh"
unset _handoff_self _handoff_dir

# _handoff_key -> the glyph-stripped window name on stdout, or non-zero if it
# can't be resolved. Delegates to the shared resolver; if that lib somehow
# failed to load, degrades to the $TMUX_PANE-targeted path (the pre-2026-07-13
# legacy behavior — a bare/untargeted display-message would return the CLIENT's
# focused window, so we never do that).
_handoff_key() {
  # 0. EXPLICIT OVERRIDE — for a session with no tmux server to ask.
  #    A confined pulse tick (tools/tick-jail/tick-jailed.sh) runs under bwrap with
  #    no tmux binary and no socket, so every resolution path below fails. Without
  #    this seam _handoff_suffix silently returns "" and handoff_path yields the
  #    BARE refs/session-handoff.md — which, in a per-window project whose notes are
  #    all scoped (--dive, --desk, --digest, --dream, --elevate) and where no bare
  #    file exists, would CREATE one and become the fallback every future unresolved
  #    reader picks up, ahead of all five real notes. The 2026-07-27 dive tick spotted
  #    that and deliberately wrote no handoff at all; this is the fix that lets it
  #    write the right one instead (explore-nvi5 sibling gap).
  #    The launcher sets it from the real window name BEFORE entering the jail.
  if [ -n "${HANDOFF_WINDOW:-}" ]; then
    printf '%s' "$HANDOFF_WINDOW" | sed -E 's/^(🧠|✅|🔔|🌀|📬) ?//'
    return 0
  fi
  if command -v tmux_resolve_window >/dev/null 2>&1; then
    tmux_resolve_window
    return
  fi
  [ -n "${TMUX_PANE:-}" ] || return 1
  local tb w
  tb=$(command -v tmux 2>/dev/null); [ -x "$tb" ] || tb=/usr/bin/tmux
  [ -x "$tb" ] || return 1
  w=$("$tb" display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null \
        | sed -E 's/^(🧠|✅|🔔|🌀|📬) ?//')
  [ -n "$w" ] || return 1
  printf '%s' "$w"
}

# _handoff_suffix <dir> -> "--<window>" when <dir> opts in AND a window key
# resolves; else "" (legacy single file).
_handoff_suffix() {
  local dir="${1:-.}" k
  [ -f "$dir/refs/.handoff-per-window" ] || { printf ''; return; }
  k=$(_handoff_key) || { printf ''; return; }
  printf -- '--%s' "$k"
}

# Writers — the canonical path for THIS session in <dir> (default cwd).
handoff_path()          { local d="${1:-.}"; printf '%s/refs/session-handoff%s.md' "$d" "$(_handoff_suffix "$d")"; }
offboard_pending_path() { local d="${1:-.}"; printf '%s/.offboard-pending%s'        "$d" "$(_handoff_suffix "$d")"; }
last_offboard_path()    { local d="${1:-.}"; printf '%s/.claude/last-offboard-session%s' "$d" "$(_handoff_suffix "$d")"; }

# --- SEAT front matter: the reverse-rename guard (dotfiles-tzfr, spec R6) ----
#
# The bug this closes: this file's reader warned only when the scoped note was
# MISSING. The REVERSE rename — a window renamed ONTO a name that already has a
# note — resolved, found the file, and served ANOTHER SEAT'S handoff in silence.
# That is the di->pulse failure (bd-msi5) with the surviving half unpatched: the
# tooling said nothing either way, and a session onboarded from a stranger's
# note.
#
# The mechanism is the one agreed with seat-resolve.sh, not a parallel
# invention: a note CARRIES ITS OWNER in YAML front matter, and the reader
# compares that against the seat this window resolves to.
#
#     ---
#     seat: desk
#     session: zig-computer
#     window: desk
#     ---
#
# R6, as amended: an ABSENT seat: (every note written before the migration) is
# never an error — the note is served with a one-line migration notice, and the
# next /offboard write stamps it.

# _handoff_note_seat <file> -> the note's declared seat, or non-zero. Only a
# LEADING front-matter block counts; a `seat:` further down the note is prose.
_handoff_note_seat() {
  local f="${1:-}" s
  [ -n "$f" ] && [ -f "$f" ] || return 1
  IFS= read -r s < "$f" || return 1
  [ "$s" = "---" ] || return 1
  s=$(awk 'NR==1 {next}
           /^---[[:space:]]*$/ {exit}
           /^seat:[[:space:]]*[^[:space:]]/ {
             sub(/^seat:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }
          ' "$f")
  [ -n "$s" ] || return 1
  printf '%s' "$s"
}

# handoff_seat_frontmatter -> the front-matter block for THIS session, on
# stdout. Non-zero and SILENT when no seat resolves — a note must never be
# stamped with a guessed owner, which would turn the guard into a liar.
handoff_seat_frontmatter() {
  local out seat ses win
  command -v seat_resolve >/dev/null 2>&1 || return 1
  out=$(seat_resolve --quiet) || return 1
  seat=$(printf '%s\n' "$out" | awk -F= '$1=="seat"{print $2; exit}')
  ses=$(printf '%s\n' "$out"  | awk -F= '$1=="session"{print $2; exit}')
  win=$(printf '%s\n' "$out"  | awk -F= '$1=="window"{print $2; exit}')
  [ -n "$seat" ] || return 1
  printf -- '---\n'
  printf 'seat: %s\n' "$seat"
  [ -n "$ses" ] && printf 'session: %s\n' "$ses"
  [ -n "$win" ] && printf 'window: %s\n' "$win"
  printf -- '---\n'
}

# handoff_stamp_seat <file> — idempotently (re)write <file>'s front matter so it
# declares the seat that WROTE it. Called on the write side (/offboard, bead
# dotfiles-ap3m). Non-zero and NO WRITE when no seat resolves.
handoff_stamp_seat() {
  local f="${1:-}" fm tmp
  [ -n "$f" ] || return 2
  fm=$(handoff_seat_frontmatter) || return 1
  tmp="$f.seatstamp.$$"
  {
    printf '%s\n' "$fm"
    if [ -f "$f" ]; then
      awk 'NR==1 && $0=="---" { infm=1; next }
           infm && /^---[[:space:]]*$/ { infm=0; skipped=1; next }
           !infm { print }
          ' "$f"
    fi
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# _handoff_seat_guard <note-file> -> 0 = serve it, non-zero = DO NOT serve it
# (the caller prints nothing and returns 3). Five cases; the middle one is the
# bug fix:
#   resolved seat S, note says S        -> serve, silently
#   resolved seat S, note says T != S   -> LOUD, NOT SERVED       (the fix)
#   resolved seat S, note says nothing  -> serve + migration notice (R6)
#   no seat resolves, note says T       -> LOUD, NOT SERVED — an unregistered
#                                          window cannot be checked against T,
#                                          and serving a note that names an
#                                          owner we cannot verify is the exact
#                                          silent-serve this guard exists for
#   no seat resolves, note says nothing -> serve, silently (pre-seat behavior,
#                                          byte-identical to before this change)
_handoff_seat_guard() {
  local f="${1:-}" note_seat resolved roster
  command -v seat_resolve >/dev/null 2>&1 || return 0
  roster=$(seat_roster_path) || return 0
  note_seat=$(_handoff_note_seat "$f") || note_seat=""
  resolved=$(seat_self_name --quiet) || resolved=""

  if [ -n "$note_seat" ] && [ -n "$resolved" ] && [ "$note_seat" != "$resolved" ]; then
    {
      printf '🚫 handoff: this note belongs to ANOTHER SEAT — NOT served.\n'
      printf '    note: %s\n' "$f"
      printf '    the note declares seat: %s\n' "$note_seat"
      printf '    this window resolves to seat: %s\n' "$resolved"
      printf '    A window was renamed onto a name that already had a note (the reverse of bd-msi5).\n'
      printf "    Read %s's own note, or fix the roster's aliases: — do NOT onboard from this one.\n" "$resolved"
    } >&2
    return 1
  fi

  if [ -n "$note_seat" ] && [ -z "$resolved" ]; then
    {
      printf '🚫 handoff: this note declares seat "%s" but THIS WINDOW HAS NO SEAT — NOT served.\n' "$note_seat"
      printf '    note: %s\n' "$f"
      printf '    roster: %s\n' "$roster"
      printf '    An unregistered window cannot be checked against the note owner, so serving it\n'
      printf '    would be the silent guess this guard exists to refuse (R5/R6).\n'
      printf '    Register this window as a seat, or add it to seat "%s" aliases:.\n' "$note_seat"
    } >&2
    return 1
  fi

  if [ -z "$note_seat" ] && [ -n "$resolved" ]; then
    printf '⚠️  handoff: note %s carries no seat: front matter (pre-migration) — serving it as seat "%s". The next /offboard write stamps it.\n' \
      "$f" "$resolved" >&2
  fi
  return 0
}

# _handoff_seat_diagnosis <window> — one or two lines, on the CALLER'S stream
# (the missing-note block already redirects the whole group to stderr), saying
# whether this window is a registered seat. Silent when there is no seat lib
# and no roster, so nothing changes in a project that has neither.
_handoff_seat_diagnosis() {
  local win="${1:-}" seat roster
  command -v seat_resolve >/dev/null 2>&1 || return 0
  roster=$(seat_roster_path) || return 0
  if seat=$(seat_self_name --quiet) && [ -n "$seat" ]; then
    printf '    seat: this window is seat "%s" (%s) — the note is missing for the SEAT, not just the window.\n' \
      "$seat" "$roster"
    return 0
  fi
  printf '    seat: "%s" is NOT a registered seat (%s). An unregistered window has no seat and no\n' "$win" "$roster"
  printf '          scoped history; if it was renamed, add "%s" to the old seat aliases: — the\n' "$win"
  printf '          resolver refuses to guess (R5, dotfiles-seat-address-spec-uikg).\n'
}

# Reader — the note THIS session should read. /onboard reads THIS.
#
# Three cases, and the middle one is a bug fix (bd-msi5):
#   1. scoped note exists                  -> the scoped note.
#   2. per-window project, scoped note MISSING -> still the scoped path (which
#      does not exist), plus a LOUD stderr diagnostic. NOT the legacy file.
#   3. not opted in (or window unresolvable, so no suffix) -> the legacy file,
#      exactly as before.
#
# Why case 2 changed: the legacy fallback made a missing scoped note read as
# "this window has no history" and then silently served a DIFFERENT window's
# file. Measured 2026-08-03 — the work:di -> work:pulse rename (bd-j8di) moved
# session-handoff--di.md to --pulse.md while a session was still live in a window
# named `di`; /onboard fell through to refs/session-handoff.md, last written
# 2026-07-06, and onboarded a month stale. Zig caught it; nothing in the tooling
# did. In a per-window project the legacy file belongs to NO window, so serving
# it to a window that asked for its own note is always a guess.
#
# The contract: STDOUT stays a single path with no decoration (callers capture
# it — /onboard Step 1 does `HANDOFF=$(handoff_read_path .)` then `[ -f "$HANDOFF" ]
# && cat`), and the diagnostic goes to STDERR. Returning the nonexistent scoped
# path rather than empty means that caller degrades to the honest "no note for
# this window" — it prints the path it wanted, cats nothing, and the human sees
# which scoped notes DO exist. Returning empty would work too but tells the human
# less; returning the legacy path is the bug.
handoff_read_path() {
  local d="${1:-.}" p legacy win others
  p=$(handoff_path "$d")
  legacy="$d/refs/session-handoff.md"
  if [ -f "$p" ]; then
    # The seat guard applies to SCOPED notes only. A legacy single-file note
    # belongs to the PROJECT, not to a window — every seat that opens that repo
    # is entitled to read it, so comparing owners there would be noise, and
    # opted-out projects stay byte-identical to their pre-seat behavior.
    if [ "$p" != "$legacy" ]; then
      _handoff_seat_guard "$p" || return 3
    fi
    printf '%s' "$p"; return 0
  fi

  # Scoped iff handoff_path did NOT hand back the legacy name — i.e. the suffix
  # was non-empty. Compare paths rather than calling _handoff_key a second time:
  # one resolution per call, and no second copy of the filename format to drift.
  if [ "$p" != "$legacy" ]; then
    win=${p##*/session-handoff--}; win=${win%.md}
    # List the dir and FILTER — never `ls "$d"/refs/session-handoff--*.md`. An
    # unmatched glob is a hard error in zsh (`no matches found`, printed before
    # ls runs, and 2>/dev/null on ls cannot suppress it), and Claude Code's Bash
    # tool runs zsh. Caught by exactly that, 2026-08-04.
    others=$(ls -1 "$d/refs" 2>/dev/null | grep '^session-handoff--.*\.md$' | tr '\n' ' ')
    {
      printf '⚠️  handoff: NO note for this window (%s).\n' "$win"
      printf '    missing: %s\n' "$p"
      printf '    scoped notes that DO exist: %s\n' "${others:-(none)}"
      [ -f "$legacy" ] && printf '    %s exists but was NOT read — in a per-window project it belongs to no window (bd-msi5).\n' "$legacy"
      printf '    If a window was renamed, this window is carrying the OLD name. Read the right scoped note by hand, or rename the window.\n'
      # ...and say whether this window is a SEAT at all. An unregistered window
      # is the upstream cause of "no note for this window" often enough that
      # naming it here is the difference between a puzzle and an instruction.
      _handoff_seat_diagnosis "$win"
    } >&2
    printf '%s' "$p"
    return 0
  fi

  printf '%s/refs/session-handoff.md' "$d"
}
