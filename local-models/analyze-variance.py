#!/usr/bin/env python3
"""analyze-variance.py — cross-trial + cross-scenario variance + PASS-rate check.

Harness for the "compare across runs, not within one" discipline PLUS the
"absolute-success-rate" check (the missing fourth habit from
feedback-silent-success-pattern). Detects contamination/anomalies in
bench-matrix.sh output by combining wall-time variance with Tier 1
PASS/FAIL/INCONCLUSIVE scoring from analyze-bench.py.

Beads:
  - local-coding-models-u3y follow-up (variance checks)
  - local-coding-models-rw2 (PASS-rate check — closes the gap that let v2's
    270 garbage trials pass the variance harness as "uniform = clean")
MEMORY: feedback-silent-success-pattern habits #2 + #4.

CLI:
    python3 analyze-variance.py --results-dir DIR --cohort CANDIDATE
    python3 analyze-variance.py --results-dir DIR --cohort CANDIDATE --strict
    python3 analyze-variance.py --results-dir DIR --cohort CANDIDATE \
        --scenarios-dir DIR [--min-pass-rate 0.30]

Exit codes:
    0 = no anomalies detected
    1 = anomalies detected (cohort likely contaminated OR systemic failure);
        reasons on stderr
    2 = usage error / no results found

Checks:
  1. Within-scenario trial variance: trials of the same scenario within the
     cohort should cluster. Flag any trial > 2x the median of the same
     (scenario, cohort). Three-trial median is robust to one outlier.
  2. Cross-scenario median ratio: in a clean cohort, fast/slow scenarios
     usually fall within ~5x. Flag if (max_scenario_median /
     min_scenario_median) > 10x — strong signal that one scenario is being
     starved (memory pressure, network, contention).
  3. Verdict-shape check (round-2 vocabulary, bead dotfiles-6go): flags
     SYSTEMIC shapes only — INVALID_ROUTING anywhere, zero successes
     across the cohort (uniform-failure, rw2), unknown verdict strings,
     and SYSTEMIC_FAIL marker files in the results dir. Individual
     TIMEOUT / ARTIFACT_FAIL / INFRA_FAIL trials are legitimate
     measurements on realistic pass rates — they are counted by the
     pass-rate check, NOT flagged per-trial. TIMEOUT_SUCCESS counts as
     success (artifact matched; only the DONE ack was killed).
  4. (--scenarios-dir) Absolute PASS rate via Tier 1 grep-runner. Flag the
     cohort if PASS-rate < min_pass_rate. Variance alone cannot tell uniform
     success from uniform failure; this is the missing fourth habit. The
     v2-garbage case had 0 PASS / 270 trials, all variance-clean.

--strict makes anomaly cohorts exit non-zero so callers (bench-matrix.sh)
can abort. Without --strict, it just reports.
"""

from __future__ import annotations

import argparse
import importlib.util
import re
import statistics
import sys
from pathlib import Path


def _load_analyze_bench():
    """Load analyze-bench.py via importlib (hyphen in filename blocks `import`)."""
    sibling = Path(__file__).parent / "analyze-bench.py"
    spec = importlib.util.spec_from_file_location("analyze_bench", sibling)
    if spec is None or spec.loader is None:
        return None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# Result file name shape:
#   <scenario_base>-<candidate>-trial<N>-<UTCTS>.md
# Example:
#   01-trivial-rename-trinity-mini-trial1-20260531T002602Z.md
#
# Naive regex `(scen)-(cand)-trial...` is AMBIGUOUS because both `scen` and
# `cand` are kebab-case strings containing `-`. The split point is unrecoverable
# from the regex alone. The caller passes the candidate; we anchor on
# `-{candidate}-trial` to recover scenario unambiguously.
WALL_RE = re.compile(r"\*\*Wall time\*\*:\s*(\d+)s")
VERDICT_RE = re.compile(r"\*\*verdict_tag\*\*:\s*(\w+)")
TAIL_RE = re.compile(r"^trial(?P<trial>[1-9])-(?P<ts>\d{8}T\d{6}Z)\.md$")
SCEN_RE = re.compile(r"^\d{2}-[a-z0-9-]+$")


def parse_result_file(path: Path, candidate: str) -> dict | None:
    """Pull (scenario, trial, wall_seconds, verdict_tag) from a result .md.

    `candidate` is required: kebab-case scenario+candidate share `-` as both
    separator and intra-name char, so the split is unrecoverable from regex
    alone. Anchor on `-{candidate}-trial`.
    """
    name = path.name
    anchor = f"-{candidate}-trial"
    if anchor not in name:
        return None
    pos = name.index(anchor)
    scen = name[:pos]
    tail = name[pos + len(f"-{candidate}-") :]  # leaves "trial<N>-<TS>.md"
    if not SCEN_RE.match(scen):
        return None
    m = TAIL_RE.match(tail)
    if not m:
        return None
    body = path.read_text(errors="replace")
    wall_m = WALL_RE.search(body)
    verdict_m = VERDICT_RE.search(body)
    return {
        "path": path,
        "scenario": scen,
        "candidate": candidate,
        "trial": int(m.group("trial")),
        "ts": m.group("ts"),
        "wall_seconds": int(wall_m.group(1)) if wall_m else None,
        "verdict": verdict_m.group(1) if verdict_m else None,
    }


def collect_cohort_results(results_dir: Path, cohort: str) -> list[dict]:
    """Find all result files for the given candidate cohort.

    Anchors on candidate name to avoid the kebab-case scen+cand ambiguity.
    """
    all_md = sorted(results_dir.glob("*.md"))
    out = []
    for p in all_md:
        parsed = parse_result_file(p, cohort)
        if parsed and parsed["wall_seconds"] is not None:
            out.append(parsed)
    return out


def detect_within_scenario_outliers(results: list[dict]) -> list[str]:
    """Per scenario, flag any trial whose wall_seconds > 2x the scenario's median."""
    flags: list[str] = []
    by_scen: dict[str, list[dict]] = {}
    for r in results:
        by_scen.setdefault(r["scenario"], []).append(r)
    for scen, trials in sorted(by_scen.items()):
        if len(trials) < 2:
            continue  # can't compute median meaningfully on 1 trial
        walls = sorted(t["wall_seconds"] for t in trials)
        med = statistics.median(walls)
        for t in trials:
            if t["wall_seconds"] > 2 * med and med > 0:
                ratio = t["wall_seconds"] / med
                flags.append(
                    f"WITHIN-SCENARIO OUTLIER: {scen} trial{t['trial']} "
                    f"= {t['wall_seconds']}s vs scenario median {med:.0f}s "
                    f"(ratio {ratio:.1f}x). File: {t['path'].name}"
                )
    return flags


def detect_cross_scenario_anomaly(results: list[dict]) -> list[str]:
    """If max_scenario_median / min_scenario_median > 10x, flag the cohort.

    Reasoning: scenarios vary in difficulty + token count, but a 10x median
    ratio strongly suggests either:
      - The slow scenario is being starved (memory pressure, contention)
      - The fast scenario is short-circuiting (model giving up / no work done)
    """
    flags: list[str] = []
    by_scen: dict[str, list[int]] = {}
    for r in results:
        by_scen.setdefault(r["scenario"], []).append(r["wall_seconds"])
    medians = {
        scen: statistics.median(walls)
        for scen, walls in by_scen.items()
        if walls
    }
    if len(medians) < 2:
        return flags  # need ≥2 scenarios to compare
    fastest_scen = min(medians, key=medians.get)
    slowest_scen = max(medians, key=medians.get)
    ratio = (
        medians[slowest_scen] / medians[fastest_scen]
        if medians[fastest_scen] > 0
        else 0
    )
    if ratio > 10:
        flags.append(
            f"CROSS-SCENARIO ANOMALY: {slowest_scen} median "
            f"{medians[slowest_scen]:.0f}s vs {fastest_scen} median "
            f"{medians[fastest_scen]:.0f}s (ratio {ratio:.1f}x > 10x threshold). "
            f"This cohort is likely contaminated by memory pressure or "
            f"another process competing for the backend's GPU/CPU."
        )
    return flags


# Round-2 verdict vocabulary (run-scenario.sh, bead dotfiles-6go).
# SUCCESS = the trial carries a success artifact. TIMEOUT_SUCCESS is the
# e21 case: wall cap killed the run AFTER the work was done — the sandbox
# matched the scenario's Expected artifacts, only the DONE ack was lost.
SUCCESS_VERDICTS = {"OK", "TIMEOUT_SUCCESS"}
# Legitimate non-success measurements: the harness worked, the model (or
# the wall clock, or the infra for that one trial) didn't. These are DATA
# on realistic pass rates — never per-trial abort flags. Their aggregate
# weight is governed by the Tier-1 pass-rate check + bench-matrix's
# absolute success floor.
DATA_VERDICTS = {"TIMEOUT", "ARTIFACT_FAIL", "INFRA_FAIL"}


def detect_verdict_anomalies(results: list[dict]) -> list[str]:
    """Flag SYSTEMIC verdict shapes, not individual failed trials.

    Strict-abort is reserved for shapes that invalidate the whole cohort:
      - INVALID_ROUTING anywhere: the wrong model served a trial; every
        measurement in the cohort is suspect (postmortem #2).
      - Zero successes across the cohort: the rw2 uniform-failure shape —
        nothing produced a success artifact (postmortem #1/#10).
      - Unknown verdict strings: vocabulary drift between the runner and
        this analyzer must surface loudly, not pass silently.

    Individual TIMEOUT / ARTIFACT_FAIL / INFRA_FAIL trials are NOT flagged
    here (they were pre-2026-06-10, which made --strict abort the matrix on
    any single honest failure — the gate-composition bug this rewrite
    fixes).
    """
    flags: list[str] = []
    tagged = [r for r in results if r["verdict"]]
    if not tagged:
        return flags
    successes = [r for r in tagged if r["verdict"] in SUCCESS_VERDICTS]
    for r in tagged:
        if r["verdict"] == "INVALID_ROUTING":
            flags.append(
                f"INVALID_ROUTING: {r['scenario']} trial{r['trial']} was "
                f"served by the wrong model — the cohort's measurements "
                f"cannot be attributed. File: {r['path'].name}"
            )
        elif r["verdict"] not in SUCCESS_VERDICTS | DATA_VERDICTS:
            flags.append(
                f"UNKNOWN VERDICT: {r['scenario']} trial{r['trial']} = "
                f"{r['verdict']} — not in the round-2 vocabulary "
                f"(runner/analyzer drift?). File: {r['path'].name}"
            )
    if not successes:
        sample = ", ".join(
            f"{r['scenario']} trial{r['trial']}={r['verdict']}"
            for r in tagged[:3]
        )
        flags.append(
            f"ZERO SUCCESSES: 0/{len(tagged)} tagged trials carry a success "
            f"verdict ({'/'.join(sorted(SUCCESS_VERDICTS))}) — the rw2 "
            f"uniform-failure shape. Sample: {sample}"
        )
    return flags


def detect_systemic_fail_markers(results_dir: Path, cohort: str) -> list[str]:
    """Flag SYSTEMIC_FAIL marker files bench-matrix.sh wrote for this cohort.

    bench-matrix writes ``SYSTEMIC_FAIL-<cohort>-<ts>.txt`` when a cohort
    cleared zero success artifacts; if the analyzer runs over such a dir
    (e.g. a re-analysis after the abort), the marker must keep flagging.
    """
    flags: list[str] = []
    for marker in sorted(results_dir.glob(f"SYSTEMIC_FAIL-{cohort}-*.txt")):
        flags.append(
            f"SYSTEMIC_FAIL MARKER: {marker.name} present in results dir — "
            f"bench-matrix recorded a zero-success cohort here; do not trust "
            f"these results without diagnosis."
        )
    return flags


# Known systemic-error markers — substrings that appear in EVERY result file
# of a broken run. The matrix-v2 failure on 2026-05-31 had "API Error: 500
# fetch failed" in every one of 270 trials; variance check didn't catch it
# because failures clustered. This check is the missing ABSOLUTE-success-rate
# habit: variance alone can't tell uniform-success from uniform-failure.
SYSTEMIC_ERROR_MARKERS = [
    "API Error: 500",
    "fetch failed",
    "rate limit",
    "ECONNREFUSED",
    "Connection refused",
    "model not found",
]


def detect_systemic_failure(
    results: list[dict], min_success_rate: float = 0.5
) -> list[str]:
    """Flag the cohort if too many trials contain known systemic-error markers.

    Reads each trial's body (already cached in path) for SYSTEMIC_ERROR_MARKERS
    strings. If MORE than (1-min_success_rate) of trials hit a known marker,
    the whole cohort is flagged as systemically failing — distinct from
    contamination/outliers. This catches the layer-mismatch failure mode
    where the harness checked the wrong code path and the bench's actual
    path was returning errors for every trial.
    """
    flags: list[str] = []
    if not results:
        return flags
    err_counts: dict[str, int] = dict.fromkeys(SYSTEMIC_ERROR_MARKERS, 0)
    err_files: dict[str, list[str]] = {
        marker: [] for marker in SYSTEMIC_ERROR_MARKERS
    }
    for r in results:
        body = r["path"].read_text(errors="replace")
        for marker in SYSTEMIC_ERROR_MARKERS:
            if marker in body:
                err_counts[marker] += 1
                err_files[marker].append(r["path"].name)
    total = len(results)
    fail_threshold = int(total * (1 - min_success_rate))
    for marker, count in err_counts.items():
        if count > fail_threshold:
            sample = err_files[marker][:2]
            flags.append(
                f"SYSTEMIC FAILURE: {count}/{total} trials contain '{marker}'. "
                f"Cohort cannot be trusted — every trial likely hit the same "
                f"infrastructure error (CCR / network / model-load). "
                f"Sample files: {', '.join(sample)}"
            )
    return flags


def detect_low_pass_rate(
    results: list[dict],
    scenarios_dir: Path,
    min_pass_rate: float = 0.30,
) -> list[str]:
    """Flag the cohort if Tier 1 PASS rate falls below ``min_pass_rate``.

    The missing fourth habit. Variance alone cannot tell uniform-success
    from uniform-failure — matrix v2 was 270 trials of garbage that all
    clustered to the same wall time and all reported verdict_tag=OK.
    Tier 1 (analyze-bench.score_trial) deterministically scores each
    trial as PASS / FAIL / INCONCLUSIVE by parsing the scenario's
    ``## Pass criteria`` block.

    If fewer than ``min_pass_rate`` of trials PASS, flag the cohort as
    systemically failing — distinct from the variance/outlier flags.

    A threshold of 0.30 means at least 9/30 trials must PASS to clear.
    v2-garbage scored 0/270 PASS; even threshold 1% catches it. A clean
    cohort typically scores 0.7-1.0 across scenarios it can handle.
    INCONCLUSIVE trials count as neither PASS nor FAIL — the rate is
    PASS_count / total_count.
    """
    flags: list[str] = []
    if not results:
        return flags
    bench = _load_analyze_bench()
    if bench is None:
        flags.append(
            "PASS-RATE CHECK SKIPPED: could not import analyze-bench.py "
            "(file missing or unreadable). Variance flags alone CANNOT "
            "distinguish uniform success from uniform failure — re-run with "
            "analyze-bench.py reachable."
        )
        return flags
    verdicts: dict[str, int] = {"PASS": 0, "FAIL": 0, "INCONCLUSIVE": 0}
    per_trial: list[tuple[str, str]] = []
    for r in results:
        try:
            verdict = bench.score_trial(
                trial_path=r["path"], scenarios_dir=scenarios_dir
            )
        except Exception as e:
            verdict = "INCONCLUSIVE"
            per_trial.append((r["path"].name, f"INCONCLUSIVE (error: {e})"))
            verdicts["INCONCLUSIVE"] += 1
            continue
        if verdict not in verdicts:
            verdict = "INCONCLUSIVE"
        verdicts[verdict] += 1
        per_trial.append((r["path"].name, verdict))
    total = len(results)
    pass_rate = verdicts["PASS"] / total if total else 0.0
    summary = (
        f"Tier 1 verdicts: {verdicts['PASS']} PASS, {verdicts['FAIL']} FAIL, "
        f"{verdicts['INCONCLUSIVE']} INCONCLUSIVE (PASS rate "
        f"{pass_rate * 100:.0f}%)"
    )
    print(f"  {summary}")
    if pass_rate < min_pass_rate:
        flags.append(
            f"LOW PASS RATE: {verdicts['PASS']}/{total} trials PASS "
            f"({pass_rate * 100:.0f}% < {min_pass_rate * 100:.0f}% threshold). "
            f"Cohort cannot be trusted as a measurement — investigate before "
            f"drawing conclusions. {verdicts['FAIL']} FAIL, "
            f"{verdicts['INCONCLUSIVE']} INCONCLUSIVE."
        )
    return flags


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--results-dir", type=Path, required=True)
    parser.add_argument(
        "--cohort", required=True, help="candidate name, e.g. trinity-mini"
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit nonzero on any flag (so bench-matrix.sh can abort)",
    )
    parser.add_argument(
        "--scenarios-dir",
        type=Path,
        default=None,
        help=(
            "scenarios dir containing <scen>.md files; enables Tier 1 "
            "PASS-rate check via analyze-bench.score_trial. Without this "
            "flag, only variance/outlier checks run (uniform-failure cohorts "
            "will not be flagged)."
        ),
    )
    parser.add_argument(
        "--min-pass-rate",
        type=float,
        default=0.30,
        help=(
            "minimum fraction of trials that must Tier-1 PASS for the cohort "
            "to clear the absolute-success check (default 0.30; only used "
            "when --scenarios-dir is supplied)"
        ),
    )
    args = parser.parse_args(argv)

    if not args.results_dir.exists():
        print(
            f"error: results-dir {args.results_dir} not found", file=sys.stderr
        )
        return 2

    results = collect_cohort_results(args.results_dir, args.cohort)
    if not results:
        print(
            f"error: no result files matched cohort={args.cohort}",
            file=sys.stderr,
        )
        return 2

    print(
        f"analyze-variance: cohort={args.cohort}, {len(results)} trials across "
        f"{len({r['scenario'] for r in results})} scenarios"
    )

    all_flags: list[str] = []
    all_flags.extend(detect_within_scenario_outliers(results))
    all_flags.extend(detect_cross_scenario_anomaly(results))
    all_flags.extend(detect_verdict_anomalies(results))
    all_flags.extend(
        detect_systemic_fail_markers(args.results_dir, args.cohort)
    )
    if args.scenarios_dir is not None:
        if not args.scenarios_dir.exists():
            print(
                f"warning: --scenarios-dir {args.scenarios_dir} not found; "
                f"skipping Tier 1 PASS-rate check",
                file=sys.stderr,
            )
        else:
            all_flags.extend(
                detect_low_pass_rate(
                    results, args.scenarios_dir, args.min_pass_rate
                )
            )
    else:
        print(
            "  ⚠ Tier 1 PASS-rate check SKIPPED (no --scenarios-dir). "
            "Variance flags alone cannot detect uniform-failure cohorts "
            "(see local-coding-models-rw2 — the v2-garbage scenario)."
        )

    # detect_systemic_failure() remains opt-in only — it's a string-match
    # forensic tool for known-garbage cohorts. Use the Tier 1 PASS-rate
    # check above instead for production gating.

    if all_flags:
        print(
            f"\n⚠ {len(all_flags)} variance flag(s) for cohort '{args.cohort}':",
            file=sys.stderr,
        )
        for f in all_flags:
            print(f"  ⚠ {f}", file=sys.stderr)
        return 1 if args.strict else 0
    else:
        print(f"  ✓ no variance anomalies in cohort '{args.cohort}'")
        return 0


if __name__ == "__main__":
    sys.exit(main())
