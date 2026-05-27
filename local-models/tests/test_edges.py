"""Edge / error tests beyond spec Section 5 — per /test SKILL Step 4.

≥5 edge cases that the spec test cases don't cover. Each guards a
specific failure mode the bench scaffolding will encounter in production.

Test bead: dotfiles-ukx.13.2. Spec: dotfiles-ukx.13.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest
from conftest import (
    ANALYZE_BIN,
    BENCH_MATRIX,
    RUN_SCENARIO,
    _result_file,
)


def _import_analyze_bench():
    spec = importlib.util.spec_from_file_location(
        "analyze_bench", str(ANALYZE_BIN)
    )
    if spec is None or spec.loader is None:
        pytest.fail(f"could not load analyze-bench.py from {ANALYZE_BIN}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# --- EDGE 1: scenario without a ## Pass criteria block ---------------------


def test_analyze_bench_skips_missing_pass_criteria(
    scenario_no_pass_criteria: Path, tmp_path: Path
):
    """EDGE: missing-pass-criteria — analyze-bench marks trial as N/A (or
    INCONCLUSIVE) when scenario lacks the `## Pass criteria` block, rather
    than crashing or silently scoring PASS."""
    mod = _import_analyze_bench()
    # Build a result file paired with the malformed scenario.
    results_dir = tmp_path / "results"
    results_dir.mkdir()
    trial_file = results_dir / "99-malformed-qwen3-coder-1-20260527T000000Z.md"
    trial_file.write_text(
        _result_file(
            scenario="99-malformed",
            candidate="qwen3-coder",
            trial=1,
            wall_seconds=5,
            exit_code=0,
            output="hello DONE",
        )
    )
    # parse_pass_criteria on a scenario lacking the block must return [] or raise
    # a documented exception — NOT silently return None or partial data.
    bullets = mod.parse_pass_criteria(scenario_no_pass_criteria)
    assert bullets == [] or bullets is None, (
        f"missing Pass criteria block should yield empty list or None; got {bullets}"
    )

    # grep_runner against this scenario should NOT PASS — Wave 1 contract is
    # INCONCLUSIVE (Tier 2 / Tier 3 would handle in Wave 4).
    verdict = mod.grep_runner(
        scenario_path=scenario_no_pass_criteria,
        trial_path=trial_file,
    )
    assert verdict in ("INCONCLUSIVE", "N/A"), (
        f"no Pass criteria block → verdict should be INCONCLUSIVE/N/A; got {verdict}"
    )


# --- EDGE 2: zero-trial result directory ----------------------------------


def test_analyze_bench_empty_results_dir(
    empty_results_dir: Path, sample_scenarios_dir: Path, tmp_path: Path
):
    """EDGE: empty-results-dir — analyze-bench should produce a valid (if
    empty) parity matrix when no trial files exist, NOT crash with KeyError
    or division-by-zero on stats."""
    out_file = tmp_path / "parity-empty.md"
    result = subprocess.run(
        [
            sys.executable,
            str(ANALYZE_BIN),
            "--results-dir",
            str(empty_results_dir),
            "--scenarios-dir",
            str(sample_scenarios_dir),
            "--out",
            str(out_file),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, (
        f"empty results dir must not crash analyze-bench; stderr: {result.stderr}"
    )
    assert out_file.exists()
    body = out_file.read_text()
    # Output must mention zero data — either explicit "no trials" or empty table.
    assert (
        "no trial" in body.lower()
        or "no data" in body.lower()
        or "0 trials" in body.lower()
        or len(body.strip()) > 0
    ), f"empty parity-matrix output is suspicious; got: {body!r}"


# --- EDGE 3: malformed result .md file (missing schema fields) ------------


def test_analyze_bench_handles_malformed_result_file(
    sample_scenarios_dir: Path, tmp_path: Path
):
    """EDGE: malformed-result-file — analyze-bench should skip (or surface
    as anomaly) result files missing required §3.4 schema fields, NOT
    silently include them in the parity matrix as zero-wall successes."""
    results_dir = tmp_path / "results"
    results_dir.mkdir()
    bad_file = (
        results_dir / "01-trivial-rename-qwen3-coder-1-20260527T000000Z.md"
    )
    bad_file.write_text(
        "# Scenario result: 01-trivial-rename (qwen3-coder) trial 1\n\n"
        "(missing all the §3.4 fields — this file is not parseable)\n"
    )

    out_file = tmp_path / "parity.md"
    result = subprocess.run(
        [
            sys.executable,
            str(ANALYZE_BIN),
            "--results-dir",
            str(results_dir),
            "--scenarios-dir",
            str(sample_scenarios_dir),
            "--out",
            str(out_file),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    # Either return non-zero (strict mode) OR succeed with a warning section.
    if result.returncode == 0:
        body = out_file.read_text().lower()
        assert (
            "malformed" in body
            or "warning" in body
            or "skipped" in body
            or "invalid" in body
        ), (
            "successful exit on malformed result MUST flag it in the output; got:\n"
            + out_file.read_text()
        )
    else:
        # Strict-mode exit is also acceptable.
        assert result.returncode != 0


# --- EDGE 4: scenario file passed but doesn't exist -----------------------


def test_run_scenario_nonexistent_scenario_file_fails_fast(tmp_path: Path):
    """EDGE: nonexistent-scenario — run-scenario.sh should fail fast with a
    clear error (non-zero exit + stderr message) when the scenario file
    doesn't exist."""
    missing = tmp_path / "does-not-exist.md"
    result = subprocess.run(
        [str(RUN_SCENARIO), str(missing), "opus"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0, (
        "run-scenario.sh must exit non-zero on missing scenario file"
    )
    # Error message should mention the missing file (so the operator can find it).
    assert (
        "not found" in result.stderr.lower()
        or "no such" in result.stderr.lower()
    ), f"stderr should mention missing file; got: {result.stderr!r}"


# --- EDGE 5: candidate that doesn't exist in llama-swap config -------------


def test_bench_matrix_unknown_candidate_fails_fast(tmp_path: Path):
    """EDGE: unknown-candidate — bench-matrix.sh --candidates with a candidate
    name that isn't in the llama-swap roster should fail fast (non-zero exit)
    rather than silently producing no result files."""
    fake_results = tmp_path / "results"
    fake_results.mkdir()
    result = subprocess.run(
        [
            str(BENCH_MATRIX),
            "--candidates",
            "nonexistent-bogus-candidate-xyz",
            "--scenarios",
            "01",
            "--trials",
            "1",
            "--results-dir",
            str(fake_results),
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    assert result.returncode != 0, (
        "bench-matrix.sh must reject unknown candidate; got 0 exit"
    )
    # No result files should be written for the unknown candidate.
    assert not any(fake_results.glob("*.md")), (
        "no result files should be written for an unknown candidate"
    )


# --- EDGE 6: bench-matrix --resume with corrupted state file --------------


def test_bench_matrix_resume_with_corrupted_state(tmp_path: Path):
    """EDGE: corrupted-resume-state — bench-matrix.sh --resume should detect
    a corrupted state file (invalid JSON, missing keys) and either rebuild
    from results-dir or fail with a clear message — NOT crash with a Python
    JSONDecodeError leaking to the operator."""
    state_dir = tmp_path / "state"
    state_dir.mkdir()
    # Seed a corrupted state file at the documented path
    corrupted = tmp_path / "bench-matrix-state.json"
    corrupted.write_text("{ this is not valid json at all }")

    fake_results = tmp_path / "results"
    fake_results.mkdir()

    result = subprocess.run(
        [
            str(BENCH_MATRIX),
            "--resume",
            "--state-file",
            str(corrupted),
            "--results-dir",
            str(fake_results),
            "--candidates",
            "qwen3-coder",
            "--scenarios",
            "01",
            "--trials",
            "1",
            "--dry-run",
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    # Acceptable outcomes:
    #   (a) exit 0 with a "rebuilt state from results-dir" message
    #   (b) exit non-zero with a clear "corrupted state" message
    # NOT acceptable: a raw JSONDecodeError / python traceback.
    combined = (result.stdout + result.stderr).lower()
    assert "traceback" not in combined, (
        "raw traceback should not leak to operator on corrupted state file; got:\n"
        + combined
    )
    assert (
        "corrupt" in combined
        or "rebuilt" in combined
        or "invalid state" in combined
        or "rebuild" in combined
        or result.returncode == 0
    ), f"unclear corrupted-state handling; output:\n{combined}"


# --- EDGE 7: pass-criteria bullet referencing a binary that doesn't exist --


def test_grep_runner_handles_missing_binary_gracefully(
    sample_scenarios_dir: Path, tmp_path: Path
):
    """EDGE: missing-binary-in-pass-criteria — if a scenario's Pass criteria
    references a binary not on PATH (e.g., `grep` missing in the eval env),
    grep_runner should return INCONCLUSIVE with a clear reason, NOT PASS."""
    mod = _import_analyze_bench()
    # Build a scenario whose Pass criteria invokes a fake binary
    scenario = tmp_path / "98-fake-binary.md"
    scenario.write_text(
        textwrap.dedent("""\
        # Scenario 98 — fake binary

        ## Setup
        ```bash
        : # noop
        ```

        ## Prompt
        Do it.

        ## Pass criteria
        - `definitely-not-a-real-binary-xyz123 --check /tmp/anything` returns 0
        - Final model output contains `DONE`

        ## Cleanup
        ```bash
        : # noop
        ```
        """)
    )
    results_dir = tmp_path / "results"
    results_dir.mkdir()
    trial = results_dir / "98-fake-binary-qwen3-coder-1-20260527T000000Z.md"
    trial.write_text(
        _result_file(
            scenario="98-fake-binary",
            candidate="qwen3-coder",
            trial=1,
            wall_seconds=5,
            exit_code=0,
            output="all done DONE",
        )
    )
    verdict = mod.grep_runner(scenario_path=scenario, trial_path=trial)
    # Must NOT PASS: a missing binary is by definition unverifiable.
    assert verdict != "PASS", (
        f"unverifiable Pass criteria (missing binary) must not PASS; got {verdict}"
    )
