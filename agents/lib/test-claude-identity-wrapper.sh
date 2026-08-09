#!/bin/sh
# test-claude-identity-wrapper.sh — the attribution-header contract for
# claude-identity-wrapper.sh, asserted by INSPECTING THE ENV OF A LAUNCHED
# PROCESS (a fake `claude` earlier on PATH that dumps its own environment),
# never by reading the wrapper's source.
#
#   bash agents/lib/test-claude-identity-wrapper.sh   # also re-runs itself under zsh
#   zsh  agents/lib/test-claude-identity-wrapper.sh
#
# WHY IT EXISTS (dotfiles-v93v). The wrapper sent ONE header,
# `X-Session-Identity: <tmux session>:<window>`, which pico maps to
# standardAttributes.user. The first field is the tmux SESSION name, not the
# machine, and that namespace is shared — zig-computer, marketing-vps and metis
# all have a session named `work`. A second header `X-Machine-Origin:
# <hostname -s>` carries the machine into standardAttributes.group.
#
# ⚠️ EPOCH 2, 2026-08-09 (dotfiles-jbnp). The header NAMES and the newline
# separator are unchanged; the VALUES are not. `user` is now the derived SEAT
# ADDRESS `<host>:<seat>` and `group` is the TAP, and two canonical-name copies
# (`X-Seat-Address`, `X-Tap`) ride along so the gateway-side rename can be
# config-only later. Every expectation below therefore moved, and that is the
# point of the change rather than a regression — see the epoch-2 note at the top
# of claude-identity-wrapper.sh and refs/probes/gateway-attribution-epoch2.md.
# The epoch-1 VALUES are deliberately NOT preserved anywhere in this suite:
# this file tests what the wrapper EMITS, and the wrapper cannot emit two
# epochs at once. Epoch-1 rows live in requests.db, which nothing here writes
# and nothing may rewrite.
#
# The epoch-2 regressions this guards, on top of R1–R5:
#   R6  the address falling back to raw tmux `session:window` when the resolver
#       is unavailable. Post the one-session ruling that string is byte-equal to
#       `host:seat` for a REGISTERED window, so a source read and a live spot
#       check both look right — and an UNREGISTERED or renamed window then emits
#       a seat-shaped value that is not a seat. T17 (alias -> canonical) and T18
#       (unregistered -> `?`) are the two cases where derived and raw differ.
#   R7  the tap asserted from the roster instead of derived from the launch's
#       own CLAUDE_CONFIG_DIR — which would make `group` say what a seat is
#       SUPPOSED to bill to rather than what it is billing to.  (T15, T19)
#
# The regressions this guards, each of which passes a source read:
#   R1  `_host` computed only inside `if [ -z "$_base" ]` -> the machine header
#       vanishes in exactly the case where ANTHROPIC_BASE_URL was already
#       exported, i.e. every freshly-started shell.  (T5)
#   R2  the machine header emitted only inside the tmux branch -> jailed and
#       non-interactive ticks stay machine-unattributed, which is most of the
#       point.  (T2)
#   R3  the two headers joined with `, ` / `; ` / a space instead of a NEWLINE.
#       ANTHROPIC_CUSTOM_HEADERS is newline-separated; the parser extracted from
#       the 2.1.220 binary is literally
#           for (let c of s.split("\n")) { let u = c.indexOf(":");
#             if (u >= 0) l[c.substring(0,u).trim()] = c.substring(u+1).trim() }
#       so a comma join is NOT a malformed header name — it yields ONE header,
#       `X-Session-Identity`, whose VALUE silently carries the machine text.
#       Attribution then looks fine and is wrong.  (T1, byte-checked)
#   R4  the launch contract broken on ONE branch. The wrapper has four explicit
#       launch cases, and a mutation sweep on 2026-08-02 found that dropping
#       --dangerously-skip-permissions (M5) or injecting ANTHROPIC_AUTH_TOKEN
#       (M7) in the `elif [ -n "$_hdrs" ]` case SURVIVED this suite: argv was
#       asserted once, off a file a DIFFERENT test's launch had written, and
#       that launch took the first case. Every launch now asserts its own argv
#       and its own credential-absence, and each test names the case it drives.
#       That branch is the one marketing-vps lives on (no ~/.<host>.zshenv, no
#       tmux in unattended ticks), where a dropped flag hangs pulse ticks
#       fleet-wide and an injected credential moves billing off the claude.ai
#       subscription.  (assert_launch, called after EVERY run)
#   R5  the CC_NO_GATEWAY hatch checked AFTER an inherited ANTHROPIC_BASE_URL
#       rather than before, which makes it UNREACHABLE in every fresh zsh: zsh
#       sources ~/.zshenv on EVERY invocation, that sources ~/.<host>.zshenv,
#       and that EXPORTS ANTHROPIC_BASE_URL — so the inherited-wins rule has
#       already matched by the time the hatch is looked at. The hatch then only
#       works where the variable happens to be unset (bash), which is the
#       opposite of where it is needed.  (dotfiles-20rx; T9 T10 T11 T12)
#
#       Two halves, and the second is the one a source read misses: clearing the
#       variable INSIDE the wrapper does not bypass anything, because the value
#       is EXPORTED in the calling shell and the child inherits it regardless.
#       It has to be removed from the launched environment — see cases 2u/4u.
#
#       T6/T6b did NOT catch this, and the reason is worth keeping: `run()`
#       launches under `env -i` with HOME=$FAKEHOME, so the shell it starts has
#       no startup file to export the variable and no ambient environment —
#       a shape that exists nowhere in production. Not a zsh-vs-bash gap: T6
#       passed under BOTH shells. The suite could only see the bug once a test
#       modelled a shell that starts with the variable ALREADY set, which is
#       what $STARTHOME below exists for.
#
# Everything is asserted against `printenv` inside the child, so a change that
# builds the right string but fails to EXPORT it still fails here.
#
# THE LAUNCH CASES AND WHO DRIVES THEM (keep this current):
#   case 1   _hdrs && _base            T1  T2  T5  T7  T10
#   case 2   _hdrs only                T3  T3b T6      <- the marketing-vps shape
#   case 3   _base only                T4b
#   case 4   neither                   T4
#   case 2u  _hdrs, strip inherited    T9  T11
#   case 4u  neither, strip inherited  T12
# The `u` cases are the ones that must REMOVE ANTHROPIC_BASE_URL from the
# launched environment (`env -u`) rather than merely decline to set it — an
# exported value in the calling shell is inherited whatever the wrapper
# computes, which is why clearing the variable internally does not bypass
# anything. Each case is driven by at least one test on purpose (R4).

DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
WRAPPER="$DIR/claude-identity-wrapper.sh"
FAILS=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n       expected: [%s]\n       got:      [%s]\n' "$1" "$2" "$3"; FAILS=$((FAILS+1)); }

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
MOCKDIR="$TMPROOT/bin"; mkdir -p "$MOCKDIR"
DUMPDIR="$TMPROOT/dump"; mkdir -p "$DUMPDIR"
FAKEHOME="$TMPROOT/home"; mkdir -p "$FAKEHOME"

# --- the probe: a fake `claude` that dumps ITS OWN environment ---------------
# `printenv` (not an echo of a shell variable) so what is recorded is what the
# child process actually inherited. `+x` distinguishes unset from set-empty.
# The creds file is the SUBSCRIPTION-SAFE invariant made mechanical: any of
# these in the launched environment flips Claude Code off the claude.ai
# subscription onto per-token billing, so the file must come back EMPTY.
cat > "$MOCKDIR/claude" <<'EOF'
#!/bin/sh
rm -f "$DUMPDIR/hdrs" "$DUMPDIR/hdrs.od" "$DUMPDIR/base" "$DUMPDIR/leak"
printf '%s\n' "$*" > "$DUMPDIR/args"
if [ -n "${LEAK_CANARY+x}" ]; then printenv LEAK_CANARY > "$DUMPDIR/leak"; fi
: > "$DUMPDIR/creds"
for v in ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_OAUTH_TOKEN \
         CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY_HELPER; do
  if printenv "$v" > /dev/null; then printf '%s\n' "$v" >> "$DUMPDIR/creds"; fi
done
if [ -n "${ANTHROPIC_CUSTOM_HEADERS+x}" ]; then
  printenv ANTHROPIC_CUSTOM_HEADERS > "$DUMPDIR/hdrs"
  printenv ANTHROPIC_CUSTOM_HEADERS | od -c > "$DUMPDIR/hdrs.od"
fi
if [ -n "${ANTHROPIC_BASE_URL+x}" ]; then
  printenv ANTHROPIC_BASE_URL > "$DUMPDIR/base"
fi
# The config dir the LAUNCHED process actually got. A rollover that changes the
# headers but not this is the whole defect in one line: the request would
# announce a tap it is not running on.
if [ -n "${CLAUDE_CONFIG_DIR+x}" ]; then
  printenv CLAUDE_CONFIG_DIR > "$DUMPDIR/cfgdir"
fi
exit 0
EOF
chmod +x "$MOCKDIR/claude"

# --- mock hostname: MOCK_HOST, or nothing at all (the fail-open case) --------
cat > "$MOCKDIR/hostname" <<'EOF'
#!/bin/sh
[ -n "${MOCK_HOST:-}" ] || { echo "hostname: mocked failure" >&2; exit 1; }
printf '%s\n' "$MOCK_HOST"
EOF
chmod +x "$MOCKDIR/hostname"

# --- mock tmux: answers by the format string requested -----------------------
cat > "$MOCKDIR/tmux" <<'EOF'
#!/bin/sh
case "$*" in
  *session_name*) printf '%s\n' "${MOCK_SESS:-}" ;;
  *window_name*)  printf '%s\n' "${MOCK_WIN:-}" ;;
esac
EOF
chmod +x "$MOCKDIR/tmux"

# The per-host env file the wrapper reads in a subshell. LEAK_CANARY proves the
# subshell containment: it must never reach the caller or the launched child.
printf '%s\n' \
  'export ANTHROPIC_BASE_URL="http://127.0.0.1:17017/claude"' \
  'export LEAK_CANARY=leaked' > "$FAKEHOME/.testbox.zshenv"

# --- $STARTHOME: a home whose SHELL STARTUP FILE exports the base URL --------
# This is what production actually looks like and what $FAKEHOME cannot model
# (see R5). zsh sources ~/.zshenv on EVERY invocation — interactive or not,
# login or not — so on a real box the variable is in the environment before the
# wrapper's first line runs. bash reaches the same shape via $BASH_ENV, which
# non-interactive `bash -c` sources (it does NOT read ~/.bashrc), so both
# shells are covered by one fixture and the tests below are shell-agnostic.
#
# The startup value is DELIBERATELY DIFFERENT from the per-host file's value,
# so "the inherited value won" is distinguishable from "the per-host file was
# re-read" — same string for both would make T10 unable to tell them apart.
STARTHOME="$TMPROOT/starthome"; mkdir -p "$STARTHOME"
cp "$FAKEHOME/.testbox.zshenv" "$STARTHOME/.testbox.zshenv"
printf '%s\n' 'export ANTHROPIC_BASE_URL="http://start.example/v1"' \
  > "$STARTHOME/.zshenv"

export DUMPDIR MOCKDIR

# run <shell> <env assignments...> -- launches `claude --resume x` through the
# wrapper in a pristine subshell of the named shell, and leaves the child's
# environment in $DUMPDIR. The dump files are removed FIRST, so a test that
# fails to launch at all reads <UNSET>/<NO LAUNCH> rather than the previous
# test's leftovers — the exact staleness that let M5 and M7 survive.
#
# $RUN_HOME selects the home the launched shell sees; it defaults to $FAKEHOME
# (no startup file) and is switched to $STARTHOME for the R5 tests. Set it back
# after — a leaked $STARTHOME would silently hand every later test an inherited
# base URL.
RUN_HOME="$FAKEHOME"
run() {
  _sh=$1; shift
  rm -f "$DUMPDIR/hdrs" "$DUMPDIR/hdrs.od" "$DUMPDIR/base" "$DUMPDIR/args" \
        "$DUMPDIR/creds" "$DUMPDIR/leak" "$DUMPDIR/cfgdir" "$DUMPDIR/stderr"
  env -i \
    HOME="$RUN_HOME" PATH="$MOCKDIR:/usr/bin:/bin" DUMPDIR="$DUMPDIR" \
    "$@" \
    "$_sh" -c '. "$0"; claude --resume x' "$WRAPPER" 2> "$DUMPDIR/stderr"
}

# runargs — same as run(), but the launch's OWN argv is supplied by the caller.
# The failover consult reads `--model` out of it (the model-scoped allotment is
# a different ceiling from the unified ones), so a case that drives that arm
# cannot use run()'s fixed `--resume x`.
runargs() {
  _sh=$1; _cargs=$2; shift 2
  rm -f "$DUMPDIR/hdrs" "$DUMPDIR/hdrs.od" "$DUMPDIR/base" "$DUMPDIR/args" \
        "$DUMPDIR/creds" "$DUMPDIR/leak" "$DUMPDIR/cfgdir" "$DUMPDIR/stderr"
  env -i \
    HOME="$RUN_HOME" PATH="$MOCKDIR:/usr/bin:/bin" DUMPDIR="$DUMPDIR" \
    "$@" \
    "$_sh" -c ". \"\$0\"; claude $_cargs" "$WRAPPER" 2> "$DUMPDIR/stderr"
}
got_hdrs()  { [ -f "$DUMPDIR/hdrs" ]  && cat "$DUMPDIR/hdrs"  || printf '<UNSET>'; }
got_base()  { [ -f "$DUMPDIR/base" ]  && cat "$DUMPDIR/base"  || printf '<UNSET>'; }
got_args()  { [ -f "$DUMPDIR/args" ]  && cat "$DUMPDIR/args"  || printf '<NO LAUNCH>'; }
got_creds() { [ -f "$DUMPDIR/creds" ] && cat "$DUMPDIR/creds" || printf '<NO LAUNCH>'; }
got_cfgdir() { [ -f "$DUMPDIR/cfgdir" ] && cat "$DUMPDIR/cfgdir" || printf '<UNSET>'; }
got_stderr() { [ -f "$DUMPDIR/stderr" ] && cat "$DUMPDIR/stderr" || printf ''; }

check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}

# THE PER-LAUNCH CONTRACT. Called after EVERY run(), against THAT run's own
# dump — never a file some other test wrote. Two assertions, both fleet-critical
# and both branch-local:
#   argv    dropping --dangerously-skip-permissions prompts, and an unattended
#           pulse tick then hangs forever with nobody to answer.
#   creds   SUBSCRIPTION-SAFE: custom headers only, never a gateway credential.
ARGV_EXPECT='--dangerously-skip-permissions --resume x'
assert_launch() { # <label prefix>
  check "$1 argv (skip-permissions + \"\$@\")" "$ARGV_EXPECT" "$(got_args)"
  check "$1 no credential in the launched env" '' "$(got_creds)"
}

SH=${TEST_SHELL:-bash}
echo "test-claude-identity-wrapper (shell=$SH)"

# `four <address> <tap>` — the full epoch-2 header block, in emission order:
# the two LEGACY names pico's CEL reads today, then the two CANONICAL names
# carrying the same bytes for the eventual config-only rename.
four() { printf 'X-Session-Identity: %s\nX-Machine-Origin: %s\nX-Seat-Address: %s\nX-Tap: %s' "$1" "$2" "$1" "$2"; }

# $FAKEHOME has no agents tier, so agents_root() finds nothing, seat_resolve is
# unreachable, and every run below lands on the EXPLICIT not-a-seat form. That
# is deliberate: the degraded box must be visible in the data, never
# seat-shaped. T16–T18 install a fixture tier and drive the resolved forms.
BOTH=$(four 'testbox:?pulse' primary)

# T1 [case 1] tmux + hostname: all four headers, newline-separated, legacy first.
run "$SH" MOCK_HOST=testbox TMUX_PANE=%1 MOCK_SESS=work MOCK_WIN=pulse
check 'T1 [case 1] four headers, newline-separated' "$BOTH" "$(got_hdrs)"
assert_launch 'T1 [case 1]'

# T1a — the tmux SESSION is no longer an input. MOCK_SESS is deliberately `work`
# in T1 (the epoch-1 first field) and the address does not contain it: epoch 2
# reads the HOST, so the shared-session-name collision that made `group` exist
# in the first place cannot reach `user` at all.
case "$(got_hdrs)" in
  *work:*) fail 'T1a the tmux session name is NOT in the address' 'no "work:"' "$(got_hdrs)" ;;
  *)       pass 'T1a the tmux session name is NOT in the address' ;;
esac

# T1b — the separator is a REAL newline, byte-checked via `od -c` on the child's
# own env. Counted, not merely present: `printenv` appends one newline of its
# own, so a `grep -q '\n'` would pass against a comma-joined single line. Four
# headers -> exactly four \n bytes in the dump. R3.
odnl=$(grep -o '\\n' "$DUMPDIR/hdrs.od" 2>/dev/null | wc -l | tr -d ' ')
check 'T1b exactly three \n separators, byte-counted in od -c of the child env' \
  '4' "$odnl"
case "$(got_hdrs)" in
  *,*|*';'*) fail 'T1c no comma/semicolon separator' 'no , or ;' "$(got_hdrs)" ;;
  *)         pass 'T1c no comma/semicolon separator' ;;
esac

# T2 [case 1] NO tmux: still attributed. R2 — this case sent no header at all
# before dotfiles-v93v. The window is unknowable, so the address is the shortest
# explicit form, `<host>:?` — a host-only row, never a guessed seat.
run "$SH" MOCK_HOST=testbox
check 'T2 [case 1] no tmux -> host-only address, tap still known' \
  "$(four 'testbox:?' primary)" "$(got_hdrs)"
assert_launch 'T2 [case 1]'

# T3 [case 2] hostname fails, tmux present: the HOST field degrades to `?` and
# nothing else moves. This is the `elif [ -n "$_hdrs" ]` case — the one an
# unattended tick on a hostname-less box lives on, and the one M5/M7 survived on.
run "$SH" TMUX_PANE=%1 MOCK_SESS=work MOCK_WIN=pulse
check 'T3 [case 2] hostname fails -> ? in the host field, not a dropped header' \
  "$(four '?:?pulse' primary)" "$(got_hdrs)"
check 'T3 [case 2] no base URL' '<UNSET>' "$(got_base)"
assert_launch 'T3 [case 2]'

# T3b [case 2] glyph/whitespace sanitization of the window token is unchanged.
# The leading '-' is the real, pre-existing behavior and is pinned deliberately:
# the glyph becomes '-' via the whitespace squeeze, THEN tr -cd drops the glyph
# itself, leaving the separator behind. MOCK_SESS is still set and still absent
# from the output — epoch 2 never reads it.
# CAVEAT worth knowing: HOME is $FAKEHOME here, so agents_root() resolves
# nothing and the window comes from the FALLBACK `tmux display-message
# '#{window_name}'` path, not production's tmux_resolve_window.
# tmux-pane-resolve.sh has its own suite (test-tmux-pane-resolve.sh) and this
# diff does not touch it; noted rather than restructured for.
run "$SH" TMUX_PANE=%1 MOCK_SESS='wo rk' MOCK_WIN='✅ my pane'
check 'T3b [case 2] window token still sanitized' \
  "$(four '?:?-my-pane' primary)" "$(got_hdrs)"
assert_launch 'T3b [case 2]'

# --- reaching launch cases 3 and 4 in epoch 2 --------------------------------
# The tap is derivable from almost anything (unset CLAUDE_CONFIG_DIR means the
# vendor default, i.e. `primary`), so "no headers at all" is no longer reached
# by simply having no tmux and no hostname. `CLAUDE_CONFIG_DIR=/` is the one
# genuinely degenerate value — it has no basename to name a tap with — and it is
# what keeps cases 3, 4 and 4u driven. An untested launch branch is exactly how
# M5/M7 survived once already (R4), so this is not a contrivance to preserve a
# number; it is the branch staying covered.
NOTAP=/

# T4 [case 4] nothing resolvable at all: ANTHROPIC_CUSTOM_HEADERS is not set,
# no base URL — the bare `else` case. FAIL-OPEN.
run "$SH" CLAUDE_CONFIG_DIR="$NOTAP"
check 'T4 [case 4] nothing resolvable -> no header var at all' '<UNSET>' "$(got_hdrs)"
check 'T4 [case 4] no base URL' '<UNSET>' "$(got_base)"
assert_launch 'T4 [case 4]'

# T4a — the degenerate tap ALONE does not suppress the address: with a hostname
# present there is still something true to say. This is what stops `NOTAP` from
# becoming a blanket off-switch for attribution.
run "$SH" CLAUDE_CONFIG_DIR="$NOTAP" MOCK_HOST=testbox
check 'T4a [case 2] degenerate tap -> address headers only, no tap headers' \
  "$(printf 'X-Session-Identity: testbox:?\nX-Seat-Address: testbox:?')" "$(got_hdrs)"
assert_launch 'T4a [case 2]'

# T4b [case 3] base URL but NO header at all — the fourth launch case, which
# nothing else reaches. hostname fails AND no tmux AND no derivable tap AND an
# inherited base URL.
run "$SH" CLAUDE_CONFIG_DIR="$NOTAP" ANTHROPIC_BASE_URL=http://inherited.example/v1
check 'T4b [case 3] base URL alone, no headers' '<UNSET>' "$(got_hdrs)"
check 'T4b [case 3] inherited base URL passed through' \
  'http://inherited.example/v1' "$(got_base)"
assert_launch 'T4b [case 3]'

# T5 [case 1] inherited ANTHROPIC_BASE_URL: it WINS, and the machine header is
# still present. R1 — `_host` used to be computed only in the branch this skips.
run "$SH" MOCK_HOST=testbox TMUX_PANE=%1 MOCK_SESS=work MOCK_WIN=pulse \
    ANTHROPIC_BASE_URL=http://inherited.example/v1
check 'T5 [case 1] inherited base URL wins' 'http://inherited.example/v1' "$(got_base)"
check 'T5b [case 1] host still in the address with an inherited base URL (R1)' "$BOTH" "$(got_hdrs)"
assert_launch 'T5 [case 1]'

# T6 [case 2] CC_NO_GATEWAY=1 bypasses the per-host file; headers unaffected.
# Also `elif [ -n "$_hdrs" ]` — the M5/M7 branch.
# NOTE: this launches from a shell with NO inherited ANTHROPIC_BASE_URL, which
# is the ONE shape the hatch worked in before dotfiles-20rx. T9/T10/T11 cover
# the shape production actually has. Keep both.
run "$SH" MOCK_HOST=testbox TMUX_PANE=%1 MOCK_SESS=work MOCK_WIN=pulse CC_NO_GATEWAY=1
check 'T6 [case 2] CC_NO_GATEWAY=1 -> no base URL' '<UNSET>' "$(got_base)"
check 'T6b [case 2] CC_NO_GATEWAY=1 -> headers still sent' "$BOTH" "$(got_hdrs)"
assert_launch 'T6 [case 2]'

# T7 [case 1] per-host ~/.<host>.zshenv resolution (host name feeds the path).
run "$SH" MOCK_HOST=testbox TMUX_PANE=%1 MOCK_SESS=work MOCK_WIN=pulse
check 'T7 [case 1] base URL derived from per-host zshenv' \
  'http://127.0.0.1:17017/claude' "$(got_base)"
assert_launch 'T7 [case 1]'

# T8 — the per-host file is read in a SUBSHELL: its other exports (LEAK_CANARY,
# set beside ANTHROPIC_BASE_URL in the fixture zshenv) reach NEITHER the caller
# NOR the launched child. The child half is the one that matters for the
# subscription invariant: a real ~/.<host>.zshenv can hold anything.
rm -f "$DUMPDIR/leak"
leak=$(env -i HOME="$FAKEHOME" PATH="$MOCKDIR:/usr/bin:/bin" DUMPDIR="$DUMPDIR" \
       MOCK_HOST=testbox "$SH" -c '. "$0"; claude >/dev/null; printf "%s" "${LEAK_CANARY:-<none>}"' "$WRAPPER")
check 'T8 per-host exports do not leak into the caller' '<none>' "$leak"
check 'T8b per-host exports do not leak into the CHILD either' '<UNSET>' \
  "$([ -f "$DUMPDIR/leak" ] && cat "$DUMPDIR/leak" || printf '<UNSET>')"

# --- R5: the escape hatch in a shell that ALREADY exported the base URL ------
# dotfiles-20rx. Everything below runs out of $STARTHOME (see the fixture), so
# the shell the wrapper is sourced into starts with ANTHROPIC_BASE_URL already
# in its environment — the fleet's actual condition, and the one under which
# the hatch used to be unreachable.
RUN_HOME="$STARTHOME"

# T9pre — FIXTURE SANITY, and not optional: if the startup file ever stopped
# firing, T9 would pass for the wrong reason (nothing to override) and would
# guard nothing. Assert the precondition the way the bead reproduces it, from
# the shell's own environment, before asserting anything about the wrapper.
fresh=$(env -i HOME="$STARTHOME" PATH="$MOCKDIR:/usr/bin:/bin" \
        BASH_ENV="$STARTHOME/.zshenv" CC_NO_GATEWAY=1 \
        "$SH" -c 'printf "%s" "${ANTHROPIC_BASE_URL:-<unset>}"')
check 'T9pre fixture: a fresh shell exports ANTHROPIC_BASE_URL before the wrapper runs' \
  'http://start.example/v1' "$fresh"

# T9 [case 2u] THE REGRESSION. Fresh shell (base URL already exported) + armed
# hatch -> the gateway MUST be bypassed. Before the fix the inherited value was
# honored first and the hatch never ran: `_base` stayed set and every claude
# launched from any zsh on the fleet still went through the gateway, including
# the 503-on-compaction recovery the hatch exists for.
run "$SH" MOCK_HOST=testbox TMUX_PANE=%1 MOCK_SESS=work MOCK_WIN=pulse \
    CC_NO_GATEWAY=1 BASH_ENV="$STARTHOME/.zshenv"
check 'T9 [case 2u] armed hatch beats a shell-startup ANTHROPIC_BASE_URL (R5)' \
  '<UNSET>' "$(got_base)"
# Bypassing the gateway must not cost attribution: the headers are how a
# hatched request is still accounted for once it stops passing through pico.
check 'T9b [case 2u] hatched launch still sends both headers' "$BOTH" "$(got_hdrs)"
assert_launch 'T9 [case 2u]'

# T10 [case 1] THE OTHER HALF, and the reason the fix is an ordering change and
# not a deletion: with the hatch NOT armed, the inherited value still wins over
# the per-host file. $STARTHOME holds BOTH — .zshenv exports start.example and
# .testbox.zshenv exports 127.0.0.1:17017 — so the value proves which path ran.
run "$SH" MOCK_HOST=testbox TMUX_PANE=%1 MOCK_SESS=work MOCK_WIN=pulse \
    BASH_ENV="$STARTHOME/.zshenv"
check 'T10 [case 1] hatch NOT armed -> inherited value still beats the per-host file' \
  'http://start.example/v1' "$(got_base)"
assert_launch 'T10 [case 1]'

RUN_HOME="$FAKEHOME"

# T11 [case 2u] the same regression in its shell-independent form: the value is
# handed in explicitly rather than by a startup file. Worth having separately —
# it fails under bash too, so it does not depend on zsh being installed, and it
# pins the precedence rule itself rather than one shell's way of triggering it.
run "$SH" MOCK_HOST=testbox TMUX_PANE=%1 MOCK_SESS=work MOCK_WIN=pulse \
    CC_NO_GATEWAY=1 ANTHROPIC_BASE_URL=http://inherited.example/v1
check 'T11 [case 2u] armed hatch beats an explicitly inherited base URL (R5)' \
  '<UNSET>' "$(got_base)"
check 'T11b [case 2u] headers still sent' "$BOTH" "$(got_hdrs)"
assert_launch 'T11 [case 2u]'

# T12 [case 4u] the headerless half of the strip path — hostname fails AND no
# tmux AND no derivable tap AND an inherited base URL AND an armed hatch.
# Nothing else reaches the bare `env -u ... claude` branch, and an untested
# launch branch is exactly how M5/M7 survived once already (R4).
run "$SH" CLAUDE_CONFIG_DIR="$NOTAP" CC_NO_GATEWAY=1 ANTHROPIC_BASE_URL=http://inherited.example/v1
check 'T12 [case 4u] armed hatch strips inherited base URL with no headers at all' \
  '<UNSET>' "$(got_base)"
check 'T12b [case 4u] still no header var' '<UNSET>' "$(got_hdrs)"
assert_launch 'T12 [case 4u]'

# --- T13/T14 [dotfiles-tm0w]: agents_root() resolution is LOUD on failure,
# silent on success ----------------------------------------------------------
# The wrapper's load-time sourcing of tmux-pane-resolve.sh now goes through
# the shared agents_root() resolver (agents/lib/agents-root.sh) rather than a
# hardcoded $HOME/dotfiles path. Neither $FAKEHOME above IS this: it has no
# ~/.agents and no ~/dotfiles/agents, so every run() call already exercises
# the loud-failure path (visible as stderr noise throughout this suite's
# output) — but nothing until now ASSERTED it. These two cases pin both ends.

# T13: agents_root() unresolvable (bare, empty $HOME) -> a named, loud stderr
# note, not silence.
t13err=$(env -i HOME="$TMPROOT/t13-void" PATH="$MOCKDIR:/usr/bin:/bin" \
          "$SH" -c '. "$0"' "$WRAPPER" 2>&1 1>/dev/null)
case "$t13err" in
  *"tmux-pane-resolve.sh not found via agents_root()"*) pass 'T13 [dotfiles-tm0w] agents_root() unresolvable -> loud stderr note' ;;
  *) fail 'T13 [dotfiles-tm0w] agents_root() unresolvable -> loud stderr note' \
       '*tmux-pane-resolve.sh not found via agents_root()*' "$t13err" ;;
esac

# T14: the fallback candidate DOES resolve ($HOME/dotfiles/agents/lib/tmux-
# pane-resolve.sh present) -> silent, no warning at all.
T14HOME="$TMPROOT/t14-resolves"
mkdir -p "$T14HOME/dotfiles/agents/lib"
: > "$T14HOME/dotfiles/agents/lib/tmux-pane-resolve.sh"
t14err=$(env -i HOME="$T14HOME" PATH="$MOCKDIR:/usr/bin:/bin" \
          "$SH" -c '. "$0"' "$WRAPPER" 2>&1 1>/dev/null)
if [ -z "$t14err" ]; then
  pass 'T14 [dotfiles-tm0w] agents_root() resolves via $HOME/dotfiles fallback -> silent'
else
  fail 'T14 [dotfiles-tm0w] agents_root() resolves via $HOME/dotfiles fallback -> silent' \
    '<empty>' "$t14err"
fi

# --- T15 [dotfiles-jbnp]: the TAP is derived from CLAUDE_CONFIG_DIR ----------
# R7. `group` must say what this launch is ACTUALLY billing to, so the only
# input is the config dir in the launch's own environment — the same variable
# pulse-inject exports into the pane and tick-jailed.sh sets through bwrap.
# The unrecognised case gets a `?` for the same reason the address does: a dir
# that does not follow the `~/.claude-<tap>` convention is not a known tap, and
# silently naming it one would put fabricated rows in the billing rollup.
# ~/.claude-tick is the one deliberate exception (dotfiles-iez1): it is a jail
# PROFILE of `primary`, not a tap — ~/.claude and ~/.claude-tick carry the
# IDENTICAL account fingerprint (same Max subscription), so the config-dir
# convention's usual "strip claude-, that's the tap name" read would be
# billing-false here specifically.
#
# ⚠️ EPOCH 3, 2026-08-09 (dotfiles-kecb). The three expected VALUES moved with
# Zig's naming ruling: `personal` -> `primary`, `work` -> `linearb`, and
# ~/.claude-secondary joins as `secondary`. Two of the three are still derived
# by the plain "strip claude-, that's the tap" rule; `~/.claude-work ->
# linearb` is NOT — the directory name did not move, only the tap name did — so
# it is the one arm that needs its own case here and its own case in the
# wrapper. Getting it wrong is silent: `work` is a perfectly plausible tap name
# and the rollup would simply carry two names for one account forever.
tap_of() { printf '%s\n' "$1" | sed -n 's/^X-Tap: //p'; }

run "$SH" MOCK_HOST=testbox                                  # CLAUDE_CONFIG_DIR unset
check 'T15a unset CLAUDE_CONFIG_DIR -> primary (the vendor default ~/.claude)' \
  'primary' "$(tap_of "$(got_hdrs)")"
assert_launch 'T15a'

for _cd_case in "/home/x/.claude:primary" "/home/x/.claude-work:linearb" \
                "/home/x/.claude-tick:primary" "~/.claude-work:linearb" \
                "/home/x/.claude-work/:linearb" "/home/x/.claude-secondary:secondary" \
                "/home/x/nonsense:?nonsense"; do
  _cd=${_cd_case%:*}; _want=${_cd_case##*:}
  run "$SH" MOCK_HOST=testbox CLAUDE_CONFIG_DIR="$_cd"
  check "T15 tap derivation: $_cd -> $_want" "$_want" "$(tap_of "$(got_hdrs)")"
done

# T15z — the EPOCH-2 names must be GONE from what this wrapper emits. Not a
# restatement of the loop above: that loop asserts each arm's new value, this
# asserts the OLD value cannot come back through any arm, which is what a
# half-applied rename actually looks like (one `case` arm missed, everything
# else green).
for _cd in /home/x/.claude /home/x/.claude-work /home/x/.claude-tick; do
  run "$SH" MOCK_HOST=testbox CLAUDE_CONFIG_DIR="$_cd"
  case "$(tap_of "$(got_hdrs)")" in
    personal|work) fail "T15z $_cd emits no EPOCH-2 tap name" 'primary|linearb|secondary' "$(tap_of "$(got_hdrs)")" ;;
    *)             pass "T15z $_cd emits no EPOCH-2 tap name" ;;
  esac
done

# --- the fixture agents tier: seat resolution, without the live roster -------
# agents_root() accepts $HOME/.agents when it holds AGENTS.md, so a home with
# .agents/AGENTS.md + .agents/lib -> the REAL lib dir gives the wrapper a
# working seat_resolve. $SEATS_YML (seat-resolve.sh's documented test seam)
# points it at a fixture roster, so these cases never depend on who happens to
# hold a seat in the live agents/seats.yml.
#
# $SEAT_WINDOW (also documented, and what the tick jail already exports) is used
# instead of the mock tmux so that NO tmux call is involved at all: that is what
# makes T17 a proof about the RESOLVER rather than about the mock.
TIERHOME="$TMPROOT/tierhome"; mkdir -p "$TIERHOME/.agents"
: > "$TIERHOME/.agents/AGENTS.md"
ln -s "$DIR" "$TIERHOME/.agents/lib"
FIXROSTER="$TMPROOT/seats-fixture.yml"
cat > "$FIXROSTER" <<'EOF'
schema: 1
hosts: [testbox]
charter: null
taps:
  personal:
    type: claude
    config_dir: ~/.claude
    failover: []
seats:
  desk:
    charter-line: "fixture seat"
    office: "The Fixture"
    sigil: "🪑"
    home: ~/tmp
    model: fable
    effort: high
    aliases:
      - olddesk
    history: refs/seats/desk.history.md
    schedules: []
EOF

if command -v python3 >/dev/null 2>&1; then
  RUN_HOME="$TIERHOME"

  # T16 — a REGISTERED window resolves to <host>:<seat>. Post the one-session
  # ruling this string is byte-equal to what raw tmux would have produced, which
  # is exactly why T17 and T18 exist: this case alone cannot tell derived from
  # coincidental.
  run "$SH" MOCK_HOST=testbox SEATS_YML="$FIXROSTER" SEAT_WINDOW=desk
  check 'T16 [jbnp] registered window -> <host>:<seat>' \
    "$(four 'testbox:desk' primary)" "$(got_hdrs)"
  assert_launch 'T16'

  # T17 — THE PROOF THAT THE ADDRESS IS DERIVED (R6). The window is `olddesk`,
  # an ALIAS. Raw tmux says `olddesk`; the resolver says `desk`. A wrapper that
  # fell back to the raw name would pass T16 and fail only here — and in
  # production that fallback is invisible, because the two agree for every
  # window that happens to be named after its seat. Live analogue, same day:
  # window `di-monday` -> `zig-computer:linearb`.
  run "$SH" MOCK_HOST=testbox SEATS_YML="$FIXROSTER" SEAT_WINDOW=olddesk
  check 'T17 [jbnp] ALIAS window resolves to the CANONICAL seat, not the raw name' \
    "$(four 'testbox:desk' primary)" "$(got_hdrs)"
  assert_launch 'T17'

  # T18 — an UNREGISTERED window is marked, never seat-shaped. With a roster
  # present and readable, `ghost` is simply not a seat; the `?` is what makes
  # `agentgateway_user LIKE '%?%'` a usable unattributed-bucket query instead of
  # a value indistinguishable from a real seat.
  run "$SH" MOCK_HOST=testbox SEATS_YML="$FIXROSTER" SEAT_WINDOW=ghost
  check 'T18 [jbnp] unregistered window -> explicit <host>:?<window>' \
    "$(four 'testbox:?ghost' primary)" "$(got_hdrs)"
  assert_launch 'T18'

  RUN_HOME="$FAKEHOME"
else
  echo "  skip T16-T18 (no python3 — seat-resolve.sh cannot read a roster)"
fi

# --- T19 [dotfiles-jbnp]: derive, then ASSERT against the live roster --------
# _ciw_tap() is deliberately syntactic so a claude launch never depends on the
# roster parsing. The cost of that is a CONVENTION that could drift: a future
# tap whose config_dir is not `~/.claude-<name>` would be derived under the
# wrong name, silently, in the billing rollup. This closes it at test time —
# every `taps:` row in the REAL agents/seats.yml is fed to the wrapper and must
# come back as its own name.
#
# ⚠️ EPOCH 3 (dotfiles-kecb): "its own name" is now "its own name AFTER the
# rename". agents/seats.yml still carries the EPOCH-2 keys `personal` and
# `work`, because several consumers read those strings (marshal.conf's tap
# filter, pulse-inject's seat pinning) and the roster rename is a separate,
# sequenced change. `epoch3_of` is that rename, written down ONCE, in the one
# place that compares the two. It is deliberately an EXPLICIT MAP and not a
# "whatever the wrapper says" pass-through: the entire value of this case is
# that it fails when the roster gains a tap the wrapper derives differently, and
# a pass-through would make it agree with the wrapper by construction. When the
# roster is renamed, this map becomes three identities and can go.
epoch3_of() {
  case "$1" in
    personal) printf 'primary' ;;
    work)     printf 'linearb' ;;
    *)        printf '%s' "$1" ;;
  esac
}
LIVEROSTER="$DIR/../seats.yml"
if [ -f "$LIVEROSTER" ]; then
  _n=0
  # awk over the taps: block only. `intaps` rather than `in` — `in` is an awk
  # keyword. Ends at the next column-0 key.
  awk '
    /^taps:/ { intaps=1; next }
    intaps && /^[^ ]/ { intaps=0 }
    intaps && /^  [a-z][a-z0-9_-]*:[[:space:]]*$/ { name=$1; sub(/:$/, "", name); next }
    intaps && /^    config_dir:/ { print name "\t" $2 }
  ' "$LIVEROSTER" > "$TMPROOT/taps"
  while IFS='	' read -r _tapname _tapdir; do
    [ -n "$_tapname" ] && [ -n "$_tapdir" ] || continue
    _n=$((_n + 1))
    run "$SH" MOCK_HOST=testbox CLAUDE_CONFIG_DIR="$_tapdir"
    check "T19 roster tap '$_tapname' (config_dir $_tapdir) derives to its epoch-3 name" \
      "$(epoch3_of "$_tapname")" "$(tap_of "$(got_hdrs)")"
  done < "$TMPROOT/taps"
  if [ "$_n" -eq 0 ]; then
    fail 'T19 fixture: at least one taps: row was read from the live roster' \
      '>=1 tap' "0 (the awk extraction matched nothing — the roster shape moved)"
  else
    pass "T19 fixture: $_n taps: row(s) read from $LIVEROSTER"
  fi
else
  echo "  skip T19 (no live roster at $LIVEROSTER)"
fi

# ===========================================================================
# T20-T27 [dotfiles-kecb] — THE TAP-FAILOVER CONSULT AT THE LAUNCH SEAM
# ===========================================================================
# Everything below is hermetic: a fixture taps.conf, a fixture $HOME holding
# three config dirs with fixture credentials, and a stub `curl` that answers
# the usage endpoint by looking at which token it was handed. No network, no
# ssh, no real account.
#
# The regressions these guard, each of which passes a source read:
#   R8  a rollover that changes the config dir but not the headers (or the
#       headers but not the config dir) — the request then announces a tap it
#       is not running on, which is the exact 19:23Z defect with the tap
#       system's own machinery.  (T20)
#   R9  a rollover that happens SILENTLY — right tap, no X-Home-Tap, no ledger
#       row, no stderr line. Byte-identical downstream to a launch whose home
#       tap was always that pool, so nothing could ever count them.  (T20b-d)
#   R10 rolling over on data nobody could read. An unmeasurable pool is not a
#       pool with headroom, and an unmeasurable HOME is not a reason to
#       leave.  (T21, T21b)
#   R11 the per-seat home-tap override ignored, so a LinearB seat's overflow
#       silently lands on Zig's personal subscription while LinearB's sits
#       idle.  (T22)
#   R12 the model-scoped (Fable) allotment ignored — the unified windows have
#       headroom, the Fable weekly does not, and the launch stalls anyway
#       because nothing consulted the one dimension that was full.  (T23,
#       T23b)
#   R13 an INHERITED attribution header passed through to a launch this
#       wrapper declined to attribute, so an ambient `X-Tap` from a parent
#       session speaks for a process it knows nothing about.  (T25)
TAPCONF="$TMPROOT/taps.conf"
TAPHOME="$TMPROOT/taphome"
mkdir -p "$TAPHOME/.claude" "$TAPHOME/.claude-secondary" "$TAPHOME/.claude-work"

# A fixture credential per pool. The `accessToken` is a MARKER, not a secret:
# the stub curl below routes on it, which is how one stub serves three pools.
# expiresAt is far in the future so the expiry refusal does not fire here (T24
# drives that arm on purpose).
for _p in claude:PRIMARY claude-secondary:SECONDARY claude-work:LINEARB; do
  printf '{"claudeAiOauth":{"accessToken":"FIXTURE-%s","expiresAt":99999999999999}}\n' \
    "${_p##*:}" > "$TAPHOME/.${_p%%:*}/.credentials.json"
done

cat > "$TAPCONF" <<'EOF'
order=primary,secondary,linearb
pool.primary.taps=primary,tick
pool.primary.config_dir=~/.claude
pool.primary.groups=primary,personal
pool.secondary.taps=secondary
pool.secondary.config_dir=~/.claude-secondary
pool.secondary.groups=secondary
pool.linearb.taps=linearb
pool.linearb.config_dir=~/.claude-work
pool.linearb.groups=linearb,work
seat_home.desk=linearb
ceiling=1.0
fable_scope=Fable
fable_models=fable
fable_ceiling=1.0
cache_ttl_seconds=120
timeout_seconds=4
EOF

# The stub curl. $STUB_<POOL> names the response shape each pool answers with;
# unset means "this pool answers nothing", i.e. unmeasurable. The `-w
# %{http_code}` contract of the real call is reproduced exactly, because the
# reader parses the body and the code out of one stream.
cat > "$MOCKDIR/curl" <<'EOF'
#!/bin/sh
who=UNKNOWN
for a in "$@"; do
  case "$a" in
    *FIXTURE-PRIMARY*)   who=PRIMARY ;;
    *FIXTURE-SECONDARY*) who=SECONDARY ;;
    *FIXTURE-LINEARB*)   who=LINEARB ;;
  esac
done
eval "shape=\${STUB_$who:-}"
case "$shape" in
  "")     printf 'network unreachable\n' >&2; exit 7 ;;
  http401) printf '{"type":"error"}\n401'; exit 0 ;;
  *)
    # shape is `<5h>,<7d>,<fable>` in PERCENT, matching the real document.
    f5=${shape%%,*}; rest=${shape#*,}; f7=${rest%%,*}; ff=${rest#*,}
    printf '{"limits":[{"kind":"session","percent":%s},{"kind":"weekly_all","percent":%s},{"kind":"weekly_scoped","percent":%s,"scope":{"model":{"display_name":"Fable"}}}]}\n200' "$f5" "$f7" "$ff"
    exit 0 ;;
esac
EOF
chmod +x "$MOCKDIR/curl"

# Every consult case below carries the same five env assignments: the fixture
# conf, the fixture home for `~` expansion, the oauth arm only (the gateway arm
# would need ssh), no cache (a cache would make case N depend on case N-1), and
# a fixture ledger path.
#
# They are written out LITERALLY at every call site rather than held in one
# $FAILENV variable, and that is not verbosity — it is the zsh word-splitting
# trap. `run "$SH" $FAILENV …` splits into five arguments under bash and stays
# ONE argument under zsh (zsh performs no field splitting on parameter
# expansions), so `env` would set a single variable whose name is
# TAP_HEADROOM_CONF and whose value is the whole line: no conf, no consult,
# every rollover case silently passing under bash and failing under zsh.
# Measured here, exactly that way, before this comment existed.

if command -v python3 >/dev/null 2>&1; then
  RUN_HOME="$TIERHOME"
  hdr_of() { printf '%s\n' "$2" | sed -n "s/^$1: //p"; }

  # T20 — THE ROLLOVER. primary is AT its ceiling (100%), secondary is empty.
  # Four assertions, because four separate things have to move together and
  # any three of them without the fourth is a defect: the launched process's
  # CONFIG DIR, the `X-Tap` header, the explicit rollover pair, and the
  # durable ledger row.
  rm -f "$TMPROOT/rollover.jsonl"
  run "$SH" MOCK_HOST=testbox SEATS_YML="$FIXROSTER" SEAT_WINDOW=ghost \
      CLAUDE_CONFIG_DIR="$TAPHOME/.claude" TAP_HEADROOM_CONF="$TAPCONF" TAP_HEADROOM_HOME="$TAPHOME" TAP_HEADROOM_SOURCE=oauth TAP_HEADROOM_NO_CACHE=1 CIW_ROLLOVER_LEDGER="$TMPROOT/rollover.jsonl" \
      STUB_PRIMARY=100,50,50 STUB_SECONDARY=0,0,0
  check 'T20 rollover: the LAUNCHED process gets the new pool config dir' \
    "$TAPHOME/.claude-secondary" "$(got_cfgdir)"
  check 'T20b rollover: X-Tap carries the tap that RAN, not the home tap' \
    'secondary' "$(tap_of "$(got_hdrs)")"
  check 'T20c rollover: X-Home-Tap names the tap it came from' \
    'primary' "$(hdr_of X-Home-Tap "$(got_hdrs)")"
  check 'T20c2 rollover: X-Tap-Rollover marks the row' \
    '1' "$(hdr_of X-Tap-Rollover "$(got_hdrs)")"
  case "$(got_stderr)" in
    *"TAP ROLLOVER"*) pass 'T20d rollover: one loud sentence on stderr' ;;
    *) fail 'T20d rollover: one loud sentence on stderr' '*TAP ROLLOVER*' "$(got_stderr)" ;;
  esac
  if grep -q '"home_tap":"primary","used_tap":"secondary"' "$TMPROOT/rollover.jsonl" 2>/dev/null; then
    pass 'T20e rollover: a ledger row carrying home_tap != used_tap'
  else
    fail 'T20e rollover: a ledger row carrying home_tap != used_tap' \
      '"home_tap":"primary","used_tap":"secondary"' \
      "$([ -f "$TMPROOT/rollover.jsonl" ] && cat "$TMPROOT/rollover.jsonl" || printf '<no ledger file>')"
  fi
  assert_launch 'T20'

  # T20f — THE NON-ROLLOVER, and it is not a formality: it is what stops every
  # assertion above from being satisfied by a wrapper that rolls over
  # unconditionally. Home has headroom -> home, no rollover headers at all, no
  # ledger row, no stderr sentence.
  rm -f "$TMPROOT/rollover.jsonl"
  run "$SH" MOCK_HOST=testbox SEATS_YML="$FIXROSTER" SEAT_WINDOW=ghost \
      CLAUDE_CONFIG_DIR="$TAPHOME/.claude" TAP_HEADROOM_CONF="$TAPCONF" TAP_HEADROOM_HOME="$TAPHOME" TAP_HEADROOM_SOURCE=oauth TAP_HEADROOM_NO_CACHE=1 CIW_ROLLOVER_LEDGER="$TMPROOT/rollover.jsonl" \
      STUB_PRIMARY=50,50,50 STUB_SECONDARY=0,0,0
  check 'T20f home has headroom -> X-Tap stays primary' 'primary' "$(tap_of "$(got_hdrs)")"
  check 'T20g home has headroom -> NO X-Home-Tap header' '' "$(hdr_of X-Home-Tap "$(got_hdrs)")"
  check 'T20h home has headroom -> NO ledger row' '<no ledger file>' \
    "$([ -f "$TMPROOT/rollover.jsonl" ] && cat "$TMPROOT/rollover.jsonl" || printf '<no ledger file>')"
  assert_launch 'T20f'

  # T21 — R10, direction one: the home pool is at its ceiling and NOTHING else
  # can be measured. Staying home is the ruled answer — a stalled launch on the
  # right account is recoverable (dotfiles-yrsg waits out the reset); a silently
  # cross-billed one is not.
  run "$SH" MOCK_HOST=testbox SEATS_YML="$FIXROSTER" SEAT_WINDOW=ghost \
      CLAUDE_CONFIG_DIR="$TAPHOME/.claude" TAP_HEADROOM_CONF="$TAPCONF" TAP_HEADROOM_HOME="$TAPHOME" TAP_HEADROOM_SOURCE=oauth TAP_HEADROOM_NO_CACHE=1 CIW_ROLLOVER_LEDGER="$TMPROOT/rollover.jsonl" STUB_PRIMARY=100,50,50
  check 'T21 [R10] home at ceiling + no candidate measurable -> stays home' \
    'primary' "$(tap_of "$(got_hdrs)")"
  check 'T21a and does NOT claim a rollover' '' "$(hdr_of X-Tap-Rollover "$(got_hdrs)")"

  # T21b — R10, direction two: the home pool cannot be measured AT ALL. An
  # unreadable home is not evidence that it is full, so nothing moves — and
  # this is the case a "ceiling or unknown -> roll" shortcut gets wrong on
  # every network blip.
  run "$SH" MOCK_HOST=testbox SEATS_YML="$FIXROSTER" SEAT_WINDOW=ghost \
      CLAUDE_CONFIG_DIR="$TAPHOME/.claude" TAP_HEADROOM_CONF="$TAPCONF" TAP_HEADROOM_HOME="$TAPHOME" TAP_HEADROOM_SOURCE=oauth TAP_HEADROOM_NO_CACHE=1 CIW_ROLLOVER_LEDGER="$TMPROOT/rollover.jsonl" STUB_SECONDARY=0,0,0
  check 'T21b [R10] home UNMEASURABLE -> stays home, never rolls on ignorance' \
    'primary' "$(tap_of "$(got_hdrs)")"
  check 'T21c and does NOT claim a rollover' '' "$(hdr_of X-Tap-Rollover "$(got_hdrs)")"

  # T22 — R11, the per-seat home-tap override. Window `desk` is a registered
  # seat and the fixture conf gives it seat_home.desk=linearb. primary is full;
  # BOTH secondary and linearb have headroom, and the GLOBAL order would pick
  # secondary. The override is the only thing that makes linearb win, so this
  # case cannot pass by accident.
  run "$SH" MOCK_HOST=testbox SEATS_YML="$FIXROSTER" SEAT_WINDOW=desk \
      CLAUDE_CONFIG_DIR="$TAPHOME/.claude" TAP_HEADROOM_CONF="$TAPCONF" TAP_HEADROOM_HOME="$TAPHOME" TAP_HEADROOM_SOURCE=oauth TAP_HEADROOM_NO_CACHE=1 CIW_ROLLOVER_LEDGER="$TMPROOT/rollover.jsonl" \
      STUB_PRIMARY=100,50,50 STUB_SECONDARY=0,0,0 STUB_LINEARB=0,0,0
  check 'T22 [R11] the seat override orders the candidates behind home' \
    'linearb' "$(tap_of "$(got_hdrs)")"
  check 'T22b and the launched config dir moved with it' \
    "$TAPHOME/.claude-work" "$(got_cfgdir)"

  # T22c — the same launch from an UNREGISTERED window takes the global order
  # instead. Without this, T22 would also pass against a wrapper that simply
  # preferred linearb always.
  run "$SH" MOCK_HOST=testbox SEATS_YML="$FIXROSTER" SEAT_WINDOW=ghost \
      CLAUDE_CONFIG_DIR="$TAPHOME/.claude" TAP_HEADROOM_CONF="$TAPCONF" TAP_HEADROOM_HOME="$TAPHOME" TAP_HEADROOM_SOURCE=oauth TAP_HEADROOM_NO_CACHE=1 CIW_ROLLOVER_LEDGER="$TMPROOT/rollover.jsonl" \
      STUB_PRIMARY=100,50,50 STUB_SECONDARY=0,0,0 STUB_LINEARB=0,0,0
  check 'T22c no override -> the global order (secondary before linearb)' \
    'secondary' "$(tap_of "$(got_hdrs)")"

  # T23 — R12, the FABLE dimension. Every unified window has room (50%/50%);
  # only the model-scoped weekly allotment is exhausted, and the launch names
  # `--model fable`. Nothing in the gateway's captured attributes can see this
  # — it is the whole reason the OAuth usage document had to be found.
  runargs "$SH" '--model fable -p hi' MOCK_HOST=testbox SEATS_YML="$FIXROSTER" \
      SEAT_WINDOW=ghost CLAUDE_CONFIG_DIR="$TAPHOME/.claude" TAP_HEADROOM_CONF="$TAPCONF" TAP_HEADROOM_HOME="$TAPHOME" TAP_HEADROOM_SOURCE=oauth TAP_HEADROOM_NO_CACHE=1 CIW_ROLLOVER_LEDGER="$TMPROOT/rollover.jsonl" \
      STUB_PRIMARY=50,50,100 STUB_SECONDARY=0,0,0
  check 'T23 [R12] fable allotment exhausted on a --model fable launch -> rollover' \
    'secondary' "$(tap_of "$(got_hdrs)")"

  # T23b — THE CONTROL, and it is what makes T23 mean anything: the identical
  # pool state with a launch that does NOT name fable stays home. A wrapper
  # that consulted the fable arm unconditionally would pass T23 and fail here,
  # and it would drain the reserve pool for every opus tick on the fleet.
  runargs "$SH" '--model opus-5 -p hi' MOCK_HOST=testbox SEATS_YML="$FIXROSTER" \
      SEAT_WINDOW=ghost CLAUDE_CONFIG_DIR="$TAPHOME/.claude" TAP_HEADROOM_CONF="$TAPCONF" TAP_HEADROOM_HOME="$TAPHOME" TAP_HEADROOM_SOURCE=oauth TAP_HEADROOM_NO_CACHE=1 CIW_ROLLOVER_LEDGER="$TMPROOT/rollover.jsonl" \
      STUB_PRIMARY=50,50,100 STUB_SECONDARY=0,0,0
  check 'T23b [R12] the SAME pool state, a non-fable launch -> stays home' \
    'primary' "$(tap_of "$(got_hdrs)")"

  # T24 — an EXPIRED credential answers 401, and 401 must never read as
  # headroom. Real shape: pool linearb's access token was expired on
  # 2026-08-09 and the live endpoint answered
  # `{"type":"error","error":{"type":"authentication_error"}}`. Here primary is
  # full and secondary's token 401s, so a reader that scored a failed read as
  # "0% used" would roll straight into an account it cannot even authenticate
  # to. The right answer is to stay home.
  run "$SH" MOCK_HOST=testbox SEATS_YML="$FIXROSTER" SEAT_WINDOW=ghost \
      CLAUDE_CONFIG_DIR="$TAPHOME/.claude" TAP_HEADROOM_CONF="$TAPCONF" TAP_HEADROOM_HOME="$TAPHOME" TAP_HEADROOM_SOURCE=oauth TAP_HEADROOM_NO_CACHE=1 CIW_ROLLOVER_LEDGER="$TMPROOT/rollover.jsonl" \
      STUB_PRIMARY=100,50,50 STUB_SECONDARY=http401
  check 'T24 a 401 candidate is UNAVAILABLE, not empty -> stays home' \
    'primary' "$(tap_of "$(got_hdrs)")"

  # T24b — the consult can be switched off entirely, and then it costs
  # nothing and changes nothing. This is the escape hatch a fleet-wide launch
  # path has to have.
  run "$SH" MOCK_HOST=testbox SEATS_YML="$FIXROSTER" SEAT_WINDOW=ghost \
      CLAUDE_CONFIG_DIR="$TAPHOME/.claude" TAP_HEADROOM_CONF="$TAPCONF" TAP_HEADROOM_HOME="$TAPHOME" TAP_HEADROOM_SOURCE=oauth TAP_HEADROOM_NO_CACHE=1 CIW_ROLLOVER_LEDGER="$TMPROOT/rollover.jsonl" CIW_TAP_FAILOVER=off \
      STUB_PRIMARY=100,50,50 STUB_SECONDARY=0,0,0
  check 'T24b CIW_TAP_FAILOVER=off -> no consult, no rollover' \
    'primary' "$(tap_of "$(got_hdrs)")"

  RUN_HOME="$FAKEHOME"
  rm -f "$MOCKDIR/curl"
else
  echo "  skip T20-T24 (no python3 — the headroom reader cannot parse a usage document)"
fi

# --- T25 [dotfiles-kecb]: AN INHERITED ATTRIBUTION HEADER IS NEVER PASSED ON -
# R13, and the measured half of the 19:23Z defect that this wrapper CAN reach.
# `claude` exports ANTHROPIC_CUSTOM_HEADERS to its own children, so a Bash-tool
# shell inside a session starts life carrying its parent's `X-Tap`. When this
# wrapper declines to attribute a launch at all it must REMOVE that ambient
# value, not let it through: a request with no header logs as `unknown` and is
# visibly unattributed; one carrying somebody else's header is confidently
# wrong. Cases 4s (nothing resolvable), 3s (base URL only) and 4us (hatch
# armed) are the three that decline.
STALE='X-Session-Identity: other:seat
X-Machine-Origin: primary
X-Seat-Address: other:seat
X-Tap: primary'

run "$SH" CLAUDE_CONFIG_DIR="$NOTAP" ANTHROPIC_CUSTOM_HEADERS="$STALE"
check 'T25 [case 4s] no derivable header -> the INHERITED one is stripped' \
  '<UNSET>' "$(got_hdrs)"
assert_launch 'T25 [case 4s]'

run "$SH" CLAUDE_CONFIG_DIR="$NOTAP" ANTHROPIC_CUSTOM_HEADERS="$STALE" \
    ANTHROPIC_BASE_URL=http://inherited.example/v1
check 'T25b [case 3s] base URL only -> the INHERITED header is still stripped' \
  '<UNSET>' "$(got_hdrs)"
check 'T25b2 [case 3s] and the base URL still passes through' \
  'http://inherited.example/v1' "$(got_base)"
assert_launch 'T25b [case 3s]'

run "$SH" CLAUDE_CONFIG_DIR="$NOTAP" ANTHROPIC_CUSTOM_HEADERS="$STALE" \
    CC_NO_GATEWAY=1 ANTHROPIC_BASE_URL=http://inherited.example/v1
check 'T25c [case 4us] armed hatch -> both inherited values stripped' \
  '<UNSET>' "$(got_hdrs)"
check 'T25c2 [case 4us] base URL stripped too' '<UNSET>' "$(got_base)"
assert_launch 'T25c [case 4us]'

# T25d — the OTHER direction: when the wrapper DOES have something to say, its
# own block replaces the inherited one rather than merging with it.
run "$SH" MOCK_HOST=testbox ANTHROPIC_CUSTOM_HEADERS="$STALE"
check 'T25d a derivable launch replaces the inherited block outright' \
  "$(four 'testbox:?' primary)" "$(got_hdrs)"

# --- T26 [dotfiles-kecb]: the zsh/.zshenv strip, AS COMMITTED ---------------
# The remaining bypass is `env … claude`, which invokes the BINARY and never
# reaches this wrapper at all (a shell function is not inherited by `env`).
# That path is closed one tier down, in zsh/.zshenv, and this repo's rule 2
# says a documented mechanism is executable: the block is EXTRACTED FROM THE
# COMMITTED FILE by line range and those bytes are run, never a retyped copy.
ZSHENV="$DIR/../../zsh/.zshenv"
if [ -f "$ZSHENV" ]; then
  awk '/^case "\$\{ANTHROPIC_CUSTOM_HEADERS-\}" in$/,/^esac$/' "$ZSHENV" > "$TMPROOT/strip.sh"
  if [ -s "$TMPROOT/strip.sh" ]; then
    pass 'T26 fixture: the strip block was extracted from the committed zsh/.zshenv'
    _t26=$(env -i PATH=/usr/bin:/bin ANTHROPIC_CUSTOM_HEADERS="$STALE" \
      "$SH" -c '. "$0"; printf "%s" "${ANTHROPIC_CUSTOM_HEADERS-<UNSET>}"' "$TMPROOT/strip.sh")
    check 'T26 the committed block DROPS an inherited wrapper-shaped header' \
      '<UNSET>' "$_t26"
    _t26b=$(env -i PATH=/usr/bin:/bin ANTHROPIC_CUSTOM_HEADERS='X-Something-Else: mine' \
      "$SH" -c '. "$0"; printf "%s" "${ANTHROPIC_CUSTOM_HEADERS-<UNSET>}"' "$TMPROOT/strip.sh")
    check 'T26b it leaves a header block that is NOT ours alone' \
      'X-Something-Else: mine' "$_t26b"
    _t26c=$(env -i PATH=/usr/bin:/bin \
      "$SH" -c '. "$0"; printf "%s" "${ANTHROPIC_CUSTOM_HEADERS-<UNSET>}"' "$TMPROOT/strip.sh")
    check 'T26c and it is a no-op when nothing was inherited' '<UNSET>' "$_t26c"
  else
    fail 'T26 fixture: the strip block was extracted from the committed zsh/.zshenv' \
      'a non-empty case…esac block' '<nothing matched — the block moved or was renamed>'
  fi
else
  echo "  skip T26 (no zsh/.zshenv at $ZSHENV)"
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS ($SH)"; else echo "$FAILS FAILURE(S) ($SH)"; fi

# Run the whole matrix under zsh too, from the bash invocation, because the
# wrapper is sourced by BOTH shells and the pre-commit gate only calls `bash`.
if [ -z "${TEST_SHELL:-}" ] && command -v zsh >/dev/null 2>&1; then
  echo
  TEST_SHELL=zsh zsh "$0" || FAILS=$((FAILS+1))
fi

[ "$FAILS" -eq 0 ]
