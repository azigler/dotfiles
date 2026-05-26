# Scenario 02 — Easy add function

## Setup
```bash
SANDBOX="${SANDBOX:-/tmp/claude-local-test}"
mkdir -p "$SANDBOX/s02"
cat > "$SANDBOX/s02/strutil.py" <<'EOF'
def reverse_string(s: str) -> str:
    """Return s reversed."""
    return s[::-1]
EOF
cat > "$SANDBOX/s02/test_strutil.py" <<'EOF'
from strutil import reverse_string


def test_reverse_string():
    assert reverse_string("abc") == "cba"
EOF
cd "$SANDBOX/s02"
```

## Prompt
In `/tmp/claude-local-test/s02/`, add a new function `is_palindrome(s: str) -> bool` to `strutil.py` that returns True if `s` reads the same forward and backward (case-sensitive). Add one test for it in `test_strutil.py` covering at least the cases `"racecar"` (True) and `"hello"` (False). Run `python -m pytest test_strutil.py` to confirm both tests pass. When done, reply with the single word "DONE".

## Pass criteria
- `strutil.py` defines `is_palindrome` (verify: `grep -c 'def is_palindrome' strutil.py` equals `1`)
- `test_strutil.py` has at least 2 tests (verify: `grep -c '^def test_' test_strutil.py` >= `2`)
- `cd /tmp/claude-local-test/s02 && python -m pytest test_strutil.py -q` exits 0
- Final model output contains the word `DONE`

## Cleanup
```bash
rm -rf "${SANDBOX:-/tmp/claude-local-test}/s02"
```

## Notes
- Adds a function + test + verifies via Bash tool
- Expected wall time: ~30s Opus, ~90s local
- Tests: Write tool, Edit tool, Bash tool composition
- Failure modes: model adds the function but skips the test, model writes test that doesn't actually run, model uses `unittest` instead of pytest (test still passes, criterion still met)
