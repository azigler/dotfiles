#!/usr/bin/env python3
"""zig-watchdog.py — mechanical stall/crash detection + revive for long-running jobs.

Single-tick driver invoked by `zig-watchdog.timer` (systemd-user, every 5min).
Each registered JobClass implements probe()/revive(); the tick orchestrator
loads prior state, probes all jobs, fires revive() on STALL/CRASH (subject to
cooldown), persists new state to ~/.cache/zig-watchdog/state.json, and appends
alerts to ~/.cache/zig-watchdog/alerts.json (JSON-lines).

After max_revive_attempts consecutive failed revives the job is marked
`alerting=true`, which the bench-dashboard SPA's watchdog widget surfaces
via the browser Notification API.

Stdlib only. Python 3.11+.

Spec: dotfiles-olh §4.
Bead: dotfiles-olh
"""

from __future__ import annotations

import argparse
import json
import logging
import re
import shlex
import subprocess
import sys
from collections.abc import Callable
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_STATE_DIR = Path.home() / ".cache" / "zig-watchdog"
DEFAULT_RESULTS_DIR = Path("/home/ubuntu/dotfiles/claude/sandbox/results")
PICO_HOST = "100.72.47.4"
PICO_SSH = "pico"
DASHBOARD_HEALTHZ_URL = "http://localhost:8765/healthz"
START_DASHBOARD_SH = "/home/ubuntu/dotfiles/local-models/start-dashboard.sh"
BENCH_MATRIX_SH = "/home/ubuntu/dotfiles/local-models/bench-matrix.sh"
HERMES_BIN = "/home/ubuntu/explore/hermes-agent-trial/.venv/bin/hermes"

# Probe thresholds
HF_STALL_ETIME_MIN = 5  # minutes of cumulative etime with CPU=0 before STALL
HERMES_CRASH_LOOP_THRESHOLD = 3

# Regex matching a Hermes `kanban show` event line. Format:
#   [YYYY-MM-DD HH:MM] [optional 'run N'] event_name {data}
# The event_name is alphanumeric_with_underscores; data is loose dict syntax
# we don't try to parse. We only care about the event_name and the implicit
# ordering (the lines are emitted chronologically).
_HERMES_EVENT_LINE_RE = re.compile(
    r"^\s*\[(?P<ts>\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})\]\s*"
    r"(?:\[run\s+\d+\]\s*)?"
    r"(?P<event>[a-z_]+)\b",
    re.MULTILINE,
)


def _count_crashes_since_last_unblock(show_text: str) -> int:
    """Count `crashed` events that occurred after the most recent `unblocked`.

    If the task has never been unblocked, count all `crashed` events from the
    start. Used to filter out stale lifetime crash counters from Hermes —
    `consecutive_crashes` doesn't reset on unblock, so a task that previously
    crash-looped and was manually unblocked to retry would otherwise re-trip
    the watchdog on its first tick. Fix bd-cke.
    """
    if not show_text:
        return 0
    events = list(_HERMES_EVENT_LINE_RE.finditer(show_text))
    if not events:
        return 0
    last_unblock_idx = -1
    for i, m in enumerate(events):
        if m.group("event") == "unblocked":
            last_unblock_idx = i
    return sum(
        1
        for m in events[last_unblock_idx + 1 :]
        if m.group("event") == "crashed"
    )


# ---------------------------------------------------------------------------
# Result enums
# ---------------------------------------------------------------------------


class ProbeResult(StrEnum):
    OK = "OK"
    STALL = "STALL"
    CRASH = "CRASH"
    UNKNOWN = "UNKNOWN"


class ReviveResult(StrEnum):
    SUCCESS = "SUCCESS"
    FAILED = "FAILED"


# ---------------------------------------------------------------------------
# Executor — the seam tests stub out
# ---------------------------------------------------------------------------


class SubprocessExecutor:
    """Default executor: runs real subprocess.run() calls per-kind.

    Each job invokes `executor.run(kind, ...)` with a small, well-defined set
    of `kind` tags. Tests inject a FakeExecutor that returns canned responses
    for each kind — no real ssh, curl, or systemctl in the test path.
    """

    def __init__(self, timeout: int = 30):
        self.timeout = timeout

    def run(self, kind: str, **kwargs) -> tuple[int, str, str]:
        """Dispatch on kind. Returns (returncode, stdout, stderr)."""
        argv = self._argv_for(kind, **kwargs)
        if argv is None:
            return (127, "", f"unknown kind: {kind}")
        try:
            proc = subprocess.run(
                argv,
                capture_output=True,
                text=True,
                timeout=self.timeout,
                check=False,
            )
            return (proc.returncode, proc.stdout, proc.stderr)
        except subprocess.TimeoutExpired as exc:
            return (124, "", f"timeout: {exc}")
        except (OSError, FileNotFoundError) as exc:
            return (126, "", f"exec failed: {exc}")

    # ----- kind → argv resolution -----
    def _argv_for(self, kind: str, **kwargs) -> list[str] | None:
        if kind == "pgrep_bench_matrix":
            return ["pgrep", "-f", "bench-matrix.sh"]
        if kind == "curl_ollama_tags":
            return [
                "curl",
                "-sf",
                "--max-time",
                "5",
                f"http://{PICO_HOST}:11434/api/tags",
            ]
        if kind == "curl_mlx_models":
            return [
                "curl",
                "-sf",
                "--max-time",
                "5",
                f"http://{PICO_HOST}:8081/v1/models",
            ]
        if kind == "shell_revive_bench_matrix":
            ts = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
            log = f"/tmp/bench-matrix-smoke-{ts}.log"
            cmd = (
                f"nohup bash {shlex.quote(BENCH_MATRIX_SH)} "
                f"--smoke --resume --timeout 20 > {shlex.quote(log)} 2>&1 &"
            )
            return ["bash", "-c", cmd]
        if kind == "ssh_pgrep_hf_download":
            return [
                "ssh",
                "-o",
                "ConnectTimeout=5",
                PICO_SSH,
                "pgrep -fl 'hf download'",
            ]
        if kind == "ssh_ps_pcpu_etime":
            pid = kwargs.get("pid", "")
            return [
                "ssh",
                "-o",
                "ConnectTimeout=5",
                PICO_SSH,
                f"ps -o pcpu=,etime=,args= -p {shlex.quote(str(pid))}",
            ]
        if kind == "ssh_kill_and_restart_hf":
            pid = kwargs.get("pid", "")
            cmdline = kwargs.get("cmdline", "hf download")
            ts = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
            log = f"~/log/hf-pull-{ts}.log"
            # Kill then re-run the same hf download command in nohup.
            remote = (
                f"kill -9 {shlex.quote(str(pid))} 2>/dev/null; "
                f"mkdir -p ~/log; "
                f"nohup {cmdline} > {log} 2>&1 & disown"
            )
            return ["ssh", "-o", "ConnectTimeout=5", PICO_SSH, remote]
        if kind == "systemctl_is_active_hermes":
            return ["systemctl", "--user", "is-active", "hermes-gateway"]
        if kind == "systemctl_restart_hermes":
            return ["systemctl", "--user", "restart", "hermes-gateway"]
        if kind == "hermes_dispatch_dry_run":
            return [HERMES_BIN, "kanban", "dispatch", "--dry-run", "--json"]
        if kind == "hermes_diagnostics_json":
            return [HERMES_BIN, "kanban", "diagnostics", "--json"]
        if kind == "hermes_kanban_show":
            task_id = kwargs.get("task_id", "")
            return [HERMES_BIN, "kanban", "show", task_id]
        if kind == "hermes_kanban_block":
            task_id = kwargs.get("task_id", "")
            reason = kwargs.get(
                "reason", "auto-blocked by zig-watchdog: crash-loop detected"
            )
            return [HERMES_BIN, "kanban", "block", task_id, reason]
        if kind == "curl_dashboard_healthz":
            return ["curl", "-sf", "--max-time", "5", DASHBOARD_HEALTHZ_URL]
        if kind == "shell_start_dashboard":
            return ["bash", START_DASHBOARD_SH]
        return None


# ---------------------------------------------------------------------------
# Job classes
# ---------------------------------------------------------------------------


class _Job:
    """Common config for all job classes."""

    name: str = "_Job"
    cooldown_seconds: int = 600
    max_revive_attempts: int = 3


class BenchMatrixJob(_Job):
    """bench-matrix.sh smoke runs. STALL when aborted-by-healthcheck AND
    backends recovered AND no bench-matrix.sh PID alive."""

    name = "BenchMatrix"

    def __init__(
        self,
        executor: Any,
        results_dir: Path = DEFAULT_RESULTS_DIR,
    ):
        self.executor = executor
        self.results_dir = Path(results_dir)
        self._latest_healthcheck_fail: Path | None = None

    def probe(self) -> ProbeResult:
        # (a) any HEALTHCHECK_FAIL marker present?
        if not self.results_dir.exists():
            return ProbeResult.OK
        fails = sorted(self.results_dir.glob("HEALTHCHECK_FAIL-*.txt"))
        if not fails:
            return ProbeResult.OK
        self._latest_healthcheck_fail = fails[-1]
        # (b) is bench-matrix.sh already running again? if yes, OK (don't double-fire)
        rc, _, _ = self.executor.run("pgrep_bench_matrix")
        if rc == 0:
            return ProbeResult.OK
        # (c) backends back up?
        ol_rc, _, _ = self.executor.run("curl_ollama_tags")
        mlx_rc, _, _ = self.executor.run("curl_mlx_models")
        if ol_rc != 0 or mlx_rc != 0:
            return (
                ProbeResult.UNKNOWN
            )  # backends still down; can't safely revive
        return ProbeResult.STALL

    def revive(self) -> ReviveResult:
        rc, _, _ = self.executor.run("shell_revive_bench_matrix")
        return ReviveResult.SUCCESS if rc == 0 else ReviveResult.FAILED


class HfDownloadJob(_Job):
    """hf download stalls on pico. STALL when CPU=0 AND etime exceeds threshold."""

    name = "HfDownload"
    # The downloads on pico run for hours legitimately, but cooldown stops us
    # firing the same kill+restart twice in a row before progress is visible.
    cooldown_seconds = 600

    def __init__(self, executor: Any):
        self.executor = executor
        # Track stalled (pid → cmdline) discovered in probe() for revive()
        self._stalled: list[tuple[str, str]] = []

    def probe(self) -> ProbeResult:
        self._stalled = []
        rc, out, _ = self.executor.run("ssh_pgrep_hf_download")
        if rc != 0 or not out.strip():
            return ProbeResult.OK
        # Each line: "PID hf download <args>"
        stalled_any = False
        for line in out.splitlines():
            parts = line.split(None, 1)
            if not parts:
                continue
            pid = parts[0].strip()
            if not pid.isdigit():
                continue
            ps_rc, ps_out, _ = self.executor.run("ssh_ps_pcpu_etime", pid=pid)
            if ps_rc != 0 or not ps_out.strip():
                continue
            # ps output like: "0.0 08:23:11 hf download foo/bar"
            ps_parts = ps_out.strip().split(None, 2)
            if len(ps_parts) < 3:
                continue
            try:
                pcpu = float(ps_parts[0])
            except ValueError:
                continue
            etime = ps_parts[1]
            cmdline = ps_parts[2]
            if pcpu == 0.0 and _etime_minutes(etime) >= HF_STALL_ETIME_MIN:
                self._stalled.append((pid, cmdline))
                stalled_any = True
        return ProbeResult.STALL if stalled_any else ProbeResult.OK

    def revive(self) -> ReviveResult:
        if not self._stalled:
            return ReviveResult.FAILED
        all_ok = True
        for pid, cmdline in self._stalled:
            rc, _, _ = self.executor.run(
                "ssh_kill_and_restart_hf", pid=pid, cmdline=cmdline
            )
            if rc != 0:
                all_ok = False
        return ReviveResult.SUCCESS if all_ok else ReviveResult.FAILED


class HermesGatewayJob(_Job):
    """Hermes gateway + kanban dispatcher. CRASH on inactive service OR
    repeated_crashes diagnostic >= threshold."""

    name = "HermesGateway"

    def __init__(self, executor: Any):
        self.executor = executor
        self._service_inactive = False
        # All crash-loop tasks ever detected this probe (for visibility)
        self.crash_loop_task_ids: list[str] = []
        # Subset that aren't already blocked (the ones revive() should act on)
        self._actionable_crash_loop_task_ids: list[str] = []

    def probe(self) -> ProbeResult:
        self._service_inactive = False
        self.crash_loop_task_ids = []
        self._actionable_crash_loop_task_ids = []
        rc, _out, _ = self.executor.run("systemctl_is_active_hermes")
        if rc != 0:
            self._service_inactive = True
            return ProbeResult.CRASH
        # dispatch dry-run as liveness check
        dr_rc, _, _ = self.executor.run("hermes_dispatch_dry_run")
        if dr_rc != 0:
            return ProbeResult.UNKNOWN
        # diagnostics for crash-loop tasks
        diag_rc, diag_out, _ = self.executor.run("hermes_diagnostics_json")
        if diag_rc != 0:
            return ProbeResult.UNKNOWN
        try:
            diags = json.loads(diag_out) if diag_out.strip() else []
        except json.JSONDecodeError:
            return ProbeResult.UNKNOWN
        for entry in diags or []:
            tid = entry.get("task_id")
            for d in entry.get("diagnostics", []) or []:
                if d.get("kind") != "repeated_crashes":
                    continue
                count = (
                    (d.get("data") or {}).get("consecutive_crashes")
                    or d.get("count")
                    or 0
                )
                try:
                    count = int(count)
                except (TypeError, ValueError):
                    count = 0
                if count >= HERMES_CRASH_LOOP_THRESHOLD and tid:
                    self.crash_loop_task_ids.append(tid)
                    # Only block tasks that aren't already blocked.
                    if entry.get("status") != "blocked":
                        self._actionable_crash_loop_task_ids.append(tid)
        # Per-task recent-crashes filter (bd-cke): the diagnostic's
        # `consecutive_crashes` is a lifetime counter that doesn't reset on
        # unblock — so a task that previously crash-looped and was blocked,
        # then unblocked to retry under different conditions (e.g. our skill
        # fix), shows as "97 crashes" forever. Without this filter the
        # watchdog re-blocks any actually-working retry on its first tick.
        # The fix: count `crashed` events whose timestamps fall AFTER the
        # most recent `unblocked` event; only treat as actionable if the
        # recent count meets the threshold.
        recently_actionable: list[str] = []
        for tid in self._actionable_crash_loop_task_ids:
            rc, out, _ = self.executor.run("hermes_kanban_show", task_id=tid)
            if rc != 0:
                # Conservative: if we can't read the events, fall back to
                # the diagnostic's count — i.e. preserve old behavior.
                recently_actionable.append(tid)
                continue
            recent = _count_crashes_since_last_unblock(out)
            if recent >= HERMES_CRASH_LOOP_THRESHOLD:
                recently_actionable.append(tid)
        self._actionable_crash_loop_task_ids = recently_actionable
        # CRASH means "the revive can do something." Stale diagnostics from
        # already-blocked tasks OR tasks whose lifetime counter is stale
        # post-unblock are informational, not actionable. Fix bd-hpi + bd-cke.
        if self._actionable_crash_loop_task_ids:
            return ProbeResult.CRASH
        return ProbeResult.OK

    def revive(self) -> ReviveResult:
        if self._service_inactive:
            rc, _, _ = self.executor.run("systemctl_restart_hermes")
            return ReviveResult.SUCCESS if rc == 0 else ReviveResult.FAILED
        # If every detected crash-loop task is already blocked there's nothing
        # to do — the prior block held; treat as SUCCESS so we don't burn down
        # the revive_attempts counter for a non-actionable observation.
        if (
            not self._actionable_crash_loop_task_ids
            and self.crash_loop_task_ids
        ):
            return ReviveResult.SUCCESS
        if not self._actionable_crash_loop_task_ids:
            return ReviveResult.FAILED
        all_ok = True
        for tid in self._actionable_crash_loop_task_ids:
            rc, _, _ = self.executor.run(
                "hermes_kanban_block",
                task_id=tid,
                reason=(
                    f"auto-blocked by zig-watchdog: "
                    f">={HERMES_CRASH_LOOP_THRESHOLD} crashes detected"
                ),
            )
            if rc != 0:
                all_ok = False
        return ReviveResult.SUCCESS if all_ok else ReviveResult.FAILED


class BenchDashboardJob(_Job):
    """The bench-dashboard SPA itself. CRASH when /healthz unreachable."""

    name = "BenchDashboard"
    cooldown_seconds = 120  # restart is cheap; allow faster retries

    def __init__(self, executor: Any):
        self.executor = executor

    def probe(self) -> ProbeResult:
        rc, _, _ = self.executor.run("curl_dashboard_healthz")
        return ProbeResult.OK if rc == 0 else ProbeResult.CRASH

    def revive(self) -> ReviveResult:
        rc, _, _ = self.executor.run("shell_start_dashboard")
        return ReviveResult.SUCCESS if rc == 0 else ReviveResult.FAILED


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


_ETIME_RE = re.compile(
    r"^(?:(?:(?P<days>\d+)-)?(?P<h>\d+):)?(?P<m>\d+):(?P<s>\d+)$"
)


def _etime_minutes(etime: str) -> float:
    """Convert a ps etime string ([[DD-]HH:]MM:SS) into total minutes."""
    m = _ETIME_RE.match(etime.strip())
    if not m:
        return 0.0
    days = int(m.group("days") or 0)
    hours = int(m.group("h") or 0)
    mins = int(m.group("m") or 0)
    secs = int(m.group("s") or 0)
    return days * 24 * 60 + hours * 60 + mins + secs / 60.0


def _utcnow_iso() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# Tick orchestrator
# ---------------------------------------------------------------------------


def _load_state(state_dir: Path) -> dict[str, Any]:
    f = state_dir / "state.json"
    if not f.exists():
        return {"last_tick_utc": None, "jobs": {}}
    try:
        return json.loads(f.read_text())
    except (OSError, json.JSONDecodeError):
        return {"last_tick_utc": None, "jobs": {}}


def _write_state(state_dir: Path, state: dict[str, Any]) -> None:
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "state.json").write_text(json.dumps(state, indent=2))


def _append_alert(state_dir: Path, alert: dict[str, Any]) -> None:
    state_dir.mkdir(parents=True, exist_ok=True)
    with (state_dir / "alerts.json").open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(alert) + "\n")


def _within_cooldown(
    job_state: dict[str, Any], cooldown_seconds: int, now: datetime
) -> bool:
    last = job_state.get("last_revive_attempt_utc")
    if not last:
        return False
    try:
        last_dt = datetime.strptime(last, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=UTC
        )
    except ValueError:
        return False
    elapsed = (now - last_dt).total_seconds()
    return elapsed < cooldown_seconds


def run_tick(
    jobs: list[Any],
    state_dir: Path,
    now_fn: Callable[[], datetime] = lambda: datetime.now(UTC),
) -> dict[str, Any]:
    """Run one tick across all registered jobs.

    Reads prior state, probes each job, fires revive() when STALL/CRASH
    (subject to cooldown), updates state, appends alerts when revive fails
    AND the per-job revive_attempts counter has crossed max_revive_attempts.

    Returns the new state dict.
    """
    now = now_fn()
    now_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    prior = _load_state(state_dir)
    prior_jobs = prior.get("jobs") or {}

    new_jobs: dict[str, dict[str, Any]] = {}
    for job in jobs:
        prev = prior_jobs.get(job.name, {})
        try:
            probe_result = job.probe()
        except (OSError, ValueError, RuntimeError) as exc:
            logging.warning(
                "probe %s raised %s; treating as UNKNOWN", job.name, exc
            )
            probe_result = ProbeResult.UNKNOWN

        revive_attempts = int(prev.get("revive_attempts") or 0)
        alerting = bool(prev.get("alerting") or False)
        last_revive_attempt_utc = prev.get("last_revive_attempt_utc")

        # If probe is OK, reset counters
        if probe_result == ProbeResult.OK:
            revive_attempts = 0
            alerting = False
        elif probe_result in (ProbeResult.STALL, ProbeResult.CRASH):
            # Respect cooldown
            if _within_cooldown(prev, job.cooldown_seconds, now):
                logging.info("skip revive %s (cooldown not elapsed)", job.name)
            else:
                try:
                    revive_result = job.revive()
                except (OSError, ValueError, RuntimeError) as exc:
                    logging.warning(
                        "revive %s raised %s; treating as FAILED", job.name, exc
                    )
                    revive_result = ReviveResult.FAILED
                last_revive_attempt_utc = now_iso
                if revive_result == ReviveResult.SUCCESS:
                    # Successful action — emit informative alert, reset counter
                    _append_alert(
                        state_dir,
                        {
                            "utc": now_iso,
                            "job": job.name,
                            "kind": f"{probe_result.value.lower()}-recovered",
                            "detail": (
                                f"{probe_result.value} detected; revive returned SUCCESS"
                            ),
                            "auto_action": "revived",
                        },
                    )
                    revive_attempts = 0
                    alerting = False
                else:
                    revive_attempts += 1
                    if revive_attempts >= job.max_revive_attempts:
                        alerting = True
                        _append_alert(
                            state_dir,
                            {
                                "utc": now_iso,
                                "job": job.name,
                                "kind": "revive-exhausted",
                                "detail": (
                                    f"{probe_result.value} persists; "
                                    f"{revive_attempts} consecutive failed revives"
                                ),
                                "auto_action": "alerting",
                            },
                        )
        # UNKNOWN: leave counters alone

        new_jobs[job.name] = {
            "last_probe": probe_result.value
            if isinstance(probe_result, ProbeResult)
            else str(probe_result),
            "last_probe_utc": now_iso,
            "last_revive_attempt_utc": last_revive_attempt_utc,
            "revive_attempts": revive_attempts,
            "alerting": alerting,
        }

    new_state = {"last_tick_utc": now_iso, "jobs": new_jobs}
    _write_state(state_dir, new_state)
    return new_state


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def default_jobs(executor: Any) -> list[Any]:
    return [
        BenchMatrixJob(executor=executor),
        HfDownloadJob(executor=executor),
        HermesGatewayJob(executor=executor),
        BenchDashboardJob(executor=executor),
    ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "zig-watchdog — mechanical stall/crash detection + revive "
            "(run one tick)"
        )
    )
    parser.add_argument(
        "--state-dir",
        type=Path,
        default=DEFAULT_STATE_DIR,
        help=f"state output dir (default: {DEFAULT_STATE_DIR})",
    )
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    executor = SubprocessExecutor()
    jobs = default_jobs(executor)
    state = run_tick(jobs=jobs, state_dir=args.state_dir)

    # Human-friendly summary line
    summary = ", ".join(
        f"{name}={info['last_probe']}" + ("!" if info["alerting"] else "")
        for name, info in state["jobs"].items()
    )
    logging.info("zig-watchdog tick complete: %s", summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
