#!/bin/bash
# bead-markers.sh — ONE grammar implementation for the fleet/outward marker
# fields named by 69qr (R1c `fleet:`, R2 `fleet-model:`) and htqt (R4
# `outward:`) but never given a field, schema, or writer anywhere in the
# codebase (dotfiles-dh89 — grep proved them prose-only).
#
# CONVENTION DECIDED (dotfiles-dh89, 2026-08-09): br 0.2.16 has NO key/value
# metadata verb. `br update --agent-context` sets a schema-v11
# governing-instructions JSON blob that is DB-ONLY — it is not exported to
# the JSONL at all, so a marker stored there would not survive clone or
# machine transfer (this replaces dh89's earlier "different subsystem"
# framing with the concrete, checkable reason: field census on this repo's
# own issues.jsonl shows zero rows carrying it). `br label` DOES exist, is
# real, and IS exported to JSONL — but a label is flat/valueless, so it is
# the right shape for `friction` (SKILL.md's existing convention) and, as of
# dotfiles-pcdq, for the two BOOLEAN markers `fleet` and `outward` (presence
# IS the value). It is still the wrong shape for `fleet-model: opus`, which
# needs an arbitrary VALUE, not just presence/absence — so `fleet-model`
# stays a description-line marker. `fleet` and `outward` therefore now have
# TWO representations: `br label add <id> -l fleet` / `-l outward` is
# canonical going forward; the plain-text description line documented below
# is READ-FALLBACK ONLY, kept so beads marked before the migration (or by a
# writer that hasn't moved to labels yet) still resolve correctly. Markers
# without a clean label shape (`fleet-model`) live as plain text lines
# inside the bead's `--description`, one marker per line, with a STRICT
# grammar both this file's readers and its writer share:
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

# _bm_br_has_label <bead-id> <label> -> return 0 iff the bead's `labels`
# array (as reported by `br show <id> --json`) contains <label> exactly;
# return 1 for absence OR any read failure (an unreadable bead is treated as
# label-absent, which sends callers to the description-line fallback rather
# than erroring). Same `--json` LIST-not-object quirk as
# _bm_br_show_description above — index [0].
_bm_br_has_label() {
  local id=$1 label=$2
  br show "$id" --json 2>/dev/null | python3 -c '
import json, sys
label = sys.argv[1]
try:
    rows = json.load(sys.stdin)
    row = rows[0] if isinstance(rows, list) else rows
    sys.exit(0 if label in (row.get("labels") or []) else 1)
except Exception:
    sys.exit(1)
' "$label"
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

# marker_is_fleet <bead-id> -> return 0 iff the bead is fleet-eligible, 1
# otherwise. LABEL-BACKED FIRST (dotfiles-pcdq): `br label add <id> -l
# fleet` is checked before anything else, since presence of the label IS
# the true value for a boolean marker. Falls back to the description-line
# form (`Fleet: yes`, grammar-exact) for beads not yet migrated.
marker_is_fleet() {
  local id=$1 value
  _bm_br_has_label "$id" fleet && return 0
  value=$(marker_get "$id" fleet) || return 1
  marker_bool_from_value "$value"
}

# marker_is_outward <bead-id> -> same label-first / description-fallback
# shape as marker_is_fleet, for the htqt outward gate's `outward: yes`.
marker_is_outward() {
  local id=$1 value
  _bm_br_has_label "$id" outward && return 0
  value=$(marker_get "$id" outward) || return 1
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
