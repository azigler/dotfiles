#!/usr/bin/env python3
"""seneschal-gather.py — the front desk's deterministic aggregation pass.

The runner behind ``/seneschal brief`` (bead ``dotfiles-front-desk-faty``). The
SKILL says WHAT the brief is; this says HOW it is assembled, so the skill body
stays a charter instead of a recipe (``feedback_skill_body_is_what_not_how``).

WHAT IT IS NOT. It has no authority. It reads; it never dispatches, never runs
``br update``/``br close``, never send-keys, never writes outside ``--out``. The
seneschal reports and routes; the MARSHAL dispatches (seats.yml charter lines,
ratified in ``dotfiles-seat-address-spec-uikg``). That boundary is constitutional
— a brief that could act would be a dispatch surface with a reporting label on
it, and the laundering path (some loop reading the brief as a work queue) is the
threat the ADVISORY header exists to make grep-visible.

SOURCES, IN PREFERENCE ORDER. The cross-repo ``human:`` aggregation ALREADY
EXISTS and runs: ~/harnessd's daemon joins beads, the tmux 🔔 lexicon and loop
states into ``state.json``. This consumes that bus and only falls back to a local
roster scan when the bus is unreachable — building a second aggregator would be
the two-copies defect with a fast clock.

FAILS LOUD, NEVER SHORT. Every section reports ``N of M`` read and names what it
could not read. A source that is down renders as a degraded section with the
reason on the line; it never renders as "nothing to report", because those two
look identical to a reader and mean opposite things.

CONFIDENTIALITY. ``refs/`` is git-tracked and pushed, so ``linearb*`` / ``cfp*``
titles and commit subjects must never reach the brief body
(``feedback_linearb_beads_confidential``). Those repos are counted, never quoted
— the same prefix denylist ``agents/skills/dream/dream.py`` uses
(``CONFIDENTIAL_PREFIXES``), for the same reason. The brief file is ALSO
gitignored; the denylist is the belt, the gitignore is the braces.

Usage:
    seneschal-gather.py [--out PATH|-] [--hours 24] [--state-url URL]
                        [--roster PATH] [--now ISO8601] [--tz America/Los_Angeles]

Env overrides (all exist so the suite can drive real code paths, not stubs):
    SENESCHAL_STATE_URL    default state-bus URL
    SENESCHAL_SYSTEMCTL    systemctl binary (section TODAY)
    SENESCHAL_FLEET_HEALTH fleet-health ledger path (section THE WORKS)
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import UTC, datetime, timedelta
from pathlib import Path

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - stdlib since 3.9
    ZoneInfo = None  # type: ignore[assignment]

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_STATE_URL = os.environ.get(
    "SENESCHAL_STATE_URL", "http://100.98.174.21:14174/state.json"
)
DEFAULT_ROSTER = REPO_ROOT / "agents" / "seats.yml"
DEFAULT_OUT = REPO_ROOT / "refs" / "seneschal-brief.md"
DEFAULT_TZ = "America/Los_Angeles"
FLEET_HEALTH = Path(
    os.environ.get(
        "SENESCHAL_FLEET_HEALTH", "~/.local/share/fleet-health/pico.jsonl"
    )
).expanduser()
# The laurels ledger `dream.py laurels` appends to (dotfiles-qnfk R2/R4). The
# brief is where Zig sees EVERY placement — that visibility is what lets the
# placement be direct rather than propose-gated.
LAURELS = Path(
    os.environ.get(
        "SENESCHAL_LAURELS", "~/.local/share/fleet-health/laurels.jsonl"
    )
).expanduser()
LAUREL_WINDOW_DAYS = 7  # one dream cycle: the brief shows the week's placements

# Prefix match, not equality: `linearb-notes` and `cfp2026` are the same secret.
CONFIDENTIAL_PREFIXES = ("linearb", "cfp")

MAX_NEEDS = 8
MAX_SHIPPED = 10
MAX_TIMERS = 8
BLOCKED_GLYPH = "🔔"


def clip(text: str, width: int) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= width else text[: width - 1] + "…"


def is_confidential(path: Path) -> bool:
    return any(
        part.startswith(CONFIDENTIAL_PREFIXES)
        for part in Path(path).expanduser().parts
    )


# --------------------------------------------------------------------------
# roster — the repo set is DERIVED from seats.yml `home:`, never a second copy
# --------------------------------------------------------------------------
def parse_roster(path: Path) -> tuple[dict[str, dict[str, str]], list[str]]:
    """Minimal seats.yml reader: seat name -> {home, model}.

    Hand-parsed on purpose, exactly as ``agents/lib/validate-seats.py`` is: the
    brief must render on a box with no PyYAML, and the two keys it wants are
    unambiguous at fixed indentation.
    """
    seats: dict[str, dict[str, str]] = {}
    errs: list[str] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        return {}, [f"roster unreadable ({exc.strerror or exc})"]
    in_seats = False
    cur = None
    for line in lines:
        if re.match(r"^seats:\s*$", line):
            in_seats = True
            continue
        if in_seats and re.match(r"^\S", line):
            in_seats = False
        if not in_seats:
            continue
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if m:
            cur = m.group(1)
            seats[cur] = {}
            continue
        if cur is None:
            continue
        m = re.match(r"^    (home|model|office|sigil):\s*(.+?)\s*$", line)
        if m:
            seats[cur][m.group(1)] = m.group(2).strip("\"'")
    if not seats:
        errs.append("roster parsed to 0 seats")
    return seats, errs


def roster_repos(seats: dict[str, dict[str, str]]) -> list[Path]:
    out: list[Path] = []
    for seat in seats.values():
        home = seat.get("home")
        if not home:
            continue
        p = Path(home).expanduser()
        if p not in out and (p / ".git").exists():
            out.append(p)
    return sorted(out)


# --------------------------------------------------------------------------
# the state bus
# --------------------------------------------------------------------------
def fetch_state(url: str, timeout: float = 6.0) -> tuple[dict | None, str]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8")), ""
    except (urllib.error.URLError, OSError, ValueError, TimeoutError) as exc:
        return None, f"{type(exc).__name__}: {clip(str(exc), 60)}"


# --------------------------------------------------------------------------
# (a) NEEDS YOU
# --------------------------------------------------------------------------
def needs_from_state(state: dict) -> list[str]:
    rows = []
    for b in (state.get("you") or {}).get("beads") or []:
        age = b.get("age_days")
        age_s = f"{age:.0f}d" if isinstance(age, (int, float)) else "?d"
        title = re.sub(r"^human:\s*", "", str(b.get("title", "")))
        rows.append(
            f"P{b.get('priority', '?')} {b.get('id', '?')} · {age_s} · {clip(title, 84)}"
        )
    return rows


def _repo_has_beads(repo: Path) -> bool:
    return (repo / ".beads" / "issues.jsonl").exists()


def _repo_has_db(repo: Path) -> bool:
    beads_dir = repo / ".beads"
    return beads_dir.is_dir() and any(beads_dir.glob("*.db"))


def br_list(
    repo: Path, extra_args: list[str], timeout: float = 15.0
) -> tuple[list[dict[str, str]], str]:
    """Read via `br list`, never as a mutation (``dotfiles-6f8s``).

    Two read modes, chosen per-repo, both proven zero-mutation by measurement
    (mtimes of every ``.beads/*`` file unchanged across the call):

    - Repo already has a `.beads/*.db`: DB-backed read with
      ``--no-auto-import --no-auto-flush``. This is a REAL improvement over
      hand-parsing the JSONL — it sees writes still unflushed to disk, which
      the JSONL-only path below (and the old hand-parse) cannot.
    - Repo has no `.beads/*.db` yet: ``--no-db`` (JSONL-only) instead. Bare
      DB-mode `br list` on a JSONL-only repo was measured to CREATE
      `beads.db` + `beads.db-wal` + `.br_recovery/` as a side effect — an
      advisory read of ANOTHER repo's store must never do that, which is
      exactly why the original code avoided `br` entirely. This path does
      not see unflushed DB writes (there is no DB); that is an honest
      tradeoff, not a silently-eaten one.

    Either way this replaces hand-rolled `json.loads` line-parsing with `br`'s
    own CSV writer + native `--status`/`--title-contains` filtering.
    """
    if not _repo_has_beads(repo):
        return [], ""
    mode_args = (
        ["--no-auto-import", "--no-auto-flush"]
        if _repo_has_db(repo)
        else ["--no-db"]
    )
    cmd = [
        "br",
        "list",
        "--format",
        "csv",
        "--no-color",
        "--limit",
        "0",
        *mode_args,
        *extra_args,
    ]
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(repo),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return [], type(exc).__name__
    if proc.returncode != 0:
        return [], clip(
            (proc.stderr or "").strip() or f"rc={proc.returncode}", 50
        )
    try:
        rows = list(csv.DictReader(io.StringIO(proc.stdout)))
    except csv.Error as exc:
        return [], f"unparseable csv: {type(exc).__name__}"
    return rows, ""


def needs_from_repos(
    repos: list[Path], now: datetime
) -> tuple[list[str], list[str]]:
    """Fallback scan, via `br_list` (see its docstring for the mutation
    guarantee). Reads each repo's open `human:` beads."""
    rows: list[tuple[int, float, str]] = []
    unreadable: list[str] = []
    for repo in repos:
        if not _repo_has_beads(repo):
            continue
        recs, err = br_list(
            repo,
            [
                "--status",
                "open",
                "--title-contains",
                "human:",
                "--fields",
                "id,title,priority,created_at",
            ],
        )
        if err:
            unreadable.append(f"{repo.name} ({err})")
            continue
        for b in recs:
            title = str(b.get("title", ""))
            if not title.lower().startswith("human:"):
                continue
            age = age_days(b.get("created_at"), now)
            shown = (
                "<redacted — confidential repo>"
                if is_confidential(repo)
                else title
            )
            shown = re.sub(r"^human:\s*", "", shown)
            priority = b.get("priority", "9") or "9"
            rows.append(
                (
                    int(priority),
                    -age,
                    f"P{priority} {b.get('id', '?')} · "
                    f"{age:.0f}d · {clip(shown, 84)}",
                )
            )
    rows.sort()
    return [r[2] for r in rows], unreadable


def age_days(ts: str | None, now: datetime) -> float:
    d = parse_ts(ts)
    return 0.0 if d is None else max(0.0, (now - d).total_seconds() / 86400)


def parse_ts(ts: str | None) -> datetime | None:
    if not ts:
        return None
    s = str(ts).replace("Z", "+00:00")
    s = re.sub(
        r"\.(\d{6})\d+", r".\1", s
    )  # br writes nanoseconds; py wants micro
    try:
        d = datetime.fromisoformat(s)
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=UTC)


def blocked_sessions(state: dict) -> list[str]:
    out = []
    for w in state.get("fleet") or []:
        glyph = str(w.get("glyph", ""))
        st = str(w.get("state", ""))
        if BLOCKED_GLYPH in glyph or st in ("blocked", "waiting"):
            dwell = w.get("dwell_minutes")
            dwell_s = (
                f"{dwell:.0f}m" if isinstance(dwell, (int, float)) else "?"
            )
            out.append(
                f"{BLOCKED_GLYPH} {w.get('window', '?')} · blocked {dwell_s}"
            )
    return out


# --------------------------------------------------------------------------
# (b) SHIPPED OVERNIGHT
# --------------------------------------------------------------------------
def git_since(repo: Path, since_iso: str) -> tuple[int, list[str], str]:
    try:
        proc = subprocess.run(
            [
                "git",
                "-C",
                str(repo),
                "log",
                "--no-merges",
                f"--since={since_iso}",
                "--pretty=format:%s",
            ],
            capture_output=True,
            text=True,
            timeout=25,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return 0, [], type(exc).__name__
    if proc.returncode != 0:
        return 0, [], clip(proc.stderr or f"rc={proc.returncode}", 40)
    subjects = [s for s in proc.stdout.splitlines() if s.strip()]
    return len(subjects), subjects, ""


def closed_since(repo: Path, cutoff: datetime) -> tuple[int, str]:
    """Via `br_list` (see its docstring for the mutation guarantee)."""
    if not _repo_has_beads(repo):
        return 0, ""
    recs, err = br_list(
        repo, ["--status", "closed", "--fields", "id,closed_at,updated_at"]
    )
    if err:
        return 0, err
    n = 0
    for b in recs:
        d = parse_ts(b.get("closed_at") or b.get("updated_at"))
        if d and d >= cutoff:
            n += 1
    return n, ""


# --------------------------------------------------------------------------
# (c) THE WORKS — pico, per the estate lexicon (dotfiles-demesne-lexicon-gadu)
# --------------------------------------------------------------------------
def works_lines(path: Path, limit: int = 3) -> list[str]:
    if not path.exists():
        return ["watcher not yet built (dotfiles-kkpq)"]
    try:
        rows = [
            ln
            for ln in path.read_text(encoding="utf-8").splitlines()
            if ln.strip()
        ]
    except OSError as exc:
        return [f"ledger unreadable: {type(exc).__name__}"]
    if not rows:
        return ["ledger present but empty"]
    out = []
    for ln in rows[-limit:]:
        try:
            d = json.loads(ln)
            out.append(clip(" · ".join(f"{k}={v}" for k, v in d.items()), 96))
        except ValueError:
            out.append(clip(ln, 96))
    return out


# --------------------------------------------------------------------------
# (c2) LAURELS — placement weeks ONLY (dotfiles-qnfk R4/T10)
# --------------------------------------------------------------------------
def laurel_lines(
    path: Path,
    now: datetime,
    seats: dict[str, dict[str, str]],
    window_days: int = LAUREL_WINDOW_DAYS,
) -> tuple[list[str], str]:
    """Rendered laurel lines for the window, plus a degraded-read reason.

    NO CEREMONY WITHOUT SUBSTANCE. An absent ledger, or a ledger with nothing
    in the window, returns ``([], "")`` and the caller emits NO SECTION AT ALL
    — a standing "## LAURELS — none this week" would train the reader to skip
    the heading, and the heading is the whole point on the weeks it fires.

    A ledger that EXISTS but cannot be read is different, and says so: that is
    a degraded read, and this file's rule is fail-loud-never-short.
    """
    if not path.exists():
        return [], ""
    try:
        raw = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        return [], f"laurels ledger unreadable: {type(exc).__name__}"
    cutoff = now - timedelta(days=window_days)
    rows: list[tuple[datetime, str]] = []
    bad = 0
    for ln in raw:
        if not ln.strip():
            continue
        try:
            d = json.loads(ln)
        except ValueError:
            bad += 1
            continue
        when = parse_ts(d.get("ts"))
        if when is None or when < cutoff:
            continue
        seat = str(d.get("seat", "?"))
        row = seats.get(seat, {})
        office = row.get("office", "")
        home = row.get("home", "")
        head = f"🏅 {seat}" + (f" ({office})" if office else "")
        # Same denylist posture as every other section: a laurel earned in a
        # confidential repo is COUNTED, never quoted.
        if home and is_confidential(Path(home)):
            rows.append(
                (when, f"{head} — details withheld (confidential repo)")
            )
            continue
        cite = " · ".join(
            x for x in (str(d.get("bead", "")), str(d.get("commit", ""))) if x
        )
        body = clip(str(d.get("title", "")), 48)
        why = clip(str(d.get("why", "")), 70)
        rows.append(
            (
                when,
                f"{head} · {body}"
                + (f" — {why}" if why else "")
                + (f"  [{cite}]" if cite else ""),
            )
        )
    rows.sort()
    err = f"{bad} unparseable ledger line(s)" if bad else ""
    return [r[1] for r in rows], err


# --------------------------------------------------------------------------
# (d) TODAY
# --------------------------------------------------------------------------
def timers_next(now: datetime, horizon: datetime, tz) -> tuple[list[str], str]:
    binary = os.environ.get("SENESCHAL_SYSTEMCTL", "systemctl")
    try:
        proc = subprocess.run(
            [
                binary,
                "--user",
                "list-timers",
                "--all",
                "--no-pager",
                "--output=json",
            ],
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return [], type(exc).__name__
    if proc.returncode != 0:
        return [], clip(proc.stderr or f"rc={proc.returncode}", 40)
    try:
        rows = json.loads(proc.stdout or "[]")
    except ValueError:
        return [], "unparseable systemctl json"
    out: list[tuple[datetime, str]] = []
    for r in rows:
        nxt = r.get("next")
        if not isinstance(nxt, (int, float)) or nxt <= 0:
            continue
        when = datetime.fromtimestamp(nxt / 1_000_000, tz=UTC)
        if when > horizon or when < now:
            continue
        out.append((when, str(r.get("unit", "?")).removesuffix(".timer")))
    out.sort()
    return [f"{w.astimezone(tz).strftime('%H:%M')}  {u}" for w, u in out], ""


# --------------------------------------------------------------------------
# render
# --------------------------------------------------------------------------
def build(args) -> str:
    tz = ZoneInfo(args.tz) if ZoneInfo else UTC
    now = parse_ts(args.now) or datetime.now(UTC)
    cutoff = now - timedelta(hours=args.hours)
    horizon = now + timedelta(hours=24)

    seats, roster_errs = parse_roster(Path(args.roster))
    repos = roster_repos(seats)
    model = seats.get("seneschal", {}).get("model", "unknown")

    state, state_err = fetch_state(args.state_url)

    L: list[str] = []
    L.append(
        f"<!-- seneschal-brief v1 | advisory: true | authority: none | "
        f"dispatch: never | generated: {now.astimezone(tz).isoformat(timespec='seconds')} "
        f"| roster-model: {model} -->"
    )
    L.append(
        f"# 🗝 SENESCHAL BRIEF — {now.astimezone(tz).strftime('%a %Y-%m-%d %H:%M %Z')}"
    )
    L.append("")
    bus = "state bus OK" if state else f"state bus DOWN ({state_err})"
    src = [bus, f"roster {len(seats)} seats / {len(repos)} repos"]
    src += roster_errs
    L.append("sources: " + " | ".join(src))
    L.append("")

    # (a) NEEDS YOU -------------------------------------------------------
    if state:
        needs = needs_from_state(state)
        needs_src = "state bus (fleet-wide)"
        needs_bad: list[str] = []
    else:
        needs, needs_bad = needs_from_repos(repos, now)
        needs_src = f"LOCAL roster scan of {len(repos)} repos — bus down, coverage is narrower"
    blocked = blocked_sessions(state) if state else []

    L.append(
        f"## 🔔 NEEDS YOU — {len(needs)} open human: beads, {len(blocked)} blocked seats"
    )
    L.append(f"_source: {needs_src}_")
    if needs_bad:
        L.append(
            f"_UNREADABLE: {len(needs_bad)} ledger(s) — {', '.join(needs_bad)}_"
        )
    for row in needs[:MAX_NEEDS]:
        L.append(f"- {row}")
    if len(needs) > MAX_NEEDS:
        L.append(f"- …and {len(needs) - MAX_NEEDS} more")
    for row in blocked:
        L.append(f"- {row}")
    if not needs and not blocked:
        L.append(
            "- nothing blocked on Zig "
            + ("✅" if state else "(per a DEGRADED read)")
        )
    L.append("")

    # (b) SHIPPED OVERNIGHT ----------------------------------------------
    since_iso = cutoff.astimezone(UTC).isoformat()
    ship_lines: list[str] = []
    commits = closed = scanned = 0
    ship_bad: list[str] = []
    for repo in repos:
        n, subjects, err = git_since(repo, since_iso)
        if err:
            ship_bad.append(f"{repo.name} ({err})")
            continue
        scanned += 1
        c, cerr = closed_since(repo, cutoff)
        if cerr:
            ship_bad.append(f"{repo.name}/beads ({cerr})")
        commits += n
        closed += c
        if n == 0 and c == 0:
            continue
        head = f"{repo.name}: {n} commit{'s' if n != 1 else ''}, {c} bead{'s' if c != 1 else ''} closed"
        if is_confidential(repo):
            ship_lines.append(head + " — subjects withheld (confidential repo)")
        else:
            ship_lines.append(
                head + (f" — {clip(subjects[0], 68)}" if subjects else "")
            )
    L.append(
        f"## 📦 SHIPPED OVERNIGHT — {commits} commit{'s' if commits != 1 else ''}, "
        f"{closed} bead{'s' if closed != 1 else ''} closed "
        f"in {args.hours}h ({scanned} of {len(repos)} repos read)"
    )
    if ship_bad:
        L.append(f"_UNREADABLE: {', '.join(ship_bad)}_")
    for row in sorted(ship_lines)[:MAX_SHIPPED]:
        L.append(f"- {row}")
    if len(ship_lines) > MAX_SHIPPED:
        L.append(f"- …and {len(ship_lines) - MAX_SHIPPED} more repos")
    if not ship_lines:
        L.append("- no commits and no bead closures in the window")
    L.append("")

    # (c2) LAURELS — rendered ONLY on a week something was placed (T10) ----
    laurels, laurel_err = laurel_lines(LAURELS, now, seats)
    if laurels or laurel_err:
        L.append(
            f"## 🏅 LAURELS — {len(laurels)} placed in the last {LAUREL_WINDOW_DAYS}d"
        )
        L.append(
            "_placed by the Remembrancer from cited evidence; the seat cannot "
            "award itself (dotfiles-qnfk R2/R6)_"
        )
        if laurel_err:
            L.append(f"_UNREADABLE: {laurel_err}_")
        for row in laurels:
            L.append(f"- {row}")
        L.append("")

    # (c) THE WORKS -------------------------------------------------------
    L.append("## 🏭 THE WORKS — pico")
    for row in works_lines(FLEET_HEALTH):
        L.append(f"- {row}")
    L.append("")

    # (d) TODAY -----------------------------------------------------------
    timers, terr = timers_next(now, horizon, tz)
    L.append(f"## 📅 TODAY — {len(timers)} timers in the next 24h")
    if terr:
        L.append(f"- UNREADABLE: systemctl — {terr}")
    for row in timers[:MAX_TIMERS]:
        L.append(f"- {row}")
    if len(timers) > MAX_TIMERS:
        L.append(f"- …and {len(timers) - MAX_TIMERS} more")
    if not timers and not terr:
        L.append("- nothing scheduled in the next 24h")
    L.append("")
    L.append(
        "_ADVISORY ONLY — the seneschal reports and routes; the marshal dispatches. "
        "This brief is not a work queue._"
    )
    return "\n".join(L) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Assemble the seneschal's daily brief."
    )
    ap.add_argument(
        "--out",
        default=str(DEFAULT_OUT),
        help="write the brief here too ('-' = stdout only)",
    )
    ap.add_argument("--hours", type=float, default=24.0)
    ap.add_argument("--state-url", default=DEFAULT_STATE_URL)
    ap.add_argument("--roster", default=str(DEFAULT_ROSTER))
    ap.add_argument("--now", default=None, help="ISO8601 override (tests)")
    ap.add_argument("--tz", default=DEFAULT_TZ)
    args = ap.parse_args(argv)

    brief = build(args)
    sys.stdout.write(brief)
    if args.out != "-":
        out = Path(args.out).expanduser()
        try:
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(brief, encoding="utf-8")
        except OSError as exc:
            print(f"WARN: could not write {out}: {exc}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
