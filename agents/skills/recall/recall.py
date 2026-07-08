#!/usr/bin/env python3
"""/recall — grep + expand over Claude Code transcript JSONL and tool-results.

Spec: explore-76oc §4.2 (Phase 2). Reads local ``~/.claude/projects`` files
directly (D6 — independent of any vault) and **fails LOUD** on any matched line
it cannot fully surface (D7): unparseable JSON, a non-UTF8 decode error, a
byte-capped huge line, or a genuinely-unknown record schema (true drift) —
never a silent drop. A silently-incomplete recall would feed the harness a
false-complete history, exactly the failure mode the fail-loud thesis targets.

Algorithm (§4.2):
  * grep the RAW bytes FIRST (drift-robust), parse SECOND;
  * Scope-A coverage per slug: recursive ``**/*.jsonl`` (main + subagents) plus
    ``**/tool-results/*.txt``;
  * two render paths — JSON turn for ``*.jsonl``, raw text for tool-results;
  * type-keyed render (OQ-D1): conversational turns render ``message.content[]``
    (a block list OR a bare string); non-conversational records with known
    text-bearing fields (ai-title / last-prompt / custom-title / system /
    queue-operation / attachment / file-history-snapshot / ...) render keyed by
    ``type``; only a genuinely-UNKNOWN type (or a conversational turn whose
    content truly can't be extracted) goes LOUD, so the loud channel stays a
    real schema-drift detector rather than a flood of known structural records;
  * tolerate a trailing partial last line ONLY for the active session file
    (newest-mtime ``*.jsonl`` in scope — OQ-D4);
  * huge-line cap with a visible truncation marker (OQ-D2);
  * substring match by default, ``--regex`` opt-in with a ReDoS guard that
    bounds each line AND aborts the whole run once a line hits the budget (so a
    pathological pattern aborts loudly instead of grinding for hours).

Contract for callers: exit 0 = >=1 hit, 1 = no hits, 2 = error;
``--json`` emits a JSON array of ``{slug, session, ts, role, line, text}``
(matched-but-unrenderable drift lines appear with ``role="unrenderable"``).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import sys
from dataclasses import dataclass
from pathlib import Path

# --------------------------------------------------------------------------- #
# Tunables (env-overridable where the spec/tests require it)
# --------------------------------------------------------------------------- #
DEFAULT_MAX_LINE_BYTES = (
    256 * 1024
)  # OQ-D2: sane per-line cap; RECALL_MAX_LINE_BYTES overrides
REGEX_LINE_BUDGET_S = 2.0  # OQ-D7: per-line ReDoS wall-clock guard
LOUD_FULL_LIMIT = 2000  # show a whole raw line loudly below this; else a window
JSON_LOUD_TEXT_LIMIT = 8192  # cap the raw text carried in a --json drift entry
READ_CHUNK = 1 << 16  # streaming read block (never slurp whole huge files)

# SIGALRM is the only reliable way to interrupt a catastrophic C-level regex in
# CPython (verified: it does interrupt `re` mid-backtrack). Absent on non-Unix.
_ALARM = hasattr(signal, "SIGALRM")

# Content-block types we recognize inside a conversational message.content[].
# A turn whose blocks are ALL recognized but yield no text (e.g. a
# signature-only redacted_thinking block) is a legitimate empty turn, quietly
# skipped — NOT flagged as drift.
RECOGNIZED_BLOCK_TYPES = frozenset(
    {
        "text",
        "thinking",
        "redacted_thinking",
        "tool_use",
        "tool_result",
        "image",
        "document",
    }
)

# Non-conversational top-level record types and the field(s) (in priority
# order) that carry their human-relevant text. Grounded in the live corpus
# (2026-07-07): these render as hits keyed by `type` so a raw match on a known
# structural record surfaces as a searchable hit instead of flooding the loud
# drift channel. A type absent from this map (and not message-form) is treated
# as genuine schema drift -> LOUD.
KNOWN_TYPE_FIELDS: dict[str, tuple[str, ...]] = {
    "ai-title": ("aiTitle",),
    "custom-title": ("customTitle",),
    "last-prompt": ("lastPrompt",),
    "queue-operation": ("content",),
    "system": ("content", "subtype"),
    "attachment": ("attachment",),
    "file-history-snapshot": ("snapshot",),
    "progress": ("data", "content"),
    "summary": ("summary",),
    "mode": ("mode",),
    "permission-mode": ("permissionMode",),
    "bridge-session": ("bridgeSessionId",),
    # PR/agent metadata records (present in bulk on the real corpus — pr-link 1268,
    # agent-setting 207, agent-name 108): render their searchable text as hits, not drift.
    "pr-link": ("prUrl", "prRepository"),
    "agent-name": ("agentName",),
    "agent-setting": ("agentSetting",),
    # Subagent-workflow journal records (<uuid>/subagents/workflows/*/journal.jsonl):
    # `result` carries the delegated agent's finding text; `started` is a marker.
    "result": ("result",),
    "started": ("key",),
}

# Sentinel: a recognized-but-textless record — quietly skip (not a hit, not loud).
SKIP = object()


class ReDoSAbort(Exception):
    """Raised from the SIGALRM handler to break a runaway regex evaluation."""


class GuardTripped(Exception):
    """Raised to abort the WHOLE run once the ReDoS per-line budget is hit."""


def _alarm_handler(_signum, _frame):
    raise ReDoSAbort()


@dataclass
class Hit:
    slug: str
    session: str
    ts: str
    role: str
    line: int
    text: str


# --------------------------------------------------------------------------- #
# Matching (raw-first) + ReDoS-guarded regex
# --------------------------------------------------------------------------- #
class Matcher:
    """Substring-on-bytes by default; ReDoS-guarded regex-on-text with --regex."""

    def __init__(self, query: str, regex: bool):
        self.query = query
        self.regex = regex
        self.qbytes = query.encode("utf-8")
        self.guard_fired = False
        self.pattern = re.compile(query) if regex else None

    def _guarded_search(self, s: str):
        if _ALARM:
            signal.setitimer(signal.ITIMER_REAL, REGEX_LINE_BUDGET_S)
        try:
            return self.pattern.search(s)
        except ReDoSAbort:
            # F1: bound each line AND abort the whole run — a pathological
            # pattern otherwise costs (per-line budget * N lines) = hours.
            self.guard_fired = True
            raise GuardTripped() from None
        finally:
            if _ALARM:
                signal.setitimer(signal.ITIMER_REAL, 0)

    def matches(self, raw: bytes) -> bool:
        if not self.regex:
            return self.qbytes in raw
        return self._guarded_search(raw.decode("utf-8", "replace")) is not None

    def offset(self, s: str) -> int:
        """Char offset of the match in ``s`` (for centering a loud snippet)."""
        if self.regex:
            m = self._guarded_search(s)
            return m.start() if m else 0
        i = s.find(self.query)
        return i if i >= 0 else 0


# --------------------------------------------------------------------------- #
# Streaming line reader with a hard per-line byte cap (OQ-D2)
# --------------------------------------------------------------------------- #
def stream_lines(path: Path, cap: int):
    """Yield ``(lineno, raw_bytes, truncated, had_newline)`` for ``path``.

    ``raw_bytes`` is capped at ``cap`` bytes; ``truncated`` is True when the
    physical line exceeded the cap (its tail is read-and-discarded, never held
    in memory — no OOM on a 64 MB inlined tool-result). ``had_newline`` is False
    only for a final line lacking a trailing newline (a live-tail partial).
    """
    lineno = 0
    buf = bytearray()
    truncated = False
    over = False  # past the cap for the current line -> discarding its tail
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(READ_CHUNK)
            if not chunk:
                break
            start = 0
            while True:
                nl = chunk.find(b"\n", start)
                if nl == -1:
                    seg = chunk[start:]
                    if not over:
                        space = cap - len(buf)
                        if len(seg) > space:
                            buf += seg[: max(space, 0)]
                            truncated = True
                            over = True
                        else:
                            buf += seg
                    break
                seg = chunk[start:nl]
                if not over:
                    space = cap - len(buf)
                    if len(seg) > space:
                        buf += seg[: max(space, 0)]
                        truncated = True
                    else:
                        buf += seg
                lineno += 1
                yield lineno, bytes(buf), truncated, True
                buf = bytearray()
                truncated = False
                over = False
                start = nl + 1
        if buf or over or truncated:
            lineno += 1
            yield lineno, bytes(buf), truncated, False


# --------------------------------------------------------------------------- #
# Type-keyed render (OQ-D1)
# --------------------------------------------------------------------------- #
def _stringify(value) -> str:
    if isinstance(value, str):
        return value
    if value is None:
        return ""
    try:
        return json.dumps(value, ensure_ascii=False)
    except (TypeError, ValueError):
        return str(value)


def extract_text(content) -> str | None:
    """Pull renderable text out of a ``message.content`` — a block list OR a
    bare string (both real-corpus shapes)."""
    if content is None:
        return None
    if isinstance(content, str):
        return content or None
    if isinstance(content, list):
        parts: list[str] = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
                continue
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "text" and isinstance(block.get("text"), str):
                parts.append(block["text"])
            elif btype == "thinking" and isinstance(block.get("thinking"), str):
                # F4: render thinking cleartext so a thinking-only turn is searchable.
                parts.append(block["thinking"])
            elif btype == "redacted_thinking":
                # F4: signature-only encrypted block — no cleartext to render.
                continue
            elif btype == "tool_use":
                parts.append(
                    f"[tool_use {block.get('name', '')}] "
                    + _stringify(block.get("input"))
                )
            elif btype == "tool_result":
                parts.append(
                    "[tool_result] " + _stringify(block.get("content"))
                )
            elif isinstance(block.get("text"), str):
                parts.append(block["text"])
        joined = " ".join(p for p in parts if p)
        return joined or None
    return None


def _all_blocks_recognized(content) -> bool:
    """True if ``content`` is a recognized-but-textless conversational payload
    (empty / null / a list of only recognized block types) — a legitimate empty
    turn to skip, not schema drift to alarm on."""
    if content is None or content == "":
        return True
    if isinstance(content, list):
        for block in content:
            if isinstance(block, str):
                continue
            if (
                isinstance(block, dict)
                and block.get("type") in RECOGNIZED_BLOCK_TYPES
            ):
                continue
            return False
        return True
    return False


def _known_type_text(rec: dict, rtype: str) -> str | None:
    fields = KNOWN_TYPE_FIELDS.get(rtype)
    if fields is None:
        return None
    parts = [_stringify(rec[f]) for f in fields if rec.get(f) not in (None, "")]
    text = " ".join(p for p in parts if p)
    if text:
        return text
    # Known type but its text fields are absent (a raw match on an id, say):
    # still render — never drop — but make it obviously the whole record.
    return _stringify(rec)


def render_by_type(rec):
    """Classify a parsed record. Returns one of:

      * ``(role, text)`` — a renderable hit;
      * ``SKIP``         — recognized-but-textless (quietly skipped, F4);
      * ``None``         — genuine schema drift (surfaced LOUDLY, D7).

    Records are keyed by top-level ``type``; conversational turns carry a
    ``message`` with ``role`` + ``content``; other known types carry their text
    in top-level fields (KNOWN_TYPE_FIELDS)."""
    if not isinstance(rec, dict):
        return None
    msg = rec.get("message")
    if isinstance(msg, dict):
        text = extract_text(msg.get("content"))
        role = msg.get("role") or rec.get("type") or "unknown"
        if text:
            return str(role), text
        if _all_blocks_recognized(msg.get("content")):
            return SKIP
        return None  # conversational shape but truly unextractable -> drift
    rtype = rec.get("type")
    if isinstance(rtype, str):
        text = _known_type_text(rec, rtype)
        if text is not None:
            return rtype, text
    return None  # unknown, non-message type -> drift (LOUD)


# --------------------------------------------------------------------------- #
# Output collector
# --------------------------------------------------------------------------- #
class Collector:
    def __init__(self, as_json: bool):
        self.as_json = as_json
        self.hits: list[dict] = []
        self.n_hits = 0
        self.n_loud = 0

    def hit(self, h: Hit) -> None:
        self.n_hits += 1
        obj = {
            "slug": h.slug,
            "session": h.session,
            "ts": h.ts,
            "role": h.role,
            "line": h.line,
            "text": h.text,
        }
        if self.as_json:
            self.hits.append(obj)
        else:
            sys.stdout.write(
                f"{obj['slug']}  {obj['session']}  L{obj['line']}  "
                f"{obj['ts']}  [{obj['role']}]  {obj['text']}\n"
            )

    def loud(
        self,
        path: Path,
        lineno: int,
        raw: bytes,
        reason: str,
        matcher: Matcher,
        slug: str,
        session: str,
    ) -> None:
        """D7: a matched line we can't fully surface goes LOUDLY to stderr with
        its raw content, AND (F2) into the --json array as ``role="unrenderable"``
        — so a caller reading only the json channel can't be handed a
        false-complete result. Still counts as a hit for the exit code."""
        self.n_loud += 1
        s = raw.decode("utf-8", "replace")
        if len(s) <= LOUD_FULL_LIMIT:
            shown = s
        else:
            pos = matcher.offset(s)
            a = max(0, pos - 200)
            b = min(len(s), pos + 400)
            shown = s[a:b]
            if a > 0:
                shown = "…" + shown
            if b < len(s):
                shown = shown + "…"
        sys.stderr.write(
            f"recall[incomplete:{reason}] {path}:{lineno}: {shown} [raw]\n"
        )
        if self.as_json:
            json_text = (
                s
                if len(s) <= JSON_LOUD_TEXT_LIMIT
                else s[:JSON_LOUD_TEXT_LIMIT] + "…"
            )
            self.hits.append(
                {
                    "slug": slug,
                    "session": session,
                    "ts": "",
                    "role": "unrenderable",
                    "line": lineno,
                    "text": json_text,
                }
            )

    def finish(self) -> None:
        if self.as_json:
            sys.stdout.write(json.dumps(self.hits) + "\n")

    def exit_code(self) -> int:
        return 0 if (self.n_hits + self.n_loud) > 0 else 1


# --------------------------------------------------------------------------- #
# Per-line rendering of a matched line
# --------------------------------------------------------------------------- #
def render_matched_jsonl(
    col: Collector,
    matcher: Matcher,
    path: Path,
    slug: str,
    session: str,
    lineno: int,
    raw: bytes,
    truncated: bool,
    had_newline: bool,
    is_active: bool,
    is_context: bool,
) -> None:
    # OQ-D4: a trailing partial (no newline) is a live-tail write-in-flight only
    # for the active session file — tolerate it silently. A partial last line in
    # any OTHER file is real corruption -> loud.
    if not had_newline:
        if is_active or is_context:
            return
        col.loud(path, lineno, raw, "partial-last-line", matcher, slug, session)
        return

    # OQ-D5: a non-UTF8 line is loud + raw-surfaced, never an errors='ignore' skip.
    try:
        s = raw.decode("utf-8")
    except UnicodeDecodeError:
        if is_context:
            return
        col.loud(
            path, lineno, raw, "decode-error-non-utf8", matcher, slug, session
        )
        return

    try:
        rec = json.loads(s)
    except (json.JSONDecodeError, ValueError):
        if is_context:
            return
        reason = (
            "truncated-line-exceeds-cap" if truncated else "unparseable-json"
        )
        col.loud(path, lineno, raw, reason, matcher, slug, session)
        return

    rendered = render_by_type(rec)
    if rendered is SKIP:
        # Recognized-but-textless (e.g. a signature-only redacted_thinking turn):
        # quietly skipped — not a hit, not a false drift alarm.
        return
    if rendered is None:
        # OQ-D1: a genuinely-unknown schema is the real silent-miss -> LOUD.
        if is_context:
            return
        col.loud(
            path, lineno, raw, "unrenderable-schema", matcher, slug, session
        )
        return

    role, text = rendered
    ts = rec.get("timestamp") or ""
    if truncated:
        text = text + " …[truncated]"
    col.hit(Hit(slug, session, str(ts), role, lineno, text))


def render_matched_txt(
    col: Collector,
    path: Path,
    slug: str,
    session: str,
    lineno: int,
    raw: bytes,
    truncated: bool,
) -> None:
    text = raw.decode("utf-8", "replace")
    if truncated:
        text = text + " …[truncated]"
    col.hit(Hit(slug, session, "", "tool-result", lineno, text))


# --------------------------------------------------------------------------- #
# Per-file processing (with --expand support)
# --------------------------------------------------------------------------- #
def process_file(
    col: Collector,
    matcher: Matcher,
    path: Path,
    slug: str,
    session: str,
    cap: int,
    expand: int,
    is_active: bool,
) -> None:
    is_txt = path.suffix == ".txt"

    if is_txt:
        for lineno, raw, truncated, _nl in stream_lines(path, cap):
            if matcher.matches(raw):
                render_matched_txt(
                    col, path, slug, session, lineno, raw, truncated
                )
        return

    if expand <= 0:
        for lineno, raw, truncated, had_nl in stream_lines(path, cap):
            if matcher.matches(raw):
                render_matched_jsonl(
                    col,
                    matcher,
                    path,
                    slug,
                    session,
                    lineno,
                    raw,
                    truncated,
                    had_nl,
                    is_active,
                    is_context=False,
                )
        return

    # --expand N: include +/-N surrounding turns from THIS file only, in order.
    entries = list(stream_lines(path, cap))
    matched = {e[0] for e in entries if matcher.matches(e[1])}
    if not matched:
        return
    max_line = len(entries)
    want: set[int] = set()
    for center in matched:
        for ln in range(
            max(1, center - expand), min(max_line, center + expand) + 1
        ):
            want.add(ln)
    for lineno, raw, truncated, had_nl in entries:
        if lineno not in want:
            continue
        render_matched_jsonl(
            col,
            matcher,
            path,
            slug,
            session,
            lineno,
            raw,
            truncated,
            had_nl,
            is_active,
            is_context=(lineno not in matched),
        )


# --------------------------------------------------------------------------- #
# Scope + file discovery (Scope A, recursive)
# --------------------------------------------------------------------------- #
def slug_files(slug_dir: Path) -> list[Path]:
    """Scope A for one slug: recursive main+subagent jsonl + tool-results txt."""
    if not slug_dir.is_dir():
        return []
    files: list[Path] = []
    for p in slug_dir.rglob("*.jsonl"):
        if p.is_file():
            files.append(p)
    for p in slug_dir.rglob("*.txt"):
        if p.is_file() and p.parent.name == "tool-results":
            files.append(p)
    return files


def session_of(slug_dir: Path, f: Path) -> str:
    rel = f.relative_to(slug_dir)
    parts = rel.parts
    if len(parts) == 1:
        return f.stem
    return parts[0]


def current_slug_from_cwd() -> str:
    """Claude keys projects by a cwd-derived slug: '/home/ubuntu/explore' ->
    '-home-ubuntu-explore' (non-alphanumerics become '-')."""
    return re.sub(r"[^A-Za-z0-9]", "-", os.getcwd())


def resolve_root(arg_root: str | None) -> Path:
    if arg_root is not None:
        return Path(arg_root)
    env_root = os.environ.get("CLAUDE_PROJECTS_ROOT")
    if env_root:
        return Path(env_root)
    return Path.home() / ".claude" / "projects"


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="recall.py",
        description="grep + expand over Claude Code transcripts (spec explore-76oc §4.2)",
    )
    p.add_argument(
        "query", help="substring (default) or regex (--regex) to search for"
    )
    p.add_argument(
        "--expand",
        type=int,
        default=0,
        metavar="N",
        help="include +/-N surrounding turns from the same file",
    )
    p.add_argument(
        "--regex",
        action="store_true",
        help="treat query as a regex (ReDoS-guarded)",
    )
    p.add_argument(
        "--all", action="store_true", help="search every slug under the root"
    )
    p.add_argument(
        "--slug",
        default=None,
        help="restrict to one slug (bind with '=': slugs start with '-')",
    )
    p.add_argument(
        "--json",
        action="store_true",
        help="emit a JSON array of {slug,session,ts,role,line,text}",
    )
    p.add_argument(
        "--root",
        default=None,
        help="projects root (overrides CLAUDE_PROJECTS_ROOT)",
    )
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if args.query == "":
        sys.stderr.write(
            "recall: refusing an empty query (would match everything)\n"
        )
        return 2

    root = resolve_root(args.root)
    if not root.is_dir():
        sys.stderr.write(
            f"recall: projects root does not exist or is not a directory: {root}\n"
        )
        return 2

    if args.all:
        slugs = sorted(d.name for d in root.iterdir() if d.is_dir())
    elif args.slug:
        slugs = [args.slug]
    else:
        slugs = [current_slug_from_cwd()]

    try:
        cap = int(
            os.environ.get("RECALL_MAX_LINE_BYTES", DEFAULT_MAX_LINE_BYTES)
        )
    except ValueError:
        cap = DEFAULT_MAX_LINE_BYTES
    if cap <= 0:
        cap = DEFAULT_MAX_LINE_BYTES

    try:
        matcher = Matcher(args.query, args.regex)
    except re.error as exc:
        sys.stderr.write(f"recall: invalid regex: {exc}\n")
        return 2

    # Collect (slug, file) pairs and identify the active session file (OQ-D4):
    # the newest-mtime *.jsonl across the searched scope.
    pairs: list[tuple[str, Path, Path]] = []  # (slug, slug_dir, file)
    active: Path | None = None
    best_mtime = -1.0
    for slug in slugs:
        slug_dir = root / slug
        for f in slug_files(slug_dir):
            pairs.append((slug, slug_dir, f))
            if f.suffix == ".jsonl":
                try:
                    m = f.stat().st_mtime
                except OSError:
                    continue
                if m > best_mtime:
                    best_mtime = m
                    active = f

    pairs.sort(key=lambda t: (t[0], str(t[2])))

    col = Collector(args.json)

    if args.regex and _ALARM:
        signal.signal(signal.SIGALRM, _alarm_handler)

    try:
        for slug, slug_dir, f in pairs:
            process_file(
                col,
                matcher,
                f,
                slug,
                session_of(slug_dir, f),
                cap,
                args.expand,
                is_active=(f == active),
            )
    except GuardTripped:
        # F1: a pathological --regex pattern hit the per-line budget. Bounding
        # each line still lets the run cost (budget * N lines) = hours, so abort
        # the whole run loudly rather than keep scanning.
        sys.stderr.write(
            "recall[regex-guard]: pattern too expensive (hit the per-line time "
            "budget); aborting the run (possible ReDoS). Narrow the pattern.\n"
        )
        return 2

    col.finish()
    return col.exit_code()


if __name__ == "__main__":
    sys.exit(main())
