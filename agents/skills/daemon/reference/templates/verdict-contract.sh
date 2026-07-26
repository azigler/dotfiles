#!/usr/bin/env bash
# Template: the unattended-script reporting contract (dotfiles-cxle).
#
# WHY: the fleet's dominant defect is "a step stops working while the thing
# reporting on it keeps saying success." A daemon is the worst host for it —
# unattended, on a timer, nobody reading stdout. Copy this shape into any
# script whose success another script (or a ledger, or a dashboard) consumes.
#
# Four things below, in order: EMIT a verdict on every terminal path · CONSUME
# it fail-closed · VERIFY the write by re-reading · report COVERAGE. Working
# real instances: ~/andrewzigler3/src/scripts/push-github-readme.sh (emitter)
# + readme_push_verdict() in ~/andrewzigler3/scripts/daily-build.sh (consumer)
# + lib/gdoc/handlers.ts "Proof, not trust" in the LinearB fleet agent (502 on
# a write that didn't land).
#
# NOT runnable as-is: peer_reachable / count_inputs / list_inputs / write_item /
# verify_item / advance_cursor and $LEDGER are placeholders for your daemon's.
set -euo pipefail

MARKER=SYNC_RESULT   # <NAME>_RESULT — one marker name per script, documented in its header

# ── 1. EMIT: exactly one marker on EVERY terminal path, including the boring
#    ones. "Nothing to do" and "peer absent" are verdicts, not silence. An
#    early `exit 0` with no marker is the bug this whole file exists to stop.
emit() { printf '%s=%s\n' "$MARKER" "$1"; }
trap 'rc=$?; [ "$rc" -ne 0 ] && emit failed; exit "$rc"' EXIT   # crashes report too

if ! peer_reachable; then
  # Intermittent upstream (travel laptop, phone): ABSENT is expected, not an
  # incident. Own verdict, logged, never alarmed, cursor untouched.
  emit absent
  exit 0
fi

# ── 4. COVERAGE: a step that processes N inputs says how many it ACTUALLY
#    processed against how many exist. `truncated: true` is not a report;
#    "200 candidates from 1 of 67 sessions" is (explore-j2p9).
TOTAL=$(count_inputs)
DONE=0
for item in $(list_inputs); do
  # ── 3. POST-WRITE VERIFICATION: re-read the target and compare. Never trust
  #    the response — a 200 OK with a frozen modified_at is the normal failure.
  write_item "$item"
  if ! verify_item "$item"; then
    emit failed
    echo "write not present on re-read: $item" >&2
    exit 1        # the cursor/watermark below is NOT advanced — stays retryable
  fi
  DONE=$((DONE + 1))
done

# The gate advances on OUTCOME, never on intent (bd-troe: a failed push still
# advanced the content hash, so the artifact stayed stale and nothing retried).
if [ "$DONE" -eq "$TOTAL" ]; then
  advance_cursor
  emit ok
else
  emit partial   # partial is a real verdict; the consumer decides what it means
fi
echo "coverage: processed ${DONE}/${TOTAL}" >&2

# Every ledger line names the row it evaluated: never null, never a guessed
# name; the only escape hatch is the literal "unattributed" (see /pulse).
printf '{"ts":"%s","row":"%s","outcome":"%s","processed":%d,"total":%d}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${LEDGER_ROW:-unattributed}" \
  "${VERDICT:-unknown}" "$DONE" "$TOTAL" >> "$LEDGER"

# ── 2. CONSUME (this half lives in the CALLING script). Capture output — do
#    NOT suppress it — read the marker, and treat "exit 0, no marker" as
#    FAILURE. `cmd && DID_IT=true` is the defect one layer down: it was the
#    PRESCRIBED fix in bd-xtm9 and reproduced the bug it was meant to close.
sync_verdict() {                       # args: <exit_code> <captured_output>
  local rc="$1" out="$2"
  [ "$rc" -ne 0 ] && { echo failed; return 0; }
  case "$out" in
    *"SYNC_RESULT=ok"*)      echo ok ;;
    *"SYNC_RESULT=partial"*) echo partial ;;
    *"SYNC_RESULT=absent"*)  echo absent ;;
    *"SYNC_RESULT=failed"*)  echo failed ;;
    *) echo unknown ;;                 # fail-closed: unverifiable != success
  esac
}
# Caller:
#   OUT="$(./sync.sh 2>&1)"; RC=$?; printf '%s\n' "$OUT"     # echo it to the log
#   V="$(sync_verdict "$RC" "$OUT")"
#   [ "$V" = ok ] && SYNCED=true       # the ONLY place success becomes true
#   [ "$V" = unknown ] && log "WARNING: exit 0, no verdict — treating as NOT synced"
#
# NEGATIVE CONTROL, before you trust any of this: break the effect (stash the
# write, revoke the token, empty the input) and re-run. The verdict MUST come
# back non-ok and the caller MUST notice. A check that cannot fail is not a
# check — keep sync_verdict pure so a test can drive every case offline.
