#!/bin/bash
# Mutation harness for post-tool-model-guard.sh — the silent model-degradation
# guard (dotfiles-p89v).
#
#   bash agents/hooks/test/mutate-model-guard.sh [-v]
#
# WHY THIS EXISTS. Every failure mode of this guard is SILENT, which is the same
# property that made the bug it guards worth guarding: a session knocked from
# Fable 5 to Opus 4.8 keeps answering, keeps committing, and turns no timer red.
# A guard that stops biting fails the identical way — nothing errors, the suite
# stays green, and fable-level scenarios go on being served by the fallback model
# with nobody knowing. This repo's rule 1: a green suite is not evidence that a
# guard bites; only a mutant that dies is. tools/githooks/pre-commit is the caller.
#
# THE PROPERTY THAT MAKES THIS HARNESS HONEST: assert the mutation APPLIED.
# Modelled on agents/scheduler/mutate-tunnel-ownership.sh, whose five checks are
# reproduced here rather than re-derived (dotfiles-47nf: an over-escaped pattern
# matched nothing, the suite went red anyway, and by exit code alone that is
# indistinguishable from a proper kill):
#   1. the target text occurs EXACTLY ONCE in the pristine file
#   2. the replacement text occurs ZERO times in the pristine file (not a no-op)
#   3. the file's bytes actually changed
#   4. the replacement occurs exactly once afterwards
#   5. `bash -n` is still clean — it died of the bug it NAMES, not of a syntax
#      error that fails every case
# Any of those failing is a HARNESS ERROR, reported as such, never as a kill.
#
# And a killed mutant must die on the cases it NAMES. Every check() below carries
# both a must-FAIL and a must-PASS list; the must-PASS list is what stops a mutant
# that merely broke the hook globally from reading as a clean kill (dotfiles-77s4).
#
# HERMETIC. The hook, the suite and the real-bytes fixture are copied into a
# throwaway tree; the suite resolves the hook by `dirname $0/..`, so the copy is
# self-contained and agents/hooks/ is never edited. Safe to run concurrently with
# the suite itself (all state lives under the suite's own mktemp -d).
#
# agents/lib/model-canon.sh is copied in TOO (dotfiles-lstn). The hook resolves
# it relative to its own location, so without the copy the scratch hook would
# silently fall back to naming EXPECTED verbatim — i.e. every canonicalisation
# case would go red on the BASELINE, which reads as "the suite is broken" rather
# than as the missing dependency it is. The copy is asserted, not assumed.

# shellcheck disable=SC2016
# ^ file-wide and deliberate: every mutation argument below is LITERAL SOURCE
# TEXT copied out of post-tool-model-guard.sh. `$1`, `$COOLDOWN`, `$(norm …)`
# and friends inside them must NOT expand — they are matched byte-for-byte
# against the file on disk, and an expanded one would match nothing.

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")" && pwd)"          # agents/hooks/test
HOOKS="$(cd "$SRC/.." && pwd)"                # agents/hooks
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-model-guard.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

HOOK="post-tool-model-guard.sh"
SUITE="test-post-tool-model-guard.sh"
FIXTURE="model-guard-transcript.fixture.jsonl"
FIXTURE2="model-guard-subagent.fixture.jsonl"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$WORK/hooks/test" "$WORK/lib" "$WORK/pristine"
[ -f "$HOOKS/$HOOK" ] || { echo "HARNESS ERROR: $HOOKS/$HOOK does not exist" >&2; exit 2; }
cp -a "$HOOKS/$HOOK" "$WORK/pristine/$HOOK"
CANONLIB="$(cd "$HOOKS/../lib" 2>/dev/null && pwd)/model-canon.sh"
[ -f "$CANONLIB" ] || { echo "HARNESS ERROR: $CANONLIB does not exist — the hook's canonicalisation dependency" >&2; exit 2; }
cp -a "$CANONLIB" "$WORK/lib/model-canon.sh"
for f in "$SUITE" "$FIXTURE" "$FIXTURE2"; do
  [ -f "$SRC/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
  cp -a "$SRC/$f" "$WORK/hooks/test/$f"
done

fresh_copy() {
  MUTANT_OK=1
  cp -a "$WORK/pristine/$HOOK" "$WORK/hooks/$HOOK"
  chmod +x "$WORK/hooks/$HOOK"
}

run_suite() {
  SUITE_OUT=$(bash "$WORK/hooks/test/$SUITE" 2>&1)
  return $?
}

harness_error() {
  echo "HARNESS ERROR  $*" >&2
  HARNESS_ERR=1
  MUTANT_OK=0
}

# mutate <literal-from> <literal-to> — literal substring swap on the hook, with
# all five applied-ness assertions. Fixed strings, never regexes: over-escaping a
# pattern is the exact failure this harness exists to make impossible.
mutate() {
  local from=$1 to=$2
  local path="$WORK/hooks/$HOOK" pristine="$WORK/pristine/$HOOK"

  python3 - "$pristine" "$path" "$from" "$to" <<'PY'
import sys
pristine, path, frm, to = sys.argv[1:5]
before = open(pristine).read()
n = before.count(frm)
if n != 1:
    sys.stderr.write(f"  target text occurs {n}x (want exactly 1) in {path}\n")
    sys.stderr.write("  the line this mutant aims at has MOVED or CHANGED; "
                     "re-derive the mutant from the current source.\n")
    sys.exit(1)
if to in before:
    sys.stderr.write("  replacement text is ALREADY present in the pristine "
                     "file — this mutation would be a no-op.\n")
    sys.exit(1)
after = before.replace(frm, to)
open(path, "w").write(after)
if after.count(to) != 1:
    sys.stderr.write("  replacement is not present exactly once after the write\n")
    sys.exit(1)
PY
  # shellcheck disable=SC2181  # the heredoc'd python is the command; $? is it
  [ $? -eq 0 ] || { harness_error "$HOOK: mutation did not apply"; return 1; }

  if cmp -s "$pristine" "$path"; then
    harness_error "$HOOK: bytes are IDENTICAL to pristine after a 'successful' write"
    return 1
  fi
  if ! bash -n "$path"; then
    harness_error "$HOOK: the mutant is not valid bash — it would fail every case for the wrong reason"
    return 1
  fi
  return 0
}

# check <mutant-name> <must-FAIL cases> [<must-PASS cases>]
check() {
  local name=$1 want_fail=$2 want_pass=${3:-} got c missing="" wrongly=""

  if [ "$MUTANT_OK" -ne 1 ]; then
    echo "NOT RUN   $name  (its mutation did not apply — see HARNESS ERROR above)"
    return
  fi

  if run_suite; then
    echo "SURVIVED  $name  ($SUITE is still green)"
    printf '%s\n' "$SUITE_OUT" | tail -1 | sed 's/^/          /'
    FAILED=1
    return
  fi

  got=$(printf '%s\n' "$SUITE_OUT" | grep -E '^  - ' | awk '{ print $2 }' | tr '\n' ' ')
  for c in $want_fail; do
    case " $got " in *" $c "*) ;; *) missing="$missing $c" ;; esac
  done
  for c in $want_pass; do
    case " $got " in *" $c "*) wrongly="$wrongly $c" ;; esac
  done

  if [ -n "$missing" ]; then
    echo "MIS-KILLED $name"
    echo "           the suite went red but NOT on the case(s) this mutant names:$missing"
    echo "           actually failing: ${got:-<none>}"
    FAILED=1
  elif [ -n "$wrongly" ]; then
    echo "MIS-KILLED $name"
    echo "           case(s) that had to keep PASSING went red:$wrongly"
    echo "           actually failing: ${got:-<none>}"
    FAILED=1
  else
    echo "killed    $name"
    echo "          failing cases: $got"
  fi
  [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$SUITE_OUT" | sed 's/^/          | /'
  return 0
}

echo "=== baseline: the unmutated copy must be GREEN ============================"
fresh_copy
if run_suite; then
  echo "  ok      $SUITE: $(printf '%s\n' "$SUITE_OUT" | tail -1)"
else
  echo "  BROKEN  $SUITE is RED before any mutation — nothing below means anything"
  printf '%s\n' "$SUITE_OUT" | tail -12 | sed 's/^/          /'
  exit 1
fi

echo
echo "=== mutants ==============================================================="

# M1 — the <synthetic> skip removed. Those rows are interrupt/error placeholders
# (3 of them in the 2cc9586e transcript); read as a serving model they make the
# guard fire on a perfectly healthy session, which is how a real guard gets
# turned off by the person it keeps interrupting. C13 is its sole detector.
fresh_copy
mutate 'select(. != "<synthetic>")' 'select(. != "NEVER-MATCHES-ANY-MODEL-ID")'
check "M1 synthetic-rows-read-as-a-serving-model" "C13" "C1 C2"

# M2 — the [1m] context-tag strip neutered. settings.json says
# `claude-fable-5[1m]` and the wire says `claude-fable-5`; without the strip the
# guard declares a healthy fable session degraded, permanently, on every seat
# whose expectation comes from settings. C15 is its sole detector.
fresh_copy
mutate "norm() { printf '%s' \"\$1\" | sed -e 's/\\[[^][]*\\]\$//' | tr '[:upper:]' '[:lower:]'; }" \
       "norm() { printf '%s' \"\$1\" | sed -e 's/ZZ-NO-SUCH-SUFFIX-ZZ\$//' | tr '[:upper:]' '[:lower:]'; }"
check "M2 context-tag-[1m]-not-normalised" "C15" "C1 C2"

# M3 — the MOLT rung deleted from the ladder: the second knock skips straight to
# "stop and ask Zig". Zig's playbook is restore -> molt -> ask, and a ladder that
# escalates to a human on knock two burns the one automated recovery step.
fresh_copy
mutate 'elif [ "$TRIES" -eq 2 ]; then ACTION=molt' \
       'elif [ "$TRIES" -eq 99 ]; then ACTION=molt'
check "M3 molt-rung-missing-from-the-ladder" "C7 C10" "C1 C8"

# M4 — the cooldown gate disarmed, so a persisting mismatch re-instructs on EVERY
# tool round. That is the nag loop the episode counter exists to prevent, and it
# also inflates `tries` to the "stop and ask Zig" rung within seconds — the guard
# then summons Zig for a single downgrade it never gave the session a chance to
# fix. C9 is its sole detector.
fresh_copy
mutate 'if [ "$PENDING" -eq 1 ] && [ $(( NOW - LAST_EMIT )) -lt "$COOLDOWN" ]; then' \
       'if [ "$PENDING" -eq 1 ] && [ $(( NOW - LAST_EMIT )) -lt 0 ]; then'
check "M4 cooldown-disarmed-instructs-every-tool-round" "C9" "C1 C2"

# M5 — the `off` escape hatch neutered. An intentionally-Opus seat then cannot
# silence the guard at all, and the only remaining remedy is deleting the hook —
# which removes it for every seat on the machine. C4 is its sole detector.
fresh_copy
mutate 'case "$(norm "${EXPECTED:-}")" in off|none|any|disabled) exit 0 ;; esac' \
       'case "$(norm "${EXPECTED:-}")" in zz-no-such-value) exit 0 ;; esac'
check "M5 off-switch-neutered" "C4" "C1 C5"

# M6 — FAIL-OPEN violated: an unreadable transcript now emits the blocking exit
# code. A hook that shouts on its own read errors is a hook that breaks every
# session on the machine the first time a path moves (this repo's rule 1).
fresh_copy
mutate '    ledger_row "check-failed" "$1" "" ""
  fi
  exit 0
}' '    ledger_row "check-failed" "$1" "" ""
  fi
  exit 2
}'
check "M6 detection-error-no-longer-fails-open" "C11 C12" "C1"

# M7 — the sidechain filter removed, so a dispatched subagent's model is read as
# this session's. Opus/Sonnet subagents are the DEFAULT allocation (AGENTS.md:
# "Fable plans and reviews, Opus/Sonnet implement"), so this fires on every
# healthy orchestrator that delegates. C14 is its sole detector.
fresh_copy
mutate 'if .type == "assistant" and (.isSidechain // false | not) then' \
       'if .type == "assistant" then'
check "M7 sidechain-subagent-model-read-as-the-session-model" "C14" "C1 C2"

# M8 — THE SUBAGENT BAIL removed. This is the one that was live: a subagent's
# invocation carries the PARENT's session_id and the SUBAGENT's transcript_path,
# whose rows are 100% isSidechain — so SERVED empties, every delegating session
# drips `check-failed` rows into the ledger that dotfiles-7pbn is meant to count,
# and the subagent writes the PARENT's state file behind its back. Measured on
# this bead's own agent (117 rows, all sidechain, claude-opus-5, parent
# session_id 538b7ef4). C22 is its sole detector.
fresh_copy
mutate '  [ "$_TB" = "$SESSION_ID" ] || exit 0' \
       '  [ "$_TB" = "$SESSION_ID" ] || true'
check "M8 guard-runs-in-subagent-context" "C22" "C1 C2"

# M9 — the isSidechain filter dropped from the REFUSAL-ROW extraction. A refusal
# inside an opus-dispatched subagent then caches originalModel into the parent's
# expectation, and a perfectly healthy fable session is instructed to /model
# itself onto the subagent's model and walked up the ladder. C23 is its sole
# detector, and it is a different filter from M7's — that one guards SERVED,
# this one guards EXPECTED.
fresh_copy
mutate '  elif .type == "system" and .subtype == "model_refusal_fallback"
       and (.isSidechain // false | not) then' \
       '  elif .type == "system" and .subtype == "model_refusal_fallback" then'
check "M9 sidechain-refusal-row-poisons-the-expected-model" "C23" "C1 C2 C3"

# M10 — [restore-instructs-alias]. THE ONE THAT WAS LIVE (dotfiles-lstn). The
# restore rung goes back to naming EXPECTED verbatim, which in production is a
# roster ALIAS. `/model` PERSISTS its argument into settings.json, so obeying
# that instruction rewrites the machine default to the 200k form for every
# session launched afterwards — the guard becomes the WRITER of the drift it
# exists to catch, and every mechanical signal stays green (same model name,
# same statusline, only the context window differs). C24 is its sole detector.
# C25 must keep passing: an un-tabled model is instructed verbatim either way,
# so a mutant that reddens it broke the passthrough rather than the canon.
fresh_copy
mutate "argument '\$CANON'" "argument '\$EXPECTED'"
check "M10 restore-instructs-alias" "C24" "C1 C2 C21 C25"

# M11 — the same write, one rung up. The molt rung types `/model` too, so a fix
# applied only to the restore rung leaves the alias-write reachable on the
# second knock — and the second knock is the one that ends in a fresh context,
# i.e. the one whose model choice sticks. C26 is its sole detector; C7 (the molt
# rung itself) must keep passing, or the mutant broke the ladder, not the id.
fresh_copy
mutate "/model '\$CANON' — that exact id" "/model '\$EXPECTED' — that exact id"
check "M11 molt-rung-instructs-alias" "C26" "C1 C7 C10 C24"

# M12 — THE SETTINGS-DRIFT ALARM REMOVED. Nothing else on this box watches the
# key `/model` persists into: on 2026-08-09 live settings sat at "fable" for
# hours while the statusline, the transcript and every timer stayed green. With
# the alarm gone the guard still catches a session being knocked off its model
# and still misses the machine defaulting the whole fleet to 200k. C27/C29 are
# its detectors; C28 must keep passing (a removed alarm cannot cry wolf).
fresh_copy
mutate 'if [ "$SDRIFT" -eq 0 ] && [ "${MODEL_GUARD_USE_SETTINGS:-1}" != "0" ] \' \
       'if [ "$SDRIFT" -eq 99 ] && [ "${MODEL_GUARD_USE_SETTINGS:-1}" != "0" ] \'
check "M12 settings-drift-alarm-removed" "C27 C29" "C1 C2 C28"

# M13 — the alarm's once-per-session memory dropped, so a standing drift
# re-emits on EVERY tool round. This is the failure direction that gets a guard
# switched off by the person it interrupts, and it is why the emission is keyed
# on a state flag rather than the cooldown the ladder uses. C29 is its sole
# detector — C27 (the first emission) is identical under this mutant, which is
# what makes C29 non-redundant.
fresh_copy
mutate '    SDRIFT=2
    write_state' \
       '    SDRIFT=0
    write_state'
check "M13 settings-drift-alarm-nags-every-round" "C29" "C1 C27 C28"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "RESULT: HARNESS ERROR — at least one mutation did not apply. That is not a"
  echo "        kill and must not be read as one; re-derive the mutant from source."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "RESULT: FAIL — a mutant survived or died on the wrong cases."
  exit 1
fi
echo "RESULT: all mutants killed, each on the case(s) it names."
exit 0
