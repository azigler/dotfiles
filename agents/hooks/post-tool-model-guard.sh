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
# ── THE COLD-START SEAM (dotfiles-8x8l) ─────────────────────────────────────
# MEASURED 2026-08-09: on the day the guard shipped, SIX of seven ledger rows
# were `check-failed / no-served-model` with both expected and served empty —
# the guard was blind 86% of the time while its ledger looked alive. All six
# correlate to the SAME instant, to the second: the session's FIRST tool round.
#
#   session   blind row     first tool_result in that session's transcript
#   c1a4bebd  11:38:41Z     11:38:41.685Z
#   a491e4bf  11:41:08Z     11:41:08.406Z
#   724edc28  15:05:27Z     15:05:27.309Z
#   d38310f1  15:45:55Z     15:45:55.328Z
#   81f50c07  16:59:48Z     16:59:48.618Z
#   6038861a  18:08:26Z     18:08:26.623Z
#
# Reproduced live, in a fresh interactive session under a scratch state root,
# with the transcript file snapshotted every 50ms (session 7e29e574, blind row
# at 21:37:47Z). The snapshot ring shows why: the client writes the turn's
# assistant rows as ONE BATCH, and that batch lands AFTER the tool has already
# run — so the file the hook reads at the first PostToolUse holds only the
# session preamble (mode / permission-mode / attachment / file-history-snapshot
# / user / last-prompt / ai-title) and NOT ONE assistant row:
#
#   21:37:45.772  12 lines   <- what the hook read.  ZERO assistant rows.
#   21:37:47.030             assistant tool_use row (timestamp, not write time)
#   21:37:47      ***        the guard fires: SERVED empty -> no-served-model
#   21:37:47.203  14 lines   <- the batch has landed: 2 assistant rows, model
#                               claude-haiku-4-5-20251001
#
# Rounds 2..N are unaffected — the window then already holds EARLIER assistant
# rows — which is exactly why each blind session produced ONE row and never a
# second. `model-guard-coldstart.fixture.jsonl` is that 12-line read, verbatim.
#
# Two consequences, and the hook implements both:
#   1. RE-READ. A read that finds no served model waits MODEL_GUARD_RETRY_SLEEP
#      and looks again, up to MODEL_GUARD_RETRIES times. The batch lands within
#      a few hundred ms, so the check usually recovers instead of being skipped.
#   2. NAME THE SHAPE. A check that still cannot see says WHY in the ledger, per
#      row, instead of a generic `no-served-model` (see the LEDGER block).
#
# ── FAIL-OPEN ───────────────────────────────────────────────────────────────
# A broken guard must never block normal work. Missing/unreadable transcript, no
# parseable assistant model, no jq: one rate-limited ledger row and exit 0, no
# instruction. Only a CONFIRMED mismatch ever emits. Exit 2 is
# used for the instruction because a PostToolUse hook's stderr is only shown to
# the agent on exit 2 — the tool has already run, so nothing is blocked or undone.
#
# ── LEDGER ──────────────────────────────────────────────────────────────────
# One append-only JSONL row per event at
# $HARNESS_STATE_DIR/model-degradation-ledger.jsonl:
#   {"ts","epoch","row","session","expected","served","tries","event","action"}
# `row` is the non-null row name ("model-guard") this repo's ledger convention
# requires — a null row name produced 23 bad rows across 3 projects once
# (dotfiles-mlti). Events: detected | recovered | check-failed | check-skipped.
#
# `action` on a blind round NAMES THE SHAPE — the whole point of dotfiles-8x8l,
# since a bare `check-failed` cannot distinguish "the guard is broken" from "the
# session has not spoken yet". `expected` is filled in on these rows too, so an
# auditor can see the guard knows the seat:
#   check-skipped no-assistant-row-yet            the cold-start read above:
#                                                 rows parsed, none of them an
#                                                 assistant row. Benign.
#   check-failed  no-transcript                   path missing or unreadable
#   check-failed  transcript-empty                zero lines in the window
#   check-failed  transcript-unparseable          lines present, jq parsed none
#   check-failed  assistant-rows-carry-no-model   assistant rows with no
#                                                 .message.model — a client
#                                                 shape change, worth knowing
#   check-failed  assistant-rows-all-synthetic    only <synthetic> placeholders
#   check-failed  assistant-rows-all-sidechain    only subagent rows in the
#                                                 window (the p89v shape, past
#                                                 the structural bail)
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
#   MODEL_GUARD_RETRIES          4     re-reads when no served model is visible
#   MODEL_GUARD_RETRY_SLEEP      0.25  seconds between those re-reads — 4 x 0.25
#                                      is a 1s ceiling, chosen against a MEASURED
#                                      race window: the growth log of a live
#                                      session shows the preamble at 21:53:08.157
#                                      (12 lines, 0 assistant rows) and the
#                                      assistant batch at 21:53:09.686 (14 lines,
#                                      2 assistant rows) — the hook fires
#                                      somewhere inside that ~1.5s gap, so it
#                                      wins on some rounds and not others.
#                                      THE CEILING IS COOLDOWN-GATED, and that is
#                                      a mechanism (the `retry` key in the state
#                                      file), not an aspiration: it is paid only
#                                      when the read is blind, and then at most
#                                      once per MODEL_GUARD_COOLDOWN_SECS per
#                                      session — including on seats that turn out
#                                      to be `off` or undeclared, whose spend is
#                                      recorded before those bails. Ungated, a
#                                      persistently blind shape paid it on EVERY
#                                      tool call: measured 1193/1155/1160ms on a
#                                      declared seat and 1228/1254/1220ms on an
#                                      `off` one, three consecutive calls inside
#                                      one cooldown. A mid-session round finds an
#                                      earlier assistant row on the first look
#                                      and never sleeps at all.
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
TRIES=0; PENDING=0; LAST_EMIT=0; LAST_CFAIL=0; LAST_RETRY=0; DERIVED=""
if [ -f "$STATE_FILE" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      tries)   TRIES=$v ;;
      pending) PENDING=$v ;;
      emit)    LAST_EMIT=$v ;;
      cfail)   LAST_CFAIL=$v ;;
      retry)   LAST_RETRY=$v ;;
      derived) DERIVED=$v ;;
    esac
  done < "$STATE_FILE"
fi
case "$TRIES"     in ''|*[!0-9]*) TRIES=0 ;; esac
case "$PENDING"   in ''|*[!0-9]*) PENDING=0 ;; esac
case "$LAST_EMIT" in ''|*[!0-9]*) LAST_EMIT=0 ;; esac
case "$LAST_CFAIL" in ''|*[!0-9]*) LAST_CFAIL=0 ;; esac
case "$LAST_RETRY" in ''|*[!0-9]*) LAST_RETRY=0 ;; esac

# Atomic: write a temp beside the target and rename. A truncate-write here is
# observable — a reader can see a half-written file, and two writers can lose an
# update. The SUBAGENT BAIL below removes the second writer, but "only one writer
# today" is not a reason to leave a torn read on the table.
write_state() {
  mkdir -p "$STATE_DIR" || return 0
  local tmp="$STATE_FILE.tmp.$$"
  printf 'tries=%s\npending=%s\nemit=%s\ncfail=%s\nretry=%s\nderived=%s\n' \
    "$TRIES" "$PENDING" "$LAST_EMIT" "$LAST_CFAIL" "$LAST_RETRY" "$DERIVED" > "$tmp" || { rm -f "$tmp"; return 0; }
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

# check_failed <event> <why> — the fail-open path. Rate-limited by the same
# cooldown so a permanently broken read cannot spray one row per tool call.
# <event> is check-failed for a real read error and check-skipped for a round
# the guard was never in a position to make (cold start); <why> NAMES the shape,
# and EXPECTED rides along so a blind row still says which seat it was watching.
# Every caller runs after EXPECTED has been resolved — that ordering is what
# dotfiles-8x8l bought, and it is why `${EXPECTED:-}` is a guard, not a default.
check_failed() {
  if [ $(( NOW - LAST_CFAIL )) -ge "$COOLDOWN" ]; then
    LAST_CFAIL=$NOW
    write_state
    ledger_row "$1" "$2" "${EXPECTED:-}" ""
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

# ONE jq pass over the tail, emitting two tagged facts. jq aborts on a partially
# written trailing line but has already emitted everything before it — that is
# the graceful degradation we want from a file being appended to live.
read_facts() {
  FACTS=""; SERVED=""; FALLBACK_ORIG=""; READ_FAIL=""
  if [ -z "$TRANSCRIPT" ] || [ ! -r "$TRANSCRIPT" ]; then
    READ_FAIL="no-transcript"
    return 0
  fi
  FACTS=$(tail -n "$TAIL_LINES" "$TRANSCRIPT" 2>/dev/null | jq -r '
  if .type == "assistant" and (.isSidechain // false | not) then
    (.message.model // empty) | select(. != "<synthetic>") | "S" + .
  elif .type == "system" and .subtype == "model_refusal_fallback"
       and (.isSidechain // false | not) then
    "O" + (.originalModel // "")
  else empty end' 2>/dev/null)

  SERVED=$(printf '%s\n' "$FACTS" | grep '^S' | tail -n 1 | cut -c2-)
  FALLBACK_ORIG=$(printf '%s\n' "$FACTS" | grep '^O' | tail -n 1 | cut -c2-)
  return 0
}

# THE COLD-START RE-READ (see the seam block in the header). The turn's assistant
# rows are written as a batch that can land AFTER this hook runs, so a first read
# with nothing in it is not evidence of anything yet — look again before giving up.
MG_RETRIES="${MODEL_GUARD_RETRIES:-4}"
case "$MG_RETRIES" in ''|*[!0-9]*) MG_RETRIES=0 ;; esac
MG_ATTEMPT=0
while : ; do
  read_facts
  { [ -z "$READ_FAIL" ] && [ -n "$SERVED" ]; } && break
  [ "$MG_ATTEMPT" -ge "$MG_RETRIES" ] && break
  # THE COOLDOWN GATE. Without it the ceiling is paid on EVERY tool call of a
  # persistently blind shape (unreadable path, all-sidechain or all-synthetic
  # tail) — measured at ~1.2s per call, three calls in a row, on the hottest
  # hook in the fleet. `retry` is its OWN timestamp and not `cfail`, because the
  # two rate limits gate different things and must not consume each other: the
  # spend is recorded here, before the `off` / undeclared bails below, so a seat
  # that emits no ledger row at all is still charged at most once per cooldown.
  if [ "$MG_ATTEMPT" -eq 0 ]; then
    [ $(( NOW - LAST_RETRY )) -ge "$COOLDOWN" ] || break
    LAST_RETRY=$NOW
    write_state
  fi
  MG_ATTEMPT=$((MG_ATTEMPT + 1))
  sleep "${MODEL_GUARD_RETRY_SLEEP:-0.25}"
done

# diagnose_blind — WHY is there no served model? Runs only on the blind path, so
# the extra jq pass costs nothing in the common case. Reasons are ordered from
# "nothing was there" outward to "rows were there but none of them counts";
# `no-assistant-row-yet` is the cold-start shape and the only benign one.
diagnose_blind() {
  local win lines tags rows n_side n_syn n_nomod
  win=$(tail -n "$TAIL_LINES" "$TRANSCRIPT" 2>/dev/null)
  lines=$(printf '%s\n' "$win" | grep -c . )
  [ "$lines" -eq 0 ] && { printf 'transcript-empty'; return 0; }
  tags=$(printf '%s\n' "$win" | jq -r '
    if .type == "assistant" then
      (if (.isSidechain // false) then "sidechain"
       elif (.message.model // "") == "" then "nomodel"
       elif .message.model == "<synthetic>" then "synthetic"
       else "served" end)
    else "other" end' 2>/dev/null)
  rows=$(printf '%s\n' "$tags" | grep -c . )
  [ "$rows" -eq 0 ] && { printf 'transcript-unparseable'; return 0; }
  n_side=$(printf '%s\n' "$tags" | grep -c '^sidechain$')
  n_syn=$(printf '%s\n' "$tags" | grep -c '^synthetic$')
  n_nomod=$(printf '%s\n' "$tags" | grep -c '^nomodel$')
  if [ $(( n_side + n_syn + n_nomod )) -eq 0 ]; then
    printf 'no-assistant-row-yet'
  elif [ "$n_nomod" -gt 0 ]; then
    printf 'assistant-rows-carry-no-model'
  elif [ "$n_syn" -gt 0 ]; then
    printf 'assistant-rows-all-synthetic'
  else
    printf 'assistant-rows-all-sidechain'
  fi
  return 0
}

# The client's own record of the intended model outlives the tail window once
# cached — scope is "session", so it never changes within one session.
if [ -n "$FALLBACK_ORIG" ] && [ -z "$DERIVED" ]; then
  DERIVED="$FALLBACK_ORIG"
  write_state
fi

# NOTE THE ORDER. The blind-round decision is deliberately made AFTER the
# EXPECTED resolution below, not here (where it used to live), for two reasons:
# a blind row can then carry the seat it was watching instead of two empty
# fields, and a seat that is `off` or undeclared stops emitting blind rows it
# was never going to act on. DERIVED is the reason the parse still comes first.
#
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

# --- the blind round, NAMED (dotfiles-8x8l) ---------------------------------
# Reached only for a declared seat whose model we could not read. Say which of
# the shapes it was; `no-assistant-row-yet` is the benign cold start, so it is
# ledgered as check-SKIPPED, not check-failed — a guard that has not had its
# turn yet is not a guard that broke, and conflating the two is what made six
# of seven rows unreadable on 2026-08-09.
[ -z "$READ_FAIL" ] || check_failed "check-failed" "$READ_FAIL"
if [ -z "$SERVED" ]; then
  BLIND_WHY=$(diagnose_blind)
  case "$BLIND_WHY" in
    no-assistant-row-yet) check_failed "check-skipped" "$BLIND_WHY" ;;
    *)                    check_failed "check-failed"  "$BLIND_WHY" ;;
  esac
fi

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
