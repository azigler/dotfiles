#!/usr/bin/env python3
"""Fixture test for migrate-user-config.py (dotfiles-tihhn round 3).

Covers exactly the defect classes the round 3 review flagged:
  - a dotted/quoted model-name key in [tui.model_availability_nux]
    ("gpt-5.1") that a bare-key writer would mis-parse as a nested table
  - an array value ([projects.*].tags)
  - a date value ([projects.*].first_seen)
  - a multiline (embedded-newline/tab) string ([tui].welcome_note)
  - a /tmp project entry, which must be dropped as scratch junk

Run directly: `python3 codex/test_migrate_user_config.py`. Exits 0 with
"ALL TESTS PASSED" on success, non-zero with a traceback/assertion message
on failure — no pytest dependency, since this repo has no existing test
harness to plug into.
"""

import importlib.util
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODULE_PATH = HERE / "migrate-user-config.py"

FIXTURE = """\
project_doc_max_bytes = 131072
sandbox_mode = "danger-full-access"
approval_policy = "never"

[projects."/home/ubuntu/demesne"]
trust_level = "trusted"
tags = ["harness", "trusted-seat"]
first_seen = 2026-09-24

[projects."/tmp/some-scratch-dir"]
trust_level = "trusted"

[projects."/home/ubuntu/this-path-does-not-exist-xyz-fixture"]
trust_level = "trusted"

[tui]
screen_reader_detection_done = true
welcome_note = "line one\\nline two\\ttabbed"

[tui.model_availability_nux]
gpt-6-astra = 2
"gpt-5.1" = 1
"""


def load_module():
    spec = importlib.util.spec_from_file_location(
        "migrate_user_config", MODULE_PATH
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_end_to_end_via_subprocess():
    """Run the script exactly as sync.sh would: as a subprocess against a
    real destination path (a plain file this time, standing in for
    ~/.codex/config.toml)."""
    with tempfile.TemporaryDirectory() as td:
        old_path = Path(td) / "old-config.toml"
        old_path.write_text(FIXTURE)
        new_path = Path(td) / "new-config.toml"
        new_path.write_text(
            "pre-existing content that must survive any failure\n"
        )

        result = subprocess.run(
            [sys.executable, str(MODULE_PATH), str(old_path), str(new_path)],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, f"migration failed: {result.stderr}"

        out = tomllib.loads(new_path.read_text())

        assert "/tmp/some-scratch-dir" not in out.get("projects", {}), (
            "a /tmp project entry must be dropped as scratch junk"
        )
        assert (
            "/home/ubuntu/this-path-does-not-exist-xyz-fixture"
            not in out.get("projects", {})
        ), "a project entry whose path no longer exists must be dropped"

        real = out["projects"]["/home/ubuntu/demesne"]
        assert real["tags"] == ["harness", "trusted-seat"], (
            "array value must survive"
        )
        import datetime

        assert real["first_seen"] == datetime.date(2026, 9, 24), (
            "date value must survive"
        )

        assert out["tui"]["welcome_note"] == "line one\nline two\ttabbed", (
            "multiline/control-char string must round-trip byte-for-byte"
        )

        nux = out["tui"]["model_availability_nux"]
        assert nux == {"gpt-6-astra": 2, "gpt-5.1": 1}, (
            f"dotted model key must round-trip as ONE key, not a nested table: {nux!r}"
        )

        for policy_key in (
            "project_doc_max_bytes",
            "sandbox_mode",
            "approval_policy",
        ):
            assert policy_key not in out, (
                f"policy key {policy_key!r} must be dropped"
            )

        print("test_end_to_end_via_subprocess: PASS")


def test_unquoted_keys_are_rejected_by_the_round_trip_guard():
    """Prove the safety net actually bites: if key-quoting regresses to
    bare keys (the exact round-3 defect), the round-trip check must catch
    it rather than silently writing wrong TOML."""
    mod = load_module()
    filtered = {"tui": {"model_availability_nux": {"gpt-5.1": 1}}}

    good_text = mod.render(filtered)
    good_roundtrip = tomllib.loads(good_text)
    assert good_roundtrip == filtered, (
        "the real (quoting) renderer must round-trip"
    )

    # Now simulate the round-3 bug: quote_key always returns the bare key,
    # unquoted, exactly as migrate-user-config.py:46,50 did before the fix.
    original_quote_key = mod.quote_key
    mod.quote_key = lambda k: k
    try:
        bad_text = mod.render(filtered)
    finally:
        mod.quote_key = original_quote_key

    assert "gpt-5.1" in bad_text.replace('"', ""), (
        "sanity: key is present unquoted"
    )

    try:
        bad_roundtrip = tomllib.loads(bad_text)
    except tomllib.TOMLDecodeError:
        # Also acceptable: unquoted "gpt-5.1" is parsed as a dotted table
        # path (gpt-5 . 1), which can produce a parse error depending on
        # context. Either outcome proves the guard would have caught it.
        print(
            "test_unquoted_keys_are_rejected_by_the_round_trip_guard: "
            "PASS (unquoted key made the TOML unparseable)"
        )
        return

    assert bad_roundtrip != filtered, (
        "an unquoted dotted key must NOT silently round-trip to the same "
        f"structure — got {bad_roundtrip!r} for input {filtered!r}, meaning "
        "the round-trip guard would have missed the round-3 defect"
    )
    print(
        "test_unquoted_keys_are_rejected_by_the_round_trip_guard: "
        "PASS (round-trip mismatch, as the guard requires)"
    )


def main():
    test_end_to_end_via_subprocess()
    test_unquoted_keys_are_rejected_by_the_round_trip_guard()
    print("ALL TESTS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
