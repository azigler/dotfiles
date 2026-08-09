#!/bin/bash
# Test for agents/lib/model-canon.sh — the model-alias canonicalisation table
# (dotfiles-lstn).
#
#   bash agents/lib/test-model-canon.sh
#
# The cases that matter are the two ASYMMETRIC ones, and they are asymmetric for
# measured reasons, not for tidiness:
#   * C7  fable/opus/sonnet MUST gain `[1m]`   — the bare form is 200k (probed)
#   * C8  haiku MUST NOT     gain `[1m]`       — the tagged form is an API 400
# A table that treated the four families uniformly would be wrong in one
# direction or the other whichever way it went.
#
# Case tags (C1, C2, …) are load-bearing: mutate-model-canon.sh asserts that a
# mutant kills the case it NAMES by matching those tags in the FAIL list.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="${MODEL_CANON_LIB:-$HERE/model-canon.sh}"

PASS=0
FAIL=0
FAILED_NAMES=()
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf '  FAIL %s\n     -> %s\n' "$1" "${2:-}"; }

[ -r "$LIB" ] || { echo "FATAL: lib missing: $LIB" >&2; exit 2; }

# shellcheck source=/dev/null
. "$LIB"

# canon <tok> -> prints "<output>|<rc>", so a case can assert both at once.
canon() { local o rc; o=$(model_canon "$1"); rc=$?; printf '%s|%s' "$o" "$rc"; }
drift() { local o rc; o=$(model_canon_drift "$1"); rc=$?; printf '%s|%s' "$o" "$rc"; }

echo "=== model-canon ==========================================================="

# --- C1: the table is exactly four rows, one per family ---------------------
ROWS=$(model_canon_table | grep -c .)
ALIASES=$(model_canon_table | awk '{print $1}' | sort | tr '\n' ' ')
if [ "$ROWS" -eq 4 ] && [ "$ALIASES" = "fable haiku opus sonnet " ]; then
  ok "C1 the table is the four families, once each ($ALIASES)"
else
  bad "C1 the table is the four families, once each" "rows=$ROWS aliases='$ALIASES'"
fi

# --- C2: every canonical is a FULL id, never a bare or tagged alias ---------
# The right-hand column has to be a full model id because alias resolution is
# provider-dependent (the catalog's aliases carry a per_provider map).
BADCANON=$(model_canon_table | awk '$2 !~ /^claude-/ { print $2 }')
if [ -z "$BADCANON" ]; then
  ok "C2 every canonical is a full claude-* id, never a bare alias"
else
  bad "C2 every canonical is a full claude-* id, never a bare alias" "offenders: $BADCANON"
fi

# --- C3: an alias resolves to its canonical ---------------------------------
if [ "$(canon fable)"  = 'claude-fable-5[1m]|0' ] \
   && [ "$(canon opus)"   = 'claude-opus-5[1m]|0' ] \
   && [ "$(canon sonnet)" = 'claude-sonnet-5[1m]|0' ] \
   && [ "$(canon haiku)"  = 'claude-haiku-4-5|0' ]; then
  ok "C3 each bare alias resolves to its canonical id"
else
  bad "C3 each bare alias resolves to its canonical id" \
      "fable=$(canon fable) opus=$(canon opus) sonnet=$(canon sonnet) haiku=$(canon haiku)"
fi

# --- C4: a BARE FULL ID is canonicalised too --------------------------------
# `claude-fable-5` is the shape a /model or a settings file lands in after the
# alias has been resolved once; it is still the 200k form.
if [ "$(canon claude-fable-5)" = 'claude-fable-5[1m]|0' ] \
   && [ "$(canon claude-sonnet-5)" = 'claude-sonnet-5[1m]|0' ]; then
  ok "C4 a bare full id (claude-fable-5) is canonicalised to the [1m] literal"
else
  bad "C4 a bare full id (claude-fable-5) is canonicalised to the [1m] literal" \
      "fable=$(canon claude-fable-5) sonnet=$(canon claude-sonnet-5)"
fi

# --- C5: canonicalisation is IDEMPOTENT -------------------------------------
# Applied twice (roster -> launch -> guard) it must be a fixed point, or the
# second pass produces `claude-fable-5[1m][1m]`.
if [ "$(canon 'claude-fable-5[1m]')" = 'claude-fable-5[1m]|0' ] \
   && [ "$(canon 'claude-haiku-4-5')" = 'claude-haiku-4-5|0' ]; then
  ok "C5 canonicalisation is idempotent (a canonical id is a fixed point)"
else
  bad "C5 canonicalisation is idempotent (a canonical id is a fixed point)" \
      "fable=$(canon 'claude-fable-5[1m]') haiku=$(canon claude-haiku-4-5)"
fi

# --- C6: an UNKNOWN model passes through verbatim, rc 1 ---------------------
# A seat deliberately parked on an older model must not be silently upgraded.
if [ "$(canon claude-opus-4-8)" = 'claude-opus-4-8|1' ] \
   && [ "$(canon nonsense-model)" = 'nonsense-model|1' ]; then
  ok "C6 an unknown model passes through verbatim with rc 1 (never upgraded)"
else
  bad "C6 an unknown model passes through verbatim with rc 1 (never upgraded)" \
      "opus48=$(canon claude-opus-4-8) junk=$(canon nonsense-model)"
fi

# --- C7: THE 1M FAMILIES CARRY THE TAG --------------------------------------
# Probed 2026-08-09: bare claude-fable-5 -> contextWindow 200000;
# claude-fable-5[1m] -> 1000000. Same canonicalModel both times.
MISSING=""
for a in fable opus sonnet; do
  c=$(model_canon "$a")
  case "$c" in *'[1m]') ;; *) MISSING="$MISSING $a=$c" ;; esac
done
if [ -z "$MISSING" ]; then
  ok "C7 fable/opus/sonnet canonicals all carry the [1m] tag (the 1M window)"
else
  bad "C7 fable/opus/sonnet canonicals all carry the [1m] tag (the 1M window)" \
      "without the tag these are the 200k form:$MISSING"
fi

# --- C8: HAIKU MUST NOT CARRY THE TAG ---------------------------------------
# Probed 2026-08-09: --model 'claude-haiku-4-5[1m]' -> HTTP 400 "The long
# context beta is not yet available for this subscription". There is no 1M
# haiku; `haiku[1m]` is absent from the client's own accepted-alias list.
case "$(model_canon haiku)" in
  *'[1m]') bad "C8 haiku's canonical carries NO [1m] tag (the tagged form is a 400)" \
               "got '$(model_canon haiku)' — that model string errors at the API" ;;
  *)       ok  "C8 haiku's canonical carries NO [1m] tag (the tagged form is a 400)" ;;
esac

# --- C9: the drift detector on a canonical id is SILENT ---------------------
if [ "$(drift 'claude-fable-5[1m]')" = '|0' ] \
   && [ "$(drift claude-haiku-4-5)" = '|0' ] \
   && [ "$(drift claude-opus-4-8)" = '|0' ]; then
  ok "C9 drift is silent on a canonical id, and on a model the table does not govern"
else
  bad "C9 drift is silent on a canonical id, and on a model the table does not govern" \
      "fable=$(drift 'claude-fable-5[1m]') haiku=$(drift claude-haiku-4-5) opus48=$(drift claude-opus-4-8)"
fi

# --- C10: the drift detector FIRES on the alias and on the bare id ----------
# This is the live 2026-08-09 shape: settings.json had drifted to "fable".
D1=$(model_canon_drift fable); R1=$?
D2=$(model_canon_drift claude-fable-5); R2=$?
if [ "$R1" -eq 1 ] && [ "$R2" -eq 1 ] \
   && printf '%s' "$D1" | grep -q 'claude-fable-5\[1m\]' \
   && printf '%s' "$D2" | grep -q 'claude-fable-5\[1m\]'; then
  ok "C10 drift fires on the bare alias AND the bare full id, naming the canonical"
else
  bad "C10 drift fires on the bare alias AND the bare full id, naming the canonical" \
      "alias(rc=$R1)='$D1' fullid(rc=$R2)='$D2'"
fi

# --- C11: drift fires in the OTHER direction too, on a tagged haiku ---------
# A "does it end in [1m]" check would call this healthy; it is a 400.
D3=$(model_canon_drift 'claude-haiku-4-5[1m]'); R3=$?
if [ "$R3" -eq 1 ] && printf '%s' "$D3" | grep -q "should be 'claude-haiku-4-5'"; then
  ok "C11 drift fires on a TAGGED haiku (the tag is wrong in that direction)"
else
  bad "C11 drift fires on a TAGGED haiku (the tag is wrong in that direction)" "rc=$R3 out='$D3'"
fi

# --- C12: the settings-file check reads the live seam -----------------------
T=$(mktemp -d "${TMPDIR:-/tmp}/test-model-canon.XXXXXX")
trap 'rm -rf "$T"' EXIT
printf '%s\n' '{"model":"fable"}'              > "$T/drifted.json"
printf '%s\n' '{"model":"claude-fable-5[1m]"}' > "$T/clean.json"
printf '%s\n' '{"cleanupPeriodDays":9999}'     > "$T/nomodel.json"
SD=$(model_canon_settings_drift "$T/drifted.json"); SDR=$?
model_canon_settings_drift "$T/clean.json"   >/dev/null; SCR=$?
model_canon_settings_drift "$T/nomodel.json" >/dev/null; SNR=$?
model_canon_settings_drift "$T/absent.json"  >/dev/null; SAR=$?
if [ "$SDR" -eq 1 ] && printf '%s' "$SD" | grep -q 'claude-fable-5\[1m\]' \
   && [ "$SCR" -eq 0 ] && [ "$SNR" -eq 0 ] && [ "$SAR" -eq 0 ]; then
  ok "C12 settings-file drift: fires on \"model\":\"fable\", silent on clean/no-key/absent"
else
  bad "C12 settings-file drift: fires on \"model\":\"fable\", silent on clean/no-key/absent" \
      "drifted(rc=$SDR)='$SD' clean=$SCR nokey=$SNR absent=$SAR"
fi

# --- C13: case folding ------------------------------------------------------
# `/model Fable` is a thing a human types.
if [ "$(canon FABLE)" = 'claude-fable-5[1m]|0' ] \
   && [ "$(canon 'Claude-Fable-5[1M]')" = 'claude-fable-5[1m]|0' ]; then
  ok "C13 lookup folds case (FABLE, Claude-Fable-5[1M])"
else
  bad "C13 lookup folds case (FABLE, Claude-Fable-5[1M])" \
      "FABLE=$(canon FABLE) mixed=$(canon 'Claude-Fable-5[1M]')"
fi

# --- C14: empty input is not a finding --------------------------------------
if [ "$(canon '')" = '|1' ] && [ "$(drift '')" = '|0' ]; then
  ok "C14 an empty model string resolves to nothing and is not reported as drift"
else
  bad "C14 an empty model string resolves to nothing and is not reported as drift" \
      "canon=$(canon '') drift=$(drift '')"
fi

# --- C15: the CLI shim agrees with the sourced functions --------------------
CO=$(bash "$LIB" canon fable); CR=$?
bash "$LIB" drift fable >/dev/null; DR=$?
bash "$LIB" drift 'claude-fable-5[1m]' >/dev/null; DR2=$?
TROWS=$(bash "$LIB" table | grep -c .)
if [ "$CO" = 'claude-fable-5[1m]' ] && [ "$CR" -eq 0 ] \
   && [ "$DR" -eq 1 ] && [ "$DR2" -eq 0 ] && [ "$TROWS" -eq 4 ]; then
  ok "C15 the CLI shim (canon/drift/table) agrees with the sourced functions"
else
  bad "C15 the CLI shim (canon/drift/table) agrees with the sourced functions" \
      "canon='$CO' rc=$CR driftalias=$DR driftcanon=$DR2 rows=$TROWS"
fi

# --- C16: every canonical is splice-safe for a launch string ----------------
# The canonical is TYPED INTO A SHELL by pulse-inject.sh. It must be a bare
# token optionally followed by [1m] — no quotes, no $, no spaces — or the
# injector's own token guard will (correctly) refuse it and the fleet loses
# every pin at once.
UNSAFE=""
while read -r _a c; do
  case "${c%'[1m]'}" in *[!A-Za-z0-9._-]*|"") UNSAFE="$UNSAFE $c" ;; esac
done <<EOF
$(model_canon_table)
EOF
if [ -z "$UNSAFE" ]; then
  ok "C16 every canonical is a splice-safe token (bare, optional [1m] suffix)"
else
  bad "C16 every canonical is a splice-safe token (bare, optional [1m] suffix)" "offenders:$UNSAFE"
fi

echo
printf 'PASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'
  for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
exit 0
