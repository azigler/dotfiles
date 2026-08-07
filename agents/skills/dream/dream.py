#!/usr/bin/env python3
"""dream helper — surface candidate durable-learning material for the tick.

Spec: ``explore-76oc`` §4.4 (Phase 4), extended by ``dotfiles-jx71``. This is the
**deterministic** half of the ``dream`` learning loop. It does the mechanical work
— window selection, source traversal, signal matching, dedupe, and recurrence
bookkeeping — and emits candidates as JSON. It makes **no judgment** about whether
a candidate is a durable learning and it files **nothing**: the LLM tick reads this
output, judges conservatively, and files human-gated proposal beads. This helper
NEVER writes MEMORY.md.

Three entry points
------------------
``dream.py [flags]``            legacy single-seam mode (session-recall only,
                                legacy JSON shape, legacy exit contract). Kept
                                byte-compatible for existing callers/tests.
``dream.py collect [flags]``    the full pipeline: every enabled **seam**, merged
                                and deduped, plus a ``memory_digest`` read from
                                the recurrence store.
``dream.py remember --observations FILE``
                                merge a tick's observations back into the
                                recurrence store (phase two of collect→remember).

Seams
-----
A **seam** is one place durable learnings leave a trace. Each seam is an
independent collector with a uniform shape — ``(candidates, searched, note)`` —
so "found nothing" is always distinguishable from "could not look" (the positive
control per seam). Seams degrade to empty rather than raising when their source
is absent.

  ``session-recall``        the original seam: ``recall.py`` over the current
                            slug's transcripts, one pass per learning-signal regex.
  ``offboard-history``      ``git log -p`` over ``refs/session-handoff*.md`` in the
                            CURRENT repo. ``/offboard`` overwrites rather than
                            appends, so the friction it recorded lives only in git.
  ``memory-history``        ``git log -p`` over the CURRENT slug's
                            ``memory/*.md`` in the claude-vault memory repo —
                            what we believed, then unbelieved.
  ``skill-history``         ``git log -p`` over ``agents/skills/*/SKILL.md`` in
                            the harness repo — which prompt wording keeps getting
                            re-fixed, i.e. harness rot.
  ``findings-corrections``  ``## Corrections`` / ``## Scrutiny`` blocks in the
                            current repo's ``*/FINDINGS.md``.

Recurrence memory
-----------------
``refs/dream-memory.jsonl`` (path via ``--memory``) records what has been observed
before: ``key``, ``gist``, ``count``, ``first_seen``, ``last_seen``, ``runs[]``,
``seams[]``, ``disposition``. ``collect`` emits it as ``memory_digest`` so the
TICK — a model, not a regex — can match a fresh observation to an existing key
semantically. ``remember`` merges the tick's observations back. The **recurrence
bar** (``qualifies``) says when an entry has earned a proposal.

Confidentiality
---------------
**CURRENT SLUG / CURRENT REPO ONLY.** ``linearb*`` / ``cfp*`` content must never
reach a pushed artifact (``feedback_linearb_beads_confidential``), and a proposal
bead is pushed. Every path a seam touches goes through :func:`guard_path`; a
confidential slug is a hard refusal. There is no ``--all`` / cross-slug mode and
one must not be added here. Set ``DREAM_PATH_AUDIT=<file>`` to record every
guarded path — that audit is how the test suite proves non-traversal.

Exit codes
----------
legacy mode: 0 = ran and emitted JSON; 2 = error.
``collect``: 0 = found candidates; 1 = searched and found nothing;
             3 = could not search (no seam was able to look); 2 = error/refusal.
``remember``: 0 = merged; 2 = error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import NamedTuple

# --------------------------------------------------------------------------- #
# Tunables
# --------------------------------------------------------------------------- #
DEFAULT_RECALL_PATH = (
    Path.home() / ".claude" / "skills" / "recall" / "recall.py"
)
DEFAULT_LOOKBACK_DAYS = (
    7  # first-run bounded window (spec §4.4a) — no all-history sweep
)
DEFAULT_MAX_CANDIDATES = (
    200  # token-blowout guard: cap what one run hands the tick
)
CANDIDATE_TEXT_LIMIT = (
    600  # trim each candidate's text; the tick re-recalls for full
)

# Git-history seams get their OWN window, independent of --since. --since is the
# session window (usually ~a week, read off the ledger); a churn history that
# short says nothing about recurrence. Measured on the live corpus: friction
# density in refs/session-handoff*.md is ~0% in May and ~45-55% by August, so the
# default deliberately favors RECENT history over all of it.
DEFAULT_HISTORY_DAYS = 90
DEFAULT_MAX_COMMITS = 400  # bound the git log fan-out per seam
DEFAULT_CHURN_MIN = 3  # a file revised >= N times in-window is itself a signal
MIN_CHANGED_LINE_CHARS = 20  # ignore trivial one-word diff lines
DEFAULT_MEMORY_DIGEST_LIMIT = 500  # cap digest entries handed to the tick

DEFAULT_MEMORY_GIT_DIR = Path.home() / ".claude" / "vaults" / "memory.git"
DEFAULT_SKILLS_REPO = Path.home() / "dotfiles"
DEFAULT_SKILL_PATHSPEC = "agents/skills/*/SKILL.md"
DEFAULT_HANDOFF_PATHSPEC = "refs/session-handoff*.md"

# Only conversational turns carry durable learnings. tool-result / unrenderable /
# structural-type hits are dropped up front — a user correction or stated
# preference lives in a user/assistant turn, never in raw tool output.
CANDIDATE_ROLES = frozenset({"user", "assistant"})


@dataclass(frozen=True)
class Signal:
    """A learning-signal pattern: a regex whose matches mark a turn as a *candidate*
    durable learning (NOT a confirmed one — the tick judges). ``name`` labels the
    candidate; ``rationale`` documents WHY this shape of turn tends to encode a
    reusable learning worth a MEMORY entry."""

    name: str
    pattern: str
    rationale: str


# The curated signal set. Deliberately RECALL-biased (favor surfacing over
# precision): a missed learning is worse than a noisy candidate, because the tick
# is a conservative human-gated filter downstream. Each pattern is a simple,
# linear (ReDoS-safe) case-insensitive alternation grounded in how the harness's
# own durable learnings actually read in the MEMORY tier.
SIGNALS: list[Signal] = [
    Signal(
        "correction",
        r"(?i)(\bactually,|\bno,? +(that|you|it|we|i|don|do not|not)\b|"
        r"that'?s +(wrong|not right|incorrect)|not what i +(meant|asked|wanted|said)|"
        r"\binstead of\b|you keep\b|stop +(doing|using|adding|calling)|"
        r"\bdon'?t +(do|use|ever|say|call|add|write|run|create)\b)",
        "A user correcting the agent is the single highest-signal durable-learning "
        "source: a correction that must never recur is exactly what a feedback_* "
        "MEMORY entry crystallizes (most of the memory tier is corrections).",
    ),
    Signal(
        "preference",
        r"(?i)(\bi +(prefer|like|want|always|never)\b|always +(use|do|prefer|run|write)|"
        r"from now on|going forward|in +(the +)?future|please +(always|don'?t|never|make sure)|"
        r"make sure +(to|you)|remember to|\bmy preference\b)",
        "Explicitly stated preferences ('always X', 'from now on Y') are durable by "
        "definition — they generalize across sessions, which is the whole point of "
        "the always-loaded memory tier.",
    ),
    Signal(
        "gotcha",
        r"(?i)(\bgotcha\b|\bfootgun\b|\bcaveat\b|\bpitfall\b|watch out|"
        r"the +(trick|catch) +is|\bsilently\b|bit me|caught me|\bbeware\b|the hard way)",
        "Hard-won gotchas / footguns save the most future time; they read as "
        "'footgun', 'silently', 'the trick is', 'bit me the hard way' — exactly the "
        "one-liners the memory tier exists to preserve.",
    ),
    Signal(
        "confirmed",
        r"(?i)(\bconfirmed\b|\bverified\b|that +(worked|fixed it)|works now|"
        r"the fix +(was|is)|root cause|\bTIL\b|learned that|turns out the)",
        "A validated approach or confirmed root-cause is a reusable 'confirmed-"
        "approach' learning worth recording so it is not rediscovered next session.",
    ),
    Signal(
        "rule",
        r"(?i)(the +(rule|convention|policy|invariant|decision) +is|by convention|"
        r"\bwe decided\b|standard +(is|practice)|must +(always|never)|as a +(rule|convention))",
        "Explicit rules / conventions / decisions ('the convention is', 'we decided') "
        "are the crystallized form a MEMORY entry ultimately takes.",
    ),
]

_COMPILED_SIGNALS = [(s.name, re.compile(s.pattern)) for s in SIGNALS]


def match_signals(text: str) -> list[str]:
    """Every signal name whose pattern matches ``text`` (sorted, deduped)."""
    return sorted(name for name, rx in _COMPILED_SIGNALS if rx.search(text))


class DreamError(Exception):
    """A recoverable error that maps to exit code 2 (bad recall run / bad input)."""


class ConfidentialPathError(DreamError):
    """A path under a confidential project was about to be traversed. Hard stop."""


# --------------------------------------------------------------------------- #
# Confidentiality guard
# --------------------------------------------------------------------------- #
# `linearb*` / `cfp*` content must never reach a pushed artifact
# (feedback_linearb_beads_confidential), and every proposal bead this loop's tick
# files IS pushed. The seam sizes quoted in dotfiles-jx71 were measured
# FLEET-WIDE; that was a measurement, not a licence to traverse. So every path any
# seam touches funnels through guard_path() before it is opened, globbed, or
# handed to git.
CONFIDENTIAL_PREFIXES = ("linearb", "cfp")


def path_tokens(value: object) -> list[str]:
    """Split a path/slug into alphanumeric tokens.

    Both layouts must tokenize the same way, because both are real inputs:
    ``/home/ubuntu/linearb/refs/x.md`` and the slug ``-home-ubuntu-linearb``.
    """
    return [t for t in re.split(r"[^A-Za-z0-9]+", str(value)) if t]


def is_confidential_path(value: object) -> bool:
    """True if any path component names a confidential project (``linearb*``/``cfp*``).

    Prefix matching, not equality: ``linearb-notes``, ``cfp2026`` and the slug
    ``-home-ubuntu-cfp`` are all confidential. Deliberately over-broad — a false
    positive costs one skipped file, a false negative pushes confidential content
    off-box.
    """
    return any(
        t.lower().startswith(CONFIDENTIAL_PREFIXES) for t in path_tokens(value)
    )


def _audit_sink() -> Path | None:
    p = os.environ.get("DREAM_PATH_AUDIT")
    return Path(p) if p else None


def audit_path(value: object, kind: str = "read") -> None:
    """Record a traversed path when ``DREAM_PATH_AUDIT`` is set.

    This exists so a test can prove a NEGATIVE (no ``linearb*``/``cfp*`` path was
    ever touched) with a positive control in the same file (the explore paths that
    WERE touched). A probe that can only report failure cannot tell "closed" from
    "broken".
    """
    sink = _audit_sink()
    if sink is None:
        return
    try:
        sink.parent.mkdir(parents=True, exist_ok=True)
        with open(sink, "a", encoding="utf-8") as fh:
            fh.write(f"{kind}\t{value}\n")
    except OSError:
        pass


AUDIT_REFUSED = "REFUSED"


def guard_path(value: object, kind: str = "read") -> str:
    """Raise if ``value`` names a confidential project; audit it either way.

    Order matters: a refusal is audited as ``REFUSED:<kind>`` and a permitted
    traversal as ``<kind>``, so the audit log distinguishes *what was read* from
    *what the guard stopped*. The test suite reads it both ways — no permitted
    line may name a confidential project (the negative), and the REFUSED line
    proves the guard actually fired rather than the path merely being absent
    (the positive control).
    """
    if is_confidential_path(value):
        audit_path(value, f"{AUDIT_REFUSED}:{kind}")
        raise ConfidentialPathError(
            f"refusing to traverse confidential path: {value} "
            "(linearb*/cfp* content must never reach a pushed artifact)"
        )
    audit_path(value, kind)
    return str(value)


def safe_paths(values: Iterable[object], kind: str = "read") -> list[str]:
    """Filter an iterable of paths, dropping (not raising on) confidential ones.

    Used where a source legitimately mixes projects — a repo that happens to hold
    a ``linearb-*`` subdir. The refusal is per-path so the rest of the seam still
    works.
    """
    out: list[str] = []
    for v in values:
        try:
            out.append(guard_path(v, kind))
        except ConfidentialPathError as exc:
            sys.stderr.write(f"dream: {exc}\n")
    return out


# --------------------------------------------------------------------------- #
# Time + slug helpers
# --------------------------------------------------------------------------- #
def parse_since(value: str) -> datetime:
    """Parse an ISO-8601 ``--since`` (``2026-07-01T00:00:00Z`` or a bare
    ``2026-07-01``) into an aware UTC datetime. Raises ``ValueError`` on garbage."""
    s = value.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        # bare date -> midnight UTC
        dt = datetime.fromisoformat(s + "T00:00:00+00:00")
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt


def iso_z(dt: datetime) -> str:
    """Render an aware datetime as a ``...Z`` UTC ISO string."""
    return dt.astimezone(UTC).isoformat().replace("+00:00", "Z")


def current_slug_from_cwd() -> str:
    """Claude keys projects by a cwd-derived slug (mirror of recall.py):
    '/home/ubuntu/explore' -> '-home-ubuntu-explore'."""
    return re.sub(r"[^A-Za-z0-9]", "-", os.getcwd())


def resolve_root(arg_root: str | None) -> str:
    """The projects root(s) to hand recall.py, as an os.pathsep-joined string.

    ⚠️ MUST stay multi-valued. `/dream` runs UNJAILED, but the pulse loops it
    consolidates (`dive`, `digest`) run inside the tick-jail, which relocates
    their whole config tree via CLAUDE_CONFIG_DIR (default `~/.claude-tick`).
    A single-rooted `--root=~/.claude/projects` silently excluded every jailed
    loop from the weekly consolidation and still reported success, because a
    missing vault is indistinguishable from a quiet week (`explore-jkc6`).

    Passing a single value here would ALSO defeat recall.py's own multi-root
    discovery, since an explicit --root wins outright. So join them.
    """
    if arg_root is not None:
        return arg_root
    env_root = os.environ.get("CLAUDE_PROJECTS_ROOT")
    if env_root:
        return env_root

    roots = [Path.home() / ".claude" / "projects"]
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    if cfg:
        roots.insert(0, Path(cfg) / "projects")
    tick = os.environ.get("TICK_JAIL_CONFIG_DIR") or str(
        Path.home() / ".claude-tick"
    )
    roots.append(Path(tick) / "projects")

    seen: set[str] = set()
    out: list[str] = []
    for r in roots:
        s = str(r.expanduser())
        if s in seen or not Path(s).is_dir():
            continue
        seen.add(s)
        out.append(s)
    return (
        os.pathsep.join(out)
        if out
        else str(Path.home() / ".claude" / "projects")
    )


def resolve_recall(arg_recall: str | None) -> Path:
    if arg_recall is not None:
        return Path(arg_recall)
    env_recall = os.environ.get("DREAM_RECALL")
    if env_recall:
        return Path(env_recall)
    return DEFAULT_RECALL_PATH


# --------------------------------------------------------------------------- #
# Window selection (session-level, by file mtime)
# --------------------------------------------------------------------------- #
def session_id_of(slug_dir: Path, f: Path) -> str:
    """The session id recall.py would emit for ``f`` — mirror of recall's
    ``session_of``: the file stem for a top-level log, else the first path
    component (the ``<uuid>`` dir that owns the subagent / tool-result)."""
    rel = f.relative_to(slug_dir)
    parts = rel.parts
    return f.stem if len(parts) == 1 else parts[0]


_SCAN_CACHE: dict[tuple, tuple[set[str], set[str], dict[str, float]]] = {}


def scan_window(
    root: Path, slug: str, since_epoch: float
) -> tuple[set[str], set[str], dict[str, float]]:
    """Return ``(all_sessions, in_window_sessions, session_mtimes)`` for ``slug``.

    A session is in-window if ANY of its files (main jsonl, subagent jsonl, or
    tool-results txt) has mtime >= ``since_epoch`` — session-level so a still-active
    long session is scanned in full.

    ``session_mtimes`` maps session id -> newest file mtime, which is what lets the
    caller order sessions by RECENCY. Without it the candidate cap fell back to
    alphabetical-by-UUID (``explore-j2p9``)."""
    # `root` may be a single Path or several (the jailed vault is a separate tree —
    # see resolve_root; explore-jkc6). Normalize and union across all of them.
    roots = root if isinstance(root, (list, tuple)) else [root]
    cache_key = (tuple(str(r) for r in roots), slug, since_epoch)
    cached = _SCAN_CACHE.get(cache_key)
    if cached is not None:
        return cached

    all_sessions: set[str] = set()
    in_window: set[str] = set()
    mtimes: dict[str, float] = {}

    for r in roots:
        slug_dir = Path(r) / slug
        # The ONLY directory this helper ever walks for transcripts. Audited so a
        # test can prove no confidential slug dir is reached.
        guard_path(slug_dir, "slug-dir")
        if not slug_dir.is_dir():
            continue

        def consider(p: Path, slug_dir: Path = slug_dir) -> None:
            sid = session_id_of(slug_dir, p)
            all_sessions.add(sid)
            try:
                m = p.stat().st_mtime
            except OSError:
                return
            if m > mtimes.get(sid, 0.0):
                mtimes[sid] = m
            if m >= since_epoch:
                in_window.add(sid)

        for p in slug_dir.rglob("*.jsonl"):
            if p.is_file():
                consider(p)
        for p in slug_dir.rglob("*.txt"):
            if p.is_file() and p.parent.name == "tool-results":
                consider(p)

    result = (all_sessions, in_window, mtimes)
    _SCAN_CACHE[cache_key] = result
    return result


# --------------------------------------------------------------------------- #
# recall.py subprocess bridge
# --------------------------------------------------------------------------- #
def run_recall(
    recall_path: Path, python: str, pattern: str, slug: str, root: Path
) -> list[dict]:
    """Invoke ``recall.py`` for one signal pattern over ``slug`` and return its
    ``--json`` hits. recall exit 1 (no hits) still prints ``[]`` -> empty list;
    exit 2 (recall error) -> ``DreamError``."""
    cmd = [
        python,
        str(recall_path),
        pattern,
        "--regex",
        f"--slug={slug}",
        "--json",
        # root may be several vaults; recall.py accepts an os.pathsep-joined list.
        "--root="
        + os.pathsep.join(
            str(p)
            for p in (root if isinstance(root, (list, tuple)) else [root])
        ),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode == 2:
        raise DreamError(
            f"recall.py failed (exit 2) for pattern {pattern!r}: "
            f"{proc.stderr.strip() or '(no stderr)'}"
        )
    out = (proc.stdout or "").strip()
    if not out:
        return []
    try:
        data = json.loads(out)
    except json.JSONDecodeError as exc:
        raise DreamError(f"recall.py emitted invalid JSON: {exc}") from exc
    if not isinstance(data, list):
        raise DreamError("recall.py --json did not emit a JSON array")
    return data


# --------------------------------------------------------------------------- #
# Candidate gathering (grep -> window/role filter -> dedupe -> cap)
# --------------------------------------------------------------------------- #
def _trim(text: str) -> str:
    if len(text) > CANDIDATE_TEXT_LIMIT:
        return text[:CANDIDATE_TEXT_LIMIT] + "…"
    return text


def gather_candidates(
    root: Path,
    slug: str,
    since_epoch: float,
    recall_path: Path,
    python: str,
    max_candidates: int,
) -> tuple[set[str], set[str], list[dict], bool]:
    """Run every signal pattern, then window- + role-filter and dedupe the hits.

    Dedupe key is ``(session, line)``: a turn matched by multiple signals collapses
    to ONE candidate whose ``signals`` list carries every matching signal name."""
    all_sessions, in_window, session_mtimes = scan_window(
        root, slug, since_epoch
    )

    agg: dict[tuple[str, object], dict] = {}
    for sig in SIGNALS:
        for hit in run_recall(recall_path, python, sig.pattern, slug, root):
            if hit.get("role") not in CANDIDATE_ROLES:
                continue
            session = hit.get("session")
            if session not in in_window:
                continue
            key = (session, hit.get("line"))
            entry = agg.get(key)
            if entry is None:
                entry = {
                    "slug": hit.get("slug", slug),
                    "session": session,
                    "ts": hit.get("ts", ""),
                    "role": hit.get("role"),
                    "line": hit.get("line"),
                    "text": _trim(hit.get("text") or ""),
                    "signals": set(),
                }
                agg[key] = entry
            entry["signals"].add(sig.name)

    candidates: list[dict] = []
    for entry in agg.values():
        out = dict(entry)
        out["signals"] = sorted(entry["signals"])
        candidates.append(out)

    # ⚠️ ROUND-ROBIN ACROSS SESSIONS, THEN CAP — never sort-then-truncate.
    #
    # The previous form sorted by session UUID (an ARBITRARY alphabetical order with
    # no relation to recency) and then truncated at max_candidates. That does not
    # sample the window, it keeps whichever sessions happen to sort first. Measured on
    # the 2026-07-26 tick: 67 in-window sessions, 200 candidates emitted, and the
    # distinct sessions represented in those 200 was **1** — the alphabetically-first
    # UUID. 1.5% coverage, reported as a clean `done` (explore-j2p9).
    #
    # Interleaving by session guarantees every in-window session is represented before
    # any session gets a second slot, so the cap degrades breadth gracefully instead of
    # silently collapsing to one session. Within a session, keep line order.
    by_session: dict[str, list] = {}
    for c in candidates:
        by_session.setdefault(str(c["session"]), []).append(c)
    for sess in by_session.values():
        sess.sort(key=lambda c: c["line"] if isinstance(c["line"], int) else 0)

    # Most-recently-modified session first, so a truncated run keeps the freshest work.
    order = sorted(
        by_session,
        key=lambda s: (-session_mtimes.get(s, 0.0), s),
    )

    interleaved: list = []
    idx = 0
    while len(interleaved) < len(candidates):
        added = False
        for s in order:
            bucket = by_session[s]
            if idx < len(bucket):
                interleaved.append(bucket[idx])
                added = True
        if not added:
            break
        idx += 1
    candidates = interleaved

    truncated = len(candidates) > max_candidates
    dropped_sessions = 0
    if truncated:
        kept = candidates[:max_candidates]
        kept_sessions = {str(c["session"]) for c in kept}
        dropped_sessions = len(by_session) - len(kept_sessions)
        candidates = kept
        # A bare `"truncated": true` is what let 1.5% coverage read as success. Say
        # how much of the window actually survived, loudly, on stderr.
        sys.stderr.write(
            f"dream: TRUNCATED to {max_candidates} candidates — "
            f"{len(kept_sessions)} of {len(by_session)} in-window sessions represented"
            + (
                f", {dropped_sessions} session(s) DROPPED ENTIRELY"
                if dropped_sessions
                else ""
            )
            + "\n"
        )
    return all_sessions, in_window, candidates, truncated


def build_output(
    slug: str,
    since_dt: datetime,
    all_sessions: set[str],
    in_window: set[str],
    candidates: list[dict],
    truncated: bool,
) -> dict:
    return {
        "since": iso_z(since_dt),
        "slug": slug,
        "scanned_sessions": len(all_sessions),
        "window_sessions": len(in_window),
        "n_candidates": len(candidates),
        "truncated": truncated,
        "candidates": candidates,
    }


# --------------------------------------------------------------------------- #
# git plumbing (never chdir — always an explicit -C / --git-dir base)
# --------------------------------------------------------------------------- #
NUL = "\x01"  # record separator we ask git to emit before each commit header
FS = "\x1f"  # field separator inside that header

_DIFF_NOISE_PREFIXES = (
    "+++",
    "---",
    "@@",
    "diff --git",
    "index ",
    "new file mode",
    "deleted file mode",
    "similarity index",
    "rename from",
    "rename to",
    "old mode",
    "new mode",
    "Binary files",
    "\\ No newline",
)


def git_available() -> bool:
    return shutil.which("git") is not None


def run_git(
    base: Sequence[str], args: Sequence[str], timeout: int = 180
) -> tuple[int, str, str]:
    """Run git with an explicit repo base (``-C <path>`` or ``--git-dir=…``).

    Never chdir()s the process: a global chdir in a helper that also globs
    relative paths is how a "current repo only" guarantee quietly stops being one.
    """
    cmd = ["git", "--no-pager", *base, *args]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            errors="replace",
            check=False,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, "", str(exc)
    return proc.returncode, proc.stdout or "", proc.stderr or ""


def git_toplevel(path: Path) -> Path | None:
    """The work-tree root containing ``path``, or None if it is not a git repo."""
    guard_path(path, "repo")
    if not git_available() or not Path(path).is_dir():
        return None
    rc, out, _ = run_git(["-C", str(path)], ["rev-parse", "--show-toplevel"])
    if rc != 0:
        return None
    top = out.strip()
    return Path(top) if top else None


class GitBase(NamedTuple):
    """How to address a repo: an argv prefix plus a human label for notes."""

    args: list[str]
    label: str


def repo_base(path: Path) -> GitBase:
    return GitBase(["-C", str(path)], str(path))


def detached_base(git_dir: Path, work_tree: Path) -> GitBase:
    """The claude-vault layout: a bare .git elsewhere, work-tree at ~/.claude/projects.

    ``memory.git`` deliberately does NOT live inside its work tree (git-init'ing
    that tree breaks the layout), so ``-C`` cannot reach it.
    """
    return GitBase(
        [f"--git-dir={git_dir}", f"--work-tree={work_tree}"], str(git_dir)
    )


def git_repo_ok(base: GitBase) -> bool:
    if not git_available():
        return False
    rc, out, _ = run_git(base.args, ["rev-parse", "--is-inside-work-tree"])
    if rc == 0 and out.strip() == "true":
        return True
    rc, _, _ = run_git(base.args, ["rev-parse", "--git-dir"])
    return rc == 0


# --------------------------------------------------------------------------- #
# Seam interface
# --------------------------------------------------------------------------- #
class SeamResult(NamedTuple):
    """The uniform collector shape.

    ``searched`` is the POSITIVE CONTROL and is reported separately from
    ``len(candidates)`` on purpose: a seam that looked and found nothing is a
    quiet week; a seam that could not look is a broken instrument, and a shape
    that conflates them reports the second as the first forever.
    """

    candidates: list[dict]
    searched: bool
    note: str


@dataclass
class SeamContext:
    """Everything a seam may read. Frozen-by-convention; seams never mutate it."""

    slug: str
    roots: list[Path]
    since_dt: datetime
    history_since: datetime
    recall_path: Path
    python: str = sys.executable
    max_candidates: int = DEFAULT_MAX_CANDIDATES
    max_commits: int = DEFAULT_MAX_COMMITS
    churn_min: int = DEFAULT_CHURN_MIN
    repo: Path | None = None
    skills_repo: Path | None = None
    memory_git_dir: Path | None = None
    handoff_pathspec: str = DEFAULT_HANDOFF_PATHSPEC
    skill_pathspec: str = DEFAULT_SKILL_PATHSPEC
    stats: dict = field(default_factory=dict)

    @property
    def since_epoch(self) -> float:
        return self.since_dt.timestamp()


def _candidate(
    seam: str,
    text: str,
    signals: Sequence[str],
    ts: str,
    source: str,
    detail: dict | None = None,
) -> dict:
    """The canonical cross-seam candidate shape."""
    return {
        "seams": [seam],
        "signals": sorted(set(signals)),
        "ts": ts or "",
        "text": _trim(text),
        "source": source,
        "n_sources": 1,
        "detail": detail or {},
    }


def _norm_key(text: str) -> str:
    """Dedupe key: case- and whitespace-insensitive prefix hash.

    Used both WITHIN a seam (a handoff line rewritten weekly recurs verbatim) and
    ACROSS seams (the same lesson recorded in a skill diff and a FINDINGS block).
    Cross-seam collapse is what makes the ">= 2 distinct seams in one run" half of
    the recurrence bar computable at all.
    """
    norm = re.sub(r"\s+", " ", text.strip().lower())
    # Strip leading markdown decoration: the SAME sentence is a bullet in a
    # memory file, a plain line in a handoff note, and a blockquote in a SKILL.md.
    # Without this the cross-seam collapse silently never fires.
    norm = re.sub(r"^[\s>*+\-#•]+", "", norm)[:200]
    return hashlib.sha1(norm.encode("utf-8")).hexdigest()


# --- seam 1: session-recall (the original, unchanged in behaviour) ---------- #
def seam_session_recall(ctx: SeamContext) -> SeamResult:
    live_roots = [p for p in ctx.roots if Path(p).is_dir()]
    if not live_roots:
        return SeamResult([], False, "no projects root exists")
    if not Path(ctx.recall_path).is_file():
        return SeamResult(
            [], False, f"recall.py not found at {ctx.recall_path}"
        )
    try:
        all_sessions, in_window, cands, truncated = gather_candidates(
            live_roots,
            ctx.slug,
            ctx.since_epoch,
            Path(ctx.recall_path),
            ctx.python,
            ctx.max_candidates,
        )
    except ConfidentialPathError:
        raise
    except DreamError as exc:
        return SeamResult([], False, f"recall failed: {exc}")

    ctx.stats["scanned_sessions"] = len(all_sessions)
    ctx.stats["window_sessions"] = len(in_window)
    ctx.stats["session_recall_truncated"] = truncated

    out = [
        _candidate(
            "session-recall",
            c["text"],
            c["signals"],
            c.get("ts", ""),
            f"session {c.get('session')} line {c.get('line')}",
            {
                "slug": c.get("slug"),
                "session": c.get("session"),
                "role": c.get("role"),
                "line": c.get("line"),
            },
        )
        for c in cands
    ]
    note = (
        f"{len(all_sessions)} sessions scanned, {len(in_window)} in-window"
        + (", TRUNCATED" if truncated else "")
    )
    return SeamResult(out, True, note)


# --- the shared git-history collector (3 seams stand on this) --------------- #
def _iter_commits(log_text: str):
    """Yield ``(sha, iso_ts, subject, [diff lines])`` from a ``log -p`` dump."""
    sha = ts = subject = None
    body: list[str] = []
    for line in log_text.split("\n"):
        if line.startswith(NUL):
            if sha is not None:
                yield sha, ts, subject, body
            parts = line[1:].split(FS)
            sha = parts[0] if parts else ""
            ts = parts[1] if len(parts) > 1 else ""
            subject = parts[2] if len(parts) > 2 else ""
            body = []
        elif sha is not None:
            body.append(line)
    if sha is not None:
        yield sha, ts, subject, body


def _changed_lines(diff: Sequence[str]):
    """Yield ``(path, change, text)`` for real +/- content lines in a diff."""
    current = "?"
    for raw in diff:
        if raw.startswith("+++ b/"):
            current = raw[6:].strip()
            continue
        if any(raw.startswith(p) for p in _DIFF_NOISE_PREFIXES):
            continue
        if raw.startswith("+") or raw.startswith("-"):
            text = raw[1:].strip()
            if len(text) < MIN_CHANGED_LINE_CHARS:
                continue
            yield current, ("added" if raw[0] == "+" else "removed"), text


def collect_git_history(
    ctx: SeamContext,
    seam: str,
    base: GitBase,
    pathspecs: Sequence[str],
    churn_min: int | None = None,
) -> SeamResult:
    """Mine a git history for durable-learning signal.

    Two kinds of candidate come out:
      * **changed lines** matching a learning signal — the friction itself, which
        for ``/offboard`` notes exists ONLY here (the note is overwritten each
        session, so the log is the only append-only copy); and
      * **churn** — a file revised >= ``churn_min`` times in-window. Nothing in a
        single revision says "this keeps getting re-fixed"; the count does. That
        is harness rot, stated directly.
    """
    if not git_available():
        return SeamResult([], False, "git not on PATH")
    if not git_repo_ok(base):
        return SeamResult([], False, f"not a git repo: {base.label}")

    specs = safe_paths(pathspecs, f"{seam}:pathspec")
    if not specs:
        return SeamResult([], False, "no permitted pathspec")

    args = [
        "log",
        f"--max-count={ctx.max_commits}",
        f"--since={iso_z(ctx.history_since)}",
        "--no-color",
        "-U0",
        "-p",
        f"--pretty=format:{NUL}%H{FS}%aI{FS}%s",
        "--",
        *specs,
    ]
    rc, out, err = run_git(base.args, args)
    if rc != 0:
        return SeamResult(
            [], False, f"git log failed (rc={rc}): {err.strip()[:200]}"
        )

    # (key -> candidate) so a line repeated across revisions collapses, carrying
    # the occurrence count — that repetition IS the recurrence signal.
    agg: dict[str, dict] = {}
    churn: dict[str, list[str]] = {}
    n_commits = 0

    for sha, ts, subject, diff in _iter_commits(out):
        n_commits += 1
        short = (sha or "")[:8]
        subj = subject or ""
        sig = match_signals(subj)
        if sig:
            key = _norm_key(subj)
            entry = agg.get(key)
            if entry is None:
                agg[key] = _candidate(
                    seam,
                    subj,
                    sig,
                    ts or "",
                    f"{short} (commit subject)",
                    {"commit": sha, "kind": "subject"},
                )
            else:
                entry["detail"]["occurrences"] = (
                    entry["detail"].get("occurrences", 1) + 1
                )

        seen_files: set[str] = set()
        for path, change, text in _changed_lines(diff):
            if is_confidential_path(path):
                continue
            if path not in seen_files:
                seen_files.add(path)
                churn.setdefault(path, []).append(f"{short} {subj}")
            sigs = match_signals(text)
            if not sigs:
                continue
            key = _norm_key(text)
            entry = agg.get(key)
            if entry is None:
                agg[key] = _candidate(
                    seam,
                    text,
                    sigs,
                    ts or "",
                    f"{short} {path} ({change})",
                    {
                        "commit": sha,
                        "file": path,
                        "change": change,
                        "kind": "diff-line",
                        "occurrences": 1,
                    },
                )
            else:
                entry["detail"]["occurrences"] = (
                    entry["detail"].get("occurrences", 1) + 1
                )

    cmin = ctx.churn_min if churn_min is None else churn_min
    for path, subjects in sorted(churn.items()):
        if len(subjects) < cmin:
            continue
        agg[f"churn::{seam}::{path}"] = _candidate(
            seam,
            f"{path} revised {len(subjects)}x in window: "
            + "; ".join(subjects[:6]),
            ["churn"],
            "",
            f"{path} ({len(subjects)} revisions)",
            {
                "file": path,
                "kind": "churn",
                "revisions": len(subjects),
                "subjects": subjects[:12],
            },
        )

    cands = sorted(
        agg.values(),
        key=lambda c: (
            -int(c["detail"].get("revisions", 0)),
            -int(c["detail"].get("occurrences", 1)),
            c["ts"],
        ),
    )
    truncated = len(cands) > ctx.max_candidates
    if truncated:
        cands = cands[: ctx.max_candidates]
    note = (
        f"{n_commits} commit(s) over {len(churn)} file(s) since "
        f"{iso_z(ctx.history_since)}" + (", TRUNCATED" if truncated else "")
    )
    return SeamResult(cands, True, note)


# --- seam 2: offboard-history ---------------------------------------------- #
def seam_offboard_history(ctx: SeamContext) -> SeamResult:
    if ctx.repo is None:
        return SeamResult([], False, "no current repo resolved")
    return collect_git_history(
        ctx,
        "offboard-history",
        repo_base(ctx.repo),
        [ctx.handoff_pathspec],
    )


# --- seam 3: memory-history ------------------------------------------------- #
def seam_memory_history(ctx: SeamContext) -> SeamResult:
    """Git history of the CURRENT slug's memory files.

    Scoped by pathspec to ``<slug>/memory`` — the vault holds every slug, and
    walking it unscoped is exactly the cross-slug sweep the confidentiality rule
    forbids. The pathspec goes through the guard too, so a confidential slug can
    never be built into one.
    """
    git_dir = ctx.memory_git_dir or DEFAULT_MEMORY_GIT_DIR
    work_trees = [Path(r) for r in ctx.roots]
    bases: list[GitBase] = []
    if Path(git_dir).is_dir() and work_trees:
        bases.append(detached_base(Path(git_dir), work_trees[0]))
    for r in work_trees:
        top = git_toplevel(Path(r))
        if top is not None:
            bases.append(repo_base(top))
    if not bases:
        return SeamResult(
            [], False, f"no memory vault repo (tried {git_dir} and the roots)"
        )

    spec = f"{ctx.slug}/memory"
    guard_path(spec, "memory-pathspec")
    last = SeamResult([], False, "no memory vault repo")
    for base in bases:
        res = collect_git_history(
            ctx, "memory-history", base, [spec], churn_min=2
        )
        if res.searched:
            return res
        last = res
    return last


# --- seam 4: skill-history -------------------------------------------------- #
def seam_skill_history(ctx: SeamContext) -> SeamResult:
    repo = ctx.skills_repo or DEFAULT_SKILLS_REPO
    if not Path(repo).is_dir():
        return SeamResult([], False, f"skills repo not found: {repo}")
    return collect_git_history(
        ctx, "skill-history", repo_base(Path(repo)), [ctx.skill_pathspec]
    )


# --- seam 5: findings-corrections ------------------------------------------ #
_FINDINGS_BLOCK_RE = re.compile(
    r"^(#{2,3})[ \t]*(Corrections?|Scrutiny)\b.*$", re.MULTILINE
)


def extract_correction_blocks(text: str) -> list[tuple[str, str]]:
    """Return ``(heading, body)`` for each ``## Corrections`` / ``## Scrutiny`` block.

    A block runs from its heading to the next heading at the SAME level or higher,
    so a nested ``### …`` inside a correction stays part of it.
    """
    out: list[tuple[str, str]] = []
    matches = list(_FINDINGS_BLOCK_RE.finditer(text))
    for m in matches:
        level = len(m.group(1))
        start = m.end()
        end = len(text)
        for nxt in re.finditer(r"^(#{1,6})[ \t]", text[start:], re.MULTILINE):
            if len(nxt.group(1)) <= level:
                end = start + nxt.start()
                break
        out.append((m.group(0).strip(), text[start:end].strip()))
    return out


def seam_findings_corrections(ctx: SeamContext) -> SeamResult:
    if ctx.repo is None or not Path(ctx.repo).is_dir():
        return SeamResult([], False, "no current repo resolved")
    repo = Path(ctx.repo)
    guard_path(repo, "findings-repo")

    files = safe_paths(sorted(repo.glob("*/FINDINGS.md")), "findings")
    cands: list[dict] = []
    for f in files:
        try:
            body = Path(f).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        rel = str(Path(f).relative_to(repo))
        for heading, block in extract_correction_blocks(body):
            if not block:
                continue
            sigs = match_signals(block) or ["correction-block"]
            cands.append(
                _candidate(
                    "findings-corrections",
                    f"{heading}\n{block}",
                    sigs,
                    "",
                    f"{rel} :: {heading}",
                    {"file": rel, "heading": heading, "kind": "findings-block"},
                )
            )
    truncated = len(cands) > ctx.max_candidates
    if truncated:
        cands = cands[: ctx.max_candidates]
    note = f"{len(files)} FINDINGS.md scanned" + (
        ", TRUNCATED" if truncated else ""
    )
    return SeamResult(cands, True, note)


SEAMS: dict[str, Callable[[SeamContext], SeamResult]] = {
    "session-recall": seam_session_recall,
    "offboard-history": seam_offboard_history,
    "memory-history": seam_memory_history,
    "skill-history": seam_skill_history,
    "findings-corrections": seam_findings_corrections,
}
SEAM_ORDER = list(SEAMS)


def parse_seams(value: str | None) -> list[str]:
    """Parse ``--seams a,b,c``. ``None``/``all`` -> every seam, in canonical order."""
    if value is None or value.strip().lower() in {"", "all"}:
        return list(SEAM_ORDER)
    names = [n.strip() for n in value.split(",") if n.strip()]
    unknown = [n for n in names if n not in SEAMS]
    if unknown:
        raise DreamError(
            f"unknown seam(s): {', '.join(unknown)}. "
            f"Known: {', '.join(SEAM_ORDER)}"
        )
    # canonical order, deduped
    return [n for n in SEAM_ORDER if n in set(names)]


def run_seams(
    ctx: SeamContext, names: Sequence[str]
) -> tuple[dict[str, dict], list[dict]]:
    """Run each named seam, then merge + dedupe across seams.

    Returns ``(per_seam_report, merged_candidates)``. The report keeps ``searched``
    and ``found`` as separate fields — never collapse them.
    """
    report: dict[str, dict] = {}
    merged: dict[str, dict] = {}
    order: list[str] = []

    for name in names:
        fn = SEAMS[name]
        try:
            res = fn(ctx)
        except ConfidentialPathError as exc:
            res = SeamResult([], False, f"refused: {exc}")
            sys.stderr.write(f"dream: {name}: {exc}\n")
        except DreamError as exc:
            res = SeamResult([], False, f"error: {exc}")
        report[name] = {
            "searched": bool(res.searched),
            "found": len(res.candidates),
            "note": res.note,
        }
        for cand in res.candidates:
            key = _norm_key(cand["text"])
            existing = merged.get(key)
            if existing is None:
                merged[key] = cand
                order.append(key)
                continue
            # Same text, second seam: this is the cross-seam corroboration the
            # recurrence bar's ">= 2 distinct seams in one run" clause reads.
            existing["seams"] = sorted(
                set(existing["seams"]) | set(cand["seams"])
            )
            existing["signals"] = sorted(
                set(existing["signals"]) | set(cand["signals"])
            )
            existing["n_sources"] += 1
            existing["detail"].setdefault("also_seen", []).append(
                cand["source"]
            )

    return report, [merged[k] for k in order]


def interleave_by_seam(
    candidates: list[dict], cap: int
) -> tuple[list[dict], bool]:
    """Round-robin across seams, THEN cap — never sort-then-truncate.

    Same defect class as ``explore-j2p9``: truncating a concatenated list keeps
    whichever seam happens to run first and silently drops the rest, while
    reporting a clean run.
    """
    buckets: dict[str, list[dict]] = {}
    for c in candidates:
        buckets.setdefault(c["seams"][0], []).append(c)
    order = [s for s in SEAM_ORDER if s in buckets] + [
        s for s in buckets if s not in SEAM_ORDER
    ]
    out: list[dict] = []
    idx = 0
    while len(out) < len(candidates):
        added = False
        for s in order:
            b = buckets[s]
            if idx < len(b):
                out.append(b[idx])
                added = True
        if not added:
            break
        idx += 1
    truncated = len(out) > cap
    if truncated:
        kept = out[:cap]
        kept_seams = {c["seams"][0] for c in kept}
        sys.stderr.write(
            f"dream: TRUNCATED to {cap} candidates — "
            f"{len(kept_seams)} of {len(buckets)} seams represented\n"
        )
        out = kept
    return out, truncated


# --------------------------------------------------------------------------- #
# Recurrence memory (refs/dream-memory.jsonl)
# --------------------------------------------------------------------------- #
DISPOSITIONS = ("observed", "proposed", "promoted", "rejected")


def default_memory_path(repo: Path | None) -> Path:
    root = Path(repo) if repo is not None else Path.cwd()
    return root / "refs" / "dream-memory.jsonl"


def load_memory(path: Path) -> list[dict]:
    """Read the recurrence store. A missing file is an empty store, not an error."""
    p = Path(path)
    guard_path(p, "memory-store")
    if not p.is_file():
        return []
    entries: list[dict] = []
    for i, line in enumerate(
        p.read_text(encoding="utf-8", errors="replace").splitlines(), 1
    ):
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError as exc:
            raise DreamError(f"{p}:{i}: invalid JSON: {exc}") from exc
        if isinstance(rec, dict) and rec.get("key"):
            entries.append(rec)
    return entries


def save_memory(path: Path, entries: Sequence[dict]) -> None:
    """Atomic rewrite (temp + os.replace) — a half-written store is worse than none."""
    p = Path(path)
    guard_path(p, "memory-store-write")
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        for e in entries:
            fh.write(json.dumps(e, sort_keys=True) + "\n")
    os.replace(tmp, p)


def qualifies(entry: dict) -> tuple[bool, str]:
    """The RECURRENCE BAR — when has an observation earned a proposal?

    Qualifies when EITHER:
      * it has been seen in ``>= 2`` **distinct runs** (recurrence over time), OR
      * it was seen in ``>= 2`` **distinct seams within one run** (corroboration
        across independent sources).

    Suppressions:
      * ``rejected`` stays suppressed until its count **doubles** after the
        rejection — a human said no once, and re-asking on the next sighting is
        how a propose-only loop trains its reviewer to ignore it;
      * ``promoted`` stays suppressed outright — re-proposing shipped work is the
        ``project_golem_phantom_backlog`` failure.
    """
    disposition = entry.get("disposition") or "observed"
    count = int(entry.get("count") or 0)

    if disposition == "promoted":
        return False, "already promoted — do not re-propose"
    if disposition == "rejected":
        at = int(entry.get("rejected_at_count") or count or 1)
        if count < at * 2:
            return (
                False,
                f"rejected at count {at}; suppressed until count >= {at * 2} (now {count})",
            )
        return True, f"rejected at count {at} but has since doubled to {count}"

    runs = [r for r in (entry.get("runs") or []) if r]
    if len(set(runs)) >= 2:
        return True, f"recurred across {len(set(runs))} distinct runs"

    run_seams = entry.get("run_seams") or {}
    for run, seams in run_seams.items():
        if len(set(seams or [])) >= 2:
            return (
                True,
                f"seen in {len(set(seams))} distinct seams in one run ({run})",
            )

    return False, "single run, single seam — below the recurrence bar"


def memory_digest(
    entries: Sequence[dict], limit: int = DEFAULT_MEMORY_DIGEST_LIMIT
) -> dict:
    """The compact view the TICK matches new observations against.

    Keys + gists + counts ONLY — never the full body. The tick (a model) does the
    semantic matching; do NOT add lexical fingerprinting here, it is brittle and
    it is the reason this stayed a keyword grep for four runs.
    """
    rows = []
    for e in sorted(
        entries,
        key=lambda x: (-int(x.get("count") or 0), str(x.get("key"))),
    )[:limit]:
        ok, why = qualifies(e)
        rows.append(
            {
                "key": e.get("key"),
                "gist": e.get("gist", ""),
                "count": int(e.get("count") or 0),
                "runs": len(set(e.get("runs") or [])),
                "seams": sorted(set(e.get("seams") or [])),
                "disposition": e.get("disposition") or "observed",
                "first_seen": e.get("first_seen", ""),
                "last_seen": e.get("last_seen", ""),
                "qualified": ok,
                "qualify_reason": why,
            }
        )
    return {
        "n_entries": len(entries),
        "n_qualified": sum(1 for r in rows if r["qualified"]),
        "truncated": len(entries) > limit,
        "entries": rows,
    }


def merge_observations(
    entries: Sequence[dict],
    observations: Sequence[dict],
    run_id: str,
    now_iso: str,
) -> tuple[list[dict], dict]:
    """Merge a tick's observations into the store. Returns ``(entries, summary)``."""
    by_key = {e["key"]: dict(e) for e in entries}
    created: list[str] = []
    updated: list[str] = []

    for obs in observations:
        if not isinstance(obs, dict):
            raise DreamError(f"observation is not an object: {obs!r}")
        key = (obs.get("key") or "").strip()
        if not key:
            raise DreamError(f"observation missing 'key': {obs!r}")
        seams = [s for s in (obs.get("seams") or []) if s]
        disposition = obs.get("disposition")
        if disposition is not None and disposition not in DISPOSITIONS:
            raise DreamError(
                f"unknown disposition {disposition!r} for {key!r}; "
                f"known: {', '.join(DISPOSITIONS)}"
            )

        entry = by_key.get(key)
        if entry is None:
            entry = {
                "key": key,
                "gist": obs.get("gist", ""),
                "count": 0,
                "first_seen": now_iso,
                "last_seen": now_iso,
                "runs": [],
                "seams": [],
                "run_seams": {},
                "disposition": "observed",
            }
            by_key[key] = entry
            created.append(key)
        else:
            updated.append(key)

        entry["count"] = int(entry.get("count") or 0) + 1
        entry["last_seen"] = now_iso
        if obs.get("gist"):
            entry["gist"] = obs["gist"]
        runs = list(entry.get("runs") or [])
        if run_id not in runs:
            runs.append(run_id)
        entry["runs"] = runs
        entry["seams"] = sorted(set(entry.get("seams") or []) | set(seams))
        rs = dict(entry.get("run_seams") or {})
        rs[run_id] = sorted(set(rs.get(run_id) or []) | set(seams))
        entry["run_seams"] = rs
        if obs.get("bead"):
            beads = list(entry.get("beads") or [])
            if obs["bead"] not in beads:
                beads.append(obs["bead"])
            entry["beads"] = beads
        if disposition:
            prev = entry.get("disposition") or "observed"
            # Never downgrade a human verdict back to a machine observation.
            if not (
                prev in {"promoted", "rejected"} and disposition == "observed"
            ):
                entry["disposition"] = disposition
            if disposition == "rejected" and prev != "rejected":
                entry["rejected_at_count"] = entry["count"]

    merged = sorted(by_key.values(), key=lambda e: str(e.get("key")))
    qualified = []
    for e in merged:
        ok, why = qualifies(e)
        if ok:
            qualified.append({"key": e["key"], "reason": why})
    summary = {
        "memory": None,  # filled in by the caller
        "run_id": run_id,
        "observations": len(observations),
        "new_keys": sorted(set(created)),
        "updated_keys": sorted(set(updated) - set(created)),
        "n_entries": len(merged),
        "qualified": qualified,
    }
    return merged, summary


# --------------------------------------------------------------------------- #
# collect output
# --------------------------------------------------------------------------- #
def build_collect_output(
    slug: str,
    repo: Path | None,
    since_dt: datetime,
    history_since: datetime,
    seam_report: dict[str, dict],
    candidates: list[dict],
    truncated: bool,
    digest: dict,
    stats: dict,
) -> dict:
    searched = [n for n, r in seam_report.items() if r["searched"]]
    return {
        "since": iso_z(since_dt),
        "history_since": iso_z(history_since),
        "slug": slug,
        "repo": str(repo) if repo else None,
        "scanned_sessions": int(stats.get("scanned_sessions", 0)),
        "window_sessions": int(stats.get("window_sessions", 0)),
        "seams": seam_report,
        "seams_requested": len(seam_report),
        "seams_searched": len(searched),
        "n_candidates": len(candidates),
        "truncated": truncated,
        "candidates": candidates,
        "memory_digest": digest,
    }


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
SUBCOMMANDS = ("collect", "remember", "seams")


def _add_common_scope_flags(p: argparse.ArgumentParser) -> None:
    p.add_argument(
        "--slug",
        default=None,
        help="slug to scan (bind with '=': slugs start with '-'). Default: current "
        "slug from cwd. Confidential-safe: current slug ONLY, no cross-slug mode.",
    )
    p.add_argument(
        "--root",
        default=None,
        help="projects root (overrides CLAUDE_PROJECTS_ROOT; default ~/.claude/projects)",
    )
    p.add_argument(
        "--recall",
        default=None,
        help="path to recall.py (overrides DREAM_RECALL; default "
        "~/.claude/skills/recall/recall.py)",
    )


def build_parser() -> argparse.ArgumentParser:
    """The LEGACY parser: bare `dream.py --since=… --slug=…`, session-recall only."""
    p = argparse.ArgumentParser(
        prog="dream.py",
        description=(
            "Surface candidate durable-learning turns for the dream tick "
            "(spec explore-76oc §4.4). Propose-only: emits candidates, files nothing."
        ),
        epilog=(
            "Subcommands: 'collect' (all seams + memory_digest), "
            "'remember --observations FILE' (merge recurrence memory), "
            "'seams' (list seams). Bare invocation stays session-recall-only "
            "with the legacy JSON shape."
        ),
    )
    p.add_argument(
        "--since",
        default=None,
        help="ISO-8601 window start (e.g. 2026-07-01T00:00:00Z). The tick derives "
        "it from the ledger (last run's ts). Omitted -> first-run lookback.",
    )
    p.add_argument(
        "--lookback-days",
        type=int,
        default=DEFAULT_LOOKBACK_DAYS,
        help=f"first-run bounded window when --since is omitted (default {DEFAULT_LOOKBACK_DAYS})",
    )
    _add_common_scope_flags(p)
    p.add_argument(
        "--max-candidates",
        type=int,
        default=DEFAULT_MAX_CANDIDATES,
        help=f"cap candidates emitted per run (default {DEFAULT_MAX_CANDIDATES})",
    )
    return p


def build_collect_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="dream.py collect",
        description=(
            "Run every enabled seam over the CURRENT slug / CURRENT repo, merge + "
            "dedupe, and emit candidates plus the recurrence memory_digest. "
            "Exit 0 = found, 1 = searched and empty, 3 = could not search."
        ),
    )
    p.add_argument(
        "--since",
        default=None,
        help="ISO-8601 session-window start (the session-recall seam). "
        "Omitted -> --lookback-days.",
    )
    p.add_argument(
        "--lookback-days",
        type=int,
        default=DEFAULT_LOOKBACK_DAYS,
        help=f"session window when --since is omitted (default {DEFAULT_LOOKBACK_DAYS})",
    )
    _add_common_scope_flags(p)
    p.add_argument(
        "--seams",
        default=None,
        help="comma-separated seams to run (default all): "
        + ", ".join(SEAM_ORDER),
    )
    p.add_argument(
        "--history-days",
        type=int,
        default=DEFAULT_HISTORY_DAYS,
        help=f"git-history window for the churn seams (default {DEFAULT_HISTORY_DAYS})",
    )
    p.add_argument(
        "--history-since",
        default=None,
        help="explicit ISO-8601 start for the git-history seams (overrides --history-days)",
    )
    p.add_argument(
        "--repo",
        default=None,
        help="current repo for offboard-history / findings-corrections "
        "(default: git toplevel of cwd)",
    )
    p.add_argument(
        "--skills-repo",
        default=None,
        help=f"repo holding agents/skills/*/SKILL.md (default {DEFAULT_SKILLS_REPO})",
    )
    p.add_argument(
        "--memory-git-dir",
        default=None,
        help=f"claude-vault memory git dir (default {DEFAULT_MEMORY_GIT_DIR})",
    )
    p.add_argument(
        "--memory",
        default=None,
        help="recurrence store path (default <repo>/refs/dream-memory.jsonl)",
    )
    p.add_argument(
        "--memory-digest-limit",
        type=int,
        default=DEFAULT_MEMORY_DIGEST_LIMIT,
        help=f"cap digest entries (default {DEFAULT_MEMORY_DIGEST_LIMIT})",
    )
    p.add_argument(
        "--max-candidates",
        type=int,
        default=DEFAULT_MAX_CANDIDATES,
        help=f"cap merged candidates (default {DEFAULT_MAX_CANDIDATES})",
    )
    p.add_argument(
        "--max-commits",
        type=int,
        default=DEFAULT_MAX_COMMITS,
        help=f"cap commits per git seam (default {DEFAULT_MAX_COMMITS})",
    )
    p.add_argument(
        "--churn-min",
        type=int,
        default=DEFAULT_CHURN_MIN,
        help=f"revisions before a file counts as churn (default {DEFAULT_CHURN_MIN})",
    )
    return p


def build_remember_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="dream.py remember",
        description=(
            "Merge a tick's observations into the recurrence store. Phase two of "
            "collect -> judge -> remember. Writes ONLY the store; never MEMORY.md."
        ),
    )
    p.add_argument(
        "--observations",
        required=True,
        help="JSON file: a list of observations, or {'run_id':…,'observations':[…]}. "
        "Each: {key, gist, seams:[…], disposition?, bead?}. '-' reads stdin.",
    )
    p.add_argument(
        "--memory",
        default=None,
        help="recurrence store path (default <repo>/refs/dream-memory.jsonl)",
    )
    p.add_argument(
        "--repo",
        default=None,
        help="repo used to derive the default --memory path",
    )
    p.add_argument(
        "--run-id",
        default=None,
        help="id for this run (default: --now, i.e. the run timestamp)",
    )
    p.add_argument(
        "--now",
        default=None,
        help="ISO-8601 timestamp for this merge (default: wall clock). "
        "Pass it for determinism.",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="compute + report the merge, write nothing",
    )
    return p


def resolve_repo(arg_repo: str | None) -> Path | None:
    if arg_repo is not None:
        p = Path(arg_repo)
        guard_path(p, "repo")
        return p if p.is_dir() else None
    return git_toplevel(Path.cwd())


def _resolve_live_roots(arg_root: str | None) -> list[Path]:
    root = resolve_root(arg_root)
    root_paths = [Path(p) for p in root.split(os.pathsep) if p]
    return [p for p in root_paths if p.is_dir()]


def _resolve_since(arg_since: str | None, lookback_days: int) -> datetime:
    if arg_since is not None:
        return parse_since(arg_since)
    return datetime.now(UTC) - timedelta(days=lookback_days)


# --------------------------------------------------------------------------- #
def cmd_legacy(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)

    root = resolve_root(args.root)
    root_paths = [Path(p) for p in root.split(os.pathsep) if p]
    live_roots = [p for p in root_paths if p.is_dir()]
    if not live_roots:
        sys.stderr.write(
            "dream: no projects root exists or is a directory: "
            + ", ".join(str(p) for p in root_paths)
            + "\n"
        )
        return 2
    # Say which vaults are in scope — a silently-missing one is the jkc6 defect.
    sys.stderr.write(
        "dream: consolidating "
        + str(len(live_roots))
        + " vault(s): "
        + ", ".join(str(p) for p in live_roots)
        + "\n"
    )

    recall_path = resolve_recall(args.recall)
    if not recall_path.is_file():
        sys.stderr.write(
            f"dream: recall.py not found at {recall_path} "
            "(set --recall or DREAM_RECALL)\n"
        )
        return 2

    if args.since is not None:
        try:
            since_dt = parse_since(args.since)
        except ValueError:
            sys.stderr.write(f"dream: unparseable --since: {args.since!r}\n")
            return 2
    else:
        since_dt = datetime.now(UTC) - timedelta(days=args.lookback_days)

    slug = args.slug or current_slug_from_cwd()
    if is_confidential_path(slug):
        sys.stderr.write(
            f"dream: refusing confidential slug {slug!r} — linearb*/cfp* content "
            "must never reach a pushed artifact\n"
        )
        return 2

    try:
        all_sessions, in_window, candidates, truncated = gather_candidates(
            live_roots,
            slug,
            since_dt.timestamp(),
            recall_path,
            sys.executable,
            args.max_candidates,
        )
    except DreamError as exc:
        sys.stderr.write(f"dream: {exc}\n")
        return 2

    out = build_output(
        slug, since_dt, all_sessions, in_window, candidates, truncated
    )
    sys.stdout.write(json.dumps(out) + "\n")
    return 0


def cmd_collect(argv: list[str]) -> int:
    args = build_collect_parser().parse_args(argv)

    slug = args.slug or current_slug_from_cwd()
    if is_confidential_path(slug):
        sys.stderr.write(
            f"dream: refusing confidential slug {slug!r} — linearb*/cfp* content "
            "must never reach a pushed artifact (feedback_linearb_beads_confidential)\n"
        )
        return 2

    try:
        since_dt = _resolve_since(args.since, args.lookback_days)
    except ValueError:
        sys.stderr.write(f"dream: unparseable --since: {args.since!r}\n")
        return 2
    if args.history_since is not None:
        try:
            history_since = parse_since(args.history_since)
        except ValueError:
            sys.stderr.write(
                f"dream: unparseable --history-since: {args.history_since!r}\n"
            )
            return 2
    else:
        history_since = datetime.now(UTC) - timedelta(days=args.history_days)

    try:
        seam_names = parse_seams(args.seams)
        repo = resolve_repo(args.repo)
    except DreamError as exc:
        sys.stderr.write(f"dream: {exc}\n")
        return 2

    ctx = SeamContext(
        slug=slug,
        roots=_resolve_live_roots(args.root),
        since_dt=since_dt,
        history_since=history_since,
        recall_path=resolve_recall(args.recall),
        max_candidates=args.max_candidates,
        max_commits=args.max_commits,
        churn_min=args.churn_min,
        repo=repo,
        skills_repo=Path(args.skills_repo) if args.skills_repo else None,
        memory_git_dir=(
            Path(args.memory_git_dir) if args.memory_git_dir else None
        ),
    )

    report, merged = run_seams(ctx, seam_names)
    candidates, truncated = interleave_by_seam(merged, args.max_candidates)

    mem_path = Path(args.memory) if args.memory else default_memory_path(repo)
    try:
        entries = load_memory(mem_path)
    except DreamError as exc:
        sys.stderr.write(f"dream: {exc}\n")
        return 2
    digest = memory_digest(entries, args.memory_digest_limit)
    digest["path"] = str(mem_path)
    digest["exists"] = Path(mem_path).is_file()

    out = build_collect_output(
        slug,
        repo,
        since_dt,
        history_since,
        report,
        candidates,
        truncated,
        digest,
        ctx.stats,
    )
    sys.stdout.write(json.dumps(out) + "\n")

    searched_any = any(r["searched"] for r in report.values())
    for name, r in report.items():
        if not r["searched"]:
            sys.stderr.write(
                f"dream: seam {name} COULD NOT SEARCH — {r['note']}\n"
            )
    if not searched_any:
        sys.stderr.write("dream: no seam was able to search\n")
        return 3
    return 0 if candidates else 1


def cmd_remember(argv: list[str]) -> int:
    args = build_remember_parser().parse_args(argv)

    if args.now is not None:
        try:
            now_dt = parse_since(args.now)
        except ValueError:
            sys.stderr.write(f"dream: unparseable --now: {args.now!r}\n")
            return 2
    else:
        now_dt = datetime.now(UTC)
    now_iso = iso_z(now_dt)
    run_id = args.run_id or now_iso

    try:
        if args.observations == "-":
            raw = sys.stdin.read()
        else:
            obs_path = Path(guard_path(args.observations, "observations"))
            if not obs_path.is_file():
                sys.stderr.write(
                    f"dream: observations file not found: {obs_path}\n"
                )
                return 2
            raw = obs_path.read_text(encoding="utf-8")
        data = json.loads(raw)
    except (OSError, json.JSONDecodeError, DreamError) as exc:
        sys.stderr.write(f"dream: cannot read observations: {exc}\n")
        return 2

    if isinstance(data, dict):
        observations = data.get("observations") or []
        run_id = args.run_id or data.get("run_id") or run_id
    elif isinstance(data, list):
        observations = data
    else:
        sys.stderr.write(
            "dream: observations must be a JSON list or an object with "
            "'observations'\n"
        )
        return 2

    try:
        repo = resolve_repo(args.repo)
        mem_path = (
            Path(args.memory) if args.memory else default_memory_path(repo)
        )
        entries = load_memory(mem_path)
        merged, summary = merge_observations(
            entries, observations, run_id, now_iso
        )
        summary["memory"] = str(mem_path)
        summary["dry_run"] = bool(args.dry_run)
        if not args.dry_run:
            save_memory(mem_path, merged)
    except DreamError as exc:
        sys.stderr.write(f"dream: {exc}\n")
        return 2

    sys.stdout.write(json.dumps(summary) + "\n")
    return 0


def cmd_seams(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="dream.py seams", description="List the available input seams."
    )
    p.parse_args(argv)
    sys.stdout.write(json.dumps({"seams": SEAM_ORDER}) + "\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args and args[0] in SUBCOMMANDS:
        sub, rest = args[0], args[1:]
        if sub == "collect":
            return cmd_collect(rest)
        if sub == "remember":
            return cmd_remember(rest)
        return cmd_seams(rest)
    return cmd_legacy(args)


if __name__ == "__main__":
    sys.exit(main())
