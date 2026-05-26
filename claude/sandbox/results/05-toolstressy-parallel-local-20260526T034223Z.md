# Scenario result: 05-toolstressy-parallel (local)

- **Scenario file**: `scenarios/05-toolstressy-parallel.md`
- **Model tag**: `local`
- **Started**: 2026-05-26T03:42:23Z
- **Wall time**: 2s
- **claude exit code**: 1
- **Result file**: `/home/ubuntu/dotfiles/.claude/worktrees/agent-a26b236bbfb1ab01b/claude/sandbox/results/05-toolstressy-parallel-local-20260526T034223Z.md`

## Model routing evidence

(CCR log: /home/ubuntu/.claude-code-router/logs/ccr-20260526025708.log)
    Error from provider(pico-mlx,qwen3-coder: 404): {"error": "'dict object' has no attribute 'parameters'"}
    Using background model for claude-haiku-4-5
    [provider_response_error] Error from provider(pico-mlx,qwen3-coder: 404): {"error": "'dict object' has no attribute 'parameters'"}
    Error from provider(pico-mlx,qwen3-coder: 404): {"error": "'dict object' has no attribute 'parameters'"}

## Sandbox state after run (pre-cleanup snapshot)

```
    /tmp/claude-local-test/s05/greet.py
```

## Prompt sent

```
In `/tmp/claude-local-test/s05/greet.py`, change the greeting from "Hello" to "Howdy". In the SAME assistant turn, ALSO run `python /tmp/claude-local-test/s05/greet.py` via the Bash tool to verify the change works. Do these in PARALLEL (single message with both Edit and Bash tool calls). When both have run, reply with the single word "DONE".
```

## Claude output

```
There's an issue with the selected model (claude-haiku-4-5). It may not exist or you may not have access to it. Run --model to pick a different model.
```
