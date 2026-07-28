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
args=("$@"); last="${args[${#args[@]}-1]}"
[ -n "${SSH_LOG:-}" ] && printf '%s\n' "$*" >> "$SSH_LOG"
# rsh() ships the remote command through `printf %q`, so spaces arrive as "\ ".
# Strip backslashes before matching — the real ssh never sees these patterns.
last="${last//\\/}"
for a in "${args[@]}"; do [ "$a" = "-O" ] && exit 0; done          # control-master exit
for a in "${args[@]}"; do [ "$a" = "-N" ] && exit "${TUNNEL_RC:-0}"; done   # tunnel master
case "$last" in
  *"/api/health"*)            printf '%s' "${HEALTH_CODE:-200}"; exit "${HEALTH_RC:-0}" ;;
  *"vault-sync.sh"*)          exit "${REMOTE_VAULT_RC:-0}" ;;
  *"find -L . -type f"*)      printf '%s\n' "${REMOTE_MEM_SHA-MEMSHA}"; exit 0 ;;
  *"rev-parse HEAD"*)         printf '%s\n' "${REMOTE_VAULT_HEAD:-deadbeefdeadbeef}"; exit 0 ;;
  *"br sync --import-only"*)  exit "${REMOTE_IMPORT_RC:-0}" ;;
  *"br sync --status --json"*) printf '%s\n' "${REMOTE_BEAD_JSON-{\"jsonl_content_hash\":\"BEADSHA\",\"jsonl_newer\":false\}}"; exit 0 ;;
  *"list-windows"*)           printf '%s\n' "${WIN_LIST-}"; exit 0 ;;   # empty => window absent
  *"new-window"*)             printf '%s\n' "${NEW_WIN_ID:-@7}"; exit 0 ;;
  *"pane_id"*)                printf '%s\n' "${PANE_ID:-%3}"; exit 0 ;;
  *"pane_current_command"*)   printf '%s\n' "${PANE_CMD:-zsh}"; exit 0 ;;
  *"reply with exactly: PONG"*) printf '%s\n' "${A7_BODY-PONG}"; exit 0 ;;
  *"claude-probe.txt"*)       printf '%s\n' "${PROBE_BODY-/home/andrew/.local/bin/claude
PROBE_RC=0}"; exit 0 ;;
  *"capture-pane"*)           printf '%s\n' "${PANE_CAPTURE:-? for shortcuts}"; exit 0 ;;
  *"result.json"*)            printf '%s' "${RESULT_JSON:-}"; exit 0 ;;
  *"has-session"*|*"send-keys"*|*"mkdir -p"*|*"setenv"*|*"DISPATCH.md"*|*"inflight"*|*"kill-window"*) exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$STUB/ssh"

# pulse-inject stub: records the injected cmd, returns a settable verdict.
cat > "$STUB/inject" <<'INJEOF'
#!/bin/bash
printf '%s\n' "$*" >> "${INJECT_LOG:-/dev/null}"
printf 'PULSE_INJECT_RESULT=%s\n' "${INJECT_VERDICT:-injected}"
exit 0
INJEOF
chmod +x "$STUB/inject"

# preflight stub (used where A1/A2 are not the thing under test)
cat > "$STUB/preflight" <<'PFEOF'
#!/bin/bash
# shellcheck disable=SC1090
[ -n "${STUB_KNOBS:-}" ] && [ -f "$STUB_KNOBS" ] && . "$STUB_KNOBS"
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
EOF
: > "$PROJ/refs/pulse-ledger.jsonl"
git init -q -b main "$PROJ" && git -C "$PROJ" add -A && git -C "$PROJ" commit -qm fixture

KNOBS="$ROOT/knobs"
export STUB_KNOBS="$KNOBS"
STATE="$ROOT/state"

# write_knobs KEY=VALUE... — values are single-quoted, because the stub SOURCES
# this file and an unquoted JSON value loses its quotes ({"a":"b"} -> {a:b}).
write_knobs() {
  local kv; : > "$KNOBS"
  for kv in "$@"; do printf "%s='%s'\n" "${kv%%=*}" "${kv#*=}" >> "$KNOBS"; done
}

# run <knob-lines...> — writes knobs then runs the dispatcher in --dry-run
# (--dry-run exercises the tunnel + ALL SIX assertions for real and stops before
# dispatching, which is exactly the surface these cases are about).
run_dry() {
  write_knobs "$@"
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
OUT=$(run_dry 'TUNNEL_RC=255')
check_verdict "A3 tunnel forward fails -> failed-tunnel" "$OUT" failed-tunnel

OUT=$(run_dry 'HEALTH_CODE=000')
check_verdict "A3 health 000 through the tunnel -> failed-tunnel" "$OUT" failed-tunnel
case "$OUT" in *"THROUGH THE TUNNEL"*) ok "A3 message blames the tunnel, not the proxy" ;;
  *) bad "A3 message blames the tunnel" "message did not mention the tunnel" ;; esac

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

: > "$ROOT/inject.log"
OUT=$(run_live "${BASE[@]}" 'RESULT_JSON=')
check_verdict "no payload before the deadline -> failed-timeout" "$OUT" failed-timeout
if grep -q 'REMOTE PULSE SURFACE' "$ROOT/inject.log"; then ok "a timeout SURFACES locally (silence is never silent here)"
else bad "timeout surfaces locally" "nothing was injected into the local window"; fi
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
if [ ! -s "$ROOT/inject.log" ]; then ok "a clean tick does NOT wake the local window"
else bad "clean tick stays quiet" "injected without a surface/bead request"; fi

echo
echo "== the surface callback (Zig's 2026-07-27 extension) =="
: > "$ROOT/inject.log"
OUT=$(run_live "${BASE[@]}" 'RESULT_JSON={"row":"di-friday","outcome":"done","note":"needs him","proof":{"kind":"cmd","cmd":"true"},"surface_request":{"reason":"pod weekly empty","question":"Populate it?","options":["Yes","Later"]}}')
check_verdict "surface_request still completes the dispatch" "$OUT" completed
if grep -q 'REMOTE PULSE SURFACE' "$ROOT/inject.log"; then ok "surface_request injects into the LOCAL window"
else bad "surface_request injects locally" "nothing injected"; fi
if grep -q -- '--window di' "$ROOT/inject.log" && grep -q -- '--session work' "$ROOT/inject.log"
then ok "surface targets session 'work' window 'di' by default"
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

# (a3.2) A BLOCKED DISPATCH RINGS work:di. Not because the block was invisible —
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
if grep -q -- "--window di" "$ROOT/inject.log"
  then ok "the block surfaces to window 'di' (the alert interface)"
  else bad "block surfaces to di" "wrong window"; fi
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
: > "$ROOT/ssh.log"; WIN_LIST='@4 di-tuesday' run_row di-tuesday
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
