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
#   tap          the TAP COLUMN's policy layer (dotfiles-oq4n): epoch-3 names
#                derived from taps.conf, the `seat_home.<seat>` override drawn
#                as `primary→secondary`, an override that AGREES drawn with no
#                arrow, no conf drawn as the roster's own value — plus the
#                column math the arrow forces (3 bytes, ONE cell)
#   visit        existing window (glyph-prefixed name still matches) -> select,
#                no second window; absent -> materialize in the ROSTER's
#                session with the roster's home as cwd and the canonical name
#   breakpoints  compact/medium/wide render at 40/80/120 cols, fixture roster
#                AND the real one; compact shows LIVE seats only and says so in
#                one line when there are none (Zig's phone, dotfiles-hnhl)
#   prompt       the raw input loop: every keystroke is read one byte at a time
#                and the loop owns the buffer, so backspace reaches the FIRST
#                character, a bare Esc closes with text in the buffer, and an
#                arrow key is swallowed instead of closing the popup
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
mkdir -p "$BASE/deskhome" "$BASE/alphahome" "$BASE/gammahome" "$BASE/claude-work" \
         "$BASE/deltahome" "$BASE/epsilonhome" "$BASE/zetahome"
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
    config_dir: __BASE__/claude-work
    failover: []
seats:
  seneschal:
    charter-line: "fixture front desk"
    office: "The Seneschal"
    sigil: "🔑"
    home: __BASE__/deskhome
    model: fable
    effort: high
    tap: personal
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
    tap: personal
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
    tap: personal
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
    tap: work
    aliases: []
    history: refs/seats/gamma.history.md
    schedules:
      - unit: pulse-gamma
        tap: work
        window: gamma
        session: sess-a
  # The LAUNCH seats (dotfiles-dsbl). Their own session (sess-b) keeps their
  # windows out of every court/visit case above, and each has a binding so the
  # target session is the ROSTER's answer rather than "whichever session the
  # socket named first" — three fixtures materializing into an ambiguous
  # session is a flaky suite waiting to happen.
  delta:
    charter-line: "fixture launch seat, work tap"
    office: "The Delta"
    sigil: "🧱"
    home: __BASE__/deltahome
    model: sonnet
    effort: high
    tap: work
    aliases: []
    history: refs/seats/delta.history.md
    schedules:
      - unit: pulse-delta
        tap: work
        window: delta
        session: sess-b
  epsilon:
    charter-line: "fixture launch seat, personal tap"
    office: "The Epsilon"
    sigil: "🪙"
    home: __BASE__/epsilonhome
    model: sonnet
    effort: high
    tap: personal
    aliases: []
    history: refs/seats/epsilon.history.md
    schedules:
      - unit: pulse-epsilon
        tap: personal
        window: epsilon
        session: sess-b
  zeta:
    charter-line: "fixture launch seat, never launched"
    office: "The Zeta"
    sigil: "🔧"
    home: __BASE__/zetahome
    model: sonnet
    effort: high
    tap: personal
    aliases: []
    history: refs/seats/zeta.history.md
    schedules:
      - unit: pulse-zeta
        tap: personal
        window: zeta
        session: sess-b
EOF
sed -i "s|__BASE__|$BASE|g" "$ROSTER"

# --- the fixture TAP POLICY (dotfiles-oq4n) ---------------------------------
# agents/scheduler/taps.conf is the hall's second input now, and the suite must
# be hermetic against it for the same reason it is hermetic against ~/.tmux.conf:
# Zig edits that file, and a suite whose expectations move when he does is a
# suite that reports his edits as regressions.
#
# EXPORTED, not passed per call: the tap-headroom library reads
# $TAP_HEADROOM_CONF, and every `env` invocation below would otherwise have to
# thread it through by hand. The two cases that need a DIFFERENT conf (no conf
# at all; the REAL conf against the REAL roster) set it explicitly.
#
# Shaped like the real one, and the overrides are chosen to make each rule
# fail loudly on its own:
#   alpha    tap personal, seat_home secondary -> `primary→secondary` (17 wide,
#            the widest cell, so it is what sizes the column)
#   epsilon  tap personal, seat_home linearb   -> `primary→linearb` (15 wide —
#            SHORTER than the column, so its field is PADDED, which is the only
#            place the byte-vs-cell arithmetic can go wrong)
#   beta     tap personal, seat_home primary   -> `primary`, NO arrow: an
#            override that agrees with the derived pool is not news
#   gamma    tap work, no override             -> `linearb` (the epoch-2 map)
#   seneschal/delta/zeta                       -> the plain epoch-3 name
TAPCONF="$BASE/taps.conf"
cat > "$TAPCONF" <<'EOF'
order=primary,secondary,linearb
pool.primary.taps=primary,tick
pool.primary.config_dir=~/.claude
pool.primary.groups=primary,personal
pool.secondary.taps=secondary
pool.secondary.config_dir=~/.claude-secondary
pool.secondary.groups=secondary
pool.linearb.taps=linearb
pool.linearb.config_dir=~/.claude-work
pool.linearb.groups=linearb,work
seat_home.alpha=secondary
seat_home.epsilon=linearb
seat_home.beta=primary
ceiling=1.0
EOF
export TAP_HEADROOM_CONF="$TAPCONF"
ARROW=$(printf '\xe2\x86\x92')     # U+2192, Zig's ruled override separator

# 0. The fixture must satisfy the REAL validator, or every case below tests a
# shape the roster could never legally have.
if python3 "$VALIDATOR" "$ROSTER" >/dev/null 2>"$ERR"; then ok
else bad "fixture roster must pass validate-seats.py ($(cat "$ERR"))"; fi

[ -x "$TMUX_BIN" ] || { echo "FAIL: no tmux binary — this suite cannot run"; exit 1; }
[ -x "$HALL" ] || bad "agents/bin/hall must be executable"

# hall <args…> — the script under test, pinned to the fixture roster and the
# fixture socket, with every seam this suite does not mean to use scrubbed.
#
# ⚠️ HALL_NO_LAUNCH=1 IS THE DEFAULT HERE, and it is a safety rail: since
# dotfiles-dsbl a visit LAUNCHES the seat through pulse-inject.sh, and the
# default launcher is `claude`. A suite that materializes five fixture windows
# would otherwise start five real Claude sessions and spend a tap per run. The
# LAUNCH section below opts in explicitly, with an inert launcher.
hall() {
  env -u TMUX -u TMUX_TMPDIR -u HALL_SESSION -u HALL_ONLY_IF_ABSENT \
      SEATS_YML="$ROSTER" HALL_TMUX_SOCKET="$SOCK" HALL_NO_LAUNCH=1 \
      bash "$HALL" "$@"
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
has "court renders the tap"    "linearb"       "$COURT"
# THE TAP COLUMN NEVER SAYS `-` FOR A SEAT (Zig, 2026-08-09): beta and the
# seneschal have no schedule at all and still draw a tap, because the roster
# now states it. `-` in that column is reserved for an UNREGISTERED window,
# where emptiness is the honest answer.
TAPCOL=$(printf '%s\n' "$COURT" | grep -E '^.  (beta|seneschal) ' | sed 's/.*  //')
has  "TAPCOL a schedule-less seat still shows its tap" "primary" \
     "$(printf '%s\n' "$COURT" | grep ' beta ')"
hasnt "TAPCOL a schedule-less seat never shows a dash" " -$" "$TAPCOL"
has "court counts the seats"   "7 seats"       "$COURT"

# --- THE TAP COLUMN'S POLICY LAYER (dotfiles-oq4n) -------------------------
# Zig read `personal` against the marshal while taps.conf said
# `seat_home.marshal=secondary`. Two lies in one cell: an EPOCH-2 tap name, and
# no sign of the override at all. Each rule gets its own case, and each case is
# chosen so that dropping the rule changes THIS assertion rather than some
# other one.
tap_of() { printf '%s\n' "$1" | grep -E "^.  $2 " | sed -E 's/.*[[:space:]]([^[:space:]]+)[[:space:]]*$/\1/'; }
# EPOCH 3, derived from the conf's own pool.<p>.groups (`personal` survives
# only there, and that list's first entry is the epoch-3 name). Never a table
# in the hall.
eq "TAPEPOCH personal -> primary" "primary" "$(tap_of "$COURT" seneschal)"
eq "TAPEPOCH work -> linearb"     "linearb" "$(tap_of "$COURT" gamma)"
# THE OVERRIDE, with Zig's separator. This is the marshal's case, in fixture form.
eq "TAPOVERRIDE seat_home draws the arrow" "primary${ARROW}secondary" \
   "$(tap_of "$COURT" alpha)"
eq "TAPOVERRIDE a second, shorter override" "primary${ARROW}linearb" \
   "$(tap_of "$COURT" epsilon)"
# AN OVERRIDE THAT AGREES IS NOT NEWS. beta's seat_home is `primary` and its
# tap already resolves to the primary pool: an implementation that renders the
# override unconditionally says `primary→primary` here.
eq    "TAPAGREE an override to the derived pool draws no arrow" "primary" \
      "$(tap_of "$COURT" beta)"
hasnt "TAPAGREE no arrow on beta's row" "$ARROW" "$(printf '%s\n' "$COURT" | grep ' beta ')"
# NO CONF, NO CHANGE: the v0 roster value, verbatim, with no error text and no
# dash. This is the graceful path on a machine (or a clone) with no tap policy.
NOCONF=$(env -u TMUX -u TMUX_TMPDIR -u HALL_SESSION -u HALL_ONLY_IF_ABSENT \
           SEATS_YML="$ROSTER" HALL_TMUX_SOCKET="$SOCK" \
           TAP_HEADROOM_CONF="$BASE/no-such-taps.conf" bash "$HALL" 2>/dev/null)
eq    "TAPNOCONF falls back to the roster value" "personal" "$(tap_of "$NOCONF" seneschal)"
eq    "TAPNOCONF the work seat too"              "work"     "$(tap_of "$NOCONF" gamma)"
hasnt "TAPNOCONF no arrow anywhere"              "$ARROW"   "$NOCONF"
hasnt "TAPNOCONF no error text in the cell"      "conf"     "$NOCONF"
# THE REAL ROSTER AGAINST THE REAL CONF — the thing Zig actually looked at.
# Nothing here is a fixture: agents/seats.yml says marshal tap:personal and
# agents/scheduler/taps.conf says seat_home.marshal=secondary.
REALPOLICY=$(COLUMNS=120 env -u TMUX -u TMUX_TMPDIR -u HALL_SESSION -u HALL_ONLY_IF_ABSENT \
               SEATS_YML="$ROOT/agents/seats.yml" HALL_TMUX_SOCKET="$SOCK" \
               TAP_HEADROOM_CONF="$ROOT/agents/scheduler/taps.conf" bash "$HALL" 2>/dev/null)
has "TAPREAL the marshal's override is on the court" "primary${ARROW}secondary" \
    "$(printf '%s\n' "$REALPOLICY" | grep ' marshal ')"
has "TAPREAL the Factor reads linearb, not work"     "linearb" \
    "$(printf '%s\n' "$REALPOLICY" | grep ' linearb ')"
hasnt "TAPREAL no epoch-2 name survives in the column" " personal " "$REALPOLICY"

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
#
# ⚠️ ONE ALLOWED EXCEPTION, and it is a WHITELIST OF ONE: U+2192, the tap
# column's override separator, which Zig picked explicitly over the hall's
# sketched `>` when he ruled the statusline's rollover surface (dotfiles-kcto,
# dotfiles-oq4n). It is not a glyph and is never treated as one — it is TEXT
# inside a text column, 1 cell wide — which is why it is allowed HERE and not
# in validate-seats.py, whose sigil rule governs ROSTER FIELDS and must stay
# unweakened. The allowance is named codepoint by codepoint on purpose: a
# second arrow, a box-drawing character or an em dash still goes red.
printf '%s' "$COURT" > "$OUTF"
glyph_check() {
  python3 - "$VALIDATOR" "$1" <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("_vs", sys.argv[1])
vs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vs)
ALLOWED = {0x2192}          # the tap column's override separator, Zig's pick
text = pathlib.Path(sys.argv[2]).read_text()
bad = []
for ch in text:
    if ord(ch) in ALLOWED:
        continue
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

# …and the exception is MEASURED, not asserted. U+2192 is allowed above on the
# strength of being 1 cell of text; if it were ever 2 (or if display_width
# stopped being able to tell), every padded field carrying it would be wrong by
# exactly the amount nobody would notice.
ARROWW=$(python3 - "$VALIDATOR" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("_vs", sys.argv[1])
vs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vs)
print(f"{vs.display_width(chr(0x2192))} {vs.sigil_violation(chr(0x2192)) is not None}")
PY
)
eq "TAPARROW U+2192 is ONE cell of TEXT, and not a legal sigil" "1 True" "$ARROWW"
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
# 60 is in the list because it is the MEDIUM FLOOR, and the tap column grew
# there (dotfiles-oq4n): an override cell is 17 cells where the old fixed
# column was 8, so 60 is the width at which the office and the tap can no
# longer both have what they want. If that trade ever overflows, this is the
# case that says so.
for C in 40 60 80 120; do
  OUT=$(render_at "$C")
  G=$(glyph_check "$BASE/w$C.out")
  case "$G" in CLEAN*) ok ;; *) bad "BP$C glyph rule at $C cols ($G)" ;; esac
  A=$(align_report "$BASE/w$C.out")
  if [ -z "$A" ]; then ok; else bad "BP$C alignment at $C cols ($A)"; fi
  W=$(widest "$BASE/w$C.out")
  if [ "$W" -le "$C" ]; then ok; else bad "BP$C at $C cols the court is $W wide — it will WRAP"; fi
  if [ "$C" -lt 60 ]; then
    # COMPACT is LIVE WINDOWS ONLY since Zig's 2026-08-09 phone note, so the
    # roster-completeness assertion belongs to the wider layouts. `alpha` is the
    # seat with a window here; `gamma` has none, and asserting it at 40 cols
    # would be asserting the phone dump this breakpoint exists to stop printing.
    has "BP$C the live seat renders at $C cols" "alpha" "$OUT"
  else
    has "BP$C every seat still renders at $C cols" "gamma" "$OUT"
  fi
done

# COMPACT (a phone): sigil, name, status — and deliberately NOT the office or
# the tap. Asserting what is ABSENT is the half that catches a "responsive"
# layout that just renders the wide table into a narrow terminal.
COMPACT=$(cat "$BASE/w40.out")
has   "BPCOMPACT keeps the live seat"   "alpha"         "$COMPACT"
hasnt "BPCOMPACT drops an asleep seat"  "seneschal"     "$COMPACT"
hasnt "BPCOMPACT drops the office"      "The Seneschal" "$COMPACT"
hasnt "BPCOMPACT drops the tap"         "primary"       "$COMPACT"
hasnt "BPCOMPACT drops the arrow too"   "$ARROW"        "$COMPACT"
has   "BPCOMPACT teaches the prompt"    "type a seat name" "$COMPACT"
# …and the wider layouts still draw the WHOLE roster — the asleep seats are
# dropped by the phone breakpoint, not by the renderer.
has "BPMEDIUM keeps the asleep seats"   "seneschal"     "$(cat "$BASE/w80.out")"
has "BPWIDEROSTER keeps the asleep seats" "seneschal"   "$(cat "$BASE/w120.out")"

# MEDIUM (the default desktop popup): the v0 court, host and tap included.
MEDIUM=$(cat "$BASE/w80.out")
has "BPMEDIUM has the office" "The Seneschal"  "$MEDIUM"
has "BPMEDIUM has the host"   "$(hostname -s)" "$MEDIUM"
has "BPMEDIUM has the tap"    "linearb"        "$MEDIUM"
has "BPMEDIUM has the override" "primary${ARROW}secondary" "$MEDIUM"
# At the medium FLOOR the tap column is squeezed, and what it gives up is the
# HOME side — the override keeps its full width, because the override is the
# news (`pr.→secondary`, never `primary→seco.`).
NARROW=$(cat "$BASE/w60.out")
has "BPMEDIUM60 the override survives the squeeze" "${ARROW}secondary" "$NARROW"

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

# --- THE COLUMN AFTER THE TAP (dotfiles-oq4n) ------------------------------
# The wide layout is the ONLY place the tap column is padded — the charter
# follows it — and it is therefore the only place the arrow's byte/cell
# mismatch can be seen. printf pads by BYTES; U+2192 is 3 bytes and 1 cell, so
# a field holding one is 2 bytes "wide" the terminal never draws, and every
# row with an arrow drifts LEFT by 2 relative to every row without one.
#
# The fixture is built for exactly this: alpha's cell is 17 cells (it sizes the
# column, so it is never padded) and epsilon's is 15 (so it IS padded, by 2 —
# the only arithmetic that can be wrong). Every fixture charter starts with the
# word `fixture`, which gives one anchor per row, header included.
charter_starts() {
  python3 - "$VALIDATOR" "$1" <<'PY'
import importlib.util, pathlib, re, sys
spec = importlib.util.spec_from_file_location("_vs", sys.argv[1])
vs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vs)
seen = {}
for line in pathlib.Path(sys.argv[2]).read_text().splitlines():
    if not re.match(r"^(\S)  (\S)", line):
        continue
    i = line.find("fixture")
    if i < 0:
        continue
    seen.setdefault(vs.display_width(line[:i]), []).append(line[:14].strip())
if len(seen) == 1:
    print(f"ALIGNED at cell {next(iter(seen))} across {sum(len(v) for v in seen.values())} rows")
else:
    print("SHIFTED " + " | ".join(f"cell {k}: {','.join(v)}" for k, v in sorted(seen.items())))
PY
}
CSTART=$(charter_starts "$BASE/w120.out")
case "$CSTART" in
  ALIGNED*) ok ;;
  *) bad "TAPCOLMATH the charter must start at the same cell on every row — the tap arrow is 3 bytes and 1 cell ($CSTART)" ;;
esac
# …and the fixture really does exercise both shapes, or the check above is
# asserting alignment over rows that are all the same.
has "TAPCOLMATH the wide court carries a padded arrow row" "primary${ARROW}linearb" \
    "$(cat "$BASE/w120.out")"

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
# COMPACT SHOWS LIVE WINDOWS ONLY (dotfiles-hnhl, Zig from his phone)
# ===========================================================================
# "the list of seats is still too long on my phone" — a 💤 row is a seat with
# NO window: nothing to watch, and on a phone every row is a scroll. So below
# the compact breakpoint the court renders the live seats and nothing else, and
# the count line carries the rest.
#
# Its own SERVER, because the fixture is the whole point: exactly two seats with
# windows, five without, and no unregistered window to blur the row count. A
# session's first window is named for a seat here rather than left as a shell,
# so `rows` means "seat rows" with nothing to subtract.
SOCK3="$SOCKDIR/hall-compact"
tm "$SOCK3" new-session -d -s sess-c -n seneschal -c "$BASE" 2>"$ERR"
tm "$SOCK3" new-window  -d -t "=sess-c" -n "🧠 alpha" -c "$BASE" 2>"$ERR"
# A table row is `<glyph><space><space><text>`; the legend, the count line and
# the footer all fail that shape (they lead with a word, a digit, or one space).
rows_of() { printf '%s\n' "$1" | grep -cE '^[^[:space:]]  [^[:space:]]'; }
CLIVE=$(COLUMNS=40 env -u TMUX -u TMUX_TMPDIR -u HALL_SESSION -u HALL_ONLY_IF_ABSENT \
          SEATS_YML="$ROSTER" HALL_TMUX_SOCKET="$SOCK3" bash "$HALL" 2>/dev/null)
# The ROWS, not the whole frame: the header's `here:` cell also names a seat,
# and asserting against the frame would let it stand in for a row that is gone.
CROWS=$(printf '%s\n' "$CLIVE" | grep -E '^[^[:space:]]  [^[:space:]]')
eq    "BPLIVE renders one row per LIVE seat and no more" 2 "$(rows_of "$CLIVE")"
has   "BPLIVE keeps the live seat alpha"     "alpha"     "$CROWS"
has   "BPLIVE keeps the live seat seneschal" "seneschal" "$CROWS"
for s in beta gamma delta epsilon zeta; do
  hasnt "BPLIVE drops the asleep seat $s" "$s" "$CROWS"
done
has   "BPLIVE still counts the asleep ones" "5 asleep"  "$CLIVE"
hasnt "BPLIVE no row is asleep"             "💤"        "$CROWS"
# The same server at a WIDER breakpoint still draws the whole roster: the drop
# is the phone's, not the renderer's.
CWIDE=$(COLUMNS=100 env -u TMUX -u TMUX_TMPDIR -u HALL_SESSION -u HALL_ONLY_IF_ABSENT \
          SEATS_YML="$ROSTER" HALL_TMUX_SOCKET="$SOCK3" bash "$HALL" 2>/dev/null)
eq "BPLIVEWIDE the wide court still draws every seat" 7 "$(rows_of "$CWIDE")"

# ALL ASLEEP: the roster dump was the WORST case on a phone — 18 rows saying
# nothing is running. One line says it instead. The fixture is a socket with no
# server at all, which is the only way to get zero live windows (a live server
# always has at least one, and it would render as an unregistered row).
DEADSOCK="$BASE/no-such-tmux-socket"
asleep_at() {
  COLUMNS=$1 env -u TMUX -u TMUX_TMPDIR -u HALL_SESSION -u HALL_ONLY_IF_ABSENT \
    SEATS_YML="$ROSTER" HALL_TMUX_SOCKET="$DEADSOCK" bash "$HALL" 2>/dev/null
}
CASLEEP=$(asleep_at 56)
has  "BPASLEEP says it in one line" "all 7 seats asleep $(printf '\xc2\xb7') type a name to wake one" "$CASLEEP"
eq   "BPASLEEP renders no rows at all" 0 "$(rows_of "$CASLEEP")"
for s in alpha beta gamma; do
  hasnt "BPASLEEP names no seat $s" " $s " "$CASLEEP"
done
# …and on a narrower phone it becomes two short lines rather than one wrapped
# one — a wrap is the stilt the whole layout exists to avoid.
CASLEEP40=$(asleep_at 40)
printf '%s' "$CASLEEP40" > "$BASE/asleep40.out"
has "BPASLEEP40 keeps the count line" "all 7 seats asleep"      "$CASLEEP40"
has "BPASLEEP40 keeps the invitation" "type a name to wake one" "$CASLEEP40"
W=$(widest "$BASE/asleep40.out")
if [ "$W" -le 40 ]; then ok; else bad "BPASLEEP40 the all-asleep court is $W wide at 40 cols — it will WRAP"; fi
G=$(glyph_check "$BASE/asleep40.out")
case "$G" in CLEAN*) ok ;; *) bad "BPASLEEP40 glyph rule on the all-asleep court ($G)" ;; esac
# The WIDE layout is untouched by any of this: no message, the full roster.
CASLEEPWIDE=$(asleep_at 120)
hasnt "BPASLEEPWIDE the wide court gets no message" "type a name to wake one" "$CASLEEPWIDE"
eq    "BPASLEEPWIDE the wide court still draws every seat" 7 "$(rows_of "$CASLEEPWIDE")"

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
# --no-launch (the helper's default here) materializes and starts NOTHING: an
# empty shell at the right address. The launching path is the LAUNCH section.
hasnt "no-launch starts nothing" "claude" "$(tm "$SOCK" display-message -p -t "$BETA_ID" '#{pane_current_command}')"

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
# LAUNCH (dotfiles-dsbl) — a visit starts the seat, through the INJECTOR
# ===========================================================================
# Zig, after the first live visit: "it opened the hevyd window but didn't start
# the claude session." So a materializing visit now shells out to the real
# agents/scheduler/pulse-inject.sh, which types `/onboard` into a window it
# launched — the hall itself still never send-keys, and the STRUCTURE section
# below still proves it.
#
# The injector is driven through ITS OWN seams, not a stand-in: `--launch cat`
# (an inert launcher, exactly as test-pulse-inject.sh does it) via HALL_LAUNCH,
# and PULSE_READY_MARKER='' to disable the composer readiness gate that `cat`
# could never satisfy. The EVIDENCE is the pane itself — what the injector
# typed into it — plus its verdict line, not the hall's own report of what it
# meant to do.
LAUNCHLOG="$BASE/launch.log"
hall_launching() { # same hall, but with the launch path ARMED
  env -u TMUX -u TMUX_TMPDIR -u HALL_SESSION -u HALL_ONLY_IF_ABSENT \
      -u CLAUDE_CONFIG_DIR \
      SEATS_YML="$ROSTER" HALL_TMUX_SOCKET="$SOCK" \
      HALL_INJECT="$ROOT/agents/scheduler/pulse-inject.sh" \
      HALL_LAUNCH=cat HALL_LAUNCH_LOG="$LAUNCHLOG" \
      PULSE_READY_MARKER='' PULSE_CONFIG_CRED_FILE='' \
      bash "$HALL" "$@"
}
wait_for_launch() { # wait_for_launch <n verdicts expected> -> 0 if seen
  local want=$1 i
  for i in $(seq 1 60); do
    [ "$(grep -c 'PULSE_INJECT_RESULT=' "$LAUNCHLOG" 2>/dev/null)" -ge "$want" ] && return 0
    sleep 0.5
  done
  return 1
}
pane_text() { tm "$SOCK" capture-pane -p -t "$1" 2>/dev/null; }

# --- ABSENT window -> materialize AND launch --------------------------------
# `delta` is a work-tap seat with no window anywhere yet.
tm "$SOCK" new-session -d -s sess-b -c "$BASE" 2>"$ERR"
OUT=$(hall_launching delta 2>"$ERR"); RC=$?
eq  "LAUNCH rc"                0              "$RC"
has "LAUNCH materialized"      "materialized" "$OUT"
has "LAUNCH says it launched"  "launching"    "$(cat "$ERR")"
if wait_for_launch 1; then ok; else bad "LAUNCHVERDICT the injector never reported a verdict ($(cat "$LAUNCHLOG"))"; fi
has "LAUNCHVERDICT the injector injected" "PULSE_INJECT_RESULT=injected" "$(cat "$LAUNCHLOG")"
DELTA_ID=$(wins | awk -F'\t' '$2=="delta"{print $3}')
if [ -n "$DELTA_ID" ]; then ok; else bad "LAUNCHWIN the seat's window must exist"; fi
eq  "LAUNCH ran the launcher"  "cat" "$(tm "$SOCK" display-message -p -t "$DELTA_ID" '#{pane_current_command}')"
has "LAUNCH typed /onboard"    "/onboard" "$(pane_text "$DELTA_ID")"
# TAP CORRECTNESS: delta's tap is `work`, whose config_dir is NOT the default
# seat, so the injector exports it into the pane before launching.
has "LAUNCHTAP work seat gets the config dir" "export CLAUDE_CONFIG_DIR=" "$(pane_text "$DELTA_ID")"
has "LAUNCHTAP and it is the WORK one"        "claude-work"               "$(pane_text "$DELTA_ID")"

# --- a PERSONAL seat gets NO --config-dir ----------------------------------
# The flag's job is to move a launch OFF the default seat. Asserting the
# default one only buys failure modes (exit 78 on a missing credential file,
# failed-wrong-seat on a warm pane), so the hall does not pass it.
OUT=$(hall_launching epsilon 2>"$ERR"); RC=$?
eq "LAUNCHPERSONAL rc" 0 "$RC"
if wait_for_launch 2; then ok; else bad "LAUNCHPERSONAL no verdict ($(cat "$LAUNCHLOG"))"; fi
EPS_ID=$(wins | awk -F'\t' '$2=="epsilon"{print $3}')
has   "LAUNCHPERSONAL typed /onboard"     "/onboard"                  "$(pane_text "$EPS_ID")"
hasnt "LAUNCHPERSONAL exports no seat"    "export CLAUDE_CONFIG_DIR=" "$(pane_text "$EPS_ID")"

# --- an EXISTING window is switched to and NOTHING else --------------------
# A warm seat is not re-onboarded: /onboard into a live session is a context
# reset nobody asked for. Two verdicts have been logged so far; a third would
# mean this visit launched.
BEFORE_V=$(grep -c 'PULSE_INJECT_RESULT=' "$LAUNCHLOG")
BEFORE_TEXT=$(pane_text "$DELTA_ID")
OUT=$(hall_launching delta 2>"$ERR"); RC=$?
sleep 2
eq    "LAUNCHWARM rc"                 0              "$RC"
hasnt "LAUNCHWARM did not materialize" "materialized" "$OUT"
hasnt "LAUNCHWARM did not say launching" "launching"  "$(cat "$ERR")"
eq    "LAUNCHWARM no new injector run" "$BEFORE_V"    "$(grep -c 'PULSE_INJECT_RESULT=' "$LAUNCHLOG")"
eq    "LAUNCHWARM the pane is untouched" "$BEFORE_TEXT" "$(pane_text "$DELTA_ID")"

# --- --no-launch: the escape hatch, and the attach hook's choice ------------
BEFORE_V=$(grep -c 'PULSE_INJECT_RESULT=' "$LAUNCHLOG")
OUT=$(hall_launching --no-launch zeta 2>"$ERR"); RC=$?
eq  "NOLAUNCH rc"              0              "$RC"
has "NOLAUNCH materialized"    "materialized" "$OUT"
has "NOLAUNCH says why"        "nothing started" "$(cat "$ERR")"
sleep 1
eq  "NOLAUNCH ran no injector" "$BEFORE_V" "$(grep -c 'PULSE_INJECT_RESULT=' "$LAUNCHLOG")"
ZETA_ID=$(wins | awk -F'\t' '$2=="zeta"{print $3}')
hasnt "NOLAUNCH the pane is a bare shell" "cat" \
      "$(tm "$SOCK" display-message -p -t "$ZETA_ID" '#{pane_current_command}')"

# The tmux.conf attach hook must USE that escape hatch: it fires on a machine
# event (boot, a resurrect restore), and starting a Claude session — spending a
# tap — off a machine event rather than a human's request is what the hall's
# charter avoids. This is the DECISION, asserted rather than commented.
has "NOLAUNCHHOOK the attach hook passes HALL_NO_LAUNCH" "HALL_NO_LAUNCH=1" \
    "$(awk '/# HALL-BLOCK-BEGIN/{f=1; next} /# HALL-BLOCK-END/{f=0} f' "$ROOT/tmux/tmux.conf" | grep session-created)"

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
# key everyone reaches for is a trap).
for KEYS in $'\e' $'\e[A'; do
  tm "$SOCK" select-window -t "$BETA_ID" 2>"$ERR"
  OUT=$(prompt_with "$KEYS"); RC=$?
  eq "PROMPTESC rc"        0      "$RC"
  eq "PROMPTESC stays put" "beta" "$(cur_win_name sess-a)"
  hasnt "PROMPTESC visits nothing" "materialized" "$OUT"
done

# ===========================================================================
# THE RAW INPUT LOOP (dotfiles-hnhl) — three live bugs, one root cause
# ===========================================================================
# Zig, 2026-08-09, on his phone and his desktop. The prompt used to read the
# FIRST keystroke raw and the REST through `read -r`, and all three of these are
# that split, not three separate mistakes:
#   1. backspace could never erase the first character, so the buffer could not
#      return to the empty state Enter closes on;
#   2. Esc typed instead of closing once anything was in the buffer;
#   3. any arrow key on an empty buffer closed the popup (the bare \e matched
#      before `[A` arrived).
# `read -sn1` reads from a pipe, so every one of them is a byte string on stdin.

# --- BUG 1: the first typed character is erasable --------------------------
# The tell is NOT the exit code — the old code also exited 0 here, having
# submitted the undeletable `a` and the two DEL bytes as a seat name. It is that
# NOTHING WAS SUBMITTED: an empty buffer at Enter closes silently, so a `no seat`
# refusal on stderr is proof the erase did not reach the first character.
tm "$SOCK" select-window -t "$BETA_ID" 2>"$ERR"
OUT=$(prompt_with $'a\177\177\n'); RC=$?
eq    "PROMPTBKSP rc"                    0      "$RC"
eq    "PROMPTBKSP stays put"             "beta" "$(cur_win_name sess-a)"
hasnt "PROMPTBKSP submitted nothing"     "no seat" "$(cat "$ERR")"
hasnt "PROMPTBKSP visited nothing"       "materialized" "$OUT"
# Backspace at an EMPTY buffer is a no-op, never a close and never an erase into
# the prompt itself: the DELs below are followed by a real name that must still
# be read.
tm "$SOCK" select-window -t "$BETA_ID" 2>"$ERR"
OUT=$(prompt_with $'\177\177alpha\n'); RC=$?
eq "PROMPTBKSPFLOOR rc"                0          "$RC"
eq "PROMPTBKSPFLOOR the prompt survived an empty backspace" "🧠 alpha" "$(cur_win_name sess-a)"

# --- BUG 3: an arrow key is not a close ------------------------------------
# Two arrows, then Enter on the still-empty buffer. `[A` must not land in the
# buffer either (the sequence is swallowed WHOLE), which a `no seat '[A[B'`
# refusal would report.
tm "$SOCK" select-window -t "$BETA_ID" 2>"$ERR"
OUT=$(prompt_with $'\e[A\e[B\n'); RC=$?
eq    "PROMPTARROW rc"                0      "$RC"
eq    "PROMPTARROW stays put"         "beta" "$(cur_win_name sess-a)"
hasnt "PROMPTARROW typed nothing"     "no seat" "$(cat "$ERR")"
# …and the popup was still OPEN afterwards, which is the half an exit code
# cannot show: the name typed AFTER the arrows must still visit.
tm "$SOCK" select-window -t "$BETA_ID" 2>"$ERR"
OUT=$(prompt_with $'\e[A\e[Balpha\n'); RC=$?
eq "PROMPTARROWLIVE rc"                    0          "$RC"
eq "PROMPTARROWLIVE the prompt survived the arrows" "🧠 alpha" "$(cur_win_name sess-a)"

# --- BUG 2: the BARE Esc closes with text in the buffer --------------------
# This one needs a PAUSE, and the pause is the mechanism under test: ESC + more
# bytes is an escape sequence, ESC alone is the key. On a pipe every byte is
# available at once, so `ab<ESC>` followed immediately by anything is
# indistinguishable from Alt-<key> — a FIFO with a real gap is the only honest
# fixture. The bytes after the gap are a working visit, so a prompt that ignored
# or typed the Esc lands on alpha and this case says so.
ESCOUT="$BASE/escmid.out"; : > "$ESCOUT"
FIFO2="$BASE/escfifo"; mkfifo "$FIFO2"
(
  exec 3>"$FIFO2"
  # WAIT FOR THE PROMPT rather than sleeping at it: hall renders the whole court
  # (python3 glyph audit included) before its first read, so a fixed delay here
  # is a race that shows up only on a loaded box — and it fails by making the
  # gap below LOOK like an escape sequence, i.e. by silently testing the
  # opposite behaviour.
  for _ in $(seq 1 80); do
    grep -q 'seat>' "$ESCOUT" && break
    sleep 0.25
  done
  printf 'ab\033' >&3
  sleep 2                        # THE GAP is the mechanism: ESC alone is a key.
  printf '\177\177alpha\n' >&3
  sleep 1
  exec 3>&-
) &
tm "$SOCK" select-window -t "$BETA_ID" 2>"$ERR"
env -u TMUX -u TMUX_TMPDIR -u HALL_ONLY_IF_ABSENT \
    SEATS_YML="$ROSTER" HALL_TMUX_SOCKET="$SOCK" HALL_SESSION=sess-a \
    HALL_NO_LAUNCH=1 HALL_REFRESH_SECS=0 \
    bash "$HALL" --interactive < "$FIFO2" > "$ESCOUT" 2>"$ERR"; RC=$?
wait
OUT=$(cat "$ESCOUT")
eq    "PROMPTESCMID rc"                        0      "$RC"
eq    "PROMPTESCMID the bare Esc closed on a full buffer" "beta" "$(cur_win_name sess-a)"
hasnt "PROMPTESCMID submitted nothing"         "no seat" "$(cat "$ERR")"
hasnt "PROMPTESCMID visited nothing"           "materialized" "$OUT"

# --- Ctrl-C closes cleanly -------------------------------------------------
tm "$SOCK" select-window -t "$BETA_ID" 2>"$ERR"
OUT=$(prompt_with $'ab\003'); RC=$?
eq    "PROMPTCTRLC rc"            0      "$RC"
eq    "PROMPTCTRLC stays put"     "beta" "$(cur_win_name sess-a)"
hasnt "PROMPTCTRLC submitted nothing" "no seat" "$(cat "$ERR")"

# --- LIVE REFRESH (dotfiles-hnhl, Zig: "immensely better for watching") -----
# The prompt loop is a watch loop: a keystroke that does not arrive within
# HALL_REFRESH_SECS repaints the court. Driven for real — a window appears on
# the fixture server WHILE the popup is open, and the frames must show it.
# The writer holds the FIFO open for the whole run (a `printf > fifo` at the
# end would block hall's own open until then, and the first frame would never
# paint).
FIFO="$BASE/watchfifo"; mkfifo "$FIFO"
(
  exec 3>"$FIFO"
  sleep 2
  tm "$SOCK" new-window -d -t "=sess-a" -n watchme -c "$BASE" 2>/dev/null
  sleep 3
  printf '\033' >&3
  exec 3>&-
) &
WATCH=$(env -u TMUX -u TMUX_TMPDIR -u HALL_ONLY_IF_ABSENT \
          SEATS_YML="$ROSTER" HALL_TMUX_SOCKET="$SOCK" HALL_SESSION=sess-a \
          HALL_NO_LAUNCH=1 COLUMNS=80 HALL_REFRESH_SECS=1 \
          bash "$HALL" --interactive < "$FIFO" 2>/dev/null); RC=$?
wait
eq "REFRESH rc" 0 "$RC"
# Strip the ANSI positioning so the frames can be read as text.
WCLEAN=$(printf '%s' "$WATCH" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr -d '\r')
FRAMES=$(printf '%s\n' "$WCLEAN" | grep -c 'THE HALL')
if [ "$FRAMES" -ge 3 ]; then ok
else bad "REFRESHFRAMES the court must repaint while open (frames: $FRAMES)"; fi
FIRSTFRAME=$(printf '%s\n' "$WCLEAN" | awk '/THE HALL/{n++} n==1')
LASTFRAME=$(printf '%s\n' "$WCLEAN" | awk 'BEGIN{RS="THE HALL"} END{print}')
hasnt "REFRESHLIVE the first frame predates the window" "watchme" "$FIRSTFRAME"
has   "REFRESHLIVE a later frame shows it"              "watchme" "$LASTFRAME"
# FRAME STABILITY: every repaint is a whole court at the same width, with the
# same column boundaries — a partial or shifted frame is what a naive
# clear-and-redraw produces under a state change.
printf '%s' "$WCLEAN" > "$BASE/watch.out"
WA=$(align_report "$BASE/watch.out")
if [ -z "$WA" ]; then ok; else bad "REFRESHALIGN repainted frames must stay aligned ($WA)"; fi
WW=$(widest "$BASE/watch.out")
if [ "$WW" -le 80 ]; then ok; else bad "REFRESHWIDTH a repaint must respect the width ($WW)"; fi
# The glyph audit is ONCE per process, not once per frame: a warning that
# repeats every second is a warning nobody reads.
WERR=$(env -u TMUX -u TMUX_TMPDIR SEATS_YML="$PLANTED" HALL_TMUX_SOCKET="$SOCK" \
         HALL_SESSION=sess-a HALL_NO_LAUNCH=1 COLUMNS=80 HALL_REFRESH_SECS=1 \
         bash "$HALL" --interactive 2>&1 >/dev/null <<< "$(printf '\033')")
eq "REFRESHAUDIT the glyph warning fires once" 1 "$(printf '%s\n' "$WERR" | grep -c 'GLYPH RULE')"
# `watchme` is deliberately LEFT on the fixture server: no case after this one
# counts windows, and a kill-window here would be the one destructive verb in a
# suite whose whole hygiene rule is that it has none.

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
