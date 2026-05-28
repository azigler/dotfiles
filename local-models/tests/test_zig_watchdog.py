"""Tests for zig-watchdog.py — mechanical stall/crash detection + revive.

Spec: dotfiles-olh §5 — ≥12 test cases covering:
  - BenchMatrixJob: ok-when-healthy, stall-when-aborted, revive cmd shape
  - HfDownloadJob: ok-when-growing, stall-when-CPU0-and-mtime-old,
    revive kills + restarts
  - HermesGatewayJob: ok-when-dispatch-ok, crash-loop detect (>=3),
    revive blocks crash-loop task, revive restarts service
  - BenchDashboardJob: ok-when-healthz-ok, crash-when-not, revive runs start-dashboard
  - tick orchestrator: state.json written each tick, max_revive_attempts → alert,
    cooldown_seconds prevents immediate re-revive

The watchdog accepts an `executor` callable (subprocess proxy) per job class
so tests run real probe()/revive() logic against fakes — no real ssh, curl,
systemctl, or pgrep.

Bead: dotfiles-olh
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

# --- Locate zig-watchdog.py within the same worktree ----------------------

DOTFILES_ROOT = Path(__file__).resolve().parent.parent.parent
WATCHDOG_PATH = DOTFILES_ROOT / "local-models" / "zig-watchdog.py"


def _load_watchdog_module():
    """Import zig-watchdog.py as a module (its filename has a dash)."""
    spec = importlib.util.spec_from_file_location("zig_watchdog", WATCHDOG_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load module spec from {WATCHDOG_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def wd():
    return _load_watchdog_module()


# --- FakeExecutor ----------------------------------------------------------


class FakeExecutor:
    """In-memory stand-in for the watchdog's subprocess proxy.

    `responses` is a dict mapping kind → list of (returncode, stdout, stderr)
    tuples, one per call. Each call to `run(kind, ...)` pops the next response
    in order. If `responses[kind]` is empty or absent, defaults to (0, "", "").

    `recorded` captures every call as (kind, kwargs) for assertions about what
    revive() actually invoked.
    """

    def __init__(self, responses: dict | None = None):
        self.responses = responses or {}
        self.recorded: list[tuple[str, dict]] = []

    def run(self, kind: str, **kwargs):
        self.recorded.append((kind, kwargs))
        bucket = self.responses.get(kind, [])
        if not bucket:
            return (0, "", "")
        return bucket.pop(0)


# --- BenchMatrixJob tests -------------------------------------------------


def test_probe_bench_matrix_ok_when_healthcheck_recent(wd, tmp_path):
    """BenchMatrix OK when no abort marker exists AND no bench-matrix.sh running."""
    results_dir = tmp_path / "results"
    results_dir.mkdir()
    ex = FakeExecutor(
        responses={
            "pgrep_bench_matrix": [(1, "", "")],  # no PID
            "curl_ollama_tags": [(0, '{"models":[]}', "")],
            "curl_mlx_models": [(0, '{"data":[]}', "")],
        }
    )
    job = wd.BenchMatrixJob(executor=ex, results_dir=results_dir)
    result = job.probe()
    assert result == wd.ProbeResult.OK


def test_probe_bench_matrix_stall_when_aborted_and_backends_healthy(
    wd, tmp_path
):
    """BenchMatrix STALL: HEALTHCHECK_FAIL exists, backends back up, no PID."""
    results_dir = tmp_path / "results"
    results_dir.mkdir()
    (results_dir / "HEALTHCHECK_FAIL-20260528T010217Z.txt").write_text(
        "Healthcheck H1 failed at phase: before-cohort-qwen3-coder-ollama\n"
    )
    ex = FakeExecutor(
        responses={
            "pgrep_bench_matrix": [(1, "", "")],
            "curl_ollama_tags": [
                (0, '{"models":[{"name":"qwen3-coder:30b"}]}', "")
            ],
            "curl_mlx_models": [(0, '{"data":[{"id":"trinity"}]}', "")],
        }
    )
    job = wd.BenchMatrixJob(executor=ex, results_dir=results_dir)
    assert job.probe() == wd.ProbeResult.STALL


def test_probe_bench_matrix_ok_when_aborted_but_pid_alive(wd, tmp_path):
    """Don't re-trigger when bench-matrix.sh is itself running again."""
    results_dir = tmp_path / "results"
    results_dir.mkdir()
    (results_dir / "HEALTHCHECK_FAIL-20260528T010217Z.txt").write_text("fail")
    ex = FakeExecutor(
        responses={
            "pgrep_bench_matrix": [(0, "12345", "")],
            "curl_ollama_tags": [(0, '{"models":[]}', "")],
            "curl_mlx_models": [(0, '{"data":[]}', "")],
        }
    )
    job = wd.BenchMatrixJob(executor=ex, results_dir=results_dir)
    assert job.probe() == wd.ProbeResult.OK


def test_revive_bench_matrix_runs_command_and_logs(wd, tmp_path):
    """Revive dispatches bench-matrix.sh --smoke --resume via nohup-ish shell."""
    results_dir = tmp_path / "results"
    results_dir.mkdir()
    ex = FakeExecutor(responses={"shell_revive_bench_matrix": [(0, "", "")]})
    job = wd.BenchMatrixJob(executor=ex, results_dir=results_dir)
    result = job.revive()
    assert result == wd.ReviveResult.SUCCESS
    # Confirm the executor saw the expected kind
    kinds = [k for k, _ in ex.recorded]
    assert "shell_revive_bench_matrix" in kinds


# --- HfDownloadJob tests --------------------------------------------------


def test_probe_hf_download_ok_when_no_downloads(wd):
    """No hf download PIDs on pico → OK (nothing to babysit)."""
    ex = FakeExecutor(responses={"ssh_pgrep_hf_download": [(1, "", "")]})
    job = wd.HfDownloadJob(executor=ex)
    assert job.probe() == wd.ProbeResult.OK


def test_probe_hf_download_ok_when_cpu_active(wd):
    """hf download running with CPU>0 → OK (still making progress)."""
    ex = FakeExecutor(
        responses={
            "ssh_pgrep_hf_download": [(0, "12345 hf download foo/bar", "")],
            "ssh_ps_pcpu_etime": [(0, "12.3 03:45 hf download foo/bar", "")],
        }
    )
    job = wd.HfDownloadJob(executor=ex)
    assert job.probe() == wd.ProbeResult.OK


def test_probe_hf_download_stall_when_cpu_zero(wd):
    """hf download with CPU=0.0 and etime > 5min → STALL."""
    ex = FakeExecutor(
        responses={
            "ssh_pgrep_hf_download": [(0, "12345 hf download foo/bar", "")],
            "ssh_ps_pcpu_etime": [(0, "0.0 08:23:11 hf download foo/bar", "")],
        }
    )
    job = wd.HfDownloadJob(executor=ex)
    assert job.probe() == wd.ProbeResult.STALL


def test_revive_hf_download_kills_and_restarts(wd):
    """Revive kills the stalled PID and re-runs hf download with same args."""
    ex = FakeExecutor(
        responses={
            "ssh_pgrep_hf_download": [(0, "12345 hf download foo/bar", "")],
            "ssh_ps_pcpu_etime": [(0, "0.0 08:23:11 hf download foo/bar", "")],
            "ssh_kill_and_restart_hf": [(0, "", "")],
        }
    )
    job = wd.HfDownloadJob(executor=ex)
    # probe first so the job records the stalled PID
    job.probe()
    result = job.revive()
    assert result == wd.ReviveResult.SUCCESS
    # The kill-and-restart kind must appear
    kinds = [k for k, _ in ex.recorded]
    assert "ssh_kill_and_restart_hf" in kinds
    # And the recorded call carries the PID + command
    payloads = [
        kwargs for k, kwargs in ex.recorded if k == "ssh_kill_and_restart_hf"
    ]
    assert any("12345" in str(p) for p in payloads)


# --- HermesGatewayJob tests -----------------------------------------------


def test_probe_hermes_ok_when_active_and_no_crash_loops(wd):
    """All-green: active service, dispatch dry-run OK, no crashing tasks."""
    ex = FakeExecutor(
        responses={
            "systemctl_is_active_hermes": [(0, "active", "")],
            "hermes_dispatch_dry_run": [(0, "{}", "")],
            "hermes_diagnostics_json": [(0, "[]", "")],
        }
    )
    job = wd.HermesGatewayJob(executor=ex)
    assert job.probe() == wd.ProbeResult.OK


def test_probe_hermes_crash_when_service_inactive(wd):
    """systemctl is-active returns non-zero → CRASH."""
    ex = FakeExecutor(
        responses={
            "systemctl_is_active_hermes": [(3, "inactive", "")],
        }
    )
    job = wd.HermesGatewayJob(executor=ex)
    assert job.probe() == wd.ProbeResult.CRASH


def test_probe_hermes_crash_loop_when_3_crashes_actionable(wd):
    """Diagnostics show an unblocked task with consecutive_crashes >= 3 → CRASH.

    Regression guard for bd-hpi: CRASH must surface only when the watchdog
    can do something. An unblocked task with repeated crashes is actionable
    (revive will block it).
    """
    diag = json.dumps(
        [
            {
                "task_id": "t_360fa078",
                "status": "ready",  # not blocked → actionable
                "diagnostics": [
                    {
                        "kind": "repeated_crashes",
                        "severity": "critical",
                        "data": {"consecutive_crashes": 5},
                    }
                ],
            }
        ]
    )
    ex = FakeExecutor(
        responses={
            "systemctl_is_active_hermes": [(0, "active", "")],
            "hermes_dispatch_dry_run": [(0, "{}", "")],
            "hermes_diagnostics_json": [(0, diag, "")],
        }
    )
    job = wd.HermesGatewayJob(executor=ex)
    assert job.probe() == wd.ProbeResult.CRASH
    # Job retains the crash-loop task id for revive() to act on
    assert "t_360fa078" in job.crash_loop_task_ids
    assert "t_360fa078" in job._actionable_crash_loop_task_ids


def test_probe_hermes_ok_when_only_blocked_tasks_have_crashes(wd):
    """Stale diagnostic on already-blocked task → OK (not CRASH).

    Regression guard for bd-hpi: previously the probe surfaced CRASH every
    tick when the only crash-loop diagnostic was on a task that had already
    been blocked (manually OR by a prior watchdog revive). That produced a
    perpetual red "gateway crashing" banner in the SPA even though the
    gateway was healthy and the revive had no work to do. Fix: only return
    CRASH when actionable_crash_loop_task_ids is non-empty.
    """
    diag = json.dumps(
        [
            {
                "task_id": "t_360fa078",
                "status": "blocked",  # already blocked → not actionable
                "diagnostics": [
                    {
                        "kind": "repeated_crashes",
                        "severity": "critical",
                        "data": {"consecutive_crashes": 99},
                    }
                ],
            }
        ]
    )
    ex = FakeExecutor(
        responses={
            "systemctl_is_active_hermes": [(0, "active", "")],
            "hermes_dispatch_dry_run": [(0, "{}", "")],
            "hermes_diagnostics_json": [(0, diag, "")],
        }
    )
    job = wd.HermesGatewayJob(executor=ex)
    assert job.probe() == wd.ProbeResult.OK
    # The blocked task is still visible for diagnostics (just not actionable)
    assert "t_360fa078" in job.crash_loop_task_ids
    assert "t_360fa078" not in job._actionable_crash_loop_task_ids


def test_revive_hermes_blocks_crash_loop_task(wd):
    """Revive issues `hermes kanban block <task_id>` for each crash-loop task."""
    diag = json.dumps(
        [
            {
                "task_id": "t_abc12345",
                "diagnostics": [
                    {
                        "kind": "repeated_crashes",
                        "severity": "critical",
                        "data": {"consecutive_crashes": 4},
                    }
                ],
            }
        ]
    )
    ex = FakeExecutor(
        responses={
            "systemctl_is_active_hermes": [(0, "active", "")],
            "hermes_dispatch_dry_run": [(0, "{}", "")],
            "hermes_diagnostics_json": [(0, diag, "")],
            "hermes_kanban_block": [(0, "", "")],
        }
    )
    job = wd.HermesGatewayJob(executor=ex)
    job.probe()  # populates crash_loop_task_ids
    result = job.revive()
    assert result == wd.ReviveResult.SUCCESS
    kinds = [k for k, _ in ex.recorded]
    assert "hermes_kanban_block" in kinds
    payloads = [
        kwargs for k, kwargs in ex.recorded if k == "hermes_kanban_block"
    ]
    assert any("t_abc12345" in str(p) for p in payloads)


def test_revive_hermes_restarts_service_when_inactive(wd):
    """If service is inactive, revive issues systemctl --user restart."""
    ex = FakeExecutor(
        responses={
            "systemctl_is_active_hermes": [(3, "inactive", "")],
            "systemctl_restart_hermes": [(0, "", "")],
        }
    )
    job = wd.HermesGatewayJob(executor=ex)
    job.probe()
    result = job.revive()
    assert result == wd.ReviveResult.SUCCESS
    kinds = [k for k, _ in ex.recorded]
    assert "systemctl_restart_hermes" in kinds


# --- BenchDashboardJob tests ----------------------------------------------


def test_probe_bench_dashboard_ok(wd):
    ex = FakeExecutor(responses={"curl_dashboard_healthz": [(0, "ok\n", "")]})
    job = wd.BenchDashboardJob(executor=ex)
    assert job.probe() == wd.ProbeResult.OK


def test_probe_bench_dashboard_crash(wd):
    ex = FakeExecutor(
        responses={"curl_dashboard_healthz": [(7, "", "connect failed")]}
    )
    job = wd.BenchDashboardJob(executor=ex)
    assert job.probe() == wd.ProbeResult.CRASH


def test_revive_bench_dashboard_runs_start_script(wd):
    ex = FakeExecutor(responses={"shell_start_dashboard": [(0, "", "")]})
    job = wd.BenchDashboardJob(executor=ex)
    result = job.revive()
    assert result == wd.ReviveResult.SUCCESS
    kinds = [k for k, _ in ex.recorded]
    assert "shell_start_dashboard" in kinds


# --- Tick orchestrator tests ----------------------------------------------


def test_state_json_written_each_tick(wd, tmp_path, monkeypatch):
    """Tick writes state.json with one entry per registered job."""
    state_dir = tmp_path / "state"
    state_dir.mkdir()
    # All jobs healthy
    jobs = [
        _StubJob(name="A", probe_result=wd.ProbeResult.OK),
        _StubJob(name="B", probe_result=wd.ProbeResult.OK),
    ]
    wd.run_tick(jobs=jobs, state_dir=state_dir)
    state_file = state_dir / "state.json"
    assert state_file.exists()
    data = json.loads(state_file.read_text())
    assert "last_tick_utc" in data
    assert set(data["jobs"].keys()) == {"A", "B"}
    assert data["jobs"]["A"]["last_probe"] == "OK"
    assert data["jobs"]["A"]["revive_attempts"] == 0
    assert data["jobs"]["A"]["alerting"] is False


def test_max_revive_attempts_triggers_alert(wd, tmp_path):
    """3 consecutive failed revives → alerting=true AND alert appended."""
    state_dir = tmp_path / "state"
    state_dir.mkdir()
    # A job that always reports STALL and always fails to revive
    job = _StubJob(
        name="BadJob",
        probe_result=wd.ProbeResult.STALL,
        revive_result=wd.ReviveResult.FAILED,
        cooldown_seconds=0,  # so we can re-revive immediately in tests
    )
    for _ in range(3):
        wd.run_tick(jobs=[job], state_dir=state_dir)
    data = json.loads((state_dir / "state.json").read_text())
    assert data["jobs"]["BadJob"]["alerting"] is True
    assert data["jobs"]["BadJob"]["revive_attempts"] >= 3
    # alerts.json appended at least once
    alerts_file = state_dir / "alerts.json"
    assert alerts_file.exists()
    lines = [ln for ln in alerts_file.read_text().splitlines() if ln.strip()]
    assert any('"BadJob"' in ln for ln in lines)


def test_cooldown_prevents_immediate_re_revive(wd, tmp_path):
    """A revive within cooldown_seconds of the last attempt is skipped."""
    state_dir = tmp_path / "state"
    state_dir.mkdir()
    job = _StubJob(
        name="CooldownJob",
        probe_result=wd.ProbeResult.STALL,
        revive_result=wd.ReviveResult.FAILED,
        cooldown_seconds=999_999,
    )
    wd.run_tick(jobs=[job], state_dir=state_dir)
    first_attempts = job.revive_call_count
    # Second tick: still in cooldown, so revive() shouldn't be called
    wd.run_tick(jobs=[job], state_dir=state_dir)
    assert job.revive_call_count == first_attempts


def test_tick_appends_to_alerts_jsonl(wd, tmp_path):
    """alerts.json is JSON-lines (append-only)."""
    state_dir = tmp_path / "state"
    state_dir.mkdir()
    job = _StubJob(
        name="J",
        probe_result=wd.ProbeResult.CRASH,
        revive_result=wd.ReviveResult.SUCCESS,
        cooldown_seconds=0,
    )
    wd.run_tick(jobs=[job], state_dir=state_dir)
    alerts_file = state_dir / "alerts.json"
    assert alerts_file.exists()
    lines = [ln for ln in alerts_file.read_text().splitlines() if ln.strip()]
    # On the first detect we expect at least one alert entry
    assert len(lines) >= 1
    # Each line is valid JSON
    for ln in lines:
        rec = json.loads(ln)
        assert "utc" in rec and "job" in rec and "kind" in rec


# --- Test helpers ----------------------------------------------------------


class _StubJob:
    """In-memory job stub mirroring the JobClass interface."""

    def __init__(
        self,
        name,
        probe_result,
        revive_result=None,
        cooldown_seconds=600,
        max_revive_attempts=3,
    ):
        self.name = name
        self._probe_result = probe_result
        self._revive_result = revive_result
        self.cooldown_seconds = cooldown_seconds
        self.max_revive_attempts = max_revive_attempts
        self.probe_call_count = 0
        self.revive_call_count = 0

    def probe(self):
        self.probe_call_count += 1
        return self._probe_result

    def revive(self):
        self.revive_call_count += 1
        # Default to FAILED if not set — test bug if reached
        return (
            self._revive_result if self._revive_result is not None else _raise()
        )


def _raise():
    raise AssertionError("_StubJob.revive() called without configured result")
