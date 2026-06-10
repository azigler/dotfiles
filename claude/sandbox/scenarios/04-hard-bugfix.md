# Scenario 04 — Hard bugfix (multi-file + grep)

## Setup
```bash
SANDBOX="${SANDBOX:-/tmp/claude-local-test}"
mkdir -p "$SANDBOX/s04/src"
cat > "$SANDBOX/s04/src/discount.py" <<'EOF'
def apply_discount(price, pct):
    """Apply a percentage discount. pct is 0-100."""
    # BUG: division order is wrong — should be pct/100, not 100/pct
    return price - (price * (100 / pct))
EOF
cat > "$SANDBOX/s04/src/cart.py" <<'EOF'
from discount import apply_discount


def cart_total(items, discount_pct=0):
    raw = sum(i["price"] * i["qty"] for i in items)
    if discount_pct:
        return apply_discount(raw, discount_pct)
    return raw
EOF
cat > "$SANDBOX/s04/src/checkout.py" <<'EOF'
from cart import cart_total


def checkout(cart, code):
    discount_pct = {"SAVE10": 10, "SAVE25": 25}.get(code, 0)
    return cart_total(cart, discount_pct)
EOF
cat > "$SANDBOX/s04/test_checkout.py" <<'EOF'
import sys
sys.path.insert(0, "src")

from checkout import checkout


def test_no_discount():
    cart = [{"price": 10.0, "qty": 2}]
    assert checkout(cart, None) == 20.0


def test_save10():
    cart = [{"price": 10.0, "qty": 2}]
    # 20.0 - 10% = 18.0
    assert checkout(cart, "SAVE10") == 18.0


def test_save25():
    cart = [{"price": 100.0, "qty": 1}]
    # 100.0 - 25% = 75.0
    assert checkout(cart, "SAVE25") == 75.0
EOF
cd "$SANDBOX/s04"
```

## Prompt
The test suite at `/tmp/claude-local-test/s04/test_checkout.py` is failing. Run `cd /tmp/claude-local-test/s04 && python -m pytest test_checkout.py -q` to see the failures, then trace the bug back through the code, fix it, and confirm tests pass. The bug is in ONE file. When done, reply with the single word "DONE".

## Pass criteria
- `cd /tmp/claude-local-test/s04 && python -m pytest test_checkout.py -q` exits 0
- The fix was made in `src/discount.py` only (verify: `git diff` if we wrap in a git repo, or check `grep -c 'pct / 100' src/discount.py` >= `1`)
- Tests `test_save10` and `test_save25` both pass
- Final model output contains the word `DONE`

## Expected artifacts
```bash
# Artifact-first verdict (run-scenario.sh runs this BEFORE Cleanup and
# before consulting exit codes). Exit 0 = expected sandbox state.
d="${SANDBOX:-/tmp/claude-local-test}/s04"
[[ -f "$d/src/discount.py" ]] || exit 1
# The fix must land in discount.py (pct/100, any spacing)
[[ "$(grep -Ec 'pct ?/ ?100' "$d/src/discount.py")" -ge 1 ]] || exit 1
(cd "$d" && python3 -m pytest test_checkout.py -q >/dev/null 2>&1) || exit 1
exit 0
```

## Cleanup
```bash
rm -rf "${SANDBOX:-/tmp/claude-local-test}/s04"
```

## Notes
- Requires Bash (pytest), Grep/Read (multi-file trace), Edit (fix in one place)
- Expected wall time: ~90s Opus, ~5min local
- Tests: debugging mindset, multi-file reasoning, tool composition under stress
- Failure modes: model "fixes" the test instead of the code, model rewrites all three files, model can't find the bug without hint
