# Scenario 03 — Medium refactor (extract method)

## Setup
```bash
SANDBOX="${SANDBOX:-/tmp/claude-local-test}"
mkdir -p "$SANDBOX/s03"
cat > "$SANDBOX/s03/report.py" <<'EOF'
def generate_report(orders):
    # Compute total revenue
    total = 0
    for o in orders:
        total += o["price"] * o["qty"]

    # Format header
    header = "ORDER REPORT\n" + ("=" * 30) + "\n"

    # Format body
    body = ""
    for o in orders:
        body += f"  {o['name']:20s} ${o['price'] * o['qty']:>8.2f}\n"

    # Format footer
    footer = ("-" * 30) + f"\n  TOTAL{' ' * 16}${total:>8.2f}\n"

    return header + body + footer


if __name__ == "__main__":
    orders = [
        {"name": "widget", "price": 1.50, "qty": 3},
        {"name": "sprocket", "price": 2.25, "qty": 2},
    ]
    print(generate_report(orders))
EOF
cd "$SANDBOX/s03"
```

## Prompt
In `/tmp/claude-local-test/s03/report.py`, refactor `generate_report` by extracting the total-revenue computation into a helper function called `compute_total(orders) -> float`. Update `generate_report` to call this helper. The output of `python report.py` MUST be byte-identical before and after the refactor. When done, reply with the single word "DONE".

## Pass criteria
- `grep -c 'def compute_total' report.py` equals `1`
- `compute_total` is called from inside `generate_report` (verify: `grep 'compute_total(' report.py | wc -l` >= `2` — definition + at least one call)
- `cd /tmp/claude-local-test/s03 && python report.py` produces the SAME output as the original (snapshot original first; runner compares)
- Final model output contains the word `DONE`

## Cleanup
```bash
rm -rf "${SANDBOX:-/tmp/claude-local-test}/s03"
```

## Notes
- Real refactor — extract method, preserve behavior
- Expected wall time: ~60s Opus, ~3min local
- Tests: reading + restructuring code with byte-identical output
- Failure modes: model "improves" the output formatting, breaks behavior parity; model creates `compute_total` but doesn't call it from `generate_report`
- Pre-run: capture baseline output to `/tmp/claude-local-test/s03-baseline.txt` so the runner can diff
