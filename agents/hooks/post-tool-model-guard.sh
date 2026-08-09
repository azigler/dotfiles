#!/bin/bash
# PostToolUse (all tools): the SILENT MODEL DEGRADATION guard (dotfiles-p89v).
#
# WHAT IT GUARDS. Anthropic's precaution fallback can switch a running session
# off its declared model mid-arc — Fable 5 -> Opus 4.8 — and NOTHING in the pane
# says so afterwards. The session keeps running fable-level scenarios on a
# different model, at a different capability and price, with nobody knowing.
# Zig hit this repeatedly on the night of 2026-08-08/09 (session 2cc9586e).
#
# ── THE EMPIRICAL GROUNDING (read this before changing the detection) ────────
# Measured against that exact transcript,
# ~/.claude/projects/-home-ubuntu-dotfiles/2cc9586e-….jsonl, 4,622 lines:
#
#   assistant-message model ids, counted:
#       1471  claude-fable-5        <- the declared model
#        100  claude-opus-4-8       <- the fallback
#         83  claude-opus-5
#          3  <synthetic>           <- NOT a serving model; must be skipped
#
#   five fable -> opus-4-8 transitions plus one fable -> opus-5, e.g.
#       line 4506  2026-08-09T06:42:11Z  claude-fable-5 -> claude-opus-4-8
#
#   and — the find that shapes this hook — the client writes the downgrade
#   down EXPLICITLY, one line BEFORE the first message served by the fallback:
#       {"type":"system","subtype":"model_refusal_fallback","level":"warning",
#        "trigger":"refusal","apiRefusalCategory":"cyber","scope":"session",
#        "originalModel":"claude-fable-5[1m]",
#        "fallbackModel":"claude-opus-4-8[1m]", …}
#   NINE such rows in that one session.
#
# So there are two facts in the transcript, and this hook uses both:
#   SERVED  = the newest non-synthetic, non-sidechain assistant message.model.
#             This is the ACTUAL serving model — ground truth for "what am I
#             running on right now", not what was requested.
#   EXPECTED = what this session is declared to be (see the precedence below).
#             `model_refusal_fallback.originalModel` is the client's OWN record
#             of the intended model, so when one exists it beats every machine
#             default — it cannot be wrong about which seat this is.
#
# ── THE DETECTION SEAM, AND WHY NOT THE OTHERS ──────────────────────────────
# (a) session JSONL  <- CHOSEN. Sees the served model within one tool round, is
#     already handed to every hook as .transcript_path, needs no network, and
#     carries the refusal row that names the intended model too.
# (b) agentgateway request logs — the ground truth per AGENTS.md, but off-box
#     for some seats, unavailable to a 5s hook, and it cannot tell you which
#     tmux session to instruct. Keep it for AUDIT, not for this loop.
# (c) /proc cmdline (`--model`) — a LOWER BOUND only; pulse-inject.sh:149 already
#     records that an in-session `/model` switch never appears there. Used here
#     only to resolve EXPECTED, never SERVED.
#
# ── THE RESTORE SEAM ────────────────────────────────────────────────────────
# `claude/settings.json`'s top-level `model` key is a LAUNCH-TIME seam: it is
# read at process start, same class as the always-loaded tier (this repo's
# CLAUDE.md). Editing it does NOT move a live session. The live seam is the
# in-session `/model` slash command — pulse-inject.sh:149 and :638 both document
# it as a real switch that changes the session's model without touching cmdline.
# So the tries=1 instruction names `/model`, and the guard VERIFIES on the next
# tool round rather than trusting it: if the served model has not moved by the
# time the cooldown lapses, the counter advances and the ladder escalates. That
# verification is the whole design — see OPEN QUESTION at the bottom.
#
# ── EXPECTED-MODEL PRECEDENCE (first hit wins) ──────────────────────────────
#   1. $MODEL_GUARD_EXPECTED                     env; `off` disables the guard
#   2. $STATE/model-guard/<session_id>.expected  per-seat override file; `off`
#      disables. THIS is how an intentionally-Opus seat never trips the guard.
#   3. newest transcript model_refusal_fallback.originalModel  (per-session,
#      written by the client itself), cached into state once seen
#   4. an ancestor `claude --model <x>` on /proc  (Linux only; best effort)
#   5. ~/.claude/settings.json .model            (the machine default)
#   6. nothing resolvable -> exit 0, silent. An undeclared session is not a
#      degraded one.
# Comparison is on the NORMALISED id: a trailing `[1m]` context tag is stripped
# (settings says `claude-fable-5[1m]`, the wire says `claude-fable-5`), case is
# folded, and a bare alias (`fable`/`opus`/`sonnet`/`haiku`) matches any
# `claude-<alias>-*`.
#
# ── THE LADDER (Zig's playbook, dotfiles-p89v) ──────────────────────────────
#   tries=1  RESTORE  — /model back to the declared id, then keep working
#   tries=2  MOLT     — offboard, set the model, seat-molt --self --mode compact
#                       (compact is the in-flight-safe mode: it preserves
#                       background task handles; /clear orphans them)
#   tries>=3 STOP     — AskUserQuestion to Zig (interactive) / P1 `human:` bead
#                       + PushNotification (autonomous tick). Never keep feeding
#                       fable-level scenarios to the fallback model silently.
# A "try" is an EPISODE, not a tool round: a new one starts when the session was
# last seen healthy, or when a mismatch outlives MODEL_GUARD_COOLDOWN_SECS
# (default 180) since the last instruction — that lapse IS "the restore did not
# take". Inside the cooldown the hook is silent, so it instructs rather than nags.
#
# ── SUBAGENT CONTEXT ────────────────────────────────────────────────────────
# A subagent's invocation of this hook carries the PARENT's session_id and the
# SUBAGENT's transcript_path, and is bailed on SILENTLY — no ledger row, no
# state write. Measured, with the numbers, at THE SUBAGENT BAIL below; that
# block is the authority, not this pointer.
#
# ── FAIL-OPEN ───────────────────────────────────────────────────────────────
# A broken guard must never block normal work. Missing/unreadable transcript, no
# parseable assistant model, no jq: one rate-limited `check-failed` ledger row
# and exit 0, no instruction. Only a CONFIRMED mismatch ever emits. Exit 2 is
# used for the instruction because a PostToolUse hook's stderr is only shown to
# the agent on exit 2 — the tool has already run, so nothing is blocked or undone.
#
# ── LEDGER ──────────────────────────────────────────────────────────────────
# One append-only JSONL row per event at
# $HARNESS_STATE_DIR/model-degradation-ledger.jsonl:
#   {"ts","epoch","row","session","expected","served","tries","event","action"}
# `row` is the non-null row name ("model-guard") this repo's ledger convention
# requires — a null row name produced 23 bad rows across 3 projects once
# (dotfiles-mlti). Events: detected | recovered | check-failed.
#
# Environment seams (tests use them; production uses the defaults):
#   MODEL_GUARD_EXPECTED         force the expected id, or `off` to disable
#   MODEL_GUARD_LEDGER           ledger path
#   HARNESS_STATE_DIR            state root (default ~/.local/state/harness)
#   MODEL_GUARD_SETTINGS         settings.json path (default ~/.claude/settings.json)
#   MODEL_GUARD_COOLDOWN_SECS    180   seconds before a persisting mismatch
#                                      counts as a fresh failed try
#   MODEL_GUARD_TAIL             500   transcript lines scanned per round
#   MODEL_GUARD_USE_SETTINGS     1     0 = never fall back to settings.json
#   MODEL_GUARD_USE_PROC         1     0 = never read /proc for --model
#
# OPEN QUESTION (for the orchestrator, recorded on dotfiles-p89v): whether an
# AGENT can invoke `/model` on its own pane unaided. The slash command is the
# proven live seam; what is NOT proven from this worktree is the keystroke path
# (self `tmux send-keys` queues the text until turn end, the way pulse-inject
# injects). The guard is built so this does not matter for correctness: it
# instructs, then measures. If `/model` never lands, the counter advances and
# the ladder reaches Zig — which is the correct end state either way.

# On the `2>/dev/null` below: every one of them is on a PURE READ (a `command -v`
# probe, a jq parse of text we already hold, a tail of a file whose readability
# was checked first, an awk over /proc). None is state-changing or output-bearing
# in the sense repo rule 3 guards — and the one that could hide a reason, the
# transcript parse, does not: an empty result there lands in check_failed(), which
# NAMES the failure in the ledger instead of letting it read as "nothing to do".

set -uo pipefail

INPUT=$(cat)

_MG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

command -v jq >/dev/null 2>&1 || exit 0   # allow-suppress: pure existence probe

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# No session id: nothing to key per-session state on, and no way to count tries.
# Silent exit 0 — this is not an anomaly worth a ledger row.
[ -n "$SESSION_ID" ] || exit 0

STATE_ROOT="${HARNESS_STATE_DIR:-$HOME/.local/state/harness}"
STATE_DIR="$STATE_ROOT/model-guard"
STATE_FILE="$STATE_DIR/$SESSION_ID.state"
OVERRIDE_FILE="$STATE_DIR/$SESSION_ID.expected"
LEDGER="${MODEL_GUARD_LEDGER:-$STATE_ROOT/model-degradation-ledger.jsonl}"
COOLDOWN="${MODEL_GUARD_COOLDOWN_SECS:-180}"
TAIL_LINES="${MODEL_GUARD_TAIL:-500}"
NOW=$(date +%s)

# --- state ------------------------------------------------------------------
TRIES=0; PENDING=0; LAST_EMIT=0; LAST_CFAIL=0; DERIVED=""
if [ -f "$STATE_FILE" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      tries)   TRIES=$v ;;
      pending) PENDING=$v ;;
      emit)    LAST_EMIT=$v ;;
      cfail)   LAST_CFAIL=$v ;;
      derived) DERIVED=$v ;;
    esac
  done < "$STATE_FILE"
fi
case "$TRIES"     in ''|*[!0-9]*) TRIES=0 ;; esac
case "$PENDING"   in ''|*[!0-9]*) PENDING=0 ;; esac
case "$LAST_EMIT" in ''|*[!0-9]*) LAST_EMIT=0 ;; esac
case "$LAST_CFAIL" in ''|*[!0-9]*) LAST_CFAIL=0 ;; esac

# Atomic: write a temp beside the target and rename. A truncate-write here is
# observable — a reader can see a half-written file, and two writers can lose an
# update. The SUBAGENT BAIL below removes the second writer, but "only one writer
# today" is not a reason to leave a torn read on the table.
write_state() {
  mkdir -p "$STATE_DIR" || return 0
  local tmp="$STATE_FILE.tmp.$$"
  printf 'tries=%s\npending=%s\nemit=%s\ncfail=%s\nderived=%s\n' \
    "$TRIES" "$PENDING" "$LAST_EMIT" "$LAST_CFAIL" "$DERIVED" > "$tmp" || { rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$STATE_FILE" || rm -f "$tmp"
  return 0
}

_json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# ledger_row <event> <action> <expected> <served> — best-effort, never fails the
# caller. A degradation that cannot be recorded is still a degradation; losing
# the instruction on top of it would be strictly worse.
ledger_row() {
  local event=$1 action=$2 expected=$3 served=$4 dir
  dir=$(dirname "$LEDGER")
  mkdir -p "$dir" || return 0
  printf '{"ts":"%s","epoch":%s,"row":"model-guard","session":"%s","expected":"%s","served":"%s","tries":%s,"event":"%s","action":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$NOW" \
    "$(_json_esc "$SESSION_ID")" "$(_json_esc "$expected")" "$(_json_esc "$served")" \
    "$TRIES" "$event" "$action" >> "$LEDGER" || return 0
}

# check_failed <why> — the fail-open path. Rate-limited by the same cooldown so
# a permanently broken read cannot spray one row per tool call.
check_failed() {
  if [ $(( NOW - LAST_CFAIL )) -ge "$COOLDOWN" ]; then
    LAST_CFAIL=$NOW
    write_state
    ledger_row "check-failed" "$1" "" ""
  fi
  exit 0
}

# --- normalisation ----------------------------------------------------------
# `claude-fable-5[1m]` and `claude-fable-5` are the same model; the settings key
# carries the context tag and the wire does not.
norm() { printf '%s' "$1" | sed -e 's/\[[^][]*\]$//' | tr '[:upper:]' '[:lower:]'; }

# same_model <expected> <served> — normalised equality, plus bare-alias matching
# so a seat declared `opus` is satisfied by `claude-opus-5`.
same_model() {
  local e s
  e=$(norm "$1"); s=$(norm "$2")
  [ -n "$e" ] && [ -n "$s" ] || return 1
  [ "$e" = "$s" ] && return 0
  case "$e" in
    fable|opus|sonnet|haiku) case "$s" in claude-"$e"-*) return 0 ;; esac ;;
  esac
  return 1
}

# --- read the transcript ----------------------------------------------------
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

# ── THE SUBAGENT BAIL ───────────────────────────────────────────────────────
# A SUBAGENT's PostToolUse invocation carries the PARENT's session_id but the
# SUBAGENT's transcript_path. Measured on this very bead's own agent, 2026-08-09:
#
#   transcript  …/-home-ubuntu-dotfiles/538b7ef4-…/subagents/agent-a75fc3d9….jsonl
#   session_id  538b7ef4-…                       <- the PARENT's
#   117 assistant rows, isSidechain:true on 100% of them, model claude-opus-5
#   meta.json    {"agentType":"subagent","model":"opus","spawnDepth":1}
#
# Every part of this hook is wrong in that context, three ways:
#   1. the sidechain filter empties SERVED -> a steady drip of `check-failed`
#      rows, one per cooldown per delegating session, burying real read errors;
#   2. the state file is keyed on session_id, i.e. the PARENT's — a second
#      writer stomping the parent's tries/pending/derived mid-episode;
#   3. that subagent is on claude-opus-5 ON PURPOSE (AGENTS.md: "Fable plans
#      and reviews, Opus/Sonnet implement"), so there is nothing to detect.
#
# So: bail SILENTLY. No ledger row, no state write — a delegating session is a
# normal condition, not a detection error, and ledgering it would poison the
# very counts dotfiles-7pbn is meant to surface. The test is structural: a main
# session's transcript is `<session_id>.jsonl`, a subagent's is
# `subagents/agent-<id>.jsonl`, so basename-minus-suffix == session_id iff this
# is the session's own transcript. A subagent's own degradation is out of scope
# here by construction — it has no /model to run and no pane to molt.
if [ -n "$TRANSCRIPT" ]; then
  _TB=$(basename "$TRANSCRIPT"); _TB=${_TB%.jsonl}
  [ "$_TB" = "$SESSION_ID" ] || exit 0
fi

[ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || check_failed "no-transcript"

# ONE jq pass over the tail, emitting two tagged facts. jq aborts on a partially
# written trailing line but has already emitted everything before it — that is
# the graceful degradation we want from a file being appended to live.
FACTS=$(tail -n "$TAIL_LINES" "$TRANSCRIPT" 2>/dev/null | jq -r '
  if .type == "assistant" and (.isSidechain // false | not) then
    (.message.model // empty) | select(. != "<synthetic>") | "S" + .
  elif .type == "system" and .subtype == "model_refusal_fallback"
       and (.isSidechain // false | not) then
    "O" + (.originalModel // "")
  else empty end' 2>/dev/null)

SERVED=$(printf '%s\n' "$FACTS" | grep '^S' | tail -n 1 | cut -c2-)
FALLBACK_ORIG=$(printf '%s\n' "$FACTS" | grep '^O' | tail -n 1 | cut -c2-)

# The client's own record of the intended model outlives the tail window once
# cached — scope is "session", so it never changes within one session.
if [ -n "$FALLBACK_ORIG" ] && [ -z "$DERIVED" ]; then
  DERIVED="$FALLBACK_ORIG"
  write_state
fi

[ -n "$SERVED" ] || check_failed "no-served-model"

# --- resolve EXPECTED (precedence in the header) ----------------------------
# _ancestor_model — the `--model <x>` an ancestor `claude` process was STARTED
# with, read off /proc. Same seam and same LOWER-BOUND caveat as
# pulse-inject.sh's _proc_model; Linux only, silent no-op elsewhere.
_ancestor_model() {
  local pid=${PPID:-0} depth=0 cmd model
  while [ "$pid" -gt 1 ] && [ "$depth" -lt 12 ]; do
    [ -r "/proc/$pid/cmdline" ] || return 1
    cmd=$(tr '\0' '\n' < "/proc/$pid/cmdline")
    case "$cmd" in
      *claude*)
        model=$(printf '%s\n' "$cmd" | awk '
          prev == "--model" { print; exit }
          /^--model=/       { sub(/^--model=/, ""); print; exit }
                            { prev = $0 }')
        [ -n "$model" ] && { printf '%s' "$model"; return 0; } ;;
    esac
    pid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    depth=$((depth + 1))
  done
  return 1
}

EXPECTED=""
EXPECTED_SRC=""
if [ -n "${MODEL_GUARD_EXPECTED:-}" ]; then
  EXPECTED="$MODEL_GUARD_EXPECTED"; EXPECTED_SRC="env"
elif [ -r "$OVERRIDE_FILE" ]; then
  EXPECTED=$(head -n 1 "$OVERRIDE_FILE" | tr -d '[:space:]'); EXPECTED_SRC="override"
elif [ -n "$DERIVED" ]; then
  EXPECTED="$DERIVED"; EXPECTED_SRC="refusal-fallback"
elif [ "${MODEL_GUARD_USE_PROC:-1}" != "0" ] && EXPECTED=$(_ancestor_model); then
  EXPECTED_SRC="proc"
elif [ "${MODEL_GUARD_USE_SETTINGS:-1}" != "0" ]; then
  SETTINGS="${MODEL_GUARD_SETTINGS:-$HOME/.claude/settings.json}"
  if [ -r "$SETTINGS" ]; then
    EXPECTED=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null); EXPECTED_SRC="settings"
  fi
fi

# `off` at any layer disables the guard for this seat — the escape hatch for a
# session that is INTENTIONALLY on another model.
case "$(norm "${EXPECTED:-}")" in off|none|any|disabled) exit 0 ;; esac

# Undeclared session: not a degraded one. Silent, no ledger row.
[ -n "$EXPECTED" ] || exit 0

# --- the comparison ---------------------------------------------------------
if same_model "$EXPECTED" "$SERVED"; then
  # Recovery: only interesting if we were mid-episode. Keeps `tries` — a session
  # knocked down, restored, and knocked down again must escalate, not restart.
  if [ "$PENDING" -eq 1 ]; then
    PENDING=0
    write_state
    ledger_row "recovered" "none" "$EXPECTED" "$SERVED"
  fi
  exit 0
fi

# Mismatch. Inside the cooldown of an already-instructed episode -> stay silent.
if [ "$PENDING" -eq 1 ] && [ $(( NOW - LAST_EMIT )) -lt "$COOLDOWN" ]; then
  exit 0
fi

TRIES=$((TRIES + 1))
PENDING=1
LAST_EMIT=$NOW
write_state

if [ "$TRIES" -le 1 ]; then ACTION=restore
elif [ "$TRIES" -eq 2 ]; then ACTION=molt
else ACTION=escalate
fi
ledger_row "detected" "$ACTION" "$EXPECTED" "$SERVED"

# The molt path is an EXAMPLE the agent will copy verbatim (this repo's rule 2),
# so the path is resolved from this hook's own location and only printed as an
# absolute path when it actually exists.
MOLT="$_MG_DIR/../scheduler/seat-molt.sh"
if [ -x "$MOLT" ]; then
  MOLT="$(cd "$(dirname "$MOLT")" && pwd)/seat-molt.sh"
else
  MOLT="agents/scheduler/seat-molt.sh (not found — check the agents tier)"
fi

EVIDENCE="expected '$EXPECTED' (source: $EXPECTED_SRC), actually served '$SERVED'"

case "$ACTION" in
  restore)
    echo "MODEL DEGRADATION (try $TRIES) — $EVIDENCE. Anthropic's precaution fallback has switched this session off its declared model; nothing else in the pane will tell you. RESTORE IT NOW, before your next unit of work: switch the session back with the /model slash command, argument '$EXPECTED'. Editing settings.json will NOT help — that key is read at process start only, so it cannot move a live session. Do not run another '$EXPECTED'-level scenario on '$SERVED' in the meantime. This guard re-checks every tool round and will tell you if the restore did not take." >&2
    ;;
  molt)
    echo "MODEL DEGRADATION (try $TRIES) — $EVIDENCE. The restore did not hold; this session has been knocked off its model again. MOLT IT WITH A MODEL CHANGE, now, in this order: (1) run /offboard — handoff note, commit, push; (2) switch the model back with /model '$EXPECTED'; (3) run: $MOLT --self --mode compact   — compact, NOT clear: it is the in-flight-safe mode and preserves background task handles. The fresh context must come up on '$EXPECTED'. Do not start new work on '$SERVED' first." >&2
    ;;
  *)
    echo "MODEL DEGRADATION (try $TRIES) — $EVIDENCE. STOP. Restore and molt have both failed; this session keeps being served '$SERVED'. Do NOT continue feeding '$EXPECTED'-level work to it silently. If a human is in the room: raise AskUserQuestion to Zig NOW — name the expected model, the served model, and that $TRIES attempts failed — and send a PushNotification alongside it, since a focused pane is not presence. If this is an autonomous tick with no human: file a P1 bead titled 'human: model degradation on session $SESSION_ID' describing the same, send the push, and END THE TICK. Take no further work on the wrong model either way." >&2
    ;;
esac

exit 2
