#!/bin/bash
# Test for seat-resolve.sh (bead dotfiles-seat-resolve-lib-btti) AND for the
# seat front-matter guard it gives handoff-path.sh (bead dotfiles-tzfr).
# Contract: dotfiles-seat-address-spec-uikg — R5 resolution, R6 reverse-rename,
# R7 socket/session discipline, R8 offline enumeration, R9 foreign lookup,
# R13 session and window as SEPARATE fields.
#
# Convention: executable bash, non-zero exit = failure, PASS/FAIL summary on the
# last line (see test-handoff-path.sh, test-validate-seats.sh).
#
# ⚠️ TMUX HYGIENE — READ BEFORE ADDING A CASE. Every tmux invocation here runs
#   env -u TMUX -u TMUX_TMPDIR tmux -S "$SOCKDIR/<name>" …
# through the tm() wrapper: NEVER a bare `tmux`, and NEVER `kill-server`
# without an explicit -S. This suite runs inside a live tmux session (the
# fleet's own), an inherited $TMUX silently retargets a bare tmux at THAT
# server, and a kill-server there takes down every window on the machine — a
# sibling agent did exactly that on 2026-08-08. The servers this suite starts
# live in their own $SOCKDIR and are killed by socket path on EXIT.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"

PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED+=("$1"); }

# eq <name> <want> <got>
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1 (want [$2] got [$3])"; fi; }
# has <name> <needle> <haystack>
has() { case "$3" in *"$2"*) ok ;; *) bad "$1 (missing [$2] in: $3)" ;; esac; }
# lines <pattern> <text> -> count of matching lines
lines() { printf '%s\n' "$2" | grep -c "$1"; }

TMUX_BIN=$(command -v tmux 2>/dev/null); [ -x "${TMUX_BIN:-}" ] || TMUX_BIN=/usr/bin/tmux
# The ONE place tmux is invoked. Socket-explicit, $TMUX scrubbed.
tm() { env -u TMUX -u TMUX_TMPDIR "$TMUX_BIN" -S "$@"; }

BASE=$(mktemp -d)
SOCKDIR="$BASE/sockets"; mkdir -p "$SOCKDIR"
EMPTYSOCK="$BASE/empty-sockets"; mkdir -p "$EMPTYSOCK"
ERR="$BASE/stderr"
cleanup() {
  local s
  for s in "$SOCKDIR"/*; do
    [ -S "$s" ] || continue
    tm "$s" kill-server >/dev/null 2>&1 || true   # allow-suppress: teardown probe
  done
  rm -rf "$BASE"
}
trap cleanup EXIT

# Isolate the sticky window cache tmux-pane-resolve.sh seeds on every live
# resolution — without this the suite would write the RUNNING session's cache
# entry and hand it a window name that is not its own.
export CLAUDE_LEXICON_STATE_DIR="$BASE/lexicon"
export CLAUDE_CODE_SESSION_ID=""

# --- the fixture roster ----------------------------------------------------
# Small on purpose, but shaped like the real one: an aliased seat with a
# session-qualified binding (alpha), a schedule-less interactive seat (beta),
# and a seat with TWO distinct bindings (gamma) for the R13 ambiguity case.
ROSTER="$BASE/seats.yml"
cat > "$ROSTER" <<'EOF'
schema: 1
hosts: [zig-computer]
charter: null
taps:
  personal:
    type: claude
    config_dir: ~/.claude
    failover: []
seats:
  alpha:
    charter-line: "fixture seat alpha"
    office: "The Alpha"
    sigil: "📜"
    home: ~/alpha
    model: fable
    effort: high
    tap: personal
    aliases: [alpha-old, di]
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
    home: ~/beta
    model: sonnet
    effort: high
    tap: personal
    aliases: []
    history: refs/seats/beta.history.md
    schedules: []
  gamma:
    charter-line: "fixture seat gamma"
    office: "The Gamma"
    sigil: "🧰"
    home: ~/gamma
    model: sonnet
    effort: high
    tap: personal
    # gamma-two: the bi2i rule (schedule windows must resolve to a seat name or
    # alias) landed after this fixture; the alias is the fixture's compliance,
    # and it also exercises alias-window resolution for free.
    aliases: [gamma-two]
    history: refs/seats/gamma.history.md
    schedules:
      - unit: pulse-gamma-one
        tap: personal
        window: gamma
        session: sess-a
      - unit: pulse-gamma-two
        tap: personal
        window: gamma-two
        session: sess-a
  delta:
    charter-line: "fixture seat delta"
    office: "The Delta"
    sigil: "🧾"
    home: ~/delta
    model: sonnet
    effort: high
    tap: personal
    aliases: [delta-old]
    history: refs/seats/delta.history.md
    schedules:
      - unit: pulse-delta
        tap: personal
        window: delta-old
        session: sess-a
EOF

export SEATS_YML="$ROSTER"
export SEAT_TMUX_SOCKET_DIR="$EMPTYSOCK"    # default: NO live server in view
. "$HERE/seat-resolve.sh"

# 0. The fixture must satisfy the real validator, or every case below tests a
# shape the roster could never legally have.
if python3 "$HERE/validate-seats.py" "$ROSTER" >/dev/null 2>"$ERR"; then ok
else bad "fixture roster must pass validate-seats.py ($(cat "$ERR"))"; fi

# --- R8: enumerable with NO tmux server at all -----------------------------
eq "R8 seat_names (offline)" "alpha beta gamma delta" "$(seat_names | tr '\n' ' ' | sed 's/ $//')"
eq "roster path honors SEATS_YML" "$ROSTER" "$(seat_roster_path)"

# --- R5 case 1: exact window name -> that seat, silently -------------------
OUT=$(seat_resolve --window beta --session whatever 2>"$ERR"); RC=$?
eq  "exact rc"          0                "$RC"
has "exact seat"        "seat=beta"      "$OUT"
has "exact match kind"  "match=exact"    "$OUT"
has "exact model"       "model=sonnet"   "$OUT"
has "exact home"        "home=~/beta"    "$OUT"
has "exact history"     "history=refs/seats/beta.history.md" "$OUT"
eq  "exact is silent"   ""               "$(cat "$ERR")"

# --- R5 case 2: an ALIAS resolves to the canonical seat + a migration notice.
# This is the di->pulse rename (bd-msi5) as a regression case: the alias entry
# is the ONLY thing that keeps a renamed window attached to its history.
OUT=$(seat_resolve --window di --session sess-a 2>"$ERR"); RC=$?
eq  "alias rc"            0             "$RC"
has "alias -> canonical"  "seat=alpha"  "$OUT"
has "alias match kind"    "match=alias" "$OUT"
has "alias keeps the matched name" "matched_name=di" "$OUT"
has "alias notice says ALIAS"      "ALIAS" "$(cat "$ERR")"
has "alias notice names the seat"  "alpha" "$(cat "$ERR")"
OUT=$(seat_resolve --window alpha-old --session sess-a 2>"$ERR")
has "second alias also resolves" "seat=alpha" "$OUT"
# The linearb / di-monday shape: an alias that is ALSO a session-qualified
# binding window. Both rules apply, in that order.
OUT=$(seat_resolve --window delta-old --session sess-a 2>"$ERR"); RC=$?
eq  "bound alias rc"     0             "$RC"
has "bound alias seat"   "seat=delta"  "$OUT"
has "bound alias kind"   "match=alias" "$OUT"
OUT=$(seat_resolve --window delta-old --session sess-b 2>"$ERR"); RC=$?
eq  "bound alias in the WRONG session refuses" 3  "$RC"
eq  "bound alias refusal emits nothing"        "" "$OUT"
has "bound alias refusal cites R7" "R7" "$(cat "$ERR")"

# --- R5 case 3: UNREGISTERED -> loud refusal, exit 3, NOTHING on stdout ----
OUT=$(seat_resolve --window nosuchwindow --session sess-a 2>"$ERR"); RC=$?
eq  "unregistered rc is 3"          3    "$RC"
eq  "unregistered stdout is empty"  ""   "$OUT"
has "unregistered says so"          "NOT a registered seat" "$(cat "$ERR")"
has "unregistered names the window" "nosuchwindow"          "$(cat "$ERR")"
has "unregistered lists the seats"  "alpha"                 "$(cat "$ERR")"
has "unregistered points at aliases" "aliases"              "$(cat "$ERR")"
# --quiet silences the diagnostic but NEVER the refusal.
OUT=$(seat_resolve --quiet --window nosuchwindow 2>"$ERR"); RC=$?
eq "quiet still refuses" 3  "$RC"
eq "quiet is silent"     "" "$(cat "$ERR")"

# --- R13: session and window are SEPARATE FIELDS ---------------------------
# An address is never a tmux -t target; a consumer must build one from the two
# fields. Assert both lines exist and that no combined form is emitted.
OUT=$(seat_resolve --window alpha --session sess-a 2>"$ERR")
has "R13 session field"  "session=sess-a" "$OUT"
has "R13 window field"   "window=alpha"  "$OUT"
case "$OUT" in *"sess-a:alpha"*) bad "R13 must never emit a combined session:window" ;; *) ok ;; esac
eq "R13 exactly one session= line" 1 "$(lines '^session=' "$OUT")"
eq "R13 exactly one window= line"  1 "$(lines '^window='  "$OUT")"

# --- R7: the binding's session qualifies the lookup ------------------------
OUT=$(seat_resolve --window alpha --session sess-a 2>"$ERR"); RC=$?
eq  "R7 right session resolves" 0            "$RC"
has "R7 right session -> alpha" "seat=alpha" "$OUT"
OUT=$(seat_resolve --window alpha --session sess-b 2>"$ERR"); RC=$?
eq  "R7 wrong session refuses"       3  "$RC"
eq  "R7 wrong session emits nothing" "" "$OUT"
has "R7 refusal names the bound session" "sess-a" "$(cat "$ERR")"
has "R7 refusal names this session"      "sess-b" "$(cat "$ERR")"
has "R7 refusal cites the rule"          "R7"     "$(cat "$ERR")"
# A seat with NO schedule has no session to qualify against -> resolves anywhere.
OUT=$(seat_resolve --window beta --session sess-zzz 2>"$ERR"); RC=$?
eq "R7 schedule-less seat is session-agnostic" 0 "$RC"

# --- R9: foreign lookup, roster row + liveness, with no tmux server --------
OUT=$(seat_resolve --seat alpha 2>"$ERR"); RC=$?
eq  "foreign rc"              0                  "$RC"
has "foreign seat"            "seat=alpha"       "$OUT"
has "foreign model"           "model=fable"      "$OUT"
has "foreign office"          "office=The Alpha" "$OUT"
has "foreign history"         "history=refs/seats/alpha.history.md" "$OUT"
has "foreign aliases"         "aliases=alpha-old di"       "$OUT"
has "foreign bindings count"  "bindings=1"                 "$OUT"
has "foreign binding unit"    "binding_1_unit=pulse-alpha" "$OUT"
has "foreign binding tap"     "binding_1_tap=personal"     "$OUT"
has "foreign binding session" "binding_1_session=sess-a"   "$OUT"
has "foreign binding window"  "binding_1_window=alpha"    "$OUT"
has "foreign liveness (no server)" "live=no" "$OUT"
eq  "foreign is silent"       ""             "$(cat "$ERR")"
# R13 on the foreign path: unambiguous -> a bare pair; ambiguous -> none.
eq "foreign unambiguous session (line-anchored)" 1 "$(lines '^session=sess-a$' "$OUT")"
eq "foreign unambiguous window (line-anchored)"  1 "$(lines '^window=alpha$'   "$OUT")"
# THE SEAT'S OWN TAP (Zig, 2026-08-09): every seat declares the tap it draws
# from, so a consumer never has to infer one from the schedules — and a
# schedule-less seat has an answer at all, which is the whole point of the
# ruling. It is field 10 of the seat record, APPENDED, so `home` and `sigil`
# below must still be exactly where they were.
has "seat emits its own tap" "tap=personal" "$OUT"
has "appending tap did not shift home"  "home=~/alpha" "$OUT"
has "appending tap did not shift sigil" "sigil=📜"     "$OUT"
# …and the TAP TABLE is in the dump, so a launcher can get the config_dir
# without a second reader of seats.yml.
DUMP=$(_seat_dump)
eq "tap table carries the config dir" "~/.claude" "$(_seat_tap_config_dir personal "$DUMP")"
eq "an unknown tap has no config dir" ""          "$(_seat_tap_config_dir nosuchtap "$DUMP")"

OUT=$(seat_resolve --seat gamma 2>"$ERR")
has "gamma has two bindings" "bindings=2" "$OUT"
eq  "R13 ambiguous seat emits NO bare session" 0 "$(lines '^session=' "$OUT")"
eq  "R13 ambiguous seat emits NO bare window"  0 "$(lines '^window='  "$OUT")"

OUT=$(seat_resolve --seat nosuchseat 2>"$ERR"); RC=$?
eq  "unknown seat rc is 3"          3        "$RC"
eq  "unknown seat stdout is empty"  ""       "$OUT"
has "unknown seat names the roster" "$ROSTER" "$(cat "$ERR")"

# --- usage errors get their own exit code ----------------------------------
OUT=$(seat_resolve --nope 2>"$ERR"); RC=$?
eq "unknown flag rc is 2" 2 "$RC"
OUT=$(seat_resolve --seat 2>"$ERR"); RC=$?
eq "missing --seat value rc is 2" 2 "$RC"

# --- no roster at all -> refusal, never a guess ----------------------------
OUT=$(SEATS_YML="$BASE/does-not-exist.yml" seat_resolve --window beta 2>"$ERR"); RC=$?
eq  "no roster rc is 3" 3                 "$RC"
has "no roster says so" "no roster found" "$(cat "$ERR")"

# ===========================================================================
# REAL TMUX SERVERS — each starts on its own socket under $SOCKDIR.
# ===========================================================================
SOCK1="$SOCKDIR/one"
SOCK2="$SOCKDIR/two"

# self <socket> <server-pid> <pane> — self-resolution as a LIVE session sees it:
# nothing but $TMUX and $TMUX_PANE, in a subshell so the exports cannot leak.
self() ( export TMUX="$1,$2,0" TMUX_PANE="$3" SEAT_TMUX_SOCKET_DIR="$SOCKDIR"; seat_resolve )

if [ -x "$TMUX_BIN" ]; then
  tm "$SOCK1" new-session -d -s sess-a -n alpha -c "$BASE" 2>"$ERR"
  tm "$SOCK1" rename-window -t sess-a:0 "🧠 alpha" 2>"$ERR"
  PANE=$(tm "$SOCK1" display-message -p -t sess-a:0 '#{pane_id}' 2>"$ERR")
  SRVPID=$(tm "$SOCK1" display-message -p '#{pid}' 2>"$ERR")

  # Self-resolution end to end, through the wrapped tmux-pane-resolve.sh, with
  # a lexicon glyph on the window name.
  OUT=$(self "$SOCK1" "$SRVPID" "$PANE" 2>"$ERR"); RC=$?
  eq  "live self rc"      0                "$RC"
  has "live self seat"    "seat=alpha"     "$OUT"
  has "live self window (glyph stripped)" "window=alpha" "$OUT"
  has "live self session" "session=sess-a" "$OUT"
  has "live self socket"  "socket=$SOCK1"  "$OUT"

  # Foreign lookup SEES the live window (R9 liveness).
  OUT=$(SEAT_TMUX_SOCKET_DIR="$SOCKDIR" seat_resolve --seat alpha 2>"$ERR")
  has "foreign liveness yes"     "live=yes"              "$OUT"
  has "foreign liveness socket"  "live_1_socket=$SOCK1"  "$OUT"
  has "foreign liveness session" "live_1_session=sess-a" "$OUT"
  has "foreign liveness window"  "live_1_window=alpha"  "$OUT"

  # R7 / dotfiles-2v8h: a SECOND server holding the SAME (session, window)
  # tuple makes the tuple non-unique machine-wide. `--seat` must refuse and
  # name both sockets; SELF-resolution inside server one must be UNAFFECTED
  # (spec test case 5 — self-resolution never searches other sockets).
  tm "$SOCK2" new-session -d -s sess-a -n alpha -c "$BASE" 2>"$ERR"
  OUT=$(SEAT_TMUX_SOCKET_DIR="$SOCKDIR" seat_resolve --seat alpha 2>"$ERR"); RC=$?
  eq  "dup tuple rc is 3"          3  "$RC"
  eq  "dup tuple stdout is empty"  "" "$OUT"
  has "dup tuple names socket one" "$SOCK1"          "$(cat "$ERR")"
  has "dup tuple names socket two" "$SOCK2"          "$(cat "$ERR")"
  has "dup tuple names the tuple"  "window 'alpha'" "$(cat "$ERR")"
  OUT=$(self "$SOCK1" "$SRVPID" "$PANE" 2>"$ERR"); RC=$?
  eq  "self UNAFFECTED by the duplicate" 0 "$RC"
  has "self still resolves to alpha" "seat=alpha" "$OUT"
  tm "$SOCK2" kill-server >/dev/null 2>&1 || true   # allow-suppress: teardown
else
  bad "tmux binary missing — the R7 socket cases could not run"
fi

# ===========================================================================
# handoff-path.sh, btti half — the UNREGISTERED-WINDOW refusal. _handoff_key
# stays byte-identical (the seat work adds diagnostics, it never moves a file);
# what changes is that the missing-note diagnostic now says whether this window
# is a seat at all, which is the usual upstream cause of a missing note.
# ===========================================================================
. "$HERE/handoff-path.sh"

DIR="$BASE/proj"; mkdir -p "$DIR/refs" "$DIR/.claude"
touch "$DIR/refs/.handoff-per-window"        # per-window scoping opted in
NOTE="$DIR/refs/session-handoff--alpha.md"
WNOTE="$DIR/refs/session-handoff--wintest.md"

# In window `alpha` of session sess-a, i.e. seat alpha. Subshell + export so
# the vars reach the tmux/python children and cannot leak into later cases.
as_alpha()  ( export HANDOFF_WINDOW=alpha   SEAT_SESSION=sess-a; "$@" )
as_nobody() ( export HANDOFF_WINDOW=wintest SEAT_SESSION=sess-a; "$@" )

eq "_handoff_key unchanged (registered)"   "alpha"   "$(as_alpha _handoff_key)"
eq "_handoff_key unchanged (unregistered)" "wintest" "$(as_nobody _handoff_key)"
eq "handoff_path unchanged" "$NOTE" "$(as_alpha handoff_path "$DIR")"

# No notes exist yet, so both reads take the MISSING-note branch.
OUT=$(as_nobody handoff_read_path "$DIR" 2>"$ERR")
has "missing note still warns"        "NO note for this window"  "$(cat "$ERR")"
has "missing note names the seat gap" "is NOT a registered seat" "$(cat "$ERR")"
OUT=$(as_alpha handoff_read_path "$DIR" 2>"$ERR")
has "missing note for a REAL seat says which seat" 'seat "alpha"' "$(cat "$ERR")"

# --- TZFR-SECTION-BEGIN -----------------------------------------------------
# ===========================================================================
# dotfiles-tzfr — the REVERSE-RENAME guard in handoff-path.sh.
# Mechanism (agreed with this lib, not invented in parallel): the note carries
# its owner in front matter; the reader compares it to the resolved seat.
# ===========================================================================

# WRITE side: the note gets seat: front matter, idempotently.
printf 'body line\n' > "$NOTE"
as_alpha handoff_stamp_seat "$NOTE"
eq  "stamp writes the seat"     "alpha"         "$(_handoff_note_seat "$NOTE")"
has "stamp keeps the body"      "body line"     "$(cat "$NOTE")"
has "stamp records the window"  "window: alpha" "$(cat "$NOTE")"
as_alpha handoff_stamp_seat "$NOTE"
eq "stamp is idempotent (one front-matter block)" 2 "$(grep -c '^---$' "$NOTE")"
eq "stamp is idempotent (body intact)" "body line" "$(tail -1 "$NOTE")"
# A window with no seat must never stamp a guessed owner.
printf 'body line\n' > "$WNOTE"
if as_nobody handoff_stamp_seat "$WNOTE"; then bad "stamp must refuse without a seat"; else ok; fi
eq "refused stamp leaves the file alone" "body line" "$(cat "$WNOTE")"

# READ, matching seat -> served, silently.
OUT=$(as_alpha handoff_read_path "$DIR" 2>"$ERR"); RC=$?
eq "matching seat rc"     0       "$RC"
eq "matching seat serves" "$NOTE" "$OUT"
eq "matching seat silent" ""      "$(cat "$ERR")"

# THE BUG (dotfiles-tzfr): a window renamed ONTO a name that already has a
# note. The note belongs to seat beta; this window resolves to seat alpha.
# Before the fix, handoff_read_path found the file and served it with NO
# diagnostic whatsoever — these five assertions are what fail against that.
printf -- '---\nseat: beta\nsession: sess-a\nwindow: alpha\n---\nbeta private notes\n' > "$NOTE"
OUT=$(as_alpha handoff_read_path "$DIR" 2>"$ERR"); RC=$?
eq  "reverse rename refuses (rc)"         3  "$RC"
eq  "reverse rename serves NOTHING"       "" "$OUT"
has "reverse rename is loud"              "ANOTHER SEAT" "$(cat "$ERR")"
has "reverse rename names the note owner" "beta"         "$(cat "$ERR")"
has "reverse rename names this seat"      "alpha"        "$(cat "$ERR")"

# R6 as amended: an ABSENT seat: is never an error. Serve it, and say once that
# it predates the migration.
printf 'a pre-migration note with no front matter\n' > "$NOTE"
OUT=$(as_alpha handoff_read_path "$DIR" 2>"$ERR"); RC=$?
eq  "absent front matter rc"             0       "$RC"
eq  "absent front matter serves"         "$NOTE" "$OUT"
has "absent front matter notices"        "no seat: front matter" "$(cat "$ERR")"
has "absent front matter names the seat" "alpha"                 "$(cat "$ERR")"

# A note that names an owner, read from a window with NO seat: unverifiable, so
# refused rather than silently served.
printf -- '---\nseat: alpha\n---\nalpha notes\n' > "$WNOTE"
OUT=$(as_nobody handoff_read_path "$DIR" 2>"$ERR"); RC=$?
eq  "unregistered + owned note refuses"        3  "$RC"
eq  "unregistered + owned note serves nothing" "" "$OUT"
has "unregistered + owned note is loud" "HAS NO SEAT" "$(cat "$ERR")"

# Unregistered window with a PLAIN note keeps the pre-seat behavior exactly:
# served, silent. A shared lib must not start shouting in every project whose
# windows have no roster row yet.
printf 'plain note\n' > "$WNOTE"
OUT=$(as_nobody handoff_read_path "$DIR" 2>"$ERR"); RC=$?
eq "unregistered + plain note rc"     0        "$RC"
eq "unregistered + plain note serves" "$WNOTE" "$OUT"
eq "unregistered + plain note silent" ""       "$(cat "$ERR")"

# No roster (a project on a machine with no seats.yml) -> the guard is inert
# and every path is byte-identical to the pre-seat lib.
printf -- '---\nseat: beta\n---\nbeta notes\n' > "$NOTE"
OUT=$( export SEATS_YML="$BASE/does-not-exist.yml" HANDOFF_WINDOW=alpha
       handoff_read_path "$DIR" 2>"$ERR" ); RC=$?
eq "no roster -> serves as before" "$NOTE" "$OUT"
eq "no roster -> rc 0"             0       "$RC"
eq "no roster -> silent"           ""      "$(cat "$ERR")"
# --- TZFR-SECTION-END -------------------------------------------------------

TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then echo "PASS: $PASS/$TOTAL test cases"; exit 0; fi
echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED[@]}"; do echo "  - $n"; done
exit 1
