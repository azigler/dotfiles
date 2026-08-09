#!/usr/bin/env bash
# Test suite for agents/bin/hall — THE HALL, v0 (bead dotfiles-sb6s).
#
# Convention: executable bash, non-zero exit = failure, PASS/FAIL summary on the
# last line (see agents/lib/test-seat-resolve.sh, test-validate-seats.sh).
#
# ⚠️ TMUX HYGIENE — READ BEFORE ADDING A CASE. Every tmux invocation here runs
#     env -u TMUX -u TMUX_TMPDIR tmux -S "$SOCKDIR/<name>" …
# through the tm() wrapper: NEVER a bare `tmux`, and NEVER `kill-server` without
# an explicit -S. This suite runs inside a live tmux session (the fleet's own),
# an inherited $TMUX silently retargets a bare tmux at THAT server, and a
# kill-server there takes down every window on the machine — a sibling agent did
# exactly that on 2026-08-08. The servers this suite starts live in their own
# $SOCKDIR and are killed by socket path on EXIT, then the socket files are
# rm -f'd (a killed server does not reliably unlink its own socket —
# dotfiles-2v8h).
#
# What is covered, and why each case exists:
#   court        every roster seat renders; live glyph from tmux; 💤 with no
#                window; 🚧 for a live window that matches no seat/alias
#   glyphs       the REAL court output goes through validate-seats.py's own
#                sigil rule — the roster's mechanical enforcement, applied to
#                the renderer (Zig's 2026-08-09 glyph pin, which also fixes 📬)
#   visit        existing window (glyph-prefixed name still matches) -> select,
#                no second window; absent -> materialize in the ROSTER's
#                session with the roster's home as cwd and the canonical name
#   home         the front desk: `hall home` is `hall seneschal`
#   refusals     unknown seat -> exit 2 with near matches
#   structure    no send-keys, no kill-*: the hall navigates, it never types
#                and never destroys
#   tmux.conf    the committed HALL block is EXECUTED as committed (this repo's
#                rule 2): the popup binding survives tmux-pain-control's own
#                `prefix H`, the attach hook fires for the host-named session
#                and NOT for any other one

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && cd .. && pwd)"
HALL="$HERE/hall"
VALIDATOR="$ROOT/agents/lib/validate-seats.py"

PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED+=("$1"); }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1 (want [$2] got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok ;; *) bad "$1 (missing [$2] in: $3)" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1 (unexpected [$2] in: $3)" ;; *) ok ;; esac; }

TMUX_BIN=$(command -v tmux 2>/dev/null); [ -x "${TMUX_BIN:-}" ] || TMUX_BIN=/usr/bin/tmux
# The ONE place tmux is invoked. Socket-explicit, $TMUX scrubbed, and -f
# /dev/null.
#
# ⚠️ -f /dev/null IS LOAD-BEARING, not tidiness. A tmux server started on a
# private socket still reads ~/.tmux.conf, and this machine's conf enables
# tmux-continuum with @continuum-restore on — so a fixture server RESTORES the
# live session set into itself, asynchronously, a second or two after it starts.
# Measured while writing this suite: a `zig-computer` session with a restored
# window appeared inside the fixture and stole a materialization, and because
# the restore races the test it failed intermittently. It would also load the
# HALL block below and fire the attach hook inside every fixture. The fixture
# server must be a blank server.
tm() { env -u TMUX -u TMUX_TMPDIR "$TMUX_BIN" -f /dev/null -S "$@"; }

BASE=$(mktemp -d)
SOCKDIR="$BASE/sockets"; mkdir -p "$SOCKDIR"
SOCK="$SOCKDIR/hall-main"
SOCK2="$SOCKDIR/hall-conf"
ERR="$BASE/stderr"
OUTF="$BASE/stdout"

cleanup() {
  local s
  for s in "$SOCKDIR"/*; do
    [ -S "$s" ] || continue
    tm "$s" kill-server >/dev/null 2>&1 || true   # allow-suppress: teardown probe
    rm -f "$s"
  done
  rm -rf "$BASE"
}
trap cleanup EXIT

# --- the fixture roster -----------------------------------------------------
# Shaped like the real one: the seneschal (for `hall home`), an aliased seat
# with a session-qualified binding (alpha), a schedule-less seat whose home is
# `~` so home-expansion is actually exercised (beta), and a work-tap seat
# (gamma) so the tap column has something to differ on.
mkdir -p "$BASE/deskhome" "$BASE/alphahome" "$BASE/gammahome"
ROSTER="$BASE/seats.yml"
cat > "$ROSTER" <<'EOF'
schema: 1
hosts: [zig-computer]
charter: null
taps:
  personal:
    type: claude
    config_dir: ~/.claude
    failover: [work]
  work:
    type: claude
    config_dir: ~/.claude-work
    failover: []
seats:
  seneschal:
    charter-line: "fixture front desk"
    office: "The Seneschal"
    sigil: "🔑"
    home: __BASE__/deskhome
    model: fable
    effort: high
    aliases: []
    history: refs/seats/seneschal.history.md
    schedules: []
  alpha:
    charter-line: "fixture seat alpha"
    office: "The Alpha"
    sigil: "📜"
    home: __BASE__/alphahome
    model: fable
    effort: high
    aliases: [alpha-old]
    history: refs/seats/alpha.history.md
    schedules:
      - unit: pulse-alpha
        tap: personal
        window: alpha
        session: sess-a
  beta:
    charter-line: "fixture seat beta"
    office: "The Beta"
    sigil: "🧭"
    home: ~/
    model: sonnet
    effort: high
    aliases: []
    history: refs/seats/beta.history.md
    schedules: []
  gamma:
    charter-line: "fixture seat gamma"
    office: "The Gamma"
    sigil: "🧾"
    home: __BASE__/gammahome
    model: opus
    effort: high
    aliases: []
    history: refs/seats/gamma.history.md
    schedules:
      - unit: pulse-gamma
        tap: work
        window: gamma
        session: sess-a
EOF
sed -i "s|__BASE__|$BASE|g" "$ROSTER"

# 0. The fixture must satisfy the REAL validator, or every case below tests a
# shape the roster could never legally have.
if python3 "$VALIDATOR" "$ROSTER" >/dev/null 2>"$ERR"; then ok
else bad "fixture roster must pass validate-seats.py ($(cat "$ERR"))"; fi

[ -x "$TMUX_BIN" ] || { echo "FAIL: no tmux binary — this suite cannot run"; exit 1; }
[ -x "$HALL" ] || bad "agents/bin/hall must be executable"

# hall <args…> — the script under test, pinned to the fixture roster and the
# fixture socket, with every seam this suite does not mean to use scrubbed.
hall() {
  env -u TMUX -u TMUX_TMPDIR -u HALL_SESSION -u HALL_ONLY_IF_ABSENT \
      SEATS_YML="$ROSTER" HALL_TMUX_SOCKET="$SOCK" bash "$HALL" "$@"
}
wins() { tm "$SOCK" list-windows -a -F '#{session_name}	#{window_name}	#{window_id}'; }
win_count() { wins | grep -c . ; }
# The ACTIVE window of a session, by session name. Never a `-t <sess>:<win>`
# target (R13) and never display-message -t, which wants a pane.
cur_win_name() {
  tm "$SOCK" list-windows -t "=$1" -F '#{?window_active,ACTIVE ,}#{window_name}' \
    | sed -n 's/^ACTIVE //p'
}

# ===========================================================================
# THE COURT VIEW
# ===========================================================================
tm "$SOCK" new-session -d -s sess-a -n shellwin -c "$BASE" 2>"$ERR"
tm "$SOCK" new-window -d -t "=sess-a" -n "🧠 alpha" -c "$BASE" 2>"$ERR"

COURT=$(hall 2>"$ERR")
eq "court rc" 0 "$?"
has "court header names the hall"  "THE HALL"        "$COURT"
has "court header names the host"  "$(hostname -s)"  "$COURT"
has "court has a seat column"      "seat"            "$COURT"

# Every roster seat renders — derived from the roster, not from a hardcoded
# list, so adding a fixture seat cannot silently go unrendered.
for s in seneschal alpha beta gamma; do
  has "court renders seat $s" "$s" "$COURT"
done
has "court renders the office" "The Seneschal" "$COURT"
has "court renders the model"  "sonnet"        "$COURT"
has "court renders the tap"    "work"          "$COURT"
has "court counts the seats"   "4 seats"       "$COURT"

# Status glyphs come from the LIVE window name, and 💤 from its absence.
ALPHA_ROW=$(printf '%s\n' "$COURT" | grep ' alpha ')
has "live window -> its own glyph" "🧠" "$ALPHA_ROW"
BETA_ROW=$(printf '%s\n' "$COURT" | grep ' beta ')
has "no window -> asleep" "💤" "$BETA_ROW"
hasnt "an asleep seat has no activity time" "0s" "$BETA_ROW"

# 🚧 — a live window matching no seat and no alias is REPORTED, never adopted.
UNREG_ROW=$(printf '%s\n' "$COURT" | grep 'shellwin')
has "unregistered window is flagged"  "🚧"                     "$UNREG_ROW"
has "unregistered names its session"  "no seat in sess-a" "$UNREG_ROW"
has "unregistered is counted"         "1 unregistered"         "$COURT"

# The legend carries Zig's PINNED mail glyph, and never the banned envelope.
has   "legend pins the mail glyph 📬" "📬" "$COURT"
hasnt "the banned envelope U+2709"    "✉"  "$COURT"

# --- THE GLYPH RULE, against the REAL output -------------------------------
# Same mechanical check the roster's sigils get: every codepoint in the court
# view goes through validate-seats.py's glyph_violation() — the rendered-output
# form of the property rule (dotfiles-gl6z), which passes ASCII and · and
# refuses anything that is CLAIMING to be a glyph and isn't 2 cells wide. It
# also asserts the output really does contain emoji, so an all-ASCII regression
# cannot pass by having nothing to reject.
printf '%s' "$COURT" > "$OUTF"
glyph_check() {
  python3 - "$VALIDATOR" "$1" <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("_vs", sys.argv[1])
vs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vs)
text = pathlib.Path(sys.argv[2]).read_text()
bad = []
for ch in text:
    r = vs.glyph_violation(ch)
    if r:
        bad.append(f"U+{ord(ch):04X}: {r}")
emoji = {ch for ch in text if ord(ch) >= 0x1F300}
if bad:
    print("VIOLATIONS " + " | ".join(sorted(set(bad))))
elif len(emoji) < 4:
    print(f"SUSPECT only {len(emoji)} emoji in the output — is it rendering at all?")
else:
    print(f"CLEAN {len(emoji)} distinct emoji")
PY
}
GLYPHCHECK=$(glyph_check "$OUTF")
case "$GLYPHCHECK" in
  CLEAN*) ok ;;
  *)      bad "GLYPHRULE every glyph in the court view must pass validate-seats.py's glyph rule ($GLYPHCHECK)" ;;
esac

# --- ALIGNMENT: the sigil column is exactly 2 cells, on every row ------------
# align_report <file> -> one line per table row whose leading glyph is not 2
# cells wide, using validate-seats.py's display_width (the property, not
# `ord(c) >= 0x1F300`, which is what said 🗝 was 2 cells while the terminal drew
# 1). A table row is `<glyph><space><space><text>`; the legend lines use ONE
# space and are not rows.
align_report() {
  python3 - "$VALIDATOR" "$1" <<'PY'
import importlib.util, pathlib, re, sys
spec = importlib.util.spec_from_file_location("_vs", sys.argv[1])
vs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vs)
rows = 0
for line in pathlib.Path(sys.argv[2]).read_text().splitlines():
    m = re.match(r"^(\S)  (\S)", line)
    if not m:
        continue
    rows += 1
    w = vs.display_width(m.group(1))
    if w != 2:
        print(f"STILTED U+{ord(m.group(1)):04X} width={w}: {line[:40]}")
if rows == 0:
    print("NO-ROWS the court rendered no table rows at all")
PY
}
ALIGN=$(align_report "$OUTF")
if [ -z "$ALIGN" ]; then ok; else bad "ALIGNMENT every court row must start with a 2-cell glyph ($ALIGN)"; fi

# The header's own text column must start where the rows' does: 4 cells in
# (one 2-cell glyph plus two spaces). Byte offset == cell offset here because
# the header line is pure ASCII.
HDR=$(printf '%s\n' "$COURT" | grep -n 'seat *office' | head -1 | cut -d: -f2-)
case "$HDR" in
  '    seat'*) ok ;;
  *) bad "ALIGNHDR the header's seat column must start at cell 4, got: [$HDR]" ;;
esac

# --- width stability (this renders inside a display-popup) -------------------
widest() {
  python3 - "$VALIDATOR" "$1" <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("_vs", sys.argv[1])
vs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vs)
print(max((vs.display_width(line) for line in
           pathlib.Path(sys.argv[2]).read_text().splitlines()), default=0))
PY
}
WIDE=$(widest "$OUTF")
if [ "$WIDE" -le 78 ]; then ok; else bad "WIDTH court view must stay <=78 cells wide for the popup (widest: $WIDE)"; fi

# --- THE PLANTED TEXT-PRESENTATION GLYPH (dotfiles-gl6z) --------------------
# The defect itself, reproduced: a roster carrying 🗝 U+1F5DD — emoji-RANGE,
# Emoji_Presentation=No. This fixture is DELIBERATELY invalid (validate-seats.py
# rejects it, which case 0 above asserts for the good roster), because the
# question here is what the RENDERER does when a roster gets past the gate.
# Two things must happen, and the first is the one that matters: the alignment
# check must go RED. A detector that cannot fail is not a detector.
PLANTED="$BASE/seats-planted.yml"
sed 's/sigil: "🔑"/sigil: "🗝"/' "$ROSTER" > "$PLANTED"
if python3 "$VALIDATOR" "$PLANTED" >/dev/null 2>&1; then
  bad "PLANTEDGATE the planted roster must FAIL validate-seats.py (it is the defect)"
else ok; fi
PCOURT=$(env -u TMUX -u TMUX_TMPDIR -u HALL_SESSION -u HALL_ONLY_IF_ABSENT \
           SEATS_YML="$PLANTED" HALL_TMUX_SOCKET="$SOCK" bash "$HALL" 2>"$ERR")
printf '%s' "$PCOURT" > "$BASE/planted.out"
PALIGN=$(align_report "$BASE/planted.out")
case "$PALIGN" in
  *STILTED*1F5DD*) ok ;;
  *) bad "PLANTEDALIGN a text-presentation sigil must make the alignment check RED, got: [$PALIGN]" ;;
esac
# …and the hall says so itself, on stderr, naming the seat — the court still
# renders (a cockpit that refuses to draw is worse than a crooked one).
has "PLANTEDAUDIT hall names the glyph rule"  "GLYPH RULE" "$(cat "$ERR")"
has "PLANTEDAUDIT hall names the seat"        "seneschal"  "$(cat "$ERR")"
has "PLANTEDAUDIT the court still rendered"   "THE HALL"   "$PCOURT"
# The good roster's audit is SILENT: a warning that always fires is noise.
hasnt "PLANTEDQUIET a clean roster gets no glyph warning" "GLYPH RULE" "$(env -u TMUX -u TMUX_TMPDIR \
        SEATS_YML="$ROSTER" HALL_TMUX_SOCKET="$SOCK" bash "$HALL" 2>&1 >/dev/null)"

# ===========================================================================
# RESPONSIVE WIDTH (dotfiles-hnhl) — three breakpoints, one seam
# ===========================================================================
# Zig's phone showed NOTHING (tmux: "height too large") and his desktop felt
# squished. COLUMNS is the seam the popup's real `tput cols` stands in for.
# EVERY breakpoint has to keep the properties the default width has: the glyph
# rule, the alignment, and now a budget — no line wider than the terminal it
# was rendered for, because a wrapped row is exactly the stilt again.
render_at() { # render_at <cols> [roster] -> writes $BASE/w<cols>.out, echoes it
  local c=$1 roster=${2:-$ROSTER}
  COLUMNS=$c env -u TMUX -u TMUX_TMPDIR -u HALL_SESSION -u HALL_ONLY_IF_ABSENT \
    SEATS_YML="$roster" HALL_TMUX_SOCKET="$SOCK" bash "$HALL" 2>/dev/null \
    | tee "$BASE/w$c.out"
}
for C in 40 80 120; do
  OUT=$(render_at "$C")
  G=$(glyph_check "$BASE/w$C.out")
  case "$G" in CLEAN*) ok ;; *) bad "BP$C glyph rule at $C cols ($G)" ;; esac
  A=$(align_report "$BASE/w$C.out")
  if [ -z "$A" ]; then ok; else bad "BP$C alignment at $C cols ($A)"; fi
  W=$(widest "$BASE/w$C.out")
  if [ "$W" -le "$C" ]; then ok; else bad "BP$C at $C cols the court is $W wide — it will WRAP"; fi
  has "BP$C every seat still renders at $C cols" "gamma" "$OUT"
done

# COMPACT (a phone): sigil, name, status — and deliberately NOT the office or
# the tap. Asserting what is ABSENT is the half that catches a "responsive"
# layout that just renders the wide table into a narrow terminal.
COMPACT=$(cat "$BASE/w40.out")
has   "BPCOMPACT keeps the name"     "seneschal"     "$COMPACT"
has   "BPCOMPACT keeps the status"   "💤"            "$COMPACT"
hasnt "BPCOMPACT drops the office"   "The Seneschal" "$COMPACT"
hasnt "BPCOMPACT drops the tap"      "personal"      "$COMPACT"
has   "BPCOMPACT teaches the prompt" "type a seat name" "$COMPACT"

# MEDIUM (the default desktop popup): the v0 court, host and tap included.
MEDIUM=$(cat "$BASE/w80.out")
has "BPMEDIUM has the office" "The Seneschal"  "$MEDIUM"
has "BPMEDIUM has the host"   "$(hostname -s)" "$MEDIUM"
has "BPMEDIUM has the tap"    "work"           "$MEDIUM"

# WIDE: the room is used — the charter line appears, and the estate role is
# spelled out rather than abbreviated to the bare host.
WIDEOUT=$(cat "$BASE/w120.out")
has "BPWIDE adds the charter column" "charter"            "$WIDEOUT"
has "BPWIDE prints a charter line"   "fixture seat alpha" "$WIDEOUT"
has "BPWIDE keeps every medium column" "model"            "$WIDEOUT"
# The wide layout is wider than the medium one — otherwise "responsive" is a
# word for three names for the same table.
if [ "$(widest "$BASE/w120.out")" -gt "$(widest "$BASE/w80.out")" ]; then ok
else bad "BPWIDE the wide court must actually use the room it is given"; fi

# THE REAL ROSTER, at every breakpoint. The fixture cannot see this: charter
# lines are free PROSE, every one of the 18 real ones is written with an em
# dash (U+2014, in the banned block), and the wide layout is the first thing
# that ever printed them. hall_plain folds them; this is what says so.
REAL_ROSTER="$ROOT/agents/seats.yml"
for C in 40 80 120; do
  render_at "$C" "$REAL_ROSTER" >/dev/null
  G=$(glyph_check "$BASE/w$C.out")
  case "$G" in CLEAN*) ok ;; *) bad "BPREAL$C the REAL roster at $C cols breaks the glyph rule ($G)" ;; esac
  W=$(widest "$BASE/w$C.out")
  if [ "$W" -le "$C" ]; then ok; else bad "BPREAL$C the REAL roster at $C cols is $W wide — it will WRAP"; fi
done

# ===========================================================================
# VISIT — existing window
# ===========================================================================
BEFORE=$(win_count)
OUT=$(hall alpha 2>"$ERR"); RC=$?
eq  "visit existing rc"                0        "$RC"
eq  "visit existing creates no window" "$BEFORE" "$(win_count)"
has "visit existing names the seat"    "alpha"  "$OUT"
has "visit existing names the office"  "The Alpha" "$OUT"
hasnt "visit existing did not materialize" "materialized" "$OUT"
# The glyph-prefixed live name still matched, and the session switched to it.
eq "visit selects the window" "🧠 alpha" "$(cur_win_name sess-a)"

# An ALIAS resolves to the canonical seat and reuses the same window.
tm "$SOCK" select-window -t "=sess-a" 2>"$ERR"
tm "$SOCK" select-window -t "$(wins | awk -F'\t' '$2=="shellwin"{print $3}')" 2>"$ERR"
BEFORE=$(win_count)
OUT=$(hall alpha-old 2>"$ERR"); RC=$?
eq  "visit by alias rc"                0         "$RC"
eq  "visit by alias creates no window" "$BEFORE" "$(win_count)"
has "visit by alias says ALIAS"        "ALIAS"   "$(cat "$ERR")"
has "visit by alias lands on alpha"    "🧠 alpha" "$(cur_win_name sess-a)"

# ===========================================================================
# VISIT — materialization
# ===========================================================================
OUT=$(hall beta 2>"$ERR"); RC=$?
eq  "materialize rc"              0              "$RC"
has "materialize says so"         "materialized" "$OUT"
BETA_ID=$(wins | awk -F'\t' '$1=="sess-a" && $2=="beta"{print $3}')
if [ -n "$BETA_ID" ]; then ok; else bad "materialize must create a window named for the seat"; fi
eq "materialize selects the new window" "beta" "$(cur_win_name sess-a)"
# home: ~ in the roster -> the window's cwd is $HOME, expanded.
eq "materialize expands ~ in the roster home" "$HOME" \
   "$(tm "$SOCK" display-message -p -t "$BETA_ID" '#{pane_current_path}')"
# v0 launches NOTHING: an empty shell at the right address is the whole job.
hasnt "v0 does not launch claude" "claude" "$(tm "$SOCK" display-message -p -t "$BETA_ID" '#{pane_current_command}')"

# Materialization happens at the ROSTER's address, never in the caller's
# session: `other` is the newest (so the most likely "current") session, and
# gamma's binding says sess-a.
tm "$SOCK" new-session -d -s other -c "$BASE" 2>"$ERR"
OUT=$(hall gamma 2>"$ERR"); RC=$?
eq "visit with a rival session rc" 0 "$RC"
GAMMA_SESS=$(wins | awk -F'\t' '$2=="gamma"{print $1}')
eq "materialize uses the ROSTER session, not the caller's" "sess-a" "$GAMMA_SESS"
GAMMA_ID=$(wins | awk -F'\t' '$2=="gamma"{print $3}')
eq "materialize uses the roster home as cwd" "$BASE/gammahome" \
   "$(tm "$SOCK" display-message -p -t "$GAMMA_ID" '#{pane_current_path}')"

# ===========================================================================
# HOME — the front desk
# ===========================================================================
# seneschal has no binding, so the target session is explicit here (this is
# exactly what the attach hook passes).
OUT=$(env -u TMUX -u TMUX_TMPDIR -u HALL_ONLY_IF_ABSENT \
        SEATS_YML="$ROSTER" HALL_TMUX_SOCKET="$SOCK" HALL_SESSION=sess-a \
        bash "$HALL" home 2>"$ERR"); RC=$?
eq  "home rc"                 0               "$RC"
has "home is the seneschal"   "seneschal"     "$OUT"
has "home names the office"   "The Seneschal" "$OUT"
eq  "home lands at the desk"  "seneschal"     "$(cur_win_name sess-a)"
eq  "home materialized at the seneschal's home" "$BASE/deskhome" \
    "$(tm "$SOCK" display-message -p -t "$(wins | awk -F'\t' '$2=="seneschal"{print $3}')" '#{pane_current_path}')"

# HALL_ONLY_IF_ABSENT — the attach hook's guard. The window exists now, so the
# hall must leave the session's selection exactly where it is.
tm "$SOCK" select-window -t "$BETA_ID" 2>"$ERR"
OUT=$(env -u TMUX -u TMUX_TMPDIR SEATS_YML="$ROSTER" HALL_TMUX_SOCKET="$SOCK" \
        HALL_SESSION=sess-a HALL_ONLY_IF_ABSENT=1 bash "$HALL" home 2>"$ERR"); RC=$?
eq  "only-if-absent rc"              0        "$RC"
eq  "only-if-absent does not switch" "beta"   "$(cur_win_name sess-a)"
has "only-if-absent says why"        "leaving it alone" "$(cat "$ERR")"

# ===========================================================================
# THE PROMPT (dotfiles-hnhl) — every form Zig might type means the same thing
# ===========================================================================
# The footer used to say "hall <seat> to visit", which reads as an instruction
# to type those exact words; Zig typed a bare seat name. Both are right, so
# both work — plus `home` and `hall home`. Driven end to end through
# --interactive with the line on stdin, because the parse and the visit are one
# behaviour, not two.
# HALL_SESSION is pinned for the same reason the `hall home` case above pins
# it: the seneschal has no roster binding, so without it the target session is
# whatever the socket happens to answer with, and the fixture has three.
prompt_with() { # prompt_with <stdin bytes> -> RC set, stdout returned
  printf '%s' "$1" | env -u TMUX -u TMUX_TMPDIR -u HALL_ONLY_IF_ABSENT \
    SEATS_YML="$ROSTER" HALL_TMUX_SOCKET="$SOCK" HALL_SESSION=sess-a \
    bash "$HALL" --interactive 2>"$ERR"
}
for FORM in 'alpha' 'hall alpha' '  alpha  '; do
  tm "$SOCK" select-window -t "$BETA_ID" 2>"$ERR"
  OUT=$(prompt_with "$FORM
"); RC=$?
  eq "PROMPT [$FORM] rc"    0         "$RC"
  eq "PROMPT [$FORM] visits" "🧠 alpha" "$(cur_win_name sess-a)"
done
for FORM in 'home' 'hall home'; do
  tm "$SOCK" select-window -t "$BETA_ID" 2>"$ERR"
  OUT=$(prompt_with "$FORM
"); RC=$?
  eq "PROMPTHOME [$FORM] rc"     0           "$RC"
  eq "PROMPTHOME [$FORM] visits" "seneschal" "$(cur_win_name sess-a)"
done

# A bare Enter closes, and an unknown name retries rather than closing on the
# typo — the two behaviours the raw-keystroke read must not have broken.
tm "$SOCK" select-window -t "$BETA_ID" 2>"$ERR"
OUT=$(prompt_with "
"); RC=$?
eq "PROMPTENTER rc"          0      "$RC"
eq "PROMPTENTER stays put"   "beta" "$(cur_win_name sess-a)"

# ESC closes on ONE keypress (Zig, live: a popup you cannot dismiss with the
# key everyone reaches for is a trap). The escape SEQUENCE of an arrow key
# (ESC [ A) must close too rather than leaving `[A` in the next prompt.
for KEYS in $'\e' $'\e[A'; do
  tm "$SOCK" select-window -t "$BETA_ID" 2>"$ERR"
  OUT=$(prompt_with "$KEYS"); RC=$?
  eq "PROMPTESC rc"        0      "$RC"
  eq "PROMPTESC stays put" "beta" "$(cur_win_name sess-a)"
  hasnt "PROMPTESC visits nothing" "materialized" "$OUT"
done

# ===========================================================================
# REFUSALS
# ===========================================================================
OUT=$(hall nosuchseat 2>"$ERR"); RC=$?
eq  "unknown seat rc is 2"         2   "$RC"
eq  "unknown seat prints nothing"  ""  "$OUT"
has "unknown seat names the input" "nosuchseat" "$(cat "$ERR")"
has "unknown seat lists the roster" "alpha"     "$(cat "$ERR")"
# A near miss gets near matches, not the whole roster.
OUT=$(hall alph 2>"$ERR"); RC=$?
eq  "near-miss rc is 2"           2         "$RC"
has "near miss suggests alpha"    "alpha"   "$(cat "$ERR")"
has "near miss says did you mean" "Did you mean" "$(cat "$ERR")"
# Two seats at once is a usage error, not a guess about which one.
OUT=$(hall alpha beta 2>"$ERR"); RC=$?
eq "two seats rc is 2" 2 "$RC"

# ===========================================================================
# STRUCTURE — the hall NAVIGATES; it never types and never destroys
# ===========================================================================
# Comments are stripped first: this file DISCUSSES send-keys at length, and a
# grep that counts prose cannot tell an explanation from a call.
CODE=$(grep -vE '^[[:space:]]*#' "$HALL")
eq "hall contains no send-keys"   0 "$(printf '%s\n' "$CODE" | grep -c 'send-keys')"
eq "hall contains no kill-server" 0 "$(printf '%s\n' "$CODE" | grep -c 'kill-server')"
eq "hall contains no kill-window" 0 "$(printf '%s\n' "$CODE" | grep -cE 'kill-window|kill-session')"
# Every tmux call goes through the socket-explicit wrapper (R7 / dotfiles-2v8h):
# the only bare `tmux` in the code is the `command -v` that finds the binary.
eq "hall never calls tmux bare" 0 \
   "$(printf '%s\n' "$CODE" | grep -cE '(^|[;&|(])[[:space:]]*tmux[[:space:]]')"

# ===========================================================================
# THE tmux.conf HALL BLOCK, EXECUTED AS COMMITTED (repo rule 2)
# ===========================================================================
# The bytes come out of tmux/tmux.conf by marker, never retyped — the detail
# that breaks an example is usually a quoting one, and retyping repairs it
# silently. The only edit is the install path ($HOME/dotfiles -> this worktree),
# because the fixture must run THIS tree's hall.
CONF="$BASE/hall-block.conf"
awk '/# HALL-BLOCK-BEGIN/{f=1; next} /# HALL-BLOCK-END/{f=0} f' \
  "$ROOT/tmux/tmux.conf" > "$CONF"
if [ -s "$CONF" ]; then ok; else bad "the HALL block markers must delimit real content in tmux/tmux.conf"; fi
sed -i "s|\$HOME/dotfiles|$ROOT|g" "$CONF"

tm "$SOCK2" new-session -d -s seed -c "$BASE" 2>"$ERR"
tm "$SOCK2" set-environment -g SEATS_YML "$ROSTER" 2>"$ERR"
# The hall lives on `prefix W` (Zig, 2026-08-09 — unbound, zero displacement).
# The block still sits AFTER the tpm run (last-writer-wins is the general
# hazard); simulate a plugin binding on W, source the block, assert the hall
# won — AND assert pain-control's `prefix H` resize was NOT displaced.
tm "$SOCK2" bind-key -r -T prefix H resize-pane -L 5 2>"$ERR"
tm "$SOCK2" bind-key -r -T prefix W resize-pane -R 5 2>"$ERR"
if tm "$SOCK2" source-file "$CONF" 2>"$ERR"; then ok
else bad "the committed HALL block must parse ($(cat "$ERR"))"; fi
BINDING=$(tm "$SOCK2" list-keys -T prefix | grep -E "^bind-key( -r)? +-T prefix +W ")
has "prefix W opens the hall in a popup" "display-popup" "$BINDING"
hasnt "prefix W no longer holds a plugin bind" "resize-pane" "$BINDING"

# --- POPUP SIZING: percentages, never cells (dotfiles-hnhl) -----------------
# On Zig's PHONE, `-w 84 -h 32` made tmux answer "height too large" and draw
# NOTHING. An absolute size is a promise about a client you have not met; a
# percentage is computed against the client that is actually opening the popup,
# so NO client size can produce that error. Both halves are asserted: the
# percentages are there, AND no bare cell count survives anywhere in the
# binding.
# tmux re-prints the binding with the size ARGUMENTS QUOTED (`-h "85%"`), so
# match against what the SERVER says, not against the source line.
if printf '%s\n' "$BINDING" | grep -qE ' -w "?[0-9]+%'; then ok
else bad "POPUPW the popup width must be a PERCENTAGE (got: $BINDING)"; fi
if printf '%s\n' "$BINDING" | grep -qE ' -h "?[0-9]+%'; then ok
else bad "POPUPH the popup height must be a PERCENTAGE (got: $BINDING)"; fi
if printf '%s\n' "$BINDING" | grep -qE ' -[wh] "?[0-9]+"? '; then
  bad "POPUPABS an absolute cell size survives in the binding: $BINDING"
else ok; fi
# …and the percentages must actually leave room: 100% or more is a popup with
# no border and, at -h, the same overflow by another name.
PCTS=$(printf '%s\n' "$BINDING" | grep -oE ' -[wh] "?[0-9]+%' | grep -oE '[0-9]+')
PCTBAD=""
for p in $PCTS; do [ "$p" -ge 100 ] || [ "$p" -lt 50 ] && PCTBAD="$PCTBAD $p"; done
if [ -z "$PCTBAD" ]; then ok; else bad "POPUPPCT popup percentage(s) out of the 50-99 range:$PCTBAD"; fi
HBIND=$(tm "$SOCK2" list-keys -T prefix | grep -E "^bind-key( -r)? +-T prefix +H ")
has "prefix H keeps pain-control's resize (nothing displaced)" "resize-pane" "$HBIND"

# The attach default: a session named for the HOST gets the front desk.
tm "$SOCK2" new-session -d -s "$(hostname -s)" -c "$BASE" 2>"$ERR"
DESK=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  DESK=$(tm "$SOCK2" list-windows -a -F '#{session_name}	#{window_name}' | grep -F "seneschal")
  [ -n "$DESK" ] && break
  sleep 0.5
done
has "session-created materializes the front desk" "seneschal" "$DESK"
has "the desk lands in the host-named session"    "$(hostname -s)" "$DESK"

# …and a session that is NOT the host's is left completely alone.
tm "$SOCK2" new-session -d -s notthehost -c "$BASE" 2>"$ERR"
sleep 2
OTHER=$(tm "$SOCK2" list-windows -t "=notthehost" -F '#{window_name}')
hasnt "a non-host session gets no front desk" "seneschal" "$OTHER"

TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then echo "PASS: $PASS/$TOTAL test cases"; exit 0; fi
echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED[@]}"; do echo "  - $n"; done
exit 1
