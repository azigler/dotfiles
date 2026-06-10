# Scenario 01 — Trivial rename

## Setup
```bash
SANDBOX="${SANDBOX:-/tmp/claude-local-test}"
mkdir -p "$SANDBOX/s01"
cat > "$SANDBOX/s01/calc.py" <<'EOF'
def add_numbers(a, b):
    """Sum two numbers."""
    return a + b


if __name__ == "__main__":
    print(add_numbers(2, 3))
EOF
cd "$SANDBOX/s01"
```

## Prompt
In `/tmp/claude-local-test/s01/calc.py`, rename the function `add_numbers` to `sum_two`. Update the call site too. Make no other changes. When done, reply with the single word "DONE".

## Pass criteria
- File `/tmp/claude-local-test/s01/calc.py` exists
- `grep -c '^def sum_two' /tmp/claude-local-test/s01/calc.py` equals `1`
- `grep -c 'add_numbers' /tmp/claude-local-test/s01/calc.py` equals `0`
- File still has the `if __name__ == "__main__":` guard
- Final model output contains the word `DONE`

## Expected artifacts
```bash
# Artifact-first verdict (run-scenario.sh runs this BEFORE Cleanup and
# before consulting exit codes). Exit 0 = expected sandbox state.
f="${SANDBOX:-/tmp/claude-local-test}/s01/calc.py"
[[ -f "$f" ]] || exit 1
[[ "$(grep -c '^def sum_two' "$f")" -eq 1 ]] || exit 1
[[ "$(grep -c 'add_numbers' "$f")" -eq 0 ]] || exit 1
grep -q 'if __name__ == "__main__":' "$f" || exit 1
exit 0
```

## Cleanup
```bash
rm -rf "${SANDBOX:-/tmp/claude-local-test}/s01"
```

## Notes
- Smallest possible Edit task — 1 file, 2 token sites
- Expected wall time: <10s Opus, <30s local
- Tests: can the model use Edit at all on a single file
- Failure modes to watch: model decides to "improve" docstring, model writes "DONE" but doesn't actually edit
