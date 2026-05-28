# ruff: noqa: RUF001
# RUF001/RUF003 (ambiguous unicode multiplication sign vs latin x) are
# disabled file-wide because the bench-matrix.sh driver emits literal
# U+00D7 MULTIPLICATION SIGN in its log lines (RUN scen MULT_SIGN cand
# MULT_SIGN N trials), and the dashboard parser MUST handle that exact
# character. Tests embed it verbatim; substituting LATIN x would
# silently mis-test the parser.
"""Tests for bench-dashboard.py — tailnet dashboard for bench-matrix runs.

Spec: dotfiles-vgb §5 — ≥11 test cases covering:
  - parse_result_file (Wave-2 + legacy Wave-1 filename shapes)
  - parse_log (cohort transitions + abort detection)
  - build_state (run_status, candidate ordering, cell status derivation)
  - HTTP endpoints (/, /api/state.json, /api/log, /healthz)
  - empty / missing input safety

Bead: dotfiles-vgb
"""

from __future__ import annotations

import importlib.util
import json
import socket
import textwrap
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

# --- Locate bench-dashboard.py within the same worktree -------------------

DOTFILES_ROOT = Path(__file__).resolve().parent.parent.parent
DASHBOARD_PATH = DOTFILES_ROOT / "local-models" / "bench-dashboard.py"


def _load_dashboard_module():
    """Import bench-dashboard.py as a module (its filename has a dash)."""
    spec = importlib.util.spec_from_file_location(
        "bench_dashboard", DASHBOARD_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load module spec from {DASHBOARD_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def dashboard():
    """The bench-dashboard module, loaded lazily so tests with pure-function
    coverage still run even if HTTP-server fixtures fail."""
    return _load_dashboard_module()


# --- Sample data (drawn from real fixtures referenced in the spec) ---------

REAL_RESULT_QWEN3 = textwrap.dedent("""\
    # Scenario result: 01-trivial-rename (local) trial 1

    - **Scenario file**: `/home/ubuntu/dotfiles/claude/sandbox/scenarios/01-trivial-rename.md`
    - **Model tag**: `local`
    - **Candidate**: `qwen3-coder`
    - **CCR route**: `pico-mlx,qwen3-coder`
    - **HF model**: `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`
    - **Trial**: 1
    - **Started**: 2026-05-28T00:49:59Z
    - **Wall time**: 705s
    - **wall_cap_seconds**: 1200
    - **cold_load_trial**: true
    - **scoring_tier**: 1
    - **claude exit code**: 0
    - **verdict_tag**: OK
    - **Result file**: `/home/ubuntu/dotfiles/claude/sandbox/results/01-trivial-rename-qwen3-coder-trial1-20260528T004959Z.md`

    ## Model routing evidence

    (CCR log)
    """)

REAL_RESULT_TRINITY = textwrap.dedent("""\
    # Scenario result: 01-trivial-rename (local) trial 1

    - **Scenario file**: `/home/ubuntu/dotfiles/claude/sandbox/scenarios/01-trivial-rename.md`
    - **Model tag**: `local`
    - **Candidate**: `trinity-mini`
    - **CCR route**: `pico-mlx,trinity-mini`
    - **HF model**: `mlx-community/Trinity-Mini-4bit`
    - **Trial**: 1
    - **Started**: 2026-05-28T00:38:20Z
    - **Wall time**: 685s
    - **wall_cap_seconds**: 1200
    - **cold_load_trial**: true
    - **scoring_tier**: 1
    - **claude exit code**: 0
    - **verdict_tag**: OK
    """)

# ukx.13.3-era (no trial<N> in filename; trial# only inside file)
LEGACY_RESULT_LOCAL = textwrap.dedent("""\
    # Scenario result: 01-trivial-rename (local)

    - **Scenario file**: `claude/sandbox/scenarios/01-trivial-rename.md`
    - **Model tag**: `local`
    - **Started**: 2026-05-26T04:19:28Z
    - **Wall time**: 3649s
    - **claude exit code**: 0
    """)

# Real driver log shape — 2 cohorts + abort
REAL_DRIVER_LOG = textwrap.dedent("""\
    ==> bench-matrix plan:
        candidates: trinity-mini qwen3-coder qwen3-coder-ollama devstral deepseek-coder-v2-lite-ollama laguna-xs2 deepseek-r1-14b glm-4.5-air kimi-linear
        scenarios:  01-trivial-rename
        trials:     1
        timeout:    20m per trial
        smoke:      1
    ==> running healthcheck H1 (start-of-run, /home/ubuntu/dotfiles/local-models/healthcheck.sh)...
    === local-models healthcheck — 2026-05-28T00:38:16Z ===

    RESULT: healthy
    ==> candidate cohort: trinity-mini (backend=mlx)
        RUN  01-trivial-rename × trinity-mini × 1 trials (cap=20m)
    ==> running healthcheck H1 (before-cohort-qwen3-coder, /home/ubuntu/dotfiles/local-models/healthcheck.sh)...
    === local-models healthcheck — 2026-05-28T00:49:45Z ===

    RESULT: healthy
    ==> candidate cohort: qwen3-coder (backend=mlx)
        RUN  01-trivial-rename × qwen3-coder × 1 trials (cap=20m)
    ==> running healthcheck H1 (before-cohort-qwen3-coder-ollama, /home/ubuntu/dotfiles/local-models/healthcheck.sh)...
    === local-models healthcheck — 2026-05-28T01:01:44Z ===

    RESULT: CRITICAL issues — fix before continuing local-model work
    error: healthcheck H1 failed (before-cohort-qwen3-coder-ollama) — aborting matrix
    """)


# --- Fixtures: results dir mirrors of real bench state --------------------


@pytest.fixture
def results_dir_two_done(tmp_path: Path) -> Path:
    """Results dir mirroring the current smoke state: trinity-mini done +
    qwen3-coder done + an abort marker."""
    d = tmp_path / "results"
    d.mkdir()
    (
        d / "01-trivial-rename-trinity-mini-trial1-20260528T003820Z.md"
    ).write_text(REAL_RESULT_TRINITY)
    (d / "01-trivial-rename-qwen3-coder-trial1-20260528T004959Z.md").write_text(
        REAL_RESULT_QWEN3
    )
    (d / "HEALTHCHECK_FAIL-20260528T010217Z.txt").write_text(
        "Healthcheck H1 failed at phase: before-cohort-qwen3-coder-ollama\n"
    )
    return d


@pytest.fixture
def results_dir_legacy(tmp_path: Path) -> Path:
    """Results dir with one legacy ukx.13.3-shape file (no trial<N> in name)."""
    d = tmp_path / "results-legacy"
    d.mkdir()
    (d / "01-trivial-rename-local-20260526T041928Z.md").write_text(
        LEGACY_RESULT_LOCAL
    )
    return d


@pytest.fixture
def empty_results_dir(tmp_path: Path) -> Path:
    d = tmp_path / "results-empty"
    d.mkdir()
    return d


@pytest.fixture
def driver_log_file(tmp_path: Path) -> Path:
    p = tmp_path / "bench-matrix-smoke-20260528T003816Z.log"
    p.write_text(REAL_DRIVER_LOG)
    return p


@pytest.fixture
def empty_log_file(tmp_path: Path) -> Path:
    p = tmp_path / "bench-matrix-empty.log"
    p.write_text("")
    return p


@pytest.fixture
def running_log_file(tmp_path: Path) -> Path:
    """Driver log that shows a RUN line WITHOUT a result file → running cell."""
    p = tmp_path / "bench-matrix-running.log"
    p.write_text(
        textwrap.dedent("""\
        ==> bench-matrix plan:
        ==> running healthcheck H1 (start-of-run, ...)...
        RESULT: healthy
        ==> candidate cohort: trinity-mini (backend=mlx)
            RUN  01-trivial-rename × trinity-mini × 1 trials (cap=20m)
        """)
    )
    return p


# --- HTTP server fixture ---------------------------------------------------


def _free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


@pytest.fixture
def live_server(dashboard, results_dir_two_done, driver_log_file):
    """Start the dashboard HTTP server in a background thread on a random
    high port. Yields the base URL. Tears down on exit."""
    port = _free_port()
    server = dashboard.make_server(
        host="127.0.0.1",
        port=port,
        results_dir=results_dir_two_done,
        log_path=driver_log_file,
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    # Tiny wait so the listener is definitely accepting
    for _ in range(50):
        try:
            urllib.request.urlopen(
                f"http://127.0.0.1:{port}/healthz", timeout=0.1
            )
            break
        except (urllib.error.URLError, ConnectionRefusedError):
            time.sleep(0.02)
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


# --- Tests: pure parsers --------------------------------------------------


def test_parse_result_file_extracts_wave2_fields(dashboard):
    """TEST: parse_result_file — extracts wall_time_s and verdict_tag from a real result."""
    info = dashboard.parse_result_file(
        Path("01-trivial-rename-qwen3-coder-trial1-20260528T004959Z.md"),
        REAL_RESULT_QWEN3,
    )
    assert info["wall_time_s"] == 705
    assert info["verdict_tag"] == "OK"
    assert info["exit_code"] == 0
    assert info["candidate"] == "qwen3-coder"
    assert info["scenario"] == "01-trivial-rename"
    assert info["trial"] == 1
    assert info["scoring_tier"] == 1
    assert info["started"] == "2026-05-28T00:49:59Z"


def test_parse_log_cohort_transitions(dashboard, driver_log_file):
    """TEST: parse_log_cohort_transitions — finds all cohort transitions in driver log.

    The real smoke log shows 2 successful cohort starts (trinity-mini + qwen3-coder)
    before the abort. We expect exactly 2 cohort entries in parsed output.
    """
    parsed = dashboard.parse_log(driver_log_file.read_text())
    cohorts = parsed["cohorts"]
    assert len(cohorts) == 2
    assert cohorts[0]["cohort"] == "trinity-mini"
    assert cohorts[0]["backend"] == "mlx"
    assert cohorts[1]["cohort"] == "qwen3-coder"
    assert cohorts[1]["backend"] == "mlx"


def test_parse_log_abort_detection(dashboard, driver_log_file):
    """TEST: parse_log_abort_detection — surfaces HEALTHCHECK_FAIL as abort."""
    parsed = dashboard.parse_log(driver_log_file.read_text())
    assert parsed["aborted"] is True
    assert parsed["abort_reason"] is not None
    assert "qwen3-coder-ollama" in parsed["abort_reason"]


def test_state_with_no_results(dashboard, empty_results_dir, tmp_path):
    """TEST: state_with_no_results — empty results dir doesn't crash.

    Expected: state with all candidates status=queued, run_status=unknown.
    """
    missing_log = tmp_path / "nonexistent.log"
    state = dashboard.build_state(
        results_dir=empty_results_dir, log_path=missing_log
    )
    assert state["run_status"] == "unknown"
    assert len(state["candidates"]) == 9
    for c in state["candidates"]:
        assert c["status"] == "queued"
        assert c["trials"] == []


def test_state_with_missing_log(dashboard, results_dir_two_done, tmp_path):
    """TEST: state_with_missing_log — missing log file doesn't crash."""
    missing_log = tmp_path / "definitely-missing.log"
    state = dashboard.build_state(
        results_dir=results_dir_two_done, log_path=missing_log
    )
    # No log = no abort detection, but result files still parse fine.
    assert state["log_tail"] in ("", None)
    # log_path field should still be a string for the UI
    assert "log_path" in state


def test_roster_canonical_order(dashboard, empty_results_dir, tmp_path):
    """TEST: roster_canonical_order — candidates always in lightest-first order."""
    state = dashboard.build_state(
        results_dir=empty_results_dir, log_path=tmp_path / "no.log"
    )
    names = [c["name"] for c in state["candidates"]]
    assert names[0] == "trinity-mini"
    assert names[-1] == "kimi-linear"
    # The full canonical roster (per bench-matrix.sh ROSTER):
    assert names == [
        "trinity-mini",
        "qwen3-coder",
        "qwen3-coder-ollama",
        "devstral",
        "deepseek-coder-v2-lite-ollama",
        "laguna-xs2",
        "deepseek-r1-14b",
        "glm-4.5-air",
        "kimi-linear",
    ]


def test_parse_old_style_result_filename(
    dashboard, results_dir_legacy, tmp_path
):
    """TEST: parse_old_style_result_filename — graceful for ukx.13.3-era results."""
    state = dashboard.build_state(
        results_dir=results_dir_legacy, log_path=tmp_path / "no.log"
    )
    # We don't expect the legacy `local` candidate to map onto the canonical
    # roster (it's a generic 'local' tag, not one of the 9 roster names), but
    # the build_state call must NOT crash on the legacy filename, AND the
    # parsed record should land in scenarios_seen.
    assert "01-trivial-rename" in state["scenarios_seen"]


def test_cell_status_when_running(
    dashboard, empty_results_dir, running_log_file
):
    """TEST: cell_status_when_running — driver log shows RUN line without
    result file → status=running."""
    state = dashboard.build_state(
        results_dir=empty_results_dir, log_path=running_log_file
    )
    # find trinity-mini in candidates
    trinity = next(
        c for c in state["candidates"] if c["name"] == "trinity-mini"
    )
    assert trinity["status"] == "running"


def test_state_with_two_done_marks_run_aborted(
    dashboard, results_dir_two_done, driver_log_file
):
    """Integration-shape: real smoke state. trinity-mini done + qwen3-coder done +
    rest queued, run_status=aborted, abort_reason mentions qwen3-coder-ollama."""
    state = dashboard.build_state(
        results_dir=results_dir_two_done, log_path=driver_log_file
    )
    assert state["run_status"] == "aborted"
    assert state["abort_reason"] is not None
    assert "qwen3-coder-ollama" in state["abort_reason"]
    by_name = {c["name"]: c for c in state["candidates"]}
    assert by_name["trinity-mini"]["status"] == "done"
    assert by_name["qwen3-coder"]["status"] == "done"
    # Everything from qwen3-coder-ollama onward must still be queued.
    for n in [
        "qwen3-coder-ollama",
        "devstral",
        "deepseek-coder-v2-lite-ollama",
        "laguna-xs2",
        "deepseek-r1-14b",
        "glm-4.5-air",
        "kimi-linear",
    ]:
        assert by_name[n]["status"] == "queued"


# --- Tests: HTTP endpoints ------------------------------------------------


def test_api_state_returns_json(live_server):
    """TEST: api_state_returns_json — /api/state.json returns valid JSON with Content-Type."""
    with urllib.request.urlopen(
        f"{live_server}/api/state.json", timeout=2
    ) as resp:
        assert resp.status == 200
        ctype = resp.headers.get("Content-Type", "")
        assert "application/json" in ctype
        body = resp.read().decode("utf-8")
        data = json.loads(body)
        assert "candidates" in data
        assert "run_status" in data


def test_api_log_returns_text(live_server):
    """TEST: api_log_returns_text — /api/log returns log content."""
    with urllib.request.urlopen(f"{live_server}/api/log", timeout=2) as resp:
        assert resp.status == 200
        ctype = resp.headers.get("Content-Type", "")
        assert "text/plain" in ctype


def test_api_html_renders(live_server):
    """TEST: api_html_renders — / returns HTML containing dashboard markers."""
    with urllib.request.urlopen(f"{live_server}/", timeout=2) as resp:
        assert resp.status == 200
        body = resp.read().decode("utf-8")
        assert "bench-dashboard" in body
        # roster markers — at least the lightest + heaviest candidates appear in markup
        assert "trinity-mini" in body
        assert "kimi-linear" in body


def test_api_healthz(live_server):
    """TEST: api_healthz — /healthz returns ok."""
    with urllib.request.urlopen(f"{live_server}/healthz", timeout=2) as resp:
        assert resp.status == 200
        body = resp.read().decode("utf-8")
        assert body == "ok\n"


# --- Tests: zig-watchdog SPA-integration endpoints + widget ---------------
#
# These tests exercise the dashboard's extension surface added for the
# zig-watchdog (spec dotfiles-olh §4.6):
#   - GET /api/watchdog-state.json → contents of ~/.cache/zig-watchdog/state.json
#   - GET /api/alerts.json         → tail of ~/.cache/zig-watchdog/alerts.json
#                                    as a JSON array (line-delimited input)
#   - HTML index includes a `watchdog` widget that the SPA's JS hydrates.
#
# To avoid mutating the operator's real `~/.cache/zig-watchdog/`, we point the
# dashboard at a tmp dir via the same dashboard_config mechanism it already
# uses for results_dir + log_path.


@pytest.fixture
def watchdog_state_dir(tmp_path: Path) -> Path:
    """Stand-in for ~/.cache/zig-watchdog/ with realistic state + alerts."""
    d = tmp_path / "zig-watchdog-cache"
    d.mkdir()
    state = {
        "last_tick_utc": "2026-05-28T03:00:00Z",
        "jobs": {
            "BenchMatrix": {
                "last_probe": "STALL",
                "last_probe_utc": "2026-05-28T03:00:00Z",
                "last_revive_attempt_utc": None,
                "revive_attempts": 0,
                "alerting": False,
            },
            "HermesGateway": {
                "last_probe": "CRASH",
                "last_probe_utc": "2026-05-28T03:00:00Z",
                "last_revive_attempt_utc": "2026-05-28T03:00:01Z",
                "revive_attempts": 3,
                "alerting": True,
            },
        },
    }
    (d / "state.json").write_text(json.dumps(state, indent=2))
    # JSON-lines alerts: two entries
    alert_lines = [
        json.dumps(
            {
                "utc": "2026-05-28T03:05:00Z",
                "job": "HermesGateway",
                "kind": "crash-loop-detected",
                "detail": "task t_360fa078 crashed 5x in 5min",
                "auto_action": "blocked",
            }
        ),
        json.dumps(
            {
                "utc": "2026-05-28T03:00:00Z",
                "job": "BenchMatrix",
                "kind": "stall-detected",
                "detail": "aborted at qwen3-coder-ollama",
                "auto_action": "restarted",
            }
        ),
    ]
    (d / "alerts.json").write_text("\n".join(alert_lines) + "\n")
    return d


@pytest.fixture
def live_server_with_watchdog(
    dashboard, results_dir_two_done, driver_log_file, watchdog_state_dir
):
    """Like live_server, but additionally pointed at a watchdog cache dir."""
    port = _free_port()
    server = dashboard.make_server(
        host="127.0.0.1",
        port=port,
        results_dir=results_dir_two_done,
        log_path=driver_log_file,
        watchdog_dir=watchdog_state_dir,
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    for _ in range(50):
        try:
            urllib.request.urlopen(
                f"http://127.0.0.1:{port}/healthz", timeout=0.1
            )
            break
        except (urllib.error.URLError, ConnectionRefusedError):
            time.sleep(0.02)
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def test_api_watchdog_state_returns_json(live_server_with_watchdog):
    """TEST: /api/watchdog-state.json returns the watchdog state.json verbatim."""
    with urllib.request.urlopen(
        f"{live_server_with_watchdog}/api/watchdog-state.json", timeout=2
    ) as resp:
        assert resp.status == 200
        ctype = resp.headers.get("Content-Type", "")
        assert "application/json" in ctype
        data = json.loads(resp.read().decode("utf-8"))
        assert "jobs" in data
        assert "HermesGateway" in data["jobs"]
        assert data["jobs"]["HermesGateway"]["alerting"] is True


def test_api_alerts_returns_array(live_server_with_watchdog):
    """TEST: /api/alerts.json returns a JSON array (last 100 entries)."""
    with urllib.request.urlopen(
        f"{live_server_with_watchdog}/api/alerts.json", timeout=2
    ) as resp:
        assert resp.status == 200
        ctype = resp.headers.get("Content-Type", "")
        assert "application/json" in ctype
        arr = json.loads(resp.read().decode("utf-8"))
        assert isinstance(arr, list)
        assert len(arr) == 2
        assert {a["job"] for a in arr} == {"HermesGateway", "BenchMatrix"}


def test_api_alerts_when_missing_returns_empty_array(
    dashboard, results_dir_two_done, driver_log_file, tmp_path
):
    """TEST: /api/alerts.json returns [] when alerts.json doesn't exist yet."""
    empty_dir = tmp_path / "empty-watchdog"
    empty_dir.mkdir()
    port = _free_port()
    server = dashboard.make_server(
        host="127.0.0.1",
        port=port,
        results_dir=results_dir_two_done,
        log_path=driver_log_file,
        watchdog_dir=empty_dir,
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    for _ in range(50):
        try:
            urllib.request.urlopen(
                f"http://127.0.0.1:{port}/healthz", timeout=0.1
            )
            break
        except (urllib.error.URLError, ConnectionRefusedError):
            time.sleep(0.02)
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/api/alerts.json", timeout=2
        ) as resp:
            arr = json.loads(resp.read().decode("utf-8"))
            assert arr == []
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/api/watchdog-state.json", timeout=2
        ) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            # Missing state.json → minimal shell that the UI can still render
            assert "jobs" in data
            assert data["jobs"] == {}
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def test_api_html_includes_watchdog_widget(live_server_with_watchdog):
    """TEST: HTML index includes a Watchdog widget the SPA's JS can hydrate."""
    with urllib.request.urlopen(
        f"{live_server_with_watchdog}/", timeout=2
    ) as resp:
        body = resp.read().decode("utf-8")
        # Widget marker — the JS hydrates this container.
        assert "watchdog" in body.lower()
        # JS uses /api/alerts.json + /api/watchdog-state.json
        assert "/api/alerts.json" in body
        assert "/api/watchdog-state.json" in body
        # Notification API plumbing
        assert "Notification" in body


# --- Tests: per-trial detail endpoint + parser ----------------------------
#
# Bead dotfiles-a1y — surface prompt / output / sandbox state / verdict
# per trial cell. parse_result_file_full extends parse_result_file with
# the section bodies (currently dropped). GET /api/trial/<id> returns the
# parsed JSON, ?raw=1 returns the original .md, missing trials → 404.

# A full real-shape result file (mirrors the trinity-mini smoke output) —
# every section the modal needs is present, and the flagged excerpt is
# intentionally empty (which is the common, modal-should-hide case).
REAL_RESULT_FULL_TRINITY = textwrap.dedent("""\
    # Scenario result: 01-trivial-rename (local) trial 1

    - **Scenario file**: `/home/ubuntu/dotfiles/claude/sandbox/scenarios/01-trivial-rename.md`
    - **Model tag**: `local`
    - **Candidate**: `trinity-mini`
    - **CCR route**: `pico-mlx,trinity-mini`
    - **HF model**: `mlx-community/Trinity-Mini-4bit`
    - **Trial**: 1
    - **Started**: 2026-05-28T00:38:20Z
    - **Wall time**: 685s
    - **wall_cap_seconds**: 1200
    - **cold_load_trial**: true
    - **scoring_tier**: 1
    - **claude exit code**: 0
    - **verdict_tag**: OK
    - **Result file**: `/home/ubuntu/dotfiles/claude/sandbox/results/01-trivial-rename-trinity-mini-trial1-20260528T003820Z.md`

    ## Model routing evidence

    (CCR log: /home/ubuntu/.claude-code-router/logs/ccr-20260526041459.log)
        Using background model for claude-haiku-4-5
        Using background model for claude-haiku-4-5

    ## Sandbox state after run (pre-cleanup snapshot)

    ```
        /tmp/claude-local-test/s01/calc.py
    FILECONTENTS:/tmp/claude-local-test/s01/calc.py:def sum_two(a, b):
    ```

    ## Prompt sent

    ```
    In `/tmp/claude-local-test/s01/calc.py`, rename the function `add_numbers` to `sum_two`. Update the call site too. Make no other changes. When done, reply with the single word "DONE".
    ```

    ## Claude output

    ```
    DONE
    ```

    ## flagged_log_excerpt

    ```
    ```
    """)


# A second fixture where flagged_log_excerpt has actual content — the
# modal should show that section, not hide it.
REAL_RESULT_FULL_FLAGGED = textwrap.dedent("""\
    # Scenario result: 02-fail-case (local) trial 1

    - **Scenario file**: `/home/ubuntu/dotfiles/claude/sandbox/scenarios/02-fail-case.md`
    - **Candidate**: `qwen3-coder`
    - **Trial**: 1
    - **Started**: 2026-05-28T01:00:00Z
    - **Wall time**: 900s
    - **claude exit code**: 1
    - **verdict_tag**: FAIL

    ## Model routing evidence

    (CCR log: routed)

    ## Sandbox state after run (pre-cleanup snapshot)

    ```
    state body
    ```

    ## Prompt sent

    ```
    prompt body
    ```

    ## Claude output

    ```
    output body
    ```

    ## flagged_log_excerpt

    ```
    WARNING: tool call timed out after 30s
    ERROR: nonzero exit from sandbox cleanup
    ```
    """)


@pytest.fixture
def results_dir_full(tmp_path: Path) -> Path:
    """Results dir holding a trial whose .md has all detail sections."""
    d = tmp_path / "results-full"
    d.mkdir()
    (
        d / "01-trivial-rename-trinity-mini-trial1-20260528T003820Z.md"
    ).write_text(REAL_RESULT_FULL_TRINITY)
    (d / "02-fail-case-qwen3-coder-trial1-20260528T010000Z.md").write_text(
        REAL_RESULT_FULL_FLAGGED
    )
    return d


@pytest.fixture
def live_server_full(dashboard, results_dir_full, driver_log_file):
    """Like live_server, but pointed at the results-full fixture so the
    /api/trial/<id> endpoint has rich detail to surface."""
    port = _free_port()
    server = dashboard.make_server(
        host="127.0.0.1",
        port=port,
        results_dir=results_dir_full,
        log_path=driver_log_file,
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    for _ in range(50):
        try:
            urllib.request.urlopen(
                f"http://127.0.0.1:{port}/healthz", timeout=0.1
            )
            break
        except (urllib.error.URLError, ConnectionRefusedError):
            time.sleep(0.02)
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def test_parse_result_file_full_extracts_prompt_sent(dashboard):
    """TEST: parse_result_file_full extracts the Prompt sent block body."""
    info = dashboard.parse_result_file_full(
        Path("01-trivial-rename-trinity-mini-trial1-20260528T003820Z.md"),
        REAL_RESULT_FULL_TRINITY,
    )
    assert "rename the function `add_numbers` to `sum_two`" in (
        info["prompt_sent"] or ""
    )
    assert (
        info["prompt_sent"]
        .strip()
        .endswith('reply with the single word "DONE".')
    )


def test_parse_result_file_full_extracts_claude_output(dashboard):
    """TEST: parse_result_file_full extracts the Claude output block body."""
    info = dashboard.parse_result_file_full(
        Path("01-trivial-rename-trinity-mini-trial1-20260528T003820Z.md"),
        REAL_RESULT_FULL_TRINITY,
    )
    assert info["claude_output"].strip() == "DONE"


def test_parse_result_file_full_extracts_sandbox_state(dashboard):
    """TEST: parse_result_file_full extracts the Sandbox state body."""
    info = dashboard.parse_result_file_full(
        Path("01-trivial-rename-trinity-mini-trial1-20260528T003820Z.md"),
        REAL_RESULT_FULL_TRINITY,
    )
    assert "/tmp/claude-local-test/s01/calc.py" in (
        info["sandbox_state_after_raw"] or ""
    )
    assert "FILECONTENTS:" in info["sandbox_state_after_raw"]


def test_parse_result_file_full_flagged_excerpt_empty(dashboard):
    """TEST: parse_result_file_full returns empty string when flagged block
    body is empty (the common case)."""
    info = dashboard.parse_result_file_full(
        Path("01-trivial-rename-trinity-mini-trial1-20260528T003820Z.md"),
        REAL_RESULT_FULL_TRINITY,
    )
    assert info["flagged_log_excerpt"] == ""


def test_parse_result_file_full_flagged_excerpt_present(dashboard):
    """TEST: parse_result_file_full extracts flagged excerpt body when present."""
    info = dashboard.parse_result_file_full(
        Path("02-fail-case-qwen3-coder-trial1-20260528T010000Z.md"),
        REAL_RESULT_FULL_FLAGGED,
    )
    assert "WARNING" in info["flagged_log_excerpt"]
    assert "ERROR" in info["flagged_log_excerpt"]


def test_api_trial_returns_json_for_existing(live_server_full):
    """TEST: GET /api/trial/<id> returns parsed JSON detail for an existing trial."""
    tid = "01-trivial-rename-trinity-mini-trial1-20260528T003820Z"
    with urllib.request.urlopen(
        f"{live_server_full}/api/trial/{tid}", timeout=2
    ) as resp:
        assert resp.status == 200
        ctype = resp.headers.get("Content-Type", "")
        assert "application/json" in ctype
        data = json.loads(resp.read().decode("utf-8"))
    assert data["id"] == tid
    assert data["scenario"] == "01-trivial-rename"
    assert data["candidate"] == "trinity-mini"
    assert data["trial"] == 1
    assert data["verdict_tag"] == "OK"
    assert data["wall_time_s"] == 685
    assert data["exit_code"] == 0
    # The new sections must be present (and non-empty for the rich trial).
    assert "rename the function" in data["prompt_sent"]
    assert data["claude_output"].strip() == "DONE"
    assert "FILECONTENTS:" in data["sandbox_state_after_raw"]
    assert data["flagged_log_excerpt"] == ""
    # raw_markdown is the original file body verbatim
    assert "## Prompt sent" in data["raw_markdown"]


def test_api_trial_raw_returns_text_plain(live_server_full):
    """TEST: GET /api/trial/<id>?raw=1 returns the original .md as text/plain."""
    tid = "01-trivial-rename-trinity-mini-trial1-20260528T003820Z"
    with urllib.request.urlopen(
        f"{live_server_full}/api/trial/{tid}?raw=1", timeout=2
    ) as resp:
        assert resp.status == 200
        ctype = resp.headers.get("Content-Type", "")
        assert "text/plain" in ctype
        body = resp.read().decode("utf-8")
    # The raw markdown contains the section headers verbatim.
    assert body.startswith("# Scenario result:")
    assert "## Prompt sent" in body
    assert "## Claude output" in body


def test_api_trial_missing_returns_404(live_server_full):
    """TEST: GET /api/trial/<nonexistent-id> returns HTTP 404."""
    with pytest.raises(urllib.error.HTTPError) as excinfo:
        urllib.request.urlopen(
            f"{live_server_full}/api/trial/nonexistent-trial", timeout=2
        )
    assert excinfo.value.code == 404


def test_api_html_includes_trial_modal(live_server_full):
    """TEST: HTML index includes the trial-detail modal markup + cell handlers."""
    with urllib.request.urlopen(f"{live_server_full}/", timeout=2) as resp:
        body = resp.read().decode("utf-8")
    # Modal container the JS toggles
    assert "trial-detail-modal" in body or "trial-modal" in body
    # The fetch wiring for /api/trial/
    assert "/api/trial/" in body
