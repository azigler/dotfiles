#!/bin/bash
# pulse-escalate.sh — the keep-the-marshal-moving ladder (dotfiles-9z3o).
#
# THE PROBLEM. A scheduled seat has no human in the room. When its tick bounces
# because the window is blocked on a human (pulse-inject records
# reason=blocked_on_andrew and returns deferred-blocked-on-human) or because the
# composer never came up (reason=not_ready), NOTHING escalates: pulse-retry.sh —
# the only existing consumer of the bounce log — re-fires a loop ONLY after the 🔔
# has cleared, and skips not_ready entirely. So a persistent block escalates to
# nobody and the loop silently eats every fire until someone happens to look.
# Live evidence: maiden marshal night 2026-08-09 — a post-molt AskUserQuestion
# froze the seat, pulse-inject deferred twice, and the Esc recovery exposed the
# stale-🔔 defect (dotfiles-jisc).
#
# THE LADDER (Zig via the Master of Works, 2026-08-09), in order, no gaps:
#
#   0. GRACE   — for grace_minutes after the episode's FIRST bounce this script
#                does nothing at all. Zig's rung 2 ("a supervising session
#                nudges") is satisfied by standing still while someone else acts.
#   1. TRUTH   — the jisc reconciler. PROVE the block before escalating it, and
#                prove the ABSENCE of one before clearing a glyph: see TWO
#                INDEPENDENT SIGNALS below. Name-only trust is removed on this,
#                the consumer, side (jisc AC). This rung does NOT re-fire the
#                loop: see SINGLE OWNERSHIP below. It covers 🔔 AND the lying
#                🧠/🌀 (see THE LYING 🧠), and it is the ONLY rung an unlisted
#                loop ever reaches (see THE SCOPE SPLIT).
#   2. NUDGE   — modal chrome present => genuinely blocked => the front desk's
#                business. A SPECIFIC nudge naming the blocked seat, injected into
#                the seneschal window via pulse-inject --cmd (a real user turn).
#   3. RAISE   — no seneschal window, or it is itself 🔔: `systemctl --user start
#                <seneschal_unit>.service`, with the nudge carried in
#                $STATE_DIR/pulse-escalate-nudge.md so the raised brief has the
#                specifics rather than the daily default. Deliberately minimal —
#                see WINDOW SPAWNING IS NOT THIS SCRIPT'S JOB below.
#   4. FLOOR   — still bouncing after the ladder + a cooldown: a P1 `human:` bead
#                AND a push. Always reached; the ladder never dead-ends.
#
# TWO INDEPENDENT SIGNALS BEFORE ANY RENAME — and a JOINED capture.
#
# The first cut of rung 1 renamed on ONE signal: "the chrome ERE did not match".
# Adversarial review broke it in the obvious way — a NARROW pane. tmux hard-wraps
# a pane's lines at its width, so a real dialog renders as `Enter to sel` / `ect`
# and `❯ 1` / `. Yes`, no ERE alternative matches, and a LIVE modal is classified
# stale. The consequence chain is the worst one available: the glyph clears,
# pulse-retry (which owns the re-fire) sees a cleared 🔔 and re-fires, and the
# injection's trailing Enter answers Zig's open dialog with its default option.
#
# Both layers of the fix are load-bearing and each has its own mutant:
#
#   (a) CAPTURE JOINED — `tmux capture-pane -pJ`. -J joins soft-wrapped lines, so
#       wrapping can no longer split a chrome fragment in half.
#   (b) RENAME NEEDS POSITIVE EVIDENCE, not an absence. Clearing a glyph requires
#       chrome ABSENT *and* an IDLE COMPOSER present — the composer footer that an
#       open dialog does not render. Measured on this box 2026-08-09, joined
#       captures of a live 🔔 pane and a live ✅ pane:
#           chrome ERE   -> blocked 2 matches   idle 0 matches
#           composer ERE -> blocked 0 matches   idle 1 match
#       The composer ERE is pulse-inject's own READY_MARKER, reused rather than
#       re-derived: it is the fingerprint that injector already trusts to mean
#       "this pane can accept typed input", which is exactly the claim a rename
#       is about to make.
#
# So the classification is three-valued — blocked-chrome | idle-composer |
# AMBIGUOUS — and ONLY `idle-composer` renames. Every ambiguity (capture failed,
# capture empty, marker disabled, chrome absent but no composer either) is
# AMBIGUOUS and takes the escalation rungs. The reconciler can miss a stale 🔔; it
# cannot clear a live dialog. The three-way split is also what the log records, so
# "refused because chrome" and "refused because we could not tell" stay
# distinguishable in the telemetry.
#
# THE LYING 🧠 — THE SILENT-STALL CLASS THAT HAD NO WATCHER (dotfiles-t5fj).
#
# A seat whose turn DIES mid-flight leaves its window glyph reading 🧠 (or 🌀)
# forever: the lexicon says "thinking", the composer is idle, and nothing on the
# box disagrees. Four panes were in exactly that state on the morning of
# 2026-08-09. The lie is load-bearing in three directions at once:
#
#   * pulse-inject's --fresh same-loop guard refuses to type into what looks like
#     a live turn (verdict deferred-already-running, bounce reason
#     `already_running`), so EVERY scheduled tick for that seat defers — for as
#     long as the window lives, up to 24h.
#   * pulse-retry resolves on the same lying glyph, so the watcher that owns the
#     re-fire never sees a reason to act.
#   * this script's rung 1 fixed only 🔔.
#
# So the class had no watcher at all. Rung 1 now covers 🧠 and 🌀 on EXACTLY the
# same proof as 🔔 — one joined capture, chrome ABSENT, idle composer PROVEN — and,
# as with 🔔, it renames and STOPS. pulse-retry owns every re-fire.
#
# THE ASYMMETRY THAT MAKES THIS SAFE, stated because it is not obvious. For 🔔 the
# dangerous mistake is clearing a LIVE DIALOG, and signal 1 (chrome) is what
# catches it. For 🧠 the dangerous mistake is stripping the glyph off a LIVE TURN,
# and chrome says nothing whatever about that: the two glyphs are guarded by two
# different signals against two different failures, and neither is ever renamed on
# an absence.
#
# For 🧠, that guard is signal 2 PLUS SIGNAL 3, and the third one is not belt and
# braces. The premise handed to this build was "a mid-flight turn shows a spinner
# and NO composer footer, so the idle-composer requirement alone protects a live
# turn". That premise could not be verified here: the live tmux server is off
# limits while the marshal campaign runs, and the api-error capture corpus
# contains ZERO panes with a live spinner (671 rows, `esc to interrupt` matches
# none) — it only ever fires on panes whose turn has already died. An unverifiable
# premise is not a guard, and if it is wrong the failure is the worst one here:
# the composer footer renders under a running turn, the pane classifies idle, and
# a live turn's glyph is stripped. So the busy fingerprint is checked EXPLICITLY —
# `esc to interrupt`, the interrupt hint a turn shows only while it is running —
# and a pane carrying it is BUSY, never idle, whatever else is on the screen. If
# the premise was right the check is redundant; if it was wrong it is the whole
# guard. Cheap either way.
#
# THE SCOPE SPLIT — RECONCILIATION IS FLEET-SAFE, THE LADDER STAYS OPT-IN.
# `loops` remains the opt-in gate for rungs 2-4: that ladder's floor is a P1 bead
# and a push to Zig's phone, and nothing opts into a buzzing phone by accident.
# But the rung-1 VERB — strip a glyph after two independent proofs, tell nobody,
# re-fire nothing — summons no one and wakes no one, and the seats that stall
# silently are precisely the ones nobody thought to list. So a bouncing loop that
# is NOT in escalate.conf gets RECONCILIATION ONLY: capture, classify,
# rename-if-proven, stop. Zero nudge, zero raise, zero bead, zero push.
#
# An unlisted loop has no row to read, so its window is DERIVED — unit `pulse-<seat>`
# to window `<seat>`, in `reconcile_session` (default: the seneschal's session,
# which is where the fleet's seats live) — with the bare loop name tried as a
# fallback. Derivation cannot be dangerous here: a wrong guess simply matches no
# window and does nothing, which is the exact no-op an unlisted seat got before,
# and a right guess still has to clear both proofs. The result line keeps the two
# populations apart: `reconciled:N` is conf-listed, `reconciled-unlisted:N` is not,
# and `checked:N` still counts ONLY the loops the ladder itself is allowed to walk.
#
# SINGLE OWNERSHIP OF THE RE-FIRE DECISION (dotfiles-t5fj, measured 2026-08-09).
# pulse-retry.sh already decides whether a bounced tick gets re-fired, and re-fires
# on exactly the condition rung 1 creates: a window whose 🔔 has cleared. Tonight it
# beat a manual recovery by TWO SECONDS and queued a stale '/clear + /marshal night'
# pair into a LIVE run's composer. Two owners of one decision is that race. So this
# script NEVER runs `systemctl --user start <blocked-loop>.service` — it clears the
# lying glyph and stops, and the existing 2-minute watcher takes it from there under
# its own dedup and next-fire rules. (Rung 3 starting the SENESCHAL's unit is not an
# exception: that is a different loop's injection, not a re-fire of the blocked one.)
#
# WINDOW SPAWNING IS NOT THIS SCRIPT'S JOB (dotfiles-32mf, fleet rule: ONE spawn
# implementation). Rung 3 is exactly `systemctl --user start <seneschal_unit>` plus
# the nudge file, and it stays that way even when the seneschal WINDOW IS ABSENT and
# that injection therefore cannot land — the episode falls through to the floor on
# the next run, which is the same path a failed raise already takes. A generalized
# seat-spawn helper (spawn the owning seat's window with a guaranteed
# onboard/offboard) is being built under dotfiles-32mf; when it lands, this rung
# UPGRADES to call it. Growing a second spawn here would be the second
# implementation the fleet rule exists to prevent.
#
# AND THE LOG SAYS ONLY WHAT THIS SCRIPT DID. The same review caught pulse-retry
# claiming credit for clearing a 🔔 it merely outlived. An outcome owned by another
# mechanism never appears in these lines — renamed, nudged, raised, filed; never
# "re-fired", "unblocked" or "recovered".
#
# THE PUSH PATH IS REAL, AND THIS IS WHAT IT WIRES TO (investigated 2026-08-09).
# harnessd exposes POST /act/push/test (internal/daemon/push.go →
# push.Manager.SendTest → every subscribed device in
# ~/.local/state/harness/push-subs.json). It is behind actionGate: an
# `X-Harnessd-Action: 1` header, an allowlisted Origin, and a Tailscale whois of
# the peer. Measured from a plain shell ON zig-computer, against the daemon's
# tailnet bind (100.98.174.21:14174):
#
#   POST /act/push/unsubscribe {"endpoint":""}  + header + Origin -> 400 "missing endpoint"
#   POST /act/push/test        NOT-JSON         + header + Origin -> 400 "malformed JSON body"
#   POST /act/push/test        {}               no header         -> 403 "forbidden"
#
# The two 400s are the proof: the gate PASSED (403 is the gate's own answer) and
# the handler got past its `s.push == nil` check (that path is a 503), i.e. push
# is configured and the route is shell-callable with curl. So the floor is a P1
# `human:` bead AND a real push — not the bead alone.
#
# GAPS THIS BUILD DOES NOT CLOSE, stated rather than hidden:
#   * The raise rung's nudge FILE has no reader yet. `human:`-prefixed P1 beads
#     ARE read by seneschal-gather.py (it filters on exactly that prefix), so the
#     FLOOR rung is guaranteed-surfaced; the raise rung's extra specificity is
#     best-effort until /seneschal reads pulse-escalate-nudge.md.
#   * Both EREs are UI fingerprints. A Claude Code that changed its dialog footer
#     makes chrome read as absent; one that changed its composer footer makes the
#     idle signal read as absent. Either drift lands in AMBIGUOUS, which escalates
#     — never renames. Drift costs a false escalation, never a mis-answered dialog.
#
# OUTCOME CONTRACT. The LAST line of stdout is always
#
#   PULSE_ESCALATE_RESULT=checked:<n>:grace:<n>:reconciled:<n>:reconciled-unlisted:<n>:nudged:<n>:raised:<n>:floored:<n>:skipped:<n>:errors:<n>
#   PULSE_ESCALATE_RESULT=failed-config     (exit 78 — conf unreadable / not key=value)
#   PULSE_ESCALATE_RESULT=checker-broken    (exit 1  — THIS script cannot run
#                                            safely; ZERO actions were taken)
#
# Exit 0 on every other path: a best-effort watcher, where one loop's failure must
# never abort the rest (`set -uo pipefail`, no -e — pulse-retry.sh's posture, for
# pulse-retry.sh's reason).
#
# STATE IS A PRECONDITION, NOT A NICETY — the state directory is WRITE-PROBED
# before anything is read or touched, and an unwritable one is `checker-broken`,
# exit 1, nothing done. Adversarial review demonstrated the alternative: with the
# state dir read-only, the first cut reported `raised:1 … errors:0` and exit 0 on
# EVERY run, five minutes apart, because the rung it had "already fired" could
# never be remembered — an invisible repeat of `systemctl --user start`. A ladder
# that cannot persist which rung it is on has no ladder, only a first rung; the
# posture (and the vocabulary) is api-stall-recover.sh's, deliberately.
# `mkdir -p` alone is NOT that probe: it SUCCEEDS on an existing read-only
# directory, which is precisely the failure shape. A real file is created and
# removed.
#
# IDEMPOTENCY. State is per loop+EPISODE in $STATE_DIR/pulse-escalate-state.jsonl:
# {"loop","episode","rung","acted_ts"}. An EPISODE is the contiguous run of
# escalate-worthy bounces for one loop whose neighbours are within
# episode_gap_minutes, keyed by its FIRST bounce. One rung-action per run, at most
# one of each rung per episode, cooldown_minutes between rungs — and a rung only
# advances when the loop has bounced AGAIN since our action (newest bounce ts >
# acted_ts), so a rung that WORKED closes the episode and one that did not is
# followed by the next rung.
#
# NEVER: re-fire the blocked loop (single ownership, above); inject into any 🔔
# window (pulse-retry's precedent — the text would land in the modal and its Enter
# would answer it); act while the loop's own tick is in flight (`is-active`); write
# to the bounce log (read-only here).
#
# Test seams (env; production sets none of them). tmux / systemctl resolve through
# PATH, so a hermetic suite shims them:
#   HARNESS_STATE_DIR  · PULSE_ESCALATE_CONF · PULSE_ESCALATE_LOG
#   PULSE_ESCALATE_INJECT (pulse-inject.sh path) · PULSE_ESCALATE_BR · PULSE_ESCALATE_CURL
#   PULSE_ESCALATE_MODAL_MARKER — the dialog-chrome ERE; EMPTY disables the
#   reconciler, in the safe direction (every 🔔 then reads as genuinely blocked).
#   PULSE_ESCALATE_IDLE_MARKER  — the composer ERE (signal 2); EMPTY likewise
#   disables renaming, never blocking.
#   PULSE_ESCALATE_BUSY_MARKER  — the live-turn ERE (signal 3). EMPTY here is the
#   ONE knob that is NOT safe to blank — it removes the live-turn guard rather
#   than adding an ambiguity — so it is defaulted, documented, and left alone
#   outside the suite.

set -uo pipefail
export LC_ALL=C

STATE_DIR="${HARNESS_STATE_DIR:-$HOME/.local/state/harness}"

# THE WRITE PROBE. Before a single window is read or a single unit started: this
# ladder's whole idempotency is a file in here, so an unwritable state dir means
# every run re-fires the same rung forever with a clean verdict and exit 0. That
# is not a degraded mode, it is a broken checker — so it refuses, loudly, having
# touched nothing. `mkdir -p` cannot answer this on its own (it succeeds on an
# existing read-only directory); only writing a real file can.
_probe="$STATE_DIR/.pulse-escalate-probe.$$"
if ! mkdir -p "$STATE_DIR" || ! : > "$_probe"; then
  printf 'pulse-escalate: state directory %s is not writable — refusing to act\n' "$STATE_DIR" >&2
  printf '                without somewhere to remember which rung already fired.\n' >&2
  echo "PULSE_ESCALATE_RESULT=checker-broken"
  exit 1
fi
rm -f "$_probe"

LOG="${PULSE_ESCALATE_LOG:-$STATE_DIR/pulse-escalate.log}"
BOUNCES="$STATE_DIR/pulse-bounces.jsonl"
ESC_STATE="$STATE_DIR/pulse-escalate-state.jsonl"
NUDGE_FILE="$STATE_DIR/pulse-escalate-nudge.md"
_ME_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONF="${PULSE_ESCALATE_CONF:-$_ME_DIR/escalate.conf}"
INJECT="${PULSE_ESCALATE_INJECT:-$_ME_DIR/pulse-inject.sh}"
BR_BIN="${PULSE_ESCALATE_BR:-br}"
CURL_BIN="${PULSE_ESCALATE_CURL:-curl}"

# SIGNAL 1 — dialog chrome, from a live capture of a blocked pane (zig-computer,
# 2026-08-09): a numbered option list with a ❯ caret, closing on "Enter to select ·
# Tab/Arrow keys to navigate · Esc to cancel". Each phrase is matched
# independently because the footer wraps; -J on the capture is what stops a wrap
# splitting a phrase in half.
MODAL_MARKER="${PULSE_ESCALATE_MODAL_MARKER-Enter to select|Tab/Arrow keys to navigate|Esc to cancel|Do you want to (proceed|make this edit)|❯ [0-9]+\. }"

# SIGNAL 2 — an IDLE COMPOSER, the positive evidence a rename requires. This is
# pulse-inject.sh's READY_MARKER verbatim: the footer that injector already trusts
# to mean "this pane accepts typed input", which is the claim clearing a 🔔 makes.
# A pane showing a dialog renders NONE of it (measured: 0 matches on the live 🔔
# capture, 1 on the live ✅ capture).
# `manual mode on` added at install (2026-08-09): the arming drill launched a real
# claude whose footer read `⏸ manual mode on · ← for agents` — a permission-mode
# variant READY_MARKER never met, so a truly stale 🔔 over such a pane classified
# AMBIGUOUS and would escalate instead of reconciling. Safe direction, wrong
# outcome; the fleet's seats run bypass mode, so this is belt for scratch panes.
IDLE_MARKER="${PULSE_ESCALATE_IDLE_MARKER-shift\+tab to cycle|\? for shortcuts|bypass permissions on|accept edits on|plan mode on|manual mode on}"

# SIGNAL 3 — A LIVE TURN. The interrupt hint a running turn prints beside its
# spinner ("✻ Brewing… (esc to interrupt · ctrl+t for todos)") and an idle pane
# never does; a DIED turn prints the past-tense form with no hint at all
# ("✻ Worked for 2m 57s"), which is what the 2026-08-09 stalled captures show.
# This is signal 2's counterweight and the ONLY thing standing between a live
# 🧠 turn and a stripped glyph if the composer footer does render mid-turn — see
# THE ASYMMETRY in the header for why that premise is treated as unproven.
# A busy pane can never classify idle, whatever else is on the screen.
BUSY_MARKER="${PULSE_ESCALATE_BUSY_MARKER-esc to interrupt}"

TMUX_BIN=$(command -v tmux 2>>"$LOG")
[ -x "${TMUX_BIN:-}" ] || TMUX_BIN=/usr/bin/tmux
SYSTEMCTL_BIN=$(command -v systemctl 2>>"$LOG")
[ -x "${SYSTEMCTL_BIN:-}" ] || SYSTEMCTL_BIN=/usr/bin/systemctl

note() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

# --- Helpers (json_field / ts_key / strip_lexicon are pulse-retry.sh's, verbatim
# --- and for its stated reason: one line each, replication keeps the proven
# --- behaviour of both scripts independent).
json_field() { printf '%s' "$1" | sed -n -E "s/.*\"$2\":\"([^\"]*)\".*/\1/p"; }
ts_key() { printf '%s' "$1" | tr -cd '0-9'; }
strip_lexicon() { printf '%s' "$1" | sed -E 's/^(🧠|✅|🔔|🌀) ?//'; }
iso_epoch() { date -u -d "$1" +%s 2>>"$LOG"; }

# CONFIG — key=value only, and the parser REFUSES anything else (marshal.conf's
# parser, same argument: a config file that can execute is a config file that can
# be an incident, and this one is read by an unattended 5-minute loop).
declare -A CFG=()
CONF_ERROR=""
conf_load() {
  local file=$1 line key value n=0
  [ -r "$file" ] || { CONF_ERROR="config not readable: $file"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac
    if ! printf '%s' "$line" | grep -qE '^[a-z][a-z0-9_]*=[A-Za-z0-9_:,./~+-]*$'; then
      CONF_ERROR="config line $n is not a plain key=value: $line"
      return 1
    fi
    key=${line%%=*}; value=${line#*=}
    CFG[$key]=$value
  done < "$file"
  return 0
}
cfg() {
  local k=$1 d=${2:-}
  if [ -n "${CFG[$k]+set}" ] && [ -n "${CFG[$k]}" ]; then printf '%s' "${CFG[$k]}"; else printf '%s' "$d"; fi
}

CHECKED=0; GRACED=0; RECONCILED=0; RECON_UNLISTED=0
NUDGED=0; RAISED=0; FLOORED=0; SKIPPED=0; ERRORS=0
emit_result() {
  printf 'PULSE_ESCALATE_RESULT=checked:%s:grace:%s:reconciled:%s:reconciled-unlisted:%s:nudged:%s:raised:%s:floored:%s:skipped:%s:errors:%s\n' \
    "$CHECKED" "$GRACED" "$RECONCILED" "$RECON_UNLISTED" "$NUDGED" "$RAISED" "$FLOORED" "$SKIPPED" "$ERRORS"
}

conf_load "$CONF" || {
  note "FAIL: $CONF_ERROR"
  echo "pulse-escalate: $CONF_ERROR" >&2
  echo "PULSE_ESCALATE_RESULT=failed-config"
  exit 78
}

GRACE_S=$(( $(cfg grace_minutes 10) * 60 ))
COOLDOWN_S=$(( $(cfg cooldown_minutes 15) * 60 ))
GAP_S=$(( $(cfg episode_gap_minutes 45) * 60 ))
SEN_UNIT=$(cfg seneschal_unit pulse-seneschal)
SEN_WINDOW=$(cfg seneschal_window seneschal)
SEN_SESSION=$(cfg seneschal_session zig-computer)
SEN_DIR=$(cfg seneschal_dir "$HOME/dotfiles")
# Where an UNLISTED loop's seat window is looked for (THE SCOPE SPLIT). Defaults to
# the seneschal's session because that is the session the fleet's seats live in;
# it is a separate key so moving the front desk cannot silently move the sweep.
RECON_SESSION=$(cfg reconcile_session "$SEN_SESSION")
BEAD_REPO=$(cfg bead_repo "$HOME/dotfiles")
PUSH_URL=$(cfg push_url)
PUSH_ORIGIN=$(cfg push_origin)

# win_lookup <session> <window> — prints "<index> <live-name>" for the window whose
# LEXICON-STRIPPED name is <window>; empty output means absent. The index is what
# every later tmux call targets: a name carrying a 🔔 and a space is not a target
# anyone should be re-quoting.
win_lookup() {
  local session=$1 want=$2 line idx name
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    idx=${line%% *}; name=${line#* }
    [ "$(strip_lexicon "$name")" = "$want" ] || continue
    printf '%s %s' "$idx" "$name"; return 0
  done < <("$TMUX_BIN" list-windows -t "=$session" -F '#{window_index} #{window_name}' 2>>"$LOG")
  return 1
}

# pane_state <session> <index>
#   -> 0 blocked-chrome · 1 idle-composer · 2 AMBIGUOUS · 3 LIVE TURN.
# THE ONLY VALUE THAT MAY RENAME IS 1, and it requires POSITIVE evidence, not the
# absence of the other signals (see TWO INDEPENDENT SIGNALS in the header).
# -J joins soft-wrapped lines, so a narrow pane cannot split a chrome phrase in
# half and manufacture a `1`. Chrome wins ties: a pane showing both is a dialog.
# BUSY beats idle: a running turn may or may not render the composer footer under
# its spinner (unverifiable here — THE ASYMMETRY), so the interrupt hint decides.
pane_state() {
  local session=$1 idx=$2 pane
  [ -n "$MODAL_MARKER" ] || return 2                  # marker disabled => cannot tell
  pane=$("$TMUX_BIN" capture-pane -pJ -t "=$session:$idx" 2>>"$LOG")
  [ -n "$pane" ] || return 2                          # no capture => cannot tell
  printf '%s\n' "$pane" | grep -Eq "$MODAL_MARKER" && return 0
  if [ -n "$BUSY_MARKER" ] && printf '%s\n' "$pane" | grep -Eq "$BUSY_MARKER"; then
    return 3                                          # a turn is RUNNING — hands off
  fi
  [ -n "$IDLE_MARKER" ] || return 2
  printf '%s\n' "$pane" | grep -Eq "$IDLE_MARKER" && return 1
  return 2                                            # neither signal => cannot tell
}

# --- Read the bounce log (READ-ONLY to this script) ---------------------------
#
# THE EPISODE-TRIGGER REASON SET. `already_running` is pulse-inject's --fresh
# same-loop refusal (dotfiles-t5fj: `record_bounce "already_running"`, verdict
# `deferred-already-running`) — a tick deferred because the pane LOOKS mid-turn.
# Over a lying 🧠 that is a permanent refusal, so it is the single most important
# reason in this set, and rung 1 is exactly the fix for it. The `deferred-*` forms
# are the emitted VERDICT strings rather than bounce reasons; they are matched for
# the same defensive reason the human one already was — one writer, two vocabularies,
# and a filter that silently drops a whole class is invisible until someone stalls.
declare -A BTS=() BREASON=()
if [ -s "$BOUNCES" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    l=$(json_field "$line" loop); t=$(json_field "$line" ts); r=$(json_field "$line" reason)
    if [ -z "$l" ] || [ -z "$t" ]; then continue; fi
    case "$r" in blocked_on_andrew|deferred-blocked-on-human|not_ready|already_running|deferred-already-running) ;; *) continue ;; esac
    BTS[$l]="${BTS[$l]:-}$t"$'\n'
    BREASON[$l]="$r"
  done < "$BOUNCES"
fi

# --- Existing state -----------------------------------------------------------
declare -A S_EPISODE=() S_RUNG=() S_ACTED=()
if [ -s "$ESC_STATE" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    l=$(json_field "$line" loop); [ -n "$l" ] || continue
    S_EPISODE[$l]=$(json_field "$line" episode)
    S_RUNG[$l]=$(json_field "$line" rung)
    S_ACTED[$l]=$(json_field "$line" acted_ts)
  done < "$ESC_STATE"
fi

now=$(date +%s)
now_iso=$(date -u +%FT%TZ)
changed=0

# record <loop> <episode> <rung> — remember the rung we just acted on.
record() { S_EPISODE[$1]=$2; S_RUNG[$1]=$3; S_ACTED[$1]=$now_iso; changed=1; }

# --- THE TARGET LIST: conf-listed loops first, then everything else -------------
#
# Two populations, one body (THE SCOPE SPLIT in the header). `listed=1` walks the
# whole ladder; `listed=0` reaches rung 1 and stops. Building both up front keeps
# the ladder's opt-in gate exactly where it was — a loop is listed iff `loops`
# names it — while letting the fleet-safe rung see every bouncing seat.
declare -a TARGETS=()
declare -A IS_LISTED=()
IFS=, read -r -a LOOP_ROWS <<< "$(cfg loops)"
for row in "${LOOP_ROWS[@]:-}"; do
  [ -n "$row" ] || continue
  # ARITY IS CHECKED ON THE ROW, NOT ON THE FIELDS AFTER SPLITTING. `${row#*:}`
  # returns the WHOLE STRING when there is no colon, so a colonless row like
  # `pulse-marshal` used to survive an emptiness check with loop=window=session=
  # "pulse-marshal" and drive the ladder against a garbage window name. Adversarial
  # review found it; a positive shape match is the only honest test.
  if ! printf '%s' "$row" | grep -qE '^[^:]+:[^:]+:[^:]+$'; then
    note "skip malformed loops entry '$row' — want exactly <unit>:<window>:<session>"
    ERRORS=$((ERRORS + 1)); continue
  fi
  IS_LISTED[${row%%:*}]=1
  TARGETS+=("1|$row")
done

# Sorted, so a run's log reads the same way twice with the same input. A loop name
# carrying a ':' or a '|' would corrupt the packed row, and is not a systemd unit
# prefix anyway — refuse it rather than derive a window from half of it.
mapfile -t _bounced < <(printf '%s\n' "${!BTS[@]}" | sort)
for l in "${_bounced[@]}"; do
  [ -n "$l" ] || continue
  [ -n "${IS_LISTED[$l]+set}" ] && continue
  case "$l" in *:*|*'|'*) note "skip unlisted loop '$l': the name is not a plain unit prefix"; continue ;; esac
  TARGETS+=("0|$l:${l#pulse-}:$RECON_SESSION")
done

for target in "${TARGETS[@]:-}"; do
  [ -n "$target" ] || continue
  listed=${target%%|*}; row=${target#*|}
  loop=${row%%:*}; rest=${row#*:}; window=${rest%%:*}; session=${rest#*:}

  bl="${BTS[$loop]:-}"
  [ -n "$bl" ] || continue
  # `checked` counts the loops THE LADDER may walk, and only those — the scope
  # split adds a population, it does not silently inflate the ladder's own metric.
  [ "$listed" = 1 ] && CHECKED=$((CHECKED + 1))

  mapfile -t tss < <(printf '%s' "$bl" | sort)
  n=${#tss[@]}
  newest=${tss[n-1]}
  newest_ep=$(iso_epoch "$newest")
  [ -n "$newest_ep" ] || { note "skip $loop: unparseable bounce ts '$newest'"; ERRORS=$((ERRORS + 1)); continue; }

  # An episode whose newest bounce is older than the gap is OVER — the loop
  # recovered on its own and nothing here has any business acting.
  if [ $((now - newest_ep)) -gt "$GAP_S" ]; then SKIPPED=$((SKIPPED + 1)); continue; fi

  ep_start=$newest; prev=$newest_ep
  for ((i = n - 2; i >= 0; i--)); do
    e=$(iso_epoch "${tss[i]}") || break
    [ -n "$e" ] || break
    [ $((prev - e)) -le "$GAP_S" ] || break
    ep_start=${tss[i]}; prev=$e
  done
  ep_start_ep=$(iso_epoch "$ep_start")
  age_min=$(( (now - ep_start_ep) / 60 ))
  reason="${BREASON[$loop]:-unknown}"

  # Never act while the loop's own tick is genuinely in flight.
  st=$("$SYSTEMCTL_BIN" --user is-active "$loop.service" 2>>"$LOG")
  case "$st" in
    active|activating|reloading)
      note "skip $loop: its tick is in flight (is-active=$st)"; SKIPPED=$((SKIPPED + 1)); continue ;;
  esac

  # RUNG 0 — GRACE. A supervising session moves first.
  if [ $((now - ep_start_ep)) -lt "$GRACE_S" ]; then
    note "grace $loop: episode $ep_start is ${age_min}m old (< $((GRACE_S / 60))m) — leaving the first move to a supervisor"
    GRACED=$((GRACED + 1)); continue
  fi

  same_episode=0
  [ "${S_EPISODE[$loop]:-}" = "$ep_start" ] && same_episode=1
  rung=""; acted=""
  if [ "$same_episode" = 1 ]; then rung="${S_RUNG[$loop]:-}"; acted="${S_ACTED[$loop]:-}"; fi

  # A rung that WORKED closes the episode: nothing has bounced since we acted.
  # (`floored` is terminal either way — the floor never fires twice per episode.)
  if [ -n "$rung" ]; then
    if [ "$rung" = floored ]; then SKIPPED=$((SKIPPED + 1)); continue; fi
    nk=$(ts_key "$newest"); ak=$(ts_key "$acted")
    if [ "${nk:-0}" -le "${ak:-0}" ]; then
      SKIPPED=$((SKIPPED + 1)); continue
    fi
    acted_ep=$(iso_epoch "$acted")
    if [ -n "$acted_ep" ] && [ $((now - acted_ep)) -lt "$COOLDOWN_S" ]; then
      SKIPPED=$((SKIPPED + 1)); continue
    fi
  fi

  # RUNG 1 — TRUTH. The jisc reconciler: capture-pane before believing the glyph.
  # ⚠️ THE RENAME IS THE WHOLE RUNG — no re-fire (SINGLE OWNERSHIP, in the header).
  # What the truth probe actually established, carried verbatim into the nudge —
  # the front desk is told what was OBSERVED, never a confidence nobody earned.
  #
  # The window is looked up by CANDIDATE. A listed loop has exactly one: the
  # window its conf row names. An unlisted one has a derived pair — `pulse-<seat>`
  # stripped to `<seat>` first, then the bare loop name — and if neither matches,
  # `wl` stays empty and this rung is a no-op, which is the whole downside of
  # guessing wrong (THE SCOPE SPLIT).
  if [ "$listed" = 1 ]; then
    wcands=("$window")
  else
    wcands=("$window")
    [ "$window" = "$loop" ] || wcands+=("$loop")
  fi
  wl=""
  for cand in "${wcands[@]}"; do
    if wl=$(win_lookup "$session" "$cand"); then window=$cand; break; fi
    wl=""
  done

  pane_note="no '$window' window is present in $session"
  if [ -n "$wl" ]; then
    widx=${wl%% *}; wname=${wl#* }
    # WHICH GLYPH IS LYING. 🔔 claims a human is needed; 🧠/🌀 claim a turn is
    # running. Both are claims the pane can refute, and both are refuted by the
    # SAME two proofs — so the rung is one code path, not two (see THE LYING 🧠).
    # ✅ is not a lie about anything, and an unglyphed window has nothing to strip.
    glyph=""
    case "$wname" in
      🔔*) glyph=🔔 ;;
      🧠*) glyph=🧠 ;;
      🌀*) glyph=🌀 ;;
    esac
    pane_note="window '$wname' carries no 🔔/🧠/🌀 to reconcile"
    if [ -n "$glyph" ]; then
      pane_state "$session" "$widx"; pm=$?
      case "$pm" in
        0) pane_note="a joined capture-pane shows live dialog chrome — the block is real" ;;
        3) pane_note="a joined capture-pane shows a LIVE TURN (the interrupt hint is on screen) — the $glyph is telling the truth" ;;
        *) pane_note="a joined capture-pane could not classify the pane (no dialog chrome, no live turn, no idle composer) — treated as still working" ;;
      esac
      # ONLY `1` (idle composer PROVEN present, chrome and live-turn PROVEN absent,
      # in a JOINED capture) may rename. 0, 2 and 3 all decline — and they are
      # logged differently, so "refused because a dialog is up", "refused because a
      # turn is running" and "refused because we could not tell" stay
      # distinguishable in the telemetry.
      if [ "$pm" = 1 ]; then
        stripped=$(strip_lexicon "$wname")
        "$TMUX_BIN" rename-window -t "=$session:$widx" "$stripped" 2>>"$LOG"
        after=$("$TMUX_BIN" list-windows -t "=$session" -F '#{window_index} #{window_name}' 2>>"$LOG" \
                | sed -n -E "s/^$widx //p" | head -1)
        # VERIFIED AGAINST THE WHOLE LEXICON, not against the one glyph we came
        # here for: strip_lexicon removes any of the four, so "the name now equals
        # its own stripped form" is the honest post-condition, and it stays true
        # when a fifth glyph is added.
        if [ -n "$after" ] && [ "$after" = "$(strip_lexicon "$after")" ]; then
          # States ONLY what this script did — see the header's log clause.
          note "RENAMED $loop: window $widx '$wname' carried $glyph over an IDLE COMPOSER, with no dialog chrome and no live turn in the joined capture (stale glyph, dotfiles-jisc/t5fj); renamed to '$after' after verifying the rename took. No re-fire issued here — pulse-retry owns that decision."
          record "$loop" "$ep_start" reconciled
          if [ "$listed" = 1 ]; then
            RECONCILED=$((RECONCILED + 1))
          else
            RECON_UNLISTED=$((RECON_UNLISTED + 1))
          fi
          continue
        fi
        note "WARN: $loop: rename of window $widx did not clear $glyph (now '${after:-<gone>}')"
        ERRORS=$((ERRORS + 1)); continue
      fi
      # What happens NEXT is the scope split, so the log says which it is rather
      # than promising an escalation an unlisted loop will never get.
      if [ "$listed" = 1 ]; then next_step="escalating"; else next_step="reconciliation-only (unlisted loop: no nudge, no raise, no bead, no push)"; fi
      case "$pm" in
        0) note "$loop: pane $widx shows dialog CHROME PRESENT in the joined capture — genuinely blocked, $next_step" ;;
        3) note "$loop: pane $widx shows a LIVE TURN (BUSY) in the joined capture — the $glyph is true, never renaming over a running turn, $next_step" ;;
        *) note "$loop: pane $widx is AMBIGUOUS (no chrome, no live turn, no idle composer, or nothing captured) — $next_step, never renaming on an absence" ;;
      esac
    fi
  fi

  # ---- THE SCOPE SPLIT: rungs 2-4 are opt-in, rung 1 was not -------------------
  # An unlisted loop stops here, whatever rung 1 concluded. The ladder below ends
  # in a P1 bead and a push to Zig's phone; `loops` is the consent for that, and
  # nothing derived from a bounce log may grant it. (Reached only when rung 1 did
  # NOT reconcile — a successful reconcile has already `continue`d.)
  if [ "$listed" != 1 ]; then continue; fi

  # The nudge, carried by rungs 2 and 3 alike.
  nudge="Escalation from pulse-escalate — the '$window' seat (loop $loop, session $session) has not delivered a tick for ${age_min}m: it bounced $n time(s), newest reason '$reason', and $pane_note. You are the front desk: read that window, answer or reroute whatever is holding it so the loop's next tick can land. If it genuinely needs Zig, file the P1 human: bead and say so."

  # RUNG 2 — SENESCHAL DUTY. Never into a 🔔 window, and only a DELIVERED
  # injection counts (pulse-inject's own verdict is the evidence, not its exit code).
  if [ "$rung" != nudged ] && [ "$rung" != raised ]; then
    if sl=$(win_lookup "$SEN_SESSION" "$SEN_WINDOW"); then
      sname=${sl#* }
      if [ "$sname" != "${sname#🔔}" ]; then
        note "$loop: seneschal window '$sname' is itself 🔔 — not injecting; raising instead"
      elif [ -x "$INJECT" ]; then
        out=$("$INJECT" --dir "$SEN_DIR" --session "$SEN_SESSION" --window "$SEN_WINDOW" --cmd "$nudge" 2>&1)
        v=$(printf '%s\n' "$out" | grep -o 'PULSE_INJECT_RESULT=[a-z-]*' | tail -1 | cut -d= -f2-)
        if [ "$v" = injected ]; then
          note "NUDGED $loop: specific nudge delivered to $SEN_SESSION:$SEN_WINDOW (episode $ep_start, ${age_min}m)"
          record "$loop" "$ep_start" nudged
          NUDGED=$((NUDGED + 1)); continue
        fi
        note "$loop: seneschal nudge did NOT deliver (PULSE_INJECT_RESULT=${v:-<none>}) — raising instead"
      else
        note "$loop: no executable injector at $INJECT — raising instead"
      fi
    else
      note "$loop: no '$SEN_WINDOW' window in $SEN_SESSION — raising instead"
    fi
  fi

  # RUNG 3 — RAISE the seneschal, with the nudge carried.
  if [ "$rung" != raised ]; then
    { printf '# pulse-escalate nudge — %s\n\n%s\n' "$now_iso" "$nudge" > "$NUDGE_FILE"; } \
      || note "WARN: could not write $NUDGE_FILE (raising anyway)"
    if "$SYSTEMCTL_BIN" --user start "$SEN_UNIT.service" >>"$LOG" 2>&1; then
      note "RAISED $loop: started $SEN_UNIT.service; nudge carried in $NUDGE_FILE (episode $ep_start, ${age_min}m)"
      record "$loop" "$ep_start" raised
      RAISED=$((RAISED + 1)); continue
    fi
    note "WARN: $loop: 'systemctl --user start $SEN_UNIT.service' failed — falling through to the floor"
    ERRORS=$((ERRORS + 1))
  fi

  # RUNG 4 — THE FLOOR. P1 `human:` bead (seneschal-gather.py filters on exactly
  # that prefix, so this rung is the one that is GUARANTEED to surface) + push.
  title="human: $window seat blocked ${age_min}m — pulse-escalate ladder exhausted for $loop"
  desc="## Context
pulse-escalate.sh walked its whole ladder for loop '$loop' (seat window
'$window' in session '$session') and the loop is STILL bouncing: $n bounce(s)
in this episode, first at $ep_start, newest at $newest, reason '$reason'.
Grace, the stale-🔔 reconciler, the seneschal nudge and the seneschal raise have
all been tried. This is the floor rung: the loop needs a human.

## Task
Look at $session:$window, answer or dismiss whatever is holding it, and confirm
the loop's next tick lands.

## Acceptance Criteria
- [ ] The blocking modal in $session:$window is resolved
- [ ] $loop.service produces a delivered tick (no new bounce record)"
  if ( cd "$BEAD_REPO" && "$BR_BIN" create -t bug -p 1 -d "$desc" "$title" ) >>"$LOG" 2>&1; then
    note "FLOOR $loop: filed P1 human: bead in $BEAD_REPO"
  else
    note "WARN: $loop: 'br create' failed in $BEAD_REPO — the push below is the only floor left"
    ERRORS=$((ERRORS + 1))
  fi
  if [ -n "$PUSH_URL" ]; then
    body=$(python3 -c 'import json,sys; print(json.dumps({"title":sys.argv[1],"body":sys.argv[2],"all":True,"urgency":"high"}))' \
             "$window seat is stuck" "$title" 2>>"$LOG")
    code=$("$CURL_BIN" -sS -o /dev/null -w '%{http_code}' -X POST "$PUSH_URL" \
             -H 'X-Harnessd-Action: 1' -H "Origin: $PUSH_ORIGIN" \
             -H 'Content-Type: application/json' -d "$body" 2>>"$LOG")
    case "$code" in
      2*) note "FLOOR $loop: push delivered (HTTP $code)" ;;
      *)  note "WARN: $loop: push to $PUSH_URL returned HTTP ${code:-<none>}"; ERRORS=$((ERRORS + 1)) ;;
    esac
  else
    note "WARN: $loop: no push_url configured — the bead is the only floor"
  fi
  record "$loop" "$ep_start" floored
  FLOORED=$((FLOORED + 1))
done

# --- Write state atomically (only when something changed) ---------------------
if [ "$changed" = 1 ]; then
  tmp="$ESC_STATE.tmp.$$"
  : > "$tmp" || { note "FAIL: cannot write escalate-state tmp $tmp"; emit_result; exit 0; }
  for l in "${!S_EPISODE[@]}"; do
    printf '{"loop":"%s","episode":"%s","rung":"%s","acted_ts":"%s"}\n' \
      "$l" "${S_EPISODE[$l]}" "${S_RUNG[$l]:-}" "${S_ACTED[$l]:-}" >> "$tmp"
  done
  mv -f "$tmp" "$ESC_STATE" || { note "FAIL: cannot install escalate-state $ESC_STATE"; rm -f "$tmp"; }
fi

emit_result
exit 0
