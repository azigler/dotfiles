#!/usr/bin/env python3
"""Extract only Codex-WRITTEN keys ([projects.*], [tui]) from an old Codex
config.toml, dropping every tracked POLICY key (sandbox_mode,
approval_policy, project_doc_max_bytes, ...).

Why: the new layout puts policy in the System layer
(/etc/codex/config.toml -> codex/managed_config.toml), which Codex never
writes to. The User layer (~/.codex/config.toml) outranks System, so if a
migration copied policy keys into it too, that copy would silently win
forever and the tracked policy would never take effect again. This script
is the one-time bridge sync.sh's codex target calls: it keeps ONLY the
state Codex itself put there.

Also drops [projects.*] entries that are scratch junk: a path under /tmp,
or a path that no longer exists on disk (dotfiles-tihhn).

SAFETY: nothing at <new-config.toml> is touched until the freshly written
TOML has been round-tripped through tomllib and shown to parse back to
EXACTLY the filtered data. The write itself is an atomic os.replace() of a
same-directory temp file, so a crash or a failed round-trip leaves whatever
was already at <new-config.toml> (symlink or plain file) untouched — the
caller must NOT pre-delete it. Any failure prints a loud error and exits 1.

Usage: migrate-user-config.py <old-config.toml> <new-config.toml>
"""

import datetime
import os
import pathlib
import re
import sys
import tempfile
import tomllib

BARE_KEY_RE = re.compile(r"[A-Za-z0-9_-]+")


def escape_basic_string(s):
    """Escape `s` as the body of a TOML single-line basic string."""
    out = []
    for ch in s:
        cp = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\b":
            out.append("\\b")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\f":
            out.append("\\f")
        elif ch == "\r":
            out.append("\\r")
        elif cp < 0x20 or cp == 0x7F:
            out.append(f"\\u{cp:04X}")
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def quote_key(k):
    """A TOML bare key is [A-Za-z0-9_-]+; anything else (including a
    dotted-looking model name like "gpt-5.1", which contains a literal '.'
    that would otherwise be parsed as a table-path separator) must be
    quoted as a basic string key."""
    if BARE_KEY_RE.fullmatch(k):
        return k
    return escape_basic_string(k)


def dump_scalar(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if v != v:
            return "nan"
        if v in (float("inf"), float("-inf")):
            return "inf" if v > 0 else "-inf"
        return repr(v)
    if isinstance(v, str):
        return escape_basic_string(v)
    if isinstance(v, (datetime.datetime, datetime.date, datetime.time)):
        return v.isoformat()
    raise TypeError(f"unsupported scalar TOML value: {v!r}")


def dump_value(v):
    """Render any tomllib-produced value as a TOML inline value. Nested
    dicts become inline tables (`{ k = v }`) and lists become inline
    arrays — including arrays of dicts ("arrays of tables"), which are
    just arrays of inline tables. This needs no header/table-path
    bookkeeping at all, so there is nothing to get wrong recursively;
    only the round-trip check below is trusted for correctness."""
    if isinstance(v, dict):
        if not v:
            return "{}"
        parts = [f"{quote_key(k)} = {dump_value(val)}" for k, val in v.items()]
        return "{ " + ", ".join(parts) + " }"
    if isinstance(v, list):
        return "[" + ", ".join(dump_value(x) for x in v) + "]"
    return dump_scalar(v)


def dump_top_level(lines, header, table):
    lines.append(f"[{header}]")
    for k, v in table.items():
        lines.append(f"{quote_key(k)} = {dump_value(v)}")
    lines.append("")


def is_junk_project(path_str):
    p = pathlib.Path(path_str)
    if str(p) == "/tmp" or str(p).startswith("/tmp/"):
        return True
    return bool(not p.exists())


def build_filtered(old):
    """Return the dict we intend to keep, in the same shape tomllib would
    parse our own output back into — this is the thing the round-trip
    check compares against."""
    kept_projects = {}
    projects = old.get("projects")
    if isinstance(projects, dict):
        for path, entry in projects.items():
            if is_junk_project(path):
                continue
            kept_projects[path] = entry

    tui = old.get("tui") if isinstance(old.get("tui"), dict) else None

    filtered = {}
    if kept_projects:
        filtered["projects"] = kept_projects
    if tui is not None:
        filtered["tui"] = tui
    return filtered


def render(filtered):
    lines = [
        "# Codex-WRITTEN state only (project trust, [tui]) — migrated from the",
        "# old tracked config.toml by codex/migrate-user-config.py, policy keys",
        "# dropped on purpose (dotfiles-tihhn). THIS file (the User layer)",
        "# outranks /etc/codex/config.toml (the System layer) for any key both",
        '# set (measured: User approval_policy="on-request" beat System',
        '# approval_policy="never"), so a policy key left here would silently',
        "# override the tracked policy forever — never add one back by hand.",
        "",
    ]
    for path, entry in filtered.get("projects", {}).items():
        dump_top_level(lines, f"projects.{quote_key(path)}", entry)
    if "tui" in filtered:
        dump_top_level(lines, "tui", filtered["tui"])
    return "\n".join(lines).rstrip("\n") + "\n"


def main(argv):
    if len(argv) != 3:
        print(
            "usage: migrate-user-config.py <old-config.toml> <new-config.toml>",
            file=sys.stderr,
        )
        return 2
    old_path, new_path = argv[1], argv[2]

    try:
        with open(old_path, "rb") as f:
            old = tomllib.load(f)
    except OSError as e:
        print(f"error: cannot read {old_path}: {e}", file=sys.stderr)
        return 1
    except tomllib.TOMLDecodeError as e:
        print(f"error: cannot parse {old_path} as TOML: {e}", file=sys.stderr)
        return 1

    filtered = build_filtered(old)

    try:
        text = render(filtered)
    except TypeError as e:
        print(
            f"error: cannot render filtered config as TOML, leaving {new_path} untouched: {e}",
            file=sys.stderr,
        )
        return 1

    try:
        roundtripped = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        print(
            f"error: rendered TOML failed to re-parse, leaving {new_path} untouched: {e}",
            file=sys.stderr,
        )
        return 1

    if roundtripped != filtered:
        print(
            f"error: round-trip mismatch, leaving {new_path} untouched.\n"
            f"  filtered:      {filtered!r}\n"
            f"  round-tripped: {roundtripped!r}",
            file=sys.stderr,
        )
        return 1

    # Only now, with a verified-correct rendering in hand, touch the
    # filesystem — and only via an atomic same-directory rename, so a crash
    # between here and completion still leaves either the old file/symlink
    # or the fully-written new file, never a partial write.
    dest_dir = os.path.dirname(os.path.abspath(new_path)) or "."
    try:
        fd, tmp_path = tempfile.mkstemp(
            dir=dest_dir, prefix=".migrate-user-config."
        )
        try:
            with os.fdopen(fd, "w") as f:
                f.write(text)
            os.replace(tmp_path, new_path)
        except OSError:
            os.unlink(tmp_path)
            raise
    except OSError as e:
        print(
            f"error: cannot write {new_path}, leaving prior state untouched: {e}",
            file=sys.stderr,
        )
        return 1

    n = len(filtered.get("projects", {}))
    print(
        f"migrated {n} project trust entr{'y' if n == 1 else 'ies'}"
        f"{' + [tui] state' if 'tui' in filtered else ''} -> {new_path}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
