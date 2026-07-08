"""Shared fixtures/builders for the scrub.py test suite (Layer 0, explore-r2iq).

These helpers drive ``scrub.py`` via subprocess against a FAKE fixture tree in a
tmp dir (never a real ~/.claude / memory file), mirroring the /recall suite's
style. The module ALSO imports scrub.py directly so a handful of pure-function
guards (the allowlist, safe_rewrite's JSON-validity checks, the entropy filter)
can be asserted without a subprocess.

scrub.py CLI under test:
    scrub.py {scan,redact} <paths...> [--apply] [--exclude P] [--entropy]
                                      [--gitleaks] [--quiet]
Exit codes: 1 if any secret matched, 0 if clean.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

# scrub.py lives one directory up from this tests/ dir.
SCRUB_DIR = Path(__file__).resolve().parents[1]
SCRUB_PY = SCRUB_DIR / "scrub.py"
if str(SCRUB_DIR) not in sys.path:
    sys.path.insert(0, str(SCRUB_DIR))


DEFAULT_TIMEOUT = 60

# ---------------------------------------------------------------------------- #
# Canonical high-confidence secret literals — one per provider pattern. Each is
# shaped to satisfy the corresponding regex in scrub.PATTERNS. NOT real creds.
# ---------------------------------------------------------------------------- #
SECRETS = {
    "bearer-token": (
        "Bearer abcdefghijklmnopqrstuvwxyz0123456789ABCDEF"
    ),  # >=40 token chars
    "google-client-secret": "GOCSPX-abcdefghij0123456789KLmno",
    "google-refresh-token": "1//0abcdefghijklmnopqrstuvwxyz0123456789ABC",
    "google-api-key": "AIza0123456789abcdefghijklmnopqrstuvwxy",  # AIza + 35
    "github-token": "ghp_x8Kf2mNp9qRt3vWy7bZc1dEg5hJk4nAsBd",  # >=30 after ghp_
    "anthropic-key": "sk-ant-api03-abcdefghij0123456789KLMN",
    "openai-key": "sk-proj-abcdefghij0123456789KLMNopqr",
    "aws-akia": "AKIAABCDEFGHIJKLMNOP",  # AKIA + 16
    "slack-token": "xoxb-0123456789-abcdefABCDEF",
}

# A random-looking, high-entropy token with NO distinctive prefix: invisible to
# the default high-confidence scan, but the --entropy scan should surface it.
HIGH_ENTROPY_SECRET = "k3Jd8Fh2Lp0qWz7xYv4Bn6Mc1Ts9Rg5Ae2Uo0Ii8Nl"

# A benign 44-char Google Doc ID (starts with '1'), deliberately HIGH entropy so
# a naive entropy scan WOULD flag it — the allowlist must suppress it.
_HI = "aB3dE7gH1jK2mN5pQ8rS4tU6vW9xY0zAcDeFgHiJkLmNoPqRsTuVwXyZ"
GDOC_ID = "1" + _HI[:43]
assert len(GDOC_ID) == 44, len(GDOC_ID)

ENV_REF = "$OPENAI_API_KEY"
PATH_POINTER = "~/.secrets/openai.key"
GIT_SHA = "da39a3ee5e6b4b0d3255bfef95601890afd80709"
UUID = "550e8400-e29b-41d4-a716-446655440000"


# ---------------------------------------------------------------------------- #
# Filesystem writers
# ---------------------------------------------------------------------------- #
def write_text(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def jline(obj: dict) -> str:
    """One JSONL line (non-ASCII kept literal so U+2028/U+0085 land raw)."""
    return json.dumps(obj, ensure_ascii=False)


def write_jsonl(path: Path, records) -> Path:
    return write_text(path, "".join(jline(r) + "\n" for r in records))


# ---------------------------------------------------------------------------- #
# Subprocess invoker
# ---------------------------------------------------------------------------- #
class Result:
    def __init__(self, cp: subprocess.CompletedProcess):
        self.returncode = cp.returncode
        self.stdout = (cp.stdout or b"").decode("utf-8", "replace")
        self.stderr = (cp.stderr or b"").decode("utf-8", "replace")

    @property
    def combined(self) -> str:
        return self.stdout + "\n" + self.stderr


def invoke(
    mode: str,
    paths,
    flags=(),
    *,
    env=None,
    timeout=DEFAULT_TIMEOUT,
) -> Result:
    args = [sys.executable, str(SCRUB_PY), mode, *map(str, paths), *flags]
    run_env = os.environ.copy()
    if env:
        run_env.update({k: str(v) for k, v in env.items()})
    cp = subprocess.run(args, capture_output=True, timeout=timeout, env=run_env)
    return Result(cp)
