"""Contract tests for the `/recall` CLI (spec explore-76oc §4.2 / §5).

RED PHASE: recall.py does not exist yet. These tests DEFINE the contract the
impl wave must satisfy. Every test steers recall.py at a fixture projects tree
(never the real ~/.claude/projects) and asserts on stdout / --json / exit code /
stderr.

CLI under test:
    recall.py "<query>" [--expand N] [--regex] [--all] [--slug S] [--json] [--root PATH]

Exit codes: 0 = >=1 hit, 1 = no hits, 2 = error.
--json  -> a JSON array of {slug, session, ts, role, line, text} objects.

Testability contract the impl MUST honor (mirrors the spec's REQUIRED --root
override): the projects root is overridable via --root and/or CLAUDE_PROJECTS_ROOT,
and the huge-line cap is overridable via the RECALL_MAX_LINE_BYTES env var so the
cap can be exercised without a literal 64 MB fixture.
"""

from __future__ import annotations

import json
import subprocess

import pytest
from _recall_helpers import (
    assistant_turn,
    custom_title_line,
    file_history_snapshot_line,
    jline,
    main_path,
    progress_line,
    slug_flag,
    subagent_path,
    tool_result_path,
    unknown_schema_line,
    user_turn,
    user_turn_str,
    write_bytes,
    write_turns,
)

SLUG = "-home-ubuntu-explore"
SLUG_A = "-home-ubuntu-testalpha"
SLUG_B = "-home-ubuntu-testbeta"

# The set the --json contract pins EXACTLY (§4.2).
JSON_KEYS = {"slug", "session", "ts", "role", "line", "text"}

# Broad, case-insensitive token set for "a visible truncation/loud marker".
# Deliberately generous so the impl keeps wording freedom while a marker is
# still REQUIRED to exist.
MARKER_TOKENS = (
    "…",
    "...",
    "trunc",
    "cap",
    "max",
    "elided",
    "clip",
    "omitted",
    "snip",
    "unrender",
    "raw",
)


def _json(result):
    """Parse the --json array. Callers assert returncode == 0 FIRST so this is
    never reached in the red phase (keeps failures clean, not collection errors)."""
    return json.loads(result.stdout or "[]")


# --------------------------------------------------------------------------- #
# §5 core cases
# --------------------------------------------------------------------------- #
def test_recall_finds_known_past_decision(recall, root):
    """§5 recall-finds-known-past-decision: a unique phrase in a main jsonl is
    found, with ts + text present."""
    write_turns(
        main_path(root, SLUG),
        [
            user_turn("what storage mechanism did we pick?", 0),
            assistant_turn("we chose the detached-git-dir vault mechanism", 1),
            assistant_turn("unrelated later chatter", 2),
        ],
    )
    r = recall("detached-git-dir", slug_flag(SLUG), "--json", root=root)
    assert r.returncode == 0, r.stderr
    data = _json(r)
    assert len(data) >= 1
    hit = next(o for o in data if "detached-git-dir" in o["text"])
    assert hit["role"] == "assistant"
    assert hit["ts"], "timestamp must be surfaced"
    assert hit["slug"] == SLUG


def test_recall_expand_surrounds(recall, root):
    """§5 recall-expand-surrounds: --expand 2 returns match +/-2 turns from the
    same file, in order."""
    write_turns(
        main_path(root, SLUG),
        [
            assistant_turn("CTX1_before_two", 0),
            assistant_turn("CTX2_before_one", 1),
            assistant_turn("CTX3_the UNIQUEMATCH here", 2),
            assistant_turn("CTX4_after_one", 3),
            assistant_turn("CTX5_after_two", 4),
        ],
    )
    r = recall("UNIQUEMATCH", slug_flag(SLUG), "--expand=2", root=root)
    assert r.returncode == 0, r.stderr
    sentinels = [
        "CTX1_before_two",
        "CTX2_before_one",
        "CTX3_the",
        "CTX4_after_one",
        "CTX5_after_two",
    ]
    for s in sentinels:
        assert s in r.stdout, f"{s} missing from expanded output"
    positions = [r.stdout.index(s) for s in sentinels]
    assert positions == sorted(positions), (
        "expanded turns must appear in file order"
    )


def test_recall_parsed_but_unrenderable_is_loud(recall, root):
    """§5 recall-parsed-but-unrenderable-is-loud (OQ-D1/D7): a VALID-JSON line
    with an unrecognized schema that matches the query is surfaced LOUDLY on
    stderr with its raw line — never silently dropped — and still counts as a
    hit."""
    write_bytes(
        main_path(root, SLUG),
        jline(
            unknown_schema_line(
                "QUERYUNIQUE lives in an unrenderable record", 0
            )
        ),
    )
    r = recall("QUERYUNIQUE", slug_flag(SLUG), root=root)
    assert r.returncode == 0, (
        "a raw match (even if unrenderable) is a hit -> exit 0"
    )
    assert r.stderr.strip(), "the loud channel (stderr) must fire"
    assert "QUERYUNIQUE" in r.stderr, (
        "the raw unrenderable line must be surfaced on stderr, not dropped"
    )


def test_recall_live_tail_partial_ok(recall, root):
    """§5 recall-live-tail-partial-ok (OQ-D4): recalling the ACTIVE session
    tolerates a trailing partial (mid-write) last line — no false loud alarm —
    while still returning the prior complete lines.

    Determinism note for the impl: with no live session id available under a
    fixture --root, the active session is the newest-mtime *.jsonl in scope.
    Here it is the SOLE file in its slug, so it is unambiguously active."""
    path = main_path(root, SLUG)
    write_bytes(
        path,
        jline(assistant_turn("PRIORHIT complete_alpha", 0)),
        jline(user_turn("PRIORHIT complete_beta", 1)),
        # trailing PARTIAL last line: matches the query but is truncated (no
        # closing braces, no newline) as if a write is in flight.
        b'{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"PRIORHIT PARTIALTAILMARKER',
    )
    r = recall("PRIORHIT", slug_flag(SLUG), root=root)
    assert r.returncode == 0, r.stderr
    assert "complete_alpha" in r.stdout or "complete_beta" in r.stdout, (
        "prior complete lines must return"
    )
    assert "PARTIALTAILMARKER" not in r.combined, (
        "the tolerated live-tail partial must NOT raise a loud alarm"
    )


def test_recall_huge_line_capped(recall, root):
    """§5 recall-huge-line-capped (OQ-D2): a single line far larger than the cap
    is truncated with a visible marker; the process does not OOM or hang.

    The cap is exercised via RECALL_MAX_LINE_BYTES (the testability override) so
    no literal 64 MB fixture is needed."""
    payload = "HUGEQ_start " + ("A" * (1 << 20)) + " HUGETAILSENTINEL"  # ~1 MiB
    write_bytes(main_path(root, SLUG), jline(assistant_turn(payload, 0)))
    try:
        r = recall(
            "HUGEQ_start",
            slug_flag(SLUG),
            root=root,
            extra_env={"RECALL_MAX_LINE_BYTES": "65536"},
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        pytest.fail("huge line hung the process (no streaming/cap)")
    assert r.returncode == 0, r.stderr
    assert "HUGEQ_start" in r.combined, (
        "the match near the line start must still be found"
    )
    assert "HUGETAILSENTINEL" not in r.stdout, (
        "content past the cap must be truncated away"
    )
    assert len(r.stdout_bytes) < (len(payload) // 2), (
        "output must be bounded well below the payload (no full echo)"
    )
    assert any(m in r.combined.lower() for m in MARKER_TOKENS), (
        "a visible truncation marker is required"
    )


def test_recall_no_hits_exit_1(recall, root):
    """§5 recall-no-hits: a nonexistent string -> exit 1, empty result."""
    write_turns(
        main_path(root, SLUG), [assistant_turn("nothing relevant here", 0)]
    )
    r = recall(
        "STRING_THAT_APPEARS_NOWHERE_ZZZ", slug_flag(SLUG), "--json", root=root
    )
    assert r.returncode == 1, r.stderr
    assert _json(r) == []


def test_recall_json_contract(recall, root):
    """§5 recall-json-contract: --json emits objects with EXACTLY
    {slug, session, ts, role, line, text}."""
    write_turns(
        main_path(root, SLUG),
        [assistant_turn("JSONCONTRACT payload text", 0)],
    )
    r = recall("JSONCONTRACT", slug_flag(SLUG), "--json", root=root)
    assert r.returncode == 0, r.stderr
    data = _json(r)
    assert isinstance(data, list) and data, "must be a non-empty JSON array"
    for obj in data:
        assert isinstance(obj, dict)
        assert set(obj.keys()) == JSON_KEYS, (
            f"unexpected key set: {sorted(obj.keys())}"
        )
    hit = next(o for o in data if "JSONCONTRACT" in o["text"])
    assert hit["slug"] == SLUG
    assert hit["role"] == "assistant"
    assert isinstance(hit["line"], int), (
        "'line' is the line number within the file"
    )


def test_recall_all_scope_isolation(recall, root):
    """§5 recall-all-scope: a hit that exists ONLY in slug B is NOT returned by a
    scoped (current-slug) run, but IS returned with --all."""
    write_turns(
        main_path(root, SLUG_A),
        [assistant_turn("alpha-only unrelated content", 0)],
    )
    write_turns(
        main_path(root, SLUG_B),
        [assistant_turn("BETAEXCLUSIVE decision text", 0)],
    )

    scoped = recall("BETAEXCLUSIVE", slug_flag(SLUG_A), "--json", root=root)
    assert scoped.returncode == 1, (
        "scoped to slug A, the B-only phrase must not appear"
    )
    assert _json(scoped) == []

    everywhere = recall("BETAEXCLUSIVE", "--all", "--json", root=root)
    assert everywhere.returncode == 0, everywhere.stderr
    data = _json(everywhere)
    assert any(
        o["slug"] == SLUG_B and "BETAEXCLUSIVE" in o["text"] for o in data
    )


def test_recall_covers_subagent_transcripts(recall, root):
    """§5 recall-covers-subagent-transcripts (OQ-D3): a phrase present ONLY in a
    <uuid>/subagents/*.jsonl is found (proves recursive coverage)."""
    write_turns(
        main_path(root, SLUG),
        [assistant_turn("top-level chatter, no target here", 0)],
    )
    write_turns(
        subagent_path(root, SLUG),
        [assistant_turn("SUBAGENTONLY delegated finding", 0)],
    )
    r = recall("SUBAGENTONLY", slug_flag(SLUG), "--json", root=root)
    assert r.returncode == 0, r.stderr
    data = _json(r)
    assert any("SUBAGENTONLY" in o["text"] for o in data), (
        "subagent transcript must be covered"
    )


def test_recall_covers_tool_results_txt(recall, root):
    """§5 recall-covers-tool-results-txt (OQ-D3/OQ-03): a string present ONLY in
    tool-results/*.txt is found via the raw-text path, with role='tool-result'."""
    write_bytes(
        tool_result_path(root, SLUG, name="foo.txt"),
        b"line one of raw tool output\nTOOLRESULTONLY unique marker on line two\nline three\n",
    )
    r = recall("TOOLRESULTONLY", slug_flag(SLUG), "--json", root=root)
    assert r.returncode == 0, r.stderr
    data = _json(r)
    hit = next(o for o in data if "TOOLRESULTONLY" in o["text"])
    assert hit["role"] == "tool-result", (
        "tool-results/*.txt lines render with role='tool-result'"
    )


def test_recall_type_keyed_render_handles_all_types(recall, root):
    """§5 recall-type-keyed-render (OQ-D1): a file mixing assistant/user/progress/
    file-history-snapshot/custom-title lines that all match -> conversational
    turns render their text; non-conversational matched types are surfaced (raw)
    and never silently dropped or mis-rendered."""
    write_bytes(
        main_path(root, SLUG),
        jline(assistant_turn("SHAREDQ assistant A1SENT", 0)),
        jline(user_turn("SHAREDQ user U1SENT", 1)),
        jline(progress_line("SHAREDQ progress P1SENT", 2)),
        jline(file_history_snapshot_line("SHAREDQ snapshot F1SENT", 3)),
        jline(custom_title_line("SHAREDQ title C1SENT", 4)),
    )
    r = recall("SHAREDQ", slug_flag(SLUG), root=root)
    assert r.returncode == 0, r.stderr
    # conversational turns render their text (on stdout)
    assert "A1SENT" in r.stdout, "assistant turn must render"
    assert "U1SENT" in r.stdout, "user turn must render"
    # non-conversational matched types are surfaced somewhere (not dropped)
    for sentinel in ("P1SENT", "F1SENT", "C1SENT"):
        assert sentinel in r.combined, (
            f"matched non-conversational line {sentinel} was silently dropped"
        )


# --------------------------------------------------------------------------- #
# Edge / error cases (>=5 beyond the core set)
# --------------------------------------------------------------------------- #
def test_recall_decode_error_is_loud(recall, root):
    """OQ-D5: a non-UTF8 line matching the query is surfaced with a LOUD marker +
    the raw region — never a silent errors='ignore' skip."""
    write_bytes(
        main_path(root, SLUG),
        b'{"type":"user","message":{"role":"user","content":"DECODEZONE \xff\xfe\x80 rawregion"}}\n',
    )
    r = recall("DECODEZONE", slug_flag(SLUG), root=root)
    assert r.returncode != 2, (
        "a single bad-decode line is handled, not a fatal error"
    )
    assert r.stderr.strip(), "decode trouble must surface on the loud channel"
    assert "DECODEZONE" in r.stderr, (
        "the raw region of the undecodable line must be surfaced, not skipped"
    )


def test_recall_regex_opt_in_and_redos_guard(recall, root):
    """OQ-D7: substring match by default; --regex opt-in; a pathological regex
    must not hang (ReDoS guard)."""
    write_turns(
        main_path(root, SLUG),
        [
            assistant_turn("AAA literal a.c ALPHASENT", 0),
            assistant_turn("BBB regexish aXc BETASENT", 1),
            assistant_turn("CCC " + ("a" * 3000) + "b tailnomatch", 2),
        ],
    )
    # (a) default: "a.c" is a literal substring -> matches ALPHASENT, not BETASENT
    r = recall("a.c", slug_flag(SLUG), "--json", root=root)
    assert r.returncode == 0, r.stderr
    texts = " ".join(o["text"] for o in _json(r))
    assert "ALPHASENT" in texts, (
        "substring default must match the literal 'a.c'"
    )
    assert "BETASENT" not in texts, (
        "substring default must NOT treat '.' as a wildcard"
    )

    # (b) --regex opt-in: "a.c" now matches "aXc" too
    r = recall("a.c", slug_flag(SLUG), "--regex", "--json", root=root)
    assert r.returncode == 0, r.stderr
    texts = " ".join(o["text"] for o in _json(r))
    assert "BETASENT" in texts, "--regex must enable wildcard matching"

    # (c) ReDoS guard: a catastrophic pattern must terminate under the timeout
    try:
        recall(r"(a+)+$", slug_flag(SLUG), "--regex", root=root, timeout=10)
    except subprocess.TimeoutExpired:
        pytest.fail(
            "ReDoS: pathological regex did not terminate within 10s (missing guard)"
        )


def test_recall_error_exit_2_bad_root(recall, root):
    """Edge: a bad --root path is a usage error -> exit 2 with a loud message
    (not silently treated as 'no hits')."""
    bad = root / "does-not-exist-subdir-zzz"  # never created
    r = recall("anything", root=bad)
    assert r.returncode == 2, "an invalid root must be an error, not exit 1"
    assert r.stderr.strip(), "an error must be reported loudly"
    assert ("root" in r.stderr.lower()) or (str(bad) in r.stderr), (
        "the error must name the root problem"
    )


def test_recall_expand_does_not_cross_files(recall, root):
    """Edge: --expand context is bounded to the matching file — it must not bleed
    surrounding turns in from a DIFFERENT session file."""
    write_turns(
        main_path(root, SLUG, session="sessA"),
        [
            assistant_turn("A_ctx_one", 0),
            assistant_turn("A_ctx_two", 1),
            assistant_turn("A_the CROSSMATCH here", 2),
            assistant_turn("A_ctx_after", 3),
        ],
    )
    write_turns(
        main_path(root, SLUG, session="sessB"),
        [
            assistant_turn("B_FOREIGN_ONE should never appear", 0),
            assistant_turn("B_FOREIGN_TWO should never appear", 1),
        ],
    )
    r = recall("CROSSMATCH", slug_flag(SLUG), "--expand=5", root=root)
    assert r.returncode == 0, r.stderr
    assert "A_ctx_one" in r.stdout and "A_ctx_after" in r.stdout, (
        "same-file context must be included"
    )
    assert "B_FOREIGN_ONE" not in r.combined, (
        "expand must not cross into another file"
    )
    assert "B_FOREIGN_TWO" not in r.combined, (
        "expand must not cross into another file"
    )


def test_recall_empty_query_rejected(recall, root):
    """Edge: an empty query is rejected (exit 2), not silently matched against
    everything."""
    write_turns(main_path(root, SLUG), [assistant_turn("some content", 0)])
    r = recall("", slug_flag(SLUG), root=root)
    assert r.returncode == 2, "an empty query must be rejected"
    assert ("quer" in r.stderr.lower()) or ("empty" in r.stderr.lower()), (
        "the rejection must be explained"
    )


def test_recall_env_root_override(recall, root):
    """Edge: CLAUDE_PROJECTS_ROOT alone (no --root flag) steers the projects root
    (the REQUIRED env-based testability override)."""
    write_turns(
        main_path(root, SLUG), [assistant_turn("ENVROOTHIT via env var", 0)]
    )
    r = recall("ENVROOTHIT", slug_flag(SLUG), root=None, env_root=root)
    assert r.returncode == 0, r.stderr
    assert "ENVROOTHIT" in r.combined


def test_recall_root_flag_precedence_over_env(recall, root, tmp_path):
    """Edge: --root takes precedence over CLAUDE_PROJECTS_ROOT. The phrase lives
    only under the --root tree; the env decoy tree does not have it."""
    decoy = tmp_path / "decoy-projects"
    decoy.mkdir()
    write_turns(
        main_path(decoy, SLUG), [assistant_turn("decoy content only", 0)]
    )
    write_turns(
        main_path(root, SLUG),
        [assistant_turn("PRECEDENCEHIT under the real root", 0)],
    )
    r = recall("PRECEDENCEHIT", slug_flag(SLUG), root=root, env_root=decoy)
    assert r.returncode == 0, "--root must win over the env decoy"
    assert "PRECEDENCEHIT" in r.combined


def test_recall_user_string_content_renders(recall, root):
    """Edge (real-corpus robustness): a `user` turn whose message.content is a
    bare STRING (not a block list) still renders — the renderer must handle both
    content shapes that exist in the live corpus."""
    write_turns(
        main_path(root, SLUG), [user_turn_str("STRQ user string STRSENT", 0)]
    )
    r = recall("STRQ", slug_flag(SLUG), "--json", root=root)
    assert r.returncode == 0, r.stderr
    data = _json(r)
    hit = next(o for o in data if "STRSENT" in o["text"])
    assert hit["role"] == "user"
