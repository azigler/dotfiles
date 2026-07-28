#!/usr/bin/env python3
"""scrub.py — detect + redact high-confidence secrets in the claude-vault tiers
(memory files and transcript JSONL / tool-results). Layer 0 of the secret-hygiene
system (explore-r2iq). Stdlib-only (the optional gitleaks backend is a subprocess).

Modes:
  scan     <paths...>            report files + per-pattern match counts; exit 1 if any found
  redact   <paths...> [--apply]  replace each secret with a dated marker (dry-run unless --apply)
  denylist                       print the live-value denylist decision table (NAMES only)

Two detectors run in BOTH scan and redact:
  1. PATTERNS   — the high-confidence prefix/shape regexes (below). Unchanged.
  2. DENYLIST   — the LIVE VALUE denylist: every `export NAME=VALUE` in ~/.secrets
                  (override: --secrets-file / $SCRUB_SECRETS_FILE), admitted by the
                  shape rule in `denylist_verdict`, matched VERBATIM. Computed at
                  runtime and discarded; never persisted, never printed as a value —
                  hits are reported as `secrets-file:NAME`. Disable: --no-denylist.

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

The PATTERNS detector is HIGH-CONFIDENCE only (distinctive secret prefixes +
BEGIN-PRIVATE-KEY + long Bearer tokens). Deliberately NOT entropy-based in redact:
at 2GB transcript scale a raw entropy scan false-positives on doc-ids/base64, and a
false positive in REDACT mode corrupts real content. Entropy stays a scan-only
concern (--entropy), handled by review.

The DENYLIST detector is the complement: it covers credentials with NO distinctive
shape (the ones prefix patterns structurally cannot see) by comparing against the
values that actually exist on this box. Because the comparison is verbatim equality
with a known credential, it has no false-positive risk, which is why — unlike
entropy — it is safe in redact mode too. That matters: a gate that can only DETECT
a secret it cannot REDACT stalls the vault forever; this one closes the loop.
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
    # Custom `sk-<name>-<hex>` service/gateway keys (e.g. agentgateway's
    # sk-goose-<hex> / sk-cc-<hex>). The (?<![A-Za-z0-9]) lookbehind anchors `sk`
    # to a token start so words ending in "sk" (risk-, task-, disk-) can't match;
    # the [0-9a-f]{8,} hex tail excludes placeholders like `sk-goose-REPLACE_ME`.
    "gateway-sk-key": re.compile(
        r"(?<![A-Za-z0-9])sk-[a-z][a-z0-9]{0,30}-[0-9a-f]{8,}"
    ),
    "aws-akia": re.compile(r"AKIA[0-9A-Z]{16}"),
    "slack-token": re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),
    "gitlab-pat": re.compile(r"glpat-[A-Za-z0-9_-]{20}"),
    "bearer-token": re.compile(r"Bearer [A-Za-z0-9._~+/=-]{40,}"),
    # Rails signed session/remember cookies. The COOKIE NAME is the
    # high-confidence marker — the value is an opaque base64 blob with no
    # distinctive prefix of its own, so name-anchoring is the only way to catch
    # this class without dropping to entropy (which redact mode forbids).
    # `_otwarchive_session` is AO3's; `remember_user_token` is stock Devise and
    # is the more dangerous of the pair — it re-establishes a session on its own,
    # so possession is account access until it expires or the user logs out
    # everywhere. Added 2026-07-26 after a live AO3 pair was pasted into a
    # session and this scanner reported 0 matches on the transcript 25 minutes
    # before the hourly vault sync would have committed it to git history.
    "rails-session-cookie": re.compile(
        r"(?:_[a-z0-9_]*session|_?session_id|remember_[a-z0-9_]*token)"
        # Separator class includes quotes so the JSON-serialised shape
        # ("_session_id": "<blob>") matches too — a transcript stores cookies
        # that way far more often than as a bare `name value` pair.
        r"[\"'=:\s]+[A-Za-z0-9%._-]{40,}"
    ),
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


# ---------------------------------------------------------------------------- #
# LIVE VALUE DENYLIST (explore-wmlc) — the second detector, on by default in BOTH
# scan and redact.
#
# WHY IT EXISTS. The PATTERNS above are prefix/shape-anchored, so they can only see
# credentials whose issuer stamped a recognisable prefix on them. Measured
# 2026-07-28 against the real ~/.secrets: 22 exported variables, 3 pattern matches.
# The gate consumed that exit code and called the other 19 "clean" — and because the
# gate and the redactor share the detector, redacting the 3 visible ones would have
# turned a correctly-BLOCKED transcript into a PASSING one still carrying the rest,
# straight into permanent git history. A narrow detector wired to an admission gate
# is a false-confidence machine, not a gate.
#
# WHAT IT DOES. At run time, read ~/.secrets (or $SCRUB_SECRETS_FILE /
# --secrets-file), parse `export NAME=VALUE`, keep the values that pass the shape
# rule below, and test whether any appears VERBATIM in the scanned text.
#
# THE PRIVACY CONTRACT — this is the part to not break:
#   * the list is built in memory and discarded when the process exits;
#   * it is NEVER written to disk, a temp file, a ledger, or a log;
#   * a hit is reported as the KEY `secrets-file:<NAME>` — the variable NAME and a
#     count. No value, no prefix, no length, ever reaches stdout/stderr from a hit.
#   * `denylist` mode prints the decision table (name + length + verdict) so the
#     rule is inspectable — still never a value.
#
# THE SHAPE RULE (denylist_verdict). A value is ADMITTED iff it is not obviously a
# non-credential that would false-positive on ordinary content:
#   too-short   len < DENY_MIN_LEN (20)   — short ids/handles collide with prose
#   integer     all digits                — HEVY_TOKEN_EXPIRES_AT, counters
#   url         scheme://…                — CDN_BASE_URL and friends
#   whitespace  contains any whitespace   — a phrase, not a token
#   pointer     $VAR / ${VAR} / ~/… / /…  — a reference, not a literal (the GOOD
#                                           pattern; see the memory convention)
# Everything else is admitted. The rule is shape-based on purpose: it does not
# consult the variable NAME, so it cannot be fooled by a credential that happens to
# be called `..._ID` (R2_ACCESS_KEY_ID is a real credential; R2_ACCOUNT_ID is a
# quasi-public identifier and IS admitted). Erring that way is deliberate: a
# false positive here costs one redacted identifier in a private vault; a false
# negative costs a live credential in permanent git history.
#
# THE ALLOWLIST IS DELIBERATELY NOT APPLIED HERE. `is_allowlisted` exists to tame a
# HEURISTIC (entropy) — its `git-sha` rule matches any 40/64-hex run, and three of
# the real credentials in ~/.secrets are exactly 64 hex characters. Running the
# denylist through it would silently discard them. Verbatim equality with a known
# credential needs no taming.
# ---------------------------------------------------------------------------- #
DENY_MIN_LEN = 20
SECRETS_FILE_DEFAULT = "~/.secrets"

# `export NAME=VALUE`; `export` optional so a plain .env works too.
_EXPORT_RE = re.compile(
    r"^[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.MULTILINE
)
_URL_RE = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://")
_POINTER_RE = re.compile(r"^(?:\$\{?[A-Za-z_]|~/|/)")


def _unquote(v: str) -> str:
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    return v


def denylist_verdict(value: str) -> str:
    """'ok' if `value` is admitted to the denylist, else the filter that rejected it.
    Pure + total, so `denylist` mode can print the same decision the scan makes."""
    if not value:
        return "empty"
    if len(value) < DENY_MIN_LEN:
        return "too-short"
    if value.isdigit():
        return "integer"
    if _URL_RE.match(value):
        return "url"
    if any(c.isspace() for c in value):
        return "whitespace"
    if _POINTER_RE.match(value):
        return "pointer"
    return "ok"


def parse_secrets_file(path: str) -> list[tuple[str, str]]:
    """[(NAME, VALUE)] for every assignment in `path`, in file order. Raises OSError
    if unreadable — the caller decides whether that is fatal (it is not: it degrades
    to 'denylist unavailable', which is REPORTED, never silently swallowed)."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    return [
        (m.group(1), _unquote(m.group(2))) for m in _EXPORT_RE.finditer(text)
    ]


def denylist_table(path: str) -> list[tuple[str, int, str]]:
    """[(NAME, len(value), verdict)] — the inspectable decision table. NO values."""
    return [
        (n, len(v), denylist_verdict(v)) for n, v in parse_secrets_file(path)
    ]


def build_denylist(path: str) -> list[tuple[str, str]]:
    """[(NAME, needle)] for the admitted values, longest needle first.

    Each admitted value contributes its RAW form and, when different, its
    JSON-string-escaped form -- a transcript stores a credential inside a JSON
    string value, so a value containing a quote/backslash only ever appears there in
    escaped form and a raw-only search would miss it. Longest-first ordering makes
    redaction deterministic when one needle contains another."""
    out: list[tuple[str, str]] = []
    for name, value in parse_secrets_file(path):
        if denylist_verdict(value) != "ok":
            continue
        needles = {value}
        needles.add(json.dumps(value)[1:-1])
        out.extend((name, n) for n in needles)
    out.sort(key=lambda t: len(t[1]), reverse=True)
    return out


def scan_denylist(text: str, deny: list[tuple[str, str]]) -> dict[str, int]:
    """{'secrets-file:NAME': count} for every live value present verbatim in `text`."""
    counts: dict[str, int] = {}
    for name, needle in deny:
        n = text.count(needle)
        if n:
            counts[f"secrets-file:{name}"] = (
                counts.get(f"secrets-file:{name}", 0) + n
            )
    return counts


def redact_denylist(text: str, deny: list[tuple[str, str]]) -> tuple[str, int]:
    """Replace every live value with MARKER. Verbatim equality => no false positive,
    so this is safe in redact mode (unlike entropy). Values never contain a newline
    (the `whitespace` filter rejects them), so the line count cannot drift."""
    total = 0
    for _name, needle in deny:
        n = text.count(needle)
        if n:
            text = text.replace(needle, MARKER)
            total += n
    return text, total


def iter_files(paths, exts=(".jsonl", ".txt", ".md")):
    for p in paths:
        if os.path.isfile(p):
            yield p
        else:
            for root, _dirs, files in os.walk(p):
                for f in files:
                    if f.endswith(exts):
                        yield os.path.join(root, f)


def scan_text(
    text: str, deny: list[tuple[str, str]] | None = None
) -> dict[str, int]:
    counts = {}
    for name, pat in PATTERNS.items():
        n = sum(1 for m in pat.finditer(text) if not is_allowlisted(m.group(0)))
        if n:
            counts[name] = n
    if deny:
        counts.update(scan_denylist(text, deny))
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


def redact_text(
    text: str, deny: list[tuple[str, str]] | None = None
) -> tuple[str, int]:
    total = 0
    # bearer first (keep prefix)
    text, n = _BEARER_KEEP.subn(lambda m: m.group(1) + MARKER, text)
    total += n
    for name, pat in PATTERNS.items():
        if name == "bearer-token":
            continue
        text, n = pat.subn(MARKER, text)
        total += n
    if deny:
        text, n = redact_denylist(text, deny)
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
    ap.add_argument("mode", choices=["scan", "redact", "denylist"])
    ap.add_argument("paths", nargs="*")
    ap.add_argument(
        "--apply",
        action="store_true",
        help="redact: actually write (default dry-run)",
    )
    ap.add_argument(
        "--secrets-file",
        default=os.environ.get("SCRUB_SECRETS_FILE", SECRETS_FILE_DEFAULT),
        help="live-value denylist source (default ~/.secrets or $SCRUB_SECRETS_FILE)",
    )
    ap.add_argument(
        "--no-denylist",
        action="store_true",
        help="disable the live-value denylist (patterns only)",
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
    secrets_path = os.path.expanduser(a.secrets_file)

    # `denylist` mode: print the decision table and stop. NAMES + lengths + the
    # filter verdict — never a value. This is what makes the rule inspectable.
    if a.mode == "denylist":
        try:
            rows = denylist_table(secrets_path)
        except OSError as e:
            print(
                f"denylist: cannot read {secrets_path} ({e.__class__.__name__})",
                file=sys.stderr,
            )
            return 2
        print(f"# live-value denylist source: {secrets_path}")
        print(
            f"# admitted iff: len >= {DENY_MIN_LEN}, not integer/url/whitespace/pointer"
        )
        for name, ln, verdict in rows:
            mark = "ADMIT " if verdict == "ok" else "skip  "
            print(
                f"{mark} {name:28s} len={ln:<5d} {'' if verdict == 'ok' else verdict}"
            )
        ok = sum(1 for _n, _l, v in rows if v == "ok")
        print(
            f"\n== denylist: {ok} of {len(rows)} values admitted ==",
            file=sys.stderr,
        )
        return 0

    if not a.paths:
        ap.error(f"{a.mode}: at least one path is required")

    # Build the live-value denylist. UNAVAILABLE is a THIRD state, not a silent
    # pass: it is named in the summary line so "gate passed" can never be confused
    # with "gate passed with only 3 of 22 credentials detectable" (explore-wmlc).
    deny: list[tuple[str, str]] = []
    deny_status = "off" if a.no_denylist else "unavailable"
    deny_names = 0
    if not a.no_denylist:
        try:
            deny = build_denylist(secrets_path)
            deny_names = len({n for n, _ in deny})
            deny_status = "on"
        except OSError as e:
            deny_status = f"unavailable:{e.__class__.__name__}"
            # A greppable WARN, not just a bracket in the summary. The vault call
            # sites forward this stream to ~/.claude/vault-sync.log, so the one
            # state that silently re-narrows the gate is the one state that says so.
            print(
                f"WARN: scrub: live-value denylist UNAVAILABLE ({secrets_path}: "
                f"{e.__class__.__name__}) — this run detects PREFIX PATTERNS ONLY.",
                file=sys.stderr,
            )

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
        counts = scan_text(text, deny)
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
            new_text, redacted = redact_text(text, deny)
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

    # The detector line is the three-valued rule made visible: a caller reading the
    # log can tell "clean under BOTH detectors" from "clean under the patterns only
    # because the live-value denylist could not be built". Deliberately brace-free —
    # scrub-continue.sh's per-file parser keys on a trailing `{...}` counts dict.
    det = f"{len(PATTERNS)} patterns"
    if deny_status == "on":
        det += f" + {deny_names} live-values from {secrets_path}"
    else:
        det += f"; live-value denylist {deny_status.upper()}"
    print(
        f"\n== {a.mode}: {files_hit} files with matches, {total_matches} secret matches"
        f"  [detectors: {det}] ==",
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
