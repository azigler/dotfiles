#!/bin/bash
# test-seat-molt.sh — regression suite for seat-molt.sh (dotfiles-it06).
#
# Hermetic: a PRIVATE tmux server addressed by an ABSOLUTE SOCKET PATH inside
# this run's temp dir, a fake project tree, a fake ledger, and a pane that runs
# `cat >> <file>` so every keystroke this script types is RECORDED rather than
# executed. Nothing here can reach the live server or type into a real seat.
#
# WHY -S <path> AND NOT -L <name>. `-L` is resolved through $TMUX_TMPDIR, i.e.
# through the environment — the exact precedence that took the live server down
# on 2026-08-09 (dotfiles-2v8h). `-S` with an absolute path takes the decision
# away from the environment entirely, which is also what seat-molt.sh does in
# production. Every invocation additionally strips TMUX/TMUX_TMPDIR, so nothing
# here can EVER be read as depending on ambient env for its socket. Cleanup is
# socket-scoped `kill-server` + an explicit `rm -f` of the socket file — never a
# bare `tmux kill-server`, which would take Zig's session with it.
#
# THE CASE IDS ARE A CONTRACT. mutate-seat-molt.sh asserts that each mutant dies
# on the case(s) it NAMES, and it reads those names out of the `  - <id> …`
# lines this suite prints on failure. Renumbering a case means updating that
# harness — a mutant that dies on the wrong case is not a kill.
#
# Usage: bash agents/scheduler/test-seat-molt.sh     (exit 0 = all pass)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/seat-molt.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/moltsuite.XXXXXX")
SOCKPATH="$T/tmux.sock"
TM=(env -u TMUX -u TMUX_TMPDIR tmux -S "$SOCKPATH")

cleanup() {
  "${TM[@]}" kill-server 2>/dev/null   # allow-suppress: socket-scoped, no server is normal
  rm -f "$SOCKPATH"
  rm -rf "$T"
}
trap cleanup EXIT

PASS=0; FAIL=0
FAILED_NAMES=()
ok()  { PASS=$((PASS+1)); printf '  ok   %s %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1 $2"); printf '  FAIL %s %s\n' "$1" "$2"; }

# --- fixtures ---------------------------------------------------------------
PROJ="$T/proj"
mkdir -p "$PROJ/.claude"
LEDGER="$T/molt-ledger.jsonl"

# The pane program: paint the composer's input-ready marker, then swallow (and
# RECORD) everything typed at it. A real Claude pane would execute nothing we
# type; this records it instead, which is how "typed NOTHING" is asserted.
cat > "$T/pane.sh" <<'PANE'
#!/bin/bash
[ -n "${MOLT_TEST_MARKER:-}" ] && printf '%s\n' "$MOLT_TEST_MARKER"
cat >> "$1"
PANE
chmod +x "$T/pane.sh"

# HERMETICITY, and it cost a mis-kill to find. `--self` takes its Claude session
# id from $CLAUDE_CODE_SESSION_ID, and the offboard marker must NAME that id —
# so inside a Claude Code session (where the variable is set) the suite behaves
# differently than in a human's shell. Measured 2026-08-09 while building
# mutate-seat-molt.sh: case 23 refused with "does not name session
# 2cc9586e-…" — the AGENT's own id, leaked in from the environment — the pane
# was left untouched for the WRONG reason, and the M4 mutant read as a mis-kill.
# Pin it to the id fresh_offboard writes; pin the pct dir for the same reason.
export CLAUDE_CODE_SESSION_ID=sess-abc
export CONTEXT_GUARD_STATE_DIR="$T/pct"
export MOLT_LEDGER="$LEDGER"
export MOLT_LOG="$T/molt.log"
export MOLT_POLL=0.2
export MOLT_IDLE_STABLE=2
export MOLT_IDLE_TIMEOUT=6
export MOLT_CLEAR_SETTLE=0.3
export MOLT_COMPACT_GRACE=0.3
export MOLT_COMPACT_TIMEOUT=6
export MOLT_SELF_IDLE_TIMEOUT=2
# The turn-end signal --self reads instead of pane-text stability (dotfiles-ygf8).
# Isolated per-run, exactly like the ledger above.
export HARNESS_STATE_DIR="$T/state"
TURN_END_DIR="$HARNESS_STATE_DIR/turn-end"

TYPED=""
SESS=""
WID=""
# mk_pane <session> <window-name> [marker]
#   A detached session whose single window carries <window-name> verbatim
#   (glyph included) and whose pane records keystrokes to $TYPED.
#
#   The pane runs pane.sh DIRECTLY (new-session's command argument), not a login
#   shell: this box's zsh rc itself talks to tmux, and an interactive shell in a
#   fixture pane spawns sessions on the fixture server and paints its own noise
#   into the pane the assertions read.
#
#   TARGETS ARE WINDOW IDS. `-t "=<session>"` is a target-SESSION form; tmux 3.5a
#   rejects it as a pane/window target ("can't find pane: =molty1") — measured
#   while writing this suite, and it fails SILENTLY into "the pane never became
#   ready". Resolve the window id once and address `@N` / `@N.0`, which is the
#   same discipline seat-molt.sh itself follows (R13).
mk_pane() {
  SESS=$1
  TYPED="$T/typed.$1"
  : > "$TYPED"
  "${TM[@]}" new-session -d -s "$1" -n "$2" -x 200 -y 50 -c "$T" \
    "MOLT_TEST_MARKER=$(printf '%q' "${3:-? for shortcuts}") bash $T/pane.sh $TYPED"
  WID=$("${TM[@]}" list-windows -t "=$1" -F '#{window_id}' | head -1)
  # automatic-rename would relabel the window after the running command and
  # silently destroy the lexicon glyph this suite is asserting on.
  "${TM[@]}" set-window-option -t "$WID" automatic-rename off >/dev/null
  # Wait until the marker is actually on screen, so an idle-wait case is never
  # racing the fixture's own startup.
  local n=0
  while [ "$n" -lt 200 ]; do
    "${TM[@]}" capture-pane -p -t "$WID.0" | grep -qF "${3:-? for shortcuts}" && break
    n=$((n+1)); sleep 0.05
  done
  "${TM[@]}" rename-window -t "$WID" "$2"
}
kill_pane() { [ -n "$SESS" ] && "${TM[@]}" kill-session -t "=$SESS" 2>/dev/null; SESS=""; }  # allow-suppress: already-gone is fine

fresh_offboard() { printf '%s\n' "${1:-sess-abc}" > "$PROJ/.claude/last-offboard-session"; }
no_offboard()    { rm -f "$PROJ/.claude/last-offboard-session"; }
age_offboard()   { # <seconds ago>
  . "$HERE/../hooks/lib/portable.sh"
  _p_touch_at "$(( $(date +%s) - $1 ))" "$PROJ/.claude/last-offboard-session"
}
reset_ledger()   { : > "$LEDGER"; }

# turn_end_fresh/stale/no_turn_end <session_id=sess-abc> — the stamp
# seat-molt.sh --self reads instead of pane-text stability (dotfiles-ygf8).
turn_end_fresh() { mkdir -p "$TURN_END_DIR"; : > "$TURN_END_DIR/${1:-sess-abc}"; }
turn_end_stale() { # <session_id=sess-abc> — older than any t0 this suite can produce
  . "$HERE/../hooks/lib/portable.sh"
  mkdir -p "$TURN_END_DIR"
  _p_touch_at "$(( $(date +%s) - 3600 ))" "$TURN_END_DIR/${1:-sess-abc}"
}
no_turn_end() { rm -f "$TURN_END_DIR/${1:-sess-abc}"; }

OUT=""; RC=0; VERDICT=""
molt() { OUT=$("$SCRIPT" --socket "$SOCKPATH" --dir "$PROJ" "$@" 2>&1); RC=$?
         VERDICT=$(printf '%s\n' "$OUT" | grep -o 'SEAT_MOLT_RESULT=[a-z-]*' | tail -1); }

want_verdict() { # <id> <desc> <expected>
  if [ "$VERDICT" = "SEAT_MOLT_RESULT=$3" ]; then ok "$1" "$2"
  else bad "$1" "$2 -- got '${VERDICT:-<none>}' rc=$RC"; fi
}
want_typed() { # <id> <desc> <needle>
  if grep -qF "$3" "$TYPED"; then ok "$1" "$2"; else bad "$1" "$2 -- '$3' was never typed"; fi
}
want_untouched() { # <id> <desc>
  if [ -s "$TYPED" ]; then bad "$1" "$2 -- typed: $(tr '\n' ' ' < "$TYPED")"; else ok "$1" "$2"; fi
}

echo "== seat-molt.sh regression suite"

# --- 1-5: argument handling -------------------------------------------------
bash -n "$SCRIPT" && ok 1 "bash -n parses" || bad 1 "bash -n"

OUT=$("$SCRIPT" --socket "$SOCKPATH" --target s w 2>&1); RC=$?
VERDICT=$(printf '%s\n' "$OUT" | grep -o 'SEAT_MOLT_RESULT=[a-z-]*' | tail -1)
want_verdict 2 "--mode is required" failed-usage

molt --target s w --mode auto
want_verdict 3 "--mode auto without --in-flight refuses (only the agent knows)" failed-usage

OUT=$("$SCRIPT" --socket "$SOCKPATH" --target lonely --mode molt 2>&1); RC=$?
VERDICT=$(printf '%s\n' "$OUT" | grep -o 'SEAT_MOLT_RESULT=[a-z-]*' | tail -1)
want_verdict 4 "--target needs BOTH session and window" failed-usage

molt --target nosuch nowindow --mode molt
want_verdict 5 "an absent session/window is failed-no-window" failed-no-window

# --- 6-7: the happy path ----------------------------------------------------
echo
echo "-- the cycle"
reset_ledger; fresh_offboard; mk_pane molty1 "✅ seat"
molt --target molty1 seat --mode molt --pct 78
want_verdict 6 "idle pane + fresh offboard -> molted" molted
want_typed   6b "/clear was typed" "/clear"
want_typed   6c "/onboard was typed" "/onboard"
if grep -q '"session":"molty1"' "$LEDGER" && grep -q '"window":"seat"' "$LEDGER" \
   && grep -q '"mode":"molt"' "$LEDGER" && grep -q '"result":"molted"' "$LEDGER" \
   && grep -q '"pct":78' "$LEDGER"; then ok 7 "ledger row carries ts/session/window/mode/pct/result"
else bad 7 "ledger row: $(tail -1 "$LEDGER")"; fi
kill_pane

# --- 8-9: the idle wait -----------------------------------------------------
echo
echo "-- rail 1: idle-wait"
reset_ledger; fresh_offboard; mk_pane molty2 "🧠 seat"
( sleep 1; "${TM[@]}" rename-window -t "$WID" "✅ seat" ) &
_flip=$!
molt --target molty2 seat --mode molt
wait "$_flip" 2>/dev/null   # allow-suppress: the flipper is done either way
want_verdict 8 "a busy pane that goes idle mid-wait is molted (the WAIT works)" molted
kill_pane

reset_ledger; fresh_offboard; mk_pane molty3 "🧠 seat"
MOLT_IDLE_TIMEOUT=2 molt --target molty3 seat --mode molt
want_verdict   9 "a pane that never goes idle is aborted-not-idle" aborted-not-idle
want_untouched 9n "the never-idle pane was typed into NOT AT ALL"
kill_pane

# --- 10-11: the modal abort -------------------------------------------------
echo
echo "-- rail 2: modal abort"
reset_ledger; fresh_offboard; mk_pane molty4 "🔔 seat"
MOLT_IDLE_TIMEOUT=2 molt --target molty4 seat --mode molt
want_verdict   10 "a 🔔 window aborts (never send-keys into a dialog)" aborted-modal
want_untouched 10n "the 🔔 pane was typed into NOT AT ALL"
kill_pane

reset_ledger; fresh_offboard; mk_pane molty5 "✅ seat" "Do you want to proceed?"
MOLT_IDLE_TIMEOUT=2 molt --target molty5 seat --mode molt
want_verdict   11 "an in-pane dialog aborts even with an idle glyph" aborted-modal
want_untouched 11n "the dialog pane was typed into NOT AT ALL"
kill_pane

# --- 12-16: offboard freshness ----------------------------------------------
echo
echo "-- rail 3: offboard freshness"
reset_ledger; no_offboard; mk_pane molty6 "✅ seat"
molt --target molty6 seat --mode molt
want_verdict   12 "no offboard marker -> refused-not-offboarded" refused-not-offboarded
want_untouched 12n "an un-offboarded pane was typed into NOT AT ALL"
kill_pane

reset_ledger; fresh_offboard; age_offboard 7200; mk_pane molty7 "✅ seat"
molt --target molty7 seat --mode molt
want_verdict   13 "a 2h-old offboard is NOT fresh -> refused" refused-not-offboarded
want_untouched 13n "the stale-offboard pane was typed into NOT AT ALL"
kill_pane

reset_ledger; fresh_offboard "sess-OTHER"; mk_pane molty8 "✅ seat"
molt --target molty8 seat --mode molt --session-id sess-MINE
want_verdict 14 "a marker naming another session does not release" refused-not-offboarded
kill_pane

reset_ledger; fresh_offboard "sess-MINE"; mk_pane molty9 "✅ seat"
molt --target molty9 seat --mode molt --session-id sess-MINE
want_verdict 15 "a fresh marker naming THIS session releases" molted
kill_pane

reset_ledger; no_offboard; mk_pane moltyA "✅ seat"
molt --target moltyA seat --mode compact
want_verdict   16 "COMPACT also demands a fresh offboard (compaction is lossy)" refused-not-offboarded
want_untouched 16n "the un-offboarded compact target was typed into NOT AT ALL"
kill_pane

# --- 17-18: mode auto -------------------------------------------------------
echo
echo "-- mode auto: the agent states its in-flight status"
reset_ledger; fresh_offboard; mk_pane moltyB "✅ seat"
molt --target moltyB seat --mode auto --in-flight no
want_verdict 17 "auto + nothing in flight -> MOLT (/clear)" molted
want_typed   17b "auto/no typed /clear" "/clear"
kill_pane

reset_ledger; fresh_offboard; mk_pane moltyC "✅ seat"
molt --target moltyC seat --mode auto --in-flight yes
want_verdict 18 "auto + work in flight -> COMPACT (handles survive)" compacted
want_typed   18b "auto/yes typed /compact" "/compact"
want_typed   18c "auto/yes typed /onboard after compaction" "/onboard"
if grep -qF "/clear" "$TYPED"; then bad 18d "auto/yes must NEVER /clear (it would orphan the handles)"
else ok 18d "auto/yes never typed /clear"; fi
kill_pane

# --- 19-21: the rate limit --------------------------------------------------
echo
echo "-- rail 4: rate limit (molt-loop protection)"
reset_ledger; fresh_offboard; mk_pane moltyD "✅ seat"
printf '{"ts":"now","epoch":%s,"session":"moltyD","window":"seat","mode":"molt","pct":80,"result":"molted"}\n' \
  "$(date +%s)" >> "$LEDGER"
molt --target moltyD seat --mode molt
want_verdict   19 "a second molt inside the window is refused" refused-rate-limited
want_untouched 19n "the rate-limited pane was typed into NOT AT ALL"
kill_pane

reset_ledger; fresh_offboard; mk_pane moltyE "✅ seat"
printf '{"ts":"old","epoch":%s,"session":"moltyE","window":"seat","mode":"molt","pct":80,"result":"molted"}\n' \
  "$(( $(date +%s) - 4000 ))" >> "$LEDGER"
molt --target moltyE seat --mode molt
want_verdict 20 "a molt older than the window does not block" molted
kill_pane

reset_ledger; fresh_offboard; mk_pane moltyF "✅ seat"
printf '{"ts":"now","epoch":%s,"session":"moltyF","window":"seat","mode":"molt","pct":80,"result":"refused-not-offboarded"}\n' \
  "$(date +%s)" >> "$LEDGER"
molt --target moltyF seat --mode molt
want_verdict 21 "a REFUSAL row must not lock the window out of a real molt" molted
kill_pane

# --- 22: R13 — the session is matched EXACTLY -------------------------------
echo
echo "-- R13: session and window are separate fields, matched exactly"
reset_ledger; fresh_offboard
mk_pane molty "✅ seat";  TYPED_A="$TYPED"
mk_pane moltyX "✅ seat"; TYPED_B="$TYPED"
molt --target molty seat --mode molt
TYPED="$TYPED_A"; want_typed 22 "the named session was cycled" "/clear"
if [ -s "$TYPED_B" ]; then bad 22n "the LOOK-ALIKE session moltyX was typed into: $(tr '\n' ' ' < "$TYPED_B")"
else ok 22n "the look-alike session moltyX was left alone"; fi
"${TM[@]}" kill-session -t "=molty" 2>/dev/null   # allow-suppress: already-gone is fine
"${TM[@]}" kill-session -t "=moltyX" 2>/dev/null  # allow-suppress: already-gone is fine

# --- 23: --self, and the invoker that never goes idle -----------------------
echo
echo "-- --self: detach, then wait for the invoker's turn to end"
reset_ledger; fresh_offboard; no_turn_end; mk_pane moltyG "🧠 seat"
OUT=$(MOLT_DETACH=0 "$SCRIPT" --self --target moltyG seat --socket "$SOCKPATH" --dir "$PROJ" \
        --mode auto --in-flight no 2>&1); RC=$?
VERDICT=$(printf '%s\n' "$OUT" | grep -o 'SEAT_MOLT_RESULT=[a-z-]*' | tail -1)
want_verdict   23 "--self with NO turn-end stamp times out (no --wait-idle-first case reaches pane-stability anymore)" aborted-not-idle
want_untouched 23n "the timed-out --self pane was typed into NOT AT ALL"
kill_pane

# --- 23b: THE BUG (dotfiles-ygf8, FINDING 3) --------------------------------
# A pane that NEVER stabilizes by the old pane-text measure (window name stuck
# on 🧠 forever, exactly like case 23's fixture and a real background builder's
# spinner) must still molt once a FRESH turn-end stamp lands — that stamp,
# written after the invoker's turn genuinely ends, is the whole point of this
# bead. The stamp write is deliberately at least 1 FULL second past t0 -- both
# t0 and mtime are second-granularity `date +%s` values, so a write inside the
# SAME calendar second as t0's capture risks mtime == t0, which fails the
# strict -gt in wait_for_turn_end. This case overrides MOLT_SELF_IDLE_TIMEOUT
# to 8s (well past the global 2s) so a loaded box's scheduling jitter on the
# background flipper cannot cost the test the race either — a real pre-commit
# run flaked aborted-not-idle here at the tight 2s/1s margin (dotfiles-ygf8).
echo
echo "-- --self: a churning pane molts on a fresh turn-end stamp (THE bug)"
reset_ledger; fresh_offboard; no_turn_end; mk_pane moltyI "🧠 seat"
( sleep 1.5; turn_end_fresh ) &
_flip=$!
OUT=$(MOLT_DETACH=0 MOLT_SELF_IDLE_TIMEOUT=8 "$SCRIPT" --self --target moltyI seat --socket "$SOCKPATH" --dir "$PROJ" \
        --mode auto --in-flight no 2>&1); RC=$?
wait "$_flip" 2>/dev/null   # allow-suppress: the flipper is done either way
VERDICT=$(printf '%s\n' "$OUT" | grep -o 'SEAT_MOLT_RESULT=[a-z-]*' | tail -1)
want_verdict 23b "a pane stuck on 🧠 forever still molts once the turn-end stamp lands" molted
want_typed   23b2 "/clear was typed despite the pane never text-stabilizing" "/clear"
want_typed   23b3 "/onboard was typed after the stamp-driven molt" "/onboard"
kill_pane

# --- 23e: R14b — a cross-server invoker pane id must NOT ride to the child --
# The invoker's $TMUX_PANE is an id on the INVOKER's server. When the molt
# targets a different socket (this suite's fake server), a colliding id there
# belongs to an unrelated pane; before R14b the parent passed it anyway and
# the child typed /clear into whatever that id resolved to here (measured
# live: a session with TMUX_PANE=%3 leaked it into this suite and 23b2/23b3
# went red because the keystrokes landed in another fixture's pane).
# Deterministic reproduction: a victim session whose real pane id on THIS
# fake server we pass as TMUX_PANE, with $TMUX naming a DIFFERENT server.
echo
echo "-- --self: a cross-server invoker pane id is refused (R14b)"
reset_ledger; fresh_offboard; no_turn_end
mk_pane moltyV "🧠 victim"
VICTIM_TYPED="$TYPED"
VICTIM_PANE=$("${TM[@]}" list-panes -t "=moltyV" -F '#{pane_id}' | head -1)
mk_pane moltyW "🧠 seat"
( sleep 1.5; turn_end_fresh ) &
_flip=$!
OUT=$(TMUX="/nonexistent-molt-test.sock,1,0" TMUX_PANE="$VICTIM_PANE" \
      MOLT_DETACH=0 MOLT_SELF_IDLE_TIMEOUT=8 \
      "$SCRIPT" --self --target moltyW seat --socket "$SOCKPATH" --dir "$PROJ" \
      --mode auto --in-flight no 2>&1); RC=$?
wait "$_flip" 2>/dev/null   # allow-suppress: the flipper is done either way
VERDICT=$(printf '%s\n' "$OUT" | grep -o 'SEAT_MOLT_RESULT=[a-z-]*' | tail -1)
want_verdict 23e  "cross-server pane id: molt still lands via window-name resolution" molted
want_typed   23e2 "/clear went to the NAMED window's pane, not the colliding id" "/clear"
if grep -qF "/clear" "$VICTIM_TYPED"; then
  bad 23e3 "the colliding victim pane was typed into"
else
  ok 23e3 "the colliding victim pane was untouched"
fi
"${TM[@]}" kill-session -t "=moltyV" 2>/dev/null   # allow-suppress: already-gone is fine
kill_pane

# --- 23c: a STALE turn-end stamp (older than t0) does NOT satisfy the wait --
# A leftover stamp from a PREVIOUS turn must not be read as "this turn ended" —
# only an mtime newer than t0 counts.
echo
echo "-- --self: a stale turn-end stamp (older than t0) does not satisfy the wait"
reset_ledger; fresh_offboard; turn_end_stale; mk_pane moltyJ "🧠 seat"
OUT=$(MOLT_DETACH=0 "$SCRIPT" --self --target moltyJ seat --socket "$SOCKPATH" --dir "$PROJ" \
        --mode auto --in-flight no 2>&1); RC=$?
VERDICT=$(printf '%s\n' "$OUT" | grep -o 'SEAT_MOLT_RESULT=[a-z-]*' | tail -1)
want_verdict   23c "a stale (pre-t0) turn-end stamp times out just like no stamp at all" aborted-not-idle
want_untouched 23cn "the stale-stamp pane was typed into NOT AT ALL"
kill_pane

# --- 23d: a MODAL pane with a fresh stamp keeps waiting, never molts -------
# The turn did not end for MOLTING purposes if a dialog is open — send-keys
# there would answer Andrew's question with the default. wait_for_turn_end
# checks is_modal on every fresh-stamp sighting and keeps polling rather than
# proceeding, so this times out as aborted-not-idle (NOT aborted-modal — that
# verdict is --target's fast-return; --self's loop just never becomes eligible).
echo
echo "-- --self: a modal pane with a fresh stamp still does not molt"
reset_ledger; fresh_offboard; no_turn_end; mk_pane moltyK "🔔 seat"
( sleep 0.3; turn_end_fresh ) &
_flip=$!
OUT=$(MOLT_DETACH=0 "$SCRIPT" --self --target moltyK seat --socket "$SOCKPATH" --dir "$PROJ" \
        --mode auto --in-flight no 2>&1); RC=$?
wait "$_flip" 2>/dev/null   # allow-suppress: the flipper is done either way
VERDICT=$(printf '%s\n' "$OUT" | grep -o 'SEAT_MOLT_RESULT=[a-z-]*' | tail -1)
want_verdict   23d "a modal pane with a fresh stamp still times out (never molts)" aborted-not-idle
want_untouched 23dn "the modal --self pane was typed into NOT AT ALL"
kill_pane

# --- 24: a lib-less copy FAILS CLOSED on the mtime (dotfiles-5vz2) ----------
echo
echo "-- fail closed: no portable.sh means no freshness answer"
reset_ledger; fresh_offboard; mk_pane moltyH "✅ seat"
mkdir -p "$T/nolib"
cp "$SCRIPT" "$T/nolib/seat-molt.sh"
OUT=$(bash "$T/nolib/seat-molt.sh" --socket "$SOCKPATH" --dir "$PROJ" \
        --target moltyH seat --mode molt 2>&1); RC=$?
VERDICT=$(printf '%s\n' "$OUT" | grep -o 'SEAT_MOLT_RESULT=[a-z-]*' | tail -1)
want_verdict   24 "an unreadable mtime must NOT grant the release" refused-not-offboarded
want_untouched 24n "the fail-closed pane was typed into NOT AT ALL"
printf '%s\n' "$OUT" | grep -q "could not read the mtime" \
  && ok 24m "the fail-closed path announces itself" \
  || bad 24m "the fail-closed path is silent"
kill_pane

# --- 25: R14 — a passed invoker pane beats <window_id>.0 --------------------
# The 2026-08-09 live failure: a split window put another session at pane .0,
# and the --self child (rebuilding "$WIN_ID.0") watched and would have cycled
# the WRONG session. With --pane, the child must type into the INVOKER's pane
# and leave pane .0 completely untouched.
echo
echo "-- R14: self-pane passthrough targets the invoker's pane, never .0"
reset_ledger; fresh_offboard
mk_pane moltyR "✅ seat"
TYPED0="$TYPED"
TYPED1="$T/typed.moltyR.p1"
: > "$TYPED1"
"${TM[@]}" split-window -d -t "=moltyR:0" -c "$T"   "MOLT_TEST_MARKER=$(printf '%q' '? for shortcuts') bash $T/pane.sh $TYPED1"
PANE1=$("${TM[@]}" list-panes -t "=moltyR:0" -F '#{pane_id}' | tail -1)
_n=0; while [ "$_n" -lt 200 ]; do
  "${TM[@]}" capture-pane -p -t "$PANE1" | grep -qF '? for shortcuts' && break
  _n=$((_n+1)); sleep 0.05
done
molt --target moltyR seat --pane "$PANE1" --mode molt
want_verdict 25 "molt with --pane completes" molted
TYPED="$TYPED1"; want_typed 25a "the INVOKER pane ($PANE1) was cycled" "/clear"
TYPED="$TYPED0"; want_untouched 25b0 "pane .0 (the other session) was typed into NOT AT ALL"
kill_pane

# --- 25b: R14 fallback — a dead passed pane falls back to window-name .0 ----
echo
echo "-- R14: a vanished invoker pane falls back to name resolution"
reset_ledger; fresh_offboard
mk_pane moltyS "✅ seat"
molt --target moltyS seat --pane '%99999' --mode molt
want_verdict 25c "dead --pane still molts via fallback" molted
want_typed   25d "fallback typed into pane .0" "/clear"
kill_pane

# --- summary ----------------------------------------------------------------
echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
exit 1
