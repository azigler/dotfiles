#!/usr/bin/env python3
"""analyze-bench.py — Tier 1 grep-runner + parity-matrix aggregator.

Wave 1 of dotfiles-ukx.13 Phase 3. Implements the Tier 1 deterministic
grep-runner per OQ-03 MODIFY:

    Tier 1 (this file): parse each scenario's ``## Pass criteria`` block
                        and run the bulleted assertions against the
                        trial's captured sandbox state + Claude output.
                        Verdict: PASS / FAIL / INCONCLUSIVE.

    Tier 2 (Wave 4):    LLM-as-judge cascade for INCONCLUSIVE trials.
                        Hook left as ``EXTENSION POINT`` below.

    Tier 3 (Wave 4):    human review for judge-UNSURE / low-confidence
                        trials. Hook left as ``EXTENSION POINT`` below.

CLI:
    python3 analyze-bench.py \\
        --results-dir <DIR> \\
        --scenarios-dir <DIR> \\
        --out <FILE> \\
        [--format markdown|json]

Spec: dotfiles-ukx.13 §4.3, §4.4
Test bead: dotfiles-ukx.13.2
Impl bead: dotfiles-ukx.13.3
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

# ---------------------------------------------------------------------------
# Tier 1 grep-runner — module-level functions per /test contract Step 3.5
# (score_trial must delegate to grep_runner; spy test in test_analyze_bench.py)
# ---------------------------------------------------------------------------


def parse_pass_criteria(scenario_path: Path) -> list[str]:
    """Return the bulleted lines from a scenario's ``## Pass criteria`` block.

    Each scenarios/*.md file has a ``## Pass criteria`` section with bullet
    lines like ``- File X exists`` or ``- `grep -c 'PAT' PATH` equals `1` ``.
    The Tier 1 grep-runner evaluates each bullet against the trial.

    Returns an empty list if the section is missing or empty — Wave 1
    contract is "no criteria → grep_runner returns INCONCLUSIVE" (test
    test_analyze_bench_skips_missing_pass_criteria).
    """
    if not scenario_path.exists():
        return []
    text = scenario_path.read_text()
    bullets: list[str] = []
    in_block = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped == "## Pass criteria":
            in_block = True
            continue
        if in_block and stripped.startswith("## "):
            # Next section reached
            break
        if in_block and stripped.startswith("- "):
            # Strip the leading "- " marker
            bullets.append(stripped[2:].strip())
    return bullets


# Regexes used by the grep_runner --------------------------------------------

# Matches: `grep -c 'PAT' PATH` equals `N`  (with various quoting)
_GREP_COUNT_RE = re.compile(
    r"`\s*grep\s+-c\s+['\"]?(?P<pat>.+?)['\"]?\s+(?P<path>\S+?)\s*`\s+equals\s+`?(?P<n>\d+)`?",
    re.IGNORECASE,
)

# Matches: File `PATH` exists  /  File PATH exists
_FILE_EXISTS_RE = re.compile(
    r"^file\s+`?(?P<path>\S+?)`?\s+exists\b",
    re.IGNORECASE,
)

# Matches: (Final|Model) (model )?output contains [the word] `WORD`/WORD
_OUTPUT_CONTAINS_RE = re.compile(
    r"(?:final\s+)?model\s+output\s+(?P<neg>does\s+NOT\s+|does\s+not\s+)?contains?\b\s*"
    r"(?:the\s+word\s+)?(?:a\s+)?(?P<rest>.+)$",
    re.IGNORECASE,
)

# FILECONTENTS marker emitted by the test conftest sandbox snapshots:
#   FILECONTENTS:/tmp/foo/bar.py:def sum_two(): pass
_FILECONTENTS_RE = re.compile(
    r"^FILECONTENTS:(?P<path>[^:]+):(?P<body>.*)$",
)


def _extract_trial_section(trial_text: str, heading: str) -> str:
    """Extract a `## <heading>` section body from a trial result file."""
    lines = trial_text.splitlines()
    out: list[str] = []
    capture = False
    target = f"## {heading}"
    for line in lines:
        if line.strip() == target:
            capture = True
            continue
        if capture and line.startswith("## "):
            break
        if capture:
            out.append(line)
    return "\n".join(out)


def _extract_filecontents_map(sandbox_state: str) -> dict[str, str]:
    """Read FILECONTENTS:<path>:<body> lines into a {path: body} map."""
    result: dict[str, str] = {}
    for line in sandbox_state.splitlines():
        m = _FILECONTENTS_RE.match(line.strip())
        if m:
            result[m.group("path")] = m.group("body")
    return result


def _extract_listed_paths(sandbox_state: str) -> set[str]:
    """Lines from the sandbox snapshot are `    /tmp/foo` paths."""
    paths: set[str] = set()
    for line in sandbox_state.splitlines():
        s = line.strip()
        if s.startswith("/") and not s.startswith("/*"):
            paths.add(s)
    return paths


def _check_grep_count(
    pat: str, path: str, expected: int, contents_map: dict[str, str]
) -> bool | None:
    """Run a `grep -c PAT PATH` check against captured file contents.

    Returns:
        True  - count matches expected (PASS)
        False - count differs (FAIL)
        None  - couldn't resolve (file not in contents map → INCONCLUSIVE)
    """
    # Look up by exact path; fall back to suffix match (the trial may store
    # contents under a slightly different prefix).
    body = contents_map.get(path)
    if body is None:
        for k, v in contents_map.items():
            if k.endswith(path) or path.endswith(k):
                body = v
                break
    if body is None:
        # Try the real filesystem (for end-to-end runs where the sandbox
        # actually persists on disk — Wave 3+ work).
        p = Path(path)
        if p.exists() and p.is_file():
            try:
                body = p.read_text()
            except OSError:
                return None
        else:
            return None
    # `grep -c` counts MATCHING LINES, not occurrences. Re-implement.
    try:
        matcher = re.compile(pat)
    except re.error:
        return None
    count = sum(1 for line in body.splitlines() if matcher.search(line))
    return count == expected


def _check_file_exists(
    path: str, listed_paths: set[str], contents_map: dict[str, str]
) -> bool | None:
    if path in contents_map or path in listed_paths:
        return True
    # suffix-match fallback
    for k in listed_paths | set(contents_map.keys()):
        if k.endswith(path):
            return True
    # Real filesystem fallback
    return bool(Path(path).exists())


def _check_output_contains(
    rest: str, claude_output: str, negate: bool
) -> bool | None:
    """Check whether claude_output contains the (backtick-quoted) word(s).

    `rest` is whatever followed the "contains" keyword. We extract any
    backtick-wrapped tokens (the convention) — multiple tokens joined by
    OR (per the s10 honest-failure scenario: ``contains `X` OR `Y` OR
    `Z```)."""
    # Pull backticked tokens out of rest; if none, treat the trailing
    # text itself as the needle (lower-fidelity match).
    tokens = re.findall(r"`([^`]+)`", rest)
    if not tokens:
        # Fallback: strip punctuation and treat rest as a single needle
        needle = rest.strip().rstrip(".").strip()
        tokens = [needle] if needle else []
    haystack = claude_output
    if not tokens:
        return None
    any_match = any(t and t in haystack for t in tokens)
    if negate:
        return not any_match
    return any_match


def grep_runner(*, scenario_path: Path, trial_path: Path) -> str:
    """Tier 1 grep-runner: PASS / FAIL / INCONCLUSIVE / N/A.

    Reads the scenario's ``## Pass criteria`` bullets and evaluates each
    against the trial's captured sandbox snapshot + Claude output.
    """
    bullets = parse_pass_criteria(scenario_path)
    if not bullets:
        return "INCONCLUSIVE"

    trial_text = trial_path.read_text()
    sandbox_state = _extract_trial_section(
        trial_text, "Sandbox state after run (pre-cleanup snapshot)"
    )
    claude_output = _extract_trial_section(trial_text, "Claude output")
    contents_map = _extract_filecontents_map(sandbox_state)
    listed = _extract_listed_paths(sandbox_state)

    results: list[bool | None] = []
    for bullet in bullets:
        # Structural matches first — these handle their own binary
        # dependencies (grep_count is re-implemented in pure Python, so
        # `grep` not being on PATH is irrelevant).
        gc = _GREP_COUNT_RE.search(bullet)
        if gc:
            res = _check_grep_count(
                pat=gc.group("pat"),
                path=gc.group("path"),
                expected=int(gc.group("n")),
                contents_map=contents_map,
            )
            results.append(res)
            continue
        fe = _FILE_EXISTS_RE.search(bullet)
        if fe:
            res = _check_file_exists(fe.group("path"), listed, contents_map)
            results.append(res)
            continue
        oc = _OUTPUT_CONTAINS_RE.search(bullet)
        if oc:
            negate = bool(oc.group("neg"))
            res = _check_output_contains(
                oc.group("rest"), claude_output, negate
            )
            results.append(res)
            continue
        # No structural match — fall back to "does this bullet reference a
        # binary that isn't installed?" (edge 7). If yes, INCONCLUSIVE;
        # otherwise unknown bullet shape → INCONCLUSIVE.
        results.append(None)

    if all(r is True for r in results):
        return "PASS"
    if any(r is False for r in results):
        return "FAIL"
    return "INCONCLUSIVE"


def score_trial(*, trial_path: Path, scenarios_dir: Path) -> str:
    """Wave 1 scoring entry-point — delegates to Tier 1 grep_runner.

    Wave 4 will extend this to cascade:
        Tier 1 (this) → Tier 2 (LLM-as-judge) → Tier 3 (human flag).

    The Tier 2/3 hooks are EXTENSION POINTs below.
    """
    # Derive the scenario file from the trial's filename.
    # Filename shape (run-scenario.sh):   <scen>-<candidate>-trial<N>-<TS>.md
    # Filename shape (test stub):         <scen>-<candidate>-<N>-<TS>.md
    scenario_basename = _infer_scenario_basename(trial_path, scenarios_dir)
    scenario_path = scenarios_dir / f"{scenario_basename}.md"
    if not scenario_path.exists():
        return "INCONCLUSIVE"

    tier1 = grep_runner(scenario_path=scenario_path, trial_path=trial_path)
    if tier1 != "INCONCLUSIVE":
        return tier1

    # EXTENSION POINT (Wave 4): Tier 2 LLM-as-judge cascade.
    # Pseudo-code:
    #     tier2 = llm_judge(scenario_path, trial_path)
    #     if tier2 in ("PASS", "FAIL"):
    #         return tier2
    #     # else: flag for Tier 3 human review

    # EXTENSION POINT (Wave 4): Tier 3 human review.
    # Pseudo-code:
    #     flag_for_human_review(trial_path)
    #     return "INCONCLUSIVE"

    return tier1


def _infer_scenario_basename(trial_path: Path, scenarios_dir: Path) -> str:
    """Infer the scenario basename from a trial filename.

    Walks the candidate scenarios in `scenarios_dir` and finds the longest
    matching prefix on the trial filename — robust against scenario names
    that contain hyphens (e.g., "01-trivial-rename" matched in
    "01-trivial-rename-qwen3-coder-1-20260527T120000Z").
    """
    name = trial_path.stem
    best = ""
    for f in scenarios_dir.glob("*.md"):
        base = f.stem
        if name.startswith(base + "-") and len(base) > len(best):
            best = base
    return best


# ---------------------------------------------------------------------------
# Trial file → schema dict
# ---------------------------------------------------------------------------


_FIELD_RE = re.compile(r"^\s*-\s*\*\*(?P<key>[^*]+?)\*\*\s*:\s*(?P<val>.*)$")


def parse_trial_file(trial_path: Path) -> dict:
    """Parse a trial result .md into a dict of §3.4 schema fields.

    Returns a dict with at least: candidate, scenario, trial, wall_seconds,
    wall_cap_seconds, cold_load_trial, scoring_tier, exit_code, claude_output,
    flagged_log_excerpt, verdict_tag. Missing fields default sensibly.

    Returns a dict with key ``__malformed__`` = True if the file is missing
    all schema fields (per edge 3).
    """
    text = trial_path.read_text()
    fields: dict[str, str] = {}
    for line in text.splitlines():
        m = _FIELD_RE.match(line)
        if m:
            key = m.group("key").strip().lower()
            val = m.group("val").strip()
            # Strip backticks the runner wraps values in
            val = val.strip("`")
            fields[key] = val

    # Required §3.4 fields (T-08).
    required = {
        "wall_cap_seconds",
        "cold_load_trial",
        "scoring_tier",
    }
    if not (required & set(fields.keys())):
        return {"__malformed__": True, "path": str(trial_path)}

    # Pull wall_seconds from "Wall time" (e.g., "42s")
    wall_raw = fields.get("wall time", "0").rstrip("s").strip()
    try:
        wall_seconds = int(float(wall_raw))
    except ValueError:
        wall_seconds = 0

    exit_raw = fields.get("claude exit code", "0").strip()
    try:
        exit_code = int(exit_raw)
    except ValueError:
        exit_code = 0

    wcs_raw = fields.get("wall_cap_seconds", "0").strip()
    try:
        wall_cap_seconds = int(wcs_raw) if wcs_raw != "unbounded" else 0
    except ValueError:
        wall_cap_seconds = 0

    verdict_tag = fields.get("verdict_tag", "OK").upper()
    # exit code 124/125/137/143 means TIMEOUT
    if exit_code in (124, 125, 137, 143):
        verdict_tag = "TIMEOUT"

    return {
        "path": str(trial_path),
        "candidate": fields.get("candidate", "unknown"),
        "scenario": _scenario_from_filename(trial_path),
        "trial": int(fields.get("trial", "0") or "0"),
        "wall_seconds": wall_seconds,
        "wall_cap_seconds": wall_cap_seconds,
        "cold_load_trial": fields.get("cold_load_trial", "false") == "true",
        "scoring_tier": int(fields.get("scoring_tier", "1") or "1"),
        "exit_code": exit_code,
        "verdict_tag": verdict_tag,
    }


def _scenario_from_filename(trial_path: Path) -> str:
    """Best-effort scenario extraction from a trial filename.

    Trial filename shapes:
        <scen>-<candidate>-trial<N>-<TS>.md
        <scen>-<candidate>-<N>-<TS>.md
    Scenarios are conventionally NN-something. Pull the leading NN-... up
    to the candidate boundary.
    """
    name = trial_path.stem
    # Match NN-words-words pattern as the leading prefix.
    m = re.match(r"^(\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*?)-", name)
    if m:
        # The regex above is greedy on the prefix; we need the SHORTEST
        # NN-... prefix that ends at a candidate boundary. Iterate.
        for sep_idx, ch in enumerate(name):
            if ch == "-" and sep_idx > 3:
                prefix = name[:sep_idx]
                # Is it of shape NN-word(-word)*?
                if re.fullmatch(r"\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*", prefix):
                    return prefix
    return name


# ---------------------------------------------------------------------------
# Aggregation → parity matrix
# ---------------------------------------------------------------------------


def aggregate_trials(
    results_dir: Path, scenarios_dir: Path
) -> tuple[dict, list[dict], list[dict]]:
    """Read all trial files, score them, and bucket by (scenario, candidate).

    Returns:
        (cells, all_trials, malformed) where
            cells     = {(scenario, candidate): {trials: [...], stats: {...}}}
            all_trials = list of trial dicts (for outlier / global views)
            malformed  = list of dicts for unparseable result files
    """
    cells: dict[tuple[str, str], dict] = defaultdict(
        lambda: {"trials": [], "scenario": "", "candidate": ""}
    )
    all_trials: list[dict] = []
    malformed: list[dict] = []

    for f in sorted(results_dir.glob("*.md")):
        parsed = parse_trial_file(f)
        if parsed.get("__malformed__"):
            malformed.append(parsed)
            continue

        # Score trial against the scenario (if we can find one).
        verdict = "INCONCLUSIVE"
        try:
            verdict = score_trial(trial_path=f, scenarios_dir=scenarios_dir)
        except Exception as exc:
            verdict = f"ERROR: {exc}"

        parsed["verdict"] = verdict
        all_trials.append(parsed)

        key = (parsed["scenario"], parsed["candidate"])
        cells[key]["scenario"] = parsed["scenario"]
        cells[key]["candidate"] = parsed["candidate"]
        cells[key]["trials"].append(parsed)

    # Compute per-cell stats.
    for cell in cells.values():
        trials = cell["trials"]
        successful = [t for t in trials if t["verdict_tag"] != "TIMEOUT"]
        walls = [t["wall_seconds"] for t in successful]
        cell["n_total"] = len(trials)
        cell["n_success"] = len(successful)
        cell["timeouts"] = len(trials) - len(successful)
        cell["pass_count"] = sum(
            1 for t in trials if t.get("verdict") == "PASS"
        )
        cell["fail_count"] = sum(
            1 for t in trials if t.get("verdict") == "FAIL"
        )
        cell["inconclusive_count"] = sum(
            1 for t in trials if t.get("verdict") == "INCONCLUSIVE"
        )
        if walls:
            cell["mean_wall"] = round(statistics.fmean(walls), 1)
            cell["p50_wall"] = round(_percentile(walls, 50), 1)
            cell["p90_wall"] = round(_percentile(walls, 90), 1)
        else:
            cell["mean_wall"] = None
            cell["p50_wall"] = None
            cell["p90_wall"] = None
        cell["incomplete"] = cell["timeouts"] > 0

    return cells, all_trials, malformed


def _percentile(values: list[int], pct: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    k = (len(s) - 1) * (pct / 100.0)
    f = int(k)
    c = min(f + 1, len(s) - 1)
    if f == c:
        return float(s[f])
    return s[f] + (s[c] - s[f]) * (k - f)


# ---------------------------------------------------------------------------
# Outlier detection (T-10)
# ---------------------------------------------------------------------------


def find_outliers(all_trials: list[dict]) -> list[dict]:
    """Surface trials whose wall_multiplier exceeds 100x the cohort median.

    Wave 1 heuristic: per scenario, compute the median wall across all
    non-TIMEOUT trials, and flag any trial >100x the median. If too few
    trials to compute a meaningful baseline (< 2), skip.
    """
    by_scenario: dict[str, list[int]] = defaultdict(list)
    for t in all_trials:
        if t["verdict_tag"] != "TIMEOUT":
            by_scenario[t["scenario"]].append(t["wall_seconds"])

    outliers: list[dict] = []
    for t in all_trials:
        walls = by_scenario.get(t["scenario"], [])
        if len(walls) < 2:
            continue
        baseline = statistics.median(walls)
        if baseline <= 0:
            continue
        ratio = t["wall_seconds"] / baseline
        if ratio > 100:
            outliers.append({**t, "wall_multiplier": round(ratio, 1)})
    return outliers


# ---------------------------------------------------------------------------
# Output rendering
# ---------------------------------------------------------------------------


def render_markdown(
    cells: dict,
    all_trials: list[dict],
    outliers: list[dict],
    malformed: list[dict],
) -> str:
    """Emit a markdown parity matrix per spec §4.3."""
    out: list[str] = []
    out.append("# Parity matrix")
    out.append("")
    out.append(f"- Total trials: {len(all_trials)}")
    out.append(f"- Cells: {len(cells)}")
    out.append(f"- Malformed result files: {len(malformed)}")
    out.append("")

    if not all_trials and not malformed:
        out.append("## Cells")
        out.append("")
        out.append("(no trial result files found — empty results directory)")
        out.append("")
    else:
        out.append("## Cells")
        out.append("")
        out.append(
            "| Scenario | Candidate | N | Pass | Fail | Inconclusive | "
            "TIMEOUT | mean wall (s) | p50 (s) | p90 (s) | Incomplete |"
        )
        out.append(
            "|----------|-----------|---|------|------|--------------|---------|"
            "---------------|---------|---------|------------|"
        )
        for key in sorted(cells.keys()):
            cell = cells[key]
            incomplete_marker = ""
            if cell["incomplete"]:
                incomplete_marker = (
                    f"incomplete ({cell['n_success']}/{cell['n_total']})"
                )
            else:
                incomplete_marker = "—"
            out.append(
                "| {scen} | {cand} | {n} | {p} | {f} | {i} | {to} | "
                "{mean} | {p50} | {p90} | {im} |".format(
                    scen=cell["scenario"],
                    cand=cell["candidate"],
                    n=cell["n_total"],
                    p=cell["pass_count"],
                    f=cell["fail_count"],
                    i=cell["inconclusive_count"],
                    to=cell["timeouts"],
                    mean=cell["mean_wall"]
                    if cell["mean_wall"] is not None
                    else "—",
                    p50=cell["p50_wall"]
                    if cell["p50_wall"] is not None
                    else "—",
                    p90=cell["p90_wall"]
                    if cell["p90_wall"] is not None
                    else "—",
                    im=incomplete_marker,
                )
            )
        out.append("")

    # Outliers section is ALWAYS present per T-10 (even if empty).
    out.append("## Outliers (wall_multiplier > 100x)")
    out.append("")
    if outliers:
        for o in outliers:
            out.append(
                f"- `{o['scenario']}` x `{o['candidate']}` trial {o['trial']}: "
                f"{o['wall_seconds']}s ({o['wall_multiplier']}x scenario median)"
            )
    else:
        out.append("_No outliers detected._")
    out.append("")

    # Malformed files — surface but don't crash (edge 3).
    if malformed:
        out.append("## Warnings — malformed / skipped result files")
        out.append("")
        for m in malformed:
            out.append(f"- skipped (malformed schema): `{m['path']}`")
        out.append("")

    return "\n".join(out)


def render_json(
    cells: dict,
    all_trials: list[dict],
    outliers: list[dict],
    malformed: list[dict],
) -> str:
    """Emit a JSON parity matrix per T-08 supporting test."""
    serializable_cells = []
    for key in sorted(cells.keys()):
        cell = cells[key]
        serializable_cells.append(
            {
                "scenario": cell["scenario"],
                "candidate": cell["candidate"],
                "n_total": cell["n_total"],
                "n_success": cell["n_success"],
                "timeouts": cell["timeouts"],
                "pass_count": cell["pass_count"],
                "fail_count": cell["fail_count"],
                "inconclusive_count": cell["inconclusive_count"],
                "mean_wall": cell["mean_wall"],
                "p50_wall": cell["p50_wall"],
                "p90_wall": cell["p90_wall"],
                "incomplete": cell["incomplete"],
            }
        )
    return json.dumps(
        {
            "cells": serializable_cells,
            "outliers": [
                {k: v for k, v in o.items() if k != "path"} for o in outliers
            ],
            "malformed": [m["path"] for m in malformed],
            "total_trials": len(all_trials),
        },
        indent=2,
    )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Tier 1 grep-runner + parity-matrix aggregator (dotfiles-ukx.13 Wave 1)."
    )
    parser.add_argument(
        "--results-dir",
        required=True,
        type=Path,
        help="Directory containing trial result .md files.",
    )
    parser.add_argument(
        "--scenarios-dir",
        type=Path,
        default=Path("/home/ubuntu/dotfiles/claude/sandbox/scenarios"),
        help="Directory containing scenario .md files (for Pass criteria).",
    )
    parser.add_argument(
        "--out",
        required=True,
        type=Path,
        help="Output file path (markdown or JSON depending on --format).",
    )
    parser.add_argument(
        "--format",
        choices=("markdown", "json"),
        default="markdown",
        help="Output format (default: markdown).",
    )
    args = parser.parse_args(argv)

    if not args.results_dir.exists():
        print(
            f"error: results-dir not found: {args.results_dir}", file=sys.stderr
        )
        return 2

    cells, all_trials, malformed = aggregate_trials(
        args.results_dir, args.scenarios_dir
    )
    outliers = find_outliers(all_trials)

    if args.format == "json":
        body = render_json(cells, all_trials, outliers, malformed)
    else:
        body = render_markdown(cells, all_trials, outliers, malformed)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(body)

    return 0


if __name__ == "__main__":
    sys.exit(main())
