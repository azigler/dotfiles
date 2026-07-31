#!/bin/bash
# pulse-dispatch-remote.sh — run ONE pulse tick on marketing-vps (the LinearB
# company seat) while this machine stays the authority for the LEDGER and the
# BELL.
#
# Zig's framing, which the whole design serves:
#
#     "this machine kicks off the work, the VPS runs the reasoning and drafting,
#      the result comes back here, and THIS machine marks the pulse done and
#      updates the ledger."
#
# So the split is not "where does the tick run" and it is not "the box is not
# trusted to write." marketing-vps is a PEER: it reaches the fleet proxy, holds
# the service-account key, has a git identity that commits and pushes, and may
# write beads (Zig, 2026-07-28). It lands its own deliverables.
#
# Exactly two things are reserved to zig-computer, each for a specific reason:
#
#   THE LEDGER   refs/pulse-ledger.jsonl is a single-writer file. A remote write
#                forks it and the fork is invisible until two rows disagree. The
#                tick reports outcome/proof/note in the result payload; this
#                script writes the row.
#   THE BELL     an AskUserQuestion on an unattended shared box reaches nobody
#                and freezes the pane. The tick fills in surface_request and the
#                local session raises the real question here.
#
# Everything else the tick produces — a doc tab, an Asana comment, a commit, a
# bead — it produces itself, and pushes.
#
# ---------------------------------------------------------------------------
# The flow
# ---------------------------------------------------------------------------
#   1. tunnel up      PROBE FIRST, then ADOPT-OR-OPEN. Open the control master
#                     with NO forward, and ask the box whether 127.0.0.1:<port>
#                     already answers. 200 -> TUNNEL_MODE=adopted, which under the
#                     standing-forward posture (Zig, 2026-07-29) is the normal
#                     steady state. Only when nothing healthy is there does this
#                     run open `ssh -R <port>:127.0.0.1:<port>` itself
#                     (ExitOnForwardFailure=yes, TUNNEL_MODE=owned), reclaiming a
#                     bound-but-dead port once if the bind is refused. Either way,
#                     http://localhost:7100 is zig's fleet proxy on BOTH machines
#                     — which is why no skill needs a hostname branch.
#   2. refresh        ALL FOUR freshness tiers, dispatch-triggered (see below).
#   3. preflight      seven hard assertions, below. Nothing is dispatched unless
#                     all six pass.
#   4. dispatch       stage DISPATCH.md, send-keys `/pulse tick <remote-dir>` into
#                     the box's tmux.
#   5. poll           wait for result.json to appear and parse.
#   6. land           write the ledger row HERE; file any bead the payload
#                     REQUESTED (the box may also have filed its own and pushed).
#   7. surface        if the payload carries a surface_request, inject into the
#                     LOCAL work:di window so the LOCAL session raises the
#                     AskUserQuestion.
#   8. tunnel down    EXIT trap, always — but it only ever tears down a forward
#                     THIS RUN opened. An adopted box-side forward, and one that
#                     A3's self-heal opened, are both left exactly as found: the
#                     box is meant to hold a standing forward.
#
# ---------------------------------------------------------------------------
# THE FOUR FRESHNESS TIERS — and why "stale" is worse than "broken"
# ---------------------------------------------------------------------------
# Zig's framing (2026-07-27), which sets the bar for this whole section:
#
#     Missing output he catches on his weekly harvest. WRONG output he cannot.
#
# A stale box does not fail. It produces a complete, plausible, confidently wrong
# artifact built from last week's logic — a tie-in audit against a retired format,
# a post calibrated on superseded voice feedback — and it lands in Asana looking
# exactly like a good one. There is no signal to notice. That makes freshness a
# CORRECTNESS property, not a hygiene one, and it is why every tier below is
# refreshed at dispatch and then GATED on identity rather than on an age budget.
#
# Four tiers feed a tick, and as measured on 2026-07-27 all four were hourly-
# polled with NONE of them dispatch-triggered — i.e. a tick could fire up to an
# hour behind on every one of them simultaneously:
#
#   T1 REPOS        ~/dotfiles (global skills reach the box through the
#                   ~/.claude/skills -> ~/dotfiles/agents/skills symlink, plus the
#                   global CLAUDE.md) and ~/linearb + the dashboard-dev-interrupted
#                   submodule (project skills, refs/pulse.md, .beads/issues.jsonl).
#                   Poller: vps-repo-refresh.timer, hourly. Measured ~2 commits behind.
#   T2 MEMORY       ~/.claude/projects/<slug>/memory — the feedback corpus the DI
#                   skills calibrate voice against. Poller: claude-vault-sync.timer,
#                   hourly. Measured DIVERGENT at inspection (MEMORY.md md5 differed
#                   because a memory file had just been written locally).
#   T3 TRANSCRIPTS  same vault, different sparse scope.
#   T4 BEAD INDEX   `br` reads .beads/beads.db, not the JSONL that arrives with
#                   the T1 pull, so after the pull the index must be rebuilt or
#                   bead state reads stale/absent. The DB is gitignored and
#                   reconciliation happens through git + the jsonl-union merge
#                   driver, so rebuilding it is a read-freshness step, not a risk.
#
# What this script does about it: refresh all four EXPLICITLY at dispatch (step
# 2), then hard-fail if any is still behind (step 3). The refresh is not trusted
# to have worked — each tier is re-asserted afterward against zig-computer:
#
#   T1 -> A1/A2  sha identity per repo and submodule (vps-preflight)
#   T2 -> A5     sha256 digest identity over the whole project memory dir
#   T3 -> (warn) the vault sync runs and its exit code is decoded; the sparse
#                scope for this slug is being fixed out of band, so a
#                transcripts-only failure is a LOUD WARN, not a block. It is the
#                one tier a tick does not read from.
#   T4 -> A6     `br sync --status --json`.jsonl_content_hash identity, plus
#                jsonl_newer == false (nothing left un-imported)
#
# Content-hash identity is deliberate, and it is the same choice vps-preflight
# already made for repos: there is no "close enough" window to tune wrong, and a
# digest cannot report green on a box an hour behind the way a timestamp check can.
#
# What step 2/3 do about T4 is READ-freshness only: `br sync --import-only`
# rebuilds .beads/beads.db, which is gitignored (`.beads/*.db`), so it dirties no
# tracked file at all. The tick itself MAY write beads (Zig, 2026-07-28) — the
# DISPATCH.md contract below spells out the pull/write/flush/commit/push
# discipline that goes with it.
#
# ---------------------------------------------------------------------------
# A DIRTY CHECKOUT DOES NOT BLOCK A TICK (Zig, 2026-07-30 · dotfiles-f4ub)
# ---------------------------------------------------------------------------
# The freshness tiers above are about STALE CODE. Dirt is a different thing and it
# used to be conflated with staleness: vps-repo-refresh.sh hard-failed on any
# modified tracked file, and vps-preflight.sh blocked on uncommitted changes HERE.
# Both are now warnings. Ticks proceed and work in messy repos, commit their own
# paths when done, and leave everything else exactly as they found it.
#
# The removed gate is replaced, not simply deleted — that replacement is step 2b'
# below. The receipt records dirty paths and whether each pull actually advanced;
# vps-preflight surfaces it and writes --report; this script puts it in the tick's
# DISPATCH.md and in the ledger row. What still BLOCKS is code drift the box would
# actually run differently: A2's sha identity, in both directions.
#
# ---------------------------------------------------------------------------
# Why the preflight is the load-bearing part (explore-7iz9 §10)
# ---------------------------------------------------------------------------
# These ticks already have a rich vocabulary for legitimately not finishing:
# `blocked` on a missing Pod Weekly, a P1 `human:` bead, a deferred bell. A remote
# tick that loses its tunnel, runs against a stale submodule, or finds `claude`
# off PATH files a row that looks EXACTLY like a legitimate parked deliverable —
# and nobody is attached to that box. Silence and success are indistinguishable.
#
# The answer is not better remote logging (a log on an unwatched box is the
# transcript-vault outage that ran green for 120 hours). The answer is that the
# infrastructure failures are converted into a NONZERO EXIT ON THE MACHINE ZIG
# WATCHES, before a single remote token is spent. The remote tick is never warned
# about a broken precondition; it is never started.
#
# The six assertions, and the specific silent failure each one buys:
#
#   A1  submodule empty on the box      -> a tick finds no refs/pulse.md and
#                                          reports "empty project", not "broken".
#                                          (vps-preflight `require` + receipt)
#   A2  box repo HEAD behind origin     -> the tick drafts confidently off code
#                                          days older than the local skills.
#                                          (vps-preflight sha identity, 3 axes)
#                                          Since dotfiles-w16i A2 REPAIRS the one
#                                          case that cannot lose work: a LOCAL
#                                          checkout strictly behind the published
#                                          tip is fast-forwarded and recorded,
#                                          because on a peer fleet zig-computer
#                                          falls behind as routine. Ahead and
#                                          diverged still block for a human.
#   A3  tunnel not answering /api/health -> every Asana/Slack call 000s and the
#       *** FROM THE VPS SIDE ***          tick files "blocked: no data". Testing
#                                          this locally proves NOTHING: the proxy
#                                          is always up locally. The forward is
#                                          what breaks, and only the far end can
#                                          see the forward.
#   A4  `claude` not on the pane's PATH -> `vps run` is a NON-login shell and the
#                                          box's claude/node live behind an
#                                          interactive-zsh login profile. Wrong
#                                          shell shape = "command not found",
#                                          typed into a pane nobody reads.
#   A5  memory tier behind              -> the DI voice skills calibrate against
#                                          the feedback corpus. A tick an hour
#                                          behind writes to last week's rules and
#                                          nothing about the output says so.
#   A6  bead index behind the JSONL     -> `br` reads the DB. A box that pulled a
#                                          new JSONL but never imported it reads
#                                          bead state that is silently stale or
#                                          absent, so the tick's own context is wrong.
#
# A1 and A2 are delegated to vps-preflight.sh, which already implements them
# (including the axis nobody names: GitHub behind ZIG-COMPUTER, which no pull can
# fix). A3-A6 are implemented here because they are properties of THIS dispatch's
# tunnel, pane, memory tier, and bead index — not of the checkout.
#
# ---------------------------------------------------------------------------
# The two things the remote tick may NEVER do — and the one it must do carefully
# ---------------------------------------------------------------------------
#   NO LEDGER.  refs/pulse-ledger.jsonl is authoritative HERE. A remote write
#               would fork it, and the fork is invisible until two rows disagree.
#               (vps-repo-manifest.txt does list the ledger as a `harvest` path —
#               that is a BACKSTOP, not the channel: it keeps a rogue remote write
#               from blocking the next ff-only pull and from being lost. The
#               payload below is the contract.)
#   NO BELL.    No AskUserQuestion. Nobody is attached to that box, so a dialog
#               there reaches no one and freezes the pane. The payload's
#               surface_request fires back here and the LOCAL session asks.
#
#   BEADS ARE ALLOWED, THROUGH GIT (Zig, 2026-07-28). The old ban assumed two
#               bead stores that could not reconcile. They reconcile now: the box
#               pulls and pushes, and the `jsonl-union` merge driver is registered
#               on BOTH machines, so a concurrent write dedupes by id and keeps the
#               newer updated_at. The discipline is pull -> br -> `br sync
#               --flush-only` -> commit -> push, staging `.beads/issues.jsonl` BY
#               NAME (a directory pathspec stages deletions — see DISPATCH.md §4).
#               A bead written on the box and never pushed is the failure mode
#               now; a dirty .beads/ left behind is no longer one. The payload's
#               bead_request remains available for a tick that would rather hand
#               the filing back.
#
# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------
# marketing-vps is a SHARED box (ben, kevin, mike, ubuntu also have accounts).
# Nothing is copied to it.
#
# ⚠️ THE TUNNEL IS NO LONGER RUN-LIFETIME-BOUNDED, and pretending otherwise would
# be the more dangerous error. Zig's 2026-07-29 call is that the box holds a
# STANDING forward (ensure-fleet-tunnel.sh's `ssh -L`), so the normal case is
# TUNNEL_MODE=adopted: 127.0.0.1:$PORT answers on the box before this dispatch
# starts and keeps answering after it ends. Only TUNNEL_MODE=owned — the fallback
# where no healthy path existed — dies with this script's ssh process. What that
# costs is honest and worth stating: the fleet proxy is reachable from the box by
# anyone with a shell there, continuously, not just for a tick's duration.
#
# The CREDENTIALS are unaffected and remain run-scoped either way: they live in the
# tmux session environment, are refcounted per in-flight row, and are unset at
# teardown regardless of tunnel mode.
# FLEET_API_TOKEN is the single sanctioned exception (--with-fleet-token,
# default OFF): it is piped over ssh STDIN — never in this script's argv, never in
# the ssh command line, never written to the box's disk — into the tmux session
# environment, and unset again at teardown. The residual exposure is honest and
# worth stating: `tmux setenv` takes the value as an argument, so it is visible in
# that one short-lived process's /proc cmdline, and readable via
# `tmux show-environment` by the `andrew` account for the tunnel's lifetime. It is
# never persisted. Rotate on any suspicion; prefer a per-tick minted token when the
# proxy learns to mint one.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   pulse-dispatch-remote.sh --row <name> --dir <local-project> [options]
#
#   --row            REQUIRED. The pulse row to run. Never hardcoded; it is
#                    validated against <dir>/refs/pulse.md so a typo cannot
#                    become an "unattributed" ledger row.
#   --dir            REQUIRED. The LOCAL authoritative project dir. The ledger is
#                    written here.
#   --remote-dir     The project dir ON THE BOX. Default: /home/andrew/linearb/<basename of --dir>
#   --host           ssh alias (default marketing-vps, or $VPS_HOST)
#   --port           fleet proxy port to reverse-forward (default 7100)
#   --remote-session tmux session on the box (default pulse-dispatch — deliberately
#                    NOT `vps-agent`, which the /vps Fable runs drive)
#   --session        LOCAL tmux session for the surface callback (default work)
#   --window         LOCAL tmux window for the surface callback (default di)
#   --timeout        seconds to wait for the remote result (default 3600)
#   --poll           seconds between result polls (default 30)
#   --fresh          warm process, COLD CONTEXT: when the remote pane already runs
#                    claude, send `/clear` and settle BEFORE the tick, so a weekly
#                    row does not open on top of last week's conversation. No-op on
#                    a cold launch (already fresh). Same semantics as
#                    pulse-inject.sh --fresh; PULSE_FRESH_SETTLE (default 2) tunes
#                    the settle. Matters MORE here than locally: each row now owns a
#                    durable per-row session on the box, so without this a weekly
#                    tick reliably resumes a 7-day-old context.
#   --with-fleet-token  broker FLEET_API_TOKEN into the remote tick's tmux env
#   --allow-unpushed    passed through to vps-preflight (hand-fires only)
#   --no-refresh        passed through to vps-preflight (diagnostics only)
#   --skip-sync      DIAGNOSTICS ONLY. Skip the T2/T3/T4 refresh (step 2c-2e) but
#                    still run assertions A5/A6, so you can see what is stale
#                    without changing it. NEVER set this in a timer unit.
#   --loop <id>      loop id, for bounce records (units pass --loop %p)
#   --dry-run        run the tunnel, the full four-tier refresh, and ALL SIX
#                    assertions for real, then stop. Dispatches nothing, writes no
#                    ledger row, injects nothing.
#
# ---------------------------------------------------------------------------
# OUTCOME CONTRACT — PULSE_DISPATCH_RESULT (same discipline as pulse-inject.sh)
# ---------------------------------------------------------------------------
# The exit code cannot answer "did the tick run, and did its result land?". So
# every terminal path prints exactly ONE machine-readable line, LAST on STDOUT:
#
#   PULSE_DISPATCH_RESULT=completed        remote tick ran; ledger row written here
#   PULSE_DISPATCH_RESULT=dry-run-ok       all six assertions passed; nothing dispatched
#   PULSE_DISPATCH_RESULT=failed-usage     bad/missing args (64)
#   PULSE_DISPATCH_RESULT=failed-row       --row is not in the project's pulse.md (65)
#   PULSE_DISPATCH_RESULT=failed-tunnel    step 1: no usable path to the fleet proxy —
#                                          the -R bind was refused AND the box has no
#                                          healthy forward of its own AND reclaiming the
#                                          port did not help; or the box is unreachable;
#                                          or A3: /api/health not 200 from the VPS side (71)
#   PULSE_DISPATCH_RESULT=failed-preflight A1/A2: vps-preflight blocked (73)
#   PULSE_DISPATCH_RESULT=failed-no-claude A4: claude not on the target pane's PATH (74)
#   PULSE_DISPATCH_RESULT=failed-inject    could not type the tick into the box (75)
#   PULSE_DISPATCH_RESULT=failed-timeout   no result payload within --timeout (76)
#   PULSE_DISPATCH_RESULT=failed-payload   payload missing/malformed/row mismatch (77)
#   PULSE_DISPATCH_RESULT=failed-ledger    ledger row rejected by the lint; rolled back (78)
#   PULSE_DISPATCH_RESULT=failed-vault     A5: memory tier not identical after sync (79)
#   PULSE_DISPATCH_RESULT=failed-beads     A6: bead index not current with the JSONL (80)
#   PULSE_DISPATCH_RESULT=failed           any other non-zero exit
#
# FAIL CLOSED: exit 0 with no marker means an older dispatcher or a path that
# forgot to report — treat it as NOT completed. Only `completed` may set a
# caller's "the tick ran" flag.
#
# TEST SEAMS (same idiom as PULSE_TMUX_BIN in pulse-inject.sh) — unset in
# production, where resolution is byte-for-byte what it was:
#   PULSE_DISPATCH_SSH / _PREFLIGHT / _INJECT / _LINT / _STATE / _VAULT
#
# Bead: bd-zcxo   ·   Architecture: ~/explore/refs/vps-architecture-and-pulse-migration.md §8(c), §9 Phase 3, §10

set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LOG=/tmp/pulse-dispatch-remote.log

SSH_BIN="${PULSE_DISPATCH_SSH:-ssh}"
PREFLIGHT="${PULSE_DISPATCH_PREFLIGHT:-$HERE/vps-preflight.sh}"
INJECT="${PULSE_DISPATCH_INJECT:-$HERE/pulse-inject.sh}"
MANIFEST="${PULSE_DISPATCH_MANIFEST:-$HERE/vps-repo-manifest.txt}"
SCRUB="${PULSE_DISPATCH_SCRUB:-$HOME/.claude/skills/scrub-secrets/scrub.py}"
RSYNC_BIN="${PULSE_DISPATCH_RSYNC:-rsync}"
LEDGER_LINT="${PULSE_DISPATCH_LINT:-$HERE/pulse-ledger-lint.py}"
STATE_ROOT="${PULSE_DISPATCH_STATE:-$HOME/.local/state/pulse-dispatch}"
# The local vault entrypoint — the same script claude-vault-sync.timer runs.
LOCAL_VAULT_SYNC="${PULSE_DISPATCH_VAULT:-$HERE/../vault/vault-sync.sh}"
REMOTE_VAULT_SYNC='$HOME/dotfiles/agents/vault/vault-sync.sh'
# The box's own tunnel self-heal — it reaches BACK here over ssh and opens the
# forward itself when the reverse one has died. Single-quoted on purpose: $HOME
# must expand on the box, not here (same convention as REMOTE_VAULT_SYNC).
REMOTE_ENSURE_TUNNEL='$HOME/dotfiles/agents/scheduler/ensure-fleet-tunnel.sh'

HOST="${VPS_HOST:-marketing-vps}"
PORT=7100
ROW=""
DIR=""
REMOTE_DIR=""
REMOTE_SESSION="work"   # ONE session on the box; the ROW names the window
SESSION="work"
WINDOW="di"
TIMEOUT=3600
POLL=30
DRY_RUN=0
WITH_TOKEN=0
FRESH=0
ALLOW_UNPUSHED=0
NO_REFRESH=0
SKIP_SYNC=0
LOOP=""

# --- outcome contract -------------------------------------------------------
# Defined before argument parsing on purpose: `unknown arg` is the very first
# thing that can end this script, and a path that exits before the emitter exists
# is a path with no verdict.
RESULT_SENT=0
emit_result() {
  [ "$RESULT_SENT" -eq 1 ] && return 0
  RESULT_SENT=1
  printf 'PULSE_DISPATCH_RESULT=%s\n' "$1"
}

note() {
  { flock -w 5 9 || true
    printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${BASHPID:-$$}" "$*" >&9
  } 9>>"$LOG"
}
say()  { printf '%s\n' "$*"; note "$*"; }
warn() { printf 'pulse-dispatch: %s\n' "$*" >&2; note "WARN $*"; }

# fail <verdict> <exit-code> <message...>
# Every hard failure names the assertion it belongs to and its remedy, on stderr.
# This is the machine Zig watches; a failure that is not loud here is a failure
# that becomes a fake `blocked` row on a box nobody reads.
fail() {
  local verdict=$1 code=$2; shift 2
  printf 'PULSE-DISPATCH: BLOCKED — %s\n' "$*" >&2
  note "BLOCKED($verdict/$code) $*"
  # RING THE BELL. A blocked tick was not invisible before this — the harnessd
  # loop list shows the row going STALE once its cadence + grace elapses, and Zig
  # does read that (his correction, 2026-07-27). But that signal is PULL, DELAYED
  # by the grace window, and reasonless: it says "did not run", not "blocked on a
  # dirty checkout, here is the repo and the remedy." Those are different products.
  # The remote box cannot raise an AskUserQuestion anyone will see, so the LOCAL
  # work:di session raises it — same path the payload surface_request uses, and
  # work:di is the alert interface for every remote row by design.
  #
  # INVERTED 2026-07-29 (dotfiles-wv2a) — an allowlist of verdicts was the wrong
  # shape and it cost a tick: failed-tunnel was not on it, so the di-wednesday
  # dispatch that died at step 1 rang nothing at all and existed only in
  # journalctl until Zig thought to ask hours later. An allowlist has to be
  # remembered every time a verdict is added; a denylist fails safe. So: surface
  # EVERY verdict EXCEPT the two that are operator typos on a hand-run
  # (failed-usage / failed-row — those would wake the window for a slip of the
  # keyboard, and the operator is already looking at the error). A --dry-run never
  # surfaces: a human is at the terminal by definition.
  # Guarded against recursion: surface_locally warns, it never calls fail. And
  # guarded against double-ringing: a path that already surfaced (the timeout
  # path does, before failing) sets SURFACED and is not surfaced twice.
  case "$verdict" in
    failed-usage|failed-row) : ;;
    *)
      if [ "${DRY_RUN:-0}" != 1 ] && [ "${SURFACED:-0}" != 1 ] \
         && [ -n "${LOCAL_STATE:-}" ] && declare -F surface_locally >/dev/null 2>&1; then
        local sfile="$LOCAL_STATE/surface-blocked.json"
        printf '%s\n' "{\"kind\":\"dispatch_blocked\",\"row\":\"$ROW\",\"run\":\"$RUN_ID\",\"verdict\":\"$verdict\",\"detail\":$(printf '%s' "$*" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '"see stderr"')}" > "$sfile" 2>/dev/null
        surface_locally "$sfile" "blocked:$verdict" || \
          warn "the block could not be surfaced to $SESSION:$WINDOW either — it exists ONLY in journalctl now"
      fi ;;
  esac
  emit_result "$verdict"
  exit "$code"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --row)             ROW=$2; shift 2 ;;
    --dir)             DIR=$2; shift 2 ;;
    --remote-dir)      REMOTE_DIR=$2; shift 2 ;;
    --host)            HOST=$2; shift 2 ;;
    --port)            PORT=$2; shift 2 ;;
    --remote-session)  REMOTE_SESSION=$2; shift 2 ;;
    --session)         SESSION=$2; shift 2 ;;
    --window)          WINDOW=$2; shift 2 ;;
    --timeout)         TIMEOUT=$2; shift 2 ;;
    --poll)            POLL=$2; shift 2 ;;
    --loop)            LOOP=$2; shift 2 ;;
    --fresh)           FRESH=1; shift ;;
    --with-fleet-token) WITH_TOKEN=1; shift ;;
    --allow-unpushed)  ALLOW_UNPUSHED=1; shift ;;
    --no-refresh)      NO_REFRESH=1; shift ;;
    --skip-sync)       SKIP_SYNC=1; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         sed -n '2,150p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "pulse-dispatch: unknown arg $1" >&2; emit_result failed-usage; exit 64 ;;
  esac
done

# PER-ROW remote session. Was a single shared "pulse-dispatch" session, with the
# pane resolved as `list-panes | head -1` — so EVERY row landed in the SAME pane,
# and row B's tick opened on top of row A's entire conversation. Locally this
# never bit us because pulse-inject.sh gives each row its own tmux WINDOW, which
# is its own Claude session; the remote side had no equivalent. Two failures fell
# out of that: context bleed (a tick reasoning over the previous row's work) and
# collision (Wed 06:00 digest + Wed 07:00 di-wednesday are an hour apart against a
# 3600s poll timeout). One session per row restores the local semantics exactly:
# durable across weeks for the same row, isolated between rows.
# ONE remote session, ONE WINDOW PER ROW — `work:di-monday`, `work:di-tuesday`,
# ... — mirroring the LOCAL layout exactly (Zig, 2026-07-27). The earlier shape
# was a session per row; windows are what the local model actually uses, and one
# `tmux attach -t work` on the box then shows every row side by side.
#
# Isolation is unchanged: a tmux WINDOW is its own pane and its own Claude
# session, so rows still cannot bleed context into each other. What DOES become
# shared is the tmux ENVIRONMENT — `setenv` is per-session, not per-window — which
# is why the credential teardown below is refcounted rather than unconditional.
REMOTE_WINDOW="$ROW"

# ---------------------------------------------------------------------------
# SURFACE BACK TO ZIG — defined HERE, before the first fail() can fire.
#
# It used to be defined at Step 10, ~400 lines below the preflight assertions,
# which meant the failure path most likely to need a human could not have called
# it even if it tried: at preflight time the function did not exist yet.
# ---------------------------------------------------------------------------
SURFACED=0
surface_locally() {
  local sfile=$1 reason=$2 cmd out verdict
  # Claimed BEFORE the attempt, not after: the point of the flag is that fail()
  # must not ring a second time for the same event, and that is true whether this
  # attempt is delivered or bounced (a bounce means work:di is already blocked on
  # Zig — ringing it again cannot help and just doubles the noise).
  SURFACED=1
  [ -x "$INJECT" ] || { warn "cannot surface: $INJECT is not executable"; return 1; }
  cmd="REMOTE PULSE SURFACE (row=$ROW, run=$RUN_ID, reason=$reason): a pulse tick that ran on marketing-vps needs you HERE. Read $sfile and raise the AskUserQuestion it describes (this is the 🔔 the remote box cannot ring), file any bead it names that the remote side did not already file and push, and land the ledger row at $DIR/refs/pulse-ledger.jsonl. Do NOT re-run the tick."
  out=$("$INJECT" --dir "$DIR" --session "$SESSION" --window "$WINDOW" \
        ${LOOP:+--loop "$LOOP"} --cmd "$cmd" 2>&1)
  printf '%s\n' "$out" | sed 's/^/    inject: /'
  verdict=$(printf '%s\n' "$out" | grep -o 'PULSE_INJECT_RESULT=[a-z-]*' | tail -1 | cut -d= -f2)
  case "${verdict:-}" in
    injected) say "surfaced: AskUserQuestion request delivered to $SESSION:$WINDOW"; return 0 ;;
    "")       warn "surface NOT delivered: no PULSE_INJECT_RESULT marker (older injector?). Treating as NOT delivered."; return 1 ;;
    *)        warn "surface NOT delivered: PULSE_INJECT_RESULT=$verdict. The request is staged at $sfile; \
$SESSION:$WINDOW must be unblocked (it may be sitting on an open question) and the surface re-sent."; return 1 ;;
  esac
}

# tmux `setenv` is per-SESSION and all rows now share `work`, so an unconditional
# unset at teardown would strip the credentials out from under a row still mid-tick
# (di-tuesday 07:00 and weekly-report 09:00 are the same session, and the poll
# timeout is an hour). Refcount instead: each dispatch claims a marker, teardown
# releases it, and only the LAST one out unsets. Markers are empty files on the
# box, never the values.
INFLIGHT_DIR="\$HOME/work/pulse-dispatch/.inflight"

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------
[ -n "$ROW" ] || { echo "pulse-dispatch: --row is required (no row is hardcoded)" >&2; emit_result failed-usage; exit 64; }
[ -n "$DIR" ] || { echo "pulse-dispatch: --dir is required" >&2; emit_result failed-usage; exit 64; }
[ -d "$DIR" ] || { echo "pulse-dispatch: --dir $DIR does not exist" >&2; emit_result failed-usage; exit 64; }
DIR=$(cd "$DIR" && pwd -P)

command -v jq >/dev/null 2>&1 || { echo "pulse-dispatch: jq required" >&2; emit_result failed-usage; exit 64; }

TABLE="$DIR/refs/pulse.md"
[ -f "$TABLE" ] || fail failed-row 65 "no routing table at $TABLE — this project is not pulse-enabled. Run /pulse setup first."

# The row must be a REAL row in Andrew's steering wheel. A typo'd --row would
# otherwise produce a ledger line naming a row no analytic knows, which is exactly
# the invisible-row defect the /pulse ledger spec spends a page on.
if ! awk -F'|' '/^[[:space:]]*\|/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); print $3 }' "$TABLE" \
     | grep -qxF "$ROW"; then
  fail failed-row 65 "row '$ROW' is not in $TABLE. Valid rows: $(awk -F'|' '/^[[:space:]]*\|/ { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$3); if ($3 != "" && $3 != "name") printf "%s ", $3 }' "$TABLE")"
fi

[ -n "$REMOTE_DIR" ] || REMOTE_DIR="/home/andrew/linearb/$(basename "$DIR")"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$ROW"
REMOTE_WORK="/home/andrew/work/pulse-dispatch/$RUN_ID"
LOCAL_STATE="$STATE_ROOT/$RUN_ID"
CTL="$LOCAL_STATE/ssh-ctl.sock"
mkdir -p "$LOCAL_STATE" || fail failed 1 "cannot create state dir $LOCAL_STATE"

note "=== dispatch run=$RUN_ID row=$ROW dir=$DIR remote=$HOST:$REMOTE_DIR dry_run=$DRY_RUN"

# ---------------------------------------------------------------------------
# Teardown. Registered BEFORE the tunnel goes up so a failure between "ssh
# started" and "trap set" cannot leak a forward on a shared box.
# ---------------------------------------------------------------------------
TUNNEL_UP=0
# How this run reached the fleet proxy. Read by cleanup(), so it must exist before
# the trap is armed.
#   TUNNEL_MODE=adopted  the box already had a healthy forward of its own and this
#                        run borrowed it. Under the standing-forward posture (Zig,
#                        2026-07-29) this is the NORMAL case, not a fallback.
#                        Teardown must NOT touch it: it is somebody else's process
#                        with somebody else's lifetime, and killing it is exactly
#                        the shared-box hazard ensure-fleet-tunnel.sh refuses to
#                        commit.
#   TUNNEL_MODE=owned    no healthy path existed, so this run opened the -R forward
#                        itself. Teardown closes it implicitly — the forward is a
#                        property of the ssh master process.
#
# DELIBERATELY ABSENT: teardown does not drop a forward that A3's self-heal opened
# mid-run. Under the standing-forward posture that heal produces exactly the state
# the box is supposed to be in, so closing it would fight the chosen posture and
# strand the NEXT tick. Do not "fix" this back into a cleanup (Zig, 2026-07-29).
TUNNEL_MODE=""
cleanup() {
  local rc=$?
  if [ "$TUNNEL_UP" = 1 ]; then
    if [ "$WITH_TOKEN" = 1 ]; then
      # Unset before the socket dies: the token must not outlive the tunnel.
      "$SSH_BIN" -S "$CTL" -o BatchMode=yes "$HOST" \
        "rm -f '$INFLIGHT_DIR/$ROW'; \
         if [ -z \"\$(ls -A '$INFLIGHT_DIR' 2>/dev/null)\" ]; then \
           for v in FLEET_API_TOKEN SITE_PASSWORD SLACK_BOT_TOKEN SLACK_NEWS_PLANNING_CHANNEL_ID; do tmux setenv -u -t '$REMOTE_SESSION' \$v; done; \
           echo unset; \
         else echo held; fi" >/dev/null 2>>"$LOCAL_STATE/teardown.err" || \
        warn "could not release the remote credential refcount (see $LOCAL_STATE/teardown.err)"
    fi
    "$SSH_BIN" -S "$CTL" -O exit "$HOST" >/dev/null 2>>"$LOCAL_STATE/teardown.err" || \
      warn "control-master exit returned non-zero; check for a stray ssh to $HOST"
    note "master down (TUNNEL_MODE=${TUNNEL_MODE:-unknown}$([ "$TUNNEL_MODE" = adopted ] && printf ' — the box-side forward is left up, by design'))"
  fi
  [ "$rc" -ne 0 ] && emit_result failed
  exit "$rc"
}
trap cleanup EXIT

# rsh <command...> — run on the box through the control master, LOGIN shell.
#
# bash -lc, not `ssh host cmd`: the box's claude/node/bun live behind an
# interactive-zsh login profile and `vps run` (a non-login shell) cannot see
# them. Anything that shells out non-login silently gets "command not found",
# which is failure mode #1 in explore-7iz9 §1.7.
#
# stderr is deliberately NOT suppressed anywhere in this script. A swallowed
# remote error reads as "no data", and "no data" reads as a legitimate quiet
# tick — the exact confusion §10 is about.
rsh() { "$SSH_BIN" -S "$CTL" -o BatchMode=yes "$HOST" "bash -lc $(printf '%q' "$*")"; }

# ---------------------------------------------------------------------------
# Step 1 — TUNNEL UP: PROBE FIRST, THEN ADOPT-OR-OPEN.
#
# WHAT THIS COST US (2026-07-29, dotfiles-wv2a). This step used to do exactly one
# thing: open `ssh -R` with ExitOnForwardFailure=yes and die if the bind was
# refused. Two features shipped the same day bind the SAME port on the box — this
# reverse forward, and ensure-fleet-tunnel.sh's local `ssh -L` self-heal — so
# whichever is up first wins and the other is refused. On the morning of the 29th
# the box already held a HEALTHY local forward (curl 127.0.0.1:7100/api/health ->
# 200 from the box), and the di-wednesday dispatch killed itself at step 1 rather
# than use it. The tick never ran; nothing rang.
#
# The asymmetry WAS the bug: ensure-fleet-tunnel.sh is explicitly tolerant ("never
# fights a healthy tunnel — if the port answers, do nothing"), and step 3's A3
# already treats a box-owned forward as a legitimate state. Only step 1 was
# intolerant, ~370 lines before A3 could say so.
#
# PROBE FIRST, not try-then-fall-back. Zig's 2026-07-29 posture call is that the
# box KEEPS a standing forward, which makes `adopted` the steady state rather than
# the exception. Attempting the -R first would then push a scary "remote port
# forwarding failed for listen port 7100" line into tunnel.err on essentially
# EVERY run — noise that trains a reader to ignore the one file that matters when
# the tunnel is genuinely broken. So: ask first, and only bind when nothing
# healthy answers.
#
#   a. master with NO forward   — fails => the box is genuinely unreachable.
#   b. probe from the box       — three-valued, the same contract as /vps and
#                                 ensure-fleet-tunnel.sh: 200 up / 000 nothing
#                                 listening / anything else = BLOCKED (a real
#                                 answer, never "no data").
#      200                      => ADOPT. Normal path. Say it plainly.
#   c. not 200                  => no healthy path. Close the master, open one
#                                 WITH -R (=> owned). If that bind is refused the
#                                 port is bound-but-dead, so ask the box to drop
#                                 only ITS OWN forward (pidfile-scoped; a pkill on
#                                 port $PORT would murder another user's run on a
#                                 shared box) and retry the -R exactly ONCE.
#   d. still failing            => fail failed-tunnel with the real reason.
#
# ExitOnForwardFailure=yes remains load-bearing on the -R we open ourselves.
# Without it ssh connects happily when the remote port is already bound, and every
# subsequent proxy call from the box reaches SOMEONE ELSE'S listener or nothing at
# all — with the ssh exiting 0. That is a silent wrong-answer generator, which is
# the one thing worse than the hard failure this step used to produce.
# ---------------------------------------------------------------------------
open_master() {   # the control master, NO forward
  "$SSH_BIN" -f -N -M -S "$CTL" \
    -o BatchMode=yes -o ConnectTimeout=15 \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    "$HOST" 2>>"$LOCAL_STATE/tunnel.err"
}
open_reverse() {  # the control master, WITH the reverse forward
  "$SSH_BIN" -f -N -M -S "$CTL" \
    -o ExitOnForwardFailure=yes -o BatchMode=yes -o ConnectTimeout=15 \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -R "127.0.0.1:$PORT:127.0.0.1:$PORT" "$HOST" 2>>"$LOCAL_STATE/tunnel.err"
}
close_master() {
  [ -e "$CTL" ] || return 0
  "$SSH_BIN" -S "$CTL" -O exit "$HOST" >/dev/null 2>>"$LOCAL_STATE/tunnel.err" || rm -f "$CTL"
}
# Three-valued probe FROM THE BOX. Never `curl ... || echo 000`: on a refused
# connection curl both prints 000 and exits non-zero, so a fallback would fire too
# and the caller would read "000\n000" — matching neither branch. Capture, then
# substitute only when the output is genuinely empty (which means the ssh hop
# itself said nothing).
box_health() {
  local code
  code=$(rsh "curl -s -o /dev/null -m 15 -w '%{http_code}' http://127.0.0.1:$PORT/api/health" 2>>"$LOCAL_STATE/tunnel.err")
  code=${code//$'\r'/}
  printf '%s' "${code:-000}"
}

say "tunnel: opening the control master to $HOST (no forward yet — probing what the box already has)"
if ! open_master; then
  fail failed-tunnel 71 "could not open an ssh control master to $HOST at all (see $LOCAL_STATE/tunnel.err).
    This is not a port conflict — no forward was requested. The box is unreachable, the key is
    rejected, or sshd is down. Check: $SSH_BIN -o BatchMode=yes $HOST true"
fi
TUNNEL_UP=1

BOX_CODE=$(box_health)
if [ "$BOX_CODE" = 200 ]; then
  TUNNEL_MODE=adopted
  say "tunnel: TUNNEL_MODE=adopted — $HOST already answers 200 on 127.0.0.1:$PORT (its standing forward). Using it; teardown will NOT touch it."
else
  warn "tunnel: $HOST has no healthy path to the fleet proxy (probe='$BOX_CODE'$([ "$BOX_CODE" != 000 ] && printf ' — BLOCKED, something is listening and refusing')) — opening the reverse forward from here"
  close_master; TUNNEL_UP=0
  if open_reverse; then
    TUNNEL_MODE=owned
    say "tunnel: TUNNEL_MODE=owned (this run opened -R $PORT:127.0.0.1:$PORT; it dies with this dispatch)"
  else
    warn "tunnel: the -R bind was refused — port $PORT is bound on $HOST but does NOT answer. Asking the box to drop only ITS OWN forward, then retrying once."
    # The master went away with the failed -R, so re-open it to ask.
    close_master
    if ! open_master; then
      fail failed-tunnel 71 "the -R bind was refused AND the plain control master then failed too (see $LOCAL_STATE/tunnel.err).
    The box became unreachable between the probe and the retry. Nothing was dispatched."
    fi
    TUNNEL_UP=1
    # pidfile-scoped, with a pgrep fallback that only ever matches `ssh -L ... zig-computer`
    # started BY THAT SCRIPT. A reverse forward from here appears on the box as an
    # sshd process and cannot match it, so this can never drop another dispatch's tunnel.
    RECLAIM=$(rsh "$REMOTE_ENSURE_TUNNEL down --port $PORT" 2>&1); RECLAIM_RC=$?
    printf '%s\n' "$RECLAIM" | sed 's/^/    /'
    note "reclaim rc=$RECLAIM_RC"
    close_master; TUNNEL_UP=0
    sleep 1
    if open_reverse; then
      TUNNEL_MODE=owned
      say "tunnel: RECLAIMED — the dead binder was dropped and TUNNEL_MODE=owned"
    else
      fail failed-tunnel 71 "no usable path to the fleet proxy on $HOST, and both recoveries failed.
    The box's own forward answered '$BOX_CODE' (not 200), asking it to drop that forward returned
    rc=$RECLAIM_RC, and the reverse forward still cannot bind 127.0.0.1:$PORT there.
    See $LOCAL_STATE/tunnel.err. Diagnose on the box (never pkill on the port — it is shared):
      ssh $HOST 'ss -tlnp | grep $PORT; ~/dotfiles/agents/scheduler/ensure-fleet-tunnel.sh status'
    A stale master of YOUR OWN would also do this: ls $STATE_ROOT/*/ssh-ctl.sock, then $SSH_BIN -S <sock> -O exit $HOST
    Dispatching now would produce a tick that silently sees no Asana and no Slack."
    fi
  fi
fi
printf '%s\n' "$TUNNEL_MODE" > "$LOCAL_STATE/tunnel-mode"
note "TUNNEL_MODE=$TUNNEL_MODE"
say "tunnel: up (TUNNEL_MODE=$TUNNEL_MODE)"

# ---------------------------------------------------------------------------
# Step 2a — T2/T3 PUSH FROM HERE, first.
#
# Ordering is load-bearing: `vault-sync` is pull-then-push on each machine
# INDEPENDENTLY, so the box can only pull what zig-computer has already pushed.
# Syncing only the box is not sufficient to make the box current.
#
# MEASURED END TO END, 2026-07-27 — this is not a theoretical concern:
#   1. a new memory file was written locally at ~18:40; the local hourly sync had
#      last run at 18:00, so the write was unpublished.
#   2. vault-sync ON THE BOX reported `transcripts=ok memory=ok`, "pulled latest",
#      and exited 0 — while the box's MEMORY.md md5 was still the OLD value
#      (007d1cfc… vs local a844195c…). It pulled the latest PUBLISHED, which did
#      not include the write.
#   3. vault-sync HERE pushed it (a new memory commit appeared in the vault).
#   4. vault-sync on the box again -> md5 matched exactly.
#
# Two rules fall out, and both are implemented below:
#   - local push FIRST, then remote pull, then assert.
#   - assert on CONTENT, never on exit status. Step 2 above exited 0 while stale.
#     "A green sync on the box is not evidence the box is current" is the same
#     class as everything else in §10: a green status that means nothing.
#
# This is the vault-shaped twin of vps-preflight's staleness axis 3 (GitHub behind
# zig-computer) — the axis a pull mechanism structurally cannot fix. For git,
# vps-preflight already enforces the same rule one step later, and enforces it by
# BLOCKING (exit 72) rather than auto-pushing: a dispatcher that silently pushed
# Zig's uncommitted-intent local commits would be making a call that is his.
#
# Exit codes are decoded, not just tested: vault-sync's units digit names the
# tier (x0 transcripts, x1 memory, x2 both; 1x degraded, 2x stale). A tick reads
# MEMORY and never reads transcripts, so a transcripts-only failure is a loud
# WARN and a memory failure is a block. That is not leniency — the sparse scope
# for this slug is a known out-of-band fix, and blocking every dispatch on a tier
# no tick reads would train exactly the "discount the alarm" habit the alarm
# exists to avoid.
# ---------------------------------------------------------------------------
decode_vault_rc() {   # $1 = rc -> English
  case "$1" in
    0)  printf 'healthy' ;;
    10) printf 'DEGRADED: transcripts tier failed this run (memory fine)' ;;
    11) printf 'DEGRADED: memory tier failed this run (transcripts fine)' ;;
    12) printf 'DEGRADED: BOTH tiers failed this run' ;;
    20) printf 'STALE: transcripts tier has not succeeded in hours (memory fine)' ;;
    21) printf 'STALE: memory tier has not succeeded in hours (transcripts fine)' ;;
    22) printf 'STALE: BOTH tiers have not succeeded in hours' ;;
    *)  printf 'unknown vault-sync exit %s' "$1" ;;
  esac
}
# Did the MEMORY tier fail? (units digit 1 or 2 => memory implicated)
vault_memory_failed() { case "$1" in 0) return 1 ;; *1|*2) return 0 ;; *) return 1 ;; esac; }

if [ "$SKIP_SYNC" = 1 ]; then
  warn "--skip-sync: NOT refreshing the memory/transcript/bead tiers (assertions A5/A6 still run). Never do this in a timer."
else
  if [ -x "$LOCAL_VAULT_SYNC" ]; then
    say "sync T2/T3 (local push): $LOCAL_VAULT_SYNC"
    "$LOCAL_VAULT_SYNC" > "$LOCAL_STATE/vault-local.log" 2>&1
    LV_RC=$?
    say "  local vault-sync rc=$LV_RC — $(decode_vault_rc "$LV_RC")  (log: $LOCAL_STATE/vault-local.log)"
    if vault_memory_failed "$LV_RC"; then
      fail failed-vault 79 "the LOCAL memory vault did not sync (rc=$LV_RC — $(decode_vault_rc "$LV_RC")).
    The box pulls memory from GitHub, so unpushed local memory can never reach it and the
    tick would calibrate against an older feedback corpus. Log: $LOCAL_STATE/vault-local.log"
    elif [ "$LV_RC" -ne 0 ]; then
      warn "local vault-sync: $(decode_vault_rc "$LV_RC") — transcripts only, which no tick reads. Continuing; fix out of band."
    fi
  else
    warn "local vault-sync not found at $LOCAL_VAULT_SYNC — T2/T3 not pushed from here; A5 below is the backstop"
  fi
fi

# ---------------------------------------------------------------------------
# Step 2a — T0 PUSH the out-of-band tier (gitignored / local-only).
#
# `require-oob` in the manifest marks a path git can NEVER deliver: the IMC
# campaign folders are gitignored in the umbrella, so no amount of pulling puts
# them on the box, and refs/beats.md points every beat at ~/linearb/imc-<month>.
# A tick without that corpus drafts confidently WITHOUT campaign context —
# wrong output, not missing output, which is the failure a weekly harvest cannot
# catch.
#
# So the manifest is the single control surface: declare a path `require-oob`
# once and it travels on every dispatch. Nobody has to remember an rsync.
# Credentials are excluded by pattern — the box holds NO secrets by design
# (explore-7iz9 brokers them over the tunnel instead), and a sweep of the box
# on 2026-07-27 confirmed 0 .env* and 0 service-account files.
# ---------------------------------------------------------------------------
if [ "$SKIP_SYNC" != 1 ] && [ -r "$MANIFEST" ]; then
  _oob=()
  # PRE-SCAN for `oob-exclude`, because the complement rule below needs the
  # exclusions BEFORE it enumerates, and a manifest must never depend on the
  # ORDER its directives happen to appear in.
  #
  # Why an explicit directive rather than inferring it (bead dotfiles-f5tg, 2026-07-28).
  # The tempting rule is "skip any child that is its own git repo — a different
  # git owns it." That is WRONG here and would have broken the August IMC
  # silently: `imc-aug26` has its own `.git` AND is untracked by the umbrella,
  # but its remote is `lb-marketing/*`, which this box's PAT 404s on — so git
  # cannot deliver it and rsync is the ONLY transport that can. Inferring would
  # have dropped it from the tier and produced exactly the failure the comment
  # below warns about: a tick drafting confidently without campaign context.
  # "Has a .git" does not imply "reachable by this box's credentials."
  _oob_excl=()
  while read -r _d _p _rest; do
    [ "$_d" = "oob-exclude" ] && _oob_excl+=("${_p#\$HOME/}")
  done < "$MANIFEST"
  while read -r _d _p _rest; do
    case "$_d" in
      require-oob) _oob+=("${_p#\$HOME/}") ;;
      require-oob-untracked)
        # THE COMPLEMENT RULE (Zig, 2026-07-27: "why not sync the whole
        # ~/linearb"). Answer: git already owns 14 of its 18 top-level entries,
        # and rsyncing OVER a tracked checkout dirties it relative to HEAD —
        # which trips the manifest's own `readonly` assertion and breaks the
        # freshness guarantee. Git and rsync would fight over the same files.
        # So push exactly the COMPLEMENT: every top-level child git does not
        # own. Anything new and untracked travels with no manifest edit, and
        # nothing git manages is touched.
        _base=${_p#\$HOME/}
        [ -d "$HOME/$_base" ] || fail failed-preflight 73 \
          "manifest declares require-oob-untracked '\$HOME/$_base' but that directory does not exist on zig-computer"
        while IFS= read -r _child; do
          [ -n "$_child" ] || continue
          _oob+=("$_base/$_child")
        done < <(cd "$HOME/$_base" && for _c in */; do
                   _c=${_c%/}
                   git ls-files --error-unmatch "$_c" >/dev/null 2>&1 && continue
                   grep -q "path = $_c" .gitmodules 2>/dev/null && continue
                   # Declared-out via `oob-exclude`: a path that reaches the box
                   # by its OWN transport and must not also be rsync'd, because
                   # two writers over one directory fight (git vs rsync).
                   #
                   # GLOB, not just literal (2026-07-30). The whole class here is
                   # "a DIFFERENT git owns this", and that class arrives one new
                   # directory at a time — every `/bootstrap-imc` run makes another
                   # `imc-<month>` repo with its own remote. A literal-only
                   # exclusion means each new campaign folder silently re-enters the
                   # rsync tier until someone remembers to add a line, and the
                   # failure is destructive: `--delete` against a stale source
                   # removes work the box has committed but zig has not pulled.
                   _skip=0
                   for _x in "${_oob_excl[@]}"; do
                     case "$_base/$_c" in $_x) _skip=1; break ;; esac
                   done
                   [ "$_skip" = 1 ] && continue
                   printf '%s\n' "$_c"
                 done)
        ;;
    esac
  done < "$MANIFEST"
  if [ "${#_oob[@]}" -gt 0 ]; then
    if ! command -v "$RSYNC_BIN" >/dev/null 2>&1; then
      fail failed-preflight 73 "rsync not found, but the manifest declares ${#_oob[@]} require-oob path(s) that git cannot deliver"
    fi
    for _pat in "${_oob[@]}"; do
      # GLOB-expanded, so `imc-*` covers next month's campaign folder with no
      # manifest edit. A pattern matching nothing is a failure, exactly like a
      # missing literal — "declared but absent" must never be silent.
      shopt -s nullglob
      # shellcheck disable=SC2206  # deliberate word-split: this is the glob expansion
      _matches=( $HOME/$_pat )
      shopt -u nullglob
      [ "${#_matches[@]}" -gt 0 ] || fail failed-preflight 73 \
        "manifest declares require-oob '\$HOME/$_pat' but nothing matches it on zig-computer either — fix the manifest or restore the path"
      for _abs in "${_matches[@]}"; do
      # nullglob only suppresses patterns that CONTAIN a metacharacter; a literal
      # path with no `*` survives expansion even when it does not exist. So the
      # per-match existence check is what actually catches a declared-but-absent
      # literal — the array being non-empty proves nothing.
      [ -e "$_abs" ] || fail failed-preflight 73 \
        "manifest declares require-oob '\$HOME/$_pat' but '$_abs' does not exist on zig-computer either — fix the manifest or restore the path"
      _rel=${_abs#"$HOME"/}
      # POSITIVE GATE, not just a pattern denylist. The --exclude list below is a
      # list of things someone thought of; `.envrc` alone is not matched by
      # `.env.*`, and *.pem / *.key / credentials.json / id_rsa were all absent
      # from it. Under the complement rule ANY new untracked folder ships
      # automatically, so a hand-written denylist is the wrong guarantee. Scan
      # what is about to leave the machine and REFUSE on a hit — the box is a
      # SHARED team disk and holds no secrets by design (explore-7iz9).
      if [ -x "$SCRUB" ] || [ -f "$SCRUB" ]; then
        # Honor an executable scanner directly; the shipped scrub.py is mode 644
        # with a python3 shebang, so it needs the interpreter.
        if [ -x "$SCRUB" ]; then _scan=( "$SCRUB" ); else _scan=( python3 "$SCRUB" ); fi
        if ! "${_scan[@]}" scan --quiet "$_abs" >>"$LOCAL_STATE/scrub.log" 2>&1; then
          fail failed-preflight 73 "REFUSING to push '$_rel' to $HOST — the secret scanner found a high-confidence secret in it.
    See $LOCAL_STATE/scrub.log. Move the credential to ~/.secrets (or an .env the
    exclusions cover) and re-run. The box is a shared disk and must hold no secrets."
        fi
      else
        warn "scrub-secrets not found at $SCRUB — pushing '$_rel' on the exclusion patterns alone"
      fi
      say "sync T0: pushing out-of-band $_rel -> $HOST"
      "$RSYNC_BIN" -az --delete \
        --exclude='.git/' --exclude='node_modules/' --exclude='.next/' \
        --exclude='target/' --exclude='.venv/' --exclude='dist/' \
        --exclude='.ruff_cache/' --exclude='__pycache__/' \
        --exclude='.claude/worktrees/' \
        --exclude='.env' --exclude='.env.*' --exclude='.envrc' --exclude='*.env.local' \
        --exclude='*.pem' --exclude='*.key' --exclude='id_rsa*' \
        --exclude='credentials.json' --exclude='token.json' \
        --exclude='.google-service-account.json' --exclude='*service-account*.json' \
        "$_abs/" "$HOST:$_rel/" 2>>"$LOCAL_STATE/rsync.err" \
        || fail failed-preflight 73 "rsync of out-of-band path '$_rel' to $HOST failed (see $LOCAL_STATE/rsync.err)"
      done
    done
  fi
fi

# Step 2b — T1 REFRESH + A1/A2 GATE, via vps-preflight.sh.
#
# Not reimplemented here. vps-preflight already drives vps-repo-refresh on the
# box and judges the receipt LOCALLY, covering all three staleness axes —
# including the one a pull mechanism structurally cannot fix (GitHub behind
# zig-computer). It also harvests back any tracked file a previous remote tick
# wrote. Adding a second implementation of that would be a second thing to drift.
#
# Refresh and gate are FUSED inside that one call by its own design, which is a
# stronger guarantee than doing them as two steps here: there is no window in
# which a receipt from some earlier refresh could be mistaken for this one.
#
# This must run before T4: the bead JSONL the box imports arrives with this pull.
# ---------------------------------------------------------------------------
[ -x "$PREFLIGHT" ] || fail failed-preflight 73 "vps-preflight.sh not executable at $PREFLIGHT"
CHECKOUT_REPORT="$LOCAL_STATE/checkout-state.json"
PF_ARGS=(--host "$HOST" --harvest-dir "$LOCAL_STATE/harvest" --report "$CHECKOUT_REPORT")
[ "$ALLOW_UNPUSHED" = 1 ] && PF_ARGS+=(--allow-unpushed)
[ "$NO_REFRESH" = 1 ]     && PF_ARGS+=(--no-refresh)

say "sync T1 + preflight A1+A2: refreshing $HOST and judging the receipt locally"
if ! "$PREFLIGHT" "${PF_ARGS[@]}"; then
  fail failed-preflight 73 "vps-preflight blocked (assertions A1 empty-submodule / A2 stale-HEAD).
    Its stderr above names the exact repo and remedy. Nothing was dispatched, so no
    remote tokens were spent and no misleading ledger row exists.
    NOTE: a merely DIRTY checkout no longer blocks (dotfiles-f4ub) — if this says
    'in_sync=false' or 'NOT the same code', that is COMMITTED code drift, not WIP.
    NOTE: a checkout merely BEHIND the published tip no longer blocks either
    (dotfiles-w16i) — the preflight fast-forwards it. So a local-side block here
    means AHEAD (push it), DIVERGED, or a fast-forward that could not be applied."
fi

# ---------------------------------------------------------------------------
# Step 2b' — CARRY THE CHECKOUT STATE FORWARD. This is the load-bearing half of
# dotfiles-f4ub: a dirty or non-advancing checkout no longer blocks, so the only
# thing standing between "the tick ran in a messy tree" and a silently-wrong
# artifact is that the messiness is SAID OUT LOUD — to the tick (DISPATCH.md
# below), and to the ledger row (step 9), which is where a later reader learns
# what tree an artifact was built from.
#
# Zig's standing principle is the whole reason this block exists: missing output
# he catches on his weekly harvest; WRONG output he cannot.
# ---------------------------------------------------------------------------
CHECKOUT_JSON='{"clean":true,"local_dirty":[],"remote_dirty":[],"stalled":[],"auto_ff":[]}'
CHECKOUT_CLEAN=true
if [ -s "$CHECKOUT_REPORT" ] && jq -e . "$CHECKOUT_REPORT" >/dev/null 2>&1; then
  CHECKOUT_JSON=$(jq -c . "$CHECKOUT_REPORT")
  # `if has("clean")`, NOT `.clean // true`. jq's `//` treats `false` as empty, so
  # `.clean // true` reads a dirty report as CLEAN — the exact silent-wrong-answer
  # this block exists to prevent. Never `//` a boolean.
  CHECKOUT_CLEAN=$(jq -r 'if has("clean") then .clean else true end' <<<"$CHECKOUT_JSON")
else
  warn "no checkout-state report at $CHECKOUT_REPORT (older vps-preflight?) — the tick will be told the state is UNKNOWN rather than clean"
  CHECKOUT_JSON='{"clean":null,"local_dirty":[],"remote_dirty":[],"stalled":[],"auto_ff":[]}'
  CHECKOUT_CLEAN=unknown
fi
if [ "$CHECKOUT_CLEAN" != true ]; then
  say "checkout state: NOT CLEAN (clean=$CHECKOUT_CLEAN) — carried into DISPATCH.md and the ledger row"
  jq -r '(.local_dirty[]? | "  local  · " + .), (.remote_dirty[]? | "  remote · " + .repo + ": " + (.paths|join(", "))), (.stalled[]? | "  stalled· " + .)' \
     <<<"$CHECKOUT_JSON" | while IFS= read -r l; do say "$l"; done
fi
# Said on EVERY run, clean or not (dotfiles-w16i): an auto-fast-forward leaves the
# tree clean, so it would otherwise vanish inside the clean branch — and a silent
# catch-up hides the fact that this machine and the box had drifted apart.
if [ "$(jq -r '(.auto_ff // []) | length' <<<"$CHECKOUT_JSON")" -gt 0 ]; then
  say "checkout: fast-forwarded before dispatch (zig-computer was behind the published tip)"
  jq -r '.auto_ff[]? | "  ff     · " + .repo + ": " + .from + " -> " + .to + " (" + (.commits|tostring) + " commit(s))"' \
     <<<"$CHECKOUT_JSON" | while IFS= read -r l; do say "$l"; done
fi

# The prose the tick actually reads. Built here rather than inside the heredoc so
# the heredoc stays a template — an unquoted heredoc executes anything it is
# handed, and jq output is the last thing that should be evaluated there.
if [ "$CHECKOUT_CLEAN" = true ]; then
  CHECKOUT_NOTE="Every managed checkout on this box is CLEAN and at its published tip. Anything dirty when you finish is therefore YOURS."
else
  # NOTE ON THE BACKTICKS BELOW: they are safe. This string is interpolated into
  # an UNQUOTED heredoc, and shell expansion is not recursive — the result of a
  # parameter expansion is never re-scanned for command substitution. Backticks
  # written LITERALLY in the heredoc body are the hazard, and those are escaped
  # there. Verified by rendering the heredoc in isolation.
  CHECKOUT_NOTE=$(jq -r '
    ["**You are working in a tree that is NOT clean.** That is normal now and it does not stop you. What it means for you:"]
    + (if (.remote_dirty | length) > 0
       then ["", "- DIRTY ON THIS BOX. Somebody else is mid-edit here. Do NOT commit, revert, stash, clean or `git add` any of these:"]
            + [.remote_dirty[] | "  - `" + .repo + "`: " + (.paths | map("`" + . + "`") | join(", "))]
       else [] end)
    + (if (.stalled | length) > 0
       then ["", "- **STALE CODE WARNING.** These checkouts REFUSED to fast-forward this run, so you may be running older logic than zig-computer:"]
            + [.stalled[] | "  - `" + . + "`"]
            + ["  SAY SO in your `note`. An artifact built on stale logic looks exactly like a good one, which is the failure nobody catches downstream."]
       else [] end)
    + (if (.local_dirty | length) > 0
       then ["", "- Uncommitted on ZIG-COMPUTER, so it never reached you (informational — you cannot see these edits):"]
            + [.local_dirty[] | "  - " + .]
       else [] end)
    | join("\n")' <<<"$CHECKOUT_JSON")
fi

# The auto-fast-forward note appends to BOTH branches above, because it is
# orthogonal to dirt: the tree it produces is clean, and the thing worth telling
# the tick is that this machine had fallen behind the box and was caught up. On a
# peer fleet that is routine, but "routine" is exactly what stops getting said.
AUTOFF_NOTE=$(jq -r 'if ((.auto_ff // []) | length) > 0 then
    (["", "- CAUGHT UP BEFORE DISPATCH. zig-computer was BEHIND the published tip and was fast-forwarded (a fast-forward cannot lose work, so nothing was discarded):"]
     + [.auto_ff[] | "  - `" + .repo + "`: " + .from + " -> " + .to + " (" + (.commits|tostring) + " commit(s))"]) | join("\n")
  else "" end' <<<"$CHECKOUT_JSON")
[ -z "$AUTOFF_NOTE" ] || CHECKOUT_NOTE="$CHECKOUT_NOTE
$AUTOFF_NOTE"

# ---------------------------------------------------------------------------
# Step 2c — T2/T3 PULL ON THE BOX. Runs after 2b so the box is executing the
# CURRENT vault-sync.sh, not a copy from whenever it last pulled dotfiles.
# ---------------------------------------------------------------------------
if [ "$SKIP_SYNC" != 1 ]; then
  say "sync T2/T3 (remote pull): $REMOTE_VAULT_SYNC on $HOST"
  rsh "$REMOTE_VAULT_SYNC" > "$LOCAL_STATE/vault-remote.log" 2>&1
  RV_RC=$?
  say "  remote vault-sync rc=$RV_RC — $(decode_vault_rc "$RV_RC")  (log: $LOCAL_STATE/vault-remote.log)"
  if vault_memory_failed "$RV_RC"; then
    fail failed-vault 79 "the REMOTE memory vault did not sync on $HOST (rc=$RV_RC — $(decode_vault_rc "$RV_RC")).
    Log: $LOCAL_STATE/vault-remote.log
    A tick on a box whose memory tier is behind calibrates against a stale feedback corpus
    and produces plausible, wrong output with no signal attached. Not dispatching."
  elif [ "$RV_RC" -ne 0 ]; then
    warn "remote vault-sync: $(decode_vault_rc "$RV_RC") — transcripts only, which no tick reads. Continuing; fix out of band."
  fi
fi

# ---------------------------------------------------------------------------
# Step 3 — A5: the memory tier is IDENTICAL, not merely "recently synced".
#
# Digest over the whole project memory dir, path-relative on both sides so the
# differing $HOME cannot make two identical corpora look different. `find -L`
# follows the peer symlinks vps-phase2-symlinks.sh installs. Identity, not an age
# budget — the same choice vps-preflight made for repos, for the same reason.
# ---------------------------------------------------------------------------
SLUG=$(printf '%s' "$DIR" | tr '/' '-')
LOCAL_MEM="$HOME/.claude/projects/$SLUG/memory"
REMOTE_MEM="/home/andrew/.claude/projects/$SLUG/memory"
# Sorted relative paths + content, rolled into one hash. LC_ALL=C so the sort
# order is byte order on both boxes rather than locale order.
MEM_DIGEST_CMD='cd "%s" 2>/dev/null && find -L . -type f | LC_ALL=C sort | xargs -r sha256sum | sha256sum | cut -d" " -f1'

if [ -d "$LOCAL_MEM" ]; then
  # shellcheck disable=SC2059  # MEM_DIGEST_CMD is a format string by construction
  LOCAL_MEM_SHA=$(bash -c "$(printf "$MEM_DIGEST_CMD" "$LOCAL_MEM")")
  REMOTE_MEM_SHA=$(rsh "$(printf "$MEM_DIGEST_CMD" "$REMOTE_MEM")" 2>>"$LOCAL_STATE/remote.err")
  REMOTE_MEM_SHA=${REMOTE_MEM_SHA//$'\r'/}
  if [ -z "$REMOTE_MEM_SHA" ]; then
    fail failed-vault 79 "A5 FAILED: $HOST has no readable memory dir at $REMOTE_MEM.
    The tick would run with NO project memory — no voice-feedback corpus, no lessons — and
    would draft confidently without them. Remedy: check the vault sparse scope covers slug
    '$SLUG' and that vps-phase2-symlinks.sh has run on the box."
  fi
  if [ "$LOCAL_MEM_SHA" != "$REMOTE_MEM_SHA" ]; then
    fail failed-vault 79 "A5 FAILED: the memory tier is NOT identical after syncing both ends.
    zig-computer ${LOCAL_MEM_SHA:0:12}  !=  $HOST ${REMOTE_MEM_SHA:0:12}
    The DI voice skills calibrate against this corpus, so a behind-box produces a complete,
    plausible artifact built from superseded feedback — the failure Zig cannot catch on a
    weekly harvest because there is nothing missing to notice.
    Remedy: confirm the local push landed (git --git-dir=~/.claude/vaults/memory.git log -1),
    then re-run. Logs: $LOCAL_STATE/vault-local.log · $LOCAL_STATE/vault-remote.log"
  fi
  say "preflight A5: OK (memory tier identical, ${LOCAL_MEM_SHA:0:12})"
else
  warn "A5 skipped: no local memory dir at $LOCAL_MEM (nothing to compare)"
fi

# T3 assert — vault HEAD identity, the ref-level check the content digest gives
# us for free on the memory side. WARN-level by design: as of 2026-07-27 the box's
# transcripts sparse scope was widened to cover this slug (plus agent-factory and
# weekly-reporting) and 47 files / 237 MB materialized, so the tier is genuinely
# covered — but no tick READS transcripts, so a lag here cannot produce a wrong
# artifact. It is recorded, not blocking. (Memory is the tier that can, and A5
# blocks on it.)
for V in memory transcripts; do
  L=$(git --git-dir="$HOME/.claude/vaults/$V.git" rev-parse HEAD 2>>"$LOCAL_STATE/vault-head.err")
  R=$(rsh "git --git-dir=\$HOME/.claude/vaults/$V.git rev-parse HEAD" 2>>"$LOCAL_STATE/vault-head.err")
  R=${R//$'\r'/}
  if [ -z "$L" ] || [ -z "$R" ]; then
    warn "vault $V: could not read HEAD on one side (local='${L:0:8}' remote='${R:0:8}'; see $LOCAL_STATE/vault-head.err)"
  elif [ "$L" != "$R" ]; then
    warn "vault $V: HEAD differs — zig ${L:0:8} != $HOST ${R:0:8}$([ "$V" = memory ] && printf ' (A5 above is the blocking check for this tier)')"
  else
    say "  vault $V: HEAD identical (${L:0:8})"
  fi
done

# ---------------------------------------------------------------------------
# Step 3b — T4 REFRESH + A6 GATE: the bead index is current with the JSONL.
#
# `br` reads .beads/beads.db, not the JSONL — so a box that pulled a new JSONL in
# step 2b but never imported it reads bead state that is silently stale (or, on
# this box, absent entirely: it has no beads.db for this project at all).
#
# --import-only is the READ half and only the read half. It writes .beads/beads.db,
# which is gitignored, so no tracked file is dirtied and the read-only tripwire in
# vps-repo-refresh.sh stays clean. The standing rule is untouched: the box never
# creates, updates, or closes a bead, and never writes the JSONL.
#
# The gate is jsonl_content_hash identity plus jsonl_newer == false. The hash is a
# property of the FILE, so comparing it across machines proves both that the pull
# landed and that the import consumed exactly what we have.
# ---------------------------------------------------------------------------
if [ -f "$DIR/.beads/issues.jsonl" ]; then
  if [ "$SKIP_SYNC" != 1 ]; then
    say "sync T4 (remote bead index): br sync --import-only in $REMOTE_DIR"
    rsh "cd '$REMOTE_DIR' && br sync --import-only" > "$LOCAL_STATE/beads-import.log" 2>&1 \
      || warn "remote 'br sync --import-only' exited non-zero (log: $LOCAL_STATE/beads-import.log) — A6 below is the verdict, not this"
  fi

  LOCAL_BEAD_JSON=$( cd "$DIR" && br sync --status --json 2>>"$LOCAL_STATE/beads-local.err" )
  REMOTE_BEAD_JSON=$( rsh "cd '$REMOTE_DIR' && br sync --status --json" 2>>"$LOCAL_STATE/remote.err" )

  LOCAL_BEAD_SHA=$(jq -r '.jsonl_content_hash // empty' <<<"${LOCAL_BEAD_JSON:-{\}}"  2>/dev/null)
  REMOTE_BEAD_SHA=$(jq -r '.jsonl_content_hash // empty' <<<"${REMOTE_BEAD_JSON:-{\}}" 2>/dev/null)
  REMOTE_NEWER=$(jq -r '.jsonl_newer // empty'          <<<"${REMOTE_BEAD_JSON:-{\}}" 2>/dev/null)

  if [ -z "$REMOTE_BEAD_SHA" ]; then
    fail failed-beads 80 "A6 FAILED: could not read the bead sync status on $HOST.
    raw: $(printf '%.300s' "${REMOTE_BEAD_JSON:-<empty>}")
    'br' may be missing from the pane-independent login PATH, or $REMOTE_DIR/.beads is absent.
    Import log: $LOCAL_STATE/beads-import.log"
  fi
  if [ -n "$LOCAL_BEAD_SHA" ] && [ "$LOCAL_BEAD_SHA" != "$REMOTE_BEAD_SHA" ]; then
    fail failed-beads 80 "A6 FAILED: the bead JSONL is not the same file on both machines.
    zig-computer ${LOCAL_BEAD_SHA:0:12}  !=  $HOST ${REMOTE_BEAD_SHA:0:12}
    The T1 pull should have delivered it, so this means local bead state is committed-but-unpushed,
    or the box's submodule is not at the published tip. The tick would read stale bead context.
    Remedy: br sync --flush-only && git -C $DIR add .beads/issues.jsonl && commit && push, then re-run."
  fi
  if [ "$REMOTE_NEWER" = "true" ]; then
    fail failed-beads 80 "A6 FAILED: $HOST reports jsonl_newer=true — its bead DB has NOT consumed the JSONL it holds.
    'br' reads the DB, so the tick would see stale or missing bead state while the file on disk is current.
    Import log: $LOCAL_STATE/beads-import.log"
  fi
  say "preflight A6: OK (bead JSONL identical ${REMOTE_BEAD_SHA:0:12}, index imported)"
else
  warn "A6 skipped: no .beads/issues.jsonl in $DIR"
fi

# ---------------------------------------------------------------------------
# Step 3 — A3: the tunnel answers /api/health FROM THE VPS SIDE.
#
# This MUST be tested through the tunnel, from the far end. Curling
# 127.0.0.1:7100 on zig-computer proves the proxy is up, which it essentially
# always is — it proves nothing about the forward, and the forward is the thing
# that breaks. A tick whose tunnel is down does not error: every Asana call 000s
# and it files "blocked, no data", which is a legitimate-looking row.
# ---------------------------------------------------------------------------
say "preflight A3: probing http://127.0.0.1:$PORT/api/health from $HOST"
HEALTH=$(rsh "curl -sS -m 15 -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/api/health" 2>&1)
HEALTH_RC=$?

# SELF-HEAL before failing (added 2026-07-28, Zig).
#
# The reverse forward above can only be opened FROM HERE, so when it dies the
# box is stranded: every Asana/Slack/gdoc call 000s and a tick has no way to
# recover. Now that marketing-vps holds an ssh key back to zig-computer
# (~/.ssh/id_zig_computer + the `zig-computer` Host block in ~/.ssh/local), the
# box can open the SAME path itself as a LOCAL forward. Ask it to, then re-probe.
#
# Only 000 (nothing listening) is worth healing. A non-200 HTTP answer means
# something IS listening and is refusing — reopening the socket cannot fix that,
# and churning it would just hide the real fault.
if [ "$HEALTH_RC" -eq 0 ] && [ "$HEALTH" != "200" ] && [ "$HEALTH" != "000" ]; then
  fail failed-tunnel 71 "A3 FAILED: $HOST reached the proxy and got HTTP $HEALTH, not 200.
    Something IS listening on 127.0.0.1:$PORT over there and is refusing. This is a
    BLOCKED answer, not an absent one — do not read it as 'no data', and do not
    reopen the tunnel hoping it clears. Check the fleet proxy here:
      systemctl --user status lb-fleet && curl -i http://127.0.0.1:$PORT/api/health"
fi

if [ "$HEALTH_RC" -ne 0 ] || [ "$HEALTH" != "200" ]; then
  warn "A3: no answer through the tunnel (rc=$HEALTH_RC body='$HEALTH') — asking $HOST to reopen it itself"
  HEAL=$(rsh "$REMOTE_ENSURE_TUNNEL ensure --port $PORT" 2>&1)
  HEAL_RC=$?
  printf '%s\n' "$HEAL" | sed 's/^/    /'
  if [ "$HEAL_RC" -ne 0 ]; then
    fail failed-tunnel 71 "A3 FAILED: the fleet proxy is not reachable THROUGH THE TUNNEL from $HOST,
    and the box could not reopen it either (self-heal rc=$HEAL_RC).
    got: rc=$HEALTH_RC body='$HEALTH' (want rc=0 and http_code 200)
    Check: (a) the local proxy — curl -fsS http://127.0.0.1:$PORT/api/health on zig-computer;
           (b) the box's key back here — ssh $HOST 'ssh -o BatchMode=yes zig-computer true';
           (c) AllowTcpForwarding on both sshd configs;
           (d) a stale listener holding $PORT on the box.
    Dispatching now would produce a tick that silently sees no Asana and no Slack."
  fi
  HEALTH=$(rsh "curl -sS -m 15 -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/api/health" 2>&1)
  [ "$HEALTH" = "200" ] || fail failed-tunnel 71 "A3 FAILED: self-heal reported success but the probe still returns '$HEALTH'.
    Never trust the heal over the probe — this is exactly the 'I did a thing' vs 'it works' gap."
  # The healed forward is left UP on purpose — see cleanup()'s "deliberately
  # absent" note. The box is meant to hold a standing forward, so this heal is the
  # posture arriving late, not a leak to tidy away.
  say "preflight A3: HEALED — the box reopened the tunnel itself and it now answers 200 (TUNNEL_MODE=$TUNNEL_MODE; the healed forward stays up, by design)"
else
  say "preflight A3: OK (200 through the tunnel, TUNNEL_MODE=$TUNNEL_MODE)"
fi

# ---------------------------------------------------------------------------
# Step 4 — A4: `claude` is on the TARGET PANE's PATH.
#
# Two pane shapes, and the honest test differs:
#   - the pane already runs `claude`  -> resolution is PROVEN by the running
#     process. No probe needed, and a probe would be typed into a live TUI.
#   - the pane is at a shell          -> probe it IN THE PANE. Not over `ssh
#     bash -lc`: that is a different shell with a different PATH, and passing
#     there while the pane fails is precisely the login/non-login footgun.
# ---------------------------------------------------------------------------
rsh "tmux has-session -t '=$REMOTE_SESSION' || tmux new-session -d -s '$REMOTE_SESSION' -n '$REMOTE_WINDOW' -c '$REMOTE_DIR'" \
  >/dev/null 2>>"$LOCAL_STATE/remote.err" \
  || fail failed-no-claude 74 "could not create/find tmux session '$REMOTE_SESSION' on $HOST (see $LOCAL_STATE/remote.err)"

# The row's WINDOW inside that session. Exact-match on the name, and create it if
# absent — same contract as pulse-inject.sh locally. Matching on #{window_name}
# rather than an index keeps this base-index independent (marketing-vps sets
# base-index 1), which is the same trap that broke pane resolution earlier today.
#
# ⚠️ LEXICON-AWARE, and it must be (fixed 2026-07-28). The tmux-status hook
# PREFIXES the window name with 🧠/✅/🔔/🌀, so a window this script created as
# "weekly-report" is called "✅ weekly-report" by the time the next dispatch
# looks for it. The old matcher split on whitespace and compared $2, which is
# the GLYPH, never the row name — so the lookup failed for every window that had
# ever run a tick, and each dispatch silently created ANOTHER window. Two
# `weekly-report` windows were live on marketing-vps when Zig caught it; left
# alone it grows one window per dispatch, forever. pulse-inject.sh had solved
# this locally (its `strip_lexicon`) and the comment above claimed parity that
# the code did not have.
#
# Parsing note: do NOT put \t in the tmux -F format here. tmux does not expand
# escapes in -F, so over ssh it emits a LITERAL backslash-t and every field
# split silently returns the whole line. (pulse-inject.sh gets away with
# $'...\t...' because bash expands it to a real tab before tmux ever sees it;
# that trick does not survive the ssh quoting round-trip.) So: split on the
# FIRST space — window_id never contains one — and treat the remainder as the
# name. Then strip the leading decoration. The strip is a generic
# "non-alphanumeric run at the front" rather than a fixed glyph list, so a new
# glyph in the lexicon cannot silently reintroduce the leak. Row names are
# alphanumeric/dash, so this cannot eat a real name.
WIN_ID=$(rsh "tmux list-windows -t '=$REMOTE_SESSION' -F '#{window_id} #{window_name}' | awk -v n='$REMOTE_WINDOW' '{id=\$1; name=\$0; sub(/^[^ ]+ +/, \"\", name); sub(/^[^a-zA-Z0-9_]+/, \"\", name); if (name==n) {print id; exit}}'" 2>>"$LOCAL_STATE/remote.err")
WIN_ID=${WIN_ID//$'\r'/}
if [ -z "$WIN_ID" ]; then
  WIN_ID=$(rsh "tmux new-window -d -P -F '#{window_id}' -t '=$REMOTE_SESSION' -n '$REMOTE_WINDOW' -c '$REMOTE_DIR'" 2>>"$LOCAL_STATE/remote.err")
  WIN_ID=${WIN_ID//$'\r'/}
  note "created remote window $REMOTE_SESSION:$REMOTE_WINDOW ($WIN_ID)"
fi
case "$WIN_ID" in
  @[0-9]*) : ;;
  *) fail failed-no-claude 74 "could not resolve a window id for '$REMOTE_SESSION:$REMOTE_WINDOW' on $HOST (got '$WIN_ID'; see $LOCAL_STATE/remote.err)" ;;
esac

# Resolve the pane by its tmux-assigned unique id (%N), NOT by "session:0.0".
# Index bases are a per-server option: marketing-vps sets `base-index 1` AND
# `pane-base-index 1`, so ":0.0" names a window/pane that can never exist there
# and every send-keys fails with "can't find window: 0". Measured 2026-07-27 —
# five preflight assertions passed and A4 failed on this alone. A pane id is
# base-independent and unambiguous, so it is correct on any tmux config.
# `list-panes`, NOT `display-message -t '=name'`: measured 2026-07-27 on
# marketing-vps, the `=` exact-match prefix makes display-message print NOTHING
# and still exit 0 — a silent wrong answer, the exact failure class this script
# exists to refuse. list-panes answers the question directly.
PANE=$(rsh "tmux list-panes -t '$WIN_ID' -F '#{pane_id}' | head -1" 2>>"$LOCAL_STATE/remote.err")
PANE=${PANE//$'\r'/}
case "$PANE" in
  %[0-9]*) : ;;
  *) fail failed-no-claude 74 "could not resolve a pane id for '$REMOTE_SESSION:$REMOTE_WINDOW' on $HOST (got '$PANE'; see $LOCAL_STATE/remote.err)" ;;
esac
note "remote pane resolved to $PANE"
PANE_CMD=$(rsh "tmux display-message -p -t '$PANE' '#{pane_current_command}'" 2>>"$LOCAL_STATE/remote.err")
PANE_CMD=${PANE_CMD//$'\r'/}
note "remote pane_current_command='$PANE_CMD'"

PANE_WARM=0
# ---------------------------------------------------------------------------
# A7 — can claude actually COMPLETE A REQUEST on the box?
#
# A4 below only ever proved the BINARY RESOLVES (`command -v claude`), or that a
# claude process is running. Neither says the API is reachable. On 2026-07-27 the
# box had inherited zig-computer's ANTHROPIC_BASE_URL pointing at a tailnet
# gateway it cannot reach, so every claude invocation there failed — and A4 went
# green through all of it, because a binary that resolves and a binary that works
# are different claims. Every run that day was --dry-run, which stops before
# injecting, so nothing ever exercised the difference. A live tick would have
# burned its window and produced nothing.
#
# So: make one bounded, trivial request. It costs a handful of tokens on a weekly
# row and it is the only assertion that can actually fail on a broken gateway.
A7_OUT=$(rsh "cd ~ && timeout 90 claude -p 'reply with exactly: PONG' 2>&1 | tail -2" 2>>"$LOCAL_STATE/remote.err")
A7_OUT=${A7_OUT//$'\r'/}
case "$A7_OUT" in
  *PONG*) say "preflight A7: OK (claude completed a live request on $HOST)" ;;
  *) fail failed-no-claude 74 "A7 FAILED: claude on $HOST did not complete a trivial request.
    got: $(printf '%s' "${A7_OUT:-<no output>}" | tr '\n' ' ' | cut -c1-300)
    The binary may resolve while the API is unreachable — check ANTHROPIC_BASE_URL
    on the box (it must NOT inherit zig-computer's tailnet gateway), and that the
    company-seat login is still valid: ssh $HOST 'claude -p hi'.
    NOT dispatching: a tick with no working model burns its window and writes nothing." ;;
esac

if [ "$PANE_CMD" = "claude" ]; then
  PANE_WARM=1
  say "preflight A4: OK (claude is already the pane's running process)"
else
  PROBE="$REMOTE_WORK/claude-probe.txt"
  rsh "mkdir -p '$REMOTE_WORK'" >/dev/null 2>>"$LOCAL_STATE/remote.err" \
    || fail failed-no-claude 74 "cannot create $REMOTE_WORK on $HOST (see $LOCAL_STATE/remote.err)"
  # Typed into the pane, so the PATH under test is the pane's own.
  PROBE_CMD="command -v claude > '$PROBE' 2>&1; echo \"PROBE_RC=\$?\" >> '$PROBE'"
  PROBE_B64=$(printf '%s' "$PROBE_CMD" | base64 | tr -d '\n')
  rsh "tmux send-keys -t '$PANE' -l \"\$(printf %s '$PROBE_B64' | base64 -d)\"; tmux send-keys -t '$PANE' Enter" \
    >/dev/null 2>>"$LOCAL_STATE/remote.err" \
    || fail failed-no-claude 74 "could not type the claude probe into $PANE (see $LOCAL_STATE/remote.err)"

  PROBE_OUT=""
  for _ in $(seq 1 20); do
    sleep 1
    PROBE_OUT=$(rsh "cat '$PROBE' 2>/dev/null || true")
    case "$PROBE_OUT" in *PROBE_RC=*) break ;; esac
  done
  case "$PROBE_OUT" in
    *"PROBE_RC=0"*) say "preflight A4: OK (pane resolves claude at $(printf '%s' "$PROBE_OUT" | head -1))" ;;
    *) fail failed-no-claude 74 "A4 FAILED: 'claude' is not on the PATH of pane $PANE on $HOST.
    probe output: $(printf '%s' "${PROBE_OUT:-<no output within 20s>}" | tr '\n' ' ')
    The box's claude/node live behind an INTERACTIVE ZSH LOGIN profile; a pane started
    as a plain or non-login shell cannot see them. Remedy: recreate the session so its
    pane runs a login shell, e.g.
      ssh $HOST \"tmux kill-window -t $REMOTE_SESSION:$REMOTE_WINDOW\"   # just this row's window; other rows keep theirs
    Dispatching now would type /pulse tick into a shell that answers 'command not found'." ;;
  esac
fi

# ---------------------------------------------------------------------------
# --dry-run stops here. Everything above ran for real — the tunnel really opened,
# the refresh really ran, and both A3 and A4 really probed the box. That is the
# point: a dry run that skipped the assertions would prove nothing about them.
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
  say "DRY RUN: all preflight assertions passed."
  say "  tunnel mode:   TUNNEL_MODE=$TUNNEL_MODE  (recorded at $LOCAL_STATE/tunnel-mode)"
  # The checkout state is printed on the dry run for the same reason it is put in
  # the ledger row: since dotfiles-f4ub a dirty or non-advancing tree PROCEEDS, so
  # the only defence against a silently-stale run is that it is stated.
  say "  checkout:      clean=${CHECKOUT_CLEAN:-unknown}  (report: $CHECKOUT_REPORT)"
  if [ "${CHECKOUT_CLEAN:-true}" != true ]; then
    jq -r '(.remote_dirty[]? | "    dirty on the box: " + .repo + ": " + (.paths|join(", "))),
           (.stalled[]?      | "    STALE (fast-forward refused): " + .),
           (.local_dirty[]?  | "    dirty here (never reaches the box): " + .)' \
       <<<"${CHECKOUT_JSON:-{\}}" | while IFS= read -r _l; do say "$_l"; done
    say "    -> a real run would put all of the above in DISPATCH.md and the ledger row"
  fi
  # Outside the clean=false branch on purpose: an auto-fast-forward leaves the
  # tree CLEAN, so gating this on not-clean would hide the one action the
  # preflight actually took.
  jq -r '.auto_ff[]? | "    fast-forwarded here: " + .repo + ": " + .from + " -> " + .to + " (" + (.commits|tostring) + " commit(s))"' \
     <<<"${CHECKOUT_JSON:-{\}}" | while IFS= read -r _l; do say "$_l"; done
  say "  would stage:   $HOST:$REMOTE_WORK/DISPATCH.md"
  if [ "$WITH_TOKEN" = 1 ]; then
    # Names only — never a value, not even a length. Brokering itself happens
    # after this exit, so a dry run must at least show WHICH credentials a real
    # run would carry and which the project file is missing.
    _dr_have=""; _dr_miss=""
    for _v in FLEET_API_TOKEN SITE_PASSWORD SLACK_BOT_TOKEN SLACK_NEWS_PLANNING_CHANNEL_ID; do
      if [ "$_v" = FLEET_API_TOKEN ]; then
        { [ -n "${FLEET_API_TOKEN:-}" ] || grep -q "^export ${_v}=" "$HOME/.secrets" 2>/dev/null; } \
          && _dr_have="$_dr_have $_v" || _dr_miss="$_dr_miss $_v"
      elif grep -q "^${_v}=" "$DIR/.env.local" 2>/dev/null; then _dr_have="$_dr_have $_v"
      else _dr_miss="$_dr_miss $_v"; fi
    done
    say "  would broker: ${_dr_have:-（none）}"
    [ -n "$_dr_miss" ] && say "  MISSING:      $_dr_miss  (a row needing these fails on the box)"
  fi
  if [ "$FRESH" = 1 ] && [ "$PANE_WARM" = 1 ]; then
    say "  would clear:   /clear into $PANE first (--fresh, pane is warm)"
  elif [ "$FRESH" = 1 ]; then
    say "  would clear:   nothing (--fresh, but the pane is cold — already fresh)"
  fi
  say "  would inject:  /pulse tick $REMOTE_DIR  (into $HOST tmux $PANE)"
  say "  would poll:    $HOST:$REMOTE_WORK/result.json  (up to ${TIMEOUT}s)"
  say "  would write:   $DIR/refs/pulse-ledger.jsonl   (row=$ROW)"
  say "  would surface: $SESSION:$WINDOW via $INJECT   (only if the payload asks)"
  emit_result dry-run-ok
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 5 — broker FLEET_API_TOKEN (opt-in), stdin-only.
# ---------------------------------------------------------------------------
if [ "$WITH_TOKEN" = 1 ]; then
  TOK="${FLEET_API_TOKEN:-}"
  if [ -z "$TOK" ] && [ -f "$HOME/.secrets" ]; then
    # shellcheck disable=SC1091
    TOK=$( . "$HOME/.secrets" >/dev/null 2>&1; printf '%s' "${FLEET_API_TOKEN:-}" )
  fi
  [ -n "$TOK" ] || fail failed-usage 64 "--with-fleet-token given but FLEET_API_TOKEN is not set and not in ~/.secrets"
  # Over STDIN: the value never appears in this script's argv nor in the ssh
  # command line. It reaches the tmux session env and nothing else; cleanup()
  # unsets it. Never echoed — not here, not on failure.
  if ! printf '%s' "$TOK" | "$SSH_BIN" -S "$CTL" -o BatchMode=yes "$HOST" \
        "read -r t; tmux setenv -t '$REMOTE_SESSION' FLEET_API_TOKEN \"\$t\"" \
        2>>"$LOCAL_STATE/remote.err"; then
    fail failed-inject 75 "could not broker FLEET_API_TOKEN into the remote tmux env (see $LOCAL_STATE/remote.err)"
  fi
  unset TOK
  rsh "mkdir -p '$INFLIGHT_DIR' && touch '$INFLIGHT_DIR/$ROW'" >/dev/null 2>>"$LOCAL_STATE/remote.err" \
    || warn "could not claim the credential refcount marker; teardown may unset while another row runs"
  say "credential: FLEET_API_TOKEN brokered into tmux env for this run only (never written to the box's disk)"

  # PROJECT SECRETS the fleet proxy does NOT cover. Audited 2026-07-27 across all
  # five DI rows; everything else a skill names is either proxied or local-only:
  #   ASANA_ACCESS_TOKEN  -> proxied (/api/asana)
  #   GOOGLE_CLIENT_*/REFRESH_TOKEN -> the LOCAL-FALLBACK identity only; over the
  #                          proxy the write runs as the service account
  #   GITHUB_TOKEN, ANTHROPIC_KEY -> named only in .env.local doc blocks; no live
  #                          call (the playbook is read from the synced repo, and
  #                          the tick IS the model)
  # These three are the real gap, and each fails in a DIFFERENT way if missing:
  #   SITE_PASSWORD                  -> /api/research/* returns 401 (VERIFIED:
  #                                     401 with no password AND with a wrong one),
  #                                     so di-wednesday's research unit dies.
  #   SLACK_BOT_TOKEN                -> the skills construct WebClient directly;
  #                                     the fleet only proxies INBOUND /api/slack/
  #                                     events, so there is no outbound route.
  #   SLACK_NEWS_PLANNING_CHANNEL_ID -> not secret, but the post has no target.
  # Read from the PROJECT's .env.local (never argv), brokered over stdin like the
  # fleet token, unset at teardown. Missing ones warn rather than fail: a row that
  # does not need Slack should still dispatch.
  if [ -f "$DIR/.env.local" ]; then
    for _v in SITE_PASSWORD SLACK_BOT_TOKEN SLACK_NEWS_PLANNING_CHANNEL_ID; do
      _val=$(grep -m1 "^${_v}=" "$DIR/.env.local" 2>/dev/null | cut -d= -f2- | sed 's/^"//;s/"$//' | cut -d'#' -f1 | sed 's/[[:space:]]*$//')
      if [ -z "$_val" ]; then
        note "project secret $_v not found in $DIR/.env.local — a row needing it will fail on the box"
        continue
      fi
      if ! printf '%s' "$_val" | "$SSH_BIN" -S "$CTL" -o BatchMode=yes "$HOST" \
            "read -r t; tmux setenv -t '$REMOTE_SESSION' $_v \"\$t\"" \
            2>>"$LOCAL_STATE/remote.err"; then
        fail failed-inject 75 "could not broker $_v into the remote tmux env (see $LOCAL_STATE/remote.err)"
      fi
      BROKERED="${BROKERED:+$BROKERED }$_v"
    done
    unset _val
    [ -n "${BROKERED:-}" ] && say "credential: brokered $BROKERED for this run only (never written to the box's disk)"
  else
    note "no $DIR/.env.local — project secrets (SITE_PASSWORD, SLACK_*) not brokered"
  fi
fi

# A NON-SECRET marker so a skill can tell it is running on the dispatch box
# rather than on zig-computer. di-wednesday needs this: its Fable positioning vet
# normally fires onto marketing-vps with /vps, which would be a
# self-hop when the tick already runs there. Inferring from hostname was the
# alternative and it is worse — the box's hostname is vps-8a9eb245 while the ssh
# ALIAS is marketing-vps, so the obvious check is wrong in a way that fails
# silently. An explicit signal from the dispatcher cannot drift.
rsh "tmux setenv -t '$REMOTE_SESSION' PULSE_DISPATCH_REMOTE 1" >/dev/null 2>>"$LOCAL_STATE/remote.err" \
  || warn "could not set PULSE_DISPATCH_REMOTE in the remote tmux env (a skill that branches on it will take the local path)"

# ---------------------------------------------------------------------------
# Step 6 — stage DISPATCH.md: the remote tick's contract.
#
# Written as a FILE rather than crammed into the injected line, because the
# injected line must be exactly one line (a newline in send-keys submits the
# composer) and this contract is not one line's worth of rules.
# ---------------------------------------------------------------------------
DISPATCH_MD=$(cat <<EOF
# REMOTE DISPATCH CONTRACT — run $RUN_ID

You are running on **marketing-vps** (the LinearB company seat), dispatched from
zig-computer by \`pulse-dispatch-remote.sh\`. Run the pulse row **$ROW** for the
project at \`$REMOTE_DIR\`, exactly per the \`/pulse\` skill — with the four
overrides below. The overrides WIN over the /pulse skill and over the project's
refs/pulse.md wherever they disagree.

You are a **peer machine**, not a courier. You reach the fleet proxy (Asana,
Google Docs, Slack), you hold the \`lb-agent-accounts\` service-account key at
\`~/.secrets/google-service-account.json\`, you have a git identity that commits
and pushes, and \`br\` is on your PATH. **Finish your own work** — write the tab,
post the comment, land the file. Do not park a deliverable for zig-computer to
land; the only two things reserved to that machine are §1 and §3 below, and each
has a specific reason.

## 1. NEVER write the ledger
Do **not** create, append to, or edit \`$REMOTE_DIR/refs/pulse-ledger.jsonl\`.
The ledger is a single-writer file, authoritative on zig-computer. Your
outcome/proof/note go in the result payload below; the dispatcher writes the row
there. A remote ledger write forks the file and the fork is invisible until two
rows disagree.

## 2. Beads are PERMITTED — through git, or not at all
You MAY run \`br\` (Zig, 2026-07-28): create, update, close. The old blanket ban
assumed two bead stores that could not reconcile; they reconcile now, because you
can pull and push and the \`jsonl-union\` merge driver is registered on BOTH
machines. The discipline that replaces the ban, and it is not optional:

    git -C <repo> pull --ff-only     # BEFORE you write
    br create / br update / br close
    br sync --flush-only
    git -C <repo> add .beads/issues.jsonl && git -C <repo> commit && git -C <repo> push

A bead written here and never pushed is the failure now — not the write itself,
and no longer a dirty \`.beads/\` either (that stopped being fatal on
2026-07-30). If you would rather not carry it, \`bead_request\` in the payload
still works and the local side files it. Note the staging rule in §4 applies here
too: \`git add .beads/issues.jsonl\` names a FILE, which is correct;
\`git add .beads\` names a directory, which is not.

## 3. NEVER raise an AskUserQuestion
There is nobody attached to this box — a dialog here reaches no one and freezes
this pane. If this tick needs Zig (a Pod Weekly blocker, an approval, a
present-for-approval row), fill in \`surface_request\` instead. The dispatcher
relays it to the \`work:di\` window on zig-computer and the LOCAL session raises
the real AskUserQuestion, with the real bell and the real phone notification.

## 4. Own your writes through git — and COMMIT ONLY YOUR OWN FILES, BY NAME

### The state you are working in
$CHECKOUT_NOTE

A dirty checkout no longer blocks anything (Zig, 2026-07-30): every repo on this
box is somebody's work in progress, so ticks proceed and work in the mess.
**Nothing you do may clean up after anyone.** No \`git checkout -- <path>\`, no
\`git reset --hard\`, no \`git stash\`, no \`git clean\`. If a file is dirty and
it is not yours, leave it exactly as you found it and mention it in your \`note\`.

### Landing YOUR work
**Pull, write, commit, push.** Prefer \`--ff-only\`; if a pull needs a real merge,
resolve it deliberately rather than leaving a half-finished rebase. If a pull is
REFUSED because somebody's WIP is in the way, do not force it — commit what is
yours, say so in your \`note\`, and move on. Checkout shape: \`~/dotfiles\` and
\`~/linearb\` sit on \`main\` and push normally, while the project submodules are
checked out DETACHED at the published tip, so a commit there needs
\`git push origin HEAD:main\` — an unpushed submodule commit is simply lost at
the next refresh.

### ⚠️ THE WIP GUARD — NAME THE FILES
Permission to commit in a messy tree is permission to sweep somebody else's
unfinished work into your commit, which is strictly worse than losing a tick. So
the staging rule is absolute:

**FORBIDDEN:** \`git add -A\` · \`git add .\` · \`git commit -a\` · **and any
directory or glob pathspec** (\`git add refs/\`, \`git add 'src/*.ts'\`).
**REQUIRED:** explicit file paths, one by one — \`git add refs/a.md refs/b.md\`.

The directory case is not theoretical and it is the one people get wrong:
\`git add <dir>\` does not mean "add my new files under dir", it means "make the
index match the working tree there" — **including deletions**. On 2026-07-30 an
hourly rsync removed 12 committed files on this box between a \`cp\` and a
\`git add refs/doc-scripts\`, and two commits captured those deletions as if they
were intentional. Verified in a scratch repo: with a file deleted from \`d/\`,
plain \`git add d\` stages \`D d/gone.txt\`.

Run this before every commit — it catches exactly that case:

    test "\$(git diff --cached --diff-filter=D --name-only | wc -l)" -eq 0 \\
      || { echo "ABORT: staged deletions I did not intend"; \\
           git diff --cached --diff-filter=D --name-only; }

A deletion you MEANT is fine: stage it explicitly with \`git rm\` and say so in
the message. The rule is only that no deletion arrives as a side effect of naming
a directory.

Your tree does not have to be clean when you finish. It has to be true: what you
authored is committed and pushed, what you did not author is untouched.

## Credentials
The fleet proxy is reachable at \`http://localhost:$PORT\` — a tunnel back to
zig-computer, so the same URL the local skills already use works here unchanged.
This run reached it as \`TUNNEL_MODE=$TUNNEL_MODE\` ("adopted" = this box's own
standing forward, which outlives this dispatch; "owned" = a reverse forward from
zig-computer that dies when this dispatch ends). The BROKERED CREDENTIALS are
run-scoped either way and are unset at teardown. Do not persist any token to disk.

## The result payload — REQUIRED, this is your only output channel
Write \`$REMOTE_WORK/result.json.tmp\` then \`mv\` it to
\`$REMOTE_WORK/result.json\` (atomic — the dispatcher is polling and must never
read a half-written file). Write it EXACTLY ONCE, at the end of the tick, even
if the tick was quiet or could not run.

\`\`\`json
{
  "schema": 1,
  "run_id": "$RUN_ID",
  "row": "$ROW",
  "outcome": "done | quiet | blocked",
  "note": "the ledger note you would have written — plain prose, name plainly what did and did not get produced",
  "proof": {"kind": "cmd", "cmd": "a shell command that RE-RUNS from the repo root and exits 0"},
  "bead_request": {"priority": 1, "title": "human: ...", "description": "..."},
  "surface_request": {
    "reason": "one line: why this needs Zig",
    "question": "the exact question the LOCAL session should ask him",
    "options": ["option A", "option B"],
    "detail": "anything the local session needs in order to ask it well"
  },
  "artifacts": ["urls / gids / tab ids the tick produced"]
}
\`\`\`

- \`row\` MUST be the literal string \`$ROW\` — never null, never invented.
- \`outcome\` follows the project's own semantics in \`refs/pulse.md\`: a tick that
  ran and correctly escalated is \`done\` plus an escalation bead — filed here per
  §2 or handed over as a \`bead_request\` — not \`blocked\`. \`blocked\` is
  reserved for a tick that could not run at all.
- \`proof\` is REQUIRED on \`done\`. It must have verifier-distance and it must be
  re-runnable **on zig-computer** (the dispatcher's ledger row carries it and the
  local pre-commit hook re-runs it). \`\$FLEET_API_TOKEN\` and
  \`http://localhost:$PORT\` both resolve there, so a proof written against them
  is portable. A proof pointing at a path that exists only on this box is not.
- \`bead_request\` and \`surface_request\` are OPTIONAL — omit the key entirely
  when there is nothing to ask for. Do not emit an empty object.
- If §4 flagged a STALE checkout, or you left somebody else's dirt untouched, or
  a pull was refused, **put it in \`note\`.** The ledger row already records the
  machine-readable checkout state; your sentence is what makes it legible to a
  human reading the row six weeks later.

If you cannot finish, still write the payload with \`outcome\` set honestly and a
\`note\` saying what stopped you. Silence is the one unacceptable outcome: the
dispatcher's timeout cannot tell a crashed tick from a slow one, and a tick that
goes quiet is exactly the failure this whole mechanism exists to make visible.
EOF
)
DISPATCH_B64=$(printf '%s' "$DISPATCH_MD" | base64 | tr -d '\n')
rsh "mkdir -p '$REMOTE_WORK' && printf %s '$DISPATCH_B64' | base64 -d > '$REMOTE_WORK/DISPATCH.md'" \
  >/dev/null 2>>"$LOCAL_STATE/remote.err" \
  || fail failed-inject 75 "could not stage DISPATCH.md at $HOST:$REMOTE_WORK (see $LOCAL_STATE/remote.err)"
printf '%s\n' "$DISPATCH_MD" > "$LOCAL_STATE/DISPATCH.md"
say "staged: $HOST:$REMOTE_WORK/DISPATCH.md"

# ---------------------------------------------------------------------------
# Step 7 — launch claude in the pane if it isn't there, then inject the tick.
#
# The readiness gate below is a remote re-implementation of pulse-inject.sh's,
# and it has to be: pulse-inject speaks only to the LOCAL tmux server (it shells
# `tmux` directly), so it cannot drive a pane over ssh. The LOCAL surface
# callback at step 10 does reuse it, unchanged — that is where the session/window
# auto-creation logic is shared rather than copied.
# ---------------------------------------------------------------------------
READY_MARKER=${PULSE_READY_MARKER-'shift\+tab to cycle|\? for shortcuts|for agents|bypass permissions|accept edits on|plan mode on'}
READY_TIMEOUT=${PULSE_READY_TIMEOUT:-120}

if [ "$PANE_WARM" != 1 ]; then
  say "remote: launching claude in $PANE"
  LAUNCH_B64=$(printf '%s' "cd '$REMOTE_DIR' && claude" | base64 | tr -d '\n')
  rsh "tmux send-keys -t '$PANE' -l \"\$(printf %s '$LAUNCH_B64' | base64 -d)\"; tmux send-keys -t '$PANE' Enter" \
    >/dev/null 2>>"$LOCAL_STATE/remote.err" \
    || fail failed-inject 75 "could not launch claude in $PANE (see $LOCAL_STATE/remote.err)"

  # Liveness is not readiness: pane_current_command flips to 'claude' seconds
  # before the TUI can accept typed input, and typing early drops the keystrokes
  # SILENTLY. Same lesson, same fix, same fail-closed choice as pulse-inject
  # (dotfiles-mrta): on timeout we do NOT inject blind — there is nothing to type
  # into, so "inject anyway" is a silent loss, not a late try.
  _t0=$(date +%s); _deadline=$(( _t0 + READY_TIMEOUT )); _ready=""
  while [ "$(date +%s)" -lt "$_deadline" ]; do
    if rsh "tmux capture-pane -p -t '$PANE'" 2>/dev/null | grep -Eq "$READY_MARKER"; then _ready=1; break; fi
    sleep 3
  done
  [ -n "$_ready" ] || fail failed-inject 75 "claude's composer never became input-ready in $PANE within ${READY_TIMEOUT}s.
    NOT injecting — typing into a pane with no composer loses the tick silently.
    Watch it with: $SSH_BIN $HOST 'tmux attach -t $REMOTE_SESSION'"
  say "remote: composer ready after $(( $(date +%s) - _t0 ))s"
  sleep 2
fi

# --fresh: warm process, cold context. Only meaningful when the pane was ALREADY
# running claude — a cold launch is fresh by construction and a /clear there just
# costs a round trip. The prompt cache TTL is ~1h and these rows are a WEEK apart,
# so a resumed session buys zero cached tokens and pays full cache-creation on
# everything it accumulated (dotfiles-6ycc). Per-row sessions made this the normal
# case rather than the exception, so it is opt-in per unit but wanted on all of them.
if [ "$FRESH" = 1 ] && [ "$PANE_WARM" = 1 ]; then
  CLR_B64=$(printf '%s' '/clear' | base64 | tr -d '\n')
  rsh "tmux send-keys -t '$PANE' -l \"\$(printf %s '$CLR_B64' | base64 -d)\"" \
    >/dev/null 2>>"$LOCAL_STATE/remote.err" \
    || fail failed-inject 75 "--fresh: send-keys of /clear failed (see $LOCAL_STATE/remote.err)"
  sleep 1
  rsh "tmux send-keys -t '$PANE' Enter" >/dev/null 2>>"$LOCAL_STATE/remote.err" \
    || fail failed-inject 75 "--fresh: send-keys of Enter after /clear failed — the pane may hold an unsent /clear"
  sleep "${PULSE_FRESH_SETTLE:-2}"
  say "fresh: cleared the remote context before dispatching (pane was warm)"
elif [ "$FRESH" = 1 ]; then
  note "fresh: pane was cold-launched, so no /clear needed"
fi

# ONE line — a newline inside send-keys -l submits the composer, so the contract
# reference has to ride on the same line as the tick command.
TICK_CMD="/pulse tick $REMOTE_DIR (REMOTE DISPATCH — read $REMOTE_WORK/DISPATCH.md FIRST and obey it; it overrides ledger, bead, and AskUserQuestion handling for this tick, and defines the result payload you must write)"
TICK_B64=$(printf '%s' "$TICK_CMD" | base64 | tr -d '\n')
rsh "tmux send-keys -t '$PANE' -l \"\$(printf %s '$TICK_B64' | base64 -d)\"" \
  >/dev/null 2>>"$LOCAL_STATE/remote.err" \
  || fail failed-inject 75 "send-keys of the tick text failed (see $LOCAL_STATE/remote.err)"
sleep 1
rsh "tmux send-keys -t '$PANE' Enter" >/dev/null 2>>"$LOCAL_STATE/remote.err" \
  || fail failed-inject 75 "send-keys of Enter failed — the tick text may be sitting unsent in $PANE"
say "dispatched: row=$ROW into $HOST tmux $PANE"

# ---------------------------------------------------------------------------
# Step 8 — poll for the payload.
#
# `mv` into place is atomic within a directory, so a successful `cat` + parse is
# never a torn read. An unparseable body means "still being written" only in the
# sense that it is not there yet; we keep polling and let the timeout be the
# verdict rather than guessing.
# ---------------------------------------------------------------------------
say "polling $HOST:$REMOTE_WORK/result.json (every ${POLL}s, up to ${TIMEOUT}s)"
_t0=$(date +%s); _deadline=$(( _t0 + TIMEOUT )); PAYLOAD=""
while [ "$(date +%s)" -lt "$_deadline" ]; do
  sleep "$POLL"
  BODY=$(rsh "cat '$REMOTE_WORK/result.json' 2>/dev/null || true")
  if [ -n "$BODY" ] && printf '%s' "$BODY" | jq -e '.outcome' >/dev/null 2>&1; then
    PAYLOAD=$BODY; break
  fi
done

if [ -z "$PAYLOAD" ]; then
  # A timeout is the §10 failure shape in its purest form — the tick may have
  # crashed, hung, or finished without writing. It must NOT go quiet on this
  # side too, so it is surfaced locally as well as failing loudly.
  printf '%s\n' "$(rsh "tmux capture-pane -p -t '$PANE' | tail -60" 2>&1)" > "$LOCAL_STATE/remote-pane-tail.txt"
  jq -n --arg row "$ROW" --arg run "$RUN_ID" --arg host "$HOST" --arg work "$REMOTE_WORK" \
        --arg tail "$LOCAL_STATE/remote-pane-tail.txt" \
     '{reason:"remote pulse tick produced no result payload before the dispatcher timed out",
       question:("The remote " + $row + " tick on " + $host + " never returned a payload. It may have crashed, hung, or finished silently. How do you want to handle it?"),
       options:["Re-run it remotely","Run it locally instead","Leave it — I will look at the box"],
       detail:("run=" + $run + "  remote work dir=" + $work + "  last 60 lines of the remote pane were saved to " + $tail + ". NO ledger row was written for this run.")}' \
     > "$LOCAL_STATE/surface.json"
else
  printf '%s\n' "$PAYLOAD" > "$LOCAL_STATE/result.json"
  say "payload received after $(( $(date +%s) - _t0 ))s"
fi

# ---------------------------------------------------------------------------
# Step 10 — SURFACE BACK TO ZIG. (Definition lives near the top; see there.)
#
# The bell has to ring HERE. The migration plan originally kept news-planning and
# di-monday local forever for exactly this reason: their deliverable IS the
# AskUserQuestion, and a dialog on an unattended shared box is worthless. Zig's
# 2026-07-27 extension keeps that property while letting the drafting move: the
# remote tick emits a surface_request, and the LOCAL session raises the real
# dialog — real bell, real phone notification, real person.
#
# Session/window auto-creation is REUSED, not rewritten: pulse-inject.sh already
# creates the `work` session detached when absent, creates the `di` window when
# absent, launches claude, gates on the composer being input-ready, and refuses
# to type into a window that is already 🔔-blocked on Zig. Re-implementing any of
# that here would be a second copy to drift.
#
# FAIL CLOSED on its verdict: pulse-inject exits 0 on three structurally
# different outcomes (injected / bounced / deferred), so `if pulse-inject.sh` is
# the bug one layer down. Only PULSE_INJECT_RESULT=injected counts as delivered.
# ---------------------------------------------------------------------------

if [ -z "$PAYLOAD" ]; then
  surface_locally "$LOCAL_STATE/surface.json" timeout || true
  fail failed-timeout 76 "no result payload from $HOST within ${TIMEOUT}s for row=$ROW (run=$RUN_ID).
    The remote pane's last 60 lines: $LOCAL_STATE/remote-pane-tail.txt
    NO ledger row was written — a tick that cannot prove it ran must not leave one.
    Inspect: $SSH_BIN $HOST 'tmux attach -t $REMOTE_SESSION'"
fi

# ---------------------------------------------------------------------------
# Step 9 — validate the payload, then WRITE THE LEDGER HERE.
# ---------------------------------------------------------------------------
P_ROW=$(jq -r '.row // empty'     <<<"$PAYLOAD")
P_OUT=$(jq -r '.outcome // empty' <<<"$PAYLOAD")
P_NOTE=$(jq -r '.note // ""'      <<<"$PAYLOAD")

[ -n "$P_ROW" ] || fail failed-payload 77 "payload has no .row (null or missing). The /pulse ledger spec forbids a null row: every per-row analytic keys on the name, so the tick would be invisible. Payload saved at $LOCAL_STATE/result.json"
[ "$P_ROW" = "$ROW" ] || fail failed-payload 77 "payload row '$P_ROW' != dispatched row '$ROW' — the remote tick ran something other than what was asked for. Refusing to write the ledger. Payload: $LOCAL_STATE/result.json"
case "$P_OUT" in
  done|quiet|blocked) : ;;
  *) fail failed-payload 77 "payload outcome '$P_OUT' is not one of done|quiet|blocked. Payload: $LOCAL_STATE/result.json" ;;
esac
if [ "$P_OUT" = "done" ] && ! jq -e '.proof.kind and (.proof.cmd // .proof.bead)' <<<"$PAYLOAD" >/dev/null; then
  fail failed-payload 77 "payload outcome=done carries no usable proof token. /pulse forbids a self-declared done, and the local pre-commit hook would reject the row anyway. Payload: $LOCAL_STATE/result.json"
fi

LEDGER="$DIR/refs/pulse-ledger.jsonl"
LINE=$(jq -cn \
  --arg ts   "$(date -u +%FT%TZ)" \
  --arg row  "$P_ROW" \
  --arg out  "$P_OUT" \
  --arg note "$P_NOTE" \
  --arg run  "$RUN_ID" \
  --arg host "$HOST" \
  --argjson proof "$(jq -c '.proof // null' <<<"$PAYLOAD")" \
  --argjson checkout "${CHECKOUT_JSON:-null}" \
  '{ts:$ts, row:$row, outcome:$out, note:$note,
    dispatch:{remote:true, host:$host, run_id:$run, checkout:$checkout}}
   + (if $proof == null then {} else {proof:$proof} end)') \
  || fail failed-ledger 78 "could not build the ledger line from the payload ($LOCAL_STATE/result.json)"

# Snapshot for rollback. A malformed row poisons the ledger for every consumer,
# so it must be possible to take it back out — appending and hoping is not enough.
BACKUP="$LOCAL_STATE/pulse-ledger.jsonl.before"
[ -f "$LEDGER" ] && cp -p "$LEDGER" "$BACKUP"
mkdir -p "$(dirname "$LEDGER")"
printf '%s\n' "$LINE" >> "$LEDGER"
say "ledger: appended row=$P_ROW outcome=$P_OUT checkout_clean=${CHECKOUT_CLEAN:-unknown} auto_ff=$(jq -r '(.auto_ff // []) | length' <<<"${CHECKOUT_JSON:-{\}}") to $LEDGER"

if [ -x "$LEDGER_LINT" ] || [ -f "$LEDGER_LINT" ]; then
  if ! python3 "$LEDGER_LINT" --project "$DIR"; then
    if [ -f "$BACKUP" ]; then cp -p "$BACKUP" "$LEDGER"; else : > "$LEDGER"; fi
    fail failed-ledger 78 "pulse-ledger-lint rejected the row; it has been ROLLED BACK (ledger restored from $BACKUP).
    The remote payload is preserved at $LOCAL_STATE/result.json — fix and land it by hand."
  fi
  say "ledger: lint clean"
fi

# The ledger row is written but deliberately NOT committed. The local pre-commit
# hook re-runs `done` proofs, and a proof authored on the VPS deserves a human
# (or a local session) at the commit, not a script racing a hook. The surface
# prompt names the file so whoever picks it up knows to land it.

# ---------------------------------------------------------------------------
# Step 9b — stage any bead request. The dispatcher does not run `br` itself:
# bead lifecycle belongs to the orchestrator (global CLAUDE.md), and a script
# quietly minting P1 beads is a worse trade than one short local prompt.
# ---------------------------------------------------------------------------
HAS_BEAD=0
if jq -e '.bead_request' <<<"$PAYLOAD" >/dev/null 2>&1; then
  jq -c '.bead_request' <<<"$PAYLOAD" > "$LOCAL_STATE/bead-request.json"
  HAS_BEAD=1
  say "bead: request staged at $LOCAL_STATE/bead-request.json (NOT filed — the local session files it)"
fi

# ---------------------------------------------------------------------------
# Step 10 — surface, if the payload asked for it (or if a bead needs filing).
# ---------------------------------------------------------------------------
if jq -e '.surface_request' <<<"$PAYLOAD" >/dev/null 2>&1; then
  jq '.surface_request + {_bead_request: (.bead_request // null), _ledger: "'"$LEDGER"'", _payload: "'"$LOCAL_STATE/result.json"'"}' \
     <<<"$PAYLOAD" > "$LOCAL_STATE/surface.json"
  surface_locally "$LOCAL_STATE/surface.json" surface-request || true
elif [ "$HAS_BEAD" = 1 ]; then
  jq -n --arg b "$LOCAL_STATE/bead-request.json" --arg l "$LEDGER" --arg p "$LOCAL_STATE/result.json" \
     '{reason:"remote tick asked for a bead to be filed locally",
       question:"A remote pulse tick filed no bead (by design) and needs one created here. File it?",
       options:["File it as requested","Show me the payload first"],
       detail:("bead request: " + $b + "  ·  ledger row appended (uncommitted): " + $l + "  ·  full payload: " + $p)}' \
     > "$LOCAL_STATE/surface.json"
  surface_locally "$LOCAL_STATE/surface.json" bead-request || true
fi

say "run $RUN_ID complete: row=$P_ROW outcome=$P_OUT · state=$LOCAL_STATE"
emit_result completed
exit 0
