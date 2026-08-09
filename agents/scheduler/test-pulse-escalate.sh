#!/bin/bash
# Test for pulse-escalate.sh — the keep-the-marshal-moving ladder (dotfiles-9z3o).
#
# HERMETIC, and it has to be: a LIVE marshal drain runs on this box. Every external
# hand is a shim on PATH — `tmux`, `systemctl`, `br`, `curl` — plus a recorder stub for
# pulse-inject.sh, and HARNESS_STATE_DIR / PULSE_ESCALATE_CONF point at per-case
# tmpdirs. No real tmux server, no real systemd unit, no real bead, no real push, and
# the real ~/.local/state/harness/pulse-bounces.jsonl is never opened.
#
# The shims read $PE_FAKE (a per-case control dir):
#   $PE_FAKE/windows/<session>   — "<index> <name>" per line; the fake tmux's window list,
#                                  REWRITTEN in place by `rename-window` (so a case can
#                                  assert the reconciler's verified rename actually took)
#   $PE_FAKE/panes/<sess>-<idx>  — what `capture-pane -p` prints for that window
#   $PE_FAKE/renames             — every rename-window, appended
#   $PE_FAKE/started             — every `systemctl --user start`ed unit
#   $PE_FAKE/isactive/<unit>     — what `systemctl --user is-active <unit>` prints
#   $PE_FAKE/br-calls            — every `br` invocation
#   $PE_FAKE/curl-calls          — every `curl` invocation ($PE_FAKE/curl-body: its -d)
#   $PE_FAKE/inject-calls        — every pulse-inject invocation
# Knobs: PE_RENAME_NOOP=1 (a rename that silently does not take), PE_CURL_CODE,
#        PE_INJECT_VERDICT.
#
# CASE NAMES START WITH THEIR NUMBER on purpose: mutate-pulse-escalate.sh maps each
# mutant to the case(s) it must kill by parsing `  - <n> ...` out of the summary below.
#
# Convention matches the rest of agents/scheduler/test-*: executable bash, non-zero exit
# = failure, PASS/FAIL summary on the last line.

set -u

ESC="$(cd "$(dirname "$0")" && pwd)/pulse-escalate.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

BIN="$ROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/tmux" <<'EOTM'
#!/bin/bash
# Fake tmux — list-windows / capture-pane / rename-window, backed by $PE_FAKE.
cmd="${1:-}"; shift || true
tgt=""; new=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t) tgt="${2:-}"; shift 2 ;;
    -F) shift 2 ;;
    -p) shift ;;
    *)  new="$1"; shift ;;
  esac
done
tgt="${tgt#=}"
sess="${tgt%%:*}"
idx="${tgt##*:}"
case "$cmd" in
  list-windows)
    f="$PE_FAKE/windows/$sess"
    [ -f "$f" ] && cat "$f"
    ;;
  capture-pane)
    f="$PE_FAKE/panes/$sess-$idx"
    [ -f "$f" ] && cat "$f"
    ;;
  rename-window)
    printf '%s %s %s\n' "$sess" "$idx" "$new" >> "$PE_FAKE/renames"
    f="$PE_FAKE/windows/$sess"
    if [ -f "$f" ] && [ "${PE_RENAME_NOOP:-0}" != 1 ]; then
      : > "$f.tmp"
      while IFS= read -r l; do
        if [ "${l%% *}" = "$idx" ]; then printf '%s %s\n' "$idx" "$new" >> "$f.tmp"
        else printf '%s\n' "$l" >> "$f.tmp"; fi
      done < "$f"
      mv -f "$f.tmp" "$f"
    fi
    ;;
esac
exit 0
EOTM

cat > "$BIN/systemctl" <<'EOSC'
#!/bin/bash
# Fake systemctl — records every call; answers is-active, records start.
echo "$*" >> "$PE_FAKE/calls"
sub=""; unit=""
for a in "$@"; do
  case "$a" in
    is-active) sub=is-active ;;
    start)     sub=start ;;
    *.service|*.timer) unit="$a" ;;
  esac
done
case "$sub" in
  start) echo "$unit" >> "$PE_FAKE/started" ;;
  is-active)
    f="$PE_FAKE/isactive/$unit"
    if [ -f "$f" ]; then cat "$f"; else echo inactive; fi
    ;;
esac
exit 0
EOSC

cat > "$BIN/br" <<'EOBR'
#!/bin/bash
# ONE recorded line per invocation — a bead description is multi-line by construction,
# and a case that counts invocations must not count its paragraphs.
printf '%s' "$*" | tr '\n' ' ' >> "$PE_FAKE/br-calls"
printf '\n' >> "$PE_FAKE/br-calls"
exit "${PE_BR_RC:-0}"
EOBR

cat > "$BIN/curl" <<'EOCU'
#!/bin/bash
printf '%s\n' "$*" >> "$PE_FAKE/curl-calls"
prev=""
for a in "$@"; do
  [ "$prev" = "-d" ] && printf '%s\n' "$a" >> "$PE_FAKE/curl-body"
  prev="$a"
done
printf '%s' "${PE_CURL_CODE:-200}"
exit 0
EOCU

chmod +x "$BIN/tmux" "$BIN/systemctl" "$BIN/br" "$BIN/curl"
export PATH="$BIN:$PATH"

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

ago_iso() { date -u -d "-$1 minutes" +%FT%TZ; }

# --- The two pane fixtures the whole reconciler turns on ----------------------
#
# MODAL: transcribed from a LIVE capture of a blocked pane on zig-computer
# (2026-08-09, the hevyd seat) — the numbered option list with its ❯ caret and the
# dialog footer. The footer WRAPS mid-phrase ("Esc to" / "cancel"), which is exactly
# why the marker matches each phrase independently rather than the whole line.
MODAL_PANE='──────────────────────────────────────────────
↰  ☐ Creatine start  ☐ Waist reading  ✔ Submit  ↱

Reminder 7 — creatine: the plan was Sun 08-09, 5 g,
right after you weigh. What is the real first-dose
date?

❯ 1. Today, 2026-08-09
     Took the first 5 g today
  2. Not yet — have not started
  3. Chat about this

Enter to select · Tab/Arrow keys to navigate · Esc to
cancel'

# IDLE: the composer of a session whose AskUserQuestion was CANCELLED with Esc —
# dotfiles-jisc's stale 🔔. The window name still carries the glyph; the pane holds
# no dialog at all. Note "shift+tab to cycle" / "? for shortcuts": the readiness
# marker pulse-inject polls for, and NOT modal chrome.
IDLE_PANE='> Try "edit <filepath> to ..."

  ? for shortcuts                          shift+tab to cycle'

# setup_case — a fresh state dir + control dir + conf. Every knob is defaulted to the
# marshal-shaped happy path; a case overrides only what it is about.
setup_case() {
  CASE=$(mktemp -d)
  PE_FAKE=$(mktemp -d)
  mkdir -p "$PE_FAKE/windows" "$PE_FAKE/panes" "$PE_FAKE/isactive" "$CASE/repo"
  export HARNESS_STATE_DIR="$CASE"
  export PE_FAKE
  unset PE_RENAME_NOOP PE_CURL_CODE PE_BR_RC PE_INJECT_VERDICT
  cat > "$PE_FAKE/inject" <<'EOIN'
#!/bin/bash
printf '%s' "$*" | tr '\n' ' ' >> "$PE_FAKE/inject-calls"
printf '\n' >> "$PE_FAKE/inject-calls"
printf 'PULSE_INJECT_RESULT=%s\n' "${PE_INJECT_VERDICT:-injected}"
exit 0
EOIN
  chmod +x "$PE_FAKE/inject"
  export PULSE_ESCALATE_INJECT="$PE_FAKE/inject"
  export PULSE_ESCALATE_CONF="$CASE/escalate.conf"
  export PULSE_ESCALATE_BR="$BIN/br"
  export PULSE_ESCALATE_CURL="$BIN/curl"
  unset PULSE_ESCALATE_MODAL_MARKER
  cat > "$CASE/escalate.conf" <<EOCONF
loops=pulse-marshal:marshal:zig-computer
grace_minutes=10
cooldown_minutes=15
episode_gap_minutes=45
seneschal_unit=pulse-seneschal
seneschal_window=seneschal
seneschal_session=zig-computer
seneschal_dir=$CASE/repo
bead_repo=$CASE/repo
push_url=http://127.0.0.1:1/act/push/test
push_origin=http://127.0.0.1:1
EOCONF
  # The default fleet: a 🔔 marshal window at index 1, an idle seneschal at index 2.
  printf '1 🔔 marshal\n2 ✅ seneschal\n' > "$PE_FAKE/windows/zig-computer"
  printf '%s\n' "$MODAL_PANE" > "$PE_FAKE/panes/zig-computer-1"
  printf '%s\n' "$IDLE_PANE"  > "$PE_FAKE/panes/zig-computer-2"
}

bounce() { # bounce <minutes-ago> [reason] [loop]
  printf '{"ts":"%s","loop":"%s","reason":"%s"}\n' \
    "$(ago_iso "$1")" "${3:-pulse-marshal}" "${2:-blocked_on_andrew}" \
    >> "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
}
prior_state() { # prior_state <episode-ts> <rung> <acted-minutes-ago>
  printf '{"loop":"pulse-marshal","episode":"%s","rung":"%s","acted_ts":"%s"}\n' \
    "$1" "$2" "$(ago_iso "$3")" > "$HARNESS_STATE_DIR/pulse-escalate-state.jsonl"
}
run() { OUT=$("$ESC" 2>&1); RC=$?; VERDICT=$(printf '%s\n' "$OUT" | tail -1); }
count() { [ -f "$PE_FAKE/$1" ] && wc -l < "$PE_FAKE/$1" | tr -d ' ' || echo 0; }
rung_of() { sed -n -E 's/.*"rung":"([^"]*)".*/\1/p' "$HARNESS_STATE_DIR/pulse-escalate-state.jsonl" 2>/dev/null | head -1; }
winname() { sed -n -E "s/^$1 //p" "$PE_FAKE/windows/zig-computer" | head -1; }
v_has() { case "$VERDICT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------------------
# Case 1: GRACE. An episode younger than grace_minutes gets NOTHING — no rename, no
#   inject, no start, no state. Rung 2 of Zig's ladder is a supervising session, and
#   this watcher satisfies it by standing still.
setup_case
bounce 3
run
if [ "$RC" = 0 ] && [ "$(count renames)" = 0 ] && [ "$(count inject-calls)" = 0 ] \
   && [ "$(count started)" = 0 ] && v_has "grace:1" && [ ! -f "$HARNESS_STATE_DIR/pulse-escalate-state.jsonl" ]; then
  ok
else
  bad "1 grace: a 3-minute-old episode is left entirely alone (rc=$RC verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 2: THE RECONCILER (dotfiles-jisc). 🔔 NAME + NO dialog chrome in the pane =>
#   a VERIFIED rename that clears the glyph, and the episode closes at rung
#   `reconciled`. NOTHING is escalated to a human.
setup_case
printf '%s\n' "$IDLE_PANE" > "$PE_FAKE/panes/zig-computer-1"
bounce 25
run
if [ "$(count renames)" = 1 ] && [ "$(winname 1)" = "marshal" ] \
   && [ "$(rung_of)" = reconciled ] && [ "$(count inject-calls)" = 0 ] && v_has "reconciled:1"; then
  ok
else
  bad "2 reconcile: stale 🔔 (no chrome) is renamed and verified (renames=$(count renames) name='$(winname 1)' rung=$(rung_of) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 2b: SINGLE OWNERSHIP OF THE RE-FIRE (dotfiles-t5fj — pulse-retry beat a manual
#   recovery by two seconds and queued a stale '/clear + /marshal night' pair into a live
#   composer). The rename is the WHOLE rung. Asserted on every `systemctl` call, not just
#   `start`s: the in-flight `is-active` probe is the only one this path may make.
setup_case
printf '%s\n' "$IDLE_PANE" > "$PE_FAKE/panes/zig-computer-1"
bounce 25
run
if [ "$(count started)" = 0 ] && ! grep -q 'start' "$PE_FAKE/calls" \
   && [ "$(grep -c 'pulse-marshal.service' "$PE_FAKE/calls")" = 1 ] \
   && grep -q 'is-active pulse-marshal.service' "$PE_FAKE/calls"; then
  ok
else
  bad "2b single-owner: the reconcile path never re-fires the blocked loop (started=$(count started) calls=$(tr '\n' '|' < "$PE_FAKE/calls"))"
fi

# ---------------------------------------------------------------------------
# Case 2c: THE LOG CLAIMS NO OUTCOME IT DOES NOT OWN. t5fj also caught pulse-retry's log
#   taking credit for clearing a 🔔 it merely outlived, and a dishonest causation line
#   poisons the telemetry every later escalation decision reads.
setup_case
printf '%s\n' "$IDLE_PANE" > "$PE_FAKE/panes/zig-computer-1"
bounce 25
run
LOGTXT=$(cat "$HARNESS_STATE_DIR/pulse-escalate.log" 2>/dev/null)
if printf '%s' "$LOGTXT" | grep -q 'RENAMED pulse-marshal' \
   && ! printf '%s' "$LOGTXT" | grep -Eq 're-fired|refired|unblocked|recovered'; then
  ok
else
  bad "2c honest-log: the reconcile line reports the rename and claims no outcome it does not own"
fi

# ---------------------------------------------------------------------------
# Case 3: THE OTHER HALF OF THE SAME GUARD — a GENUINE AskUserQuestion. The chrome is
#   present, so the window is NEVER renamed. This is the case that stops the reconciler
#   answering Zig's open question by clearing its glyph out from under it.
setup_case
bounce 25
run
if [ "$(count renames)" = 0 ] && [ "$(rung_of)" != reconciled ]; then
  ok
else
  bad "3 modal-present: a live dialog is never renamed (renames=$(count renames) rung=$(rung_of))"
fi

# ---------------------------------------------------------------------------
# Case 4: SENESCHAL DUTY. Genuine modal => a SPECIFIC nudge into the seneschal window,
#   through pulse-inject's --cmd pathway, naming the blocked seat and its loop.
setup_case
bounce 25
run
if [ "$(count inject-calls)" = 1 ] && v_has "nudged:1" && [ "$(rung_of)" = nudged ] \
   && grep -q -- "--window seneschal" "$PE_FAKE/inject-calls" \
   && grep -q "marshal" "$PE_FAKE/inject-calls" \
   && grep -q "pulse-marshal" "$PE_FAKE/inject-calls"; then
  ok
else
  bad "4 nudge: a genuinely blocked seat produces one seneschal injection naming it (injects=$(count inject-calls) rung=$(rung_of) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 5: NEVER INJECT INTO A 🔔 WINDOW (pulse-retry's precedent — the text would land
#   in the modal and the Enter would answer it). A 🔔 seneschal is skipped entirely and
#   the ladder RAISES instead; no injection is even attempted.
setup_case
printf '1 🔔 marshal\n2 🔔 seneschal\n' > "$PE_FAKE/windows/zig-computer"
bounce 25
run
if [ "$(count inject-calls)" = 0 ] && grep -qx "pulse-seneschal.service" "$PE_FAKE/started" \
   && [ "$(rung_of)" = raised ] && v_has "raised:1"; then
  ok
else
  bad "5 blocked-seneschal: a 🔔 front desk is never injected into; the ladder raises (injects=$(count inject-calls) rung=$(rung_of))"
fi

# ---------------------------------------------------------------------------
# Case 6: SENESCHAL ABSENT => RAISE, with the nudge CARRIED in the state dir so the
#   raised brief can surface this blockage and not just the daily default.
setup_case
printf '1 🔔 marshal\n' > "$PE_FAKE/windows/zig-computer"
bounce 25
run
if grep -qx "pulse-seneschal.service" "$PE_FAKE/started" && [ "$(rung_of)" = raised ] \
   && [ -s "$HARNESS_STATE_DIR/pulse-escalate-nudge.md" ] \
   && grep -q "pulse-marshal" "$HARNESS_STATE_DIR/pulse-escalate-nudge.md"; then
  ok
else
  bad "6 raise: an absent seneschal is raised and the nudge is carried in pulse-escalate-nudge.md (rung=$(rung_of))"
fi

# ---------------------------------------------------------------------------
# Case 7: THE FLOOR. Already `raised`, cooldown elapsed, and the loop has bounced AGAIN
#   since => a P1 `human:` bead AND a push. The `human:` prefix is load-bearing:
#   seneschal-gather.py filters on exactly that string.
setup_case
EP=$(ago_iso 60)
printf '{"ts":"%s","loop":"pulse-marshal","reason":"blocked_on_andrew"}\n' "$EP" \
  > "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
bounce 30
bounce 1
prior_state "$EP" raised 20
run
if [ "$(count br-calls)" = 1 ] && grep -q 'human:' "$PE_FAKE/br-calls" && grep -q -- '-p 1' "$PE_FAKE/br-calls" \
   && [ "$(count curl-calls)" = 1 ] && [ "$(rung_of)" = floored ] && v_has "floored:1"; then
  ok
else
  bad "7 floor: an exhausted ladder files a P1 human: bead AND pushes (br=$(count br-calls) curl=$(count curl-calls) rung=$(rung_of) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 8: NOT_READY EPISODES ESCALATE. pulse-retry.sh skips this reason entirely, which
#   is the hole this watcher exists to close: a composer that never comes up is a
#   stalled loop with nobody told. No 🔔 anywhere, so the ladder goes straight to the
#   front desk.
setup_case
printf '1 ✅ marshal\n2 ✅ seneschal\n' > "$PE_FAKE/windows/zig-computer"
bounce 25 not_ready
bounce 20 not_ready
run
if [ "$(count inject-calls)" = 1 ] && [ "$(rung_of)" = nudged ] && v_has "checked:1" \
   && grep -q "not_ready" "$PE_FAKE/inject-calls"; then
  ok
else
  bad "8 not_ready: a not_ready episode escalates and the nudge names the reason (injects=$(count inject-calls) rung=$(rung_of) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 9: NON-CRITICAL LOOPS ARE IGNORED. `loops` is the opt-in gate; a seat that is not
#   listed is never escalated however hard it bounces. (The ladder ends in a push to
#   Zig's phone — nothing opts in by accident.)
setup_case
bounce 25 blocked_on_andrew pulse-hevyd-recap
bounce 20 blocked_on_andrew pulse-dive
run
if v_has "checked:0" && [ "$(count inject-calls)" = 0 ] && [ "$(count started)" = 0 ] \
   && [ "$(count renames)" = 0 ] && [ "$(count br-calls)" = 0 ]; then
  ok
else
  bad "9 opt-in: loops absent from escalate.conf are never escalated (verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 10: IN-FLIGHT GUARD. The loop's own tick is running right now — escalating over
#   it would nudge a human about work that is in progress.
setup_case
echo active > "$PE_FAKE/isactive/pulse-marshal.service"
bounce 25
run
if [ "$(count inject-calls)" = 0 ] && [ "$(count renames)" = 0 ] && v_has "skipped:1"; then
  ok
else
  bad "10 in-flight: nothing escalates while the loop's tick is active (injects=$(count inject-calls) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 11: COOLDOWN. A rung fired 2 minutes ago; the ladder does not fire another one
#   inside cooldown_minutes even though the loop has bounced since.
setup_case
EP=$(ago_iso 60)
printf '{"ts":"%s","loop":"pulse-marshal","reason":"blocked_on_andrew"}\n' "$EP" \
  > "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
bounce 30
bounce 1
prior_state "$EP" nudged 2
run
if [ "$(count inject-calls)" = 0 ] && [ "$(count started)" = 0 ] && [ "$(count br-calls)" = 0 ] \
   && v_has "skipped:1"; then
  ok
else
  bad "11 cooldown: no second rung inside cooldown_minutes (injects=$(count inject-calls) started=$(count started) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 12: A RUNG THAT WORKED CLOSES THE EPISODE. Cooldown is long past, but nothing has
#   bounced SINCE the action — so the loop recovered and the ladder stops. This is what
#   keeps a one-off block from marching to a P1 bead.
setup_case
EP=$(ago_iso 40)
printf '{"ts":"%s","loop":"pulse-marshal","reason":"blocked_on_andrew"}\n' "$EP" \
  > "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
prior_state "$EP" nudged 35
run
if [ "$(count inject-calls)" = 0 ] && [ "$(count started)" = 0 ] && [ "$(count br-calls)" = 0 ] \
   && v_has "skipped:1"; then
  ok
else
  bad "12 no-new-bounce: a rung that worked closes the episode (injects=$(count inject-calls) br=$(count br-calls) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 13: A STALE EPISODE IS OVER. The newest bounce is older than episode_gap_minutes
#   — the loop recovered hours ago and there is nothing to escalate.
setup_case
bounce 120
run
if v_has "skipped:1" && [ "$(count inject-calls)" = 0 ] && [ "$(count renames)" = 0 ]; then
  ok
else
  bad "13 stale-episode: a bounce older than episode_gap_minutes escalates nothing (verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 14: THE OUTCOME CONTRACT. The verdict is the LAST line of stdout on the quiet
#   path, in the documented shape — and a bad config is `failed-config`/78, not a silent
#   no-op that reads exactly like "nothing to do".
setup_case
run
if [ "$RC" = 0 ] && [ "$VERDICT" = "PULSE_ESCALATE_RESULT=checked:0:grace:0:reconciled:0:nudged:0:raised:0:floored:0:skipped:0:errors:0" ]; then
  ok
else
  bad "14 verdict: the empty run emits the full documented result line last (rc=$RC verdict='$VERDICT')"
fi
setup_case
# shellcheck disable=SC2016  # the command substitution is the FIXTURE: the config line
# must reach the parser as literal bytes, because the whole point is that the parser
# refuses it rather than a shell ever expanding it.
printf 'loops=$(rm -rf /)\n' > "$CASE/escalate.conf"
run
if [ "$RC" = 78 ] && [ "$VERDICT" = "PULSE_ESCALATE_RESULT=failed-config" ]; then
  ok
else
  bad "14b config: a line that is not a plain key=value is REFUSED (rc=$RC verdict='$VERDICT')"
fi

# ---------------------------------------------------------------------------
# Case 15: AN UNVERIFIABLE PANE FAILS SAFE. capture-pane returns nothing (a dead pane, a
#   tmux hiccup) — the reconciler must NOT rename. It may miss a stale 🔔; it may never
#   clear a live dialog on a guess.
setup_case
: > "$PE_FAKE/panes/zig-computer-1"
bounce 25
run
if [ "$(count renames)" = 0 ] && [ "$(winname 1)" = "🔔 marshal" ] && [ "$(count inject-calls)" = 1 ]; then
  ok
else
  bad "15 unverifiable: an empty capture is treated as blocked, never as stale (renames=$(count renames) name='$(winname 1)')"
fi

# ---------------------------------------------------------------------------
# Case 16: MODAL_MARKER EMPTY DISABLES THE RECONCILER, in the safe direction. This is the
#   escape hatch for a Claude Code that changes its dialog chrome: with no fingerprint to
#   match, every 🔔 reads as genuinely blocked rather than as stale.
setup_case
export PULSE_ESCALATE_MODAL_MARKER=""
printf '%s\n' "$IDLE_PANE" > "$PE_FAKE/panes/zig-computer-1"
bounce 25
run
unset PULSE_ESCALATE_MODAL_MARKER
if [ "$(count renames)" = 0 ] && [ "$(winname 1)" = "🔔 marshal" ] && [ "$(rung_of)" = nudged ]; then
  ok
else
  bad "16 marker-empty: an empty chrome marker disables renaming, not blocking (renames=$(count renames) rung=$(rung_of))"
fi

# ---------------------------------------------------------------------------
# Case 17: THE RENAME MUST BE VERIFIED. tmux accepted the rename and the glyph is STILL
#   there — so the episode is NOT recorded as reconciled (which would close it, leaving a
#   really-blocked seat un-escalated) and the run reports an error.
setup_case
export PE_RENAME_NOOP=1
printf '%s\n' "$IDLE_PANE" > "$PE_FAKE/panes/zig-computer-1"
bounce 25
run
unset PE_RENAME_NOOP
if [ "$(count renames)" = 1 ] && [ "$(rung_of)" != reconciled ] && v_has "errors:1"; then
  ok
else
  bad "17 verified-rename: a rename that does not clear 🔔 is never recorded as reconciled (rung=$(rung_of) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 18: THE BOUNCE LOG IS READ-ONLY to this watcher. It is pulse-inject's record and
#   harnessd's input; a consumer that wrote to it would be manufacturing the very signal
#   it reads.
setup_case
bounce 25
BEFORE=$(cat "$HARNESS_STATE_DIR/pulse-bounces.jsonl")
run
if [ "$BEFORE" = "$(cat "$HARNESS_STATE_DIR/pulse-bounces.jsonl")" ]; then
  ok
else
  bad "18 read-only: pulse-bounces.jsonl is never written by the escalator"
fi

# --- Summary ---
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED_NAMES[@]}"; do
  echo "  - $n"
done
exit 1
