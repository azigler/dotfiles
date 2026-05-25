"""Trinity-Mini Hermes-XML → OpenAI tool_calls[] parser shim.

Per `~/explore/local-coding-models/refs/research/research-trinity-toolcalls.md`
(bead `explore-4te.17`):

Trinity-Mini (Arcee AI, BFCL V3 score 59.67) is a real function-calling model.
Its trained output format is Hermes-style XML wrapping JSON:

    <tool_call>
    {"name": "read_file", "arguments": {"path": "/etc/hostname"}}
    </tool_call>

`mlx_lm.server` 0.31.3 lacks a Hermes parser registration, so the XML stays in
`content` and `tool_calls[]` stays empty. The vLLM equivalent is
`--tool-call-parser hermes --reasoning-parser deepseek_r1 --enable-auto-tool-choice`.

This shim lifts the XML into structured `tool_calls[]` client-side. Stable
contract because Trinity's emit format is documented and unchanging.

Usage::

    import json, urllib.request
    from trinity_shim import parse_trinity_response, call_trinity_mlx

    # Convenience: call + parse in one step
    response = call_trinity_mlx(
        prompt="Read /etc/hostname",
        tools=[{"type": "function", "function": {
            "name": "read_file",
            "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
        }}],
    )
    print(response["message"]["tool_calls"])  # → structured OpenAI shape

    # OR: take a raw mlx_lm.server response and parse
    raw = json.loads(urllib.request.urlopen(req).read())
    cleaned = parse_trinity_response(raw)
    print(cleaned["message"]["tool_calls"])
"""

from __future__ import annotations

import json
import re
import urllib.request
import uuid
from typing import Any

# Trinity's Hermes-style XML wrapper. DOTALL because JSON body has newlines.
_TOOL_CALL_PATTERN = re.compile(
    r"<tool_call>\s*(\{.*?\})\s*</tool_call>", re.DOTALL
)


def parse_trinity_response(response: dict[str, Any]) -> dict[str, Any]:
    """Lift Hermes-XML `<tool_call>` blocks out of `content` into `tool_calls[]`.

    Mutates the response in place AND returns it for chaining.

    Contract:
    - If `content` contains one or more `<tool_call>{...}</tool_call>` blocks,
      each is parsed as JSON `{"name": ..., "arguments": ...}` and synthesized
      into an OpenAI `tool_calls[]` entry with a generated `id`.
    - The XML blocks are stripped from `content` (the remaining text is the
      model's narration around the calls, if any).
    - If `tool_calls[]` already has entries (e.g. server-side parser fired
      after all), those are preserved and the shim's parsed entries appended.
    - If `content` has no `<tool_call>` blocks, response is returned unchanged.

    Works on `mlx_lm.server` `/v1/chat/completions` response shape::

        {"choices": [{"message": {"role": "assistant",
                                  "content": "...<tool_call>{...}</tool_call>...",
                                  "tool_calls": []}}]}

    AND on the bare `message` dict shape (Ollama `/api/chat` style). The shim
    autodetects which shape it got.
    """
    # Auto-detect shape: chat-completions (choices[].message) vs ollama-native (message)
    if response.get("choices"):
        msg = response["choices"][0]["message"]
    elif "message" in response:
        msg = response["message"]
    else:
        return response  # unknown shape; pass through

    content = msg.get("content") or ""
    matches = _TOOL_CALL_PATTERN.findall(content)
    if not matches:
        return response

    parsed_calls = []
    for body in matches:
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            # Malformed JSON in XML body — leave the block in content; skip
            continue
        name = payload.get("name")
        arguments = payload.get("arguments", {})
        if not name:
            continue
        parsed_calls.append(
            {
                "id": f"call_{uuid.uuid4().hex[:24]}",
                "type": "function",
                "function": {
                    "name": name,
                    # OpenAI shape: arguments must be a JSON string, not an object
                    "arguments": json.dumps(arguments)
                    if isinstance(arguments, (dict, list))
                    else str(arguments),
                },
            }
        )

    if not parsed_calls:
        return response

    # Strip the XML blocks from content
    cleaned_content = _TOOL_CALL_PATTERN.sub("", content).strip()
    msg["content"] = cleaned_content

    # Preserve any pre-existing tool_calls (defensive); append parsed ones
    existing = msg.get("tool_calls") or []
    msg["tool_calls"] = existing + parsed_calls
    return response


def call_trinity_mlx(
    prompt: str,
    tools: list[dict] | None = None,
    *,
    model: str = "mlx-community/Trinity-Mini-4bit",
    base_url: str = "http://100.72.47.4:8081/v1/chat/completions",
    max_tokens: int = 1024,
    temperature: float = 0.7,
    timeout: float = 120.0,
    **extra_body: Any,
) -> dict[str, Any]:
    """Convenience: call Trinity MLX with tools, parse Hermes XML, return shaped response.

    Returns the FULL response dict with `tool_calls[]` lifted. Caller reads
    `response["choices"][0]["message"]["tool_calls"]` for the structured calls.
    """
    body: dict[str, Any] = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": False,
    }
    if tools:
        body["tools"] = tools
        body["tool_choice"] = "auto"
    body.update(extra_body)

    req = urllib.request.Request(
        base_url,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = json.loads(resp.read())
    return parse_trinity_response(raw)


if __name__ == "__main__":
    # Self-test against pico Trinity MLX
    print("=== trinity_shim self-test ===")
    print("Calling Trinity MLX with read_file tool...")
    response = call_trinity_mlx(
        prompt="Read /etc/hostname using the read_file tool. Then read /etc/os-release using the same tool.",
        tools=[
            {
                "type": "function",
                "function": {
                    "name": "read_file",
                    "description": "Read contents of a file",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": {
                                "type": "string",
                                "description": "absolute path",
                            }
                        },
                        "required": ["path"],
                    },
                },
            }
        ],
        max_tokens=500,
        temperature=0,
    )
    msg = response["choices"][0]["message"]
    print(
        f"\nstructured tool_calls (after shim): {len(msg.get('tool_calls', []))}"
    )
    for i, tc in enumerate(msg.get("tool_calls", [])):
        fn = tc["function"]
        print(f"  [{i}] {fn['name']}({fn['arguments']})")
    print(f"\ncontent (stripped of XML): {msg.get('content', '')[:200]!r}")
    print(f"reasoning (if present): {msg.get('reasoning', '<absent>')[:200]!r}")
    # Verdict
    if msg.get("tool_calls"):
        print(
            "\n✅ Shim works: Trinity emitted Hermes XML, shim lifted into tool_calls[]"
        )
    else:
        print(
            "\n⚠️ No tool_calls extracted. Either Trinity didn't emit tool calls or the XML doesn't match the expected shape."
        )
