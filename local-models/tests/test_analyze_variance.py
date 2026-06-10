"""Tests for analyze-variance.py — the cohort variance + PASS-rate guard.

Why this suite exists: matrix postmortem 2026-06 failure modes #10 and #12
(refs/matrix-postmortem-2026-06.md in explore/local-coding-models). The
guard scripts shipped with silent bugs caught only by eye:

  - The cohort-name-anchor regex regression: a naive `(scen)-(cand)-trial`
    split is ambiguous (both halves are kebab-case) and silently matched
    only 6 of 30 result files. The fix anchors on `-{candidate}-trial`.
    test_collect_thirty_of_thirty is the regression guard.
  - The rw2 class: a cohort where EVERY trial fails identically (uniform
    error text, verdict_tag OK, uniform wall times) passed all variance
    checks — variance measures uniformity, not success. The headline test
    here builds that exact shape synthetically and asserts that
    `--strict --scenarios-dir ...` exits non-zero on it.

Fixture bodies mirror the REAL v3/v4 result-file shape (see
explore/local-coding-models/results/round-1/v3v4-partial/*.md): filename
`<scen>-<cand>-trial<N>-<UTCTS>.md`, body fields **Candidate**,
**Wall time**, **verdict_tag**, plus the sandbox/output sections the
Tier 1 grep-runner scores.

Tests marked "KNOWN GAP" pin current (buggy/blind) behavior on purpose;
the corresponding entries live in tests/KNOWN-GAPS.md. Do NOT "fix" the
script to make those pins fail without updating both.

Bead: dotfiles-t4k (implements local-coding-models-wkw).
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest
from conftest import VARIANCE_BIN

# --- Module / CLI access -----------------------------------------------------


@pytest.fixture(scope="module")
def va():
    """Import analyze-variance.py as a module (hyphen blocks `import`)."""
    spec = importlib.util.spec_from_file_location(
        "analyze_variance", str(VARIANCE_BIN)
    )
    if spec is None or spec.loader is None:
        pytest.fail(f"could not load analyze-variance.py from {VARIANCE_BIN}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _run_variance(*args: str) -> subprocess.CompletedProcess[str]:
    """Invoke the analyze-variance.py CLI. Returns CompletedProcess."""
    return subprocess.run(
        [sys.executable, str(VARIANCE_BIN), *args],
        capture_output=True,
        text=True,
        check=False,
    )


# --- Result-file builders (real v3/v4 shape) ---------------------------------

# Sandbox/output pairs that Tier-1 PASS the conftest sample scenarios.
S01_PASS_SANDBOX = (
    "    /tmp/bench-test/s01/calc.py\n"
    "FILECONTENTS:/tmp/bench-test/s01/calc.py:def sum_two(): pass"
)
S01_PASS_OUTPUT = "Renamed the function as requested. DONE"
S10_PASS_OUTPUT = "I don't know the PR number. The repo may not exist. DONE"

# The rw2-class uniform failure: the exact v2-garbage error string — every
# trial identical, verdict still tagged OK by the runner.
UNIFORM_FAILURE_OUTPUT = "API Error: 500 fetch failed"
EMPTY_SANDBOX = "    (no files found — trial produced no sandbox output)"


def _result_body(
    *,
    scenario: str,
    candidate: str,
    trial: int,
    wall_seconds: int | None,
    verdict: str | None = "OK",
    output: str = S01_PASS_OUTPUT,
    sandbox: str = S01_PASS_SANDBOX,
    exit_code: int = 0,
) -> str:
    """Render a result .md matching the real v3/v4 file shape."""
    wall_line = (
        f"- **Wall time**: {wall_seconds}s\n"
        if wall_seconds is not None
        else ""
    )
    verdict_line = f"- **verdict_tag**: {verdict}\n" if verdict else ""
    return textwrap.dedent(f"""\
        # Scenario result: {scenario} (local) trial {trial}

        - **Scenario file**: `claude/sandbox/scenarios/{scenario}.md`
        - **Model tag**: `local`
        - **Candidate**: `{candidate}`
        - **Trial**: {trial}
        - **Started**: 2026-06-01T03:35:19Z
        {wall_line}- **wall_cap_seconds**: 2700
        - **cold_load_trial**: false
        - **scoring_tier**: 1
        - **claude exit code**: {exit_code}
        {verdict_line}
        ## Sandbox state after run (pre-cleanup snapshot)

        ```
        {sandbox}
        ```

        ## Claude output

        ```
        {output}
        ```

        ## flagged_log_excerpt

        ```
        ```
        """)


def _write_trial(
    results_dir: Path,
    *,
    scenario: str,
    candidate: str,
    trial: int,
    wall_seconds: int | None,
    **body_kwargs,
) -> Path:
    ts = f"20260601T03351{trial % 10}Z"
    p = results_dir / f"{scenario}-{candidate}-trial{trial}-{ts}.md"
    p.write_text(
        _result_body(
            scenario=scenario,
            candidate=candidate,
            trial=trial,
            wall_seconds=wall_seconds,
            **body_kwargs,
        )
    )
    return p


# Ten kebab-case scenario names (multi-hyphen on purpose — the ambiguity
# that broke the naive regex).
TEN_SCENARIOS = [
    "01-trivial-rename",
    "02-easy-add-function",
    "03-medium-refactor",
    "04-hard-bugfix",
    "05-multi-file-edit",
    "06-test-first-fix",
    "07-doc-sync-update",
    "08-api-shape-change",
    "09-long-context-grep",
    "10-honest-failure",
]


@pytest.fixture
def thirty_trial_dir(tmp_path: Path) -> Path:
    """10 scenarios x 3 trials for trinity-mini, plus 30 qwen3-coder decoys.

    Both candidate names are kebab-case multi-hyphen strings — the exact
    shape that made the naive scen/cand split ambiguous.
    """
    d = tmp_path / "results-30"
    d.mkdir()
    for candidate in ("trinity-mini", "qwen3-coder"):
        for scen in TEN_SCENARIOS:
            for trial in (1, 2, 3):
                _write_trial(
                    d,
                    scenario=scen,
                    candidate=candidate,
                    trial=trial,
                    wall_seconds=40 + trial * 5,
                )
    return d


@pytest.fixture
def clean_cohort_dir(tmp_path: Path) -> Path:
    """A healthy trinity-mini cohort: clustered walls, all trials Tier-1 PASS."""
    d = tmp_path / "results-clean"
    d.mkdir()
    for trial, wall in ((1, 40), (2, 45), (3, 50)):
        _write_trial(
            d,
            scenario="01-trivial-rename",
            candidate="trinity-mini",
            trial=trial,
            wall_seconds=wall,
        )
    for trial, wall in ((1, 10), (2, 12), (3, 14)):
        _write_trial(
            d,
            scenario="10-honest-failure",
            candidate="trinity-mini",
            trial=trial,
            wall_seconds=wall,
            sandbox="    (no files in s10 sandbox — text-only scenario)",
            output=S10_PASS_OUTPUT,
        )
    return d


@pytest.fixture
def uniform_failure_dir(tmp_path: Path) -> Path:
    """The rw2-class synthetic fixture: every trial fails IDENTICALLY.

    Uniform error text, verdict_tag OK, uniform wall times. Variance-only
    checks see a perfectly clean cohort; only the Tier 1 PASS-rate check
    can flag it.
    """
    d = tmp_path / "results-uniform-failure"
    d.mkdir()
    for scen in ("01-trivial-rename", "10-honest-failure"):
        for trial in (1, 2, 3):
            _write_trial(
                d,
                scenario=scen,
                candidate="trinity-mini",
                trial=trial,
                wall_seconds=7,  # identical wall on every trial
                verdict="OK",  # the runner tagged garbage OK (rw2)
                output=UNIFORM_FAILURE_OUTPUT,
                sandbox=EMPTY_SANDBOX,
            )
    return d


# --- parse_result_file / collect_cohort_results ------------------------------


def test_parse_real_v3v4_filename_shape(va, tmp_path: Path):
    """Parse a file named + shaped like the real v3/v4 partial results."""
    p = _write_trial(
        tmp_path,
        scenario="01-trivial-rename",
        candidate="trinity-mini",
        trial=1,
        wall_seconds=465,
    )
    parsed = va.parse_result_file(p, "trinity-mini")
    assert parsed is not None
    assert parsed["scenario"] == "01-trivial-rename"
    assert parsed["candidate"] == "trinity-mini"
    assert parsed["trial"] == 1
    assert parsed["wall_seconds"] == 465
    assert parsed["verdict"] == "OK"


def test_parse_rejects_other_candidate(va, tmp_path: Path):
    p = _write_trial(
        tmp_path,
        scenario="01-trivial-rename",
        candidate="trinity-mini",
        trial=1,
        wall_seconds=100,
    )
    assert va.parse_result_file(p, "qwen3-coder") is None


def test_parse_rejects_malformed_tail(va, tmp_path: Path):
    """trial0 and a missing timestamp must both be rejected."""
    bad1 = (
        tmp_path / "01-trivial-rename-trinity-mini-trial0-20260601T033519Z.md"
    )
    bad1.write_text("- **Wall time**: 5s\n")
    bad2 = tmp_path / "01-trivial-rename-trinity-mini-trial1-notats.md"
    bad2.write_text("- **Wall time**: 5s\n")
    assert va.parse_result_file(bad1, "trinity-mini") is None
    assert va.parse_result_file(bad2, "trinity-mini") is None


def test_parse_trial_ten_dropped_known_gap(va, tmp_path: Path):
    """KNOWN GAP: TAIL_RE caps trials at 1-9; trial10+ is silently dropped.

    Pins current behavior — see KNOWN-GAPS.md. At N>=10 trials per cell
    (postmortem says N=3 was too low), files beyond trial9 vanish from
    the cohort without any warning: the silent-miss class again.
    """
    p = tmp_path / "01-trivial-rename-trinity-mini-trial10-20260601T033519Z.md"
    p.write_text("- **Wall time**: 50s\n")
    assert va.parse_result_file(p, "trinity-mini") is None


def test_parse_cohort_substring_contamination_known_gap(va, tmp_path: Path):
    """KNOWN GAP: a cohort name that is a suffix of another candidate's name
    matches that candidate's files, with a mangled scenario name.

    `-mini-trial` occurs inside `...-trinity-mini-trial1-...`, and the
    mangled scenario `01-trivial-rename-trinity` still satisfies SCEN_RE.
    Pins current behavior — see KNOWN-GAPS.md.
    """
    p = _write_trial(
        tmp_path,
        scenario="01-trivial-rename",
        candidate="trinity-mini",
        trial=1,
        wall_seconds=100,
    )
    parsed = va.parse_result_file(p, "mini")
    assert parsed is not None  # WRONG cohort, silently accepted
    assert parsed["scenario"] == "01-trivial-rename-trinity"  # mangled


def test_candidate_name_embedded_in_scenario(va, tmp_path: Path):
    """Anchor must split correctly even when the scenario name CONTAINS the
    candidate name (`05-trinity-mini-port` x `trinity-mini`)."""
    p = _write_trial(
        tmp_path,
        scenario="05-trinity-mini-port",
        candidate="trinity-mini",
        trial=2,
        wall_seconds=80,
    )
    parsed = va.parse_result_file(p, "trinity-mini")
    assert parsed is not None
    assert parsed["scenario"] == "05-trinity-mini-port"
    assert parsed["trial"] == 2


def test_collect_thirty_of_thirty(va, thirty_trial_dir: Path):
    """REGRESSION (postmortem #12, bead wkw): the naive scen/cand regex
    silently matched only 6 of 30 files. The candidate-anchored parser
    must collect ALL 30 trinity-mini trials — 10 scenarios x 3 trials —
    and none of the 30 qwen3-coder decoys."""
    results = va.collect_cohort_results(thirty_trial_dir, "trinity-mini")
    assert len(results) == 30, (
        f"expected 30/30 trials collected, got {len(results)} — "
        "the 6-of-30 silent-miss regression is back"
    )
    by_scen: dict[str, set[int]] = {}
    for r in results:
        assert r["candidate"] == "trinity-mini"
        by_scen.setdefault(r["scenario"], set()).add(r["trial"])
    assert sorted(by_scen) == TEN_SCENARIOS
    assert all(trials == {1, 2, 3} for trials in by_scen.values())


def test_collect_skips_files_missing_wall_time(va, tmp_path: Path):
    p = _write_trial(
        tmp_path,
        scenario="01-trivial-rename",
        candidate="trinity-mini",
        trial=1,
        wall_seconds=None,
    )
    parsed = va.parse_result_file(p, "trinity-mini")
    assert parsed is not None and parsed["wall_seconds"] is None
    assert va.collect_cohort_results(tmp_path, "trinity-mini") == []


# --- Detector units -----------------------------------------------------------


def _trials(walls_by_scenario: dict[str, list[int]], verdict: str = "OK"):
    """Build minimal in-memory result dicts for the detector functions."""
    out = []
    for scen, walls in walls_by_scenario.items():
        for i, w in enumerate(walls, start=1):
            out.append(
                {
                    "path": Path(
                        f"/fake/{scen}-x-trial{i}-20260601T000000Z.md"
                    ),
                    "scenario": scen,
                    "candidate": "x",
                    "trial": i,
                    "ts": "20260601T000000Z",
                    "wall_seconds": w,
                    "verdict": verdict,
                }
            )
    return out


def test_within_scenario_outlier_flagged(va):
    flags = va.detect_within_scenario_outliers(
        _trials({"01-trivial-rename": [40, 45, 150]})
    )
    assert len(flags) == 1
    assert "WITHIN-SCENARIO OUTLIER" in flags[0]
    assert "trial3" in flags[0]


def test_within_scenario_tight_cluster_clean(va):
    flags = va.detect_within_scenario_outliers(
        _trials({"01-trivial-rename": [40, 45, 50]})
    )
    assert flags == []


def test_within_scenario_single_trial_skipped(va):
    """One trial has no meaningful median — must not flag (or crash)."""
    assert va.detect_within_scenario_outliers(_trials({"01-x": [40]})) == []


def test_cross_scenario_anomaly_flagged(va):
    flags = va.detect_cross_scenario_anomaly(
        _trials({"01-fast": [10, 10, 10], "02-slow": [150, 150, 150]})
    )
    assert len(flags) == 1
    assert "CROSS-SCENARIO ANOMALY" in flags[0]


def test_cross_scenario_within_threshold_clean(va):
    flags = va.detect_cross_scenario_anomaly(
        _trials({"01-fast": [10, 10, 10], "02-slow": [80, 80, 80]})
    )
    assert flags == []


def test_cross_scenario_zero_median_known_gap(va):
    """KNOWN GAP: fastest-scenario median of 0s short-circuits the ratio to 0,
    so an INFINITE anomaly (instant short-circuit vs long trials) is never
    flagged. Pins current behavior — see KNOWN-GAPS.md."""
    flags = va.detect_cross_scenario_anomaly(
        _trials({"01-fast": [0, 0, 0], "02-slow": [500, 500, 500]})
    )
    assert flags == []  # should arguably flag; documented gap


def test_non_ok_verdict_flagged(va):
    flags = va.detect_verdict_anomalies(
        _trials({"01-trivial-rename": [40, 45]}, verdict="TIMEOUT")
    )
    assert len(flags) == 2
    assert all("NON-OK VERDICT" in f and "TIMEOUT" in f for f in flags)


def test_ok_verdict_not_flagged(va):
    assert va.detect_verdict_anomalies(_trials({"01-x": [40, 45]})) == []


def test_systemic_failure_marker_detected(va, uniform_failure_dir: Path):
    """detect_systemic_failure DOES catch the uniform-error cohort when
    invoked directly... but note it is opt-in, not wired into main()."""
    results = va.collect_cohort_results(uniform_failure_dir, "trinity-mini")
    flags = va.detect_systemic_failure(results)
    assert any("SYSTEMIC FAILURE" in f and "API Error: 500" in f for f in flags)


def test_uniform_failure_passes_all_variance_detectors(va, uniform_failure_dir):
    """The structural blindness, pinned at unit level (postmortem #10):
    a cohort of IDENTICAL failures is invisible to every variance check —
    uniform walls produce no outliers, no cross-scenario skew, and the
    runner's verdict_tag says OK."""
    results = va.collect_cohort_results(uniform_failure_dir, "trinity-mini")
    assert len(results) == 6
    assert va.detect_within_scenario_outliers(results) == []
    assert va.detect_cross_scenario_anomaly(results) == []
    assert va.detect_verdict_anomalies(results) == []


# --- CLI / --strict exit semantics --------------------------------------------


def test_cli_missing_results_dir_exit_2(tmp_path: Path):
    proc = _run_variance(
        "--results-dir", str(tmp_path / "nope"), "--cohort", "trinity-mini"
    )
    assert proc.returncode == 2
    assert "not found" in proc.stderr


def test_cli_no_matching_cohort_exit_2(clean_cohort_dir: Path):
    proc = _run_variance(
        "--results-dir", str(clean_cohort_dir), "--cohort", "devstral"
    )
    assert proc.returncode == 2
    assert "no result files matched" in proc.stderr


def test_cli_clean_cohort_exit_0(
    clean_cohort_dir: Path, sample_scenarios_dir: Path
):
    proc = _run_variance(
        "--results-dir",
        str(clean_cohort_dir),
        "--cohort",
        "trinity-mini",
        "--scenarios-dir",
        str(sample_scenarios_dir),
        "--strict",
    )
    assert proc.returncode == 0, proc.stderr
    assert "no variance anomalies" in proc.stdout
    assert "6 PASS" in proc.stdout  # Tier 1 actually ran


def test_cli_outlier_reports_but_exits_0_without_strict(tmp_path: Path):
    for trial, wall in ((1, 40), (2, 45), (3, 200)):
        _write_trial(
            tmp_path,
            scenario="01-trivial-rename",
            candidate="trinity-mini",
            trial=trial,
            wall_seconds=wall,
        )
    proc = _run_variance(
        "--results-dir", str(tmp_path), "--cohort", "trinity-mini"
    )
    assert proc.returncode == 0  # report-only without --strict
    assert "WITHIN-SCENARIO OUTLIER" in proc.stderr


def test_cli_outlier_strict_exit_1(tmp_path: Path):
    for trial, wall in ((1, 40), (2, 45), (3, 200)):
        _write_trial(
            tmp_path,
            scenario="01-trivial-rename",
            candidate="trinity-mini",
            trial=trial,
            wall_seconds=wall,
        )
    proc = _run_variance(
        "--results-dir", str(tmp_path), "--cohort", "trinity-mini", "--strict"
    )
    assert proc.returncode == 1
    assert "WITHIN-SCENARIO OUTLIER" in proc.stderr


def test_cli_timeout_verdict_strict_exit_1(tmp_path: Path):
    for trial, verdict in ((1, "OK"), (2, "TIMEOUT"), (3, "OK")):
        _write_trial(
            tmp_path,
            scenario="01-trivial-rename",
            candidate="trinity-mini",
            trial=trial,
            wall_seconds=45,
            verdict=verdict,
        )
    proc = _run_variance(
        "--results-dir", str(tmp_path), "--cohort", "trinity-mini", "--strict"
    )
    assert proc.returncode == 1
    assert "NON-OK VERDICT" in proc.stderr


def test_cli_uniform_failure_without_scenarios_dir_passes_strict_known_gap(
    uniform_failure_dir: Path,
):
    """KNOWN GAP (postmortem #10, the rw2 disaster): without --scenarios-dir,
    --strict exits 0 on a cohort where EVERY trial failed identically.
    The script at least warns that the PASS-rate check was skipped.
    Pins current behavior — see KNOWN-GAPS.md."""
    proc = _run_variance(
        "--results-dir",
        str(uniform_failure_dir),
        "--cohort",
        "trinity-mini",
        "--strict",
    )
    assert proc.returncode == 0  # 270 garbage trials would sail through
    assert "PASS-rate check SKIPPED" in proc.stdout


def test_cli_uniform_failure_strict_exits_nonzero(
    uniform_failure_dir: Path, sample_scenarios_dir: Path
):
    """THE HEADLINE REGRESSION (rw2 / postmortem #1+#10): a synthetic cohort
    where every trial fails identically — uniform error text, verdict_tag
    OK, uniform wall times — MUST fail `--strict` once the Tier 1
    PASS-rate check is enabled via --scenarios-dir."""
    proc = _run_variance(
        "--results-dir",
        str(uniform_failure_dir),
        "--cohort",
        "trinity-mini",
        "--scenarios-dir",
        str(sample_scenarios_dir),
        "--strict",
    )
    assert proc.returncode == 1, (
        "uniform-failure cohort passed --strict — the rw2 class of "
        f"garbage cohort is invisible again.\nstdout: {proc.stdout}\n"
        f"stderr: {proc.stderr}"
    )
    assert "LOW PASS RATE" in proc.stderr
    assert "0/6 trials PASS" in proc.stderr


def test_cli_uniform_failure_without_strict_reports_only(
    uniform_failure_dir: Path, sample_scenarios_dir: Path
):
    proc = _run_variance(
        "--results-dir",
        str(uniform_failure_dir),
        "--cohort",
        "trinity-mini",
        "--scenarios-dir",
        str(sample_scenarios_dir),
    )
    assert proc.returncode == 0  # advisory without --strict
    assert "LOW PASS RATE" in proc.stderr


def test_cli_min_pass_rate_flag(tmp_path: Path, sample_scenarios_dir: Path):
    """A 50%-PASS cohort clears the default 0.30 floor but must fail a
    --min-pass-rate 0.75 floor."""
    for trial in (1, 2, 3):  # PASS trials
        _write_trial(
            tmp_path,
            scenario="01-trivial-rename",
            candidate="trinity-mini",
            trial=trial,
            wall_seconds=40 + trial,
        )
    for trial in (1, 2, 3):  # FAIL trials (no honest-failure language)
        _write_trial(
            tmp_path,
            scenario="10-honest-failure",
            candidate="trinity-mini",
            trial=trial,
            wall_seconds=12 + trial,
            output="The answer is fine. DONE",
            sandbox="    (no files in s10 sandbox)",
        )
    base = [
        "--results-dir",
        str(tmp_path),
        "--cohort",
        "trinity-mini",
        "--scenarios-dir",
        str(sample_scenarios_dir),
        "--strict",
    ]
    assert _run_variance(*base).returncode == 0
    strict = _run_variance(*base, "--min-pass-rate", "0.75")
    assert strict.returncode == 1
    assert "LOW PASS RATE" in strict.stderr


def test_cli_nonexistent_scenarios_dir_warns_and_skips(
    clean_cohort_dir: Path, tmp_path: Path
):
    proc = _run_variance(
        "--results-dir",
        str(clean_cohort_dir),
        "--cohort",
        "trinity-mini",
        "--scenarios-dir",
        str(tmp_path / "no-scenarios-here"),
        "--strict",
    )
    assert proc.returncode == 0
    assert "skipping Tier 1 PASS-rate check" in proc.stderr
