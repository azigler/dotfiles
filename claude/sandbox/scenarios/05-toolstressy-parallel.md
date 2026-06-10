# Scenario 05 — Tool-stressy parallel (Edit + Bash)

## Setup
```bash
SANDBOX="${SANDBOX:-/tmp/claude-local-test}"
mkdir -p "$SANDBOX/s05"
cat > "$SANDBOX/s05/greet.py" <<'EOF'
def greet(name):
    return f"Hello, {name}!"


if __name__ == "__main__":
    print(greet("world"))
EOF
cd "$SANDBOX/s05"
```

## Prompt
In `/tmp/claude-local-test/s05/greet.py`, change the greeting from "Hello" to "Howdy". In the SAME assistant turn, ALSO run `python /tmp/claude-local-test/s05/greet.py` via the Bash tool to verify the change works. Do these in PARALLEL (single message with both Edit and Bash tool calls). When both have run, reply with the single word "DONE".

## Pass criteria
- `grep -c 'Howdy' /tmp/claude-local-test/s05/greet.py` equals `1`
- `grep -c 'Hello' /tmp/claude-local-test/s05/greet.py` equals `0`
- Model output shows BOTH Edit and Bash tool invocations
- Final model output contains the word `DONE`
- (Bonus) If running with `--output-format=stream-json` we can verify both `tool_use` blocks appeared in the same `assistant` message (parallel emission)

## Expected artifacts
```bash
# Artifact-first verdict (run-scenario.sh runs this BEFORE Cleanup and
# before consulting exit codes). Exit 0 = expected sandbox state.
# NOTE: the parallel-emission criterion is output-shaped and stays in
# Pass criteria (Tier-1 scoring); the artifact contract is the edit.
f="${SANDBOX:-/tmp/claude-local-test}/s05/greet.py"
[[ -f "$f" ]] || exit 1
[[ "$(grep -c 'Howdy' "$f")" -eq 1 ]] || exit 1
[[ "$(grep -c 'Hello' "$f")" -eq 0 ]] || exit 1
exit 0
```

## Cleanup
```bash
rm -rf "${SANDBOX:-/tmp/claude-local-test}/s05"
```

## Notes
- THE G16 stress case — does the local model emit parallel tool_calls
- Per GUARDRAILS G16: only Qwen3-Coder via llama-swap :8090 passes this empirically
- Expected wall time: ~15s Opus, ~45s local
- Tests: parallel tool call emission, not just sequential
- Failure modes: model serializes Edit then Bash (still functional but fails the parallel criterion); local refuses to emit tool calls per G16 if route is wrong
