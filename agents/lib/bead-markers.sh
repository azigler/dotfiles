#!/bin/bash
# bead-markers.sh — ONE grammar implementation for the fleet/outward marker
# fields named by 69qr (R1c `fleet:`, R2 `fleet-model:`) and htqt (R4
# `outward:`) but never given a field, schema, or writer anywhere in the
# codebase (dotfiles-dh89 — grep proved them prose-only).
#
# CONVENTION DECIDED (dotfiles-dh89, 2026-08-09): br 0.2.16 has NO key/value
# metadata verb. `br update --agent-context` sets a governing-instructions
# JSON blob for a different subsystem (beads_rust#297, descendant-inherited
# context), not a general marker store. `br label` DOES exist and is real,
# but it is a flat, valueless tag namespace — right shape for `friction`
# (SKILL.md's existing convention), wrong shape for `fleet-model: opus`,
# which needs a VALUE, not just presence/absence. So markers live as plain
# text lines inside the bead's `--description`, one marker per line, with a
# STRICT grammar both this file's readers and its writer share:
#
#   <Key>:<one-or-more-spaces><token><optional trailing spaces><end of line>
#
# <Key> is matched case-insensitively but must be followed IMMEDIATELY by
# ':' — so `Fleet:` never matches a `Fleet-Model:` line and `Fleetish:` never
# matches `Fleet:` (no word-boundary needed; the colon anchor already does
# it). <token> is `[A-Za-z0-9_-]+` — no spaces, no punctuation that would let
# a value smuggle a second marker onto the same line.
#
# Boolean markers (`fleet`, `outward`) are TRUE iff their token is EXACTLY
# "yes" (case-insensitive). `fleet: yesterday` is a WELL-FORMED line with a
# real captured value ("yesterday") — it is just not a true one.
# marker_get always tells you what is actually written; marker_is_fleet is
# the one place that collapses that to a boolean, and it is the boolean
# collapse a "loosened" grammar would target (e.g. prefix-matching "yes*"
# instead of requiring the exact token) — see mutate-bead-markers.sh.
#
# WHO MAY SET EACH MARKER is documented normatively in
# agents/skills/beads/SKILL.md's MARKERS section — this header is
# descriptive of the grammar only, that section is the actual contract.
#
# Consumers (drain, outward guard — later beads) import this file and call
# ONLY the ID-BASED API at the bottom. Nothing here calls `br close` /
# `br update --status` / `br create` — only `br show` (read) and
# `br update --description` (the marker write itself).

# ---------------------------------------------------------------------------
# I/O SEAM — the only two functions that touch `br`. Tests stub these two
# instead of the real binary, so the grammar is proven correct without ever
# reading or mutating real bead state.
# ---------------------------------------------------------------------------

# _bm_br_show_description <bead-id> -> prints the bead's description on
# stdout and returns 0, or prints nothing and returns 1 on any failure.
# `br show <id> --json` returns a LIST, not an object (br 0.2.16 quirk
# documented in /beads) — index [0].
_bm_br_show_description() {
  local id=$1
  br show "$id" --json 2>/dev/null | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)
    row = rows[0] if isinstance(rows, list) else rows
    sys.stdout.write(row.get("description") or "")
except Exception:
    sys.exit(1)
'
}

# _bm_br_update_description <bead-id> <new-description>
_bm_br_update_description() {
  local id=$1 desc=$2
  br update "$id" --description "$desc" >/dev/null
}

# ---------------------------------------------------------------------------
# PURE GRAMMAR — no I/O, fully unit-testable, shared by every reader/writer.
# ---------------------------------------------------------------------------

# marker_key_for <marker> -> canonical key string on stdout, or return 1 for
# an unrecognized marker name.
marker_key_for() {
  case "$1" in
    fleet)       printf 'Fleet' ;;
    fleet-model) printf 'Fleet-Model' ;;
    outward)     printf 'Outward' ;;
    *)           return 1 ;;
  esac
}

# _bm_line_regex <key> -> the anchored ERE for a well-formed marker line,
# capturing the value in \1. Callers match case-insensitively
# (grep -i / sed ...I).
_bm_line_regex() {
  printf '^[[:space:]]*%s:[[:space:]]+([A-Za-z0-9_-]+)[[:space:]]*$' "$1"
}

# marker_extract <marker> <text> -> prints the LAST well-formed value for
# <marker> found in <text> and returns 0; prints nothing and returns 1 if no
# well-formed line exists; returns 2 for an unrecognized marker name. Pure —
# no br call.
marker_extract() {
  local marker=$1 text=$2 key re line
  key=$(marker_key_for "$marker") || return 2
  re=$(_bm_line_regex "$key")
  line=$(printf '%s\n' "$text" | grep -iE "$re" | tail -n1)
  [ -n "$line" ] || return 1
  printf '%s\n' "$line" | sed -E "s/$re/\1/I"
}

# marker_bool_from_value <value> -> return 0 iff <value> is exactly "yes"
# (case-insensitive), 1 otherwise. THE place a "loosened" grammar hides —
# e.g. a prefix match ([Yy][Ee][Ss]*) would wrongly admit "yesterday".
marker_bool_from_value() {
  case "$1" in
    [Yy][Ee][Ss]) return 0 ;;
    *)            return 1 ;;
  esac
}

# marker_strip <marker> <text> -> prints <text> with every well-formed line
# for <marker> removed. Used by marker_set before appending the new line so
# re-setting a marker never leaves a stale duplicate.
marker_strip() {
  local marker=$1 text=$2 key re
  key=$(marker_key_for "$marker") || { printf '%s' "$text"; return 2; }
  re=$(_bm_line_regex "$key")
  printf '%s\n' "$text" | grep -ivE "$re"
}

# ---------------------------------------------------------------------------
# ID-BASED API — what the drain and the outward guard actually import.
# ---------------------------------------------------------------------------

# marker_get <bead-id> <marker> -> prints the value on stdout; return codes
# match marker_extract (0 found / 1 not found / 2 unrecognized marker), plus
# 1 if the bead's description could not be read at all.
marker_get() {
  local id=$1 marker=$2 text
  text=$(_bm_br_show_description "$id") || return 1
  marker_extract "$marker" "$text"
}

# marker_is_fleet <bead-id> -> return 0 iff the bead carries `fleet: yes`
# (grammar-exact), 1 otherwise (absent, malformed, or any other value).
marker_is_fleet() {
  local id=$1 value
  value=$(marker_get "$id" fleet) || return 1
  marker_bool_from_value "$value"
}

# marker_set <bead-id> <marker> <value> -> replaces (or appends) the marker
# line and writes the bead's description back via `br update`. <value> must
# match the token grammar ([A-Za-z0-9_-]+, non-empty); a boolean marker
# (fleet, outward) SHOULD be set to "yes" only by convention — marker_set
# itself does not narrow further than the token grammar, because
# fleet-model needs arbitrary tokens (model names).
marker_set() {
  local id=$1 marker=$2 value=$3 key text stripped new_desc
  key=$(marker_key_for "$marker") || {
    echo "marker_set: unknown marker '$marker'" >&2
    return 2
  }
  case "$value" in
    '' | *[!A-Za-z0-9_-]*)
      echo "marker_set: value '$value' fails the token grammar ([A-Za-z0-9_-]+)" >&2
      return 2
      ;;
  esac
  text=$(_bm_br_show_description "$id") || {
    echo "marker_set: could not read description for $id" >&2
    return 1
  }
  stripped=$(marker_strip "$marker" "$text")
  if [ -n "$stripped" ]; then
    new_desc=$(printf '%s\n\n%s: %s' "$stripped" "$key" "$value")
  else
    new_desc=$(printf '%s: %s' "$key" "$value")
  fi
  _bm_br_update_description "$id" "$new_desc"
}
