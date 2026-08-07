#!/bin/bash
# Test for pulse-ledger-watch.sh — the LOCAL-loop completion watcher (dotfiles-wqby).
#
# Hermetic: a per-case tmpdir holds the manifest, the project + its ledger, the
# watcher's state root, and a FAKE `systemctl` shim on PATH. No real unit, no real
# ledger, no real surface queue is touched — except in the end-to-end bounce case,
# which drives the REAL pulse-surface-queue.sh against a fake injector, because a
# stubbed queue cannot prove the "never dropped, never duplicated" property that
# case exists to prove.
#
# The shim reads $PLW_FAKE:
#   $PLW_FAKE/units             — one unit name per line, for `list-unit-files`
#   $PLW_FAKE/execstart/<unit>  — value printed for `show <unit> -p ExecStart --value`
#
# Convention matches the other test-*.sh here: executable bash, non-zero exit =
# failure, PASS/FAIL summary on the last line.

set -u

WATCH="$(cd "$(dirname "$0")" && pwd)/pulse-ledger-watch.sh"
REAL_QUEUE="$(cd "$(dirname "$0")" && pwd)/pulse-surface-queue.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

BIN="$ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/systemctl" <<'EOSC'
#!/bin/bash
# Fake systemctl — only the two reads pulse-ledger-watch.sh makes.
sub=""; unit=""; prop=""
i=1
while [ "$i" -le "$#" ]; do
  a="${!i}"
  case "$a" in
    list-unit-files) sub=list ;;
    show)            sub=show ;;
    -p)              i=$((i + 1)); prop="${!i}" ;;
    *.service)       unit="$a" ;;
  esac
  i=$((i + 1))
done
case "$sub" in
  list)
    # $PLW_FAKE/systemctl-fail reproduces "no user bus": stderr + non-zero rc +
    # NOTHING on stdout — indistinguishable from "zero units" to a caller that
    # does not check the exit status, which is the whole point of the case.
    if [ -f "$PLW_FAKE/systemctl-fail" ]; then
      echo "Failed to connect to bus: No medium found" >&2
      exit 1
    fi
    [ -f "$PLW_FAKE/units" ] && awk 'NF {print $1"  static  -"}' "$PLW_FAKE/units" ;;
  show) [ "$prop" = ExecStart ] && [ -f "$PLW_FAKE/execstart/$unit" ] && cat "$PLW_FAKE/execstart/$unit" ;;
esac
exit 0
EOSC
chmod +x "$BIN/systemctl"
export PATH="$BIN:$PATH"

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

INJECT_LOCAL='{ path=/x/pulse-inject.sh ; argv[]=/x/pulse-inject.sh --loop pulse-demo --dir /p --session work --window demo --cmd /pulse tick ; }'

# setup_case: fresh state + fake unit table + a one-loop manifest + a project whose
# ledger already holds one row. Exports everything the watcher reads.
setup_case() {
  CASE=$(mktemp -d)
  PLW_FAKE="$CASE/fake"
  mkdir -p "$PLW_FAKE/execstart" "$CASE/proj/refs"
  export PLW_FAKE
  export PULSE_LEDGER_WATCH_STATE="$CASE/state"
  export PULSE_LEDGER_WATCH_LOG="$CASE/watch.log"
  export HARNESS_MANIFEST="$CASE/manifest.json"
  LEDGER="$CASE/proj/refs/pulse-ledger.jsonl"

  printf 'pulse-demo.service\n' > "$PLW_FAKE/units"
  printf '%s\n' "$INJECT_LOCAL" > "$PLW_FAKE/execstart/pulse-demo.service"
  cat > "$HARNESS_MANIFEST" <<MANEOF
{"version":1,"projects":[{"key":"demo","path":"$CASE/proj","loops":[
  {"timer":"pulse-demo","ledger":"refs/pulse-ledger.jsonl","ledger_row":"demo"}]}]}
MANEOF
  row 2026-08-01T10:00:00Z done "the first row"

  # Recorder queue stub. STAGE_VERDICT scripts the outcome so a failed stage can be
  # asserted without corrupting a real queue.
  cat > "$CASE/queue" <<'QEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$PLW_FAKE/stage-calls"
printf 'PULSE_SURFACE_RESULT=%s\n' "${STAGE_VERDICT:-staged}"
exit 0
QEOF
  chmod +x "$CASE/queue"
  export PULSE_SURFACE_QUEUE="$CASE/queue"
}

# row <ts> <outcome> <note> [rowname] — append a ledger row.
row() {
  local rn=${4:-demo}
  printf '{"ts":"%s","row":"%s","outcome":"%s","note":"%s"}\n' "$1" "$rn" "$2" "$3" >> "$LEDGER"
}

stage_calls() { [ -f "$PLW_FAKE/stage-calls" ] && wc -l < "$PLW_FAKE/stage-calls" | tr -d ' ' || echo 0; }
marker() { cat "$PULSE_LEDGER_WATCH_STATE/marks/pulse-demo" 2>>"$CASE/err" || true; }
verdict_of() { printf '%s\n' "$1" | grep -o 'PULSE_LEDGER_WATCH_RESULT=[a-z0-9:-]*' | tail -1 | cut -d= -f2-; }

# ---------------------------------------------------------------------------
# Case 1: FIRST SIGHT SEEDS, it does not announce. With no marker there is no
#   honest answer to "newer than what", and announcing would replay a backlog Zig
#   has already seen.
setup_case
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:1:errors:0" ] && [ "$(stage_calls)" = 0 ]; then ok
else bad "first sight seeds and stages nothing (verdict=$(verdict_of "$OUT") stages=$(stage_calls))"; fi
if [ "$(marker)" = "2026-08-01T10:00:00Z" ]; then ok
else bad "first sight records the newest ts as the marker (got '$(marker)')"; fi

# ---------------------------------------------------------------------------
# Case 2: a NEW ledger row stages EXACTLY ONE surface, and the marker advances to
#   that row's ts.
setup_case
"$WATCH" > /dev/null 2>&1                       # seed
row 2026-08-02T11:00:00Z done "the report published"
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:1:seeded:0:errors:0" ] && [ "$(stage_calls)" = 1 ]; then ok
else bad "a new row stages exactly one surface (verdict=$(verdict_of "$OUT") stages=$(stage_calls))"; fi
if [ "$(marker)" = "2026-08-02T11:00:00Z" ]; then ok
else bad "a staged surface advances the marker to that row's ts (got '$(marker)')"; fi

# The stage call has to carry the row (the queue's collapse key), the loop's own
# session:window (so an ATTENDED tick's own 🔔 defers it), and the project dir.
CALL=$(cat "$PLW_FAKE/stage-calls")
for tok in "--row demo" "--session work" "--window demo" "--dir $CASE/proj" "--reason completed:done"; do
  case "$CALL" in
    *"$tok"*) ok ;;
    *) bad "the stage call carries '$tok' (got: $CALL)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Case 3: IDEMPOTENCE. Two runs, no new row between them → nothing more staged.
setup_case
"$WATCH" > /dev/null 2>&1                       # seed
row 2026-08-02T11:00:00Z done "published"
"$WATCH" > /dev/null 2>&1                       # stages once
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:0:errors:0" ] && [ "$(stage_calls)" = 1 ]; then ok
else bad "a second run with no new row stages nothing (verdict=$(verdict_of "$OUT") stages=$(stage_calls))"; fi

# ---------------------------------------------------------------------------
# Case 4: two rows land between runs → ONE stage, for the NEWEST. Collapse is the
#   queue's rule; this is the same rule one layer up, so the queue never even sees
#   the superseded row.
setup_case
"$WATCH" > /dev/null 2>&1
row 2026-08-02T11:00:00Z done "first"
row 2026-08-02T19:00:00Z quiet "second"
"$WATCH" > /dev/null 2>&1
if [ "$(stage_calls)" = 1 ] && [ "$(marker)" = "2026-08-02T19:00:00Z" ]; then ok
else bad "two new rows → one stage for the newest (stages=$(stage_calls) marker=$(marker))"; fi
case "$(cat "$PLW_FAKE/stage-calls")" in
  *"--reason completed:quiet"*) ok ;;
  *) bad "the staged surface is the NEWEST row's outcome" ;;
esac

# ---------------------------------------------------------------------------
# Case 5: done / quiet / blocked ALL surface — the dispatcher's always-surface
#   policy, not a filter for "interesting" outcomes.
for out in done quiet blocked; do
  setup_case
  "$WATCH" > /dev/null 2>&1
  row 2026-08-02T11:00:00Z "$out" "an outcome"
  "$WATCH" > /dev/null 2>&1
  if [ "$(stage_calls)" = 1 ] && grep -q -- "--reason completed:$out" "$PLW_FAKE/stage-calls"; then ok
  else bad "outcome '$out' surfaces like every other (stages=$(stage_calls))"; fi
done

# ---------------------------------------------------------------------------
# Case 6: a FAILED STAGE does NOT advance the marker — the row is retried on the
#   next run rather than lost. (The DRAIN failing is a different thing entirely;
#   see the end-to-end bounce case below.)
setup_case
"$WATCH" > /dev/null 2>&1
row 2026-08-02T11:00:00Z done "published"
OUT=$(STAGE_VERDICT=failed "$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:0:errors:1" ] && [ "$(marker)" = "2026-08-01T10:00:00Z" ]; then ok
else bad "a refused stage leaves the marker put (verdict=$(verdict_of "$OUT") marker=$(marker))"; fi
"$WATCH" > /dev/null 2>&1
if [ "$(stage_calls)" = 2 ] && [ "$(marker)" = "2026-08-02T11:00:00Z" ]; then ok
else bad "the next run retries the row a refused stage left behind (stages=$(stage_calls) marker=$(marker))"; fi

# ---------------------------------------------------------------------------
# Case 7: a MISSING LEDGER is an ERROR that says so out loud. It must never read as
#   "no new rows" — that silence is the whole defect this script exists to end.
setup_case
rm -f "$LEDGER"
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:0:errors:1" ]; then ok
else bad "a missing ledger counts as an ERROR (verdict=$(verdict_of "$OUT"))"; fi
if printf '%s' "$OUT" | grep -q 'ERROR pulse-demo/ledger-missing'; then ok
else bad "a missing ledger names itself loudly on stderr (got: $OUT)"; fi
if [ ! -f "$PULSE_LEDGER_WATCH_STATE/marks/pulse-demo" ]; then ok
else bad "a missing ledger writes no marker (a marker would hide the drift forever)"; fi

# ---------------------------------------------------------------------------
# Case 8: a LOCAL loop with NO MANIFEST ENTRY is an ERROR. Its completions can
#   never be resolved to a ledger, so it would silently never surface.
setup_case
printf 'pulse-demo.service\npulse-orphan.service\n' > "$PLW_FAKE/units"
printf '%s\n' "$INJECT_LOCAL" > "$PLW_FAKE/execstart/pulse-orphan.service"
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:1:errors:1" ]; then ok
else bad "an unregistered local loop is an ERROR beside the healthy one (verdict=$(verdict_of "$OUT"))"; fi
if printf '%s' "$OUT" | grep -q 'ERROR pulse-orphan/unregistered'; then ok
else bad "the unregistered loop is named loudly on stderr (got: $OUT)"; fi

# ---------------------------------------------------------------------------
# Case 9: an UNREADABLE MANIFEST stops everything, loudly. Nothing is watched, and
#   the script must not report that state as a quiet clean run.
setup_case
rm -f "$HARNESS_MANIFEST"
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:0:errors:1" ] && printf '%s' "$OUT" | grep -q 'ERROR manifest'; then ok
else bad "an absent manifest is a loud error, not a clean run (verdict=$(verdict_of "$OUT"))"; fi
setup_case
printf 'this is not json\n' > "$HARNESS_MANIFEST"
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:0:errors:1" ] && printf '%s' "$OUT" | grep -q 'ERROR manifest'; then ok
else bad "an unparsable manifest is a loud error (verdict=$(verdict_of "$OUT"))"; fi

# ---------------------------------------------------------------------------
# Case 10: a CORRUPT ledger line is an ERROR, not "nothing new". A half-written row
#   is exactly when a completion is most likely to be pending.
setup_case
"$WATCH" > /dev/null 2>&1
printf '{"ts":"2026-08-02T11:00:00Z","row":"demo","outcome":"do\n' >> "$LEDGER"
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:0:errors:1" ] \
   && printf '%s' "$OUT" | grep -q 'ERROR pulse-demo/ledger-unparsable'; then ok
else bad "a corrupt ledger is a loud error (verdict=$(verdict_of "$OUT"))"; fi

# ---------------------------------------------------------------------------
# Case 11: a manifest ledger_row that matches NO row in the ledger is drift, and
#   drift here means a loop that can never surface. Loud, not silent.
setup_case
cat > "$HARNESS_MANIFEST" <<MANEOF
{"version":1,"projects":[{"key":"demo","path":"$CASE/proj","loops":[
  {"timer":"pulse-demo","ledger":"refs/pulse-ledger.jsonl","ledger_row":"typo-row"}]}]}
MANEOF
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:0:errors:1" ] \
   && printf '%s' "$OUT" | grep -q 'ERROR pulse-demo/row-absent'; then ok
else bad "a row pin matching nothing is a loud error (verdict=$(verdict_of "$OUT"))"; fi

# Case 11b: ledger_row null means MATCH ANY ROW (the picod shape the manifest
#   documents) — a null pin must not be read as the empty-string row name.
setup_case
cat > "$HARNESS_MANIFEST" <<MANEOF
{"version":1,"projects":[{"key":"demo","path":"$CASE/proj","loops":[
  {"timer":"pulse-demo","ledger":"refs/pulse-ledger.jsonl","ledger_row":null}]}]}
MANEOF
"$WATCH" > /dev/null 2>&1
row 2026-08-02T11:00:00Z done "some other row" other-row
"$WATCH" > /dev/null 2>&1
if [ "$(stage_calls)" = 1 ] && grep -q -- "--row pulse-demo" "$PLW_FAKE/stage-calls"; then ok
else bad "ledger_row null matches any row, keyed by the loop id (stages=$(stage_calls))"; fi

# ---------------------------------------------------------------------------
# Case 12: a REMOTELY DISPATCHED loop is skipped. pulse-dispatch-remote.sh already
#   surfaces every completion itself; watching it too would double-announce.
setup_case
printf '{ path=/x/pulse-dispatch-remote.sh ; argv[]=/x/pulse-dispatch-remote.sh --row demo ; }\n' \
  > "$PLW_FAKE/execstart/pulse-demo.service"
row 2026-08-02T11:00:00Z done "a remote tick"
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:0:errors:0" ] && [ "$(stage_calls)" = 0 ]; then ok
else bad "a dispatched loop is skipped, not double-announced (verdict=$(verdict_of "$OUT"))"; fi

# Case 12b: a pulse-* unit that injects nothing (pulse-retry, pulse-stall) is
#   skipped WITHOUT an error — it has no ledger row and no surface to lose.
setup_case
printf 'pulse-demo.service\npulse-retry.service\n' > "$PLW_FAKE/units"
printf '{ path=/x/pulse-retry.sh ; argv[]=/x/pulse-retry.sh ; }\n' > "$PLW_FAKE/execstart/pulse-retry.service"
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:1:errors:0" ]; then ok
else bad "a non-injecting pulse-* unit is a silent skip (verdict=$(verdict_of "$OUT"))"; fi

# ---------------------------------------------------------------------------
# Case 13: session/window come from the unit's ExecStart, and fall back to
#   work/pulse when it names neither.
setup_case
printf '{ path=/x/pulse-inject.sh ; argv[]=/x/pulse-inject.sh --loop pulse-demo --dir /p --cmd /pulse tick ; }\n' \
  > "$PLW_FAKE/execstart/pulse-demo.service"
"$WATCH" > /dev/null 2>&1
row 2026-08-02T11:00:00Z done "published"
"$WATCH" > /dev/null 2>&1
CALL=$(cat "$PLW_FAKE/stage-calls")
case "$CALL" in
  *"--session work"*"--window pulse"*) ok ;;
  *) bad "session/window default to work/pulse when ExecStart names neither (got: $CALL)" ;;
esac

# Case 13b: an ABSOLUTE ledger path in the manifest (the vault-sync shape) is used
#   as-is rather than joined onto the project path.
setup_case
mkdir -p "$CASE/elsewhere"
ALT="$CASE/elsewhere/other-ledger.jsonl"
printf '{"ts":"2026-08-01T10:00:00Z","row":"demo","outcome":"done","note":"x"}\n' > "$ALT"
cat > "$HARNESS_MANIFEST" <<MANEOF
{"version":1,"projects":[{"key":"demo","path":"$CASE/proj","loops":[
  {"timer":"pulse-demo","ledger":"$ALT","ledger_row":"demo"}]}]}
MANEOF
"$WATCH" > /dev/null 2>&1
printf '{"ts":"2026-08-02T11:00:00Z","row":"demo","outcome":"done","note":"y"}\n' >> "$ALT"
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:1:seeded:0:errors:0" ]; then ok
else bad "an absolute manifest ledger path is honored (verdict=$(verdict_of "$OUT"))"; fi

# ---------------------------------------------------------------------------
# Case 14 — END TO END, against the REAL pulse-surface-queue.sh: A BOUNCED DRAIN
#   LOSES NOTHING AND DUPLICATES NOTHING.
#
#   This is the case a stubbed queue cannot prove. The window is 🔔-blocked, so the
#   injector refuses; the entry must stay PENDING, the marker must already have
#   advanced (the row is staged exactly once — re-staging every 2 minutes would
#   inflate the queue's `superseded` counter and make the announcement claim the
#   tick re-ran when it did not), and when the bell clears the drain must deliver
#   exactly ONE announcement.
setup_case
export PULSE_SURFACE_QUEUE="$REAL_QUEUE"
export PULSE_SURFACE_STATE="$CASE/queue-root"
export PULSE_SURFACE_LOG="$CASE/queue.log"
cat > "$CASE/inject" <<'IEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$PLW_FAKE/inject-calls"
if [ -f "$PLW_FAKE/bell" ]; then
  printf 'PULSE_INJECT_RESULT=deferred-blocked-on-human\n'
else
  printf 'PULSE_INJECT_RESULT=injected\n'
fi
exit 0
IEOF
chmod +x "$CASE/inject"
export PULSE_DISPATCH_INJECT="$CASE/inject"
touch "$PLW_FAKE/bell"                          # the window is sitting on a 🔔

"$WATCH" > /dev/null 2>&1                       # seed
row 2026-08-02T11:00:00Z done "published while Zig was away"
"$WATCH" > /dev/null 2>&1                       # stages into the REAL queue
DR=$("$REAL_QUEUE" drain 2>&1)
if printf '%s' "$DR" | grep -q 'PULSE_SURFACE_RESULT=deferred:1'; then ok
else bad "a 🔔-blocked drain defers rather than delivering (got: $(printf '%s' "$DR" | tail -1))"; fi
if [ "$("$REAL_QUEUE" list | grep -c '"row":"demo"')" = 1 ]; then ok
else bad "the bounced announcement stays PENDING in the queue"; fi
if [ "$(marker)" = "2026-08-02T11:00:00Z" ]; then ok
else bad "the marker advanced on the successful STAGE, not on delivery (got '$(marker)')"; fi

"$WATCH" > /dev/null 2>&1                       # a later tick of the 2-min timer
"$WATCH" > /dev/null 2>&1
if [ "$("$REAL_QUEUE" list | grep -c '"row":"demo"')" = 1 ]; then ok
else bad "re-running the watcher while the announcement is held does NOT re-stage it"; fi
if [ "$("$REAL_QUEUE" list | grep '^{' | jq -r '.superseded' | head -1)" = "0" ]; then ok
else bad "the held entry is never collapsed onto itself (superseded must stay 0)"; fi

rm -f "$PLW_FAKE/bell"                          # Zig answers; the bell clears
DR=$("$REAL_QUEUE" drain 2>&1)
if printf '%s' "$DR" | grep -q 'PULSE_SURFACE_RESULT=delivered:1'; then ok
else bad "the held announcement is delivered once the bell clears (got: $(printf '%s' "$DR" | tail -1))"; fi
if [ "$("$REAL_QUEUE" list 2>&1 | grep -c '"row":"demo"')" = 0 ] \
   && [ "$(wc -l < "$PLW_FAKE/inject-calls")" = 2 ]; then ok
else bad "delivery empties the queue and announces exactly once per bounce attempt"; fi

# The surface object the announcement points at has to be readable and has to say
# the tick ran LOCALLY — the queue's own prose still says marketing-vps.
SF="$PULSE_LEDGER_WATCH_STATE/surfaces/pulse-demo.json"
if [ -s "$SF" ] && jq -e '._source == "pulse-ledger-watch" and ._ledger_ts == "2026-08-02T11:00:00Z"' "$SF" > /dev/null; then ok
else bad "the staged surface object carries its provenance and the row's ts"; fi
if jq -re '.question, .detail | strings' "$SF" | grep -q 'do NOT re-run the tick'; then ok
else bad "the surface tells the reader the ledger row is written and the tick must not be re-run"; fi
unset PULSE_SURFACE_STATE PULSE_SURFACE_LOG PULSE_DISPATCH_INJECT

# ---------------------------------------------------------------------------
# Cases 16-19 (dotfiles-sxsv) — WHAT THE DRAIN TYPES, not what the file contains.
#
#   Case 14 above asserts the surface FILE. The drain's injected command is a
#   SEPARATE piece of prose, it is read and OBEYED by the receiving Claude session,
#   and nothing asserted it — which is exactly where the P1 lived: the command was
#   hardcoded for the remote dispatcher and told the session to "land the ledger
#   row" that a LOCAL tick had already written. The session wrote a duplicate with a
#   fresh ts, this watcher read that as new two minutes later, and the announcement
#   re-typed itself forever while corrupting the ledger the mechanism reads.
#
#   So: assert the injected text, for BOTH origins, in BOTH the 1-pending and
#   n-pending forms.

# use_real_queue: point the watcher at the REAL queue with a recording injector.
use_real_queue() {
  export PULSE_SURFACE_QUEUE="$REAL_QUEUE"
  export PULSE_SURFACE_STATE="$CASE/queue-root"
  export PULSE_SURFACE_LOG="$CASE/queue.log"
  cat > "$CASE/inject" <<'IEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$PLW_FAKE/inject-calls"
printf 'PULSE_INJECT_RESULT=injected\n'
exit 0
IEOF
  chmod +x "$CASE/inject"
  export PULSE_DISPATCH_INJECT="$CASE/inject"
}
typed() { cat "$PLW_FAKE/inject-calls" 2>/dev/null; }
# has/hasnt <label> <needle> — assert the typed command does / does not carry it.
has()   { case "$(typed)" in *"$2"*) ok ;; *) bad "$1" ;; esac; }
hasnt() { case "$(typed)" in *"$2"*) bad "$1" ;; *) ok ;; esac; }

# Case 16: a LOCAL surface, 1 pending. The two false clauses must be ABSENT.
setup_case
use_real_queue
"$WATCH" > /dev/null 2>&1                       # seed
row 2026-08-02T11:00:00Z done "the report published"
"$WATCH" > /dev/null 2>&1                       # stage, --origin local
"$REAL_QUEUE" drain > /dev/null 2>&1
hasnt "a LOCAL surface never claims the tick ran on marketing-vps"     "marketing-vps"
hasnt "a LOCAL surface never tells the session to land the ledger row" "land the ledger row"
hasnt "a LOCAL surface never tells the session to land any ledger rows" "land any ledger rows"
has   "a LOCAL surface says the ledger row is ALREADY WRITTEN"         "ALREADY WRITTEN"
has   "a LOCAL surface still forbids re-running the tick"              "Do NOT re-run the tick"
has   "a LOCAL surface labels itself LOCAL"                            "LOCAL PULSE SURFACE"
unset PULSE_SURFACE_STATE PULSE_SURFACE_LOG PULSE_DISPATCH_INJECT

# Case 17: a REMOTE surface, 1 pending — the dispatcher's wording, UNCHANGED. It
#   stages without --origin, so this also pins the default.
setup_case
use_real_queue
"$REAL_QUEUE" stage --row demo --run r1 --session work --window demo --dir "$CASE/proj" \
  --file /tmp/nope.json --reason completed:done --summary "a remote tick" > /dev/null 2>&1
"$REAL_QUEUE" drain > /dev/null 2>&1
has   "a REMOTE surface still says the tick ran on marketing-vps"  "ran on marketing-vps"
has   "a REMOTE surface still says to land the ledger row"         "land the ledger row at $CASE/proj/refs/pulse-ledger.jsonl"
has   "a REMOTE surface still labels itself REMOTE"                "REMOTE PULSE SURFACE"
hasnt "a REMOTE surface does not claim the row is already written" "ALREADY WRITTEN"
unset PULSE_SURFACE_STATE PULSE_SURFACE_LOG PULSE_DISPATCH_INJECT

# Case 18: the N-PENDING form carries the same clauses INDEPENDENTLY — it is a
#   different sentence, not a truncation, so fixing only the single form fixes half
#   the bug. Two local rows into one window.
setup_case
use_real_queue
for r in alpha beta; do
  "$REAL_QUEUE" stage --row "$r" --run "lw:$r" --session work --window demo --dir "$CASE/proj" \
    --file "/tmp/$r.json" --origin local --reason completed:done --summary "$r landed" > /dev/null 2>&1
done
"$REAL_QUEUE" drain > /dev/null 2>&1
hasnt "the n-pending LOCAL form never claims marketing-vps"          "marketing-vps"
hasnt "the n-pending LOCAL form never says to land any ledger rows"  "land any ledger rows"
has   "the n-pending LOCAL form says the rows are ALREADY WRITTEN"   "ALREADY WRITTEN"
has   "the n-pending LOCAL form still forbids re-running any tick"   "Do NOT re-run any tick"
has   "the n-pending LOCAL form labels itself LOCAL"                 "LOCAL PULSE SURFACE (2 PENDING"
unset PULSE_SURFACE_STATE PULSE_SURFACE_LOG PULSE_DISPATCH_INJECT

# Case 18b: the n-pending REMOTE form is unchanged (both stages omit --origin).
setup_case
use_real_queue
for r in alpha beta; do
  "$REAL_QUEUE" stage --row "$r" --run "d:$r" --session work --window demo --dir "$CASE/proj" \
    --file "/tmp/$r.json" --reason completed:done --summary "$r landed" > /dev/null 2>&1
done
"$REAL_QUEUE" drain > /dev/null 2>&1
has "the n-pending REMOTE form still says to land any ledger rows" "land any ledger rows at $CASE/proj/refs/pulse-ledger.jsonl"
has "the n-pending REMOTE form still labels itself REMOTE"         "REMOTE PULSE SURFACE (2 PENDING"
unset PULSE_SURFACE_STATE PULSE_SURFACE_LOG PULSE_DISPATCH_INJECT

# Case 19: a MIXED group (one local, one remote waiting on the same window) claims
#   neither origin globally, marks the local entry, and scopes the ledger
#   instruction to the entries that are NOT marked local.
setup_case
use_real_queue
"$REAL_QUEUE" stage --row remoterow --run d1 --session work --window demo --dir "$CASE/proj" \
  --file /tmp/a.json --reason completed:done --summary "remote landed" > /dev/null 2>&1
"$REAL_QUEUE" stage --row localrow --run lw1 --session work --window demo --dir "$CASE/proj" \
  --file /tmp/b.json --origin local --reason completed:done --summary "local landed" > /dev/null 2>&1
"$REAL_QUEUE" drain > /dev/null 2>&1
has "a MIXED group labels itself MIXED"                              "MIXED PULSE SURFACE"
has "a MIXED group marks the LOCAL entry in the per-row list"        "ran LOCALLY (its ledger row is ALREADY written)"
has "a MIXED group scopes the ledger instruction to the non-LOCAL entries" "ONLY for the entries above that are NOT marked 'ran LOCALLY'"
unset PULSE_SURFACE_STATE PULSE_SURFACE_LOG PULSE_DISPATCH_INJECT

# ---------------------------------------------------------------------------
# Case 15: --loop narrows the run to one loop (the manual/diagnostic path), and
#   --dry-run stages nothing and writes no marker.
setup_case
printf 'pulse-demo.service\npulse-other.service\n' > "$PLW_FAKE/units"
printf '%s\n' "$INJECT_LOCAL" > "$PLW_FAKE/execstart/pulse-other.service"
OUT=$("$WATCH" --loop pulse-demo 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:1:errors:0" ]; then ok
else bad "--loop considers only the named loop (verdict=$(verdict_of "$OUT"))"; fi
setup_case
"$WATCH" > /dev/null 2>&1
row 2026-08-02T11:00:00Z done "published"
OUT=$("$WATCH" --dry-run 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:1:seeded:0:errors:0" ] && [ "$(stage_calls)" = 0 ] \
   && [ "$(marker)" = "2026-08-01T10:00:00Z" ]; then ok
else bad "--dry-run reports the stage it would make and changes nothing (stages=$(stage_calls) marker=$(marker))"; fi

# ---------------------------------------------------------------------------
# Cases 20-25 — the four findings from the dotfiles-wqby adversarial review. Each
# one was reproduced with a probe before it was fixed; each case is that probe.

# Case 20 (finding 1): CONCURRENT RUNS STAGE ONCE. The queue's lock guards the
#   queue FILE, not this script's read-marker → stage → write-marker window, so two
#   runs used to both read the stale marker and both stage the same row —
#   pending:1 with superseded:1, an announcement claiming a tick re-ran when it did
#   not. The slow stage stub widens the window so the race is deterministic.
setup_case
cat > "$CASE/queue" <<'QEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$PLW_FAKE/stage-calls"
sleep 1
printf 'PULSE_SURFACE_RESULT=staged\n'
exit 0
QEOF
chmod +x "$CASE/queue"
"$WATCH" > /dev/null 2>&1                       # seed
row 2026-08-02T11:00:00Z done "published"
"$WATCH" > /dev/null 2>&1 &
"$WATCH" > /dev/null 2>&1 &
wait
if [ "$(stage_calls)" = 1 ] && [ "$(marker)" = "2026-08-02T11:00:00Z" ]; then ok
else bad "two concurrent runs stage one new row exactly ONCE (stages=$(stage_calls) marker=$(marker))"; fi

# Case 21 (finding 2): AN UNWRITABLE marks/ REFUSES TO STAGE, loudly, rather than
#   staging the same row on every run forever. Reproduced with chmod 555: the stage
#   succeeded, the marker write failed, and cumulative stage calls went 1 → 2 → 3
#   with the queue's `superseded` climbing behind them.
if [ "$(id -u)" = 0 ]; then
  ok; ok; ok                                    # running as root defeats chmod; not a real skip path on this fleet
else
  setup_case
  "$WATCH" > /dev/null 2>&1                     # seed
  row 2026-08-02T11:00:00Z done "published"
  chmod 555 "$PULSE_LEDGER_WATCH_STATE/marks"
  OUT=$("$WATCH" 2>&1)
  if [ "$(verdict_of "$OUT")" = "staged:0:seeded:0:errors:1" ] && [ "$(stage_calls)" = 0 ] \
     && printf '%s' "$OUT" | grep -q 'ERROR pulse-demo/marker-unwritable'; then ok
  else bad "an unwritable marks/ refuses to stage and says so (verdict=$(verdict_of "$OUT") stages=$(stage_calls))"; fi
  "$WATCH" > /dev/null 2>&1
  if [ "$(stage_calls)" = 0 ]; then ok
  else bad "an unwritable marks/ never accumulates repeat stagings (stages=$(stage_calls))"; fi
  chmod 755 "$PULSE_LEDGER_WATCH_STATE/marks"
  "$WATCH" > /dev/null 2>&1
  if [ "$(stage_calls)" = 1 ] && [ "$(marker)" = "2026-08-02T11:00:00Z" ]; then ok
  else bad "the held row surfaces once marks/ is writable again (stages=$(stage_calls) marker=$(marker))"; fi
fi

# Case 22 (finding 3a): A FAILED systemctl ENUMERATION IS AN ERROR. With no user
#   bus, systemctl prints nothing, writes to stderr and exits non-zero — and
#   `mapfile < <(systemctl …)` reported that as zero units and a clean
#   staged:0:seeded:0:errors:0 run. Total blindness dressed as normality.
setup_case
touch "$PLW_FAKE/systemctl-fail"
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:0:errors:1" ] \
   && printf '%s' "$OUT" | grep -q 'ERROR systemctl'; then ok
else bad "a failed unit enumeration is a loud error, not a clean run (verdict=$(verdict_of "$OUT"))"; fi
# and a SUCCESSFUL enumeration that matches nothing is still anomalous: pulse-retry
# .service alone should always match on a box that runs this watcher.
setup_case
: > "$PLW_FAKE/units"
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:0:errors:1" ] \
   && printf '%s' "$OUT" | grep -q 'ERROR no-units'; then ok
else bad "zero matching units is a loud error (verdict=$(verdict_of "$OUT"))"; fi

# Case 23 (finding 3b): A TRUNCATED MARKER RECOVERS BY ANNOUNCING, loudly. The old
#   code could not tell "no marker" from "empty marker", so it RE-SEEDED: the
#   marker jumped past a finished tick and that announcement was lost permanently.
#   One duplicate announcement (which the queue collapses) beats a silent loss.
for junk in "" "garbage"; do
  setup_case
  "$WATCH" > /dev/null 2>&1                     # seed
  row 2026-08-02T11:00:00Z done "published"
  printf '%s' "$junk" > "$PULSE_LEDGER_WATCH_STATE/marks/pulse-demo"
  OUT=$("$WATCH" 2>&1)
  if [ "$(verdict_of "$OUT")" = "staged:1:seeded:0:errors:1" ] && [ "$(stage_calls)" = 1 ] \
     && [ "$(marker)" = "2026-08-02T11:00:00Z" ] \
     && printf '%s' "$OUT" | grep -q 'ERROR pulse-demo/marker-corrupt'; then ok
  else bad "a corrupt marker ('$junk') announces rather than re-seeding, and says so (verdict=$(verdict_of "$OUT") stages=$(stage_calls))"; fi
done

# Case 24 (finding 3c): A MALFORMED ts IS AN ERROR. ts_key() strips non-digits, so
#   "yesterday" became 0, which is <= any marker, which logged "no new row" and
#   returned errors:0 — the quietest failure in the script. There was an explicit
#   error for an ABSENT ts and none for an unusable one.
setup_case
"$WATCH" > /dev/null 2>&1                       # seed
printf '{"ts":"yesterday","row":"demo","outcome":"done","note":"x"}\n' >> "$LEDGER"
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:0:errors:1" ] && [ "$(stage_calls)" = 0 ] \
   && printf '%s' "$OUT" | grep -q 'ERROR pulse-demo/row-ts-unparsable'; then ok
else bad "an unparsable ts is a loud error, not a silent skip (verdict=$(verdict_of "$OUT"))"; fi
# A date-only ts is the subtler half: it PARSES as digits (8 of them) but compares
# wrongly against a 14-digit key, so it would read as older than every real row.
setup_case
"$WATCH" > /dev/null 2>&1
printf '{"ts":"2026-08-02","row":"demo","outcome":"done","note":"x"}\n' >> "$LEDGER"
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:0:errors:1" ] \
   && printf '%s' "$OUT" | grep -q 'ERROR pulse-demo/row-ts-unparsable'; then ok
else bad "a truncated (date-only) ts is a loud error (verdict=$(verdict_of "$OUT"))"; fi

# Case 25 (finding 4): A NEWLY REGISTERED LOOP'S FIRST REAL TICK SURFACES. It used
#   not to: with no matching row, run 1 errored (row-absent) and wrote no marker, so
#   the run after the loop's FIRST REAL TICK was that row's "first sight" — it
#   seeded and announced nothing, and only the SECOND tick ever surfaced. That is
#   not a 2-minute install window; it is every new loop, always. The row-absent path
#   now writes a floor marker on the way past.
setup_case
: > "$LEDGER"                                   # registered, never ticked
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:0:errors:1" ] \
   && printf '%s' "$OUT" | grep -q 'ERROR pulse-demo/row-absent'; then ok
else bad "a loop with no matching row is still a loud error (verdict=$(verdict_of "$OUT"))"; fi
if [ "$(marker)" = "0000-00-00T00:00:00Z" ]; then ok
else bad "the row-absent path leaves a FLOOR marker so the first real row is not swallowed (got '$(marker)')"; fi
row 2026-08-02T11:00:00Z done "the very first tick"
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:1:seeded:0:errors:0" ] && [ "$(stage_calls)" = 1 ]; then ok
else bad "the FIRST real tick of a newly registered loop SURFACES (verdict=$(verdict_of "$OUT") stages=$(stage_calls))"; fi
# and the honest half of the header still holds: a loop whose ledger already has
# history when the watcher first sees it seeds, and does not replay that backlog.
setup_case
OUT=$("$WATCH" 2>&1)
if [ "$(verdict_of "$OUT")" = "staged:0:seeded:1:errors:0" ] && [ "$(stage_calls)" = 0 ]; then ok
else bad "a pre-existing ledger still SEEDS on first sight (verdict=$(verdict_of "$OUT"))"; fi

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
