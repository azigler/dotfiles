# Scenario result: 01-trivial-rename (local)

- **Scenario file**: `scenarios/01-trivial-rename.md`
- **Model tag**: `local`
- **Started**: 2026-05-26T03:35:29Z
- **Wall time**: 2s
- **claude exit code**: 1
- **Result file**: `/home/ubuntu/dotfiles/.claude/worktrees/agent-a26b236bbfb1ab01b/claude/sandbox/results/01-trivial-rename-local-20260526T033529Z.md`

## Model routing evidence

(CCR log: /home/ubuntu/.claude-code-router/logs/ccr-20260526025708.log)
    Error from provider(pico-mlx,qwen3-coder: 404): {"error": "'dict object' has no attribute 'parameters'"}
    Using background model for claude-haiku-4-5
    [provider_response_error] Error from provider(pico-mlx,qwen3-coder: 404): {"error": "'dict object' has no attribute 'parameters'"}
    Error from provider(pico-mlx,qwen3-coder: 404): {"error": "'dict object' has no attribute 'parameters'"}

## Sandbox state after run (pre-cleanup snapshot)

```
    /tmp/claude-local-test/s01/calc.py
```

## Prompt sent

```
In `/tmp/claude-local-test/s01/calc.py`, rename the function `add_numbers` to `sum_two`. Update the call site too. Make no other changes. When done, reply with the single word "DONE".
```

## Claude output

```
There's an issue with the selected model (claude-haiku-4-5). It may not exist or you may not have access to it. Run --model to pick a different model.
```
