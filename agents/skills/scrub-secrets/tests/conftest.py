"""pytest fixtures for the scrub.py suite.

`tree` gives each test an isolated tmp fixture dir; `scrub` returns a callable
that drives scrub.py via subprocess against that tree (never a real memory file).
"""

from __future__ import annotations

import pytest
from _scrub_helpers import Result, invoke


@pytest.fixture
def tree(tmp_path):
    """An isolated, empty fixture dir for one test."""
    d = tmp_path / "vault"
    d.mkdir()
    return d


@pytest.fixture
def scrub_cli():
    """Return a callable: scrub_cli(mode, paths, *flags, env=..., timeout=...)."""

    def _run(mode, paths, *flags, env=None, timeout=60) -> Result:
        if not isinstance(paths, (list, tuple)):
            paths = [paths]
        return invoke(mode, paths, list(flags), env=env, timeout=timeout)

    return _run
