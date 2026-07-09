"""pytest fixtures for the recall-distill helper suite.

``root`` is an isolated fake ``~/.claude/projects`` (tmp). ``distill`` drives
``distill.py`` against it (which drives the real ``recall.py``). If recall.py is
not installed at the resolved path, the suite skips loudly rather than silently
passing — distill genuinely depends on it.
"""

from __future__ import annotations

import pytest
from _distill_helpers import RECALL_PY, Result, invoke


@pytest.fixture(autouse=True)
def _require_recall():
    if not RECALL_PY.is_file():
        pytest.skip(
            f"recall.py not found at {RECALL_PY} — set RECALL_PY to run the "
            "recall-distill integration suite"
        )


@pytest.fixture
def root(tmp_path):
    p = tmp_path / "projects"
    p.mkdir()
    return p


@pytest.fixture
def distill():
    def _run(*flags, root, **kw) -> Result:
        return invoke(*flags, root=root, **kw)

    return _run
