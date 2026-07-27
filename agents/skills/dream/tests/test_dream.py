"""Tests for the DETERMINISTIC recall-distill helper (spec explore-76oc §4.4).

These pin the mechanical contract only — window filtering, signal matching,
dedupe, and the JSON output shape. The LLM-judgment part (is a candidate a
durable learning?) is the TICK's job and is deliberately NOT tested here.

Every test drives distill.py -> recall.py against a fixture projects tree, and
pins each file's mtime explicitly so the window (since) filter never depends on
the runner's wall clock.
"""

from __future__ import annotations

import re
import sys
from datetime import UTC, datetime
from pathlib import Path

from _distill_helpers import (
    DISTILL_PY,
    assistant_turn,
    main_path,
    progress_line,
    set_mtime,
    tool_result_path,
    user_turn,
    write_text,
    write_turns,
)

# import distill for the pattern-compile unit check
sys.path.insert(0, str(DISTILL_PY.parent))
import distill

SLUG = "-home-ubuntu-explore"
SLUG_FLAG = f"--slug={SLUG}"

SINCE_ISO = "2026-07-01T00:00:00Z"
SINCE_EPOCH = datetime(2026, 7, 1, tzinfo=UTC).timestamp()
IN_WINDOW = SINCE_EPOCH + 86400  # a day after `since`
BEFORE_WINDOW = SINCE_EPOCH - 86400  # a day before `since`

TOP_KEYS = {
    "since",
    "slug",
    "scanned_sessions",
    "window_sessions",
    "n_candidates",
    "truncated",
    "candidates",
}
CANDIDATE_KEYS = {"slug", "session", "ts", "role", "line", "text", "signals"}


# --------------------------------------------------------------------------- #
# Window filtering
# --------------------------------------------------------------------------- #
def test_window_excludes_sessions_older_than_since(distill, root):
    """A session whose files predate `since` is NOT scanned; only the in-window
    session's learning surfaces."""
    old = write_turns(
        main_path(root, SLUG, session="old-session"),
        [user_turn("from now on always run the tests", 0)],
    )
    new = write_turns(
        main_path(root, SLUG, session="new-session"),
        [user_turn("from now on always run the tests", 0)],
    )
    set_mtime(old, BEFORE_WINDOW)
    set_mtime(new, IN_WINDOW)

    r = distill(f"--since={SINCE_ISO}", SLUG_FLAG, root=root)
    assert r.returncode == 0, r.stderr
    out = r.json()

    assert out["scanned_sessions"] == 2
    assert out["window_sessions"] == 1
    sessions = {c["session"] for c in out["candidates"]}
    assert sessions == {"new-session"}, (
        "the pre-window session must be filtered out"
    )


def test_window_defaults_include_recent_files(distill, root):
    """With --since given, files stamped after it are in-window (sanity for the
    baseline all-tests-set-mtime assumption)."""
    f = write_turns(
        main_path(root, SLUG),
        [
            assistant_turn(
                "the fix was to add a flock; verified it works now", 0
            )
        ],
    )
    set_mtime(f, IN_WINDOW)
    r = distill(f"--since={SINCE_ISO}", SLUG_FLAG, root=root)
    assert r.returncode == 0, r.stderr
    assert r.json()["window_sessions"] == 1


# --------------------------------------------------------------------------- #
# Signal matching
# --------------------------------------------------------------------------- #
def test_signal_gotcha(distill, root):
    f = write_turns(
        main_path(root, SLUG),
        [assistant_turn("watch out for this pitfall in the argv parser", 0)],
    )
    set_mtime(f, IN_WINDOW)
    r = distill(f"--since={SINCE_ISO}", SLUG_FLAG, root=root)
    assert r.returncode == 0, r.stderr
    cands = r.json()["candidates"]
    assert len(cands) == 1
    assert cands[0]["signals"] == ["gotcha"]


def test_signal_preference(distill, root):
    f = write_turns(
        main_path(root, SLUG),
        [user_turn("from now on, please always run the linter", 0)],
    )
    set_mtime(f, IN_WINDOW)
    r = distill(f"--since={SINCE_ISO}", SLUG_FLAG, root=root)
    assert r.returncode == 0, r.stderr
    cands = r.json()["candidates"]
    assert len(cands) == 1
    assert cands[0]["signals"] == ["preference"]


def test_no_signal_no_candidate(distill, root):
    """A turn with no learning-signal phrase yields zero candidates (exit 0)."""
    f = write_turns(
        main_path(root, SLUG),
        [
            user_turn("the weather is nice today", 0),
            assistant_turn("here is the file you asked about", 1),
        ],
    )
    set_mtime(f, IN_WINDOW)
    r = distill(f"--since={SINCE_ISO}", SLUG_FLAG, root=root)
    assert r.returncode == 0, r.stderr
    out = r.json()
    assert out["n_candidates"] == 0
    assert out["candidates"] == []


# --------------------------------------------------------------------------- #
# Dedupe (one turn, multiple signals -> one candidate)
# --------------------------------------------------------------------------- #
def test_dedupe_multi_signal_collapses_to_one_candidate(distill, root):
    """A single turn matched by TWO signal patterns collapses to ONE candidate
    carrying both signal labels — not two candidates."""
    f = write_turns(
        main_path(root, SLUG),
        [user_turn("actually, I prefer that you always use spaces", 0)],
    )
    set_mtime(f, IN_WINDOW)
    r = distill(f"--since={SINCE_ISO}", SLUG_FLAG, root=root)
    assert r.returncode == 0, r.stderr
    cands = r.json()["candidates"]
    assert len(cands) == 1, "the same turn must not appear twice"
    assert set(cands[0]["signals"]) == {"correction", "preference"}


# --------------------------------------------------------------------------- #
# Role filtering (durable learnings live in conversational turns only)
# --------------------------------------------------------------------------- #
def test_role_filter_drops_tool_results_and_progress(distill, root):
    """The same learning phrase in a user turn, a tool-results txt, and a
    non-conversational `progress` record yields exactly ONE candidate — the user
    turn. tool-result / progress are dropped by the role filter, not matched
    away."""
    phrase = "please always run the linter"
    main = write_turns(
        main_path(root, SLUG),
        [user_turn(phrase, 0), progress_line(phrase, 1)],
    )
    tr = write_text(
        tool_result_path(root, SLUG), phrase + " (raw tool output)\n"
    )
    set_mtime(main, IN_WINDOW)
    set_mtime(tr, IN_WINDOW)

    r = distill(f"--since={SINCE_ISO}", SLUG_FLAG, root=root)
    assert r.returncode == 0, r.stderr
    cands = r.json()["candidates"]
    assert len(cands) == 1
    assert cands[0]["role"] in {"user", "assistant"}


# --------------------------------------------------------------------------- #
# JSON output shape
# --------------------------------------------------------------------------- #
def test_json_output_shape(distill, root):
    f = write_turns(
        main_path(root, SLUG),
        [user_turn("from now on always squash the migrations", 0)],
    )
    set_mtime(f, IN_WINDOW)
    r = distill(f"--since={SINCE_ISO}", SLUG_FLAG, root=root)
    assert r.returncode == 0, r.stderr
    out = r.json()
    assert set(out.keys()) == TOP_KEYS
    assert out["slug"] == SLUG
    assert out["since"].endswith("Z")
    assert isinstance(out["candidates"], list)
    for c in out["candidates"]:
        assert set(c.keys()) == CANDIDATE_KEYS
        assert isinstance(c["signals"], list)
        assert isinstance(c["line"], int)


def test_max_candidates_caps_and_flags_truncated(distill, root):
    """--max-candidates bounds the emit and sets truncated=True when it bites."""
    turns = [
        user_turn(f"from now on always do thing number {i}", i)
        for i in range(5)
    ]
    f = write_turns(main_path(root, SLUG), turns)
    set_mtime(f, IN_WINDOW)
    r = distill(
        f"--since={SINCE_ISO}", SLUG_FLAG, "--max-candidates=2", root=root
    )
    assert r.returncode == 0, r.stderr
    out = r.json()
    assert out["n_candidates"] == 2
    assert out["truncated"] is True
    assert len(out["candidates"]) == 2


# --------------------------------------------------------------------------- #
# Error paths (exit 2)
# --------------------------------------------------------------------------- #
def test_bad_root_exits_2(distill, tmp_path):
    r = distill(f"--since={SINCE_ISO}", SLUG_FLAG, root=tmp_path / "nope")
    assert r.returncode == 2
    assert "root" in r.stderr.lower()


def test_missing_recall_exits_2(distill, root):
    r = distill(
        f"--since={SINCE_ISO}",
        SLUG_FLAG,
        root=root,
        recall=Path("/nonexistent/recall.py"),
    )
    assert r.returncode == 2
    assert "recall" in r.stderr.lower()


def test_bad_since_exits_2(distill, root):
    write_turns(main_path(root, SLUG), [user_turn("i prefer tabs", 0)])
    r = distill("--since=not-a-timestamp", SLUG_FLAG, root=root)
    assert r.returncode == 2
    assert "since" in r.stderr.lower()


# --------------------------------------------------------------------------- #
# Unit: every signal pattern is a valid, compilable regex
# --------------------------------------------------------------------------- #
def test_all_signal_patterns_compile():
    assert distill.SIGNALS, "there must be at least one learning signal"
    names = [s.name for s in distill.SIGNALS]
    assert len(names) == len(set(names)), "signal names must be unique"
    for sig in distill.SIGNALS:
        re.compile(sig.pattern)  # raises re.error if malformed
        assert sig.rationale.strip(), f"{sig.name} must document WHY it signals"
