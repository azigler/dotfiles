#!/usr/bin/env python3
"""scrub.py — detect + redact high-confidence secrets in the claude-vault tiers
(memory files and transcript JSONL / tool-results). Layer 0 of the secret-hygiene
system (explore-r2iq). Stdlib-only (the optional gitleaks backend is a subprocess).

Modes:
  scan    <paths...>            report files + per-pattern match counts; exit 1 if any found
  redact  <paths...> [--apply]  replace each secret with a dated marker (dry-run unless --apply)

Scan-only extras (never touch redact):
  --entropy    ALSO report high-entropy token runs, ALLOWLIST-filtered (see ALLOWLIST).
               Deliberately opt-in and detect-only — entropy false-positives corrupt
               content if redacted, so redact stays high-confidence-only.
  --gitleaks   ALSO fold in gitleaks-detect findings (maintained ruleset), deduped by
               file:line. Falls back to the custom scan if gitleaks isn't installed —
               never hard-fails on its absence.

Safety (redact):
  - marker is JSON-safe (no quotes/backslashes/control chars) so a raw byte-replace
    inside a JSON string value preserves JSONL validity.
  - per-file atomic write: write a temp copy, verify (a) same line count and
    (b) every line of a .jsonl still parses as JSON, THEN os.replace(). Any check
    fails -> the temp is discarded and the original is untouched.
  - JSONL is \n-delimited ONLY: the validity check splits on "\n", NOT str.splitlines()
    (which over-splits on \r / U+2028 / U+2029 / U+0085 that can appear INSIDE a JSON
    string value, producing a false "unparseable" that would skip a safe redact).
  - --exclude <path> skips a file (e.g. the active session, mid-write).
  - --dry-run (default) never writes; --apply performs the replace.

Only HIGH-CONFIDENCE patterns (distinctive secret prefixes + BEGIN-PRIVATE-KEY +
long Bearer tokens). Deliberately NOT entropy-based in redact: at 2GB transcript
scale a raw entropy scan false-positives on doc-ids/base64, and a false positive in
REDACT mode corrupts real content. Entropy stays a scan-only concern (--entropy),
handled by review.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter

MARKER = "[REDACTED-SECRET]"

# name -> compiled pattern. Each must be unambiguous enough that a match is
# overwhelmingly a real secret (safe to overwrite in place).
PATTERNS: dict[str, re.Pattern] = {
    "private-key-block": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "google-client-secret": re.compile(r"GOCSPX-[A-Za-z0-9_-]{20,}"),
    "google-refresh-token": re.compile(r"1//0[A-Za-z0-9_-]{30,}"),
    "google-api-key": re.compile(r"AIza[0-9A-Za-z_-]{35}"),
    "github-token": re.compile(
        r"gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}"
    ),
    "anthropic-key": re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}"),
    "openai-key": re.compile(r"sk-proj-[A-Za-z0-9_-]{20,}"),
    "aws-akia": re.compile(r"AKIA[0-9A-Z]{16}"),
    "slack-token": re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),
    "gitlab-pat": re.compile(r"glpat-[A-Za-z0-9_-]{20}"),
    "bearer-token": re.compile(r"Bearer [A-Za-z0-9._~+/=-]{40,}"),
}
# for bearer we keep the "Bearer " prefix and only redact the token part:
_BEARER_KEEP = re.compile(r"(Bearer )[A-Za-z0-9._~+/=-]{40,}")

# ---------------------------------------------------------------------------- #
# Benign-shape ALLOWLIST — known false positives that a BROADER / entropy scan
# would otherwise flag. The high-confidence PATTERNS above already avoid these
# (distinctive prefixes), so on the default scan the allowlist is a no-op; it
# earns its keep the moment --entropy (or any future broad mode) is enabled, and
# it documents the exact shapes today's manual scan had to hand-classify.
# A token is suppressed iff it FULLMATCHES one of these.
# ---------------------------------------------------------------------------- #
ALLOWLIST: dict[str, re.Pattern] = {
    # Google Doc / Drive file IDs: 44 chars, always start with "1".
    "google-doc-id": re.compile(r"1[A-Za-z0-9_-]{43}"),
    # $ENV_VAR / ${ENV_VAR} references (pointers, not literals — the good pattern).
    "env-var-ref": re.compile(r"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"),
    # ~/path pointers (a location, never the secret itself).
    "path-pointer": re.compile(r"~/[^\s\"']*"),
    # git object shas (40-hex sha1, 64-hex sha256).
    "git-sha": re.compile(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}"),
    # UUIDs (v4 and friends).
    "uuid": re.compile(
        r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
        r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    ),
}


def is_allowlisted(token: str) -> bool:
    """True if `token` is entirely a known-benign shape (doc-id/env/path/sha/uuid)."""
    return any(pat.fullmatch(token) for pat in ALLOWLIST.values())


# ---------------------------------------------------------------------------- #
# High-entropy token detection (scan-only; --entropy). Base64/token-ish runs of
# >= ENTROPY_MIN_LEN chars whose Shannon entropy clears ENTROPY_THRESHOLD and
# that are NOT allowlisted. Never used by redact.
# ---------------------------------------------------------------------------- #
_TOKEN_RE = re.compile(r"[A-Za-z0-9/+=_-]{24,}")
ENTROPY_MIN_LEN = 24
ENTROPY_THRESHOLD = 4.5


def _shannon(s: str) -> float:
    if not s:
        return 0.0
    n = len(s)
    return -sum((c / n) * math.log2(c / n) for c in Counter(s).values())


def entropy_hits(text: str) -> list[str]:
    hits = []
    for m in _TOKEN_RE.finditer(text):
        tok = m.group(0)
        if len(tok) < ENTROPY_MIN_LEN or is_allowlisted(tok):
            continue
        if _shannon(tok) >= ENTROPY_THRESHOLD:
            hits.append(tok)
    return hits


def iter_files(paths, exts=(".jsonl", ".txt", ".md")):
    for p in paths:
        if os.path.isfile(p):
            yield p
        else:
            for root, _dirs, files in os.walk(p):
                for f in files:
                    if f.endswith(exts):
                        yield os.path.join(root, f)


def scan_text(text: str) -> dict[str, int]:
    counts = {}
    for name, pat in PATTERNS.items():
        n = sum(1 for m in pat.finditer(text) if not is_allowlisted(m.group(0)))
        if n:
            counts[name] = n
    return counts


def scan_line_hits(text: str) -> set[int]:
    """1-based line numbers containing >=1 high-confidence (non-allowlisted) match.
    Used only for gitleaks file:line dedup."""
    lines = set()
    for pat in PATTERNS.values():
        for m in pat.finditer(text):
            if is_allowlisted(m.group(0)):
                continue
            lines.add(text.count("\n", 0, m.start()) + 1)
    return lines


def redact_text(text: str) -> tuple[str, int]:
    total = 0
    # bearer first (keep prefix)
    text, n = _BEARER_KEEP.subn(lambda m: m.group(1) + MARKER, text)
    total += n
    for name, pat in PATTERNS.items():
        if name == "bearer-token":
            continue
        text, n = pat.subn(MARKER, text)
        total += n
    return text, total


def safe_rewrite(path: str, new_text: str) -> str:
    """Atomically replace `path` with new_text after validity checks. Returns 'ok'
    or an error string; on error the original is untouched."""
    is_jsonl = path.endswith(".jsonl")
    with open(path, encoding="utf-8", errors="replace") as fh:
        old = fh.read()
    if old.count("\n") != new_text.count("\n"):
        return "line-count-changed"
    if is_jsonl:
        # JSONL is \n-delimited ONLY; str.splitlines() over-splits on \r/ /etc.
        # that can appear inside a JSON string value, producing false "unparseable".
        for i, line in enumerate(new_text.split("\n"), 1):
            line = line.strip()
            if not line:
                continue
            try:
                json.loads(line)
            except Exception as e:
                return f"jsonl-line-{i}-unparseable:{e.__class__.__name__}"
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".scrub-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(new_text)
        os.replace(tmp, path)
    except Exception as e:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        return f"write-failed:{e}"
    return "ok"


# ---------------------------------------------------------------------------- #
# Optional gitleaks backend (detect-only; --gitleaks). Runs the maintained
# ruleset and folds findings into the scan report, deduped by file:line. Never
# hard-fails: if the binary is absent the custom scan is the fallback.
# ---------------------------------------------------------------------------- #
def gitleaks_bin() -> str | None:
    b = shutil.which("gitleaks")
    if b:
        return b
    fallback = os.path.expanduser("~/.local/bin/gitleaks")
    if os.path.isfile(fallback) and os.access(fallback, os.X_OK):
        return fallback
    return None


def run_gitleaks(paths, excl) -> tuple[list[dict], str | None]:
    """Return (findings, error). findings: unique {file, line, rule} deduped by
    (file, line), respecting the --exclude set. error is a warn-string (binary
    missing / run failure) — the caller warns and continues, never aborts."""
    binp = gitleaks_bin()
    if not binp:
        return [], "not-found"
    timeout = int(os.environ.get("SCRUB_GITLEAKS_TIMEOUT", "300"))
    by_key: dict[tuple[str, int], dict] = {}
    err = None
    for p in paths:
        fd, report = tempfile.mkstemp(suffix=".json", prefix=".scrub-gl-")
        os.close(fd)
        try:
            subprocess.run(
                [
                    binp,
                    "detect",
                    "--source",
                    p,
                    "--no-git",
                    "--redact",
                    "--report-format",
                    "json",
                    "--report-path",
                    report,
                    "--no-banner",
                    "--exit-code",
                    "0",
                ],
                capture_output=True,
                timeout=timeout,
                check=False,
            )
            with open(report, encoding="utf-8") as fh:
                data = json.load(fh)
        except Exception as e:
            err = f"run-failed:{e.__class__.__name__}"
            data = []
        finally:
            with contextlib.suppress(OSError):
                os.unlink(report)
        for item in data or []:
            f = os.path.abspath(item.get("File", ""))
            if f in excl:
                continue
            line = int(item.get("StartLine", 0) or 0)
            by_key.setdefault(
                (f, line),
                {"file": f, "line": line, "rule": item.get("RuleID", "")},
            )
    return list(by_key.values()), err


def main() -> int:
    ap = argparse.ArgumentParser(
        description="detect/redact high-confidence secrets"
    )
    ap.add_argument("mode", choices=["scan", "redact"])
    ap.add_argument("paths", nargs="+")
    ap.add_argument(
        "--apply",
        action="store_true",
        help="redact: actually write (default dry-run)",
    )
    ap.add_argument(
        "--exclude",
        action="append",
        default=[],
        help="skip this file (repeatable)",
    )
    ap.add_argument(
        "--entropy",
        action="store_true",
        help="scan: also report high-entropy tokens (allowlist-filtered; scan-only)",
    )
    ap.add_argument(
        "--gitleaks",
        action="store_true",
        help="scan: also fold in gitleaks findings (falls back to custom scan)",
    )
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    excl = {os.path.abspath(x) for x in a.exclude}
    want_gitleaks = a.gitleaks and a.mode == "scan"

    files_hit = 0
    total_matches = 0
    changed = 0
    errors = []
    custom_hits_by_file: dict[str, set[int]] = {}
    for path in iter_files(a.paths):
        if os.path.abspath(path) in excl:
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        counts = scan_text(text)
        if a.mode == "scan" and a.entropy:
            eh = entropy_hits(text)
            if eh:
                counts = dict(counts)
                counts["high-entropy"] = len(eh)
        if want_gitleaks:
            lh = scan_line_hits(text)
            if lh:
                custom_hits_by_file[os.path.abspath(path)] = lh
        if not counts:
            continue
        files_hit += 1
        n = sum(counts.values())
        total_matches += n
        if a.mode == "scan":
            if not a.quiet:
                print(f"{path}: {n}  {counts}")
        else:  # redact
            new_text, redacted = redact_text(text)
            if a.apply:
                res = safe_rewrite(path, new_text)
                if res != "ok":
                    errors.append((path, res))
                    if not a.quiet:
                        print(f"SKIP(unsafe) {path}: {res}", file=sys.stderr)
                    continue
            changed += 1
            if not a.quiet:
                verb = "redacted" if a.apply else "would redact"
                print(f"{verb} {redacted} in {path}")

    if want_gitleaks:
        findings, gl_err = run_gitleaks(a.paths, excl)
        if gl_err:
            print(
                f"gitleaks: {gl_err} (custom scan only)",
                file=sys.stderr,
            )
        new = 0
        for f in findings:
            if f["line"] in custom_hits_by_file.get(f["file"], set()):
                continue  # already counted by the custom scan (dedup by file:line)
            new += 1
            if not a.quiet:
                print(f"{f['file']}:{f['line']}: [gitleaks:{f['rule']}]")
        total_matches += new
        if new:
            files_hit += len({f["file"] for f in findings})
        if not a.quiet:
            print(
                f"== gitleaks: {new} additional finding(s) beyond the custom scan ==",
                file=sys.stderr,
            )

    print(
        f"\n== {a.mode}: {files_hit} files with matches, {total_matches} secret matches ==",
        file=sys.stderr,
    )
    if a.mode == "redact":
        mode = "APPLIED" if a.apply else "DRY-RUN (use --apply to write)"
        print(
            f"== {mode}: {changed} files {'changed' if a.apply else 'would change'}, "
            f"{len(errors)} skipped-unsafe ==",
            file=sys.stderr,
        )
    return 1 if total_matches else 0


if __name__ == "__main__":
    sys.exit(main())
