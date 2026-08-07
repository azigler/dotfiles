"""Tests for the SEAM interface, the recurrence memory, and the confidentiality
guard (``dotfiles-jx71``).

``test_dream.py`` pins the legacy single-seam contract and must keep passing
untouched; this file covers everything added on top of it:

* each seam collects real material from a fixture source, and **degrades to
  ``searched=False`` rather than raising** when its source is absent;
* ``searched`` is reported separately from ``found`` (the positive control), and
  the exit contract 0/1/3 follows from it;
* the cross-seam merge collapses a duplicate and unions its ``seams``;
* the recurrence bar, and the ``collect`` -> ``remember`` round trip;
* the confidentiality guard — with a **path audit** that proves a
  ``linearb*``/``cfp*`` path is never traversed, and a positive control in the
  same file proving the audit itself works.
"""

from __future__ import annotations

import json
import sys
from datetime import UTC, datetime
from pathlib import Path

from _dream_helpers import (
    DREAM_PY,
    Result,
    git_commit_file,
    git_init,
    invoke,
    invoke_raw,
    main_path,
    set_mtime,
    user_turn,
    write_turns,
)

sys.path.insert(0, str(DREAM_PY.parent))
import dream

SLUG = "-home-ubuntu-explore"
CONF_SLUG = "-home-ubuntu-linearb"
SINCE_ISO = "2026-07-01T00:00:00Z"
# A day INSIDE the window. Derived, never hand-typed — an epoch literal that
# silently lands before `since` turns every seam test into a false "found nothing".
IN_WINDOW = datetime(2026, 7, 2, tzinfo=UTC).timestamp()

# A changed line long enough to clear MIN_CHANGED_LINE_CHARS and carrying a signal.
GOTCHA = "watch out: the flock silently drops the lock on fork"
PREF = "from now on always run the linter before committing anything"


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def collect(
    root: Path,
    *flags: str,
    repo: Path,
    skills_repo: Path | None = None,
    memory_git_dir: Path | None = None,
    memory: Path | None = None,
    env: dict | None = None,
) -> Result:
    """Run ``dream.py collect`` with EVERY external source pinned at a fixture.

    Nothing here may fall back to the live ``~/dotfiles`` / claude-vault / cwd
    repo — a test that silently reads the real machine is not a test.
    """
    args = [
        "collect",
        f"--slug={SLUG}",
        f"--repo={repo}",
        "--history-since=1970-01-01T00:00:00Z",
        f"--skills-repo={skills_repo or (Path(root).parent / 'no-skills-repo')}",
        f"--memory-git-dir={memory_git_dir or (Path(root).parent / 'no-memory.git')}",
        f"--memory={memory or (Path(root).parent / 'dream-memory.jsonl')}",
        *flags,
    ]
    return invoke(*args, root=root, env=env)


def seam_report(res: Result) -> dict:
    return res.json()["seams"]


def texts(res: Result) -> list[str]:
    return [c["text"] for c in res.json()["candidates"]]


def plain_repo(tmp_path: Path, name: str = "plain") -> Path:
    p = tmp_path / name
    p.mkdir(parents=True, exist_ok=True)
    return p


# --------------------------------------------------------------------------- #
# Seam registry
# --------------------------------------------------------------------------- #
def test_seams_subcommand_lists_all_five():
    r = invoke_raw("seams")
    assert r.returncode == 0, r.stderr
    assert r.json()["seams"] == [
        "session-recall",
        "offboard-history",
        "memory-history",
        "skill-history",
        "findings-corrections",
    ]


def test_unknown_seam_is_an_error(root, tmp_path):
    r = collect(root, "--seams=not-a-seam", repo=plain_repo(tmp_path))
    assert r.returncode == 2
    assert "unknown seam" in r.stderr.lower()


def test_seams_flag_selects_a_subset(root, tmp_path):
    r = collect(root, "--seams=findings-corrections", repo=plain_repo(tmp_path))
    assert set(seam_report(r)) == {"findings-corrections"}


# --------------------------------------------------------------------------- #
# Seam 1 — session-recall (the ported seam, behaviour unchanged)
# --------------------------------------------------------------------------- #
def test_seam_session_recall_collects(root, tmp_path):
    f = write_turns(main_path(root, SLUG), [user_turn(PREF, 0)])
    set_mtime(f, IN_WINDOW)
    r = collect(
        root,
        "--seams=session-recall",
        f"--since={SINCE_ISO}",
        repo=plain_repo(tmp_path),
    )
    assert r.returncode == 0, r.stderr
    rep = seam_report(r)["session-recall"]
    assert rep["searched"] is True
    assert rep["found"] == 1
    assert r.json()["candidates"][0]["seams"] == ["session-recall"]
    assert "preference" in r.json()["candidates"][0]["signals"]


def test_seam_session_recall_degrades_when_recall_missing(root, tmp_path):
    f = write_turns(main_path(root, SLUG), [user_turn(PREF, 0)])
    set_mtime(f, IN_WINDOW)
    r = invoke(
        "collect",
        f"--slug={SLUG}",
        "--seams=session-recall",
        f"--repo={plain_repo(tmp_path)}",
        root=root,
        recall=Path("/nonexistent/recall.py"),
    )
    # degraded, not crashed: exit 3 = could not search
    assert r.returncode == 3, r.stderr
    rep = seam_report(r)["session-recall"]
    assert rep["searched"] is False
    assert rep["found"] == 0
    assert "recall.py not found" in rep["note"]


# --------------------------------------------------------------------------- #
# Seam 2 — offboard-history
# --------------------------------------------------------------------------- #
def test_seam_offboard_history_collects_from_git(root, tmp_path):
    repo = git_init(tmp_path / "explore")
    git_commit_file(
        repo, "refs/session-handoff.md", "# handoff\nnothing yet here\n"
    )
    git_commit_file(
        repo,
        "refs/session-handoff.md",
        f"# handoff\n{GOTCHA}\n",
        subject="offboard: note",
    )
    r = collect(root, "--seams=offboard-history", repo=repo)
    assert r.returncode == 0, r.stderr
    rep = seam_report(r)["offboard-history"]
    assert rep["searched"] is True
    assert rep["found"] >= 1
    assert any(GOTCHA in t for t in texts(r)), texts(r)


def test_seam_offboard_history_degrades_on_non_repo(root, tmp_path):
    r = collect(root, "--seams=offboard-history", repo=plain_repo(tmp_path))
    rep = seam_report(r)["offboard-history"]
    assert rep["searched"] is False
    assert rep["found"] == 0
    assert "not a git repo" in rep["note"]


def test_offboard_history_surfaces_churn(root, tmp_path):
    """A handoff note rewritten N times is itself the signal — /offboard
    overwrites rather than appends, so only the count says 'this keeps changing'."""
    repo = git_init(tmp_path / "explore")
    for i in range(4):
        git_commit_file(
            repo,
            "refs/session-handoff.md",
            f"# handoff revision {i}\nsome ordinary prose here\n",
            subject=f"offboard: rev {i}",
        )
    r = collect(root, "--seams=offboard-history", "--churn-min=3", repo=repo)
    churn = [
        c for c in r.json()["candidates"] if c["detail"].get("kind") == "churn"
    ]
    assert churn, r.json()["candidates"]
    assert churn[0]["detail"]["revisions"] == 4
    assert churn[0]["signals"] == ["churn"]


# --------------------------------------------------------------------------- #
# Seam 3 — memory-history
# --------------------------------------------------------------------------- #
def test_seam_memory_history_collects_current_slug_only(root, tmp_path):
    """The vault holds every slug; the seam is pathspec-scoped to THIS one."""
    git_init(root)
    git_commit_file(root, f"{SLUG}/memory/MEMORY.md", "- an old belief\n")
    git_commit_file(
        root,
        f"{SLUG}/memory/MEMORY.md",
        f"- {GOTCHA}\n",
        subject="memory: revise",
    )
    git_commit_file(
        root,
        f"{CONF_SLUG}/memory/MEMORY.md",
        "- LEAKTOKEN confidential belief that must never surface\n",
    )
    r = collect(root, "--seams=memory-history", repo=plain_repo(tmp_path))
    assert r.returncode == 0, r.stderr
    rep = seam_report(r)["memory-history"]
    assert rep["searched"] is True
    assert any(GOTCHA in t for t in texts(r)), texts(r)
    assert "LEAKTOKEN" not in r.stdout


def test_seam_memory_history_degrades_when_no_vault(root, tmp_path):
    r = collect(root, "--seams=memory-history", repo=plain_repo(tmp_path))
    rep = seam_report(r)["memory-history"]
    assert rep["searched"] is False
    assert rep["found"] == 0


# --------------------------------------------------------------------------- #
# Seam 4 — skill-history
# --------------------------------------------------------------------------- #
def test_seam_skill_history_collects(root, tmp_path):
    skills = git_init(tmp_path / "dotfiles")
    git_commit_file(skills, "agents/skills/foo/SKILL.md", "# foo\nplain body\n")
    git_commit_file(
        skills,
        "agents/skills/foo/SKILL.md",
        f"# foo\n{PREF}\n",
        subject="foo: harden the wording",
    )
    r = collect(
        root,
        "--seams=skill-history",
        repo=plain_repo(tmp_path),
        skills_repo=skills,
    )
    assert r.returncode == 0, r.stderr
    rep = seam_report(r)["skill-history"]
    assert rep["searched"] is True
    assert any(PREF in t for t in texts(r)), texts(r)


def test_seam_skill_history_degrades_when_repo_absent(root, tmp_path):
    r = collect(
        root,
        "--seams=skill-history",
        repo=plain_repo(tmp_path),
        skills_repo=tmp_path / "does-not-exist",
    )
    rep = seam_report(r)["skill-history"]
    assert rep["searched"] is False
    assert "not found" in rep["note"]


# --------------------------------------------------------------------------- #
# Seam 5 — findings-corrections
# --------------------------------------------------------------------------- #
FINDINGS = f"""# Some exploration

## Findings

Ordinary prose that is not a correction at all.

## Corrections

{GOTCHA}

## Scrutiny — 2026-08-01: Verdict: SHIP

The reviewer confirmed the measurement held up under a re-run.

## Next
Unrelated trailing section.
"""


def test_seam_findings_corrections_extracts_blocks(root, tmp_path):
    repo = plain_repo(tmp_path, "explore")
    (repo / "child").mkdir(parents=True)
    (repo / "child" / "FINDINGS.md").write_text(FINDINGS, encoding="utf-8")
    r = collect(root, "--seams=findings-corrections", repo=repo)
    assert r.returncode == 0, r.stderr
    rep = seam_report(r)["findings-corrections"]
    assert rep["searched"] is True
    assert rep["found"] == 2, texts(r)  # Corrections + Scrutiny, not Findings
    assert any(GOTCHA in t for t in texts(r))
    assert not any("Unrelated trailing section" in t for t in texts(r))


def test_seam_findings_no_findings_is_searched_but_empty(root, tmp_path):
    """The positive control: 'looked, found nothing' (exit 1) is NOT 'could not
    look' (exit 3)."""
    r = collect(root, "--seams=findings-corrections", repo=plain_repo(tmp_path))
    assert r.returncode == 1, r.stderr
    rep = seam_report(r)["findings-corrections"]
    assert rep["searched"] is True
    assert rep["found"] == 0


def test_extract_correction_blocks_unit():
    blocks = dream.extract_correction_blocks(FINDINGS)
    assert [h.split("—")[0].strip() for h, _ in blocks] == [
        "## Corrections",
        "## Scrutiny",
    ]
    assert GOTCHA in blocks[0][1]


# --------------------------------------------------------------------------- #
# Exit contract
# --------------------------------------------------------------------------- #
def test_exit_3_when_no_seam_can_search(root, tmp_path):
    r = collect(
        root,
        "--seams=offboard-history,skill-history",
        repo=plain_repo(tmp_path),
    )
    assert r.returncode == 3, r.stderr
    assert r.json()["seams_searched"] == 0
    assert "no seam was able to search" in r.stderr


def test_exit_0_when_anything_found(root, tmp_path):
    repo = plain_repo(tmp_path, "explore")
    (repo / "child").mkdir(parents=True)
    (repo / "child" / "FINDINGS.md").write_text(FINDINGS, encoding="utf-8")
    r = collect(root, "--seams=findings-corrections", repo=repo)
    assert r.returncode == 0
    assert r.json()["n_candidates"] > 0


# --------------------------------------------------------------------------- #
# Cross-seam merge
# --------------------------------------------------------------------------- #
def test_merge_collapses_duplicate_across_seams(root, tmp_path):
    """The same line reached by two independent seams is ONE candidate carrying
    BOTH seam names — which is exactly what the recurrence bar's
    '>= 2 distinct seams in one run' clause reads."""
    repo = git_init(tmp_path / "explore")
    git_commit_file(repo, "refs/session-handoff.md", f"# handoff\n{GOTCHA}\n")

    git_init(root)
    git_commit_file(root, f"{SLUG}/memory/MEMORY.md", f"- {GOTCHA}\n")

    r = collect(root, "--seams=offboard-history,memory-history", repo=repo)
    assert r.returncode == 0, r.stderr
    hits = [c for c in r.json()["candidates"] if GOTCHA in c["text"]]
    assert len(hits) == 1, hits
    assert set(hits[0]["seams"]) == {"offboard-history", "memory-history"}
    assert hits[0]["n_sources"] == 2


def test_merge_round_robins_across_seams(root, tmp_path):
    """Cap must sample every seam, never keep whichever ran first (explore-j2p9)."""
    repo = git_init(tmp_path / "explore")
    git_commit_file(
        repo,
        "refs/session-handoff.md",
        "\n".join(f"{GOTCHA} number {i}" for i in range(6)) + "\n",
    )
    findings_repo = repo / "child"
    findings_repo.mkdir(parents=True)
    (findings_repo / "FINDINGS.md").write_text(FINDINGS, encoding="utf-8")

    r = collect(
        root,
        "--seams=offboard-history,findings-corrections",
        "--max-candidates=2",
        repo=repo,
    )
    seams = {c["seams"][0] for c in r.json()["candidates"]}
    assert seams == {"offboard-history", "findings-corrections"}
    assert r.json()["truncated"] is True


# --------------------------------------------------------------------------- #
# Recurrence memory — the bar
# --------------------------------------------------------------------------- #
def _entry(**kw) -> dict:
    base = {
        "key": "k",
        "gist": "g",
        "count": 1,
        "runs": ["r1"],
        "seams": ["session-recall"],
        "run_seams": {"r1": ["session-recall"]},
        "disposition": "observed",
    }
    base.update(kw)
    return base


def test_bar_single_run_single_seam_is_below():
    ok, why = dream.qualifies(_entry())
    assert ok is False
    assert "below the recurrence bar" in why


def test_bar_two_distinct_runs_qualifies():
    ok, why = dream.qualifies(
        _entry(count=2, runs=["r1", "r2"], run_seams={"r1": ["a"], "r2": ["a"]})
    )
    assert ok is True
    assert "2 distinct runs" in why


def test_bar_two_seams_in_one_run_qualifies():
    ok, why = dream.qualifies(
        _entry(run_seams={"r1": ["session-recall", "skill-history"]})
    )
    assert ok is True
    assert "distinct seams in one run" in why


def test_bar_rejected_is_suppressed_until_count_doubles():
    rejected = _entry(
        count=2,
        runs=["r1", "r2"],
        disposition="rejected",
        rejected_at_count=2,
    )
    ok, why = dream.qualifies(rejected)
    assert ok is False and "suppressed until count >= 4" in why

    rejected["count"] = 4
    ok, why = dream.qualifies(rejected)
    assert ok is True and "doubled" in why


def test_bar_promoted_is_suppressed():
    ok, why = dream.qualifies(
        _entry(count=9, runs=["r1", "r2"], disposition="promoted")
    )
    assert ok is False
    assert "already promoted" in why


# --------------------------------------------------------------------------- #
# Recurrence memory — the remember subcommand
# --------------------------------------------------------------------------- #
def write_obs(path: Path, run_id: str, observations: list[dict]) -> Path:
    path.write_text(
        json.dumps({"run_id": run_id, "observations": observations}),
        encoding="utf-8",
    )
    return path


def test_remember_creates_then_bumps_across_runs(tmp_path):
    mem = tmp_path / "refs" / "dream-memory.jsonl"
    obs = write_obs(
        tmp_path / "obs1.json",
        "run-1",
        [
            {
                "key": "flock-gotcha",
                "gist": "flock drops on fork",
                "seams": ["session-recall"],
            }
        ],
    )
    r1 = invoke_raw(
        "remember",
        f"--observations={obs}",
        f"--memory={mem}",
        "--now=2026-08-01T00:00:00Z",
    )
    assert r1.returncode == 0, r1.stderr
    s1 = r1.json()
    assert s1["new_keys"] == ["flock-gotcha"]
    assert s1["qualified"] == []  # one run, one seam: below the bar

    obs2 = write_obs(
        tmp_path / "obs2.json",
        "run-2",
        [
            {
                "key": "flock-gotcha",
                "gist": "flock drops on fork",
                "seams": ["skill-history"],
            }
        ],
    )
    r2 = invoke_raw(
        "remember",
        f"--observations={obs2}",
        f"--memory={mem}",
        "--now=2026-08-08T00:00:00Z",
    )
    assert r2.returncode == 0, r2.stderr
    s2 = r2.json()
    assert s2["updated_keys"] == ["flock-gotcha"]
    assert [q["key"] for q in s2["qualified"]] == ["flock-gotcha"]

    entries = dream.load_memory(mem)
    assert len(entries) == 1
    e = entries[0]
    assert e["count"] == 2
    assert e["runs"] == ["run-1", "run-2"]
    assert sorted(e["seams"]) == ["session-recall", "skill-history"]
    assert e["first_seen"] == "2026-08-01T00:00:00Z"
    assert e["last_seen"] == "2026-08-08T00:00:00Z"
    assert e["disposition"] == "observed"


def test_remember_two_seams_in_one_run_qualifies_immediately(tmp_path):
    mem = tmp_path / "dream-memory.jsonl"
    obs = write_obs(
        tmp_path / "obs.json",
        "run-1",
        [
            {
                "key": "two-seam",
                "gist": "seen twice in one run",
                "seams": ["offboard-history", "findings-corrections"],
            }
        ],
    )
    r = invoke_raw(
        "remember",
        f"--observations={obs}",
        f"--memory={mem}",
        "--now=2026-08-01T00:00:00Z",
    )
    assert r.returncode == 0, r.stderr
    assert [q["key"] for q in r.json()["qualified"]] == ["two-seam"]


def test_remember_records_rejection_baseline(tmp_path):
    mem = tmp_path / "dream-memory.jsonl"
    obs = write_obs(
        tmp_path / "obs.json",
        "run-1",
        [
            {
                "key": "nope",
                "gist": "zig said no",
                "seams": ["a"],
                "disposition": "rejected",
            }
        ],
    )
    r = invoke_raw(
        "remember",
        f"--observations={obs}",
        f"--memory={mem}",
        "--now=2026-08-01T00:00:00Z",
    )
    assert r.returncode == 0, r.stderr
    e = dream.load_memory(mem)[0]
    assert e["disposition"] == "rejected"
    assert e["rejected_at_count"] == 1
    assert r.json()["qualified"] == []


def test_remember_rejects_bad_disposition(tmp_path):
    mem = tmp_path / "dream-memory.jsonl"
    obs = write_obs(
        tmp_path / "obs.json",
        "run-1",
        [{"key": "k", "gist": "g", "disposition": "wishful"}],
    )
    r = invoke_raw("remember", f"--observations={obs}", f"--memory={mem}")
    assert r.returncode == 2
    assert "unknown disposition" in r.stderr
    assert not mem.exists()


def test_remember_dry_run_writes_nothing(tmp_path):
    mem = tmp_path / "dream-memory.jsonl"
    obs = write_obs(tmp_path / "obs.json", "run-1", [{"key": "k", "gist": "g"}])
    r = invoke_raw(
        "remember", f"--observations={obs}", f"--memory={mem}", "--dry-run"
    )
    assert r.returncode == 0, r.stderr
    assert r.json()["dry_run"] is True
    assert not mem.exists()


# --------------------------------------------------------------------------- #
# collect carries the memory_digest
# --------------------------------------------------------------------------- #
def test_collect_emits_memory_digest(root, tmp_path):
    mem = tmp_path / "dream-memory.jsonl"
    obs = write_obs(
        tmp_path / "obs.json",
        "run-1",
        [
            {
                "key": "a",
                "gist": "first",
                "seams": ["session-recall", "skill-history"],
            },
            {"key": "b", "gist": "second", "seams": ["session-recall"]},
        ],
    )
    assert (
        invoke_raw(
            "remember",
            f"--observations={obs}",
            f"--memory={mem}",
            "--now=2026-08-01T00:00:00Z",
        ).returncode
        == 0
    )

    r = collect(
        root,
        "--seams=findings-corrections",
        repo=plain_repo(tmp_path),
        memory=mem,
    )
    digest = r.json()["memory_digest"]
    assert digest["exists"] is True
    assert digest["path"] == str(mem)
    assert digest["n_entries"] == 2
    assert digest["n_qualified"] == 1  # 'a' saw two seams in one run
    keys = {e["key"]: e for e in digest["entries"]}
    assert set(keys) == {"a", "b"}
    assert keys["a"]["qualified"] is True
    assert keys["b"]["qualified"] is False
    # the digest is keys + gists + counts ONLY — never full bodies
    assert set(keys["a"]) == {
        "key",
        "gist",
        "count",
        "runs",
        "seams",
        "disposition",
        "first_seen",
        "last_seen",
        "qualified",
        "qualify_reason",
    }


def test_collect_missing_memory_store_is_not_an_error(root, tmp_path):
    r = collect(
        root,
        "--seams=findings-corrections",
        repo=plain_repo(tmp_path),
        memory=tmp_path / "absent.jsonl",
    )
    assert r.returncode in (0, 1), r.stderr
    digest = r.json()["memory_digest"]
    assert digest["exists"] is False
    assert digest["n_entries"] == 0


# --------------------------------------------------------------------------- #
# Confidentiality guard
# --------------------------------------------------------------------------- #
def test_is_confidential_path_unit():
    for bad in (
        "-home-ubuntu-linearb",
        "-home-ubuntu-cfp",
        "/home/ubuntu/linearb/refs/x.md",
        "/home/ubuntu/cfp2026/notes.md",
        "linearb-notes/FINDINGS.md",
        "/tmp/projects/-home-ubuntu-linearb/memory/MEMORY.md",
    ):
        assert dream.is_confidential_path(bad), bad
    for ok in (
        "-home-ubuntu-explore",
        "/home/ubuntu/dotfiles/agents/skills/dream/dream.py",
        "refs/session-handoff--dream.md",
        "/home/ubuntu/explore/linear-algebra/FINDINGS.md",
    ):
        assert not dream.is_confidential_path(ok), ok


def test_guard_path_raises_and_audits(tmp_path, monkeypatch):
    audit = tmp_path / "audit.log"
    monkeypatch.setenv("DREAM_PATH_AUDIT", str(audit))
    dream.guard_path("/home/ubuntu/explore/ok.md", "read")
    try:
        dream.guard_path("/home/ubuntu/linearb/secret.md", "read")
    except dream.ConfidentialPathError:
        pass
    else:  # pragma: no cover
        raise AssertionError("guard_path must raise on a confidential path")
    lines = audit.read_text(encoding="utf-8").splitlines()
    assert any(
        line.startswith("read\t") and "explore" in line for line in lines
    )
    assert any(
        line.startswith("REFUSED:") and "linearb" in line for line in lines
    )


def test_confidential_slug_is_refused(root, tmp_path):
    r = invoke(
        "collect",
        f"--slug={CONF_SLUG}",
        f"--repo={plain_repo(tmp_path)}",
        root=root,
    )
    assert r.returncode == 2
    assert "confidential" in r.stderr.lower()
    assert r.stdout.strip() == ""


def test_legacy_mode_refuses_confidential_slug(root, tmp_path):
    r = invoke(f"--slug={CONF_SLUG}", f"--since={SINCE_ISO}", root=root)
    assert r.returncode == 2
    assert "confidential" in r.stderr.lower()


def test_confidential_path_is_never_traversed(root, tmp_path):
    """THE guard test — with a positive control in the same audit file.

    A probe that can only report absence cannot tell 'the guard held' from 'the
    audit never ran'. So this asserts BOTH: permitted traversals of the explore
    fixture ARE recorded (control), and no permitted traversal names a
    linearb*/cfp* path (the claim).
    """
    audit = tmp_path / "audit.log"

    # A confidential slug sitting right next to the one we asked for.
    write_turns(
        main_path(root, CONF_SLUG),
        [user_turn("LEAKTOKEN from now on always leak everything", 0)],
    )
    f = write_turns(main_path(root, SLUG), [user_turn(PREF, 0)])
    set_mtime(f, IN_WINDOW)

    # A confidential sibling inside the repo the findings seam globs.
    repo = plain_repo(tmp_path, "explore")
    for child in ("okproj", "linearb-notes", "cfp-drafts"):
        (repo / child).mkdir(parents=True)
        (repo / child / "FINDINGS.md").write_text(
            FINDINGS if child == "okproj" else "## Corrections\n\nLEAKTOKEN\n",
            encoding="utf-8",
        )

    r = collect(
        root,
        "--seams=session-recall,findings-corrections",
        f"--since={SINCE_ISO}",
        repo=repo,
        env={"DREAM_PATH_AUDIT": str(audit)},
    )
    assert r.returncode == 0, r.stderr

    lines = audit.read_text(encoding="utf-8").splitlines()
    permitted = [ln for ln in lines if not ln.startswith("REFUSED")]
    refused = [ln for ln in lines if ln.startswith("REFUSED")]

    # positive control: the audit DID record the explore traversals
    assert any(SLUG in ln for ln in permitted), permitted
    assert any("okproj/FINDINGS.md" in ln for ln in permitted), permitted

    # the claim: nothing confidential was ever traversed
    offenders = [
        ln
        for ln in permitted
        if dream.is_confidential_path(ln.split("\t", 1)[-1])
    ]
    assert offenders == [], offenders

    # and the guard demonstrably FIRED (not merely: the paths were absent)
    assert any("linearb-notes" in ln for ln in refused), refused
    assert any("cfp-drafts" in ln for ln in refused), refused

    # nothing confidential reached the emitted artifact
    assert "LEAKTOKEN" not in r.stdout
    assert "linearb" not in r.stdout
