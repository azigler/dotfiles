#!/bin/bash
# test-demesne-freeze.sh — regression suite for demesne-freeze.sh (dotfiles-ocm7).
#
# Hermetic: SYSTEMD_UNIT_DIR points at a per-case fixture directory (never the
# real ~/.config/systemd/user), HARNESS_STATE_DIR points at a per-case tmpdir
# (never ~/.local/state/harness), DEMESNE_LEDGER_ROOT points at a per-case
# fixture tree (never real ~/*/refs/*ledger*.jsonl), and a FAKE `systemctl` is
# prepended to PATH — same seam idiom as test-pulse-retry.sh /
# test-pulse-ledger-watch.sh. NO real systemd unit is ever touched.
#
# The four things this suite must never let regress:
#   - derivation is grep-DERIVED, never pulse-prefix-matched (Scrutiny-L E3):
#     a non-pulse unit that references the retargeted path is in-scope, and a
#     .service with no sibling .timer contributes nothing to freeze.
#   - derivation matches BOTH path forms — the pre-kvrl 'dotfiles/agents' and
#     the post-kvrl '.agents/agents' — with the dot ESCAPED (dotfiles-ypbc:
#     greping only the old form collapsed the live set from 31 files to 4).
#   - the snapshot is written to a FILE before anything is stopped, and
#     unfreeze restores from that FILE, never recomputed, never from memory.
#   - a ledger that looks mid-tick BLOCKS freeze unless --force.
#   - every terminal path prints exactly one DEMESNE_FREEZE_RESULT=<verdict>
#     as the last stdout line (daemon-skill verdict discipline).
#
# Usage: bash agents/scheduler/test-demesne-freeze.sh   (exit 0 = pass)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# Overridable so a mutant copy can be run through the same suite (this repo's
# CLAUDE.md rule 1: a green suite is not evidence a guard bites; only a
# mutant that dies is).
SCRIPT="${DFZ_SCRIPT:-$HERE/demesne-freeze.sh}"

ROOT_T=$(mktemp -d "${TMPDIR:-/tmp}/dfz-test.XXXXXX")
PASS=0; FAIL=0

cleanup() { rm -rf "$ROOT_T"; }
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

eq() { # eq <desc> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 -- got [$2], wanted [$3]"; fi
}
has() { # has <desc> <haystack> <needle>
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 -- expected to find: $3 in: $2" ;; esac
}
not_has() { # not_has <desc> <haystack> <needle>
  case "$2" in *"$3"*) bad "$1 -- did NOT want to find: $3 in: $2" ;; *) ok "$1" ;; esac
}

# last_line STR — the final line of a multi-line string.
last_line() { printf '%s\n' "$1" | tail -n1; }

# marker_count STR — how many DEMESNE_FREEZE_RESULT= lines appear at all.
# The verdict discipline requires exactly one, and it must be the last line.
marker_count() { printf '%s\n' "$1" | grep -c '^DEMESNE_FREEZE_RESULT=' || true; }

# assert_verdict <desc> <stdout> <expected-regex>
assert_verdict() {
  local desc="$1" out="$2" re="$3" last cnt
  last=$(last_line "$out")
  cnt=$(marker_count "$out")
  if [ "$cnt" -eq 1 ] && printf '%s' "$last" | grep -qE "$re"; then
    ok "$desc"
  else
    bad "$desc -- last='$last' marker_count=$cnt full_tail=$(printf '%s' "$out" | tail -n3)"
  fi
}

# --- Fake systemctl -----------------------------------------------------
# Reads $DFZ_FAKE (per-case control dir):
#   $DFZ_FAKE/calls                 — every invocation, one per line
#   $DFZ_FAKE/list-unit-files.txt   — scripted `list-unit-files --type=timer` body
#   $DFZ_FAKE/list-fail             — if present, list-unit-files fails (rc 1)
#   $DFZ_FAKE/state/<unit>          — current is-active state ("active"/"inactive")
#   $DFZ_FAKE/stuck/<unit>          — if present, `stop` does NOT flip state to inactive
#   $DFZ_FAKE/start-fail/<unit>     — if present, `start` fails (rc 1, state untouched)
#   $DFZ_FAKE/stopped, started      — units passed to stop/start, one per line
BIN="$ROOT_T/bin"
mkdir -p "$BIN"
cat > "$BIN/systemctl" <<'EOSC'
#!/bin/bash
FAKE="$DFZ_FAKE"
mkdir -p "$FAKE/state" "$FAKE/stuck" "$FAKE/start-fail"
printf '%s\n' "$*" >> "$FAKE/calls"
sub="${2:-}"
case "$sub" in
  list-unit-files)
    if [ -f "$FAKE/list-fail" ]; then
      echo "fake: simulated systemctl failure" >&2
      exit 1
    fi
    cat "$FAKE/list-unit-files.txt" 2>/dev/null
    exit 0
    ;;
  stop)
    unit="${3:-}"
    echo "$unit" >> "$FAKE/stopped"
    if [ ! -f "$FAKE/stuck/$unit" ]; then
      echo inactive > "$FAKE/state/$unit"
    fi
    exit 0
    ;;
  start)
    unit="${3:-}"
    echo "$unit" >> "$FAKE/started"
    if [ -f "$FAKE/start-fail/$unit" ]; then
      exit 1
    fi
    echo active > "$FAKE/state/$unit"
    exit 0
    ;;
  is-active)
    unit="${3:-}"
    st=$(cat "$FAKE/state/$unit" 2>/dev/null || echo inactive)
    echo "$st"
    [ "$st" = active ] && exit 0 || exit 3
    ;;
  *)
    exit 0
    ;;
esac
EOSC
chmod +x "$BIN/systemctl"
export PATH="$BIN:$PATH"

# --- Fixture builders -----------------------------------------------------

# write_unit_fixture DIR — the standard derivation fixture:
#   foo.service (matches OLD dotfiles/agents form, has sibling foo.timer)
#                                                          -> IN derived set
#   foo.timer
#   bar.service (matches, NO sibling bar.timer)            -> excluded (no timer)
#   baz.timer   (matches directly, no baz.service needed)  -> IN derived set
#   newpath.service (matches the POST-kvrl .agents/agents form, sibling timer)
#                                                          -> IN derived set
#   newpath.timer      (dotfiles-ypbc: the fleet's units were retargeted from
#                    %h/dotfiles/agents to %h/.agents/agents; a derivation that
#                    only greps the old form collapses the freeze set to a
#                    handful and leaves the rest running through a flip window)
#   notdot.service + notdot.timer (xagents/agents — the SAME bytes as
#                    .agents/agents with the dot standing in for 'x')
#                                                          -> excluded
#                    (proves the dot is escaped, not an any-char wildcard)
#   qux.service + qux.timer (does NOT reference the path)  -> excluded entirely
#   restart-loop-check.timer + .service (does NOT match)   -> IN derived set anyway
#     (the explicit floor — proves it survives even if the grep ever misses it)
write_unit_fixture() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/foo.service" <<'EOF'
[Service]
ExecStart=/home/ubuntu/dotfiles/agents/scheduler/foo.sh
EOF
  cat > "$dir/foo.timer" <<'EOF'
[Timer]
OnCalendar=hourly
EOF
  cat > "$dir/bar.service" <<'EOF'
[Service]
ExecStart=/home/ubuntu/dotfiles/agents/scheduler/bar.sh
EOF
  cat > "$dir/baz.timer" <<'EOF'
[Timer]
# references /home/ubuntu/dotfiles/agents/scheduler/baz.sh
OnCalendar=daily
EOF
  cat > "$dir/newpath.service" <<'EOF'
[Service]
ExecStart=%h/.agents/agents/scheduler/newpath.sh
EOF
  cat > "$dir/newpath.timer" <<'EOF'
[Timer]
OnCalendar=hourly
EOF
  cat > "$dir/notdot.service" <<'EOF'
[Service]
ExecStart=/home/ubuntu/xagents/agents/scheduler/notdot.sh
EOF
  cat > "$dir/notdot.timer" <<'EOF'
[Timer]
OnCalendar=daily
EOF
  cat > "$dir/qux.service" <<'EOF'
[Service]
ExecStart=/home/ubuntu/unrelated/tool.sh
EOF
  cat > "$dir/qux.timer" <<'EOF'
[Timer]
OnCalendar=daily
EOF
  cat > "$dir/restart-loop-check.service" <<'EOF'
[Service]
ExecStart=/usr/bin/true
EOF
  cat > "$dir/restart-loop-check.timer" <<'EOF'
[Timer]
OnCalendar=*:0/5
EOF
}

# case_env DIR — sets up a fresh {unit,state,ledger,fake} quad and prints
# nothing; caller reads the exported vars.
setup_case() {
  CASE=$(mktemp -d "$ROOT_T/case.XXXXXX")
  UNITS="$CASE/units"
  STATE="$CASE/state"
  LEDGERS="$CASE/ledgers"
  FAKE="$CASE/fake"
  mkdir -p "$UNITS" "$STATE" "$LEDGERS" "$FAKE/state" "$FAKE/stuck" "$FAKE/start-fail"
  write_unit_fixture "$UNITS"
  # Standard snapshot table: foo.timer + newpath.timer + restart-loop-check.timer
  # enabled, baz.timer disabled, qux.timer/notdot.timer enabled (untouched —
  # neither is in the derived set).
  cat > "$FAKE/list-unit-files.txt" <<'EOF'
foo.timer                    enabled  enabled
baz.timer                    disabled enabled
newpath.timer                enabled  enabled
restart-loop-check.timer     enabled  enabled
qux.timer                    enabled  enabled
notdot.timer                 enabled  enabled
EOF
  export SYSTEMD_UNIT_DIR="$UNITS"
  export HARNESS_STATE_DIR="$STATE"
  export DEMESNE_LEDGER_ROOT="$LEDGERS"
  export DEMESNE_QUIESCENT_SECONDS=300
  export DFZ_FAKE="$FAKE"
}

run() { # run <verb...> -> sets OUT, RC
  OUT=$("$SCRIPT" "$@" 2>/dev/null)
  RC=$?
}

calls_of() { [ -f "$FAKE/$1" ] && sort "$FAKE/$1" | tr '\n' ',' || echo ""; }

# =========================================================================
# 1  Derivation correctness
# =========================================================================
setup_case
run status
eq   "1a status exits 0" "$RC" 0
has  "1b derived set includes foo.timer (matched service + sibling timer)" "$OUT" "foo.timer"
has  "1c derived set includes baz.timer (matched directly)" "$OUT" "baz.timer"
has  "1d derived set includes restart-loop-check.timer (explicit floor)" "$OUT" "restart-loop-check.timer"
has  "1d2 derived set includes newpath.timer (post-kvrl .agents/agents form)" "$OUT" "newpath.timer"
not_has "1e derived set excludes bar (service matched, no sibling timer)" "$OUT" "bar.timer"
not_has "1f derived set excludes qux (no path reference at all)" "$OUT" "qux.timer"
not_has "1f2 derived set excludes notdot (xagents/agents — the dot is escaped, not a wildcard)" "$OUT" "notdot.timer"
has  "1g raw grep match count reported" "$OUT" "raw grep matches:   4 file(s)"
has  "1h derived count reported" "$OUT" "derived timer set:  4 unit(s)"
assert_verdict "1i status verdict is status-unfrozen (nothing frozen yet)" "$OUT" '^DEMESNE_FREEZE_RESULT=status-unfrozen$'

# =========================================================================
# 2  Derivation against a unit dir with NO matches at all -> empty-derivation
# =========================================================================
setup_case
EMPTY_UNITS="$CASE/empty-units"
mkdir -p "$EMPTY_UNITS"
export SYSTEMD_UNIT_DIR="$EMPTY_UNITS"
run freeze
eq   "2a freeze on an empty unit dir refuses" "$RC" 1
assert_verdict "2b verdict is failed-empty-derivation" "$OUT" '^DEMESNE_FREEZE_RESULT=failed-empty-derivation$'
eq   "2c no stop calls were made" "$(calls_of stopped)" ""

# =========================================================================
# 3  Snapshot round-trip: freeze snapshots BEFORE stopping, stops exactly
#    the derived set, and nothing outside it.
# =========================================================================
setup_case
run freeze
eq   "3a freeze succeeds" "$RC" 0
assert_verdict "3b verdict is frozen" "$OUT" '^DEMESNE_FREEZE_RESULT=frozen$'
eq   "3c stopped exactly {baz,foo,newpath,restart-loop-check}.timer" \
  "$(calls_of stopped)" "baz.timer,foo.timer,newpath.timer,restart-loop-check.timer,"
not_has "3d qux.timer was never stopped" "$(calls_of stopped)" "qux.timer"
not_has "3d2 notdot.timer was never stopped" "$(calls_of stopped)" "notdot.timer"
eq   "3e snapshot file was written before any stop (content preserved verbatim)" \
  "$(cat "$STATE/demesne-freeze-snapshot.txt")" "$(cat "$FAKE/list-unit-files.txt")"
eq   "3f derived-set file records exactly the frozen set" \
  "$(sort "$STATE/demesne-freeze-derived.txt" | tr '\n' ',')" "baz.timer,foo.timer,newpath.timer,restart-loop-check.timer,"
eq   "3g marker file exists after a successful freeze" "$([ -f "$STATE/demesne-freeze-active" ] && echo yes)" "yes"

# status while frozen
run status
assert_verdict "3h status reports status-frozen" "$OUT" '^DEMESNE_FREEZE_RESULT=status-frozen$'
has  "3i status says frozen: yes" "$OUT" "frozen: yes"
has  "3j status says the derived set matches the snapshot (unit dir unchanged)" "$OUT" "matches the last recorded snapshot exactly"

# =========================================================================
# 4  Unfreeze restores EXACTLY the recorded enabled-set (18/6-style assert:
#    enabled units get restarted, the disabled one does NOT).
# =========================================================================
run unfreeze
eq   "4a unfreeze succeeds" "$RC" 0
assert_verdict "4b verdict is unfrozen" "$OUT" '^DEMESNE_FREEZE_RESULT=unfrozen$'
eq   "4c started exactly {foo,newpath,restart-loop-check}.timer (the enabled ones)" \
  "$(calls_of started)" "foo.timer,newpath.timer,restart-loop-check.timer,"
not_has "4d baz.timer (disabled at snapshot time) was never restarted" "$(calls_of started)" "baz.timer"
eq   "4e marker file removed after a successful unfreeze" "$([ -f "$STATE/demesne-freeze-active" ] && echo yes || echo no)" "no"

run status
assert_verdict "4f status reports status-unfrozen after unfreeze" "$OUT" '^DEMESNE_FREEZE_RESULT=status-unfrozen$'
has  "4g status says frozen: no" "$OUT" "frozen: no"

# =========================================================================
# 5  Blocked-inflight: a ledger that looks mid-tick blocks freeze; --force
#    overrides it.
# =========================================================================
setup_case
mkdir -p "$LEDGERS/someproj/refs"
: > "$LEDGERS/someproj/refs/pulse-ledger.jsonl"   # mtime = now = well within the window
run freeze
eq   "5a freeze without --force is blocked" "$RC" 1
assert_verdict "5b verdict is blocked-inflight" "$OUT" '^DEMESNE_FREEZE_RESULT=blocked-inflight$'
eq   "5c blocked freeze made NO stop calls" "$(calls_of stopped)" ""
eq   "5d blocked freeze wrote no marker" "$([ -f "$STATE/demesne-freeze-active" ] && echo yes || echo no)" "no"

run freeze --force
eq   "5e freeze --force proceeds despite the fresh ledger" "$RC" 0
assert_verdict "5f verdict is frozen with --force" "$OUT" '^DEMESNE_FREEZE_RESULT=frozen$'

# an old (quiescent) ledger must NOT block
setup_case
mkdir -p "$LEDGERS/someproj/refs"
touch -d '@1' "$LEDGERS/someproj/refs/pulse-ledger.jsonl" 2>/dev/null \
  || touch -t 197001010000 "$LEDGERS/someproj/refs/pulse-ledger.jsonl"
run freeze
eq   "5g an old/quiescent ledger does not block freeze" "$RC" 0
assert_verdict "5h verdict is frozen (quiescent)" "$OUT" '^DEMESNE_FREEZE_RESULT=frozen$'

# =========================================================================
# 6  failed-snapshot: systemctl list-unit-files fails -> refuse to freeze,
#    no stop calls, no marker.
# =========================================================================
setup_case
touch "$FAKE/list-fail"
run freeze
eq   "6a freeze refuses when the snapshot read fails" "$RC" 1
assert_verdict "6b verdict is failed-snapshot" "$OUT" '^DEMESNE_FREEZE_RESULT=failed-snapshot$'
eq   "6c no stop calls were made" "$(calls_of stopped)" ""
eq   "6d no marker was written" "$([ -f "$STATE/demesne-freeze-active" ] && echo yes || echo no)" "no"

# =========================================================================
# 7  failed-stop: a unit that refuses to go inactive fails the freeze and
#    the verdict names it; the marker is NOT written.
# =========================================================================
setup_case
touch "$FAKE/stuck/foo.timer"
echo active > "$FAKE/state/foo.timer"
run freeze
eq   "7a freeze fails when a unit will not stop" "$RC" 1
assert_verdict "7b verdict is failed-stop naming foo.timer" "$OUT" '^DEMESNE_FREEZE_RESULT=failed-stop:.*foo\.timer.*$'
eq   "7c no marker was written on a failed stop" "$([ -f "$STATE/demesne-freeze-active" ] && echo yes || echo no)" "no"

# =========================================================================
# 8  Unfreeze failure paths
# =========================================================================
# 8a: no snapshot on record at all
setup_case
run unfreeze
eq   "8a-rc unfreeze with no snapshot refuses" "$RC" 1
assert_verdict "8a-verdict is failed-no-snapshot" "$OUT" '^DEMESNE_FREEZE_RESULT=failed-no-snapshot$'

# 8b: derived-set file names a unit the snapshot never recorded — must
#     refuse rather than guess (the exactness requirement, not "assert from
#     memory").
setup_case
run freeze
eq   "8b-setup freeze for missing-entry case succeeds" "$RC" 0
echo "phantom.timer" >> "$STATE/demesne-freeze-derived.txt"
run unfreeze
eq   "8b-rc unfreeze refuses on an unrecorded derived unit" "$RC" 1
assert_verdict "8b-verdict is failed-missing-snapshot-entry naming phantom.timer" \
  "$OUT" '^DEMESNE_FREEZE_RESULT=failed-missing-snapshot-entry:.*phantom\.timer.*$'

# 8c: start genuinely fails for a unit that was enabled at snapshot time
setup_case
run freeze
eq   "8c-setup freeze for failed-restore case succeeds" "$RC" 0
touch "$FAKE/start-fail/foo.timer"
run unfreeze
eq   "8c-rc unfreeze fails when start fails" "$RC" 1
assert_verdict "8c-verdict is failed-restore naming foo.timer" \
  "$OUT" '^DEMESNE_FREEZE_RESULT=failed-restore:.*foo\.timer.*$'

# =========================================================================
# 9  Bad arguments / usage
# =========================================================================
setup_case
run freeze --nonsense
eq   "9a unknown freeze flag refuses" "$RC" 1
assert_verdict "9b verdict is failed-badarg" "$OUT" '^DEMESNE_FREEZE_RESULT=failed-badarg$'

OUT=$("$SCRIPT" 2>&1); RC=$?
eq   "9c no verb prints usage and exits non-zero" "$RC" 1
has  "9d usage mentions all three verbs" "$OUT" "freeze|unfreeze|status"

OUT=$("$SCRIPT" bogus-verb 2>&1); RC=$?
eq   "9e unknown verb exits non-zero" "$RC" 1

# =========================================================================
# 10  Marker-on-every-terminal-path — the daemon-skill verdict discipline.
#     Every branch exercised above already asserted this individually via
#     assert_verdict; this final sweep re-confirms the property holds even
#     for the SUCCESS paths (freeze/unfreeze/status), not just the failure
#     ones, and that PASS is 0 marker lines is never expected.
# =========================================================================
setup_case
run status
assert_verdict "10a status (unfrozen, fresh state) carries exactly one terminal marker" "$OUT" '^DEMESNE_FREEZE_RESULT='
run freeze
assert_verdict "10b freeze (success) carries exactly one terminal marker" "$OUT" '^DEMESNE_FREEZE_RESULT='
run status
assert_verdict "10c status (frozen) carries exactly one terminal marker" "$OUT" '^DEMESNE_FREEZE_RESULT='
run unfreeze
assert_verdict "10d unfreeze (success) carries exactly one terminal marker" "$OUT" '^DEMESNE_FREEZE_RESULT='

echo
printf 'demesne-freeze: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
