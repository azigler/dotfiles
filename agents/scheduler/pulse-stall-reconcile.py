#!/usr/bin/env python3
"""pulse-stall-reconcile — write the ledger row a DEAD tick could not write.

WHY THIS EXISTS (explore-88k9)
------------------------------
Every pulse loop's ledger row is written by the tick itself, at its wrap step. That
works for done / quiet / blocked, which all presuppose a tick healthy enough to reach
its wrap step. It cannot work for the one failure that matters most: a tick that dies
before completing a single turn. It has no way to report, so the ledger stays silent,
and silence is indistinguishable from "still running".

On 2026-07-28 both dive fires (00:00 and 06:00 PT) 401'd on turn one — the tick-jail's
OAuth credential had frozen (explore-4a2o) — and wrote nothing at all. ``pulse-inject``
had logged ``PULSE_INJECT_RESULT=injected`` for both, so from the outside each fire
looked delivered. The dashboard could only say ``stale``.

This is ``~/explore/CLAUDE.md``'s "name the consumer in the same change as the
producer", applied to the fire itself: an injected fire is a producer whose only
consumer is the tick it wakes up. When that consumer dies, nothing closes the loop.
This script is the independent consumer — outside the tick, outside the jail, LLM-free,
so it survives exactly the conditions that kill a tick.

WHAT IT DOES
------------
For each loop in the harnessd manifest:

  1. read the loop's last fire from its systemd timer (``LastTriggerUSec``);
  2. if the fire is older than the loop's ``grace_minutes`` (default 90) and NO ledger
     row has landed since that fire, append ONE ``outcome: "stalled"`` row;
  3. skip a fire already recorded as a BOUNCE — a bounce means the tick never started
     (the window was 🔔-blocked and pulse-inject deliberately typed nothing), which is
     a different, self-healing condition that harnessd already renders.

Idempotency is structural, not bookkept: the row this script appends itself carries a
``ts`` after the fire, so the next run sees a row in-window and stands down. One row per
unreported fire, forever, with no state file to corrupt.

DELIBERATELY NOT DONE HERE: no re-fire, no repair, no notification-by-default. Writing
the truthful row is the whole job — harnessd already turns a ``stalled`` row into an
attention state, and re-firing a loop whose tick just died in an unknown way is how you
turn one stalled tick into a loop that burns tokens all night.

Usage:
    pulse-stall-reconcile.py [--dry-run] [--manifest PATH] [--now ISO8601]

Exit codes: 0 = ran (whether or not it wrote anything), 1 = could not run at all.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

DEFAULT_MANIFEST = Path.home() / "harnessd" / "refs" / "harness-manifest.json"
BOUNCES_PATH = (
    Path.home() / ".local" / "state" / "harness" / "pulse-bounces.jsonl"
)
LOG_PATH = (
    Path.home() / ".local" / "state" / "harness" / "pulse-stall-reconcile.log"
)
DEFAULT_GRACE_MINUTES = 90

#: Extra head-room on top of the loop's declared grace before we call a fire dead.
#: ``grace_minutes`` is what the DASHBOARD uses to start showing concern; writing a
#: permanent ledger row is a stronger claim than colouring a cell, so it waits longer.
#: Without this, a legitimately long tick that overruns its grace by a few minutes
#: would get a "stalled" row written underneath it while it is still working.
STALL_MARGIN_MINUTES = 30

# How long after a trigger a service start can still be ATTRIBUTED to it.
# systemd starts the service within seconds; the slack is for RandomizedDelaySec
# and a loaded box. Anything later was started by something else (a manual
# `systemctl start`, pulse-retry, a hand-run) while LastTriggerUSec still points
# at the older stamp — and attributing it to that stamp writes a stall for a fire
# that never happened (dotfiles-05jn, second half).
ATTRIBUTION_WINDOW_MINUTES = 15


def parse_iso(s: str | None) -> datetime | None:
    if not s or not isinstance(s, str):
        return None
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=UTC)


def timer_last_fire(unit: str) -> datetime | None:
    """Last trigger time of a systemd user timer, or None if never/unknown."""
    try:
        out = subprocess.run(
            ["systemctl", "--user", "show", unit, "-p", "LastTriggerUSec"],
            capture_output=True,
            text=True,
            timeout=15,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    val = out.split("=", 1)[1].strip() if "=" in out else ""
    # systemd prints "n/a" (or empty) when the timer has never fired.
    if not val or val == "n/a":
        return None
    # e.g. "Tue 2026-07-28 13:00:30 UTC"
    for fmt in ("%a %Y-%m-%d %H:%M:%S %Z", "%a %Y-%m-%d %H:%M:%S UTC"):
        try:
            return datetime.strptime(val, fmt).replace(tzinfo=UTC)
        except ValueError:
            continue
    return None


def service_last_start(unit: str) -> datetime | None:
    """When the .service last actually EXECUTED, or None if it never has.

    THE DEFECT THIS EXISTS FOR (dotfiles-05jn). ``systemctl enable --now`` starts the
    TIMER unit and stamps its ``LastTriggerUSec`` **without ever running the service**.
    Reading the timer alone therefore reports a fire that never invoked anything, and
    this script would then write a ``stalled`` row for it. Live instance 2026-08-01:
    re-arming autonoveld's four timers produced four phantom stall rows, all pinned to
    the enable-time second, while all four services showed an EMPTY
    ``ExecMainStartTimestamp``.

    So a fire is only real if the service ran AT OR AFTER it. Empty means never ran;
    older than the trigger means some previous fire ran it, not this one.
    """
    try:
        out = subprocess.run(
            [
                "systemctl",
                "--user",
                "show",
                unit,
                "-p",
                "ExecMainStartTimestamp",
            ],
            capture_output=True,
            text=True,
            timeout=15,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    val = out.split("=", 1)[1].strip() if "=" in out else ""
    if not val or val == "n/a":
        return None
    for fmt in ("%a %Y-%m-%d %H:%M:%S %Z", "%a %Y-%m-%d %H:%M:%S UTC"):
        try:
            return datetime.strptime(val, fmt).replace(tzinfo=UTC)
        except ValueError:
            continue
    return None


def load_jsonl(path: Path) -> list[dict]:
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return []
    rows = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict):
            rows.append(obj)
    return rows


def newest_row_ts(ledger: Path, row_name: str | None) -> datetime | None:
    """Newest ``ts`` among ledger rows matching ``row_name``.

    ``row_name`` None means MATCH ANY ROW — the manifest's documented pin for a loop
    whose single timer writes several row names (picod). Mirrors
    ``ledger_streak.matches_row`` rather than importing it, so this script keeps working
    when ~/harnessd is absent (a VPS tick host) — the manifest is the only dependency.
    """
    best = None
    for obj in load_jsonl(ledger):
        if row_name is not None and obj.get("row") != row_name:
            continue
        ts = parse_iso(obj.get("ts"))
        if ts and (best is None or ts > best):
            best = ts
    return best


def newest_bounce_ts(bounces: list[dict], loop: str) -> datetime | None:
    best = None
    for obj in bounces:
        if obj.get("loop") != loop:
            continue
        ts = parse_iso(obj.get("ts"))
        if ts and (best is None or ts > best):
            best = ts
    return best


def stalled_row(
    row_name: str, fire: datetime, now: datetime, timer: str
) -> dict:
    waited = int((now - fire).total_seconds() // 60)
    return {
        "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "row": row_name,
        "outcome": "stalled",
        "reconciled": True,
        "fire_ts": fire.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "timer": timer,
        # Every clause below is something this script ACTUALLY established. The
        # previous wording asserted three things it never checked — that pulse-inject
        # "reported the tick INJECTED", that the tick "did not bounce (it was typed
        # into a ready window)", and that it "did not block (nothing chose to park on
        # Andrew)" — while reading only LastTriggerUSec and the ledger. That is the
        # dotfiles-cxle class (the consumer reports what the step never established),
        # and its sibling dotfiles-kel5. State what was checked; name what was not.
        "note": (
            f"STALLED — {timer}.timer triggered at {fire:%Y-%m-%dT%H:%M:%SZ} AND "
            f"{timer}.service executed (ExecMainStartTimestamp at or after that "
            f"trigger), but no `{row_name}` row landed in the {waited}m since, and no "
            "bounce was recorded for this timer in that window. So the tick started "
            "and did not report. NOT CHECKED HERE: whether pulse-inject typed "
            "successfully, and whether the tick parked on Zig — this script reads the "
            "timer, the service start, the ledger and the bounce log, nothing else. "
            "Row written by pulse-stall-reconcile, NOT by the tick: a tick that cannot "
            "complete a turn cannot log its own failure (explore-88k9). Check the "
            "window's pane and the session transcript for the first turn's error."
        ),
    }


def append_row(ledger: Path, row: dict) -> None:
    with ledger.open("a") as fh:
        fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def log(entry: dict) -> None:
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open("a") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError:
        pass


def reconcile(manifest_path: Path, now: datetime, dry_run: bool) -> list[dict]:
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(
            f"pulse-stall-reconcile: cannot read manifest {manifest_path}: {exc}",
            file=sys.stderr,
        )
        raise SystemExit(1) from exc

    bounces = load_jsonl(BOUNCES_PATH)
    written: list[dict] = []

    for project in manifest.get("projects", []):
        project_path = project.get("path")
        for loop in project.get("loops", []):
            timer = loop.get("timer")
            ledger_rel = loop.get("ledger")
            if not timer or not ledger_rel or not project_path:
                continue

            # ``ledger_row: null`` legitimately means "match any row" — keep that
            # semantic rather than skipping, but we cannot INVENT a row name for a
            # stalled write, so such loops are reported and skipped (see note below).
            row_name = loop.get("ledger_row")

            fire = timer_last_fire(f"{timer}.timer")
            if fire is None:
                continue

            # dotfiles-05jn: a timer trigger is NOT a fire. `enable --now` stamps
            # LastTriggerUSec without executing the service, so gate on whether the
            # SERVICE actually ran at or after the trigger. Without this, every
            # re-arm / install / rename manufactures a stall row for a tick that was
            # never invoked — and does it at exactly the moment an operator is least
            # sure whether the loop is healthy.
            # The start must ALSO belong to THIS trigger. systemd starts the
            # service within seconds of firing, so a start hours later was caused
            # by something else — a manual `systemctl start`, pulse-retry, a
            # hand-run — while LastTriggerUSec still points at the old (or
            # enable-time) stamp. Without this window the manual run gets
            # attributed to the stale trigger and we write a stall for a fire that
            # never happened. Found 2026-08-01: a `systemctl start` at 22:44 was
            # blamed on the 19:05 re-arm stamp, 3.5h earlier.
            svc_start = service_last_start(f"{timer}.service")
            attributable = (
                svc_start is not None
                and fire
                <= svc_start
                <= fire + timedelta(minutes=ATTRIBUTION_WINDOW_MINUTES)
            )
            if not attributable:
                log(
                    {
                        "ts": now.isoformat(),
                        "event": "skipped-timer-armed-but-service-never-ran",
                        "timer": timer,
                        "fire_ts": fire.isoformat(),
                        "service_last_start": (
                            svc_start.isoformat() if svc_start else None
                        ),
                        "why": (
                            "the timer unit was activated (enable --now / install / "
                            "rename) but the service did not execute for this "
                            "trigger — not a stall"
                        ),
                    }
                )
                continue

            grace = loop.get("grace_minutes") or DEFAULT_GRACE_MINUTES
            deadline = fire + timedelta(minutes=grace + STALL_MARGIN_MINUTES)
            if now < deadline:
                continue

            ledger = Path(os.path.expanduser(project_path)) / ledger_rel
            if not ledger.exists():
                continue

            if (
                last := newest_row_ts(ledger, row_name)
            ) is not None and last >= fire:
                continue  # the tick reported; nothing to do (also the idempotency gate)

            bounce = newest_bounce_ts(bounces, timer)
            if bounce is not None and bounce >= fire:
                continue  # bounced, not stalled — a different, self-healing condition

            if row_name is None:
                # A null pin means the loop writes several row names; there is no honest
                # single name to attribute a stalled row to, and guessing would corrupt
                # the very signal this script exists to make trustworthy.
                log(
                    {
                        "ts": now.isoformat(),
                        "event": "skipped-null-row",
                        "timer": timer,
                        "ledger": str(ledger),
                    }
                )
                continue

            row = stalled_row(row_name, fire, now, timer)
            if not dry_run:
                append_row(ledger, row)
                log(
                    {
                        "ts": now.isoformat(),
                        "event": "stalled-row-written",
                        "timer": timer,
                        "row": row_name,
                        "ledger": str(ledger),
                        "fire_ts": row["fire_ts"],
                    }
                )
            written.append({"timer": timer, "ledger": str(ledger), **row})

    return written


# --------------------------------------------------------------------------- #
# Self-test fixtures. Hermetic: a tmpdir manifest + ledgers, a stubbed timer
# reader. No real project, ledger, systemd unit, or tmux server is touched.
# Run: pulse-stall-reconcile.py --selftest
# --------------------------------------------------------------------------- #
def _selftest() -> int:
    import tempfile

    global timer_last_fire, BOUNCES_PATH, LOG_PATH

    real_timer, real_bounces, real_log = timer_last_fire, BOUNCES_PATH, LOG_PATH
    failures: list[str] = []

    def check(name: str, got, want) -> None:
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    fire = datetime(2026, 7, 28, 13, 0, 30, tzinfo=UTC)
    late = datetime(
        2026, 7, 28, 16, 0, 0, tzinfo=UTC
    )  # past 90m grace + 30m margin
    early = datetime(2026, 7, 28, 14, 0, 0, tzinfo=UTC)  # inside grace

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        proj = root / "proj" / "refs"
        proj.mkdir(parents=True)
        ledger = proj / "pulse-ledger.jsonl"
        manifest = root / "manifest.json"
        LOG_PATH = root / "reconcile.log"
        BOUNCES_PATH = root / "bounces.jsonl"

        manifest.write_text(
            json.dumps(
                {
                    "projects": [
                        {
                            "key": "proj",
                            "path": str(root / "proj"),
                            "loops": [
                                {
                                    "timer": "pulse-fake",
                                    "ledger": "refs/pulse-ledger.jsonl",
                                    "ledger_row": "fake",
                                    "grace_minutes": 90,
                                }
                            ],
                        }
                    ]
                }
            )
        )

        timer_last_fire = lambda unit: fire  # noqa: E731

        def rows() -> list[dict]:
            return load_jsonl(ledger)

        # 1. inside grace -> silent, even with an empty ledger
        ledger.write_text("")
        check(
            "inside-grace writes nothing", reconcile(manifest, early, False), []
        )

        # 2. past deadline, no row -> exactly one stalled row
        written = reconcile(manifest, late, False)
        check("past-deadline writes one row", len(written), 1)
        check("outcome is stalled", [r["outcome"] for r in rows()], ["stalled"])
        check("row name preserved", rows()[0]["row"], "fake")
        check("fire_ts recorded", rows()[0]["fire_ts"], "2026-07-28T13:00:30Z")

        # 3. IDEMPOTENCY — the row it just wrote is itself the reconciled marker
        check("second run is a no-op", reconcile(manifest, late, False), [])
        check("still exactly one row", len(rows()), 1)

        # 4. the tick DID report -> never reconciled
        ledger.write_text(
            json.dumps(
                {"ts": "2026-07-28T13:45:00Z", "row": "fake", "outcome": "done"}
            )
            + "\n"
        )
        check(
            "reported tick is left alone", reconcile(manifest, late, False), []
        )

        # 5. a BOUNCE for that fire -> skipped (tick never started; self-healing)
        ledger.write_text("")
        BOUNCES_PATH.write_text(
            json.dumps(
                {
                    "ts": "2026-07-28T13:00:35Z",
                    "loop": "pulse-fake",
                    "reason": "blocked_on_andrew",
                }
            )
            + "\n"
        )
        check("bounced fire is skipped", reconcile(manifest, late, False), [])
        BOUNCES_PATH.write_text("")

        # 6. ledger_row: null -> skipped, never guessed
        manifest.write_text(manifest.read_text().replace('"fake"', "null"))
        check("null row is skipped", reconcile(manifest, late, False), [])
        manifest.write_text(
            manifest.read_text().replace(
                '"ledger_row": null', '"ledger_row": "fake"'
            )
        )

        # 7. --dry-run touches nothing
        ledger.write_text("")
        check("dry-run reports", len(reconcile(manifest, late, True)), 1)
        check("dry-run wrote nothing", rows(), [])

        # 8. a timer that never fired -> nothing to reconcile
        timer_last_fire = lambda unit: None  # noqa: E731
        check(
            "never-fired timer is skipped", reconcile(manifest, late, False), []
        )

    timer_last_fire, BOUNCES_PATH, LOG_PATH = real_timer, real_bounces, real_log

    if failures:
        for f in failures:
            print(f"  FAIL {f}", file=sys.stderr)
        print(
            f"pulse-stall-reconcile selftest: {len(failures)} FAILURE(S)",
            file=sys.stderr,
        )
        return 1
    print(
        "pulse-stall-reconcile selftest: PASS (8 cases — grace window, "
        "stalled write, idempotency, reported tick, bounce, null row, "
        "dry-run, never-fired)"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="report what would be written; touch nothing",
    )
    ap.add_argument("--now", help="ISO8601 override for tests")
    ap.add_argument(
        "--selftest",
        action="store_true",
        help="run hermetic regression fixtures",
    )
    args = ap.parse_args(argv)

    if args.selftest:
        return _selftest()

    now = parse_iso(args.now) if args.now else datetime.now(UTC)
    if now is None:
        print(f"pulse-stall-reconcile: bad --now {args.now!r}", file=sys.stderr)
        return 1

    written = reconcile(args.manifest, now, args.dry_run)
    for row in written:
        verb = "would write" if args.dry_run else "wrote"
        print(
            f"{verb} stalled row: {row['timer']} -> {row['ledger']} "
            f"(fire {row['fire_ts']})"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
