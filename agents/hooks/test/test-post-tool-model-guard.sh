#!/bin/bash
# Test for post-tool-model-guard.sh — the silent model-degradation guard
# (dotfiles-p89v). Hook test convention: see test-worktree-guard.sh.
#
# THE FIXTURE IS REAL BYTES, NOT A GUESS. model-guard-transcript.fixture.jsonl
# is six lines lifted verbatim out of the session that actually suffered the
# downgrades — ~/.claude/projects/-home-ubuntu-dotfiles/2cc9586e-….jsonl, lines
# 4499/4500/4503/4504/4505/4506 — spanning the 2026-08-09T06:42Z transition:
#
#   assistant  claude-fable-5     06:41:31Z
#   assistant  claude-fable-5     06:41:40Z
#   permission-mode                            (a non-message row, kept on purpose)
#   user                          06:41:41Z
#   system     model_refusal_fallback  06:41:52Z
#              originalModel=claude-fable-5[1m]  fallbackModel=claude-opus-4-8[1m]
#   assistant  claude-opus-4-8    06:42:11Z    <- the first degraded message
#
# Only free-text payloads were elided (assistant/user content) and identifying
# keys dropped (cwd, gitBranch, uuids, requestId, …). Every structural key the
# hook reads — type, subtype, isSidechain, message.model, originalModel — is the
# original byte sequence. Regenerate ONLY from a real transcript; a hand-typed
# fixture would be exactly the guess this suite exists to avoid.
#
# The failure-before / absence-after demonstration is cases C1 vs C2: the tail
# ending on claude-opus-4-8 MUST fire the guard, and the same file truncated to
# its fable-only prefix MUST NOT.
#
# THE SECOND FIXTURE IS ALSO REAL BYTES (dotfiles-8x8l).
# model-guard-coldstart.fixture.jsonl is the transcript AS THE HOOK READ IT
# during a real blind firing — session 7e29e574, 2026-08-09T21:37:47Z, whose
# ledger row was the exact `check-failed / no-served-model` shape this bead was
# filed for. It was captured by snapshotting the live file every 50ms while a
# fresh interactive session took its first tool round: at 21:37:45.772 the file
# held these 12 lines and NOT ONE assistant row; at 21:37:47.203, 1.4s later and
# after the guard had already fired, the client's batched assistant rows landed.
# Only free-text payloads (attachment / snapshot / message.content) were elided
# and identifying keys dropped. Nothing was added — the ABSENCE of an assistant
# row is the fixture's whole content, and hand-typing it would have been the
# guess this suite exists to avoid. C24 is its regression guard; C25 shows the
# re-read recovering the round instead of skipping it.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="${MODEL_GUARD_HOOK:-$(cd "$HERE/.." && pwd)/post-tool-model-guard.sh}"
FIXTURE="$HERE/model-guard-transcript.fixture.jsonl"
COLDSTART="$HERE/model-guard-coldstart.fixture.jsonl"

PASS=0
FAIL=0
FAILED_NAMES=()
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf '  FAIL %s\n     -> %s\n' "$1" "${2:-}"; }

[ -r "$FIXTURE" ] || { echo "FATAL: fixture missing: $FIXTURE" >&2; exit 2; }
[ -r "$COLDSTART" ] || { echo "FATAL: fixture missing: $COLDSTART" >&2; exit 2; }
[ -x "$HOOK" ] || { echo "FATAL: hook not executable: $HOOK" >&2; exit 2; }

T=$(mktemp -d "${TMPDIR:-/tmp}/test-model-guard.XXXXXX")
trap 'rm -rf "$T"' EXIT

# Transcript variants built from the fixture.
FULL="$T/full.jsonl"; cp "$FIXTURE" "$FULL"                 # tail = claude-opus-4-8
CLEAN="$T/clean.jsonl"; head -n 4 "$FIXTURE" > "$CLEAN"      # tail = claude-fable-5
EMPTY="$T/empty.jsonl"; : > "$EMPTY"
GARBAGE="$T/garbage.jsonl"; printf 'not json at all\n{"type":"user"}\n' > "$GARBAGE"

# SYNTH: the fixture plus a trailing <synthetic> assistant row (the 3 real ones
# in that session are interrupt/error placeholders, not a serving model).
SYNTH="$T/synth.jsonl"; cp "$CLEAN" "$SYNTH"
printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"model":"<synthetic>","role":"assistant","content":[]}}' >> "$SYNTH"

# NOFB: the real opus-4-8 message with NO refusal-fallback row ahead of it —
# a downgrade that arrived by some route the client did not annotate. This is
# what forces expected-model resolution down to the machine default.
NOFB="$T/nofb.jsonl"; cp "$CLEAN" "$NOFB"; tail -n 1 "$FIXTURE" >> "$NOFB"

# SIDE: fable tail plus a SIDECHAIN opus message (a dispatched subagent writes
# into the same file in some client versions; it is not this session's model).
SIDE="$T/side.jsonl"; cp "$CLEAN" "$SIDE"
printf '%s\n' '{"type":"assistant","isSidechain":true,"message":{"model":"claude-opus-4-8","role":"assistant","content":[]}}' >> "$SIDE"

# SIDEFB: a MAIN-session transcript (healthy fable tail) that happens to contain
# a SIDECHAIN refusal-fallback row naming a different originalModel. Without an
# isSidechain filter on the O extraction, a dispatched subagent's refusal poisons
# the parent's cached expectation and the healthy session gets walked up the
# ladder toward the wrong model. The row is the real one, re-tagged sidechain.
SIDEFB="$T/sidefb.jsonl"
sed -n '5p' "$FIXTURE" | sed 's/"isSidechain":false/"isSidechain":true/; s/"originalModel":"claude-fable-5\[1m\]"/"originalModel":"claude-opus-5[1m]"/' > "$SIDEFB"
cat "$CLEAN" >> "$SIDEFB"

SETTINGS="$T/settings.json"
printf '%s\n' '{"model":"claude-fable-5[1m]"}' > "$SETTINGS"

# --- runner -----------------------------------------------------------------
# Every case gets its own state root. MODEL_GUARD_USE_PROC=0 by default because
# this suite runs INSIDE a real claude process: without it the /proc ancestry
# walk would read the harness's own --model and make cases environment-dependent.
#
# The transcript is COPIED to <session_id>.jsonl before each run, because that
# is the real shape of a main session's transcript and the hook's subagent bail
# keys on it (basename-minus-.jsonl == session_id). A case that wants the
# subagent shape builds its own path — see C22.
#
# MODEL_GUARD_RETRIES=0 by default: the production default re-reads a blind
# transcript (the cold-start race, dotfiles-8x8l), which would add real sleeps to
# every deliberately-blind case here and prove nothing. C25 turns it back on and
# is the case that actually exercises it.
STDERR=""; EXITC=0; STATE=""
runh() {   # runh <transcript-source> <session> [extra env assignments...]
  local src=$1 sid=$2; shift 2
  local tp
  mkdir -p "$T/tp"
  tp="$T/tp/$sid.jsonl"
  rm -f "$tp"
  [ -e "$src" ] && cp "$src" "$tp"     # a nonexistent src leaves tp absent, on purpose
  STATE="$T/state-$sid"
  STDERR=$(env HARNESS_STATE_DIR="$STATE" \
               MODEL_GUARD_USE_PROC=0 \
               MODEL_GUARD_USE_SETTINGS=0 \
               MODEL_GUARD_COOLDOWN_SECS=0 \
               MODEL_GUARD_RETRIES=0 \
               "$@" \
           "$HOOK" 2>&1 >/dev/null <<EOF
{"session_id":"$sid","transcript_path":"$tp","cwd":"$T"}
EOF
  )
  EXITC=$?
}
ledger() { cat "$STATE/model-degradation-ledger.jsonl" 2>/dev/null; }   # allow-suppress: existence probe
lrows()  { ledger | grep -c . ; }
fires()  { [ "$EXITC" -eq 2 ] && printf '%s' "$STDERR" | grep -q 'MODEL DEGRADATION'; }

echo "=== post-tool-model-guard ================================================="

# --- C0: the fixture really carries the real ids ----------------------------
if grep -q '"model":"claude-opus-4-8"' "$FIXTURE" \
   && grep -q '"model":"claude-fable-5"' "$FIXTURE" \
   && grep -q '"subtype":"model_refusal_fallback"' "$FIXTURE" \
   && grep -q '"originalModel":"claude-fable-5\[1m\]"' "$FIXTURE"; then
  ok "C0 fixture carries the real serving-model ids + the refusal-fallback row"
else
  bad "C0 fixture carries the real serving-model ids + the refusal-fallback row" \
      "the fixture was regenerated from something that is not the real transcript"
fi

# --- C1: FAILURE-BEFORE — the real opus-4-8 tail MUST fire ------------------
runh "$FULL" c1 MODEL_GUARD_EXPECTED=claude-fable-5
if fires && printf '%s' "$STDERR" | grep -q "claude-opus-4-8"; then
  ok "C1 real opus-4-8 tail fires the guard (exit 2, names the served model)"
else
  bad "C1 real opus-4-8 tail fires the guard (exit 2, names the served model)" "exit=$EXITC out=$STDERR"
fi

# --- C2: ABSENCE-AFTER — the same file, fable tail, MUST NOT fire -----------
runh "$CLEAN" c2 MODEL_GUARD_EXPECTED=claude-fable-5
if [ "$EXITC" -eq 0 ] && [ -z "$STDERR" ]; then
  ok "C2 fable tail stays silent (exit 0, no instruction)"
else
  bad "C2 fable tail stays silent (exit 0, no instruction)" "exit=$EXITC out=$STDERR"
fi

# --- C3: expected derived from the client's own refusal-fallback row --------
runh "$FULL" c3
if fires && printf '%s' "$STDERR" | grep -q 'source: refusal-fallback'; then
  ok "C3 expected model derived from model_refusal_fallback.originalModel"
else
  bad "C3 expected model derived from model_refusal_fallback.originalModel" "exit=$EXITC out=$STDERR"
fi

# --- C4: the per-seat override file `off` disables the guard entirely -------
STATE="$T/state-c4"; mkdir -p "$STATE/model-guard"; printf 'off\n' > "$STATE/model-guard/c4.expected"
runh "$FULL" c4
if [ "$EXITC" -eq 0 ] && [ -z "$STDERR" ]; then
  ok "C4 override file 'off' disables the guard"
else
  bad "C4 override file 'off' disables the guard" "exit=$EXITC out=$STDERR"
fi

# --- C5: an intentionally-Opus seat never trips ----------------------------
STATE="$T/state-c5"; mkdir -p "$STATE/model-guard"; printf 'claude-opus-4-8\n' > "$STATE/model-guard/c5.expected"
runh "$FULL" c5
if [ "$EXITC" -eq 0 ] && [ -z "$STDERR" ]; then
  ok "C5 seat declared as opus-4-8 does not trip on an opus-4-8 tail"
else
  bad "C5 seat declared as opus-4-8 does not trip on an opus-4-8 tail" "exit=$EXITC out=$STDERR"
fi

# --- C6: ledger row, non-null row name, event + action ----------------------
runh "$FULL" c6 MODEL_GUARD_EXPECTED=claude-fable-5
ROW=$(ledger | tail -n 1)
if printf '%s' "$ROW" | grep -q '"row":"model-guard"' \
   && printf '%s' "$ROW" | grep -q '"event":"detected"' \
   && printf '%s' "$ROW" | grep -q '"action":"restore"' \
   && printf '%s' "$ROW" | grep -q '"expected":"claude-fable-5"' \
   && printf '%s' "$ROW" | grep -q '"served":"claude-opus-4-8"' \
   && printf '%s' "$ROW" | grep -q '"tries":1'; then
  ok "C6 ledger row: non-null row name, detected/restore, expected+served+tries"
else
  bad "C6 ledger row: non-null row name, detected/restore, expected+served+tries" "row=$ROW"
fi

# --- C7: second episode escalates to the MOLT ------------------------------
runh "$FULL" c7 MODEL_GUARD_EXPECTED=claude-fable-5
runh "$FULL" c7 MODEL_GUARD_EXPECTED=claude-fable-5
if fires \
   && printf '%s' "$STDERR" | grep -q 'seat-molt.sh' \
   && printf '%s' "$STDERR" | grep -q -- '--self --mode compact' \
   && ledger | tail -n 1 | grep -q '"action":"molt"'; then
  ok "C7 second episode escalates to molt (compact, in-flight-safe)"
else
  bad "C7 second episode escalates to molt (compact, in-flight-safe)" "exit=$EXITC out=$STDERR row=$(ledger | tail -n 1)"
fi

# --- C8: third episode STOPS and raises to Zig ------------------------------
runh "$FULL" c8 MODEL_GUARD_EXPECTED=claude-fable-5
runh "$FULL" c8 MODEL_GUARD_EXPECTED=claude-fable-5
runh "$FULL" c8 MODEL_GUARD_EXPECTED=claude-fable-5
if fires \
   && printf '%s' "$STDERR" | grep -q 'AskUserQuestion' \
   && printf '%s' "$STDERR" | grep -q 'PushNotification' \
   && printf '%s' "$STDERR" | grep -q 'P1 bead' \
   && ledger | tail -n 1 | grep -q '"action":"escalate"'; then
  ok "C8 third episode stops and raises (AskUserQuestion / P1 human bead + push)"
else
  bad "C8 third episode stops and raises (AskUserQuestion / P1 human bead + push)" "exit=$EXITC out=$STDERR row=$(ledger | tail -n 1)"
fi

# --- C9: inside the cooldown the guard instructs once, then stays silent ----
runh "$FULL" c9 MODEL_GUARD_EXPECTED=claude-fable-5 MODEL_GUARD_COOLDOWN_SECS=3600
FIRST=$EXITC
runh "$FULL" c9 MODEL_GUARD_EXPECTED=claude-fable-5 MODEL_GUARD_COOLDOWN_SECS=3600
if [ "$FIRST" -eq 2 ] && [ "$EXITC" -eq 0 ] && [ -z "$STDERR" ] && [ "$(lrows)" -eq 1 ]; then
  ok "C9 cooldown: one instruction + one ledger row per episode, no nag loop"
else
  bad "C9 cooldown: one instruction + one ledger row per episode, no nag loop" "first=$FIRST second=$EXITC rows=$(lrows) out=$STDERR"
fi

# --- C10: recovery clears pending but PRESERVES the try count ---------------
runh "$FULL"  c10 MODEL_GUARD_EXPECTED=claude-fable-5      # try 1 -> restore
runh "$CLEAN" c10 MODEL_GUARD_EXPECTED=claude-fable-5      # recovered
REC=$(ledger | tail -n 1)
runh "$FULL"  c10 MODEL_GUARD_EXPECTED=claude-fable-5      # knocked down again -> molt
if printf '%s' "$REC" | grep -q '"event":"recovered"' \
   && printf '%s' "$STDERR" | grep -q 'seat-molt.sh' \
   && ledger | tail -n 1 | grep -q '"action":"molt"'; then
  ok "C10 recovery is ledgered and the try count survives it (next knock = molt)"
else
  bad "C10 recovery is ledgered and the try count survives it (next knock = molt)" "rec=$REC out=$STDERR row=$(ledger | tail -n 1)"
fi

# --- C11: FAIL-OPEN on a missing transcript ---------------------------------
runh "$T/does-not-exist.jsonl" c11 MODEL_GUARD_EXPECTED=claude-fable-5
if [ "$EXITC" -eq 0 ] && [ -z "$STDERR" ] && ledger | grep -q '"event":"check-failed"' \
   && ledger | grep -q '"action":"no-transcript"'; then
  ok "C11 missing transcript: exit 0, no instruction, check-failed row names it"
else
  bad "C11 missing transcript: exit 0, no instruction, check-failed row names it" "exit=$EXITC out=$STDERR ledger=$(ledger)"
fi

# --- C12: FAIL-OPEN when no serving model can be read, AND SAY WHICH --------
# The two shapes are different failures and must not share one label: an empty
# file is a session that has written nothing, a garbage file is a parse that
# died. dotfiles-8x8l: the generic `no-served-model` made six real ledger rows
# unattributable, so the reason string is part of the contract now.
runh "$GARBAGE" c12 MODEL_GUARD_EXPECTED=claude-fable-5
G1=$EXITC
GLEDGER=$(ledger)
runh "$EMPTY" c12b MODEL_GUARD_EXPECTED=claude-fable-5
if [ "$G1" -eq 0 ] && [ "$EXITC" -eq 0 ] && [ -z "$STDERR" ] \
   && printf '%s' "$GLEDGER" | grep -q '"event":"check-failed"' \
   && printf '%s' "$GLEDGER" | grep -q '"action":"transcript-unparseable"' \
   && ledger | grep -q '"action":"transcript-empty"'; then
  ok "C12 unparseable / empty transcript: exit 0, no instruction, reason NAMED per row"
else
  bad "C12 unparseable / empty transcript: exit 0, no instruction, reason NAMED per row" "garbage=$G1 empty=$EXITC out=$STDERR garbage-ledger=$GLEDGER empty-ledger=$(ledger)"
fi

# --- C13: a <synthetic> tail is not a serving model -------------------------
runh "$SYNTH" c13 MODEL_GUARD_EXPECTED=claude-fable-5
if [ "$EXITC" -eq 0 ] && [ -z "$STDERR" ]; then
  ok "C13 <synthetic> assistant row is skipped, not read as the served model"
else
  bad "C13 <synthetic> assistant row is skipped, not read as the served model" "exit=$EXITC out=$STDERR"
fi

# --- C14: a sidechain (subagent) message is not this session's model --------
runh "$SIDE" c14 MODEL_GUARD_EXPECTED=claude-fable-5
if [ "$EXITC" -eq 0 ] && [ -z "$STDERR" ]; then
  ok "C14 sidechain assistant message is ignored"
else
  bad "C14 sidechain assistant message is ignored" "exit=$EXITC out=$STDERR"
fi

# --- C15: the [1m] context tag is not a model difference --------------------
runh "$CLEAN" c15 MODEL_GUARD_EXPECTED='claude-fable-5[1m]'
if [ "$EXITC" -eq 0 ] && [ -z "$STDERR" ]; then
  ok "C15 'claude-fable-5[1m]' is the same model as 'claude-fable-5'"
else
  bad "C15 'claude-fable-5[1m]' is the same model as 'claude-fable-5'" "exit=$EXITC out=$STDERR"
fi

# --- C16: a bare alias matches its family -----------------------------------
runh "$FULL" c16 MODEL_GUARD_EXPECTED=opus
E1=$EXITC
runh "$CLEAN" c16b MODEL_GUARD_EXPECTED=fable
if [ "$E1" -eq 0 ] && [ "$EXITC" -eq 0 ] && [ -z "$STDERR" ]; then
  ok "C16 alias 'opus' matches claude-opus-4-8; 'fable' matches claude-fable-5"
else
  bad "C16 alias 'opus' matches claude-opus-4-8; 'fable' matches claude-fable-5" "opus=$E1 fable=$EXITC out=$STDERR"
fi

# --- C17: no session id -> silent, no state, no ledger ----------------------
STATE="$T/state-c17"
STDERR=$(env HARNESS_STATE_DIR="$STATE" MODEL_GUARD_USE_PROC=0 MODEL_GUARD_EXPECTED=claude-fable-5 \
         "$HOOK" 2>&1 >/dev/null <<EOF
{"transcript_path":"$FULL"}
EOF
); EXITC=$?
if [ "$EXITC" -eq 0 ] && [ -z "$STDERR" ] && [ ! -d "$STATE" ]; then
  ok "C17 no session_id: silent exit 0, nothing written"
else
  bad "C17 no session_id: silent exit 0, nothing written" "exit=$EXITC out=$STDERR"
fi

# --- C18: settings.json is the machine-default expectation ------------------
runh "$NOFB" c18 MODEL_GUARD_USE_SETTINGS=1 MODEL_GUARD_SETTINGS="$SETTINGS"
if fires && printf '%s' "$STDERR" | grep -q 'source: settings'; then
  ok "C18 settings.json .model is used when nothing more specific declares one"
else
  bad "C18 settings.json .model is used when nothing more specific declares one" "exit=$EXITC out=$STDERR"
fi

# --- C19: check-failed rows are rate-limited, not one per tool call ---------
runh "$T/nope.jsonl" c19 MODEL_GUARD_EXPECTED=claude-fable-5 MODEL_GUARD_COOLDOWN_SECS=3600
runh "$T/nope.jsonl" c19 MODEL_GUARD_EXPECTED=claude-fable-5 MODEL_GUARD_COOLDOWN_SECS=3600
runh "$T/nope.jsonl" c19 MODEL_GUARD_EXPECTED=claude-fable-5 MODEL_GUARD_COOLDOWN_SECS=3600
if [ "$(lrows)" -eq 1 ]; then
  ok "C19 a permanently broken read writes ONE check-failed row, not one per call"
else
  bad "C19 a permanently broken read writes ONE check-failed row, not one per call" "rows=$(lrows)"
fi

# --- C20: an undeclared session is not a degraded one -----------------------
# The fable-tail transcript carries no refusal-fallback row, /proc is off, and
# the settings path does not exist — so no layer of the precedence declares
# anything. An undeclared session must be left alone, not guessed at.
runh "$CLEAN" c20 MODEL_GUARD_USE_SETTINGS=1 MODEL_GUARD_SETTINGS="$T/no-such-settings.json"
if [ "$EXITC" -eq 0 ] && [ -z "$STDERR" ]; then
  ok "C20 no declared model anywhere: silent, no instruction"
else
  bad "C20 no declared model anywhere: silent, no instruction" "exit=$EXITC out=$STDERR"
fi

# --- C21: the instruction is imperative and self-contained ------------------
runh "$FULL" c21 MODEL_GUARD_EXPECTED=claude-fable-5
if printf '%s' "$STDERR" | grep -q '/model' \
   && printf '%s' "$STDERR" | grep -q 'claude-fable-5' \
   && printf '%s' "$STDERR" | grep -qi 'settings.json will NOT help'; then
  ok "C21 restore instruction names /model, the target id, and the settings dead end"
else
  bad "C21 restore instruction names /model, the target id, and the settings dead end" "out=$STDERR"
fi

# --- C22: the REAL subagent shape — silent bail, nothing written ------------
# Parent session_id + subagents/agent-*.jsonl transcript + 100% isSidechain
# rows on claude-opus-5. This is the shape measured on this bead's own agent
# (see the fixture note); the hook must treat it as a normal condition, not as
# a detection error — no instruction, NO ledger row, no state file.
PARENT=parent-538b7ef4
SUBDIR="$T/proj/$PARENT/subagents"
mkdir -p "$SUBDIR"
cp "$HERE/model-guard-subagent.fixture.jsonl" "$SUBDIR/agent-a75fc3d9dbfee0c92.jsonl"
STATE="$T/state-c22"
STDERR=$(env HARNESS_STATE_DIR="$STATE" MODEL_GUARD_USE_PROC=0 MODEL_GUARD_USE_SETTINGS=0 \
             MODEL_GUARD_EXPECTED=claude-fable-5 \
         "$HOOK" 2>&1 >/dev/null <<EOF
{"session_id":"$PARENT","transcript_path":"$SUBDIR/agent-a75fc3d9dbfee0c92.jsonl","cwd":"$T"}
EOF
); EXITC=$?
if [ "$EXITC" -eq 0 ] && [ -z "$STDERR" ] && [ ! -d "$STATE" ]; then
  ok "C22 subagent context (parent session_id + subagents/agent-*.jsonl): silent bail, nothing written"
else
  bad "C22 subagent context (parent session_id + subagents/agent-*.jsonl): silent bail, nothing written" \
      "exit=$EXITC out=$STDERR ledger=$(ledger)"
fi

# --- C23: a sidechain refusal row must not poison the cached expectation ----
runh "$SIDEFB" c23 MODEL_GUARD_EXPECTED=""
if [ "$EXITC" -eq 0 ] && [ -z "$STDERR" ]; then
  ok "C23 a SIDECHAIN model_refusal_fallback row does not become the expected model"
else
  bad "C23 a SIDECHAIN model_refusal_fallback row does not become the expected model" "exit=$EXITC out=$STDERR"
fi

# --- C24: THE COLD-START SHAPE, from the real blind firing ------------------
# dotfiles-8x8l's regression guard. Against the pre-fix hook this case fails
# twice over: the row read `"action":"no-served-model"` with `"expected":""`,
# which is why six such rows in one day said nothing about what went wrong or
# which seat it happened on. Three things are asserted, all of them contract:
#   * it is a check-SKIPPED, not a check-failed — the session had not spoken yet
#   * the action NAMES the shape (no-assistant-row-yet)
#   * the row carries the seat's expected model even though it saw no served one
# C0-style integrity first: the fixture must contain ZERO assistant rows, since
# their absence IS the bug it reproduces.
if [ "$(grep -c '"type":"assistant"' "$COLDSTART")" -eq 0 ] \
   && [ "$(grep -c . "$COLDSTART")" -gt 0 ] \
   && grep -q '"type":"user"' "$COLDSTART"; then
  ok "C24a cold-start fixture is a real session preamble with zero assistant rows"
else
  bad "C24a cold-start fixture is a real session preamble with zero assistant rows" \
      "the fixture was regenerated from something that is not a cold-start transcript"
fi

runh "$COLDSTART" c24 MODEL_GUARD_EXPECTED=claude-fable-5
ROW=$(ledger | tail -n 1)
if [ "$EXITC" -eq 0 ] && [ -z "$STDERR" ] \
   && printf '%s' "$ROW" | grep -q '"event":"check-skipped"' \
   && printf '%s' "$ROW" | grep -q '"action":"no-assistant-row-yet"' \
   && printf '%s' "$ROW" | grep -q '"expected":"claude-fable-5"' \
   && printf '%s' "$ROW" | grep -q '"served":""'; then
  ok "C24 cold start: check-skipped/no-assistant-row-yet, and the row names the seat"
else
  bad "C24 cold start: check-skipped/no-assistant-row-yet, and the row names the seat" "exit=$EXITC out=$STDERR row=$ROW"
fi

# --- C25: the re-read RECOVERS the round it would have skipped --------------
# Same cold-start file, but the client's batched assistant rows land while the
# hook is looking — which is what actually happens in a live session (measured:
# the batch trailed the tool round by a few hundred ms). With the re-read the
# guard makes a real verdict on the FIRST tool round instead of losing it; the
# appended row is the real claude-opus-4-8 message from the other fixture, so a
# pass here is a genuine detection, not just a non-empty read.
STATE="$T/state-c25"
mkdir -p "$T/tp"
CTP="$T/tp/c25.jsonl"
cp "$COLDSTART" "$CTP"
( sleep 0.4; tail -n 1 "$FIXTURE" >> "$CTP" ) &
APPENDER=$!
STDERR=$(env HARNESS_STATE_DIR="$STATE" MODEL_GUARD_USE_PROC=0 MODEL_GUARD_USE_SETTINGS=0 \
             MODEL_GUARD_COOLDOWN_SECS=0 MODEL_GUARD_EXPECTED=claude-fable-5 \
             MODEL_GUARD_RETRIES=12 MODEL_GUARD_RETRY_SLEEP=0.2 \
         "$HOOK" 2>&1 >/dev/null <<EOF
{"session_id":"c25","transcript_path":"$CTP","cwd":"$T"}
EOF
); EXITC=$?
wait "$APPENDER"
if fires && printf '%s' "$STDERR" | grep -q 'claude-opus-4-8' \
   && ledger | tail -n 1 | grep -q '"event":"detected"'; then
  ok "C25 re-read wins the cold-start race: a real verdict on the first tool round"
else
  bad "C25 re-read wins the cold-start race: a real verdict on the first tool round" "exit=$EXITC out=$STDERR row=$(ledger | tail -n 1)"
fi

echo
printf 'PASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'
  for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
exit 0
