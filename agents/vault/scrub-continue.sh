#!/usr/bin/env bash
# scrub-continue.sh — SCRUB-AND-CONTINUE for both claude-vault tiers (dotfiles-t6sd).
#
# POLICY (Zig, 2026-07-26, repo owner's call for these PRIVATE vaults): a
# high-confidence secret found in vault-bound content is REDACTED IN PLACE and the
# push CONTINUES. It is no longer a wall that halts the backup. The vault stalled
# for 121 consecutive runs / five days because the Layer-1 gate is fail-closed and
# nothing downstream could clear it unattended.
#
# The gate does NOT go away — it moves from "the only thing that happens" to "the
# backstop that catches what redaction could not fix". Ordering is the whole design:
#
#     stage  ->  SCAN  ->  REDACT the hits  ->  re-stage  ->  VERIFY  ->  commit
#                                                                   \-> pre-commit
#                                                                       gate (wall)
#
# WHY HERE AND NOT IN THE PRE-COMMIT HOOK. The hook runs with the index already
# built, and the transcripts hook's fast path scans each staged path's ON-DISK
# SOURCE. A hook that redacted the on-disk file would leave the *staged blob*
# still carrying the secret while its own re-scan of the (now clean) disk file
# passed — it would commit the secret and report success. Fixing that inside the
# hook means re-running `git add` from within the commit that is already in
# progress, which mutates the index mid-commit. Redacting BEFORE staging makes the
# redacted bytes the staged bytes by construction, and leaves the hook as a pure,
# unchanged, fail-closed verifier. One writer, one wall.
#
# WHAT STILL FAILS LOUDLY (the line, drawn explicitly):
#   * scrub.py absent / python3 absent      -> INERT. No redaction, no failure. The
#     pre-commit hook is best-effort on the same condition; this matches it.
#   * scrub.py exits with anything other than 0 (clean) or 1 (found)  -> FAILED.
#     The redactor is the thing keeping the gate from firing; if it is broken we
#     refuse to commit blind rather than shrug.
#   * a rewrite fails its validity check (scrub.py prints SKIP(unsafe): line-count
#     drift, or a .jsonl line that will not parse)  -> LOUD WARN, and the file is
#     left untouched and still staged, so the pre-commit gate BLOCKS the commit.
#     That is deliberate: the gate produces the semantically-correct status
#     (2 = BLOCKED, "parked on a human"), and there is exactly one enforcement
#     point rather than two that can disagree.
#   * a secret SURVIVES redaction and is still present on the verify re-scan
#     -> LOUD WARN + the same fall-through to the gate.
# So the loop keeps running for the expected case and still goes red for the
# genuinely-broken one.
#
# IDEMPOTENCE. scrub.py only rewrites a file whose scan produced matches, and the
# marker it writes ([REDACTED-SECRET]) matches none of the patterns. A second run
# over already-redacted content therefore scans clean, writes nothing, and emits no
# ledger row — a true no-op, not a re-write.
#
# VISIBILITY. A redaction is now a NORMAL event, which means the gate is no longer
# the thing that tells anyone a credential hit disk. This file is. Every event
# appends one JSONL row to $VAULT_REDACTION_LEDGER naming the tier, the action, the
# path and the pattern names + counts (NEVER the secret itself), and prints a WARN
# to the caller's stderr (-> ~/.claude/vault-sync.log). vault-sync.sh turns the
# per-run row delta into a `scrub=` term in its one-line verdict and a `scrub`
# field in its own ledger row, and journals a redacting run at NOTICE instead of
# INFO — visible in `systemctl status` / `journalctl -p notice`, without reddening
# a unit whose behaviour was, by policy, correct.

VAULT_DIR="${VAULT_DIR:-$HOME/.claude/vaults}"
SCRUB="${SCRUB:-$HOME/.claude/skills/scrub-secrets/scrub.py}"

# The coreutils-flavour shim (dotfiles-5vz2). `stat -c %Y` below is GNU-only and
# was failing on every macOS call behind a `2>/dev/null`.
_SC_HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [ -r "$_SC_HERE/../hooks/lib/portable.sh" ]; then
  # shellcheck source=/dev/null
  . "$_SC_HERE/../hooks/lib/portable.sh"
fi
VAULT_SCRUB_CONTINUE="${VAULT_SCRUB_CONTINUE:-1}"
VAULT_REDACTION_LEDGER="${VAULT_REDACTION_LEDGER:-$HOME/.claude/vault-redactions.jsonl}"
VAULT_REDACTION_LEDGER_MAX="${VAULT_REDACTION_LEDGER_MAX:-5000}"

# How recently a transcript must have been written to count as LIVE. 15 minutes:
# long enough to cover a session that is thinking/idling between turns, short
# enough that a finished session's transcript is redacted on the very next hourly
# fire. Only used by the TRANSCRIPTS tier (see _sc_is_live).
VAULT_LIVE_WINDOW_SEC="${VAULT_LIVE_WINDOW_SEC:-900}"

# --------------------------------------------------------------------------- #
# _sc_ledger TIER ACTION PATH DETAIL — one JSONL row per noteworthy event.
# DETAIL carries pattern NAMES and COUNTS only (e.g. "{'aws-akia': 1}") or an
# error string — never the matched text. python3 does the JSON quoting so a path
# with a quote/backslash cannot produce an invalid row.
# --------------------------------------------------------------------------- #
_sc_ledger() {
  [ -n "${VAULT_REDACTION_LEDGER:-}" ] || return 0
  mkdir -p "$(dirname "$VAULT_REDACTION_LEDGER")" 2>/dev/null
  python3 - "$1" "$2" "$3" "${4:-}" >> "$VAULT_REDACTION_LEDGER" 2>/dev/null <<'PY'
import datetime, json, sys
tier, action, path, detail = sys.argv[1:5]
print(json.dumps({
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "row": "vault-scrub",
    "tier": tier,
    "action": action,
    "path": path,
    "detail": detail,
}))
PY
  # bounded growth via atomic rename, so a concurrent reader sees a whole file.
  local lines
  [ -f "$VAULT_REDACTION_LEDGER" ] || return 0
  lines=$(wc -l < "$VAULT_REDACTION_LEDGER")
  if [ "$lines" -gt "$VAULT_REDACTION_LEDGER_MAX" ]; then
    tail -n $((VAULT_REDACTION_LEDGER_MAX / 2)) "$VAULT_REDACTION_LEDGER" \
      > "$VAULT_REDACTION_LEDGER.tmp" 2>/dev/null \
      && mv -f "$VAULT_REDACTION_LEDGER.tmp" "$VAULT_REDACTION_LEDGER" 2>/dev/null
  fi
}

# --------------------------------------------------------------------------- #
# _sc_is_live FILE — is this file being written RIGHT NOW?
#
# Redacting a file that is being appended to is genuinely dangerous, and not in a
# subtle way: safe_rewrite() writes a temp copy and os.replace()s it, which swaps
# the INODE. A writer holding an append fd on the old inode keeps writing into the
# now-unlinked file and every subsequent line is silently lost. So the live file is
# never rewritten.
#
# Identified WITHOUT hardcoding a session UUID, by two independent signals, unioned:
#
#   1. AN OPEN FD. Walk /proc/<pid>/fd and look for a symlink resolving to this
#      file. This is the EXACT signal — a file someone has open is by definition
#      in use — and it is pure procfs, no lsof dependency. Verified empirically on
#      this box 2026-07-26: Claude Code opens/appends/closes per write and holds
#      NO persistent fd, so today this signal fires for nothing. It is kept because
#      it costs one directory walk and is the only signal that stays correct if the
#      writer ever switches to a held-open handle.
#   2. MTIME FRESHNESS. Modified within VAULT_LIVE_WINDOW_SEC. This is the signal
#      that actually does the work today. Coarse, dependency-free, and it cannot
#      miss an active writer.
#
# Union, not intersection: either signal alone marks the file live. False positives
# only cost one deferred cycle; a false negative costs a corrupted transcript.
# --------------------------------------------------------------------------- #
_sc_open_fds_cache=""
_sc_open_fds_loaded=0
_sc_load_open_fds() {
  [ "$_sc_open_fds_loaded" -eq 1 ] && return 0
  _sc_open_fds_loaded=1
  local p fd t
  for p in /proc/[0-9]*; do
    for fd in "$p"/fd/*; do
      t=$(readlink "$fd" 2>/dev/null) || continue
      case "$t" in
        *.jsonl|*.jsonl' (deleted)'|*.md|*.txt) _sc_open_fds_cache="$_sc_open_fds_cache$t"$'\n' ;;
      esac
    done
  done 2>/dev/null
  return 0
}

_sc_is_live() {
  local f="$1" now mtime
  _sc_load_open_fds
  case $'\n'"$_sc_open_fds_cache" in
    *$'\n'"$f"$'\n'*) return 0 ;;
  esac
  # NOT `stat -c %Y` (dotfiles-5vz2): BSD stat has no -c, so on macOS this
  # returned 1 for EVERY file and no transcript was ever treated as live —
  # a redaction-deferral policy that had silently stopped applying.
  mtime=$(_p_mtime "$f") || return 1
  now=$(date +%s)
  [ $(( now - mtime )) -lt "$VAULT_LIVE_WINDOW_SEC" ]
}

# --------------------------------------------------------------------------- #
# sc_scan_hits TIER OUTVAR FILE... — run `scrub.py scan`, push each hit file into
# the caller's array OUTVAR. Echoes nothing. Returns:
#   0  scanned (OUTVAR may be empty = clean)
#   1  scrub.py is broken (unexpected exit) — caller must FAIL
#   2  inert (no scrub.py / no python3) — caller continues without redaction
# The per-file `counts` dict is stashed under _sc_counts_get <file>.
#
# ⚠️ NOT `declare -A` (dotfiles-5vz2, same shape as dotfiles-yr2h). macOS
# /bin/bash is 3.2.57 and has no associative arrays. `declare -gA X 2>/dev/null
# || declare -A X` does not save you: BOTH fail, and then every `X["$f"]=...`
# is parsed as an INDEXED subscript, i.e. as ARITHMETIC on the path — "syntax
# error: operand expected (error token is /Users/...)". The shebang here is
# /usr/bin/env bash, which finds bash 5 on this box TODAY, so the failure is
# latent rather than live; it becomes live the moment anything invokes these
# libs with /bin/bash. Parallel indexed arrays cost a linear scan over a set
# that is at most a few staged files.
# --------------------------------------------------------------------------- #
_SC_COUNTS_K=()
_SC_COUNTS_V=()

# _sc_counts_put <file> <counts>   — last write for a key wins.
_sc_counts_put() {
  local i=0
  while [ "$i" -lt "${#_SC_COUNTS_K[@]}" ]; do
    if [ "${_SC_COUNTS_K[$i]}" = "$1" ]; then _SC_COUNTS_V[$i]="$2"; return 0; fi
    i=$((i + 1))
  done
  _SC_COUNTS_K+=("$1"); _SC_COUNTS_V+=("$2")
}

# _sc_counts_get <file> [default]  — echoes the counts dict, or the default.
_sc_counts_get() {
  local i=0
  while [ "$i" -lt "${#_SC_COUNTS_K[@]}" ]; do
    if [ "${_SC_COUNTS_K[$i]}" = "$1" ]; then printf '%s' "${_SC_COUNTS_V[$i]}"; return 0; fi
    i=$((i + 1))
  done
  printf '%s' "${2:-}"
}
sc_scan_hits() {
  local tier="$1" outvar="$2"; shift 2
  [ "$#" -gt 0 ] || return 0
  [ -f "$SCRUB" ] || return 2
  command -v python3 >/dev/null 2>&1 || return 2
  local out rc line f pats
  out=$(python3 "$SCRUB" scan "$@" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    echo "WARN: scrub-and-continue ($tier): scrub.py scan exited $rc — the redactor is" >&2
    echo "      broken, refusing to commit blind. Output:" >&2
    printf '%s\n' "$out" | tail -20 >&2
    _sc_ledger "$tier" "scrub-error" "" "scan exit $rc"
    return 1
  fi
  [ "$rc" -eq 0 ] && return 0
  # scan prints one `<path>: <n>  {<counts>}` line per hit file (greedy .* on the
  # path so a colon inside a path binds to the LAST `: N  {` — paths win).
  while IFS= read -r line; do
    if [[ "$line" =~ ^(.*):\ ([0-9]+)\ \ (\{.*\})$ ]]; then
      f="${BASH_REMATCH[1]}"; pats="${BASH_REMATCH[3]}"
      _sc_counts_put "$f" "$pats"       # pattern NAMES + counts only, never the match
      eval "$outvar+=(\"\$f\")"
    fi
  done <<< "$out"
  return 0
}

# --------------------------------------------------------------------------- #
# sc_redact_files TIER FILE... — redact the given (already known-dirty) files and
# verify. Returns 0 (continue) or 1 (FAILED: scrub.py broken).
# A file that could not be safely rewritten, or whose secret survived, is left
# staged on purpose so the fail-closed pre-commit gate blocks the commit.
# --------------------------------------------------------------------------- #
sc_redact_files() {
  local tier="$1"; shift
  [ "$#" -gt 0 ] || return 0
  local out rc line f reason n detail
  out=$(python3 "$SCRUB" redact --apply "$@" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    echo "WARN: scrub-and-continue ($tier): scrub.py redact exited $rc — refusing to" >&2
    echo "      commit blind. Output:" >&2
    printf '%s\n' "$out" | tail -20 >&2
    _sc_ledger "$tier" "scrub-error" "" "redact exit $rc"
    return 1
  fi
  while IFS= read -r line; do
    if [[ "$line" =~ ^redacted\ ([0-9]+)\ in\ (.*)$ ]]; then
      # Read BASH_REMATCH into locals BEFORE any function call — calling
      # _sc_counts_get runs a `[` test that resets it.
      f="${BASH_REMATCH[2]}"; n="${BASH_REMATCH[1]}"
      detail=$(_sc_counts_get "$f" "$n")
      echo "WARN: scrub-and-continue ($tier) REDACTED $n secret(s) in $f $(_sc_counts_get "$f")" >&2
      _sc_ledger "$tier" redacted "$f" "$detail"
    elif [[ "$line" =~ ^SKIP\(unsafe\)\ (.*):\ (.*)$ ]]; then
      f="${BASH_REMATCH[1]}"; reason="${BASH_REMATCH[2]}"
      echo "WARN: scrub-and-continue ($tier) COULD NOT redact $f ($reason) — file left" >&2
      echo "      untouched and still staged; the pre-commit gate will block this commit." >&2
      _sc_ledger "$tier" skipped-unsafe "$f" "$reason"
    fi
  done <<< "$out"
  # VERIFY: anything still dirty after the rewrite is a survivor, not a shrug.
  local survivors=()
  sc_scan_hits "$tier" survivors "$@" || return 1
  local s
  for s in ${survivors[@]+"${survivors[@]}"}; do
    echo "WARN: scrub-and-continue ($tier) SECRET SURVIVED redaction in $s $(_sc_counts_get "$s")" >&2
    _sc_ledger "$tier" survived "$s" "$(_sc_counts_get "$s")"
  done
  return 0
}
