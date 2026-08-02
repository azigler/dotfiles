#!/bin/bash
# Test for mac.upgrade.sh sec_brew() — the ORDER of update / migrate / probe /
# trust / upgrade (bead dotfiles-v26x).
#
# Hook test convention: executable bash, non-zero exit = failure, PASS/FAIL
# summary on the last line. ⚠️ RUN UNDER BASH, NOT ZSH.
#
# THE DEFECT THIS SUITE EXISTS TO PIN. The untrusted-tap probe ran at the TOP of
# sec_brew(), BEFORE `brew update`. The probe asks brew "is this formula behind?"
# and brew can only answer out of LOCAL tap metadata, so against a stale index it
# answers "no" for a formula that is genuinely behind. The probe therefore found
# nothing, printed `✓ no untrusted taps blocking upgrades`, `--trust-taps` had
# nothing to trust — and `brew upgrade` then silently skipped those same formulae
# LATER IN THE SAME RUN, printing `Skipping <f>: tap formula is not trusted`.
# Measured on metis 2026-08-01, same formula either side of the refresh:
#   before: brew outdated --verbose dicklesworthstone/tap/bv -> (empty)
#   after : -> dicklesworthstone/tap/bv (0.16.4) < 0.18.0
#
# TWO LAYERS, DELIBERATELY. The static layer compares line numbers of the five
# anchors inside sec_brew() — cheap, and it fails on the exact edit that would
# reintroduce the bug. The runtime layer drives the REAL script against a stub
# `brew` that reproduces the measured behaviour (a third-party formula reads
# "current" until `brew update` has run) and asserts what the run PRINTS.
#
# AND THE MUTANT MUST DIE. A guard never observed to fail is not a guard, so the
# last section builds a mutated copy of mac.upgrade.sh with `brew update` moved
# back down next to `brew upgrade` — the original bug, exactly — and requires
# BOTH layers to reject it. If the mutant survives, this suite fails, because
# then the two layers above are decoration.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$ROOT/mac.upgrade.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/mac-upgrade-order.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

[ -f "$SCRIPT" ] || { echo "FAIL: cannot find mac.upgrade.sh at $SCRIPT"; exit 1; }

# --- the anchors, in the order they must appear ----------------------------
# Each is an ERE matched INSIDE sec_brew() only. `once` anchors must match
# EXACTLY once — a second `brew update` bolted in above a still-early probe
# would otherwise satisfy a naive "update comes first" check. `first` anchors
# may repeat (the probe block runs `brew outdated` twice by design) and are
# pinned by their FIRST occurrence, which is the one the ordering is about.
A_NAMES=(update migrate probe trust upgrade)
A_RES=(
  'run brew update'
  'was renamed to'
  'HOMEBREW_NO_AUTO_UPDATE=1 brew outdated'
  'run brew trust --tap'
  'run brew upgrade [|][|] fail'
)
A_MODE=(once once first once once)

sec_range() { # <file> -> "<start> <end>" of sec_brew()'s body
  awk '/^sec_brew\(\) \{/ {s=NR} s && /^\}/ {print s" "NR; exit}' "$1"
}

# Line numbers of every anchor, newline-separated, "" if the range is missing.
anchor_lines() { # <file> <ere>
  local rng s e
  rng=$(sec_range "$1") || return 1
  [ -n "$rng" ] || return 1
  s=${rng% *}; e=${rng#* }
  awk -v s="$s" -v e="$e" -v re="$2" 'NR>=s && NR<=e && $0 ~ re {print NR}' "$1"
}

# The whole static check as one predicate so the mutant can be run through it.
# Prints its diagnosis on stderr; returns 0 only if the order is correct.
order_ok() { # <file>
  local file=$1 i n lines count prev=0 prev_name="" this
  if [ -z "$(sec_range "$file")" ]; then
    echo "  no sec_brew() found in $file" >&2; return 1
  fi
  for i in "${!A_NAMES[@]}"; do
    n=${A_NAMES[$i]}
    lines=$(anchor_lines "$file" "${A_RES[$i]}")
    count=$(printf '%s\n' "$lines" | grep -c .)
    if [ "${A_MODE[$i]}" = once ] && [ "$count" -ne 1 ]; then
      echo "  anchor '$n' must appear exactly once in sec_brew(); got: ${lines//$'\n'/,}" >&2
      return 1
    fi
    if [ "$count" -lt 1 ]; then
      echo "  anchor '$n' is missing from sec_brew()" >&2
      return 1
    fi
    this=$(printf '%s\n' "$lines" | head -1)
    if [ "$this" -le "$prev" ]; then
      echo "  '$n' (line $this) must come AFTER '$prev_name' (line $prev)" >&2
      return 1
    fi
    prev=$this; prev_name=$n
  done
  return 0
}

# --- 0. the script is syntactically valid ----------------------------------
if bash -n "$SCRIPT" 2>"$TMP/synerr"; then ok
else bad "bash -n mac.upgrade.sh: $(cat "$TMP/synerr")"; fi

# --- 1. static: update -> migrate -> probe -> trust -> upgrade -------------
if order_ok "$SCRIPT" 2>"$TMP/orderr"; then ok
else bad "sec_brew() order is wrong:$(sed 's/^/ /' "$TMP/orderr")"; fi

# --- 2. HOMEBREW_NO_AUTO_UPDATE is on the PROBES ONLY ----------------------
# Gagging auto-update on the real refresh would re-create the stale-index bug
# by a different route: the update would stop being an update.
UPD_LINE=$(sed -n "$(anchor_lines "$SCRIPT" 'run brew update' | head -1)p" "$SCRIPT")
case "$UPD_LINE" in
  *HOMEBREW_NO_AUTO_UPDATE*) bad "HOMEBREW_NO_AUTO_UPDATE must not be set on the real 'brew update'" ;;
  *)                         ok ;;
esac

GAGGED=$(anchor_lines "$SCRIPT" 'HOMEBREW_NO_AUTO_UPDATE=1' | wc -l | tr -d ' ')
PROBES=$(anchor_lines "$SCRIPT" 'HOMEBREW_NO_AUTO_UPDATE=1 brew outdated' | wc -l | tr -d ' ')
if [ "$GAGGED" = "$PROBES" ]; then ok
else bad "every HOMEBREW_NO_AUTO_UPDATE in sec_brew() must be on a 'brew outdated' probe ($GAGGED set, $PROBES on probes)"; fi

# --- 3. a failed update must NOT skip the probe ----------------------------
# `set -uo pipefail` with no `-e` is the mechanism; `|| fail` (not `|| return`)
# is the intent. Both are asserted, because either one alone is undone silently.
if grep -q '^set -uo pipefail$' "$SCRIPT"; then ok
else bad "mac.upgrade.sh must stay 'set -uo pipefail' (no -e) so a failed update still probes"; fi

case "$UPD_LINE" in
  *"|| fail"*)                ok ;;
  *)                          bad "'brew update' must report via fail(), got: $UPD_LINE" ;;
esac
case "$UPD_LINE" in
  *return*|*exit*|*"&&"*)     bad "a failed 'brew update' must not short-circuit the probe: $UPD_LINE" ;;
  *)                          ok ;;
esac

# --- the stub brew ---------------------------------------------------------
# Reproduces the measured behaviour: acme/tap/widget reads CURRENT until
# `brew update` has run, and is invisible to the bare `brew outdated --verbose`
# either way (that is the untrusted-tap blindness the probe exists to catch).
mkdir -p "$TMP/bin" "$TMP/state"
cat > "$TMP/bin/brew" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BREW_STUB_LOG"
cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
  update)   : > "$BREW_STUB_STATE/updated"; exit 0 ;;
  list)     printf '%s\n' acme/tap/widget openssl; exit 0 ;;
  outdated)
    f=""
    for a in "$@"; do case "$a" in --*) ;; *) f=$a ;; esac; done
    if [ -n "$f" ] && [ -e "$BREW_STUB_STATE/updated" ]; then
      echo "$f (1.0) < 2.0"
    fi
    exit 0 ;;
  services) echo "Name Status User File"; exit 0 ;;
  *)        exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/brew"

run_script() { # <script> <state-tag> [extra args...] -> stdout, log at $TMP/<tag>.log
  local script=$1 tag=$2; shift 2
  rm -rf "$TMP/state-$tag"; mkdir -p "$TMP/state-$tag"
  BREW_STUB_LOG="$TMP/$tag.log" BREW_STUB_STATE="$TMP/state-$tag" \
    PATH="$TMP/bin:$PATH" bash "$script" --only brew "$@" 2>&1
}

# Index of the first stub-log line equal to <cmd word>, or 0 if never called.
log_pos() { # <tag> <first-word>
  awk -v w="$2" 'NR>0 && $1==w {print NR; found=1; exit} END{if(!found) print 0}' "$TMP/$1.log"
}

# --- 4. runtime: the probe REPORTS the stale-metadata formula --------------
OUT_PLAIN=$(run_script "$SCRIPT" plain)
case "$OUT_PLAIN" in
  *"third-party tap(s) are UNTRUSTED: acme/tap"*) ok ;;
  *) bad "probe did not report the stale-metadata third-party formula:
$OUT_PLAIN" ;;
esac
case "$OUT_PLAIN" in
  *"no untrusted taps blocking upgrades"*)
     bad "printed the clean line while a formula was in fact blocked" ;;
  *) ok ;;
esac
case "$OUT_PLAIN" in
  *"frozen: acme/tap/widget (1.0) < 2.0"*) ok ;;
  *) bad "the blocked upgrade was not named in the report:
$OUT_PLAIN" ;;
esac

# --- 5. runtime: update BEFORE the probe, trust BEFORE upgrade -------------
P_UPDATE=$(log_pos plain update)
P_OUTDATED=$(awk 'NR>0 && $1=="outdated" && NF>2 {print NR; f=1; exit} END{if(!f) print 0}' "$TMP/plain.log")
if [ "$P_UPDATE" -gt 0 ] && [ "$P_OUTDATED" -gt "$P_UPDATE" ]; then ok
else bad "stub trace: 'update' (#$P_UPDATE) must precede the per-formula probe (#$P_OUTDATED)"; fi

OUT_TRUST=$(run_script "$SCRIPT" trust --trust-taps)
T_UPDATE=$(log_pos trust update)
T_TRUST=$(log_pos trust trust)
T_UPGRADE=$(log_pos trust upgrade)
if [ "$T_TRUST" -gt 0 ] && [ "$T_UPGRADE" -gt 0 ] && [ "$T_TRUST" -lt "$T_UPGRADE" ]; then ok
else bad "stub trace: 'trust' (#$T_TRUST) must precede 'upgrade' (#$T_UPGRADE) or trusting no-ops this run"; fi
if [ "$T_UPDATE" -gt 0 ] && [ "$T_UPDATE" -lt "$T_TRUST" ]; then ok
else bad "stub trace: 'update' (#$T_UPDATE) must precede 'trust' (#$T_TRUST)"; fi
case "$OUT_TRUST" in
  *"trusted acme/tap"*) ok ;;
  *) bad "--trust-taps did not trust the blocked tap:
$OUT_TRUST" ;;
esac

# --- 6. --dry-run stays inert ---------------------------------------------
# The probes are read-only and DO run; nothing that mutates may.
DRY=$(run_script "$SCRIPT" dry --dry-run)
case "$DRY" in *"[dry-run] brew update"*) ok ;; *) bad "--dry-run did not print the brew update it withheld"; esac
if grep -qxE 'update|upgrade|trust .*|cleanup -s|migrate .*' "$TMP/dry.log"; then
  bad "--dry-run executed a mutating brew command: $(grep -xE 'update|upgrade|trust .*|cleanup -s|migrate .*' "$TMP/dry.log" | tr '\n' ' ')"
else ok; fi

# --- 7. THE MUTANT MUST DIE ------------------------------------------------
# Move `brew update` back down beside `brew upgrade` — the original bug, and the
# single edit most likely to reintroduce it. Both layers must reject this.
MUT="$TMP/mutant.sh"
awk '
  /^[[:space:]]*run brew update \|\| fail/ { held=$0; next }
  /^[[:space:]]*run brew upgrade \|\| fail/ && held != "" { print held; held="" }
  { print }
' "$SCRIPT" > "$MUT"

if ! cmp -s "$SCRIPT" "$MUT" && bash -n "$MUT" 2>/dev/null; then ok   # allow-suppress
else bad "the mutant was not built (awk move failed, or it does not parse) — section 7 proves nothing"; fi

if order_ok "$MUT" 2>/dev/null; then   # allow-suppress
  bad "STATIC GUARD DOES NOT BITE: it accepts a mac.upgrade.sh whose probe runs before brew update"
else ok; fi

OUT_MUT=$(run_script "$MUT" mutant)
case "$OUT_MUT" in
  *"no untrusted taps blocking upgrades"*) ok ;;   # bug faithfully reproduced
  *) bad "the runtime layer cannot tell the orders apart — the mutant did not print the false-clean line:
$OUT_MUT" ;;
esac
case "$OUT_MUT" in
  *"third-party tap(s) are UNTRUSTED"*)
     bad "mutant still reported the blocked tap — the stub does not model stale metadata" ;;
  *) ok ;;
esac

# --- Summary ---
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL sec_brew() ordering cases"
  exit 0
fi
echo "FAIL: $FAIL/$TOTAL sec_brew() ordering cases failed"
for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
exit 1
