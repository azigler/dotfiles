#!/usr/bin/env python3
"""validate-seats.py — schema + policy validator for agents/seats.yml (v1).

Bead: dotfiles-lbxa. Contract: dotfiles-seat-address-spec-uikg. Tap-type
abstraction: dotfiles-d3ky.

STDLIB-ONLY BY DESIGN (no PyYAML dependency for a fleet-wide pre-commit gate).
Ships its own minimal YAML-subset parser covering exactly the constructs
seats.yml v1 uses: block mappings, block sequences (`- key: value` items and
plain scalar items), flow lists (`[a, b]` / `[]`), quoted/unquoted scalars,
`null`/`~`, booleans, and `#` comments (respecting quotes). It is NOT a
general YAML parser — do not point it at arbitrary YAML.

Checks enforced (each has a dedicated fixture in test-validate-seats.sh):
  R1   seat name grammar: ^[a-z][a-z0-9-]{1,31}$
  R1b  alias-vs-name uniqueness: an alias must not equal ANY seat's name
  R1c  alias-vs-alias uniqueness: an alias must not repeat across seats
  R4   one-tap-per-window: every schedule binding to the same
       (session, window) pair must name the same tap
  WINDOW every schedule's window: must resolve to a seat name or a
        listed alias (dotfiles-bi2i) — an unlisted window has no
        resolvable seat and R5 would refuse it
  TAP  every tap declares a `type`, and it is one of the known types
  MODEL every seat's `model` is one of the pinned aliases
  SIGIL every seat's `sigil` is emoji-presentation: reject U+2000-U+2BFF
        outside a small allowlist, reject the learned denylist, reject VS16

Usage:
  validate-seats.py [path]      # default: agents/seats.yml relative to CWD,
                                 # or the path passed on argv[1]
Exit 0 + "OK" on success. Exit 1 + one line per violation on failure.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# --------------------------------------------------------------------------
# Minimal YAML-subset parser
# --------------------------------------------------------------------------


class YamlError(Exception):
    pass


def _strip_comment(line: str) -> str:
    in_s = in_d = False
    for i, c in enumerate(line):
        if c == "'" and not in_d:
            in_s = not in_s
        elif c == '"' and not in_s:
            in_d = not in_d
        elif (
            c == "#"
            and not in_s
            and not in_d
            and (i == 0 or line[i - 1] in " \t")
        ):
            return line[:i]
    return line


def _split_flow_items(inner: str) -> list:
    items, buf, in_s, in_d, depth = [], "", False, False, 0
    for c in inner:
        if c == "'" and not in_d:
            in_s = not in_s
        elif c == '"' and not in_s:
            in_d = not in_d
        elif c in "[{" and not in_s and not in_d:
            depth += 1
        elif c in "]}" and not in_s and not in_d:
            depth -= 1
        if c == "," and not in_s and not in_d and depth == 0:
            items.append(buf.strip())
            buf = ""
        else:
            buf += c
    if buf.strip():
        items.append(buf.strip())
    return items


def _parse_scalar(s: str):
    s = s.strip()
    if s == "" or s in ("null", "~"):
        return None
    if s == "true":
        return True
    if s == "false":
        return False
    if s.startswith("[") and s.endswith("]"):
        inner = s[1:-1].strip()
        return (
            []
            if inner == ""
            else [_parse_scalar(i) for i in _split_flow_items(inner)]
        )
    if s.startswith("{") and s.endswith("}"):
        inner = s[1:-1].strip()
        return {}  # empty flow maps only; not otherwise used in seats.yml v1
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        return s[1:-1]
    try:
        return int(s)
    except ValueError:
        pass
    return s


def _split_key_value(content: str) -> tuple:
    in_s = in_d = False
    for i, c in enumerate(content):
        if c == "'" and not in_d:
            in_s = not in_s
        elif c == '"' and not in_s:
            in_d = not in_d
        elif (
            c == ":"
            and not in_s
            and not in_d
            and (i + 1 == len(content) or content[i + 1] in " \t")
        ):
            return content[:i].strip(), content[i + 1 :].strip()
    raise YamlError(f"expected 'key: value' or 'key:', got: {content!r}")


class _Lines:
    """Indentation-tagged, comment-and-blank-stripped source lines."""

    def __init__(self, text: str):
        self.entries = []
        for raw in text.splitlines():
            stripped_of_comment = _strip_comment(raw)
            if not stripped_of_comment.strip():
                continue
            indent = len(stripped_of_comment) - len(
                stripped_of_comment.lstrip(" ")
            )
            self.entries.append((indent, stripped_of_comment.strip()))
        self.i = 0

    def peek(self):
        return self.entries[self.i] if self.i < len(self.entries) else None

    def advance(self):
        self.i += 1


def _parse_mapping(lines: _Lines, indent: int) -> dict:
    result = {}
    while True:
        top = lines.peek()
        if top is None or top[0] != indent or top[1].startswith("- "):
            break
        _, content = top
        lines.advance()
        key, val = _split_key_value(content)
        if val != "":
            result[key] = _parse_scalar(val)
            continue
        nxt = lines.peek()
        if nxt is not None and nxt[0] > indent:
            result[key] = _parse_node(lines, nxt[0])
        else:
            result[key] = None
    return result


def _parse_sequence(lines: _Lines, indent: int) -> list:
    result = []
    while True:
        top = lines.peek()
        if top is None or top[0] != indent or not top[1].startswith("- "):
            break
        _, content = top
        lines.advance()
        item = content[2:].strip()
        if item == "":
            nxt = lines.peek()
            result.append(
                _parse_node(lines, nxt[0]) if nxt and nxt[0] > indent else None
            )
            continue
        try:
            key, val = _split_key_value(item)
        except YamlError:
            result.append(_parse_scalar(item))
            continue
        # Inline mapping opened on the dash line; sibling keys are indented
        # to align under the text after "- " (i.e. indent + 2).
        mapping = {key: (_parse_scalar(val) if val != "" else None)}
        while True:
            nxt = lines.peek()
            if nxt is None or nxt[0] <= indent:
                break
            nk, ncontent = nxt
            k2, v2 = _split_key_value(ncontent)
            lines.advance()
            if v2 != "":
                mapping[k2] = _parse_scalar(v2)
            else:
                after = lines.peek()
                mapping[k2] = (
                    _parse_node(lines, after[0])
                    if after and after[0] > nk
                    else None
                )
        result.append(mapping)
    return result


def _parse_node(lines: _Lines, indent: int):
    top = lines.peek()
    if top is None or top[0] < indent:
        return None
    if top[1].startswith("- "):
        return _parse_sequence(lines, top[0])
    return _parse_mapping(lines, top[0])


def load_seats_yaml(text: str) -> dict:
    lines = _Lines(text)
    top = lines.peek()
    if top is None:
        return {}
    return _parse_mapping(lines, top[0])


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------

SEAT_NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,31}$")
KNOWN_TAP_TYPES = {"claude", "codex"}
KNOWN_MODELS = {"fable", "opus", "sonnet", "haiku"}

# Sigil rule (AGENTS.md user section / dotfiles-lbxa AC):
# reject classic-symbol codepoints U+2000-U+2BFF (Zig's terminal hands these
# to a nerdfont, not the emoji font) except a small proven-safe allowlist;
# reject the learned denylist; reject VS16 (never rely on it to force emoji
# presentation).
SIGIL_RANGE_ALLOWLIST = {0x2705, 0x2753, 0x2754, 0x274C, 0x2B50}
SIGIL_DENYLIST = {0x1F3A4}  # microphone — falls back to a nerdfont glyph
VS16 = 0xFE0F


def sigil_violation(sigil: str) -> str | None:
    if not sigil:
        return "empty sigil"
    for ch in sigil:
        cp = ord(ch)
        if cp == VS16:
            return f"contains VS16 (U+FE0F) — never rely on VS16 for emoji presentation, sigil={sigil!r}"
        if cp in SIGIL_DENYLIST:
            return f"U+{cp:04X} is denylisted (known nerdfont fallback), sigil={sigil!r}"
        if 0x2000 <= cp <= 0x2BFF and cp not in SIGIL_RANGE_ALLOWLIST:
            return (
                f"U+{cp:04X} is in U+2000-U+2BFF (classic-symbol range; falls back to a "
                f"nerdfont glyph on Zig's terminal) and not in the allowlist, sigil={sigil!r}"
            )
    return None


def validate(doc: dict) -> list:
    errors = []

    taps = doc.get("taps") or {}
    seats = doc.get("seats") or {}

    # --- taps: type required + known -------------------------------------
    for tap_name, tap in taps.items():
        tap = tap or {}
        ttype = tap.get("type")
        if ttype is None:
            errors.append(f"TAP: tap '{tap_name}' is missing required 'type'")
        elif ttype not in KNOWN_TAP_TYPES:
            errors.append(
                f"TAP: tap '{tap_name}' has unknown type {ttype!r}; "
                f"allowed: {sorted(KNOWN_TAP_TYPES)}"
            )

    seat_names = list(seats.keys())
    seat_name_set = set(seat_names)

    # --- R1: seat name grammar --------------------------------------------
    for name in seat_names:
        if not SEAT_NAME_RE.match(name):
            errors.append(
                f"R1: seat name {name!r} does not match ^[a-z][a-z0-9-]{{1,31}}$"
            )

    # --- R1b/R1c: alias uniqueness ----------------------------------------
    alias_owner = {}  # alias -> first seat that declared it
    for seat_name, seat in seats.items():
        seat = seat or {}
        for alias in seat.get("aliases") or []:
            if alias in seat_name_set:
                errors.append(
                    f"ALIAS-VS-NAME: seat '{seat_name}' declares alias {alias!r}, "
                    f"which is already a seat NAME"
                )
            if alias in alias_owner and alias_owner[alias] != seat_name:
                errors.append(
                    f"ALIAS-VS-ALIAS: alias {alias!r} is declared by both "
                    f"'{alias_owner[alias]}' and '{seat_name}'"
                )
            else:
                alias_owner.setdefault(alias, seat_name)

    # --- MODEL: pinned set ---------------------------------------------------
    for seat_name, seat in seats.items():
        seat = seat or {}
        model = seat.get("model")
        if model not in KNOWN_MODELS:
            errors.append(
                f"MODEL: seat '{seat_name}' has model {model!r}; allowed: {sorted(KNOWN_MODELS)}"
            )

    # --- SIGIL ----------------------------------------------------------------
    for seat_name, seat in seats.items():
        seat = seat or {}
        sigil = seat.get("sigil")
        reason = sigil_violation(sigil if isinstance(sigil, str) else "")
        if reason:
            errors.append(
                f"SIGIL: seat '{seat_name}' sigil rejected — {reason}"
            )

    # --- WINDOW: schedule window must resolve to a seat name or alias --------
    resolvable = seat_name_set | set(alias_owner.keys())
    for seat_name, seat in seats.items():
        seat = seat or {}
        for sched in seat.get("schedules") or []:
            sched = sched or {}
            window = sched.get("window")
            unit = sched.get("unit", "<unnamed>")
            if window not in resolvable:
                errors.append(
                    f"WINDOW: seat '{seat_name}/{unit}' schedule window "
                    f"{window!r} is not a seat name or a listed alias"
                )

    # --- R4: one-tap-per-window (qualified by session, per R7) ---------------
    # window_key -> {tap: [ "seat/unit", ... ]}
    window_taps: dict = {}
    for seat_name, seat in seats.items():
        seat = seat or {}
        for sched in seat.get("schedules") or []:
            sched = sched or {}
            window = sched.get("window")
            session = sched.get("session")
            tap = sched.get("tap")
            unit = sched.get("unit", "<unnamed>")
            key = (session, window)
            window_taps.setdefault(key, {}).setdefault(tap, []).append(
                f"{seat_name}/{unit}"
            )

    for (session, window), by_tap in window_taps.items():
        if len(by_tap) > 1:
            detail = "; ".join(
                f"tap={t!r} <- {names}"
                for t, names in sorted(
                    by_tap.items(), key=lambda kv: str(kv[0])
                )
            )
            errors.append(
                f"R4: window '{window}' (session {session!r}) is bound to more than one "
                f"tap across its schedules: {detail}"
            )

    return errors


def main(argv: list) -> int:
    path = Path(argv[1]) if len(argv) > 1 else Path("agents/seats.yml")
    if not path.exists():
        print(f"validate-seats: FAIL — file not found: {path}", file=sys.stderr)
        return 1
    text = path.read_text()
    try:
        doc = load_seats_yaml(text)
    except YamlError as e:
        print(f"validate-seats: FAIL — parse error: {e}", file=sys.stderr)
        return 1

    if doc.get("schema") != 1:
        print(
            f"validate-seats: FAIL — unsupported schema: {doc.get('schema')!r} (want 1)",
            file=sys.stderr,
        )
        return 1

    errors = validate(doc)
    if errors:
        print(
            f"validate-seats: FAIL — {len(errors)} violation(s) in {path}:",
            file=sys.stderr,
        )
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1

    print(
        f"validate-seats: OK — {path} ({len(doc.get('seats') or {})} seats, {len(doc.get('taps') or {})} taps)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
