"""Tests for analyze-bench.py Tier 1 grep-runner.

Covers spec dotfiles-ukx.13 test cases T-08, T-09, T-11 (Tier 1 scope).
Tier 2 (LLM-as-judge) and Tier 3 (human flag) are Wave 4 work and out
of scope for these tests.

The analyze-bench.py module will live at:
    /home/ubuntu/dotfiles/local-models/analyze-bench.py

Tests invoke it via subprocess (it's a CLI script). When the impl agent
adds python-importable entry-points (e.g., a `score_trial(trial_path)`
function), the spy-based delegation test below also exercises those.

Test bead: dotfiles-ukx.13.2.
"""

from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

import pytest
from conftest import ANALYZE_BIN

# --- Helpers ---------------------------------------------------------------


def _run_analyze(*args: str) -> subprocess.CompletedProcess[str]:
    """Invoke the analyze-bench.py CLI. Returns CompletedProcess (no raise)."""
    return subprocess.run(
        [sys.executable, str(ANALYZE_BIN), *args],
        capture_output=True,
        text=True,
        check=False,
    )


def _import_analyze_bench():
    """Import analyze-bench.py as a Python module (for delegation spy test).

    The file has a hyphen in the name so the standard import statement
    doesn't work; we use importlib.util.spec_from_file_location.
    """
    spec = importlib.util.spec_from_file_location(
        "analyze_bench", str(ANALYZE_BIN)
    )
    if spec is None or spec.loader is None:
        pytest.fail(f"could not load analyze-bench.py from {ANALYZE_BIN}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# --- Spec test cases (T-08, T-09, T-11) -----------------------------------


def test_analyze_bench_binary_exists():
    """TEST: T-09 setup (spec dotfiles-ukx.13 §4.3) — analyze-bench.py must exist on disk."""
    assert ANALYZE_BIN.exists(), f"analyze-bench.py not found at {ANALYZE_BIN}"
    assert ANALYZE_BIN.is_file()


def test_analyze_bench_emits_markdown_matrix(
    sample_results_dir: Path, sample_scenarios_dir: Path, tmp_path: Path
):
    """TEST: T-09 (spec dotfiles-ukx.13 §5) — analyze-bench.py over a known-good
    results-dir emits a markdown matrix with mean/p50/p90 wall per cell."""
    out_file = tmp_path / "parity-matrix.md"
    result = _run_analyze(
        "--results-dir",
        str(sample_results_dir),
        "--scenarios-dir",
        str(sample_scenarios_dir),
        "--out",
        str(out_file),
    )
    assert result.returncode == 0, f"stderr: {result.stderr}"
    assert out_file.exists()
    body = out_file.read_text()
    # Mean / p50 / p90 are the spec-mandated wall metrics.
    assert re.search(r"\bmean\b", body, re.I), "matrix output missing 'mean'"
    assert re.search(r"\bp50\b", body, re.I), "matrix output missing 'p50'"
    assert re.search(r"\bp90\b", body, re.I), "matrix output missing 'p90'"
    # Each candidate appears in the matrix.
    assert "qwen3-coder" in body


def test_analyze_bench_marks_timeout_trials_incomplete(
    sample_results_dir: Path, sample_scenarios_dir: Path, tmp_path: Path
):
    """TEST: T-11 (spec dotfiles-ukx.13 §5) — TIMEOUT trials marked as
    'incomplete (N/N runs succeeded)'."""
    out_file = tmp_path / "parity.md"
    result = _run_analyze(
        "--results-dir",
        str(sample_results_dir),
        "--scenarios-dir",
        str(sample_scenarios_dir),
        "--out",
        str(out_file),
    )
    assert result.returncode == 0, f"stderr: {result.stderr}"
    body = out_file.read_text()
    # The sample_results_dir fixture seeds 1 PASS + 1 FAIL + 1 TIMEOUT for s01.
    # 2 of 3 trials produced terminal verdicts (one TIMEOUT'd).
    # Expect at least one cell to surface the incomplete marker.
    assert re.search(r"incomplete", body, re.I) or re.search(
        r"\b2\s*/\s*3\b", body
    ), (
        "expected 'incomplete' or fractional N/N marker for the TIMEOUT-containing cell; got:\n"
        + body
    )


def test_result_schema_includes_wall_cap_seconds(sample_results_dir: Path):
    """TEST: T-08 (spec dotfiles-ukx.13 §5 + §3.4) — result schema validates
    against the §3.4 fields (wall_cap_seconds present)."""
    # Read any sample result; every result file produced by run-scenario.sh
    # MUST carry wall_cap_seconds per §3.4 (OQ-02 decision).
    for f in sample_results_dir.glob("*.md"):
        text = f.read_text()
        assert "wall_cap_seconds" in text, (
            f"{f.name} missing wall_cap_seconds field"
        )


def test_result_schema_includes_cold_load_trial(sample_results_dir: Path):
    """TEST: T-08 (spec dotfiles-ukx.13 §3.4 + OQ-05) — result schema carries
    cold_load_trial boolean (trial 1 cold, trials 2..N warm within a cohort)."""
    for f in sample_results_dir.glob("*.md"):
        text = f.read_text()
        assert "cold_load_trial" in text, (
            f"{f.name} missing cold_load_trial field"
        )


def test_result_schema_includes_scoring_tier(sample_results_dir: Path):
    """TEST: T-08 (spec dotfiles-ukx.13 §3.4 + OQ-03) — scoring_tier 1|2|3 field."""
    for f in sample_results_dir.glob("*.md"):
        text = f.read_text()
        assert "scoring_tier" in text, f"{f.name} missing scoring_tier field"


def test_result_schema_includes_flagged_log_excerpt(sample_results_dir: Path):
    """TEST: T-08 (spec dotfiles-ukx.13 §3.4 + OQ-09) — flagged_log_excerpt
    section present (may be empty for unflagged trials)."""
    for f in sample_results_dir.glob("*.md"):
        text = f.read_text()
        assert "flagged_log_excerpt" in text, (
            f"{f.name} missing flagged_log_excerpt section"
        )


# --- Tier 1 grep-runner: parse and execute Pass criteria ------------------


def test_grep_runner_extracts_pass_criteria_block(sample_scenarios_dir: Path):
    """TEST: T-08/T-09 supporting (spec dotfiles-ukx.13 §4.4 Tier 1) —
    Tier 1 grep-runner reads the scenario's `## Pass criteria` block."""
    mod = _import_analyze_bench()
    # The Wave 1 impl exposes a `parse_pass_criteria(scenario_path)` function
    # that returns a list of bullet-line assertions. Exact contract is the
    # /test→/impl handoff: tests document the shape.
    assert hasattr(mod, "parse_pass_criteria"), (
        "analyze-bench.py must expose parse_pass_criteria(path) for Tier 1"
    )
    bullets = mod.parse_pass_criteria(
        sample_scenarios_dir / "01-trivial-rename.md"
    )
    assert isinstance(bullets, list)
    assert len(bullets) >= 3, (
        f"scenario 01 has 5 pass criteria bullets; parser got {len(bullets)}"
    )
    # Should at least surface the 'def sum_two' grep + the DONE assertion.
    blob = "\n".join(bullets)
    assert "sum_two" in blob
    assert "DONE" in blob


def test_grep_runner_pass_on_passing_trial(
    sample_scenarios_dir: Path, sample_results_dir: Path
):
    """TEST: T-09 (spec dotfiles-ukx.13 §4.4 Tier 1) — grep-runner reports
    PASS for a trial whose output + sandbox state satisfies all criteria."""
    mod = _import_analyze_bench()
    assert hasattr(mod, "grep_runner"), (
        "analyze-bench.py must expose grep_runner(scenario, trial)"
    )
    trial = (
        sample_results_dir
        / "01-trivial-rename-qwen3-coder-1-20260527T120000Z.md"
    )
    verdict = mod.grep_runner(
        scenario_path=sample_scenarios_dir / "01-trivial-rename.md",
        trial_path=trial,
    )
    assert verdict in ("PASS", "FAIL", "INCONCLUSIVE"), (
        f"unexpected verdict: {verdict}"
    )
    assert verdict == "PASS", (
        f"trial with sum_two + DONE should PASS; got {verdict}"
    )


def test_grep_runner_fail_on_failing_trial(
    sample_scenarios_dir: Path, sample_results_dir: Path
):
    """TEST: T-09 (spec dotfiles-ukx.13 §4.4 Tier 1) — grep-runner reports
    FAIL for a trial whose sandbox still has add_numbers (rename never happened)."""
    mod = _import_analyze_bench()
    trial = (
        sample_results_dir
        / "01-trivial-rename-qwen3-coder-2-20260527T130000Z.md"
    )
    verdict = mod.grep_runner(
        scenario_path=sample_scenarios_dir / "01-trivial-rename.md",
        trial_path=trial,
    )
    assert verdict == "FAIL", (
        f"trial with add_numbers (no rename) should FAIL; got {verdict}"
    )


# --- Delegation test (per /test SKILL Step 3.5) ---------------------------


def test_score_trial_delegates_to_grep_runner(
    sample_scenarios_dir: Path, sample_results_dir: Path, monkeypatch
):
    """TEST: T-08/T-09 supporting (per /test SKILL Step 3.5) — score_trial()
    must DELEGATE to Tier 1 grep_runner, not stub-return PASS.

    Guards against an impl that ships score_trial returning a constant —
    spy on grep_runner and assert it was called with the trial path.
    """
    mod = _import_analyze_bench()
    assert hasattr(mod, "score_trial"), (
        "analyze-bench.py must expose score_trial(trial_path) — the Wave 1 entry-point that"
        " delegates to Tier 1 (and in Wave 4 will cascade to Tier 2/3)"
    )

    call_log: list[Path] = []
    original = mod.grep_runner

    def spy_grep_runner(*, scenario_path: Path, trial_path: Path):
        call_log.append(trial_path)
        return original(scenario_path=scenario_path, trial_path=trial_path)

    monkeypatch.setattr(mod, "grep_runner", spy_grep_runner)

    trial = (
        sample_results_dir
        / "01-trivial-rename-qwen3-coder-1-20260527T120000Z.md"
    )
    result = mod.score_trial(
        trial_path=trial,
        scenarios_dir=sample_scenarios_dir,
    )
    assert call_log, "score_trial did not invoke grep_runner — stubbed body?"
    assert call_log[0] == trial
    assert result in ("PASS", "FAIL", "INCONCLUSIVE")


# --- Outlier callouts (T-10 spec) -----------------------------------------


def test_outlier_callouts_section_present(
    sample_results_dir: Path, sample_scenarios_dir: Path, tmp_path: Path
):
    """TEST: T-10 (spec dotfiles-ukx.13 §5) — outlier callouts where
    wall_multiplier > 100x appear in a dedicated section.

    Even if no trial in the fixture exceeds 100x, the section header MUST
    exist (analyze-bench emits an empty 'Outliers' section so downstream
    readers know it was considered).
    """
    out_file = tmp_path / "parity.md"
    result = _run_analyze(
        "--results-dir",
        str(sample_results_dir),
        "--scenarios-dir",
        str(sample_scenarios_dir),
        "--out",
        str(out_file),
    )
    assert result.returncode == 0, f"stderr: {result.stderr}"
    body = out_file.read_text()
    assert re.search(r"##\s*Outlier", body, re.I), (
        "parity matrix must include an Outliers section (T-10); got:\n" + body
    )


# --- JSON emit path (downstream consumers want machine-readable too) ------


def test_analyze_bench_emits_json_when_asked(
    sample_results_dir: Path, sample_scenarios_dir: Path, tmp_path: Path
):
    """TEST: T-08 supporting — analyze-bench.py may emit JSON parity matrix
    for programmatic downstream (Wave 4 LLM-judge cascade reads it)."""
    out_file = tmp_path / "parity.json"
    result = _run_analyze(
        "--results-dir",
        str(sample_results_dir),
        "--scenarios-dir",
        str(sample_scenarios_dir),
        "--out",
        str(out_file),
        "--format",
        "json",
    )
    assert result.returncode == 0, f"stderr: {result.stderr}"
    assert out_file.exists()
    data = json.loads(out_file.read_text())
    assert isinstance(data, dict), "JSON parity matrix must be a dict"
    # Expect at least a 'cells' or 'matrix' key per cell
    assert "cells" in data or "matrix" in data, (
        "JSON output must expose a 'cells' or 'matrix' key; got: "
        + ", ".join(data.keys())
    )
