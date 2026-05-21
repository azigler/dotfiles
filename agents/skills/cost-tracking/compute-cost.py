#!/usr/bin/env python3
"""Compute exact orchestrator token cost for a Claude Code session JSONL.

Reads the session JSONL on disk, filters out subagent sidechains
(`isSidechain: true` — those have their own per-bead rows from
task-notification `<usage>` blocks), sums orchestrator-only token usage,
applies model pricing, and prints a row ready for cost-tracking.md.

Usage:
    python3 ~/.claude/skills/cost-tracking/compute-cost.py \\
        [--session-jsonl PATH] \\
        [--model claude-opus-4-7 | claude-sonnet-4-6] \\
        [--format row | json | verbose | commit-line]

Default behavior: auto-discovers the most-recently-modified session JSONL
under `~/.claude/projects/<slug>/` where `<slug>` is the cwd path with
slashes replaced by hyphens (e.g., `/home/ubuntu/foo` -> `-home-ubuntu-foo`).

Format options:
    row          - markdown table row, ready to append to cost-tracking.md
    json         - machine-readable summary
    verbose      - human-readable breakdown
    commit-line  - one-liner for commit bodies (default for /choreo-style flows)

Pricing source: Anthropic public API rates as of 2026-04-18.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PRICING = {
    "claude-opus-4-7": {
        "input": 15.0 / 1_000_000,
        "output": 75.0 / 1_000_000,
        "cache_creation": 18.75 / 1_000_000,
        "cache_read": 1.50 / 1_000_000,
    },
    "claude-sonnet-4-6": {
        "input": 3.0 / 1_000_000,
        "output": 15.0 / 1_000_000,
        "cache_creation": 3.75 / 1_000_000,
        "cache_read": 0.30 / 1_000_000,
    },
    "claude-haiku-4-5": {
        "input": 1.0 / 1_000_000,
        "output": 5.0 / 1_000_000,
        "cache_creation": 1.25 / 1_000_000,
        "cache_read": 0.10 / 1_000_000,
    },
}


def sum_session_usage(jsonl_path: Path) -> dict:
    """Sum usage fields across orchestrator (non-sidechain) assistant turns."""
    totals = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": 0,
        "orchestrator_turns": 0,
        "sidechain_turns_skipped": 0,
    }

    with jsonl_path.open("r", encoding="utf-8") as fh:
        for line_num, raw in enumerate(fh, start=1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError:
                print(
                    f"warning: line {line_num} invalid JSON, skipping",
                    file=sys.stderr,
                )
                continue

            if entry.get("type") != "assistant":
                continue

            if entry.get("isSidechain") is True:
                totals["sidechain_turns_skipped"] += 1
                continue

            usage = (entry.get("message") or {}).get("usage") or {}
            totals["input_tokens"] += usage.get("input_tokens", 0)
            totals["output_tokens"] += usage.get("output_tokens", 0)
            totals["cache_creation_input_tokens"] += usage.get(
                "cache_creation_input_tokens", 0
            )
            totals["cache_read_input_tokens"] += usage.get(
                "cache_read_input_tokens", 0
            )
            totals["orchestrator_turns"] += 1

    return totals


def compute_cost(totals: dict, model: str) -> float:
    """Compute dollar cost from usage totals using model pricing."""
    rates = PRICING[model]
    return (
        totals["input_tokens"] * rates["input"]
        + totals["output_tokens"] * rates["output"]
        + totals["cache_creation_input_tokens"] * rates["cache_creation"]
        + totals["cache_read_input_tokens"] * rates["cache_read"]
    )


def format_k(n: int) -> str:
    """Format a token count as K-compact (e.g., 123456 -> '123K')."""
    return f"{n // 1000}K" if n >= 1000 else str(n)


def cwd_to_project_slug(cwd: Path) -> str:
    """Convert /home/ubuntu/foo -> -home-ubuntu-foo (Claude Code's slug convention)."""
    return str(cwd.resolve()).replace("/", "-")


def resolve_session_jsonl(explicit: Path | None) -> Path:
    """Find the active session JSONL — explicit path or most-recent in project dir."""
    if explicit is not None:
        return explicit

    cwd = Path.cwd()
    slug = cwd_to_project_slug(cwd)
    project_dir = Path.home() / ".claude" / "projects" / slug

    if not project_dir.is_dir():
        raise SystemExit(
            f"error: no project session dir found at {project_dir}\n"
            f"hint: pass --session-jsonl explicitly, or cd into a project that "
            "has had a Claude Code session"
        )

    candidates = sorted(
        project_dir.glob("*.jsonl"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        raise SystemExit(
            f"error: no session JSONL found in {project_dir}; "
            "pass --session-jsonl explicitly"
        )
    return candidates[0]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Compute orchestrator session cost from Claude Code JSONL"
    )
    parser.add_argument(
        "--session-jsonl",
        default=None,
        type=Path,
        help=(
            "Path to the session JSONL file "
            "(default: most-recent in ~/.claude/projects/<cwd-slug>/)"
        ),
    )
    parser.add_argument(
        "--model",
        default="claude-opus-4-7",
        choices=sorted(PRICING.keys()),
        help="Pricing model to apply (default: claude-opus-4-7)",
    )
    parser.add_argument(
        "--format",
        default="row",
        choices=["row", "json", "verbose", "commit-line"],
        help=(
            "Output format (default: row — markdown table row for cost-tracking.md)"
        ),
    )
    parser.add_argument(
        "--date",
        default=None,
        help="Override the date in `row` output (default: today, YYYY-MM-DD)",
    )
    args = parser.parse_args(argv)

    jsonl_path = resolve_session_jsonl(args.session_jsonl)
    if not jsonl_path.exists():
        print(
            f"error: session JSONL not found at {jsonl_path}", file=sys.stderr
        )
        return 1

    totals = sum_session_usage(jsonl_path)
    cost = compute_cost(totals, args.model)
    session_id_short = jsonl_path.stem[:8]

    if args.format == "json":
        out = {
            "session_id_short": session_id_short,
            "model": args.model,
            **totals,
            "cost_usd": round(cost, 4),
        }
        print(json.dumps(out, indent=2))
    elif args.format == "verbose":
        print(f"Session:                 {session_id_short}")
        print(f"Model:                   {args.model}")
        print(f"Orchestrator turns:      {totals['orchestrator_turns']}")
        print(f"Sidechain turns skipped: {totals['sidechain_turns_skipped']}")
        print(f"Input tokens:            {totals['input_tokens']:,}")
        print(f"Output tokens:           {totals['output_tokens']:,}")
        print(
            f"Cache creation tokens:   {totals['cache_creation_input_tokens']:,}"
        )
        print(f"Cache read tokens:       {totals['cache_read_input_tokens']:,}")
        print(f"Cost:                    ${cost:.4f}")
    elif args.format == "row":
        from datetime import date

        date_str = args.date or date.today().isoformat()
        print(
            f"| {date_str} | {session_id_short} | "
            f"{format_k(totals['input_tokens'])} | "
            f"{format_k(totals['output_tokens'])} | "
            f"{format_k(totals['cache_creation_input_tokens'])} | "
            f"{format_k(totals['cache_read_input_tokens'])} | "
            f"${cost:.2f} |"
        )
    else:  # commit-line
        print(
            f"Tokens: in={format_k(totals['input_tokens'])} "
            f"out={format_k(totals['output_tokens'])} "
            f"cc={format_k(totals['cache_creation_input_tokens'])} "
            f"cr={format_k(totals['cache_read_input_tokens'])} "
            f"-> ${cost:.2f}"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
