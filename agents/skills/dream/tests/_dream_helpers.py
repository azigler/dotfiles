"""Shared builders + subprocess invoker for the recall-distill test suite.

The tests drive the REAL pipeline: they invoke ``distill.py`` via subprocess,
which in turn invokes the REAL ``recall.py`` — both steered at a FAKE fixture
projects tree via ``--root`` / ``--recall`` so nothing touches the live
``~/.claude/projects``. This mirrors recall's own fixture-first test style and
pins the true end-to-end contract, not a mocked one.

The transcript record builders reproduce the real corpus shape (spec §4.2 /
recall's ``_recall_helpers``): records are ``type``-keyed, role nested at
``message.role``, timestamp at top-level ``timestamp``, text in
``message.content`` as a typed-block list.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

# distill.py lives one dir up from tests/.
DISTILL_PY = Path(__file__).resolve().parents[1] / "distill.py"

# recall.py: the real one distill depends on. Overridable via RECALL_PY for CI /
# relocation; defaults to the global install. Tests skip if it is absent.
RECALL_PY = Path(
    os.environ.get(
        "RECALL_PY",
        str(Path.home() / ".claude" / "skills" / "recall" / "recall.py"),
    )
)

DEFAULT_TIMEOUT = 60  # two nested subprocess levels; generous but bounded


# --------------------------------------------------------------------------- #
# Record builders (deterministic — no wall clock)
# --------------------------------------------------------------------------- #
def ts(n: int) -> str:
    return f"2026-07-04T12:{(n // 60) % 60:02d}:{n % 60:02d}.000Z"


def assistant_turn(text: str, n: int = 0) -> dict:
    return {
        "type": "assistant",
        "uuid": f"asst-{n:04d}",
        "timestamp": ts(n),
        "message": {
            "role": "assistant",
            "content": [{"type": "text", "text": text}],
        },
    }


def user_turn(text: str, n: int = 0) -> dict:
    return {
        "type": "user",
        "uuid": f"user-{n:04d}",
        "timestamp": ts(n),
        "message": {
            "role": "user",
            "content": [{"type": "text", "text": text}],
        },
    }


def progress_line(text: str, n: int = 0) -> dict:
    """A non-conversational record — must never become a candidate (role filter)."""
    return {
        "type": "progress",
        "uuid": f"prog-{n:04d}",
        "timestamp": ts(n),
        "data": {"note": text},
    }


# --------------------------------------------------------------------------- #
# Filesystem layout writers (mirror ~/.claude/projects/<slug>/...)
# --------------------------------------------------------------------------- #
def jline(record: dict) -> bytes:
    return (json.dumps(record, separators=(",", ":")) + "\n").encode("utf-8")


def write_turns(path: Path, records) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as fh:
        for r in records:
            fh.write(jline(r))
    return path


def write_text(path: Path, body: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    return path


def main_path(
    root: Path, slug: str, session: str = "00000000-0000-0000-0000-000000000001"
) -> Path:
    return Path(root) / slug / f"{session}.jsonl"


def tool_result_path(
    root: Path,
    slug: str,
    session: str = "00000000-0000-0000-0000-000000000001",
    name: str = "foo.txt",
) -> Path:
    return Path(root) / slug / session / "tool-results" / name


def set_mtime(path: Path, epoch: float) -> None:
    """Pin a file's mtime so the window (since) filter is deterministic."""
    os.utime(path, (epoch, epoch))


# --------------------------------------------------------------------------- #
# Subprocess invoker
# --------------------------------------------------------------------------- #
class Result:
    def __init__(self, cp: subprocess.CompletedProcess):
        self.returncode = cp.returncode
        self.stdout = (cp.stdout or b"").decode("utf-8", "replace")
        self.stderr = (cp.stderr or b"").decode("utf-8", "replace")

    def json(self) -> dict:
        return json.loads(self.stdout)


def invoke(
    *flags: str,
    root: Path,
    recall: Path = RECALL_PY,
    timeout: int = DEFAULT_TIMEOUT,
) -> Result:
    args = [
        sys.executable,
        str(DISTILL_PY),
        *flags,
        f"--root={root}",
        f"--recall={recall}",
    ]
    cp = subprocess.run(args, capture_output=True, timeout=timeout, check=False)
    return Result(cp)
