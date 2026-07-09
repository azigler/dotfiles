#!/usr/bin/env python3
"""recall-distill helper — surface candidate durable-learning turns for the tick.

Spec: ``explore-76oc`` §4.4 (Phase 4). This is the **deterministic** half of the
``recall-distill`` learning loop. It does the mechanical work — window selection,
signal-pattern grepping (via ``/recall``), and dedupe — and emits candidate turns
as JSON. It makes **no judgment** about whether a candidate is a durable learning
and it files **nothing**: the LLM tick reads this output, judges conservatively,
and files human-gated proposal beads. This helper NEVER writes MEMORY.md.

Pipeline (matches the deliverable contract):
  (i)  list the sessions in scope NEWER than a ``--since`` timestamp (a session is
       in-window if ANY of its files was modified after ``since``; session-level
       so a learning stated early in a long, still-active session is not missed);
  (ii) run ``recall.py`` once per curated learning-signal pattern (regex, over the
       current slug only — the confidential-safe MVP scope);
  (iii) aggregate + dedupe the hits (a turn matched by N patterns collapses to ONE
       candidate carrying all N signal labels), window- and role-filter them, cap
       the count, and emit them as a JSON object for the tick to review.

Determinism: no wall clock is consulted when ``--since`` is given (tests always
pass it); the only clock use is the first-run default lookback when ``--since`` is
omitted. The projects root AND the recall.py path are overridable (``--root`` /
``CLAUDE_PROJECTS_ROOT`` and ``--recall`` / ``RECALL_DISTILL_RECALL``) so the whole
pipeline runs against a fixture tree in tests.

Exit: 0 = ran and emitted JSON (candidates may be empty — a valid quiet run);
2 = error (bad root, unparseable ``--since``, recall.py not found, or a recall
failure). The tick always parses stdout as JSON on exit 0.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

# --------------------------------------------------------------------------- #
# Tunables
# --------------------------------------------------------------------------- #
DEFAULT_RECALL_PATH = (
    Path.home() / ".claude" / "skills" / "recall" / "recall.py"
)
DEFAULT_LOOKBACK_DAYS = (
    7  # first-run bounded window (spec §4.4a) — no all-history sweep
)
DEFAULT_MAX_CANDIDATES = (
    200  # token-blowout guard: cap what one run hands the tick
)
CANDIDATE_TEXT_LIMIT = (
    600  # trim each candidate's text; the tick re-recalls for full
)

# Only conversational turns carry durable learnings. tool-result / unrenderable /
# structural-type hits are dropped up front — a user correction or stated
# preference lives in a user/assistant turn, never in raw tool output.
CANDIDATE_ROLES = frozenset({"user", "assistant"})


@dataclass(frozen=True)
class Signal:
    """A learning-signal pattern: a regex whose matches mark a turn as a *candidate*
    durable learning (NOT a confirmed one — the tick judges). ``name`` labels the
    candidate; ``rationale`` documents WHY this shape of turn tends to encode a
    reusable learning worth a MEMORY entry."""

    name: str
    pattern: str
    rationale: str


# The curated signal set. Deliberately RECALL-biased (favor surfacing over
# precision): a missed learning is worse than a noisy candidate, because the tick
# is a conservative human-gated filter downstream. Each pattern is a simple,
# linear (ReDoS-safe) case-insensitive alternation grounded in how the harness's
# own durable learnings actually read in the MEMORY tier.
SIGNALS: list[Signal] = [
    Signal(
        "correction",
        r"(?i)(\bactually,|\bno,? +(that|you|it|we|i|don|do not|not)\b|"
        r"that'?s +(wrong|not right|incorrect)|not what i +(meant|asked|wanted|said)|"
        r"\binstead of\b|you keep\b|stop +(doing|using|adding|calling)|"
        r"\bdon'?t +(do|use|ever|say|call|add|write|run|create)\b)",
        "A user correcting the agent is the single highest-signal durable-learning "
        "source: a correction that must never recur is exactly what a feedback_* "
        "MEMORY entry crystallizes (most of the memory tier is corrections).",
    ),
    Signal(
        "preference",
        r"(?i)(\bi +(prefer|like|want|always|never)\b|always +(use|do|prefer|run|write)|"
        r"from now on|going forward|in +(the +)?future|please +(always|don'?t|never|make sure)|"
        r"make sure +(to|you)|remember to|\bmy preference\b)",
        "Explicitly stated preferences ('always X', 'from now on Y') are durable by "
        "definition — they generalize across sessions, which is the whole point of "
        "the always-loaded memory tier.",
    ),
    Signal(
        "gotcha",
        r"(?i)(\bgotcha\b|\bfootgun\b|\bcaveat\b|\bpitfall\b|watch out|"
        r"the +(trick|catch) +is|\bsilently\b|bit me|caught me|\bbeware\b|the hard way)",
        "Hard-won gotchas / footguns save the most future time; they read as "
        "'footgun', 'silently', 'the trick is', 'bit me the hard way' — exactly the "
        "one-liners the memory tier exists to preserve.",
    ),
    Signal(
        "confirmed",
        r"(?i)(\bconfirmed\b|\bverified\b|that +(worked|fixed it)|works now|"
        r"the fix +(was|is)|root cause|\bTIL\b|learned that|turns out the)",
        "A validated approach or confirmed root-cause is a reusable 'confirmed-"
        "approach' learning worth recording so it is not rediscovered next session.",
    ),
    Signal(
        "rule",
        r"(?i)(the +(rule|convention|policy|invariant|decision) +is|by convention|"
        r"\bwe decided\b|standard +(is|practice)|must +(always|never)|as a +(rule|convention))",
        "Explicit rules / conventions / decisions ('the convention is', 'we decided') "
        "are the crystallized form a MEMORY entry ultimately takes.",
    ),
]


class DistillError(Exception):
    """A recoverable error that maps to exit code 2 (bad recall run / bad input)."""


# --------------------------------------------------------------------------- #
# Time + slug helpers
# --------------------------------------------------------------------------- #
def parse_since(value: str) -> datetime:
    """Parse an ISO-8601 ``--since`` (``2026-07-01T00:00:00Z`` or a bare
    ``2026-07-01``) into an aware UTC datetime. Raises ``ValueError`` on garbage."""
    s = value.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        # bare date -> midnight UTC
        dt = datetime.fromisoformat(s + "T00:00:00+00:00")
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt


def iso_z(dt: datetime) -> str:
    """Render an aware datetime as a ``...Z`` UTC ISO string."""
    return dt.astimezone(UTC).isoformat().replace("+00:00", "Z")


def current_slug_from_cwd() -> str:
    """Claude keys projects by a cwd-derived slug (mirror of recall.py):
    '/home/ubuntu/explore' -> '-home-ubuntu-explore'."""
    return re.sub(r"[^A-Za-z0-9]", "-", os.getcwd())


def resolve_root(arg_root: str | None) -> Path:
    if arg_root is not None:
        return Path(arg_root)
    env_root = os.environ.get("CLAUDE_PROJECTS_ROOT")
    if env_root:
        return Path(env_root)
    return Path.home() / ".claude" / "projects"


def resolve_recall(arg_recall: str | None) -> Path:
    if arg_recall is not None:
        return Path(arg_recall)
    env_recall = os.environ.get("RECALL_DISTILL_RECALL")
    if env_recall:
        return Path(env_recall)
    return DEFAULT_RECALL_PATH


# --------------------------------------------------------------------------- #
# Window selection (session-level, by file mtime)
# --------------------------------------------------------------------------- #
def session_id_of(slug_dir: Path, f: Path) -> str:
    """The session id recall.py would emit for ``f`` — mirror of recall's
    ``session_of``: the file stem for a top-level log, else the first path
    component (the ``<uuid>`` dir that owns the subagent / tool-result)."""
    rel = f.relative_to(slug_dir)
    parts = rel.parts
    return f.stem if len(parts) == 1 else parts[0]


def scan_window(
    root: Path, slug: str, since_epoch: float
) -> tuple[set[str], set[str]]:
    """Return ``(all_sessions, in_window_sessions)`` for ``slug``. A session is
    in-window if ANY of its files (main jsonl, subagent jsonl, or tool-results txt)
    has mtime >= ``since_epoch`` — session-level so a still-active long session is
    scanned in full."""
    slug_dir = root / slug
    all_sessions: set[str] = set()
    in_window: set[str] = set()
    if not slug_dir.is_dir():
        return all_sessions, in_window

    def consider(p: Path) -> None:
        sid = session_id_of(slug_dir, p)
        all_sessions.add(sid)
        try:
            if p.stat().st_mtime >= since_epoch:
                in_window.add(sid)
        except OSError:
            pass

    for p in slug_dir.rglob("*.jsonl"):
        if p.is_file():
            consider(p)
    for p in slug_dir.rglob("*.txt"):
        if p.is_file() and p.parent.name == "tool-results":
            consider(p)
    return all_sessions, in_window


# --------------------------------------------------------------------------- #
# recall.py subprocess bridge
# --------------------------------------------------------------------------- #
def run_recall(
    recall_path: Path, python: str, pattern: str, slug: str, root: Path
) -> list[dict]:
    """Invoke ``recall.py`` for one signal pattern over ``slug`` and return its
    ``--json`` hits. recall exit 1 (no hits) still prints ``[]`` -> empty list;
    exit 2 (recall error) -> ``DistillError``."""
    cmd = [
        python,
        str(recall_path),
        pattern,
        "--regex",
        f"--slug={slug}",
        "--json",
        f"--root={root}",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode == 2:
        raise DistillError(
            f"recall.py failed (exit 2) for pattern {pattern!r}: "
            f"{proc.stderr.strip() or '(no stderr)'}"
        )
    out = (proc.stdout or "").strip()
    if not out:
        return []
    try:
        data = json.loads(out)
    except json.JSONDecodeError as exc:
        raise DistillError(f"recall.py emitted invalid JSON: {exc}") from exc
    if not isinstance(data, list):
        raise DistillError("recall.py --json did not emit a JSON array")
    return data


# --------------------------------------------------------------------------- #
# Candidate gathering (grep -> window/role filter -> dedupe -> cap)
# --------------------------------------------------------------------------- #
def _trim(text: str) -> str:
    if len(text) > CANDIDATE_TEXT_LIMIT:
        return text[:CANDIDATE_TEXT_LIMIT] + "…"
    return text


def gather_candidates(
    root: Path,
    slug: str,
    since_epoch: float,
    recall_path: Path,
    python: str,
    max_candidates: int,
) -> tuple[set[str], set[str], list[dict], bool]:
    """Run every signal pattern, then window- + role-filter and dedupe the hits.

    Dedupe key is ``(session, line)``: a turn matched by multiple signals collapses
    to ONE candidate whose ``signals`` list carries every matching signal name."""
    all_sessions, in_window = scan_window(root, slug, since_epoch)

    agg: dict[tuple[str, object], dict] = {}
    for sig in SIGNALS:
        for hit in run_recall(recall_path, python, sig.pattern, slug, root):
            if hit.get("role") not in CANDIDATE_ROLES:
                continue
            session = hit.get("session")
            if session not in in_window:
                continue
            key = (session, hit.get("line"))
            entry = agg.get(key)
            if entry is None:
                entry = {
                    "slug": hit.get("slug", slug),
                    "session": session,
                    "ts": hit.get("ts", ""),
                    "role": hit.get("role"),
                    "line": hit.get("line"),
                    "text": _trim(hit.get("text") or ""),
                    "signals": set(),
                }
                agg[key] = entry
            entry["signals"].add(sig.name)

    candidates: list[dict] = []
    for entry in agg.values():
        out = dict(entry)
        out["signals"] = sorted(entry["signals"])
        candidates.append(out)

    candidates.sort(
        key=lambda c: (
            str(c["session"]),
            c["line"] if isinstance(c["line"], int) else 0,
        )
    )
    truncated = len(candidates) > max_candidates
    if truncated:
        candidates = candidates[:max_candidates]
    return all_sessions, in_window, candidates, truncated


def build_output(
    slug: str,
    since_dt: datetime,
    all_sessions: set[str],
    in_window: set[str],
    candidates: list[dict],
    truncated: bool,
) -> dict:
    return {
        "since": iso_z(since_dt),
        "slug": slug,
        "scanned_sessions": len(all_sessions),
        "window_sessions": len(in_window),
        "n_candidates": len(candidates),
        "truncated": truncated,
        "candidates": candidates,
    }


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="distill.py",
        description=(
            "Surface candidate durable-learning turns for the recall-distill tick "
            "(spec explore-76oc §4.4). Propose-only: emits candidates, files nothing."
        ),
    )
    p.add_argument(
        "--since",
        default=None,
        help="ISO-8601 window start (e.g. 2026-07-01T00:00:00Z). The tick derives "
        "it from the ledger (last run's ts). Omitted -> first-run lookback.",
    )
    p.add_argument(
        "--lookback-days",
        type=int,
        default=DEFAULT_LOOKBACK_DAYS,
        help=f"first-run bounded window when --since is omitted (default {DEFAULT_LOOKBACK_DAYS})",
    )
    p.add_argument(
        "--slug",
        default=None,
        help="slug to scan (bind with '=': slugs start with '-'). Default: current "
        "slug from cwd. Confidential-safe MVP: current slug ONLY, no cross-slug mode.",
    )
    p.add_argument(
        "--max-candidates",
        type=int,
        default=DEFAULT_MAX_CANDIDATES,
        help=f"cap candidates emitted per run (default {DEFAULT_MAX_CANDIDATES})",
    )
    p.add_argument(
        "--root",
        default=None,
        help="projects root (overrides CLAUDE_PROJECTS_ROOT; default ~/.claude/projects)",
    )
    p.add_argument(
        "--recall",
        default=None,
        help="path to recall.py (overrides RECALL_DISTILL_RECALL; default "
        "~/.claude/skills/recall/recall.py)",
    )
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    root = resolve_root(args.root)
    if not root.is_dir():
        sys.stderr.write(
            f"distill: projects root does not exist or is not a directory: {root}\n"
        )
        return 2

    recall_path = resolve_recall(args.recall)
    if not recall_path.is_file():
        sys.stderr.write(
            f"distill: recall.py not found at {recall_path} "
            "(set --recall or RECALL_DISTILL_RECALL)\n"
        )
        return 2

    if args.since is not None:
        try:
            since_dt = parse_since(args.since)
        except ValueError:
            sys.stderr.write(f"distill: unparseable --since: {args.since!r}\n")
            return 2
    else:
        since_dt = datetime.now(UTC) - timedelta(days=args.lookback_days)

    slug = args.slug or current_slug_from_cwd()

    try:
        all_sessions, in_window, candidates, truncated = gather_candidates(
            root,
            slug,
            since_dt.timestamp(),
            recall_path,
            sys.executable,
            args.max_candidates,
        )
    except DistillError as exc:
        sys.stderr.write(f"distill: {exc}\n")
        return 2

    out = build_output(
        slug, since_dt, all_sessions, in_window, candidates, truncated
    )
    sys.stdout.write(json.dumps(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
