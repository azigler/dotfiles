#!/bin/bash
# test-fleet-creds.sh — regression suite for fleet-creds.sh.
#
# Guards the defect fixed in bd-su3u: `tmux setenv` populates the SESSION
# environment, which a shell samples once at startup, so a pulse tick delivered
# by send-keys into an ALREADY-RUNNING pane never inherited anything the
# dispatcher brokered. `ensure` must therefore read the brokered session env
# itself, before (and often instead of) the ssh round-trip.
#
# Hermetic: DUMMY values only, a PRIVATE tmux server (-L), and a stub `ssh` first
# on PATH. Never contacts zig-computer, never prints a real credential.
#
# Two traps this suite is built around — both cost a rewrite when it was written:
#   1. The pane shell is ZSH. Probe with `printenv`, never `${!v}` (a bash-ism
#      zsh answers with "bad substitution" — the same trap fleet-creds.sh dodges
#      by running its remote snippet under `bash -lc`).
#   2. An interactive login shell on zig-computer ALREADY exports
#      FLEET_API_TOKEN, and `env -u` cannot strip what the shell re-creates at
#      startup. That ambient value is exactly why that one var appeared to work
#      while the three .env.local-only vars silently did not. The probe masks any
#      non-dummy value, and the assertions key on the dummies.
#
# Usage: bash agents/scheduler/test-fleet-creds.sh     (exit 0 = all pass)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/fleet-creds.sh"
TMPDIR_T=$(mktemp -d "${TMPDIR:-/tmp}/fcsuite.XXXXXX")
SOCK=fcsuite$$
# Env hygiene (dotfiles-2v8h, the 2026-08-09 incident): -L already overrides an
# inherited $TMUX, but every invocation below also strips TMUX/TMUX_TMPDIR so
# nothing here can EVER be read as depending on ambient env for its socket.
TM=(env -u TMUX -u TMUX_TMPDIR tmux -L "$SOCK")
SOCKPATH="/tmp/tmux-$UID/$SOCK"
PASS=0; FAIL=0

# `kill-server` alone is NOT enough to keep /tmp/tmux-1000/ clean — measured
# live (dotfiles-2v8h): a successful kill-server on this box regularly exits
# WITHOUT unlinking its own socket special file, so the dead file lingers and
# accumulates across runs. `rm -f` the socket path explicitly — a plain
# unlink, never touches a live server on a DIFFERENT name, no-op if tmux
# already cleaned up.
cleanup() { "${TM[@]}" kill-server 2>/dev/null; rm -f "$SOCKPATH"; rm -rf "$TMPDIR_T"; }
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
check(){ # check <desc> <haystack> <needle>
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 -- expected to find: $3" ;; esac
}

# stub ssh; $1 = the body it should print (TSV lines), $2 = exit code
stub_ssh() {
  { printf '#!/bin/bash\necho CALLED >> %q\n' "$TMPDIR_T/ssh-calls"
    printf 'cat <<%s\n%s\n%s\n' "'SSHOUT'" "$1" "SSHOUT"
    printf 'exit %s\n' "$2"
  } > "$TMPDIR_T/bin/ssh"
  chmod +x "$TMPDIR_T/bin/ssh"
}

mkdir -p "$TMPDIR_T/bin"

# A session whose pane shell is already running, with $1 = space-separated vars
# to broker. Anything not listed stays genuinely absent from the session env.
fresh() {
  SESS="s$RANDOM"
  "${TM[@]}" new-session -d -s "$SESS" -x 200 -y 50
  until "${TM[@]}" list-panes -t "$SESS" -F '#{pane_pid}' | grep -q '[0-9]'; do :; done
  for v in $1; do "${TM[@]}" setenv -t "$SESS" "$v" "dummy_${v}_value"; done
}

# Run in the ALREADY-RUNNING pane shell (never a new pane — that would defeat
# the entire point of the suite) and return its combined output.
pane_run() {
  local tag=$1 cmd=$2 n=0
  rm -f "$TMPDIR_T/$tag" "$TMPDIR_T/$tag.done"
  "${TM[@]}" send-keys -t "$SESS" \
    "{ $cmd ; } > $TMPDIR_T/$tag 2>&1 ; touch $TMPDIR_T/$tag.done" Enter
  until [ -f "$TMPDIR_T/$tag.done" ] || [ "$n" -gt 300 ]; do n=$((n+1)); command sleep 0.2; done
  cat "$TMPDIR_T/$tag"
}

PROBE='for v in SLACK_BOT_TOKEN SLACK_NEWS_PLANNING_CHANNEL_ID SITE_PASSWORD; do printf "%s=[%s]\n" "$v" "$(printenv $v || echo NOTSET)"; done'
ALL4="FLEET_API_TOKEN SLACK_BOT_TOKEN SLACK_NEWS_PLANNING_CHANNEL_ID SITE_PASSWORD"

echo "== fleet-creds.sh regression suite"
bash -n "$SCRIPT" && ok "bash -n parses" || bad "bash -n"

# --- 1. the defect: brokering is invisible to an already-running shell --------
echo
echo "-- 1. baseline: send-keys shell does NOT inherit the brokered session env"
fresh "$ALL4"
out=$(pane_run baseline "$PROBE")
check "SLACK_BOT_TOKEN empty in the running shell"    "$out" "SLACK_BOT_TOKEN=[NOTSET]"
check "SITE_PASSWORD empty in the running shell"      "$out" "SITE_PASSWORD=[NOTSET]"
check "session env DOES hold it" \
  "$("${TM[@]}" show-environment -t "$SESS" SLACK_BOT_TOKEN)" "SLACK_BOT_TOKEN=dummy_"

# --- 2. the fix: ensure --export populates that same shell, with no ssh -------
echo
echo "-- 2. ensure --export resolves all four from the brokered env, no ssh"
rm -f "$TMPDIR_T/ssh-calls"
stub_ssh "" 255                      # any ssh call at all is a failure here
out=$(pane_run fixed "eval \"\$(PATH=$TMPDIR_T/bin:\$PATH $SCRIPT ensure --export --host unreachable.invalid)\"; echo EXIT=\$?; $PROBE")
check "reports the brokered env as the source" "$out" "loaded from brokered tmux env"
check "SLACK_BOT_TOKEN now in the running shell"  "$out" "SLACK_BOT_TOKEN=[dummy_SLACK_BOT_TOKEN_value]"
check "SITE_PASSWORD now in the running shell"    "$out" "SITE_PASSWORD=[dummy_SITE_PASSWORD_value]"
check "exit 0"                                    "$out" "EXIT=0"
if [ -f "$TMPDIR_T/ssh-calls" ]; then bad "ssh was invoked despite everything resolving locally"
else ok "no ssh round-trip"; fi
"${TM[@]}" kill-session -t "$SESS"

# --- 3. mixed: fetch ONLY what the brokered env could not answer --------------
echo
echo "-- 3. mixed source: one var absent locally is fetched, and only that one"
rm -f "$TMPDIR_T/ssh-calls"
# Wire format is NAME<TAB>VALUE<TAB>ORIGIN (3 fields). The origin field was added
# when ~/.secrets stopped being the only upstream source, so that each var reports
# the exact FILE it came from and not merely the host.
stub_ssh "$(printf 'SLACK_BOT_TOKEN\tupstream_dummy\t/home/ubuntu/.secrets')" 0
fresh "FLEET_API_TOKEN SLACK_NEWS_PLANNING_CHANNEL_ID SITE_PASSWORD"
"${TM[@]}" setenv -u -t "$SESS" SLACK_BOT_TOKEN     # the "-NAME" form: ABSENT, not a value
out=$(pane_run mixed "PATH=$TMPDIR_T/bin:\$PATH $SCRIPT ensure --host fakepeer; echo EXIT=\$?")
check "asks the peer for only the missing var" "$out" "fetching SLACK_BOT_TOKEN from fakepeer"
check "missing var attributed to the peer"     "$out" "SLACK_BOT_TOKEN: loaded from fakepeer"
check "names the FILE the value came from"     "$out" "fakepeer:/home/ubuntu/.secrets"
check "present var attributed to the broker"   "$out" "SITE_PASSWORD: loaded from brokered tmux env"
check "exit 0"                                 "$out" "EXIT=0"
"${TM[@]}" kill-session -t "$SESS"

# --- 4. exit 2: missing everywhere -------------------------------------------
echo
echo "-- 4. empty upstream AND unbrokered -> exit 2, honest message"
# A var that is empty in every upstream file is NOT emitted at all, so the honest
# all-missing answer is an EMPTY response. (It used to be emitted as "NAME<TAB>" —
# that form is now a hard error, see test 6b: tab is IFS whitespace, so the empty
# field collapsed and the ORIGIN was read as the credential.)
stub_ssh "" 0
fresh "FLEET_API_TOKEN SLACK_NEWS_PLANNING_CHANNEL_ID SITE_PASSWORD"
out=$(pane_run miss "PATH=$TMPDIR_T/bin:\$PATH $SCRIPT ensure --host fakepeer; echo EXIT=\$?")
check "names every place it looked" "$out" "not set in any source on fakepeer"
check "an empty answer is not a false failure" "$out" "MISSING"
check "exit 2"                      "$out" "EXIT=2"
"${TM[@]}" kill-session -t "$SESS"

# --- 5. exit 1: peer unreachable, but partial results still emitted -----------
echo
echo "-- 5. peer unreachable -> exit 1, resolvable vars still exported"
stub_ssh "ssh: could not resolve hostname" 255
fresh "FLEET_API_TOKEN SLACK_NEWS_PLANNING_CHANNEL_ID SITE_PASSWORD"
# NOTE: the pipe here is for masking only, never for a status check — the pane
# shell is zsh, where $PIPESTATUS does not exist and silently expands to empty.
# The exit code is asserted separately below, pipe-free.
out=$(pane_run unreach "PATH=$TMPDIR_T/bin:\$PATH $SCRIPT ensure --export --host fakepeer 2>&1 | sed 's/=.*/=<masked>/'")
check "distinguishes unreachable from missing-upstream" "$out" "UNRESOLVED"
check "still exports what it could resolve"             "$out" "export SITE_PASSWORD=<masked>"
out2=$(pane_run unreach2 "PATH=$TMPDIR_T/bin:\$PATH $SCRIPT ensure --host fakepeer >/dev/null 2>&1; echo EXIT=\$?")
check "exit 1" "$out2" "EXIT=1"
"${TM[@]}" kill-session -t "$SESS"

# --- 6. refuses to report success over an unparseable answer -----------------
echo
echo "-- 6. garbage from the peer -> exit 2, no false success"
stub_ssh "zsh: bad substitution" 0
fresh "FLEET_API_TOKEN SLACK_NEWS_PLANNING_CHANNEL_ID SITE_PASSWORD"
out=$(pane_run garbage "PATH=$TMPDIR_T/bin:\$PATH $SCRIPT ensure --host fakepeer; echo EXIT=\$?")
# The guard is a line-SHAPE check, not a sentinel grep. A sentinel keyed off the
# requested var could not tell "the peer errored" from "that var is legitimately
# unset everywhere" once empty vars stopped being emitted -- and it let remote error
# text through whenever the sentinel line happened to appear.
check "shape guard rejects the answer"   "$out" "not NAME<TAB>VALUE<TAB>ORIGIN"
check "shows the offending line"         "$out" "zsh: bad substitution"
check "exit 2"                           "$out" "EXIT=2"
"${TM[@]}" kill-session -t "$SESS"

# --- 6b. THE FIELD-SHIFT TRAP: an empty value must never become the credential ---
# Regression guard for a real bug (2026-08-05). TAB is an IFS *whitespace*
# character, so bash `read` COLLAPSES a run of them: the line
# "NAME<TAB><TAB>/home/ubuntu/.secrets" parsed as value=/home/ubuntu/.secrets,
# origin="". The script then reported the FILE PATH as a loaded credential --
# "loaded (len=21)" for three vars, because that path is 21 characters -- and
# exited 0. A caller would have authenticated with a filesystem path.
# The emitter must skip empty vars; the shape guard is the backstop if it ever
# stops doing so. Either way this answer must NOT produce a success.
echo
echo "-- 6b. empty value + populated origin -> never reported as loaded"
stub_ssh "$(printf 'SLACK_BOT_TOKEN\t\t/home/ubuntu/.secrets')" 0
fresh "FLEET_API_TOKEN SLACK_NEWS_PLANNING_CHANNEL_ID SITE_PASSWORD"
out=$(pane_run shift "PATH=$TMPDIR_T/bin:\$PATH $SCRIPT ensure --host fakepeer; echo EXIT=\$?")
if printf '%s' "$out" | grep -q 'SLACK_BOT_TOKEN: loaded'; then
  bad "the file path was accepted as a credential (field-shift bug is back)"
else ok "empty value never reported as loaded"; fi
check "does not exit 0" "$out" "EXIT=2"
"${TM[@]}" kill-session -t "$SESS"

# --- 7. no value ever reaches stdout/stderr outside --export ------------------
echo
echo "-- 7. values are never echoed without --export"
fresh "$ALL4"
out=$(pane_run quiet "PATH=$TMPDIR_T/bin:\$PATH $SCRIPT ensure --host unreachable.invalid; $SCRIPT status")
case "$out" in
  *dummy_SITE_PASSWORD_value*) bad "a value leaked into non---export output" ;;
  *) ok "no value in ensure/status output" ;;
esac
check "status reports presence + length only" "$out" "SITE_PASSWORD: PRESENT (len="
"${TM[@]}" kill-session -t "$SESS"

echo
echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
