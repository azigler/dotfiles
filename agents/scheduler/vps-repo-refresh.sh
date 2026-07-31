#!/bin/bash
# vps-repo-refresh.sh — bring marketing-vps's checkouts to the published tip and
# emit a signed-off RECEIPT, or fail loudly and emit nothing. Runs ON THE VPS.
#
# Context: explore-7iz9 selects architecture (c) — the five migrating DI +
# weekly-report pulse ticks run on the LinearB company seat on marketing-vps, with
# credentials brokered over a reverse SSH tunnel rather than copied to that shared
# disk. This script is the first clause of Zig's instruction: "the vps needs to
# keep its repos up to date."
#
# Measured state before this existed (2026-07-26, marketing-vps):
#   - no cron, and only two user timers (vault-sync + a launchpad cache clean);
#     NOTHING pulled anything.
#   - ~/dotfiles was 55 commits behind origin/main, ~/linearb 3 behind.
#   - EVERY submodule uninitialized: dashboard-dev-interrupted, weekly-reporting
#     and agent-factory were empty DIRECTORIES.
#
# ---------------------------------------------------------------------------
# DIRTY IS NORMAL. DIRTY NEVER BLOCKS. NOTHING HERE EVER CLEANS A DIRTY FILE.
# ---------------------------------------------------------------------------
# Zig, 2026-07-30 (dotfiles-f4ub): *"pulses shouldn't trigger a tripwire if state
# is dirty. they should proceed, so they can work in messy repos... but yea it
# shouldn't try to nuke or clean up repos when they're dirty, they're all WIPs."*
#
# That inverts what this script used to do, deliberately, and it cost a full fleet
# outage to learn. An agent on the box left `benchmarks-2026.md` uncommitted in
# ~/linearb; the dirty-tree tripwire wrote NO receipt; vps-preflight fail-closed;
# EVERY dispatched pulse row on every project blocked. And the remedy the tripwire
# printed — `git checkout -- <path>` — would have destroyed verified
# benchmark-canon work. It survived only because the diff got inspected first.
#
# So, the three rules that replace the tripwire:
#
#   1. A dirty tracked file is a WARNING carried in the receipt, never a failure.
#      The refresh completes, the receipt is written, the dispatch proceeds.
#   2. NOTHING in this script resets, checks out, stashes or cleans a dirty
#      tracked file, and no failure text recommends that anyone else does. Every
#      repo on this box is somebody's work in progress.
#   3. FLAGGING IS THE PRICE OF PROCEEDING. Removing the block removes the thing
#      that made a stale-code run impossible, so the replacement has to make
#      staleness VISIBLE: the receipt carries `dirty` (which paths, per repo),
#      `pull_advanced` (did the fast-forward actually move HEAD), and `warnings`.
#      pulse-dispatch-remote.sh puts that in the tick's DISPATCH.md and in the
#      ledger row. A tick that ran against a stale tree and said nothing is the
#      failure this design must not create — "missing output he catches, WRONG
#      output he cannot."
#
# ---------------------------------------------------------------------------
# THE OTHER DESIGN POINTS: fail-closed on REAL faults, and never trust a cached ref
# ---------------------------------------------------------------------------
# The governing risk of the whole migration is that a remote tick's INFRASTRUCTURE
# failure is indistinguishable from its normal `blocked` state, on a box nobody
# watches. So:
#
#  1. The receipt is DELETED FIRST and written only when nothing genuinely FAILED
#     (a missing repo, a dead remote, a broken manifest — not dirt). A crashed or
#     killed refresh therefore leaves NO receipt at all — never a stale one. The
#     gate treats "no receipt" as failure, so the failure mode of this script is
#     "the tick does not run", not "the tick runs against yesterday".
#
#  2. Staleness is measured against `git ls-remote`, a LIVE query — never against
#     the local `origin/<branch>` ref. This is not paranoia, it is a bug that was
#     caught live on 2026-07-26: on the VPS,
#         git rev-list --count HEAD..origin/main   ->  0     (looks current!)
#         ...after a real `git fetch`...           ->  55    (55 commits behind)
#     A staleness check that reads the cached remote-tracking ref reports GREEN on
#     a checkout five days stale. That is exactly the silent-wrong-answer class
#     this mechanism exists to eliminate, so it must not be reintroduced inside it.
#
#  3. Every failure names its own remedy on stderr, tagged `REFRESH-FAIL:`. stderr
#     is never suppressed: a swallowed git error reading as "no data" is the same
#     bug class again.
#
# Ordering is load-bearing (the loop invariant):
#     a. re-sync the listed submodules to the umbrella gitlink -> gitlinks clean
#     b. harvest (COPY, never reset) any tick-written tracked file
#     c. RECORD any other dirty tracked file                   -> warn + receipt
#     d. ls-remote, fetch, merge --ff-only the umbrella        -> may refuse; warn
#     e. submodule update --init (applies any new pin)
#     f. fetch each listed submodule and detach at ITS branch tip
#   (e) leaves the gitlinks dirty relative to the pin, which is why the next run
#   starts at (a). Without (a) the ff-only pull in (d) would start failing the
#   moment Zig bumps a pin.
#
#   Since dotfiles-f4ub, (b) no longer resets and (c) no longer blocks, so (d)'s
#   fast-forward CAN be refused when an incoming commit touches a file that is
#   dirty here. That is recorded (`pull_advanced: false`), not fatal: the box then
#   holds an older tree, and judging whether that is acceptable belongs to
#   vps-preflight on the machine Zig watches, not to a script on the box.
#
# Usage:
#   vps-repo-refresh.sh [--manifest FILE] [--self-update] [--assert] [--quiet]
#
#   --self-update  Pull $HOME/dotfiles first and re-exec if THIS script or the
#                  manifest changed, so the dispatcher can never run a stale copy
#                  of the very thing that fixes staleness. Solves the bootstrap
#                  chicken-and-egg (the script ships to the box via the mechanism
#                  it implements).
#   --assert       Validate an EXISTING receipt only: no network, no git writes.
#                  Cheap enough for a tick's own preflight to call directly.
#   --manifest     Default: <script dir>/vps-repo-manifest.txt
#
# Exit codes:  0 ok · 64 usage · 65 manifest · 69 missing tool · 70 refresh failed
#              75 receipt assertion failed
#
# Bead: explore-7iz9

set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
MANIFEST="$HERE/vps-repo-manifest.txt"
STATE="${VPS_REFRESH_STATE:-$HOME/.cache/vps-repo-refresh}"
RECEIPT="$STATE/receipt.json"
FAILURE="$STATE/last-failure.txt"
HARVEST="$STATE/harvest"
SELF_UPDATE=0
ASSERT_ONLY=0
QUIET=0
# Max receipt age, seconds, for --assert. Default 30 min: comfortably longer than
# a refresh + tick handshake, far shorter than any pulse cadence.
MAX_AGE="${VPS_RECEIPT_MAX_AGE:-1800}"

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)    MANIFEST=$2; shift 2 ;;
    --self-update) SELF_UPDATE=1; shift ;;
    --assert)      ASSERT_ONLY=1; shift ;;
    --quiet)       QUIET=1; shift ;;
    --max-age)     MAX_AGE=$2; shift 2 ;;
    -h|--help)     sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "vps-repo-refresh: unknown arg $1" >&2; exit 64 ;;
  esac
done

say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
die()  { printf 'REFRESH-FAIL: %s\n' "$*" >&2; mkdir -p "$STATE" 2>/dev/null
         printf '%s REFRESH-FAIL: %s\n' "$(date -u +%FT%TZ)" "$*" >> "$FAILURE"
         exit "${2:-70}"; }

command -v git >/dev/null 2>&1 || die "git not on PATH (PATH=$PATH)" 69

# ---------------------------------------------------------------------------
# Manifest parsing. Expand $HOME / ~ but nothing else — no eval, the manifest is
# data and must never be able to execute.
# ---------------------------------------------------------------------------
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST" 65

expand() {
  local p=$1
  p=${p//\$HOME/$HOME}
  # shellcheck disable=SC2088  # the tilde is DATA from the manifest, matched
  # literally on purpose — this branch is the hand-rolled expansion shellcheck
  # is telling us to do, and quoting is what keeps globbing off.
  case "$p" in "~/"*) p="$HOME/${p#\~/}" ;; esac
  printf '%s' "$p"
}

REPOS=() ; SUBS=() ; REQS=() ; REQ_OOB=() ; READONLY=() ; BEADSTORES=() ; HARVESTS=()
while read -r kind a b c _rest; do
  case "${kind:-}" in
    ''|'#'*)     continue ;;
    repo)        REPOS+=("$(expand "$a")|${b:-origin}|${c:-main}") ;;
    submodule)   SUBS+=("$(expand "$a")|$b|${c:-main}") ;;
    readonly)    READONLY+=("$(expand "$a")") ;;
    beadstore)   BEADSTORES+=("$(expand "$a")|$b") ;;
    harvest)     HARVESTS+=("$(expand "$a")|$b") ;;
    require)     REQS+=("$(expand "$a")") ;;
    require-oob) REQ_OOB+=("$(expand "$a")") ;;
    # The complement tier is PUSHED by pulse-dispatch-remote.sh (which alone knows
    # what git owns on zig-computer). Here we only assert the parent landed, so an
    # unknown-directive death cannot take the whole refresh down.
    require-oob-untracked) REQ_OOB+=("$(expand "$a")") ;;
    # `oob-exclude` is a SECURITY DECLARATION, not a refresh instruction: it names
    # a path that must never be pushed to this shared box (lb-granola, a
    # LinearB-confidential meeting corpus, which reaches the box by its own git
    # transport). Only pulse-dispatch-remote.sh acts on it, subtracting the path
    # from the complement it enumerates. The refresh's whole job here is to NOT
    # DIE on it — accepted, deliberately a no-op.
    #
    # It was missed when the directive shipped (dotfiles-f5tg, 2026-07-28), and
    # the `*)` arm below then killed every refresh on the box for a day: no
    # receipt written, so vps-preflight fail-closed and EVERY remote pulse row
    # blocked (dotfiles-0bf2). Same lesson as the sibling above, learned the
    # expensive way — this manifest has THREE readers, and a directive only one
    # of them needs must still parse in all three.
    oob-exclude) : ;;
    *) die "manifest: unknown directive '$kind' in $MANIFEST" 65 ;;
  esac
done < "$MANIFEST"

[ ${#REPOS[@]} -gt 0 ] || die "manifest declares no repos" 65

# ---------------------------------------------------------------------------
# --assert: validate an existing receipt. No network, no git. This is what a tick
# calls before it trusts its own checkout.
# ---------------------------------------------------------------------------
if [ "$ASSERT_ONLY" = 1 ]; then
  [ -f "$RECEIPT" ] || {
    echo "REFRESH-FAIL: no receipt at $RECEIPT — the checkout is UNVERIFIED." >&2
    echo "  A refresh either never ran or died partway. Do NOT proceed with the tick." >&2
    echo "  Remedy: $HERE/vps-repo-refresh.sh --self-update" >&2
    exit 75
  }
  gen=$(sed -n 's/.*"generated_epoch"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$RECEIPT" | head -1)
  ok=$(sed -n 's/.*"ok"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' "$RECEIPT" | head -1)
  now=$(date -u +%s)
  [ "$ok" = true ] || { echo "REFRESH-FAIL: receipt says ok=$ok" >&2; exit 75; }
  [ -n "$gen" ]    || { echo "REFRESH-FAIL: receipt has no generated_epoch" >&2; exit 75; }
  age=$(( now - gen ))
  [ "$age" -le "$MAX_AGE" ] || {
    echo "REFRESH-FAIL: receipt is ${age}s old (max ${MAX_AGE}s) — checkout may have drifted." >&2
    exit 75
  }
  say "receipt ok (age ${age}s)"
  exit 0
fi

# ---------------------------------------------------------------------------
# --self-update: get THIS script current before it decides what current means.
# ---------------------------------------------------------------------------
if [ "$SELF_UPDATE" = 1 ]; then
  DOT="$HOME/dotfiles"
  if [ -d "$DOT/.git" ]; then
    before=$( { sha256sum "$0" "$MANIFEST" 2>/dev/null || true; } | awk '{print $1}' | tr '\n' ' ')
    say "self-update: pulling $DOT"
    git -C "$DOT" fetch --quiet origin main \
      || die "self-update: fetch of $DOT failed (see git error above)"
    git -C "$DOT" merge --ff-only --quiet origin/main \
      || die "self-update: $DOT is not fast-forwardable — it has local commits or divergence. The VPS must never author commits; inspect with: git -C $DOT status"
    after=$( { sha256sum "$0" "$MANIFEST" 2>/dev/null || true; } | awk '{print $1}' | tr '\n' ' ')
    if [ "$before" != "$after" ]; then
      say "self-update: script/manifest changed — re-exec"
      exec "$0" --manifest "$MANIFEST" ${QUIET:+--quiet}
    fi
  else
    say "self-update: $DOT is not a git checkout — skipping"
  fi
fi

# ---------------------------------------------------------------------------
# Fail-closed: destroy the old receipt BEFORE touching anything.
# ---------------------------------------------------------------------------
mkdir -p "$STATE" "$HARVEST" || die "cannot create state dir $STATE"
rm -f "$RECEIPT"

FAILURES=()
note_fail() { FAILURES+=("$1"); printf 'REFRESH-FAIL: %s\n' "$1" >&2; }

# A WARNING is a fact the downstream reader must SEE but must not be stopped by:
# dirt, a refused fast-forward, a submodule that could not be moved because
# somebody is mid-edit in it. It goes to stderr tagged REFRESH-WARN and into the
# receipt's `warnings` array — the receipt is still written, and the dispatch
# still proceeds. This array is the whole reason the tripwire could be removed
# without reintroducing the silent-stale-run failure mode.
WARNINGS=()
note_warn() { WARNINGS+=("$1"); printf 'REFRESH-WARN: %s\n' "$1" >&2; }

# JSON-escape one string for the hand-rolled receipt below (no jq on this path).
jstr() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | sed ':a;N;$!ba;s/\n/\\n/g'; }

# `git status --porcelain -uno` limited to tracked files, minus the paths this
# repo is allowed to have dirty (its harvest list).
#
# --ignore-submodules=all, for parity with vps-preflight.sh's check_local(): a
# gitlink reads as modified whenever the submodule checkout is ahead of the
# umbrella's pin, and step (f) below ends EVERY run by detaching each listed
# submodule at its own published tip — so this script itself guarantees that
# state. Without the flag the tripwire accused the box of writing tracked files
# it never touched (`pipeline-website`, dotfiles-h13q) and blocked every
# dispatch. Non-lossy: a submodule that matters gets its own `readonly` manifest
# line and its own pass through this function, where its real contents are
# checked as a repo rather than as one gitlink line in its parent.
tracked_dirt() {
  local repo=$1 out line path allowed
  out=$(git -C "$repo" status --porcelain --untracked-files=no --ignore-submodules=all 2>&1) || {
    printf 'STATUS-ERROR %s' "$out"; return
  }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path=${line:3}
    allowed=0
    for h in "${HARVESTS[@]}"; do
      [ "${h%%|*}" = "$repo" ] && [ "${h#*|}" = "$path" ] && allowed=1
    done
    [ "$allowed" = 1 ] || printf '%s\n' "$path"
  done <<< "$out"
}

# --- (a) re-sync listed submodules to the umbrella gitlink -------------------
# Restores gitlink cleanliness left behind by step (f) of the PREVIOUS run.
#
# `submodule update` (no --force) checks out the pinned sha INSIDE the submodule.
# It carries local modifications forward where it can and REFUSES where it cannot,
# so it never discards a WIP edit — and a refusal is a warning here, not a
# failure: somebody is mid-edit in that submodule and that is allowed now.
for s in "${SUBS[@]}"; do
  repo=${s%%|*}; rest=${s#*|}; sub=${rest%%|*}
  [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || continue
  if [ ! -e "$repo/$sub/.git" ]; then
    say "submodule: $sub is not initialized — cloning (one-time, this is slow)"
  fi
  out=$(git -C "$repo" submodule update --init -- "$sub" 2>&1) \
    || note_warn "submodule init/update could not move $sub in $repo (usually an uncommitted edit inside it — LEFT ALONE on purpose): $out"
done

# --- (b) harvest tick-written tracked files — COPY ONLY, never reset ---------
# This used to preserve a copy and then `git checkout --` the path, so the ff-only
# pull in (d) could not be refused by it. That reset is GONE (dotfiles-f4ub):
# preserving a copy first does not make destroying the working copy acceptable,
# and the same code path is what would have eaten benchmark-canon work on
# 2026-07-30. The copy is a BACKSTOP so a remote-authored ledger row is never
# lost; the file itself stays exactly as the tick left it, and vps-preflight
# copies the preserved version home.
HARVESTED=()
for h in "${HARVESTS[@]}"; do
  repo=${h%%|*}; rel=${h#*|}
  [ -e "$repo/$rel" ] || continue
  if ! git -C "$repo" diff --quiet -- "$rel" 2>/dev/null; then
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    slug=$(printf '%s/%s' "${repo#$HOME/}" "$rel" | tr '/' '_')
    dest="$HARVEST/${stamp}__${slug}"
    if cp -p "$repo/$rel" "$dest" 2>&1; then
      sum=$(sha256sum "$dest" | awk '{print $1}')
      say "harvest: preserved a COPY of $repo/$rel -> $dest (the file itself is left dirty, by design)"
      HARVESTED+=("$dest|$sum")
    else
      note_warn "harvest: could not preserve a copy of $repo/$rel — the file is untouched; land it by hand before it is overwritten"
    fi
  fi
done

# --- (c) RECORD dirty tracked files. Warn, never block, never clean ----------
# The `readonly` directive name is historical twice over. The box is a peer with a
# git identity and may write these checkouts — and since dotfiles-f4ub it may also
# LEAVE them dirty. Every repo here is somebody's work in progress, so the only
# job of this loop is to say so, loudly and specifically, and hand the paths to
# the receipt so the tick and the ledger row both know what tree they got.
#
# What is NOT here, on purpose: any remedy that reverts. `git checkout --` and
# `reset --hard` must never appear in this file's output. The tripwire this
# replaced printed exactly that advice on 2026-07-30 against a file holding
# verified benchmark-canon work.
DIRTY_JSON=()
for repo in "${READONLY[@]}"; do
  [ -d "$repo" ] || { note_fail "declared repo missing: $repo"; continue; }
  dirt=$(tracked_dirt "$repo")
  case "$dirt" in
    # A git that cannot answer is a REAL fault — the one thing in this loop that
    # still fails. "status failed" is not "nothing is dirty"; reading it that way
    # is the swallowed-error-as-no-data bug class.
    STATUS-ERROR*) note_fail "git status failed in $repo: ${dirt#STATUS-ERROR }" ;;
    "") : ;;
    *) note_warn "$repo is DIRTY — uncommitted changes to tracked files:
$(sed 's/^/    /' <<<"$dirt")
    This is a WARNING, not a failure: dirty is normal, dirty is somebody's WIP,
    and nothing here will touch it. The refresh proceeds and so does the tick.
    What it DOES mean downstream: a fast-forward that needs one of these paths
    will be refused, so the box may run an older tree — recorded per repo as
    pull_advanced in the receipt.
    If this dirt is YOURS, land it: git -C $repo add <explicit file paths>
    && git -C $repo commit && git -C $repo push. Never 'git add <directory>' —
    a directory pathspec stages DELETIONS made by anything else touching the tree."
       _paths=$(while IFS= read -r _p; do [ -n "$_p" ] && printf '"%s",' "$(jstr "$_p")"; done <<<"$dirt")
       DIRTY_JSON+=("{\"repo\":\"$(jstr "$repo")\",\"paths\":[${_paths%,}]}") ;;
  esac
  # NO committer-identity assertion. It used to fail the refresh whenever the box
  # had user.email set, on the theory that an unset identity makes `git commit`
  # refuse and is therefore a free guard. Removed 2026-07-27 (Zig) for two reasons:
  #
  # 1. It was a PROXY for the wrong thing. The harm is a DIVERGED CHECKOUT — the
  #    box holding commits or edits that a pull cannot reconcile. Two assertions
  #    above already detect that directly: modified-tracked-files, and HEAD !=
  #    published tip. Both fired on their own the night the box first diverged;
  #    the identity check added no detection, only a second complaint about a
  #    capability. Forbidding the capability is not the same as detecting the harm,
  #    and only one of those is worth blocking a tick over.
  # 2. It was UNENFORCEABLE where it mattered. The identity arrives from the
  #    fleet-wide dotfiles `git/.gitconfig`, symlinked to ~/.gitconfig on every
  #    machine. "Unset it on the box" therefore meant either stripping Zig's
  #    identity from EVERY machine or de-linking the box's gitconfig and breaking
  #    its dotfiles sync. A guard whose only remedy is worse than the thing it
  #    guards gets worked around, not obeyed.
  #
  # What still holds the line, after dotfiles-f4ub relaxed the dirt half: the box
  # must MATCH the published tip. It may have an identity, it may have dirt, and
  # it may not have DIVERGENCE — a commit here that the pull cannot reconcile is
  # still a hard failure at step (d), and vps-preflight still judges sha identity
  # on the machine Zig watches.
done

# --- (d) umbrella repos: live remote query, fetch, ff-only ------------------
REPO_JSON=()
for r in "${REPOS[@]}"; do
  path=${r%%|*}; rest=${r#*|}; remote=${rest%%|*}; branch=${rest#*|}
  if [ ! -d "$path/.git" ] && [ ! -f "$path/.git" ]; then
    note_fail "repo missing or not a git checkout: $path"
    REPO_JSON+=("{\"path\":\"$path\",\"branch\":\"$branch\",\"head\":null,\"remote\":null,\"in_sync\":false}")
    continue
  fi
  # LIVE remote tip. Never `git rev-parse origin/$branch` — that reads a cached
  # ref that reported "0 behind" on a 55-commit-stale checkout (see header).
  rsha=$(git -C "$path" ls-remote "$remote" "refs/heads/$branch" 2>&1 | awk '{print $1}' | head -1)
  case "$rsha" in
    [0-9a-f][0-9a-f]*) : ;;
    *) note_fail "ls-remote failed for $path ($remote/$branch): $rsha"
       REPO_JSON+=("{\"path\":\"$path\",\"branch\":\"$branch\",\"head\":null,\"remote\":null,\"in_sync\":false}")
       continue ;;
  esac
  before_head=$(git -C "$path" rev-parse HEAD 2>/dev/null)
  out=$(git -C "$path" fetch --quiet "$remote" "$branch" 2>&1) \
    || note_fail "fetch failed for $path: $out"
  # A REFUSED FAST-FORWARD IS NO LONGER FATAL (dotfiles-f4ub). Two different things
  # land here and they deserve different words, but neither may destroy anything:
  #   - dirt in the way: an incoming commit touches a file that is uncommitted
  #     here, so git refuses rather than clobber it. Correct behaviour. The box
  #     keeps the older tree and `pull_advanced` records that it did not move.
  #   - real divergence: this checkout has its own commits. Also recorded, also
  #     not repaired here — vps-preflight's sha-identity check is the gate, on
  #     the machine Zig watches.
  # NO `reset --hard` remedy. That line used to live here and it is exactly the
  # advice that would have destroyed a morning's verified work.
  pull_ok=true
  out=$(git -C "$path" merge --ff-only --quiet FETCH_HEAD 2>&1) || {
    pull_ok=false
    note_warn "$path could NOT fast-forward to $remote/$branch — it keeps the tree it has: $out
    Either an incoming commit touches a path that is uncommitted here (git is
    refusing to clobber your WIP, which is correct), or this checkout has its own
    commits. NOTHING has been reverted and nothing will be.
    To land it yourself: commit or push what is yours here first, then re-run.
    To inspect: git -C $path status && git -C $path log --oneline HEAD..FETCH_HEAD"
  }
  head=$(git -C "$path" rev-parse HEAD 2>/dev/null)
  advanced=false; [ "$head" != "$before_head" ] && advanced=true
  sync=false; [ "$head" = "$rsha" ] && sync=true
  [ "$sync" = true ] || note_warn "$path HEAD (${head:0:8}) != published tip (${rsha:0:8}) after the pull — this box is running an OLDER tree. Recorded in the receipt as in_sync=false; vps-preflight decides whether a tick may run against it."
  REPO_JSON+=("{\"path\":\"$path\",\"branch\":\"$branch\",\"head\":\"$head\",\"remote\":\"$rsha\",\"in_sync\":$sync,\"pull_advanced\":$advanced,\"pull_ok\":$pull_ok}")
  say "repo: $path @ ${head:0:8} (tip ${rsha:0:8}, advanced=$advanced)"
done

# --- (e) re-apply any newly pulled gitlink, then (f) track submodule tips ----
SUB_JSON=()
for s in "${SUBS[@]}"; do
  repo=${s%%|*}; rest=${s#*|}; sub=${rest%%|*}; branch=${rest#*|}
  full="$repo/$sub"
  out=$(git -C "$repo" submodule update --init -- "$sub" 2>&1) \
    || note_warn "submodule update could not move $sub after the umbrella pull (usually an uncommitted edit inside it — LEFT ALONE on purpose): $out"
  if [ ! -e "$full/.git" ]; then
    note_fail "submodule $sub is still uninitialized — it is an EMPTY DIRECTORY. A tick there finds no refs/pulse.md and looks like an empty project rather than an error. Remedy: git -C $repo submodule update --init -- $sub"
    SUB_JSON+=("{\"repo\":\"$repo\",\"path\":\"$sub\",\"head\":null,\"remote\":null,\"in_sync\":false}")
    continue
  fi
  rsha=$(git -C "$full" ls-remote origin "refs/heads/$branch" 2>&1 | awk '{print $1}' | head -1)
  case "$rsha" in
    [0-9a-f][0-9a-f]*) : ;;
    *) note_fail "ls-remote failed for submodule $sub: $rsha"
       SUB_JSON+=("{\"repo\":\"$repo\",\"path\":\"$sub\",\"head\":null,\"remote\":null,\"in_sync\":false}")
       continue ;;
  esac
  out=$(git -C "$full" fetch --quiet origin "$branch" 2>&1) \
    || note_fail "fetch failed for submodule $sub: $out"
  # Detach at the published tip, NOT the umbrella's pinned gitlink — the pin lags
  # by days (manifest header). Detached because the tip is the target, not because
  # the box may not commit — it may, but a submodule commit here needs an explicit
  # `git push origin HEAD:main` or this re-detach discards it.
  #
  # This is a REF MOVE, not a path reset: `git checkout --detach <sha>` carries
  # uncommitted edits forward when it can and REFUSES when it cannot, so it never
  # destroys WIP. (`git checkout -- <path>`, the form that does destroy, is gone
  # from this file entirely — see step (b).) A refusal is a warning: the submodule
  # holds somebody's edit and stays where it is.
  sub_before=$(git -C "$full" rev-parse HEAD 2>/dev/null)
  sub_ok=true
  out=$(git -C "$full" checkout --quiet --detach "$rsha" 2>&1) || {
    sub_ok=false
    note_warn "could not move $sub to $rsha — it stays at ${sub_before:0:8} (usually an uncommitted edit in the way; NOTHING was reverted): $out"
  }
  head=$(git -C "$full" rev-parse HEAD 2>/dev/null)
  sub_adv=false; [ "$head" != "$sub_before" ] && sub_adv=true
  sync=false; [ "$head" = "$rsha" ] && sync=true
  [ "$sync" = true ] || note_warn "$sub HEAD (${head:0:8}) != published tip (${rsha:0:8}) — this submodule is running an OLDER tree. Recorded as in_sync=false; vps-preflight is the gate."
  SUB_JSON+=("{\"repo\":\"$repo\",\"path\":\"$sub\",\"head\":\"$head\",\"remote\":\"$rsha\",\"in_sync\":$sync,\"pull_advanced\":$sub_adv,\"pull_ok\":$sub_ok}")
  say "submodule: $sub @ ${head:0:8} (advanced=$sub_adv)"
done

# --- bead-store tripwire ----------------------------------------------------
BEAD_JSON=()
for b in "${BEADSTORES[@]}"; do
  repo=${b%%|*}; rel=${b#*|}; f="$repo/$rel"
  if [ -f "$f" ]; then
    sum=$(sha256sum "$f" | awk '{print $1}')
    prev=""
    [ -f "$STATE/beadprint" ] && prev=$(grep -F "$f " "$STATE/beadprint" 2>/dev/null | awk '{print $2}' | tail -1)
    if [ -n "$prev" ] && [ "$prev" != "$sum" ]; then
      # A pull legitimately changes the JSONL, and so does a bead the box itself
      # wrote (permitted since 2026-07-28). A LOCAL uncommitted change shows up in
      # step (c)'s `dirty` list. Either way this is a recorded observation, never
      # a failure, and the receipt carries the digest.
      say "beadstore: $f changed since last refresh (expected after a pull)"
    fi
    BEAD_JSON+=("{\"path\":\"$f\",\"sha256\":\"$sum\"}")
    grep -vF "$f " "$STATE/beadprint" 2>/dev/null > "$STATE/beadprint.new"
    printf '%s %s\n' "$f" "$sum" >> "$STATE/beadprint.new"
    mv "$STATE/beadprint.new" "$STATE/beadprint"
  else
    note_fail "beadstore missing: $f"
  fi
done

# --- required paths ---------------------------------------------------------
REQ_JSON=()
check_req() {
  local p=$1 oob=$2 ok=true
  if [ -d "$p" ]; then
    [ -n "$(ls -A "$p" 2>/dev/null)" ] || ok=false
  elif [ -f "$p" ]; then
    [ -s "$p" ] || ok=false
  else
    ok=false
  fi
  if [ "$ok" = false ]; then
    if [ "$oob" = 1 ]; then
      note_fail "required OUT-OF-BAND path missing or empty: $p
    git can never deliver this — it is gitignored/local-only. Pulling again will
    not help. It must be copied to the box (rsync) or its consumer descoped."
    else
      note_fail "required path missing or empty: $p"
    fi
  fi
  REQ_JSON+=("{\"path\":\"$p\",\"oob\":$([ "$oob" = 1 ] && echo true || echo false),\"ok\":$ok}")
}
for p in "${REQS[@]}";    do check_req "$p" 0; done
# require-oob entries may be GLOBS (e.g. imc-*), so next month's campaign folder
# is covered without a manifest edit. Expand here; a pattern that matches nothing
# is checked as its literal self, which fails — "declared but absent" stays loud.
for p in "${REQ_OOB[@]}"; do
  shopt -s nullglob
  # shellcheck disable=SC2206  # deliberate word-split: this is the glob expansion
  _m=( $p )
  shopt -u nullglob
  if [ "${#_m[@]}" -gt 0 ]; then
    for _one in "${_m[@]}"; do check_req "$_one" 1; done
  else
    check_req "$p" 1
  fi
done

# ---------------------------------------------------------------------------
# Receipt. Written whenever nothing genuinely FAILED — warnings do not suppress
# it, they RIDE IN it. Suppressing the receipt on dirt was the outage of
# 2026-07-30: no receipt meant vps-preflight fail-closed and every dispatched row
# on the box blocked, with the only diagnosis living in a log on a box nobody
# watches. A receipt that says "here is the dirt, here is what did not move" is
# strictly more useful than no receipt at all.
# ---------------------------------------------------------------------------
join() { local IFS=,; printf '%s' "$*"; }
HARV_JSON=()
for hv in "${HARVESTED[@]:-}"; do
  [ -n "$hv" ] || continue
  HARV_JSON+=("{\"file\":\"${hv%%|*}\",\"sha256\":\"${hv#*|}\"}")
done
WARN_JSON=()
for w in "${WARNINGS[@]:-}"; do
  [ -n "$w" ] || continue
  WARN_JSON+=("\"$(jstr "$w")\"")
done

if [ ${#FAILURES[@]} -gt 0 ]; then
  {
    printf '%s vps-repo-refresh FAILED with %d problem(s) on %s\n' \
      "$(date -u +%FT%TZ)" "${#FAILURES[@]}" "$(hostname -s)"
    printf '  - %s\n' "${FAILURES[@]}"
  } >> "$FAILURE"
  echo "REFRESH-FAIL: ${#FAILURES[@]} problem(s); NO receipt written — the checkout is UNVERIFIED and no tick may run against it." >&2
  echo "  full log: $FAILURE (on $(hostname -s))" >&2
  exit 70
fi

now_epoch=$(date -u +%s)
cat > "$RECEIPT.tmp" <<EOF
{
  "schema": 1,
  "ok": true,
  "host": "$(hostname -s)",
  "generated_at": "$(date -u +%FT%TZ)",
  "generated_epoch": $now_epoch,
  "manifest_sha256": "$(sha256sum "$MANIFEST" | awk '{print $1}')",
  "repos": [$(join "${REPO_JSON[@]:-}")],
  "submodules": [$(join "${SUB_JSON[@]:-}")],
  "beadstores": [$(join "${BEAD_JSON[@]:-}")],
  "required": [$(join "${REQ_JSON[@]:-}")],
  "harvested": [$(join "${HARV_JSON[@]:-}")],
  "clean": $([ ${#DIRTY_JSON[@]} -eq 0 ] && echo true || echo false),
  "dirty": [$(join "${DIRTY_JSON[@]:-}")],
  "warnings": [$(join "${WARN_JSON[@]:-}")]
}
EOF
mv "$RECEIPT.tmp" "$RECEIPT" || die "cannot write receipt $RECEIPT"
if [ ${#WARNINGS[@]} -gt 0 ]; then
  say "receipt written WITH ${#WARNINGS[@]} warning(s): $RECEIPT"
  printf 'REFRESH-WARN: %d warning(s) recorded in the receipt — the refresh SUCCEEDED and the dispatch may proceed. Nothing was reverted.\n' "${#WARNINGS[@]}" >&2
else
  say "receipt written: $RECEIPT"
fi
exit 0
