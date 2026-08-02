#!/bin/bash
# Test for pre-shared-tree-guard.sh — the shared-working-tree guard
# (explore-igrd).
#
# Hook test convention (see test-worktree-guard.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line
#
# The name must be test-<SCRIPT BASENAME>.sh, prefix included — the repo's
# tools/githooks/pre-commit maps a staged `pre-shared-tree-guard.sh` to
# `test-pre-shared-tree-guard.sh` literally. Named `test-shared-tree-guard.sh`
# this suite ran only when IT was staged, and the gate printed "no suite
# found" for the hook itself: a coverage gap that looks green.
#
# ⚠️ RUN UNDER BASH, NOT ZSH. Every hook suite here shares that rule.
#
# THE POINT OF THIS SUITE, and why it starts real systemd units. A guard that
# has never been watched refusing is the vacuity this fleet keeps
# rediscovering. The hook's whole verdict hinges on "is another writer active
# in this repo", and that answer comes from systemd + the harnessd manifest —
# so faking it with a test-only env backdoor would test a code path that never
# runs in production. Instead the suite starts REAL transient user units
# (`systemd-run --user`) and points the hook at a REAL fixture manifest via
# $HARNESS_MANIFEST, so the same LastTriggerUSec / ledger / bounce reads the
# live hook makes are the ones under test.
#
# Every BLOCK case is paired with an ALLOW case in the same syntactic
# position: a guard that blocks everything is not a guard.
#
# If systemd --user is unavailable the writer-dependent cases SKIP loudly
# rather than passing vacuously.

set -u

HOOKDIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HOOKDIR/pre-shared-tree-guard.sh"
# The suite parses and renders timestamps for its own fixtures. `date -d` /
# `date -u -d @N` are GNU-only, so on BSD every one of those lines died and
# took the fixture with it — the same defect the hook had (dotfiles-5vz2).
. "$HOOKDIR/lib/portable.sh"
PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()

TMP=$(mktemp -d "${TMPDIR:-/tmp}/stg-test.XXXXXX")
# PHYSICAL path. The hook resolves the repo with `git rev-parse
# --show-toplevel` from a `pwd -P` cwd, and detector B compares that against a
# unit's WorkingDirectory / ExecStart verbatim. On macOS the fixture root is
# under /var/folders, /var is a symlink to /private/var, and an unresolved
# fixture path therefore never matches the resolved one the hook computes —
# the detector-B cases fail for a reason that has nothing to do with the hook.
TMP=$(cd "$TMP" && pwd -P)
REPO="$TMP/repo"
MANIFEST="$TMP/manifest.json"
BOUNCES="$TMP/bounces.jsonl"
UNIT_A="stg-test-a-$$"
UNIT_B="stg-test-b-$$"
UNIT_C="stg-test-c-$$"

cleanup() {
  systemctl --user stop "$UNIT_A.timer" "$UNIT_A.service" >/dev/null 2>&1
  systemctl --user stop "$UNIT_B.service" "$UNIT_C.service" >/dev/null 2>&1
  systemctl --user reset-failed "$UNIT_A.timer" "$UNIT_A.service" \
    "$UNIT_B.service" "$UNIT_C.service" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- fixture repo ----------------------------------------------------------
mkdir -p "$REPO/refs" "$REPO/sub"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
echo one > "$REPO/one.txt"
echo two > "$REPO/sub/two.txt"
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","row":"t","outcome":"quiet"}' > "$REPO/refs/test-ledger.jsonl"
cat > "$REPO/slow.sh" <<'SH'
#!/bin/bash
exec /bin/sleep 600
SH
chmod +x "$REPO/slow.sh"
git -C "$REPO" add one.txt sub/two.txt refs/test-ledger.jsonl slow.sh
git -C "$REPO" commit -qm seed
: > "$BOUNCES"

# A second, unrelated repo — equally dirty, no loop declared for it.
REPO2="$TMP/other"
mkdir -p "$REPO2"
git -C "$REPO2" init -q -b main
git -C "$REPO2" config user.email t@t
git -C "$REPO2" config user.name t
echo x > "$REPO2/f.txt"
git -C "$REPO2" add f.txt
git -C "$REPO2" commit -qm seed
echo dirty > "$REPO2/wip.txt"

write_manifest() {   # $1 = timer stem, $2 = grace_minutes
  cat > "$MANIFEST" <<EOF
{"version":1,"projects":[
  {"key":"probe","path":"$REPO","loops":[
    {"timer":"$1","ledger":"refs/test-ledger.jsonl","ledger_row":"t","grace_minutes":$2}
  ]},
  {"key":"nullpin","path":"$TMP/absent","loops":[
    {"timer":"never-fires","ledger":"refs/x.jsonl","ledger_row":null,"grace_minutes":90}
  ]}
]}
EOF
}
write_manifest "$UNIT_A" 90

dirty()  { echo "tick-wip-$RANDOM" > "$REPO/tick-capture.txt"; }
clean()  { rm -f "$REPO/tick-capture.txt"; git -C "$REPO" checkout -q -- . 2>/dev/null; }

# run_case <name> <want_exit> <command> [want_stderr] [extra env...]
run_case() {
  local name=$1 want=$2 cmd=$3 want_stderr=${4:-}
  local extra=()
  if [ "$#" -gt 4 ]; then shift 4; extra=("$@"); fi
  local payload stderr_out got
  payload=$(jq -cn --arg c "$cmd" --arg d "$REPO" '{tool_input:{command:$c},cwd:$d}')
  stderr_out=$(echo "$payload" | env HARNESS_MANIFEST="$MANIFEST" \
      HARNESS_PULSE_BOUNCES="$BOUNCES" ${extra[@]+"${extra[@]}"} "$HOOK" 2>&1 >/dev/null)
  got=$?
  if [ "$got" -ne "$want" ]; then
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name (exit: want $want, got $got)"); return
  fi
  if [ -n "$want_stderr" ] && ! echo "$stderr_out" | grep -qF "$want_stderr"; then
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name (stderr missing: $want_stderr)"); return
  fi
  PASS=$((PASS + 1))
}

# run_case_cwd — same, but the session cwd is somewhere else entirely.
run_case_cwd() {
  local name=$1 want=$2 cmd=$3 cwd=$4 want_stderr=${5:-}
  local payload stderr_out got
  payload=$(jq -cn --arg c "$cmd" --arg d "$cwd" '{tool_input:{command:$c},cwd:$d}')
  stderr_out=$(echo "$payload" | env HARNESS_MANIFEST="$MANIFEST" \
      HARNESS_PULSE_BOUNCES="$BOUNCES" "$HOOK" 2>&1 >/dev/null)
  got=$?
  if [ "$got" -ne "$want" ]; then
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name (exit: want $want, got $got)"); return
  fi
  if [ -n "$want_stderr" ] && ! echo "$stderr_out" | grep -qF "$want_stderr"; then
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name (stderr missing: $want_stderr)"); return
  fi
  PASS=$((PASS + 1))
}

# --- cases that need no writer at all --------------------------------------

# 1. no destructive verb → ALLOW (and the hook exits on its cheap pre-filter)
dirty
run_case "allow: an ordinary command" 0 'git status --porcelain'

# 2. prose that merely MENTIONS the verb inside a quoted message → ALLOW.
#    command_skeleton blanks quoted contents; without it this is a false block
#    on a commit message that documents the rule.
run_case "allow: 'git stash' inside a quoted commit message" 0 \
  'git commit -m "do not git stash on a shared tree"'

# --- the writer: a REAL transient systemd timer -----------------------------
#
# ⚠️ WHY THERE IS ALSO A DOUBLE (dotfiles-5vz2). Everything from here to the
# `fi # HAVE_SYSTEMD` at the bottom is the entire substance of this suite — 27
# of its 29 cases — and on macOS it skipped WHOLESALE, because macOS has no
# systemd. The suite then printed a green "PASS: 2/2 (skipped: 1)" while the
# hook's `date -d` was failing on every call on that box. A skip is not a pass,
# and a skip that swallows 93% of a suite is indistinguishable from one.
#
# So: REAL transient units when systemd is there (Linux — unchanged, and still
# the authority, because the whole point of this suite is that the hook reads
# real systemd state), and a PATH-level `systemctl` / `systemd-run` DOUBLE when
# it is not. The double is deliberately at the PATH boundary, not inside the
# hook: there is no test-only branch in the hook, so the code path exercised is
# byte-for-byte the production one, including the LastTriggerUSec string format
# that the timestamp parse has to cope with. The summary line says which mode
# ran, every time — a double you cannot see in the output is the same problem
# as a skip you cannot see.
FAKE_SYSTEMD=0
if ! command -v systemctl >/dev/null 2>&1 || ! command -v systemd-run >/dev/null 2>&1; then
  FAKE_SYSTEMD=1
  FAKEBIN="$TMP/bin"
  FAKEUNITS="$TMP/units"
  mkdir -p "$FAKEBIN" "$FAKEUNITS"

  cat > "$FAKEBIN/systemctl" <<'STUB'
#!/bin/bash
# Minimal `systemctl --user` double: answers exactly the four queries
# pre-shared-tree-guard.sh and this suite make, off flat files in $FAKEUNITS.
D=${FAKEUNITS:?}
CMD=""; UNIT=""; VALUE=0; PROPS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --user|--no-legend|--plain|--no-pager|--type=*|--state=*|--quiet) ;;
    --value) VALUE=1 ;;
    -p) shift; PROPS+=("$1") ;;
    -p*) PROPS+=("${1#-p}") ;;
    -*) ;;
    *) if [ -z "$CMD" ]; then CMD=$1; elif [ -z "$UNIT" ]; then UNIT=$1
       else UNITS_EXTRA="${UNITS_EXTRA:-} $1"; fi ;;
  esac
  shift
done
case "$CMD" in
  show)
    if [ -z "$UNIT" ]; then                 # `show -p Version --value`
      for p in ${PROPS[@]+"${PROPS[@]}"}; do
        [ "$p" = Version ] && echo 255 || echo ""
      done
      exit 0
    fi
    for p in ${PROPS[@]+"${PROPS[@]}"}; do
      v=""
      [ -f "$D/$UNIT" ] && v=$(sed -n "s/^$p=//p" "$D/$UNIT" | head -1)
      if [ "$VALUE" = 1 ]; then printf '%s\n' "$v"; else printf '%s=%s\n' "$p" "$v"; fi
    done ;;
  list-units)
    for f in "$D"/*.service; do
      [ -e "$f" ] || continue
      grep -q '^ActiveState=activating' "$f" || continue
      printf '%s loaded activating start running\n' "$(basename "$f")"
    done ;;
  stop)
    for u in $UNIT ${UNITS_EXTRA:-}; do
      [ -f "$D/$u" ] || continue
      sed 's/^ActiveState=.*/ActiveState=inactive/' "$D/$u" > "$D/$u.new" && mv "$D/$u.new" "$D/$u"
    done ;;
esac
exit 0
STUB

  cat > "$FAKEBIN/systemd-run" <<'STUB'
#!/bin/bash
# Minimal `systemd-run --user` double: materializes the unit files the
# systemctl double above reads. A timer unit records LastTriggerUSec in
# systemd's OWN rendering ("Sat 2026-08-01 14:00:21 PDT") — that exact string
# is what the hook has to parse, and parsing it is what was broken.
D=${FAKEUNITS:?}
UNIT=""; TYPE=simple; WD=""; TIMER=0; EXECSTART=""
while [ $# -gt 0 ]; do
  case "$1" in
    --user|--no-block|--quiet) ;;
    --unit=*) UNIT=${1#--unit=} ;;
    --on-active=*) TIMER=1 ;;
    --timer-property=*) ;;
    --property=Type=*) TYPE=${1#--property=Type=} ;;
    --property=WorkingDirectory=*) WD=${1#--property=WorkingDirectory=} ;;
    --property=*) ;;
    -*) ;;
    *) EXECSTART="$*"; break ;;
  esac
  shift
done
[ -n "$UNIT" ] || exit 1
mkdir -p "$D"
printf 'Type=%s\nWorkingDirectory=%s\nExecStart=%s\nActiveState=activating\n' \
  "$TYPE" "$WD" "$EXECSTART" > "$D/$UNIT.service"
[ "$TIMER" = 1 ] && printf 'LastTriggerUSec=%s\nActiveState=waiting\n' \
  "$(date '+%a %Y-%m-%d %H:%M:%S %Z')" > "$D/$UNIT.timer"
exit 0
STUB

  chmod +x "$FAKEBIN/systemctl" "$FAKEBIN/systemd-run"
  export FAKEUNITS
  PATH="$FAKEBIN:$PATH"
  export PATH
fi

HAVE_SYSTEMD=0
# ⚠️ NOT `systemctl --user is-system-running`: it prints "degraded" and exits
# 1 whenever ANY user unit is in the failed state, which is a normal steady
# state on this box — using it as the availability probe skipped every case
# below while reporting a green 2/2. Ask the manager something it can only
# answer if it is reachable.
if command -v systemd-run >/dev/null 2>&1 \
   && systemctl --user show -p Version --value >/dev/null 2>&1; then
  # A oneshot service that stays `activating` for the whole suite keeps the
  # transient TIMER loaded too — transient units are garbage-collected once
  # they finish, which would take LastTriggerUSec with them.
  if systemd-run --user --unit="$UNIT_A" --on-active=1 \
       --timer-property=RemainAfterElapse=yes \
       --property=Type=oneshot /bin/sleep 600 >/dev/null 2>&1; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      FIRE=$(systemctl --user show "$UNIT_A.timer" -p LastTriggerUSec --value 2>/dev/null)
      case "$FIRE" in ''|n/a) sleep 0.5 ;; *) HAVE_SYSTEMD=1; break ;; esac
    done
  fi
fi

if [ "$FAKE_SYSTEMD" = 1 ]; then SYSTEMD_MODE=double; else SYSTEMD_MODE=real; fi

if [ "$HAVE_SYSTEMD" = 0 ]; then
  echo "SKIP: no usable systemd --user AND the double did not come up — 27 of 29" >&2
  echo "      cases (every writer-dependent one) did NOT run. This is not a pass." >&2
  SKIP=1
  SYSTEMD_MODE=none
else

# The fixture loop has now FIRED and written no ledger row since → in flight.

# 4. clean tree + writer active → ALLOW. The dirty precondition: with nothing
#    on disk to lose, these verbs destroy nothing and `git stash` is a no-op.
clean
run_case "allow: clean tree even with a writer in flight" 0 'git stash'

# --- THE POSITIVE CONTROL --------------------------------------------------
dirty
# 5. dirty tree + writer in flight + bare `git stash` → BLOCK
run_case "BLOCK: git stash while a tick is in flight" 2 'git stash' \
  "another writer is"
# 6. ...and it names the writer, so the message is actionable.
run_case "BLOCK: the block names the in-flight loop" 2 'git stash' "$UNIT_A"

# 7. the scoped form is the documented escape → ALLOW
run_case "allow: git stash push -- <paths>" 0 'git stash push -- one.txt'
# 8. ...but a message is not a pathspec.
run_case "BLOCK: git stash push -m 'wip' (no pathspec)" 2 "git stash push -m 'wip'" \
  "another writer is"

# 9/10. reset --hard blocks; a soft/pathspec reset does not.
run_case "BLOCK: git reset --hard" 2 'git reset --hard' "another writer is"
run_case "allow: git reset one.txt (index only)" 0 'git reset one.txt'

# 11/12. whole-tree checkout blocks; a named path does not.
run_case "BLOCK: git checkout ." 2 'git checkout .' "another writer is"
run_case "allow: git checkout -- one.txt" 0 'git checkout -- one.txt'
run_case "BLOCK: git checkout -- ." 2 'git checkout -- .' "another writer is"

# 13/14. same for restore; --staged only rewrites the index.
run_case "BLOCK: git restore ." 2 'git restore .' "another writer is"
run_case "allow: git restore --staged ." 0 'git restore --staged .'

# 15/16. clean -fd blocks unscoped; scoped to a path it does not. And a dry
#        run is never a block (the `-*f*` short-bundle match must not catch
#        long options that merely contain an f, e.g. --exclude=foo).
run_case "BLOCK: git clean -fd" 2 'git clean -fd' "another writer is"
run_case "allow: git clean -fd -- sub" 0 'git clean -fd -- sub'
run_case "allow: git clean -n --exclude=foo" 0 'git clean -n --exclude=foo'

# 17. the non-capturing stash verbs touch the stash, not the tree.
run_case "allow: git stash list" 0 'git stash list'
run_case "allow: git stash pop" 0 'git stash pop'

# 18. `cd <repo> && git stash` from an unrelated cwd → BLOCK. The repo at risk
#     is the one the command WALKS INTO.
run_case_cwd "BLOCK: cd \$REPO && git stash from elsewhere" 2 \
  "cd $REPO && git stash" "$TMP" "another writer is"

# 19. `git -C <repo> stash` from an unrelated cwd → BLOCK.
run_case_cwd "BLOCK: git -C \$REPO stash from elsewhere" 2 \
  "git -C $REPO stash" "$TMP" "another writer is"

# 20. an unrelated repo is untouched by this repo's writer — the gate is
#     repo-scoped, not host-scoped.
run_case_cwd "allow: git stash in a DIFFERENT, equally dirty repo" 0 \
  "git stash" "$REPO2"

# 20b. no manifest → ALLOW even with a real writer running. The gate fails
#      OPEN when it cannot establish one; a machine with no harness installed
#      must not lose `git stash`.
run_case "allow: fails open with no manifest" 0 'git stash' "" \
  HARNESS_MANIFEST="$TMP/nope.json"

# --- autostash: `git pull --rebase` is a stash with no error at all --------
# 21. plain pull --rebase is NOT blocked (it fails obstructively, not
#     destructively — and an untracked-only dirty tree does not stop it).
run_case "allow: git pull --rebase with autostash unset" 0 'git pull --rebase'
# 22. ...but the explicit flag is exactly the destructive path.
run_case "BLOCK: git pull --rebase --autostash" 2 'git pull --rebase --autostash' \
  "another writer is"
# 23. and so is the CONFIG, which is the landmine worth guarding: had
#     rebase.autoStash been true on 2026-08-01, `git pull --rebase` would have
#     stashed the tick's work automatically, with no prompt and no error.
git -C "$REPO" config rebase.autoStash true
run_case "BLOCK: git pull --rebase with rebase.autoStash=true" 2 'git pull --rebase' \
  "rebase.autoStash"
run_case "allow: --no-autostash overrides the config" 0 'git pull --rebase --no-autostash'
git -C "$REPO" config --unset rebase.autoStash
# 23b. the merge path stashes just as hard when asked to.
run_case "BLOCK: git pull --autostash (merge path)" 2 'git pull --autostash' \
  "another writer is"
run_case "allow: a plain git pull (merge, no autostash)" 0 'git pull'

# --- THE NEGATIVE CONTROLS: the writer stops looking active ----------------

# 24. the tick REPORTS (its ledger row lands after the fire) → ALLOW.
#     ⚠️ This is the case that HID the hook's `date -d` bug for as long as it
#     existed. It is the only one whose verdict depends on parsing systemd's
#     LastTriggerUSec, and it lived behind a systemd gate that skips wholesale
#     on macOS — so the suite reported a green 2/2 while never once evaluating
#     the comparison. It now runs on both flavours (see FAKE_SYSTEMD above),
#     and its own `date -d` is gone.
FIRE_EPOCH=$(_p_epoch "$FIRE") || { echo "FATAL: cannot parse LastTriggerUSec '$FIRE'" >&2; exit 1; }
printf '{"ts":"%s","row":"t","outcome":"done"}\n' \
  "$(_p_iso_utc "$((FIRE_EPOCH + 60))")" >> "$REPO/refs/test-ledger.jsonl"
run_case "allow: the tick already logged its ledger row" 0 'git stash'

# 25. a row for a DIFFERENT row name does not count as this loop reporting.
git -C "$REPO" checkout -q -- refs/test-ledger.jsonl
printf '{"ts":"%s","row":"other","outcome":"done"}\n' \
  "$(_p_iso_utc "$((FIRE_EPOCH + 60))")" >> "$REPO/refs/test-ledger.jsonl"
run_case "BLOCK: another loop's row is not this loop's receipt" 2 'git stash' \
  "another writer is"
git -C "$REPO" checkout -q -- refs/test-ledger.jsonl

# 26. a BOUNCE at/after the fire means the tick never started → ALLOW.
printf '{"ts":"%s","loop":"%s","reason":"not_ready"}\n' \
  "$(_p_iso_utc "$((FIRE_EPOCH + 1))")" "$UNIT_A" >> "$BOUNCES"
run_case "allow: a bounced fire is not a writer" 0 'git stash'
: > "$BOUNCES"

# 27. a fire older than grace + margin is STALLED, not running → ALLOW.
#     grace=0 with a margin of -1 makes a 0-minute-old fire exceed the bound
#     without waiting 90 real minutes; the comparison under test is the live
#     one, only its constants are shrunk.
write_manifest "$UNIT_A" 0
run_case "allow: a fire past grace+margin is stalled, not in flight" 0 'git stash' "" \
  HARNESS_STALL_MARGIN_MINUTES=-1
write_manifest "$UNIT_A" 90

# 28. the guard is repo-scoped: a loop declared for ANOTHER project does not
#     make this repo unsafe. (The fixture's second project pins a nonexistent
#     path; the first is what matches.)
run_case "BLOCK: still blocks with an unrelated second project declared" 2 'git stash' \
  "another writer is"

# --- detector B: a oneshot job running out of this repo ---------------------
# Detector A is the observed case (a tmux-injected tick). Detector B covers
# the other real writer shape: an LLM-free job like zettel-refresh.service,
# which IS visible to systemd for its whole run.
write_manifest "no-such-timer" 90     # detector A now finds nothing
run_case "allow: no in-flight tick and no running job" 0 'git stash'
# --no-block is REQUIRED, not cosmetic: without it `systemd-run` waits for the
# START JOB to complete, and a Type=oneshot start job is not complete until
# ExecStart exits — so it blocks for the full 600s of the probe it just
# started. (Hung the suite the first time it ran.)
if systemd-run --user --no-block --unit="$UNIT_B" --property=Type=oneshot \
     "$REPO/slow.sh" >/dev/null 2>&1; then
  for _ in 1 2 3 4 5 6; do
    STATE=$(systemctl --user show "$UNIT_B.service" -p ActiveState --value 2>/dev/null)
    [ "$STATE" = "activating" ] && break
    sleep 0.5
  done
  if [ "$STATE" = "activating" ]; then
    run_case "BLOCK: a oneshot job running out of this repo" 2 'git stash' \
      "$UNIT_B"
  else
    echo "SKIP: $UNIT_B never reached 'activating' (state=$STATE)" >&2
    SKIP=$((SKIP + 1))
  fi
  systemctl --user stop "$UNIT_B.service" >/dev/null 2>&1
else
  echo "SKIP: could not start the detector-B probe unit" >&2
  SKIP=$((SKIP + 1))
fi

# 29b. the OTHER shape of the same detector: a unit whose WorkingDirectory IS
#      the repo root, running a binary from outside it. This is the commonest
#      real shape, and it was MISSED by the first implementation — matching
#      only `*"$repo/"*` never matches `/home/ubuntu/dotfiles` with no
#      trailing slash. A live positive control against the real manifest
#      caught it returning a clean exit 0 with a real writer running; the
#      fixture above passed anyway because its probe ran a script INSIDE the
#      repo. Both shapes are asserted from here on.
if systemd-run --user --no-block --unit="$UNIT_C" --property=Type=oneshot \
     --property=WorkingDirectory="$REPO" /bin/sleep 600 >/dev/null 2>&1; then
  for _ in 1 2 3 4 5 6; do
    STATE=$(systemctl --user show "$UNIT_C.service" -p ActiveState --value 2>/dev/null)
    [ "$STATE" = "activating" ] && break
    sleep 0.5
  done
  if [ "$STATE" = "activating" ]; then
    run_case "BLOCK: a oneshot job whose WorkingDirectory is this repo" 2 'git stash' \
      "$UNIT_C"
  else
    echo "SKIP: $UNIT_C never reached 'activating' (state=$STATE)" >&2
    SKIP=$((SKIP + 1))
  fi
  systemctl --user stop "$UNIT_C.service" >/dev/null 2>&1
else
  echo "SKIP: could not start the WorkingDirectory probe unit" >&2
  SKIP=$((SKIP + 1))
fi
write_manifest "$UNIT_A" 90

fi   # HAVE_SYSTEMD

clean

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$PASS shared-tree-guard cases (skipped: $SKIP, systemd: $SYSTEMD_MODE)"
  exit 0
else
  printf 'FAILED:\n'
  for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  echo "FAIL: $FAIL failed, $PASS passed (skipped: $SKIP, systemd: $SYSTEMD_MODE)"
  exit 1
fi
