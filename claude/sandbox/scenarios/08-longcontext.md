# Scenario 08 — Long-context (30K token preamble, focused change)

## Setup
```bash
SANDBOX="${SANDBOX:-/tmp/claude-local-test}"
mkdir -p "$SANDBOX/s08"

# Generate a ~30K-token preamble by concatenating padding. Real text, not
# random bytes — random bytes don't exercise tokenizer realistically.
# ~4 chars/token → 30K tokens ≈ 120K chars.
python3 - <<'PY'
import os
out = os.path.expanduser("/tmp/claude-local-test/s08/preamble.md")
para = ("This module is part of a hypothetical large codebase. " * 20) + "\n\n"
with open(out, "w") as f:
    # ~140 chars per paragraph * 900 paragraphs ≈ 126K chars ≈ 31.5K tokens
    for i in range(900):
        f.write(f"## Section {i}\n\n{para}")
PY

cat > "$SANDBOX/s08/api.py" <<'EOF'
# CRITICAL SENTINEL: the function below must be renamed.
def process_request(payload):
    """Validate and process an incoming request."""
    if not payload:
        return None
    return {"status": "ok", "data": payload}
EOF
cd "$SANDBOX/s08"
```

## Prompt
First read `/tmp/claude-local-test/s08/preamble.md` (it's long context). Then make ONE focused change: in `/tmp/claude-local-test/s08/api.py`, rename `process_request` to `handle_request`. Update any call sites in the file (there are none in this case, but check). Confirm the change with `grep`. When done, reply with `DONE`.

## Pass criteria
- `grep -c 'def handle_request' /tmp/claude-local-test/s08/api.py` equals `1`
- `grep -c 'process_request' /tmp/claude-local-test/s08/api.py` equals `0`
- Final model output contains `DONE`
- (Soft check) Wall time should NOT be wildly worse than scenario 01 — if it's 5× slower, the model is choking on context

## Cleanup
```bash
rm -rf "${SANDBOX:-/tmp/claude-local-test}/s08"
```

## Notes
- 30K-token preamble exercises CCR's `longContextThreshold: 50000` boundary — at 30K we stay on the `background` route (Qwen3 via llama-swap), not `longContext` (Laguna via Ollama)
- Qwen3-Coder-30B context window is 256K, so 30K is well within capacity
- Tests: does the model find the right needle in a haystack, does latency degrade gracefully
- Expected wall time: ~30s Opus, ~3-5min local (prefill cost on 30K tokens is real)
- Failure modes: model gets "lost" in preamble and forgets the actual task, model hallucinates call sites that don't exist, request times out on local (mlx_lm prefill is slow on M1 Max at 30K)
- If this hangs >10min on local, cancel and mark FAILED — that's a real signal about workload viability
