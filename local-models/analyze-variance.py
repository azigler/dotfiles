#!/usr/bin/env python3
"""analyze-variance.py — cross-trial + cross-scenario variance check.

Harness for the "compare across runs, not within one" discipline. Detects
contamination/anomalies in bench-matrix.sh output by comparing wall times
within a cohort. Catches the V1 trinity-mini failure mode (scenario 01 at
685s while scenario 03 was 181s — 3.7x outlier, clearly contaminated).

Bead: local-coding-models-u3y follow-up.
MEMORY: feedback-silent-success-pattern habit #2.

CLI:
    python3 analyze-variance.py --results-dir DIR --cohort CANDIDATE
    python3 analyze-variance.py --results-dir DIR --cohort CANDIDATE --strict

Exit codes:
    0 = no anomalies detected
    1 = anomalies detected (cohort likely contaminated); reasons on stderr
    2 = usage error / no results found

Two checks:
  1. Within-scenario trial variance: trials of the same scenario within the
     cohort should cluster. Flag any trial > 2x the median of the same
     (scenario, cohort). Three-trial median is robust to one outlier.
  2. Cross-scenario median ratio: in a clean cohort, fast/slow scenarios
     usually fall within ~5x. Flag if (max_scenario_median /
     min_scenario_median) > 10x — strong signal that one scenario is being
     starved (memory pressure, network, contention).

--strict makes anomaly cohorts exit non-zero so callers (bench-matrix.sh)
can abort. Without --strict, it just reports.
"""

from __future__ import annotations

import argparse
import re
import statistics
import sys
from pathlib import Path

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


def detect_verdict_anomalies(results: list[dict]) -> list[str]:
    """Flag any non-OK verdict — TIMEOUT, FAIL, etc."""
    flags: list[str] = []
    for r in results:
        if r["verdict"] and r["verdict"] != "OK":
            flags.append(
                f"NON-OK VERDICT: {r['scenario']} trial{r['trial']} "
                f"= {r['verdict']} (wall={r['wall_seconds']}s). "
                f"File: {r['path'].name}"
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
