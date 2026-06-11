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
# KNOWN-GAPS #1/#2 (fail-open on transport failure) are FIXED — the tests
# that used to pin the fail-open behavior now assert fail-CLOSED (exit 2).
# See tests/KNOWN-GAPS.md.
#
# Bead: dotfiles-t4k (implements local-coding-models-wkw).
# Bead: dotfiles-afx (fail-closed flip).

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
  # missing file = no survivors). When the transport "works" (SSH_FAKE_EXIT
  # unset/0) and the remote command asks for the run-proof sentinel, echo it
  # back like a real remote shell would; SSH_FAKE_DROP_SENTINEL=1 simulates
  # a connection that returns exit 0 but never ran the command to completion.
  # SSH_FAKE_EXIT simulates transport failure.
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
if [[ "${SSH_FAKE_EXIT:-0}" -eq 0 && "${SSH_FAKE_DROP_SENTINEL:-0}" -eq 0 \
      && "$remote_cmd" == *__SAFE_REMOTE_RAN__* ]]; then
  echo "__SAFE_REMOTE_RAN__"
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
  grep -q "pgrep -af '\[o\]llama'" "$SSH_LOG"
}

@test "pgrep: survivors return 1 and are printed for the operator" {
  pgrep_response 1 "1234 ollama runner --model qwen3"
  run sremote "safe_pgrep_remote pico 'ollama'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"found surviving matches"* ]]
  [[ "$output" == *"1234 ollama runner --model qwen3"* ]]
}

@test "pgrep: unreachable host fails CLOSED with exit 2 (FIXED: KNOWN-GAPS #1)" {
  # ssh transport failure (exit 255, no output) must NOT read as "zero
  # matches": the host was never checked at all, so the guard refuses to
  # report all-clear — distinct exit code 2 + loud stderr.
  export SSH_FAKE_EXIT=255
  run sremote "safe_pgrep_remote pico 'ollama'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"VERIFY IMPOSSIBLE"* ]]
}

@test "pgrep: exit-0 transport without the run-proof sentinel fails CLOSED too" {
  # Belt-and-suspenders for KNOWN-GAPS #1: even if ssh exits 0, an empty
  # capture that lacks the sentinel means the remote command never provably
  # ran (dropped mid-stream) — still exit 2, never all-clear.
  export SSH_FAKE_DROP_SENTINEL=1
  run sremote "safe_pgrep_remote pico 'ollama'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"VERIFY IMPOSSIBLE"* ]]
}

# ---- safe_pkill_remote ----

@test "pkill: kill then clean verify returns 0 with exactly 2 ssh calls" {
  run sremote "safe_pkill_remote pico 'ollama' 0"
  [ "$status" -eq 0 ]
  [ "$(ssh_call_count)" -eq 2 ]
  # Call 1 is the kill, call 2 the verification pgrep.
  head -1 "$SSH_LOG" | grep -q "pkill -9 -f '\[o\]llama'"
  tail -1 "$SSH_LOG" | grep -q "pgrep -af '\[o\]llama'"
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

@test "pkill: unreachable host fails CLOSED with exit 2 (FIXED: KNOWN-GAPS #2)" {
  # The kill rides a dead transport: nothing was provably killed, so the
  # function must stop right there — exit 2 after the single failed kill
  # attempt, no bogus verification pass.
  export SSH_FAKE_EXIT=255
  run sremote "safe_pkill_remote pico 'ollama' 0"
  [ "$status" -eq 2 ]
  [[ "$output" == *"KILL UNVERIFIABLE"* ]]
  [ "$(ssh_call_count)" -eq 1 ]
}

@test "neutralize: embedded pattern is bracket-neutralized against self-match (bead dotfiles-7ou)" {
  # macOS pgrep/pkill -a includes ANCESTORS: the remote zsh -c wrapper whose
  # cmdline contains the literal pattern matched itself, so every eviction
  # probe found a fresh "survivor" and pre-flight aborted (first live firing
  # 2026-06-11). The pattern embedded in the ssh command must carry a
  # bracketed first char so it cannot match its own literal occurrence.
  run sremote "safe_pgrep_remote pico 'llama-server'"
  [ "$status" -eq 0 ]
  grep -q "pgrep -af '\[l\]lama-server'" "$SSH_LOG"
}

@test "neutralize: EACH alternation branch is bracketed, not just the head" {
  # 'llama-server|ollama' with only the head bracketed leaves the 'ollama'
  # branch self-matchable — the eviction probe uses exactly this pattern.
  run sremote "safe_pgrep_remote pico 'llama-server|ollama'"
  [ "$status" -eq 0 ]
  grep -q "pgrep -af '\[l\]lama-server|\[o\]llama'" "$SSH_LOG"
}

@test "neutralize: pkill path is neutralized too" {
  run sremote "safe_pkill_remote pico 'ollama serve' 0"
  [ "$status" -eq 0 ]
  sed -n '1p' "$SSH_LOG" | grep -q "pkill -9 -f '\[o\]llama serve'"
}

@test "neutralize: real survivors are still detected through the bracketed pattern" {
  # The neutralized regex must keep matching REAL processes — scripted
  # response simulates one.
  pgrep_response 1 "4321 llama-server --jinja"
  run sremote "safe_pgrep_remote pico 'llama-server'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"4321 llama-server"* ]]
}
