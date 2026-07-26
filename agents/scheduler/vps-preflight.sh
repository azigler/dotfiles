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
# Usage:
#   vps-preflight.sh [--host marketing-vps] [--manifest FILE] [--max-age 1800]
#                    [--allow-unpushed] [--no-refresh] [--harvest-dir DIR] [--quiet]
#
#   --allow-unpushed  Downgrade axis-3 failures to a loud WARN. For a hand-fired
#                     pilot where you knowingly accept published-but-older code.
#                     NEVER set this in a timer unit.
#   --no-refresh      Judge the existing receipt without driving a refresh
#                     (diagnostics only).
#   --harvest-dir     Where remote-written ledger rows are copied back.
#                     Default ~/.local/state/vps-harvest.
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
    --quiet)          QUIET=1; shift ;;
    -h|--help)        sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "vps-preflight: unknown arg $1" >&2; exit 64 ;;
  esac
done

say()   { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
block() { printf 'VPS-PREFLIGHT: BLOCKED — %s\n' "$1" >&2; exit "$2"; }

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
  [ "$head" = "$rsha" ] || UNPUBLISHED+=("$key: local HEAD ${head:0:8} is NOT the published tip ${rsha:0:8} — the VPS pulls from GitHub, so a remote tick would run OLDER code than your local ticks. Remedy: git -C $path push origin $branch")
  [ -z "$dirt" ]        || UNPUBLISHED+=("$key: uncommitted tracked changes will NOT reach the VPS:
$(sed 's/^/        /' <<<"$dirt")")
}

while read -r kind a b c _rest; do
  case "${kind:-}" in
    repo)      check_local "$(expand "$a")" "${c:-main}" "$a" ;;
    submodule) check_local "$(expand "$a")/$b" "${c:-main}" "$a::$b" ;;
  esac
done < "$MANIFEST"

if [ ${#UNPUBLISHED[@]} -gt 0 ]; then
  printf 'VPS-PREFLIGHT: %d unpublished-work problem(s) on zig-computer:\n' "${#UNPUBLISHED[@]}" >&2
  printf '  - %s\n' "${UNPUBLISHED[@]}" >&2
  if [ "$ALLOW_UNPUSHED" = 1 ]; then
    echo "  (--allow-unpushed: continuing anyway — the remote tick will run PUBLISHED code, which is older than yours)" >&2
  else
    block "zig-computer's work is not published; a pull-based refresh cannot deliver it" 72
  fi
else
  say "local: all in-scope checkouts published and clean"
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
      key=$a ;;
    submodule)
      rhead=$(jq -r --arg p "$b" '.submodules[] | select(.path == $p) | .head'    <<<"$RECEIPT" | head -1)
      rsync=$(jq -r --arg p "$b" '.submodules[] | select(.path == $p) | .in_sync' <<<"$RECEIPT" | head -1)
      key="$a::$b" ;;
    *) continue ;;
  esac
  lsha=${LOCAL_SHA[$key]:-}
  [ -n "$rhead" ] && [ "$rhead" != "null" ] || { MISMATCH+=("$key: absent from the receipt"); continue; }
  [ "$rsync" = true ] || MISMATCH+=("$key: VPS reports in_sync=false")
  [ "$lsha" = "$rhead" ] || MISMATCH+=("$key: VPS ${rhead:0:8} != zig-computer ${lsha:0:8} — NOT the same code")
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
# (the pulse ledger). The refresh preserved it before resetting so the
# fast-forward pull could proceed; landing it is the dispatcher's job, but losing
# it is not an option, so it comes home here.
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

say "VPS-PREFLIGHT: OK — $HOST is identical to zig-computer (receipt ${age}s old)"
exit 0
