#!/bin/bash
# mutate-stop-context-guard.sh — mutation harness for stop-context-guard.sh's
# turn-end stamp / re-arm / nudge machinery (dotfiles-ygf8).
#
# WHY THIS EXISTS. Same argument as mutate-seat-molt.sh and
# mutate-tunnel-ownership.sh: every one of these three behaviors fails
# SILENTLY when it stops biting, and none of them turn the suite red on
# their own. A dropped stamp write means seat-molt.sh --self waits forever
# with no sign anything is wrong. A dropped re-arm means the 75% backstop is
# dead for the rest of a session's life after its first climb past the
# floor — the exact live bug (Zig at 78%, no guard firing) this bead was
# filed for. A nudge that ignores its own rate limit is a nag, which the AC
# explicitly rules out. Only a mutant proves the test actually bites.
#
# Same two disciplines as mutate-seat-molt.sh, not re-derived here:
#   - a mutation must be ASSERTED APPLIED (exact single occurrence in the
#     pristine file, bytes changed, valid bash) before the suite's exit code
#     means anything — an unapplied mutation is a HARNESS ERROR, not a kill.
#   - a killed mutant must fail the case(s) it NAMES, not just "something".
#
#   bash agents/hooks/test/mutate-stop-context-guard.sh [-v]

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")" && pwd)"          # agents/hooks/test
HOOKS_SRC="$(cd "$SRC/.." && pwd)"            # agents/hooks
AGENTS_SRC="$(cd "$HOOKS_SRC/.." && pwd)"     # agents
REPO_SRC="$(cd "$AGENTS_SRC/.." && pwd)"      # repo root

HOOK="stop-context-guard.sh"
SUITE="test-stop-context-guard.sh"

[ -f "$HOOKS_SRC/$HOOK" ] || { echo "HARNESS ERROR: $HOOKS_SRC/$HOOK does not exist" >&2; exit 2; }
[ -f "$SRC/$SUITE" ]      || { echo "HARNESS ERROR: $SRC/$SUITE does not exist" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-scg.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/pristine" "$WORK/agents/hooks/test"
cp -a "$HOOKS_SRC/$HOOK" "$WORK/pristine/$HOOK"
cp -a "$SRC/$SUITE"      "$WORK/pristine/$SUITE"

# Everything the hook and its suite resolve as siblings, mirrored at the
# SAME relative depth as the real repo (agents/hooks/test/..., not
# hooks/test/...) — the suite derives STATUSLINE and scheduler paths by
# climbing from its own $0, so a shallower mirror resolves them to bogus
# paths outside $WORK, not a missing file, and fails silently. Symlinked,
# not copied, so the mutant is the ONLY difference from a real checkout.
ln -sfn "$HOOKS_SRC/lib" "$WORK/agents/hooks/lib"
ln -sfn "$HOOKS_SRC/pre-compact-observe.sh" "$WORK/agents/hooks/pre-compact-observe.sh"
ln -sfn "$HOOKS_SRC/pre-compact.sh" "$WORK/agents/hooks/pre-compact.sh"
ln -sfn "$AGENTS_SRC/scheduler" "$WORK/agents/scheduler"
ln -sfn "$REPO_SRC/claude" "$WORK/claude"

FAILED=0
MUTANT_OK=0
SUITE_OUT=""

fresh_copy() {
  MUTANT_OK=1
  cp -a "$WORK/pristine/$HOOK"  "$WORK/agents/hooks/$HOOK"
  cp -a "$WORK/pristine/$SUITE" "$WORK/agents/hooks/test/$SUITE"
}

harness_error() {
  echo "HARNESS ERROR  $*" >&2
  FAILED=1
  MUTANT_OK=0
}

# mutate <hook|suite> <literal-from> <literal-to>
mutate() {
  local which=$1 from=$2 to=$3
  local fname path pristine
  case "$which" in
    hook)  fname=$HOOK;  path="$WORK/agents/hooks/$HOOK";       pristine="$WORK/pristine/$HOOK" ;;
    suite) fname=$SUITE; path="$WORK/agents/hooks/test/$SUITE"; pristine="$WORK/pristine/$SUITE" ;;
    *) harness_error "unknown mutate target '$which'"; return 1 ;;
  esac

  python3 - "$pristine" "$path" "$from" "$to" <<'PY'
import sys
pristine, path, frm, to = sys.argv[1:5]
before = open(pristine).read()
n = before.count(frm)
if n != 1:
    sys.stderr.write(f"  target text occurs {n}x (want exactly 1) in {pristine}\n")
    sys.stderr.write("  the line this mutant aims at has MOVED or CHANGED; "
                      "re-derive the mutant from the current source.\n")
    sys.exit(1)
if to in before:
    sys.stderr.write("  replacement text is ALREADY present in the pristine "
                      "file -- this mutation would be a no-op.\n")
    sys.exit(1)
after = before.replace(frm, to)
open(path, "w").write(after)
if after.count(to) != 1:
    sys.stderr.write("  replacement is not present exactly once after the write\n")
    sys.exit(1)
PY
  local rc=$?
  [ $rc -eq 0 ] || { harness_error "$fname: mutation did not apply"; return 1; }

  if cmp -s "$pristine" "$path"; then
    harness_error "$fname: bytes are IDENTICAL to pristine after a 'successful' write"
    return 1
  fi
  if ! bash -n "$path"; then
    harness_error "$fname: the mutant is not valid bash — it would fail every case for the wrong reason"
    return 1
  fi
  return 0
}

run_suite() {
  SUITE_OUT=$(bash "$WORK/agents/hooks/test/$SUITE" 2>&1)
}

# check <mutant-name> <newline-separated must-FAIL case substrings> [<newline-separated must-still-PASS case substrings>]
check() {
  local name=$1 want_fail=$2 want_pass=${3:-} got_block missing="" wrongly=""

  if [ "$MUTANT_OK" -ne 1 ]; then
    echo "NOT RUN    $name  (mutation did not apply — see HARNESS ERROR above)"
    return
  fi

  run_suite
  if printf '%s\n' "$SUITE_OUT" | grep -q '^PASS:'; then
    echo "SURVIVED   $name  (suite is still green)"
    FAILED=1
    return
  fi

  got_block=$(printf '%s\n' "$SUITE_OUT" | sed -n '/^  - /p')

  while IFS= read -r want; do
    [ -n "$want" ] || continue
    printf '%s\n' "$got_block" | grep -qF -- "$want" || missing="$missing|$want"
  done <<< "$want_fail"

  while IFS= read -r want; do
    [ -n "$want" ] || continue
    printf '%s\n' "$got_block" | grep -qF -- "$want" && wrongly="$wrongly|$want"
  done <<< "$want_pass"

  if [ -n "$missing" ]; then
    echo "MIS-KILLED $name"
    echo "           red, but NOT on the case(s) this mutant names: ${missing#|}"
    FAILED=1
  elif [ -n "$wrongly" ]; then
    echo "MIS-KILLED $name"
    echo "           case(s) that had to keep passing went red: ${wrongly#|}"
    FAILED=1
  else
    echo "killed     $name"
  fi
  [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$SUITE_OUT" | sed 's/^/           | /'
}

echo "== baseline (no mutation) — must be green =="
fresh_copy
run_suite
if printf '%s\n' "$SUITE_OUT" | grep -q '^PASS:'; then
  echo "baseline OK"
else
  echo "HARNESS ERROR: baseline suite is not green — fix the suite before trusting any mutant" >&2
  printf '%s\n' "$SUITE_OUT" >&2
  exit 2
fi

echo
echo "== mutants =="

# M1: stamp-write-removed — the turn-end stamp stops being written. Only
# the two dedicated stamp cases can observe this; everything else is
# indifferent to whether the file exists.
fresh_copy
mutate hook \
  'touch "$_CG_TURN_END_DIR/$SESSION_ID" 2>/dev/null' \
  ': # MUTANT: stamp write removed'
check "M1 stamp-write-removed" \
"the turn-end stamp is written even on a quiet below-threshold Stop
the turn-end stamp is written even under stop_hook_active" \
"below threshold is a no-op
stamp case: a quiet below-threshold Stop is still a no-op"

# M2: re-arm-removed — the hysteresis clear (path a) stops firing. The
# marker never auto-clears, so the dead-backstop case reproduces exactly.
fresh_copy
mutate hook \
  'rm -f "$MARKER" 2>/dev/null' \
  ': # MUTANT: re-arm removed'
check "M2 re-arm-removed" \
"re-arm: the marker clears WITHOUT a manual rm -f when pct drops below threshold-20
re-arm: the guard fires AGAIN after re-arm" \
"re-arm setup: fires at 80%
re-arm setup: marker is set after firing
a pct drop below threshold-20 is itself a no-op
a drop that stays above threshold-20 does NOT re-arm (no flap)"

# M3: nudge-always — the rate-limit comparison is neutralized, so NUDGE_DUE
# never resets to 0 and the nudge fires on every eligible call: a nag, not
# a nudge.
fresh_copy
mutate hook \
  '[ "$NUDGE_AGE" -lt "$NUDGE_RATE_SECS" ] && NUDGE_DUE=0' \
  ': # MUTANT: nudge rate limit ignored'
check "M3 nudge-always" \
"the nudge is suppressed on a second call inside the rate window" \
"below the 50% nudge floor is a no-op
the nudge fires at 55%
the nudge message is the self-service one
the nudge fires again once the rate window has elapsed
80% fires (the backstop
80% prints the BACKSTOP message, not the nudge
the nudge message must not appear alongside the backstop"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "ALL MUTANTS KILLED (on their named cases)"
  exit 0
fi
echo "MUTATION SWEEP FAILED — see SURVIVED / MIS-KILLED / HARNESS ERROR above"
exit 1
