# Scenario 09 — Self-correct (catch the planted flaw)

## Setup
```bash
SANDBOX="${SANDBOX:-/tmp/claude-local-test}"
mkdir -p "$SANDBOX/s09"
cat > "$SANDBOX/s09/math_utils.py" <<'EOF'
def average(nums):
    """Return the arithmetic mean of nums. Returns None for empty input."""
    if not nums:
        return None
    # PLANTED FLAW: integer division loses precision
    return sum(nums) // len(nums)


if __name__ == "__main__":
    print(average([1, 2, 3, 4]))  # should print 2.5, currently prints 2
EOF
cd "$SANDBOX/s09"
```

## Prompt
Read `/tmp/claude-local-test/s09/math_utils.py`. There is at least one subtle correctness bug in the `average` function — find it, fix it, and explain in 1-2 sentences why your fix is right. Verify with `python /tmp/claude-local-test/s09/math_utils.py` (it should print `2.5`, not `2`). When done, reply with `DONE`.

## Pass criteria
- `python /tmp/claude-local-test/s09/math_utils.py` outputs exactly `2.5` (and a trailing newline)
- The fix uses `/` not `//` (verify: `grep -c 'sum(nums) //' /tmp/claude-local-test/s09/math_utils.py` equals `0`)
- Model output contains the words "integer division" OR "float division" OR "precision" OR "//" in the explanation
- Final model output contains `DONE`

## Cleanup
```bash
rm -rf "${SANDBOX:-/tmp/claude-local-test}/s09"
```

## Notes
- Tests: can the model do CODE REVIEW + fix, not just whatever-was-asked
- Expected wall time: ~30s Opus, ~2min local
- Failure modes:
  - Model misses the `//` and "fixes" something else (e.g. the empty-input check)
  - Model finds the bug but can't articulate WHY (poor explanation quality)
  - Model fixes by adding `float()` instead of changing `//` to `/` — both work, accept either
- Smell test: a degraded model often "fixes" perfectly correct code, this scenario probes that tendency
