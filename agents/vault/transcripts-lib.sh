#!/usr/bin/env bash
# transcripts-lib.sh — claude-transcripts vault helpers (explore-76oc Phase 3, §4.3).
# Sourced by bootstrap-transcripts.sh, vault-push-transcripts.sh, and the selftest.
#
# Parallel to vault-lib.sh (the claude-memory vault), deliberately a SEPARATE file:
# the memory vault auto-runs every session end and must not be destabilized by
# transcripts changes. Future: DRY the shared helpers into vault-core.sh once both
# are proven.
#
# Layout (D1 — detached git-dir + shared work-tree; the two vaults share ONE tree,
# each with its own excludesFile so neither stages the other's paths):
#   git-dir   = ~/.claude/vaults/transcripts.git   (OUTSIDE the tree → no root .git)
#   work-tree = ~/.claude/projects                 (READ-ONLY to this vault, always)
#   excludes  = ~/dotfiles/agents/vault/transcripts.excludes  (jsonl + tool-results txt)
#
# Storage = plain delta-git (git-lfs REJECTED, D5/OQ-C1). A single file that would
# breach GitHub's 100 MiB wall is stored as line-boundary CHUNKS injected into the
# vault object store (split-on-copy) — the live file on disk is NEVER touched, moved,
# gzipped, or truncated (Zig 2026-07-08: keep full history + stay flexible for future
# huge transcripts). `cat <path>.part* > <path>` reconstructs the original byte-exact.
#
# Identity is inherited (global, Zig) — this file NEVER runs `git config --global`
# (explore-62q5). Commits are authored by Zig with Claude as co-author.

VAULT_DIR="${VAULT_DIR:-$HOME/.claude/vaults}"
TRANSCRIPTS_GIT="${TRANSCRIPTS_GIT:-$VAULT_DIR/transcripts.git}"
TRANSCRIPTS_WORKTREE="${TRANSCRIPTS_WORKTREE:-$HOME/.claude/projects}"
TRANSCRIPTS_EXCLUDES="${TRANSCRIPTS_EXCLUDES:-$HOME/dotfiles/agents/vault/transcripts.excludes}"
TRANSCRIPTS_LOCK="${TRANSCRIPTS_LOCK:-$VAULT_DIR/.transcripts.lock}"
TRANSCRIPTS_REPO="${TRANSCRIPTS_REPO:-azigler/claude-transcripts}"
TRANSCRIPTS_VISCACHE="${TRANSCRIPTS_VISCACHE:-$VAULT_DIR/.transcripts-visibility}"
TRANSCRIPTS_OVERSIZE_LOG="${TRANSCRIPTS_OVERSIZE_LOG:-$HOME/.claude/.transcripts-oversize.log}"
SCRUB="${SCRUB:-$HOME/.claude/skills/scrub-secrets/scrub.py}"

# scrub-and-continue (dotfiles-t6sd): redact secrets in staged content and KEEP
# PUSHING, instead of letting the fail-closed gate stall the vault. Sourced from
# alongside this file so both tiers share one implementation.
_TL_HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [ -f "$_TL_HERE/scrub-continue.sh" ]; then
  # shellcheck source=/dev/null
  . "$_TL_HERE/scrub-continue.sh"
fi

# Size thresholds (bytes). GitHub hard-rejects a single file >100 MiB; we chunk at
# 99 MiB into <=95 MiB parts to leave margin for growth within the stage→push window.
TS_WALL_BYTES="${TS_WALL_BYTES:-104857600}"        # 100 MiB — GitHub hard wall (never push a blob this big)
TS_SPLIT_TRIGGER="${TS_SPLIT_TRIGGER:-103809024}"  # 99 MiB — at/above → split-on-copy
TS_WARN_BYTES="${TS_WARN_BYTES:-94371840}"         # 90 MiB — warn loudly (visibility)
TS_CHUNK_HUMAN="${TS_CHUNK_HUMAN:-95M}"            # split -C size per part (<= 95 MiB, line-bounded)

# Raw vault git op — NO lock. Caller MUST hold the flock or be single-threaded.
tgit() {
  git --git-dir="$TRANSCRIPTS_GIT" \
      --work-tree="$TRANSCRIPTS_WORKTREE" \
      -c core.excludesFile="$TRANSCRIPTS_EXCLUDES" "$@"
}

# Locked single op — for one-shot external callers (bootstrap / selftest).
tvault() {
  mkdir -p "$VAULT_DIR" 2>/dev/null
  flock -w 10 "$TRANSCRIPTS_LOCK" \
    git --git-dir="$TRANSCRIPTS_GIT" \
        --work-tree="$TRANSCRIPTS_WORKTREE" \
        -c core.excludesFile="$TRANSCRIPTS_EXCLUDES" "$@"
}

# Network vault op with a HARD timeout — a stalled connection must never hang the
# daily push. NOTE: bootstrap's INITIAL push must NOT use this (a multi-hundred-MB
# first push can exceed the timeout) — it uses a bare `tvault push`.
tgit_net() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "${VAULT_NET_TIMEOUT:-120}" git --git-dir="$TRANSCRIPTS_GIT" \
      --work-tree="$TRANSCRIPTS_WORKTREE" -c core.excludesFile="$TRANSCRIPTS_EXCLUDES" "$@"
  else
    git --git-dir="$TRANSCRIPTS_GIT" \
      --work-tree="$TRANSCRIPTS_WORKTREE" -c core.excludesFile="$TRANSCRIPTS_EXCLUDES" "$@"
  fi
}

# Echo PRIVATE / PUBLIC / INTERNAL / UNKNOWN, cached once/day (OQ-E2). Fail CLOSED:
# any error → UNKNOWN and the caller refuses to push. (Transcripts-local copy of the
# memory helper, keyed to TRANSCRIPTS_REPO + its own cache — no shared-lib edit.)
t_cached_repo_visibility() {
  local today line d v vis gh_cmd
  today=$(date -u +%F)
  if [ -f "$TRANSCRIPTS_VISCACHE" ]; then
    line=$(cat "$TRANSCRIPTS_VISCACHE" 2>/dev/null)
    d="${line%% *}"; v="${line#* }"
    if [ "$d" = "$today" ] && [ -n "$v" ]; then echo "$v"; return 0; fi
  fi
  gh_cmd=(gh repo view "$TRANSCRIPTS_REPO" --json visibility -q .visibility)
  command -v timeout >/dev/null 2>&1 && gh_cmd=(timeout 15 "${gh_cmd[@]}")
  vis=$("${gh_cmd[@]}" 2>/dev/null | tr '[:lower:]' '[:upper:]')
  if [ -n "$vis" ]; then
    mkdir -p "$VAULT_DIR" 2>/dev/null
    printf '%s %s\n' "$today" "$vis" > "$TRANSCRIPTS_VISCACHE" 2>/dev/null
  else
    vis="UNKNOWN"
  fi
  echo "$vis"
}

# A staged path is a legitimate transcript iff it is a *.jsonl or a tool-results/*.txt
# (optionally a .partNNN chunk of either) AND is not under */memory/. Used by the
# inverse leak-guard. Echoes nothing = OK; echoes the offending path(s) = leak.
_transcripts_leaked_paths() {
  local staged
  staged=$(tgit diff --cached --name-only 2>/dev/null) || true
  # NOTE the `|| true` on every grep: grep exits 1 when it matches NOTHING, which is
  # the GOOD (no-leak) case. Without the guards this function returns 1 on success,
  # and a `leaked=$(_transcripts_leaked_paths)` under `set -e` (bootstrap) aborts the
  # script on the no-leak path. (The memory vault-lib.sh guards the same way.)
  {
    # anything NOT an allowed transcript/tool-result path (or its chunk)
    printf '%s\n' "$staged" | grep -Ev '(\.jsonl|/tool-results/[^/]+\.txt)(\.part[0-9]{3})?$' || true
    # anything under a memory/ dir (belt-and-suspenders — memory is the other vault)
    printf '%s\n' "$staged" | grep -E '/memory/' || true
  } | { grep -v '^$' || true; } | sort -u
}

# split-on-copy: for one oversize staged file, replace its full-file index entry with
# line-boundary chunk blobs (<= TS_CHUNK_HUMAN each) injected into the object store.
# The live file on disk is NEVER read-then-written — only READ (split reads it) and
# the vault INDEX is edited. Deterministic: same head bytes → same chunk shas → tiny
# daily delta on an append-only file. Returns 1 on any failure (caller refuses commit).
_chunk_oversize_into_index() {
  local path="$1" f="$2" tmp part sha partpath i=1
  tmp=$(mktemp -d) || return 1
  # line-bounded chunks p000, p001, ... each <= TS_CHUNK_HUMAN bytes.
  if ! split -C "$TS_CHUNK_HUMAN" -d -a 3 -- "$f" "$tmp/p" 2>/dev/null; then
    echo "WARN: transcripts chunk split failed for $path" >&2; rm -rf "$tmp"; return 1
  fi
  # drop the full-file blob add -A staged (and any prior canonical tracking).
  tgit rm -q --cached -- "$path" >/dev/null 2>&1 || tgit reset -q -- "$path" >/dev/null 2>&1 || true
  for part in "$tmp"/p*; do
    [ -f "$part" ] || continue
    sha=$(tgit hash-object -w -- "$part" 2>/dev/null) || {
      echo "WARN: transcripts chunk hash-object failed for $path" >&2; rm -rf "$tmp"; return 1; }
    partpath=$(printf '%s.part%03d' "$path" "$i")
    tgit update-index --add --cacheinfo "100644,$sha,$partpath" 2>/dev/null || {
      echo "WARN: transcripts chunk update-index failed for $partpath" >&2; rm -rf "$tmp"; return 1; }
    i=$((i+1))
  done
  rm -rf "$tmp"
  echo "note: chunked oversize transcript $path -> $((i-1)) part(s) (live file untouched; cat *.part* to reconstruct)" >&2
  printf '%s\t%s\t%s parts\n' "$(date -u +%FT%TZ)" "$path" "$((i-1))" >> "$TRANSCRIPTS_OVERSIZE_LOG" 2>/dev/null || true
  return 0
}

# Scan staged files for oversize (>= TS_SPLIT_TRIGGER) and chunk each. Also warns on
# >= TS_WARN_BYTES. Returns 1 if any chunk operation failed.
_transcripts_apply_size_guard() {
  local path f sz rc=0 warned=0
  while IFS= read -r -d '' path; do
    f="$TRANSCRIPTS_WORKTREE/$path"
    [ -f "$f" ] || continue
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [ "$sz" -ge "$TS_SPLIT_TRIGGER" ]; then
      _chunk_oversize_into_index "$path" "$f" || rc=1
    elif [ "$sz" -ge "$TS_WARN_BYTES" ]; then
      echo "note: large transcript $path ($((sz/1048576)) MiB) — under the 100 MiB wall, committed whole" >&2
      warned=1
    fi
  done < <(tgit diff --cached --name-only -z 2>/dev/null)
  return $rc
}

# SCRUB-AND-CONTINUE (dotfiles-t6sd). Runs on the STAGED set, after `add -A` and
# BEFORE the size guard — the chunker builds its .partNNN blobs by re-reading the
# on-disk file, so redacting first is what makes the chunks clean too.
#
# Three outcomes per staged transcript:
#   * clean            -> untouched, staged, committed. The overwhelmingly common case.
#   * dirty + not live -> redacted in place, re-staged, committed. Ledger row + WARN.
#   * dirty + LIVE     -> NEVER rewritten (see _sc_is_live: os.replace swaps the inode
#                         out from under an appending writer and silently eats every
#                         later line). Instead the path is UNSTAGED for this run only
#                         and picked up on a later fire once the session goes quiet.
#                         Deferring ONE file for one cycle replaces stalling the whole
#                         vault indefinitely. A live file that is CLEAN is staged and
#                         committed exactly as before — the common path is unchanged.
# Returns 1 only when scrub.py itself is broken; everything else continues and, if
# it could not be cleaned, is caught by the unchanged fail-closed pre-commit gate.
_transcripts_scrub_and_continue() {
  [ "${VAULT_SCRUB_CONTINUE:-1}" = "1" ] || return 0
  declare -F sc_scan_hits >/dev/null 2>&1 || return 0   # helper absent -> inert
  local path base f rel rc
  local -a cand=() live=() hits=() livehits=()
  local -A seen=()
  while IFS= read -r -d '' path; do
    base="$path"
    case "$path" in *.part[0-9][0-9][0-9]) base="${path%.part[0-9][0-9][0-9]}";; esac
    [ -n "${seen[$base]:-}" ] && continue
    seen[$base]=1
    f="$TRANSCRIPTS_WORKTREE/$base"
    [ -f "$f" ] || continue          # index diverged from disk: the gate scans the blob
    if _sc_is_live "$f"; then live+=("$f"); else cand+=("$f"); fi
  done < <(tgit diff --cached --name-only -z --diff-filter=d 2>/dev/null)

  if [ "${#cand[@]}" -gt 0 ]; then
    sc_scan_hits transcripts hits "${cand[@]}"; rc=$?
    [ "$rc" -eq 1 ] && return 1                       # scrub.py broken -> FAILED
    if [ "$rc" -eq 0 ] && [ "${#hits[@]}" -gt 0 ]; then
      sc_redact_files transcripts "${hits[@]}" || return 1
      # re-stage so the REDACTED bytes are the staged bytes (only on the rare path
      # where something actually changed — this re-walks the work-tree).
      tgit add -A >/dev/null 2>&1 || true
    fi
  fi

  # Live files: scanned but never rewritten. A dirty one is unstaged for this run.
  if [ "${#live[@]}" -gt 0 ]; then
    sc_scan_hits transcripts livehits "${live[@]}"; rc=$?
    [ "$rc" -eq 1 ] && return 1
    for f in ${livehits[@]+"${livehits[@]}"}; do
      rel="${f#"$TRANSCRIPTS_WORKTREE"/}"
      tgit reset -q -- "$rel" >/dev/null 2>&1 || true
      tgit reset -q -- "$rel".part[0-9][0-9][0-9] >/dev/null 2>&1 || true
      echo "WARN: scrub-and-continue (transcripts) DEFERRED $rel — a secret is present" >&2
      echo "      but the session is still writing to it; rewriting a live transcript" >&2
      echo "      would lose the writer's later lines. Unstaged this run only; it is" >&2
      echo "      redacted and committed on the next fire after the session goes quiet." >&2
      _sc_ledger transcripts deferred-live "$f" "${_SC_COUNTS[$f]:-}"
    done
  fi
  return 0
}

# The locked body of the daily push. Benign errors quiet (note:), real errors loud
# (WARN:) — OQ-A3. Mirrors _vault_push_locked but with the transcripts guards.
#
# RETURN STATUS (dotfiles-t6sd) — identical tier-status contract to
# _vault_push_locked in vault-lib.sh; keep the two in lockstep:
#   0 OK | 1 FAILED | 2 BLOCKED | 3 DEFERRED | 4 SKIPPED | 9 INERT
# This is the tier whose 120 consecutive gate-blocked pushes read as 0/SUCCESS.
_transcripts_push_locked() {
  local vis out leaked
  vis=$(t_cached_repo_visibility)
  if [ "$vis" != "PRIVATE" ]; then
    echo "note: transcripts push skipped (visibility=$vis)" >&2
    return 4
  fi
  if ! out=$(tgit add -A 2>&1); then
    echo "WARN: transcripts vault stage failed: $out" >&2
    return 1
  fi
  # SCRUB-AND-CONTINUE — redact staged secrets in place and keep going. Must run
  # BEFORE the size guard (the chunker re-reads the file from disk) and before the
  # commit (so the pre-commit gate sees redacted content).
  if ! _transcripts_scrub_and_continue; then
    tgit reset -q 2>/dev/null || true
    echo "WARN: transcripts vault REFUSED — the secret redactor is broken (nothing committed)" >&2
    return 1
  fi
  # SIZE GUARD (split-on-copy) — replace any oversize staged blob with chunk parts
  # BEFORE the leak guard + commit, so no >100 MiB blob ever reaches the pack/push.
  if ! _transcripts_apply_size_guard; then
    tgit reset -q 2>/dev/null || true
    echo "WARN: transcripts vault REFUSED — size-guard/chunk failure (nothing committed)" >&2
    return 1
  fi
  # INVERSE LEAK GUARD (mirror of memory's, scrutiny-finding-1 class): an in-tree
  # .gitignore can override core.excludesFile, so re-assert EVERY run that only
  # transcript paths (+ their .partNNN chunks) are staged and NOTHING under memory/.
  leaked=$(_transcripts_leaked_paths)
  if [ -n "$leaked" ]; then
    tgit reset -q 2>/dev/null || true
    echo "WARN: transcripts vault REFUSED — non-transcript/memory path(s) staged (excludes bypassed?):" >&2
    printf '%s\n' "$leaked" | head >&2
    return 1
  fi
  # PEER delete-guard (spec lin-i2d.1 OQ-09/OQ-13): on a peer (marker present),
  # never propagate deletions from a sparse/absent work-tree — strip staged
  # deletions, keep adds/mods. No-op on the primary. Mirrors the memory guard.
  if [ -f "${VAULT_DIR:-$HOME/.claude/vaults}/.peer" ]; then
    local dels; dels=$(tgit diff --cached --diff-filter=D --name-only 2>/dev/null || true)
    if [ -n "$dels" ]; then
      echo "WARN: peer delete-guard (transcripts) stripped $(printf '%s\n' "$dels" | grep -c .) staged deletion(s):" >&2
      printf '%s\n' "$dels" | sed 's#/.*##' | sort -u | head >&2
      printf '%s\n' "$dels" | while IFS= read -r f; do [ -n "$f" ] && tgit reset -q -- "$f" 2>/dev/null; done
    fi
  fi
  if tgit diff --cached --quiet 2>/dev/null; then
    return 0                                   # nothing changed
  fi
  # Name the commit after the slug(s) actually changed — derived from the STAGED
  # files (the daily push commits many slugs' transcripts at once), consistent with
  # the memory vault fix (explore-ha3v).
  local slugs nslugs subj; local -a msg
  slugs=$(tgit diff --cached --name-only 2>/dev/null | sed 's#/.*##' | sort -u | grep -v '^$' || true)
  nslugs=$(printf '%s\n' "$slugs" | grep -c . || true)
  if [ "$nslugs" -le 1 ]; then
    subj="transcripts: ${slugs:-snapshot} $(date -u +%FT%TZ)"
    msg=(-m "$subj")
  else
    subj="transcripts: ${nslugs} slugs $(date -u +%FT%TZ)"
    msg=(-m "$subj" -m "$(printf '%s\n' "$slugs")")
  fi
  # authored by Zig (inherited global identity), Claude as co-author.
  msg+=(-m "Co-Authored-By: Claude <noreply@anthropic.com>")
  if ! out=$(tgit commit -q "${msg[@]}" 2>&1); then
    # a pre-commit-hook block (Layer-1 secret gate or the >=100MiB belt-and-suspenders)
    # or a real fs failure — loud, and raise the secret alert marker for /onboard.
    echo "WARN: transcripts vault commit blocked/failed:" >&2
    printf '%s\n' "$out" >&2
    if printf '%s' "$out" | grep -qi 'secret'; then
      printf 'transcripts vault commit blocked by secret gate %s\n' "$(date -u +%FT%TZ)" \
        > "$HOME/.claude/.secret-alert" 2>/dev/null || true
    fi
    return 2
  fi
  # reconcile then best-effort push — bounded by timeout, benign on failure but
  # reported: a deferred push did not reach the remote (dotfiles-t6sd).
  tgit_net pull --rebase --autostash -q origin main >/dev/null 2>&1 || true
  if ! tgit_net push -q origin main >/dev/null 2>&1; then
    echo "note: transcripts push deferred" >&2
    return 3
  fi
}

# Daily push entrypoint (§4.3). ONE flock spans the whole add→guard→commit→pull→push
# critical section. Inert until bootstrap runs.
#
# Returns the tier-status code (0/1/2/3/4/9 — see _transcripts_push_locked) rather
# than the old unconditional 0. Best-effort callers (session-end.sh) already guard
# with `|| true`; vault-push-transcripts.sh propagates it as its own exit status.
vault_push_transcripts() {
  local rc
  [ -d "$TRANSCRIPTS_GIT" ] || return 9
  mkdir -p "$VAULT_DIR" 2>/dev/null
  find "$TRANSCRIPTS_GIT" -name index.lock -mmin +5 -delete 2>/dev/null
  (
    flock -w 10 9 || { echo "note: transcripts vault busy (lock timeout)" >&2; exit 3; }
    _transcripts_push_locked
  ) 9>"$TRANSCRIPTS_LOCK"
  rc=$?
  return "$rc"
}
