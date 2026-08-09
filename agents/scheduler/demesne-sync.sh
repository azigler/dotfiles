#!/bin/bash
# demesne-sync.sh — the re-sync mechanism and the IDENTITY GATE for the
# agent-brain split cutover (dotfiles-lg1z, under
# dotfiles-agent-brain-split-ezeu; the gate this arms is criterion E2 of
# dotfiles-retarget-claude-symlinks-860z).
#
# WHY THIS EXISTS
# The seed step (dotfiles-demesne-repo-seed-clxe) copied the agent tier out of
# the public repo into the private one and then STOPPED. Work kept landing in
# ~/dotfiles. By 2026-08-09 the private copy was ~176 commits stale — seats.yml,
# the hall, the molt, the seat resolver, six new hooks and their suites all
# existed on one side only. The cutover's most important precondition is
# 860z E2: the two trees must be byte-identical IMMEDIATELY BEFORE the symlink
# flip, because a commit landing between seed and flip silently reverts at
# cutover — the harness starts resolving through demesne and the newer work is
# simply gone from under it.
#
# That precondition was PROSE, and it was unrunnable prose: a bare `diff -r`
# over the two trees can never report empty, because both trees carry python
# bytecode, pytest/ruff caches and an installed node_modules that no one has any
# intention of syncing. A gate that cannot pass is a gate nobody runs. This
# script makes it a command with an exit code.
#
# THE SYNCED SET IS THE BRAIN, AND ONLY THE BRAIN
# Derived from ezeu's own count — "359 of 523 tracked files ... are agent brain
# (agents/ 297, refs/ 53, claude/ 9)". Those three directories are what the
# epic's success criteria are written about and what the ~/.claude symlinks
# resolve into, so those three are what this gate covers. The host-service dirs
# the seed also copied (tailscale/ reef/ a1111/ mlx/ ollama/) are deliberately
# OUT of scope: they are the subject of dotfiles-infra-md-depublish-zga2, they
# are not on any symlink path, and widening the synced set would widen what
# `--delete` is allowed to touch for no gate-related benefit.
#
# ONE WAY, ALWAYS. dotfiles -> demesne. There is no reverse mode and there will
# not be one: the public repo is where the work lands and the private repo is
# the copy. A "sync back" verb is how a stale copy overwrites live work.
#
# THE TWO-WRITERS DOCTRINE APPLIES ACROSS REPOS. A dirty ~/demesne means some
# other process — a pulse tick, a sibling session, a half-finished edit — owns
# files in that tree right now. rsync --delete into it would take that work with
# no diff and no undo, which is exactly the failure AGENTS.md records for
# `git stash`. So sync REFUSES on a dirty destination rather than trying to be
# clever about which files are whose.
#
# --delete IS SCOPED TO THE SYNCED DIRS, STRUCTURALLY. Each directory is its own
# rsync invocation with a trailing slash on both sides, so deletion can only ever
# reach inside $DEST/agents, $DEST/refs, $DEST/claude. demesne has its own life
# outside those — docs/, audits/, CLAUDE.md, the host-service dirs — and none of
# it is visible to this script. A single whole-tree `rsync --delete "$SRC/"
# "$DEST/"` would be shorter and would silently delete all of it; test case 6
# exists to kill exactly that mutation.
#
# KNOWN LIMIT — `diff -r` COMPARES CONTENT, NOT MODE. The gate is the one the
# bead names, and it cannot see a permission bit. Measured on the first live
# run: agents/scheduler/lb-granola-publish-guard.sh was 755 in dotfiles and 644
# in demesne; `rsync -a` fixed it (mode is in -a) and `diff -r` reported nothing
# either before or after. For an executable that is real drift — the file is
# there, byte-identical, and will not run. Not closed here on scope grounds; the
# honest reading of a green gate today is "identical in content, unverified in
# mode". A follow-up wants a mode comparison that shares THIS exclusion list
# rather than a second translation of it.
#
# VERBS
#   (default)   sync:  rsync the brain, dotfiles -> demesne
#   --gate      identity gate: `diff -r` under the same exclusions.
#               exit 0 = identical, exit 10 = drift (the diff is printed)
#   --dry-run   both modes; changes nothing, exits 0
#
# THE GATE COMMAND, AS COMMITTED (this repo's rule 2 — a documented example is
# executable, so test-demesne-sync.sh case 9 extracts THESE BYTES out of the
# object DB and runs them, rather than a retyped copy).
#
# It resolves the script through `git rev-parse --show-toplevel` rather than
# hardcoding ~/dotfiles, and that is deliberate on rule-2 grounds: a hardcoded
# path is only executable from one checkout, so the test could not run the
# committed bytes from a worktree — and an example the test cannot execute is
# the wrong-example defect this repo has hit four times. Run it from anywhere
# inside your dotfiles checkout.
#
# GATE-EXAMPLE-BEGIN
# "$(git rev-parse --show-toplevel)/agents/scheduler/demesne-sync.sh" --gate; echo "gate exit=$?"
# GATE-EXAMPLE-END
#
# CONTRACT LINE. Every terminal path prints exactly one of these as its LAST
# stdout line (the daemon-skill verdict discipline demesne-freeze.sh follows —
# a caller greps the last line and never parses prose):
#   sync:  DEMESNE_SYNC_RESULT=OK dirs=<n> changed=<n>
#          DEMESNE_SYNC_RESULT=DRYRUN dirs=<n> changed=<n>
#          DEMESNE_SYNC_RESULT=REFUSED reason=<reason>
#          DEMESNE_SYNC_RESULT=ERROR reason=<reason>
#   gate:  DEMESNE_GATE_RESULT=IDENTICAL dirs=<n> entries=0
#          DEMESNE_GATE_RESULT=DRIFT dirs=<n> entries=<n>
#          DEMESNE_GATE_RESULT=DRYRUN dirs=<n>
#          DEMESNE_GATE_RESULT=ERROR reason=<reason>
#
# EXIT CODES
#   0   success (synced, dry-run, or gate-identical)
#   1   error / usage
#   2   refusal (dirty destination, or a precondition that must be fixed by hand)
#   10  gate found drift  — the ONE code a caller should branch on
#
# TEST SEAMS
#   DEMESNE_SYNC_SRC           override the source root      (default ~/dotfiles)
#   DEMESNE_SYNC_DEST          override the destination root (default ~/demesne)
#   DEMESNE_SYNC_EXCLUDE_FILE  override the exclusion list   (default: beside
#                              this script). Overriding it is a TEST seam, not
#                              an operational one — the whole point of the list
#                              is that it is committed and reviewed.

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

SRC="${DEMESNE_SYNC_SRC:-$HOME/dotfiles}"
DEST="${DEMESNE_SYNC_DEST:-$HOME/demesne}"
EXCLUDE_FILE="${DEMESNE_SYNC_EXCLUDE_FILE:-$SCRIPT_DIR/demesne-sync.exclude}"

# The brain, per dotfiles-agent-brain-split-ezeu's Context. See the header.
SYNCED_DIRS=(agents refs claude)

info() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

sync_result()  { info "DEMESNE_SYNC_RESULT=$*"; }
gate_result()  { info "DEMESNE_GATE_RESULT=$*"; }

# --- the exclusion set ----------------------------------------------------

EXCLUDES=()

# load_excludes — read the committed list into EXCLUDES. Rejects any pattern
# containing a `/`: rsync and diff -x disagree about those (rsync anchors a
# slashed pattern against the transfer root, diff still matches basenames), and
# a pattern that means two different things to the two halves is precisely the
# drift this single-file design exists to prevent.
load_excludes() {
  local line
  if [ ! -f "$EXCLUDE_FILE" ]; then
    warn "ERROR: exclusion list not found: $EXCLUDE_FILE"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    # patterns are single tokens; strip all surrounding whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      */*)
        warn "ERROR: exclusion pattern contains '/': '$line'"
        warn "       rsync and 'diff -x' do not agree on slashed patterns."
        return 1
        ;;
    esac
    EXCLUDES+=("$line")
  done < "$EXCLUDE_FILE"
  if [ "${#EXCLUDES[@]}" -eq 0 ]; then
    warn "ERROR: exclusion list $EXCLUDE_FILE contains no patterns"
    return 1
  fi
  return 0
}

rsync_exclude_args() {
  local p
  for p in "${EXCLUDES[@]}"; do printf '%s\n' "--exclude=$p"; done
}

diff_exclude_args() {
  local p
  for p in "${EXCLUDES[@]}"; do printf '%s\n' "-x"; printf '%s\n' "$p"; done
}

# --- the blindness check ---------------------------------------------------
#
# Every exclusion is a hole in the gate: content matching one is neither copied
# nor compared, so the gate reads IDENTICAL over it either way. That is correct
# for bytecode and catastrophic for brain content. If the source is a git repo,
# assert that no TRACKED path under the synced dirs has a component matching any
# pattern — i.e. that the list only ever hides generated files. Silent when it
# holds; refuses when it does not.
tracked_shadowed_by_excludes() {
  local f p comp
  # Pure existence probe: is the source a git work tree at all? (Fixtures are
  # not, and that is fine — there is nothing tracked to shadow.)
  git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0  # allow-suppress
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local IFS_SAVE=$IFS
    IFS='/'
    # shellcheck disable=SC2206
    local parts=($f)
    IFS=$IFS_SAVE
    local hit=""
    for comp in "${parts[@]}"; do
      for p in "${EXCLUDES[@]}"; do
        # shellcheck disable=SC2053
        if [[ $comp == $p ]] && [ -z "$hit" ]; then
          hit="$f (component \"$comp\" matches exclusion \"$p\")"
        fi
      done
    done
    [ -n "$hit" ] || continue
    # TRACKED-BUT-IGNORED IS DEBRIS, NOT CONTENT. A path the source repo's OWN
    # .gitignore names was force-added or predates the rule — it is precisely
    # the generated matter this list exists to skip, and refusing on it would
    # make the gate unrunnable over an accident. Found live on the first run:
    # three .pyc blobs under agents/skills/scrub-secrets/tests/__pycache__/ have
    # been tracked in ~/dotfiles since 15d271c. Say so, loudly, every run —
    # and do not block on it.
    if git -C "$SRC" check-ignore --no-index -q -- "$f"; then
      warn "note: exclusion covers a TRACKED-BUT-GITIGNORED path in the source"
      warn "      — build debris that should be untracked: $hit"
      continue
    fi
    printf '%s\n' "$hit"
  done < <(git -C "$SRC" ls-files -- "${SYNCED_DIRS[@]}")
  return 0
}

# --- preflight -------------------------------------------------------------

# preflight — shared by both modes. Prints nothing when it passes; sets
# PREFLIGHT_REASON and returns non-zero when it does not.
PREFLIGHT_REASON=""
preflight() {
  local d src_real dest_real shadowed

  if [ ! -d "$SRC" ];  then PREFLIGHT_REASON="src-missing:$SRC";   return 1; fi
  if [ ! -d "$DEST" ]; then PREFLIGHT_REASON="dest-missing:$DEST"; return 1; fi

  src_real=$(cd -- "$SRC" && pwd -P)   || { PREFLIGHT_REASON="src-unreadable";  return 1; }
  dest_real=$(cd -- "$DEST" && pwd -P) || { PREFLIGHT_REASON="dest-unreadable"; return 1; }

  # One way, and never onto itself. Nesting either way would let --delete inside
  # a synced dir reach the other root.
  if [ "$src_real" = "$dest_real" ]; then
    PREFLIGHT_REASON="src-equals-dest"; return 1
  fi
  case "$dest_real/" in "$src_real"/*) PREFLIGHT_REASON="dest-inside-src"; return 1 ;; esac
  case "$src_real/" in "$dest_real"/*) PREFLIGHT_REASON="src-inside-dest"; return 1 ;; esac

  for d in "${SYNCED_DIRS[@]}"; do
    if [ ! -d "$SRC/$d" ]; then PREFLIGHT_REASON="src-dir-missing:$d"; return 1; fi
  done

  shadowed=$(tracked_shadowed_by_excludes)
  if [ -n "$shadowed" ]; then
    warn "ERROR: the exclusion list hides TRACKED source content — the gate would be blind to it:"
    warn "$shadowed"
    PREFLIGHT_REASON="exclusion-shadows-tracked-file"
    return 1
  fi

  return 0
}

# dest_dirty_report — the two-writers guard, sync only. Empty output means the
# destination is a clean git tree (or is not a git repo at all, which is the
# fixture case: nothing to protect, and it is said out loud rather than
# silently treated as clean).
dest_dirty_report() {
  # Pure existence probe (see tracked_shadowed_by_excludes).
  if ! git -C "$DEST" rev-parse --is-inside-work-tree >/dev/null 2>&1; then  # allow-suppress
    warn "note: $DEST is not a git work tree — no dirty-destination check is possible."
    return 0
  fi
  git -C "$DEST" status --porcelain
}

# --- sync ------------------------------------------------------------------

cmd_sync() {
  local dry="$1"
  local d rc changed=0 out dirty line
  local -a ex rs_args

  if ! preflight; then
    warn "ERROR: preflight failed: $PREFLIGHT_REASON"
    if [ "$PREFLIGHT_REASON" = "exclusion-shadows-tracked-file" ]; then
      sync_result "REFUSED reason=$PREFLIGHT_REASON"; return 2
    fi
    sync_result "ERROR reason=$PREFLIGHT_REASON"; return 1
  fi

  dirty=$(dest_dirty_report)
  if [ -n "$dirty" ]; then
    warn "REFUSING: $DEST has uncommitted changes. Another writer owns work in that"
    warn "tree right now, and rsync --delete would take it with no diff and no undo."
    warn "Commit or set aside that work in $DEST first (git stash push -- <paths>,"
    warn "named — never a bare stash), then re-run."
    warn "$dirty"
    sync_result "REFUSED reason=dest-dirty"
    return 2
  fi

  while IFS= read -r line; do ex+=("$line"); done < <(rsync_exclude_args)

  info "source:      $SRC"
  info "destination: $DEST"
  info "synced dirs: ${SYNCED_DIRS[*]}"
  info "exclusions:  ${EXCLUDES[*]}"
  [ "$dry" -eq 1 ] && info "MODE: dry run — nothing will be written"

  for d in "${SYNCED_DIRS[@]}"; do
    # Trailing slashes on BOTH sides: this is what confines --delete to
    # $DEST/$d. Do not collapse this loop into one whole-tree rsync.
    rs_args=(-a --delete --itemize-changes "${ex[@]}")
    [ "$dry" -eq 1 ] && rs_args+=(--dry-run)
    out=$(rsync "${rs_args[@]}" "$SRC/$d/" "$DEST/$d/")
    rc=$?
    if [ "$rc" -ne 0 ]; then
      warn "ERROR: rsync failed for '$d' (rc=$rc)"
      sync_result "ERROR reason=rsync-failed:$d"
      return 1
    fi
    local n=0
    [ -n "$out" ] && n=$(printf '%s\n' "$out" | grep -c .)
    changed=$((changed + n))
    info "--- $d: $n item(s) $([ "$dry" -eq 1 ] && echo 'would change' || echo changed)"
    [ -n "$out" ] && printf '%s\n' "$out"
  done

  if [ "$dry" -eq 1 ]; then
    sync_result "DRYRUN dirs=${#SYNCED_DIRS[@]} changed=$changed"
  else
    sync_result "OK dirs=${#SYNCED_DIRS[@]} changed=$changed"
  fi
  return 0
}

# --- gate ------------------------------------------------------------------

cmd_gate() {
  local dry="$1"
  local d entries=0 out rc all="" line
  local -a ex

  if ! preflight; then
    warn "ERROR: preflight failed: $PREFLIGHT_REASON"
    gate_result "ERROR reason=$PREFLIGHT_REASON"
    [ "$PREFLIGHT_REASON" = "exclusion-shadows-tracked-file" ] && return 2
    return 1
  fi

  while IFS= read -r line; do ex+=("$line"); done < <(diff_exclude_args)

  info "identity gate: $SRC  ==  $DEST"
  info "synced dirs:   ${SYNCED_DIRS[*]}"
  info "exclusions:    ${EXCLUDES[*]}"

  if [ "$dry" -eq 1 ]; then
    for d in "${SYNCED_DIRS[@]}"; do
      info "would run: diff -rq ${ex[*]} $SRC/$d $DEST/$d"
    done
    gate_result "DRYRUN dirs=${#SYNCED_DIRS[@]}"
    return 0
  fi

  for d in "${SYNCED_DIRS[@]}"; do
    out=$(diff -rq "${ex[@]}" "$SRC/$d" "$DEST/$d")
    rc=$?
    # diff: 0 = same, 1 = differences, >1 = trouble
    if [ "$rc" -gt 1 ]; then
      warn "ERROR: diff failed for '$d' (rc=$rc)"
      gate_result "ERROR reason=diff-failed:$d"
      return 1
    fi
    if [ -n "$out" ]; then
      all+="$out"$'\n'
      entries=$((entries + $(printf '%s\n' "$out" | grep -c .)))
    fi
  done

  if [ "$entries" -eq 0 ]; then
    info "no drift under the exclusion set"
    gate_result "IDENTICAL dirs=${#SYNCED_DIRS[@]} entries=0"
    return 0
  fi

  printf '%s' "$all"
  gate_result "DRIFT dirs=${#SYNCED_DIRS[@]} entries=$entries"
  return 10
}

# --- main ------------------------------------------------------------------

usage() {
  cat >&2 <<'EOF'
Usage: demesne-sync.sh [--gate] [--dry-run]

  (no args)   sync the agent brain (agents/ refs/ claude/) dotfiles -> demesne.
              Refuses if the destination has uncommitted changes. --delete is
              scoped to the three synced dirs; nothing else in demesne is
              touched. One way, always.
  --gate      identity gate: diff -r under the same committed exclusion set.
              exit 0 = identical, exit 10 = drift (printed), 1 = error.
  --dry-run   works in both modes; changes nothing and exits 0.

Env: DEMESNE_SYNC_SRC, DEMESNE_SYNC_DEST, DEMESNE_SYNC_EXCLUDE_FILE (test seams)
EOF
}

main() {
  local mode=sync dry=0 a
  for a in "$@"; do
    case "$a" in
      --gate)    mode=gate ;;
      --dry-run) dry=1 ;;
      -h|--help) usage; return 0 ;;
      *)
        warn "ERROR: unknown option: $a"
        usage
        return 1
        ;;
    esac
  done

  if ! load_excludes; then
    if [ "$mode" = gate ]; then gate_result "ERROR reason=bad-exclusion-list"
    else sync_result "ERROR reason=bad-exclusion-list"; fi
    return 1
  fi

  if [ "$mode" = gate ]; then cmd_gate "$dry"; else cmd_sync "$dry"; fi
}

main "$@"
exit $?
