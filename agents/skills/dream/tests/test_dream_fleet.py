"""Tests for FLEET SCOPE — slug iteration, the confinement denylist, per-repo
filing, cross-slug recurrence, the caps, and ``--dry-run`` (``dotfiles-xicr``).

``test_dream.py`` pins the legacy single-seam contract and ``test_dream_seams.py``
the seam interface; both must keep passing untouched. This file covers what
lifting CURRENT-SLUG-ONLY added:

* ``collect`` with no ``--slug`` iterates every PERMITTED slug under the root;
* the denylist — a ``linearb``-named fixture slug must **never** appear in the
  emitted artifact, by name or by content. That is the confidentiality test, and
  it carries a positive control (permitted slugs DO appear; the audit log shows
  the denial FIRED) so "closed" cannot read as "broken";
* proposals are planned into **each repo's own** bead store, and a repo with no
  store is a LOUD SKIP rather than a silent redirect;
* a learning seen in >= 2 slugs self-flags, in the candidate AND in the proposal
  body the plan previews;
* ``--max-slugs`` / ``--max-per-slug`` bound the cost;
* ``--dry-run`` leaves the tree byte-identical, and the guard that makes that
  true actually bites.

The slug fixtures are REAL slugs of REAL tmp directories, so the slug -> repo
resolver is exercised end to end rather than stubbed — that resolver is the one
piece of fleet scope a mock would hide (the forward transform is lossy).
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import pytest
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

GOTCHA = "watch out: the flock silently drops the lock on fork"
PREF = "from now on always run the linter before committing anything"
LEAK = "LEAKTOKEN confidential material that must never be emitted"
IN_WINDOW = 1_782_000_000.0  # 2026-06-20; any --since older than this is fine
SINCE_ISO = "2026-01-01T00:00:00Z"


# --------------------------------------------------------------------------- #
# fixture builders
# --------------------------------------------------------------------------- #
def slug_of(path: Path) -> str:
    """The slug Claude would key ``path`` by — derived, never hand-typed."""
    return dream.slugify_name(str(path))


def make_repo(tmp_path: Path, name: str, *, beads: bool = True) -> Path:
    """A git repo with a handoff note and (optionally) its own bead store."""
    repo = git_init(tmp_path / name)
    if beads:
        (repo / ".beads").mkdir(parents=True, exist_ok=True)
        (repo / ".beads" / f"{name}.db").write_bytes(b"")
        (repo / ".beads" / "issues.jsonl").write_text("", encoding="utf-8")
    return repo


def register_slug(root: Path, repo: Path) -> str:
    """Create the projects-root dir for ``repo``'s slug and return the slug."""
    slug = slug_of(repo)
    (Path(root) / slug).mkdir(parents=True, exist_ok=True)
    return slug


def fleet(
    root: Path,
    *flags: str,
    tmp_path: Path,
    skills_repo: Path | None = None,
    memory: Path | None = None,
    env: dict | None = None,
) -> Result:
    """``dream.py collect`` in FLEET mode with every external source pinned.

    No ``--slug`` (that is what selects fleet scope) and no ``--repo`` (each slug
    resolves its own). Nothing may fall back to the live machine.
    """
    args = [
        "collect",
        "--history-since=1970-01-01T00:00:00Z",
        f"--since={SINCE_ISO}",
        f"--skills-repo={skills_repo or (tmp_path / 'no-skills-repo')}",
        f"--memory-git-dir={tmp_path / 'no-memory.git'}",
        f"--memory={memory or (tmp_path / 'dream-memory.jsonl')}",
        *flags,
    ]
    return invoke(*args, root=root, env=env)


def plan_for(res: Result, slug: str) -> dict:
    rows = [r for r in res.json()["filing_plan"] if r["slug"] == slug]
    assert rows, f"{slug} not in filing plan: {res.json()['filing_plan']}"
    return rows[0]


def tree_state(root: Path) -> set:
    """(relpath, size, mtime_ns) for every file under ``root``."""
    out = set()
    for p in sorted(Path(root).rglob("*")):
        if p.is_file():
            st = p.stat()
            out.add((str(p.relative_to(root)), st.st_size, st.st_mtime_ns))
    return out


# --------------------------------------------------------------------------- #
# 1. Slug iteration — the lift itself
# --------------------------------------------------------------------------- #
def test_fleet_iterates_every_permitted_slug(root, tmp_path):
    """The whole point: two slugs, one run, BOTH mined.

    Pre-dotfiles-xicr this run would have mined whichever slug the cwd named and
    reported a clean success for the other one's silence.
    """
    alpha = make_repo(tmp_path, "alpha")
    beta = make_repo(tmp_path, "beta")
    git_commit_file(
        alpha, "refs/session-handoff.md", f"# a\n{GOTCHA} in alpha\n"
    )
    git_commit_file(beta, "refs/session-handoff.md", f"# b\n{PREF} in beta\n")
    sa, sb = register_slug(root, alpha), register_slug(root, beta)

    r = fleet(root, "--seams=offboard-history", tmp_path=tmp_path)
    assert r.returncode == 0, r.stderr
    out = r.json()
    assert out["fleet"] is True
    assert {s["slug"] for s in out["slugs"]} == {sa, sb}
    texts = [c["text"] for c in out["candidates"]]
    assert any("in alpha" in t for t in texts), texts
    assert any("in beta" in t for t in texts), texts
    assert {s for c in out["candidates"] for s in c["slugs"]} == {sa, sb}


def test_slugs_subcommand_reports_scope(root, tmp_path):
    alpha = make_repo(tmp_path, "alpha")
    sa = register_slug(root, alpha)
    r = invoke_raw("slugs", f"--root={root}", "--resolve")
    assert r.returncode == 0, r.stderr
    out = r.json()
    assert [s["slug"] for s in out["slugs"]] == [sa]
    assert out["slugs"][0]["repo"] == str(alpha)
    assert out["slugs"][0]["store_ok"] is True


def test_no_fleet_restores_current_slug_only(root, tmp_path):
    """The escape hatch still exists and still narrows."""
    alpha = make_repo(tmp_path, "alpha")
    beta = make_repo(tmp_path, "beta")
    git_commit_file(
        alpha, "refs/session-handoff.md", f"# a\n{GOTCHA} in alpha\n"
    )
    git_commit_file(beta, "refs/session-handoff.md", f"# b\n{GOTCHA} in beta\n")
    register_slug(root, alpha)
    register_slug(root, beta)

    r = fleet(
        root,
        "--no-fleet",
        "--seams=offboard-history",
        f"--repo={alpha}",
        tmp_path=tmp_path,
    )
    assert r.json()["fleet"] is False
    texts = [c["text"] for c in r.json()["candidates"]]
    assert any("in alpha" in t for t in texts), texts
    assert not any("in beta" in t for t in texts), texts


# --------------------------------------------------------------------------- #
# 2. THE DENYLIST — the explicit confidentiality test
# --------------------------------------------------------------------------- #
def test_denylisted_slug_never_appears_in_fleet_output(root, tmp_path):
    """A linearb-named slug must NEVER surface — name, path, or content.

    With a positive control in the same assertions, because a test that can only
    observe an absence cannot tell "the denylist held" from "the fixture never
    existed": the permitted slug IS present, the audit log records the denial as
    a REFUSAL (so the guard demonstrably fired), and the denied COUNT is > 0.
    """
    audit = tmp_path / "audit.log"
    alpha = make_repo(tmp_path, "alpha")
    git_commit_file(
        alpha, "refs/session-handoff.md", f"# a\n{GOTCHA} in alpha\n"
    )
    sa = register_slug(root, alpha)

    # A confidential project sitting right beside it, with real material in it.
    linearb = make_repo(tmp_path, "linearb-fixture")
    git_commit_file(linearb, "refs/session-handoff.md", f"# l\n{LEAK}\n")
    denied_slug = register_slug(root, linearb)
    write_turns(main_path(root, denied_slug), [user_turn(LEAK, 0)])
    assert "linearb" in denied_slug  # the fixture is what we think it is

    r = fleet(
        root,
        "--seams=offboard-history,session-recall",
        tmp_path=tmp_path,
        env={"DREAM_PATH_AUDIT": str(audit)},
    )
    assert r.returncode == 0, r.stderr
    out = r.json()

    # THE CLAIM: nothing confidential in the emitted artifact, at all.
    assert "linearb" not in r.stdout.lower()
    assert "LEAKTOKEN" not in r.stdout
    assert denied_slug not in r.stdout

    # positive control 1: the permitted slug DID get mined
    assert [s["slug"] for s in out["slugs"]] == [sa]
    assert any("in alpha" in c["text"] for c in out["candidates"])

    # positive control 2: the denial is COUNTED (never named)
    assert out["denied"]["count"] == 1
    assert out["denied"]["mechanism"] == "CONFIDENTIAL_PREFIXES denylist"
    assert out["denied"]["total_slugs_seen"] == 2

    # positive control 3: the guard demonstrably FIRED
    lines = audit.read_text(encoding="utf-8").splitlines()
    refused = [ln for ln in lines if ln.startswith("REFUSED")]
    permitted = [ln for ln in lines if not ln.startswith("REFUSED")]
    assert any("slug-denylist" in ln and "linearb" in ln for ln in refused)
    offenders = [
        ln for ln in permitted if dream.is_confidential_path(ln.split("\t")[-1])
    ]
    assert offenders == [], offenders


def test_denylisted_slug_dir_is_never_traversed(root, tmp_path):
    """Not merely absent from the output — never opened.

    The audit records every permitted traversal, so a denied slug directory
    appearing on a permitted line would mean the denylist fired too late.
    """
    audit = tmp_path / "audit.log"
    alpha = make_repo(tmp_path, "alpha")
    sa = register_slug(root, alpha)
    linearb = tmp_path / "linearb-fixture"
    linearb.mkdir()
    denied_slug = register_slug(root, linearb)
    f = write_turns(main_path(root, denied_slug), [user_turn(LEAK, 0)])
    set_mtime(f, IN_WINDOW)

    fleet(
        root,
        "--seams=session-recall",
        tmp_path=tmp_path,
        env={"DREAM_PATH_AUDIT": str(audit)},
    )
    lines = audit.read_text(encoding="utf-8").splitlines()
    permitted = [ln for ln in lines if not ln.startswith("REFUSED")]
    assert any(sa in ln for ln in permitted), permitted  # control
    assert not any(denied_slug in ln for ln in permitted), permitted


def test_denied_text_is_dropped_from_candidates(root, tmp_path):
    """A PERMITTED repo's line that NAMES a denied project is dropped too.

    Fleet scope is the first version where such a line can move between repos
    (a cross-slug candidate is offered to both filing plans), and this is what
    lets the merge gate assert ZERO mechanically. Measured live 2026-08-09: one
    dotfiles handoff line reading "…LinearB seat…".
    """
    alpha = make_repo(tmp_path, "alpha")
    git_commit_file(
        alpha,
        "refs/session-handoff.md",
        f"# a\n{GOTCHA} in alpha\nconfirmed: the linearb seat billing is fixed\n",
    )
    register_slug(root, alpha)

    r = fleet(root, "--seams=offboard-history", tmp_path=tmp_path)
    assert r.returncode == 0, r.stderr
    assert "linearb" not in r.stdout.lower()
    assert r.json()["denied"]["candidates_dropped"] == 1
    # control: the innocent line from the SAME commit survived
    assert any("in alpha" in c["text"] for c in r.json()["candidates"])


def test_drop_confidential_text_unit():
    kept, n = dream.drop_confidential_text(
        [
            {"text": "an ordinary durable learning"},
            {"text": "something about the linearb seat"},
            {"text": "a cfp2026 deadline note"},
            {"text": "linear algebra is fine"},
        ]
    )
    assert n == 2
    assert [c["text"] for c in kept] == [
        "an ordinary durable learning",
        "linear algebra is fine",
    ]


def test_explicit_denied_slug_is_still_a_hard_refusal(root, tmp_path):
    """Fleet scope did not soften the explicit path: --slug=<denied> is exit 2."""
    r = invoke(
        "collect",
        "--slug=-home-ubuntu-linearb",
        f"--repo={tmp_path}",
        root=root,
    )
    assert r.returncode == 2
    assert "confidential" in r.stderr.lower()
    assert r.stdout.strip() == ""


# --------------------------------------------------------------------------- #
# 3. Per-repo filing + the loud skip
# --------------------------------------------------------------------------- #
def test_filing_plan_targets_each_repos_own_store(root, tmp_path):
    """Bead-location discipline: alpha's learnings are filed in ALPHA."""
    alpha = make_repo(tmp_path, "alpha")
    beta = make_repo(tmp_path, "beta")
    git_commit_file(
        alpha, "refs/session-handoff.md", f"# a\n{GOTCHA} in alpha\n"
    )
    git_commit_file(beta, "refs/session-handoff.md", f"# b\n{PREF} in beta\n")
    sa, sb = register_slug(root, alpha), register_slug(root, beta)

    r = fleet(root, "--seams=offboard-history", tmp_path=tmp_path)
    pa, pb = plan_for(r, sa), plan_for(r, sb)

    assert pa["repo"] == str(alpha)
    assert pa["store"] == str(alpha / ".beads")
    assert pa["db"] == str(alpha / ".beads" / "alpha.db")
    assert pa["br_cwd"] == str(alpha)
    assert pa["store_ok"] is True and pa["skip_reason"] is None
    assert pb["repo"] == str(beta)
    assert pb["db"] == str(beta / ".beads" / "beta.db")

    # the previews are for THAT repo's material, not the other's
    assert any("in alpha" in p["body_preview"] for p in pa["proposals"])
    assert not any("in beta" in p["body_preview"] for p in pa["proposals"])


def test_ambiguous_store_offers_cwd_not_a_guessed_db(root, tmp_path):
    """Two .db files: no --db is emitted, and cwd-filing is named instead."""
    alpha = make_repo(tmp_path, "alpha")
    (alpha / ".beads" / "issues.db").write_bytes(b"")
    git_commit_file(
        alpha, "refs/session-handoff.md", f"# a\n{GOTCHA} in alpha\n"
    )
    sa = register_slug(root, alpha)

    r = fleet(root, "--seams=offboard-history", tmp_path=tmp_path)
    p = plan_for(r, sa)
    assert p["store_ok"] is True
    assert p["db"] is None, "must not guess between two stores"
    assert p["br_cwd"] == str(alpha)
    assert "ambiguous" in p["note"]


def test_storeless_repo_is_a_loud_skip(root, tmp_path):
    """No .beads -> named skip_reason, stderr LOUD SKIP, and NO redirect."""
    alpha = make_repo(tmp_path, "alpha")  # has a store
    naked = make_repo(tmp_path, "naked", beads=False)  # has none
    git_commit_file(
        alpha, "refs/session-handoff.md", f"# a\n{GOTCHA} in alpha\n"
    )
    git_commit_file(naked, "refs/session-handoff.md", f"# n\n{PREF} in naked\n")
    sa, sn = register_slug(root, alpha), register_slug(root, naked)

    r = fleet(root, "--seams=offboard-history", tmp_path=tmp_path)
    pn = plan_for(r, sn)
    assert pn["store_ok"] is False
    assert pn["store"] is None
    assert "storeless" in pn["skip_reason"]
    assert pn["n_candidates"] > 0
    assert r.json()["filing_skipped"] == 1

    assert "LOUD SKIP" in r.stderr
    assert sn in r.stderr

    # the skip is LOUD, not a redirect: naked's material is NOT planned into
    # alpha, which is the bead-location violation the plan exists to prevent.
    pa = plan_for(r, sa)
    assert not any("in naked" in p["body_preview"] for p in pa["proposals"])
    assert pa["store_ok"] is True  # control


def test_storeless_repo_with_nothing_to_file_is_quiet(root, tmp_path):
    """No candidates -> nothing skipped -> no cry-wolf on stderr."""
    naked = make_repo(tmp_path, "naked", beads=False)
    git_commit_file(naked, "refs/session-handoff.md", "# n\nordinary prose\n")
    register_slug(root, naked)
    r = fleet(root, "--seams=offboard-history", tmp_path=tmp_path)
    assert r.json()["filing_skipped"] == 0
    assert "LOUD SKIP" not in r.stderr


def test_global_seam_files_into_the_harness_repo(root, tmp_path):
    """skill-history is fleet-wide, so its proposals go to the skills repo."""
    skills = make_repo(tmp_path, "dotfiles-fixture")
    git_commit_file(skills, "agents/skills/foo/SKILL.md", "# foo\nplain\n")
    git_commit_file(
        skills,
        "agents/skills/foo/SKILL.md",
        f"# foo\n{PREF}\n",
        subject="foo: harden",
    )
    alpha = make_repo(tmp_path, "alpha")
    register_slug(root, alpha)

    r = fleet(
        root,
        "--seams=skill-history",
        tmp_path=tmp_path,
        skills_repo=skills,
    )
    assert r.returncode == 0, r.stderr
    row = plan_for(r, dream.FLEET_SLUG)
    assert row["repo"] == str(skills)
    assert row["store_ok"] is True
    assert any(
        p["title"].startswith("propose-harden") for p in row["proposals"]
    ), row["proposals"]


def test_global_seam_runs_once_not_once_per_slug(root, tmp_path):
    """N slugs must not produce N copies of the same harness finding."""
    skills = make_repo(tmp_path, "dotfiles-fixture")
    git_commit_file(skills, "agents/skills/foo/SKILL.md", "# foo\nplain\n")
    git_commit_file(
        skills,
        "agents/skills/foo/SKILL.md",
        f"# foo\n{PREF}\n",
        subject="foo: harden",
    )
    for name in ("alpha", "beta", "gamma"):
        register_slug(root, make_repo(tmp_path, name))

    r = fleet(
        root, "--seams=skill-history", tmp_path=tmp_path, skills_repo=skills
    )
    hits = [c for c in r.json()["candidates"] if PREF in c["text"]]
    assert len(hits) == 1, hits
    # attributed to the fleet, and NOT self-corroborated by re-running
    assert hits[0]["slugs"] == [dream.FLEET_SLUG]
    assert hits[0]["n_sources"] == 1
    assert hits[0]["cross_slug"] is False


# --------------------------------------------------------------------------- #
# 4. Cross-slug recurrence — the self-flag
# --------------------------------------------------------------------------- #
def test_cross_slug_recurrence_self_flags(root, tmp_path):
    """The same lesson in two projects is a HARNESS fact, and says so."""
    alpha = make_repo(tmp_path, "alpha")
    beta = make_repo(tmp_path, "beta")
    git_commit_file(alpha, "refs/session-handoff.md", f"# a\n{GOTCHA}\n")
    git_commit_file(beta, "refs/session-handoff.md", f"# b\n{GOTCHA}\n")
    sa, sb = register_slug(root, alpha), register_slug(root, beta)

    r = fleet(root, "--seams=offboard-history", tmp_path=tmp_path)
    assert r.returncode == 0, r.stderr
    hits = [c for c in r.json()["candidates"] if GOTCHA in c["text"]]
    assert len(hits) == 1, hits  # one candidate, two sources
    assert sorted(hits[0]["slugs"]) == sorted([sa, sb])
    assert hits[0]["cross_slug"] is True
    assert hits[0]["n_sources"] == 2
    assert r.json()["n_cross_slug"] == 1

    # and it reaches the PROPOSAL TEXT, not just the JSON
    body = plan_for(r, sa)["proposals"][0]["body_preview"]
    assert "CROSS-SLUG RECURRENCE" in body
    assert sa in body and sb in body


def test_single_slug_recurrence_is_not_flagged(root, tmp_path):
    """The negative control for the flag: one slug, twice, is not cross-slug."""
    alpha = make_repo(tmp_path, "alpha")
    git_commit_file(alpha, "refs/session-handoff.md", f"# a\n{GOTCHA}\n")
    git_commit_file(
        alpha, "refs/session-handoff.md", f"# a2\n{GOTCHA}\n", subject="again"
    )
    register_slug(root, alpha)
    r = fleet(root, "--seams=offboard-history", tmp_path=tmp_path)
    hits = [c for c in r.json()["candidates"] if GOTCHA in c["text"]]
    assert hits and hits[0]["cross_slug"] is False
    assert r.json()["n_cross_slug"] == 0


def test_bar_two_slugs_qualifies():
    ok, why = dream.qualifies(
        {
            "key": "k",
            "count": 1,
            "runs": ["r1"],
            "seams": ["offboard-history"],
            "run_seams": {"r1": ["offboard-history"]},
            "slugs": ["-a", "-b"],
            "disposition": "observed",
        }
    )
    assert ok is True
    assert why.startswith("CROSS-SLUG")


def test_bar_fleet_pseudo_slug_does_not_count():
    """(fleet) is not a project — pairing it with one slug is not recurrence."""
    ok, why = dream.qualifies(
        {
            "key": "k",
            "count": 1,
            "runs": ["r1"],
            "run_seams": {"r1": ["skill-history"]},
            "slugs": ["-a", dream.FLEET_SLUG],
            "disposition": "observed",
        }
    )
    assert ok is False
    assert "below the recurrence bar" in why


def test_remember_records_slugs_and_qualifies_cross_slug(tmp_path):
    mem = tmp_path / "dream-memory.jsonl"
    obs1 = tmp_path / "o1.json"
    obs1.write_text(
        json.dumps(
            {
                "run_id": "run-1",
                "observations": [
                    {
                        "key": "flock",
                        "gist": "flock drops on fork",
                        "seams": ["offboard-history"],
                        "slug": "-home-ubuntu-alpha",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    r1 = invoke_raw(
        "remember",
        f"--observations={obs1}",
        f"--memory={mem}",
        "--now=2026-08-01T00:00:00Z",
    )
    assert r1.returncode == 0, r1.stderr
    assert r1.json()["qualified"] == []  # one slug, one run, one seam

    obs2 = tmp_path / "o2.json"
    obs2.write_text(
        json.dumps(
            {
                "run_id": "run-1",
                "observations": [
                    {
                        "key": "flock",
                        "gist": "flock drops on fork",
                        "seams": ["offboard-history"],
                        "slugs": ["-home-ubuntu-beta"],
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    r2 = invoke_raw(
        "remember",
        f"--observations={obs2}",
        f"--memory={mem}",
        "--now=2026-08-01T00:00:00Z",
    )
    assert r2.returncode == 0, r2.stderr
    assert [q["key"] for q in r2.json()["qualified"]] == ["flock"]
    assert "CROSS-SLUG" in r2.json()["qualified"][0]["reason"]

    e = dream.load_memory(mem)[0]
    assert e["slugs"] == ["-home-ubuntu-alpha", "-home-ubuntu-beta"]


def test_remember_refuses_a_denied_slug_in_an_observation(tmp_path):
    """The store is durable; a denied slug must not be writable into it."""
    mem = tmp_path / "dream-memory.jsonl"
    obs = tmp_path / "o.json"
    obs.write_text(
        json.dumps([{"key": "k", "gist": "g", "slug": "-home-ubuntu-linearb"}]),
        encoding="utf-8",
    )
    r = invoke_raw("remember", f"--observations={obs}", f"--memory={mem}")
    assert r.returncode == 2
    assert "confidential" in r.stderr.lower()
    assert not mem.exists()


def test_digest_counts_cross_slug_entries(root, tmp_path):
    mem = tmp_path / "dream-memory.jsonl"
    mem.write_text(
        "\n".join(
            json.dumps(e)
            for e in (
                {"key": "a", "count": 2, "slugs": ["-x", "-y"]},
                {"key": "b", "count": 1, "slugs": ["-x"]},
            )
        )
        + "\n",
        encoding="utf-8",
    )
    register_slug(root, make_repo(tmp_path, "alpha"))
    r = fleet(root, "--seams=offboard-history", tmp_path=tmp_path, memory=mem)
    digest = r.json()["memory_digest"]
    assert digest["n_cross_slug"] == 1
    rows = {e["key"]: e for e in digest["entries"]}
    assert rows["a"]["qualified"] is True
    assert "CROSS-SLUG" in rows["a"]["qualify_reason"]
    # the ROW SHAPE stays keys+gists+counts — no bodies, no new fields
    assert set(rows["a"]) == {
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


# --------------------------------------------------------------------------- #
# 5. Caps — fleet scope multiplies cost, so the caps are load-bearing
# --------------------------------------------------------------------------- #
def test_max_slugs_caps_iteration_newest_first(root, tmp_path):
    alpha = make_repo(tmp_path, "alpha")
    beta = make_repo(tmp_path, "beta")
    git_commit_file(
        alpha, "refs/session-handoff.md", f"# a\n{GOTCHA} in alpha\n"
    )
    git_commit_file(beta, "refs/session-handoff.md", f"# b\n{GOTCHA} in beta\n")
    sa, sb = register_slug(root, alpha), register_slug(root, beta)
    # beta's slug dir is the freshest, so it is the one that survives the cap
    os.utime(Path(root) / sa, (1_700_000_000, 1_700_000_000))
    os.utime(Path(root) / sb, (1_790_000_000, 1_790_000_000))

    r = fleet(
        root, "--seams=offboard-history", "--max-slugs=1", tmp_path=tmp_path
    )
    assert r.json()["n_slugs"] == 1
    assert [s["slug"] for s in r.json()["slugs"]] == [sb]
    assert "iterating 1 of 2 permitted slug(s)" in r.stderr
    assert any("in beta" in c["text"] for c in r.json()["candidates"])
    assert not any("in alpha" in c["text"] for c in r.json()["candidates"])


def test_max_per_slug_caps_each_slug_independently(root, tmp_path):
    """One noisy slug must not spend the whole global budget."""
    alpha = make_repo(tmp_path, "alpha")
    beta = make_repo(tmp_path, "beta")
    git_commit_file(
        alpha,
        "refs/session-handoff.md",
        "\n".join(f"{GOTCHA} alpha number {i}" for i in range(8)) + "\n",
    )
    git_commit_file(beta, "refs/session-handoff.md", f"# b\n{PREF} in beta\n")
    sa, sb = register_slug(root, alpha), register_slug(root, beta)

    r = fleet(
        root, "--seams=offboard-history", "--max-per-slug=2", tmp_path=tmp_path
    )
    per = {s["slug"]: s["n_candidates"] for s in r.json()["slugs"]}
    assert per[sa] == 2, per
    assert per[sb] >= 1, per
    # beta survives despite alpha being eight times louder
    assert any("in beta" in c["text"] for c in r.json()["candidates"])


def test_global_cap_round_robins_across_slugs(root, tmp_path):
    """--max-candidates must sample every slug, not keep the first one."""
    alpha = make_repo(tmp_path, "alpha")
    beta = make_repo(tmp_path, "beta")
    for repo, tag in ((alpha, "alpha"), (beta, "beta")):
        git_commit_file(
            repo,
            "refs/session-handoff.md",
            "\n".join(f"{GOTCHA} {tag} number {i}" for i in range(5)) + "\n",
        )
    sa, sb = register_slug(root, alpha), register_slug(root, beta)

    r = fleet(
        root,
        "--seams=offboard-history",
        "--max-candidates=2",
        tmp_path=tmp_path,
    )
    slugs = {s for c in r.json()["candidates"] for s in c["slugs"]}
    assert slugs == {sa, sb}, r.json()["candidates"]
    assert r.json()["truncated"] is True


def test_cap_defaults_are_conservative():
    """The defaults are the cost contract; changing one is a deliberate act."""
    assert dream.DEFAULT_MAX_SLUGS == 12
    assert dream.DEFAULT_MAX_PER_SLUG == 60


# --------------------------------------------------------------------------- #
# 6. --dry-run — the merge gate
# --------------------------------------------------------------------------- #
def test_dry_run_writes_nothing(root, tmp_path):
    """Full collect + plan against real fixtures, byte-identical tree after."""
    alpha = make_repo(tmp_path, "alpha")
    git_commit_file(
        alpha, "refs/session-handoff.md", f"# a\n{GOTCHA} in alpha\n"
    )
    sa = register_slug(root, alpha)
    mem = tmp_path / "absent-memory.jsonl"

    before = tree_state(tmp_path)
    r = fleet(
        root,
        "--dry-run",
        "--seams=offboard-history",
        tmp_path=tmp_path,
        memory=mem,
    )
    after = tree_state(tmp_path)

    assert r.returncode == 0, r.stderr
    assert r.json()["dry_run"] is True
    assert before == after, before ^ after
    assert not mem.exists()
    assert not (alpha / "refs" / "dream-memory.jsonl").exists()

    # and it PRINTED what it would file: repo, title, body preview
    assert "WOULD FILE" in r.stderr
    assert str(alpha) in r.stderr
    assert "propose-memory:" in r.stderr
    assert "## Proposed MEMORY entry" in r.stderr
    assert "nothing was written" in r.stderr
    assert plan_for(r, sa)["proposals"], "a dry run with candidates must plan"


def test_dry_run_write_guard_actually_bites(tmp_path):
    """The mutant test for --dry-run: with the guard armed, a write RAISES.

    Without this, "it writes nothing" is a claim about the current call graph
    rather than a property — and the next seam that learns to write would break
    it silently.
    """
    mem = tmp_path / "store.jsonl"
    dream.arm_no_write()
    try:
        with pytest.raises(dream.WriteRefused):
            dream.save_memory(mem, [{"key": "k"}])
    finally:
        dream._NO_WRITE = False
    assert not mem.exists()
    dream.save_memory(mem, [{"key": "k"}])  # control: it writes when unarmed
    assert mem.is_file()


# --------------------------------------------------------------------------- #
# 7. Reporting — searched vs found survives aggregation
# --------------------------------------------------------------------------- #
def test_seam_report_aggregates_without_conflating_searched_and_found(
    root, tmp_path
):
    """One repo-less slug must not make the seam look healthy or broken.

    ``searched`` aggregates as ANY (one scope that could look proves the
    instrument works) — and that is only OBSERVABLE when the failing scope is
    iterated LAST, because a report that simply keeps the LAST scope's value
    agrees with ANY in every other ordering. So the mtimes are pinned to put the
    broken scope at the end. Without that pin this case passed against exactly
    that defect (mutant `report-conflate` survived the first sweep).
    """
    alpha = make_repo(tmp_path, "alpha")
    git_commit_file(
        alpha, "refs/session-handoff.md", f"# a\n{GOTCHA} in alpha\n"
    )
    sa = register_slug(root, alpha)
    # a slug whose directory is gone entirely -> no repo -> cannot search
    broken = Path(root) / "-nonexistent-path-xyzzy"
    broken.mkdir()
    os.utime(Path(root) / sa, (1_790_000_000, 1_790_000_000))  # newest -> first
    os.utime(broken, (1_700_000_000, 1_700_000_000))  # oldest -> LAST

    r = fleet(root, "--seams=offboard-history", tmp_path=tmp_path)
    assert [s["slug"] for s in r.json()["slugs"]] == [sa, broken.name]
    rep = r.json()["seams"]["offboard-history"]
    assert rep["searched"] is True
    assert rep["found"] >= 1
    assert "1/2 scope(s) searched" in rep["note"]
    assert "first failure" in rep["note"]


def test_slug_to_path_resolves_dashed_and_dotted_names(tmp_path):
    """The lossy forward transform is why a naive replace('-','/') is wrong."""
    for name in ("local-coding-models", ".claude-work", "plain"):
        (tmp_path / name).mkdir()
        target = tmp_path / name
        assert dream.slug_to_path(slug_of(target)) == target


def test_slug_to_nearest_path_falls_back_to_the_parent(tmp_path):
    """A removed worktree still files into the repo it came from."""
    repo = tmp_path / "alpha"
    repo.mkdir()
    gone = slug_of(repo / ".claude" / "worktrees" / "agent-dead")
    assert dream.slug_to_path(gone) is None
    assert dream.slug_to_nearest_path(gone) == repo
