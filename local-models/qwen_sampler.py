"""Qwen3-Coder MLX sampler-defaults wrapper.

Per `~/explore/local-coding-models/refs/research/research-mlx-repetition.md`
(bead `explore-4te.14` — RESOLVED):

`mlx_lm.server` 0.31.3 accepts `repetition_penalty` (plus `repetition_context_size`,
`presence_penalty`, `frequency_penalty`) as request-body parameters — documented in
`SERVER.md` but NOT in `--help` (doc-discoverability bug). Without these, Qwen3 MLX
mode-collapses on long prose generation. With Qwen-recommended sampler shape it works
fine.

This module bakes Qwen3-Coder's recommended sampler config (from the HF model card)
into every request so callers don't have to remember:

    temperature=0.7, top_p=0.8, top_k=20,
    repetition_penalty=1.10, repetition_context_size=64

Empirical receipt (2026-05-25): with these defaults, Qwen3-Coder-30B-A3B-Instruct-4bit
produces clean prose at 82% tail-unique-word ratio. Without them, mode collapse.

Usage::

    from qwen_sampler import call_qwen_mlx, inject_qwen_defaults

    # Convenience: call Qwen MLX with Qwen sampler baked in
    response = call_qwen_mlx(
        prompt="Continue this prose: ...",
        max_tokens=700,
    )
    text = response["choices"][0]["message"]["content"]

    # Or: inject defaults into an arbitrary request body before dispatching
    body = {"model": "...", "messages": [...], "max_tokens": 500}
    body = inject_qwen_defaults(body)  # adds sampler params
    # ... then POST it yourself

Companion to `trinity_shim.py` (same `~/dotfiles/local-models/` directory).
"""

from __future__ import annotations

import json
import urllib.request
from typing import Any

# Qwen3-Coder-30B HF model card recommended sampler config (verified working 2026-05-25)
QWEN_SAMPLER_DEFAULTS: dict[str, Any] = {
    "temperature": 0.7,
    "top_p": 0.8,
    "top_k": 20,
    "repetition_penalty": 1.10,  # THE fix for G13 long-prose mode collapse
    "repetition_context_size": 64,  # default 20 is too short for sentence loops
}

# Pico's serving endpoints (override via env / kwargs if running elsewhere)
QWEN_MLX_MODEL = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
QWEN_OLLAMA_MODEL = "qwen3-coder:30b"
MLX_BASE_URL = "http://100.72.47.4:8081/v1/chat/completions"
OLLAMA_BASE_URL = "http://100.72.47.4:11434/v1/chat/completions"


def inject_qwen_defaults(
    body: dict[str, Any], *, override_existing: bool = False
) -> dict[str, Any]:
    """Add Qwen-recommended sampler params to a chat-completions request body.

    Args:
        body: the request-body dict (mutated in place AND returned)
        override_existing: if True, overwrite caller-set sampler values with
            Qwen defaults. Default False — caller's explicit choice wins.

    Returns:
        The (possibly mutated) body. Always returns for chaining.

    Example::

        body = {"model": "...", "messages": [...], "max_tokens": 500, "temperature": 0.9}
        inject_qwen_defaults(body)
        # body["temperature"] is still 0.9 (caller's explicit value)
        # body["repetition_penalty"] is now 1.10 (was missing)

        inject_qwen_defaults(body, override_existing=True)
        # body["temperature"] is now 0.7 (Qwen default forced)
    """
    for key, default in QWEN_SAMPLER_DEFAULTS.items():
        if override_existing or key not in body:
            body[key] = default
    return body


def call_qwen_mlx(
    prompt: str | None = None,
    messages: list[dict] | None = None,
    *,
    model: str = QWEN_MLX_MODEL,
    base_url: str = MLX_BASE_URL,
    max_tokens: int = 700,
    timeout: float = 180.0,
    sampler_overrides: dict[str, Any] | None = None,
    **extra_body: Any,
) -> dict[str, Any]:
    """Call Qwen3-Coder MLX with Qwen-recommended sampler baked in.

    Provide either `prompt` (one-shot user message) or `messages` (full
    conversation). Sampler is Qwen-recommended; override individual params
    via `sampler_overrides={"temperature": 0.9}` etc.

    Returns the full response dict from mlx_lm.server.

    For Ollama backend instead of MLX, use `base_url=OLLAMA_BASE_URL` and
    `model=QWEN_OLLAMA_MODEL`. Ollama has `repeat_penalty=1.10` default so the
    sampler params are belt-and-suspenders there — no harm.
    """
    if messages is None:
        if prompt is None:
            raise ValueError("Provide either prompt= or messages=")
        messages = [{"role": "user", "content": prompt}]

    body: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "stream": False,
    }
    inject_qwen_defaults(body)
    if sampler_overrides:
        body.update(sampler_overrides)
    body.update(extra_body)

    req = urllib.request.Request(
        base_url,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def call_qwen_ollama(
    prompt: str | None = None,
    messages: list[dict] | None = None,
    **kwargs: Any,
) -> dict[str, Any]:
    """Shortcut for Qwen3-Coder Ollama backend (same sampler discipline)."""
    return call_qwen_mlx(
        prompt=prompt,
        messages=messages,
        model=QWEN_OLLAMA_MODEL,
        base_url=OLLAMA_BASE_URL,
        **kwargs,
    )


if __name__ == "__main__":
    import time

    print("=== qwen_sampler self-test ===")
    print("Calling Qwen3 MLX with Qwen sampler baked in...")
    t0 = time.perf_counter()
    response = call_qwen_mlx(
        prompt="Write exactly one sentence: 'The fire crackled in the dark.' Then stop.",
        max_tokens=50,
    )
    elapsed = time.perf_counter() - t0
    content = response["choices"][0]["message"]["content"]
    usage = response.get("usage", {})
    print(
        f"\nTook {elapsed:.1f}s; {usage.get('completion_tokens', '?')} tokens"
    )
    print(f"Content: {content!r}")
    print(
        "\nVerifying sampler defaults were applied (check by inspecting body):"
    )
    test_body = {"model": "x", "messages": [], "max_tokens": 100}
    inject_qwen_defaults(test_body)
    print(f"  temperature: {test_body['temperature']}")
    print(f"  top_p: {test_body['top_p']}")
    print(f"  top_k: {test_body['top_k']}")
    print(f"  repetition_penalty: {test_body['repetition_penalty']}")
    print(f"  repetition_context_size: {test_body['repetition_context_size']}")
    print("\n✅ Sampler defaults injected as expected")
