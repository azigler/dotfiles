#!/usr/bin/env bats
#
# test_pico_lock.bats — bats suite for local-models/lib/pico_lock.sh.
#
# Why: matrix postmortem 2026-06 failure mode #12 — the harness's own guard
# scripts shipped with silent bugs (the same-owner-different-PID acquire bug
# was found only during a by-eye smoke test). This suite makes the lock
# contract executable:
#
#   - acquire / release / check happy paths
#   - stale-lock steal (holder PID dead OR lock expired)
#   - refuse non-owner release
#   - REFUSE same-owner-different-PID acquire (the documented edge: two
#     bench-matrix instances must never silently overlap)
#   - allow same-owner-SAME-PID refresh
#
# Tests marked "KNOWN GAP" pin current behavior; see tests/KNOWN-GAPS.md.
#
# Everything runs offline against a lock file in $BATS_TEST_TMPDIR via the
# PICO_LOCK_FILE override. Run: bats local-models/tests/test_pico_lock.bats
#
# Bead: dotfiles-t4k (implements local-coding-models-wkw).

setup() {
  DOTFILES_ROOT="${DOTFILES_ROOT:-$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)}"
  PICO_LOCK="$DOTFILES_ROOT/local-models/lib/pico_lock.sh"
  export PICO_LOCK_FILE="$BATS_TEST_TMPDIR/pico-busy.lock"
  HELPER_PID=""
}

teardown() {
  if [[ -n "$HELPER_PID" ]]; then
    kill "$HELPER_PID" 2>/dev/null || true
  fi
}

# Run a snippet in a fresh bash with the lib sourced (its own $$).
plock() {
  bash -c "source '$PICO_LOCK'; $1"
}

# Spawn a long-lived process so a crafted lock has a LIVE holder PID.
spawn_live_holder() {
  sleep 300 &
  HELPER_PID=$!
}

# Produce a PID guaranteed to be dead (our own reaped child).
dead_pid() {
  bash -c 'exit 0' &
  local pid=$!
  wait "$pid" 2>/dev/null || true
  echo "$pid"
}

# Craft a lock file directly: write_lock OWNER PID EXPIRES_OFFSET_SECONDS
write_lock() {
  local owner="$1" pid="$2" offset="${3:-600}"
  local now exp
  now=$(date -u +%s)
  exp=$((now + offset))
  cat > "$PICO_LOCK_FILE" <<EOF
{
  "owner": "$owner",
  "pid": $pid,
  "acquired_at": "2026-06-10T00:00:00Z",
  "acquired_at_epoch": $now,
  "expires_at": "2026-06-10T23:59:59Z",
  "expires_at_epoch": $exp,
  "reason": "crafted by test"
}
EOF
}

lock_field() {
  python3 -c "import json; print(json.load(open('$PICO_LOCK_FILE'))['$1'])"
}

# ---- acquire happy path ----

@test "acquire: succeeds on free lock and records owner + reason" {
  run plock "pico_acquire bench-test 60 smoke run"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pico_acquire: OK"* ]]
  [ -f "$PICO_LOCK_FILE" ]
  [ "$(lock_field owner)" = "bench-test" ]
  [ "$(lock_field reason)" = "smoke run" ]
}

@test "acquire: usage error (exit 2) when owner/duration missing" {
  run plock "pico_acquire only-owner"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}

# ---- check ----

@test "check: FREE (exit 0) when no lock file exists" {
  run plock "pico_check"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FREE"* ]]
}

@test "check: BUSY (exit 1) when a live fresh holder exists" {
  spawn_live_holder
  write_lock other-consumer "$HELPER_PID" 600
  run plock "pico_check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BUSY"* ]]
  [[ "$output" == *"other-consumer"* ]]
}

@test "check: STALE (exit 0) when the holder PID is dead" {
  write_lock crashed-matrix "$(dead_pid)" 600
  run plock "pico_check"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STALE"* ]]
}

@test "check: STALE (exit 0) when the lock has expired (holder still alive)" {
  spawn_live_holder
  write_lock overdue-matrix "$HELPER_PID" -10
  run plock "pico_check"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STALE"* ]]
}

# ---- acquire contention ----

@test "acquire: REFUSED when a different owner holds a fresh lock" {
  spawn_live_holder
  write_lock other-consumer "$HELPER_PID" 600
  run plock "pico_acquire bench-test 60 want it"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
  # Lock must be untouched.
  [ "$(lock_field owner)" = "other-consumer" ]
}

@test "acquire: REFUSED for same-owner-DIFFERENT-PID (the documented edge)" {
  # Two bench-matrix instances must NOT silently overlap: same owner name
  # from a different PID is refused, not treated as a refresh. This was a
  # real bug found during pico_lock.sh's own smoke test (postmortem #12).
  spawn_live_holder
  write_lock bench-matrix "$HELPER_PID" 600
  run plock "pico_acquire bench-matrix 60 second instance"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
  [ "$(lock_field pid)" = "$HELPER_PID" ]
}

@test "acquire: same-owner-SAME-PID refresh is allowed and updates the lock" {
  run plock "pico_acquire bench-matrix 60 first && pico_acquire bench-matrix 7200 refreshed"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refresh by current holder"* ]]
  [ "$(lock_field reason)" = "refreshed" ]
}

# ---- stale steal ----

@test "acquire: steals a stale lock whose holder PID is dead" {
  write_lock crashed-matrix "$(dead_pid)" 600
  run plock "pico_acquire bench-test 60 takeover"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stealing STALE lock"* ]]
  [[ "$output" == *"pico_acquire: OK"* ]]
  [ "$(lock_field owner)" = "bench-test" ]
}

@test "acquire: steals an expired lock even if the holder is still alive" {
  spawn_live_holder
  write_lock overdue-matrix "$HELPER_PID" -10
  run plock "pico_acquire bench-test 60 takeover"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stealing STALE lock"* ]]
  [ "$(lock_field owner)" = "bench-test" ]
}

# ---- release ----

@test "release: owner releases its own lock (file removed)" {
  run plock "pico_acquire bench-test 60 work && pico_release bench-test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pico_release: OK"* ]]
  [ ! -f "$PICO_LOCK_FILE" ]
}

@test "release: REFUSED for non-owner (lock survives)" {
  spawn_live_holder
  write_lock alice "$HELPER_PID" 600
  run plock "pico_release mallory"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
  [ -f "$PICO_LOCK_FILE" ]
  [ "$(lock_field owner)" = "alice" ]
}

@test "release: no lock present is a no-op success" {
  run plock "pico_release bench-test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no lock to release"* ]]
}

@test "release: same-owner-DIFFERENT-PID succeeds (KNOWN GAP — asymmetric)" {
  # Acquire refuses same-owner-different-PID, but release does NOT check
  # the PID: a refused second instance's cleanup trap can still release
  # the RUNNING holder's lock. Pins current behavior — see KNOWN-GAPS.md.
  spawn_live_holder
  write_lock bench-matrix "$HELPER_PID" 600
  run plock "pico_release bench-matrix"
  [ "$status" -eq 0 ]
  [ ! -f "$PICO_LOCK_FILE" ]
}

# ---- CLI mode ----

@test "CLI: no subcommand prints usage and exits 2" {
  run bash "$PICO_LOCK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "CLI: check subcommand works standalone" {
  run bash "$PICO_LOCK" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"FREE"* ]]
}

@test "CLI: acquire records a transient PID — instantly STALE (KNOWN GAP)" {
  # CLI-mode acquire records $$ of the short-lived wrapper process. By the
  # next command that PID is dead, so the lock is immediately stealable —
  # the script's own usage example (`acquire bench-matrix-phase3 108000 ...`)
  # produces a lock that protects nothing. Sourced usage (bench-matrix.sh)
  # is unaffected. Pins current behavior — see KNOWN-GAPS.md.
  run bash "$PICO_LOCK" acquire bench-cli 60 cli smoke
  [ "$status" -eq 0 ]
  run bash "$PICO_LOCK" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"STALE"* ]]
  run bash "$PICO_LOCK" release bench-cli
  [ "$status" -eq 0 ]
  [ ! -f "$PICO_LOCK_FILE" ]
}
