"""Contract tests for scrub.py — Layer 0 of the secret-hygiene system (explore-r2iq).

Every subprocess test steers scrub.py at a tmp fixture tree (never a real memory
file). A few pure-function guards import scrub.py directly for the sharp cases the
CLI can't isolate (allowlist recognition, safe_rewrite's JSON-validity contract,
the splitlines-vs-split regression, the entropy filter).

scrub.py CLI: scrub.py {scan,redact} <paths...> [--apply] [--exclude P]
                                     [--entropy] [--gitleaks] [--quiet]
Exit codes: 1 if any secret matched, 0 if clean.
"""

from __future__ import annotations

import json

import pytest
import scrub
from _scrub_helpers import (
    ENV_REF,
    GATEWAY_KEY_PLACEHOLDER,
    GDOC_ID,
    GIT_SHA,
    HIGH_ENTROPY_SECRET,
    PATH_POINTER,
    SECRETS,
    UUID,
    write_jsonl,
    write_text,
)

MARKER = scrub.MARKER


# --------------------------------------------------------------------------- #
# scan: reports + exit codes
# --------------------------------------------------------------------------- #
def test_scan_reports_and_exits_1_when_found(scrub_cli, tree):
    f = write_text(
        tree / "note.md", f"my key {SECRETS['anthropic-key']} oops\n"
    )
    r = scrub_cli("scan", tree)
    assert r.returncode == 1, r.combined
    assert "note.md" in r.stdout
    assert "anthropic-key" in r.stdout
    assert str(f) in r.stdout


def test_scan_exits_0_when_clean(scrub_cli, tree):
    write_text(
        tree / "note.md", "nothing secret here, just prose about widgets\n"
    )
    r = scrub_cli("scan", tree)
    assert r.returncode == 0, r.combined


def test_gateway_sk_key_caught_but_placeholder_and_words_ignored(
    scrub_cli, tree
):
    """Regression (explore-fk14): custom sk-<name>-<hex> gateway keys were a
    blind spot. Catch the real shape; do NOT flag the .example REPLACE_ME
    placeholder, nor words ending in 'sk' (risk-/task-/disk-)."""
    # true positive: a real-shaped gateway key in vault content is flagged
    # (.md — the dir-walk covers .md/.jsonl/.txt; explicit non-vault paths like a
    # .yaml config are also scanned when named directly, verified separately).
    write_text(tree / "note.md", f"gateway key {SECRETS['gateway-sk-key']}\n")
    hit = scrub_cli("scan", tree)
    assert hit.returncode == 1, hit.combined
    assert "gateway-sk-key" in hit.stdout

    # true negatives: the placeholder + hyphenated words that contain "sk-"
    write_text(
        tree / "note.md",
        f"placeholder {GATEWAY_KEY_PLACEHOLDER}\n"
        "risk-manage-abcdef12 task-run-deadbeef1 disk-cache-00112233\n",
    )
    clean = scrub_cli("scan", tree)
    assert clean.returncode == 0, clean.combined


def test_scan_never_echoes_the_secret_value(scrub_cli, tree):
    """The report prints counts + pattern names, NEVER the raw secret."""
    secret = SECRETS["github-token"]
    write_text(tree / "note.md", f"tok {secret}\n")
    r = scrub_cli("scan", tree)
    assert r.returncode == 1
    assert secret not in r.combined


# --------------------------------------------------------------------------- #
# redact: dry-run vs --apply
# --------------------------------------------------------------------------- #
def test_redact_dry_run_writes_nothing(scrub_cli, tree):
    secret = SECRETS["aws-akia"]
    f = write_text(tree / "note.md", f"key {secret}\n")
    before = f.read_bytes()
    r = scrub_cli("redact", tree)  # no --apply
    assert r.returncode == 1, r.combined
    assert f.read_bytes() == before, "dry-run must not touch the file"
    assert secret in f.read_text(encoding="utf-8")


def test_redact_apply_replaces_each_secret_with_marker(scrub_cli, tree):
    secret = SECRETS["aws-akia"]
    f = write_text(tree / "note.md", f"key {secret} end\n")
    r = scrub_cli("redact", tree, "--apply")
    assert r.returncode == 1, r.combined
    out = f.read_text(encoding="utf-8")
    assert secret not in out
    assert MARKER in out


@pytest.mark.parametrize("name", sorted(SECRETS))
def test_each_provider_pattern_is_redacted(scrub_cli, tree, name):
    secret = SECRETS[name]
    f = write_text(tree / "note.md", f"prefix {secret} suffix\n")
    r = scrub_cli("redact", tree, "--apply")
    assert r.returncode == 1, r.combined
    out = f.read_text(encoding="utf-8")
    assert secret not in out, f"{name} not redacted: {out!r}"
    assert MARKER in out
    if name == "bearer-token":
        # bearer keeps its "Bearer " prefix, redacts only the token.
        assert "Bearer " + MARKER in out


# --------------------------------------------------------------------------- #
# JSON-safe atomic rewrite (the safety guarantee)
# --------------------------------------------------------------------------- #
def test_redact_jsonl_stays_valid_and_linecount_unchanged(scrub_cli, tree):
    recs = [
        {"role": "user", "text": "hi"},
        {"role": "assistant", "text": f"secret {SECRETS['openai-key']} here"},
        {"role": "user", "text": f"and {SECRETS['google-api-key']} too"},
    ]
    f = write_jsonl(tree / "session.jsonl", recs)
    before_nl = f.read_text(encoding="utf-8").count("\n")
    r = scrub_cli("redact", tree, "--apply")
    assert r.returncode == 1, r.combined
    text = f.read_text(encoding="utf-8")
    assert text.count("\n") == before_nl, "line count must be preserved"
    for line in text.split("\n"):
        if line.strip():
            json.loads(line)  # must still parse — raises on failure
    assert SECRETS["openai-key"] not in text
    assert SECRETS["google-api-key"] not in text
    assert MARKER in text


def test_splitlines_regression_embedded_separators_not_false_skipped(
    scrub_cli, tree
):
    """A JSONL line whose STRING VALUE contains U+2028 / U+2029 / U+0085 is valid
    whole-line JSON, but str.splitlines() over-splits on those chars. The redact
    validity check must split on '\\n' only — else it false-flags the line
    unparseable and SKIPS a safe redact. Guard: the secret is actually removed."""
    sep = chr(0x2028) + "mid" + chr(0x2029) + "more" + chr(0x0085)
    recs = [
        {"role": "user", "text": "plain"},
        {
            "role": "assistant",
            "text": f"pre{sep}post {SECRETS['anthropic-key']}",
        },
    ]
    f = write_jsonl(tree / "session.jsonl", recs)
    before_nl = f.read_text(encoding="utf-8").count("\n")
    r = scrub_cli("redact", tree, "--apply")
    assert r.returncode == 1, r.combined
    assert "SKIP(unsafe)" not in r.combined, r.combined
    text = f.read_text(encoding="utf-8")
    assert SECRETS["anthropic-key"] not in text, (
        "regression: safe redact was skipped"
    )
    assert text.count("\n") == before_nl
    # separators survive + every line still parses
    assert chr(0x2028) in text and chr(0x0085) in text
    for line in text.split("\n"):
        if line.strip():
            json.loads(line)


def test_crlf_terminated_jsonl_redacts(scrub_cli, tree):
    """CRLF line endings (\\r\\n): split('\\n') leaves a trailing \\r that .strip()
    cleans before json.loads — the redact must still apply."""
    l1 = json.dumps({"role": "user", "text": "plain"}, ensure_ascii=False)
    l2 = json.dumps(
        {"role": "assistant", "text": f"x {SECRETS['github-token']} y"},
        ensure_ascii=False,
    )
    f = write_text(tree / "session.jsonl", l1 + "\r\n" + l2 + "\r\n")
    r = scrub_cli("redact", tree, "--apply")
    assert r.returncode == 1, r.combined
    assert "SKIP(unsafe)" not in r.combined, r.combined
    assert SECRETS["github-token"] not in f.read_text(encoding="utf-8")


# --------------------------------------------------------------------------- #
# --exclude
# --------------------------------------------------------------------------- #
def test_exclude_skips_a_file(scrub_cli, tree):
    keep = write_text(tree / "keep.md", f"a {SECRETS['aws-akia']}\n")
    skip = write_text(tree / "skip.md", f"b {SECRETS['aws-akia']}\n")
    r = scrub_cli("scan", tree, "--exclude", str(skip))
    assert r.returncode == 1, r.combined
    assert str(keep) in r.stdout
    assert str(skip) not in r.stdout


def test_exclude_protects_active_session_from_redact(scrub_cli, tree):
    active = write_text(tree / "active.jsonl", "")
    write_jsonl(
        active, [{"role": "user", "text": f"live {SECRETS['aws-akia']}"}]
    )
    before = active.read_bytes()
    r = scrub_cli("redact", tree, "--apply", "--exclude", str(active))
    assert active.read_bytes() == before, "excluded file must be untouched"
    assert r.returncode == 0, r.combined  # nothing else had a secret


# --------------------------------------------------------------------------- #
# Benign shapes are NOT matched by the high-confidence patterns
# --------------------------------------------------------------------------- #
def test_benign_shapes_not_matched_by_high_confidence_scan(scrub_cli, tree):
    write_text(
        tree / "mem.md",
        f"doc {GDOC_ID}\nenv {ENV_REF}\npath {PATH_POINTER}\n"
        f"sha {GIT_SHA}\nuuid {UUID}\n",
    )
    r = scrub_cli("scan", tree)
    assert r.returncode == 0, r.combined


# --------------------------------------------------------------------------- #
# Allowlist (pure-function guards + --entropy wiring)
# --------------------------------------------------------------------------- #
def test_is_allowlisted_recognizes_every_benign_shape():
    assert scrub.is_allowlisted(GDOC_ID)
    assert scrub.is_allowlisted("$OPENAI_API_KEY")
    assert scrub.is_allowlisted("${OPENAI_API_KEY}")
    assert scrub.is_allowlisted("~/.secrets/key")
    assert scrub.is_allowlisted(GIT_SHA)
    assert scrub.is_allowlisted(UUID)
    # a real secret is NOT allowlisted
    assert not scrub.is_allowlisted(HIGH_ENTROPY_SECRET)
    assert not scrub.is_allowlisted(SECRETS["anthropic-key"])


def test_entropy_hits_filters_allowlisted_tokens():
    # the gdoc id is high-entropy (would be flagged) but allowlisted -> suppressed
    assert scrub._shannon(GDOC_ID) >= scrub.ENTROPY_THRESHOLD
    assert scrub.entropy_hits(GDOC_ID) == []
    # a random secret is surfaced
    assert scrub.entropy_hits(HIGH_ENTROPY_SECRET) == [HIGH_ENTROPY_SECRET]
    # mixed: only the real secret survives the allowlist filter
    mixed = f"{GDOC_ID} and {GIT_SHA} and {HIGH_ENTROPY_SECRET}"
    assert scrub.entropy_hits(mixed) == [HIGH_ENTROPY_SECRET]


def test_entropy_scan_reports_random_secret(scrub_cli, tree):
    write_text(tree / "blob.txt", f"token {HIGH_ENTROPY_SECRET}\n")
    r = scrub_cli("scan", tree, "--entropy")
    assert r.returncode == 1, r.combined
    assert "high-entropy" in r.stdout


def test_entropy_scan_suppresses_allowlisted_gdoc_id(scrub_cli, tree):
    write_text(tree / "doc.txt", f"see doc {GDOC_ID} for details\n")
    r = scrub_cli("scan", tree, "--entropy")
    assert r.returncode == 0, (
        r.combined
    )  # allowlist suppressed the only high-entropy token


# --------------------------------------------------------------------------- #
# safe_rewrite pure-function contract (import-level, sharp cases)
# --------------------------------------------------------------------------- #
def test_safe_rewrite_no_splitlines_oversplit(tmp_path):
    """The exact regression: a valid JSON line carrying U+2028/U+2029/U+0085 must
    return 'ok'. Under str.splitlines() it would over-split into unparseable
    fragments and return 'jsonl-line-1-unparseable'."""
    val = (
        "before" + chr(0x2028) + "mid" + chr(0x2029) + "x" + chr(0x0085) + "end"
    )
    line = json.dumps({"t": val}, ensure_ascii=False)
    p = tmp_path / "x.jsonl"
    p.write_text(line + "\n", encoding="utf-8")
    assert scrub.safe_rewrite(str(p), line + "\n") == "ok"


def test_safe_rewrite_rejects_line_count_change(tmp_path):
    p = tmp_path / "x.jsonl"
    orig = json.dumps({"t": "a"}) + "\n"
    p.write_text(orig, encoding="utf-8")
    bad = orig + json.dumps({"t": "b"}) + "\n"  # extra line
    assert scrub.safe_rewrite(str(p), bad) == "line-count-changed"
    assert p.read_text(encoding="utf-8") == orig, "original untouched on reject"


def test_safe_rewrite_rejects_unparseable_jsonl(tmp_path):
    p = tmp_path / "x.jsonl"
    orig = json.dumps({"t": "a"}) + "\n"
    p.write_text(orig, encoding="utf-8")
    broken = '{"t": "a" BROKEN}\n'  # same line count, invalid JSON
    res = scrub.safe_rewrite(str(p), broken)
    assert res.startswith("jsonl-line-1-unparseable"), res
    assert p.read_text(encoding="utf-8") == orig, "original untouched on reject"


# --------------------------------------------------------------------------- #
# gitleaks backend (detect-only; tolerant of absence)
# --------------------------------------------------------------------------- #
GITLEAKS = scrub.gitleaks_bin()


@pytest.mark.skipif(GITLEAKS is None, reason="gitleaks not installed")
def test_gitleaks_folds_findings_deduped(scrub_cli, tree):
    """With gitleaks present, --gitleaks runs it, folds findings, and the
    custom-caught token on the same file:line is deduped (0 additional)."""
    write_text(tree / "leak.txt", f"gh {SECRETS['github-token']} here\n")
    r = scrub_cli("scan", tree, "--gitleaks")
    assert r.returncode == 1, r.combined
    assert "gitleaks:" in r.stderr  # summary line always prints
    # same secret, same line -> deduped, no double count
    assert "0 additional finding(s)" in r.stderr, r.stderr


def test_gitleaks_absent_falls_back_to_custom_scan(scrub_cli, tree):
    """Forcing gitleaks off the PATH + HOME must NOT hard-fail: the custom scan is
    the fallback (warns 'not-found', still exits on the custom result)."""
    write_text(tree / "leak.txt", f"gh {SECRETS['github-token']} here\n")
    env = {"PATH": "/nonexistent", "HOME": str(tree)}
    r = scrub_cli("scan", tree, "--gitleaks", env=env)
    assert r.returncode == 1, r.combined  # custom scan still found it
    assert "not-found" in r.stderr, r.stderr
