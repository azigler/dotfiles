#!/usr/bin/env bash
# vault-sync-alarm-test.sh — regression tests for the vault-sync FAILURE-PROPAGATION
# contract (dotfiles-t6sd). Guards the "exit-0 lie": before this bead, vault-sync.sh
# exited 0/SUCCESS on 120 consecutive runs whose transcripts push was blocked by the
# Layer-1 secret gate, so `systemctl status` reported green while backups were dead.
#
# EVERY test runs against a fully SYNTHETIC scratch $HOME (fake vaults, fake remotes,
# a stubbed `gh`). It NEVER touches ~/.claude/vaults, ~/.claude/projects, or any real
# transcript. The "secret" it seeds is a fabricated AWS-key-SHAPED string that matches
# scrub.py's `aws-akia` regex and has never been a credential anywhere.
#
# Usage:  bash agents/vault/test/vault-sync-alarm-test.sh
#         VAULT_SYNC_TEST_KEEP=1 ... to keep the scratch dir for inspection.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
VAULTDIR="$(dirname "$HERE")"
SYNC="$VAULTDIR/vault-sync.sh"

# A FABRICATED, never-real AWS-key-shaped token: "AKIA" + exactly 16 [0-9A-Z].
# Assembled at runtime so this file itself never contains a scannable literal.
FAKE_SECRET="AKIA$(printf '%s' 'FAKESEEDEDTEST00')"

# Resolve the REAL scrub.py path NOW, against the real $HOME. This must not be
# expanded inside run_sync's env prefix: `HOME=$scratch SCRUB=$HOME/...` resolves
# $HOME to the SCRATCH home, the pre-commit hook's `[ -f "$SCRUB" ] || exit 0`
# then silently disables the gate, and every gate test passes vacuously. That
# false-green cost a debugging round; keep this here.
REAL_SCRUB="${SCRUB:-$HOME/.claude/skills/scrub-secrets/scrub.py}"
if [ ! -f "$REAL_SCRUB" ]; then
  echo "ABORT: scrub.py not found at $REAL_SCRUB — the gate under test is absent." >&2
  exit 2
fi

pass=0; fail=0
ok(){ printf 'PASS: %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/vault-sync-alarm.XXXXXX")"
cleanup(){ [ -n "${VAULT_SYNC_TEST_KEEP:-}" ] || rm -rf "$SCRATCH"; }
trap cleanup EXIT
echo "scratch: $SCRATCH"

# --------------------------------------------------------------------------- #
# build_scratch — a self-contained fake harness home with both vault tiers wired
# to local bare remotes. Arg 1 selects what is planted in the transcript:
#
#   clean       no secret at all.
#   seeded      the fake secret in a MALFORMED (truncated) JSONL line whose mtime
#               is backdated out of the live window. This is the T2/T4/T5 fault
#               injector, and it changed with dotfiles-t6sd's scrub-and-continue:
#               a plain seeded secret is no longer a failure — it is redacted and
#               the push continues, which is the whole point. What still blocks is
#               a secret scrub.py CANNOT safely remove, and the honest, realistic
#               instance of that is a transcript truncated mid-line by a crash:
#               safe_rewrite refuses to write a .jsonl whose lines will not parse,
#               leaves the file untouched, and the unchanged fail-closed gate then
#               blocks the commit. Same alarm contract, a fault that is still a
#               fault. (Backdating the mtime matters independently: a fresh file
#               counts as LIVE and is deferred rather than redacted.)
#   redactable  the fake secret in a WELL-FORMED, backdated JSONL line — the new
#               happy path: redact, commit, push, exit 0.
#   live        the fake secret in a WELL-FORMED JSONL left at NOW's mtime, i.e.
#               a session still writing. Must never be rewritten.
# --------------------------------------------------------------------------- #
build_scratch() {
  local mode="$1" H="$SCRATCH/home" WT VD
  # ${SCRATCH:?} — an unset SCRATCH here would make these `rm -rf /home` etc.
  rm -rf "${SCRATCH:?}/home" "${SCRATCH:?}/remotes" "${SCRATCH:?}/bin"
  WT="$H/.claude/projects"; VD="$H/.claude/vaults"
  mkdir -p "$WT/-test-slug/memory" "$VD" "$SCRATCH/remotes" "$SCRATCH/bin"

  # stub `gh` — the visibility guard must see PRIVATE, and credential.helper is unused
  # because both remotes are local paths.
  cat > "$SCRATCH/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in *visibility*) echo private ;; *) exit 0 ;; esac
GH
  chmod +x "$SCRATCH/bin/gh"

  # content: one memory file (always clean here) + one transcript.
  printf '# test memory %s\n' "$(date -u +%s%N)" > "$WT/-test-slug/memory/MEMORY.md"
  case "$mode" in
    seeded)
      # truncated line: valid-looking prefix, no closing brace -> unparseable JSON,
      # so scrub.py's safe_rewrite refuses to rewrite it and the gate blocks.
      printf '{"role":"user","text":"key is %s\n' "$FAKE_SECRET" > "$WT/-test-slug/t.jsonl"
      touch -d '2 hours ago' "$WT/-test-slug/t.jsonl"
      ;;
    redactable)
      printf '{"role":"user","text":"key is %s"}\n' "$FAKE_SECRET" > "$WT/-test-slug/t.jsonl"
      touch -d '2 hours ago' "$WT/-test-slug/t.jsonl"
      ;;
    live)
      printf '{"role":"user","text":"key is %s"}\n' "$FAKE_SECRET" > "$WT/-test-slug/t.jsonl"
      ;;   # mtime = now => inside VAULT_LIVE_WINDOW_SEC => live
    *)
      printf '{"role":"user","text":"nothing to see here %s"}\n' "$(date -u +%s%N)" \
        > "$WT/-test-slug/t.jsonl"
      ;;
  esac

  local v
  for v in memory transcripts; do
    git init -q --bare "$SCRATCH/remotes/$v.git"
    git --git-dir="$VD/$v.git" --work-tree="$WT" init -q
    git --git-dir="$VD/$v.git" config core.hooksPath "$VD/$v.git/hooks"
    git --git-dir="$VD/$v.git" config user.email test@example.invalid
    git --git-dir="$VD/$v.git" config user.name  "vault test"
    git --git-dir="$VD/$v.git" remote add origin "$SCRATCH/remotes/$v.git"
    mkdir -p "$VD/$v.git/hooks"
    printf '%s %s\n' "$(date -u +%F)" PRIVATE > "$VD/.$v-visibility"
  done
  install -m 0755 "$VAULTDIR/pre-commit-scrub"             "$VD/memory.git/hooks/pre-commit"
  install -m 0755 "$VAULTDIR/pre-commit-scrub-transcripts" "$VD/transcripts.git/hooks/pre-commit"

  # commit #1 on each tier so `pull --rebase origin main` has a branch to track.
  for v in memory transcripts; do
    git --git-dir="$VD/$v.git" --work-tree="$WT" \
        -c core.excludesFile="$VAULTDIR/$v.excludes" commit -q --allow-empty \
        -m "init $v" --no-verify
    git --git-dir="$VD/$v.git" branch -M main 2>/dev/null
    git --git-dir="$VD/$v.git" push -q origin main
  done
}

# run_sync — invoke vault-sync.sh against the scratch home. Echoes combined output
# to $RUN_OUT and sets $RUN_RC. stderr is CAPTURED, never discarded (that swallowing
# is the bug class under test).
RUN_OUT=""; RUN_RC=0
RUN_SCRUB=""            # override scrub.py for one run (broken-redactor tests)
run_sync() {
  local H="$SCRATCH/home"
  RUN_OUT=$(
    HOME="$H" \
    PATH="$SCRATCH/bin:$PATH" \
    VAULT_DIR="$H/.claude/vaults" \
    MEMORY_EXCLUDES="$VAULTDIR/memory.excludes" \
    TRANSCRIPTS_EXCLUDES="$VAULTDIR/transcripts.excludes" \
    SCRUB="${RUN_SCRUB:-$REAL_SCRUB}" \
    VAULT_SYNC_LEDGER="$H/.claude/vault-sync-ledger.jsonl" \
    VAULT_REDACTION_LEDGER="$H/.claude/vault-redactions.jsonl" \
    bash "$SYNC" 2>&1
  )
  RUN_RC=$?
  # VAULT_SYNC_TEST_VERBOSE=1 replays the run's full combined output — the only way
  # to READ what a redacting run actually says, which is the whole visibility claim.
  if [ -n "${VAULT_SYNC_TEST_VERBOSE:-}" ]; then
    printf '\n>>> run_sync (rc=%d) <<<\n%s\n>>> end <<<\n\n' "$RUN_RC" "$RUN_OUT"
  fi
}
REDL="$SCRATCH/home/.claude/vault-redactions.jsonl"
redl_count() { wc -l < "$REDL" 2>/dev/null || echo 0; }
remote_blob() {  # $1 = tier, $2 = path — echo the committed content on the REMOTE
  git --git-dir="$SCRATCH/remotes/$1.git" show "main:$2" 2>/dev/null
}

stamp_age_set() {   # arg1: tier, arg2: `date -d` offset — forge stamp mtime + body
  local f="$SCRATCH/home/.claude/vaults/.last-success-$1"
  printf '%s\n' "$(date -u -d "$2" +%FT%TZ)" > "$f"
  touch -d "$2" "$f"
}

# =========================================================================== #
echo "--- T1: fully healthy run exits 0 (no false alarm) ------------------"
build_scratch clean
run_sync
[ "$RUN_RC" -eq 0 ] && ok "healthy-run-exits-0" || no "healthy-run-exits-0 (rc=$RUN_RC)
$RUN_OUT"
printf '%s' "$RUN_OUT" | grep -q 'vault-sync OK' \
  && ok "healthy-run-verdict-OK" || no "healthy-run-verdict-OK"
for t in memory transcripts; do
  [ -f "$SCRATCH/home/.claude/vaults/.last-success-$t" ] \
    && ok "healthy-writes-$t-success-stamp" || no "healthy-writes-$t-success-stamp"
done

echo "--- T2: transcripts blocked, memory OK -> exit 10 (partial failure) --"
build_scratch seeded
run_sync
[ "$RUN_RC" -eq 10 ] && ok "partial-failure-exits-10" || no "partial-failure-exits-10 (rc=$RUN_RC)
$RUN_OUT"
# the whole point of a DISTINCT code: 10 != 0, so a memory-only success is NOT
# reported as a both-tiers success.
[ "$RUN_RC" -ne 0 ] && ok "partial-failure-not-conflated-with-success" \
                    || no "partial-failure-not-conflated-with-success"
printf '%s' "$RUN_OUT" | grep -q 'transcripts=blocked' \
  && ok "partial-failure-names-the-tier" || no "partial-failure-names-the-tier"
printf '%s' "$RUN_OUT" | grep -q 'memory=ok' \
  && ok "partial-failure-reports-memory-ok" || no "partial-failure-reports-memory-ok"
[ -f "$SCRATCH/home/.claude/vaults/.last-success-memory" ] \
  && ok "blocked-tier-does-not-suppress-healthy-tier-stamp" \
  || no "blocked-tier-does-not-suppress-healthy-tier-stamp"
[ ! -f "$SCRATCH/home/.claude/vaults/.last-success-transcripts" ] \
  && ok "blocked-tier-writes-no-success-stamp" || no "blocked-tier-writes-no-success-stamp"

echo "--- T3: the ledger row harnessd reads ------------------------------"
LEDGER="$SCRATCH/home/.claude/vault-sync-ledger.jsonl"
[ -f "$LEDGER" ] && ok "ledger-written" || no "ledger-written"
if [ -f "$LEDGER" ]; then
  tail -n1 "$LEDGER" | python3 -c '
import json,sys
r=json.loads(sys.stdin.read())
assert r["row"]=="vault-sync", r
assert r["outcome"]=="blocked", r          # blocked => harnessd renders amber
assert r["ts"].endswith("Z"), r
' && ok "ledger-row-shape-matches-harnessd" || no "ledger-row-shape-matches-harnessd"
fi

echo "--- T4: a blocked run does NOT skip the other tier ------------------"
build_scratch seeded
run_sync
printf '%s' "$RUN_OUT" | grep -q 'transcripts: pulled latest' \
  && ok "both-tiers-still-attempted" || no "both-tiers-still-attempted"
# The strong form: the MEMORY content must actually be on the memory REMOTE even
# though the transcripts tier was blocked in the same run.
git --git-dir="$SCRATCH/remotes/memory.git" ls-tree -r --name-only main 2>/dev/null \
  | grep -q '^-test-slug/memory/MEMORY.md$' \
  && ok "memory-content-reached-remote-while-transcripts-blocked" \
  || no "memory-content-reached-remote-while-transcripts-blocked"
# ...and the blocked transcript must NOT be on the transcripts remote.
git --git-dir="$SCRATCH/remotes/transcripts.git" ls-tree -r --name-only main 2>/dev/null \
  | grep -q '^-test-slug/t.jsonl$' \
  && no "blocked-transcript-must-not-reach-remote" \
  || ok "blocked-transcript-must-not-reach-remote"

echo "--- T5: staleness escalates blocked(10) -> STALE(20) after N hours --"
build_scratch seeded
run_sync                                        # first blocked run: no stamp yet
[ "$RUN_RC" -eq 10 ] && ok "no-stamp-means-degraded-not-stale" \
                     || no "no-stamp-means-degraded-not-stale (rc=$RUN_RC)"
stamp_age_set transcripts '1 hour ago'
run_sync
[ "$RUN_RC" -eq 10 ] && ok "1h-old-stamp-is-degraded-not-stale" \
                     || no "1h-old-stamp-is-degraded-not-stale (rc=$RUN_RC)"
stamp_age_set transcripts '7 hours ago'
run_sync
[ "$RUN_RC" -eq 20 ] && ok "7h-old-stamp-escalates-to-STALE-20" \
                     || no "7h-old-stamp-escalates-to-STALE-20 (rc=$RUN_RC)"
printf '%s' "$RUN_OUT" | grep -q 'STALE' \
  && ok "stale-verdict-says-STALE" || no "stale-verdict-says-STALE"

echo "--- T6: recovery — a healthy run after a failure returns to 0 -------"
build_scratch seeded
run_sync
[ "$RUN_RC" -ne 0 ] || no "pre-recovery-should-fail"
printf '{"role":"user","text":"redacted"}\n' > "$SCRATCH/home/.claude/projects/-test-slug/t.jsonl"
run_sync
[ "$RUN_RC" -eq 0 ] && ok "recovers-to-0-once-unblocked" \
                    || no "recovers-to-0-once-unblocked (rc=$RUN_RC)
$RUN_OUT"

echo "--- T7: an un-bootstrapped (inert) machine still exits 0 ------------"
rm -rf "$SCRATCH/home/.claude/vaults"
mkdir -p "$SCRATCH/home/.claude/vaults"
run_sync
[ "$RUN_RC" -eq 0 ] && ok "inert-vault-exits-0" || no "inert-vault-exits-0 (rc=$RUN_RC)"

# =========================================================================== #
# SCRUB-AND-CONTINUE (dotfiles-t6sd). A high-confidence secret in vault-bound
# content is redacted in place and the push CONTINUES. Zig's call, 2026-07-26:
# these vaults are private and the credentials involved are rotated; a fail-closed
# wall that stalls backups for five days is the worse failure.
# =========================================================================== #
echo "--- T8: seeded secret is REDACTED, committed, and PUSHED (exit 0) ----"
build_scratch redactable
run_sync
[ "$RUN_RC" -eq 0 ] && ok "redact-and-continue-exits-0" \
                    || no "redact-and-continue-exits-0 (rc=$RUN_RC)
$RUN_OUT"
printf '%s' "$RUN_OUT" | grep -q 'transcripts=ok' \
  && ok "redact-and-continue-tier-ok" || no "redact-and-continue-tier-ok"
BLOB=$(remote_blob transcripts '-test-slug/t.jsonl')
printf '%s' "$BLOB" | grep -q '\[REDACTED-SECRET\]' \
  && ok "pushed-content-carries-the-redaction-marker" \
  || no "pushed-content-carries-the-redaction-marker (blob=$BLOB)"
printf '%s' "$BLOB" | grep -qF "$FAKE_SECRET" \
  && no "pushed-content-must-not-contain-the-secret" \
  || ok "pushed-content-must-not-contain-the-secret"
# the on-disk source is redacted too (the redaction is the point, not a copy of it)
grep -qF "$FAKE_SECRET" "$SCRATCH/home/.claude/projects/-test-slug/t.jsonl" \
  && no "on-disk-transcript-must-not-contain-the-secret" \
  || ok "on-disk-transcript-must-not-contain-the-secret"
# ...and it is still valid JSONL after the rewrite.
python3 -c '
import json,sys
for i, ln in enumerate(open(sys.argv[1]).read().split("\n"), 1):
    if ln.strip(): json.loads(ln)
' "$SCRATCH/home/.claude/projects/-test-slug/t.jsonl" \
  && ok "redacted-jsonl-still-parses" || no "redacted-jsonl-still-parses"

echo "--- T9: a redacting run is DISTINGUISHABLE from a clean run ---------"
printf '%s' "$RUN_OUT" | grep -q 'scrub=\[redacted=1\]' \
  && ok "verdict-line-names-the-redaction" \
  || no "verdict-line-names-the-redaction
$RUN_OUT"
[ -s "$REDL" ] && ok "redaction-ledger-written" || no "redaction-ledger-written"
tail -n1 "$REDL" 2>/dev/null | python3 -c '
import json,sys
r=json.loads(sys.stdin.read())
assert r["row"]=="vault-scrub", r
assert r["tier"]=="transcripts", r
assert r["action"]=="redacted", r
assert r["path"].endswith("-test-slug/t.jsonl"), r
assert "aws-akia" in r["detail"], r      # pattern NAME recorded...
' && ok "redaction-ledger-row-shape" || no "redaction-ledger-row-shape"
grep -qF "$FAKE_SECRET" "$REDL" \
  && no "redaction-ledger-must-not-echo-the-secret" \
  || ok "redaction-ledger-must-not-echo-the-secret"
tail -n1 "$SCRATCH/home/.claude/vault-sync-ledger.jsonl" | python3 -c '
import json,sys
r=json.loads(sys.stdin.read())
assert r["outcome"]=="done", r            # green: a redaction is NOT a failure
assert r["scrub"]==1, r                   # ...but it is counted
' && ok "sync-ledger-row-is-green-but-counts-the-scrub" \
  || no "sync-ledger-row-is-green-but-counts-the-scrub"
# the control: a clean run must NOT carry a scrub term.
build_scratch clean
run_sync
printf '%s' "$RUN_OUT" | grep -q 'scrub=' \
  && no "clean-run-carries-no-scrub-term" || ok "clean-run-carries-no-scrub-term"

echo "--- T10: idempotence — a second run over redacted content is a no-op -"
build_scratch redactable
run_sync
BEFORE_N=$(redl_count)
BEFORE_SUM=$(md5sum < "$SCRATCH/home/.claude/projects/-test-slug/t.jsonl")
touch -d '2 hours ago' "$SCRATCH/home/.claude/projects/-test-slug/t.jsonl"
run_sync
[ "$RUN_RC" -eq 0 ] && ok "second-run-exits-0" || no "second-run-exits-0 (rc=$RUN_RC)"
[ "$(redl_count)" -eq "$BEFORE_N" ] \
  && ok "second-run-appends-no-redaction-ledger-rows" \
  || no "second-run-appends-no-redaction-ledger-rows ($BEFORE_N -> $(redl_count))"
[ "$(md5sum < "$SCRATCH/home/.claude/projects/-test-slug/t.jsonl")" = "$BEFORE_SUM" ] \
  && ok "second-run-does-not-rewrite-the-file" || no "second-run-does-not-rewrite-the-file"
printf '%s' "$RUN_OUT" | grep -q 'scrub=' \
  && no "second-run-carries-no-scrub-term" || ok "second-run-carries-no-scrub-term"

echo "--- T11: a BROKEN scrub.py still turns the unit red -----------------"
build_scratch redactable
cat > "$SCRATCH/bin/broken-scrub.py" <<'BS'
#!/usr/bin/env python3
import sys
print("boom: the redactor is broken", file=sys.stderr)
sys.exit(3)
BS
RUN_SCRUB="$SCRATCH/bin/broken-scrub.py"
run_sync
RUN_SCRUB=""
[ "$RUN_RC" -ne 0 ] && ok "broken-scrub-turns-unit-red" \
                    || no "broken-scrub-turns-unit-red (rc=$RUN_RC)
$RUN_OUT"
printf '%s' "$RUN_OUT" | grep -q 'redactor is broken' \
  && ok "broken-scrub-says-why" || no "broken-scrub-says-why"
grep -qF "$FAKE_SECRET" <(remote_blob transcripts '-test-slug/t.jsonl') \
  && no "broken-scrub-must-not-push-the-secret" || ok "broken-scrub-must-not-push-the-secret"

echo "--- T12: a LIVE transcript is never rewritten, only deferred --------"
build_scratch live
LIVE_SUM=$(md5sum < "$SCRATCH/home/.claude/projects/-test-slug/t.jsonl")
run_sync
[ "$RUN_RC" -eq 0 ] && ok "live-deferral-exits-0" || no "live-deferral-exits-0 (rc=$RUN_RC)
$RUN_OUT"
[ "$(md5sum < "$SCRATCH/home/.claude/projects/-test-slug/t.jsonl")" = "$LIVE_SUM" ] \
  && ok "live-transcript-bytes-untouched" || no "live-transcript-bytes-untouched"
remote_blob transcripts '-test-slug/t.jsonl' | grep -qF "$FAKE_SECRET" \
  && no "live-transcript-secret-must-not-reach-remote" \
  || ok "live-transcript-secret-must-not-reach-remote"
printf '%s' "$RUN_OUT" | grep -q 'scrub=\[deferred-live=1\]' \
  && ok "live-deferral-is-visible-in-the-verdict" \
  || no "live-deferral-is-visible-in-the-verdict
$RUN_OUT"
# ...and once the session goes quiet, the very next fire cleans it up and pushes.
touch -d '2 hours ago' "$SCRATCH/home/.claude/projects/-test-slug/t.jsonl"
run_sync
[ "$RUN_RC" -eq 0 ] && ok "deferred-file-lands-on-the-next-fire" \
                    || no "deferred-file-lands-on-the-next-fire (rc=$RUN_RC)"
remote_blob transcripts '-test-slug/t.jsonl' | grep -q '\[REDACTED-SECRET\]' \
  && ok "deferred-file-is-redacted-then-pushed" || no "deferred-file-is-redacted-then-pushed"

echo "--- T13: the MEMORY tier scrubs-and-continues too --------------------"
build_scratch clean
printf '# notes\napi key: %s\n' "$FAKE_SECRET" \
  > "$SCRATCH/home/.claude/projects/-test-slug/memory/MEMORY.md"
run_sync
[ "$RUN_RC" -eq 0 ] && ok "memory-redact-and-continue-exits-0" \
                    || no "memory-redact-and-continue-exits-0 (rc=$RUN_RC)
$RUN_OUT"
remote_blob memory '-test-slug/memory/MEMORY.md' | grep -q '\[REDACTED-SECRET\]' \
  && ok "memory-pushed-content-is-redacted" || no "memory-pushed-content-is-redacted"
remote_blob memory '-test-slug/memory/MEMORY.md' | grep -qF "$FAKE_SECRET" \
  && no "memory-pushed-content-must-not-contain-the-secret" \
  || ok "memory-pushed-content-must-not-contain-the-secret"
grep -q '"tier": "memory"' "$REDL" \
  && ok "memory-redaction-is-ledgered" || no "memory-redaction-is-ledgered"

echo
printf '== %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
