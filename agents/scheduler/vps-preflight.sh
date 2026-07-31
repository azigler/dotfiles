#!/bin/bash
# vps-preflight.sh — THE STALENESS GATE. Runs ON ZIG-COMPUTER, never on the VPS.
#
# Contract, in one sentence: this exits 0 only when marketing-vps's checkouts are
# byte-identical to zig-computer's, and NO tick may be dispatched unless it does.
#
# ---------------------------------------------------------------------------
# Why the gate lives HERE and not on the box
# ---------------------------------------------------------------------------
# The governing risk of the whole migration (explore-7iz9 §10) is that a remote
# tick's infrastructure failure looks exactly like its normal `blocked` state, on
# a box nobody watches. A self-check that runs on the VPS shares that box's
# unwatchedness: when it fails, it fails into a log nobody reads — which is
# precisely the shape of the transcript-vault outage that ran green for 120
# consecutive hours (dotfiles-t6sd).
#
# So the gate is inverted. zig-computer reaches OUT, drives the refresh, pulls the
# receipt BACK, and judges it locally. Every failure — unreachable box, failed
# refresh, empty submodule, stale receipt, sha mismatch — becomes a NONZERO EXIT
# ON THE MACHINE ZIG WATCHES, before a single token is spent remotely. The remote
# tick is not "warned" about staleness; it is never started.
#
# ---------------------------------------------------------------------------
# The three staleness axes (all three are checked; only one is obvious)
# ---------------------------------------------------------------------------
#   1. VPS behind GitHub .......... fixed by the refresh. Measured 2026-07-26:
#      ~/dotfiles was 55 commits behind, ~/linearb 3 behind, all submodules empty.
#   2. Umbrella gitlink behind submodule tip ... handled by tracking the
#      submodule's own branch tip rather than the pin (the pin lagged by days).
#   3. GitHub behind ZIG-COMPUTER — the axis a pull mechanism structurally
#      CANNOT fix, and the one nobody had named. Measured 2026-07-26:
#          dashboard-dev-interrupted  local d7bc7fc (07-25 22:40)
#                                     published eb5d93e (07-24 22:21)
#          weekly-reporting           local 2bc74ec (07-25 22:40)
#                                     published 1824279 (07-21 16:10)
#      i.e. Zig's own checkouts held 1-4 days of UNPUSHED skill edits. A refresh
#      that "succeeded" would have delivered code objectively older than what the
#      local ticks run — a green light on a confidently-wrong tick. Step 1 below
#      is the check for it, and it is why "pull from GitHub" is only safe when
#      paired with a local publish assertion.
#
# The gate's verdict is IDENTITY, not a staleness budget: local sha == remote sha,
# per repo and per submodule. There is no "close enough" window to tune wrong.
#
# ---------------------------------------------------------------------------
# WHAT THIS GATE DELIBERATELY DOES *NOT* BLOCK ON: a dirty working tree
# ---------------------------------------------------------------------------
# Zig, 2026-07-30 (dotfiles-f4ub). Uncommitted tracked changes on THIS machine
# used to be an axis-3 failure — "uncommitted tracked changes will NOT reach the
# VPS" — and blocking on it cost real work twice in one morning. It is now a
# WARNING that is carried forward rather than a block, for three reasons:
#
#   1. Every checkout here is somebody's WIP. Zig edits ~/linearb constantly; a
#      gate that requires a clean tree before any pulse row may run means the
#      whole remote fleet is hostage to whatever is open in an editor.
#   2. It forced a WORSE workaround. With no way to park an in-flight change, a
#      verified benchmark edit had to be encoded into a bead as a patch and the
#      tree restored, so the gate's own remedy became "delete the work".
#   3. The identity check still holds the line that matters. COMMITTED-but-
#      unpublished work (axis 3 proper) is still a hard block, because that means
#      the box would run genuinely different code. Uncommitted work is not code
#      the box would run differently — it is code that simply is not code yet.
#
# The price of not blocking is FLAGGING, and it is not optional: the dirt is
# printed here, written to --report, and pulse-dispatch-remote.sh puts it in the
# tick's DISPATCH.md and in the ledger row. "Missing output he catches; WRONG
# output he cannot" — so a run against a dirty or stale tree must never be silent.
#
# NOTHING HERE EVER CLEANS ANYTHING. No `git checkout --`, no `reset --hard`, no
# stash, and no failure text that recommends one.
#
# Usage:
#   vps-preflight.sh [--host marketing-vps] [--manifest FILE] [--max-age 1800]
#                    [--allow-unpushed] [--no-refresh] [--harvest-dir DIR]
#                    [--report FILE] [--quiet]
#
#   --allow-unpushed  Downgrade axis-3 failures to a loud WARN. For a hand-fired
#                     pilot where you knowingly accept published-but-older code.
#                     NEVER set this in a timer unit.
#   --no-refresh      Judge the existing receipt without driving a refresh
#                     (diagnostics only).
#   --harvest-dir     Where remote-written ledger rows are copied back.
#                     Default ~/.local/state/vps-harvest.
#   --report FILE     Write a JSON checkout-state summary (local dirt, remote
#                     dirt, repos whose pull did not advance). This is the
#                     machine-readable half of the flagging contract above —
#                     the dispatcher reads it into DISPATCH.md and the ledger.
#
# Exit codes: 0 ok · 64 usage · 65 manifest · 69 missing tool
#             71 VPS unreachable · 72 local work unpublished (axis 3)
#             73 remote refresh failed · 74 receipt bad/stale/mismatched
#
# Bead: explore-7iz9

set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
HOST="${VPS_HOST:-marketing-vps}"
MANIFEST="$HERE/vps-repo-manifest.txt"
MAX_AGE=1800
ALLOW_UNPUSHED=0
DO_REFRESH=1
QUIET=0
HARVEST_DIR="${VPS_HARVEST_DIR:-$HOME/.local/state/vps-harvest}"
REPORT=""
# Where the refresh script lives ON THE VPS. Absolute, and reached through the
# box's own ~/dotfiles clone — the script ships by the mechanism it implements.
REMOTE_SCRIPT='$HOME/dotfiles/agents/scheduler/vps-repo-refresh.sh'
REMOTE_RECEIPT='$HOME/.cache/vps-repo-refresh/receipt.json'

while [ $# -gt 0 ]; do
  case "$1" in
    --host)           HOST=$2; shift 2 ;;
    --manifest)       MANIFEST=$2; shift 2 ;;
    --max-age)        MAX_AGE=$2; shift 2 ;;
    --allow-unpushed) ALLOW_UNPUSHED=1; shift ;;
    --no-refresh)     DO_REFRESH=0; shift ;;
    --harvest-dir)    HARVEST_DIR=$2; shift 2 ;;
    --report)         REPORT=$2; shift 2 ;;
    --quiet)          QUIET=1; shift ;;
    -h|--help)        sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "vps-preflight: unknown arg $1" >&2; exit 64 ;;
  esac
done

say()   { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
warn()  { printf 'VPS-PREFLIGHT: WARN — %s\n' "$*" >&2; }
# block() writes the report before exiting: a dispatcher that got blocked still
# wants to know WHAT was dirty, and a report only written on the happy path is a
# report that never exists when it matters.
block() { write_report; printf 'VPS-PREFLIGHT: BLOCKED — %s\n' "$1" >&2; exit "$2"; }

# Carried-forward state, in declaration order of when it is discovered. These are
# WARNINGS, not gates — see the header. They exist so that "the tick proceeded"
# and "the tick proceeded against a messy tree" are distinguishable downstream.
LOCAL_DIRTY=()      # "key\tstatus-lines"  — uncommitted tracked changes HERE
REMOTE_DIRTY_JSON=  # the receipt's .dirty array, verbatim
STALLED=()          # repos/submodules whose pull did not advance ON THE BOX
REPORT_WRITTEN=0
write_report() {
  [ -n "$REPORT" ] || return 0
  [ "$REPORT_WRITTEN" = 0 ] || return 0
  REPORT_WRITTEN=1
  mkdir -p "$(dirname "$REPORT")" 2>/dev/null
  local ld sl
  ld=$(printf '%s\n' "${LOCAL_DIRTY[@]:-}" | jq -R -s -c 'split("\n") | map(select(length>0))')
  sl=$(printf '%s\n' "${STALLED[@]:-}"     | jq -R -s -c 'split("\n") | map(select(length>0))')
  jq -n --argjson local_dirty "$ld" \
        --argjson stalled "$sl" \
        --argjson remote_dirty "${REMOTE_DIRTY_JSON:-[]}" \
        '{local_dirty:$local_dirty, remote_dirty:$remote_dirty, stalled:$stalled,
          clean: (($local_dirty|length)==0 and ($remote_dirty|length)==0 and ($stalled|length)==0)}' \
    > "$REPORT" 2>/dev/null || warn "could not write the checkout-state report to $REPORT"
}

command -v jq  >/dev/null 2>&1 || { echo "vps-preflight: jq required" >&2; exit 69; }
command -v ssh >/dev/null 2>&1 || { echo "vps-preflight: ssh required" >&2; exit 69; }
[ -f "$MANIFEST" ] || { echo "vps-preflight: manifest not found: $MANIFEST" >&2; exit 65; }

# shellcheck disable=SC2088  # the tilde is DATA from the manifest, matched
# literally on purpose — this IS the hand-rolled expansion shellcheck asks for.
expand() { local p=$1; p=${p//\$HOME/$HOME}; case "$p" in "~/"*) p="$HOME/${p#\~/}" ;; esac; printf '%s' "$p"; }

# ---------------------------------------------------------------------------
# Step 1 — LOCAL PUBLISH CHECK (staleness axis 3).
# Nothing downstream can be trusted if the source of truth is not published.
# Keys are manifest-relative ("$HOME/linearb" / "$HOME/linearb::weekly-reporting")
# so the same key matches on both boxes despite the different $HOME.
# ---------------------------------------------------------------------------
declare -A LOCAL_SHA=()
UNPUBLISHED=()

check_local() {          # $1 = local path, $2 = branch, $3 = manifest key
  local path=$1 branch=$2 key=$3 head rsha dirt
  [ -d "$path" ] || { UNPUBLISHED+=("$key: local checkout missing at $path"); return; }
  head=$(git -C "$path" rev-parse HEAD 2>&1) || { UNPUBLISHED+=("$key: rev-parse failed: $head"); return; }
  rsha=$(git -C "$path" ls-remote origin "refs/heads/$branch" 2>&1 | awk '{print $1}' | head -1)
  case "$rsha" in [0-9a-f][0-9a-f]*) : ;; *) UNPUBLISHED+=("$key: ls-remote failed: $rsha"); return ;; esac
  LOCAL_SHA["$key"]=$head
  # --ignore-submodules=all: a gitlink reads as modified whenever the submodule
  # checkout is ahead of the umbrella's pin, which is the NORMAL local state here
  # (Zig doesn't bump pins on every skill edit). Those submodules get their own
  # manifest lines and their own identity check, so ignoring the gitlink noise is
  # non-lossy — and without it every run drowns the real findings.
  # The pulse ledger and .beads/ are excluded for different reasons: the ledger is
  # tick-written churn, and .beads/ is checked by the refresh's own tripwire.
  dirt=$(git -C "$path" status --porcelain --untracked-files=no --ignore-submodules=all 2>/dev/null \
         | grep -v ' refs/pulse-ledger.jsonl$' | grep -v '\.beads/')
  # The remedy DEPENDS ON WHICH WAY the two diverged, and getting it wrong is
  # worse than saying nothing: "push" is the line someone follows at 07:00
  # without thinking, and after an upstream REBASE it would shove an older local
  # HEAD over newer published work. Ask git which case this is.
  if [ "$head" != "$rsha" ]; then
    if git -C "$path" merge-base --is-ancestor "$rsha" "$head" 2>/dev/null; then
      _fix="git -C $path push origin $branch"          # local is genuinely ahead
    elif git -C "$path" merge-base --is-ancestor "$head" "$rsha" 2>/dev/null; then
      _fix="git -C $path fetch origin && git -C $path merge --ff-only origin/$branch"   # simply behind
    else
      _fix="HISTORIES DIVERGED (an upstream rebase does this). If the published tip is authoritative: git -C $path fetch origin && git -C $path reset --hard origin/$branch — this DISCARDS local commits, so check 'git log origin/$branch..HEAD' first"
    fi
    UNPUBLISHED+=("$key: local HEAD ${head:0:8} is NOT the published tip ${rsha:0:8} — the VPS pulls from GitHub, so a remote tick would run code that does not match yours. Remedy: $_fix")
  fi
  # DIRT IS A WARNING, NOT A BLOCK (dotfiles-f4ub). It used to go into
  # UNPUBLISHED and exit 72. See the header for why that was wrong; the short
  # version is that it made the whole remote fleet hostage to whatever Zig had
  # open in an editor, and its only remedy was to destroy the edit.
  # Deliberately NOT accompanied by a "revert it" suggestion: this is somebody's
  # work in progress and nothing in this pipeline may propose deleting it.
  # Kept to ONE line per repo on purpose: this string is both the stderr warning
  # and a JSON array element in --report, and a multi-line element would split
  # into nonsense entries there.
  [ -z "$dirt" ] || LOCAL_DIRTY+=("$key: uncommitted tracked changes stay HERE (the box runs the published tip) — $(printf '%s' "$dirt" | tr '\n' '|' | sed 's/|/ | /g; s/ | $//')")
}

while read -r kind a b c _rest; do
  case "${kind:-}" in
    repo)      check_local "$(expand "$a")" "${c:-main}" "$a" ;;
    submodule) check_local "$(expand "$a")/$b" "${c:-main}" "$a::$b" ;;
  esac
done < "$MANIFEST"

if [ ${#LOCAL_DIRTY[@]} -gt 0 ]; then
  printf 'VPS-PREFLIGHT: %d checkout(s) DIRTY on zig-computer — proceeding (dirty is WIP, not a fault):\n' "${#LOCAL_DIRTY[@]}" >&2
  printf '  - %s\n' "${LOCAL_DIRTY[@]}" >&2
  echo "  This does NOT block the dispatch. The box runs the PUBLISHED tip, so the tick" >&2
  echo "  simply will not see these edits — which is recorded in the ledger row so a later" >&2
  echo "  reader can tell what tree the artifact came from. Nothing here will touch them." >&2
fi

if [ ${#UNPUBLISHED[@]} -gt 0 ]; then
  printf 'VPS-PREFLIGHT: %d unpublished-work problem(s) on zig-computer:\n' "${#UNPUBLISHED[@]}" >&2
  printf '  - %s\n' "${UNPUBLISHED[@]}" >&2
  if [ "$ALLOW_UNPUSHED" = 1 ]; then
    echo "  (--allow-unpushed: continuing anyway — the remote tick will run PUBLISHED code, which is older than yours)" >&2
  else
    # Still a block, deliberately (dotfiles-f4ub scope decision): this is
    # COMMITTED work the box cannot see, i.e. the box would run genuinely
    # different code. Uncommitted work — handled above — is a different axis.
    block "zig-computer's COMMITTED work is not published; a pull-based refresh cannot deliver it (uncommitted work is a warning, not this)" 72
  fi
elif [ ${#LOCAL_DIRTY[@]} -eq 0 ]; then
  say "local: all in-scope checkouts published and clean"
else
  say "local: all in-scope checkouts published (some are dirty — see the warnings above)"
fi

# ---------------------------------------------------------------------------
# Step 2 — reachability. Separated from the refresh so a dead box is a distinct,
# unambiguous exit code rather than a generic ssh failure buried in git output.
# ---------------------------------------------------------------------------
ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true \
  || block "cannot reach $HOST over ssh (BatchMode, 10s)" 71
say "remote: $HOST reachable"

# ---------------------------------------------------------------------------
# Step 3 — drive the refresh. bash -lc because the VPS login shell is zsh (which
# aborts on an unmatched glob) and because `git` is only guaranteed on the LOGIN
# path there. stderr is deliberately NOT suppressed — a swallowed git error that
# reads as "no data" is the exact bug class this gate exists to catch.
# ---------------------------------------------------------------------------
if [ "$DO_REFRESH" = 1 ]; then
  say "remote: running vps-repo-refresh.sh --self-update"
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" \
      "bash -lc 'set -o pipefail; $REMOTE_SCRIPT --self-update'" \
    || block "remote refresh exited non-zero (see REFRESH-FAIL lines above); no receipt was written, so the checkout is UNVERIFIED" 73
fi

# ---------------------------------------------------------------------------
# Step 4 — judge the receipt LOCALLY.
# ---------------------------------------------------------------------------
RECEIPT=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" "bash -lc 'cat $REMOTE_RECEIPT'" 2>&1) \
  || block "no receipt on $HOST — a refresh never completed. Never proceed on a missing receipt: absent is the FAIL-CLOSED state, by design." 74
echo "$RECEIPT" | jq -e . >/dev/null 2>&1 \
  || block "receipt is not valid JSON: $(printf '%.200s' "$RECEIPT")" 74

ok=$(jq -r '.ok'              <<<"$RECEIPT")
gen=$(jq -r '.generated_epoch' <<<"$RECEIPT")
age=$(( $(date -u +%s) - gen ))
[ "$ok" = true ]        || block "receipt reports ok=$ok" 74
[ "$age" -le "$MAX_AGE" ] || block "receipt is ${age}s old (max ${MAX_AGE}s) — refresh did not run for THIS dispatch" 74

# ---------------------------------------------------------------------------
# Step 4a — the receipt's WARNINGS. These do not gate anything; the whole point
# is that they are carried, not swallowed. `dirty` names the box's WIP paths;
# `pull_advanced:false` says a fast-forward was refused (usually because an
# incoming commit touches one of those paths), which is the ONE state that can
# make a tick run last week's logic without anything looking wrong. It has to be
# said out loud here AND land in --report, because the ledger row is the only
# place a later reader can learn what tree an artifact came from.
# ---------------------------------------------------------------------------
REMOTE_DIRTY_JSON=$(jq -c '.dirty // []' <<<"$RECEIPT")
if [ "$(jq -r 'length' <<<"$REMOTE_DIRTY_JSON")" -gt 0 ]; then
  printf 'VPS-PREFLIGHT: %s has DIRTY tracked files — proceeding (they are WIP, and nothing will touch them):\n' "$HOST" >&2
  jq -r '.[] | "  - " + .repo + ": " + (.paths | join(", "))' <<<"$REMOTE_DIRTY_JSON" >&2
fi
# `pull_ok`, NOT `pull_advanced`: a checkout that was ALREADY at the tip does not
# advance either, and reporting that as stalled would cry wolf on the steady
# state — which is how a warning gets trained out of a reader. `pull_ok:false`
# means git actively REFUSED, which is the only interesting case.
while IFS=$'\t' read -r _k _pok; do
  [ -n "$_k" ] || continue
  [ "$_pok" = false ] || continue
  STALLED+=("$_k")
# `if has(...)`, NOT `.pull_ok // true`. jq's `//` is the ALTERNATIVE operator and
# it treats `false` as empty, so `false // true` is `true` — which silently
# reported every refused pull as fine. Never use `//` to default a BOOLEAN.
done < <(jq -r '((.repos // [])[]       | [.path, (if has("pull_ok") then .pull_ok else true end | tostring)]),
                ((.submodules // [])[]  | [(.repo + "/" + .path), (if has("pull_ok") then .pull_ok else true end | tostring)])
                | @tsv' <<<"$RECEIPT")
if [ ${#STALLED[@]} -gt 0 ]; then
  printf 'VPS-PREFLIGHT: %d checkout(s) on %s REFUSED to fast-forward this run:\n' "${#STALLED[@]}" "$HOST" >&2
  printf '  - %s\n' "${STALLED[@]}" >&2
  echo "  Not repaired here — git declined to clobber a WIP edit, which is correct." >&2
  echo "  Whether the resulting older tree is dispatchable is the identity check below," >&2
  echo "  not this line." >&2
fi

# The receipt reports absolute VPS paths (/home/andrew/...) while LOCAL_SHA is
# keyed by manifest text ($HOME/...) — the two boxes have different $HOME. Re-key
# by walking the manifest again and matching the receipt on the path suffix
# (repos) or the exact submodule path (submodules).
MISMATCH=()
while read -r kind a b c _rest; do
  case "${kind:-}" in
    repo)
      rhead=$(jq -r --arg suf "/${a##*/}" '.repos[] | select(.path | endswith($suf)) | .head' <<<"$RECEIPT" | head -1)
      rsync=$(jq -r --arg suf "/${a##*/}" '.repos[] | select(.path | endswith($suf)) | .in_sync' <<<"$RECEIPT" | head -1)
      rpath=$(jq -r --arg suf "/${a##*/}" '.repos[] | select(.path | endswith($suf)) | .path' <<<"$RECEIPT" | head -1)
      key=$a ;;
    submodule)
      rhead=$(jq -r --arg p "$b" '.submodules[] | select(.path == $p) | .head'    <<<"$RECEIPT" | head -1)
      rsync=$(jq -r --arg p "$b" '.submodules[] | select(.path == $p) | .in_sync' <<<"$RECEIPT" | head -1)
      rpath=$(jq -r --arg p "$b" '.submodules[] | select(.path == $p) | (.repo + "/" + .path)' <<<"$RECEIPT" | head -1)
      key="$a::$b" ;;
    *) continue ;;
  esac
  lsha=${LOCAL_SHA[$key]:-}
  [ -n "$rhead" ] && [ "$rhead" != "null" ] || { MISMATCH+=("$key: absent from the receipt"); continue; }
  # If the fast-forward was REFUSED for this checkout, say so in the same breath —
  # otherwise "in_sync=false" reads as a mystery and the reader's first instinct
  # is to reach for a reset, which is precisely the move this whole change exists
  # to prevent. Name the cause and the non-destructive remedy together.
  _why=""
  case " ${STALLED[*]:-} " in
    *" $rpath "*) _why=" — its fast-forward was REFUSED (a WIP edit on the box is in the way). Land or push that edit ON THE BOX and re-run; do NOT reset it." ;;
  esac
  [ "$rsync" = true ] || MISMATCH+=("$key: VPS reports in_sync=false$_why")
  [ "$lsha" = "$rhead" ] || MISMATCH+=("$key: VPS ${rhead:0:8} != zig-computer ${lsha:0:8} — NOT the same code$_why")
done < "$MANIFEST"

# Required paths: an empty submodule is an empty DIRECTORY, and a tick that finds
# no refs/pulse.md there reports "empty project", not "broken infrastructure".
while IFS=$'\t' read -r p pok poob; do
  [ -n "$p" ] || continue
  [ "$pok" = true ] && continue
  if [ "$poob" = true ]; then
    MISMATCH+=("required OUT-OF-BAND path missing on the VPS: $p (gitignored/local-only — pulling will never fix it; rsync it or descope its consumer)")
  else
    MISMATCH+=("required path missing/empty on the VPS: $p")
  fi
done < <(jq -r '.required[] | [.path, (.ok|tostring), (.oob|tostring)] | @tsv' <<<"$RECEIPT")

if [ ${#MISMATCH[@]} -gt 0 ]; then
  printf 'VPS-PREFLIGHT: %d checkout problem(s):\n' "${#MISMATCH[@]}" >&2
  printf '  - %s\n' "${MISMATCH[@]}" >&2
  block "the VPS checkout is not identical to zig-computer's; do NOT dispatch the tick" 74
fi

# ---------------------------------------------------------------------------
# Step 5 — bring back anything the previous remote tick wrote to a tracked file
# (the pulse ledger). The refresh preserves a COPY and, since dotfiles-f4ub,
# leaves the original alone — so this is a backstop against loss, not a rescue
# from a reset. Landing it is the dispatcher's job; losing it is not an option.
# ---------------------------------------------------------------------------
mapfile -t HARV < <(jq -r '.harvested[]?.file' <<<"$RECEIPT")
if [ ${#HARV[@]} -gt 0 ] && [ -n "${HARV[0]:-}" ]; then
  mkdir -p "$HARVEST_DIR"
  for f in "${HARV[@]}"; do
    if scp -q "$HOST:$f" "$HARVEST_DIR/" 2>&1; then
      say "harvest: $HARVEST_DIR/$(basename "$f")  <- remote tick wrote this; land it locally"
    else
      echo "VPS-PREFLIGHT: WARN could not copy back $f (it remains on $HOST)" >&2
    fi
  done
fi

write_report
if [ ${#LOCAL_DIRTY[@]} -gt 0 ] || [ "$(jq -r 'length' <<<"${REMOTE_DIRTY_JSON:-[]}")" -gt 0 ]; then
  say "VPS-PREFLIGHT: OK — $HOST is identical to zig-computer (receipt ${age}s old), with dirty trees noted above and carried forward"
else
  say "VPS-PREFLIGHT: OK — $HOST is identical to zig-computer (receipt ${age}s old)"
fi
exit 0
