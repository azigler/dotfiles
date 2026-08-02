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
# The three regressions this guards, each of which passes a source read:
#   R1  `_host` computed only inside `if [ -z "$_base" ]` -> the machine header
#       vanishes in exactly the case where ANTHROPIC_BASE_URL was already
#       exported, i.e. every freshly-started shell.  (T5)
#   R2  the machine header emitted only inside the tmux branch -> jailed and
#       non-interactive ticks stay machine-unattributed, which is most of the
#       point.  (T2)
#   R3  the two headers joined with `, ` or `; ` instead of a NEWLINE.
#       ANTHROPIC_CUSTOM_HEADERS is newline-separated (first-party env-vars
#       docs); a comma yields one malformed header name.  (T1, byte-checked)
#
# Everything is asserted against `printenv` inside the child, so a change that
# builds the right string but fails to EXPORT it still fails here.

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
cat > "$MOCKDIR/claude" <<'EOF'
#!/bin/sh
rm -f "$DUMPDIR/hdrs" "$DUMPDIR/hdrs.od" "$DUMPDIR/base"
printf '%s\n' "$*" > "$DUMPDIR/args"
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
# environment in $DUMPDIR.
run() {
  _sh=$1; shift
  rm -f "$DUMPDIR/hdrs" "$DUMPDIR/hdrs.od" "$DUMPDIR/base" "$DUMPDIR/args"
  env -i \
    HOME="$FAKEHOME" PATH="$MOCKDIR:/usr/bin:/bin" DUMPDIR="$DUMPDIR" \
    "$@" \
    "$_sh" -c '. "$0"; claude --resume x' "$WRAPPER"
}
got_hdrs() { [ -f "$DUMPDIR/hdrs" ] && cat "$DUMPDIR/hdrs" || printf '<UNSET>'; }
got_base()  { [ -f "$DUMPDIR/base" ] && cat "$DUMPDIR/base" || printf '<UNSET>'; }

check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}

SH=${TEST_SHELL:-bash}
echo "test-claude-identity-wrapper (shell=$SH)"

BOTH=$(printf 'X-Session-Identity: work:pulse\nX-Machine-Origin: testbox')

# T1 — tmux + hostname: BOTH headers, newline-separated, session header first.
run "$SH" MOCK_HOST=testbox TMUX_PANE=%1 MOCK_SESS=work MOCK_WIN=pulse
check 'T1 both headers, newline-separated' "$BOTH" "$(got_hdrs)"

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

# T2 — NO tmux: the machine header is still emitted. R2 — this case sent no
# header at all before dotfiles-v93v.
run "$SH" MOCK_HOST=testbox
check 'T2 no tmux -> machine header alone' 'X-Machine-Origin: testbox' "$(got_hdrs)"

# T3 — hostname fails, tmux present: the session header survives untouched and
# is BYTE-IDENTICAL to the pre-change format (pico's `user` column + history).
run "$SH" TMUX_PANE=%1 MOCK_SESS=work MOCK_WIN=pulse
check 'T3 hostname fails -> session header alone, unchanged format' \
  'X-Session-Identity: work:pulse' "$(got_hdrs)"

# T3b — glyph/whitespace sanitization of the session token is unchanged. The
# leading '-' is the real, pre-existing behavior and is pinned deliberately: the
# glyph becomes '-' via the whitespace squeeze, THEN tr -cd drops the glyph
# itself, leaving the separator behind. Byte-identical to before dotfiles-v93v,
# which is the property that matters for pico's `user` column.
run "$SH" TMUX_PANE=%1 MOCK_SESS='wo rk' MOCK_WIN='✅ my pane'
check 'T3b session token still sanitized' \
  'X-Session-Identity: wo-rk:-my-pane' "$(got_hdrs)"

# T4 — nothing resolvable at all: ANTHROPIC_CUSTOM_HEADERS is not set. FAIL-OPEN.
run "$SH"
check 'T4 nothing resolvable -> no header var at all' '<UNSET>' "$(got_hdrs)"

# T5 — inherited ANTHROPIC_BASE_URL: it WINS, and the machine header is still
# present. R1 — `_host` used to be computed only in the branch this case skips.
run "$SH" MOCK_HOST=testbox TMUX_PANE=%1 MOCK_SESS=work MOCK_WIN=pulse \
    ANTHROPIC_BASE_URL=http://inherited.example/v1
check 'T5 inherited base URL wins' 'http://inherited.example/v1' "$(got_base)"
check 'T5b machine header present with inherited base URL (R1)' "$BOTH" "$(got_hdrs)"

# T6 — CC_NO_GATEWAY=1 bypasses the per-host file; headers are unaffected.
run "$SH" MOCK_HOST=testbox TMUX_PANE=%1 MOCK_SESS=work MOCK_WIN=pulse CC_NO_GATEWAY=1
check 'T6 CC_NO_GATEWAY=1 -> no base URL' '<UNSET>' "$(got_base)"
check 'T6b CC_NO_GATEWAY=1 -> headers still sent' "$BOTH" "$(got_hdrs)"

# T7 — per-host ~/.<host>.zshenv resolution still works (host name feeds the path).
run "$SH" MOCK_HOST=testbox TMUX_PANE=%1 MOCK_SESS=work MOCK_WIN=pulse
check 'T7 base URL derived from per-host zshenv' 'http://127.0.0.1:17017/claude' "$(got_base)"

# T8 — the launch contract: --dangerously-skip-permissions kept, "$@" passed.
# Reads the args dumped by T7's launch, so it must precede T9's bare `claude`.
check 'T8 args: skip-permissions preserved + "$@" passed through' \
  '--dangerously-skip-permissions --resume x' "$(cat "$DUMPDIR/args")"

# T9 — the per-host file is read in a SUBSHELL: its other exports reach neither
# the caller nor the launched child.
leak=$(env -i HOME="$FAKEHOME" PATH="$MOCKDIR:/usr/bin:/bin" DUMPDIR="$DUMPDIR" \
       MOCK_HOST=testbox "$SH" -c '. "$0"; claude >/dev/null; printf "%s" "${LEAK_CANARY:-<none>}"' "$WRAPPER")
check 'T9 per-host exports do not leak into the caller' '<none>' "$leak"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS ($SH)"; else echo "$FAILS FAILURE(S) ($SH)"; fi

# Run the whole matrix under zsh too, from the bash invocation, because the
# wrapper is sourced by BOTH shells and the pre-commit gate only calls `bash`.
if [ -z "${TEST_SHELL:-}" ] && command -v zsh >/dev/null 2>&1; then
  echo
  TEST_SHELL=zsh zsh "$0" || FAILS=$((FAILS+1))
fi

[ "$FAILS" -eq 0 ]
