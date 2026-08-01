#!/usr/bin/env python3
"""Guard for the ``the documented example IS the defect`` class (dotfiles-mlti).

In a prompt-driven harness an agent does not *interpret* a documented snippet —
it **copies it**. So a wrong example is not a typo, it is a defect with a
replication mechanism: it is invisible to code review (every file is
individually well-formed), invisible to tests (nothing tests documentation),
and it **scales with adoption** — the better the docs are followed, the more
damage. Repairing the downstream mess never stops the next project reproducing
it; only fixing the example does.

Four independent audits on 2026-07-25 each found one instance, none aware of
the others. That is not a detection system, that is luck. This is the
mechanical half.

WHAT IT DOES. Extracts every fenced code block from the fleet's agent-facing
markdown (AGENTS.md / CLAUDE.md / SKILL.md / practices.md / skill reference
docs) and runs seven checks over them:

``hook-block`` — **the novel one.** Every shell statement in a documented block
    is replayed against the machine's OWN live ``PreToolUse`` Bash hooks, with
    a synthetic tool-call payload, WITHOUT executing the command. The hooks are
    the ground truth for what this harness permits: a documented command the
    harness would *refuse to run* is unambiguously wrong, and nothing else
    finds it. (Instance 2: ``AGENTS.md``'s canonical worktree-cleanup snippet
    is blocked by ``pre-bash-stderr-guard.sh`` — a rule stated 140 lines
    earlier in the same file.) See "HOOK DRY-RUN" below for exactly what this
    can and cannot see.

``shellcheck`` — shell blocks through shellcheck, after placeholder
    normalization (``<bead-id>`` → ``PH_bead_id``; without it shellcheck reads
    ``br close <bead-id>`` as a redirect and 60% of findings are noise about
    the placeholder syntax rather than the code).

``json-schema`` — JSON/JSONL blocks are parsed, and any block that looks like a
    pulse-ledger row is validated **by importing the real consumer**
    (``agents/scheduler/pulse-ledger-lint.py``) rather than by a re-implemented
    schema. Instance 1 (``"row":null``) is exactly this: valid JSON, wrong per
    its consumer, 23 bad ledger rows across three projects.

``stale-model-id`` — hardcoded model identifiers in copy-me templates, compared
    against the generation this machine actually runs (read from
    ``claude/settings.json``, never hardcoded here). Instance 4:
    ``Co-Authored-By: Claude Opus 4.6`` pasted into real commit history.

``broken-link`` — relative markdown links that do not resolve from the file
    that contains them. Instance 3's *mandate* is out of reach (see COVERAGE),
    but every link written by following it is caught here.

``vacuous-ancestor-check`` — a single narrow rule for instance 5:
    ``git merge-base --is-ancestor <branch> HEAD`` succeeds **trivially** when
    HEAD already IS that branch, so as a "did my merge land?" check it can pass
    without a merge having happened. Flagged only when nothing in the same
    block pins HEAD to something other than the branch. This rule is a
    deliberately narrow pattern match, NOT a general "is this success vacuous?"
    analysis — see COVERAGE.

``banned-git-verb`` — the four git verbs AGENTS.md's measured "Two writers, one
    working tree" table forbids (``git pull --rebase``, a pathless ``git
    stash``, ``rebase.autoStash true``, ``git push --force``), flagged only
    inside a **shell code block** — the executable surface. Prose that names
    them in order to forbid them is how the rule is supposed to be written and
    is never flagged. dotfiles-mjln: ``/commit``'s SKILL.md instructed ``git
    pull --rebase origin "$BRANCH"`` in a copy-pasteable block for four days
    while AGENTS.md, always-loaded, said the opposite. Escape hatch for a block
    that must demonstrate the wrong verb: ``# allow-banned-verb``.

HOOK DRY-RUN — what it is, precisely. A Claude Code ``PreToolUse`` hook is a
process that receives the tool call as JSON on stdin and answers with an exit
code (2 = block). It does not run the command; the harness runs the command
only if every hook exits 0. So the hooks can be asked "would you allow this?"
by handing them the payload and reading the exit code — no execution, and no
approximation of the hook logic, because the real hook binary answers.

Two honest limits, both enforced in code rather than assumed away:

* **Purity.** A hook is only *mostly* a pure analyzer. ``pre-commit-checks.sh``
  will run ``br sync``, stage ``.beads/issues.jsonl``, and even execute a pulse
  ``proof.cmd`` — but every one of those branches is gated on the hook process
  finding a git repo / a ``.beads`` dir. So hooks are invoked with cwd set to a
  **fresh temp dir that is not a git repo and has no .beads**, which makes
  those branches inert while leaving the lexical rules (``git add -A``, the
  stderr guard, the trailer rule) fully live. On top of that, only hooks on the
  audited ``PURE_HOOKS`` allowlist run at all; any other ``PreToolUse`` Bash
  hook is **reported as skipped**, never silently dropped, so a new hook shows
  up as a visible coverage gap.
* **cwd-dependent verdicts.** Some hook rules key off the session's cwd (the
  worktree-push block, the ``br close``-in-worktree block). A documented snippet
  has no cwd, so those rules are evaluated under a neutral persona and their
  verdicts are NOT observed by default. ``--persona worktree`` is an opt-in
  second pass with a worktree cwd; ALL of its hook findings are warn-severity,
  because a doc block legitimately aimed at the orchestrator must not be failed
  for what a subagent may not do. Read that pass, do not gate on it.

SEVERITY + EXIT CODE. ``error`` findings fail the run (exit 1); ``warn``
findings are reported and do not. The split exists so the gate stays
un-muteable: a linter people turn off is worse than no linter.

Usage::

    LINT=~/dotfiles/agents/doclint/doc-example-lint.py

    python3 "$LINT"                       # default fleet scope
    python3 "$LINT" --json                # machine-readable
    python3 "$LINT" --path ~/explore      # scan a specific tree or file
    python3 "$LINT" --rule hook-block     # one rule (repeatable)
    python3 "$LINT" --show-warn           # include warn-severity findings
    python3 "$LINT" --selftest            # regression fixtures
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

HOME = Path.home()
HERE = Path(__file__).resolve().parent

# --------------------------------------------------------------------------- #
# Corpus
# --------------------------------------------------------------------------- #
#: Roots scanned when no --path is given. Only AGENT-FACING markdown: the files
#: an agent is actually instructed to read and copy from.
DEFAULT_ROOTS = (
    HOME / "dotfiles" / "agents",
    HOME / "dotfiles" / "CLAUDE.md",
    HOME / "explore" / "CLAUDE.md",
    HOME / "explore" / ".claude",
    HOME / ".claude" / "CLAUDE.md",
)

#: Per-project CLAUDE.md files are discovered under these roots (depth-limited).
DISCOVER_ROOTS = (HOME,)
DISCOVER_MAXDEPTH = 3

#: Never scanned: vendored third-party docs (their examples are not OUR
#: examples — nothing here copies from a node_modules README), VCS internals,
#: and worktrees (transient copies that would double-count every finding).
EXCLUDE_DIR_PARTS = frozenset(
    {
        ".git",
        "node_modules",
        "worktrees",
        ".venv",
        "venv",
        "dist",
        "build",
        "target",
        "__pycache__",
        ".br_history",
    }
)

#: Confidential trees — excluded by default per the fleet rule that LinearB /
#: CFP state never lands in a shareable artifact. --include-confidential opts in
#: for a local-only run.
CONFIDENTIAL_ROOTS = (HOME / "linearb", HOME / "cfp")

#: Filenames that are agent instructions (as opposed to prose docs a human
#: reads). Everything under a skills/ tree counts regardless of name, because
#: skill reference docs are loaded and copied from just like SKILL.md.
INSTRUCTION_NAMES = frozenset(
    {
        "claude.md",
        "agents.md",
        "skill.md",
        "practices.md",
        "toolkit.md",
        "infra.md",
        "gemini.md",
        "copilot-instructions.md",
    }
)

SHELL_LANGS = frozenset(
    {"bash", "sh", "shell", "zsh", "console", "shell-session"}
)
JSON_LANGS = frozenset({"json", "jsonl", "jsonc", "ndjson"})

# --------------------------------------------------------------------------- #
# shellcheck policy
# --------------------------------------------------------------------------- #
#: Codes suppressed because they are inherent to a documentation FRAGMENT, not
#: defects in it. A doc block is by construction not a whole script: it has no
#: shebang, references variables the surrounding prose sets, and sources files
#: shellcheck cannot follow. Flagging those trains readers to mute the linter.
SHELLCHECK_EXCLUDE = (
    "SC1090",  # can't follow non-constant source
    "SC1091",  # not following sourced file
    "SC2034",  # var appears unused (the fragment ends before its use)
    "SC2148",  # no shebang
    "SC2154",  # referenced but not assigned (set by surrounding prose)
    "SC2016",  # single quotes prevent expansion (deliberate in jq/awk examples)
    "SC2317",  # unreachable command (function-shaped fragments)
)

#: shellcheck levels promoted to error severity. `error` means shellcheck could
#: not make sense of the code — a snippet that will not run as written.
SHELLCHECK_ERROR_LEVELS = frozenset({"error"})

#: `<placeholder>` → identifier, so shellcheck lints the CODE rather than
#: reporting the placeholder syntax as a broken redirection. Measured on the
#: real corpus (284 docs, 2026-07-26): 213 warning-or-error findings without
#: normalization, 43 with — 170 of 213, EIGHTY PERCENT, were artifacts of the
#: placeholder syntax rather than statements about the code. A linter at that
#: signal-to-noise gets muted, and a muted linter is worse than none.
PLACEHOLDER_RE = re.compile(r"<([A-Za-z][A-Za-z0-9 _./|:-]{0,48})>")

# --------------------------------------------------------------------------- #
# Hook dry-run policy
# --------------------------------------------------------------------------- #
#: PreToolUse Bash hooks audited (by reading them) to be safe to invoke with a
#: synthetic payload from a neutral cwd. The value is the audit rationale; it is
#: printed by --explain-hooks so the claim stays reviewable rather than folkloric.
PURE_HOOKS = {
    "pre-bash-stderr-guard.sh": "purely lexical: greps the command string, never executes it",
    "pre-bead-close.sh": "read-only `br lint` / `br show`; mutating branches need a real bead db",
    "pre-merge-worktree.sh": "read-only git queries; exits 0 immediately when the branch is absent",
    "pre-commit-checks.sh": "lexical git-discipline rules; every mutating branch (br sync, "
    "auto-stage, proof.cmd exec) is gated on a git repo + .beads, both "
    "absent in the neutral cwd",
}

HOOK_TIMEOUT_S = 15

# --------------------------------------------------------------------------- #


@dataclass
class Block:
    path: Path
    start_line: int  # 1-based line of the opening fence
    lang: str
    lines: list[str]
    #: The prose immediately above the fence. A JSON example means nothing on
    #: its own — WHICH schema it must satisfy is stated in the sentence that
    #: introduces it ("The ledger: refs/pulse-ledger.jsonl"), so the consumer
    #: check is scoped by this instead of guessed from the keys. Guessing from
    #: keys flagged the daily-digest skill's own `refs/digest-ledger.jsonl`
    #: examples against the pulse schema they were never subject to.
    context: str = ""

    def line_of(self, offset: int) -> int:
        """Absolute file line for a 1-based offset into the block body."""
        return self.start_line + offset


@dataclass
class Finding:
    path: Path
    line: int
    rule: str
    severity: str  # "error" | "warn"
    message: str
    snippet: str = ""

    def as_dict(self) -> dict:
        return {
            "file": str(self.path),
            "line": self.line,
            "rule": self.rule,
            "severity": self.severity,
            "message": self.message,
            "snippet": self.snippet,
        }


@dataclass
class Context:
    """Everything a check needs that is discovered, not hardcoded."""

    settings: dict = field(default_factory=dict)
    hooks: list[Path] = field(default_factory=list)
    skipped_hooks: list[Path] = field(default_factory=list)
    sandbox: Path | None = None
    persona: str = "neutral"
    model_generation: dict[str, int] = field(default_factory=dict)


# --------------------------------------------------------------------------- #
# Markdown fenced-block extraction
# --------------------------------------------------------------------------- #
_FENCE_RE = re.compile(r"^(?P<ind>[ \t]*)(?P<fence>`{3,}|~{3,})(?P<info>.*)$")

#: Lines of prose kept above each fence as the block's context (see Block.context).
CONTEXT_LINES = 20


def extract_blocks(path: Path) -> list[Block]:
    """Every fenced code block in ``path``.

    Handles both fence characters, fences longer than three, and fences
    indented inside list items (the body is de-indented by the opening fence's
    indent so the snippet lints as the reader would paste it). An unterminated
    fence runs to end of file rather than raising — a malformed doc must not
    brick the gate.
    """
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    lines = text.splitlines()
    blocks: list[Block] = []
    i = 0
    while i < len(lines):
        m = _FENCE_RE.match(lines[i])
        if not m:
            i += 1
            continue
        fence, indent = m.group("fence"), len(m.group("ind"))
        info = m.group("info").strip()
        lang = info.split()[0].lower().strip("{}.") if info else ""
        body: list[str] = []
        j = i + 1
        while j < len(lines):
            m2 = _FENCE_RE.match(lines[j])
            if (
                m2
                and m2.group("fence")[0] == fence[0]
                and len(m2.group("fence")) >= len(fence)
                and not m2.group("info").strip()
            ):
                break
            raw = lines[j]
            body.append(raw[indent:] if raw[:indent].strip() == "" else raw)
            j += 1
        blocks.append(
            Block(
                path,
                i + 1,
                lang,
                body,
                context="\n".join(
                    [*lines[max(0, i - CONTEXT_LINES) : i], info]
                ),
            )
        )
        i = j + 1
    return blocks


# --------------------------------------------------------------------------- #
# Shell statement splitting (heredoc- and continuation-aware)
# --------------------------------------------------------------------------- #
_HEREDOC_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def logical_statements(lines: list[str]) -> list[tuple[int, str]]:
    """Split a shell block into ``(1-based body offset, statement)`` pairs.

    A "statement" is what an agent copies as one Bash tool call. Heredoc bodies
    and ``\\``-continuations are joined into the statement that opened them —
    otherwise a ``git commit -m "$(cat <<'EOF' … EOF)"`` block would be fed to
    the hooks as a dozen nonsense commands, and the ``EOF`` line would read as
    an unknown verb.
    """
    stmts: list[tuple[int, str]] = []
    buf: list[str] = []
    #: Parallel to ``buf``: True where the line is heredoc BODY. Body text is
    #: data, not code, so it must be excluded from the quote-balance test —
    #: otherwise a lone apostrophe in prose ("## What's here") reads as an
    #: unterminated quote and every following command is swallowed into the
    #: heredoc's statement. That mis-attributed a real `git add .` violation in
    #: talk/SKILL.md to the `cat > README.md` line 23 lines above it.
    is_body: list[bool] = []
    start = 0
    pending_heredocs: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if not buf:
            if not line.strip() or line.lstrip().startswith("#"):
                i += 1
                continue
            start = i + 1
        in_heredoc = bool(pending_heredocs)
        buf.append(line)
        is_body.append(in_heredoc)

        if in_heredoc:
            if line.strip() == pending_heredocs[0]:
                pending_heredocs.pop(0)
            i += 1
            if pending_heredocs or _needs_more(buf, is_body):
                continue
            stmts.append((start, "\n".join(buf)))
            buf, is_body = [], []
            continue

        for m in _HEREDOC_RE.finditer(line):
            pending_heredocs.append(m.group(2))
        i += 1
        if pending_heredocs or _needs_more(buf, is_body):
            continue
        stmts.append((start, "\n".join(buf)))
        buf, is_body = [], []

    if buf:
        stmts.append((start, "\n".join(buf)))
    return stmts


def _needs_more(buf: list[str], is_body: list[bool]) -> bool:
    """True if the accumulated lines are an obviously incomplete statement."""
    joined = "\n".join(buf)
    if joined.rstrip().endswith("\\"):
        return True
    if joined.rstrip().endswith(("&&", "||", "|")):
        return True
    # Quote/substitution balance over the CODE lines only (see is_body above).
    code = "\n".join(
        line for line, body in zip(buf, is_body, strict=False) if not body
    )
    return _unbalanced(code)


def _unbalanced(s: str) -> bool:
    single = double = 0
    depth = 0
    k = 0
    while k < len(s):
        c = s[k]
        if c == "\\":
            k += 2
            continue
        if c == "'" and not double % 2:
            single += 1
        elif c == '"' and not single % 2:
            double += 1
        elif not single % 2 and not double % 2:
            if s.startswith("$(", k):
                depth += 1
                k += 2
                continue
            if c == ")" and depth:
                depth -= 1
        k += 1
    return bool(single % 2 or double % 2 or depth)


# --------------------------------------------------------------------------- #
# CHECK: shellcheck
# --------------------------------------------------------------------------- #
def normalize_placeholders(src: str) -> str:
    """``<bead-id>`` → ``PH_bead_id``, innermost-first until stable.

    Repeated because placeholders nest in the real corpus
    (``<refs/research/<topic>.md>``): one pass rewrites the inner one and
    leaves the outer angle brackets looking like a broken redirection, which
    is precisely the noise this exists to remove.
    """
    for _ in range(4):
        out = PLACEHOLDER_RE.sub(
            lambda m: "PH_" + re.sub(r"[^A-Za-z0-9]", "_", m.group(1)), src
        )
        if out == src:
            break
        src = out
    return src


def check_shellcheck(block: Block, ctx: Context) -> list[Finding]:
    if block.lang not in SHELL_LANGS or not shutil.which("shellcheck"):
        return []
    src = normalize_placeholders("\n".join(block.lines))
    if not src.strip():
        return []
    try:
        proc = subprocess.run(
            [
                "shellcheck",
                "-s",
                "bash",
                "-S",
                "warning",
                "-f",
                "json",
                "-e",
                ",".join(c[2:] for c in SHELLCHECK_EXCLUDE),
                "-",
            ],
            input=src,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return [
            Finding(
                block.path,
                block.start_line,
                "shellcheck",
                "warn",
                f"shellcheck could not run: {exc}",
            )
        ]
    if not proc.stdout.strip():
        # No JSON at all means shellcheck itself failed — surface it rather
        # than reading an empty result as "clean" (the swallowed-stderr trap
        # this whole linter exists to catch).
        if proc.returncode not in (0, 1):
            return [
                Finding(
                    block.path,
                    block.start_line,
                    "shellcheck",
                    "warn",
                    f"shellcheck exited {proc.returncode}: "
                    f"{proc.stderr.strip()[:200]}",
                )
            ]
        return []
    try:
        findings = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return [
            Finding(
                block.path,
                block.start_line,
                "shellcheck",
                "warn",
                "shellcheck produced unparseable output",
            )
        ]

    out: list[Finding] = []
    for f in findings:
        off = int(f.get("line", 1))
        sev = "error" if f.get("level") in SHELLCHECK_ERROR_LEVELS else "warn"
        snippet = (
            block.lines[off - 1].strip() if 0 < off <= len(block.lines) else ""
        )
        out.append(
            Finding(
                block.path,
                block.line_of(off),
                "shellcheck",
                sev,
                f"SC{f['code']} [{f['level']}] {f['message']}",
                snippet,
            )
        )
    return out


# --------------------------------------------------------------------------- #
# CHECK: hook dry-run
# --------------------------------------------------------------------------- #
def _matcher_matches_bash(matcher: str) -> bool:
    if not matcher:
        return True
    try:
        return bool(re.search(matcher, "Bash"))
    except re.error:
        return matcher == "Bash"


def discover_bash_pretooluse_hooks(
    settings: dict,
) -> tuple[list[Path], list[Path]]:
    """``(runnable, skipped)`` PreToolUse Bash hook scripts.

    Runnable = on the audited PURE_HOOKS allowlist. Skipped hooks are RETURNED,
    not dropped: an unaudited hook is a coverage gap and has to be visible.
    """
    runnable: list[Path] = []
    skipped: list[Path] = []
    for entry in settings.get("hooks", {}).get("PreToolUse", []) or []:
        if not _matcher_matches_bash(entry.get("matcher", "")):
            continue
        for hook in entry.get("hooks", []) or []:
            if hook.get("type") != "command":
                continue
            cmd = (hook.get("command") or "").strip()
            if not cmd:
                continue
            path = Path(os.path.expanduser(cmd.split()[0]))
            if not path.exists():
                continue
            (runnable if path.name in PURE_HOOKS else skipped).append(path)
    return runnable, skipped


def _hook_payload(command: str, cwd: str) -> str:
    return json.dumps(
        {
            "session_id": "doc-example-lint",
            "transcript_path": "/dev/null",
            "cwd": cwd,
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {
                "command": command,
                "description": "doc example dry-run",
            },
        }
    )


def run_hooks(command: str, ctx: Context, cwd: str) -> list[tuple[str, str]]:
    """``(hook name, stderr)`` for every hook that would BLOCK ``command``.

    The command is never executed: each hook is a separate process that reads
    the tool call as JSON and answers with an exit code (2 = block).
    """
    blocked: list[tuple[str, str]] = []
    for hook in ctx.hooks:
        try:
            proc = subprocess.run(
                ["bash", str(hook)],
                input=_hook_payload(command, cwd),
                capture_output=True,
                text=True,
                cwd=ctx.sandbox,
                timeout=HOOK_TIMEOUT_S,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            blocked.append((hook.name, f"(hook could not be evaluated: {exc})"))
            continue
        if proc.returncode == 2:
            blocked.append((hook.name, proc.stderr.strip()))
    return blocked


def check_hook_block(block: Block, ctx: Context) -> list[Finding]:
    if block.lang not in SHELL_LANGS or not ctx.hooks or ctx.sandbox is None:
        return []
    out: list[Finding] = []
    seen: set[tuple[str, str]] = set()
    # Under the worktree persona the refusal may be correct-and-intended: a doc
    # block aimed at the ORCHESTRATOR legitimately shows `git push`, which the
    # harness denies only to subagents. A finding only that persona sees is
    # therefore a warning, not a failure.
    severity = "warn" if ctx.persona == "worktree" else "error"
    for off, stmt in logical_statements(block.lines):
        if not stmt.strip():
            continue
        for hook_name, stderr in run_hooks(stmt, ctx, str(ctx.sandbox)):
            key = (hook_name, _first_line(stderr))
            if key in seen:
                continue
            seen.add(key)
            out.append(
                Finding(
                    block.path,
                    block.line_of(off),
                    "hook-block",
                    severity,
                    f"the machine's own {hook_name} REFUSES this documented "
                    f"command: {_first_line(stderr)}",
                    stmt.splitlines()[0].strip() if stmt.strip() else "",
                )
            )
    return out


def _first_line(text: str) -> str:
    for line in text.splitlines():
        if line.strip():
            return line.strip()[:220]
    return "(no message)"


# --------------------------------------------------------------------------- #
# CHECK: JSON blocks + the real consumer's schema
# --------------------------------------------------------------------------- #
def _load_pulse_ledger_lint():
    """Import the REAL ledger consumer, so this gate cannot drift from it."""
    candidates = [
        HERE.parent / "scheduler" / "pulse-ledger-lint.py",
        HOME / "dotfiles" / "agents" / "scheduler" / "pulse-ledger-lint.py",
    ]
    for path in candidates:
        if not path.exists():
            continue
        spec = importlib.util.spec_from_file_location("pulse_ledger_lint", path)
        if spec is None or spec.loader is None:
            continue
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    return None


_PULSE = None

#: Problems the real consumer reports that do NOT apply to a doc EXAMPLE: an
#: example legitimately names a row that exists only in the example. Everything
#: else (row=null, missing key, bad outcome, non-UTC ts) is a genuine defect in
#: the example and stays.
_DOC_EXEMPT_LEDGER_PROBLEMS = ("is not in any routing table",)


def _is_pulse_ledger_example(block: Block, rec: object) -> bool:
    """Is this documented record subject to the pulse-ledger schema?

    Two independent signals, either sufficient:

    * the prose introducing the block names the pulse ledger — this is how a
      doc actually declares which consumer an example is for; or
    * the record carries BOTH ``row`` and ``outcome``, the pulse row's
      distinguishing shape (this is what catches instance 1's ``"row":null``
      even in a doc that never says "pulse-ledger" nearby).

    Deliberately NOT "has ts + outcome": the /daily-digest skill's
    ``refs/digest-ledger.jsonl`` is a different ledger with that same pair, and
    validating it against the pulse schema produced two confident, wrong
    findings — a linter's own false positives are the same failure class it
    hunts, so the rule is narrowed to something that can be argued from the
    document.
    """
    if not isinstance(rec, dict):
        return False
    if "row" in rec and "outcome" in rec:
        return True
    return "pulse-ledger" in block.context.lower() and "outcome" in rec


def _has_placeholder_value(rec: dict, problem: str) -> bool:
    """True when the field a problem names holds an unfilled ``<placeholder>``.

    ``{"ts": "<UTC date -u +%FT%TZ>"}`` is a template, not a claim that the
    string is ISO-8601. Flagging it teaches readers to ignore this rule.
    """
    for key, value in rec.items():
        if (
            isinstance(value, str)
            and _TEMPLATE_VALUE_RE.search(value)
            and key in problem
        ):
            return True
    return False


#: Looser than PLACEHOLDER_RE on purpose: a template VALUE can hold anything
#: (``<UTC date -u +%FT%TZ>``), and here the angle brackets alone are the
#: signal that the author never claimed the string was a literal.
_TEMPLATE_VALUE_RE = re.compile(r"<[^<>\n]{1,80}>")


def check_json(block: Block, ctx: Context) -> list[Finding]:
    global _PULSE
    if block.lang not in JSON_LANGS:
        return []
    out: list[Finding] = []
    body = "\n".join(block.lines)
    if not body.strip():
        return []

    # Elisions and placeholders are conventional in docs; a block carrying them
    # is not claiming to be parseable, so parse failures there are not defects.
    elided = "..." in body or "…" in body or PLACEHOLDER_RE.search(body)

    records: list[tuple[int, object]] = []
    stripped = _strip_jsonc(body) if block.lang == "jsonc" else body
    try:
        records.append((1, json.loads(stripped)))
    except json.JSONDecodeError:
        # Not one document — try JSONL (the ledger's actual on-disk shape).
        ok = True
        line_records: list[tuple[int, object]] = []
        for n, line in enumerate(block.lines, 1):
            if not line.strip():
                continue
            try:
                line_records.append((n, json.loads(line)))
            except json.JSONDecodeError as exc:
                ok = False
                if not elided:
                    out.append(
                        Finding(
                            block.path,
                            block.line_of(n),
                            "json-schema",
                            "error",
                            f"documented JSON does not parse: {exc.msg}",
                            line.strip()[:120],
                        )
                    )
                break
        if ok:
            records = line_records

    if _PULSE is None:
        _PULSE = _load_pulse_ledger_lint() or False
    if not _PULSE:
        return out

    for n, rec in records:
        targets = rec if isinstance(rec, list) else [rec]
        for target in targets:
            if not _is_pulse_ledger_example(block, target):
                continue
            # Validate against the consumer, with row-name membership relaxed.
            valid_rows = (
                {str(target.get("row"))}
                if isinstance(target.get("row"), str)
                else set()
            )
            for problem in _PULSE.check_record(target, valid_rows):
                if any(x in problem for x in _DOC_EXEMPT_LEDGER_PROBLEMS):
                    continue
                if _has_placeholder_value(target, problem):
                    continue
                out.append(
                    Finding(
                        block.path,
                        block.line_of(n),
                        "json-schema",
                        "error",
                        f"documented pulse-ledger row violates the schema its real "
                        f"consumer (pulse-ledger-lint.py) enforces: {problem}",
                        json.dumps(target)[:120],
                    )
                )
    return out


def _strip_jsonc(text: str) -> str:
    out = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"(?m)^\s*//.*$", "", out)


# --------------------------------------------------------------------------- #
# CHECK: stale model identifiers
# --------------------------------------------------------------------------- #
_MODEL_ID_RE = re.compile(
    r"claude[- ](?:opus|sonnet|haiku)[- ](\d+)(?:[.-](\d+))?", re.I
)
_COAUTHOR_RE = re.compile(r"^\s*Co-Authored-By:\s*(.+)$", re.I | re.M)


def current_model_generation(settings: dict) -> dict[str, int]:
    """Model generation this machine runs, read from settings — never hardcoded.

    A linter for stale identifiers that pins the current one in its own source
    becomes the defect it hunts the moment the fleet moves on.
    """
    gens: dict[str, int] = {}
    env = settings.get("env", {}) or {}
    for value in [*env.values(), settings.get("model", "")]:
        if not isinstance(value, str):
            continue
        for m in re.finditer(r"claude-(opus|sonnet|haiku)-(\d+)", value, re.I):
            fam, major = m.group(1).lower(), int(m.group(2))
            gens[fam] = max(gens.get(fam, 0), major)
    return gens


def check_stale_model_id(path: Path, text: str, ctx: Context) -> list[Finding]:
    gens = ctx.model_generation
    if not gens:
        return []
    out: list[Finding] = []
    lines = text.splitlines()
    for n, line in enumerate(lines, 1):
        for m in _MODEL_ID_RE.finditer(line):
            major = int(m.group(1))
            fam_m = re.search(r"(opus|sonnet|haiku)", m.group(0), re.I)
            fam = fam_m.group(1).lower() if fam_m else ""
            current = gens.get(fam)
            if current is None or major >= current:
                continue
            is_template = (
                bool(_COAUTHOR_RE.match(line)) or "Co-Authored-By" in line
            )
            out.append(
                Finding(
                    path,
                    n,
                    "stale-model-id",
                    "error" if is_template else "warn",
                    f"hardcoded model id {m.group(0)!r} is {current - major} "
                    f"generation(s) behind the {fam} model this machine runs "
                    f"(generation {current})"
                    + (
                        " — and it sits in a copy-me commit template, so agents "
                        "paste a false attribution into real git history."
                        if is_template
                        else ""
                    ),
                    line.strip()[:120],
                )
            )
    return out


# --------------------------------------------------------------------------- #
# CHECK: broken relative links
# --------------------------------------------------------------------------- #
_LINK_RE = re.compile(r"\[[^\]\n]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
_CODE_SPAN_RE = re.compile(r"`[^`\n]*`")


def check_links(path: Path, text: str, ctx: Context) -> list[Finding]:
    out: list[Finding] = []
    in_fence = False
    fence_char = ""
    for n, raw in enumerate(text.splitlines(), 1):
        m = _FENCE_RE.match(raw)
        if m:
            if not in_fence:
                in_fence, fence_char = True, m.group("fence")[0]
            elif (
                m.group("fence")[0] == fence_char
                and not m.group("info").strip()
            ):
                in_fence = False
            continue
        if in_fence:
            continue
        # Links inside code spans are FORMS being described, not links being
        # made — resolving them produces noise (`[name](../name/FINDINGS.md)`
        # has a placeholder segment by design).
        line = _CODE_SPAN_RE.sub(lambda _m: " " * len(_m.group(0)), raw)
        for lm in _LINK_RE.finditer(line):
            target = lm.group(1)
            if _skip_link_target(target):
                continue
            rel = target.split("#", 1)[0]
            if not rel:
                continue
            resolved = (path.parent / rel).resolve()
            if resolved.exists():
                continue
            out.append(
                Finding(
                    path,
                    n,
                    "broken-link",
                    "error",
                    f"relative link {target!r} does not resolve from "
                    f"{path.parent} (→ {resolved})",
                    raw.strip()[:120],
                )
            )
    return out


def _skip_link_target(target: str) -> bool:
    if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):  # http:, mailto:, etc.
        return True
    if target.startswith(("#", "//")):
        return True
    # Placeholder segments cannot be resolved by anyone, reader included.
    return any(ch in target for ch in "<>${}*")


# --------------------------------------------------------------------------- #
# CHECK: vacuous ancestor check  (instance 5)
# --------------------------------------------------------------------------- #
_ANCESTOR_RE = re.compile(
    r"git\s+merge-base\s+--is-ancestor\s+(?P<ref>[^\s;|&]+)\s+HEAD\b"
)
#: Anything in the same block that pins HEAD to something other than the branch
#: under test, which makes the ancestor check non-vacuous.
_HEAD_PINNED_RE = re.compile(
    r"git\s+(checkout|switch)\s+(?!-b\b)|"
    r"git\s+rev-parse\s+--abbrev-ref\s+HEAD|"
    r"git\s+symbolic-ref|"
    r"git\s+branch\s+--show-current"
)


def check_vacuous_ancestor(block: Block, ctx: Context) -> list[Finding]:
    if block.lang not in SHELL_LANGS:
        return []
    body = "\n".join(block.lines)
    if _HEAD_PINNED_RE.search(body):
        return []
    out: list[Finding] = []
    for n, line in enumerate(block.lines, 1):
        m = _ANCESTOR_RE.search(line)
        if not m:
            continue
        out.append(
            Finding(
                block.path,
                block.line_of(n),
                "vacuous-ancestor-check",
                "error",
                f"`git merge-base --is-ancestor {m.group('ref')} HEAD` passes "
                "TRIVIALLY when HEAD already is that branch, so as a "
                '"did the merge land?" gate it can report success for a merge '
                "that never happened. Nothing in this block pins HEAD to the "
                "merge target first (a `git rev-parse --abbrev-ref HEAD` "
                "assertion, or a checkout of the target branch).",
                line.strip()[:120],
            )
        )
    return out


# --------------------------------------------------------------------------- #
# CHECK: banned git verbs in an executable example  (dotfiles-mjln)
# --------------------------------------------------------------------------- #
# AGENTS.md's "Two writers, one working tree" rule is the fleet's canonical git
# verb, and it is measured: `git pull --no-rebase` fails SAFELY, `--rebase` fails
# obstructively (rc 128 on ANY unrelated dirty file), and `git stash` "succeeds"
# by silently taking the other writer's work. /commit's SKILL.md nonetheless
# instructed `git pull --rebase origin "$BRANCH"` inside a copy-pasteable bash
# block for four days (dotfiles-mjln) — routing agents onto the rung whose
# refusal reflexively suggests the destructive one.
#
# So this rule is deliberately narrow: it fires ONLY inside a shell code block,
# because that is the executable surface (dotfiles/CLAUDE.md rule 2 — a
# documented example is executable in a prompt-driven harness). Prose that
# NAMES these verbs to forbid them — the AGENTS.md table, the 🚫 lines in
# /commit — is exactly how the rule is supposed to be documented and must not
# be flagged. A block that genuinely must demonstrate the wrong verb marks the
# line `# allow-banned-verb`.
_BANNED_VERBS: tuple[tuple[re.Pattern, str], ...] = (
    (
        re.compile(r"\bgit\s+pull\b(?=[^#\n]*--rebase\b)"),
        "`git pull --rebase` — AGENTS.md's rule is `git fetch origin && "
        "git merge --no-edit origin/<branch>`. Rebase refuses on any unrelated "
        "dirty file, and that refusal is what tempts the next agent into "
        "`git stash`, which destroys the other writer's work.",
    ),
    (
        re.compile(r"\bgit\s+stash\b(?!\s+(?:push\s+--|list\b|show\b))"),
        "`git stash` without explicit paths — it silently takes a second "
        "writer's uncommitted work (a /pulse tick shares this tree). If you "
        "must set aside your OWN work, name it: `git stash push -- <paths>`.",
    ),
    (
        re.compile(r"\brebase\.autoStash\b(?=[^#\n]*\btrue\b)"),
        "enabling `rebase.autoStash` turns the obstructive verb into the "
        "destructive one with no prompt and no error. It is unset fleet-wide "
        "and must stay unset.",
    ),
    (
        re.compile(r"\bgit\s+push\b(?=[^#\n]*--force(?:-with-lease)?\b)"),
        "`git push --force` / `--force-with-lease` to a shared branch — a "
        "rejected push means another machine committed; fetch, merge, push "
        "again.",
    ),
)


def check_banned_git_verb(block: Block, ctx: Context) -> list[Finding]:
    if block.lang not in SHELL_LANGS:
        return []
    out: list[Finding] = []
    for n, line in enumerate(block.lines, 1):
        stripped = line.strip()
        # A `#` line inside a block is prose, not the pasteable command.
        if not stripped or stripped.startswith("#"):
            continue
        if "allow-banned-verb" in line:
            continue
        for pat, why in _BANNED_VERBS:
            if pat.search(line):
                out.append(
                    Finding(
                        block.path,
                        block.line_of(n),
                        "banned-git-verb",
                        "error",
                        f"executable example instructs {why}",
                        stripped[:120],
                    )
                )
    return out


# --------------------------------------------------------------------------- #
# Driver
# --------------------------------------------------------------------------- #
BLOCK_RULES = {
    "hook-block": check_hook_block,
    "shellcheck": check_shellcheck,
    "json-schema": check_json,
    "vacuous-ancestor-check": check_vacuous_ancestor,
    "banned-git-verb": check_banned_git_verb,
}
FILE_RULES = {
    "stale-model-id": check_stale_model_id,
    "broken-link": check_links,
}
ALL_RULES = tuple(BLOCK_RULES) + tuple(FILE_RULES)


def is_excluded(path: Path) -> bool:
    return bool(EXCLUDE_DIR_PARTS.intersection(path.parts))


def is_instruction_doc(path: Path) -> bool:
    if path.suffix.lower() != ".md":
        return False
    if path.name.lower() in INSTRUCTION_NAMES:
        return True
    parts = {p.lower() for p in path.parts}
    return bool(parts & {"skills", "skill"})


def collect_files(
    roots: list[Path],
    include_confidential: bool,
    discover: bool,
    any_markdown: bool = False,
) -> list[Path]:
    found: dict[Path, None] = {}

    def add(p: Path, explicit: bool = False) -> None:
        if not p.is_file():
            return
        # EXCLUDE_DIR_PARTS is a TREE-WALK filter: its job is to keep vendored
        # docs and duplicate worktree copies out of a recursive scan. A file
        # named directly on the command line is a deliberate target, and
        # applying the walk filter to it silently scanned NOTHING — which is
        # exactly what a worktree agent gets, since every agent worktree lives
        # under a path part named `worktrees`. Caught while wiring the
        # banned-git-verb gate into tools/githooks/pre-commit (dotfiles-mjln):
        # the gate ran, printed `files_scanned=0`, and passed a doc that
        # instructed `git pull --rebase`.
        if not explicit and is_excluded(p):
            return
        if not include_confidential and any(
            _is_relative_to(p, c) for c in CONFIDENTIAL_ROOTS
        ):
            return
        # realpath-keyed: ~/.claude/CLAUDE.md is a symlink to agents/AGENTS.md,
        # and counting one file twice would double every finding in it.
        found.setdefault(p.resolve(), None)

    for root in roots:
        if root.is_file():
            add(root, explicit=True)
        elif root.is_dir():
            for p in root.rglob("*.md"):
                if any_markdown or is_instruction_doc(p):
                    add(p)

    if discover:
        for root in DISCOVER_ROOTS:
            for name in ("CLAUDE.md", "AGENTS.md"):
                for p in _globs_to_depth(root, name, DISCOVER_MAXDEPTH):
                    add(p)
    return sorted(found)


def _globs_to_depth(root: Path, name: str, depth: int) -> list[Path]:
    out: list[Path] = []
    for d in range(1, depth + 1):
        pattern = "/".join(["*"] * (d - 1) + [name]) if d > 1 else name
        try:
            out.extend(root.glob(pattern))
        except OSError:
            continue
    return out


def _is_relative_to(p: Path, other: Path) -> bool:
    try:
        p.resolve().relative_to(other.resolve())
        return True
    except (ValueError, OSError):
        return False


def load_settings(path: Path | None) -> dict:
    for candidate in (
        [path]
        if path
        else [
            HOME / ".claude" / "settings.json",
            HOME / "dotfiles" / "claude" / "settings.json",
        ]
    ):
        if candidate and candidate.exists():
            try:
                return json.loads(candidate.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                print(
                    f"doc-example-lint: cannot read {candidate}: {exc}",
                    file=sys.stderr,
                )
    return {}


def lint(files: list[Path], rules: set[str], ctx: Context) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            findings.append(
                Finding(path, 1, "io", "warn", f"unreadable: {exc}")
            )
            continue
        for name, fn in FILE_RULES.items():
            if name in rules:
                findings.extend(fn(path, text, ctx))
        blocks = extract_blocks(path)
        for block in blocks:
            for name, bfn in BLOCK_RULES.items():
                if name in rules:
                    findings.extend(bfn(block, ctx))
    findings.sort(key=lambda f: (str(f.path), f.line, f.rule))
    return findings


# --------------------------------------------------------------------------- #
# Selftest
# --------------------------------------------------------------------------- #
def _selftest() -> int:
    import textwrap

    tmp = Path(tempfile.mkdtemp(prefix="doc-example-lint-selftest-"))
    ctx = Context(
        settings={"env": {"ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-5[1m]"}},
        sandbox=tmp / "sandbox",
    )
    (tmp / "sandbox").mkdir()
    ctx.model_generation = current_model_generation(ctx.settings)
    assert ctx.model_generation == {"opus": 5}, ctx.model_generation

    # --- extraction -------------------------------------------------------
    doc = tmp / "EXTRACT.md"
    doc.write_text(
        textwrap.dedent("""\
        # Title

        ```bash
        echo one
        ```

        Nested inside a list:

          ```json
          {"a": 1}
          ```

        ````markdown
        ```bash
        not-a-real-block
        ```
        ````
        """),
        encoding="utf-8",
    )
    blocks = extract_blocks(doc)
    assert [b.lang for b in blocks] == ["bash", "json", "markdown"], [
        b.lang for b in blocks
    ]
    assert blocks[0].start_line == 3, blocks[0].start_line
    assert blocks[1].lines == ['{"a": 1}'], blocks[1].lines  # de-indented

    # --- statement splitting ---------------------------------------------
    stmts = logical_statements(
        textwrap.dedent("""\
        # a comment
        git status
        git commit -m "$(cat <<'EOF'
        :sparkles: thing

        Bead: x-1
        EOF
        )"
        echo done
        """).splitlines()
    )
    assert len(stmts) == 3, stmts
    assert stmts[0][1] == "git status"
    assert "Bead: x-1" in stmts[1][1] and stmts[1][1].endswith(')"')
    assert stmts[2][1] == "echo done"

    cont = logical_statements(["cmd one \\", "  --flag", "next"])
    assert len(cont) == 2, cont

    # REGRESSION: an apostrophe in heredoc PROSE must not read as an
    # unterminated quote. It did, and it swallowed the `git add .` on the far
    # side of the heredoc into the `cat >` statement — mis-attributing a real
    # violation in talk/SKILL.md by 23 lines.
    prose = logical_statements(
        [
            "cat > README.md <<EOF",
            "## What's here",
            "- handouts/ - Andrew's cheat sheets",
            "EOF",
            "git add . && git commit -m 'x'",
        ]
    )
    assert len(prose) == 2, prose
    assert prose[1][0] == 5 and prose[1][1].startswith("git add ."), prose[1]

    # REGRESSION: nested placeholders normalize fully, or shellcheck reports
    # the leftover angle brackets as a broken redirection.
    assert "<" not in normalize_placeholders(
        "echo $(realpath <refs/<topic>.md>)"
    )

    # --- INSTANCE 4 guard: stale model id in a copy-me template ----------
    doc4 = tmp / "TEMPLATE.md"
    doc4.write_text(
        "Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>\n",
        encoding="utf-8",
    )
    f4 = check_stale_model_id(doc4, doc4.read_text(encoding="utf-8"), ctx)
    assert len(f4) == 1 and f4[0].severity == "error", f4
    assert "copy-me commit template" in f4[0].message
    cur = tmp / "CURRENT.md"
    cur.write_text(
        "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>\n",
        encoding="utf-8",
    )
    assert check_stale_model_id(cur, cur.read_text(encoding="utf-8"), ctx) == []

    # --- INSTANCE 1 guard: row=null validated by the REAL consumer -------
    if _load_pulse_ledger_lint():
        good = Block(
            tmp / "L.md",
            1,
            "jsonl",
            [
                '{"ts":"2026-06-16T09:00:12Z","row":"weekly-report","outcome":"done"}'
            ],
        )
        assert check_json(good, ctx) == [], check_json(good, ctx)
        bad = Block(
            tmp / "L.md",
            1,
            "jsonl",
            ['{"ts":"2026-06-16T09:00:12Z","row":null,"outcome":"quiet"}'],
        )
        got = check_json(bad, ctx)
        assert len(got) == 1 and "row is null" in got[0].message, got
        bad_outcome = Block(
            tmp / "L.md",
            1,
            "jsonl",
            ['{"ts":"2026-06-16T09:00:12Z","row":"r","outcome":"ok"}'],
        )
        assert any("outcome" in f.message for f in check_json(bad_outcome, ctx))
    else:  # pragma: no cover
        print(
            "doc-example-lint selftest: WARN pulse-ledger-lint.py not found",
            file=sys.stderr,
        )

    malformed = Block(tmp / "L.md", 1, "json", ["{not json"])
    assert any(f.rule == "json-schema" for f in check_json(malformed, ctx))
    elided = Block(tmp / "L.md", 1, "json", ['{"a": 1, ...}'])
    assert check_json(elided, ctx) == [], "elided example must not be flagged"

    # A DIFFERENT ledger with the same ts+outcome shape is NOT the pulse
    # ledger's problem (the /daily-digest refs/digest-ledger.jsonl case).
    other_ledger = Block(
        tmp / "D.md",
        1,
        "json",
        [
            '{"ts":"2026-06-26T14:00:09Z","outcome":"quiet","note":"nothing new"}'
        ],
        context="## The ledger: refs/digest-ledger.jsonl",
    )
    assert check_json(other_ledger, ctx) == [], check_json(other_ledger, ctx)
    # …but the same shape under pulse-ledger prose IS in scope.
    pulse_ctx = Block(
        tmp / "P.md",
        1,
        "json",
        ['{"ts":"2026-06-26T14:00:09Z","outcome":"quiet","note":"x"}'],
        context="## The ledger: refs/pulse-ledger.jsonl\n\nAppend one line per tick:",
    )
    assert any(
        "missing required key 'row'" in f.message
        for f in check_json(pulse_ctx, ctx)
    ), check_json(pulse_ctx, ctx)
    # An unfilled template value is not a schema violation.
    templ = Block(
        tmp / "P.md",
        1,
        "json",
        [
            '{"ts": "<UTC date -u +%FT%TZ>", "row": "elevate", "outcome": "done"}'
        ],
    )
    assert check_json(templ, ctx) == [], check_json(templ, ctx)

    # --- INSTANCE 5 guard: vacuous ancestor check ------------------------
    vac = Block(
        tmp / "A.md",
        10,
        "bash",
        [
            "git merge worktree-agent-XXXX --no-edit",
            "git merge-base --is-ancestor worktree-agent-XXXX HEAD  # safety",
        ],
    )
    got5 = check_vacuous_ancestor(vac, ctx)
    assert len(got5) == 1 and got5[0].line == 12, got5
    guarded = Block(
        tmp / "A.md",
        1,
        "bash",
        [
            'test "$(git rev-parse --abbrev-ref HEAD)" = main || exit 1',
            "git merge-base --is-ancestor worktree-agent-XXXX HEAD",
        ],
    )
    assert check_vacuous_ancestor(guarded, ctx) == [], "guarded form must pass"

    # --- dotfiles-mjln guard: banned git verbs in an executable example ---
    # The literal line /commit's SKILL.md carried for four days, plus the three
    # other verbs AGENTS.md's measured table names.
    banned = Block(
        tmp / "C.md",
        10,
        "bash",
        [
            'git pull --rebase origin "$BRANCH"   # ALWAYS. Never push blind.',
            "git stash",
            "git config rebase.autoStash true",
            "git push --force-with-lease origin main",
        ],
    )
    gotb = check_banned_git_verb(banned, ctx)
    assert len(gotb) == 4, gotb
    assert [f.line for f in gotb] == [11, 12, 13, 14], gotb
    assert all(f.severity == "error" for f in gotb), gotb
    # The canonical form, the named-paths stash, the read-only stash verbs, a
    # `#` prose line, and the explicit escape hatch all pass.
    ok_verbs = Block(
        tmp / "C.md",
        1,
        "bash",
        [
            "git fetch origin && git merge --no-edit origin/main",
            "git stash push -- path/to/mine.md",
            "git stash list",
            "# never `git pull --rebase` here",
            "git pull --rebase origin main  # allow-banned-verb: shows the trap",
        ],
    )
    assert check_banned_git_verb(ok_verbs, ctx) == [], check_banned_git_verb(
        ok_verbs, ctx
    )
    # PROSE that forbids the verb is how the rule is supposed to be written —
    # AGENTS.md's own table would otherwise flag itself. Non-shell blocks are
    # outside the rule entirely.
    prose_block = Block(
        tmp / "C.md",
        1,
        "",
        ["| `git pull --rebase` | refuses on any dirty file | obstructive |"],
    )
    assert check_banned_git_verb(prose_block, ctx) == []

    # An EXPLICITLY named file is scanned even under an excluded dir part.
    # Every agent worktree lives under `.../worktrees/agent-XXXX/`, so without
    # this the commit gate scans zero files and passes anything.
    wt = tmp / "worktrees" / "agent-1" / "agents" / "skills" / "x"
    wt.mkdir(parents=True)
    (wt / "SKILL.md").write_text("# x\n", encoding="utf-8")
    assert collect_files([wt / "SKILL.md"], False, False) == [
        (wt / "SKILL.md").resolve()
    ], "an explicitly named file must not be dropped by the tree-walk filter"
    assert collect_files([tmp / "worktrees"], False, False, True) == [], (
        "a tree WALK must still skip worktrees (double-counting)"
    )

    # --- broken links ----------------------------------------------------
    linkdoc = tmp / "LINKS.md"
    (tmp / "real.md").write_text("x", encoding="utf-8")
    linkdoc.write_text(
        "[ok](real.md) [bad](nope.md) [ext](https://x/y.md) "
        "[ph](<topic>/FINDINGS.md)\n"
        "`[form](name/FINDINGS.md)` is the mandated shape\n"
        "```\n[infence](nope2.md)\n```\n",
        encoding="utf-8",
    )
    lf = check_links(linkdoc, linkdoc.read_text(encoding="utf-8"), ctx)
    assert len(lf) == 1 and "nope.md" in lf[0].message, lf

    # --- shellcheck ------------------------------------------------------
    if shutil.which("shellcheck"):
        placeholders = Block(
            tmp / "S.md",
            1,
            "bash",
            ["br close <bead-id>", "git worktree remove <path>"],
        )
        assert check_shellcheck(placeholders, ctx) == [], (
            "placeholder normalization must silence the redirect noise"
        )
        real = Block(tmp / "S.md", 1, "bash", ["if [ -f x ; then echo y; fi"])
        assert any(f.severity == "error" for f in check_shellcheck(real, ctx))

    # --- hook dry-run (the star check) -----------------------------------
    settings_path = HOME / ".claude" / "settings.json"
    if settings_path.exists():
        hooks, _skipped = discover_bash_pretooluse_hooks(
            load_settings(settings_path)
        )
        if hooks:
            hctx = Context(hooks=hooks, sandbox=tmp / "sandbox")
            # INSTANCE 2: the documented cleanup line the machine refuses.
            b2 = Block(
                tmp / "AG.md",
                100,
                "bash",
                [
                    "git push origin --delete worktree-agent-XXXX "
                    "2>/dev/null || true"
                ],
            )
            got2 = check_hook_block(b2, hctx)
            assert got2 and got2[0].rule == "hook-block", got2
            assert "stderr-guard" in got2[0].message, got2[0].message
            # A clean block must stay clean.
            b_ok = Block(
                tmp / "AG.md",
                1,
                "bash",
                [
                    "git worktree remove --force --force .claude/worktrees/agent-X"
                ],
            )
            assert check_hook_block(b_ok, hctx) == [], check_hook_block(
                b_ok, hctx
            )
            # The escape hatch the guard documents must be honored.
            b_hatch = Block(
                tmp / "AG.md",
                1,
                "bash",
                [
                    "git push origin --delete b 2>/dev/null || true  # allow-suppress"
                ],
            )
            assert check_hook_block(b_hatch, hctx) == []
            # git add -A is blocked by pre-commit-checks even with no repo.
            b_add = Block(tmp / "AG.md", 1, "bash", ["git add -A"])
            assert any(
                "git add" in f.message for f in check_hook_block(b_add, hctx)
            )
            # The sandbox must stay a non-repo: proves the mutating branches
            # of pre-commit-checks.sh cannot fire.
            assert not (tmp / "sandbox" / ".git").exists()
            assert not (tmp / "sandbox" / ".beads").exists()
        else:  # pragma: no cover
            print(
                "doc-example-lint selftest: WARN no pure Bash PreToolUse hooks",
                file=sys.stderr,
            )

    shutil.rmtree(tmp, ignore_errors=True)
    print(
        "doc-example-lint selftest: PASS (extraction, heredoc splitting, "
        "instances 1/2/4/5 guards, links, shellcheck normalization)"
    )
    return 0


# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument(
        "--path",
        type=Path,
        action="append",
        metavar="PATH",
        help="file or directory to scan; repeatable "
        "(default: the fleet's agent-facing docs)",
    )
    ap.add_argument(
        "--rule",
        action="append",
        choices=ALL_RULES,
        help="run only this rule; repeatable",
    )
    ap.add_argument(
        "--settings",
        type=Path,
        default=None,
        help="settings.json to read hooks + model from "
        "(default: ~/.claude/settings.json)",
    )
    ap.add_argument(
        "--persona",
        choices=("neutral", "worktree"),
        default="neutral",
        help="cwd persona for the hook dry-run (default: neutral)",
    )
    ap.add_argument(
        "--include-confidential",
        action="store_true",
        help=f"also scan {', '.join(str(c) for c in CONFIDENTIAL_ROOTS)}",
    )
    ap.add_argument(
        "--no-discover",
        action="store_true",
        help="do not auto-discover per-project CLAUDE.md files",
    )
    ap.add_argument(
        "--any-markdown",
        action="store_true",
        help=(
            "under --path, scan EVERY .md rather than only agent-instruction "
            "docs (e.g. the explore compendium's FINDINGS.md corpus, where the "
            "broken-link rule finds the downstream copies of a bad link mandate)"
        ),
    )
    ap.add_argument(
        "--show-warn",
        action="store_true",
        help="also print warn-severity findings",
    )
    ap.add_argument(
        "--explain-hooks",
        action="store_true",
        help="print the hook purity audit and exit",
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

    settings = load_settings(args.settings)
    hooks, skipped = discover_bash_pretooluse_hooks(settings)

    if args.explain_hooks:
        print("PreToolUse Bash hooks — purity audit")
        for h in hooks:
            print(f"  RUN     {h}\n          {PURE_HOOKS[h.name]}")
        for h in skipped:
            print(
                f"  SKIPPED {h}\n          not on the audited allowlist; "
                "add it to PURE_HOOKS after reading it"
            )
        return 0

    rules = set(args.rule) if args.rule else set(ALL_RULES)
    roots = args.path if args.path else list(DEFAULT_ROOTS)
    files = collect_files(
        roots,
        args.include_confidential,
        discover=not args.no_discover and not args.path,
        any_markdown=args.any_markdown,
    )

    sandbox = Path(tempfile.mkdtemp(prefix="doc-example-lint-sandbox-"))
    if args.persona == "worktree":
        sandbox = sandbox / ".claude" / "worktrees" / "agent-dryrun"
        sandbox.mkdir(parents=True)
    ctx = Context(
        settings=settings,
        hooks=hooks,
        skipped_hooks=skipped,
        sandbox=sandbox,
        persona=args.persona,
        model_generation=current_model_generation(settings),
    )
    try:
        findings = lint(files, rules, ctx)
    finally:
        root = sandbox
        while root.name != "" and "doc-example-lint-sandbox-" not in root.name:
            root = root.parent
        shutil.rmtree(root, ignore_errors=True)

    errors = [f for f in findings if f.severity == "error"]
    warns = [f for f in findings if f.severity == "warn"]

    if args.json:
        print(
            json.dumps(
                {
                    "files_scanned": len(files),
                    "rules": sorted(rules),
                    "hooks_evaluated": [str(h) for h in hooks],
                    "hooks_skipped": [str(h) for h in skipped],
                    "model_generation": ctx.model_generation,
                    "errors": len(errors),
                    "warnings": len(warns),
                    "findings": [f.as_dict() for f in findings],
                    "ok": not errors,
                },
                indent=1,
            )
        )
        return 1 if errors else 0

    shown = findings if args.show_warn else errors
    for f in shown:
        print(f"{f.path}:{f.line}: [{f.severity}] {f.rule}: {f.message}")
        if f.snippet:
            print(f"    | {f.snippet}")
    if skipped:
        print(
            f"note: {len(skipped)} PreToolUse Bash hook(s) NOT evaluated "
            f"(unaudited): {', '.join(h.name for h in skipped)}"
        )
    if not shutil.which("shellcheck"):
        print(
            "note: shellcheck not installed — the shellcheck rule was a no-op"
        )
    print(f"files_scanned={len(files)}")
    print(f"hooks_evaluated={','.join(h.name for h in hooks) or 'none'}")
    print(f"errors={len(errors)} warnings={len(warns)}")
    print(f"verdict: {'FAIL' if errors else 'CLEAN'}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
