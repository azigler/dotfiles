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
  FAILOVER (dotfiles-kf2i, spec dotfiles-d3ky) every tap's `failover:` list
        entries must (1) be non-empty/non-null, (2) name a DECLARED tap, and
        (3) share the source tap's `type:` — cross-type failover is FORBIDDEN
        v1 ("a seat's charter work is tuned per vendor — silent vendor swap
        mid-loop is a silent-quality event, not a convenience"). Unenforced
        before this bead: only tap-type presence was checked, not the rule
        d3ky actually specified.
  PROFILE (dotfiles-iez1) a `profiles:` entry is a jail/config-dir VARIANT
        of a real tap, not a tap of its own (e.g. `tick`: the same account
        as `personal`, run inside tick-jailed.sh's bwrap sandbox). Every
        profile's `tap:` must name a declared tap; every seat's optional
        `profile:` must name a declared profile. A seat's BILLING is always
        its `tap:` — `profile:` never substitutes for it.
  SEATTAP every seat declares a `tap`, and it names a declared tap
  SEATTAP-CONSISTENCY (dotfiles-e8l0) a seat's own `tap:` and every one of
        its schedules' `tap:` must agree — a seat drawing from `personal`
        cannot have a schedule that bills `work` without the roster
        contradicting itself about which vendor is actually loaded.
  MODEL every seat's `model` is one of the pinned aliases
  SIGIL every seat's `sigil` is EMOJI-PRESENTATION BY PROPERTY
        (Emoji_Presentation=Yes, embedded data below), and additionally
        outside U+2000-U+2BFF bar a small allowlist, off the learned
        denylist, and free of VS16
  SIGIL-UNIQUE (dotfiles-e8l0) no two LIVE seats may share a sigil — the
        court renders the sigil as the row's only glyph column, and two
        seats sharing one makes that column stop disambiguating rows.
  RETIRED an optional top-level `retired:` mapping holds seats that have ended
        (Art. IV: job seats retire, history preserved). Same name grammar; a
        retired name may not collide with a live seat name or any alias.
  HISTORY (only with --histories DIR, dotfiles-qnfk R1/T1/T6/T7) every LIVE and
        every RETIRED seat has <DIR>/<name>.history.md; every history file in
        DIR belongs to a live-or-retired seat; and every file's `integrity:`
        checksum matches its own body, so a HAND-EDITED history — the self-award
        this validator exists to catch — blocks the commit carrying it.
  UNIT  (dotfiles-hfm5) every schedule's `unit:` names a `.timer` file
        actually installed under --systemd-dir (default
        ~/.config/systemd/user) — the roster claiming a unit that was never
        shipped, or was renamed/removed underneath it.
  UNIT-ORPHAN (dotfiles-hfm5) the reverse direction: every ENABLED
        `pulse-*.timer` under --systemd-dir/timers.target.wants/ names a
        seat's schedule OR is listed in the top-level `unit_allowlist:` —
        a live timer nobody in the roster claims (son4's shape: the file
        existing said nothing about whether the roster KNEW about it).

  UNIT/UNIT-ORPHAN ARE WARN-BY-DEFAULT, STRICT VIA --strict-units. Unlike
  every other rule above, these two read HOST STATE (the filesystem under
  --systemd-dir), not just the document — the one input this validator does
  not otherwise depend on. Three reasons that state must not be allowed to
  block a commit by default: (1) a `br`/roster edit legitimately precedes the
  unit install by one commit (chicken-and-egg: you write the schedule row,
  THEN run pulse-inject to lay the timer down) — blocking that ordering makes
  the honest edit sequence impossible; (2) a machine with no
  ~/.config/systemd/user at all (a fresh clone, a non-systemd box, CI) must
  not fail every commit touching seats.yml on that basis alone — WARN reduces
  cleanly to "0 installed, 0 enabled, nothing to flag" wherever the directory
  is simply absent; (3) this is the caution this bead was filed under: "a
  validator that flakes with timer state breaks every roster commit." WARN
  mode never touches the exit code — every violation is still printed, to
  stderr, so nothing is silent — and `--strict-units` promotes the same
  findings to blocking, for a deliberate, out-of-band check (a human running
  it by hand, or a scheduled audit) rather than every pre-commit gate on this
  box.

--emit-json OUT (dotfiles-btw8): after the checks above all pass, write the
        parsed roster to OUT as JSON — the VERBATIM sidecar harnessd relays
        (its own digest-sidecar precedent: dotfiles emits, harnessd relays,
        neither restates). This is the ONE parser; a second emitter script
        would be parser number three, the exact defect this bead refuses.
        Deterministic (`sort_keys=True`), every key/value copied unchanged —
        `charter-line` stays `charter-line` — plus one addition: a top-level
        `_generated` key naming the source, the generator, and DO NOT EDIT
        (JSON has no comments, so the marker is data instead).

Usage:
  validate-seats.py [path] [--histories DIR] [--emit-json OUT]
                    [--systemd-dir DIR] [--strict-units]
                                 # default path: agents/seats.yml relative to
                                 # CWD, or the path passed positionally
                                 # default --systemd-dir: ~/.config/systemd/user
Exit 0 + "OK" on success. Exit 1 + one line per violation on failure.
"""

from __future__ import annotations

import hashlib
import json
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

# ==========================================================================
# THE GLYPH RULE (dotfiles-gl6z). THE PROPERTY IS THE RULE.
# ==========================================================================
# Zig, 2026-08-09, live on the hall court: "some emojis have an extra space,
# the table is stilted." Four ratified sigils — U+1F5DD, U+1F6E1, U+1F56F,
# U+1F54A — sit inside the emoji BLOCKS but carry Emoji_Presentation=No: they
# are TEXT-default. A terminal measures them one cell wide while a renderer
# that assumes "emoji => 2 cells" pads two, and every row carrying one shifts.
# That same property was behind every nerdfont-fallback correction to date —
# the U+2000-U+2BFF block ban was an APPROXIMATION of it, nearly right and
# therefore silently wrong here.
#
# So the rule is the PROPERTY now, checked against data:
#
#   Emoji_Presentation=Yes, from Unicode Emoji 15.0 emoji-data.txt
#   (https://www.unicode.org/Public/emoji/15.0/emoji-data.txt). Extracted
#   2026-08-09 on zig-computer from perl's bundled UCD (Unicode 15.0.0) with
#     perl -MUnicode::UCD=prop_invlist -e '@l=prop_invlist("Emoji_Presentation"); ...'
#   and re-derivable that way. Refresh it when Unicode adds emoji.
#
# WHY THE **Yes** LIST AND NOT THE No LIST. A No-list has to be paired with
# "…and everything else in these blocks is Yes", so an unassigned codepoint, a
# private-use nerdfont glyph, or a block Unicode adds later all default to
# ACCEPTED — the rule fails OPEN on exactly the inputs nobody thought about.
# The Yes list fails closed: unknown => rejected, and the cost of a new emoji
# is a data refresh, which is a commit, not an outage.
#
# The block ban and the denylist below STAY. They are strictly narrower than
# the property and answer a different question — U+26A1 is
# Emoji_Presentation=Yes and STILL renders as a thin nerdfont glyph in Zig's
# terminal. Property first, then Zig's font.
# fmt: off  — kept as a dense table on purpose: this is DATA transcribed from
# emoji-data.txt, and one range per line makes an 81-line wall that nobody
# diffs. Formatter off so a refresh stays a readable diff.
EMOJI_PRESENTATION_RANGES = (
    (0x231A, 0x231B),
    (0x23E9, 0x23EC),
    (0x23F0, 0x23F0),
    (0x23F3, 0x23F3),
    (0x25FD, 0x25FE),
    (0x2614, 0x2615),
    (0x2648, 0x2653),
    (0x267F, 0x267F),
    (0x2693, 0x2693),
    (0x26A1, 0x26A1),
    (0x26AA, 0x26AB),
    (0x26BD, 0x26BE),
    (0x26C4, 0x26C5),
    (0x26CE, 0x26CE),
    (0x26D4, 0x26D4),
    (0x26EA, 0x26EA),
    (0x26F2, 0x26F3),
    (0x26F5, 0x26F5),
    (0x26FA, 0x26FA),
    (0x26FD, 0x26FD),
    (0x2705, 0x2705),
    (0x270A, 0x270B),
    (0x2728, 0x2728),
    (0x274C, 0x274C),
    (0x274E, 0x274E),
    (0x2753, 0x2755),
    (0x2757, 0x2757),
    (0x2795, 0x2797),
    (0x27B0, 0x27B0),
    (0x27BF, 0x27BF),
    (0x2B1B, 0x2B1C),
    (0x2B50, 0x2B50),
    (0x2B55, 0x2B55),
    (0x1F004, 0x1F004),
    (0x1F0CF, 0x1F0CF),
    (0x1F18E, 0x1F18E),
    (0x1F191, 0x1F19A),
    (0x1F1E6, 0x1F1FF),
    (0x1F201, 0x1F201),
    (0x1F21A, 0x1F21A),
    (0x1F22F, 0x1F22F),
    (0x1F232, 0x1F236),
    (0x1F238, 0x1F23A),
    (0x1F250, 0x1F251),
    (0x1F300, 0x1F320),
    (0x1F32D, 0x1F335),
    (0x1F337, 0x1F37C),
    (0x1F37E, 0x1F393),
    (0x1F3A0, 0x1F3CA),
    (0x1F3CF, 0x1F3D3),
    (0x1F3E0, 0x1F3F0),
    (0x1F3F4, 0x1F3F4),
    (0x1F3F8, 0x1F43E),
    (0x1F440, 0x1F440),
    (0x1F442, 0x1F4FC),
    (0x1F4FF, 0x1F53D),
    (0x1F54B, 0x1F54E),
    (0x1F550, 0x1F567),
    (0x1F57A, 0x1F57A),
    (0x1F595, 0x1F596),
    (0x1F5A4, 0x1F5A4),
    (0x1F5FB, 0x1F64F),
    (0x1F680, 0x1F6C5),
    (0x1F6CC, 0x1F6CC),
    (0x1F6D0, 0x1F6D2),
    (0x1F6D5, 0x1F6D7),
    (0x1F6DC, 0x1F6DF),
    (0x1F6EB, 0x1F6EC),
    (0x1F6F4, 0x1F6FC),
    (0x1F7E0, 0x1F7EB),
    (0x1F7F0, 0x1F7F0),
    (0x1F90C, 0x1F93A),
    (0x1F93C, 0x1F945),
    (0x1F947, 0x1F9FF),
    (0x1FA70, 0x1FA7C),
    (0x1FA80, 0x1FA88),
    (0x1FA90, 0x1FABD),
    (0x1FABF, 0x1FAC5),
    (0x1FACE, 0x1FADB),
    (0x1FAE0, 0x1FAE8),
    (0x1FAF0, 0x1FAF8),
)
# fmt: on

# Retained from dotfiles-lbxa: Zig's client font hands classic-symbol
# codepoints to a nerdfont rather than the emoji font, so U+2000-U+2BFF is
# refused outside a small proven-safe allowlist — every member of which is
# ALSO Emoji_Presentation=Yes, so the two rules never disagree on it.
SIGIL_RANGE_ALLOWLIST = {0x2705, 0x2753, 0x2754, 0x274C, 0x2B50}
SIGIL_DENYLIST = {0x1F3A4}  # microphone — falls back to a nerdfont glyph
VS16 = 0xFE0F


def is_emoji_presentation(cp: int) -> bool:
    """True iff the codepoint is Emoji_Presentation=Yes (renders 2 cells)."""
    lo, hi = 0, len(EMOJI_PRESENTATION_RANGES) - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        start, end = EMOJI_PRESENTATION_RANGES[mid]
        if cp < start:
            hi = mid - 1
        elif cp > end:
            lo = mid + 1
        else:
            return True
    return False


def display_width(text: str) -> int:
    """Terminal cells `text` occupies: 2 per Emoji_Presentation=Yes char, else 1.

    Deliberately narrow: it is the width model the hall's column math uses,
    and the hall emits ASCII plus U+00B7 plus glyphs by construction (its own
    header forbids anything else). It does NOT model CJK, combining marks or
    ZWJ sequences — a roster field holding one of those is a roster question.
    """
    return sum(2 if is_emoji_presentation(ord(c)) else 1 for c in text)


def sigil_violation(sigil: str) -> str | None:
    """The SIGIL rule: every char must be a real emoji-presentation glyph."""
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
        if not is_emoji_presentation(cp):
            return (
                f"U+{cp:04X} is Emoji_Presentation=No (TEXT-default): the terminal renders it "
                f"1 cell wide while the court pads 2, so every row carrying it is stilted "
                f"(dotfiles-gl6z), sigil={sigil!r}"
            )
    return None


# --------------------------------------------------------------------------
# Histories (dotfiles-qnfk R1) — the roster and refs/seats/ must AGREE
# --------------------------------------------------------------------------
HISTORY_SUFFIX = ".history.md"


def history_body(text: str) -> str | None:
    """Every byte after the closing frontmatter delimiter, or None if the file
    has no frontmatter. Mirrors ``_hist_body`` in agents/lib/seat-history.sh —
    the two must agree byte-for-byte or the checksum is meaningless, which is
    why both are line-based: awk prints one trailing newline per line, so a
    generated file (which always ends in one) hashes identically on both
    sides. A file that does NOT — i.e. one somebody hand-edited — hashes
    differently here, and differently is the whole signal."""
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].rstrip("\n") != "---":
        return None
    for i in range(1, len(lines)):
        if lines[i].rstrip("\n") == "---":
            return "".join(lines[i + 1 :])
    return None


def history_front(text: str, key: str) -> str | None:
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return None
    for ln in lines[1:]:
        if ln == "---":
            return None
        if ln.startswith(key + ": "):
            return ln[len(key) + 2 :]
    return None


def history_violations(doc: dict, directory: Path) -> list:
    errors = []
    live = set((doc.get("seats") or {}).keys())
    retired = set((doc.get("retired") or {}).keys())
    known = live | retired

    if not directory.is_dir():
        return [
            f"HISTORY: --histories {directory} is not a directory — every seat's "
            f"career record is supposed to live there (dotfiles-qnfk R1)"
        ]

    on_disk = {
        p.name[: -len(HISTORY_SUFFIX)]
        for p in directory.iterdir()
        if p.name.endswith(HISTORY_SUFFIX)
    }

    for name in sorted(known - on_disk):
        kind = "retired" if name in retired else "seat"
        errors.append(
            f"HISTORY: {kind} '{name}' has NO history file "
            f"({directory / (name + HISTORY_SUFFIX)}). Run: "
            f"bash agents/lib/seat-history.sh init"
        )
    for name in sorted(on_disk - known):
        errors.append(
            f"HISTORY: orphan history '{name}{HISTORY_SUFFIX}' matches no live "
            f"seat and no `retired:` entry. A retired seat KEEPS its history "
            f"(Art. IV) — move its roster row to `retired:` rather than "
            f"deleting either one."
        )

    for name in sorted(known & on_disk):
        path = directory / (name + HISTORY_SUFFIX)
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            errors.append(f"HISTORY: cannot read {path}: {exc}")
            continue
        body = history_body(text)
        want = history_front(text, "integrity")
        if body is None or want is None:
            errors.append(
                f"HISTORY: {path.name} has no generated frontmatter "
                f"(seat/office/appointed/generator/integrity). It was not "
                f"written by agents/lib/seat-history.sh."
            )
            continue
        got = "sha256:" + hashlib.sha256(body.encode("utf-8")).hexdigest()
        if want != got:
            errors.append(
                f"HISTORY: {path.name} FAILS its own integrity checksum "
                f"(frontmatter says {want}, body hashes to {got}). A history is "
                f"machine-written only: a hand-added entry is exactly the "
                f"self-award dotfiles-qnfk R6/T6 exists to refuse."
            )
    return errors


def glyph_violation(ch: str) -> str | None:
    """The same rule applied to ONE character of RENDERED OUTPUT.

    The hall's court view is ASCII + U+00B7 + glyphs. Anything below U+2000 is
    plain text and passes; at or above it the character is claiming to be a
    glyph and must satisfy the whole sigil rule. This is what a renderer's
    output gets scanned with — `sigil_violation` is for a ROSTER FIELD, where
    even ASCII is wrong.
    """
    if not ch:
        return None
    if ord(ch) < 0x2000 and ord(ch) != VS16:
        return None
    return sigil_violation(ch)


# --------------------------------------------------------------------------
# Units (dotfiles-hfm5) — the roster and the installed systemd state must
# AGREE, both directions. See the UNIT/UNIT-ORPHAN docstring above for why
# this is WARN-by-default.
# --------------------------------------------------------------------------


def systemd_state(systemd_dir: Path) -> tuple:
    """(installed, enabled) — bare unit names (no ".timer" suffix).

    installed: every *.timer file directly under systemd_dir.
    enabled:   every *.timer entry under systemd_dir/timers.target.wants/ —
               that symlink is what `systemctl --user enable` actually
               writes, so reading it is equivalent to `systemctl is-enabled`
               without shelling out to systemctl (the seam: a test points
               --systemd-dir at a scratch tree with no systemd, no dbus, and
               no live-box dependency at all).
    A missing directory yields an empty set on that side, not an error —
    see the WARN-by-default rationale above.
    """
    installed = set()
    if systemd_dir.is_dir():
        for p in systemd_dir.glob("*.timer"):
            installed.add(p.name[: -len(".timer")])
    enabled = set()
    wants = systemd_dir / "timers.target.wants"
    if wants.is_dir():
        for p in wants.iterdir():
            if p.name.endswith(".timer"):
                enabled.add(p.name[: -len(".timer")])
    return installed, enabled


def unit_violations(doc: dict, systemd_dir: Path) -> list:
    """Both directions of the UNIT rule. Always returns the full tagged list
    regardless of strict/warn mode — main() decides whether these block."""
    errors = []
    seats = doc.get("seats") or {}
    allowlist = {x for x in (doc.get("unit_allowlist") or []) if x}
    installed, enabled = systemd_state(systemd_dir)

    scheduled = set()
    for seat_name, seat in seats.items():
        seat = seat or {}
        for sched in seat.get("schedules") or []:
            sched = sched or {}
            unit = sched.get("unit")
            if not unit:
                continue
            scheduled.add(unit)
            if unit not in installed:
                errors.append(
                    f"UNIT: seat '{seat_name}' schedule names unit '{unit}', "
                    f"which has no installed {unit}.timer under {systemd_dir} "
                    f"(schedule -> unit direction, dotfiles-hfm5)"
                )

    for unit in sorted(enabled - scheduled - allowlist):
        if not unit.startswith("pulse-"):
            continue  # non-pulse timers are out of the roster's jurisdiction
        errors.append(
            f"UNIT-ORPHAN: '{unit}.timer' is ENABLED under {systemd_dir} but "
            f"no seat schedule names it and it is not listed in "
            f"unit_allowlist: (unit -> schedule direction, dotfiles-hfm5)"
        )
    return errors


def validate(doc: dict) -> list:
    errors = []

    taps = doc.get("taps") or {}
    seats = doc.get("seats") or {}
    retired = doc.get("retired") or {}

    # --- RETIRED: schema-forward, validator-enforced (R5) -----------------
    # seats.yml has no `retired:` section yet — the first retirement writes
    # one. Accepting and CHECKING it now means the day a job seat ends, the
    # move is a data edit against a gate that already exists, not a schema
    # change made under time pressure. Same posture as `charter: null`.
    for name in retired:
        if not SEAT_NAME_RE.match(name):
            errors.append(
                f"RETIRED: retired seat name {name!r} does not match "
                f"^[a-z][a-z0-9-]{{1,31}}$"
            )
        if name in seats:
            errors.append(
                f"RETIRED: '{name}' is listed BOTH as a live seat and as retired "
                f"— a seat is one or the other"
            )

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

    # --- FAILOVER (dotfiles-kf2i, d3ky v1): exist, be known, be same-type --
    # d3ky's own words: "same-TYPE failover is free; cross-type failover
    # FORBIDDEN v1". This was previously unenforced — only tap-TYPE presence
    # was checked, never the failover list's own contract.
    for tap_name, tap in taps.items():
        tap = tap or {}
        ttype = tap.get("type")
        for target in tap.get("failover") or []:
            if not target:
                errors.append(
                    f"FAILOVER: tap '{tap_name}' has an empty/null failover "
                    f"entry — every failover target must name a real tap"
                )
                continue
            if target not in taps:
                errors.append(
                    f"FAILOVER: tap '{tap_name}' fails over to {target!r}, "
                    f"which is not a declared tap; known: {sorted(taps)}"
                )
                continue
            target_type = (taps[target] or {}).get("type")
            if target_type != ttype:
                errors.append(
                    f"FAILOVER: tap '{tap_name}' (type {ttype!r}) fails over "
                    f"to '{target}' (type {target_type!r}) — cross-type "
                    f"failover is FORBIDDEN v1 (dotfiles-d3ky): a seat's "
                    f"charter work is tuned per vendor, a silent vendor "
                    f"swap mid-loop is a silent-quality event"
                )

    # --- PROFILE (dotfiles-iez1): 'tick' is a jail profile, not a tap --------
    # A profile is an optional per-seat config-dir VARIANT of a real, declared
    # tap — it never carries its own billing. Two directions to check, mirror
    # of FAILOVER's own-tap-reference rule: every profile's `tap:` must name a
    # declared tap, and every seat's optional `profile:` must name a declared
    # profile. A seat's BILLING stays its `tap:` alone; `profile:` is metadata.
    profiles = doc.get("profiles") or {}
    for profile_name, profile in profiles.items():
        profile = profile or {}
        ptap = profile.get("tap")
        if ptap is None:
            errors.append(
                f"PROFILE: profile '{profile_name}' is missing required 'tap'"
            )
        elif ptap not in taps:
            errors.append(
                f"PROFILE: profile '{profile_name}' names tap {ptap!r}, which "
                f"is not declared under `taps:`; known: {sorted(taps)}"
            )

    for seat_name, seat in seats.items():
        seat = seat or {}
        seat_profile = seat.get("profile")
        if seat_profile is not None and seat_profile not in profiles:
            errors.append(
                f"PROFILE: seat '{seat_name}' declares profile {seat_profile!r}, "
                f"which is not declared under `profiles:`; known: {sorted(profiles)}"
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

    # --- SEATTAP: every seat declares the tap it draws from ------------------
    # Zig's ruling, 2026-08-09, off the live court: personal IS the default, and
    # the roster STATES its defaults rather than leaving the reader — or the
    # hall's tap column — to render `-`. `-` in that column now means only one
    # thing, an UNREGISTERED window, where the emptiness is the honest answer.
    for seat_name, seat in seats.items():
        seat = seat or {}
        tap = seat.get("tap")
        if tap is None:
            errors.append(
                f"SEATTAP: seat '{seat_name}' declares no 'tap' — every seat "
                f"draws from one; say which (personal is the default, but say it)"
            )
        elif tap not in taps:
            errors.append(
                f"SEATTAP: seat '{seat_name}' names tap {tap!r}, which is not "
                f"declared under `taps:`; known: {sorted(taps)}"
            )

    # --- SEATTAP-CONSISTENCY (dotfiles-e8l0): seat tap <-> schedule tap ------
    # A seat's own `tap:` is the seat's declared billing source; a schedule
    # binding a DIFFERENT tap is the roster contradicting itself about which
    # vendor a given run actually draws from — the exact drift this bead was
    # filed against ("a seat could declare tap: personal while its schedules
    # bind work").
    for seat_name, seat in seats.items():
        seat = seat or {}
        seat_tap = seat.get("tap")
        for sched in seat.get("schedules") or []:
            sched = sched or {}
            sched_tap = sched.get("tap")
            unit = sched.get("unit", "<unnamed>")
            if (
                seat_tap is not None
                and sched_tap is not None
                and sched_tap != seat_tap
            ):
                errors.append(
                    f"SEATTAP-CONSISTENCY: seat '{seat_name}' draws from tap "
                    f"{seat_tap!r} but its schedule '{unit}' binds tap "
                    f"{sched_tap!r} — a seat's schedules must draw from the "
                    f"same tap as the seat itself"
                )

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

    # --- SIGIL-UNIQUE (dotfiles-e8l0): no two live seats share a sigil -------
    # The court renders the sigil as the row's only glyph column; two seats
    # sharing one collapses that column back to ambiguous, the exact gap the
    # hall-wave builder reported.
    sigil_owner: dict = {}
    for seat_name, seat in seats.items():
        seat = seat or {}
        sigil = seat.get("sigil")
        if not sigil:
            continue
        if sigil in sigil_owner and sigil_owner[sigil] != seat_name:
            errors.append(
                f"SIGIL-UNIQUE: sigil {sigil!r} is shared by both "
                f"'{sigil_owner[sigil]}' and '{seat_name}' — the court's "
                f"glyph column must disambiguate rows, not merge them"
            )
        else:
            sigil_owner.setdefault(sigil, seat_name)

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


# --------------------------------------------------------------------------
# JSON sidecar (dotfiles-btw8) — agents/seats.json, the VERBATIM relay
# --------------------------------------------------------------------------
# Governing rule (the bead's own words): seats.yml DECLARES, state.json
# OBSERVES, neither restates the other. This function is the boundary of
# "declares": it copies the parsed roster into JSON and adds exactly one
# thing JSON can't express any other way — the DO NOT EDIT marker — and
# renames NOTHING. harnessd relays this file verbatim; any enrichment (e.g.
# live_windows) is the fleet JOIN outside the relay, not this emitter's job.

GENERATED_SOURCE = "agents/seats.yml"
GENERATED_GENERATOR = "agents/lib/validate-seats.py --emit-json (dotfiles-btw8)"
GENERATED_WARNING = (
    "DO NOT EDIT — this file is generated. Regenerate with: "
    "python3 agents/lib/validate-seats.py agents/seats.yml "
    "--emit-json agents/seats.json"
)


def _identity(key: str) -> str:
    """Key-spelling passthrough — the ONLY seam a rename could enter through.

    `_rename_keys` calls this on every key it copies and nothing else touches
    key spelling, so this one-line function is exactly what a "helpfully"
    renamed key (e.g. `charter-line` -> `charter_line`) would have to go
    through. The planted-rename mutant (mutate-validate-seats.sh M5) flips
    this line; the round-trip test (test-validate-seats.sh EMIT-ROUNDTRIP)
    is what has to catch it.
    """
    return key


def _rename_keys(node):
    """Deep-copies `node`, running every dict key through `_identity`."""
    if isinstance(node, dict):
        return {_identity(k): _rename_keys(v) for k, v in node.items()}
    if isinstance(node, list):
        return [_rename_keys(v) for v in node]
    return node


def render_seats_json(doc: dict) -> str:
    """Deterministic JSON text for the parsed roster `doc`.

    `sort_keys=True` gives byte-stable output across runs (roster's own key
    spellings are preserved VERBATIM by `_rename_keys`/`_identity`; sorting
    only orders them, it never renames them). The one addition is the
    top-level `_generated` marker — JSON has no comment syntax, so DO NOT
    EDIT has to be a real key instead of a header comment.
    """
    payload = _rename_keys(doc)
    if "_generated" in payload:
        raise ValueError(
            "seats.yml already declares a top-level '_generated' key — "
            "collision with the sidecar's own generated-marker key"
        )
    payload["_generated"] = {
        "source": GENERATED_SOURCE,
        "generator": GENERATED_GENERATOR,
        "warning": GENERATED_WARNING,
    }
    # ensure_ascii=False: sigils are the whole point of the roster, and an
    # escaped \uXXXX diff on every git-tracked emoji change is unreadable.
    return (
        json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    )


def main(argv: list) -> int:
    # Hand-parsed, argparse-free, for the same reason the YAML parser is
    # hand-written: this runs as a pre-commit gate on every box, and its only
    # dependency is python3 itself.
    positional: list = []
    histories: Path | None = None
    emit_json_path: Path | None = None
    systemd_dir = Path("~/.config/systemd/user").expanduser()
    strict_units = False
    rest = list(argv[1:])
    while rest:
        arg = rest.pop(0)
        if arg == "--histories":
            if not rest:
                print(
                    "validate-seats: FAIL — --histories needs a directory",
                    file=sys.stderr,
                )
                return 1
            histories = Path(rest.pop(0))
        elif arg.startswith("--histories="):
            histories = Path(arg[len("--histories=") :])
        elif arg == "--emit-json":
            if not rest:
                print(
                    "validate-seats: FAIL — --emit-json needs an output path",
                    file=sys.stderr,
                )
                return 1
            emit_json_path = Path(rest.pop(0))
        elif arg.startswith("--emit-json="):
            emit_json_path = Path(arg[len("--emit-json=") :])
        elif arg == "--systemd-dir":
            if not rest:
                print(
                    "validate-seats: FAIL — --systemd-dir needs a directory",
                    file=sys.stderr,
                )
                return 1
            systemd_dir = Path(rest.pop(0)).expanduser()
        elif arg.startswith("--systemd-dir="):
            systemd_dir = Path(arg[len("--systemd-dir=") :]).expanduser()
        elif arg == "--strict-units":
            strict_units = True
        else:
            positional.append(arg)

    path = Path(positional[0]) if positional else Path("agents/seats.yml")
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

    uviol = unit_violations(doc, systemd_dir)
    if uviol:
        if strict_units:
            errors += uviol
        else:
            print(
                f"validate-seats: WARN — {len(uviol)} unit-state note(s) "
                f"against {systemd_dir} (pass --strict-units to enforce):",
                file=sys.stderr,
            )
            for u in uviol:
                print(f"  - {u}", file=sys.stderr)

    if histories is not None:
        errors += history_violations(doc, histories)
    if errors:
        print(
            f"validate-seats: FAIL — {len(errors)} violation(s) in {path}:",
            file=sys.stderr,
        )
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1

    if emit_json_path is not None:
        emit_json_path.write_text(render_seats_json(doc))
        print(
            f"validate-seats: emitted {emit_json_path} from {path} "
            f"({len(doc.get('seats') or {})} seats)"
        )
        return 0

    n_retired = len(doc.get("retired") or {})
    extra = f", {n_retired} retired" if n_retired else ""
    extra += f", histories in {histories}" if histories is not None else ""
    print(
        f"validate-seats: OK — {path} ({len(doc.get('seats') or {})} seats, "
        f"{len(doc.get('taps') or {})} taps{extra})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
