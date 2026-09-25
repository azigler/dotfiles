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

Usage: migrate-user-config.py <old-config.toml> <new-config.toml>
Exit 0 on success (including "nothing to keep" -> writes an empty/minimal
file); exit 1 on any read/parse error, so the caller can fail loud.
"""

import pathlib
import sys
import tomllib


def toml_scalar(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    if isinstance(v, str):
        esc = v.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{esc}"'
    raise TypeError(f"unsupported scalar TOML value: {v!r}")


def write_table(lines, header, table):
    """Emit `[header]` (if given) then scalars, recursing into sub-tables."""
    scalars = {k: v for k, v in table.items() if not isinstance(v, dict)}
    subtables = {k: v for k, v in table.items() if isinstance(v, dict)}
    if header:
        lines.append(f"[{header}]")
    for k, v in scalars.items():
        lines.append(f"{k} = {toml_scalar(v)}")
    if header or scalars:
        lines.append("")
    for k, v in subtables.items():
        sub_header = f"{header}.{k}" if header else k
        write_table(lines, sub_header, v)


def is_junk_project(path_str):
    p = pathlib.Path(path_str)
    if str(p) == "/tmp" or str(p).startswith("/tmp/"):
        return True
    return bool(not p.exists())


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

    kept_projects = {}
    projects = old.get("projects")
    if isinstance(projects, dict):
        for path, entry in projects.items():
            if is_junk_project(path):
                continue
            kept_projects[path] = entry

    tui = old.get("tui") if isinstance(old.get("tui"), dict) else None

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
    for path, entry in kept_projects.items():
        path_esc = path.replace("\\", "\\\\").replace('"', '\\"')
        write_table(lines, f'projects."{path_esc}"', entry)
    if tui is not None:
        write_table(lines, "tui", tui)

    try:
        with open(new_path, "w") as f:
            f.write("\n".join(lines).rstrip("\n") + "\n")
    except OSError as e:
        print(f"error: cannot write {new_path}: {e}", file=sys.stderr)
        return 1

    n = len(kept_projects)
    print(
        f"migrated {n} project trust entr{'y' if n == 1 else 'ies'}"
        f"{' + [tui] state' if tui is not None else ''} -> {new_path}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
