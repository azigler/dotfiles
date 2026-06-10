#!/usr/bin/env bats
#
# test_safe_remote.bats — bats suite for local-models/lib/safe_remote.sh.
#
# Why: matrix postmortem 2026-06 failure mode #12 — guard tooling with no
# test suite. safe_remote.sh implements the verify-the-negation discipline
# (postmortem #3: `pkill` exits 0 whether or not processes died; 7 orphan
# ollama runners accumulated). This suite covers:
#
#   - safe_pgrep_remote: zero-matches success, survivors failure
#   - safe_pkill_remote: kill-then-verify happy path, retry-then-success,
#     retry-then-fail (the loud failure that replaces silent success)
#
# No real ssh: a PATH-shimmed fake `ssh` script in $BATS_TEST_TMPDIR logs
# every invocation and serves scripted pgrep responses from a queue, so
# the whole suite runs offline. Run: bats local-models/tests/test_safe_remote.bats
#
# Tests marked "KNOWN GAP" pin current behavior; see tests/KNOWN-GAPS.md.
#
# Bead: dotfiles-t4k (implements local-coding-models-wkw).

setup() {
  DOTFILES_ROOT="${DOTFILES_ROOT:-$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)}"
  SAFE_REMOTE="$DOTFILES_ROOT/local-models/lib/safe_remote.sh"

  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  export SSH_LOG="$BATS_TEST_TMPDIR/ssh.log"
  export SSH_PGREP_DIR="$BATS_TEST_TMPDIR/pgrep-responses"
  export SSH_PGREP_COUNT="$BATS_TEST_TMPDIR/pgrep-count"
  mkdir -p "$SSH_PGREP_DIR"
  echo 0 > "$SSH_PGREP_COUNT"
  : > "$SSH_LOG"

  # Fake ssh: append the full invocation to SSH_LOG; if the remote command
  # is a pgrep, emit the Nth scripted response (response-1, response-2, ...
  # missing file = no survivors). SSH_FAKE_EXIT simulates transport failure.
  cat > "$FAKE_BIN/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
remote_cmd="${@: -1}"
if [[ "$remote_cmd" == *pgrep* ]]; then
  n=$(($(cat "$SSH_PGREP_COUNT") + 1))
  echo "$n" > "$SSH_PGREP_COUNT"
  resp="$SSH_PGREP_DIR/response-$n"
  if [[ -f "$resp" && "${SSH_FAKE_EXIT:-0}" -eq 0 ]]; then
    cat "$resp"
  fi
fi
exit "${SSH_FAKE_EXIT:-0}"
FAKE
  chmod +x "$FAKE_BIN/ssh"
  export PATH="$FAKE_BIN:$PATH"
}

# Run a snippet in a fresh bash with the lib sourced (fake ssh on PATH).
sremote() {
  bash -c "source '$SAFE_REMOTE'; $1"
}

pgrep_response() { # pgrep_response N "line of pgrep -af output"
  printf '%s\n' "$2" > "$SSH_PGREP_DIR/response-$1"
}

ssh_call_count() { wc -l < "$SSH_LOG"; }

# ---- sanity: the shim, not real ssh ----

@test "shim: ssh resolves to the PATH-shimmed fake" {
  run bash -c "command -v ssh"
  [ "$status" -eq 0 ]
  [ "$output" = "$FAKE_BIN/ssh" ]
}

# ---- safe_pgrep_remote ----

@test "pgrep: zero matches returns 0 and makes exactly one ssh call" {
  run sremote "safe_pgrep_remote pico 'ollama'"
  [ "$status" -eq 0 ]
  [ "$(ssh_call_count)" -eq 1 ]
  grep -q "ConnectTimeout=5 pico" "$SSH_LOG"
  grep -q "pgrep -af 'ollama'" "$SSH_LOG"
}

@test "pgrep: survivors return 1 and are printed for the operator" {
  pgrep_response 1 "1234 ollama runner --model qwen3"
  run sremote "safe_pgrep_remote pico 'ollama'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"found surviving matches"* ]]
  [[ "$output" == *"1234 ollama runner --model qwen3"* ]]
}

@test "pgrep: unreachable host reports 'all clear' (KNOWN GAP — fails open)" {
  # ssh transport failure (exit 255, no output) is indistinguishable from
  # "zero matches": the `|| true` + empty-capture path returns success, so
  # verify-the-negation passes while the host was never checked at all.
  # Pins current behavior — see KNOWN-GAPS.md.
  export SSH_FAKE_EXIT=255
  run sremote "safe_pgrep_remote pico 'ollama'"
  [ "$status" -eq 0 ]
}

# ---- safe_pkill_remote ----

@test "pkill: kill then clean verify returns 0 with exactly 2 ssh calls" {
  run sremote "safe_pkill_remote pico 'ollama' 0"
  [ "$status" -eq 0 ]
  [ "$(ssh_call_count)" -eq 2 ]
  # Call 1 is the kill, call 2 the verification pgrep.
  head -1 "$SSH_LOG" | grep -q "pkill -9 -f 'ollama'"
  tail -1 "$SSH_LOG" | grep -q "pgrep -af 'ollama'"
}

@test "pkill: survivors on first verify, clean on retry returns 0 (4 ssh calls)" {
  pgrep_response 1 "1234 ollama runner"
  # response-2 absent = retry verification finds nothing
  run sremote "safe_pkill_remote pico 'ollama' 0"
  [ "$status" -eq 0 ]
  [ "$(ssh_call_count)" -eq 4 ]
  [[ "$output" == *"survivors found; retrying once"* ]]
}

@test "pkill: survivors after retry FAIL loudly with exit 1" {
  # The whole point of the lib (postmortem #3): a kill that did not stick
  # must be a loud error, not a silent exit 0.
  pgrep_response 1 "1234 ollama runner"
  pgrep_response 2 "1234 ollama runner"
  run sremote "safe_pkill_remote pico 'ollama' 0"
  [ "$status" -eq 1 ]
  [ "$(ssh_call_count)" -eq 4 ]
  [[ "$output" == *"FAILED to eliminate all matches after retry"* ]]
}

@test "pkill: WAIT_SEC propagates to the remote sleep, doubled on retry" {
  pgrep_response 1 "1234 ollama runner"
  pgrep_response 2 "1234 ollama runner"
  run sremote "safe_pkill_remote pico 'ollama' 7"
  [ "$status" -eq 1 ]
  sed -n '1p' "$SSH_LOG" | grep -q "sleep 7"
  sed -n '3p' "$SSH_LOG" | grep -q "sleep 14"
}

@test "pkill: unreachable host reports success (KNOWN GAP — fails open)" {
  # Both the kill AND the verification ride the same dead transport; the
  # verification's empty capture reads as "no survivors" and the function
  # returns 0 having killed nothing. Pins current behavior — see
  # KNOWN-GAPS.md.
  export SSH_FAKE_EXIT=255
  run sremote "safe_pkill_remote pico 'ollama' 0"
  [ "$status" -eq 0 ]
}
