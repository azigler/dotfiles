"""Live-value denylist tests (explore-wmlc).

The bug this guards: the admission gate used only the high-confidence PREFIX
patterns, which structurally cannot see a credential whose issuer stamped no
recognisable prefix on it. Measured against the real ~/.secrets on 2026-07-28: 22
exported variables, 3 detected. Because the gate and the redactor share the
detector, redacting the 3 visible ones would have turned a correctly-BLOCKED
transcript into a PASSING one still carrying the rest.

EVERY fixture here is SYNTHETIC. The suite never reads the real ~/.secrets: each
test points --secrets-file at a tmp file it wrote itself, which is also what proves
the rule GENERALISES rather than special-casing one machine's file.
"""

from __future__ import annotations

import json

import pytest
from _scrub_helpers import write_jsonl, write_text

import scrub

# The variable NAMES the prefix patterns miss on the real box (names are not
# secrets). Values below are invented for this test and are not credentials.
UNDETECTED_NAMES = [
    "FLEET_API_TOKEN",
    "AIRTABLE_PAT",
    "GAMMA_API_KEY",
    "FIGMA_PAT",
    "HEVY_API_KEY",
    "HF_TOKEN",
    "HEVYD_WEBHOOK_TOKEN",
    "R2_ACCESS_KEY_ID",
    "R2_SECRET_ACCESS_KEY",
    "GOJAMMING_TOKEN",
    "AO3_SESSION_COOKIE",
    "AO3_REMEMBER_TOKEN",
    "HEVY_SESSION_TOKEN",
    "HEVY_REFRESH_TOKEN",
    "ROBLOX_API_KEY",
]

# Deterministic synthetic values, all >= DENY_MIN_LEN, none matching any PATTERN.
SYNTHETIC = {
    name: f"synthetic-{name.lower().replace('_', '-')}-0123456789abcdef"
    for name in UNDETECTED_NAMES
}

# Shapes the filter must REJECT, mirroring the real non-credentials in ~/.secrets.
NON_SECRETS = {
    "R2_BUCKET": "bucketx",  # too-short
    "GAMMA_DEFAULT_THEME_ID": "themeid12345",  # too-short
    "HEVY_TOKEN_EXPIRES_AT": "17845000001234567890",  # integer (>= min len)
    "CDN_BASE_URL": "https://cdn.example.invalid/assets",  # url
    "SOME_PHRASE": "the quick brown fox jumps",  # whitespace
    "SOME_POINTER": "$OTHER_TOKEN_VARIABLE_NAME",  # pointer
    "SOME_PATH": "~/.secrets/openai-key-file-path",  # pointer
}


def _secrets_file(tmp_path, mapping):
    body = "".join(f'export {k}="{v}"\n' for k, v in mapping.items())
    return write_text(tmp_path / "fake-secrets", "# synthetic\n" + body)


# ---------------------------------------------------------------------------- #
# The shape rule
# ---------------------------------------------------------------------------- #
@pytest.mark.parametrize(
    "value,expected",
    [
        ("", "empty"),
        ("short", "too-short"),
        ("a" * (scrub.DENY_MIN_LEN - 1), "too-short"),
        ("1" * 30, "integer"),
        ("https://cdn.example.invalid/x", "url"),
        ("s3://bucket/some/long/key/path", "url"),
        ("a token with spaces in it here", "whitespace"),
        ("$SOME_OTHER_ENV_VARIABLE_NAME", "pointer"),
        ("${SOME_OTHER_ENV_VARIABLE_NAME}", "pointer"),
        ("~/.secrets/some/long/path/here", "pointer"),
        ("/etc/some/long/absolute/path/x", "pointer"),
        ("a" * scrub.DENY_MIN_LEN, "ok"),
        ("0123456789abcdef" * 4, "ok"),  # 64-hex: a REAL credential shape
    ],
)
def test_denylist_verdict(value, expected):
    assert scrub.denylist_verdict(value) == expected


def test_allowlist_does_not_eat_hex_credentials(tmp_path):
    """The trap: ALLOWLIST['git-sha'] matches ANY 40/64-hex run, and three real
    credentials in ~/.secrets are exactly 64 hex. The denylist must NOT be filtered
    through is_allowlisted — verbatim equality with a known credential needs no
    heuristic taming."""
    hex64 = "0123456789abcdef" * 4
    assert scrub.is_allowlisted(hex64)  # the allowlist WOULD have dropped it
    sf = _secrets_file(tmp_path, {"R2_SECRET_ACCESS_KEY": hex64})
    deny = scrub.build_denylist(str(sf))
    assert [n for n, _ in deny] == ["R2_SECRET_ACCESS_KEY"]
    assert scrub.scan_denylist(f"key={hex64}", deny) == {
        "secrets-file:R2_SECRET_ACCESS_KEY": 1
    }


def test_build_denylist_admits_only_credential_shapes(tmp_path):
    sf = _secrets_file(tmp_path, {**SYNTHETIC, **NON_SECRETS})
    admitted = {n for n, _ in scrub.build_denylist(str(sf))}
    assert admitted == set(SYNTHETIC)
    assert admitted.isdisjoint(NON_SECRETS)


def test_denylist_mode_prints_names_and_verdicts_never_values(
    tmp_path, scrub_cli
):
    sf = _secrets_file(tmp_path, {**SYNTHETIC, **NON_SECRETS})
    r = scrub_cli("denylist", [], "--secrets-file", str(sf))
    assert r.returncode == 0
    for name in SYNTHETIC:
        assert name in r.stdout
    assert (
        "too-short" in r.stdout and "url" in r.stdout and "pointer" in r.stdout
    )
    for value in {**SYNTHETIC, **NON_SECRETS}.values():
        assert value not in r.combined


# ---------------------------------------------------------------------------- #
# The gate: the undetected names must now BLOCK
# ---------------------------------------------------------------------------- #
def _transcript(tree, mapping):
    return write_jsonl(
        tree / "session.jsonl",
        [{"type": "user", "text": "hello"}]
        + [
            {"type": "tool_result", "content": f"export {k}={v}"}
            for k, v in mapping.items()
        ]
        + [{"type": "assistant", "text": "bye"}],
    )


def test_scan_blocks_transcript_carrying_undetected_credentials(
    tree, tmp_path, scrub_cli
):
    sf = _secrets_file(tmp_path, SYNTHETIC)
    t = _transcript(tree, SYNTHETIC)
    r = scrub_cli("scan", [t], "--secrets-file", str(sf))
    assert r.returncode == 1, r.combined
    for name in SYNTHETIC:
        assert f"secrets-file:{name}" in r.stdout
    for value in SYNTHETIC.values():
        assert value not in r.combined  # names + counts only, never a value


def test_patterns_alone_would_have_passed_the_same_file(
    tree, tmp_path, scrub_cli
):
    """The regression itself: without the denylist this file scans CLEAN."""
    sf = _secrets_file(tmp_path, SYNTHETIC)
    t = _transcript(tree, SYNTHETIC)
    r = scrub_cli("scan", [t], "--secrets-file", str(sf), "--no-denylist")
    assert r.returncode == 0, r.combined


def test_clean_file_still_passes(tree, tmp_path, scrub_cli):
    """Positive control — a gate that blocks everything is not a gate."""
    sf = _secrets_file(tmp_path, SYNTHETIC)
    clean = write_jsonl(
        tree / "clean.jsonl",
        [
            {
                "type": "user",
                "text": "refs $HEVY_API_KEY and ~/.secrets by pointer",
            }
        ],
    )
    r = scrub_cli("scan", [clean], "--secrets-file", str(sf))
    assert r.returncode == 0, r.combined


def test_non_secret_values_do_not_trip_the_gate(tree, tmp_path, scrub_cli):
    """A file quoting the URL / bucket / timestamp must NOT block."""
    sf = _secrets_file(tmp_path, {**SYNTHETIC, **NON_SECRETS})
    body = write_jsonl(
        tree / "benign.jsonl",
        [{"type": "assistant", "text": " ".join(NON_SECRETS.values())}],
    )
    r = scrub_cli("scan", [body], "--secrets-file", str(sf))
    assert r.returncode == 0, r.combined


def test_json_escaped_value_is_caught_inside_a_jsonl_string(
    tree, tmp_path, scrub_cli
):
    """A credential containing a quote/backslash appears in a transcript ONLY in
    its JSON-escaped form; a raw-only search would miss it."""
    value = 'ab"cd\\ef' + "0123456789abcdefghij"
    sf = _secrets_file(tmp_path, {"WEIRD_TOKEN": value})
    t = write_jsonl(
        tree / "s.jsonl", [{"type": "tool_result", "content": value}]
    )
    assert json.dumps(value)[1:-1] in t.read_text(encoding="utf-8")
    r = scrub_cli("scan", [t], "--secrets-file", str(sf))
    assert r.returncode == 1, r.combined
    assert "secrets-file:WEIRD_TOKEN" in r.stdout


# ---------------------------------------------------------------------------- #
# Redaction: the denylist is safe in redact mode, which is what closes the loop
# ---------------------------------------------------------------------------- #
def test_redact_apply_removes_live_values_and_rescan_is_clean(
    tree, tmp_path, scrub_cli
):
    sf = _secrets_file(tmp_path, SYNTHETIC)
    t = _transcript(tree, SYNTHETIC)
    before = t.read_text(encoding="utf-8")

    r = scrub_cli("redact", [t], "--apply", "--secrets-file", str(sf))
    assert r.returncode == 1, r.combined
    after = t.read_text(encoding="utf-8")

    for value in SYNTHETIC.values():
        assert value not in after
    assert scrub.MARKER in after
    assert before.count("\n") == after.count("\n")  # line count preserved
    for line in after.split("\n"):
        if line.strip():
            json.loads(line)  # still valid JSONL

    again = scrub_cli("scan", [t], "--secrets-file", str(sf))
    assert again.returncode == 0, again.combined


def test_redact_still_refuses_entropy(tree, tmp_path, scrub_cli):
    """--entropy is scan-only. A high-entropy token that is NOT a known live value
    must survive redaction untouched — a false positive there corrupts content."""
    from _scrub_helpers import HIGH_ENTROPY_SECRET

    sf = _secrets_file(tmp_path, SYNTHETIC)
    f = write_text(tree / "e.md", f"token: {HIGH_ENTROPY_SECRET}\n")

    seen = scrub_cli("scan", [f], "--entropy", "--secrets-file", str(sf))
    assert seen.returncode == 1 and "high-entropy" in seen.stdout

    r = scrub_cli(
        "redact", [f], "--apply", "--entropy", "--secrets-file", str(sf)
    )
    assert HIGH_ENTROPY_SECRET in f.read_text(encoding="utf-8"), r.combined


# ---------------------------------------------------------------------------- #
# The third state: UNAVAILABLE is reported, never silently treated as clean
# ---------------------------------------------------------------------------- #
def test_missing_secrets_file_degrades_loudly_but_never_hard_fails(
    tree, tmp_path, scrub_cli
):
    t = _transcript(tree, SYNTHETIC)
    r = scrub_cli("scan", [t], "--secrets-file", str(tmp_path / "nope"))
    assert r.returncode == 0  # patterns alone see nothing here
    assert "live-value denylist UNAVAILABLE" in r.stderr


def test_summary_names_the_detectors_in_use(tree, tmp_path, scrub_cli):
    sf = _secrets_file(tmp_path, SYNTHETIC)
    clean = write_text(tree / "c.md", "nothing here\n")
    r = scrub_cli("scan", [clean], "--secrets-file", str(sf))
    assert r.returncode == 0
    assert f"{len(SYNTHETIC)} live-values" in r.stderr
    assert "patterns" in r.stderr


def test_summary_line_has_no_braces(tree, tmp_path, scrub_cli):
    """scrub-continue.sh's per-file parser keys on a trailing `{...}` counts dict;
    a brace in the summary line would be mis-parsed as a hit file."""
    sf = _secrets_file(tmp_path, SYNTHETIC)
    t = _transcript(tree, SYNTHETIC)
    r = scrub_cli("scan", [t], "--secrets-file", str(sf))
    summary = [ln for ln in r.stderr.split("\n") if ln.startswith("== scan:")]
    assert summary and "{" not in summary[0] and "}" not in summary[0]


def test_scan_requires_a_path(scrub_cli):
    r = scrub_cli("scan", [])
    assert r.returncode == 2
    assert "at least one path" in r.combined
