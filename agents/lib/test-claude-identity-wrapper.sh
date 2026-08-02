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
#
# Everything is asserted against `printenv` inside the child, so a change that
# builds the right string but fails to EXPORT it still fails here.
#
# THE FOUR LAUNCH CASES AND WHO DRIVES THEM (keep this current):
#   case 1  _hdrs && _base   T1  T2  T5  T7
#   case 2  _hdrs only       T3  T3b T6      <- the marketing-vps shape
#   case 3  _base only       T4b
#   case 4  neither          T4

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

export DUMPDIR MOCKDIR

# run <shell> <env assignments...> -- launches `claude --resume x` through the
# wrapper in a pristine subshell of the named shell, and leaves the child's
# environment in $DUMPDIR. The dump files are removed FIRST, so a test that
# fails to launch at all reads <UNSET>/<NO LAUNCH> rather than the previous
# test's leftovers — the exact staleness that let M5 and M7 survive.
run() {
  _sh=$1; shift
  rm -f "$DUMPDIR/hdrs" "$DUMPDIR/hdrs.od" "$DUMPDIR/base" "$DUMPDIR/args" \
        "$DUMPDIR/creds" "$DUMPDIR/leak"
  env -i \
    HOME="$FAKEHOME" PATH="$MOCKDIR:/usr/bin:/bin" DUMPDIR="$DUMPDIR" \
    "$@" \
    "$_sh" -c '. "$0"; claude --resume x' "$WRAPPER"
}
got_hdrs()  { [ -f "$DUMPDIR/hdrs" ]  && cat "$DUMPDIR/hdrs"  || printf '<UNSET>'; }
got_base()  { [ -f "$DUMPDIR/base" ]  && cat "$DUMPDIR/base"  || printf '<UNSET>'; }
got_args()  { [ -f "$DUMPDIR/args" ]  && cat "$DUMPDIR/args"  || printf '<NO LAUNCH>'; }
got_creds() { [ -f "$DUMPDIR/creds" ] && cat "$DUMPDIR/creds" || printf '<NO LAUNCH>'; }

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

BOTH=$(printf 'X-Session-Identity: work:pulse\nX-Machine-Origin: testbox')

# T1 [case 1] tmux + hostname: BOTH headers, newline-separated, session first.
run "$SH" MOCK_HOST=testbox TMUX_PANE=%1 MOCK_SESS=work MOCK_WIN=pulse
check 'T1 [case 1] both headers, newline-separated' "$BOTH" "$(got_hdrs)"
assert_launch 'T1 [case 1]'

# T1b — the separator is a REAL newline, byte-checked via `od -c` on the child's
# own env. Counted, not merely present: `printenv` appends one newline of its
# own, so a `grep -q '\n'` would pass against a comma-joined single line. Two
# headers -> exactly two \n bytes in the dump. R3.
odnl=$(grep -o '\\n' "$DUMPDIR/hdrs.od" 2>/dev/null | wc -l | tr -d ' ')
check 'T1b exactly one \n separator, byte-counted in od -c of the child env' \
  '2' "$odnl"
case "$(got_hdrs)" in
  *,*|*';'*) fail 'T1c no comma/semicolon separator' 'no , or ;' "$(got_hdrs)" ;;
  *)         pass 'T1c no comma/semicolon separator' ;;
esac

# T2 [case 1] NO tmux: the machine header is still emitted. R2 — this case sent
# no header at all before dotfiles-v93v.
run "$SH" MOCK_HOST=testbox
check 'T2 [case 1] no tmux -> machine header alone' 'X-Machine-Origin: testbox' "$(got_hdrs)"
assert_launch 'T2 [case 1]'

# T3 [case 2] hostname fails, tmux present: the session header survives untouched
# and is BYTE-IDENTICAL to the pre-change format (pico's `user` column + its
# 78,956 rows of history). This is the `elif [ -n "$_hdrs" ]` case — the one
# marketing-vps will live on, and the one M5/M7 survived on.
run "$SH" TMUX_PANE=%1 MOCK_SESS=work MOCK_WIN=pulse
check 'T3 [case 2] hostname fails -> session header alone, unchanged format' \
  'X-Session-Identity: work:pulse' "$(got_hdrs)"
check 'T3 [case 2] no base URL' '<UNSET>' "$(got_base)"
assert_launch 'T3 [case 2]'

# T3b [case 2] glyph/whitespace sanitization of the session token is unchanged.
# The leading '-' is the real, pre-existing behavior and is pinned deliberately:
# the glyph becomes '-' via the whitespace squeeze, THEN tr -cd drops the glyph
# itself, leaving the separator behind.
# CAVEAT worth knowing: HOME is $FAKEHOME here, so the wrapper's load-time
# `. $HOME/dotfiles/agents/lib/tmux-pane-resolve.sh` finds nothing and the window
# comes from the FALLBACK `tmux display-message '#{window_name}'` path, not
# production's tmux_resolve_window. So "byte-identical" is proven against the
# fallback. tmux-pane-resolve.sh has its own suite (test-tmux-pane-resolve.sh)
# and this diff does not touch it; noted rather than restructured for.
run "$SH" TMUX_PANE=%1 MOCK_SESS='wo rk' MOCK_WIN='✅ my pane'
check 'T3b [case 2] session token still sanitized' \
  'X-Session-Identity: wo-rk:-my-pane' "$(got_hdrs)"
assert_launch 'T3b [case 2]'

# T4 [case 4] nothing resolvable at all: ANTHROPIC_CUSTOM_HEADERS is not set,
# no base URL — the bare `else` case. FAIL-OPEN.
run "$SH"
check 'T4 [case 4] nothing resolvable -> no header var at all' '<UNSET>' "$(got_hdrs)"
check 'T4 [case 4] no base URL' '<UNSET>' "$(got_base)"
assert_launch 'T4 [case 4]'

# T4b [case 3] base URL but NO header at all — the fourth launch case, which
# nothing else reaches. hostname fails AND no tmux AND an inherited base URL.
run "$SH" ANTHROPIC_BASE_URL=http://inherited.example/v1
check 'T4b [case 3] base URL alone, no headers' '<UNSET>' "$(got_hdrs)"
check 'T4b [case 3] inherited base URL passed through' \
  'http://inherited.example/v1' "$(got_base)"
assert_launch 'T4b [case 3]'

# T5 [case 1] inherited ANTHROPIC_BASE_URL: it WINS, and the machine header is
# still present. R1 — `_host` used to be computed only in the branch this skips.
run "$SH" MOCK_HOST=testbox TMUX_PANE=%1 MOCK_SESS=work MOCK_WIN=pulse \
    ANTHROPIC_BASE_URL=http://inherited.example/v1
check 'T5 [case 1] inherited base URL wins' 'http://inherited.example/v1' "$(got_base)"
check 'T5b [case 1] machine header present with inherited base URL (R1)' "$BOTH" "$(got_hdrs)"
assert_launch 'T5 [case 1]'

# T6 [case 2] CC_NO_GATEWAY=1 bypasses the per-host file; headers unaffected.
# Also `elif [ -n "$_hdrs" ]` — the M5/M7 branch.
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

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS ($SH)"; else echo "$FAILS FAILURE(S) ($SH)"; fi

# Run the whole matrix under zsh too, from the bash invocation, because the
# wrapper is sourced by BOTH shells and the pre-commit gate only calls `bash`.
if [ -z "${TEST_SHELL:-}" ] && command -v zsh >/dev/null 2>&1; then
  echo
  TEST_SHELL=zsh zsh "$0" || FAILS=$((FAILS+1))
fi

[ "$FAILS" -eq 0 ]
