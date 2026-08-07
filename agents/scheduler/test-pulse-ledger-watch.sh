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
  list) [ -f "$PLW_FAKE/units" ] && awk 'NF {print $1"  static  -"}' "$PLW_FAKE/units" ;;
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
