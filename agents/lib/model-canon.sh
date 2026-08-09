#!/bin/bash
# model-canon.sh — THE model-alias table (dotfiles-lstn).
#
#   source agents/lib/model-canon.sh   # then call model_canon / model_canon_drift
#   bash   agents/lib/model-canon.sh canon  <token>
#   bash   agents/lib/model-canon.sh drift  <token>
#   bash   agents/lib/model-canon.sh table
#
# ── WHY THIS FILE EXISTS ────────────────────────────────────────────────────
# A BARE ALIAS SILENTLY DROPS THE 1M CONTEXT WINDOW. That is the whole bug.
# `claude --model fable` and `claude --model claude-fable-5` both run Fable 5 —
# at 200,000 tokens. Only the `[1m]` literal opts into the extended window.
# Measured on this box, 2026-08-09, `claude … --output-format json`, reading
# `.modelUsage[<id>].contextWindow`:
#
#     --model claude-fable-5        ->  contextWindow      200000
#     --model 'claude-fable-5[1m]'  ->  contextWindow    1000000
#     --model 'claude-opus-5[1m]'   ->  contextWindow    1000000
#     --model 'claude-sonnet-5[1m]' ->  contextWindow    1000000
#     --model 'claude-haiku-4-5[1m]'-> API Error: 400 "The long context beta is
#                                      not yet available for this subscription."
#     --model claude-haiku-4-5      ->  contextWindow      200000
#
# canonicalModel comes back identical with and without the tag
# (`claude-fable-5`), so the tag is a WINDOW selector, not a different model —
# which is why the guard's norm() strips it for COMPARISON while every launch
# and restore site must still NAME it.
#
# 200k vs 1M is the compaction-thrash multiplier: a seat on the alias compacts
# five times where the literal never compacts at all. It failed silently for
# hours on 2026-08-09 — the statusline still said "Fable 5", the transcript
# still said `claude-fable-5`, and only guard math over a >200k context could
# tell the two apart.
#
# ── HOW THE DRIFT GETS WRITTEN (the loop, not a one-off) ────────────────────
# Claude Code's `/model` slash command PERSISTS its argument into live
# `~/.claude/settings.json`. So a single `/model fable` — typed by a human, or
# INSTRUCTED by post-tool-model-guard.sh's restore rung when its EXPECTED came
# from a roster alias — rewrites the machine default to the 200k form for every
# session launched afterwards. One alias anywhere becomes an alias everywhere.
# Hence the rule this file implements: comparisons normalise, INSTRUCTIONS AND
# LAUNCHES name the canonical literal.
#
# ── THE TABLE, AND THE EVIDENCE FOR EACH ROW ────────────────────────────────
# Aliases are the ROSTER's vocabulary (agents/seats.yml `model:` stays
# `fable`/`opus`/`sonnet`/`haiku`, validated by validate-seats.py's
# KNOWN_MODELS, and it is what the hall's court view shows). Canonicalisation
# happens at the BOUNDARY — the launch string and the /model instruction — not
# in the data file, so the long literal lives in exactly one place.
#
#   fable  -> claude-fable-5[1m]    catalog: context{window:1e6,native_1m:true}
#                                   probe:   1000000 (bare: 200000)
#   opus   -> claude-opus-5[1m]     catalog: window 1e6, native_1m,
#                                   supports_1m_suffix; already the pin in
#                                   claude/settings.json's
#                                   ANTHROPIC_DEFAULT_OPUS_MODEL. probe: 1000000
#   sonnet -> claude-sonnet-5[1m]   catalog: window 1e6, native_1m. probe: 1000000
#   haiku  -> claude-haiku-4-5      catalog: window 200000, NO native_1m.
#                                   probe with the tag: HTTP 400. THERE IS NO
#                                   1M HAIKU — do not "fix" this row for
#                                   symmetry; the tag is a hard error there.
#
# Corroborating the same conclusion from the client itself: the accepted-alias
# list embedded in `claude` 2.1.226 is
#   ["sonnet","opus","haiku","fable","best","sonnet[1m]","opus[1m]","fable[1m]",
#    "opusplan"]
# — three `[1m]` aliases, and `haiku[1m]` is deliberately absent.
#
# The right-hand column is the FULL ID, not `fable[1m]`, for a second reason:
# alias resolution is PROVIDER-DEPENDENT. The catalog's `aliases` map carries a
# `per_provider` table (`opus` resolves to claude-opus-4-7 on the `gateway`
# provider, `sonnet` to claude-sonnet-4-6), so the same alias can name a
# different model depending on how the session is routed. A full id cannot.
#
# ── WHAT IT DOES *NOT* REWRITE ─────────────────────────────────────────────
# Only the four families above are in the table. An explicitly pinned older
# model — `claude-opus-4-8`, `claude-sonnet-4-6` — passes through UNCHANGED
# with rc 1. A seat deliberately parked on a previous model must not be
# silently upgraded by a hygiene helper; that is a different decision and it
# belongs to whoever made it. (`claude-opus-4-8` does carry native_1m, so a
# future row for it would be defensible — file a bead, do not infer it here.)
#
# ── VERSION SENSITIVITY ─────────────────────────────────────────────────────
# `latest_per_family` moves when Anthropic ships a model. This table is a
# CALIBRATION of `claude` 2.1.226, not a constant: re-derive it (the two probes
# above, plus the alias list) when the CLI version moves. A stale row here does
# not error — it names a real, older model — so nothing will tell you.

# --- the table --------------------------------------------------------------
# One line per alias: `<alias> <canonical>`. Everything below derives from it;
# there is no second copy anywhere in this repo.
MODEL_CANON_TABLE='fable claude-fable-5[1m]
opus claude-opus-5[1m]
sonnet claude-sonnet-5[1m]
haiku claude-haiku-4-5'

# model_canon_table — the table, one `<alias> <canonical>` pair per line.
model_canon_table() { printf '%s\n' "$MODEL_CANON_TABLE"; }

# _model_canon_root <token> — lowercase, and with any trailing `[...]` context
# tag removed. `Fable`, `fable[1m]` and `fable` all root to `fable`;
# `claude-fable-5[1m]` roots to `claude-fable-5`.
_model_canon_root() {
  printf '%s' "$1" | sed -e 's/\[[^][]*\]$//' | tr '[:upper:]' '[:lower:]'
}

# model_canon <token> — print the canonical id for <token>; rc 0 when the table
# resolved it, rc 1 when it did not (and then <token> is echoed VERBATIM, so a
# caller can use the output unconditionally and treat rc as advisory).
#
# Resolves an alias (`fable`), an alias carrying the tag (`fable[1m]`), a bare
# full id (`claude-fable-5`) and an already-canonical id (`claude-fable-5[1m]`)
# — the last is a fixed point, which is what makes this safe to apply twice.
model_canon() {
  local tok=${1:-} root alias canon
  [ -n "$tok" ] || return 1
  root=$(_model_canon_root "$tok")
  while read -r alias canon; do
    [ -n "$alias" ] || continue
    if [ "$root" = "$alias" ] || [ "$root" = "$(_model_canon_root "$canon")" ]; then
      printf '%s' "$canon"
      return 0
    fi
  done <<EOF
$MODEL_CANON_TABLE
EOF
  printf '%s' "$tok"
  return 1
}

# model_canon_drift <token> — THE DETECTOR (dotfiles-lstn AC3). rc 0 = <token>
# is already the canonical literal (or is not a model this table governs);
# rc 1 = drift, and one line naming what it is and what it should be goes to
# stdout. "Drift" is deliberately BROADER than a missing `[1m]`: a bare alias
# and a bare full id are both drift, because both are the 200k form for the
# three families that have a 1M variant — and for haiku, where the canonical
# has no tag, `claude-haiku-4-5[1m]` is drift in the OTHER direction (it is a
# 400 at the API), which a "does it end in [1m]" check would call healthy.
model_canon_drift() {
  local tok=${1:-} canon
  [ -n "$tok" ] || return 0
  canon=$(model_canon "$tok") || return 0          # not in the table: not ours
  [ "$tok" = "$canon" ] && return 0
  printf "model '%s' is not the canonical id — it should be '%s'" "$tok" "$canon"
  return 1
}

# model_canon_settings_drift <settings.json> — the same check against a live
# Claude Code settings file's top-level `model` key, which is the seam
# `/model` persists into. rc 0 = clean (or no file / no key / no jq — an
# unreadable settings file is not a drift finding, and this must never be the
# thing that breaks a session).
model_canon_settings_drift() {
  local f=${1:-} m
  [ -n "$f" ] && [ -r "$f" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0   # allow-suppress: pure existence probe
  m=$(jq -r '.model // empty' "$f" 2>/dev/null)
  [ -n "$m" ] || return 0
  model_canon_drift "$m"
}

# --- CLI shim ---------------------------------------------------------------
# Sourceable AND runnable, so a caller that does not want this file's functions
# in its namespace (pulse-inject.sh, which keeps the same discipline for
# seat-resolve.sh) can fork it instead.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _mc_rc=0
  case "${1:-}" in
    canon) model_canon "${2:-}" || _mc_rc=1; printf '\n' ;;
    drift) model_canon_drift "${2:-}" || _mc_rc=1; printf '\n' ;;
    table) model_canon_table ;;
    *) echo "usage: model-canon.sh canon|drift <token> | table" >&2; exit 64 ;;
  esac
  exit "$_mc_rc"
fi
