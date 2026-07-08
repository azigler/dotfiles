"""pytest fixtures for the /recall suite.

`root` gives each test an isolated fake projects tree (tmp), and `recall`
returns a callable that drives recall.py against a fixture root — never the real
`~/.claude/projects`.
"""

from __future__ import annotations

import pytest
from _recall_helpers import DEFAULT_TIMEOUT, Result, invoke


@pytest.fixture
def root(tmp_path):
    """An isolated, empty fake `~/.claude/projects` root for one test."""
    p = tmp_path / "projects"
    p.mkdir()
    return p


@pytest.fixture
def recall():
    """Return a callable: recall(query, *flags, root=..., env_root=..., ...).

    By default the query is steered at `root` via BOTH the --root flag and the
    CLAUDE_PROJECTS_ROOT env var (belt-and-suspenders test safety). Tests that
    exercise the env-only path or --root precedence override these explicitly.
    """
    _SENTINEL = object()

    def _run(
        query,
        *flags,
        root=None,
        env_root=_SENTINEL,
        unset_env=False,
        extra_env=None,
        timeout=DEFAULT_TIMEOUT,
        cwd=None,
    ):
        er = root if env_root is _SENTINEL else env_root
        cp = invoke(
            query,
            flags,
            root_flag=root,
            env_root=er,
            unset_env=unset_env,
            extra_env=extra_env,
            timeout=timeout,
            cwd=cwd,
        )
        return Result(cp)

    return _run
