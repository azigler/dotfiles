#!/bin/bash
# Test for ensure-fleet-tunnel.sh — the self-heal half of the dispatch tunnel,
# generalized to --target / --probe-path / --expect (dotfiles-47nf).
#
# Hermetic: XDG_CACHE_HOME in a per-run tmpdir + FAKE `curl` and `ssh` shims on
# PATH. No real network, no real ssh, no real port bound. `pgrep` and `kill` are
# REAL on purpose — the ownership logic under test IS a pgrep pattern, and a
# faked pgrep would test the fake instead of the pattern.
#
# THE PROCESS-TABLE FIXTURE. The fake `ssh` backgrounds $FAKE/hold/ssh with the
# caller's exact argv. Because that stand-in is a `#!/bin/bash` script literally
# named `ssh`, the kernel gives it the cmdline
#
#     /bin/bash /tmp/…/hold/ssh -f -N -o … -L 127.0.0.1:P:HOST:P PEER
#
# which is the shape FORWARD_PAT is written against (`ssh .*-L …  PEER$`) —
# including the end anchor. Measured: pgrep -n -f finds it, an otherwise
# identical pattern with a DIFFERENT target does not, and SIGTERM clears it in
# ~11ms.
#
# THE CASES THAT MATTER MOST are the "two concurrent tunnels" ones. A
# target-blind FORWARD_PAT, an unescaped one, or a shared pidfile makes the fleet
# tunnel and the gateway tunnel each other's property, and `down` then kills a
# forward it does not own — on a shared box, mid-dispatch.
#
# MEASURED mutant -> failing cases (2026-08-03; re-measure if you change a case,
# and do not write this map from memory — the first version of it named the wrong
# cases in both entries):
#
#   M1  FORWARD_PAT="ssh .*-L .* $PEER\$"            -> 23 24 25 26 27 28
#   M2  the pre-generalization hardwired pattern
#       `…:$PORT:127\.0\.0\.1:$PORT $PEER\$`         -> 23 24 25 26 27 28
#   M3  one shared local-forward.pid for every tunnel-> 10 23 24 25 26 27 28
#   M4  re_escape neutered to an identity function   -> 28  (ONLY 28)
#   M5  tunnel_down's kill target made blind         -> 24 25 27 28, and 23
#       (ownership broken with both pids CORRECT)       must keep PASSING
#
# THAT MAP IS NOW EXECUTABLE, not a comment: mutate-tunnel-ownership.sh applies
# all five and asserts each dies on exactly the cases named here. Run it — and
# do not hand-edit this map without re-measuring, since the harness will block
# the commit if the two disagree.
#
# M4 is why case 28 exists, and case 28 is its SOLE detector. It survived the
# first version of this suite 26/26: nothing there depended on `.` being escaped,
# because 127.0.0.1 and 100.72.47.4 differ in length. Case 28 uses two
# SAME-LENGTH targets so an unescaped `.` genuinely matches the other tunnel's
# process.
#
# The `[ -n "$A_PID" ]` guards on 24-28 are load-bearing too: without them a
# mutant that loses ownership leaves the pid variable EMPTY, `alive ""` reads as
# "dead", and the case passes vacuously. M2 passed case 26 that way once. M5 is
# the converse proof — it breaks ownership while leaving BOTH pids correct and
# non-empty, so 24/25/27/28 are shown to detect ownership rather than emptiness.
#
# Convention matches the other agents/scheduler suites: executable bash,
# non-zero exit = failure, PASS/FAIL summary on the last line.

set -uo pipefail

EFT="$(cd "$(dirname "$0")" && pwd)/ensure-fleet-tunnel.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf '  FAIL %s\n     -> %s\n' "$1" "${2:-}"; }

# A peer name that exists nowhere on any real box, so the real pgrep in the
# script can never match a live fleet tunnel while these tests run.
PEER=eft-test-peer

ROOT=$(mktemp -d)
BIN="$ROOT/bin"
FAKE="$ROOT/fake"
mkdir -p "$BIN" "$FAKE/hold"

# shellcheck disable=SC2317  # invoked via trap, not by a visible caller
cleanup() {
  # Kill every stand-in this run started. Matched on THIS run's tmpdir, so it
  # can never reach a real tunnel or another run's fixtures.
  pkill -f "$FAKE/hold/ssh" || true
  rm -rf "$ROOT"
}
trap cleanup EXIT

# --- the process-table stand-in for a backgrounded `ssh -f -N -L …` ----------
# Exists only to hold a /proc entry with the right cmdline. `sleep 1 & wait`
# rather than `sleep 900` so the TERM trap runs immediately (bash defers traps
# while a FOREGROUND child runs, but `wait` returns on signal).
cat > "$FAKE/hold/ssh" <<'EOH'
#!/bin/bash
trap 'exit 0' TERM
while :; do sleep 1 & wait $!; done
EOH
chmod +x "$FAKE/hold/ssh"

# --- fake ssh ---------------------------------------------------------------
cat > "$BIN/ssh" <<'EOS'
#!/bin/bash
# Fake ssh: records the invocation, then either fails like ExitOnForwardFailure
# does, or forks a stand-in with the SAME argv and returns 0 like `ssh -f`.
printf '%s\n' "$*" >> "$EFT_FAKE/ssh-calls"
if [ -f "$EFT_FAKE/ssh-fail" ]; then
  printf 'fake ssh: bind failed, ExitOnForwardFailure refused the connection\n' >&2
  exit 255
fi
# stdio MUST be detached. Real `ssh -f` closes its handles; a stand-in that
# inherits them holds the caller's `$( … )` pipe open forever, and the whole
# suite hangs instead of failing. (Observed on the first run of this file.)
"$EFT_FAKE/hold/ssh" "$@" < /dev/null > /dev/null 2>&1 &   # allow-suppress: detaching stdio, not hiding errors
pid=$!
# Do not return until the kernel shows the full cmdline: the caller pgreps for
# it on the very next line, and a race here would look like a pattern bug.
for _ in $(seq 1 200); do
  if [ -r "/proc/$pid/cmdline" ] && tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q -- '-L '; then
    break
  fi
  sleep 0.01
done
exit 0
EOS
chmod +x "$BIN/ssh"

# --- fake curl --------------------------------------------------------------
# Per-URL scripted responses. Two special values reproduce real curl behavior
# that the three-valued probe exists to survive:
#   REFUSED -> prints "000" AND exits non-zero (ECONNREFUSED)
#   EMPTY   -> prints nothing at all and exits non-zero
cat > "$BIN/curl" <<'EOC'
#!/bin/bash
url=""
for a in "$@"; do case "$a" in http://*|https://*) url=$a ;; esac; done
printf '%s\n' "$url" >> "$EFT_FAKE/curl-urls"
printf '%s\n' "$*" >> "$EFT_FAKE/curl-args"
key=$(printf '%s' "$url" | tr -c 'A-Za-z0-9' '_')
v=""
if [ -s "$EFT_FAKE/seq_$key" ]; then
  v=$(head -n 1 "$EFT_FAKE/seq_$key")
  tail -n +2 "$EFT_FAKE/seq_$key" > "$EFT_FAKE/seq_$key.tmp"
  mv "$EFT_FAKE/seq_$key.tmp" "$EFT_FAKE/seq_$key"
fi
if [ -z "$v" ] && [ -f "$EFT_FAKE/url_$key" ]; then v=$(cat "$EFT_FAKE/url_$key"); fi
if [ -z "$v" ] && [ -f "$EFT_FAKE/default" ]; then v=$(cat "$EFT_FAKE/default"); fi
[ -n "$v" ] || v=000
case "$v" in
  REFUSED) printf '000'; exit 7 ;;
  EMPTY)   exit 7 ;;
  *)       printf '%s' "$v" ;;
esac
EOC
chmod +x "$BIN/curl"

export PATH="$BIN:$PATH"
export EFT_FAKE="$FAKE"

# --- per-case control helpers ------------------------------------------------
urlkey() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
curl_code() { printf '%s\n' "$2" > "$FAKE/url_$(urlkey "$1")"; }        # url code
curl_seq()  { local u=$1; shift; printf '%s\n' "$@" > "$FAKE/seq_$(urlkey "$u")"; }
curl_default() { printf '%s\n' "$1" > "$FAKE/default"; }

reset_case() {
  pkill -f "$FAKE/hold/ssh" || true
  rm -f "$FAKE"/url_* "$FAKE"/seq_* "$FAKE"/default "$FAKE"/ssh-calls \
        "$FAKE"/curl-urls "$FAKE"/curl-args "$FAKE"/ssh-fail
  rm -rf "$ROOT/cache"
  export XDG_CACHE_HOME="$ROOT/cache"
  : > "$FAKE/ssh-calls"
  : > "$FAKE/curl-urls"
  : > "$FAKE/curl-args"
}

OUT=""
RC=0
# `timeout` so a future hang FAILS the suite (rc 124) instead of wedging the
# pre-commit gate. Worst legitimate case is ~7s (one recycle + five re-probes).
run() { OUT=$(timeout 60 bash "$EFT" "$@" 2>&1); RC=$?; }

alive() { kill -0 "$1" 2>/dev/null; }   # allow-suppress: liveness probe only

pidfile_of() { # <port> <target>
  local slug
  slug=$(printf '%s' "$1-$2" | tr -c 'A-Za-z0-9._-' '_')
  printf '%s' "$XDG_CACHE_HOME/fleet-tunnel/local-forward-$slug.pid"
}
read_pidfile() { # <port> <target> — empty if absent, never an error
  local f
  f=$(pidfile_of "$1" "$2")
  [ -f "$f" ] && cat "$f"
}

echo "== defaults: the fleet-proxy behavior must be unchanged =="

reset_case
curl_default 200
run status
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'up (200)'; then
  ok "1  default status with 200 -> exit 0, 'up (200)'"
else bad "1  default status with 200 -> exit 0" "rc=$RC out=$OUT"; fi

if grep -qx 'http://127.0.0.1:7100/api/health' "$FAKE/curl-urls"; then
  ok "2  default probe URL is http://127.0.0.1:7100/api/health"
else bad "2  default probe URL" "got: $(cat "$FAKE/curl-urls")"; fi

reset_case
curl_default REFUSED
run status
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'DOWN (000'; then
  ok "3  curl prints 000 AND exits nonzero -> DOWN, not BLOCKED (the '|| echo 000' trap)"
else bad "3  refused connection -> DOWN(1)" "rc=$RC out=$OUT"; fi

reset_case
curl_default EMPTY
run status
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'DOWN (000'; then
  ok "4  curl prints NOTHING -> substituted to 000 -> DOWN(1)"
else bad "4  empty curl output -> DOWN(1)" "rc=$RC out=$OUT"; fi

reset_case
curl_default 503
run status
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'BLOCKED (503'; then
  ok "5  default status with 503 -> exit 2 BLOCKED"
else bad "5  default status with 503 -> exit 2" "rc=$RC out=$OUT"; fi

reset_case
curl_default 200
run ensure
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'already up (200)' && [ ! -s "$FAKE/ssh-calls" ]; then
  ok "6  ensure is idempotent: a healthy port is never churned"
else bad "6  ensure idempotent on healthy port" "rc=$RC out=$OUT ssh=$(cat "$FAKE/ssh-calls")"; fi

reset_case
curl_seq http://127.0.0.1:7100/api/health REFUSED 200
run ensure --host "$PEER"
if grep -q -- '-L 127.0.0.1:7100:127.0.0.1:7100' "$FAKE/ssh-calls"; then
  ok "7  default -L spec is 127.0.0.1:7100:127.0.0.1:7100 (target defaults to the same port on the far loopback)"
else bad "7  default -L spec" "ssh=$(cat "$FAKE/ssh-calls")"; fi

if grep -q 'ExitOnForwardFailure=yes' "$FAKE/ssh-calls"; then
  ok "8  ExitOnForwardFailure=yes is still passed (without it ssh exits 0 on a failed bind)"
else bad "8  ExitOnForwardFailure=yes" "ssh=$(cat "$FAKE/ssh-calls")"; fi

if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'HEALED'; then
  ok "9  ensure heals: 000 -> open forward -> re-probe 200 -> exit 0"
else bad "9  ensure heals to exit 0" "rc=$RC out=$OUT"; fi

DEFPID=$(read_pidfile 7100 127.0.0.1:7100)
if [ -n "$DEFPID" ] && alive "$DEFPID"; then
  ok "10 pidfile records the forward we started"
else bad "10 pidfile records the forward" "pid=[${DEFPID:-}]"; fi

# The historical cmdline shape must still be adopted by the DEFAULT pattern:
# this is the "byte-identical default" claim, tested rather than asserted.
run down --host "$PEER"
if [ "$RC" -eq 0 ] && ! alive "$DEFPID"; then
  ok "11 down closes the forward we started"
else bad "11 down closes our forward" "rc=$RC out=$OUT"; fi

reset_case
curl_default REFUSED
"$FAKE/hold/ssh" -f -N -o ExitOnForwardFailure=yes -L 127.0.0.1:7100:127.0.0.1:7100 "$PEER" < /dev/null > /dev/null 2>&1 &
ORPHAN=$!
sleep 0.3
run down --host "$PEER"
if [ "$RC" -eq 0 ] && ! alive "$ORPHAN"; then
  ok "12 pgrep re-adoption: an orphaned forward (no pidfile) is still recognised as ours"
else bad "12 pgrep re-adoption of an orphan" "rc=$RC out=$OUT alive=$(alive "$ORPHAN" && echo yes || echo no)"; fi

echo "== never kill a listener we did not start =="

reset_case
curl_default REFUSED
# A REVERSE forward (-R) from the other side, and a local forward to a DIFFERENT
# peer. Neither is ours; `down` must leave both alone.
"$FAKE/hold/ssh" -f -N -R 127.0.0.1:7100:127.0.0.1:7100 "$PEER" < /dev/null > /dev/null 2>&1 &
REV=$!
"$FAKE/hold/ssh" -f -N -L 127.0.0.1:7100:127.0.0.1:7100 somebody-elses-peer < /dev/null > /dev/null 2>&1 &
OTHERPEER=$!
sleep 0.3
run down --host "$PEER"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'no local forward of ours' \
   && alive "$REV" && alive "$OTHERPEER"; then
  ok "13 down spares a reverse (-R) forward and another peer's -L"
else bad "13 down spares foreign listeners" "rc=$RC out=$OUT rev=$(alive "$REV" && echo up || echo DEAD) other=$(alive "$OTHERPEER" && echo up || echo DEAD)"; fi

echo "== --expect: 401 is health for the gateway, 200 is not =="

reset_case
curl_code http://127.0.0.1:17017/claude/v1/models 401
run status --port 17017 --target 100.72.47.4:17017 --probe-path /claude/v1/models --expect 401
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'up (401)'; then
  ok "14 --expect 401 treats 401 as UP (transparent passthrough, no key attached)"
else bad "14 --expect 401 treats 401 as up" "rc=$RC out=$OUT"; fi

reset_case
curl_code http://127.0.0.1:17017/claude/v1/models 200
run status --port 17017 --target 100.72.47.4:17017 --probe-path /claude/v1/models --expect 401
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'BLOCKED (200'; then
  ok "15 --expect 401 treats 200 as BLOCKED(2), not healthy"
else bad "15 --expect 401 treats 200 as BLOCKED" "rc=$RC out=$OUT"; fi

reset_case
curl_code http://127.0.0.1:17017/claude/v1/models REFUSED
run status --port 17017 --target 100.72.47.4:17017 --probe-path /claude/v1/models --expect 401
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'DOWN (000'; then
  ok "16 --expect 401 keeps 000 meaning 'nothing listening', not 'blocked'"
else bad "16 --expect 401 keeps 000 = DOWN" "rc=$RC out=$OUT"; fi

reset_case
curl_seq http://127.0.0.1:17017/claude/v1/models REFUSED 401
run ensure --port 17017 --target 100.72.47.4:17017 --probe-path /claude/v1/models --expect 401 --host "$PEER"
if grep -q -- '-L 127.0.0.1:17017:100.72.47.4:17017' "$FAKE/ssh-calls"; then
  ok "17 --target lands in the -L spec (peer resolves 100.72.47.4 on the FAR end)"
else bad "17 --target in the -L spec" "ssh=$(cat "$FAKE/ssh-calls")"; fi
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'HEALED'; then
  ok "18 gateway invocation heals on 401"
else bad "18 gateway heals on 401" "rc=$RC out=$OUT"; fi

echo "== argument validation is loud, never silent =="

reset_case
run status --expect 000
if [ "$RC" -eq 64 ] && printf '%s' "$OUT" | grep -q 'expect 000 is meaningless'; then
  ok "19 --expect 000 is rejected (it would collapse the three-valued contract)"
else bad "19 --expect 000 rejected" "rc=$RC out=$OUT"; fi

reset_case
run status --target nohostport
RC1=$RC; OUT1=$OUT
run status --target 'host:12a'
RC2=$RC
run status --probe-path api/health
RC3=$RC
run status --expect 4010
RC4=$RC
run status --port abc
RC5=$RC
if [ "$RC1" -eq 64 ] && [ "$RC2" -eq 64 ] && [ "$RC3" -eq 64 ] && [ "$RC4" -eq 64 ] && [ "$RC5" -eq 64 ] \
   && printf '%s' "$OUT1" | grep -q 'must be HOST:PORT'; then
  ok "20 malformed --target / --probe-path / --expect / --port all exit 64 with a reason"
else bad "20 malformed args exit 64" "rcs=$RC1,$RC2,$RC3,$RC4,$RC5 out1=$OUT1"; fi

# An EXPLICIT empty value must be as loud as a malformed one. The next bead
# writes systemd units passing these flags; a unit with an unset variable would
# otherwise get fleet-proxy semantics on a gateway tunnel — failing safe, but
# silently, which is the wrong shape.
reset_case
run status --expect ''
RC1=$RC; OUT1=$OUT
run status --target ''
RC2=$RC
run status --probe-path ''
RC3=$RC
run status --port ''
RC4=$RC
if [ "$RC1" -eq 64 ] && [ "$RC2" -eq 64 ] && [ "$RC3" -eq 64 ] && [ "$RC4" -eq 64 ] \
   && printf '%s' "$OUT1" | grep -q 'EMPTY value'; then
  ok "21 an EXPLICIT empty --expect/--target/--probe-path/--port exits 64, never a silent default"
else bad "21 empty flag values exit 64" "rcs=$RC1,$RC2,$RC3,$RC4 out1=$OUT1"; fi

reset_case
curl_default REFUSED
: > "$FAKE/ssh-fail"
run ensure --host "$PEER"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'FAILED to open the local forward'; then
  ok "22 a refused forward fails LOUDLY with exit 1, never a silent 0"
else bad "22 refused forward -> loud exit 1" "rc=$RC out=$OUT"; fi

echo "== TWO CONCURRENT TUNNELS: neither may adopt the other's pid =="
# This is the section the bead was filed for. Ports 39100/39017 are synthetic so
# no real listener can interfere; the peer is synthetic for the same reason.

A_URL=http://127.0.0.1:39100/api/health
B_URL=http://127.0.0.1:39017/claude/v1/models

start_pair() {
  reset_case
  curl_seq "$A_URL" REFUSED 200
  curl_seq "$B_URL" REFUSED 401
  run ensure --port 39100 --target 127.0.0.1:39100 --host "$PEER"
  A_RC=$RC; A_OUT=$OUT
  run ensure --port 39017 --target 100.72.47.4:39017 --probe-path /claude/v1/models --expect 401 --host "$PEER"
  B_RC=$RC; B_OUT=$OUT
  A_PID=$(read_pidfile 39100 127.0.0.1:39100)
  B_PID=$(read_pidfile 39017 100.72.47.4:39017)
}

start_pair
if [ "$A_RC" -eq 0 ] && [ "$B_RC" -eq 0 ] && [ -n "$A_PID" ] && [ -n "$B_PID" ] \
   && [ "$A_PID" != "$B_PID" ] && alive "$A_PID" && alive "$B_PID"; then
  ok "23 two tunnels come up with DISTINCT pids in DISTINCT pidfiles"
else bad "23 two tunnels, distinct pids" "a_rc=$A_RC b_rc=$B_RC a=[${A_PID:-}] b=[${B_PID:-}] a_out=$A_OUT b_out=$B_OUT"; fi

# --- pidfile path: down A must not touch B ---
run down --port 39100 --target 127.0.0.1:39100 --host "$PEER"
if [ -n "$A_PID" ] && [ -n "$B_PID" ] && [ "$RC" -eq 0 ] && ! alive "$A_PID" && alive "$B_PID"; then
  ok "24 down A kills A and LEAVES B ALIVE (pidfile path)"
else bad "24 down A leaves B alive (pidfile)" "rc=$RC a=[${A_PID:-}] b=[${B_PID:-}] A=$(alive "$A_PID" && echo up || echo dead) B=$(alive "$B_PID" && echo up || echo DEAD)"; fi

# --- discovery path: same, with both pidfiles deleted so ONLY the pgrep
#     pattern decides ownership. A target-blind FORWARD_PAT kills B here.
start_pair
rm -f "$(pidfile_of 39100 127.0.0.1:39100)" "$(pidfile_of 39017 100.72.47.4:39017)"
run down --port 39100 --target 127.0.0.1:39100 --host "$PEER"
if [ -n "$A_PID" ] && [ -n "$B_PID" ] && [ "$RC" -eq 0 ] && ! alive "$A_PID" && alive "$B_PID"; then
  ok "25 down A via pgrep DISCOVERY kills A and leaves B alive (target-blind FORWARD_PAT dies here)"
else bad "25 down A leaves B alive (discovery)" "rc=$RC out=$OUT a=[${A_PID:-}] b=[${B_PID:-}] A=$(alive "$A_PID" && echo UP || echo dead) B=$(alive "$B_PID" && echo up || echo DEAD)"; fi

# --- and the converse: B must still be able to find ITSELF by discovery. A
#     pattern hardwired to 127.0.0.1:$PORT (the pre-generalization literal)
#     matches nothing for B, so B would leak instead of closing.
start_pair
rm -f "$(pidfile_of 39100 127.0.0.1:39100)" "$(pidfile_of 39017 100.72.47.4:39017)"
run down --port 39017 --target 100.72.47.4:39017 --host "$PEER"
if [ -n "$A_PID" ] && [ -n "$B_PID" ] && [ "$RC" -eq 0 ] && ! alive "$B_PID" && alive "$A_PID"; then
  ok "26 down B via pgrep DISCOVERY kills B and leaves A alive (a 127.0.0.1-hardwired pattern dies here)"
else bad "26 down B leaves A alive (discovery)" "rc=$RC out=$OUT a=[${A_PID:-}] b=[${B_PID:-}] A=$(alive "$A_PID" && echo up || echo DEAD) B=$(alive "$B_PID" && echo UP || echo dead)"; fi

# --- the recycle path is the same ownership question with a kill in it ---
start_pair
curl_seq "$A_URL" REFUSED 200
run ensure --port 39100 --target 127.0.0.1:39100 --host "$PEER"
if [ -n "$A_PID" ] && [ -n "$B_PID" ] && [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'recycling it' \
   && ! alive "$A_PID" && alive "$B_PID"; then
  ok "27 the recycle path (our forward is up but the port is silent) recycles A, never B"
else bad "27 recycle path spares the other tunnel" "rc=$RC out=$OUT a=[${A_PID:-}] b=[${B_PID:-}] A=$(alive "$A_PID" && echo UP || echo dead) B=$(alive "$B_PID" && echo up || echo DEAD)"; fi

# --- re_escape: an unescaped `.` in the target is a WILDCARD ------------------
# Nothing above depends on the escaping, because 127.0.0.1 and 100.72.47.4 are
# different lengths — a neutered re_escape survived the rest of this suite 26/26.
# So: two targets of the SAME length differing only where the dots are, on the
# SAME local port (never simultaneously bindable in production, but the ownership
# question is the pgrep pattern, not the bind). Unescaped, C's pattern
# `100.72.47.4` matches D's `100X72X47X4` cmdline, pgrep -n picks the newer (D),
# and `down C` kills D.
C_URL=http://127.0.0.1:39200/api/health
reset_case
curl_seq "$C_URL" REFUSED 200 REFUSED 200
run ensure --port 39200 --target 100.72.47.4:39200 --host "$PEER"
C_PID=$(read_pidfile 39200 100.72.47.4:39200)
run ensure --port 39200 --target 100X72X47X4:39200 --host "$PEER"
D_PID=$(read_pidfile 39200 100X72X47X4:39200)
rm -f "$(pidfile_of 39200 100.72.47.4:39200)" "$(pidfile_of 39200 100X72X47X4:39200)"
run down --port 39200 --target 100.72.47.4:39200 --host "$PEER"
if [ -n "$C_PID" ] && [ -n "$D_PID" ] && [ "$C_PID" != "$D_PID" ] \
   && [ "$RC" -eq 0 ] && ! alive "$C_PID" && alive "$D_PID"; then
  ok "28 re_escape: a literal-dot target does not match a same-length wildcard sibling (neutered re_escape dies here)"
else bad "28 re_escape escapes the target's dots" "rc=$RC out=$OUT c=[${C_PID:-}] d=[${D_PID:-}] C=$(alive "$C_PID" && echo UP || echo dead) D=$(alive "$D_PID" && echo up || echo DEAD)"; fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf 'PASS %d/%d\n' "$PASS" "$((PASS + FAIL))"
  exit 0
fi
printf 'FAILED:\n'
for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
printf 'FAIL %d/%d\n' "$FAIL" "$((PASS + FAIL))"
exit 1
