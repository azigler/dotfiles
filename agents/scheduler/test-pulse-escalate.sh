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
#   $PE_FAKE/panes/<sess>-<idx>  — what `capture-pane -p` prints (the WRAPPED form)
#   $PE_FAKE/panes/<sess>-<idx>.J — what `capture-pane -J` prints (soft wraps JOINED);
#                                  absent => identical to the raw. Written by set_pane.
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
#
# -J IS MODELLED, NOT IGNORED. Real tmux's -J joins soft-wrapped lines, and that
# flag is now load-bearing (a narrow pane splits dialog chrome mid-phrase). So a
# pane has TWO fixture files: `panes/<sess>-<idx>` is what the terminal actually
# holds (wrapped), and `panes/<sess>-<idx>.J` is what -J returns (joined). With
# no .J file the two are identical, which is every ordinary case. A mutant that
# drops -J therefore reads genuinely different bytes, exactly as in production.
cmd="${1:-}"; shift || true
tgt=""; new=""; joined=0
while [ $# -gt 0 ]; do
  case "$1" in
    -t) tgt="${2:-}"; shift 2 ;;
    -F) shift 2 ;;
    -pJ|-Jp|-J) joined=1; shift ;;
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
    [ "$joined" = 1 ] && [ -f "$f.J" ] && f="$f.J"
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

# IDLE: transcribed from a LIVE ✅ pane on the same box — the composer of a session
# whose AskUserQuestion was CANCELLED with Esc (dotfiles-jisc's stale 🔔). The window
# name still carries the glyph; the pane holds no dialog. Its footer is the POSITIVE
# evidence a rename now requires, and it is pulse-inject's own READY_MARKER; measured
# against the two real captures, the chrome ERE scores 2/0 and this one 0/1.
IDLE_PANE='─────────────────────────────────────────────────────
❯
─────────────────────────────────────────────────────
  ✅ [Fable 5] 📁 dotfiles | 📮 main
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ←'

# WRAPPED MODAL: the SAME live dialog in a NARROW pane. tmux hard-wraps at the pane
# width, so every chrome phrase is split mid-word and the ERE matches nothing — this
# is the raw capture that the first cut of rung 1 classified as stale and renamed,
# with a live question still on the screen (adversarial review, 2026-08-09).
WRAPPED_MODAL_RAW='Reminder 7 — creatine: the pl
an was Sun 08-09.

❯ 1
. Today, 2026-08-09
  2
. Not yet

Enter to sel
ect · Tab/Arrow keys to na
vigate · Esc to canc
el'

# ...and what `capture-pane -J` returns for that same pane: the soft wraps joined,
# every phrase whole again, chrome matching. -J is layer (a) of the fix.
WRAPPED_MODAL_JOINED='Reminder 7 — creatine: the plan was Sun 08-09.

❯ 1. Today, 2026-08-09
  2. Not yet

Enter to select · Tab/Arrow keys to navigate · Esc to cancel'

# AMBIGUOUS: neither signal. A pane mid-repaint, a dead TUI, a dialog whose chrome
# the ERE no longer fingerprints. Chrome is ABSENT here — which is exactly why an
# absence may not authorise a rename.
AMBIGUOUS_PANE='Loading…

(nothing else on the screen)'

# --- THE LYING 🧠 FIXTURES (dotfiles-t5fj) ------------------------------------
#
# STALLED_TURN_PANE is THE live instance, not a transcription and not a synthesis:
# it is byte-identical to the `tail` field of the 2026-08-09T15:11:01Z `seneschal`
# row of ~/.local/state/harness/api-error-captures.jsonl — one of the four panes
# that were stalled that morning. Its shape IS the class this rung exists for:
# an errored turn ("● API Error: Unable to connect to API"), a turn timer frozen in
# the PAST tense ("✻ Worked for 2m 57s" — no interrupt hint, because nothing is
# running), and then an idle composer with its footer. The pane proves idle; the
# WINDOW NAME is where the lie lives, and the name is not in this fixture at all —
# it comes from the harness's window list ("1 🧠 marshal"), which is exactly the
# split the two-proof standard has to resolve: never trust the name, ask the pane.
# Against the two EREs: chrome 0 matches, composer 1 match => rename proceeds.
#
# The corpus is private machine state and is NOT in this repo, so the byte-identity
# is pinned by digest below rather than re-derived at test time. Re-derive it with:
#   python3 -c "import json,hashlib;rows=[json.loads(l) for l in open('$HOME/.local/state/harness/api-error-captures.jsonl')];r=[x for x in rows if x['ts']=='2026-08-09T15:11:01Z' and x['window']=='seneschal'][0];print(hashlib.sha256(r['tail'].encode()).hexdigest())"
# shellcheck disable=SC2016  # the `$0.00` in the captured statusline is DATA, not an
# expression: this literal is byte-identical to a real pane and the digest gate below
# refuses any edit that "fixes" it.
STALLED_TURN_PANE='
 ▐▛███▜▌   Claude Code v2.1.226
▝▜█████▛▘  Fable 5 · Claude Max
  ▘▘ ▝▝    ~/dotfiles


❯ /seneschal brief

● API Error: Unable to connect to API
  (ConnectionRefused)

✻ Worked for 2m 57s



─────────────────────────────────────────────────────
❯ 
─────────────────────────────────────────────────────
  🧠 [Fable 5] 📁 dotfiles | 📮 main ~1 | 🔗 https:…
  [----------] 0% | $0.00 | 🕰️  3m 1s | (me)
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ←…'
STALLED_TURN_SHA=202708ba7d188de48b66967b8d3b7631a53c7f38694efaedb8bf504b32aea967

# LIVE TURN: a turn that is RUNNING. No corpus row can supply this one — the
# api-error capture only ever fires on a pane whose turn has already died, and all
# 671 rows lack an interrupt hint — and the live tmux server is off limits while
# the marshal campaign runs, so this is a transcription of the running-turn shape
# and is labelled as one. It deliberately carries the composer footer TOO: the
# premise "a mid-flight turn renders no composer" could not be verified, so the
# fixture assumes the pessimistic version of it, and the case below therefore
# tests the busy fingerprint rather than the absence of a composer. Strip the
# interrupt hint from this fixture and it becomes STALLED_TURN_PANE's classifier
# outcome — which is precisely the mutant.
LIVE_TURN_PANE='● Read agents/scheduler/pulse-escalate.sh (546 lines)

✻ Brewed for 3m 12s (esc to interrupt · ctrl+t for todos)

─────────────────────────────────────────────────────
❯
─────────────────────────────────────────────────────
  🧠 [Fable 5] 📁 dotfiles | 📮 main
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ←'

# The digest gate. A "tidy up the fixture" edit — a stripped trailing space, a
# normalised NBSP, a re-typed box-drawing run — silently turns the live instance
# back into a synthesis, and every case built on it starts proving nothing. That
# is a broken suite, not one failing case, so it aborts rather than counting.
_stalled_got=$(printf '%s\n' "$STALLED_TURN_PANE" | sha256sum | cut -d' ' -f1)
if [ "$_stalled_got" != "$STALLED_TURN_SHA" ]; then
  echo "FIXTURE ERROR: STALLED_TURN_PANE is no longer byte-identical to the captured pane"
  echo "  want $STALLED_TURN_SHA"
  echo "  got  $_stalled_got"
  exit 1
fi

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
  # The epochs molt_row hands back, per case. NOT resetting this is a real trap:
  # molt_prior keys an episode by ${MOLT_EPOCHS[0]}, and a leftover epoch from an
  # earlier case makes the idempotency fixture point at an episode that no longer
  # exists — the summon then fires and the case reads as a code bug (it did, once).
  MOLT_EPOCHS=()
  # $MOLT_LEDGER is seat-molt.sh's env seam and pulse-escalate reuses the NAME, so
  # a shell that happens to export it (test-seat-molt.sh does) would point this
  # suite's molt-refusal watcher at a foreign file. HARNESS_STATE_DIR above is the
  # only seam this suite wants.
  unset MOLT_LEDGER
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

# set_pane <index> <raw-capture> [joined-capture]
#   Two files, because -J is load-bearing: the raw is what an unjoined capture sees,
#   the joined is what `capture-pane -J` returns. Omit the third argument and they
#   are identical, which is the ordinary unwrapped case.
set_pane() {
  printf '%s\n' "$2" > "$PE_FAKE/panes/zig-computer-$1"
  if [ $# -ge 3 ]; then printf '%s\n' "$3" > "$PE_FAKE/panes/zig-computer-$1.J"
  else rm -f "$PE_FAKE/panes/zig-computer-$1.J"; fi
}
logtxt() { cat "$HARNESS_STATE_DIR/pulse-escalate.log" 2>/dev/null; }

bounce() { # bounce <minutes-ago> [reason] [loop]
  printf '{"ts":"%s","loop":"%s","reason":"%s"}\n' \
    "$(ago_iso "$1")" "${3:-pulse-marshal}" "${2:-blocked_on_andrew}" \
    >> "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
}
prior_state() { # prior_state <episode-ts> <rung> <acted-minutes-ago>
  printf '{"loop":"pulse-marshal","episode":"%s","rung":"%s","acted_ts":"%s"}\n' \
    "$1" "$2" "$(ago_iso "$3")" > "$HARNESS_STATE_DIR/pulse-escalate-state.jsonl"
}

# --- the molt-refusal watcher's fixtures (dotfiles-o3qj) ----------------------
# seat-molt.sh's ledger row, verbatim shape (see its THE REFUSAL RECORD block):
# ts/epoch/session/window/mode/pct/result/reason, `reason` last and always present.
MOLT_EPOCHS=()
molt_row() { # molt_row <minutes-ago> <result> [pct] [reason] [window] [session]
  local ep; ep=$(( $(date +%s) - $1 * 60 ))
  MOLT_EPOCHS+=("$ep")
  printf '{"ts":"%s","epoch":%s,"session":"%s","window":"%s","mode":"molt","pct":%s,"result":"%s","reason":"%s"}\n' \
    "$(date -u -d "@$ep" +%FT%TZ)" "$ep" "${6:-zig-computer}" "${5:-marshal}" "${3:-73}" "$2" \
    "${4:-window marshal already molted within the last 30 minutes — molt-loop protection refused a second cycle}" \
    >> "$HARNESS_STATE_DIR/molt-ledger.jsonl"
}
molt_prior() { # molt_prior <seat> <episode-epoch> <stage>
  printf '{"seat":"%s","episode":"%s","stage":"%s","acted_ts":"%s"}\n' \
    "$1" "$2" "$3" "$(ago_iso 1)" > "$HARNESS_STATE_DIR/molt-refusal-state.jsonl"
}
molt_stage() { sed -n -E 's/.*"stage":"([^"]*)".*/\1/p' "$HARNESS_STATE_DIR/molt-refusal-state.jsonl" 2>/dev/null | head -1; }
molt_conf() { printf '%s\n' "$1" >> "$CASE/escalate.conf"; }
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
# Case 2: THE RECONCILER (dotfiles-jisc). 🔔 NAME + no dialog chrome + a PROVEN idle
#   composer => a VERIFIED rename that clears the glyph, and the episode closes at rung
#   `reconciled`. NOTHING is escalated to a human. This is the case that keeps the
#   two-signal rule from being a blanket refusal: the legitimate reconcile still happens.
setup_case
set_pane 1 "$IDLE_PANE"
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
set_pane 1 "$IDLE_PANE"
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
set_pane 1 "$IDLE_PANE"
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
# Case 9: AN UNLISTED LOOP NEVER REACHES RUNGS 2-4. `loops` is the opt-in gate for the
#   ESCALATION half of the ladder; a seat that is not listed is never nudged, raised,
#   beaded or pushed however hard it bounces. (That ladder ends in a buzz on Zig's
#   phone — nothing opts in by accident.) Here neither derived window exists, so rung 1
#   is a no-op too and the run is completely silent — which is also the assertion that
#   a wrong window derivation costs nothing.
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
if [ "$RC" = 0 ] && [ "$VERDICT" = "PULSE_ESCALATE_RESULT=checked:0:grace:0:reconciled:0:reconciled-unlisted:0:nudged:0:raised:0:floored:0:skipped:0:errors:0:molt-refusals:0:molt-noted:0:molt-summoned:0" ]; then
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
set_pane 1 "$IDLE_PANE"
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
set_pane 1 "$IDLE_PANE"
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

# ---------------------------------------------------------------------------
# Case 19: THE WRAPPED-CHROME BLOCKER. A narrow pane hard-wraps the dialog mid-phrase
#   ('Enter to sel'/'ect', '❯ 1'/'. Yes'), so the chrome ERE matches NOTHING in the raw
#   capture — and the first cut renamed a LIVE modal on that absence, after which
#   pulse-retry re-fires and the injection's Enter answers Zig's open dialog with its
#   default. `capture-pane -J` joins the soft wraps, so the chrome is whole again.
#
#   The assertion is BOTH halves: no rename (the consequence), AND the log classifying
#   the pane as CHROME PRESENT rather than ambiguous (the reason). The second half is
#   what makes this case detect a dropped -J at all — with -J gone the refusal still
#   happens, via the ambiguity fallback, and only the classification tells you the
#   fingerprint stopped working.
setup_case
set_pane 1 "$WRAPPED_MODAL_RAW" "$WRAPPED_MODAL_JOINED"
bounce 25
run
if [ "$(count renames)" = 0 ] && [ "$(winname 1)" = "🔔 marshal" ] && [ "$(rung_of)" = nudged ] \
   && logtxt | grep -q 'CHROME PRESENT' && ! logtxt | grep -q 'AMBIGUOUS'; then
  ok
else
  bad "19 wrapped-chrome: a soft-wrapped live dialog is joined by -J, classified CHROME PRESENT, and never renamed (renames=$(count renames) name='$(winname 1)' rung=$(rung_of))"
fi

# ---------------------------------------------------------------------------
# Case 20: AN ABSENCE IS NOT EVIDENCE. Chrome absent AND no idle composer — a pane
#   mid-repaint, a dead TUI, or a dialog whose chrome the ERE no longer fingerprints.
#   Renaming here is renaming on a guess, so the ladder escalates and says AMBIGUOUS.
#   This is the case that makes signal 2 (positive idle-composer evidence) load-bearing:
#   with only "chrome absent" the rename would fire.
setup_case
set_pane 1 "$AMBIGUOUS_PANE"
bounce 25
run
if [ "$(count renames)" = 0 ] && [ "$(winname 1)" = "🔔 marshal" ] && [ "$(rung_of)" = nudged ] \
   && logtxt | grep -q 'AMBIGUOUS'; then
  ok
else
  bad "20 absence-is-not-evidence: chrome absent with no idle composer never renames (renames=$(count renames) name='$(winname 1)' rung=$(rung_of))"
fi

# ---------------------------------------------------------------------------
# Case 21: NO PERSISTABLE MEMORY => CHECKER BROKEN, ZERO ACTIONS. With the state dir
#   read-only the first cut reported `raised:1 … errors:0` and exit 0 on EVERY run,
#   five minutes apart — an invisible repeated `systemctl --user start`, because the
#   rung it had "already fired" could never be written down. `mkdir -p` cannot detect
#   this (it succeeds on an existing read-only dir); only a real write can.
setup_case
bounce 25
chmod a-w "$HARNESS_STATE_DIR"
run
chmod u+w "$HARNESS_STATE_DIR"
if [ "$RC" = 1 ] && [ "$VERDICT" = "PULSE_ESCALATE_RESULT=checker-broken" ] \
   && [ "$(count started)" = 0 ] && [ "$(count inject-calls)" = 0 ] \
   && [ "$(count renames)" = 0 ] && [ "$(count br-calls)" = 0 ] \
   && [ ! -f "$PE_FAKE/calls" ]; then
  ok
else
  bad "21 no-memory: an unwritable state dir is checker-broken with ZERO actions (rc=$RC verdict='$VERDICT' started=$(count started) injects=$(count inject-calls) renames=$(count renames))"
fi

# ---------------------------------------------------------------------------
# Case 22: A COLONLESS `loops` ROW IS REFUSED. `${row#*:}` returns the WHOLE STRING when
#   there is no colon, so `loops=pulse-marshal` used to pass an emptiness check with
#   loop == window == session == "pulse-marshal" and drive the ladder against a window
#   name that is really a unit name. Wrong arity is the same defect with a comma in it.
setup_case
sed -i 's|^loops=.*|loops=pulse-marshal|' "$CASE/escalate.conf"
bounce 25
run
if v_has "checked:0" && v_has "errors:1" && [ "$(count inject-calls)" = 0 ] \
   && [ "$(count renames)" = 0 ] && [ "$(count started)" = 0 ]; then
  ok
else
  bad "22 colonless-row: a loops row with no colons is skipped and counted as an error (verdict=$VERDICT)"
fi
setup_case
sed -i 's|^loops=.*|loops=pulse-marshal:marshal|' "$CASE/escalate.conf"
bounce 25
run
if v_has "checked:0" && v_has "errors:1" && [ "$(count inject-calls)" = 0 ]; then
  ok
else
  bad "22b short-row: a two-field loops row is skipped and counted as an error (verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 23: `already_running` IS AN EPISODE TRIGGER (dotfiles-t5fj). pulse-inject's
#   --fresh same-loop guard records this reason when the pane looks mid-turn and returns
#   deferred-already-running. Over a LYING glyph that refusal is permanent — every
#   scheduled tick defers, for as long as the window lives — so a reason filter that
#   drops it makes the whole class invisible to the only watcher that would act. Here the
#   block is genuine (real chrome), so the ladder does its ordinary job and the nudge
#   carries the reason to the front desk.
setup_case
bounce 25 already_running
bounce 20 already_running
run
if [ "$(count inject-calls)" = 1 ] && [ "$(rung_of)" = nudged ] && v_has "checked:1" \
   && grep -q "already_running" "$PE_FAKE/inject-calls"; then
  ok
else
  bad "23 already_running: the --fresh same-loop refusal drives an episode and the nudge names it (injects=$(count inject-calls) rung=$(rung_of) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 24: THE LYING 🧠 — THE LIVE INSTANCE. This is the morning-stall shape from
#   2026-08-09 verbatim (see STALLED_TURN_PANE: the digest gate above proves it is the
#   captured pane and not a tidy-up of one): an errored turn, a turn timer frozen in the
#   past tense, and an idle composer underneath. The window NAME still says 🧠 — the lie
#   lives there, and the fixture deliberately does not contain it, because the name comes
#   from the harness's window list and never from the pane. Two proofs (chrome ABSENT,
#   composer PRESENT, no live turn) and the glyph is stripped; the rung then STOPS,
#   exactly as it does for 🔔, because pulse-retry owns every re-fire.
setup_case
printf '1 🧠 marshal\n2 ✅ seneschal\n' > "$PE_FAKE/windows/zig-computer"
set_pane 1 "$STALLED_TURN_PANE"
bounce 25 already_running
run
if [ "$(count renames)" = 1 ] && [ "$(winname 1)" = "marshal" ] && [ "$(rung_of)" = reconciled ] \
   && [ "$(count inject-calls)" = 0 ] && [ "$(count started)" = 0 ] && v_has "reconciled:1" \
   && logtxt | grep -q 'RENAMED pulse-marshal'; then
  ok
else
  bad "24 lying-brain: a real stalled 🧠 pane (2026-08-09 capture) is proven idle and the glyph stripped (renames=$(count renames) name='$(winname 1)' rung=$(rung_of) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 24b: 🌀 IS THE SAME LIE. A session that dies mid-compaction leaves the compacting
#   glyph up forever, and pulse-inject reads it exactly as it reads a stale 🧠. One code
#   path, one proof standard, both glyphs.
setup_case
printf '1 🌀 marshal\n2 ✅ seneschal\n' > "$PE_FAKE/windows/zig-computer"
set_pane 1 "$IDLE_PANE"
bounce 25 already_running
run
if [ "$(count renames)" = 1 ] && [ "$(winname 1)" = "marshal" ] && [ "$(rung_of)" = reconciled ]; then
  ok
else
  bad "24b lying-compact: a stale 🌀 over an idle composer is reconciled like a stale 🧠 (renames=$(count renames) name='$(winname 1)' rung=$(rung_of))"
fi

# ---------------------------------------------------------------------------
# Case 25: A LIVE TURN IS NEVER RENAMED — the 🧠 half of the asymmetry. For 🔔 the
#   dangerous mistake is clearing a live DIALOG and signal 1 (chrome) catches it; chrome
#   says nothing at all about a running turn, so for 🧠 the danger is stripping the glyph
#   off work in flight, and only the interrupt hint refutes it. This fixture carries the
#   composer footer TOO, on purpose: the premise "a mid-flight turn renders no composer"
#   is unverified here, so the case asserts the guard that holds either way. The
#   classification assertion is what makes the case detect a missing busy check at all —
#   as in case 19, the refusal alone would still happen via the ambiguity fallback.
setup_case
printf '1 🧠 marshal\n2 ✅ seneschal\n' > "$PE_FAKE/windows/zig-computer"
set_pane 1 "$LIVE_TURN_PANE"
bounce 25 already_running
run
if [ "$(count renames)" = 0 ] && [ "$(winname 1)" = "🧠 marshal" ] \
   && logtxt | grep -q 'LIVE TURN' && [ "$(rung_of)" = nudged ]; then
  ok
else
  bad "25 live-turn: a running turn's 🧠 is never stripped, and the pane is classified BUSY (renames=$(count renames) name='$(winname 1)' rung=$(rung_of))"
fi

# ---------------------------------------------------------------------------
# Case 26: THE SCOPE SPLIT, RECONCILE HALF. `pulse-dive` is NOT in escalate.conf, and the
#   silently-stalled seats are exactly the unlisted ones. Its window is DERIVED
#   (pulse-dive -> dive, in reconcile_session) and the fleet-safe verb runs: two proofs,
#   glyph stripped, nobody told. The counters keep the populations apart — `checked` is
#   the ladder's own metric and must NOT move, and the reconcile lands in
#   `reconciled-unlisted`, so opting a seat in is still visible in the telemetry.
setup_case
printf '1 🧠 dive\n2 ✅ seneschal\n' > "$PE_FAKE/windows/zig-computer"
set_pane 1 "$STALLED_TURN_PANE"
bounce 25 already_running pulse-dive
run
if [ "$(count renames)" = 1 ] && [ "$(winname 1)" = "dive" ] \
   && v_has "reconciled-unlisted:1" && v_has "reconciled:0" && v_has "checked:0" \
   && [ "$(count inject-calls)" = 0 ] && [ "$(count started)" = 0 ] \
   && [ "$(count br-calls)" = 0 ] && [ "$(count curl-calls)" = 0 ]; then
  ok
else
  bad "26 unlisted-reconcile: an unlisted loop's lying glyph is fixed and counted separately (renames=$(count renames) name='$(winname 1)' verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 26b: THE SCOPE SPLIT, LADDER HALF — the zero-side-effect assertion. Same unlisted
#   loop, but rung 1 REFUSES (real chrome), which is the only path that reaches the split.
#   Rungs 2-4 must not run: no nudge, no raise, no bead, no push. `loops` is the consent
#   for a P1 bead and a buzzing phone, and nothing derived from a bounce log may grant it.
#   The log assertions are the positive half — the run must show it looked and decided,
#   not merely that it did nothing.
setup_case
printf '1 🔔 dive\n2 ✅ seneschal\n' > "$PE_FAKE/windows/zig-computer"
set_pane 1 "$MODAL_PANE"
bounce 25 already_running pulse-dive
run
if [ "$(count renames)" = 0 ] && [ "$(winname 1)" = "🔔 dive" ] \
   && [ "$(count inject-calls)" = 0 ] && [ "$(count started)" = 0 ] \
   && [ "$(count br-calls)" = 0 ] && [ "$(count curl-calls)" = 0 ] \
   && logtxt | grep -q 'CHROME PRESENT' && logtxt | grep -q 'reconciliation-only'; then
  ok
else
  bad "26b unlisted-no-ladder: an unlisted loop that cannot be reconciled escalates to nobody (injects=$(count inject-calls) started=$(count started) br=$(count br-calls) verdict=$VERDICT)"
fi

# ===========================================================================
# THE MOLT-REFUSAL WATCHER (dotfiles-o3qj) — cases 27-35
# ===========================================================================
# THE LIVE INSTANCES these are built from, both 2026-08-09: the dream seat sat at
# 100% context for 3+ hours after `refused-not-offboarded` (found only because Zig
# asked), and the marshal refused at 21:22:12Z with `refused-rate-limited` at 73%.
# In both, seat-molt's decision was RIGHT and the silence was the bug — the refusal
# went to a log with no reader. AGENTS.md it06 ("a failed/refused molt TWICE is the
# only context event that summons Zig") had no mechanical arm; these cases are it.
#
# Every case here asserts the NEGATIVES too. This watcher's floor is a P1 bead and
# a buzz on Zig's phone, so "did not fire" is as load-bearing as "fired".

# ---------------------------------------------------------------------------
# Case 27: ONE REFUSAL IS A NOTE, NOT AN ESCALATION. it06 says TWICE; a watcher that
#   summoned on the first refusal would page Zig for every ordinary rate-limit
#   bounce. The rung still writes the refusal down — a note file and a log line —
#   because the alternative to escalating is recording, not forgetting.
setup_case
molt_row 5 refused-rate-limited
run
if [ "$(count br-calls)" = 0 ] && [ "$(count curl-calls)" = 0 ] \
   && [ "$(count inject-calls)" = 0 ] && [ "$(count started)" = 0 ] && [ "$(count renames)" = 0 ] \
   && v_has "molt-refusals:1" && v_has "molt-noted:1" && v_has "molt-summoned:0" \
   && [ "$(molt_stage)" = noted ] \
   && grep -q 'zig-computer:marshal' "$HARNESS_STATE_DIR/molt-refusal-note.md" \
   && logtxt | grep -q 'MOLT-NOTE zig-computer:marshal'; then
  ok
else
  bad "27 first-refusal-notes: one refusal is recorded and escalates to nobody (br=$(count br-calls) curl=$(count curl-calls) stage=$(molt_stage) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 28: THE SUMMON — it06's rule, mechanically. A SECOND refusal for the same
#   seat inside the window is the wedge that has no other watcher, so it files a P1
#   `human:` bead (the prefix seneschal-gather.py filters on) AND pushes. Both, never
#   one: the bead is the durable surface and the push is the one that reaches him
#   tonight. The bead must carry the EVIDENCE — both verdicts and the context pct —
#   because "the marshal refused twice" is not actionable and "refused-not-offboarded
#   at 73%, then rate-limited" is.
setup_case
molt_row 40 refused-not-offboarded 61 "not offboarded: that session kept working past its offboard"
molt_row 5  refused-rate-limited   73
run
if [ "$(count br-calls)" = 1 ] && grep -q 'human:' "$PE_FAKE/br-calls" \
   && grep -q -- '-p 1' "$PE_FAKE/br-calls" && grep -q 'marshal' "$PE_FAKE/br-calls" \
   && grep -q 'refused-not-offboarded' "$PE_FAKE/br-calls" \
   && grep -q 'refused-rate-limited' "$PE_FAKE/br-calls" \
   && grep -q '73%' "$PE_FAKE/br-calls" \
   && [ "$(count curl-calls)" = 1 ] && grep -q 'marshal seat is wedged' "$PE_FAKE/curl-body" \
   && v_has "molt-summoned:1" && [ "$(molt_stage)" = summoned ] \
   && [ "$(count inject-calls)" = 0 ] && [ "$(count started)" = 0 ] && [ "$(count renames)" = 0 ]; then
  ok
else
  bad "28 second-refusal-summons: two refusals in the window file a P1 human: bead AND push, carrying both verdicts and the pct (br=$(count br-calls) curl=$(count curl-calls) stage=$(molt_stage) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 29: THE SUMMON IS IDEMPOTENT PER EPISODE. This script ticks every 5 minutes
#   and the ledger is APPEND-ONLY — the two rows that justified the summon are still
#   there on the next tick, and the one after, forever. Without the episode memory a
#   single wedge becomes a bead every five minutes and a phone that buzzes all night,
#   which is how a summon turns into noise Zig learns to ignore.
setup_case
molt_row 40 refused-not-offboarded 61
molt_row 5  refused-rate-limited   73
molt_prior "zig-computer:marshal" "${MOLT_EPOCHS[0]}" summoned
run
if [ "$(count br-calls)" = 0 ] && [ "$(count curl-calls)" = 0 ] \
   && v_has "molt-summoned:0" && v_has "molt-noted:0" && v_has "molt-refusals:1"; then
  ok
else
  bad "29 summon-idempotent: an already-summoned episode never files a second bead or push (br=$(count br-calls) curl=$(count curl-calls) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 30: THE ROLLING WINDOW IS REAL. Two refusals 200 minutes apart are two
#   separate incidents, not one escalating one — a seat that refuses once a morning
#   is not wedged, and summoning on that pair would make the P1 bead meaningless.
#   Only the newest is in the current episode, so this is a NOTE.
setup_case
molt_row 200 refused-not-offboarded 61
molt_row 5   refused-rate-limited   73
run
if [ "$(count br-calls)" = 0 ] && [ "$(count curl-calls)" = 0 ] \
   && v_has "molt-noted:1" && v_has "molt-summoned:0"; then
  ok
else
  bad "30 rolling-window: refusals further apart than the window are separate episodes (br=$(count br-calls) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 30b: ...and the window is CONF, not a constant. The same two rows, with
#   molt_refusal_window_minutes widened past their spacing, ARE one episode and DO
#   summon. This is what makes case 30 a test of the clock rather than of the fixture.
setup_case
molt_conf "molt_refusal_window_minutes=300"
molt_row 200 refused-not-offboarded 61
molt_row 5   refused-rate-limited   73
run
if [ "$(count br-calls)" = 1 ] && [ "$(count curl-calls)" = 1 ] && v_has "molt-summoned:1"; then
  ok
else
  bad "30b conf-window: widening molt_refusal_window_minutes makes the same pair one episode (br=$(count br-calls) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 31: AN EPISODE THAT IS OVER SUMMONS NOBODY. Nothing has refused inside the
#   window — the seat molted, or stopped trying, hours ago. The ledger keeps those
#   rows forever, so without this check every seat on the box eventually accumulates
#   two refusals and the summon degrades into a daily alarm about nothing.
setup_case
molt_row 400 refused-not-offboarded 61
molt_row 300 refused-rate-limited   73
run
if [ "$(count br-calls)" = 0 ] && [ "$(count curl-calls)" = 0 ] \
   && v_has "molt-refusals:0" && v_has "molt-noted:0" && v_has "molt-summoned:0"; then
  ok
else
  bad "31 stale-episode: refusals older than the window escalate nothing (br=$(count br-calls) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 32: A SUCCESSFUL MOLT ENDS THE EPISODE OUTRIGHT. Refuse, then molt, then
#   refuse again is ONE current refusal — the seat demonstrably shed its context in
#   between. This is exactly tonight's marshal trail (refused-not-offboarded 19:22,
#   molted 21:15, refused-rate-limited 21:22): a watcher without this reset would
#   have paged Zig about a seat that had just successfully molted seven minutes
#   earlier, which is the false positive that would discredit the whole mechanism.
setup_case
molt_row 40 refused-not-offboarded 61
molt_row 20 molted                 61 ""
molt_row 5  refused-rate-limited   73
run
if [ "$(count br-calls)" = 0 ] && [ "$(count curl-calls)" = 0 ] \
   && v_has "molt-noted:1" && v_has "molt-summoned:0"; then
  ok
else
  bad "32 molt-resets-episode: a successful molt between two refusals prevents the summon (br=$(count br-calls) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 33: aborted-modal IS NOT IN THE REFUSAL SET, deliberately. That pane is
#   showing Zig an open dialog — it is ALREADY summoning him, by the only mechanism
#   that matters — so a P1 bead about it is noise. Two of them still fire nothing.
#   (seat-molt records them anyway; the exclusion is the consumer's call to make,
#   and it can only make it from a record.)
setup_case
molt_row 40 aborted-modal 61 "the pane is blocked on Andrew"
molt_row 5  aborted-modal 73 "the pane is blocked on Andrew"
run
if [ "$(count br-calls)" = 0 ] && [ "$(count curl-calls)" = 0 ] \
   && v_has "molt-refusals:0" && v_has "molt-noted:0" && v_has "molt-summoned:0"; then
  ok
else
  bad "33 modal-excluded: aborted-modal never summons (that pane already has Zig's attention) (br=$(count br-calls) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 33b: aborted-not-idle IS in the set. The molt did not happen and the context
#   was not freed — the seat is wedged in exactly the way it06 is about — so two of
#   them summon like any other pair.
setup_case
molt_row 40 aborted-not-idle 61 "the pane never went idle within 900s"
molt_row 5  aborted-not-idle 73 "the pane never went idle within 900s"
run
if [ "$(count br-calls)" = 1 ] && [ "$(count curl-calls)" = 1 ] && v_has "molt-summoned:1"; then
  ok
else
  bad "33b not-idle-included: two aborted-not-idle refusals summon (the molt did not happen) (br=$(count br-calls) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 34: THE KILL SWITCH. molt_refusal_watch=off restores the pre-o3qj silence.
#   It exists so the fleet-wide-by-default judgement is reversible without an edit;
#   it is deliberately NOT a per-seat allowlist, because the seats nobody would list
#   are the ones that wedge unnoticed.
setup_case
molt_conf "molt_refusal_watch=off"
molt_row 40 refused-not-offboarded 61
molt_row 5  refused-rate-limited   73
run
if [ "$(count br-calls)" = 0 ] && [ "$(count curl-calls)" = 0 ] \
   && v_has "molt-refusals:0" && v_has "molt-summoned:0" \
   && [ ! -f "$HARNESS_STATE_DIR/molt-refusal-state.jsonl" ]; then
  ok
else
  bad "34 kill-switch: molt_refusal_watch=off does nothing at all (br=$(count br-calls) verdict=$VERDICT)"
fi

# ---------------------------------------------------------------------------
# Case 35: THE MOLT LEDGER IS READ-ONLY HERE, and the watcher touches no pane. Same
#   rule as case 18 for the bounce log: a consumer that wrote to its own input would
#   be manufacturing the signal it reads. And a refused molt leaves an IDLE-LOOKING
#   pane — there is nothing to rename and nobody to inject — so a watcher that
#   started typing would be acting on a window whose glyph is telling the truth.
setup_case
molt_row 40 refused-not-offboarded 61
molt_row 5  refused-rate-limited   73
BEFORE=$(cat "$HARNESS_STATE_DIR/molt-ledger.jsonl")
run
if [ "$BEFORE" = "$(cat "$HARNESS_STATE_DIR/molt-ledger.jsonl")" ] \
   && [ "$(count renames)" = 0 ] && [ "$(count inject-calls)" = 0 ] && [ "$(count started)" = 0 ]; then
  ok
else
  bad "35 read-only: the watcher never writes the molt ledger and never touches a pane (renames=$(count renames) injects=$(count inject-calls) started=$(count started))"
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
