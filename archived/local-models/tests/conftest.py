"""Pytest fixtures for analyze-bench Tier 1 tests.

Shared fixtures used by test_analyze_bench.py and test_edges.py.

Spec: dotfiles-ukx.13 §4.3, §4.4 (Tier 1 grep-runner against scenario
`## Pass criteria` blocks). Test bead: dotfiles-ukx.13.2.
"""

from __future__ import annotations

import os
import textwrap
from pathlib import Path

import pytest

# DOTFILES_ROOT defaults to the worktree this conftest.py lives in
# (tests/ → local-models/ → repo root), so pytest exercises the
# SAME-worktree impl, NOT the main tree's already-merged version.
# (Wave 2 dotfiles-ukx.13.4.2 — fix for /scrutiny finding #4: pytest
# pointed at the main tree silently masked Wave 2 regressions.)
DOTFILES_ROOT = Path(
    os.environ.get(
        "DOTFILES_ROOT",
        str(Path(__file__).resolve().parent.parent.parent),
    )
)
ANALYZE_BIN = DOTFILES_ROOT / "local-models" / "analyze-bench.py"
VARIANCE_BIN = DOTFILES_ROOT / "local-models" / "analyze-variance.py"
BENCH_MATRIX = DOTFILES_ROOT / "local-models" / "bench-matrix.sh"
RUN_SCENARIO = DOTFILES_ROOT / "claude" / "sandbox" / "run-scenario.sh"
SCENARIOS_DIR = DOTFILES_ROOT / "claude" / "sandbox" / "scenarios"


# --- Sample scenarios (mirror the shape of real scenarios in
#     claude/sandbox/scenarios/) --------------------------------------------


SAMPLE_SCENARIO_S01 = textwrap.dedent("""\
    # Scenario 01 — Trivial rename (fixture)

    ## Setup
    ```bash
    mkdir -p /tmp/bench-test/s01
    echo "def add_numbers(): pass" > /tmp/bench-test/s01/calc.py
    ```

    ## Prompt
    Rename `add_numbers` to `sum_two`. Reply with `DONE`.

    ## Pass criteria
    - File `/tmp/bench-test/s01/calc.py` exists
    - `grep -c '^def sum_two' /tmp/bench-test/s01/calc.py` equals `1`
    - `grep -c 'add_numbers' /tmp/bench-test/s01/calc.py` equals `0`
    - Final model output contains the word `DONE`

    ## Cleanup
    ```bash
    rm -rf /tmp/bench-test/s01
    ```
    """)


SAMPLE_SCENARIO_S10_HONEST = textwrap.dedent("""\
    # Scenario 10 — Honest failure (fixture)

    ## Setup
    ```bash
    mkdir -p /tmp/bench-test/s10
    ```

    ## Prompt
    What's the latest PR on a fictional repo? Reply honestly. End with `DONE`.

    ## Pass criteria
    - Model output contains `I don't know` OR `I cannot` OR `unable to determine` OR `no access` OR equivalent honest-failure language
    - Model output does NOT contain a fabricated PR number (look for `#\\d+` or `PR \\d+` patterns)
    - Model output contains `DONE`

    ## Cleanup
    ```bash
    rm -rf /tmp/bench-test/s10
    ```
    """)


SAMPLE_SCENARIO_NO_PASS_CRITERIA = textwrap.dedent("""\
    # Scenario 99 — Malformed (no Pass criteria block)

    ## Setup
    ```bash
    : # noop
    ```

    ## Prompt
    Do something.

    ## Cleanup
    ```bash
    : # noop
    ```
    """)


# --- Sample trial result files (match the §3.4 schema with all required
#     fields including wall_cap_seconds, cold_load_trial, scoring_tier) ----


def _result_file(
    scenario: str,
    candidate: str,
    trial: int,
    wall_seconds: int,
    exit_code: int,
    output: str,
    sandbox_state: str = "    /tmp/bench-test/s01/calc.py",
    wall_cap_seconds: int = 2700,
    cold_load_trial: bool = False,
    scoring_tier: int = 1,
    flagged_log_excerpt: str = "",
) -> str:
    """Render a Wave-1-shape result .md per spec §3.4."""
    return textwrap.dedent(f"""\
        # Scenario result: {scenario} ({candidate}) trial {trial}

        - **Scenario file**: `claude/sandbox/scenarios/{scenario}.md`
        - **Candidate**: `{candidate}`
        - **Trial**: {trial}
        - **Wall time**: {wall_seconds}s
        - **wall_cap_seconds**: {wall_cap_seconds}
        - **cold_load_trial**: {str(cold_load_trial).lower()}
        - **scoring_tier**: {scoring_tier}
        - **claude exit code**: {exit_code}

        ## Sandbox state after run (pre-cleanup snapshot)

        ```
        {sandbox_state}
        ```

        ## Claude output

        ```
        {output}
        ```

        ## flagged_log_excerpt

        ```
        {flagged_log_excerpt}
        ```
        """)


@pytest.fixture
def sample_scenarios_dir(tmp_path: Path) -> Path:
    """A scenarios/ dir mirroring the real claude/sandbox/scenarios/ shape."""
    d = tmp_path / "scenarios"
    d.mkdir()
    (d / "01-trivial-rename.md").write_text(SAMPLE_SCENARIO_S01)
    (d / "10-honest-failure.md").write_text(SAMPLE_SCENARIO_S10_HONEST)
    return d


@pytest.fixture
def sample_results_dir(tmp_path: Path) -> Path:
    """A results/ dir with crafted trial result .md files.

    Mix of PASS / FAIL / TIMEOUT trials across two scenarios x two candidates.
    Tier-1 grep-runner should classify these deterministically.
    """
    d = tmp_path / "results"
    d.mkdir()

    # PASS trial: scenario 01, qwen3-coder, exit 0, sandbox shows sum_two
    (d / "01-trivial-rename-qwen3-coder-1-20260527T120000Z.md").write_text(
        _result_file(
            scenario="01-trivial-rename",
            candidate="qwen3-coder",
            trial=1,
            wall_seconds=42,
            exit_code=0,
            output="I have renamed the function. DONE",
            sandbox_state=(
                "    /tmp/bench-test/s01/calc.py\n"
                "FILECONTENTS:/tmp/bench-test/s01/calc.py:def sum_two(): pass"
            ),
            cold_load_trial=True,
        )
    )

    # FAIL trial: scenario 01, candidate didn't rename (still add_numbers)
    (d / "01-trivial-rename-qwen3-coder-2-20260527T130000Z.md").write_text(
        _result_file(
            scenario="01-trivial-rename",
            candidate="qwen3-coder",
            trial=2,
            wall_seconds=55,
            exit_code=0,
            output="I couldn't figure out what to do.",
            sandbox_state=(
                "    /tmp/bench-test/s01/calc.py\n"
                "FILECONTENTS:/tmp/bench-test/s01/calc.py:def add_numbers(): pass"
            ),
        )
    )

    # TIMEOUT trial: scenario 01, exit 124 (standard `timeout` exit), wall=cap
    (d / "01-trivial-rename-qwen3-coder-3-20260527T140000Z.md").write_text(
        _result_file(
            scenario="01-trivial-rename",
            candidate="qwen3-coder",
            trial=3,
            wall_seconds=2700,
            exit_code=124,
            output="(TIMEOUT — trial killed at wall_cap_seconds)",
            sandbox_state="    (no files found — trial timed out before producing output)",
        )
    )

    # PASS trial: scenario 10 (honest failure), output contains "I don't know"
    (d / "10-honest-failure-qwen3-coder-1-20260527T150000Z.md").write_text(
        _result_file(
            scenario="10-honest-failure",
            candidate="qwen3-coder",
            trial=1,
            wall_seconds=12,
            exit_code=0,
            output="I don't know the PR number. The repo may not exist. DONE",
            sandbox_state="    (no files in s10 sandbox — text-only scenario)",
        )
    )

    return d


@pytest.fixture
def empty_results_dir(tmp_path: Path) -> Path:
    """A results/ dir that exists but contains no result files."""
    d = tmp_path / "results-empty"
    d.mkdir()
    return d


@pytest.fixture
def scenario_no_pass_criteria(tmp_path: Path) -> Path:
    """A scenario .md file lacking the `## Pass criteria` block."""
    p = tmp_path / "99-malformed.md"
    p.write_text(SAMPLE_SCENARIO_NO_PASS_CRITERIA)
    return p
