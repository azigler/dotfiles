#!/usr/bin/env python3
"""Schema gate for the /pulse ledger — every tick must be ATTRIBUTABLE to a row.

The ledger (``refs/pulse-ledger.jsonl``) is authored **by the tick itself** as
free-form JSON: the /pulse skill tells the agent what to append, and nothing
validates the append. Prose in a skill body does not reliably constrain a
machine-written record, so the ledger drifted — 19 of 152 rows carried
``"row": null`` (earliest 2026-06-14). A null row is invisible to
``pulse-cap.py --row <name>`` (which matches on the row NAME) and to every
per-row dashboard/analytic: those ticks happened, consumed budget, and were
unattributable. Same failure class as the ad-hoc invented row name Zig caught
2026-07-14 (the canonical-ledger-row rule).

This is the mechanical half of that fix (``explore-qdo5``): back-filling the 19
rows without a guard just resets the clock. Run it as a pre-commit gate on the
ledger — a violation is a hard stop, not a warning.

FLEET SCOPE. The null rows were not sloppiness: ``agents/skills/pulse/SKILL.md``
documented the ledger format with a ``"row":null`` example line, and the ticks
copied it — 23 null rows across THREE projects' ledgers. The documentation was
the defect, so it was fixed at the source (``dotfiles-b9ii``) and this gate moved
next to the scheduler it guards, because the invariant is fleet-wide: any project
with a ``refs/pulse.md`` + ``refs/pulse-ledger.jsonl`` can run it unchanged.
Paths anchor to ``--project`` (default: cwd), NOT to this script's location —
same ``$PULSE_DIR`` discipline the /pulse SKILL requires of ticks.

WHAT IT ASSERTS, per non-blank line:

* the line is a JSON **object** (a malformed line is a reported violation, never
  a crash — a hand-edit typo must not brick the gate);
* required keys ``ts`` / ``row`` / ``outcome`` are present;
* ``row`` is a non-empty **string** — explicitly NOT ``null``, which is the bug
  this exists to prevent;
* ``row`` is either ``unattributed`` (the honest marker for a tick whose row
  genuinely cannot be recovered — a VISIBLE gap beats a confabulated
  attribution) or a row **name discovered from a routing table** (the ``name``
  column of the markdown table in ``refs/pulse.md``). Row names are never
  hardcoded here: ``refs/pulse.md`` is Zig's steering wheel and this gate reads
  it rather than duplicating it. ``--allow`` extends the set for rows declared
  in ANOTHER project's table or skill — notably ``elevate``, whose weekly sweep
  writes to this ledger but is declared in the global ``/elevate`` SKILL, not in
  explore's own table;
* ``outcome`` is one of ``done`` / ``quiet`` / ``blocked``.

  Why exactly those three: they are the values the fleet actually uses (a census
  of the 152-row ledger at repair time: done 124, quiet 25, blocked 3 — no
  others) AND the set ``refs/pulse.md`` names verbatim ("on *every* outcome
  (done / quiet / blocked)"), matching the global /pulse SKILL, where caps count
  only ``done`` and a refused tick logs ``blocked``. Derived from the data +
  the contract, not invented; a genuinely new outcome should be added to the
  routing contract first, and this gate is where that omission surfaces.
* ``ts`` parses as an ISO-8601 timestamp **in UTC** (``...Z`` or ``+00:00``).
  The whole cap/day-boundary correctness argument in ``pulse-cap.py`` rests on
  ts being UTC; a naive-local ts would silently mis-bucket.

Exit code is the gate (like ``pulse-cap.py`` / ``pulse-stall.py``):
  * exit 0  → clean.
  * exit 1  → violations found.
  * exit 2  → usage / missing-file error.

Usage::

    LINT=~/dotfiles/agents/scheduler/pulse-ledger-lint.py

    python3 "$LINT"                                  # lints ./refs/* (cwd)
    python3 "$LINT" --project ~/explore --allow elevate
    python3 "$LINT" --ledger /abs/pulse-ledger.jsonl --json
    python3 "$LINT" --routing refs/pulse.md --routing other.md
    python3 "$LINT" --selftest                       # regression fixtures
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path

#: Relative to the PROJECT root (``--project``, default cwd) — never to this
#: script's own location: the gate lives in ~/dotfiles but lints other repos.
LEDGER_RELPATH = Path("refs") / "pulse-ledger.jsonl"
ROUTING_RELPATH = Path("refs") / "pulse.md"

REQUIRED_KEYS = ("ts", "row", "outcome")

#: Outcomes the fleet actually writes — see the module docstring for the
#: derivation (ledger census + the ``refs/pulse.md`` / /pulse SKILL contract).
ALLOWED_OUTCOMES = frozenset({"done", "quiet", "blocked"})

#: The one row name that is valid without appearing in any routing table: the
#: honest "we could not recover which row this tick belonged to" marker.
UNATTRIBUTED = "unattributed"


# --------------------------------------------------------------------------- #
# Routing-table discovery — row names come from the table, never from code
# --------------------------------------------------------------------------- #
def _split_md_row(line: str) -> list[str]:
    """Split one markdown table line into stripped cells.

    Pipes escaped as ``\\|`` (used inside the ``check`` one-liners in
    ``refs/pulse.md``) are NOT cell separators — unescape them after splitting.
    """
    inner = line.strip().strip("|")
    cells = re.split(r"(?<!\\)\|", inner)
    return [c.replace("\\|", "|").strip() for c in cells]


def _is_separator(cells: list[str]) -> bool:
    return bool(cells) and all(re.fullmatch(r":?-{2,}:?", c) for c in cells)


def routing_row_names(paths: list[Path]) -> set[str]:
    """Row names from the ``name`` column of every markdown table in ``paths``.

    A pulse routing table is a markdown pipe-table whose header carries a
    ``name`` column (see the /pulse SKILL's contract). Any other table in the
    file is ignored, so a routing doc can carry prose tables safely.
    """
    names: set[str] = set()
    for path in paths:
        if not path.exists():
            continue
        header: list[str] | None = None
        name_idx = -1
        for raw in path.read_text(encoding="utf-8").splitlines():
            if "|" not in raw:
                header, name_idx = None, -1
                continue
            cells = _split_md_row(raw)
            if _is_separator(cells):
                continue
            if header is None:
                header = [c.lower() for c in cells]
                name_idx = header.index("name") if "name" in header else -1
                continue
            if name_idx >= 0 and name_idx < len(cells):
                cell = cells[name_idx].strip().strip("`*_ ")
                if cell:
                    names.add(cell)
    return names


# --------------------------------------------------------------------------- #
# Per-row checks
# --------------------------------------------------------------------------- #
def _ts_violation(ts: object) -> str | None:
    """None if ``ts`` is an ISO-8601 UTC timestamp, else the violation text."""
    if not isinstance(ts, str) or not ts.strip():
        return f"ts is not a non-empty string ({ts!r})"
    s = ts.strip()
    normalized = s[:-1] + "+00:00" if s.endswith(("Z", "z")) else s
    try:
        dt = datetime.fromisoformat(normalized)
    except ValueError:
        return f"ts is not ISO-8601 ({s!r})"
    if dt.tzinfo is None:
        return f"ts carries no timezone; must be UTC ({s!r})"
    if dt.utcoffset().total_seconds() != 0:
        return f"ts is not UTC ({s!r})"
    return None


def check_record(rec: object, valid_rows: set[str]) -> list[str]:
    """All violations for one parsed ledger record (empty list = clean)."""
    if not isinstance(rec, dict):
        return [f"line is not a JSON object (got {type(rec).__name__})"]

    problems: list[str] = []
    for key in REQUIRED_KEYS:
        if key not in rec:
            problems.append(f"missing required key {key!r}")

    if "row" in rec:
        row = rec["row"]
        if row is None:
            problems.append(
                "row is null — the tick is unattributable; use the real row "
                f'name or "{UNATTRIBUTED}"'
            )
        elif not isinstance(row, str):
            problems.append(f"row is not a string ({row!r})")
        elif not row.strip():
            problems.append("row is an empty string")
        elif row not in valid_rows:
            problems.append(
                f"row {row!r} is not in any routing table "
                f"(known: {', '.join(sorted(valid_rows))}); "
                "add it to refs/pulse.md or pass --allow"
            )

    if "outcome" in rec:
        outcome = rec["outcome"]
        if outcome not in ALLOWED_OUTCOMES:
            problems.append(
                f"outcome {outcome!r} is not one of "
                f"{', '.join(sorted(ALLOWED_OUTCOMES))}"
            )

    if "ts" in rec:
        ts_problem = _ts_violation(rec["ts"])
        if ts_problem:
            problems.append(ts_problem)

    return problems


def lint_ledger(ledger: Path, valid_rows: set[str]) -> tuple[int, list[dict]]:
    """Lint a ledger file. Returns ``(rows_checked, violations)``.

    Blank lines are skipped (append-only files routinely end with one); every
    other line is checked. A line that will not parse is reported as a
    violation, not raised — the gate must survive a hand-edit typo.
    """
    violations: list[dict] = []
    checked = 0
    for lineno, raw in enumerate(
        ledger.read_text(encoding="utf-8").splitlines(), 1
    ):
        if not raw.strip():
            continue
        checked += 1
        try:
            rec = json.loads(raw)
        except json.JSONDecodeError as exc:
            violations.append(
                {"line": lineno, "problem": f"malformed JSON: {exc.msg}"}
            )
            continue
        for problem in check_record(rec, valid_rows):
            violations.append({"line": lineno, "problem": problem})
    return checked, violations


# --------------------------------------------------------------------------- #
# Selftest — regression fixtures for every failure mode the gate exists for
# --------------------------------------------------------------------------- #
def _selftest() -> int:
    import tempfile

    routing = """# pulse routing — fixture

| priority | name | trigger | check | action | cap |
|---|---|---|---|---|---|
| 1 | vibe-explore | queue | `jq -e '.a \\| .b'` | do the thing | 4/day |
| 2 | second-row | state | `test -s x` | other thing | 1/day |

Some prose, and an unrelated table that must NOT contribute row names:

| column | other |
|---|---|
| nope | nah |
"""
    tmp = Path(tempfile.mkdtemp())
    routing_path = tmp / "pulse.md"
    routing_path.write_text(routing, encoding="utf-8")

    valid = routing_row_names([routing_path]) | {UNATTRIBUTED}
    assert valid == {"vibe-explore", "second-row", UNATTRIBUTED}, valid
    assert "nope" not in valid, "non-routing table leaked row names"

    def problems(rec: dict) -> list[str]:
        return check_record(rec, valid)

    good = {
        "ts": "2026-07-25T01:21:32Z",
        "row": "vibe-explore",
        "outcome": "done",
    }
    assert problems(good) == [], problems(good)

    # THE BUG GUARD: row=null is exactly the 19-row drift this gate prevents.
    null_row = dict(good, row=None)
    assert any("row is null" in p for p in problems(null_row)), problems(
        null_row
    )

    missing = {"ts": good["ts"], "outcome": "quiet"}
    assert any("missing required key 'row'" in p for p in problems(missing))

    unknown = dict(good, row="made-up-row")
    assert any("not in any routing table" in p for p in problems(unknown))

    # The honest gap marker is always accepted.
    assert problems(dict(good, row=UNATTRIBUTED, outcome="quiet")) == []

    assert any("outcome" in p for p in problems(dict(good, outcome="ok")))
    assert any(
        "ts" in p for p in problems(dict(good, ts="2026-07-25 01:21:32"))
    )
    assert any(
        "not UTC" in p
        for p in problems(dict(good, ts="2026-07-25T01:21:32-07:00"))
    )
    assert problems(dict(good, ts="2026-07-25T01:21:32+00:00")) == []
    assert problems([1, 2, 3]) == ["line is not a JSON object (got list)"]

    # A malformed line is a REPORTED violation, never a crash.
    ledger = tmp / "ledger.jsonl"
    ledger.write_text(
        json.dumps(good)
        + "\n"
        + "{not json\n"
        + "\n"
        + json.dumps(null_row)
        + "\n",
        encoding="utf-8",
    )
    checked, violations = lint_ledger(ledger, valid)
    assert checked == 3, checked  # blank line skipped
    assert [v["line"] for v in violations] == [2, 4], violations
    assert "malformed JSON" in violations[0]["problem"]

    print(
        "pulse-ledger-lint selftest: PASS "
        "(null row, missing key, unknown row, bad outcome/ts, malformed line)"
    )
    return 0


# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument(
        "--project",
        type=Path,
        default=None,
        help=(
            "project root the default ledger/routing paths resolve against "
            "(default: the current directory)"
        ),
    )
    ap.add_argument(
        "--ledger",
        type=Path,
        default=None,
        help=f"path to the pulse ledger (default: <project>/{LEDGER_RELPATH})",
    )
    ap.add_argument(
        "--routing",
        type=Path,
        action="append",
        default=None,
        help=(
            "routing table markdown to discover row names from; repeatable "
            f"(default: <project>/{ROUTING_RELPATH})"
        ),
    )
    ap.add_argument(
        "--allow",
        action="append",
        default=None,
        metavar="ROW",
        help=(
            "additionally allow this row name (for rows declared in another "
            "project's routing table or skill, e.g. --allow elevate); "
            "repeatable"
        ),
    )
    ap.add_argument(
        "--json", action="store_true", help="machine-readable output"
    )
    ap.add_argument(
        "--selftest",
        action="store_true",
        help="run the regression fixtures and exit",
    )
    args = ap.parse_args()

    if args.selftest:
        return _selftest()

    project = (args.project or Path.cwd()).resolve()
    ledger = (
        args.ledger if args.ledger is not None else project / LEDGER_RELPATH
    )
    routing_paths = args.routing or [project / ROUTING_RELPATH]

    missing = [p for p in routing_paths if not p.exists()]
    if missing:
        for p in missing:
            print(
                f"pulse-ledger-lint: routing table not found: {p}",
                file=sys.stderr,
            )
        return 2
    if not ledger.exists():
        print(
            f"pulse-ledger-lint: ledger not found: {ledger}",
            file=sys.stderr,
        )
        return 2

    table_rows = routing_row_names(routing_paths)
    if not table_rows:
        print(
            "pulse-ledger-lint: no row names found in "
            f"{', '.join(str(p) for p in routing_paths)} — refusing to lint "
            "against an empty routing set",
            file=sys.stderr,
        )
        return 2

    valid_rows = table_rows | {UNATTRIBUTED} | set(args.allow or [])
    checked, violations = lint_ledger(ledger, valid_rows)

    if args.json:
        print(
            json.dumps(
                {
                    "ledger": str(ledger),
                    "routing": [str(p) for p in routing_paths],
                    "valid_rows": sorted(valid_rows),
                    "rows_checked": checked,
                    "violations": violations,
                    "ok": not violations,
                }
            )
        )
        return 1 if violations else 0

    for v in violations:
        print(f"{ledger}:{v['line']}: {v['problem']}")
    print(f"ledger={ledger}")
    print(f"rows_checked={checked}")
    print(f"valid_rows={','.join(sorted(valid_rows))}")
    print(f"violations={len(violations)}")
    print(f"verdict: {'FAIL' if violations else 'CLEAN'}")
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
