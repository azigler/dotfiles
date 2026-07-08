"""Regression tests for the /scrutinize fix-first batch (F1-F4) on recall.py.

These ADD coverage for four load-bearing fixes found by running recall.py
against the real corpus. They do NOT modify or weaken the original 19 contract
tests in test_recall.py.

F1 — aggregate ReDoS abort: a pathological --regex pattern must abort the WHOLE
     run (exit 2, loud notice), not just bound each line.
F2 — loud/unrenderable matches must appear in the --json channel too (role=
     "unrenderable"), closing the false-complete-through-json D7 hole.
F3 — known non-conversational types (ai-title / last-prompt / file-history-
     snapshot / progress / ...) render as searchable hits keyed by `type` so
     the loud channel is reserved for genuine schema drift (an UNKNOWN type).
     NOTE: this impl RENDERS known structural types as hits rather than the
     silently-dropping them — that is strictly more D7-faithful (nothing is
     dropped) and keeps the merged test_recall_type_keyed_render_handles_all_types
     green, while still emptying the loud channel of known-type noise.
F4 — a `thinking` block renders its cleartext; a signature-only
     `redacted_thinking` block is quietly skipped (not loud).
"""

from __future__ import annotations

import json
import subprocess

import pytest
from _recall_helpers import jline, main_path, ts, write_bytes

SLUG = "-home-ubuntu-explore"
JSON_KEYS = {"slug", "session", "ts", "role", "line", "text"}


def _json(result):
    return json.loads(result.stdout or "[]")


# --------------------------------------------------------------------------- #
# Local record builders for the new schemas (real-corpus shapes, 2026-07-07)
# --------------------------------------------------------------------------- #
def ai_title_line(text: str) -> dict:
    return {"type": "ai-title", "aiTitle": text, "sessionId": "s-0001"}


def last_prompt_line(text: str) -> dict:
    return {
        "type": "last-prompt",
        "lastPrompt": text,
        "leafUuid": "lp-0",
        "sessionId": "s-0001",
    }


def real_file_history_snapshot(text: str) -> dict:
    # real shape: snapshot is an object; put the searchable token in a tracked path
    return {
        "type": "file-history-snapshot",
        "messageId": "fhs-0",
        "snapshot": {
            "messageId": "fhs-0",
            "trackedFileBackups": {text: "bk"},
            "timestamp": ts(0),
        },
        "isSnapshotUpdate": False,
    }


def progress_real(text: str) -> dict:
    return {
        "type": "progress",
        "uuid": "prog-0",
        "timestamp": ts(0),
        "data": {"note": text},
    }


def unknown_vendor_line(text: str) -> dict:
    return {"type": "mystery-vendor-zzz", "uuid": "mys-0", "payload": text}


def thinking_turn(text: str, n: int = 0) -> dict:
    return {
        "type": "assistant",
        "uuid": f"asst-{n:04d}",
        "timestamp": ts(n),
        "message": {
            "role": "assistant",
            "content": [{"type": "thinking", "thinking": text}],
        },
    }


def redacted_thinking_turn(marker: str, n: int = 1) -> dict:
    # signature-only encrypted block: `data` carries no cleartext to render.
    return {
        "type": "assistant",
        "uuid": f"asst-{n:04d}",
        "timestamp": ts(n),
        "message": {
            "role": "assistant",
            "content": [{"type": "redacted_thinking", "data": marker}],
        },
    }


def catastrophic_turn(n: int) -> dict:
    # a long run of 'a' that makes `(a+)+$` backtrack catastrophically.
    return {
        "type": "assistant",
        "uuid": f"asst-{n:04d}",
        "timestamp": ts(n),
        "message": {
            "role": "assistant",
            "content": [{"type": "text", "text": "a" * 2500}],
        },
    }


# --------------------------------------------------------------------------- #
# F1 — aggregate ReDoS abort over a MULTI-line fixture
# --------------------------------------------------------------------------- #
def test_f1_regex_guard_aborts_whole_run(recall, root):
    """A catastrophic --regex over >=10 lines must ABORT THE RUN (exit 2, loud
    notice) within a few seconds — NOT bound each line and grind for
    (per-line-budget * N) seconds. Without the aggregate abort this fixture
    (12 catastrophic lines * 2s budget) would take ~24s and time out."""
    write_bytes(
        main_path(root, SLUG), *(jline(catastrophic_turn(i)) for i in range(12))
    )
    try:
        r = recall(r"(a+)+$", f"--slug={SLUG}", "--regex", root=root, timeout=8)
    except subprocess.TimeoutExpired:
        pytest.fail(
            "aggregate ReDoS guard missing: run did not abort — it kept scanning "
            "line-by-line past the first budget trip (F1 regression)"
        )
    assert r.returncode == 2, "a tripped ReDoS guard must be an error exit (2)"
    low = r.stderr.lower()
    assert "abort" in low and ("redos" in low or "guard" in low), (
        f"the abort must be announced loudly; got stderr={r.stderr!r}"
    )


# --------------------------------------------------------------------------- #
# F2 — loud/unrenderable matches surface in the --json channel too
# --------------------------------------------------------------------------- #
def test_f2_unrenderable_match_appears_in_json(recall, root):
    """An UNKNOWN-schema matched line must appear in --json as role=
    "unrenderable" (same 6-key set) AND on stderr — a caller reading only the
    json channel must not get a false-complete `[]`."""
    write_bytes(
        main_path(root, SLUG),
        jline(unknown_vendor_line("DRIFTQ hidden in an unknown schema")),
    )
    r = recall("DRIFTQ", f"--slug={SLUG}", "--json", root=root)
    assert r.returncode == 0
    data = _json(r)
    assert data, (
        "the unrenderable match must be present in the json array, not dropped"
    )
    for obj in data:
        assert set(obj.keys()) == JSON_KEYS, (
            f"unexpected key set: {sorted(obj.keys())}"
        )
    hit = next(o for o in data if "DRIFTQ" in o["text"])
    assert hit["role"] == "unrenderable", (
        "a drift line carries role='unrenderable' in json"
    )
    assert isinstance(hit["line"], int)
    # loud stderr channel still fires with the raw line
    assert "DRIFTQ" in r.stderr, (
        "the loud stderr surface must still carry the raw drift line"
    )


# --------------------------------------------------------------------------- #
# F3 — known non-conversational types render as hits; loud reserved for drift
# --------------------------------------------------------------------------- #
def test_f3_text_bearing_types_render_as_hits(recall, root):
    """ai-title / last-prompt carry real user/agent text in top-level fields;
    they must render as searchable hits keyed by `type`, not be loud/dropped."""
    write_bytes(
        main_path(root, SLUG),
        jline(ai_title_line("TITLEQ Explore recall coverage AITSENT")),
        jline(last_prompt_line("PROMPTQ what did we decide LPSENT")),
    )
    r1 = recall("TITLEQ", f"--slug={SLUG}", "--json", root=root)
    assert r1.returncode == 0, r1.stderr
    hit = next(o for o in _json(r1) if "AITSENT" in o["text"])
    assert hit["role"] == "ai-title"
    assert "incomplete" not in r1.stderr, (
        "a text-bearing known type must not go loud"
    )

    r2 = recall("PROMPTQ", f"--slug={SLUG}", "--json", root=root)
    assert r2.returncode == 0, r2.stderr
    hit = next(o for o in _json(r2) if "LPSENT" in o["text"])
    assert hit["role"] == "last-prompt"


def test_f3_known_structural_types_do_not_flood_loud(recall, root):
    """A query matching a spread of KNOWN non-conversational types (file-history-
    snapshot / progress) must produce ZERO loud lines — they render as hits keyed
    by type. This is the flood fix: loud is reserved for genuine drift."""
    write_bytes(
        main_path(root, SLUG),
        jline(real_file_history_snapshot("FLOODQ")),
        jline(progress_real("FLOODQ progress note")),
        jline(ai_title_line("FLOODQ title text")),
    )
    r = recall("FLOODQ", f"--slug={SLUG}", "--json", root=root)
    assert r.returncode == 0, r.stderr
    assert "incomplete" not in r.stderr, (
        f"known structural types flooded the loud channel: {r.stderr!r}"
    )
    roles = {o["role"] for o in _json(r)}
    assert "unrenderable" not in roles, "no known type should surface as drift"
    assert {"file-history-snapshot", "progress", "ai-title"} <= roles


def test_f3_unknown_type_is_loud_drift(recall, root):
    """A genuinely-UNKNOWN top-level type is the ONE thing that still goes loud
    (drift detector intact)."""
    write_bytes(
        main_path(root, SLUG),
        jline(unknown_vendor_line("NOVELQ from a never-seen vendor schema")),
    )
    r = recall("NOVELQ", f"--slug={SLUG}", root=root)
    assert r.returncode == 0
    assert "incomplete" in r.stderr and "NOVELQ" in r.stderr, (
        "an unknown type must remain a loud drift alarm"
    )


def test_f3_pr_and_agent_metadata_types_render_not_loud(recall, root):
    """Graduation-gate regression: pr-link (1268 real corpus records), agent-name,
    and agent-setting are KNOWN bulk types. They must render as searchable hits
    keyed by `type`, NOT flood the loud drift channel — a routine PR search must
    not cry wolf (the exact flood F3 was built to close)."""
    write_bytes(
        main_path(root, SLUG),
        jline(
            {
                "type": "pr-link",
                "sessionId": "s-1",
                "prNumber": 1,
                "prUrl": "https://github.com/azigler/PRQ-repo/pull/1",
                "prRepository": "azigler/PRQ-repo",
                "timestamp": ts(0),
            }
        ),
        jline(
            {
                "type": "agent-name",
                "sessionId": "s-1",
                "agentName": "ANQ generate machine status report",
            }
        ),
        jline(
            {
                "type": "agent-setting",
                "sessionId": "s-1",
                "agentSetting": "ASQ general-purpose",
            }
        ),
    )
    r = recall("PRQ-repo", f"--slug={SLUG}", "--json", root=root)
    assert r.returncode == 0, r.stderr
    assert "incomplete" not in r.stderr, (
        f"pr-link must not flood the loud channel: {r.stderr!r}"
    )
    assert (
        next(o for o in _json(r) if "PRQ-repo" in o["text"])["role"]
        == "pr-link"
    )

    r2 = recall("ANQ", f"--slug={SLUG}", "--json", root=root)
    assert r2.returncode == 0 and "incomplete" not in r2.stderr
    assert (
        next(o for o in _json(r2) if "ANQ" in o["text"])["role"] == "agent-name"
    )

    r3 = recall("ASQ", f"--slug={SLUG}", "--json", root=root)
    assert r3.returncode == 0 and "incomplete" not in r3.stderr
    assert (
        next(o for o in _json(r3) if "ASQ" in o["text"])["role"]
        == "agent-setting"
    )


# --------------------------------------------------------------------------- #
# F4 — thinking cleartext renders; redacted signature-only block quietly skipped
# --------------------------------------------------------------------------- #
def test_f4_thinking_renders_and_redacted_is_quiet(recall, root):
    """A `thinking` block with cleartext renders (searchable hit); a
    signature-only `redacted_thinking` block that matches is QUIETLY skipped —
    not loud, not a hit."""
    write_bytes(
        main_path(root, SLUG),
        jline(thinking_turn("THINKQ private reasoning THINKSENT", 0)),
        jline(
            redacted_thinking_turn(
                "THINKQ_encrypted REDSENT_should_not_render", 1
            )
        ),
    )
    r = recall("THINKQ", f"--slug={SLUG}", root=root)
    assert r.returncode == 0, r.stderr
    assert "THINKSENT" in r.stdout, "thinking cleartext must render as a hit"
    assert "incomplete" not in r.stderr, (
        "a signature-only redacted_thinking block must be quiet, not a false drift alarm"
    )
    assert "REDSENT" not in r.combined, (
        "the redacted block carries no cleartext — nothing to surface"
    )
