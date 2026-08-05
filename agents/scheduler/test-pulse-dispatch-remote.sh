#!/bin/bash
# Test for pulse-dispatch-remote.sh — the remote pulse dispatcher (bd-zcxo).
#
# HERMETIC. No ssh, no network, nothing on marketing-vps is touched, no pulse
# timer is read or written. `ssh` is a stub script whose behavior each case sets
# through a knobs file; the local project is a real git fixture in a tmpdir.
#
# WHY THESE CASES: the dispatcher's whole value is its preflight, and a preflight
# is only worth what its failures are worth. So every assertion gets a case that
# BREAKS IT ON PURPOSE and proves the dispatcher refuses to dispatch — the
# governing risk (explore-7iz9 §10) is a remote tick whose infrastructure failure
# is indistinguishable from a legitimate `blocked` row, so an assertion that does
# not actually fire is worse than no assertion at all.
#
# A1/A2 are proven against the REAL vps-preflight.sh with a crafted receipt, not
# against a stub of it — a stub would only prove the wiring, not the assertion.
#
# Convention matches the rest of agents/scheduler/test-*.sh: executable bash,
# non-zero exit = failure, PASS/FAIL summary on the last line.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DISPATCH="$HERE/pulse-dispatch-remote.sh"
PASS=0; FAIL=0; FAILED_NAMES=()

ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); echo "  FAIL  $1: $2"; }

# verdict <output> -> the last PULSE_DISPATCH_RESULT= marker
verdict() { printf '%s\n' "$1" | grep -o 'PULSE_DISPATCH_RESULT=[a-z-]*' | tail -1 | cut -d= -f2; }

check_verdict() { # name output want
  local got; got=$(verdict "$2")
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1" "expected verdict '$3', got '${got:-<none>}'"; fi
}

# ---------------------------------------------------------------------------
# The ssh stub. Dispatches on the remote command text; every response is a knob.
# ---------------------------------------------------------------------------
STUB="$ROOT/bin"; mkdir -p "$STUB"
cat > "$STUB/ssh" <<'STUBEOF'
#!/bin/bash
# shellcheck disable=SC1090
[ -n "${STUB_KNOBS:-}" ] && [ -f "$STUB_KNOBS" ] && . "$STUB_KNOBS"
args=("$@"); last="${args[${#args[@]}-1]}"; raw_last="$last"
# rsh() ships the remote command through `printf %q`, so spaces arrive as "\ ".
# Strip backslashes before matching AND before logging — the real ssh never sees
# these patterns, and a caller grepping the log for `foo down` should not have to
# know that the escaping put a backslash between the two words.
# `raw_last` keeps the UNSTRIPPED word, because one branch below does not want to
# pattern-match the command, it wants to RUN it (see list-windows).
[ -n "${SSH_LOG:-}" ] && printf '%s\n' "${*//\\/}" >> "$SSH_LOG"
last="${last//\\/}"
# The knob that used to answer for the whole window lookup with a precomputed id.
# It is gone (dotfiles-dajp) — the stub now runs the real awk over synthetic
# list-windows lines, so the knob is WIN_LINES and its VALUE means something
# different. A stale `WIN_LIST=` would otherwise be a silent no-op that reads as
# "no window found", i.e. a case quietly asserting something else than it says.
if [ -n "${WIN_LIST-}" ]; then
  printf 'ssh stub: WIN_LIST is retired; use WIN_LINES with full "<@id> <name>" lines\n' >&2
  exit 3
fi
# nth <count-file> — how many times this stub has been asked for a given thing.
# Some cases need a DIFFERENT answer on the retry than on the first try (the
# reclaim-and-retry path, and A3's self-heal), and the two calls are otherwise
# byte-identical, so ordering is the only thing that can distinguish them.
nth() { local f=${1:-}; [ -n "$f" ] || { printf 1; return; }; printf 'x' >> "$f"; wc -c < "$f" | tr -d ' '; }
for a in "${args[@]}"; do [ "$a" = "-O" ] && exit 0; done          # control-master exit
# The master, with or WITHOUT the reverse forward — since dotfiles-wv2a these are
# two different requests with two different meanings, so the stub must tell them
# apart. MASTER_RC governs the plain master (its failure = the box is genuinely
# unreachable); TUNNEL_RC governs the -R bind (its failure = the port is taken).
_hasR=0; for a in "${args[@]}"; do [ "$a" = "-R" ] && _hasR=1; done
for a in "${args[@]}"; do
  if [ "$a" = "-N" ]; then
    [ "$_hasR" = 1 ] || exit "${MASTER_RC:-0}"
    if [ "$(nth "${TUNNEL_COUNT_FILE:-}")" -le 1 ]
      then exit "${TUNNEL_RC:-0}"
      else exit "${TUNNEL_RC_RETRY:-${TUNNEL_RC:-0}}"; fi
  fi
done
case "$last" in
  *"/api/health"*)
    # Step 1 probes with `curl -s -o /dev/null`; A3 probes with `curl -sS`. Same
    # question, different callers — and the cases need to answer them differently
    # (adopt at step 1, then watch A3 heal).
    case "$last" in
      *"-sS"*) if [ "$(nth "${HEALTH_COUNT_FILE:-}")" -le 1 ]
                 then printf '%s' "${HEALTH_CODE:-200}"
                 else printf '%s' "${HEALTH_CODE_RETRY:-${HEALTH_CODE:-200}}"; fi
               exit "${HEALTH_RC:-0}" ;;
      *)       printf '%s' "${BOX_HEALTH:-200}"; exit "${BOX_HEALTH_RC:-0}" ;;
    esac ;;
  *"ensure-fleet-tunnel.sh down"*)   printf 'fleet-tunnel: closed our local forward (pid 1)\n'; exit "${ENSURE_DOWN_RC:-0}" ;;
  *"ensure-fleet-tunnel.sh ensure"*) printf 'fleet-tunnel: HEALED\n'; exit "${ENSURE_RC:-0}" ;;
  *"vault-sync.sh"*)          exit "${REMOTE_VAULT_RC:-0}" ;;
  *"find -L . -type f"*)      printf '%s\n' "${REMOTE_MEM_SHA-MEMSHA}"; exit 0 ;;
  *"rev-parse HEAD"*)         printf '%s\n' "${REMOTE_VAULT_HEAD:-deadbeefdeadbeef}"; exit 0 ;;
  *"br sync --import-only"*)  exit "${REMOTE_IMPORT_RC:-0}" ;;
  *"br sync --status --json"*) printf '%s\n' "${REMOTE_BEAD_JSON-{\"jsonl_content_hash\":\"BEADSHA\",\"jsonl_newer\":false\}}"; exit 0 ;;
  # ── THE WINDOW LOOKUP IS EXECUTED, NOT ANSWERED (dotfiles-dajp) ──────────
  # Every other branch here returns a canned answer. This one must not: the
  # remote command is `tmux list-windows … | awk …`, and that awk is the
  # LEXICON-STRIPPING MATCHER — the fix for a real leak (a glyph-prefixed
  # `✅ weekly-report` failing to match the row `weekly-report`, so every
  # dispatch created ANOTHER window on a box five people share). Answering with
  # a precomputed id left it with zero coverage.
  #
  # So: run the bytes the dispatcher actually sent, against a synthetic tmux.
  # There is deliberately NO COPY of the awk program in this file — a copy is
  # the two-copies defect, and it would drift silently while both sides stayed
  # green. What runs here is the production text, transported through the same
  # `printf %q` round-trip, so a change to the matcher (or to its ssh quoting,
  # which is the fragile part) is felt here immediately.
  #
  # rsh() sends exactly one word: `bash -lc <%q-quoted command>`. Re-running it
  # as `bash -c <same word>` is what the remote shell would do, minus the login
  # profile — which we skip on purpose, since a login shell would reset PATH and
  # find the real tmux instead of the fake one.
  *"list-windows"*)
    _rest=${raw_last#bash -lc }
    if [ "$_rest" = "$raw_last" ]; then
      printf 'ssh stub: remote command is no longer `bash -lc <cmd>` (rsh changed?): %s\n' "$raw_last" >&2
      exit 3
    fi
    ( PATH="${REMOTE_BIN:?ssh stub: REMOTE_BIN unset — no fake tmux to run against}:$PATH"
      eval "bash -c $_rest" )
    exit 0 ;;
  *"new-window"*)             printf '%s\n' "${NEW_WIN_ID:-@7}"; exit 0 ;;
  # The box answers whether the tmux SESSION already existed. `existed` by default
  # (the steady state); `created` is how a case says "this run made the session,
  # so the window inside it is this run's too". Anything else — including the empty
  # string — is the UNRECOGNISED answer, which must leave ownership unclaimed.
  *"has-session"*)            printf 'PULSE_SESSION=%s\n' "${BOX_SESSION-existed}"; exit 0 ;;
  *"pane_id"*)                printf '%s\n' "${PANE_ID:-%3}"; exit 0 ;;
  *"pane_current_command"*)   printf '%s\n' "${PANE_CMD:-zsh}"; exit 0 ;;
  *"reply with exactly: PONG"*) printf '%s\n' "${A7_BODY-PONG}"; exit 0 ;;
  *"claude-probe.txt"*)       printf '%s\n' "${PROBE_BODY-/home/andrew/.local/bin/claude
PROBE_RC=0}"; exit 0 ;;
  *"capture-pane"*)           printf '%s\n' "${PANE_CAPTURE:-? for shortcuts}"; exit 0 ;;
  *"result.json"*)            printf '%s' "${RESULT_JSON:-}"; exit 0 ;;
  *"send-keys"*|*"mkdir -p"*|*"setenv"*|*"DISPATCH.md"*|*"inflight"*|*"kill-window"*) exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$STUB/ssh"

# ---------------------------------------------------------------------------
# The synthetic `tmux` that the ssh stub's list-windows branch runs against.
# It lives in its OWN directory, never on the dispatcher's PATH — only the ssh
# stub prepends it, and only for that one branch. Otherwise the local half of
# the dispatcher would start talking to it too.
#
# It emits $WIN_LINES verbatim: the knob is now realistic `#{window_id}
# #{window_name}` output, exactly what the box would print, glyphs and all.
# The format guard matters — if the dispatcher ever changes its `-F`, the
# synthetic lines would no longer be the shape the awk parses, and the suite
# would keep passing against a shape production had abandoned. Refuse instead.
# ---------------------------------------------------------------------------
REMOTE_BIN="$ROOT/remotebin"; mkdir -p "$REMOTE_BIN"; export REMOTE_BIN
cat > "$REMOTE_BIN/tmux" <<'TMUXEOF'
#!/bin/bash
# shellcheck disable=SC1090
[ -n "${STUB_KNOBS:-}" ] && [ -f "$STUB_KNOBS" ] && . "$STUB_KNOBS"
case "${1:-}" in
  list-windows) ;;
  *) printf 'fake tmux: only list-windows is implemented, got: %s\n' "$*" >&2; exit 9 ;;
esac
case "$*" in
  *"-F #{window_id} #{window_name}"*) ;;
  *) printf 'fake tmux: list-windows -F changed in the dispatcher (%s) — WIN_LINES no longer models it\n' "$*" >&2
     exit 9 ;;
esac
[ -n "${WIN_LINES-}" ] && printf '%s\n' "$WIN_LINES"
exit 0
TMUXEOF
chmod +x "$REMOTE_BIN/tmux"

# pulse-inject stub: records the injected cmd, returns a settable verdict.
cat > "$STUB/inject" <<'INJEOF'
#!/bin/bash
printf '%s\n' "$*" >> "${INJECT_LOG:-/dev/null}"
printf 'PULSE_INJECT_RESULT=%s\n' "${INJECT_VERDICT:-injected}"
exit 0
INJEOF
chmod +x "$STUB/inject"

# preflight stub (used where A1/A2 are not the thing under test).
# It honours --report exactly as the real vps-preflight.sh does, so the
# dispatcher's checkout-state plumbing (dotfiles-f4ub) is EXERCISED rather than
# silently defaulting to "clean" in every case.
cat > "$STUB/preflight" <<'PFEOF'
#!/bin/bash
# shellcheck disable=SC1090
[ -n "${STUB_KNOBS:-}" ] && [ -f "$STUB_KNOBS" ] && . "$STUB_KNOBS"
_r=""
while [ $# -gt 0 ]; do
  case "$1" in --report) _r=$2; shift 2 ;; *) shift ;; esac
done
if [ -n "$_r" ] && [ -n "${PF_REPORT_JSON:-}" ]; then
  mkdir -p "$(dirname "$_r")"; printf '%s' "$PF_REPORT_JSON" > "$_r"
fi
exit "${PREFLIGHT_RC:-0}"
PFEOF
chmod +x "$STUB/preflight"

# ---------------------------------------------------------------------------
# A local project fixture: real git repo, a pulse.md with two rows, a ledger.
# ---------------------------------------------------------------------------
PROJ="$ROOT/proj"; mkdir -p "$PROJ/refs" "$PROJ/.beads"
cat > "$PROJ/refs/pulse.md" <<'EOF'
# pulse routing — fixture

| priority | name | trigger | check | action | cap |
|---|---|---|---|---|---|
| 1 | di-friday | time: Fri | `true` | do the thing | 1/week |
| 2 | di-tuesday | time: Tue | `true` | do the other thing | 1/week |
| 3 | di-mon | time: Mon | `true` | prefix-collision fixture | 1/week |
| 3 | di-monday | time: Mon | `true` | the row di-mon is a prefix of | 1/week |
EOF
# ⚠️ `di-mon` and `di-monday` are NOT filler. One row name being a strict prefix of
# another is the shape that a substring matcher gets wrong and an equality matcher
# gets right, and the remote window lookup is an equality matcher — see the
# lexicon-glyph section near the end of this file. Do not "tidy" them away.
: > "$PROJ/refs/pulse-ledger.jsonl"
git init -q -b main "$PROJ" && git -C "$PROJ" add -A && git -C "$PROJ" commit -qm fixture

KNOBS="$ROOT/knobs"
export STUB_KNOBS="$KNOBS"
STATE="$ROOT/state"

# Call counters for the stub's order-sensitive answers (see `nth` above). They are
# reset by write_knobs, so every case starts from call #1.
export TUNNEL_COUNT_FILE="$ROOT/tunnel.count" HEALTH_COUNT_FILE="$ROOT/health.count"

# write_knobs KEY=VALUE... — values are single-quoted, because the stub SOURCES
# this file and an unquoted JSON value loses its quotes ({"a":"b"} -> {a:b}).
write_knobs() {
  local kv; : > "$KNOBS"; : > "$TUNNEL_COUNT_FILE"; : > "$HEALTH_COUNT_FILE"
  for kv in "$@"; do printf "%s='%s'\n" "${kv%%=*}" "${kv#*=}" >> "$KNOBS"; done
}

# run <knob-lines...> — writes knobs then runs the dispatcher in --dry-run
# (--dry-run exercises the tunnel + ALL SIX assertions for real and stops before
# dispatching, which is exactly the surface these cases are about).
run_dry() {
  write_knobs "$@"
  SSH_LOG="${SSH_LOG_OVERRIDE:-$ROOT/ssh.log}" \
  PULSE_DISPATCH_SSH="$STUB/ssh" \
  PULSE_DISPATCH_PREFLIGHT="$STUB/preflight" \
  PULSE_DISPATCH_INJECT="$STUB/inject" PULSE_DISPATCH_MANIFEST=/nonexistent-manifest \
  PULSE_DISPATCH_VAULT=/nonexistent-local-vault \
  PULSE_DISPATCH_STATE="$STATE" \
  HOME="$ROOT/home" \
    "$DISPATCH" --row di-friday --dir "$PROJ" --dry-run --poll 1 --timeout 3 2>&1
}
mkdir -p "$ROOT/home"

echo "== argument + row validation =="
OUT=$(PULSE_DISPATCH_SSH="$STUB/ssh" "$DISPATCH" --dir "$PROJ" --dry-run 2>&1)
check_verdict "missing --row is failed-usage" "$OUT" failed-usage

OUT=$(PULSE_DISPATCH_SSH="$STUB/ssh" "$DISPATCH" --row not-a-real-row --dir "$PROJ" --dry-run 2>&1)
check_verdict "row absent from pulse.md is failed-row" "$OUT" failed-row
case "$OUT" in *"di-friday"*) ok "failed-row names the valid rows" ;;
  *) bad "failed-row names the valid rows" "valid-row list missing from the message" ;; esac

echo
echo "== A3: tunnel / fleet-proxy health, probed FROM THE VPS SIDE =="
# The box is unreachable outright — not a port conflict, since step 1 asks for no
# forward at all before it has probed. This is the ONLY shape that may still die
# at step 1 (dotfiles-wv2a).
OUT=$(run_dry 'MASTER_RC=255')
check_verdict "box unreachable (plain master fails) -> failed-tunnel" "$OUT" failed-tunnel

# A3 sees nothing, and the box cannot reopen it either. ENSURE_RC=1 is what makes
# this the self-heal-FAILED branch rather than the heal-lied-to-us branch below;
# without it the case never reached the message it claimed to assert on.
OUT=$(run_dry 'HEALTH_CODE=000' 'ENSURE_RC=1')
check_verdict "A3 health 000 through the tunnel -> failed-tunnel" "$OUT" failed-tunnel
case "$OUT" in *"THROUGH THE TUNNEL"*) ok "A3 message blames the tunnel, not the proxy" ;;
  *) bad "A3 message blames the tunnel" "message did not mention the tunnel" ;; esac

# The heal claims success and the probe still says nothing: never trust the heal
# over the probe.
OUT=$(run_dry 'HEALTH_CODE=000')
check_verdict "A3 self-heal reports success but the probe still fails -> failed-tunnel" "$OUT" failed-tunnel
case "$OUT" in *"Never trust the heal over the probe"*) ok "the heal is never believed over the probe" ;;
  *) bad "heal vs probe" "expected the 'never trust the heal' message" ;; esac

OUT=$(run_dry 'HEALTH_CODE=502')
check_verdict "A3 health 502 -> failed-tunnel" "$OUT" failed-tunnel

echo
echo "== A4: claude on the target pane's PATH =="
OUT=$(run_dry 'PANE_CMD=zsh' 'PROBE_BODY=PROBE_RC=1')
check_verdict "A4 pane cannot resolve claude -> failed-no-claude" "$OUT" failed-no-claude
case "$OUT" in *"login"*) ok "A4 message names the login/non-login shell shape" ;;
  *) bad "A4 message names the shell shape" "no mention of the login shell" ;; esac

OUT=$(run_dry 'PANE_CMD=zsh' 'PROBE_BODY=')
check_verdict "A4 probe never returns -> failed-no-claude" "$OUT" failed-no-claude

OUT=$(run_dry 'PANE_CMD=claude')
check_verdict "A4 passes when claude is the running pane process" "$OUT" dry-run-ok

echo
echo "== A5: memory tier identity (content, NEVER exit status) =="
# The knob makes the remote vault-sync exit 0 while the digest differs — the
# exact shape measured on 2026-07-27: a green sync on a stale box.
mkdir -p "$ROOT/home/.claude/projects/$(printf '%s' "$PROJ" | tr '/' '-')/memory"
echo "corpus" > "$ROOT/home/.claude/projects/$(printf '%s' "$PROJ" | tr '/' '-')/memory/MEMORY.md"
OUT=$(run_dry 'PANE_CMD=claude' 'REMOTE_VAULT_RC=0' 'REMOTE_MEM_SHA=0000000000000000deadbeef')
check_verdict "A5 memory digest mismatch -> failed-vault (despite sync rc=0)" "$OUT" failed-vault
case "$OUT" in *"NOT identical"*) ok "A5 message states the tiers are not identical" ;;
  *) bad "A5 message" "expected 'NOT identical' in the message" ;; esac

OUT=$(run_dry 'PANE_CMD=claude' 'REMOTE_MEM_SHA=')
check_verdict "A5 no remote memory dir -> failed-vault" "$OUT" failed-vault

echo
echo "== A6: bead index current with the JSONL =="
# A real beads workspace, so the LOCAL half of the A6 comparison is genuine.
( cd "$PROJ" && br init --prefix tst >/dev/null 2>&1; br q "fixture bead" >/dev/null 2>&1; br sync --flush-only >/dev/null 2>&1 ) || true
[ -s "$PROJ/.beads/issues.jsonl" ] || echo '{"id":"tst-1"}' > "$PROJ/.beads/issues.jsonl"
LSHA=$(cd "$PROJ" && br sync --status --json 2>/dev/null | jq -r '.jsonl_content_hash // "NOLOCAL"')
if [ "$LSHA" = "NOLOCAL" ] || [ -z "$LSHA" ]; then
  echo "  SKIP  A6 cases (br could not read the fixture workspace)"
else
  OUT=$(run_dry 'PANE_CMD=claude' "REMOTE_MEM_SHA=$(cd "$ROOT/home/.claude/projects/$(printf '%s' "$PROJ" | tr '/' '-')/memory" && find -L . -type f | LC_ALL=C sort | xargs -r sha256sum | sha256sum | cut -d' ' -f1)" \
        'REMOTE_BEAD_JSON={"jsonl_content_hash":"ffffffffffffffff","jsonl_newer":false}')
  check_verdict "A6 JSONL hash differs between machines -> failed-beads" "$OUT" failed-beads

  OUT=$(run_dry 'PANE_CMD=claude' "REMOTE_MEM_SHA=$(cd "$ROOT/home/.claude/projects/$(printf '%s' "$PROJ" | tr '/' '-')/memory" && find -L . -type f | LC_ALL=C sort | xargs -r sha256sum | sha256sum | cut -d' ' -f1)" \
        "REMOTE_BEAD_JSON={\"jsonl_content_hash\":\"$LSHA\",\"jsonl_newer\":true}")
  check_verdict "A6 remote jsonl_newer=true (DB never imported) -> failed-beads" "$OUT" failed-beads

  OUT=$(run_dry 'PANE_CMD=claude' "REMOTE_MEM_SHA=$(cd "$ROOT/home/.claude/projects/$(printf '%s' "$PROJ" | tr '/' '-')/memory" && find -L . -type f | LC_ALL=C sort | xargs -r sha256sum | sha256sum | cut -d' ' -f1)" \
        'REMOTE_BEAD_JSON=' )
  check_verdict "A6 unreadable remote bead status -> failed-beads" "$OUT" failed-beads
fi

echo
echo "== A1 + A2: the REAL vps-preflight.sh, with a crafted receipt =="
# Not a stub of the preflight — a stub would prove only that a non-zero exit
# propagates. These drive the real script with a real local git fixture and a
# receipt that is wrong in exactly one way.
PF="$HERE/vps-preflight.sh"
pf_fixture() {  # $1 = case name -> sets PFDIR, MANIFEST, LOCAL_HEAD
  PFDIR="$ROOT/pf-$1"; mkdir -p "$PFDIR"
  git init -q --bare -b main "$PFDIR/origin.git"
  git init -q -b main "$PFDIR/repo"; mkdir -p "$PFDIR/repo/refs"
  echo x > "$PFDIR/repo/refs/pulse.md"
  git -C "$PFDIR/repo" add -A; git -C "$PFDIR/repo" commit -qm one
  git -C "$PFDIR/repo" remote add origin "$PFDIR/origin.git"; git -C "$PFDIR/repo" push -q origin main
  LOCAL_HEAD=$(git -C "$PFDIR/repo" rev-parse HEAD)
  MANIFEST="$PFDIR/manifest.txt"
  printf 'repo %s origin main\nrequire %s\n' "$PFDIR/repo" "$PFDIR/repo/refs/pulse.md" > "$MANIFEST"
}
pf_run() {      # $1 = receipt json -> runs the real preflight with a stubbed ssh
  printf '%s' "$1" > "$PFDIR/receipt.json"
  cat > "$PFDIR/ssh" <<PFSSH
#!/bin/bash
last="\${@: -1}"
case "\$last" in *receipt*|*cat*) cat "$PFDIR/receipt.json" ;; esac
exit 0
PFSSH
  chmod +x "$PFDIR/ssh"
  PATH="$PFDIR:$PATH" "$PF" --manifest "$MANIFEST" --no-refresh --quiet 2>&1
  echo "EXIT=$?"
}

if [ -x "$PF" ]; then
  # A2 — the box's HEAD is not zig-computer's.
  pf_fixture a2
  OUT=$(pf_run "{\"ok\":true,\"generated_epoch\":$(date -u +%s),\"repos\":[{\"path\":\"/home/andrew/repo\",\"head\":\"1111111111111111111111111111111111111111\",\"in_sync\":true}],\"submodules\":[],\"required\":[{\"path\":\"x\",\"ok\":true,\"oob\":false}],\"harvested\":[]}")
  case "$OUT" in *"NOT the same code"*|*"EXIT=74"*) ok "A2 stale remote HEAD -> preflight BLOCKS (74)" ;;
    *) bad "A2 stale remote HEAD" "expected a 74 block, got: $(printf '%.180s' "$OUT")" ;; esac

  # A2 control — same sha both sides, nothing else wrong, must pass.
  pf_fixture a2ok
  OUT=$(pf_run "{\"ok\":true,\"generated_epoch\":$(date -u +%s),\"repos\":[{\"path\":\"/home/andrew/repo\",\"head\":\"$LOCAL_HEAD\",\"in_sync\":true}],\"submodules\":[],\"required\":[{\"path\":\"x\",\"ok\":true,\"oob\":false}],\"harvested\":[]}")
  case "$OUT" in *"EXIT=0"*) ok "A2 control: identical shas -> preflight PASSES" ;;
    *) bad "A2 control" "expected EXIT=0, got: $(printf '%.180s' "$OUT")" ;; esac

  # A1 — a required path (the empty-submodule class) is missing on the box.
  pf_fixture a1
  OUT=$(pf_run "{\"ok\":true,\"generated_epoch\":$(date -u +%s),\"repos\":[{\"path\":\"/home/andrew/repo\",\"head\":\"$LOCAL_HEAD\",\"in_sync\":true}],\"submodules\":[],\"required\":[{\"path\":\"/home/andrew/repo/refs/pulse.md\",\"ok\":false,\"oob\":false}],\"harvested\":[]}")
  case "$OUT" in *"required path missing"*) ok "A1 empty submodule / missing required path -> preflight BLOCKS" ;;
    *) bad "A1 missing required path" "expected a required-path block, got: $(printf '%.180s' "$OUT")" ;; esac

  # A1 — a stale receipt must never be accepted (fail-closed).
  pf_fixture a1stale
  OUT=$(pf_run "{\"ok\":true,\"generated_epoch\":1,\"repos\":[{\"path\":\"/home/andrew/repo\",\"head\":\"$LOCAL_HEAD\",\"in_sync\":true}],\"submodules\":[],\"required\":[],\"harvested\":[]}")
  case "$OUT" in *"old (max"*|*"EXIT=74"*) ok "receipt older than max-age -> preflight BLOCKS (fail-closed)" ;;
    *) bad "stale receipt" "expected a staleness block, got: $(printf '%.180s' "$OUT")" ;; esac
else
  echo "  SKIP  A1/A2 cases (vps-preflight.sh not executable)"
fi

echo
echo "== dispatcher wiring: preflight failure propagates =="
OUT=$(run_dry 'PANE_CMD=claude' 'PREFLIGHT_RC=74')
check_verdict "vps-preflight non-zero -> failed-preflight" "$OUT" failed-preflight

echo
echo "== the happy dry run: all six assertions pass, nothing is dispatched =="
MEMSHA=$(cd "$ROOT/home/.claude/projects/$(printf '%s' "$PROJ" | tr '/' '-')/memory" && find -L . -type f | LC_ALL=C sort | xargs -r sha256sum | sha256sum | cut -d' ' -f1)
BEADJSON="{\"jsonl_content_hash\":\"${LSHA:-BEADSHA}\",\"jsonl_newer\":false}"
OUT=$(run_dry 'PANE_CMD=claude' "REMOTE_MEM_SHA=$MEMSHA" "REMOTE_BEAD_JSON=$BEADJSON")
check_verdict "all assertions green -> dry-run-ok" "$OUT" dry-run-ok
case "$OUT" in *"would inject"*) ok "dry run reports what it WOULD do without doing it" ;;
  *) bad "dry run reporting" "no 'would inject' line" ;; esac
case "$OUT" in *"/pulse tick"*) ok "dry run shows the tick command it would send" ;;
  *) bad "dry run tick preview" "no tick command shown" ;; esac
# The ledger must be untouched by a dry run.
if [ ! -s "$PROJ/refs/pulse-ledger.jsonl" ]; then ok "dry run writes NO ledger row"
else bad "dry run writes no ledger row" "ledger is non-empty after a dry run"; fi

echo
echo "== step 1: PROBE FIRST, then ADOPT-OR-OPEN (dotfiles-wv2a) =="
# THE INCIDENT, 2026-07-29: the box held a HEALTHY forward of its own (its own
# `ssh -L`, which binds the same 127.0.0.1:7100), the dispatcher's `-R` bind was
# therefore refused, and step 1 killed the whole di-wednesday tick rather than use
# the working path sitting right there. These cases are that morning, frozen.
STEP1=('PANE_CMD=claude' "REMOTE_MEM_SHA=$MEMSHA" "REMOTE_BEAD_JSON=$BEADJSON")
tunnel_mode_file() { local d; d=$(ls -dt "$STATE"/*/ 2>/dev/null | head -1); printf '%s' "${d}tunnel-mode"; }

# (1) ADOPT — the steady state under the standing-forward posture (Zig, 2026-07-29).
: > "$ROOT/ssh.log"
OUT=$(run_dry "${STEP1[@]}" 'BOX_HEALTH=200' 'TUNNEL_RC=255')
check_verdict "healthy pre-bound port -> ADOPTS it and dispatches" "$OUT" dry-run-ok
case "$OUT" in *"TUNNEL_MODE=adopted"*) ok "the adopt is announced as TUNNEL_MODE=adopted" ;;
  *) bad "adopt announced" "no TUNNEL_MODE=adopted in the output" ;; esac
if [ "$(cat "$(tunnel_mode_file)" 2>/dev/null)" = adopted ]
  then ok "TUNNEL_MODE is recorded in the run state dir"
  else bad "TUNNEL_MODE recorded in state" "got '$(cat "$(tunnel_mode_file)" 2>/dev/null)'"; fi
# PROBE FIRST is the whole point of the ordering: a -R that is attempted and
# refused on every run writes a scary line into tunnel.err every run, and a file
# that cries wolf daily is a file nobody reads on the day it matters.
if grep -q '127.0.0.1:7100:127.0.0.1:7100' "$ROOT/ssh.log"
  then bad "adopt never attempts the -R bind" "a reverse forward was attempted even though the box was already healthy"
  else ok "adopt never attempts the -R bind (no scary tunnel.err line on the normal path)"; fi

# (2) TEARDOWN NEVER KILLS A FORWARD THIS RUN DID NOT CREATE. The adopted forward
#     belongs to the box; `ensure-fleet-tunnel.sh down` must never be sent for it.
if grep -q 'ensure-fleet-tunnel.sh down' "$ROOT/ssh.log"
  then bad "teardown leaves an adopted forward alone" "the run tore down a forward it did not create"
  else ok "teardown leaves an adopted forward alone"; fi

# (3) OWNED — nothing is listening on the box, so this run opens the -R itself.
: > "$ROOT/ssh.log"
OUT=$(run_dry "${STEP1[@]}" 'BOX_HEALTH=000')
check_verdict "no healthy path -> opens the reverse forward and dispatches" "$OUT" dry-run-ok
case "$OUT" in *"TUNNEL_MODE=owned"*) ok "opening our own forward is announced as TUNNEL_MODE=owned" ;;
  *) bad "owned announced" "no TUNNEL_MODE=owned in the output" ;; esac
if grep -q '127.0.0.1:7100:127.0.0.1:7100' "$ROOT/ssh.log"
  then ok "owned mode really does request the -R forward"
  else bad "owned requests -R" "no reverse forward in the ssh calls"; fi

# (4) RECLAIM-AND-RETRY — the port is BOUND BUT DEAD: nothing answers, and the -R
#     cannot bind over it. Ask the box to drop only ITS OWN forward (pidfile-scoped;
#     a pkill on a shared box would murder someone else's run) and retry ONCE.
: > "$ROOT/ssh.log"
OUT=$(run_dry "${STEP1[@]}" 'BOX_HEALTH=000' 'TUNNEL_RC=255' 'TUNNEL_RC_RETRY=0')
check_verdict "dead-but-bound port -> reclaim, retry once, dispatch" "$OUT" dry-run-ok
case "$OUT" in *RECLAIMED*) ok "the reclaim is announced" ;;
  *) bad "reclaim announced" "no RECLAIMED line in the output" ;; esac
if grep -q 'ensure-fleet-tunnel.sh down' "$ROOT/ssh.log"
  then ok "the reclaim goes through the box's own pidfile-scoped teardown"
  else bad "reclaim uses ensure-fleet-tunnel down" "no scoped teardown was requested"; fi
if grep -q 'pkill' "$ROOT/ssh.log"
  then bad "the reclaim never pkills on a shared box" "a pkill reached the box"
  else ok "the reclaim never pkills on a shared box"; fi

# (5) …and when the retry ALSO fails, that is a real failure, loudly.
OUT=$(run_dry "${STEP1[@]}" 'BOX_HEALTH=000' 'TUNNEL_RC=255' 'TUNNEL_RC_RETRY=255')
check_verdict "reclaim + retry both fail -> failed-tunnel" "$OUT" failed-tunnel

# (6) A genuinely unreachable box still exits 71 — the recovery paths must not
#     have turned a hard infrastructure failure into a soft one.
run_dry "${STEP1[@]}" 'MASTER_RC=255' >/dev/null 2>&1; RC=$?
if [ "$RC" = 71 ]; then ok "an unreachable box still exits 71"
else bad "unreachable box exits 71" "got exit $RC"; fi

# (7) A3's self-heal opens a box-side forward mid-run. It is DELIBERATELY left up:
#     under the standing-forward posture that heal produces exactly the state the
#     box is supposed to be in, and tearing it down would strand the next tick.
: > "$ROOT/ssh.log"
OUT=$(run_dry "${STEP1[@]}" 'BOX_HEALTH=200' 'HEALTH_CODE=000' 'HEALTH_CODE_RETRY=200')
check_verdict "A3 self-heal recovers -> dispatch proceeds" "$OUT" dry-run-ok
case "$OUT" in *"A3: HEALED"*|*"HEALED"*) ok "the heal is reported" ;;
  *) bad "heal reported" "no HEALED line"; esac
if grep -q 'ensure-fleet-tunnel.sh ensure' "$ROOT/ssh.log"
  then ok "the heal asks the box to open the forward itself"
  else bad "heal asks the box" "no ensure call in the ssh log"; fi
if grep -q 'ensure-fleet-tunnel.sh down' "$ROOT/ssh.log"
  then bad "a healed forward is left UP" "teardown closed the forward the heal opened — that fights the standing-forward posture"
  else ok "a healed forward is left UP (standing-forward posture, Zig 2026-07-29)"; fi

echo
echo "== payload validation + ledger write-back (live path) =="
run_live() {
  write_knobs "$@"
  PULSE_DISPATCH_SSH="$STUB/ssh" \
  PULSE_DISPATCH_PREFLIGHT="$STUB/preflight" \
  PULSE_DISPATCH_INJECT="$STUB/inject" PULSE_DISPATCH_MANIFEST=/nonexistent-manifest \
  PULSE_DISPATCH_VAULT=/nonexistent-local-vault \
  PULSE_DISPATCH_LINT=/nonexistent-lint \
  PULSE_DISPATCH_STATE="$STATE" \
  INJECT_LOG="$ROOT/inject.log" \
  HOME="$ROOT/home" \
    "$DISPATCH" --row di-friday --dir "$PROJ" --poll 1 --timeout 3 2>&1
}
BASE=('PANE_CMD=claude' "REMOTE_MEM_SHA=$MEMSHA" "REMOTE_BEAD_JSON=$BEADJSON")

# Same dispatcher, a different --row. The two-ticks-while-blocked case needs two
# DIFFERENT rows, because the queue collapses per row on purpose.
run_live_row() { # <row> <knob>...
  local row=$1; shift
  write_knobs "$@"
  PULSE_DISPATCH_SSH="$STUB/ssh" \
  PULSE_DISPATCH_PREFLIGHT="$STUB/preflight" \
  PULSE_DISPATCH_INJECT="$STUB/inject" PULSE_DISPATCH_MANIFEST=/nonexistent-manifest \
  PULSE_DISPATCH_VAULT=/nonexistent-local-vault \
  PULSE_DISPATCH_LINT=/nonexistent-lint \
  PULSE_DISPATCH_STATE="$STATE" \
  INJECT_LOG="$ROOT/inject.log" \
  HOME="$ROOT/home" \
    "$DISPATCH" --row "$row" --dir "$PROJ" --poll 1 --timeout 3 2>&1
}

# The deferred-surface queue (dotfiles-5ts2). It lives in a SIBLING of the dispatch
# state root — deliberately not inside it, because `ls -dt "$STATE"/*/ | head -1`
# ("the newest run dir") is the idiom this suite uses to find a run's artifacts, and
# a queue directory in there would silently become "the newest run".
SURFQ="$STATE-surfaces"
queue_reset()   { rm -rf "$SURFQ"; }
queue_pending() { find "$SURFQ/pending"   -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
queue_done()    { find "$SURFQ/delivered" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
# Drain WITHOUT a dispatch — the standalone path pulse-retry.timer takes every 2 min.
queue_drain()   {
  PULSE_DISPATCH_STATE="$STATE" PULSE_DISPATCH_INJECT="$STUB/inject" \
  INJECT_LOG="$ROOT/inject.log" HOME="$ROOT/home" \
    "$HERE/pulse-surface-queue.sh" drain "$@" 2>&1
}
surface_verdict() { printf '%s\n' "$1" | grep -o 'PULSE_SURFACE_RESULT=[a-z0-9:-]*' | tail -1 | cut -d= -f2-; }

echo
echo "== fail() surfacing is a DENYLIST now (dotfiles-wv2a) =="
# The 2026-07-29 miss in one line: failed-tunnel was not on the old allowlist, so
# a dispatch that died at step 1 rang NOTHING and lived only in journalctl until
# Zig thought to ask. An allowlist has to be remembered every time a verdict is
# added; a denylist fails safe.
: > "$ROOT/inject.log"
OUT=$(run_live "${BASE[@]}" 'MASTER_RC=255')
check_verdict "an unreachable box in a LIVE run -> failed-tunnel" "$OUT" failed-tunnel
if grep -q 'REMOTE PULSE SURFACE' "$ROOT/inject.log"
  then ok "failed-tunnel SURFACES to work:pulse (the verdict that cost us the tick)"
  else bad "failed-tunnel surfaces" "a tunnel failure rang nothing — this is the exact 2026-07-29 miss"; fi
: > "$ROOT/inject.log"
OUT=$(run_live "${BASE[@]}" 'REMOTE_BEAD_JSON=')
check_verdict "unreadable remote bead status in a LIVE run -> failed-beads" "$OUT" failed-beads
if grep -q 'REMOTE PULSE SURFACE' "$ROOT/inject.log"
  then ok "failed-beads surfaces too (the denylist covers the whole class)"
  else bad "failed-beads surfaces" "nothing injected"; fi
# …but an operator typo on a hand-run must NOT wake the window.
: > "$ROOT/inject.log"
OUT=$(env INJECT_LOG="$ROOT/inject.log" PULSE_DISPATCH_SSH="$STUB/ssh" \
  PULSE_DISPATCH_INJECT="$STUB/inject" PULSE_DISPATCH_STATE="$STATE" HOME="$ROOT/home" \
  "$DISPATCH" --row not-a-real-row --dir "$PROJ" 2>&1)
check_verdict "a typo'd --row is still failed-row" "$OUT" failed-row
if [ -s "$ROOT/inject.log" ]
  then bad "failed-row does not wake the window" "an operator typo rang work:pulse"
  else ok "failed-row does NOT wake the window (operator typo, hand-run)"; fi

: > "$ROOT/inject.log"
OUT=$(run_live "${BASE[@]}" 'RESULT_JSON=')
check_verdict "no payload before the deadline -> failed-timeout" "$OUT" failed-timeout
if grep -q 'REMOTE PULSE SURFACE' "$ROOT/inject.log"; then ok "a timeout SURFACES locally (silence is never silent here)"
else bad "timeout surfaces locally" "nothing was injected into the local window"; fi
# EXACTLY once. The timeout path surfaces itself and THEN calls fail(), which now
# surfaces every verdict — without the SURFACED guard that is two bells for one
# event, and a channel that double-rings gets muted.
if [ "$(grep -c 'REMOTE PULSE SURFACE' "$ROOT/inject.log")" = 1 ]
  then ok "a timeout rings the bell exactly ONCE (no double-surface)"
  else bad "timeout rings once" "got $(grep -c 'REMOTE PULSE SURFACE' "$ROOT/inject.log") injections for one event"; fi
if [ ! -s "$PROJ/refs/pulse-ledger.jsonl" ]; then ok "a timeout writes NO ledger row"
else bad "timeout writes no ledger row" "a row was written for a tick that never reported"; fi

OUT=$(run_live "${BASE[@]}" 'RESULT_JSON={"row":"di-tuesday","outcome":"done","proof":{"kind":"cmd","cmd":"true"}}')
check_verdict "payload row != dispatched row -> failed-payload" "$OUT" failed-payload

OUT=$(run_live "${BASE[@]}" 'RESULT_JSON={"row":null,"outcome":"done"}')
check_verdict "payload with a null row -> failed-payload" "$OUT" failed-payload

OUT=$(run_live "${BASE[@]}" 'RESULT_JSON={"row":"di-friday","outcome":"done","note":"n"}')
check_verdict "outcome=done with no proof -> failed-payload" "$OUT" failed-payload

OUT=$(run_live "${BASE[@]}" 'RESULT_JSON={"row":"di-friday","outcome":"finished","note":"n"}')
check_verdict "outcome outside done|quiet|blocked -> failed-payload" "$OUT" failed-payload

if [ ! -s "$PROJ/refs/pulse-ledger.jsonl" ]; then ok "no rejected payload ever reached the ledger"
else bad "rejected payloads stay out of the ledger" "ledger was written by a rejected payload"; fi

echo
echo "== the completed path =="
: > "$ROOT/inject.log"
OUT=$(run_live "${BASE[@]}" 'RESULT_JSON={"row":"di-friday","outcome":"done","note":"drafted and parked","proof":{"kind":"cmd","cmd":"true"},"artifacts":["gid-1"]}')
check_verdict "valid payload -> completed" "$OUT" completed
LINE=$(tail -1 "$PROJ/refs/pulse-ledger.jsonl")
if printf '%s' "$LINE" | jq -e '.row=="di-friday" and .outcome=="done" and .proof.cmd=="true"' >/dev/null 2>&1
then ok "ledger row written HERE with row/outcome/proof carried from the payload"
else bad "ledger row content" "got: $(printf '%.160s' "$LINE")"; fi
if printf '%s' "$LINE" | jq -e '.dispatch.remote==true and (.dispatch.run_id|length>0)' >/dev/null 2>&1
then ok "ledger row is marked as remotely dispatched (attributable later)"
else bad "ledger row provenance" "no .dispatch.remote / run_id"; fi
if printf '%s' "$LINE" | jq -e '.ts|test("^[0-9]{4}-")' >/dev/null 2>&1
then ok "ledger row carries a UTC ts written locally"; else bad "ledger ts" "bad ts"; fi
# INVERTED 2026-07-31 (dotfiles-5ts2). This case used to assert the opposite — "a
# clean tick does NOT wake the local window" — and that assertion was the defect,
# not a guard against one. A tick that drafts the Friday Deploy roundup, parks it in
# Asana and says nothing has produced work nobody knows happened. Zig: "I don't
# think there's such a thing as a low-value bell ... you need to be in charge of
# making sure I see their actions and I know when they're ready so I can pick them
# up and publish them." So: EVERY completion surfaces, surface_request or not.
if grep -q 'REMOTE PULSE SURFACE' "$ROOT/inject.log"
then ok "a clean tick with NO surface_request STILL wakes the local window (always-bell)"
else bad "always-bell" "a completed tick announced nothing — the parked draft is invisible"; fi
RUNDIR=$(ls -dt "$STATE"/*/ 2>/dev/null | head -1)
if jq -e '.question and .detail and .options' "${RUNDIR}surface.json" >/dev/null 2>&1
then ok "the synthesized surface carries a question, options and detail"
else bad "synthesized surface shape" "got: $(head -c 200 "${RUNDIR}surface.json" 2>/dev/null)"; fi
if jq -e '.detail | test("drafted and parked") and test("pulse-ledger.jsonl")' "${RUNDIR}surface.json" >/dev/null 2>&1
then ok "it says WHAT landed (the tick's note) and WHERE (the ledger row to land)"
else bad "surface says what/where" "got: $(jq -r '.detail // "<none>"' "${RUNDIR}surface.json" 2>/dev/null | head -c 200)"; fi
if jq -e '.detail | test("gid-1")' "${RUNDIR}surface.json" >/dev/null 2>&1
then ok "the payload's artifacts are named in the announcement"
else bad "artifacts in the surface" "artifact ids missing from the detail"; fi
if jq -e '.question | test("di-friday")' "${RUNDIR}surface.json" >/dev/null 2>&1
then ok "the question names the row, so the bell is self-describing"
else bad "question names the row" "got: $(jq -r '.question // "<none>"' "${RUNDIR}surface.json" 2>/dev/null)"; fi

# quiet and blocked ring too — the bar is "is there something to SEE", not "did
# something get produced". A quiet row is how Zig learns the loop is alive.
for _out in quiet blocked; do
  : > "$ROOT/inject.log"; queue_reset
  OUT=$(run_live "${BASE[@]}" "RESULT_JSON={\"row\":\"di-friday\",\"outcome\":\"$_out\",\"note\":\"nothing to do this week\"}")
  check_verdict "outcome=$_out completes" "$OUT" completed
  if grep -q 'REMOTE PULSE SURFACE' "$ROOT/inject.log"
  then ok "outcome=$_out surfaces too (done|quiet|blocked alike)"
  else bad "outcome=$_out surfaces" "a $_out tick rang nothing"; fi
done
queue_reset

echo
echo "== the surface callback (Zig's 2026-07-27 extension) =="
: > "$ROOT/inject.log"
OUT=$(run_live "${BASE[@]}" 'RESULT_JSON={"row":"di-friday","outcome":"done","note":"needs him","proof":{"kind":"cmd","cmd":"true"},"surface_request":{"reason":"pod weekly empty","question":"Populate it?","options":["Yes","Later"]}}')
check_verdict "surface_request still completes the dispatch" "$OUT" completed
if grep -q 'REMOTE PULSE SURFACE' "$ROOT/inject.log"; then ok "surface_request injects into the LOCAL window"
else bad "surface_request injects locally" "nothing injected"; fi
if grep -q -- '--window pulse' "$ROOT/inject.log" && grep -q -- '--session work' "$ROOT/inject.log"
then ok "surface targets session 'work' window 'pulse' by default"
else bad "surface target" "got: $(cat "$ROOT/inject.log")"; fi
if grep -q 'AskUserQuestion' "$ROOT/inject.log"; then ok "the injected prompt asks the LOCAL session to raise the AskUserQuestion"
else bad "surface prompt" "prompt does not mention AskUserQuestion"; fi
RUNDIR=$(ls -dt "$STATE"/*/ 2>/dev/null | head -1)
if [ -s "${RUNDIR}surface.json" ]; then ok "surface payload staged on disk for the local session to read"
else bad "surface staged" "no surface.json at ${RUNDIR}"; fi

# Fail-closed on the injector's verdict: pulse-inject exits 0 on injected,
# bounced AND deferred, so only the marker may be believed.
: > "$ROOT/inject.log"
OUT=$(INJECT_VERDICT=deferred-blocked-on-human run_live "${BASE[@]}" 'RESULT_JSON={"row":"di-friday","outcome":"done","proof":{"kind":"cmd","cmd":"true"},"surface_request":{"reason":"r","question":"q"}}')
case "$OUT" in *"surface NOT delivered"*) ok "a DEFERRED injection is reported as NOT delivered (fail closed)" ;;
  *) bad "deferred injection" "a deferred inject was treated as delivered" ;; esac
OUT=$(INJECT_VERDICT=bounced-not-ready run_live "${BASE[@]}" 'RESULT_JSON={"row":"di-friday","outcome":"done","proof":{"kind":"cmd","cmd":"true"},"surface_request":{"reason":"r","question":"q"}}')
case "$OUT" in *"surface NOT delivered"*) ok "a BOUNCED injection is reported as NOT delivered (fail closed)" ;;
  *) bad "bounced injection" "a bounced inject was treated as delivered" ;; esac

echo
echo "== the DEFERRED-SURFACE QUEUE (dotfiles-5ts2) =="
# The mechanical catch behind always-bell. pulse-inject REFUSES to type into a
# 🔔-blocked window, and before this the dispatcher just warned and moved on —
# nothing ever redelivered the announcement. Under always-bell a 🔔 is the NORMAL
# state whenever Zig is away, so without this the policy would SWALLOW the very
# notifications it exists to guarantee.

# (1) A surface into a blocked window is STAGED, not lost.
queue_reset; : > "$ROOT/inject.log"
OUT=$(INJECT_VERDICT=deferred-blocked-on-human run_live "${BASE[@]}" \
      'RESULT_JSON={"row":"di-friday","outcome":"done","note":"friday roundup parked","proof":{"kind":"cmd","cmd":"true"}}')
check_verdict "a tick whose surface bounces still COMPLETES" "$OUT" completed
if [ "$(queue_pending)" = 1 ]; then ok "a 🔔-blocked surface is STAGED in the queue (nothing is lost)"
else bad "blocked surface staged" "pending=$(queue_pending), expected 1"; fi
if [ "$(queue_done)" = 0 ]; then ok "…and is NOT marked delivered"
else bad "blocked surface not delivered" "delivered=$(queue_done)"; fi
case "$OUT" in *"will be redelivered automatically"*) ok "the dispatcher says the announcement is queued, not lost" ;;
  *) bad "queued message" "the operator is not told the surface will be redelivered" ;; esac
case "$OUT" in *"tick is NOT re-run"*) ok "…and that the TICK is not re-run (only the announcement is retried)" ;;
  *) bad "no-re-run message" "nothing says the tick is not re-run" ;; esac

# (2) A SECOND tick completes while Zig is still away. Both must be held.
OUT=$(INJECT_VERDICT=deferred-blocked-on-human run_live_row di-tuesday "${BASE[@]}" \
      'RESULT_JSON={"row":"di-tuesday","outcome":"done","note":"newsletter post drafted","proof":{"kind":"cmd","cmd":"true"}}')
check_verdict "the second blocked tick also completes" "$OUT" completed
if [ "$(queue_pending)" = 2 ]; then ok "TWO ticks finished while blocked -> TWO pending announcements"
else bad "two pending" "pending=$(queue_pending), expected 2"; fi

# (3) The bell clears. A drain with NO NEW DISPATCH delivers both, in ONE message,
#     oldest first. This is the acceptance criterion in one command: the tick is
#     never re-run, only the announcement.
: > "$ROOT/inject.log"
DOUT=$(queue_drain --session work --window pulse)
if [ "$(surface_verdict "$DOUT")" = "delivered:2" ]
then ok "the drain delivers BOTH held announcements with no new dispatch"
else bad "drain delivers both" "verdict: $(surface_verdict "$DOUT")"; fi
if [ "$(grep -c 'REMOTE PULSE SURFACE' "$ROOT/inject.log")" = 1 ]
then ok "…in exactly ONE injection (a window that gets six pings is a window Zig mutes)"
else bad "one injection" "got $(grep -c 'REMOTE PULSE SURFACE' "$ROOT/inject.log") injections"; fi
if grep -q '2 PENDING' "$ROOT/inject.log"
then ok "the announcement says HOW MANY were pending"
else bad "pending count" "got: $(head -c 200 "$ROOT/inject.log")"; fi
_fri=$(grep -o '(1) di-friday' "$ROOT/inject.log" | head -1)
_tue=$(grep -o '(2) di-tuesday' "$ROOT/inject.log" | head -1)
if [ -n "$_fri" ] && [ -n "$_tue" ]
then ok "OLDEST FIRST: di-friday (staged first) is announced before di-tuesday"
else bad "oldest first" "ordering markers missing: '$_fri' / '$_tue'"; fi
if grep -q 'Do NOT re-run any tick' "$ROOT/inject.log"
then ok "the multi-surface announcement forbids re-running the ticks"
else bad "no-re-run in the announcement" "the drain message does not forbid a re-run"; fi
if [ "$(queue_pending)" = 0 ] && [ "$(queue_done)" = 2 ]
then ok "delivered entries MOVE out of pending (pending=0, delivered=2)"
else bad "delivered move" "pending=$(queue_pending) delivered=$(queue_done)"; fi

# (4) Nothing is announced twice.
: > "$ROOT/inject.log"
DOUT=$(queue_drain --session work --window pulse)
if [ "$(surface_verdict "$DOUT")" = "empty" ] && [ ! -s "$ROOT/inject.log" ]
then ok "a second drain announces NOTHING (delivered exactly once)"
else bad "no double-announce" "verdict $(surface_verdict "$DOUT"), inject.log: $(head -c 120 "$ROOT/inject.log")"; fi

# (5) Collapse: a row that RE-RAN while held announces its NEWEST state only.
queue_reset; : > "$ROOT/inject.log"
OUT=$(INJECT_VERDICT=deferred-blocked-on-human run_live "${BASE[@]}" \
      'RESULT_JSON={"row":"di-friday","outcome":"done","note":"STALE first attempt","proof":{"kind":"cmd","cmd":"true"}}')
check_verdict "the first (soon-stale) run completes" "$OUT" completed
OUT=$(INJECT_VERDICT=deferred-blocked-on-human run_live "${BASE[@]}" \
      'RESULT_JSON={"row":"di-friday","outcome":"done","note":"NEWEST attempt","proof":{"kind":"cmd","cmd":"true"}}')
check_verdict "the re-run also completes" "$OUT" completed
if [ "$(queue_pending)" = 1 ]
then ok "two surfaces for the SAME row collapse to ONE pending entry"
else bad "same-row collapse" "pending=$(queue_pending), expected 1"; fi
if jq -e '.superseded == 1 and (.summary | test("NEWEST"))' "$SURFQ/pending/di-friday.json" >/dev/null 2>&1
then ok "the retained entry is the NEWEST, and remembers it superseded one"
else bad "collapse keeps newest" "got: $(head -c 200 "$SURFQ/pending/di-friday.json" 2>/dev/null)"; fi
if jq -e '.first_staged_at <= .staged_at' "$SURFQ/pending/di-friday.json" >/dev/null 2>&1
then ok "first_staged_at survives the collapse (so 'oldest first' still means oldest)"
else bad "first_staged_at preserved" "timestamps do not survive collapse"; fi
: > "$ROOT/inject.log"
DOUT=$(queue_drain --session work --window pulse)
if [ "$(surface_verdict "$DOUT")" = "delivered:1" ] && grep -q 'NEWEST' "$ROOT/inject.log" \
   && ! grep -q 'STALE' "$ROOT/inject.log"
then ok "the delivered announcement carries the NEWEST run and never the stale one"
else bad "stale not announced" "got: $(head -c 240 "$ROOT/inject.log")"; fi
if grep -q 're-ran 1x while the announcement was held' "$ROOT/inject.log"
then ok "…and says out loud that the row re-ran while it was held"
else bad "collapse is stated" "the announcement hides that a run was superseded"; fi

# (6) The piggyback trigger: the NEXT surface into the window carries the held one,
#     so a held announcement has two independent ways out (this, and the 2-minute
#     pulse-retry drain proven in test-pulse-retry.sh).
queue_reset; : > "$ROOT/inject.log"
OUT=$(INJECT_VERDICT=deferred-blocked-on-human run_live "${BASE[@]}" \
      'RESULT_JSON={"row":"di-friday","outcome":"done","note":"held one","proof":{"kind":"cmd","cmd":"true"}}')
: > "$ROOT/inject.log"
OUT=$(run_live_row di-tuesday "${BASE[@]}" \
      'RESULT_JSON={"row":"di-tuesday","outcome":"done","note":"the unblocking one","proof":{"kind":"cmd","cmd":"true"}}')
check_verdict "the next tick completes" "$OUT" completed
if grep -q '2 PENDING' "$ROOT/inject.log" && grep -q 'di-friday' "$ROOT/inject.log"
then ok "the next successful surface CARRIES the previously-held announcement"
else bad "piggyback drain" "got: $(head -c 240 "$ROOT/inject.log")"; fi
if [ "$(queue_pending)" = 0 ]
then ok "…and the queue is empty afterwards"
else bad "piggyback clears the queue" "pending=$(queue_pending)"; fi
queue_reset

echo
echo "== bead requests are staged, never filed by the script =="
: > "$ROOT/inject.log"
OUT=$(run_live "${BASE[@]}" 'RESULT_JSON={"row":"di-friday","outcome":"done","note":"escalated","proof":{"kind":"cmd","cmd":"true"},"bead_request":{"priority":1,"title":"human: populate the pod weekly"}}')
check_verdict "bead_request still completes" "$OUT" completed
RUNDIR=$(ls -dt "$STATE"/*/ 2>/dev/null | head -1)
if [ -s "${RUNDIR}bead-request.json" ]; then ok "bead request staged to disk"
else bad "bead staged" "no bead-request.json"; fi
if grep -q 'REMOTE PULSE SURFACE' "$ROOT/inject.log"; then ok "a bead request wakes the local window to file it"
else bad "bead surfaces" "no injection for a bead request"; fi

echo
echo "== ledger rollback when the lint rejects the row =="
cat > "$STUB/lint-reject" <<'EOF'
#!/usr/bin/env python3
import sys; sys.exit(1)
EOF
chmod +x "$STUB/lint-reject"
BEFORE=$(wc -l < "$PROJ/refs/pulse-ledger.jsonl")
OUT=$(write_knobs "${BASE[@]}" 'RESULT_JSON={"row":"di-friday","outcome":"done","proof":{"kind":"cmd","cmd":"true"}}'
  PULSE_DISPATCH_SSH="$STUB/ssh" PULSE_DISPATCH_PREFLIGHT="$STUB/preflight" \
  PULSE_DISPATCH_INJECT="$STUB/inject" PULSE_DISPATCH_MANIFEST=/nonexistent-manifest PULSE_DISPATCH_VAULT=/nonexistent \
  PULSE_DISPATCH_LINT="$STUB/lint-reject" PULSE_DISPATCH_STATE="$STATE" HOME="$ROOT/home" \
    "$DISPATCH" --row di-friday --dir "$PROJ" --poll 1 --timeout 3 2>&1)
check_verdict "lint rejects the row -> failed-ledger" "$OUT" failed-ledger
AFTER=$(wc -l < "$PROJ/refs/pulse-ledger.jsonl")
if [ "$BEFORE" = "$AFTER" ]; then ok "the rejected row was ROLLED BACK (ledger unchanged)"
else bad "ledger rollback" "ledger grew from $BEFORE to $AFTER lines"; fi

echo
echo "== T0: the out-of-band (gitignored) push, driven by the manifest =="
# `require-oob` marks a path git can NEVER deliver (the IMC folders are
# gitignored). If it silently did not travel, a tick drafts without campaign
# context -- WRONG output, which a weekly harvest cannot catch. So both the
# push and its refusal must be proven.
cat > "$STUB/rsync" <<'RSEOF'
#!/bin/bash
printf '%s\n' "$*" >> "${RSYNC_LOG:-/dev/null}"
exit "${RSYNC_RC:-0}"
RSEOF
chmod +x "$STUB/rsync"

OOB_MAN="$ROOT/oob-manifest.txt"
printf 'require-oob $HOME/oobdir\n' > "$OOB_MAN"

run_oob_with() { OOB_MAN_OVERRIDE="$1" run_oob; }
run_oob() { # extra env assignments passed through by the caller
  # Reuse the happy-path A5/A6 fixture so this section tests the T0 push only.
  local _mem _bead
  _mem=$(cd "$ROOT/home/.claude/projects/$(printf '%s' "$PROJ" | tr '/' '-')/memory" \
         && find -L . -type f | LC_ALL=C sort | xargs -r sha256sum | sha256sum | cut -d' ' -f1)
  _bead="{\"jsonl_content_hash\":\"${LSHA:-BEADSHA}\",\"jsonl_newer\":false}"
  write_knobs 'PANE_CMD=claude' "REMOTE_MEM_SHA=$_mem" "REMOTE_BEAD_JSON=$_bead"
  env RSYNC_LOG="$ROOT/rsync.log" "$@" \
    PULSE_DISPATCH_SSH="$STUB/ssh" \
    PULSE_DISPATCH_PREFLIGHT="$STUB/preflight" \
    PULSE_DISPATCH_INJECT="$STUB/inject" \
    PULSE_DISPATCH_MANIFEST="${OOB_MAN_OVERRIDE:-$OOB_MAN}" \
    PULSE_DISPATCH_RSYNC="$STUB/rsync" \
    PULSE_DISPATCH_VAULT=/nonexistent-local-vault \
    PULSE_DISPATCH_STATE="$STATE" \
    HOME="$ROOT/home" \
      "$DISPATCH" --row di-friday --dir "$PROJ" --dry-run --poll 1 --timeout 3 2>&1
}

# (a) declared but ABSENT locally -> refuse, do not dispatch silently
rm -rf "$ROOT/home/oobdir"; : > "$ROOT/rsync.log"
OUT=$(run_oob)
check_verdict "require-oob missing on zig-computer -> failed-preflight" "$OUT" failed-preflight
case "$OUT" in *"does not exist on zig-computer"*) ok "the message says which side is missing it" ;;
  *) bad "the message says which side is missing it" "unexpected: $(printf '%s' "$OUT" | tail -2)" ;; esac

# (a2) a GLOB that matches nothing is also a failure — not a silent skip.
#      nullglob makes the array empty here, which is a DIFFERENT code path from
#      the literal case above, so both need proving.
printf 'require-oob $HOME/nomatch-*\n' > "$ROOT/glob-manifest.txt"
OUT=$(OOB_MAN="$ROOT/glob-manifest.txt" run_oob_with "$ROOT/glob-manifest.txt")
check_verdict "require-oob glob matching nothing -> failed-preflight" "$OUT" failed-preflight

# (a3) a glob that DOES match pushes every match.
mkdir -p "$ROOT/home/camp-one" "$ROOT/home/camp-two"
echo x > "$ROOT/home/camp-one/a"; echo y > "$ROOT/home/camp-two/b"
printf 'require-oob $HOME/camp-*\n' > "$ROOT/glob2-manifest.txt"
: > "$ROOT/rsync.log"
OUT=$(run_oob_with "$ROOT/glob2-manifest.txt")
check_verdict "require-oob glob with matches -> dispatch proceeds" "$OUT" dry-run-ok
if grep -q "camp-one" "$ROOT/rsync.log" && grep -q "camp-two" "$ROOT/rsync.log"
  then ok "a glob pushes EVERY match, not just the first"
  else bad "a glob pushes every match" "rsync log: $(cat "$ROOT/rsync.log")"; fi

# (a4) THE COMPLEMENT RULE + `oob-exclude` (bead dotfiles-f5tg, 2026-07-28).
#      Fixture: an umbrella repo with one TRACKED child, one plain UNTRACKED
#      child, and one untracked child that carries its OWN .git.
UMB="$ROOT/home/umb"
rm -rf "$UMB"; mkdir -p "$UMB"/{tracked-kid,oob-kid,own-repo-kid}
echo t > "$UMB/tracked-kid/f"; echo o > "$UMB/oob-kid/f"; echo r > "$UMB/own-repo-kid/f"
git -C "$UMB" init -q
git -C "$UMB" config user.email t@example.invalid; git -C "$UMB" config user.name t
git -C "$UMB" add tracked-kid >/dev/null 2>&1; git -C "$UMB" commit -qm root >/dev/null 2>&1
git -C "$UMB/own-repo-kid" init -q     # a NESTED INDEPENDENT repo, untracked above

# (a4.1) Baseline: the complement ships every untracked child — INCLUDING one
#        that has its own .git. This is the guard against "simplifying"
#        oob-exclude into an inferred `[ -e "$_c/.git" ] && continue`. That
#        inference looks equivalent and is not: imc-aug26 has its own .git AND an
#        lb-marketing remote this box's PAT 404s on, so rsync is its only
#        transport. Inferring would drop it silently and a tick would draft
#        without campaign context — wrong output, not missing output.
printf 'require-oob-untracked $HOME/umb\n' > "$ROOT/compl-manifest.txt"
: > "$ROOT/rsync.log"
OUT=$(run_oob_with "$ROOT/compl-manifest.txt")
check_verdict "complement rule -> dispatch proceeds" "$OUT" dry-run-ok
if grep -q 'umb/oob-kid' "$ROOT/rsync.log"
  then ok "complement ships a plain untracked child"
  else bad "complement ships untracked child" "rsync log: $(cat "$ROOT/rsync.log")"; fi
if grep -q 'umb/own-repo-kid' "$ROOT/rsync.log"
  then ok "complement ships an untracked child that has its OWN .git (the imc-aug26 case)"
  else bad "untracked child with own .git still ships" \
       "REGRESSION: something is inferring git-ownership from .git — that silently strands imc-*"; fi
if grep -q 'umb/tracked-kid' "$ROOT/rsync.log"
  then bad "complement skips tracked children" "tracked-kid was rsync'd; git already owns it"
  else ok "complement skips tracked children"; fi

# (a4.2) `oob-exclude` removes exactly the declared child and nothing else.
printf 'require-oob-untracked $HOME/umb\noob-exclude $HOME/umb/own-repo-kid\n' \
  > "$ROOT/compl-excl-manifest.txt"
: > "$ROOT/rsync.log"
OUT=$(run_oob_with "$ROOT/compl-excl-manifest.txt")
check_verdict "oob-exclude -> dispatch proceeds" "$OUT" dry-run-ok
if grep -q 'umb/own-repo-kid' "$ROOT/rsync.log"
  then bad "oob-exclude drops the declared child" "own-repo-kid was still rsync'd"
  else ok "oob-exclude drops the declared child (lb-granola pulls itself instead)"; fi
if grep -q 'umb/oob-kid' "$ROOT/rsync.log"
  then ok "oob-exclude does not affect its siblings"
  else bad "oob-exclude leaves siblings alone" "oob-kid stopped shipping too"; fi

# (a4.3) Directive ORDER must not matter — the pre-scan exists for this.
printf 'oob-exclude $HOME/umb/own-repo-kid\nrequire-oob-untracked $HOME/umb\n' \
  > "$ROOT/compl-order-manifest.txt"
: > "$ROOT/rsync.log"
OUT=$(run_oob_with "$ROOT/compl-order-manifest.txt")
if grep -q 'umb/own-repo-kid' "$ROOT/rsync.log"
  then bad "oob-exclude works before its require-oob-untracked" \
       "order-dependent: the exclusion was not yet known when the complement enumerated"
  else ok "oob-exclude works regardless of directive order"; fi

run_row() { # run_row <row> [extra args...]
  local _row=$1; shift
  # Full happy-path fixture: A5/A6 run BEFORE pane resolution, so a knobs-light
  # run fails at the memory assertion and never reaches the tmux session at all.
  local _mem _bead
  _mem=$(cd "$ROOT/home/.claude/projects/$(printf '%s' "$PROJ" | tr '/' '-')/memory" \
         && find -L . -type f | LC_ALL=C sort | xargs -r sha256sum | sha256sum | cut -d' ' -f1)
  _bead="{\"jsonl_content_hash\":\"${LSHA:-BEADSHA}\",\"jsonl_newer\":false}"
  write_knobs 'PANE_CMD=claude' "REMOTE_MEM_SHA=$_mem" "REMOTE_BEAD_JSON=$_bead"
  SSH_LOG="$ROOT/ssh.log" \
  PULSE_DISPATCH_SSH="$STUB/ssh" \
  PULSE_DISPATCH_PREFLIGHT="$STUB/preflight" \
  PULSE_DISPATCH_INJECT="$STUB/inject" PULSE_DISPATCH_MANIFEST=/nonexistent-manifest \
  PULSE_DISPATCH_VAULT=/nonexistent-local-vault \
  PULSE_DISPATCH_STATE="$STATE" HOME="$ROOT/home" \
    "$DISPATCH" --row "$_row" --dir "$PROJ" --dry-run --poll 1 --timeout 3 "$@" >/dev/null 2>&1
}
run_row_out() { # same, but returns the dispatcher's output
  local _row=$1; shift
  local _mem _bead
  _mem=$(cd "$ROOT/home/.claude/projects/$(printf '%s' "$PROJ" | tr '/' '-')/memory" \
         && find -L . -type f | LC_ALL=C sort | xargs -r sha256sum | sha256sum | cut -d' ' -f1)
  _bead="{\"jsonl_content_hash\":\"${LSHA:-BEADSHA}\",\"jsonl_newer\":false}"
  write_knobs 'PANE_CMD=claude' "REMOTE_MEM_SHA=$_mem" "REMOTE_BEAD_JSON=$_bead"
  SSH_LOG="$ROOT/ssh.log" PULSE_DISPATCH_SSH="$STUB/ssh" PULSE_DISPATCH_PREFLIGHT="$STUB/preflight" \
  PULSE_DISPATCH_INJECT="$STUB/inject" PULSE_DISPATCH_MANIFEST=/nonexistent-manifest \
  PULSE_DISPATCH_VAULT=/nonexistent-local-vault PULSE_DISPATCH_STATE="$STATE" HOME="$ROOT/home" \
    "$DISPATCH" --row "$_row" --dir "$PROJ" --dry-run --poll 1 --timeout 3 "$@" 2>&1
}

# (a3.2) A BLOCKED DISPATCH RINGS work:pulse. Not because the block was invisible —
#        the harnessd loop list shows the row stale after its grace window — but
#        that signal is pull-based, delayed, and does not say WHY. A timer-fired
#        block should reach Zig immediately, with the reason.
: > "$ROOT/inject.log"
OUT=$(env INJECT_LOG="$ROOT/inject.log" REMOTE_VAULT_RC=1 \
  SSH_LOG="$ROOT/ssh.log" PULSE_DISPATCH_SSH="$STUB/ssh" \
  PULSE_DISPATCH_PREFLIGHT="$STUB/preflight" PULSE_DISPATCH_INJECT="$STUB/inject" \
  PULSE_DISPATCH_MANIFEST=/nonexistent-manifest PULSE_DISPATCH_VAULT=/nonexistent-local-vault \
  PULSE_DISPATCH_STATE="$STATE" HOME="$ROOT/home" \
  "$DISPATCH" --row di-tuesday --dir "$PROJ" --poll 1 --timeout 3 2>&1 || true)
if grep -q "REMOTE PULSE SURFACE" "$ROOT/inject.log"
  then ok "a blocked dispatch surfaces to the local window"
  else bad "a blocked dispatch surfaces locally" "nothing injected on a block"; fi
if grep -q "session work" "$ROOT/inject.log" || grep -q -- "--session work" "$ROOT/inject.log"
  then ok "the block surfaces to session 'work'"
  else bad "block surfaces to work" "wrong session: $(head -1 "$ROOT/inject.log" | cut -c1-80)"; fi
if grep -q -- "--window pulse" "$ROOT/inject.log"
  then ok "the block surfaces to window 'pulse' (the alert interface)"
  else bad "block surfaces to pulse" "wrong window"; fi
# A --dry-run must NEVER wake the window: it is a human at a terminal already.
: > "$ROOT/inject.log"; run_row di-tuesday
if grep -q "REMOTE PULSE SURFACE" "$ROOT/inject.log"
  then bad "a dry-run does not wake the window" "dry-run surfaced"
  else ok "a dry-run does not wake the window"; fi

# (a3.3) A7 — claude must COMPLETE A REQUEST, not merely resolve. A4 passed all of
#        2026-07-27 while the box's inherited ANTHROPIC_BASE_URL made every claude
#        call fail; only a live request can tell those apart.
OUT=$(A7_BODY='Error: connect ECONNREFUSED 100.x.x.x:443' run_row_out di-tuesday)
check_verdict "A7 fails when claude cannot reach the API" "$OUT" failed-no-claude
case "$OUT" in *"ANTHROPIC_BASE_URL"*) ok "the A7 failure names the gateway to check" ;;
  *) bad "A7 failure names the gateway" "no ANTHROPIC_BASE_URL hint in the message" ;; esac
OUT=$(run_row_out di-tuesday)
case "$OUT" in *"preflight A7: OK"*) ok "A7 passes on a working box" ;;
  *) bad "A7 passes on a working box" "no A7 OK line"; esac

# (a3.4) --fresh: clear a WARM remote pane before dispatching, so a weekly row
#        does not resume last week's conversation. No-op when cold-launched.
: > "$ROOT/ssh.log"; OUT_FRESH=$(run_row_out di-tuesday --fresh)
# send-keys payloads are base64'd onto the ssh command line (that is how a literal
# with spaces/slashes survives the hop), so the plain string never appears. Assert
# on the ENCODED form — grepping "/clear" here fails while the code is correct.
# --dry-run deliberately stops BEFORE dispatching, so no /clear ever reaches the
# wire here; assert on the reported DECISION, which is the logic under test.
case "$OUT_FRESH" in *"would clear:   /clear into"*) ok "--fresh clears a warm remote pane" ;;
  *) bad "--fresh clears a warm remote pane" "dry-run did not report a clear: $(printf '%s' "$OUT_FRESH" | grep 'would' | head -2)" ;; esac
: > "$ROOT/ssh.log"; run_row di-tuesday
OUT_NOFRESH=$(run_row_out di-tuesday)
case "$OUT_NOFRESH" in *"would clear:"*) bad "no --fresh means no /clear" "reported a clear unasked" ;;
  *) ok "no --fresh means no /clear" ;; esac
# cold pane: PANE_CMD unset -> the dispatcher launches claude itself, so a /clear
# would be pure cost. This is the case that made --fresh opt-in rather than always.
: > "$ROOT/ssh.log"
write_knobs 'PANE_CMD=zsh'
# Reset the knobs: this case runs after ones that set failure knobs (a stale
# REMOTE_VAULT_RC made it die at failed-vault, nowhere near the code under test).
_mem=$(cd "$ROOT/home/.claude/projects/$(printf '%s' "$PROJ" | tr '/' '-')/memory" \
       && find -L . -type f | LC_ALL=C sort | xargs -r sha256sum | sha256sum | cut -d' ' -f1)
write_knobs 'PANE_CMD=zsh' "REMOTE_MEM_SHA=$_mem" \
  "REMOTE_BEAD_JSON={\"jsonl_content_hash\":\"${LSHA:-BEADSHA}\",\"jsonl_newer\":false}"
# `VAR=x OUT=$(cmd)` attaches the prefixes to the ASSIGNMENT, not to cmd, so the
# subshell never sees them and the dispatcher runs without its stubs. Use `env`.
OUT_COLD=$(env SSH_LOG="$ROOT/ssh.log" PULSE_DISPATCH_SSH="$STUB/ssh" \
  PULSE_DISPATCH_PREFLIGHT="$STUB/preflight" PULSE_DISPATCH_INJECT="$STUB/inject" \
  PULSE_DISPATCH_MANIFEST=/nonexistent-manifest PULSE_DISPATCH_VAULT=/nonexistent-local-vault \
  PULSE_DISPATCH_STATE="$STATE" HOME="$ROOT/home" \
  "$DISPATCH" --row di-tuesday --dir "$PROJ" --dry-run --fresh --poll 1 --timeout 3 2>&1 || true)
case "$OUT_COLD" in *"would clear:   nothing"*) ok "--fresh is a no-op on a cold pane" ;;
  *) bad "--fresh is a no-op on a cold pane" "expected the no-op line; got: $(printf '%s' "$OUT_COLD" | tail -1)" ;; esac

# (a3.5) ONE SESSION, ONE WINDOW PER ROW — `work:di-monday`, `work:di-tuesday`, …
#        mirroring the local layout (Zig, 2026-07-27). A window is still its own
#        pane and its own Claude session, so rows cannot bleed context; what IS
#        shared is the tmux ENVIRONMENT, which is why teardown is refcounted.
: > "$ROOT/ssh.log"; run_row di-tuesday
if grep -q "=work" "$ROOT/ssh.log"
  then ok "the box uses ONE session named work"
  else bad "the box uses ONE session named work" "no work-session call in the ssh log"; fi
if grep -q "di-tuesday" "$ROOT/ssh.log"
  then ok "the row names its WINDOW"
  else bad "the row names its window" "no di-tuesday window in the ssh calls"; fi
: > "$ROOT/ssh.log"; run_row di-friday
if grep -q "di-tuesday" "$ROOT/ssh.log"
  then bad "a different row targets a different window" "di-friday touched di-tuesday's window"
  else ok "a different row targets a different window"; fi
# An EXISTING window must be reused, not duplicated — otherwise a weekly row grows
# a new window every week and --fresh clears the wrong one.
: > "$ROOT/ssh.log"; WIN_LINES='@4 di-tuesday' run_row di-tuesday
if grep -q "new-window" "$ROOT/ssh.log"
  then bad "an existing window is REUSED, not recreated" "created a second di-tuesday window"
  else ok "an existing window is REUSED, not recreated"; fi
: > "$ROOT/ssh.log"; OUT=$(run_row_out di-tuesday --remote-session custom-sess)
if grep -q "custom-sess" "$ROOT/ssh.log"
  then ok "--remote-session still overrides the session name"
  else bad "--remote-session overrides" "explicit session was ignored"; fi
# Credential teardown must be REFCOUNTED: rows share one session env, so an
# unconditional unset would strip credentials from a row still mid-tick.
: > "$ROOT/ssh.log"; FLEET_API_TOKEN=t run_row di-tuesday --with-fleet-token
if grep -q "inflight" "$ROOT/ssh.log"
  then ok "the dispatch claims a credential refcount marker"
  else bad "credential refcount is claimed" "no inflight marker in the ssh calls"; fi

# (a4) THE SECRET GATE. A denylist is a list of things someone thought of; the
#      scanner is the actual guarantee, and under the complement rule any new
#      untracked folder ships automatically. So a hit must REFUSE, not warn.
cat > "$STUB/scrub-hit" <<'SCEOF'
#!/bin/bash
echo "scan: 1 files with matches, 1 secret matches" >&2
exit 1
SCEOF
cat > "$STUB/scrub-clean" <<'SCEOF'
#!/bin/bash
exit 0
SCEOF
chmod +x "$STUB/scrub-hit" "$STUB/scrub-clean"

mkdir -p "$ROOT/home/oobdir"; echo x > "$ROOT/home/oobdir/a"
: > "$ROOT/rsync.log"
OUT=$(run_oob PULSE_DISPATCH_SCRUB="$STUB/scrub-hit")
check_verdict "scanner finds a secret -> failed-preflight" "$OUT" failed-preflight
case "$OUT" in *"REFUSING to push"*) ok "the refusal names the push it blocked" ;;
  *) bad "the refusal names the push" "unexpected: $(printf '%s' "$OUT" | tail -2)" ;; esac
if grep -q "oobdir" "$ROOT/rsync.log"
  then bad "a scanner hit blocks the push BEFORE rsync runs" "rsync ran anyway"
  else ok "a scanner hit blocks the push BEFORE rsync runs"; fi

: > "$ROOT/rsync.log"
OUT=$(run_oob PULSE_DISPATCH_SCRUB="$STUB/scrub-clean")
check_verdict "scanner clean -> dispatch proceeds" "$OUT" dry-run-ok

# (b) present -> it is actually pushed, and credentials are excluded
mkdir -p "$ROOT/home/oobdir"; echo x > "$ROOT/home/oobdir/brief.md"
: > "$ROOT/rsync.log"
OUT=$(run_oob)
check_verdict "require-oob present -> dispatch proceeds" "$OUT" dry-run-ok
if grep -q "oobdir" "$ROOT/rsync.log"; then ok "the out-of-band path was actually rsynced"
  else bad "the out-of-band path was actually rsynced" "rsync stub never saw it"; fi
if grep -q -- "--exclude=.env" "$ROOT/rsync.log" && grep -q -- "service-account" "$ROOT/rsync.log"
  then ok "credentials are excluded from the push"
  else bad "credentials are excluded from the push" "exclusion flags absent from the rsync call"; fi

# (c) rsync itself fails -> refuse, never proceed on a partial push
: > "$ROOT/rsync.log"
OUT=$(run_oob RSYNC_RC=1)
check_verdict "rsync failure -> failed-preflight" "$OUT" failed-preflight

echo
echo "== dirty checkouts PROCEED, and are FLAGGED everywhere (dotfiles-f4ub) =="
# Zig, 2026-07-30: "pulses shouldn't trigger a tripwire if state is dirty. they
# should proceed, so they can work in messy repos... they're all WIPs."
#
# Removing the gate removes the thing that made a stale-code run impossible, so
# the replacement is FLAGGING and these cases are its guard. The failure this must
# not create is a tick that ran against a dirty or stale tree and said nothing —
# "missing output he catches, WRONG output he cannot."
DIRTY_REPORT='{"clean":false,"local_dirty":["$HOME/linearb: uncommitted tracked changes stay HERE -  M refs/beats.md"],"remote_dirty":[{"repo":"/home/andrew/linearb","paths":["refs/benchmarks-2026.md"]}],"stalled":["/home/andrew/linearb"]}'

# (a) DRY RUN — a dirty box does not block, and the dry run NAMES the dirt.
OUT=$(run_dry 'PANE_CMD=claude' "REMOTE_MEM_SHA=$MEMSHA" "REMOTE_BEAD_JSON=$BEADJSON" \
      "PF_REPORT_JSON=$DIRTY_REPORT")
check_verdict "a DIRTY checkout still reaches dry-run-ok" "$OUT" dry-run-ok
case "$OUT" in *"benchmarks-2026.md"*) ok "the dry run NAMES the dirty path (not just 'not clean')" ;;
  *) bad "dry run names the dirty path" "output never mentioned the file" ;; esac
case "$OUT" in *"STALE"*) ok "a refused fast-forward is called STALE on the dry run" ;;
  *) bad "dry run flags staleness" "no STALE line" ;; esac
case "$OUT" in *"clean=false"*) ok "the dry run states clean=false plainly" ;;
  *) bad "dry run states clean=false" "no clean= line" ;; esac

# (b) LIVE RUN — the tick's DISPATCH.md carries the state AND the WIP guard.
: > "$ROOT/inject.log"
OUT=$(run_live "${BASE[@]}" "PF_REPORT_JSON=$DIRTY_REPORT" \
      'RESULT_JSON={"row":"di-friday","outcome":"done","note":"worked in a messy tree","proof":{"kind":"cmd","cmd":"true"}}')
check_verdict "a DIRTY checkout still completes a live dispatch" "$OUT" completed
RUNDIR=$(ls -dt "$STATE"/*/ 2>/dev/null | head -1)
DM="${RUNDIR}DISPATCH.md"
if [ -s "$DM" ]; then
  grep -q 'benchmarks-2026.md' "$DM" \
    && ok "DISPATCH.md tells the tick WHICH files are dirty on the box" \
    || bad "DISPATCH.md names the dirt" "the dirty path is not in the contract the tick reads"
  grep -q 'STALE CODE WARNING' "$DM" \
    && ok "DISPATCH.md warns the tick it may be running older logic" \
    || bad "DISPATCH.md warns about staleness" "no stale-code warning"
  # THE WIP GUARD. All four forbidden forms, because the first draft of this rule
  # listed only three and the missing one — a DIRECTORY pathspec — is what staged
  # 12 deletions on the box on 2026-07-30 (`git add refs/doc-scripts`).
  grep -q 'git add -A' "$DM"       && ok "WIP guard forbids git add -A"     || bad "WIP guard: git add -A" "absent"
  grep -q 'git add \.`' "$DM"      && ok "WIP guard forbids git add ."      || bad "WIP guard: git add ." "absent"
  grep -q 'git commit -a' "$DM"    && ok "WIP guard forbids git commit -a"  || bad "WIP guard: git commit -a" "absent"
  grep -q 'directory or glob pathspec' "$DM" \
    && ok "WIP guard forbids a DIRECTORY/glob pathspec (the one the first draft missed)" \
    || bad "WIP guard: directory pathspec" "the forbidden-directory rule is absent"
  grep -q -- '--diff-filter=D' "$DM" \
    && ok "WIP guard ships the staged-deletion pre-commit check" \
    || bad "WIP guard: --diff-filter=D check" "the belt-and-braces check is absent"
  # And the anti-cleanup half: the tick must never tidy somebody else's WIP.
  grep -q 'No `git checkout -- <path>`' "$DM" \
    && ok "DISPATCH.md forbids the tick from reverting anything" \
    || bad "DISPATCH.md forbids reverting" "no anti-cleanup rule"
else
  bad "DISPATCH.md staged locally" "no DISPATCH.md at $DM"
fi

# (c) THE LEDGER ROW. This is the durable half: a reader six weeks later must be
#     able to tell whether an artifact came from a clean, dirty or stale checkout.
LINE=$(tail -1 "$PROJ/refs/pulse-ledger.jsonl")
if printf '%s' "$LINE" | jq -e '.dispatch.checkout.clean == false' >/dev/null 2>&1
then ok "the ledger row records checkout.clean=false"
else bad "ledger records checkout state" "got: $(printf '%.200s' "$LINE")"; fi
if printf '%s' "$LINE" | jq -e '.dispatch.checkout.remote_dirty[0].paths[0] == "refs/benchmarks-2026.md"' >/dev/null 2>&1
then ok "the ledger row names the dirty paths"
else bad "ledger names dirty paths" "got: $(printf '%.200s' "$LINE")"; fi
if printf '%s' "$LINE" | jq -e '.dispatch.checkout.stalled | length == 1' >/dev/null 2>&1
then ok "the ledger row records the stalled checkout"
else bad "ledger records stalled" "got: $(printf '%.200s' "$LINE")"; fi

# (d) The CLEAN control. A flag that fires unconditionally is not a flag, and a
#     ledger that says "dirty" on every row teaches its reader to skip the field.
OUT=$(run_live "${BASE[@]}" 'PF_REPORT_JSON={"clean":true,"local_dirty":[],"remote_dirty":[],"stalled":[]}' \
      'RESULT_JSON={"row":"di-friday","outcome":"done","note":"clean run","proof":{"kind":"cmd","cmd":"true"}}')
check_verdict "a clean checkout still completes" "$OUT" completed
LINE=$(tail -1 "$PROJ/refs/pulse-ledger.jsonl")
if printf '%s' "$LINE" | jq -e '.dispatch.checkout.clean == true' >/dev/null 2>&1
then ok "a clean run records checkout.clean=true (the flag is not always-on)"
else bad "clean control" "got: $(printf '%.200s' "$LINE")"; fi
RUNDIR=$(ls -dt "$STATE"/*/ 2>/dev/null | head -1)
if grep -q 'Every managed checkout on this box is CLEAN' "${RUNDIR}DISPATCH.md" 2>/dev/null
then ok "a clean run tells the tick so, in the same slot"
else bad "clean DISPATCH.md" "the clean-state sentence is missing"; fi

echo
echo "== dirty is a WARN in the REAL vps-preflight; committed drift still BLOCKS =="
if [ -x "$PF" ]; then
  # The gate that forced the lin-22h "parking" workaround: uncommitted changes on
  # ZIG-COMPUTER used to exit 72, so an in-flight edit had to be encoded into a
  # bead as a patch and the tree restored — the gate's own remedy was "delete the
  # work". Now it warns and carries on.
  pf_fixture dirty
  echo "an uncommitted edit" >> "$PFDIR/repo/refs/pulse.md"
  RPT="$PFDIR/report.json"
  OUT=$(printf '%s' "{\"ok\":true,\"generated_epoch\":$(date -u +%s),\"repos\":[{\"path\":\"/home/andrew/repo\",\"head\":\"$LOCAL_HEAD\",\"in_sync\":true,\"pull_ok\":true,\"pull_advanced\":true}],\"submodules\":[],\"required\":[],\"harvested\":[],\"dirty\":[{\"repo\":\"/home/andrew/repo\",\"paths\":[\"refs/x.md\"]}]}" > "$PFDIR/receipt.json"
        cat > "$PFDIR/ssh" <<PFSSH
#!/bin/bash
last="\${@: -1}"
case "\$last" in *receipt*|*cat*) cat "$PFDIR/receipt.json" ;; esac
exit 0
PFSSH
        chmod +x "$PFDIR/ssh"
        PATH="$PFDIR:$PATH" "$PF" --manifest "$MANIFEST" --no-refresh --quiet --report "$RPT" 2>&1
        echo "EXIT=$?")
  case "$OUT" in *"EXIT=0"*) ok "local uncommitted changes NO LONGER block (they warn)" ;;
    *) bad "dirty local warns" "expected EXIT=0, got: $(printf '%.240s' "$OUT")" ;; esac
  case "$OUT" in *"DIRTY"*) ok "the preflight says DIRTY out loud" ;;
    *) bad "preflight says DIRTY" "no DIRTY line in: $(printf '%.240s' "$OUT")" ;; esac
  case "$OUT" in *"checkout -- "*|*"reset --hard"*)
      bad "the preflight never suggests reverting" "it printed revert advice, which is how verified work gets destroyed" ;;
    *) ok "the preflight never suggests reverting a dirty file" ;; esac
  if [ -s "$RPT" ] && jq -e '.clean == false and (.local_dirty|length) == 1 and (.remote_dirty[0].paths[0] == "refs/x.md")' "$RPT" >/dev/null 2>&1
  then ok "--report carries local dirt AND the receipt's remote dirt to the dispatcher"
  else bad "--report contents" "got: $(cat "$RPT" 2>/dev/null | head -c 240)"; fi

  # The pairing that keeps the relaxation honest. A2 — COMMITTED but unpublished —
  # is a different axis and stays a hard block (dotfiles-f4ub scope decision): it
  # means the box would run genuinely different code, which dirt does not.
  pf_fixture unpushed
  echo more >> "$PFDIR/repo/refs/pulse.md"
  git -C "$PFDIR/repo" commit -qam "committed here, never pushed"
  OUT=$(pf_run "{\"ok\":true,\"generated_epoch\":$(date -u +%s),\"repos\":[{\"path\":\"/home/andrew/repo\",\"head\":\"$LOCAL_HEAD\",\"in_sync\":true}],\"submodules\":[],\"required\":[],\"harvested\":[]}")
  case "$OUT" in *"EXIT=72"*) ok "A2 (committed-but-unpublished) STILL blocks — the relaxation is dirt-only" ;;
    *) bad "A2 still blocks" "expected EXIT=72, got: $(printf '%.240s' "$OUT")" ;; esac

  # ...and so does a box that refused its fast-forward far enough to fall behind.
  pf_fixture refused
  OUT=$(pf_run "{\"ok\":true,\"generated_epoch\":$(date -u +%s),\"repos\":[{\"path\":\"/home/andrew/repo\",\"head\":\"1111111111111111111111111111111111111111\",\"in_sync\":false,\"pull_ok\":false,\"pull_advanced\":false}],\"submodules\":[],\"required\":[],\"harvested\":[],\"dirty\":[]}")
  case "$OUT" in *"EXIT=74"*) ok "a box left BEHIND by a refused pull still blocks on identity" ;;
    *) bad "stale box blocks" "expected EXIT=74, got: $(printf '%.240s' "$OUT")" ;; esac
  case "$OUT" in *"REFUSED"*) ok "and the block explains WHY it is behind (a WIP edit was in the way)" ;;
    *) bad "block explains why" "no REFUSED explanation: $(printf '%.240s' "$OUT")" ;; esac
  case "$OUT" in *"do NOT reset it"*) ok "the remedy is explicitly non-destructive" ;;
    *) bad "non-destructive remedy" "the block does not warn against resetting" ;; esac
else
  echo "  SKIP  dirty-preflight cases (vps-preflight.sh not executable)"
fi

echo
echo "== BEHIND is fast-forwarded; AHEAD and DIVERGED still BLOCK (dotfiles-w16i) =="
# marketing-vps is a peer that commits and pushes on its own, so zig-computer
# falling BEHIND the published tip is the ROUTINE state, not a fault — and A2
# fail-closing on it killed four ticks in two days. The three states are now
# distinguished by REAL GIT ANCESTRY (not a string compare against ls-remote) and
# only the one that cannot lose work is repaired here.
#
# The bug being guarded is subtle and it is why case (a) checks the SHAS: the old
# code asked `merge-base --is-ancestor` WITHOUT FETCHING, so for exactly the
# commits we were behind by the published object did not exist locally, both arms
# errored, and every plain BEHIND printed "HISTORIES DIVERGED ... reset --hard".
# The 2026-07-31 19:00Z instance aimed that at a repo holding 8 commits that
# existed nowhere else on this machine.
if [ -x "$PF" ]; then
  # Advance "GitHub" without touching $PFDIR/repo — that separation is the whole
  # fixture: the local checkout must genuinely not have the incoming objects.
  pf_upstream_commit() {
    local seed="$PFDIR/seed"
    if [ ! -d "$seed" ]; then git clone -q "$PFDIR/origin.git" "$seed"; fi
    git -C "$seed" fetch -q origin main
    git -C "$seed" checkout -q -B main origin/main
    echo "$1" >> "$seed/refs/pulse.md"
    git -C "$seed" commit -qam "$1"
    git -C "$seed" push -q origin main
  }

  # (a) BEHIND -> fast-forwarded here, dispatch PROCEEDS, and it is RECORDED.
  pf_fixture behind
  pf_upstream_commit v2; pf_upstream_commit v3
  TIP=$(git -C "$PFDIR/origin.git" rev-parse main)
  BEFORE=$(git -C "$PFDIR/repo" rev-parse HEAD)
  RPT="$PFDIR/report.json"
  # Proof that the fixture reproduces the misdiagnosis precondition: before the
  # preflight runs, the published commit is NOT an object in this repo.
  if git -C "$PFDIR/repo" cat-file -e "${TIP}^{commit}" 2>/dev/null
  then bad "behind fixture" "the published tip is already local — the fixture does not reproduce the bug"
  else ok "fixture: the published tip is not yet an object here (the old code's blind spot)"; fi
  OUT=$(printf '%s' "{\"ok\":true,\"generated_epoch\":$(date -u +%s),\"repos\":[{\"path\":\"/home/andrew/repo\",\"head\":\"$TIP\",\"in_sync\":true,\"pull_ok\":true,\"pull_advanced\":true}],\"submodules\":[],\"required\":[],\"harvested\":[],\"dirty\":[]}" > "$PFDIR/receipt.json"
        cat > "$PFDIR/ssh" <<PFSSH
#!/bin/bash
last="\${@: -1}"
case "\$last" in *receipt*|*cat*) cat "$PFDIR/receipt.json" ;; esac
exit 0
PFSSH
        chmod +x "$PFDIR/ssh"
        PATH="$PFDIR:$PATH" "$PF" --manifest "$MANIFEST" --no-refresh --quiet --report "$RPT" 2>&1
        echo "EXIT=$?")
  case "$OUT" in *"EXIT=0"*) ok "BEHIND: the preflight PROCEEDS instead of blocking" ;;
    *) bad "behind proceeds" "expected EXIT=0, got: $(printf '%.240s' "$OUT")" ;; esac
  if [ "$(git -C "$PFDIR/repo" rev-parse HEAD)" = "$TIP" ] && [ "$BEFORE" != "$TIP" ]
  then ok "BEHIND: HEAD actually moved ${BEFORE:0:8} -> ${TIP:0:8} (a real fast-forward, not a message change)"
  else bad "behind fast-forwards" "HEAD is $(git -C "$PFDIR/repo" rev-parse HEAD), expected $TIP"; fi
  case "$OUT" in *"FAST-FORWARDED"*) ok "BEHIND: the catch-up is said out loud, never silent" ;;
    *) bad "behind is announced" "no FAST-FORWARDED line: $(printf '%.240s' "$OUT")" ;; esac
  case "$OUT" in *"DIVERGED"*) bad "behind is not misdiagnosed" "it still printed DIVERGED — the four-times bug" ;;
    *) ok "BEHIND: never misreported as DIVERGED (the bug that fired 4x in 2 days)" ;; esac
  case "$OUT" in *"reset --hard"*) bad "behind never says reset --hard" "the dangerous remedy appeared on a merely-behind repo" ;;
    *) ok "BEHIND: 'reset --hard' does NOT appear (the remedy text was the dangerous part)" ;; esac
  if [ -s "$RPT" ] && jq -e --arg f "${BEFORE:0:8}" --arg t "${TIP:0:8}" \
       '(.auto_ff|length) == 1 and .auto_ff[0].from == $f and .auto_ff[0].to == $t and .auto_ff[0].commits == 2' \
       "$RPT" >/dev/null 2>&1
  then ok "BEHIND: --report records repo + from-sha + to-sha + commit count"
  else bad "auto_ff in --report" "got: $(head -c 240 "$RPT" 2>/dev/null)"; fi
  if jq -e '.clean == true' "$RPT" >/dev/null 2>&1
  then ok "BEHIND: clean stays TRUE — a caught-up tree is not dirt, and must not read as dirt"
  else bad "auto_ff vs clean" "an auto-fast-forward wrongly flipped clean=false"; fi

  # (b) AHEAD -> still blocks. This is axis 3 proper: committed work the box
  #     cannot see. A pull cannot deliver it, so a human must push.
  pf_fixture ahead
  echo mine >> "$PFDIR/repo/refs/pulse.md"
  git -C "$PFDIR/repo" commit -qam "committed here, never pushed"
  AHEAD_HEAD=$(git -C "$PFDIR/repo" rev-parse HEAD)
  OUT=$(pf_run "{\"ok\":true,\"generated_epoch\":$(date -u +%s),\"repos\":[{\"path\":\"/home/andrew/repo\",\"head\":\"$LOCAL_HEAD\",\"in_sync\":true}],\"submodules\":[],\"required\":[],\"harvested\":[]}")
  case "$OUT" in *"EXIT=72"*) ok "AHEAD: still BLOCKS (72) — the auto-ff is strictly for the behind case" ;;
    *) bad "ahead blocks" "expected EXIT=72, got: $(printf '%.240s' "$OUT")" ;; esac
  case "$OUT" in *"AHEAD"*"push origin main"*) ok "AHEAD: the remedy is push, and it says which direction it drifted" ;;
    *) bad "ahead remedy" "expected an AHEAD + push remedy: $(printf '%.240s' "$OUT")" ;; esac
  case "$OUT" in *"reset --hard"*) bad "ahead never says reset --hard" "it offered to discard the unpushed commit" ;;
    *) ok "AHEAD: 'reset --hard' does NOT appear" ;; esac
  if [ "$(git -C "$PFDIR/repo" rev-parse HEAD)" = "$AHEAD_HEAD" ]
  then ok "AHEAD: the local commit is UNTOUCHED"
  else bad "ahead untouched" "HEAD moved on a repo the gate must not touch"; fi

  # (c) DIVERGED -> still blocks, and it is the ONLY state allowed to name the
  #     destructive remedy, with its warning intact.
  pf_fixture diverged
  pf_upstream_commit v2
  echo mine > "$PFDIR/repo/refs/other.md"
  git -C "$PFDIR/repo" add refs/other.md; git -C "$PFDIR/repo" commit -qm "mine"
  DIV_HEAD=$(git -C "$PFDIR/repo" rev-parse HEAD)
  TIP=$(git -C "$PFDIR/origin.git" rev-parse main)
  OUT=$(pf_run "{\"ok\":true,\"generated_epoch\":$(date -u +%s),\"repos\":[{\"path\":\"/home/andrew/repo\",\"head\":\"$TIP\",\"in_sync\":true}],\"submodules\":[],\"required\":[],\"harvested\":[]}")
  case "$OUT" in *"EXIT=72"*) ok "DIVERGED: still BLOCKS (72)" ;;
    *) bad "diverged blocks" "expected EXIT=72, got: $(printf '%.240s' "$OUT")" ;; esac
  case "$OUT" in *"HISTORIES DIVERGED"*) ok "DIVERGED: named as such, and only here" ;;
    *) bad "diverged named" "no HISTORIES DIVERGED line: $(printf '%.240s' "$OUT")" ;; esac
  case "$OUT" in *"reset --hard"*"DISCARDS local commits"*)
      ok "DIVERGED: the destructive remedy appears WITH its warning intact" ;;
    *) bad "diverged remedy" "reset --hard is missing or unwarned: $(printf '%.240s' "$OUT")" ;; esac
  if [ "$(git -C "$PFDIR/repo" rev-parse HEAD)" = "$DIV_HEAD" ]
  then ok "DIVERGED: nothing was reset — the gate only PRINTS the remedy"
  else bad "diverged untouched" "the gate moved HEAD on a diverged repo"; fi

  # (d) BEHIND but the fast-forward CANNOT be applied (a WIP edit is in the way).
  #     Never force, never stash, never reset: warn, and fall through to the block
  #     that was already there. This is the case that keeps the feature from being
  #     a hole — an auto-repair whose failure mode is "try harder" is a data-loss
  #     bug waiting for its morning.
  pf_fixture ffblocked
  pf_upstream_commit v2
  echo "my uncommitted work" >> "$PFDIR/repo/refs/pulse.md"
  WIPSHA=$(sha256sum "$PFDIR/repo/refs/pulse.md" | awk '{print $1}')
  BEFORE=$(git -C "$PFDIR/repo" rev-parse HEAD)
  TIP=$(git -C "$PFDIR/origin.git" rev-parse main)
  OUT=$(pf_run "{\"ok\":true,\"generated_epoch\":$(date -u +%s),\"repos\":[{\"path\":\"/home/andrew/repo\",\"head\":\"$TIP\",\"in_sync\":true}],\"submodules\":[],\"required\":[],\"harvested\":[]}")
  case "$OUT" in *"EXIT=72"*) ok "failed ff: falls through to the block (never proceeds on an unrepaired repo)" ;;
    *) bad "failed ff blocks" "expected EXIT=72, got: $(printf '%.240s' "$OUT")" ;; esac
  case "$OUT" in *"auto-fast-forward FAILED"*) ok "failed ff: warns, naming git's own refusal" ;;
    *) bad "failed ff warns" "no warning: $(printf '%.240s' "$OUT")" ;; esac
  case "$OUT" in *"reset --hard"*) bad "failed ff never says reset --hard" "it recommended discarding the WIP in its way" ;;
    *) ok "failed ff: 'reset --hard' does NOT appear" ;; esac
  if [ "$(git -C "$PFDIR/repo" rev-parse HEAD)" = "$BEFORE" ] \
     && [ "$(sha256sum "$PFDIR/repo/refs/pulse.md" | awk '{print $1}')" = "$WIPSHA" ]
  then ok "failed ff: HEAD and the WIP file are both UNTOUCHED — nothing was forced"
  else bad "failed ff untouched" "the gate modified a repo whose fast-forward it could not apply"; fi

  # (e) THE CONTROL. `reset --hard` must exist in exactly ONE code path, or the
  #     per-state remedies are one careless edit away from re-merging.
  PFSRC=$(grep -vE '^\s*#' "$PF")
  N=$(printf '%s\n' "$PFSRC" | grep -c 'reset --hard')
  if [ "$N" = 1 ]; then ok "source: 'reset --hard' appears in exactly one (DIVERGED) message"
  else bad "reset --hard is single-sited" "found $N occurrences in executable lines"; fi
  if printf '%s\n' "$PFSRC" | grep -q 'merge --ff-only'
  then ok "source: the repair is --ff-only (the only merge that cannot lose work)"
  else bad "ff-only repair" "the auto-repair is not an --ff-only merge"; fi
  for banned in 'reset --hard "' 'git .*stash' 'checkout .*-f ' 'clean -f'; do
    if printf '%s\n' "$PFSRC" | grep -qE "$banned"
    then bad "no destructive command" "the preflight now contains: $banned"
    else ok "source: no destructive '$banned' anywhere in the preflight"; fi
  done
else
  echo "  SKIP  three-state cases (vps-preflight.sh not executable)"
fi

echo
echo "== the dispatcher CARRIES the auto-fast-forward record (dotfiles-w16i) =="
# The record is worth as much as its delivery. An auto-ff leaves the tree CLEAN,
# so it would vanish if it rode on the dirty path — which is exactly how a silent
# catch-up would hide a morning where the box and this machine were far apart.
FF_REPORT='{"clean":true,"local_dirty":[],"remote_dirty":[],"stalled":[],"auto_ff":[{"repo":"$HOME/linearb","from":"aaaaaaaa","to":"bbbbbbbb","commits":8}]}'
OUT=$(run_dry 'PANE_CMD=claude' "REMOTE_MEM_SHA=$MEMSHA" "REMOTE_BEAD_JSON=$BEADJSON" \
      "PF_REPORT_JSON=$FF_REPORT")
check_verdict "an auto-fast-forwarded checkout still reaches dry-run-ok" "$OUT" dry-run-ok
case "$OUT" in *"aaaaaaaa -> bbbbbbbb"*) ok "the dry run prints the from-sha and the to-sha" ;;
  *) bad "dry run shows the ff shas" "no sha pair in the output" ;; esac
: > "$ROOT/inject.log"
OUT=$(run_live "${BASE[@]}" "PF_REPORT_JSON=$FF_REPORT" \
      'RESULT_JSON={"row":"di-friday","outcome":"done","note":"ran after a catch-up","proof":{"kind":"cmd","cmd":"true"}}')
check_verdict "an auto-fast-forwarded checkout completes a live dispatch" "$OUT" completed
RUNDIR=$(ls -dt "$STATE"/*/ 2>/dev/null | head -1)
if grep -q 'CAUGHT UP BEFORE DISPATCH' "${RUNDIR}DISPATCH.md" 2>/dev/null \
   && grep -q 'aaaaaaaa -> bbbbbbbb' "${RUNDIR}DISPATCH.md" 2>/dev/null
then ok "DISPATCH.md tells the tick its box was caught up, and by how much"
else bad "DISPATCH.md carries auto_ff" "the catch-up note is missing from the contract the tick reads"; fi
LINE=$(tail -1 "$PROJ/refs/pulse-ledger.jsonl")
if printf '%s' "$LINE" | jq -e '.dispatch.checkout.auto_ff[0].from == "aaaaaaaa" and .dispatch.checkout.auto_ff[0].commits == 8' >/dev/null 2>&1
then ok "the ledger row records the auto-fast-forward (durable, on dispatch.checkout)"
else bad "ledger records auto_ff" "got: $(printf '%.200s' "$LINE")"; fi
# The control: a run with no catch-up must not claim one, or the field stops
# meaning anything the first time a reader checks it.
OUT=$(run_live "${BASE[@]}" 'PF_REPORT_JSON={"clean":true,"local_dirty":[],"remote_dirty":[],"stalled":[],"auto_ff":[]}' \
      'RESULT_JSON={"row":"di-friday","outcome":"done","note":"nothing to catch up","proof":{"kind":"cmd","cmd":"true"}}')
check_verdict "a run with no catch-up still completes" "$OUT" completed
RUNDIR=$(ls -dt "$STATE"/*/ 2>/dev/null | head -1)
if grep -q 'CAUGHT UP BEFORE DISPATCH' "${RUNDIR}DISPATCH.md" 2>/dev/null
then bad "auto_ff control" "DISPATCH.md claims a catch-up that never happened"
else ok "no catch-up -> no catch-up note (the record is not always-on)"; fi

echo
echo "== --resume: the human-authorized cap waiver (bd-f9kn / bd-02r3) =="
# The property under test is NARROWNESS. A waiver that is easy to produce, or that
# leaks onto the automatic path, is not an escape hatch — it is the runaway loop
# the cap exists to stop. So every case here is either "the waiver requires a
# deliberate human act" or "a run without it is exactly the run it was before".
run_dry_args() {  # <extra dispatcher args...> — knobs are the BASE happy set
  write_knobs 'PANE_CMD=claude' "REMOTE_MEM_SHA=$MEMSHA" "REMOTE_BEAD_JSON=$BEADJSON"
  SSH_LOG="$ROOT/ssh.log" \
  PULSE_DISPATCH_SSH="$STUB/ssh" \
  PULSE_DISPATCH_PREFLIGHT="$STUB/preflight" \
  PULSE_DISPATCH_INJECT="$STUB/inject" PULSE_DISPATCH_MANIFEST=/nonexistent-manifest \
  PULSE_DISPATCH_VAULT=/nonexistent-local-vault \
  PULSE_DISPATCH_STATE="$STATE" \
  HOME="$ROOT/home" \
    "$DISPATCH" --row di-friday --dir "$PROJ" --dry-run --poll 1 --timeout 3 "$@" 2>&1
}
run_live_args() { # <extra dispatcher args...> ;; RESULT_JSON comes from $RJ
  write_knobs 'PANE_CMD=claude' "REMOTE_MEM_SHA=$MEMSHA" "REMOTE_BEAD_JSON=$BEADJSON" \
              "RESULT_JSON=$RJ"
  PULSE_DISPATCH_SSH="$STUB/ssh" \
  PULSE_DISPATCH_PREFLIGHT="$STUB/preflight" \
  PULSE_DISPATCH_INJECT="$STUB/inject" PULSE_DISPATCH_MANIFEST=/nonexistent-manifest \
  PULSE_DISPATCH_VAULT=/nonexistent-local-vault \
  PULSE_DISPATCH_LINT=/nonexistent-lint \
  PULSE_DISPATCH_STATE="$STATE" \
  INJECT_LOG="$ROOT/inject.log" \
  HOME="$ROOT/home" \
    "$DISPATCH" --row di-friday --dir "$PROJ" --poll 1 --timeout 3 "$@" 2>&1
}
RJ='{"row":"di-friday","outcome":"done","note":"collected the parked ad reads","proof":{"kind":"cmd","cmd":"true"}}'

# (a) A VALUE IS REQUIRED. A nameless waiver is a plain cap override, which is the
#     thing this deliberately is not.
OUT=$(PULSE_DISPATCH_SSH="$STUB/ssh" "$DISPATCH" --row di-friday --dir "$PROJ" --resume 2>&1)
check_verdict "--resume with no value is failed-usage" "$OUT" failed-usage
case "$OUT" in *"requires a value"*) ok "the usage error says a value is required" ;;
  *) bad "--resume usage message" "no 'requires a value' text: $(printf '%.140s' "$OUT")" ;; esac
# ...and a following FLAG is not a value. Accepting it would silently swallow the
# flag AND produce an unnamed waiver in one move.
OUT=$(PULSE_DISPATCH_SSH="$STUB/ssh" "$DISPATCH" --row di-friday --dir "$PROJ" --resume --dry-run 2>&1)
check_verdict "--resume followed by another flag is failed-usage" "$OUT" failed-usage
# A usage error is an operator typo on a hand-run, so it must not exit 0.
PULSE_DISPATCH_SSH="$STUB/ssh" "$DISPATCH" --row di-friday --dir "$PROJ" --resume >/dev/null 2>&1
if [ "$?" = 64 ]; then ok "--resume usage error exits 64 (the script's normal usage code)"
else bad "--resume exit code" "expected 64"; fi

# (b) THE DRY RUN SHOWS THE WAIVER — a human must see it before it fires.
OUT=$(run_dry_args --resume bd-icwd)
check_verdict "a resume dry run still reaches dry-run-ok" "$OUT" dry-run-ok
case "$OUT" in *"CAP GATE WAIVED"*) ok "the dry run states the cap waiver out loud" ;;
  *) bad "dry run states the waiver" "no CAP GATE WAIVED line" ;; esac
case "$OUT" in *"ref=bd-icwd"*) ok "the dry run names the ref the waiver authorizes" ;;
  *) bad "dry run names the ref" "bd-icwd absent from the dry-run output" ;; esac
# The control: no flag, no waiver line. A banner that shows unconditionally is not
# a banner.
OUT=$(run_dry_args)
check_verdict "a plain dry run is unchanged" "$OUT" dry-run-ok
case "$OUT" in *"CAP GATE WAIVED"*) bad "dry run waiver control" "a run WITHOUT --resume advertised a waiver" ;;
  *) ok "a dry run without --resume shows no waiver line" ;; esac

# (c) THE AUTHORIZATION BLOCK REACHES THE TICK, and says all of what it must.
OUT=$(run_live_args --resume bd-icwd)
check_verdict "a resume dispatch completes" "$OUT" completed
RUNDIR=$(ls -dt "$STATE"/*/ 2>/dev/null | head -1)
DM="${RUNDIR}DISPATCH.md"
if [ -s "$DM" ]; then
  grep -q 'CAP GATE WAIVED FOR THIS RUN' "$DM" \
    && ok "DISPATCH.md carries the authorization block" \
    || bad "DISPATCH.md authorization block" "the block the tick keys on is absent"
  grep -q 'bd-icwd' "$DM" \
    && ok "the block NAMES the parked deliverable it authorizes" \
    || bad "block names the ref" "bd-icwd absent from DISPATCH.md"
  grep -q 'rc `2` STILL BLOCKS' "$DM" \
    && ok "the block says rc 2 (undetermined) still BLOCKS — a waiver is not a bypass" \
    || bad "block preserves rc 2" "the undetermined-still-blocks invariant is missing"
  grep -q 'NEVER authorize this yourself' "$DM" \
    && ok "the block forbids the tick from self-authorizing a waiver" \
    || bad "block forbids self-authorization" "the no-self-authorize invariant is missing"
  grep -q 'RE-DELIVERED' "$DM" \
    && ok "the block forbids re-delivering anything that already landed" \
    || bad "block forbids double-delivery" "no anti-double-delivery rule"
else
  bad "DISPATCH.md staged locally (resume)" "no DISPATCH.md at $DM"
fi
# (d) THE LEDGER ROW CARRIES THE WAIVER — durable, so a reader six weeks later can
#     tell an authorized second fire from a runaway one.
LINE=$(tail -1 "$PROJ/refs/pulse-ledger.jsonl")
if printf '%s' "$LINE" | jq -e '.dispatch.resume.ref == "bd-icwd"' >/dev/null 2>&1
then ok "the ledger row records .dispatch.resume.ref"
else bad "ledger records the resume ref" "got: $(printf '%.200s' "$LINE")"; fi
if printf '%s' "$LINE" | jq -e '.row=="di-friday" and .outcome=="done" and .dispatch.remote==true' >/dev/null 2>&1
then ok "a resume row is otherwise an ordinary ledger row"
else bad "resume row shape" "got: $(printf '%.200s' "$LINE")"; fi

# (e) THE CONTROL THAT MATTERS MOST. A run WITHOUT --resume must be byte-for-byte
#     the run it was before this flag existed: no authorization block anywhere in
#     the contract the tick reads, and no resume field on the ledger row. If this
#     ever fails, the waiver has leaked onto the automatic path — which is the
#     runaway loop the cap exists to prevent, wearing the escape hatch's clothes.
OUT=$(run_live_args)
check_verdict "a dispatch WITHOUT --resume completes as before" "$OUT" completed
RUNDIR=$(ls -dt "$STATE"/*/ 2>/dev/null | head -1)
DM="${RUNDIR}DISPATCH.md"
if grep -qi 'CAP GATE WAIVED\|HUMAN-AUTHORIZED RESUME' "$DM" 2>/dev/null
then bad "no waiver without the flag" "DISPATCH.md carries an authorization block nobody asked for"
else ok "no --resume -> DISPATCH.md carries NO authorization block"; fi
LINE=$(tail -1 "$PROJ/refs/pulse-ledger.jsonl")
if printf '%s' "$LINE" | jq -e 'has("dispatch") and (.dispatch|has("resume"))' >/dev/null 2>&1
then bad "no resume field without the flag" "the ledger row carries .dispatch.resume: $(printf '%.200s' "$LINE")"
else ok "no --resume -> the ledger row carries NO resume field (optional, new rows only)"; fi

# (f) No systemd unit may pass the flag. This is the whole anti-runaway property,
#     and it is cheap to assert mechanically rather than trust to review.
if ls "$HERE"/../units/*.service >/dev/null 2>&1 || ls "$HERE"/*.service >/dev/null 2>&1; then
  if grep -rl -- '--resume' "$HERE"/../units/*.service "$HERE"/*.service 2>/dev/null | grep -q .
  then bad "no unit passes --resume" "a unit file carries the flag — a timer can now waive the cap"
  else ok "no shipped systemd unit passes --resume (timers cannot produce a waiver)"; fi
else
  ok "no shipped systemd unit passes --resume (none in-tree to check)"
fi

echo
echo "== --resume-auto: the MACHINE-authorized cap waiver (bd-szc4) =="
# The property under test is DISTINGUISHABILITY plus BOUNDEDNESS. `--resume` means
# "a human decided"; a watcher that borrows it destroys the only signal that tells
# a deliberate re-run from a loop re-running itself. So the second flag must (a)
# never be mistakable for the first, in either direction, (b) refuse to waive on
# assertion alone, and (c) be unable to fire twice for the same bead in a period.
# Every case below breaks exactly one of those on purpose.
#
# NOTE ON STATE: the claim store is $STATE/.waivers (dot-prefixed) and the audit is
# $STATE/machine-waiver-audit.jsonl (a FILE). Both shapes are deliberate — the
# RUNDIR lookups throughout this suite are `ls -dt "$STATE"/*/`, which matches
# visible DIRECTORIES, so either an undotted dir or a directory-shaped audit here
# would silently become "the newest run" and make unrelated assertions read the
# wrong DISPATCH.md.
WAIVER_AUDIT="$STATE/machine-waiver-audit.jsonl"
EVDIR="$ROOT/evidence"; mkdir -p "$EVDIR"
EVN=0

# mkev <jq-filter-applied-to-the-good-object> -> prints the path of a fresh file.
# Built by MUTATING one known-good object rather than by writing each variant out
# longhand: a hand-written "bad" file can accidentally be bad in a second way, and
# then the case proves the wrong refusal.
mkev() { # <jq filter> [bead] [row] [clearedAt]
  EVN=$((EVN+1))
  local f="$EVDIR/ev$EVN.json"
  jq -n --arg bead "${2:-bd-xg2w}" --arg row "${3:-di-friday}" \
        --arg cleared "${4:-$(date -u +%FT%TZ)}" \
    '{version:1, authority:"di-doc-block-watch", bead:$bead, row:$row, status:"cleared",
      probe:{kind:"asana-field", target:"Pod Weekly on card 1216039889621372",
             detail:"Pod Weekly = https://docs.google.com/document/d/EXAMPLE"},
      clearedAt:$cleared}' \
  | jq "${1:-.}" > "$f"
  printf '%s' "$f"
}

# Fresh state for this section so the bound cases start from a known-empty store.
rm -rf "$STATE/.waivers" "$WAIVER_AUDIT"

# --- (a) THE TWO FLAGS NEVER MIX, AND EVIDENCE NEVER FLOATS FREE ---------------
EV=$(mkev)
OUT=$(PULSE_DISPATCH_SSH="$STUB/ssh" "$DISPATCH" --row di-friday --dir "$PROJ" \
        --resume bd-icwd --resume-auto bd-xg2w --waiver-evidence "$EV" 2>&1)
check_verdict "--resume + --resume-auto together is failed-usage" "$OUT" failed-usage
case "$OUT" in *"mutually exclusive"*) ok "the usage error says the two waiver kinds are mutually exclusive" ;;
  *) bad "mutual-exclusion message" "no 'mutually exclusive' text: $(printf '%.160s' "$OUT")" ;; esac
OUT=$(PULSE_DISPATCH_SSH="$STUB/ssh" "$DISPATCH" --row di-friday --dir "$PROJ" \
        --waiver-evidence "$EV" 2>&1)
check_verdict "--waiver-evidence without --resume-auto is failed-usage" "$OUT" failed-usage
OUT=$(PULSE_DISPATCH_SSH="$STUB/ssh" "$DISPATCH" --row di-friday --dir "$PROJ" --resume-auto 2>&1)
check_verdict "--resume-auto with no value is failed-usage" "$OUT" failed-usage
OUT=$(PULSE_DISPATCH_SSH="$STUB/ssh" "$DISPATCH" --row di-friday --dir "$PROJ" --resume-auto --dry-run 2>&1)
check_verdict "--resume-auto followed by another flag is failed-usage" "$OUT" failed-usage

# --- (b) EVIDENCE IS REQUIRED, AND EVERY DEFECT FAILS CLOSED ------------------
# `wcase <name> <evidence-path-or-empty> <expected-substring>` — asserts the
# verdict is failed-waiver, the exit code is 66, the message names the reason, and
# CRUCIALLY that nothing was dispatched: no DISPATCH.md, no ledger row, no ssh.
LEDGER_BEFORE_ALL=$(wc -l < "$PROJ/refs/pulse-ledger.jsonl" 2>/dev/null || printf 0)
wcase() { # <name> <ev-path|""> <expect-substring> [bead]
  local name=$1 ev=$2 want=$3 bead=${4:-bd-xg2w} out rc before after
  before=$(wc -l < "$PROJ/refs/pulse-ledger.jsonl" 2>/dev/null || printf 0)
  : > "$ROOT/ssh.log"
  write_knobs 'PANE_CMD=claude' "REMOTE_MEM_SHA=$MEMSHA" "REMOTE_BEAD_JSON=$BEADJSON" "RESULT_JSON=$RJ"
  out=$(SSH_LOG="$ROOT/ssh.log" \
        PULSE_DISPATCH_SSH="$STUB/ssh" PULSE_DISPATCH_PREFLIGHT="$STUB/preflight" \
        PULSE_DISPATCH_INJECT="$STUB/inject" PULSE_DISPATCH_MANIFEST=/nonexistent-manifest \
        PULSE_DISPATCH_VAULT=/nonexistent-local-vault PULSE_DISPATCH_LINT=/nonexistent-lint \
        PULSE_DISPATCH_STATE="$STATE" HOME="$ROOT/home" \
        "$DISPATCH" --row di-friday --dir "$PROJ" --poll 1 --timeout 3 \
                    --resume-auto "$bead" ${ev:+--waiver-evidence "$ev"} 2>&1); rc=$?
  check_verdict "$name -> failed-waiver" "$out" failed-waiver
  [ "$rc" = 66 ] && ok "$name exits 66" || bad "$name exit code" "expected 66, got $rc"
  case "$out" in *"$want"*) ok "$name says why: '$want'" ;;
    *) bad "$name reason" "message lacks '$want': $(printf '%.220s' "$out")" ;; esac
  after=$(wc -l < "$PROJ/refs/pulse-ledger.jsonl" 2>/dev/null || printf 0)
  [ "$before" = "$after" ] && ok "$name wrote NO ledger row" \
    || bad "$name dispatched anyway" "the ledger grew from $before to $after lines"
  if [ -s "$ROOT/ssh.log" ]
  then bad "$name reached the box" "a refused waiver made ssh calls: $(head -1 "$ROOT/ssh.log")"
  else ok "$name made NO ssh call (refused before the tunnel, so it costs nothing)"; fi
}

wcase "no --waiver-evidence at all"     ""                                  "assertion alone"
wcase "a nonexistent evidence file"     "$EVDIR/does-not-exist.json"         "does not exist"
wcase "an empty evidence file"          "$(: > "$EVDIR/empty.json"; printf '%s' "$EVDIR/empty.json")" "is empty"
wcase "evidence that is not JSON"       "$(printf 'not json at all\n' > "$EVDIR/bad.json"; printf '%s' "$EVDIR/bad.json")" "not a JSON object"
wcase "evidence that is a JSON ARRAY"   "$(printf '[]\n' > "$EVDIR/arr.json"; printf '%s' "$EVDIR/arr.json")" "not a JSON object"
wcase "an unknown schema version"       "$(mkev '.version = 99')"            "expected 1"
wcase "evidence with no .authority"     "$(mkev 'del(.authority)')"          "must name what authorized it"
wcase "evidence for a DIFFERENT bead"   "$(mkev '.bead = "bd-other"')"       "may not authorize another"
wcase "evidence for a DIFFERENT row"    "$(mkev '.row = "di-monday"')"       "may not authorize another"
wcase "a probe that did NOT clear"      "$(mkev '.status = "still blocked"')" "not 'cleared'"
wcase "no .probe.kind"                  "$(mkev 'del(.probe.kind)')"         "is an assertion, not evidence"
wcase "no .probe.target"                "$(mkev 'del(.probe.target)')"       "cannot be re-checked by a human"
wcase "no .probe.detail"                "$(mkev 'del(.probe.detail)')"       "IS the evidence"
wcase "a RELATIVE clearedAt ('now')"    "$(mkev '.clearedAt = "now"')"       "not an absolute ISO-8601"
wcase "an unparseable clearedAt"        "$(mkev '.clearedAt = "2026-13-45T99:99:99Z"')" "not a parseable timestamp"
wcase "STALE evidence (2 days old)"     "$(mkev '.' bd-xg2w di-friday "$(date -u -d '2 days ago' +%FT%TZ)")" "describes a world that has moved"
wcase "evidence dated in the FUTURE"    "$(mkev '.' bd-xg2w di-friday "$(date -u -d '2 hours' +%FT%TZ)")"   "in the FUTURE"

# Not one of those wrote a ledger row, collectively.
LEDGER_AFTER_ALL=$(wc -l < "$PROJ/refs/pulse-ledger.jsonl" 2>/dev/null || printf 0)
[ "$LEDGER_BEFORE_ALL" = "$LEDGER_AFTER_ALL" ] \
  && ok "seventeen malformed-evidence cases produced ZERO ledger rows between them" \
  || bad "fail-closed in aggregate" "the ledger grew from $LEDGER_BEFORE_ALL to $LEDGER_AFTER_ALL"

# ...and no refusal may leave a claim behind. A refusal that spent the bound would
# make one bad evidence file permanently poison a bead.
if [ -d "$STATE/.waivers" ] && find "$STATE/.waivers" -mindepth 2 -maxdepth 2 -type d | grep -q .
then bad "a refusal spent the bound" "a refused waiver left a claim in $STATE/.waivers"
else ok "no refused waiver left a claim behind (a bad file cannot poison a bead)"; fi

# --- (c) THE DRY RUN VALIDATES BUT DOES NOT CLAIM -----------------------------
EV=$(mkev)
OUT=$(run_dry_args --resume-auto bd-xg2w --waiver-evidence "$EV")
check_verdict "a machine-waiver dry run reaches dry-run-ok" "$OUT" dry-run-ok
case "$OUT" in *"MACHINE-authorized (NO HUMAN)"*) ok "the dry run says out loud that no human authorized it" ;;
  *) bad "dry-run machine banner" "no MACHINE-authorized line: $(printf '%.200s' "$OUT")" ;; esac
case "$OUT" in *"A DRY RUN DOES NOT CLAIM"*) ok "the dry run states that it did not spend the bound" ;;
  *) bad "dry-run claim statement" "the banner does not say the claim was untouched" ;; esac
case "$OUT" in *"di-doc-block-watch"*) ok "the dry run names the authorizing watcher" ;;
  *) bad "dry-run authority" "the authority is absent from the banner" ;; esac
if [ -d "$STATE/.waivers/$(date -u +%G-W%V)/bd-xg2w" ]
then bad "dry run spent the claim" "inspecting a pending waiver destroyed it"
else ok "the dry run took NO claim (inspection does not destroy the thing inspected)"; fi

# --- (d) THE GRANT: it waives, and it renders the MACHINE block ---------------
EV=$(mkev)
: > "$ROOT/inject.log"
OUT=$(run_live_args --resume-auto bd-xg2w --waiver-evidence "$EV")
check_verdict "a machine-waiver dispatch completes" "$OUT" completed
case "$OUT" in *"MACHINE-AUTHORIZED cap waiver GRANTED"*) ok "the run announces the grant" ;;
  *) bad "grant announcement" "no GRANTED line in the output" ;; esac
RUNDIR=$(ls -dt "$STATE"/*/ 2>/dev/null | head -1)
DM_MACHINE="${RUNDIR}DISPATCH.md"
if [ -s "$DM_MACHINE" ]; then
  grep -q 'MACHINE-AUTHORIZED RESUME' "$DM_MACHINE" \
    && ok "DISPATCH.md carries the MACHINE-labelled authorization block" \
    || bad "machine block heading" "the machine heading is absent"
  grep -q 'NO HUMAN AUTHORIZED THIS RUN' "$DM_MACHINE" \
    && ok "the machine block states plainly that no human authorized the run" \
    || bad "machine block disclaimer" "the no-human statement is missing"
  # THE DECISIVE PROPERTY, and it is asserted on the TOKEN rather than the heading
  # line. A tick under load greps; if the machine block explains itself by quoting
  # the human kind's token — even to disclaim it — a substring search returns a
  # false positive and the whole distinction is decorative. Caught by this very
  # assertion on the first run: the machine block said "can never appear under the
  # heading \`HUMAN-AUTHORIZED RESUME\`", which is true prose and a broken grep. The
  # block was rewritten; the test was not relaxed.
  grep -q 'HUMAN-AUTHORIZED' "$DM_MACHINE" \
    && bad "machine block leaked the human token" "a naive grep for HUMAN-AUTHORIZED returns a false positive on a machine run" \
    || ok "the machine block contains the token HUMAN-AUTHORIZED nowhere at all (a plain grep is decisive)"
  grep -q 'di-doc-block-watch' "$DM_MACHINE" \
    && ok "the block NAMES what authorized it" \
    || bad "machine block authority" "the authorizing watcher is not named"
  grep -q 'bd-xg2w' "$DM_MACHINE" \
    && ok "the block NAMES the authorizing bead" \
    || bad "machine block bead" "the bead is absent"
  grep -q 'asana-field' "$DM_MACHINE" && grep -q 'Pod Weekly on card' "$DM_MACHINE" \
    && ok "the block carries the EVIDENCE: which probe, and against what" \
    || bad "machine block evidence" "the probe kind/target are missing"
  grep -q 'Pod Weekly = https://docs.google.com' "$DM_MACHINE" \
    && ok "the block carries what the probe actually READ BACK" \
    || bad "machine block probe detail" "the probe result is missing"
  grep -qE 'cleared at    [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$DM_MACHINE" \
    && ok "the block carries WHEN the probe cleared" \
    || bad "machine block timestamp" "no cleared-at timestamp"
  grep -q 'THE BOUND' "$DM_MACHINE" && grep -q "$(date -u +%G-W%V)" "$DM_MACHINE" \
    && ok "the block names the period-bounded claim it spent" \
    || bad "machine block bound" "the bound/period is not stated"
  # The five shared invariants must survive into the machine block verbatim — a
  # waiver kind that quietly relaxes them is a wider hole than the flag it replaced.
  grep -q 'rc `2` STILL BLOCKS' "$DM_MACHINE" \
    && ok "machine block: rc 2 (undetermined) still BLOCKS" \
    || bad "machine block rc2" "the undetermined-still-blocks invariant is missing"
  grep -q 'NEVER authorize this yourself' "$DM_MACHINE" \
    && ok "machine block: the tick still may not self-authorize" \
    || bad "machine block self-auth" "the no-self-authorize invariant is missing"
  grep -q 'RE-DELIVERED' "$DM_MACHINE" \
    && ok "machine block: nothing already landed may be re-delivered" \
    || bad "machine block double-delivery" "no anti-double-delivery rule"
else
  bad "DISPATCH.md staged locally (resume-auto)" "no DISPATCH.md at $DM_MACHINE"
fi
LINE=$(tail -1 "$PROJ/refs/pulse-ledger.jsonl")
if printf '%s' "$LINE" | jq -e '.dispatch.resume.kind == "machine" and .dispatch.resume.ref == "bd-xg2w" and .dispatch.resume.authority == "di-doc-block-watch"' >/dev/null 2>&1
then ok "the ledger row records kind=machine, the ref and the authority"
else bad "ledger machine waiver" "got: $(printf '%.240s' "$LINE")"; fi
if printf '%s' "$LINE" | jq -e '.dispatch.resume.evidence.probe_kind == "asana-field" and (.dispatch.resume.evidence.cleared_at | length > 0) and (.dispatch.resume.period | length > 0)' >/dev/null 2>&1
then ok "the ledger row carries the EVIDENCE and the period (durable, off-box)"
else bad "ledger machine evidence" "got: $(printf '%.240s' "$LINE")"; fi

# --- (e) THE BOUND HOLDS. Same bead, same period, fresh valid evidence -------
# This is the property that stops a bad probe turning into a re-dispatch loop, so
# it is asserted against a SECOND run that is otherwise entirely legitimate.
EV2=$(mkev)
LB=$(wc -l < "$PROJ/refs/pulse-ledger.jsonl")
: > "$ROOT/ssh.log"
OUT=$(run_live_args --resume-auto bd-xg2w --waiver-evidence "$EV2")
check_verdict "a SECOND machine waiver for the same bead in the same period is refused" "$OUT" failed-waiver
case "$OUT" in *"already SPENT"*) ok "the refusal says the bound is already spent" ;;
  *) bad "bound refusal message" "no 'already SPENT' text: $(printf '%.240s' "$OUT")" ;; esac
case "$OUT" in *"a human authorizes it with --resume"*) ok "the refusal points at the human path as the remedy" ;;
  *) bad "bound refusal remedy" "the refusal does not name --resume as the way through" ;; esac
LA=$(wc -l < "$PROJ/refs/pulse-ledger.jsonl")
[ "$LB" = "$LA" ] && ok "the refused second waiver wrote no ledger row" \
  || bad "second waiver dispatched" "the ledger grew from $LB to $LA"
# A DIFFERENT bead in the same period is NOT bounded — the bound is per bead, and a
# bound that stopped every bead after the first would be an outage, not a guard.
EV3=$(mkev '.' bd-other2 di-friday)
OUT=$(run_live_args --resume-auto bd-other2 --waiver-evidence "$EV3")
check_verdict "a DIFFERENT bead in the same period still waives (the bound is per bead)" "$OUT" completed

# --- (f) THE AUDIT TRAIL ------------------------------------------------------
if [ -s "$WAIVER_AUDIT" ]; then
  ok "the machine-waiver audit exists at $WAIVER_AUDIT"
  if jq -e 'select(.decision=="granted" and .bead=="bd-xg2w" and .authority=="di-doc-block-watch" and .evidence.probe_kind=="asana-field")' "$WAIVER_AUDIT" >/dev/null 2>&1
  then ok "the audit records the GRANT with its bead, authority and evidence"
  else bad "audit grant line" "no granted line with the expected fields"; fi
  if jq -e 'select(.decision=="refused")' "$WAIVER_AUDIT" >/dev/null 2>&1
  then ok "the audit records REFUSALS too (the half that explains a deliverable nobody collected)"
  else bad "audit refusal lines" "refusals were not audited"; fi
  if jq -e 'select(.decision=="refused" and (.detail | test("already SPENT")))' "$WAIVER_AUDIT" >/dev/null 2>&1
  then ok "the audit names the BOUND refusal specifically"
  else bad "audit bound refusal" "the spent-bound refusal is not in the audit"; fi
  if jq -e 'select(.decision=="dry-run")' "$WAIVER_AUDIT" >/dev/null 2>&1
  then ok "the audit distinguishes a dry-run validation from a real grant"
  else bad "audit dry-run line" "the dry run left no audit line"; fi
  # Every line must be valid JSON — an audit that cannot be parsed is a log.
  if jq -e . "$WAIVER_AUDIT" >/dev/null 2>&1
  then ok "every audit line is valid JSON"
  else bad "audit is JSONL" "at least one line does not parse"; fi
else
  bad "machine-waiver audit" "nothing at $WAIVER_AUDIT after grants and refusals"
fi

# --- (g) THE HUMAN PATH IS UNCHANGED, AND ITS GUARANTEE IS STILL TRUE ---------
# This is the case bd-szc4 exists to protect. `--resume` must still produce the
# HUMAN block, that block's sentence about timers must still be accurate, and the
# machine heading must be nowhere near it.
: > "$ROOT/inject.log"
OUT=$(run_live_args --resume bd-icwd)
check_verdict "--resume still completes after the machine path was added" "$OUT" completed
RUNDIR=$(ls -dt "$STATE"/*/ 2>/dev/null | head -1)
DM_HUMAN="${RUNDIR}DISPATCH.md"
if [ -s "$DM_HUMAN" ]; then
  grep -q 'HUMAN-AUTHORIZED RESUME' "$DM_HUMAN" \
    && ok "--resume still renders the HUMAN-labelled block" \
    || bad "human heading" "the human heading is gone"
  # The mirror of the machine-side assertion, and it must hold in BOTH directions or
  # the "grep is decisive" claim only works one way.
  grep -q 'MACHINE-AUTHORIZED' "$DM_HUMAN" \
    && bad "human block leaked the machine token" "a naive grep for MACHINE-AUTHORIZED returns a false positive on a human run" \
    || ok "the human block contains the token MACHINE-AUTHORIZED nowhere at all"
  grep -q 'no timer can produce this block' "$DM_HUMAN" \
    && ok "the human guarantee sentence is still present, word for word" \
    || bad "human guarantee sentence" "the load-bearing sentence was weakened or deleted"
  grep -q 'THERE ARE EXACTLY TWO KINDS OF CAP WAIVER' "$DM_HUMAN" \
    && ok "the human block TELLS the tick there are two authorization kinds" \
    || bad "two-kinds notice" "the tick is not told the other kind exists"
  grep -q 'Read the heading; never guess' "$DM_HUMAN" \
    && ok "the human block tells the tick HOW to tell them apart (the heading)" \
    || bad "how-to-distinguish" "the block does not say which field is authoritative"
else
  bad "DISPATCH.md staged locally (human, post-change)" "no DISPATCH.md at $DM_HUMAN"
fi
LINE=$(tail -1 "$PROJ/refs/pulse-ledger.jsonl")
if printf '%s' "$LINE" | jq -e '.dispatch.resume.kind == "human" and .dispatch.resume.ref == "bd-icwd"' >/dev/null 2>&1
then ok "the ledger row records kind=human for the human path"
else bad "ledger human kind" "got: $(printf '%.240s' "$LINE")"; fi
if printf '%s' "$LINE" | jq -e '.dispatch.resume | has("authority") or has("evidence")' >/dev/null 2>&1
then bad "human row carries machine fields" "the human waiver row has authority/evidence: $(printf '%.240s' "$LINE")"
else ok "a human waiver row carries NO authority/evidence fields (nothing to confuse a reader)"; fi

# THE GUARANTEE, ASSERTED MECHANICALLY RATHER THAN READ. The sentence claims no
# timer can produce the human block. Two things make that true and both are checked:
# no shipped unit passes --resume (case (f) above), and the ONLY assignment to the
# RESUME variable comes from the `--resume` arm — so --resume-auto cannot slide into
# the human path however the parser is later edited.
SRC=$(grep -vE '^\s*#' "$DISPATCH")
N=$(printf '%s\n' "$SRC" | grep -cE '^\s*RESUME=\$2')
if [ "$N" = 1 ]
then ok "source: RESUME is assigned from exactly one place (the --resume arm)"
else bad "RESUME single-sited" "found $N assignments of RESUME=\$2 — the human signal has another producer"; fi
if printf '%s\n' "$SRC" | grep -qE '^\s*RESUME_AUTO=\$2'
then ok "source: --resume-auto assigns its OWN variable, never RESUME"
else bad "RESUME_AUTO separate" "the machine flag does not assign RESUME_AUTO"; fi
# And no shipped unit may pass the machine flag either. A watcher may — it can
# produce evidence; a systemd unit fires on a clock and has none to give.
if ls "$HERE"/../units/*.service >/dev/null 2>&1 || ls "$HERE"/*.service >/dev/null 2>&1; then
  if grep -rl -- '--resume-auto' "$HERE"/../units/*.service "$HERE"/*.service 2>/dev/null | grep -q .
  then bad "no unit passes --resume-auto" "a unit fires on a clock and has no evidence to supply"
  else ok "no shipped systemd unit passes --resume-auto"; fi
else
  ok "no shipped systemd unit passes --resume-auto (none in-tree to check)"
fi

# --- (h) THE CONTROL. No flag, no machine block, no machine ledger field ------
OUT=$(run_live_args)
check_verdict "a dispatch with NEITHER waiver flag completes as before" "$OUT" completed
RUNDIR=$(ls -dt "$STATE"/*/ 2>/dev/null | head -1)
if grep -qi 'MACHINE-AUTHORIZED RESUME' "${RUNDIR}DISPATCH.md" 2>/dev/null
then bad "no machine block without the flag" "DISPATCH.md carries a machine authorization nobody asked for"
else ok "no --resume-auto -> DISPATCH.md carries NO machine block"; fi
LINE=$(tail -1 "$PROJ/refs/pulse-ledger.jsonl")
if printf '%s' "$LINE" | jq -e '.dispatch | has("resume")' >/dev/null 2>&1
then bad "no resume field without a flag" "got: $(printf '%.240s' "$LINE")"
else ok "no waiver flag -> the ledger row carries NO resume field at all"; fi

# --- (i) THE TWO BLOCKS, SIDE BY SIDE, AS A TICK ACTUALLY RECEIVES THEM -------
# Printed rather than only asserted: the whole requirement is that a human (and a
# tick) can tell them apart at a glance, and an assertion that greps for a string
# does not demonstrate that. This is evidence, in the output, for a reader.
echo "  ---- rendered heading + authorization paragraph, HUMAN block ----"
sed -n '/^## 0\./,/^\*\*1\./p' "$DM_HUMAN" | sed '$d' | sed 's/^/  | /'
echo "  ---- rendered heading + authorization paragraph, MACHINE block ----"
sed -n '/^## 0\./,/^\*\*THE BOUND/p' "$DM_MACHINE" | sed '$d' | sed 's/^/  | /'
H_HEAD=$(grep -m1 '^## 0\.' "$DM_HUMAN")
M_HEAD=$(grep -m1 '^## 0\.' "$DM_MACHINE")
if [ -n "$H_HEAD" ] && [ -n "$M_HEAD" ] && [ "$H_HEAD" != "$M_HEAD" ]
then ok "the two blocks' §0 headings are DIFFERENT strings (a tick can branch on one line)"
else bad "headings distinguishable" "human='$H_HEAD' machine='$M_HEAD'"; fi

echo
echo "== --dry-run LEAVES NO WINDOW IT CREATED — and never touches one it didn't (dotfiles-77s4) =="
# THE INCIDENT, 2026-08-03. Zig found `di-monday` and `di-wednesday` windows on
# marketing-vps on a FRIDAY, neither row due and neither timer fired since the
# previous week. Nothing had run them: two `--dry-run` invocations days earlier had
# each created a `work:<row>` window as part of A4 and left it there, and litter
# from an inert-sounding flag reads to a human exactly like a tick firing on the
# wrong day.
#
# The OWNERSHIP half is the one that matters most, and it is why this is a suite of
# cases rather than one. `work` is a single shared session on a box five people
# reach; a pre-existing `work:<row>` window may hold a live tick from the real
# dispatch path or Zig's own attached session. A cleanup that kills the wrong window
# is far worse than the litter it fixes — so "removes what it made" and "never
# removes what it found" are asserted separately, and the second one is the guard.
DRW=('PANE_CMD=claude' "REMOTE_MEM_SHA=$MEMSHA" "REMOTE_BEAD_JSON=$BEADJSON")

# (1) CREATED -> removed again, targeted by the id captured at creation.
: > "$ROOT/ssh.log"
OUT=$(run_dry "${DRW[@]}" 'WIN_LINES=' 'NEW_WIN_ID=@7')
check_verdict "a dry run with no pre-existing window still reaches dry-run-ok" "$OUT" dry-run-ok
if grep -q 'new-window' "$ROOT/ssh.log"
then ok "precondition: the dry run really did create a remote window"
else bad "dry run creates a window" "no new-window in the ssh log — the removal cases below would prove nothing"; fi
if grep -q "kill-window -t '@7'" "$ROOT/ssh.log"
then ok "a dry run REMOVES the window it created, by the @id it captured (not by name)"
else bad "dry run removes its own window" "no 'kill-window -t @7' among $(grep -c . "$ROOT/ssh.log") ssh calls"; fi
case "$OUT" in *"CREATED by this dry run, and REMOVED again"*) ok "the removal is NAMED in the dry-run output" ;;
  *) bad "the removal is announced" "no created-and-removed line in the output" ;; esac

# (2) ★ THE ONE THAT MATTERS. PRE-EXISTING -> not created, and NEVER killed.
#     WIN_LINES is what tmux would PRINT — `<@id> <name>` lines — and the real
#     matcher awk runs over it inside the stub (dotfiles-dajp), so "the window
#     was found" here is the production lookup answering, not a canned id. The
#     matcher's own behaviour gets its own section further down.
: > "$ROOT/ssh.log"
OUT=$(run_dry "${DRW[@]}" 'WIN_LINES=@4 di-friday')
check_verdict "a dry run that FINDS the window still reaches dry-run-ok" "$OUT" dry-run-ok
if grep -q 'new-window' "$ROOT/ssh.log"
then bad "precondition: an existing window is adopted" "the run created a SECOND window instead of finding the existing one"
else ok "precondition: the pre-existing window was FOUND, not created"; fi
if grep -q 'kill-window' "$ROOT/ssh.log"
then bad "a dry run NEVER kills a window it did not create" "a pre-existing window was killed — it could have held a live tick or Zig's own session"
else ok "a dry run NEVER kills a window it did not create (the ownership guard)"; fi
case "$OUT" in *"PRE-EXISTING, left untouched"*) ok "the dry run says out loud that the window was not its to remove" ;;
  *) bad "pre-existing window is announced" "no PRE-EXISTING line in the output" ;; esac

# (3) A REAL DISPATCH KEEPS ITS WINDOW. The tick is about to run in it; a cleanup
#     that fired here would kill the pane mid-tick.
: > "$ROOT/ssh.log"
OUT=$(SSH_LOG="$ROOT/ssh.log" run_live "${BASE[@]}" 'WIN_LINES=' 'NEW_WIN_ID=@9' \
      'RESULT_JSON={"row":"di-friday","outcome":"done","note":"n","proof":{"kind":"cmd","cmd":"true"}}')
check_verdict "a live dispatch that created its window completes" "$OUT" completed
if grep -q 'new-window' "$ROOT/ssh.log"
then ok "precondition: the live dispatch created the window"
else bad "live dispatch creates a window" "no new-window in the ssh log"; fi
if grep -q 'kill-window' "$ROOT/ssh.log"
then bad "a non-dry dispatch never removes its window" "a real dispatch killed the window its tick runs in"
else ok "a non-dry dispatch never removes its window"; fi

# (4) FAILURE PATHS. A dry run that dies AFTER creating the window still owns it.
#     Both post-creation assertions are exercised: A7 (with a warm pane) and A4's
#     in-pane probe (with a cold one).
: > "$ROOT/ssh.log"
OUT=$(run_dry "${DRW[@]}" 'WIN_LINES=' 'NEW_WIN_ID=@11' 'A7_BODY=connect: connection refused')
check_verdict "A7 fails after the window exists -> failed-no-claude" "$OUT" failed-no-claude
if grep -q "kill-window -t '@11'" "$ROOT/ssh.log"
then ok "a dry run that DIES at A7 still removes the window it created"
else bad "cleanup on the A7 failure path" "the window leaked when the run failed after creating it"; fi

: > "$ROOT/ssh.log"
OUT=$(run_dry "REMOTE_MEM_SHA=$MEMSHA" "REMOTE_BEAD_JSON=$BEADJSON" \
      'PANE_CMD=zsh' 'PROBE_BODY=PROBE_RC=1' 'WIN_LINES=' 'NEW_WIN_ID=@12')
check_verdict "A4 fails after the window exists -> failed-no-claude" "$OUT" failed-no-claude
if grep -q "kill-window -t '@12'" "$ROOT/ssh.log"
then ok "a dry run that DIES at A4 still removes the window it created"
else bad "cleanup on the A4 failure path" "the window leaked when the run failed after creating it"; fi

# (5) THE SECOND DOOR TO OWNERSHIP. When the box has no `work` session at all,
#     `new-session -n <row>` creates the session AND the row's window in one go —
#     so list-windows FINDS the window, and a naive "created only via new-window"
#     flag would leave a whole session behind.
: > "$ROOT/ssh.log"
OUT=$(run_dry "${DRW[@]}" 'BOX_SESSION=created' 'WIN_LINES=@4 di-friday')
check_verdict "a dry run that created the session reaches dry-run-ok" "$OUT" dry-run-ok
if grep -q "kill-window -t '@4'" "$ROOT/ssh.log"
then ok "a window that came with the session THIS run created is removed too"
else bad "session-created ownership" "the window created alongside a new session was left behind"; fi

# (6) FAIL SAFE ON AN UNREADABLE ANSWER. Same window, same list-windows result as
#     (5) — only the box's answer about the session is unintelligible. Ownership
#     must NOT be claimed: never remove a window you cannot prove you made.
: > "$ROOT/ssh.log"
OUT=$(run_dry "${DRW[@]}" 'BOX_SESSION=' 'WIN_LINES=@4 di-friday')
check_verdict "an unreadable session answer does not block the dry run" "$OUT" dry-run-ok
if grep -q 'kill-window' "$ROOT/ssh.log"
then bad "unreadable session answer leaves ownership unclaimed" "the run killed @4 on an answer it could not parse"
else ok "an unparseable session answer leaves ownership UNCLAIMED (fail safe)"; fi

# (7) THE ROOT CAUSE WAS INVISIBILITY, not mutation. The header has documented the
#     mutations since it was written; the operator never saw them. Every one must
#     be named in the run that made it.
OUT=$(run_dry "${DRW[@]}" 'WIN_LINES=' 'NEW_WIN_ID=@7')
while IFS='|' read -r _pat _what; do
  case "$OUT" in *"$_pat"*) ok "the dry run names the mutation: $_what" ;;
    *) bad "dry run names $_what" "'$_pat' absent from the output" ;; esac
done <<'MUT'
MUTATIONS THIS DRY RUN PERFORMED|the block header (a dry run is NOT inert)
ssh control master opened|the ssh master it opened
fleet-proxy tunnel:|what it did to the tunnel
T1 repos on|the repo fast-forwards on the box
bead index REBUILT|the bead-index rebuild on the box
SPENT REAL TOKENS|the billed claude call A7 makes
tmux window work:di-friday|the remote window it created and removed
MUT

echo
echo "== the LEXICON-GLYPH window matcher, executed for real (dotfiles-dajp) =="
# THE LEAK IT FIXES, 2026-07-28. The tmux-status hook renames a window to carry a
# state glyph — `di-friday` becomes `✅ di-friday` the moment a tick finishes in
# it. The old matcher compared the whitespace-split $2, which is the GLYPH, so the
# lookup missed EVERY window that had ever run, and each dispatch created another
# one. Two live `weekly-report` windows on marketing-vps is how Zig found it.
#
# WHY THIS SECTION IS SHAPED THIS WAY. The awk that fixes it is one inline line
# inside an `rsh "..."` string, and until now the ssh stub answered for the whole
# pipeline with a precomputed id — so the matcher had zero coverage while its
# symptom (window litter on a box five people share) is exactly the class of bug
# dotfiles-77s4 was filed for. The stub now RUNS the dispatcher's own bytes
# against a synthetic tmux; nothing here restates the awk, so these cases cannot
# drift away from the code they cover.
#
# WHAT IS OBSERVED. `WIN_ID` is not printed anywhere, but the very next thing the
# dispatcher does with it is `list-panes -t '<id>'` — so the ssh log carries the
# matcher's answer, and a MISS is visible as a `new-window` call. Both directions
# are asserted, because "found the wrong window" and "found nothing" are different
# failures with different consequences on a shared box.
: > "$ROOT/ssh.log"
matcher_run() { # <row> <win-lines> — one dry run, log reset, all knobs default
  : > "$ROOT/ssh.log"
  WIN_LINES="$2" NEW_WIN_ID=@99 run_row "$1"
}
resolved_id() { sed -n "s/.*list-panes -t '\([^']*\)'.*/\1/p" "$ROOT/ssh.log" | head -1; }

matches() { # <label> <row> <win-lines> <expected-id>
  matcher_run "$2" "$3"
  local got; got=$(resolved_id)
  if [ "$got" != "$4" ]; then bad "$1" "resolved '${got:-<nothing>}', wanted '$4'"; return; fi
  if grep -q 'new-window' "$ROOT/ssh.log"
  then bad "$1" "resolved $4 but ALSO created a window — the leak, in miniature"
  else ok "$1"; fi
}
no_match() { # <label> <row> <win-lines> — must find nothing and create @99
  matcher_run "$2" "$3"
  if ! grep -q 'new-window' "$ROOT/ssh.log"
  then bad "$1" "adopted '$(resolved_id)' — it matched a window that is not the row's"; return; fi
  if [ "$(resolved_id)" = "@99" ]
  then ok "$1"
  else bad "$1" "created a window but then used '$(resolved_id)' instead of it"; fi
}

matches "a bare window name matches its row"          di-friday '@4 di-friday'   @4
matches "a ✅-prefixed window still matches its row"   di-friday '@4 ✅ di-friday' @4
matches "a 🧠-prefixed window still matches its row"   di-friday '@4 🧠 di-friday' @4
matches "a 🔔-prefixed window still matches its row"   di-friday '@4 🔔 di-friday' @4
# 🌀 is in the lexicon but was never in the old fixed-glyph thinking. The strip is a
# generic leading non-alphanumeric run precisely so a NEW glyph cannot reintroduce
# the leak; this case is the claim, not an extra flavour of the ones above.
matches "a 🌀-prefixed window matches too (the strip is generic, not a glyph list)" \
        di-friday '@4 🌀 di-friday' @4
# The realistic box: several rows' windows, each wearing whatever glyph its last
# tick left. The matcher must walk past the near misses and stop on the right one.
matches "the right row is picked out of a glyph-laden window list" \
        di-friday $'@1 ✅ pulse\n@2 🧠 di-tuesday\n@3 🔔 di-friday\n@8 di-fridayish' @3

# ── EXACTNESS. `name==n`, not a substring test. On a shared `work` session the
#    consequence of a loose match is a dispatch typing into ANOTHER row's live
#    pane — strictly worse than the litter this matcher exists to prevent.
no_match "a row whose name is a PREFIX of a window does not cross-match" \
         di-mon '@5 di-monday'
matches "…and with both present, the row gets its OWN window, not the longer one" \
        di-mon $'@5 di-monday\n@6 di-mon' @6
matches "…and the longer row is not stolen by the shorter window either" \
        di-monday $'@6 di-mon\n@5 di-monday' @5
no_match "a glyph-prefixed near-miss is still a miss (strip, THEN compare exactly)" \
         di-mon '@7 ✅ di-monday'

# ── THE STRIP MUST NOT BECOME A WILDCARD. A window named only in glyphs strips
#    down to the empty string; if that were allowed to match, one decorative
#    window would be adopted by every row on the box.
no_match "a window whose name is only glyphs matches nothing" \
         di-friday '@3 ✅ 🧠'
no_match "an unrelated window is not adopted"        di-friday '@2 something-else'
no_match "an empty window list resolves to nothing"  di-friday ''

echo
echo "== --help actually lists the flags (bd-1gu0) =="
# The bug this guards: --help used `sed -n '2,150p'`, but the Usage block had
# drifted down past line 245 as the header comment grew. So --help printed the
# architecture preamble and cut off before the FIRST flag — silently, for a long
# time, because help that prints *something* looks like help that works. The fix
# anchors on the `# Usage` heading; these assertions make the next drift LOUD.
HELP_OUT=$("$DISPATCH" --help 2>&1)
if [ "$(printf '%s\n' "$HELP_OUT" | grep -c .)" -ge 20 ]
then ok "--help prints a substantial block (not a truncated preamble)"
else bad "--help length" "only $(printf '%s\n' "$HELP_OUT" | grep -c .) non-empty lines"; fi
for _f in --row --dir --resume --resume-auto --waiver-evidence --dry-run --window --host; do
  if printf '%s\n' "$HELP_OUT" | grep -q -- "$_f"
  then ok "--help documents $_f"
  else bad "--help documents $_f" "flag absent from help output"; fi
done
if printf '%s\n' "$HELP_OUT" | grep -q '^Usage$'
then ok "--help starts at the Usage heading (anchored, not a line range)"
else bad "--help anchor" "the Usage heading is not in the output"; fi
# dotfiles-77s4: the flag NAME promises inertness the flag does not deliver, and the
# only reader of --help is someone deciding whether it is safe to run. So --help
# must say both halves out loud: it mutates the box, and it spends money doing it.
if printf '%s\n' "$HELP_OUT" | grep -q 'NOT INERT'
then ok "--help warns that --dry-run is NOT inert"
else bad "--help warns --dry-run is not inert" "no NOT INERT warning in the help output"; fi
if printf '%s\n' "$HELP_OUT" | grep -q 'SPENDS REAL TOKENS'
then ok "--help states that a dry run spends real tokens (the A7 probe)"
else bad "--help states the A7 cost" "the paid claude call is not mentioned in --help"; fi

echo "== outcome contract =="
OUT=$(run_dry 'PANE_CMD=claude' "REMOTE_MEM_SHA=$MEMSHA" "REMOTE_BEAD_JSON=$BEADJSON")
N=$(printf '%s\n' "$OUT" | grep -c 'PULSE_DISPATCH_RESULT=')
if [ "$N" = "1" ]; then ok "exactly one PULSE_DISPATCH_RESULT marker per run"
else bad "one marker per run" "found $N markers"; fi
if [ "$(printf '%s\n' "$OUT" | tail -1)" = "PULSE_DISPATCH_RESULT=dry-run-ok" ]
then ok "the marker is the LAST line of stdout"; else bad "marker position" "not last"; fi
OUT=$(PULSE_DISPATCH_SSH="$STUB/ssh" "$DISPATCH" --bogus-flag 2>&1)
check_verdict "an unknown flag still emits a verdict" "$OUT" failed-usage

echo
echo "=============================================="
echo "  PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -gt 0 ] && printf '  failed: %s\n' "${FAILED_NAMES[@]}"
echo "=============================================="
[ "$FAIL" -eq 0 ]
