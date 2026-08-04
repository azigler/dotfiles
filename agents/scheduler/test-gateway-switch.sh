#!/bin/bash
# Test for gateway-switch.sh — the per-host agentgateway kill switch
# (dotfiles-odq0).
#
# Hermetic: a fixture $HOME holding a SYMLINK into a fixture "repo" (the exact
# shape of the real $HOME/.<host>.zshenv -> ~/dotfiles/zsh/.<host>.zshenv), plus
# fake `tmux`, `systemctl`, `curl`, `claude`, `pgrep` and `hostname` on PATH. It
# never touches the live file, never sends a key to a real pane, never toggles a
# real unit and never spends an LLM call.
#
# WHAT THIS SUITE IS REALLY FOR — the four hazards named in the script header,
# each of which was paid for on 2026-08-04 (dotfiles-9o46):
#
#   A. THE SYMLINK. Case 18 is a CONTROL: it runs `sed -i` on the fixture
#      symlink and asserts the symlink is DESTROYED. That is the failure this
#      script exists to avoid, executable, so "we write through the symlink"
#      can never decay into an untested claim. Case 19 is the same fixture with
#      gateway-switch.sh instead, asserting the link survives AND that the
#      REPO-SIDE file is the thing that changed.
#   B. NEVER TYPE INTO A NON-SHELL PANE. Cases 26-31. `send-keys` to a live
#      claude submits a prompt; the pane-table fixture deliberately mixes
#      zsh/bash with claude/bwrap/vim, and case 30 covers the script's OWN pane
#      (an `exec zsh` there would kill the script mid-run).
#   C. IDEMPOTENCY, BOTH DIRECTIONS, TWICE. Cases 20-25. The specific defect is
#      a second `off` producing `## export`, which `on` could not reverse — so
#      the assertion is BYTE IDENTITY (`cksum`), not "it looks commented".
#   D. NO HARDCODED HOSTNAMES for the tunnel step. Cases 17 and 36: with no unit
#      present the script must make NO systemctl state-changing call at all,
#      because zig-computer legitimately has no such unit.
#   G. `status` IS CHEAP AND READ-ONLY. Cases 8-13: byte-identical file after,
#      no state-changing systemctl verb, no send-keys, and NO claude call unless
#      --check-request is passed. Case 12 is the one that matters most: the
#      end-to-end check must run under `env -u CC_NO_GATEWAY`, because the hatch
#      is EXPORTED and a session that armed it hands it to every child — the
#      request then goes direct while looking like a passing gateway test. That
#      exact false pass happened on 2026-08-04, so the fake `claude` records
#      whether it inherited the hatch and the suite exports it on purpose.
#
# MEASURED mutant -> failing cases (2026-08-04, ad-hoc sweep; RE-MEASURE rather
# than editing this map from memory — every list below was WRONG on the first
# guess, and one mutant SURVIVED, which is why case 23 exists):
#
#   A1  write with `mv` (does not follow the symlink)  -> 19 20 23 24 25 26 28
#       29 31 32 33 34 35 36 37 38. The FATAL guard fires and aborts every write
#       path, so that cascade says nothing about the guard under test; A2 is the
#       one to read.
#   A2  A1 with the post-write assertion ALSO removed  -> 19  (ONLY 19 — the
#       symlink is then destroyed SILENTLY, which is the real 2026-08-04 shape)
#   C1  `off`'s "nothing to comment" no-op guard gone  -> 20
#   C3  `off` matching /ANTHROPIC_BASE_URL/ instead of
#       the anchored ACTIVE_RE                         -> 23  (it SURVIVED 41/41
#       before case 23 existed — see the note on that case)
#   C2  `on` loses the marker-strip awk rule           -> 21 22 31 35 37 38
#   B1  the pane_current_command gate replaced by true -> 27 28
#   B2  the "skip my own pane" guard removed           -> 30
#   G1  `env -u CC_NO_GATEWAY` dropped from the
#       end-to-end check                               -> 12 13
#   G2  --check-request runs unconditionally           -> 10
#   D1  timer_exists keyed on `hostname` instead of
#       unit existence                                 -> 16 33 34 35
#   E1  the missing-file refusal removed               -> 4
#
# Convention matches the other agents/scheduler suites: executable bash,
# non-zero exit = failure, PASS/FAIL summary on the last line.

set -uo pipefail

GWS="$(cd "$(dirname "$0")" && pwd)/gateway-switch.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf '  FAIL %s\n     -> %s\n' "$1" "${2:-}"; }

ROOT=$(mktemp -d)
BIN="$ROOT/bin"
FAKE="$ROOT/fake"
HOMEDIR="$ROOT/home"
mkdir -p "$BIN" "$FAKE" "$HOMEDIR"

HOLD_PID=""
# shellcheck disable=SC2317  # invoked via trap
cleanup() {
  [ -n "$HOLD_PID" ] && kill "$HOLD_PID" 2>/dev/null   # allow-suppress: it may already be gone
  rm -rf "$ROOT"
}
trap cleanup EXIT

# A host key that exists on no real box, so nothing here can resolve to a live
# per-host file even if $HOME were somehow wrong.
FIXT_HOST=gwtest
REPOFILE="$ROOT/repo/zsh/.$FIXT_HOST.zshenv"
LINKFILE="$HOMEDIR/.$FIXT_HOST.zshenv"

# ---------------------------------------------------------------------------
# fakes
# ---------------------------------------------------------------------------
cat > "$BIN/tmux" <<'EOT'
#!/bin/bash
# Fake tmux. `list-panes` prints a scripted pane table (the script's -F format
# is fixed, so the fixture is pre-formatted); `send-keys` is RECORDED, never
# executed. Everything else is a no-op success.
case "${1:-}" in
  list-panes)
    [ -f "$GW_FAKE/tmux-noserver" ] && { echo "no server running on /tmp/tmux-0" >&2; exit 1; }
    cat "$GW_FAKE/panes"
    ;;
  send-keys)
    printf '%s\n' "$*" >> "$GW_FAKE/tmux-keys"
    [ -f "$GW_FAKE/send-fail" ] && exit 1
    exit 0
    ;;
esac
exit 0
EOT

cat > "$BIN/systemctl" <<'EOS'
#!/bin/bash
# Fake systemctl --user. EVERY invocation is recorded, so a case can assert that
# no state-changing verb was reached at all (hazard D, and `status` read-only).
printf '%s\n' "$*" >> "$GW_FAKE/systemctl-calls"
args=("$@")
verb=""
for a in "$@"; do
  case "$a" in
    list-unit-files|is-enabled|is-active|enable|disable) [ -z "$verb" ] && verb=$a ;;
  esac
done
case "$verb" in
  list-unit-files)
    if [ -f "$GW_FAKE/unit-exists" ]; then
      echo "claude-gateway-tunnel.timer enabled enabled"; exit 0
    fi
    exit 1 ;;
  is-enabled) cat "$GW_FAKE/unit-enabled"; grep -qx enabled "$GW_FAKE/unit-enabled" && exit 0; exit 1 ;;
  is-active)  echo active; exit 0 ;;
  enable)     echo enabled > "$GW_FAKE/unit-enabled"; exit 0 ;;
  disable)    echo disabled > "$GW_FAKE/unit-enabled"; exit 0 ;;
esac
exit 0
EOS

cat > "$BIN/curl" <<'EOC'
#!/bin/bash
printf '%s\n' "$*" >> "$GW_FAKE/curl-args"
for a in "$@"; do case "$a" in http://*|https://*) printf '%s\n' "$a" >> "$GW_FAKE/curl-urls" ;; esac; done
code=$(cat "$GW_FAKE/code")
# REFUSED reproduces real curl: it prints 000 AND exits non-zero.
if [ "$code" = "REFUSED" ]; then printf '000'; exit 7; fi
printf '%s' "$code"
EOC

cat > "$BIN/claude" <<'EOA'
#!/bin/bash
# Records the argv AND the two env vars whose inheritance is the whole point of
# requirement G. `${VAR-<UNSET>}` (not `:-`) so unset is distinguishable from
# empty — `env -u` produces the former.
{
  printf 'argv: %s\n' "$*"
  printf 'CC_NO_GATEWAY=%s\n' "${CC_NO_GATEWAY-<UNSET>}"
  printf 'ANTHROPIC_BASE_URL=%s\n' "${ANTHROPIC_BASE_URL-<UNSET>}"
} >> "$GW_FAKE/claude-calls"
echo OK
EOA

cat > "$BIN/pgrep" <<'EOP'
#!/bin/bash
# Only the `-x <name>` form the script uses. Real pgrep exits 1 on no match.
name=""
for a in "$@"; do case "$a" in -*) ;; *) name=$a ;; esac; done
f="$GW_FAKE/pids-$name"
[ -s "$f" ] || exit 1
cat "$f"
EOP

cat > "$BIN/hostname" <<'EOH'
#!/bin/bash
cat "$GW_FAKE/hostname"
EOH

chmod +x "$BIN"/tmux "$BIN"/systemctl "$BIN"/curl "$BIN"/claude "$BIN"/pgrep "$BIN"/hostname
export PATH="$BIN:$PATH"
export GW_FAKE="$FAKE"
export HOME="$HOMEDIR"

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
# Deliberately includes DECOY prose: two comment lines that mention
# ANTHROPIC_BASE_URL / CC_NO_GATEWAY (the real file is full of them) and one
# that names `export ANTHROPIC_BASE_URL` in running text. None is an export
# line, and case 39 asserts all three survive a full off/on cycle byte-intact.
orig_content() {
  cat <<'EOF'
# gwtest — per-host NON-interactive env FIXTURE (never a real host).
export PATH="$HOME/.local/bin:$PATH"

# pico's agentgateway, reached through a local forward.
# BYPASS, two ways:
#   - one session:  CC_NO_GATEWAY=1 claude
#   - lastingly:    comment out the export ANTHROPIC_BASE_URL line below
# Note the /claude suffix is REQUIRED; /v1/models alone 404s.
export ANTHROPIC_BASE_URL="http://127.0.0.1:17017/claude"
EOF
}

make_fixture() { # gateway | bypassed | hand | double | noexport
  rm -rf "$ROOT/repo" "$HOMEDIR"
  mkdir -p "$ROOT/repo/zsh" "$HOMEDIR"
  orig_content > "$REPOFILE"
  case "$1" in
    gateway)  ;;
    bypassed) sed -i 's|^export ANTHROPIC_BASE_URL=|#gateway-switch:off# export ANTHROPIC_BASE_URL=|' "$REPOFILE" ;;
    hand)     sed -i 's|^export ANTHROPIC_BASE_URL=|# export ANTHROPIC_BASE_URL=|' "$REPOFILE" ;;
    double)   sed -i 's|^export ANTHROPIC_BASE_URL=|## export ANTHROPIC_BASE_URL=|' "$REPOFILE" ;;
    noexport) grep -v 'ANTHROPIC_BASE_URL' "$REPOFILE" > "$REPOFILE.t"; mv "$REPOFILE.t" "$REPOFILE" ;;
  esac
  ln -sfn "$REPOFILE" "$LINKFILE"
}

default_panes() {
  cat > "$FAKE/panes" <<'EOF'
%1|zsh|work:shell.0|1111
%2|claude|work:di-monday.0|2222
%3|bash|work:build.1|3333
%4|bwrap|work:jail.0|4444
%5|vim|work:edit.0|5555
EOF
}

reset_case() {
  rm -f "$FAKE/tmux-keys" "$FAKE/systemctl-calls" "$FAKE/curl-args" "$FAKE/curl-urls" \
        "$FAKE/claude-calls" "$FAKE/tmux-noserver" "$FAKE/send-fail" "$FAKE/unit-exists" \
        "$FAKE/pids-claude" "$FAKE/pids-bwrap"
  : > "$FAKE/tmux-keys"; : > "$FAKE/systemctl-calls"; : > "$FAKE/curl-args"
  : > "$FAKE/claude-calls"
  echo 401 > "$FAKE/code"
  echo enabled > "$FAKE/unit-enabled"
  echo "$FIXT_HOST" > "$FAKE/hostname"
  default_panes
  unset TMUX_PANE
}

OUT=""
RC=0
# `timeout` so a future hang FAILS the suite (rc 124) instead of wedging the
# pre-commit gate.
run() { OUT=$(timeout 60 bash "$GWS" "$@" 2>&1); RC=$?; }

sum_of() { cksum < "$LINKFILE"; }   # read THROUGH the symlink; no filename in the output
keys_of() { cat "$FAKE/tmux-keys"; }

echo "== usage + preflight refuse LOUDLY (requirement E) =="

reset_case
make_fixture gateway
run
if [ "$RC" -eq 64 ] && printf '%s' "$OUT" | grep -q 'name a subcommand'; then
  ok "1  no subcommand -> exit 64 (the verbs change fleet routing; nothing is defaulted)"
else bad "1  no subcommand -> 64" "rc=$RC out=$OUT"; fi

run --nonsense
if [ "$RC" -eq 64 ] && printf '%s' "$OUT" | grep -q "unknown arg '--nonsense'"; then
  ok "2  unknown arg -> exit 64 naming the arg"
else bad "2  unknown arg -> 64" "rc=$RC out=$OUT"; fi

run status --host ''
if [ "$RC" -eq 64 ] && printf '%s' "$OUT" | grep -q 'EMPTY value'; then
  ok "3  an EXPLICIT empty --host exits 64, never a silent fallback to \`hostname -s\`"
else bad "3  empty --host -> 64" "rc=$RC out=$OUT"; fi

reset_case
make_fixture gateway
run status --host nosuchhost
if [ "$RC" -eq 65 ] && printf '%s' "$OUT" | grep -q "no per-host zshenv at $HOMEDIR/.nosuchhost.zshenv"; then
  ok "4  missing per-host zshenv -> exit 65, and the message NAMES THE PATH"
else bad "4  missing zshenv -> 65 + path" "rc=$RC out=$OUT"; fi

reset_case
make_fixture noexport
run status --host "$FIXT_HOST"
RC1=$RC; OUT1=$OUT
run off --host "$FIXT_HOST"
RC2=$RC
if [ "$RC1" -eq 66 ] && [ "$RC2" -eq 66 ] && printf '%s' "$OUT1" | grep -q 'no ANTHROPIC_BASE_URL export line'; then
  ok "5  a file with no export line at all -> exit 66 on every verb (silence is the failure mode)"
else bad "5  no export line -> 66" "rc=$RC1,$RC2 out=$OUT1"; fi

echo "== status: reports, and changes NOTHING (requirement G) =="

reset_case
make_fixture gateway
: > "$FAKE/unit-exists"
run status --host "$FIXT_HOST"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'routing:    ON' \
   && printf '%s' "$OUT" | grep -q 'ANTHROPIC_BASE_URL=http://127.0.0.1:17017/claude'; then
  ok "6  status on a gatewayed host: routing ON + the configured value + exit 0"
else bad "6  status routing ON" "rc=$RC out=$OUT"; fi

if printf '%s' "$OUT" | grep -q 'symlink)'; then
  ok "7  status reports that the per-host file IS a symlink, and its target"
else bad "7  status reports symlink-ness" "out=$OUT"; fi

BEFORE=$(sum_of); BEFORE_LINK=$(readlink "$LINKFILE")
run status --host "$FIXT_HOST"
AFTER=$(sum_of); AFTER_LINK=$(readlink "$LINKFILE")
if [ "$BEFORE" = "$AFTER" ] && [ -L "$LINKFILE" ] && [ "$BEFORE_LINK" = "$AFTER_LINK" ]; then
  ok "8  status is READ-ONLY: byte-identical cksum after, symlink and target unchanged"
else bad "8  status is read-only" "before=[$BEFORE] after=[$AFTER] link=[$AFTER_LINK]"; fi

if ! grep -qE '(^| )(enable|disable)( |$)' "$FAKE/systemctl-calls" && [ ! -s "$FAKE/tmux-keys" ]; then
  ok "9  status reaches NO state-changing systemctl verb and sends NO keys"
else bad "9  status changes no state" "systemctl=$(cat "$FAKE/systemctl-calls") keys=$(keys_of)"; fi

if [ ! -s "$FAKE/claude-calls" ] && printf '%s' "$OUT" | grep -q 'end-to-end: skipped (no LLM call)'; then
  ok "10 status spends NO LLM call by default, and says so"
else bad "10 status makes no claude call" "calls=$(cat "$FAKE/claude-calls") out=$OUT"; fi

reset_case
make_fixture bypassed
run status --host "$FIXT_HOST"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'routing:    OFF' \
   && printf '%s' "$OUT" | grep -q 'configured value would be http://127.0.0.1:17017/claude'; then
  ok "11 status on a BYPASSED host still reads the configured value (so you can probe before turning it back on)"
else bad "11 status routing OFF" "rc=$RC out=$OUT"; fi

# --- THE FALSE-PASS GUARD -----------------------------------------------------
reset_case
make_fixture gateway
export CC_NO_GATEWAY=1          # exactly the poisoned session that produced the 2026-08-04 false pass
run status --host "$FIXT_HOST" --check-request
CR_RC=$RC; CR_OUT=$OUT
unset CC_NO_GATEWAY
if [ "$CR_RC" -eq 0 ] && grep -q '^CC_NO_GATEWAY=<UNSET>$' "$FAKE/claude-calls" \
   && grep -q '^ANTHROPIC_BASE_URL=http://127.0.0.1:17017/claude$' "$FAKE/claude-calls"; then
  ok "12 --check-request strips an INHERITED CC_NO_GATEWAY (env -u) and pins the file's base URL"
else bad "12 --check-request strips the hatch" "rc=$CR_RC calls=$(cat "$FAKE/claude-calls") out=$CR_OUT"; fi

reset_case
make_fixture bypassed
export CC_NO_GATEWAY=1
run status --host "$FIXT_HOST" --check-request
unset CC_NO_GATEWAY
if grep -q '^CC_NO_GATEWAY=<UNSET>$' "$FAKE/claude-calls" \
   && grep -q '^ANTHROPIC_BASE_URL=<UNSET>$' "$FAKE/claude-calls"; then
  ok "13 --check-request on a bypassed host tests the DIRECT route (both vars removed), not a stale one"
else bad "13 --check-request direct route" "calls=$(cat "$FAKE/claude-calls")"; fi

echo "== the probe: 401 is health, 000 is not 'no data' =="

reset_case
make_fixture gateway
echo 401 > "$FAKE/code"
run status --host "$FIXT_HOST"
A_OK=$(printf '%s' "$OUT" | grep -c 'HEALTHY')
echo REFUSED > "$FAKE/code"
run status --host "$FIXT_HOST"
B_OK=$(printf '%s' "$OUT" | grep -c 'NOTHING ANSWERED')
echo 503 > "$FAKE/code"
run status --host "$FIXT_HOST"
C_OK=$(printf '%s' "$OUT" | grep -c 'UNEXPECTED')
if [ "$A_OK" -ge 1 ] && [ "$B_OK" -ge 1 ] && [ "$C_OK" -ge 1 ]; then
  ok "14 probe verdicts: 401 HEALTHY / 000 NOTHING ANSWERED / 503 UNEXPECTED (three-valued, like /vps)"
else bad "14 probe verdicts" "401=$A_OK 000=$B_OK 503=$C_OK out=$OUT"; fi

if grep -qx 'http://127.0.0.1:17017/claude/v1/models' "$FAKE/curl-urls"; then
  ok "15 probe URL keeps the /claude prefix from the base URL (dropping it 404s every call)"
else bad "15 probe URL keeps /claude" "urls=$(cat "$FAKE/curl-urls")"; fi

echo "== requirement D: the timer step keys on EXISTENCE, never on a hostname =="

reset_case
make_fixture gateway
: > "$FAKE/unit-exists"
run status --host "$FIXT_HOST"
if printf '%s' "$OUT" | grep -q 'timer:      claude-gateway-tunnel.timer exists, is-enabled=enabled'; then
  ok "16 status reports the timer when the unit EXISTS"
else bad "16 status reports the timer" "out=$OUT"; fi

reset_case
make_fixture gateway
run status --host "$FIXT_HOST"          # no unit-exists marker => no unit on this host
if printf '%s' "$OUT" | grep -q 'no claude-gateway-tunnel.timer on this host'; then
  ok "17 status says 'no timer on this host' instead of erroring (that is zig-computer's normal state)"
else bad "17 no-timer host is normal" "out=$OUT"; fi

echo "== requirement A: the symlink. CONTROL FIRST, then the fix =="

reset_case
make_fixture gateway
LINK_BEFORE=$(readlink "$LINKFILE")
sed -i 's|^export ANTHROPIC_BASE_URL=|#export ANTHROPIC_BASE_URL=|' "$LINKFILE"
if [ ! -L "$LINKFILE" ] && [ -f "$LINKFILE" ]; then
  ok "18 CONTROL: \`sed -i\` on the symlink REPLACES it with a regular file — the defect this script avoids"
else bad "18 CONTROL sed -i breaks the symlink" "still a link? $( [ -L "$LINKFILE" ] && echo yes || echo no) (if this now PASSES as a link, sed changed and this suite's premise needs re-measuring)"; fi

reset_case
make_fixture gateway
REPO_BEFORE=$(cksum < "$REPOFILE")
run off --host "$FIXT_HOST"
REPO_AFTER=$(cksum < "$REPOFILE")
if [ "$RC" -eq 0 ] && [ -L "$LINKFILE" ] && [ "$(readlink "$LINKFILE")" = "$REPOFILE" ] \
   && [ "$REPO_BEFORE" != "$REPO_AFTER" ] && printf '%s' "$OUT" | grep -q 'symlink intact'; then
  ok "19 \`off\` writes THROUGH the symlink: link + target unchanged, and the REPO-SIDE file is what moved"
else bad "19 off preserves the symlink" "rc=$RC link=$( [ -L "$LINKFILE" ] && echo yes || echo NO) repo_changed=$( [ "$REPO_BEFORE" != "$REPO_AFTER" ] && echo yes || echo NO) out=$OUT"; fi

echo "== requirement C: idempotent, both directions, twice =="

reset_case
make_fixture gateway
ORIG=$(sum_of)
run off --host "$FIXT_HOST"
OFF1=$(sum_of); OFF1_RC=$RC
run off --host "$FIXT_HOST"
OFF2=$(sum_of); OFF2_OUT=$OUT
if [ "$OFF1_RC" -eq 0 ] && [ "$OFF1" = "$OFF2" ] && ! grep -q '^##' "$LINKFILE" \
   && printf '%s' "$OFF2_OUT" | grep -q 'already bypassed'; then
  ok "20 \`off\` twice is BYTE-IDENTICAL and says 'already bypassed' — no '## export' to un-reverse"
else bad "20 off is idempotent" "rc=$OFF1_RC off1=[$OFF1] off2=[$OFF2] out=$OFF2_OUT"; fi

run on --host "$FIXT_HOST"
ON1=$(sum_of); ON1_RC=$RC
run on --host "$FIXT_HOST"
ON2=$(sum_of); ON2_OUT=$OUT
if [ "$ON1_RC" -eq 0 ] && [ "$ON1" = "$ORIG" ] && [ "$ON2" = "$ORIG" ] \
   && printf '%s' "$ON2_OUT" | grep -q 'already routed'; then
  ok "21 \`on\` round-trips to the ORIGINAL BYTES and is itself idempotent"
else bad "21 on round-trips + idempotent" "rc=$ON1_RC orig=[$ORIG] on1=[$ON1] on2=[$ON2] out=$ON2_OUT"; fi

run off --host "$FIXT_HOST"; CYC_OFF=$(sum_of)
run on  --host "$FIXT_HOST"; CYC_ON1=$(sum_of)
run off --host "$FIXT_HOST"; CYC_OFF2=$(sum_of)
run on  --host "$FIXT_HOST"; CYC_ON2=$(sum_of)
if [ "$CYC_OFF" = "$OFF1" ] && [ "$CYC_OFF2" = "$OFF1" ] \
   && [ "$CYC_ON1" = "$ORIG" ] && [ "$CYC_ON2" = "$ORIG" ]; then
  ok "22 off/on/off/on: every OFF state and every ON state is byte-identical to the first"
else bad "22 full cycle byte-stable" "off=[$CYC_OFF/$CYC_OFF2 vs $OFF1] on=[$CYC_ON1/$CYC_ON2 vs $ORIG]"; fi

# WHY THIS CASE EXISTS: a mutation sweep found a SURVIVOR. Widening `off`'s
# transform from the anchored ACTIVE_RE to a bare /ANTHROPIC_BASE_URL/ match
# comments the prose lines too — and every cycle test above still passed 41/41,
# because the marker is stripped back off them by `on`, so the damage is
# invisible to any assertion that only compares the two END states. The
# intermediate OFF state is where it shows. Assert the bypassed file differs from
# the original by EXACTLY ONE LINE, and that the line is the export.
reset_case
make_fixture gateway
cp "$LINKFILE" "$ROOT/orig-bytes"
run off --host "$FIXT_HOST"
# `|| DIFFLINES=0` would be WRONG here and cost 20 minutes the first time: under
# `pipefail` the pipeline inherits diff's exit 1 (files differ — the expected
# case), so the fallback fires and clobbers a correct count with 0.
DIFFBODY=$( { diff "$ROOT/orig-bytes" "$LINKFILE" || true; } | grep -E '^[<>]' )
DIFFLINES=$(printf '%s\n' "$DIFFBODY" | grep -cE '^[<>]')
if [ "$RC" -eq 0 ] && [ "$DIFFLINES" -eq 2 ] \
   && [ "$(printf '%s\n' "$DIFFBODY" | grep -cE '^[<>] .*export ANTHROPIC_BASE_URL=')" -eq 2 ]; then
  ok "23 \`off\` changes EXACTLY ONE LINE — the export — leaving every comment byte-intact (a /ANTHROPIC_BASE_URL/-wide transform survived every cycle test; only this kills it)"
else bad "23 off changes exactly one line" "rc=$RC changed=$DIFFLINES body=$DIFFBODY"; fi

reset_case
make_fixture hand
run on --host "$FIXT_HOST"
if [ "$RC" -eq 0 ] && grep -qx 'export ANTHROPIC_BASE_URL="http://127.0.0.1:17017/claude"' "$LINKFILE"; then
  ok "24 \`on\` reverses a HAND-commented line (\`# export …\`) — the manual bypass the zshenv itself documents"
else bad "24 on reverses a hand-comment" "rc=$RC line=$(grep -n 'ANTHROPIC_BASE_URL=' "$LINKFILE")"; fi

reset_case
make_fixture double
run on --host "$FIXT_HOST"
N=$(grep -cE '^[[:space:]]*export[[:space:]]+ANTHROPIC_BASE_URL' "$LINKFILE") || N=0
if [ "$RC" -eq 0 ] && [ "$N" -eq 1 ] && ! grep -q '^#.*export ANTHROPIC_BASE_URL=' "$LINKFILE"; then
  ok "25 \`on\` recovers even a DOUBLE-commented \`## export\` line, to exactly ONE active line"
else bad "25 on recovers ## export" "rc=$RC active=$N out=$OUT"; fi

echo "== requirement B: never type into a pane that is not at a prompt =="

reset_case
make_fixture gateway
run off --host "$FIXT_HOST"
if grep -q -- '-t %1 C-u unset ANTHROPIC_BASE_URL Enter' "$FAKE/tmux-keys" \
   && grep -q -- '-t %3 C-u unset ANTHROPIC_BASE_URL Enter' "$FAKE/tmux-keys"; then
  ok "26 \`off\` sends \`unset ANTHROPIC_BASE_URL\` to the zsh and bash panes"
else bad "26 off updates shell panes" "keys=$(keys_of)"; fi

if ! grep -q -- '-t %2 ' "$FAKE/tmux-keys" && ! grep -q -- '-t %4 ' "$FAKE/tmux-keys" \
   && ! grep -q -- '-t %5 ' "$FAKE/tmux-keys"; then
  ok "27 NOTHING is sent to the claude (%2), bwrap (%4) or vim (%5) panes — send-keys there SUBMITS A PROMPT"
else bad "27 no keys to non-shell panes" "keys=$(keys_of)"; fi

if printf '%s' "$OUT" | grep -q "MANUAL work:di-monday.0 (%2) is running 'claude'" \
   && printf '%s' "$OUT" | grep -q "MANUAL work:jail.0 (%4) is running 'bwrap'"; then
  ok "28 those panes are REPORTED as needing a manual restart, by label and by command"
else bad "28 non-shell panes reported" "out=$OUT"; fi

if grep -q -- '-t %1 C-u ' "$FAKE/tmux-keys"; then
  ok "29 a C-u precedes the command, so half-typed text in a shell pane is discarded rather than executed"
else bad "29 C-u precedes the command" "keys=$(keys_of)"; fi

reset_case
make_fixture gateway
export TMUX_PANE=%1
run on --host "$FIXT_HOST"
unset TMUX_PANE
if ! grep -q -- '-t %1 ' "$FAKE/tmux-keys" \
   && grep -q -- '-t %3 C-u exec bash Enter' "$FAKE/tmux-keys" \
   && printf '%s' "$OUT" | grep -q 'MY OWN pane'; then
  ok "30 the script SKIPS its own pane (\$TMUX_PANE) — an \`exec\` there would kill the run mid-flight"
else bad "30 skips its own pane" "keys=$(keys_of) out=$OUT"; fi

reset_case
make_fixture bypassed
run on --host "$FIXT_HOST"
if grep -q -- '-t %1 C-u exec zsh Enter' "$FAKE/tmux-keys" \
   && grep -q -- '-t %3 C-u exec bash Enter' "$FAKE/tmux-keys"; then
  ok "31 \`on\` re-execs each shell pane with ITS OWN shell (exec zsh / exec bash), not a hardcoded zsh"
else bad "31 on execs the pane's own shell" "keys=$(keys_of)"; fi

reset_case
make_fixture gateway
: > "$FAKE/tmux-noserver"
run off --host "$FIXT_HOST"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'none reachable' \
   && grep -qE '^#gateway-switch:off# export' "$LINKFILE"; then
  ok "32 no tmux server: the file step still lands and the run still succeeds"
else bad "32 no tmux server is survivable" "rc=$RC out=$OUT"; fi

echo "== the timer verbs, and never calling them when there is no unit =="

reset_case
make_fixture gateway
: > "$FAKE/unit-exists"
echo enabled > "$FAKE/unit-enabled"
run off --host "$FIXT_HOST"
if grep -q 'disable --now claude-gateway-tunnel.timer' "$FAKE/systemctl-calls" \
   && printf '%s' "$OUT" | grep -q 'disabled --now'; then
  ok "33 \`off\` disables --now the tunnel timer when the unit exists"
else bad "33 off disables the timer" "calls=$(cat "$FAKE/systemctl-calls") out=$OUT"; fi

run off --host "$FIXT_HOST"
if printf '%s' "$OUT" | grep -q 'already disabled — no change'; then
  ok "34 a second \`off\` reports the timer as already disabled instead of re-issuing the verb"
else bad "34 timer step is idempotent" "out=$OUT"; fi

reset_case
make_fixture bypassed
: > "$FAKE/unit-exists"
echo disabled > "$FAKE/unit-enabled"
run on --host "$FIXT_HOST"
if grep -q 'enable --now claude-gateway-tunnel.timer' "$FAKE/systemctl-calls"; then
  ok "35 \`on\` enables --now the tunnel timer when the unit exists"
else bad "35 on enables the timer" "calls=$(cat "$FAKE/systemctl-calls")"; fi

reset_case
make_fixture gateway
run off --host "$FIXT_HOST"
if [ "$RC" -eq 0 ] && ! grep -qE '(^| )(enable|disable)( |$)' "$FAKE/systemctl-calls" \
   && printf '%s' "$OUT" | grep -q 'skipping the tunnel step'; then
  ok "36 with NO unit on the host, \`off\` issues no enable/disable at all (requirement D — zig-computer)"
else bad "36 no unit -> no systemctl verb" "rc=$RC calls=$(cat "$FAKE/systemctl-calls") out=$OUT"; fi

echo "== post-change verification, and the decoys =="

reset_case
make_fixture bypassed
echo REFUSED > "$FAKE/code"
run on --host "$FIXT_HOST"
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q 'ROUTING RESTORED, BUT THE GATEWAY DOES NOT ANSWER' \
   && grep -qE '^export ANTHROPIC_BASE_URL=' "$LINKFILE"; then
  ok "37 \`on\` against a DEAD gateway exits 3 and says the box now has no claude — the change still landed"
else bad "37 on with a dead gateway exits 3" "rc=$RC out=$OUT"; fi

reset_case
make_fixture bypassed
echo 401 > "$FAKE/code"
run on --host "$FIXT_HOST"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'DONE — routing restored'; then
  ok "38 \`on\` against a healthy gateway verifies with the probe and exits 0"
else bad "38 on verifies and exits 0" "rc=$RC out=$OUT"; fi

reset_case
make_fixture gateway
DECOY_BEFORE=$(grep -c 'ANTHROPIC_BASE_URL' "$LINKFILE")
run off --host "$FIXT_HOST"
run on --host "$FIXT_HOST"
if [ "$(grep -c 'ANTHROPIC_BASE_URL' "$LINKFILE")" = "$DECOY_BEFORE" ] \
   && grep -qx '#   - lastingly:    comment out the export ANTHROPIC_BASE_URL line below' "$LINKFILE" \
   && grep -qx '#   - one session:  CC_NO_GATEWAY=1 claude' "$LINKFILE"; then
  ok "39 comment PROSE that merely mentions ANTHROPIC_BASE_URL (even 'the export ANTHROPIC_BASE_URL line') survives a full cycle"
else bad "39 decoy prose untouched" "before=$DECOY_BEFORE now=$(grep -c 'ANTHROPIC_BASE_URL' "$LINKFILE") file=$(cat "$LINKFILE")"; fi

echo "== host derivation + the /proc routing report =="

reset_case
make_fixture gateway
echo "$FIXT_HOST" > "$FAKE/hostname"
run status                       # no --host: must derive it from `hostname -s`
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "host key:   $FIXT_HOST"; then
  ok "40 with no --host the host key comes from \`hostname -s\`"
else bad "40 host derived from hostname -s" "rc=$RC out=$OUT"; fi

reset_case
make_fixture gateway
# A REAL process with a KNOWN environment, so the /proc read under test is real
# even though pgrep is faked. `sleep` is exec'd by `env`, so its /proc/*/environ
# holds exactly these two values.
env ANTHROPIC_BASE_URL=http://fixture.invalid:17017/claude CC_NO_GATEWAY=1 sleep 30 &
HOLD_PID=$!
printf '%s\n' "$HOLD_PID" > "$FAKE/pids-claude"
run status --host "$FIXT_HOST"
if printf '%s' "$OUT" | grep -q "pid $HOLD_PID" \
   && printf '%s' "$OUT" | grep -q 'via http://fixture.invalid:17017/claude' \
   && printf '%s' "$OUT" | grep -q 'CC_NO_GATEWAY=1'; then
  ok "41 the process report reads routing out of a REAL /proc/<pid>/environ, hatch included"
else bad "41 /proc routing report" "pid=$HOLD_PID out=$OUT"; fi

kill "$HOLD_PID" 2>/dev/null   # allow-suppress: liveness only
HOLD_PID=""
reset_case
make_fixture gateway
run status --host "$FIXT_HOST"
if printf '%s' "$OUT" | grep -q 'processes: no running claude/bwrap'; then
  ok "42 no running claude -> a plain 'none', not an error"
else bad "42 no claude processes" "out=$OUT"; fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf 'PASS %d/%d\n' "$PASS" "$((PASS + FAIL))"
  exit 0
fi
printf 'FAILED:\n'
for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
printf 'FAIL %d/%d\n' "$FAIL" "$((PASS + FAIL))"
exit 1
