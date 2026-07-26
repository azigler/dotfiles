#!/bin/bash
# Test for vps-repo-refresh.sh — the VPS repo-currency mechanism (explore-7iz9).
#
# Hermetic: every "repo" is a real local git repo created in a tmpdir, with a bare
# repo standing in for GitHub. No network, no ssh, nothing on marketing-vps is
# touched. VPS_REFRESH_STATE is redirected per case.
#
# The cases are chosen to prove the FAIL-CLOSED property, because that is the
# whole point of the mechanism: a failed or skipped update must not silently
# proceed into a tick.
#
# Convention matches the rest of agents/scheduler/test-*.sh: executable bash,
# non-zero exit = failure, PASS/FAIL summary on the last line.

set -u

REFRESH="$(cd "$(dirname "$0")" && pwd)/vps-repo-refresh.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

# Identity comes from the ENVIRONMENT, and the global/system gitconfigs are
# neutralized, so the fixtures reproduce the VPS's real shape: `git config
# user.email` resolves to EMPTY (which is what makes `git commit` there refuse)
# while the test can still author fixture commits. Without this the suite would
# read zig-computer's own global identity and every case would trip the guard.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

ok()   { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  FAIL  $1: $2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

# --- build a fixture: bare "origin" + a "VPS" clone one commit behind ---------
# Returns via globals: CASE, UPSTREAM, CLONE, STATE, MANIFEST
fixture() {
  CASE="$ROOT/$1"; mkdir -p "$CASE"
  UPSTREAM="$CASE/origin.git"
  CLONE="$CASE/checkout"
  STATE="$CASE/state"
  MANIFEST="$CASE/manifest.txt"

  git init -q --bare -b main "$UPSTREAM"
  git init -q -b main "$CASE/seed"
  mkdir -p "$CASE/seed/refs"
  echo "routing v1" > "$CASE/seed/refs/pulse.md"
  echo '{"row":1}' > "$CASE/seed/refs/pulse-ledger.jsonl"
  git -C "$CASE/seed" add -A && git -C "$CASE/seed" commit -qm one
  git -C "$CASE/seed" remote add origin "$UPSTREAM"
  git -C "$CASE/seed" push -q origin main

  git clone -q "$UPSTREAM" "$CLONE"
  # The VPS checkout must have NO committer identity — that unset state is the
  # guard that makes `git commit` there impossible.
  git -C "$CLONE" config --unset user.email 2>/dev/null
  git -C "$CLONE" config --unset user.name  2>/dev/null

  cat > "$MANIFEST" <<EOF
repo      $CLONE origin main
readonly  $CLONE
require   $CLONE/refs/pulse.md
EOF
}

advance_upstream() {   # add a commit to "GitHub" so the clone falls behind
  echo "routing v2" > "$CASE/seed/refs/pulse.md"
  git -C "$CASE/seed" commit -qam two
  git -C "$CASE/seed" push -q origin main
}

# shellcheck disable=SC2120  # "$@" is the pass-through for ad-hoc flags when a
# future case needs one; every current case runs the default form.
run() { VPS_REFRESH_STATE="$STATE" "$REFRESH" --manifest "$MANIFEST" --quiet "$@" 2>"$CASE/err"; }

# =============================================================================
echo "case 1: a stale checkout is brought to the published tip and gets a receipt"
fixture c1
advance_upstream
run; rc=$?
check "exit 0"                "$rc" 0
check "receipt written"       "$([ -f "$STATE/receipt.json" ] && echo y || echo n)" y
check "content updated"       "$(cat "$CLONE/refs/pulse.md")" "routing v2"
check "head == published tip" "$(git -C "$CLONE" rev-parse HEAD)" "$(git -C "$UPSTREAM" rev-parse main)"
check "receipt says ok"       "$(jq -r .ok "$STATE/receipt.json")" true
check "receipt in_sync"       "$(jq -r '.repos[0].in_sync' "$STATE/receipt.json")" true

# =============================================================================
echo "case 2: FAIL-CLOSED — a failing refresh leaves NO receipt (never a stale one)"
fixture c2
run >/dev/null                                    # first run: good receipt exists
check "receipt exists first" "$([ -f "$STATE/receipt.json" ] && echo y || echo n)" y
rm -rf "$UPSTREAM"                                # "GitHub" goes away
run; rc=$?
check "exit non-zero"        "$([ "$rc" -ne 0 ] && echo y || echo n)" y
check "OLD receipt destroyed, not left stale" \
                             "$([ -f "$STATE/receipt.json" ] && echo y || echo n)" n
check "stderr carries REFRESH-FAIL" \
                             "$([ "$(grep -c 'REFRESH-FAIL' "$CASE/err")" -ge 1 ] && echo y || echo n)" y
check "stderr says UNVERIFIED" \
                             "$(grep -c 'UNVERIFIED' "$CASE/err")" 1

# =============================================================================
echo "case 3: staleness is measured LIVE, not from the cached remote-tracking ref"
# This is the bug caught on the real VPS 2026-07-26: `rev-list HEAD..origin/main`
# printed 0 on a checkout 55 commits behind, because origin/main had not been
# fetched. A gate reading the cached ref reports GREEN on a five-day-stale box.
fixture c3
advance_upstream
cached=$(git -C "$CLONE" rev-list --count HEAD..origin/main 2>/dev/null)
check "cached ref LIES (says 0 behind)" "$cached" 0
run >/dev/null; rc=$?
check "refresh still exits 0"           "$rc" 0
check "and actually moved HEAD"         "$(git -C "$CLONE" rev-parse HEAD)" "$(git -C "$UPSTREAM" rev-parse main)"

# =============================================================================
echo "case 4: a required path that is missing blocks the receipt"
# The empty-submodule class: an uninitialized submodule is an empty DIRECTORY, so
# a tick there reads as 'empty project', not as broken infrastructure.
fixture c4
echo "require $CLONE/refs/DOES-NOT-EXIST.md" >> "$MANIFEST"
run; rc=$?
check "exit non-zero"        "$([ "$rc" -ne 0 ] && echo y || echo n)" y
check "no receipt"           "$([ -f "$STATE/receipt.json" ] && echo y || echo n)" n
check "names the path"       "$(grep -c 'DOES-NOT-EXIST' "$CASE/err")" 1

# =============================================================================
echo "case 5: an EMPTY required file is treated as missing"
fixture c5
: > "$CLONE/refs/pulse.md"
git -C "$CLONE" checkout -- refs/pulse.md 2>/dev/null   # keep the tree clean
: > "$CLONE/refs/empty.md"
echo "require $CLONE/refs/empty.md" >> "$MANIFEST"
run; rc=$?
check "exit non-zero"  "$([ "$rc" -ne 0 ] && echo y || echo n)" y
check "no receipt"     "$([ -f "$STATE/receipt.json" ] && echo y || echo n)" n

# =============================================================================
echo "case 6: unexpected dirt in a readonly repo is a hard failure"
# This is the bead tripwire: a remote 'br' write dirties .beads/issues.jsonl, and
# two diverged bead stores brick 'br' on BOTH machines (explore-7iz9).
fixture c6
echo "tampered" >> "$CLONE/refs/pulse.md"
run; rc=$?
check "exit non-zero"          "$([ "$rc" -ne 0 ] && echo y || echo n)" y
check "no receipt"             "$([ -f "$STATE/receipt.json" ] && echo y || echo n)" n
check "names read-only rule"   "$(grep -c 'read-only consumer of git' "$CASE/err")" 1

# =============================================================================
echo "case 7: a committer identity on the box is a hard failure"
# The /vps skill lists `git config user.name/email` as a prerequisite. Under
# architecture (c) that is backwards: the UNSET identity is what makes `git
# commit` on the shared box impossible, and it is free.
fixture c7
git -C "$CLONE" config user.email vps@example.com
run; rc=$?
check "exit non-zero"        "$([ "$rc" -ne 0 ] && echo y || echo n)" y
check "names the identity"   "$(grep -c 'committer identity' "$CASE/err")" 1

# =============================================================================
echo "case 8: a tick-written tracked ledger row is harvested, not lost, not blocking"
fixture c8
echo "harvest $CLONE refs/pulse-ledger.jsonl" >> "$MANIFEST"
echo '{"row":2,"status":"done"}' >> "$CLONE/refs/pulse-ledger.jsonl"
advance_upstream
run; rc=$?
check "exit 0 (dirt was expected)" "$rc" 0
check "receipt written"            "$([ -f "$STATE/receipt.json" ] && echo y || echo n)" y
check "ledger reset so pull works" "$(git -C "$CLONE" status --porcelain -uno | wc -l | tr -d ' ')" 0
harvested=$(jq -r '.harvested[0].file' "$STATE/receipt.json")
check "row preserved on disk"      "$([ -s "$harvested" ] && echo y || echo n)" y
check "row content survived"       "$(grep -c '"row":2' "$harvested")" 1

# =============================================================================
echo "case 9: --assert is fail-closed on a missing receipt and on an expired one"
fixture c9
run >/dev/null
VPS_REFRESH_STATE="$STATE" "$REFRESH" --manifest "$MANIFEST" --assert --quiet 2>/dev/null; rc=$?
check "fresh receipt asserts ok"  "$rc" 0
# Backdate the receipt two hours: an old receipt is the "the refresh did not run
# for THIS dispatch" case, and it must be rejected exactly like a missing one.
sed -i "s/\"generated_epoch\": [0-9]*/\"generated_epoch\": $(( $(date -u +%s) - 7200 ))/" "$STATE/receipt.json"
VPS_REFRESH_STATE="$STATE" "$REFRESH" --manifest "$MANIFEST" --assert --quiet 2>"$CASE/err3"; rc=$?
check "expired receipt rejected"  "$([ "$rc" -ne 0 ] && echo y || echo n)" y
check "and names the age"         "$(grep -c 'receipt is 72[0-9][0-9]s old' "$CASE/err3")" 1
rm -f "$STATE/receipt.json"
VPS_REFRESH_STATE="$STATE" "$REFRESH" --manifest "$MANIFEST" --assert --quiet 2>"$CASE/err2"; rc=$?
check "missing receipt rejected"  "$([ "$rc" -ne 0 ] && echo y || echo n)" y
check "and says UNVERIFIED"       "$(grep -c 'UNVERIFIED' "$CASE/err2")" 1

# =============================================================================
echo "case 10: a diverged (non-fast-forwardable) checkout fails loudly"
fixture c10
advance_upstream
git -C "$CLONE" commit -q --allow-empty -m "a commit the VPS should never have" \
  --author="t <t@t>" 2>/dev/null
run; rc=$?
check "exit non-zero"      "$([ "$rc" -ne 0 ] && echo y || echo n)" y
check "no receipt"         "$([ -f "$STATE/receipt.json" ] && echo y || echo n)" n
check "names fast-forward" "$(grep -c 'fast-forwardable' "$CASE/err")" 1

# =============================================================================
echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { printf 'failed: %s\n' "${FAILED_NAMES[@]}"; exit 1; }
