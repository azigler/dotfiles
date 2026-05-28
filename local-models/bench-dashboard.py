#!/usr/bin/env python3
# ruff: noqa: RUF001, RUF003
# RUF001/RUF003: the bench-matrix.sh driver emits literal U+00D7
# MULTIPLICATION SIGN (×) in "RUN <scenario> × <candidate> × N trials"
# log lines, so our parser regexes must contain the same character.
# Substituting LATIN x would break log parsing on real driver output.
"""bench-dashboard.py — tailnet-private SPA for bench-matrix.sh runs.

Serves a single-page dashboard on 0.0.0.0:8765 by default. Reaches
http://100.98.174.21:8765/ (zig's Tailscale IP) so the operator can
monitor a multi-hour bench-matrix run from any tailnet device without
keeping a terminal open.

State is derived per-request by scanning:
  * /home/ubuntu/dotfiles/claude/sandbox/results/  — per-cell result .md files
  * /tmp/bench-matrix-*.log                        — driver log (most recent)

Stdlib only (no pip deps). Python 3.11+.

Endpoints:
  GET /                  → HTML SPA (embedded CSS+JS)
  GET /api/state.json    → parsed state, JSON
  GET /api/log           → driver log, text/plain (last 5000 lines if huge)
  GET /healthz           → "ok\\n"

Spec: dotfiles-vgb §4 (HTTP endpoints, schema, parser contracts).
Bead: dotfiles-vgb
"""

from __future__ import annotations

import argparse
import json
import logging
import re
import sys
import urllib.parse
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Canonical roster (lightest → heaviest) — mirrors bench-matrix.sh ROSTER.
# Keep this in sync with /home/ubuntu/dotfiles/local-models/bench-matrix.sh
# (the ROSTER bash array). Backend tags drive UI coloring; ordering drives
# the dashboard's row order.
# ---------------------------------------------------------------------------

ROSTER: list[tuple[str, str]] = [
    ("trinity-mini", "mlx"),
    ("qwen3-coder", "mlx"),
    ("qwen3-coder-ollama", "ollama"),
    ("devstral", "mlx"),
    ("deepseek-coder-v2-lite-ollama", "ollama"),
    ("laguna-xs2", "ollama"),
    ("deepseek-r1-14b", "ollama"),
    ("glm-4.5-air", "mlx"),
    ("kimi-linear", "mlx"),
]

ROSTER_NAMES: list[str] = [name for name, _ in ROSTER]

DEFAULT_RESULTS_DIR = Path("/home/ubuntu/dotfiles/claude/sandbox/results")
DEFAULT_LOG_GLOB = "/tmp/bench-matrix-*.log"
LOG_TAIL_LINES = 30
LOG_MAX_LINES = 5000  # /api/log truncation cap

# zig-watchdog SPA integration (spec dotfiles-olh §4.6)
DEFAULT_WATCHDOG_DIR = Path.home() / ".cache" / "zig-watchdog"
ALERTS_TAIL_LIMIT = 100  # /api/alerts.json returns the last N entries


# ---------------------------------------------------------------------------
# Pure parsing functions (unit-testable without HTTP).
# ---------------------------------------------------------------------------

# Filename patterns
#   Wave-2:  <scenario>-<candidate>-trial<N>-<UTC>.md
#   Legacy:  <scenario>-<candidate-or-tag>-<UTC>.md   (no `trial<N>`)
# scenario always starts with NN-<slug>, UTC is `YYYYMMDDTHHMMSSZ`.
_FN_WAVE2 = re.compile(
    r"^(?P<scenario>\d{2}-[a-z0-9][a-z0-9.-]*?)-(?P<candidate>[a-z0-9][a-z0-9.-]*?)-trial(?P<trial>\d+)-(?P<ts>\d{8}T\d{6}Z)\.md$"
)
_FN_LEGACY = re.compile(
    r"^(?P<scenario>\d{2}-[a-z0-9][a-z0-9.-]*?)-(?P<candidate>[a-z0-9][a-z0-9.-]*?)-(?P<ts>\d{8}T\d{6}Z)\.md$"
)

# Bullet body parser — "- **Key**: `value`" or "- **Key**: value"
_BULLET = re.compile(
    r"^- \*\*(?P<key>[A-Za-z0-9_ ()]+)\*\*:\s*`?(?P<value>[^`]*?)`?\s*$"
)


def _parse_int(s: str) -> int | None:
    s = s.strip()
    if not s:
        return None
    # accept "705" or "705s" → 705
    m = re.match(r"^-?\d+", s)
    if not m:
        return None
    try:
        return int(m.group(0))
    except ValueError:
        return None


def _parse_bool(s: str) -> bool | None:
    v = s.strip().lower()
    if v in ("true", "yes", "1"):
        return True
    if v in ("false", "no", "0"):
        return False
    return None


def parse_result_file(path: Path, text: str | None = None) -> dict[str, Any]:
    """Parse a result .md file into a flat dict.

    The function accepts either a path on disk (and reads it) or text supplied
    in-memory (useful for tests). The returned dict ALWAYS includes:

        scenario, candidate, trial, wall_time_s, exit_code, verdict_tag,
        scoring_tier, started, result_file (str)

    Missing-from-file values become None. Filename pattern drives scenario +
    candidate + trial; the per-bullet body may override candidate (handy for
    legacy filenames where the candidate tag is `local` but the body bullet
    has the real name).
    """
    if text is None:
        text = path.read_text(encoding="utf-8", errors="replace")
    out: dict[str, Any] = {
        "scenario": None,
        "candidate": None,
        "trial": 1,
        "wall_time_s": None,
        "exit_code": None,
        "verdict_tag": None,
        "scoring_tier": None,
        "started": None,
        "result_file": str(path),
    }
    name = path.name
    m = _FN_WAVE2.match(name)
    if m:
        out["scenario"] = m.group("scenario")
        out["candidate"] = m.group("candidate")
        out["trial"] = int(m.group("trial"))
    else:
        m = _FN_LEGACY.match(name)
        if m:
            out["scenario"] = m.group("scenario")
            out["candidate"] = m.group("candidate")
            # legacy files often have no trial number; default 1

    for line in text.splitlines():
        bm = _BULLET.match(line)
        if not bm:
            continue
        key = bm.group("key").strip().lower()
        value = bm.group("value").strip()
        if key == "candidate":
            # Body wins over filename (legacy files use a generic tag in filename)
            if value:
                out["candidate"] = value
        elif key == "scenario file":
            # extract bare scenario stem from a path like ".../01-trivial-rename.md"
            stem = Path(value).stem if value else ""
            if stem:
                out["scenario"] = stem
        elif key == "trial":
            n = _parse_int(value)
            if n is not None:
                out["trial"] = n
        elif key == "wall time":
            out["wall_time_s"] = _parse_int(value)
        elif key == "claude exit code":
            out["exit_code"] = _parse_int(value)
        elif key == "verdict_tag":
            out["verdict_tag"] = value or None
        elif key == "scoring_tier":
            out["scoring_tier"] = _parse_int(value)
        elif key == "started":
            out["started"] = value or None
    return out


# ---------------------------------------------------------------------------
# Per-trial detail parser (bead dotfiles-a1y).
# ---------------------------------------------------------------------------
#
# The per-trial result .md files contain a sequence of `## <Section>` headings
# with fenced code blocks beneath them. parse_result_file() above only
# extracts the bullet-list metadata; the section bodies (Prompt sent, Claude
# output, Sandbox state after run, Model routing evidence, flagged_log_excerpt)
# were dropped on the floor. parse_result_file_full() adds those bodies so the
# dashboard's per-trial modal can surface them.

# Section heading matcher — matches "## Prompt sent" or
# "## Sandbox state after run (pre-cleanup snapshot)" (we strip the
# parenthetical when normalizing the key).
_SECTION_HEADING = re.compile(r"^##\s+(?P<title>.+?)\s*$")

# Map normalized heading text → output-dict key.
_SECTION_KEYS: dict[str, str] = {
    "prompt sent": "prompt_sent",
    "claude output": "claude_output",
    "sandbox state after run": "sandbox_state_after_raw",
    "model routing evidence": "model_routing_evidence",
    "flagged_log_excerpt": "flagged_log_excerpt",
}


def _normalize_section_title(title: str) -> str:
    """Drop trailing parentheticals and lowercase so heading variants match.

    "Sandbox state after run (pre-cleanup snapshot)" → "sandbox state after run"
    "Prompt sent"                                    → "prompt sent"
    """
    t = re.sub(r"\s*\([^)]*\)\s*$", "", title).strip().lower()
    return t


def parse_result_file_full(
    path: Path, text: str | None = None
) -> dict[str, Any]:
    """Parse a result .md file and ALSO return the per-section bodies.

    Returns a superset of parse_result_file() with these additional keys:

        prompt_sent              : str — fenced body under `## Prompt sent`
        claude_output            : str — fenced body under `## Claude output`
        sandbox_state_after_raw  : str — fenced body under `## Sandbox state after run...`
        model_routing_evidence   : str — body under `## Model routing evidence`
                                         (may be free text, not fenced)
        flagged_log_excerpt      : str — fenced body under `## flagged_log_excerpt`
                                         (empty when the run was clean)
        raw_markdown             : str — the original file contents verbatim
        id                       : str — URL-safe identifier (filename stem)

    Section bodies for fenced sections are the content BETWEEN the opening
    and closing ``` fences (with trailing newline stripped). The
    Model-routing-evidence section is not always fenced, so we collect
    everything up to the next `##` heading instead.
    """
    if text is None:
        text = path.read_text(encoding="utf-8", errors="replace")
    base = parse_result_file(path, text)
    out: dict[str, Any] = dict(base)
    out["id"] = path.stem
    out["raw_markdown"] = text
    for key in _SECTION_KEYS.values():
        out[key] = ""

    lines = text.splitlines()
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        hm = _SECTION_HEADING.match(line)
        if not hm:
            i += 1
            continue
        norm = _normalize_section_title(hm.group("title"))
        key = _SECTION_KEYS.get(norm)
        if key is None:
            i += 1
            continue
        # Advance into the section body.
        j = i + 1
        # Skip blank lines after the heading.
        while j < n and lines[j].strip() == "":
            j += 1
        # Fenced body?
        if j < n and lines[j].strip().startswith("```"):
            # Skip the opening fence, accumulate until the matching closing fence.
            j += 1
            body_start = j
            while j < n and not lines[j].strip().startswith("```"):
                j += 1
            body = "\n".join(lines[body_start:j])
            out[key] = body
            # Step past the closing fence so we don't re-detect it.
            i = j + 1
            continue
        # Unfenced body — collect until the next `##` heading or EOF.
        body_start = j
        while j < n and not lines[j].startswith("## "):
            j += 1
        body = "\n".join(lines[body_start:j]).rstrip()
        out[key] = body
        i = j
    return out


# Driver-log line patterns
_RX_COHORT = re.compile(
    r"^==> candidate cohort:\s+(?P<cohort>\S+)\s+\(backend=(?P<backend>\S+?)\)"
)
_RX_RUN = re.compile(
    r"^\s*RUN\s+(?P<scenario>\S+)\s+×\s+(?P<candidate>\S+)\s+×\s+(?P<trials>\d+)\s+trials"
)
_RX_HEALTHCHECK = re.compile(r"^==> running healthcheck H1 \((?P<phase>[^,)]+)")
_RX_ABORT = re.compile(r"^error: healthcheck H1 failed \((?P<phase>[^)]+)\)")


def parse_log(text: str) -> dict[str, Any]:
    """Parse driver-log text into a structured summary.

    Returns:
        {
          "cohorts":     [{"cohort": str, "backend": str, "line_no": int}, ...],
          "runs":        [{"scenario": str, "candidate": str, "trials": int, "line_no": int}, ...],
          "healthchecks":[{"phase": str, "line_no": int}, ...],
          "aborted":     bool,
          "abort_reason":str | None,
          "tail":        last 30 lines joined,
        }
    """
    cohorts: list[dict[str, Any]] = []
    runs: list[dict[str, Any]] = []
    healthchecks: list[dict[str, Any]] = []
    aborted = False
    abort_reason: str | None = None

    lines = text.splitlines()
    for idx, line in enumerate(lines, start=1):
        m = _RX_COHORT.match(line)
        if m:
            cohorts.append(
                {
                    "cohort": m.group("cohort"),
                    "backend": m.group("backend"),
                    "line_no": idx,
                }
            )
            continue
        m = _RX_RUN.match(line)
        if m:
            runs.append(
                {
                    "scenario": m.group("scenario"),
                    "candidate": m.group("candidate"),
                    "trials": int(m.group("trials")),
                    "line_no": idx,
                }
            )
            continue
        m = _RX_HEALTHCHECK.match(line)
        if m:
            healthchecks.append(
                {"phase": m.group("phase").strip(), "line_no": idx}
            )
            continue
        m = _RX_ABORT.match(line)
        if m:
            aborted = True
            phase = m.group("phase").strip()
            # phase looks like "before-cohort-qwen3-coder-ollama" — strip prefix
            cohort_name = re.sub(r"^before-cohort-", "", phase)
            abort_reason = f"healthcheck-fail at {cohort_name}"
            continue

    tail = "\n".join(lines[-LOG_TAIL_LINES:]) if lines else ""
    return {
        "cohorts": cohorts,
        "runs": runs,
        "healthchecks": healthchecks,
        "aborted": aborted,
        "abort_reason": abort_reason,
        "tail": tail,
    }


# ---------------------------------------------------------------------------
# State assembly.
# ---------------------------------------------------------------------------


def _find_latest_log(glob: str = DEFAULT_LOG_GLOB) -> Path | None:
    """Pick the most recent bench-matrix log matching glob; None if absent."""
    from glob import glob as _glob

    matches = sorted(_glob(glob))
    if not matches:
        return None
    return Path(matches[-1])


def build_state(
    results_dir: Path,
    log_path: Path | None,
) -> dict[str, Any]:
    """Assemble the dashboard state from on-disk inputs.

    Schema matches spec §4.2. Always returns the full 9-candidate roster
    (lightest-first), with per-candidate `status` derived from:
      * has a result file in results_dir   → "done"
      * mentioned in a driver-log RUN line → "running"
      * otherwise                          → "queued"

    Never raises — missing dirs / logs degrade to empty trials and
    run_status="unknown".
    """
    now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    parsed_log: dict[str, Any] = {
        "cohorts": [],
        "runs": [],
        "healthchecks": [],
        "aborted": False,
        "abort_reason": None,
        "tail": "",
    }

    log_text = ""
    if log_path and log_path.exists():
        try:
            log_text = log_path.read_text(encoding="utf-8", errors="replace")
            parsed_log = parse_log(log_text)
        except OSError as exc:
            logging.warning("could not read log %s: %s", log_path, exc)

    # Per-candidate trial accumulator.
    trials_by_candidate: dict[str, list[dict[str, Any]]] = {
        n: [] for n in ROSTER_NAMES
    }
    scenarios_seen: set[str] = set()

    if results_dir.exists() and results_dir.is_dir():
        for fp in sorted(results_dir.glob("*.md")):
            try:
                info = parse_result_file(fp)
            except OSError:
                continue
            scen = info.get("scenario")
            cand = info.get("candidate")
            if scen:
                scenarios_seen.add(scen)
            # Map onto roster if candidate name matches; otherwise still
            # surface in scenarios_seen but don't try to fit non-roster
            # candidates into a row (legacy `local`/`opus` etc.).
            if cand in trials_by_candidate:
                trials_by_candidate[cand].append(
                    {
                        "trial": info.get("trial", 1),
                        "scenario": scen,
                        "started": info.get("started"),
                        "wall_time_s": info.get("wall_time_s"),
                        "exit_code": info.get("exit_code"),
                        "verdict_tag": info.get("verdict_tag"),
                        "scoring_tier": info.get("scoring_tier"),
                        "result_file": info.get("result_file"),
                    }
                )

    # Derive running candidates from log RUN-lines without a matching result.
    running_candidates: set[str] = set()
    for run in parsed_log["runs"]:
        cand = run["candidate"]
        if cand in trials_by_candidate and not trials_by_candidate[cand]:
            running_candidates.add(cand)

    # Determine run_status — order matters: aborted > complete > running > unknown.
    if parsed_log["aborted"]:
        run_status = "aborted"
    elif log_text and all(trials_by_candidate[n] for n in ROSTER_NAMES):
        run_status = "complete"
    elif parsed_log["runs"] or any(
        trials_by_candidate[n] for n in ROSTER_NAMES
    ):
        run_status = "running"
    else:
        run_status = "unknown"

    candidates_out: list[dict[str, Any]] = []
    for position, (name, backend) in enumerate(ROSTER, start=1):
        trials = trials_by_candidate[name]
        if trials:
            status = "done"
        elif name in running_candidates:
            status = "running"
        else:
            status = "queued"
        candidates_out.append(
            {
                "name": name,
                "backend": backend,
                "position": position,
                "status": status,
                "trials": trials,
            }
        )

    return {
        "timestamp": now,
        "log_path": str(log_path) if log_path else "",
        "log_tail": parsed_log["tail"],
        "run_status": run_status,
        "abort_reason": parsed_log["abort_reason"],
        "candidates": candidates_out,
        "scenarios_seen": sorted(scenarios_seen),
    }


# ---------------------------------------------------------------------------
# zig-watchdog SPA bridge helpers (spec dotfiles-olh §4.6).
# Each helper degrades gracefully when the watchdog hasn't run yet, so the
# dashboard can be brought up before the systemd-user timer.
# ---------------------------------------------------------------------------


def read_watchdog_state(watchdog_dir: Path) -> dict[str, Any]:
    """Return the parsed watchdog state.json, or a minimal empty-shell shape."""
    p = Path(watchdog_dir) / "state.json"
    if not p.exists():
        return {"last_tick_utc": None, "jobs": {}}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"last_tick_utc": None, "jobs": {}}


def read_watchdog_alerts(
    watchdog_dir: Path, limit: int = ALERTS_TAIL_LIMIT
) -> list[dict[str, Any]]:
    """Return the last `limit` watchdog alerts as a JSON array.

    The on-disk file is JSON-lines (append-only); this normalizes to an array
    so the SPA's JS can just `for (const a of arr)` it. Lines that fail to
    parse are skipped (don't crash the endpoint over a torn write).
    """
    p = Path(watchdog_dir) / "alerts.json"
    if not p.exists():
        return []
    try:
        text = p.read_text(encoding="utf-8")
    except OSError:
        return []
    out: list[dict[str, Any]] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    if limit and len(out) > limit:
        out = out[-limit:]
    return out


# ---------------------------------------------------------------------------
# HTML dashboard (single string; vanilla JS).
# ---------------------------------------------------------------------------

HTML_PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>bench-dashboard</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #0e1116;
    --panel: #161b22;
    --border: #30363d;
    --text: #c9d1d9;
    --dim: #8b949e;
    --ok: #2ea043;
    --warn: #d29922;
    --err: #f85149;
    --info: #58a6ff;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    padding: 1rem;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    background: var(--bg);
    color: var(--text);
    font-size: 14px;
  }
  h1 { margin: 0 0 .25rem; font-size: 1.1rem; }
  .meta { color: var(--dim); font-size: .85rem; margin-bottom: 1rem; }
  .badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 4px;
    font-size: .75rem;
    text-transform: uppercase;
    font-weight: 600;
    letter-spacing: .03em;
  }
  .badge.running  { background: var(--info); color: #fff; }
  .badge.complete { background: var(--ok);   color: #fff; }
  .badge.aborted  { background: var(--err);  color: #fff; }
  .badge.unknown  { background: var(--dim);  color: #000; }
  .badge.done     { background: var(--ok);   color: #fff; }
  .badge.queued   { background: var(--border); color: var(--dim); }
  .badge.failed   { background: var(--err);  color: #fff; }
  .badge.skipped  { background: var(--warn); color: #000; }

  .panel {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 1rem;
    margin-bottom: 1rem;
  }
  table { width: 100%; border-collapse: collapse; }
  th, td {
    text-align: left;
    padding: .5rem .75rem;
    border-bottom: 1px solid var(--border);
    vertical-align: top;
  }
  th { color: var(--dim); font-weight: 500; font-size: .8rem; text-transform: uppercase; }
  td.num { text-align: right; font-variant-numeric: tabular-nums; }
  tr:last-child td { border-bottom: none; }
  .backend { color: var(--dim); font-size: .75rem; }
  .abort { color: var(--err); font-weight: 600; }
  pre.log {
    background: #010409;
    border: 1px solid var(--border);
    padding: .75rem;
    border-radius: 4px;
    max-height: 320px;
    overflow: auto;
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
    font-size: .78rem;
    white-space: pre-wrap;
    word-break: break-word;
    color: #b3c0d1;
  }
  .toolbar {
    display: flex;
    gap: .5rem;
    align-items: center;
    margin-bottom: .75rem;
    font-size: .8rem;
    color: var(--dim);
  }
  .trial-cell { font-size: .82rem; color: var(--dim); }
  .verdict-OK   { color: var(--ok); font-weight: 600; }
  .verdict-FAIL { color: var(--err); font-weight: 600; }
  a { color: var(--info); }

  /* ---- per-trial detail modal (bead dotfiles-a1y) -------------------- */
  /* The trial-chip is the clickable token rendered per-trial inside the
     roster Trials cell. Hover → highlight; cursor signals clickability. */
  .trial-chip {
    display: inline-block;
    padding: 1px 6px;
    margin-right: .25rem;
    border-radius: 3px;
    background: var(--border);
    color: var(--text);
    font-size: .75rem;
    cursor: pointer;
    user-select: none;
    border: 1px solid transparent;
  }
  .trial-chip:hover { border-color: var(--info); color: var(--info); }
  .trial-chip.verdict-OK   { background: rgba(46,160,67,.15); color: var(--ok); }
  .trial-chip.verdict-FAIL { background: rgba(248,81,73,.15); color: var(--err); }

  #trial-detail-modal {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, .65);
    display: none;
    align-items: flex-start;
    justify-content: center;
    z-index: 1000;
    padding: 2rem 1rem;
    overflow-y: auto;
  }
  #trial-detail-modal.open { display: flex; }
  #trial-detail-modal .modal-card {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 6px;
    width: 100%;
    max-width: 1000px;
    padding: 1.25rem 1.5rem 1.5rem;
    position: relative;
  }
  #trial-detail-modal .modal-close {
    position: absolute;
    top: .5rem;
    right: .75rem;
    background: transparent;
    color: var(--dim);
    border: none;
    font-size: 1.5rem;
    line-height: 1;
    cursor: pointer;
  }
  #trial-detail-modal .modal-close:hover { color: var(--text); }
  #trial-detail-modal h2 { margin: 0 0 .25rem; font-size: 1rem; }
  #trial-detail-modal .modal-meta { color: var(--dim); font-size: .85rem; margin-bottom: 1rem; }
  #trial-detail-modal details {
    border: 1px solid var(--border);
    border-radius: 4px;
    margin-bottom: .75rem;
    background: #0b0e13;
  }
  #trial-detail-modal details > summary {
    padding: .5rem .75rem;
    cursor: pointer;
    font-weight: 600;
    user-select: none;
    color: var(--text);
  }
  #trial-detail-modal details > summary:hover { color: var(--info); }
  #trial-detail-modal details > pre {
    margin: 0;
    padding: .75rem;
    background: #010409;
    border-top: 1px solid var(--border);
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
    font-size: .82rem;
    white-space: pre-wrap;
    word-break: break-word;
    color: #b3c0d1;
    max-height: 400px;
    overflow: auto;
  }
  #trial-detail-modal .modal-footer {
    margin-top: 1rem;
    font-size: .82rem;
    color: var(--dim);
  }
</style>
</head>
<body>
  <h1>bench-dashboard <span id="status-badge" class="badge unknown">unknown</span></h1>
  <div class="meta">
    Last updated: <span id="ts">—</span> ·
    Log: <code id="log-path">—</code> ·
    <a href="/api/state.json">state.json</a> ·
    <a href="/api/log">raw log</a> ·
    <a href="/healthz">healthz</a>
  </div>
  <div id="abort-block" class="panel" style="display:none">
    <span class="abort">ABORTED:</span> <span id="abort-reason"></span>
  </div>

  <div id="watchdog-alert-banner" class="panel" style="display:none;border-color:var(--err);">
    <span class="abort">WATCHDOG ALERTING:</span>
    <span id="watchdog-alert-detail"></span>
  </div>

  <div class="panel" id="watchdog-panel">
    <div class="toolbar">
      <strong>zig-watchdog</strong>
      <span>(mechanical stall/crash probes, 5-min tick)</span>
      <a href="/api/watchdog-state.json">state</a> ·
      <a href="/api/alerts.json">alerts</a>
      <span id="watchdog-last-tick" style="margin-left:auto;color:var(--dim);">—</span>
    </div>
    <table>
      <thead>
        <tr>
          <th>Job</th>
          <th>Last probe</th>
          <th>Revive attempts</th>
          <th>Last revive</th>
          <th>State</th>
        </tr>
      </thead>
      <tbody id="watchdog-body">
        <tr><td colspan="5" style="color:var(--dim);">(no watchdog ticks yet — start with: <code>bash local-models/install-zig-watchdog.sh</code>)</td></tr>
      </tbody>
    </table>
  </div>

  <div class="panel">
    <div class="toolbar">
      <strong>Candidate roster</strong>
      <span>(lightest-first, 9 cohorts)</span>
      <span id="scenarios-seen"></span>
    </div>
    <table>
      <thead>
        <tr>
          <th style="width:2rem">#</th>
          <th>Candidate</th>
          <th>Status</th>
          <th>Trials</th>
          <th class="num">Last wall (s)</th>
          <th>Last verdict</th>
        </tr>
      </thead>
      <tbody id="roster-body">__ROSTER_ROWS__</tbody>
    </table>
  </div>

  <div class="panel">
    <div class="toolbar">
      <strong>Driver log tail</strong>
      <span>(last 30 lines)</span>
    </div>
    <pre class="log" id="log-tail">—</pre>
  </div>

  <!-- ============================================================
       Per-trial detail modal (bead dotfiles-a1y)
       Hidden until a roster trial-chip is clicked; populated via
       GET /api/trial/<id> and toggled via the .open class.
       Closes on Esc, click on the dim backdrop, or the X button.
       ============================================================ -->
  <div id="trial-detail-modal" role="dialog" aria-modal="true" aria-hidden="true">
    <div class="modal-card">
      <button type="button" class="modal-close" id="trial-modal-close" aria-label="Close">×</button>
      <h2 id="trial-modal-title">Trial detail</h2>
      <div class="modal-meta" id="trial-modal-meta">—</div>
      <details id="trial-section-prompt">
        <summary>Prompt sent</summary>
        <pre id="trial-prompt-body"></pre>
      </details>
      <details id="trial-section-output" open>
        <summary>Claude output</summary>
        <pre id="trial-output-body"></pre>
      </details>
      <details id="trial-section-sandbox">
        <summary>Sandbox state after run</summary>
        <pre id="trial-sandbox-body"></pre>
      </details>
      <details id="trial-section-routing">
        <summary>Model routing evidence</summary>
        <pre id="trial-routing-body"></pre>
      </details>
      <details id="trial-section-flagged" style="display:none">
        <summary>Flagged log excerpt</summary>
        <pre id="trial-flagged-body"></pre>
      </details>
      <div class="modal-footer">
        <a id="trial-raw-link" href="#" target="_blank" rel="noopener">Open raw .md file</a>
      </div>
    </div>
  </div>

<script>
const REFRESH_MS = 5000;

function esc(s) {
  if (s === null || s === undefined) return "";
  return String(s).replace(/[&<>"']/g, c => ({
    "&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"
  }[c]));
}

function renderState(state) {
  document.getElementById("ts").textContent = state.timestamp || "—";
  document.getElementById("log-path").textContent = state.log_path || "—";

  const badge = document.getElementById("status-badge");
  badge.className = "badge " + (state.run_status || "unknown");
  badge.textContent = state.run_status || "unknown";

  const abortBlock = document.getElementById("abort-block");
  if (state.abort_reason) {
    abortBlock.style.display = "";
    document.getElementById("abort-reason").textContent = state.abort_reason;
  } else {
    abortBlock.style.display = "none";
  }

  const seen = state.scenarios_seen || [];
  document.getElementById("scenarios-seen").textContent =
    seen.length ? "· scenarios touched: " + seen.join(", ") : "";

  const body = document.getElementById("roster-body");
  body.innerHTML = "";
  for (const c of state.candidates || []) {
    const tr = document.createElement("tr");
    const trials = c.trials || [];
    const lastTrial = trials.length ? trials[trials.length - 1] : null;
    const lastWall = lastTrial && lastTrial.wall_time_s != null ? lastTrial.wall_time_s : "—";
    const lastVerdict = lastTrial && lastTrial.verdict_tag ? lastTrial.verdict_tag : "—";
    const verdictClass = lastVerdict === "OK" ? "verdict-OK" :
                         lastVerdict === "FAIL" ? "verdict-FAIL" : "";

    // Render each trial as a clickable chip → opens the trial-detail modal.
    // The chip text is "trial N (verdict)" so the operator can spot which one
    // they want to inspect. trial_id is derived from the result_file basename
    // (strip the .md extension).
    let chips = "";
    if (trials.length === 0) {
      chips = "<span class=trial-cell>0 result(s)</span>";
    } else {
      for (const t of trials) {
        const fname = (t.result_file || "").split("/").pop() || "";
        const tid = fname.replace(/\.md$/, "");
        const v = t.verdict_tag || "—";
        const vc = v === "OK" ? "verdict-OK" : v === "FAIL" ? "verdict-FAIL" : "";
        chips +=
          "<span class='trial-chip " + vc + "' " +
          "data-trial-id='" + esc(tid) + "' " +
          "title='Click for full trial detail'>" +
          "T" + esc(t.trial != null ? t.trial : "?") + " " + esc(v) +
          "</span>";
      }
    }

    tr.innerHTML =
      "<td class=num>" + esc(c.position) + "</td>" +
      "<td><strong>" + esc(c.name) + "</strong> " +
        "<span class=backend>" + esc(c.backend) + "</span></td>" +
      "<td><span class='badge " + esc(c.status) + "'>" + esc(c.status) + "</span></td>" +
      "<td>" + chips + "</td>" +
      "<td class=num>" + esc(lastWall) + "</td>" +
      "<td class='" + verdictClass + "'>" + esc(lastVerdict) + "</td>";
    body.appendChild(tr);
  }

  document.getElementById("log-tail").textContent = state.log_tail || "—";
}

// ---- per-trial detail modal (bead dotfiles-a1y) -------------------------
// Click any .trial-chip in the roster → fetch /api/trial/<id> → populate
// and show the modal. Modal closes on Esc / backdrop click / X button.

function openTrialModal(tid) {
  const modal = document.getElementById("trial-detail-modal");
  const title = document.getElementById("trial-modal-title");
  const meta = document.getElementById("trial-modal-meta");
  // Reset section bodies + transient state while we fetch.
  document.getElementById("trial-prompt-body").textContent = "(loading)";
  document.getElementById("trial-output-body").textContent = "(loading)";
  document.getElementById("trial-sandbox-body").textContent = "(loading)";
  document.getElementById("trial-routing-body").textContent = "(loading)";
  document.getElementById("trial-flagged-body").textContent = "";
  document.getElementById("trial-section-flagged").style.display = "none";
  title.textContent = "Trial detail — " + tid;
  meta.textContent = "loading…";
  document.getElementById("trial-raw-link").href = "/api/trial/" + encodeURIComponent(tid) + "?raw=1";
  modal.classList.add("open");
  modal.setAttribute("aria-hidden", "false");

  fetch("/api/trial/" + encodeURIComponent(tid), {cache: "no-store"})
    .then(r => {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(data => {
      title.textContent =
        (data.scenario || "?") + " · " +
        (data.candidate || "?") + " · trial " + (data.trial != null ? data.trial : "?");
      const verdict = data.verdict_tag || "—";
      const vc = verdict === "OK" ? "verdict-OK" : verdict === "FAIL" ? "verdict-FAIL" : "";
      meta.innerHTML =
        "started: " + esc(data.started || "—") + " · " +
        "wall: " + esc(data.wall_time_s != null ? data.wall_time_s + "s" : "—") + " · " +
        "exit: " + esc(data.exit_code != null ? data.exit_code : "—") + " · " +
        "verdict: <span class='" + vc + "'>" + esc(verdict) + "</span>";
      document.getElementById("trial-prompt-body").textContent = data.prompt_sent || "(none)";
      document.getElementById("trial-output-body").textContent = data.claude_output || "(none)";
      document.getElementById("trial-sandbox-body").textContent = data.sandbox_state_after_raw || "(none)";
      document.getElementById("trial-routing-body").textContent = data.model_routing_evidence || "(none)";
      const flagged = data.flagged_log_excerpt || "";
      if (flagged.trim()) {
        document.getElementById("trial-flagged-body").textContent = flagged;
        document.getElementById("trial-section-flagged").style.display = "";
      } else {
        document.getElementById("trial-section-flagged").style.display = "none";
      }
    })
    .catch(err => {
      meta.textContent = "error: " + err.message;
    });
}

function closeTrialModal() {
  const modal = document.getElementById("trial-detail-modal");
  modal.classList.remove("open");
  modal.setAttribute("aria-hidden", "true");
}

document.addEventListener("click", function(ev) {
  const chip = ev.target.closest(".trial-chip");
  if (chip && chip.dataset.trialId) {
    openTrialModal(chip.dataset.trialId);
    return;
  }
  if (ev.target.id === "trial-modal-close") {
    closeTrialModal();
    return;
  }
  // Backdrop click — only when target IS the modal container, not its card.
  if (ev.target.id === "trial-detail-modal") {
    closeTrialModal();
  }
});

document.addEventListener("keydown", function(ev) {
  if (ev.key === "Escape") closeTrialModal();
});

async function refresh() {
  try {
    const r = await fetch("/api/state.json", {cache: "no-store"});
    const data = await r.json();
    renderState(data);
  } catch (err) {
    console.warn("refresh failed", err);
  }
}

// ---- zig-watchdog SPA bridge (spec dotfiles-olh §4.6) ---------------------
// Polls /api/watchdog-state.json + /api/alerts.json every REFRESH_MS,
// renders the watchdog widget, and fires browser Notification on new alerts.
const ALERT_SEEN_KEY = "zig-watchdog:last-seen-utc";

function probeBadgeClass(p) {
  if (p === "OK") return "done";
  if (p === "STALL") return "aborted";
  if (p === "CRASH") return "aborted";
  return "queued";
}

function renderWatchdog(state) {
  const body = document.getElementById("watchdog-body");
  const jobs = (state && state.jobs) || {};
  const names = Object.keys(jobs).sort();
  document.getElementById("watchdog-last-tick").textContent =
    state && state.last_tick_utc ? "last tick: " + state.last_tick_utc : "—";
  if (!names.length) {
    return;  // keep the "(no watchdog ticks yet)" placeholder row
  }
  body.innerHTML = "";
  let anyAlerting = false;
  let alertingNames = [];
  for (const name of names) {
    const j = jobs[name];
    const probe = j.last_probe || "UNKNOWN";
    if (j.alerting) { anyAlerting = true; alertingNames.push(name); }
    const tr = document.createElement("tr");
    tr.innerHTML =
      "<td><strong>" + esc(name) + "</strong></td>" +
      "<td><span class='badge " + probeBadgeClass(probe) + "'>" + esc(probe) + "</span></td>" +
      "<td class=num>" + esc(j.revive_attempts != null ? j.revive_attempts : "—") + "</td>" +
      "<td class=trial-cell>" + esc(j.last_revive_attempt_utc || "—") + "</td>" +
      "<td>" + (j.alerting ? "<span class='badge failed'>ALERTING</span>" : "<span class='badge done'>ok</span>") + "</td>";
    body.appendChild(tr);
  }
  const banner = document.getElementById("watchdog-alert-banner");
  if (anyAlerting) {
    banner.style.display = "";
    document.getElementById("watchdog-alert-detail").textContent =
      alertingNames.join(", ") + " — see /api/alerts.json";
  } else {
    banner.style.display = "none";
  }
}

function maybeNotify(alerts) {
  if (!("Notification" in window)) return;
  if (Notification.permission !== "granted") return;
  const lastSeen = localStorage.getItem(ALERT_SEEN_KEY) || "";
  let newest = lastSeen;
  for (const a of alerts) {
    if (a.utc > lastSeen) {
      try {
        new Notification("zig-watchdog: " + (a.job || "?"), {
          body: (a.kind || "") + " — " + (a.detail || ""),
          tag: "zig-watchdog-" + a.utc,
        });
      } catch (err) { /* notification API hiccup; non-fatal */ }
      if (a.utc > newest) newest = a.utc;
    }
  }
  if (newest && newest !== lastSeen) {
    localStorage.setItem(ALERT_SEEN_KEY, newest);
  }
}

async function refreshWatchdog() {
  try {
    const [sRes, aRes] = await Promise.all([
      fetch("/api/watchdog-state.json", {cache: "no-store"}),
      fetch("/api/alerts.json", {cache: "no-store"}),
    ]);
    const state = await sRes.json();
    const alerts = await aRes.json();
    renderWatchdog(state);
    maybeNotify(alerts);
  } catch (err) {
    console.warn("watchdog refresh failed", err);
  }
}

// Ask for browser-notification permission once, on first user gesture friendly
// load (browsers no longer prompt without a gesture, but requesting is a
// no-op when already granted/denied).
if ("Notification" in window && Notification.permission === "default") {
  try { Notification.requestPermission(); } catch (err) { /* old API */ }
}

refresh();
refreshWatchdog();
setInterval(refresh, REFRESH_MS);
setInterval(refreshWatchdog, REFRESH_MS);
</script>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# HTTP handler.
# ---------------------------------------------------------------------------


class DashboardHandler(BaseHTTPRequestHandler):
    # Set by make_server() via the server instance.
    server_version = "bench-dashboard/1.0"

    def log_message(self, format: str, *args: Any) -> None:
        # Route stdout logging through Python's logging so the nohup log is clean.
        logging.info("%s - %s", self.client_address[0], format % args)

    def _send(self, code: int, body: bytes, content_type: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        path, _, query_str = self.path.partition("?")
        query = urllib.parse.parse_qs(query_str)
        cfg = self.server.dashboard_config  # type: ignore[attr-defined]

        if path == "/healthz":
            self._send(200, b"ok\n", "text/plain; charset=utf-8")
            return

        if path == "/":
            # SSR-bake the canonical roster into the initial markup so the page
            # is greppable / accessible / useful before JS fires its first
            # /api/state.json fetch. The JS then replaces innerHTML on refresh.
            roster_rows = "".join(
                f'<tr data-candidate="{name}">'
                f'<td class="num">{pos}</td>'
                f"<td><strong>{name}</strong> "
                f'<span class="backend">{backend}</span></td>'
                f'<td><span class="badge queued">queued</span></td>'
                f'<td class="trial-cell">0 result(s)</td>'
                f'<td class="num">—</td>'
                f"<td>—</td>"
                f"</tr>"
                for pos, (name, backend) in enumerate(ROSTER, start=1)
            )
            page = HTML_PAGE.replace("__ROSTER_ROWS__", roster_rows)
            self._send(200, page.encode("utf-8"), "text/html; charset=utf-8")
            return

        if path == "/api/state.json":
            log_path = cfg["log_path"] or _find_latest_log()
            state = build_state(
                results_dir=cfg["results_dir"],
                log_path=log_path,
            )
            body = json.dumps(state, indent=2).encode("utf-8")
            self._send(200, body, "application/json; charset=utf-8")
            return

        if path == "/api/watchdog-state.json":
            wd_dir = cfg.get("watchdog_dir") or DEFAULT_WATCHDOG_DIR
            state = read_watchdog_state(wd_dir)
            body = json.dumps(state, indent=2).encode("utf-8")
            self._send(200, body, "application/json; charset=utf-8")
            return

        if path == "/api/alerts.json":
            wd_dir = cfg.get("watchdog_dir") or DEFAULT_WATCHDOG_DIR
            alerts = read_watchdog_alerts(wd_dir)
            body = json.dumps(alerts, indent=2).encode("utf-8")
            self._send(200, body, "application/json; charset=utf-8")
            return

        if path.startswith("/api/trial/"):
            trial_id = path[len("/api/trial/") :]
            # Defensive: strip any trailing slash, refuse anything that looks
            # like a directory traversal attempt.
            trial_id = trial_id.rstrip("/")
            if not trial_id or "/" in trial_id or ".." in trial_id:
                self._send(
                    404, b"trial not found\n", "text/plain; charset=utf-8"
                )
                return
            results_dir = Path(cfg["results_dir"])
            fp = results_dir / f"{trial_id}.md"
            if not fp.exists():
                self._send(
                    404, b"trial not found\n", "text/plain; charset=utf-8"
                )
                return
            try:
                text = fp.read_text(encoding="utf-8", errors="replace")
            except OSError as exc:
                self._send(
                    500,
                    f"could not read trial file: {exc}\n".encode(),
                    "text/plain; charset=utf-8",
                )
                return
            # ?raw=1 → serve the original .md verbatim as text/plain
            raw_flag = query.get("raw", ["0"])[0]
            if raw_flag in ("1", "true", "yes"):
                self._send(
                    200, text.encode("utf-8"), "text/plain; charset=utf-8"
                )
                return
            try:
                info = parse_result_file_full(fp, text)
            except Exception as exc:
                self._send(
                    500,
                    f"parser error: {exc}\n".encode(),
                    "text/plain; charset=utf-8",
                )
                return
            body = json.dumps(info, indent=2).encode("utf-8")
            self._send(200, body, "application/json; charset=utf-8")
            return

        if path == "/api/log":
            log_path = cfg["log_path"] or _find_latest_log()
            if log_path and log_path.exists():
                try:
                    text = log_path.read_text(
                        encoding="utf-8", errors="replace"
                    )
                except OSError as exc:
                    text = f"(could not read log {log_path}: {exc})\n"
                else:
                    lines = text.splitlines()
                    if len(lines) > LOG_MAX_LINES:
                        text = (
                            f"(... truncated to last {LOG_MAX_LINES} lines of {len(lines)} total ...)\n"
                            + "\n".join(lines[-LOG_MAX_LINES:])
                            + "\n"
                        )
            else:
                text = "(no log file found)\n"
            self._send(200, text.encode("utf-8"), "text/plain; charset=utf-8")
            return

        self._send(404, b"not found\n", "text/plain; charset=utf-8")


def make_server(
    host: str,
    port: int,
    results_dir: Path,
    log_path: Path | None,
    watchdog_dir: Path | None = None,
) -> ThreadingHTTPServer:
    """Construct a ThreadingHTTPServer bound to (host, port) carrying
    dashboard config (results_dir + optional fixed log_path + optional
    watchdog state dir) on the server instance so the handler can read it
    per-request.

    Pass `log_path=None` to auto-discover the most recent
    /tmp/bench-matrix-*.log on each request.

    Pass `watchdog_dir=None` to use ~/.cache/zig-watchdog (the live default).
    Tests should pass an explicit tmp dir.
    """
    server = ThreadingHTTPServer((host, port), DashboardHandler)
    server.dashboard_config = {  # type: ignore[attr-defined]
        "results_dir": Path(results_dir),
        "log_path": Path(log_path) if log_path is not None else None,
        "watchdog_dir": Path(watchdog_dir)
        if watchdog_dir is not None
        else None,
    }
    return server


# ---------------------------------------------------------------------------
# CLI entrypoint.
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="bench-dashboard — tailnet SPA for bench-matrix runs"
    )
    parser.add_argument(
        "--host", default="0.0.0.0", help="bind host (default: 0.0.0.0)"
    )
    parser.add_argument(
        "--port", type=int, default=8765, help="bind port (default: 8765)"
    )
    parser.add_argument(
        "--results-dir",
        type=Path,
        default=DEFAULT_RESULTS_DIR,
        help=f"results dir (default: {DEFAULT_RESULTS_DIR})",
    )
    parser.add_argument(
        "--log-path",
        type=Path,
        default=None,
        help=f"explicit driver-log path (default: auto-discover {DEFAULT_LOG_GLOB})",
    )
    parser.add_argument(
        "--watchdog-dir",
        type=Path,
        default=None,
        help=(
            f"zig-watchdog state/alerts dir (default: {DEFAULT_WATCHDOG_DIR})"
        ),
    )
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    server = make_server(
        host=args.host,
        port=args.port,
        results_dir=args.results_dir,
        log_path=args.log_path,
        watchdog_dir=args.watchdog_dir,
    )
    logging.info(
        "bench-dashboard serving on %s:%d (results_dir=%s, log_path=%s, watchdog_dir=%s)",
        args.host,
        args.port,
        args.results_dir,
        args.log_path or f"auto:{DEFAULT_LOG_GLOB}",
        args.watchdog_dir or DEFAULT_WATCHDOG_DIR,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logging.info("shutting down on SIGINT")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
