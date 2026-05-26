# Scenario 07 — Bead dispatch (sub-subagent simulation)

## Setup
```bash
SANDBOX="${SANDBOX:-/tmp/claude-local-test}"
mkdir -p "$SANDBOX/s07"
cat > "$SANDBOX/s07/main.py" <<'EOF'
# A small module that needs a helper added.
def main():
    print("hello")


if __name__ == "__main__":
    main()
EOF
cd "$SANDBOX/s07"
```

## Prompt
You are acting as an orchestrator. We do NOT actually want you to spawn a real subagent (the sandbox forbids nested agent tools). Instead, SIMULATE the orchestration flow by:

1. Drafting a `Bead description` block (markdown) for a hypothetical task: "add a `goodbye()` function to `/tmp/claude-local-test/s07/main.py` that prints `bye` and is called after `main()`". Include `## Context`, `## Task`, `## Acceptance Criteria` sections.
2. THEN, acting as the dispatched subagent, implement the change in `main.py`.
3. Finally, write a one-paragraph "merge report" describing what was done.

Reply with the bead description, then `---`, then the merge report. When finished, the last line of your output should be the single word "DONE".

## Pass criteria
- Output contains a "Bead description" or similar header
- Output contains `## Context`, `## Task`, `## Acceptance Criteria` (case-insensitive grep)
- `grep -c 'def goodbye' /tmp/claude-local-test/s07/main.py` equals `1`
- `grep -c 'goodbye()' /tmp/claude-local-test/s07/main.py` >= `1` (call site)
- Output contains a separator `---` somewhere
- Output contains the words `merge report` or "merge:" or similar
- Final model output contains `DONE`

## Cleanup
```bash
rm -rf "${SANDBOX:-/tmp/claude-local-test}/s07"
```

## Notes
- Tests structured-output discipline: can the model maintain the bead format AND do the implementation in one session
- We don't test ACTUAL bead dispatch (would require `br` + worktrees in sandbox) — just the shape of bead-aware reasoning
- Expected wall time: ~45s Opus, ~3min local
- Failure modes: model skips the bead description and just edits, model writes a great bead description but forgets to edit, model can't maintain markdown structure under the heading load (this is where local models typically wobble)
