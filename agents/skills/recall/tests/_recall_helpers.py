"""Shared fixtures/builders for the /recall test suite (spec explore-76oc §4.2/§5).

These helpers build a FAKE Claude Code projects tree in a tmp dir and drive
``recall.py`` via subprocess. Tests must NEVER touch the real
``~/.claude/projects`` — every invocation is steered at a fixture root via the
``--root`` flag and/or the ``CLAUDE_PROJECTS_ROOT`` env var (the testability
override the spec makes REQUIRED in §4.2).

Schema note (validated against the live corpus, 2026-07-07): transcript records
are keyed by a top-level ``type`` (``assistant`` / ``user`` / ``progress`` /
``file-history-snapshot`` / ``custom-title`` / ``system`` / ...), the role is
nested at ``message.role``, the timestamp is at top-level ``timestamp``, and the
text lives in ``message.content`` which is EITHER a list of typed blocks
(``{"type":"text","text":...}`` / ``tool_use`` / ``tool_result``) for assistant
turns OR a bare string for some user turns. The builders below reproduce that
variety so the tests pin the real contract, not a toy schema.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

# recall.py lives one directory up from this tests/ dir: .../recall/recall.py
# (the impl agent creates it; these tests invoke it there).
RECALL_PY = Path(__file__).resolve().parents[1] / "recall.py"

DEFAULT_TIMEOUT = (
    30  # seconds; also the anti-hang bound for the ReDoS/huge tests
)


# --------------------------------------------------------------------------- #
# Timestamp + record builders (deterministic — no wall clock)
# --------------------------------------------------------------------------- #
def ts(n: int) -> str:
    """Deterministic, strictly increasing ISO-8601 UTC timestamps."""
    return f"2026-07-07T12:{(n // 60) % 60:02d}:{n % 60:02d}.000Z"


def assistant_turn(text: str, n: int = 0, extra_blocks=None) -> dict:
    """An `assistant` turn: text lives in message.content[] as a text block."""
    blocks = [{"type": "text", "text": text}]
    if extra_blocks:
        blocks.extend(extra_blocks)
    return {
        "type": "assistant",
        "uuid": f"asst-{n:04d}",
        "timestamp": ts(n),
        "message": {"role": "assistant", "content": blocks},
    }


def user_turn(text: str, n: int = 0) -> dict:
    """A `user` turn with LIST content (the §4.2 content[] contract form)."""
    return {
        "type": "user",
        "uuid": f"user-{n:04d}",
        "timestamp": ts(n),
        "message": {
            "role": "user",
            "content": [{"type": "text", "text": text}],
        },
    }


def user_turn_str(text: str, n: int = 0) -> dict:
    """A `user` turn with STRING content — the OTHER real-corpus shape."""
    return {
        "type": "user",
        "uuid": f"userstr-{n:04d}",
        "timestamp": ts(n),
        "message": {"role": "user", "content": text},
    }


def progress_line(text: str, n: int = 0) -> dict:
    """A non-conversational `progress` record (no message.role / renderable text)."""
    return {
        "type": "progress",
        "uuid": f"prog-{n:04d}",
        "timestamp": ts(n),
        "data": {"note": text},
    }


def file_history_snapshot_line(text: str, n: int = 0) -> dict:
    return {
        "type": "file-history-snapshot",
        "isSnapshotUpdate": True,
        "snapshot": text,
        "messageId": f"fhs-{n}",
    }


def custom_title_line(text: str, n: int = 0) -> dict:
    return {"type": "custom-title", "title": text}


def unknown_schema_line(text: str, n: int = 0) -> dict:
    """VALID JSON, but a `type` the renderer won't recognize and no renderable
    message.content — must be surfaced LOUD (not silently dropped)."""
    return {"type": "mystery-vendor-x", "uuid": f"mys-{n:04d}", "payload": text}


# --------------------------------------------------------------------------- #
# Filesystem layout writers
# --------------------------------------------------------------------------- #
def jline(record: dict) -> bytes:
    """Serialize one record to a JSONL line (compact + trailing newline)."""
    return (json.dumps(record, separators=(",", ":")) + "\n").encode("utf-8")


def write_bytes(path: Path, *chunks: bytes) -> Path:
    """Write raw byte chunks verbatim (caller controls newlines)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as fh:
        for c in chunks:
            fh.write(c)
    return path


def write_turns(path: Path, records) -> Path:
    """Write a list of dict records as JSONL."""
    return write_bytes(path, *(jline(r) for r in records))


# Path helpers mirroring the real `~/.claude/projects/<slug>/...` layout.
def main_path(
    root: Path, slug: str, session: str = "00000000-0000-0000-0000-000000000001"
) -> Path:
    return Path(root) / slug / f"{session}.jsonl"


def subagent_path(
    root: Path,
    slug: str,
    session: str = "00000000-0000-0000-0000-000000000001",
    sub: str = "xyz",
) -> Path:
    return Path(root) / slug / session / "subagents" / f"{sub}.jsonl"


def tool_result_path(
    root: Path,
    slug: str,
    session: str = "00000000-0000-0000-0000-000000000001",
    name: str = "foo.txt",
) -> Path:
    return Path(root) / slug / session / "tool-results" / name


def slug_flag(slug: str) -> str:
    """Slugs begin with '-' (an argv footgun, OQ-E3) — always bind with '='."""
    return f"--slug={slug}"


# --------------------------------------------------------------------------- #
# Subprocess invoker
# --------------------------------------------------------------------------- #
class Result:
    """Decoded view of a recall.py run (bytes decoded with errors='replace' so a
    non-UTF8 payload in the child's output never breaks the test harness)."""

    def __init__(self, cp: subprocess.CompletedProcess):
        self.returncode = cp.returncode
        self.stdout_bytes = cp.stdout or b""
        self.stderr_bytes = cp.stderr or b""
        self.stdout = self.stdout_bytes.decode("utf-8", "replace")
        self.stderr = self.stderr_bytes.decode("utf-8", "replace")

    @property
    def combined(self) -> str:
        return self.stdout + "\n" + self.stderr


def invoke(
    query: str,
    flags=None,
    *,
    root_flag=None,
    env_root=None,
    unset_env=False,
    extra_env=None,
    timeout=DEFAULT_TIMEOUT,
    cwd=None,
) -> subprocess.CompletedProcess:
    flags = list(flags or [])
    env = os.environ.copy()

    # --- test safety: never let a run fall through to the real ~/.claude/projects
    if root_flag is None and (env_root is None or unset_env):
        raise RuntimeError(
            "test-safety: refusing to run recall without a fixture root"
        )

    if unset_env:
        env.pop("CLAUDE_PROJECTS_ROOT", None)
    elif env_root is not None:
        env["CLAUDE_PROJECTS_ROOT"] = str(env_root)
    if extra_env:
        env.update({k: str(v) for k, v in extra_env.items()})

    args = [sys.executable, str(RECALL_PY), query, *flags]
    if root_flag is not None:
        args.append(f"--root={root_flag}")

    return subprocess.run(
        args, capture_output=True, timeout=timeout, env=env, cwd=cwd
    )
