#!/bin/bash
# Test for the ~/.claude/settings.json symlink guard in session-start.sh
# (dotfiles-kdav).
#
# What it guards: settings.json is supposed to BE the tracked template at
# dotfiles/claude/settings.json via a symlink. Claude Code writes global
# settings atomically (temp + rename), and rename() replaces a symlink with a
# regular file. The break is silent and compounding — the live file keeps
# working while the tracked template falls behind (dotfiles-2wqv: 5 settings,
# including ANTHROPIC_BASE_URL and an effortLevel that kills WebSearch on
# Opus 5).
#
# Hook test convention (see test-worktree-guard.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line
#
# HERMETIC BY CONSTRUCTION. The bead's own acceptance criterion says to verify
# "by temporarily replacing the symlink with a copy" — against the REAL
# ~/.claude/settings.json that would be reproducing dotfiles-2wqv as a test
# step, on the machine's live global config, with a window where a crash
# leaves it broken. Every case here runs under a temp $HOME instead, so the
# real file is never read, written, or unlinked.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/session-start.sh"
PASS=0
FAIL=0
FAILED_NAMES=()
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

REAL_SETTINGS="$HOME/.claude/settings.json"
REAL_STATE_BEFORE="missing"
[ -L "$REAL_SETTINGS" ] && REAL_STATE_BEFORE="symlink"
[ ! -L "$REAL_SETTINGS" ] && [ -e "$REAL_SETTINGS" ] && REAL_STATE_BEFORE="regular-file"

# Build a self-contained fake $HOME:
#   $FH/dotfiles/claude/settings.json   the tracked template
#   $FH/.claude/settings.json           live, as either a symlink or a copy
# <mode> = symlink | regular | regular-identical | regular-badjson | absent
new_home() {
  local mode=$1 fh
  fh=$(mktemp -d "$BASE/home.XXXXXX")
  mkdir -p "$fh/dotfiles/claude" "$fh/.claude"
  printf '%s\n' '{"model":"opus","env":{"ANTHROPIC_BASE_URL":"http://tracked"}}' \
    > "$fh/dotfiles/claude/settings.json"
  case "$mode" in
    symlink)  ln -s "$fh/dotfiles/claude/settings.json" "$fh/.claude/settings.json" ;;
    regular)
      # what Claude Code's atomic rename actually leaves behind: a real file
      # that has since DRIFTED from the template.
      printf '%s\n' '{"model":"opus","env":{"ANTHROPIC_BASE_URL":"http://live-proxy"},"effortLevel":"xhigh"}' \
        > "$fh/.claude/settings.json" ;;
    regular-identical)
      cp "$fh/dotfiles/claude/settings.json" "$fh/.claude/settings.json" ;;
    regular-badjson)
      printf '%s\n' 'this is not json {' > "$fh/.claude/settings.json" ;;
    absent) : ;;
  esac
  printf '%s' "$fh"
}

# A REAL repo with a REAL worktree, so the hook's own IN_WORKTREE detection
# (a `.git` FILE, plus /.claude/worktrees/ in the toplevel) is exercised
# rather than simulated.
PROJ="$BASE/proj"
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
git -C "$PROJ" config user.email t@t; git -C "$PROJ" config user.name t
echo seed > "$PROJ/seed"; git -C "$PROJ" add seed; git -C "$PROJ" commit -qm seed
PROJ_WT="$PROJ/.claude/worktrees/agent-test"
git -C "$PROJ" worktree add -q -b worktree-agent-test "$PROJ_WT" >/dev/null
cleanup_proj() { git -C "$PROJ" worktree remove --force "$PROJ_WT" >/dev/null 2>&1; }

# Run the hook with $HOME pointed at the fake home. The cwd is a throwaway
# repo, so the rest of the hook (git context, beads, merge driver) stays inert.
run_hook() { # <fakehome> [worktree] -> stdout
  local fh=$1 kind=${2:-plain} cwd
  if [ "$kind" = "worktree" ]; then
    cwd="$PROJ_WT"
  else
    cwd="$PROJ"
  fi
  ( cd "$cwd" && env HOME="$fh" HARNESS_SESSION_START_LOG="$fh/hook.log" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      bash "$HOOK" <<< "{\"hook_event_name\":\"SessionStart\",\"cwd\":\"$cwd\"}" )
}

# --- 1. the broken state WARNS, and says everything the fix needs ---------
FH=$(new_home regular)
OUT=$(run_hook "$FH")

echo "$OUT" | grep -q 'not a symlink' \
  && ok || bad "regular file: warns that it is not a symlink"

# AC: "names the exact remediation"
echo "$OUT" | grep -qF 'sync.sh claude' \
  && ok || bad "regular file: names 'bash ~/dotfiles/sync.sh claude'"

# AC: "AND the merge-first caveat" — the whole point of dotfiles-2wqv is that
# running sync FIRST throws away the live-only settings.
echo "$OUT" | grep -qi 'merge first' \
  && ok || bad "regular file: states the MERGE FIRST caveat"

# Cheap refinement: name the diverged KEYS so the merge is mechanical.
# `env` differs in value, `effortLevel` exists only live.
echo "$OUT" | grep -q 'Diverged keys' \
  && ok || bad "regular file: lists the diverged keys"
echo "$OUT" | grep -q 'effortLevel' \
  && ok || bad "regular file: names the live-only key (effortLevel)"
echo "$OUT" | grep -q 'env' \
  && ok || bad "regular file: names the value-diverged key (env)"

# --- 2. it does NOT auto-repair (the entire lesson of dotfiles-2wqv) ------
if [ -L "$FH/.claude/settings.json" ]; then
  bad "regular file: hook must NOT re-create the symlink"
else
  ok
fi
if grep -q 'live-proxy' "$FH/.claude/settings.json"; then
  ok
else
  bad "regular file: hook must NOT overwrite the live file's contents"
fi
# …and it must not silently "fix" the template in the other direction either.
if grep -q 'tracked' "$FH/dotfiles/claude/settings.json"; then
  ok
else
  bad "regular file: hook must NOT rewrite the tracked template"
fi

# --- 3. the healthy state is SILENT --------------------------------------
FH=$(new_home symlink)
OUT=$(run_hook "$FH")
if echo "$OUT" | grep -q 'settings.json'; then
  bad "symlink intact: must not warn (got: $(echo "$OUT" | grep 'settings.json' | head -1))"
else
  ok
fi

# --- 4. absent file is not the same failure and must not warn ------------
#     (a fresh machine before sync.sh has run — nothing has DRIFTED yet.)
FH=$(new_home absent)
OUT=$(run_hook "$FH")
if echo "$OUT" | grep -q 'not a symlink'; then
  bad "absent settings.json: must not warn about a symlink that never existed"
else
  ok
fi

# --- 5. broken link but IDENTICAL content: warn, and say so honestly -----
#     The link is still gone (the next Claude Code write diverges it), so the
#     warning must fire — but claiming diverged keys here would be a lie.
FH=$(new_home regular-identical)
OUT=$(run_hook "$FH")
echo "$OUT" | grep -q 'not a symlink' \
  && ok || bad "identical copy: still warns (the link is what's broken)"
echo "$OUT" | grep -q 'No key differences' \
  && ok || bad "identical copy: reports no key differences rather than inventing some"

# --- 6. unparseable live file: say so, never print the reassuring line ----
FH=$(new_home regular-badjson)
OUT=$(run_hook "$FH")
echo "$OUT" | grep -q 'not a symlink' \
  && ok || bad "bad JSON: still warns"
if echo "$OUT" | grep -q 'No key differences'; then
  bad "bad JSON: must NOT claim the files agree when jq could not read them"
else
  ok
fi
echo "$OUT" | grep -q 'not valid JSON' \
  && ok || bad "bad JSON: names the parse failure"

# --- 7. subagents in worktrees are exempt (this fires on EVERY session) ---
FH=$(new_home regular)
OUT=$(run_hook "$FH" worktree)
if echo "$OUT" | grep -q 'not a symlink'; then
  bad "worktree: must not nag every dispatched subagent about global config"
else
  ok
fi

# --- 8. no measurable startup cost on the healthy path -------------------
#     The guard must be one [ -L ] test when the invariant holds; the jq
#     key-diff only runs on the already-broken path. 10 healthy runs must not
#     cost meaningfully more than the hook already did.
FH=$(new_home symlink)
T0=$(date +%s%N)
for _ in 1 2 3 4 5 6 7 8 9 10; do run_hook "$FH" >/dev/null; done
T1=$(date +%s%N)
PER_MS=$(( (T1 - T0) / 10000000 ))
if [ "$PER_MS" -lt 250 ]; then
  ok
else
  bad "healthy path costs ${PER_MS}ms/session — the guard must be a bare [ -L ] test"
fi

# --- 9. THE TEST'S OWN SAFETY PROPERTY -----------------------------------
#     The bead asked for this to be verified by mutating the real symlink.
#     Assert instead that the real one was never touched.
REAL_STATE_AFTER="missing"
[ -L "$REAL_SETTINGS" ] && REAL_STATE_AFTER="symlink"
[ ! -L "$REAL_SETTINGS" ] && [ -e "$REAL_SETTINGS" ] && REAL_STATE_AFTER="regular-file"
if [ "$REAL_STATE_BEFORE" = "$REAL_STATE_AFTER" ]; then
  ok
else
  bad "this test mutated the REAL $REAL_SETTINGS ($REAL_STATE_BEFORE -> $REAL_STATE_AFTER)"
fi

# ============================================================================
# tick-seat settings drift guard (dotfiles-qby3)
#
# ~/.claude-tick/settings.json is a MANAGED REAL FILE by design (not a
# symlink — see agents/bin/sync-tick-settings.sh's header for the bwrap
# jail-bind evidence). session-start.sh shells out to
# `sync-tick-settings.sh --check` and surfaces its output verbatim when it
# fails. These cases exercise that wiring, hermetically (fake $HOME, the
# real ~/.claude-tick is never read or written).
# ============================================================================
REAL_TICK="$HOME/.claude-tick/settings.json"
REAL_TICK_STATE_BEFORE="missing"
[ -L "$REAL_TICK" ] && REAL_TICK_STATE_BEFORE="symlink"
[ ! -L "$REAL_TICK" ] && [ -e "$REAL_TICK" ] && REAL_TICK_STATE_BEFORE="regular-file"

# tick_home <shared-model> <tick-json-or-absent> -> fh
#   Builds on new_home(symlink) (a healthy ~/.claude, so the case isolates
#   the tick guard from the primary symlink guard) and adds a
#   ~/.claude-tick/settings.json fixture.
tick_home() {
  local shared_model=$1 tick_mode=$2 fh
  fh=$(new_home symlink)
  # Overwrite the template with a caller-chosen model so "diverged" /
  # "in sync" is controlled per case.
  printf '{"model":"%s","env":{"FOO":"bar"}}\n' "$shared_model" \
    > "$fh/dotfiles/claude/settings.json"
  mkdir -p "$fh/.claude-tick"
  case "$tick_mode" in
    matching)   printf '{"model":"%s","env":{"FOO":"bar"},"theme":"dark"}\n' "$shared_model" > "$fh/.claude-tick/settings.json" ;;
    diverged)   printf '{"model":"claude-old-stale-model","env":{"FOO":"bar"},"theme":"dark"}\n' > "$fh/.claude-tick/settings.json" ;;
    symlinked)  ln -s "$fh/dotfiles/claude/settings.json" "$fh/.claude-tick/settings.json" ;;
    absent)     : ;;
  esac
  printf '%s' "$fh"
}

# --- 10. diverged tick file: warns loud, names the drifted key -----------
FH=$(tick_home "claude-new-model" diverged)
OUT=$(run_hook "$FH")
echo "$OUT" | grep -q 'DIVERGED' \
  && ok || bad "tick diverged: warns with DIVERGED"
echo "$OUT" | grep -q 'model' \
  && ok || bad "tick diverged: names the drifted key (model)"
echo "$OUT" | grep -qF 'sync-tick-settings.sh' \
  && ok || bad "tick diverged: names the fix command"

# --- 11. tick file in sync: no drift warning ------------------------------
FH=$(tick_home "claude-new-model" matching)
OUT=$(run_hook "$FH")
if echo "$OUT" | grep -q 'DIVERGED'; then
  bad "tick in sync: must not warn (got: $(echo "$OUT" | grep 'DIVERGED' | head -1))"
else
  ok
fi

# --- 12. no tick seat on this box (absent): silent, not attempted --------
FH=$(tick_home "claude-new-model" absent)
OUT=$(run_hook "$FH")
if echo "$OUT" | grep -qi 'tick'; then
  bad "no tick seat: must not mention tick settings at all (got: $(echo "$OUT" | grep -i 'tick' | head -1))"
else
  ok
fi

# --- 13. tick settings.json accidentally made a symlink: warns, doesn't crash
#     (this is exactly the state that breaks the bwrap ro-bind at jail launch —
#     see the sync-tick-settings.sh header for the measured failure.)
FH=$(tick_home "claude-new-model" symlinked)
OUT=$(run_hook "$FH")
echo "$OUT" | grep -qi 'SYMLINK' \
  && ok || bad "tick symlinked: warns that the managed file was replaced by a symlink"

# --- 14. worktree sessions are exempt from the tick guard too ------------
FH=$(tick_home "claude-new-model" diverged)
OUT=$(run_hook "$FH" worktree)
if echo "$OUT" | grep -q 'DIVERGED'; then
  bad "worktree: must not run the tick drift guard for a dispatched subagent"
else
  ok
fi

# --- 15. THE TEST'S OWN SAFETY PROPERTY (tick file) -----------------------
REAL_TICK_STATE_AFTER="missing"
[ -L "$REAL_TICK" ] && REAL_TICK_STATE_AFTER="symlink"
[ ! -L "$REAL_TICK" ] && [ -e "$REAL_TICK" ] && REAL_TICK_STATE_AFTER="regular-file"
if [ "$REAL_TICK_STATE_BEFORE" = "$REAL_TICK_STATE_AFTER" ]; then
  ok
else
  bad "this test mutated the REAL $REAL_TICK ($REAL_TICK_STATE_BEFORE -> $REAL_TICK_STATE_AFTER)"
fi

# ============================================================================
# dotfiles-tm0w: the tracked-template lookup goes through agents_root(claude)
# now, not a hardcoded $HOME/dotfiles/claude path. Two cases: total resolution
# failure must be LOUD (not silently skip the diagnostic), and the everyday
# $HOME/dotfiles fallback (already exercised by every case above, since
# new_home() only ever populates $fh/dotfiles/claude/) must keep working.
# ============================================================================

# --- 16. no tracked template ANYWHERE (no ~/.agents, no ~/dotfiles/claude) --
#     -> still warns about the broken symlink, but says explicitly that the
#     key-diff could not run, naming why (agents_root() found nothing) rather
#     than silently omitting the "Diverged keys" / "No key differences" lines.
FH=$(mktemp -d "$BASE/home.XXXXXX")
mkdir -p "$FH/.claude"
printf '%s\n' '{"model":"opus","env":{"ANTHROPIC_BASE_URL":"http://live-proxy"}}' \
  > "$FH/.claude/settings.json"
OUT=$(run_hook "$FH")
echo "$OUT" | grep -q 'not a symlink' \
  && ok || bad "no template anywhere: still warns about the broken symlink"
echo "$OUT" | grep -q 'could not diff the keys' \
  && ok || bad "no template anywhere: names that the key-diff could not run"
echo "$OUT" | grep -qF 'agents_root()' \
  && ok || bad "no template anywhere: cites agents_root() as the thing that found nothing"
if echo "$OUT" | grep -q 'Diverged keys'; then
  bad "no template anywhere: must not fabricate a key-diff with nothing to diff against"
else
  ok
fi

# --- 17. the everyday case: template found via the \$HOME/dotfiles fallback -
#     Every case above already exercises this (new_home() only ever populates
#     $fh/dotfiles/claude/), so this just makes the assertion explicit: the
#     resolver's fallback tier is what is under test here, not a fluke of the
#     other cases' fixtures.
FH=$(new_home regular)
OUT=$(run_hook "$FH")
echo "$OUT" | grep -q 'Diverged keys' \
  && ok || bad "dotfiles fallback: key-diff runs when \$HOME/dotfiles/claude/settings.json exists"

# --- Summary ---
cleanup_proj
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
exit 1
