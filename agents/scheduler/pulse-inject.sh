#!/bin/bash
# pulse-inject.sh — the tmux-injection scheduler primitive (/pulse OQ-1).
#
# Fired by a systemd user timer (or anything else). Ensures the
# dedicated scheduler window exists in Andrew's tmux, ensures an
# INTERACTIVE Claude Code session is running there, then types the
# kick-off command into it via send-keys.
#
# Why injection instead of `claude -p`: headless -p draws from the
# separate monthly Agent SDK credit pool (docs, 2026-06-15 policy) and
# is invisible — Andrew can't watch or steer. An interactive session in
# a tmux window uses the normal subscription, is observable by both
# Andrew and the agent, persists between ticks, and inherits the
# 🧠/✅/🔔/🌀 window lexicon (tmux-status.sh).
#
# Usage:
#   pulse-inject.sh --dir <project-path> --cmd "<prompt or /skill>" \
#                   [--session zig-computer] [--window pulse] [--launch claude] [--loop <id>] \
#                   [--config-dir <claude-seat>] [--model <pin>]
#
#   --dir      project directory the Claude session anchors in (required)
#   --cmd      the text typed into the session, submitted with Enter (required)
#   --session  tmux session name (default: zig-computer — ONE session per server,
#              named for the host; Zig's ruling 2026-08-09 abolished the separate
#              `work` session. Created detached if absent, so timers still work
#              after a reboot before Andrew attaches)
#   --window   dedicated window name (default: pulse). Matching strips any
#              leading lexicon glyph (🧠/✅/🔔/🌀) so the status hook's renames
#              don't break window discovery.
#   --launch   program to start when the window has no live session
#              (default: claude). Tests override with something inert.
#   --loop     the loop id (= the manifest timer / harness-state loop id, e.g.
#              pulse-daily-digest). Units pass `--loop %p` (systemd expands %p to
#              the unit prefix). On a 🔔-defer, the loop id is recorded to
#              ~/.local/state/harness/pulse-bounces.jsonl so the state bus renders
#              the tick as 'bounced' instead of a false 'tick in flight'
#              (harnessd-gf6). Optional + backward-compatible: omit it and defer
#              behaves exactly as before (logs, no bounce record). That log is
#              RETENTION-BOUNDED — see BOUNCE_MAX_LINES / PULSE_BOUNCE_MAX_LINES
#              below for the cap and exactly what it discards (explore-foda).
#   --config-dir  OPT-IN (default OFF): run this tick on a NAMED CLAUDE SEAT by
#              pinning CLAUDE_CONFIG_DIR to <path> (dotfiles-nnmm). Claude Code
#              relocates its ENTIRE config tree — credentials, projects,
#              sessions — under that dir, so a second OAuth lineage on one box
#              is a seat. ~/.claude-tick already does this for the jailed `dive`
#              loop; the seven LinearB rows use ~/.claude-work so company work
#              bills and attributes to the company seat, not to Zig's personal
#              subscription. Omit it and NOTHING changes: no env is set, no
#              seat is asserted, and every existing loop (dive/desk/dream/
#              digest) behaves byte-for-byte as before.
#              PULSE_CONFIG_CRED_FILE (default .credentials.json) = the file
#              inside <path> that must be non-empty for the seat to be usable.
#              Empty DISABLES that check (same "empty disables" idiom as
#              PULSE_READY_MARKER) — the escape hatch for a Claude Code that
#              moves its credential store.
#
#              ⚠️ WHY A FLAG AND NOT `Environment=CLAUDE_CONFIG_DIR=` IN THE
#              UNIT. Measured on zig-computer 2026-08-05 (tmux 3.5a, re-measured
#              under 3.6): this injector does NOT spawn claude — it `send-keys`
#              the launch string into a shell that ALREADY LIVES in the pane, so
#              the launched process inherits the TMUX SERVER's environment,
#              fixed whenever that server started (Zig's login), not this
#              process's. A unit-level Environment= would sit in pulse-inject's
#              own env, never reach the pane, and the tick would run on the
#              PERSONAL seat with nothing erroring. Worse, it is not even
#              consistently absent: a tmux server COLD-STARTED by the unit does
#              inherit it (measured — the pane shell then holds the value while
#              `show-environment` still reports `unknown variable`). An env that
#              reaches the tick or not depending on who happened to start the
#              tmux server is not a mechanism. So the seat is passed EXPLICITLY,
#              as an `export` typed into the pane immediately before the launch,
#              and then VERIFIED against the launched process's /proc environ.
#
#              ⚠️ AND THE REUSE PATH IS THE NASTIER HALF. Section 3 reuses a
#              live launcher instead of launching (that is the whole point of a
#              durable window). A `di-monday` window already holding a
#              PERSONAL-seat claude would be reused with no launch, no export,
#              and no error. So setting the env at launch time is necessary and
#              NOT sufficient: with --config-dir, a warm pane's launcher has its
#              seat read out of /proc and a mismatch is a HARD FAILURE
#              (failed-wrong-seat, exit 77) — never a silent proceed. Same class
#              as dotfiles-ucl4: no silent fallback.
#   --model    OPT-IN OVERRIDE (default: ASK THE ROSTER). The model tier this
#              tick runs on (dotfiles-pulse-row-model-seat-d0bk). Passing it
#              skips the roster entirely; omitting it makes this injector resolve
#              the TARGET WINDOW to its seat in `agents/seats.yml` and use that
#              seat's `model:` pin. Either way the pin is delivered the SAME way
#              --config-dir is: spliced into the LAUNCH STRING (`claude --model
#              <pin>`), explicit and verifiable, never inherited from an ambient
#              env — the whole argument in the --config-dir block above applies
#              here verbatim, because the delivery mechanism is identical (a
#              send-keys into a shell whose environment this process does not own).
#
#              ⚠️ THE PIN IS CANONICALISED BEFORE IT IS SPLICED (dotfiles-lstn).
#              The roster says `fable`; the launch string says
#              `--model 'claude-fable-5[1m]'`. A bare alias — or a bare full id
#              — silently drops the 1M context window: both run Fable 5, at
#              200,000 tokens, and only the `[1m]` literal gets 1,000,000
#              (measured 2026-08-09; the table and the probe output live in
#              agents/lib/model-canon.sh, which is the ONE place the mapping
#              exists). Alias resolution is additionally provider-dependent in
#              the client's own catalog, so a full id is the only argument that
#              means one thing everywhere. Three consequences to know:
#                * the pin is SINGLE-QUOTED on the launch string, because `[1m]`
#                  is a glob and an unmatched glob is a hard error in zsh —
#                  unquoted, the entire launch line would die and the pane would
#                  hold no launcher at all;
#                * the LEDGER records the canonical id (what the process was
#                  really started with, i.e. what the gateway will report), not
#                  the roster's short name;
#                * a warm pane launched before this carries `--model sonnet` on
#                  its cmdline and is therefore a REAL mismatch against
#                  `claude-sonnet-5[1m]` — same model, 200k instead of 1M. It is
#                  reported as such rather than normalised away, and it clears
#                  when that window's session is exited.
#              A missing model-canon.sh is a WARN + verbatim passthrough, never
#              a refusal: unpinning the whole fleet because a sibling file moved
#              would be strictly worse than the window it would save.
#
#              NO PIN => TODAY'S BEHAVIOUR, BYTE FOR BYTE. An unregistered
#              window, a missing/unparseable roster, a seat with no `model:`, or
#              a resolver refusal (R7 session mismatch) all mean "no pin": no
#              flag is appended, no verification runs, nothing is recorded. Rows
#              that never had a pin keep inheriting the machine default exactly
#              as before; the only trace is one line in $LOG.
#
#              LAUNCHER SCOPE (dotfiles-o9vi): the flag is appended for `claude`
#              AND for any launcher `is_claude_launcher()` recognizes as one that
#              forwards its own argv verbatim into `claude` — today that is only
#              `tick-jailed.sh`, whose final line execs `bwrap ${BWRAP_ARGS[@]} --
#              claude --dangerously-skip-permissions "$@"` (read, not assumed;
#              see tools/tick-jail/tick-jailed.sh). `--model <pin>` typed onto the
#              LAUNCH STRING therefore arrives as one of tick-jailed.sh's own
#              "$@" and rides that exec straight into the real claude's argv. Any
#              OTHER program gets NO --model — passing an unknown flag to an
#              unproven launcher would break the launch, and a pin that silently
#              changed unrecognized argv would be worse than an unpinned tick. A
#              pin that cannot be applied is logged as a WARN and NOT recorded as
#              requested. `dive` (roster pin `opus`, launcher tick-jailed.sh) was
#              the live instance this closes: before dotfiles-o9vi the jail
#              swallowed the pin at this same guard and every dive tick ran
#              unpinned despite a roster that claimed otherwise.
#
#              ⚠️ WARM-PANE RULE, AND WHY IT IS NOT `failed-wrong-seat`. A warm
#              pane's launcher CANNOT change model mid-flight — the process is
#              already running — so the same reuse hole --config-dir has exists
#              here, and the same read-it-from-/proc check answers it (the
#              launcher's own `--model` in /proc/<pid>/cmdline). The DECISION is
#              deliberately the other one: a mismatch is a LOGGED, RECORDED WARN
#              and the tick proceeds. The asymmetry is the point.
#                * wrong seat  = wrong BILLING + IDENTITY. Invisible everywhere
#                  (it looks like a normal tick on the wrong account), not
#                  recoverable after the fact, and refusing costs one deferred
#                  tick. Hard failure is right.
#                * wrong model = wrong QUALITY TIER. It is visible after the fact
#                  — `gen_ai_request_model` in the gateway's request_logs, which
#                  is why the ledger key below exists — and the failure direction
#                  under DEFAULT-UP/PIN-DOWN is OVER-spend, never under-think.
#                  Hard-failing would be strictly worse than the status quo it
#                  replaces: every durable pane in the fleet was launched BEFORE
#                  pins existed, so a hard gate would stall those rows
#                  indefinitely (nothing in the loop kills a warm pane) and trade
#                  "ran on the wrong tier" for "produced nothing at all".
#                * an UNVERIFIABLE warm pane (no launcher to read, unreadable
#                  /proc, or a launcher with no explicit --model) is NEVER a
#                  failure: "no --model on the cmdline" is the normal state of
#                  every pane started before this flag and of every window Zig
#                  started by hand. Conflating it with a proven mismatch is how a
#                  guard starts refusing correct panes.
#              PULSE_MODEL_ON_MISMATCH=warn (default) | fail — `fail` turns a
#              PROVEN mismatch into verdict `failed-wrong-model` (exit 77) and
#              types nothing. It exists so the ruling above can be flipped
#              without a code change, and so the warn path has a tested twin.
#              LIMIT, stated plainly: /proc/<pid>/cmdline is a LOWER BOUND on
#              truth — an in-session `/model` switch does not appear there. The
#              gateway cross-check is what closes that gap, not this.
#
#              LEDGER (additive, new key `model`): when a pin is actually applied
#              the tick appends one line to
#              $HARNESS_STATE_DIR/pulse-models.jsonl (default
#              ~/.local/state/harness/) recording the model REQUESTED, so
#              agentgateway's `gen_ai_request_model` can be cross-checked against
#              what was asked for rather than against a config read back:
#                {"ts":…,"loop":…,"session":…,"window":…,"seat":…,
#                 "model":"claude-fable-5[1m]","source":"roster|flag",
#                 "observed_model":…,"mismatch":true|false,"result":…}
#              Written ONLY when a pin was applied (so an unpinned fleet writes
#              nothing at all) and only on the paths where the tick was actually
#              delivered or refused for the model — never on a bounce/defer,
#              which produce no gateway request to join against.
#              PULSE_MODEL_MAX_LINES (default 10000) bounds it with the same
#              keep-the-newest-half atomic trim as the bounce log.
#   --fresh    OPT-IN (default OFF): warm process, COLD CONTEXT. When the pane
#              already runs the launcher, send `/clear` + Enter and settle before
#              typing the tick command, so the tick starts near the onboard floor
#              instead of re-creating the session's whole accumulated prefix.
#              Rationale (dotfiles-6ycc, ~/explore/refs/warm-session-collapse.md):
#              the prompt cache TTL is ~1h and pulse cadences are hours apart, so
#              a "warm" session buys ZERO cached tokens and pays full
#              cache-creation on everything it has accumulated. Measured on the
#              explore slug since 2026-07-01: warm resumes after a >=3h gap
#              re-create a 442,914-token median (84% of them re-create >=99% of
#              their context) against a 78,270 first-turn floor — 5.7x, and it
#              grows with session age. This decouples process liveness (keep it:
#              no relaunch race, no SessionStart re-run, scrollback survives)
#              from context accumulation (drop it). On a COLD launch --fresh is a
#              no-op: the context is already fresh and /clear would only cost a
#              round trip. /clear re-reads CLAUDE.md + the memory tier from disk
#              (verified end-to-end), so a --fresh loop cannot act on a stale
#              always-loaded snapshot.
#              PULSE_FRESH_SETTLE (default 2) = seconds to settle after /clear.
#
#              ⚠️ AND IT NEVER QUEUES BEHIND A LIVE SAME-LOOP RUN (dotfiles-t5fj,
#              measured 2026-08-09). send-keys into a 🧠 pane QUEUES by design —
#              the composer holds the text and submits it at end-of-turn — and
#              for a plain tick that is the right behaviour. For a --fresh
#              SCHEDULED tick the same design inverts: what gets queued is
#              `/clear`, so the delivery is a DELAYED CONTEXT WIPE of the run
#              that is still going, fired at whatever turn boundary comes next
#              (including an abnormal one, mid-night, with builder handles in
#              flight — the dotfiles-3135 family). Live instance: pulse-retry
#              re-fired pulse-marshal two seconds after a supervisor had already
#              injected it by hand, and `/clear` + `/marshal night` sat queued in
#              the running drain's composer. So --fresh REFUSES with verdict
#              `deferred-already-running` when the pane's current turn was
#              started by THIS loop's own tick.
#
#              THE MECHANISM, and it is deliberately not a pane-content heuristic:
#              a pane cannot prove WHOSE tick is running in it (the scrollback of
#              a warm session shows every command ever typed, and a /clear repaint
#              erases the evidence). So the injector WRITES the fact it later
#              reads — one row per DELIVERED injection to
#              $HARNESS_STATE_DIR/pulse-injections.jsonl:
#                {"ts":…,"loop":…,"session":…,"window":…,"pane":…,"fresh":0|1}
#              and "a same-loop tick is running here" is the CONJUNCTION of two
#              independent observations:
#                (a) the window's lexicon glyph says a turn is in flight (🧠 mid-
#                    turn, 🌀 compacting). ✅/bare/absent ⇒ nothing is running.
#                (b) the newest injection row for THIS loop names THIS
#                    session+window and is younger than PULSE_SAME_LOOP_TTL
#                    (default 86400s).
#              PULSE_INJECTION_MAX_LINES (default 2000) bounds the file with the
#              same keep-the-newest-half atomic trim as the bounce log.
#
#              FAILURE MODES, stated rather than hidden — and note which way each
#              one errs, because the asymmetry is the design: a FALSE "running"
#              costs one deferred tick that pulse-retry re-delivers within two
#              minutes; a FALSE "not running" is the context wipe. So every
#              unknown resolves to "running".
#                * The glyph is maintained by tmux-status.sh's hooks. A seat whose
#                  hooks are not wired shows a bare name forever, so (a) never
#                  fires and this guard cannot protect it. That is the dangerous
#                  direction and it is NOT closed here — the glyph is the only
#                  per-turn signal the harness publishes.
#                * A STALE 🧠 (a session that died mid-turn) defers a tick that
#                  could have been delivered. Safe direction; the bounce is
#                  recorded, pulse-retry polls, and pulse-escalate owns stale-glyph
#                  reconciliation.
#                * No --loop ⇒ no row identity ⇒ the guard cannot run at all, and
#                  says so in the log rather than pretending it checked.
#                * An unparseable ts on the newest row is treated as RUNNING.
#                * ⚠️ THE ONE RESIDUAL THAT ERRS THE WRONG WAY — a delivery row
#                  that could NOT BE WRITTEN (unwritable state dir, full disk).
#                  The next tick then finds no row, and "no row" means NOT
#                  running: an unknown resolving against the rule above, which
#                  replays the original incident. It cannot be fixed
#                  retroactively — the fact was never recorded, and a guard
#                  cannot refuse on evidence that does not exist — so the write
#                  failure is made LOUD instead, at the moment it is still
#                  actionable: a stderr sentence, a note() WARN, and
#                  `PULSE_INJECT_WARN=delivery-unrecorded` on stdout beside the
#                  verdict (see record_injection). What bounds the damage is NOT
#                  the TTL (that only ever shortens how long a row is believed):
#                  it is the window between the failed write and the next
#                  successful delivery row for that loop, during which the
#                  delivery signal is blind. The LEDGER signal (for a
#                  manifest-registered loop) and pulse-retry's next_fire ceiling
#                  are unaffected and still apply.
#              Only --fresh is gated. A plain tick queueing behind a live turn is
#              the composer working as designed and is left exactly as it was.
#
#              COUNTERPART: pulse-escalate.sh's "SINGLE OWNERSHIP OF THE RE-FIRE
#              DECISION" block. Escalate never re-fires; pulse-retry re-fires only
#              after re-verifying that the bounce is still live (its step 3d.5,
#              which reads the same injections file this one writes); and this
#              guard is the last line, at the pane itself.
#
# Behavior contract (tested in test-pulse-inject.sh):
#   1. No tmux server / no session  -> created detached.
#   2. No window named <window>     -> created with cwd <dir>.
#   3. Window exists, launch absent -> launch started, waited for, cmd sent.
#   4. Window exists, launch alive  -> cmd sent directly.
#   5. The window name match is lexicon-aware (✅ pulse == pulse).
#   6. --fresh + warm pane -> /clear sent BEFORE the cmd, same window.
#   7. --fresh + cold launch -> no /clear (already fresh).
#   8. --fresh never runs on a 🔔-deferred tick (the guard wins).
#   9. Readiness gate times out -> BOUNCE (record + exit 0), never a blind
#      inject into a composer that isn't there (dotfiles-mrta).
#  10. --config-dir absent -> not one byte of seat machinery runs.
#  11. --config-dir present -> the LAUNCHED process has CLAUDE_CONFIG_DIR set to
#      it (asserted from /proc, not from tmux's opinion), and a warm pane on any
#      other seat is REFUSED rather than reused.
#  12. A window that resolves to a seat with a `model:` pin -> the launcher is
#      started as `claude --model <pin>` and the request is recorded; a window
#      that resolves to no seat, or to a seat with no pin, gets NO --model and
#      writes NO record (byte-identical to the pre-pin injector).
#  13. A warm pane whose launcher provably runs a DIFFERENT --model -> logged +
#      recorded mismatch, tick proceeds (PULSE_MODEL_ON_MISMATCH=fail turns it
#      into failed-wrong-model / exit 77); an UNVERIFIABLE warm pane proceeds
#      under either setting.
#  14. --fresh into a pane whose CURRENT TURN was started by this same loop ->
#      REFUSED (deferred-already-running): no /clear, no cmd, a bounce recorded.
#      A plain (non---fresh) tick is unaffected, and so is a --fresh tick into an
#      idle pane or into a pane last delivered for a DIFFERENT loop.
#
# OUTCOME CONTRACT — PULSE_INJECT_RESULT (dotfiles-q0qi).
#
#   THE EXIT CODE CANNOT ANSWER "DID ANYTHING GET TYPED?". This script exits 0
#   on three structurally different outcomes: it really injected; it BOUNCED
#   because the composer never reported input-ready; it DEFERRED because the
#   window is 🔔-blocked on Andrew. All three are correct for /pulse (whose
#   contract is "the next timer retries") and all three are indistinguishable to
#   a caller reading only `$?` — which is exactly the fleet's #1 defect shape
#   (dotfiles-cxle, "the reporter keeps saying success"). A ONE-SHOT consumer —
#   picod's ha-portal 🛎️ button, any daemon with no next timer — has no retry to
#   paper over the difference: a deferred press is a silently dropped request.
#
#   So EVERY terminal path prints exactly ONE machine-readable line, and it is
#   the LAST line of STDOUT:
#
#     PULSE_INJECT_RESULT=injected                    the cmd was typed + Enter sent
#     PULSE_INJECT_RESULT=bounced-not-ready           readiness gate timed out; typed NOTHING
#     PULSE_INJECT_RESULT=deferred-blocked-on-human   window is 🔔-blocked; typed NOTHING
#     PULSE_INJECT_RESULT=deferred-already-running    --fresh, and the pane's current turn was
#                                                     started by THIS loop's own tick; typed
#                                                     NOTHING — queuing /clear there is a delayed
#                                                     context wipe (dotfiles-t5fj)
#     PULSE_INJECT_RESULT=failed-usage                bad/missing args (exit 64)
#     PULSE_INJECT_RESULT=failed-no-dir               --dir does not exist (exit 66)
#     PULSE_INJECT_RESULT=failed-no-tmux              tmux binary not found (exit 69)
#     PULSE_INJECT_RESULT=failed-no-session           could not create the tmux session (exit 70)
#     PULSE_INJECT_RESULT=failed-no-config-dir        --config-dir missing, or holds no credential
#                                                     — a tick there would say "Not logged in" and
#                                                     burn the window (exit 78)
#     PULSE_INJECT_RESULT=failed-wrong-seat           the live launcher in the pane runs on a
#                                                     DIFFERENT CLAUDE_CONFIG_DIR than --config-dir
#                                                     asked for; typed NOTHING (exit 77)
#     PULSE_INJECT_RESULT=failed-seat-unverifiable    --config-dir was asked for and the launcher's
#                                                     seat could not be READ; typed NOTHING (exit 77)
#     PULSE_INJECT_RESULT=failed-wrong-model          the live launcher in the pane provably runs a
#                                                     DIFFERENT --model than the pin asked for, AND
#                                                     PULSE_MODEL_ON_MISMATCH=fail; typed NOTHING
#                                                     (exit 77). UNREACHABLE by default — the
#                                                     default is warn-and-proceed, see --model.
#     PULSE_INJECT_RESULT=failed                      any other non-zero exit (crash/EXIT trap)
#
#   STREAM: STDOUT, always. note() writes only to $LOG (/tmp/pulse-inject.log) and
#   the argument guards write their prose to STDERR — neither is the verdict. A
#   consumer must capture stdout (`OUT="$(pulse-inject.sh … )"`, or `2>&1` if it
#   also wants the guard prose) and read the marker from it.
#
#   ONE NON-VERDICT MARKER SHARES THIS STREAM, and it is deliberately a different
#   key so it can never be mistaken for an outcome (dotfiles-t5fj):
#
#     PULSE_INJECT_WARN=delivery-unrecorded   the tick WAS delivered, but its row in
#                                             pulse-injections.jsonl could not be
#                                             written, so the same-loop guard and
#                                             pulse-retry's delivery signal are blind
#                                             to this tick. Printed BEFORE the verdict;
#                                             the verdict is still the last line.
#
#   A consumer that only greps `PULSE_INJECT_RESULT=` is unaffected by it, which
#   is exactly why the warning is NOT appended to the verdict line: every reader
#   of that line (this suite included) compares it for EQUALITY.
#
#   PARSING: match the literal `PULSE_INJECT_RESULT=<verdict>`; take the LAST such
#   line if you see more than one (there is exactly one per run by construction).
#   Every hard-failure verdict starts with `failed`, so `case "$v" in failed*)` is
#   a stable "this run errored" test that survives new failure verdicts.
#
#   FAIL CLOSED: exit 0 with NO marker means an OLDER injector, or a path that
#   forgot to report — treat it as NOT injected, never as success. Only
#   `injected` may set a caller's "delivered" flag. Never `pulse-inject.sh &&
#   DELIVERED=true`: that is the same defect one layer down.
#
#   EXIT CODES ARE UNCHANGED by this contract — it is purely additive, because
#   every /pulse systemd unit on the box calls this script. Consumer shape:
#   readme_push_verdict() in ~/andrewzigler3/scripts/daily-build.sh; template in
#   ~/dotfiles/agents/skills/daemon/reference/templates/verdict-contract.sh.
#
# Logs to /tmp/pulse-inject.log, one line per event, appended under an
# exclusive flock and tagged with this run's pid so simultaneous ticks
# (pulse-explore — pulse-dive after the rename flip — and pulse-di-thursday
# both fire at 13:00 UTC) stay
# attributable instead of braiding into an unreadable record — see note().
# Exit non-zero on hard failures so the systemd unit records them
# (journalctl --user -u pulse-*).

set -uo pipefail

LOG=/tmp/pulse-inject.log
# PULSE_TMUX_BIN is a TEST SEAM (same idiom as HARNESS_STATE_DIR below): it lets
# the suite point at an absent binary (exit 69) or a stub that fails (exit 70) so
# those terminal paths — and their verdict markers — are actually exercised.
# Unset (production, always) the resolution below is byte-for-byte what it was.
TMUX_BIN=${PULSE_TMUX_BIN:-}
if [ -z "$TMUX_BIN" ]; then
  TMUX_BIN=$(command -v tmux 2>/dev/null)
  [ -x "${TMUX_BIN:-}" ] || TMUX_BIN=/usr/bin/tmux
fi

SESSION="zig-computer"
WINDOW="pulse"
LAUNCH="claude"
# Process name to expect in the pane once the launcher is live (liveness/reuse
# detection). Empty => default to basename of --launch (today's behavior). A
# jailed launcher (tick-jailed.sh) execs `bwrap`, so its pane_current_command
# reads 'bwrap' not 'tick-jailed.sh' — those loops pass --launch-detect bwrap.
LAUNCH_DETECT=""
DIR=""
CMD=""
LOOP=""
FRESH=0
# The Claude seat this tick must run on (--config-dir). Empty => OFF, and every
# seat code path below is behind `[ -n "$CONFIG_DIR" ]` so the loops that do not
# ask for a seat execute exactly the instructions they executed before.
CONFIG_DIR=""
CONFIG_DIR_ABS=""
# The MODEL PIN this tick runs on (dotfiles-pulse-row-model-seat-d0bk). Empty =>
# OFF, and — exactly like CONFIG_DIR above — every model code path is behind
# `[ -n "$MODEL" ]` / `[ "$MODEL_ACTIVE" = 1 ]`, so a fleet with no pins executes
# the instructions it executed before this flag existed.
#   MODEL         the pin itself ("" = none)
#   MODEL_SOURCE  flag | roster   (provenance, for the ledger row)
#   MODEL_SEAT    the seat the roster resolved $WINDOW to ("" when --model was
#                 explicit or nothing resolved)
#   MODEL_ACTIVE  1 once `--model <pin>` is actually ON the launch string. A pin
#                 that could not be applied (non-claude launcher) is NOT active
#                 and is never recorded as requested.
MODEL=""
# The pin BEFORE canonicalisation (the roster's alias), kept only for the log
# line — the ledger, the launch string and the /proc comparison all use the
# canonical form, because that is what the process is actually started with.
MODEL_RAW=""
MODEL_SOURCE=""
MODEL_SEAT=""
MODEL_ACTIVE=0
OBSERVED_MODEL=""
MODEL_MISMATCH=0
# Test seam, same idiom as PULSE_TMUX_BIN: the seat resolver this injector asks
# for the roster pin. Production resolves it beside the script (agents/lib/);
# the suite and the mutation harness point it at the real tree because they run
# a COPY of this file from a scratch dir.
SEAT_RESOLVE_BIN=${PULSE_SEAT_RESOLVE:-"$(cd "$(dirname -- "$0")" 2>/dev/null && pwd)/../lib/seat-resolve.sh"}
# Same seam, same reason, for the ALIAS->CANONICAL table (dotfiles-lstn). Also
# invoked as a SUBPROCESS rather than sourced, for the reason resolve_model()
# gives about seat-resolve.sh: nothing this injector does not own may leak into
# its namespace and change an unpinned tick.
MODEL_CANON_BIN=${PULSE_MODEL_CANON:-"$(cd "$(dirname -- "$0")" 2>/dev/null && pwd)/../lib/model-canon.sh"}
# Bound for the model ledger, same shape + same argument as BOUNCE_MAX_LINES
# below: keep the newest HALF via an atomic rename. What it discards is the
# OLDEST rows, and the consumer is a JOIN against agentgateway's request_logs,
# whose own retention is far shorter than the 5000 rows a trim always leaves
# (~7 months at the fleet's ~24 ticks/day). Nothing reads this file in full on a
# hot path — unlike the bounce log, which harnessd re-reads on every state
# generation and which is why that cap is an order of magnitude tighter.
MODEL_MAX_LINES="${PULSE_MODEL_MAX_LINES:-10000}"
# Retention bound for the bounce log (explore-foda). It was append-only and read IN FULL
# on every harnessd state generation, so a loop bouncing on every tick while Andrew is
# away grew it without limit. Same idiom + same trim shape as the vault-sync ledger's
# VAULT_SYNC_LEDGER_MAX_LINES: over the cap, keep the newest HALF via an atomic rename,
# so a concurrent harnessd read always sees a complete file.
#
# WHAT THE BOUND DISCARDS, stated plainly: the OLDEST lines, once there are more than
# 2000. Both consumers only ever want the NEWEST record per loop — harnessd's
# _newest_bounce_by_loop / newestBounceByLoop reduce to it, and pulse-retry.sh takes the
# latest bounce ts per loop — so the only reachable loss is a loop whose newest bounce has
# been pushed out by 1000+ NEWER bounces from other loops. At the ~11 loops on this box
# that takes ~90 bounces per loop, and such a bounce is long past its own next scheduled
# fire, which is the hard TTL pulse-retry.sh already refuses to retry past. Nothing else
# reads this file: it is not history, it is a latest-state signal with a log's shape.
BOUNCE_MAX_LINES="${PULSE_BOUNCE_MAX_LINES:-2000}"   # ~160 KB; trims to the newest 1000
# Retention bound for the DELIVERY log (dotfiles-t5fj), same idiom + same trim shape as the
# bounce log and for the same reason. Both consumers want only the NEWEST row per loop — this
# script's own same-loop-running guard and pulse-retry.sh's staleness check — so what the bound
# discards (the oldest rows) is never read by either.
INJECTION_MAX_LINES="${PULSE_INJECTION_MAX_LINES:-2000}"
# How long a delivery row may still be taken as "that turn is the one running now". It exists
# only so a marker cannot become eternally load-bearing; the fleet's longest single tick is
# hours, so a day is comfortably past any real turn while still bounding a forgotten row.
SAME_LOOP_TTL="${PULSE_SAME_LOOP_TTL:-86400}"

# emit_result <verdict> — the outcome contract (see the header). ONE line, on
# STDOUT, on every terminal path.
#
# Defined BEFORE argument parsing on purpose: the very first thing that can end
# this script is `unknown arg` (exit 64), and a path that exits before the
# emitter exists is a path with no verdict — the exact hole this closes.
#
# Idempotent by design. The EXIT trap is a backstop for the paths nobody wrote
# (an unbound variable under `set -u`, a kill, a future edit that adds an exit
# and forgets the marker): it emits `failed` only when the run is ending
# non-zero AND nothing has reported yet. The guard is what keeps "exactly one
# marker per run" true rather than aspirational — without it the success path
# would print `injected` and the trap would happily print again.
INJECT_RESULT_SENT=0
emit_result() {
  [ "$INJECT_RESULT_SENT" -eq 1 ] && return 0
  INJECT_RESULT_SENT=1
  printf 'PULSE_INJECT_RESULT=%s\n' "$1"
}
# shellcheck disable=SC2317  # invoked indirectly, via `trap _on_exit EXIT` below.
_on_exit() {
  local rc=$?
  [ "$rc" -ne 0 ] && emit_result failed
  exit "$rc"
}
trap _on_exit EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)     DIR=$2; shift 2 ;;
    --cmd)     CMD=$2; shift 2 ;;
    --session) SESSION=$2; shift 2 ;;
    --window)  WINDOW=$2; shift 2 ;;
    --launch)  LAUNCH=$2; shift 2 ;;
    --launch-detect) LAUNCH_DETECT=$2; shift 2 ;;
    --loop)    LOOP=$2; shift 2 ;;
    --fresh)   FRESH=1; shift ;;
    --config-dir) CONFIG_DIR=$2; shift 2 ;;
    --model)   MODEL=$2; shift 2 ;;
    *) echo "pulse-inject: unknown arg $1" >&2; emit_result failed-usage; exit 64 ;;
  esac
done

# Append one log line ATOMICALLY (dotfiles-0lm3). Two guarantees, both needed:
#
#  1. `flock` on the log fd serializes writers, so a line is never torn in half
#     by a simultaneous tick. (The bare `echo >>` this replaces relied on the
#     kernel's O_APPEND write being one syscall — true in practice for short
#     lines, but not a contract, and the `caller:` line carries two 160-char
#     cmdlines.)
#  2. The `[pid]` tag makes a RECORD reconstructable. This is the half a plain
#     flock does NOT fix and the one that actually bit: the observed damage was
#     never torn lines, it was interleaved *whole* lines — `pulse-explore` and
#     `pulse-di-thursday` fire at the same second, so their tick/caller/injected
#     lines braid and a per-tick reader attributes the wrong body to the wrong
#     header. Nine ticks read as "fired, no row" that way, which is exactly the
#     condition the stale-loop detector (harnessd-h14z) alerts on — i.e. the
#     unsynchronized log manufactures false alarms for a detector that has
#     already been silenced once. Grouping by pid de-braids them.
#
# Format stays `<utc-ts> <fields>` with the tag inserted after the timestamp, so
# existing greps (`grep ' tick: '`, `grep 'launched '`) are unaffected.
# If `flock` is unavailable the write still goes to the same O_APPEND fd —
# degraded, never lost.
#
# $BASHPID, not $$: bash does NOT update $$ inside a subshell, so two writers
# forked from one parent would share a tag and re-braid. Production always runs
# this as its own process (where they agree), but the tag must be right in every
# caller shape or the de-braiding is silently a no-op. Fallback for non-bash.
note() {
  { flock -w 5 9 2>/dev/null
    printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${BASHPID:-$$}" "$*" >&9
  } 9>>"$LOG"
}

# record_bounce <reason>
#   A tick that did NOT get delivered must leave a machine-readable trace, or
#   it is indistinguishable from one that never fired — the "fired but no
#   ledger row" class the stale-loop detector (harnessd-h14z) alerts on.
#   Written where the state bus reads it, so the tick renders 'bounced'
#   instead of a false 'tick in flight' (harnessd-gf6).
#
#   Loop-scoped: only when --loop was passed (units pass `--loop %p`).
#   Best-effort and must NEVER fail the caller's exit 0 — a bounce that can't
#   be recorded is still a bounce, and losing the injector on top of it would
#   be strictly worse. The retention trim inherits that rule: it is appended
#   AFTER the write, guarded, and its failure is silent (see BOUNCE_MAX_LINES).
record_bounce() {
  local reason=$1
  [ -n "$LOOP" ] || return 0
  local _bdir="${HARNESS_STATE_DIR:-$HOME/.local/state/harness}"   # override for tests
  local _bfile="$_bdir/pulse-bounces.jsonl"
  { mkdir -p "$_bdir" 2>/dev/null \
    && printf '{"ts":"%s","loop":"%s","reason":"%s"}\n' \
         "$(date -u +%FT%TZ)" "$LOOP" "$reason" >> "$_bfile" 2>/dev/null ; } \
    || note "bounce-record failed for loop '$LOOP' (reason=$reason, non-fatal)"
  # Bounded growth: over the cap, keep the newest half via an atomic rename (mv), so a
  # concurrent harnessd read never observes a truncated file. The trim runs only on a
  # bounce — a rare path — so the wc is free in practice. Runs LAST so a trim failure
  # can never cost the record itself.
  local _lines
  _lines=$(wc -l < "$_bfile" 2>/dev/null || echo 0)
  if [ "${_lines:-0}" -gt "$BOUNCE_MAX_LINES" ] 2>/dev/null; then
    tail -n $((BOUNCE_MAX_LINES / 2)) "$_bfile" > "$_bfile.tmp" 2>/dev/null \
      && mv -f "$_bfile.tmp" "$_bfile" 2>/dev/null \
      && note "bounce log trimmed to the newest $((BOUNCE_MAX_LINES / 2)) lines (was $_lines)"
  fi
}

# --------------------------------------------------------------------------
# DELIVERY LOG + THE SAME-LOOP-RUNNING GUARD (dotfiles-t5fj). See --fresh in the
# header for the decision record and the failure modes; this is the mechanism.
# --------------------------------------------------------------------------
#
# record_injection — ONE row per DELIVERED injection, written where the harness
# state already lives. This is the fact nothing else on the box records: a bounce
# proves a tick did NOT land, a ledger row proves a tick FINISHED, and between
# them sits "this loop was typed into this pane at this time", which is exactly
# what both the guard below and pulse-retry.sh's staleness check need.
#
# Loop-scoped (only with --loop). NON-FATAL, like record_bounce — the tick has
# already been delivered by the time this runs, so failing the caller here would
# turn a successful tick into a reported failure — but deliberately NOT SILENT.
#
# ⚠️ WHY A FAILED WRITE IS LOUD (dotfiles-t5fj, adversarial review). This row is
# the ONLY evidence that this tick was delivered. If it is missing, the next
# --fresh tick's guard reads "this injector has never recorded a delivery for
# this loop" and PROCEEDS — an unknown resolving to NOT-running, which is the one
# direction the guard's whole design forbids, and it replays the original
# incident exactly. Nothing downstream can recover that: the fact was never
# written. So the failure is reported three ways (stderr sentence, note(), and a
# machine-readable PULSE_INJECT_WARN line) at the moment it is still actionable,
# rather than surfacing later as a context wipe with no trail.
record_injection() {
  [ -n "$LOOP" ] || return 0
  local _idir="${HARNESS_STATE_DIR:-$HOME/.local/state/harness}"   # override for tests
  local _ifile="$_idir/pulse-injections.jsonl"
  local _err
  # stderr is CAPTURED, not discarded: the message names WHY the state dir is
  # unusable, and that sentence is the whole value of making this loud.
  if ! _err=$( { mkdir -p "$_idir" \
      && printf '{"ts":"%s","loop":"%s","session":"%s","window":"%s","pane":"%s","fresh":%s}\n' \
           "$(date -u +%FT%TZ)" "$LOOP" "$SESSION" "$WINDOW" "$PANE" "$FRESH" >> "$_ifile" ; } 2>&1 ); then
    echo "pulse-inject: WARNING — the tick WAS delivered to $PANE, but its delivery row could NOT be written to $_ifile (${_err:-no message}). Until a later delivery for '$LOOP' lands, this injector's own --fresh same-loop guard and pulse-retry's delivery signal are BLIND to this tick: a re-fire could queue /clear behind it. Fix the state dir." >&2
    note "WARN: delivery row NOT recorded for loop '$LOOP' (${_err:-no message}) — the same-loop guard and pulse-retry's delivery signal cannot see this tick"
    # A DISTINCT prefix, never fused into the verdict line. The outcome contract
    # is `PULSE_INJECT_RESULT=<verdict>` matched literally, and every consumer
    # (including this suite) compares that line for EQUALITY — appending to it
    # would break every parser to report a warning. A separate marker is
    # additive: it cannot match the verdict regex, and the verdict stays last.
    printf 'PULSE_INJECT_WARN=delivery-unrecorded\n'
    return 0
  fi
  local _lines
  _lines=$(wc -l < "$_ifile" 2>/dev/null || echo 0)
  if [ "${_lines:-0}" -gt "$INJECTION_MAX_LINES" ] 2>/dev/null; then
    tail -n $((INJECTION_MAX_LINES / 2)) "$_ifile" > "$_ifile.tmp" 2>/dev/null \
      && mv -f "$_ifile.tmp" "$_ifile" 2>/dev/null \
      && note "injection log trimmed to the newest $((INJECTION_MAX_LINES / 2)) lines (was $_lines)"
  fi
}

# _inject_field <line> <key> — pull a "key":"value" out of one flat row. Same
# fixed-shape sed as pulse-retry.sh's json_field, and safe for the same reason:
# these rows are written by this script, not by an arbitrary producer.
_inject_field() { printf '%s' "$1" | sed -n -E "s/.*\"$2\":\"([^\"]*)\".*/\1/p"; }

# _last_injection — the newest delivery row for $LOOP, or empty. The file is
# append-only, so the LAST matching line is the newest (the same assumption
# pulse-ledger-watch.sh makes about a ledger's rows).
_last_injection() {
  local _f="${HARNESS_STATE_DIR:-$HOME/.local/state/harness}/pulse-injections.jsonl"
  # The readability guard is what makes an unsuppressed grep safe: an absent file
  # is answered before grep runs, so any stderr it does produce is a real error
  # and belongs in the log rather than in /dev/null.
  [ -r "$_f" ] || return 0
  grep -F "\"loop\":\"$LOOP\"" "$_f" 2>>"$LOG" | tail -n1
}

# _turn_in_flight <window-name> — does the lexicon say a turn is running in this
# window? 🧠 = mid-turn, 🌀 = compacting. ✅, a bare name, and 🔔 (handled by its
# own guard, earlier and separately) all mean no turn is in flight.
_turn_in_flight() {
  [ "$1" != "${1#🧠}" ] && return 0
  [ "$1" != "${1#🌀}" ] && return 0
  return 1
}

# _same_loop_running <window-name> — rc 0 iff the pane's CURRENT turn was started
# by this loop's own tick. Both observations must hold; see the header for why
# every unknown answers "running" instead of "not running".
_same_loop_running() {
  local _win_name=$1 _row _ts _sess _win _epoch _age
  _turn_in_flight "$_win_name" || return 1
  _row=$(_last_injection)
  if [ -z "$_row" ]; then
    note "same-loop check: window '$_win_name' is mid-turn but this injector has never recorded a delivery for loop '$LOOP' — that turn is not provably ours, proceeding"
    return 1
  fi
  _ts=$(_inject_field "$_row" ts)
  _sess=$(_inject_field "$_row" session)
  _win=$(_inject_field "$_row" window)
  if [ "$_sess" != "$SESSION" ] || [ "$_win" != "$WINDOW" ]; then
    note "same-loop check: loop '$LOOP' was last delivered to ${_sess:-?}:${_win:-?}, not $SESSION:$WINDOW — the turn running here belongs to something else, proceeding"
    return 1
  fi
  # Shape-check BEFORE date(1), so an unusable stamp is a decision this function
  # makes rather than an error it swallows.
  case "$_ts" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
    *)
      note "same-loop check: newest delivery row for '$LOOP' has ts '${_ts:-<none>}', not YYYY-MM-DDTHH:MM:SSZ — treating the live turn as OURS (an unreadable marker must never read as 'nothing is running')"
      return 0 ;;
  esac
  _epoch=$(date -u -d "$_ts" +%s)
  _age=$(( $(date +%s) - _epoch ))
  if [ "$_age" -gt "$SAME_LOOP_TTL" ]; then
    note "same-loop check: this loop's last delivery here was ${_age}s ago, past the ${SAME_LOOP_TTL}s TTL — the live turn is too old to still be that tick, proceeding"
    return 1
  fi
  note "same-loop check: window '$_win_name' is mid-turn and loop '$LOOP' was delivered to $SESSION:$WINDOW at $_ts (${_age}s ago) — that turn is OURS"
  return 0
}

# --------------------------------------------------------------------------
# SEAT VERIFICATION (--config-dir). Only ever called when --config-dir was
# passed; see the header for why the env cannot be trusted to arrive on its own.
# --------------------------------------------------------------------------
#
# _pane_launcher_pid — the pid of the process tmux is reporting as
# #{pane_current_command}, i.e. the pane's FOREGROUND process-group leader.
#
# Three tempting-but-wrong alternatives, all measured on this box (tmux 3.6):
#
#   * #{pane_pid} is the pane's SHELL, not the launcher — and /proc/<pid>/environ
#     is a snapshot taken at exec, so the `export` we type into that shell is
#     INVISIBLE there. Reading the shell's environ would report "unset" for a
#     correctly-seated pane: a guard that fails on the good case.
#   * matching on /proc/<pid>/comm diverges from tmux: a shebang script run
#     directly has comm `stub.sh` while pane_current_command says `bash`.
#   * `tmux show-environment` answers about the SESSION environment, which is a
#     filtered copy and reported `unknown variable` for a pane that demonstrably
#     had the variable. It is not the process's environment.
#
# The `+` in ps's stat field marks the foreground process group, and the leader
# is the member whose pid == pgid — exactly the process tmux names. When the
# pane is IDLE that leader is the shell itself (pid == pane_pid), which is the
# correct "no launcher is running here" answer, so it is rejected explicitly.
_pane_launcher_pid() {
  local tty ppid fg
  tty=$("$TMUX_BIN" display-message -p -t "$PANE" '#{pane_tty}' 2>/dev/null)
  ppid=$("$TMUX_BIN" display-message -p -t "$PANE" '#{pane_pid}' 2>/dev/null)
  [ -n "$tty" ] || return 1
  # Pure read; an absent tty yields empty output, which is handled below.
  fg=$(ps -o pid=,pgid=,stat= -t "${tty#/dev/}" 2>/dev/null \
       | awk '$3 ~ /\+/ && $1 == $2 { print $1 }' | tail -n1)
  case "$fg" in ''|*[!0-9]*) return 1 ;; esac
  [ "$fg" = "$ppid" ] && return 1     # the shell is in the foreground: no launcher
  printf '%s\n' "$fg"
}

# _proc_config_dir <pid> — that process's CLAUDE_CONFIG_DIR, from its own
# environment. Empty output + rc 0 means "the variable is not set" (which IS the
# personal seat, and is a mismatch, not an error). rc 1 means "could not read",
# which is a different outcome and gets a different verdict.
_proc_config_dir() {
  [ -r "/proc/$1/environ" ] || return 1
  tr '\0' '\n' < "/proc/$1/environ" | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | head -n1
  return 0
}

# assert_seat <context> — REFUSE to proceed unless the launcher live in $PANE is
# provably running on $CONFIG_DIR_ABS. Never returns on a mismatch: it emits the
# verdict and exits non-zero, because the alternative — proceeding — is the
# silent wrong-seat tick this flag exists to prevent (dotfiles-nnmm), and a
# LinearB row billing Zig's personal subscription is exactly the thing that
# would never show up as an error anywhere.
assert_seat() {
  local ctx=$1 pid seen canon
  if ! pid=$(_pane_launcher_pid); then
    echo "pulse-inject: --config-dir $CONFIG_DIR_ABS asked for, but no launcher process could be found in $PANE to verify its seat ($ctx)" >&2
    note "FAIL: seat unverifiable ($ctx): no foreground launcher in pane $PANE"
    emit_result failed-seat-unverifiable
    exit 77
  fi
  if ! seen=$(_proc_config_dir "$pid"); then
    echo "pulse-inject: --config-dir $CONFIG_DIR_ABS asked for, but /proc/$pid/environ is unreadable — cannot prove which Claude seat is running ($ctx)" >&2
    note "FAIL: seat unverifiable ($ctx): /proc/$pid/environ unreadable"
    emit_result failed-seat-unverifiable
    exit 77
  fi
  canon=""
  if [ -n "$seen" ]; then
    canon=$(cd "$seen" 2>/dev/null && pwd -P) || canon="$seen"
  fi
  if [ "$canon" != "$CONFIG_DIR_ABS" ]; then
    echo "pulse-inject: WRONG SEAT ($ctx). Pane $PANE runs pid $pid on CLAUDE_CONFIG_DIR=${seen:-<unset — the DEFAULT/personal seat>}, but --config-dir asked for $CONFIG_DIR_ABS. Refusing to inject: this tick would bill and attribute to the wrong Claude account. Kill that window's session (or exit the launcher) and let the next tick launch it on the right seat." >&2
    note "FAIL: wrong seat ($ctx): pane $PANE pid $pid has '${seen:-<unset>}', wanted '$CONFIG_DIR_ABS'"
    emit_result failed-wrong-seat
    exit 77
  fi
  note "seat verified ($ctx): pane $PANE pid $pid on CLAUDE_CONFIG_DIR=$canon"
}

# --------------------------------------------------------------------------
# MODEL PIN (--model / agents/seats.yml). See the --model block in the header
# for the decision record; this section is the mechanism.
# --------------------------------------------------------------------------
#
# record_model <result> — the ledger row (new key `model`). ONE line, appended
# where the harness state already lives, ONLY when a pin was actually applied,
# so an unpinned fleet writes nothing at all and the file's mere existence means
# "pins are live here". Best-effort like record_bounce: a ledger that cannot be
# written must never cost the tick.
#
# It records what was REQUESTED, deliberately — the whole point is to have
# something independent to cross-check agentgateway's `gen_ai_request_model`
# against. Reading the model back out of a config file would only prove the
# config, which is the mistake the seat work already paid for.
record_model() {
  local result=$1
  [ "$MODEL_ACTIVE" = 1 ] || return 0
  local _mdir="${HARNESS_STATE_DIR:-$HOME/.local/state/harness}"   # override for tests
  local _mfile="$_mdir/pulse-models.jsonl"
  local _mm=false
  [ "$MODEL_MISMATCH" = 1 ] && _mm=true
  { mkdir -p "$_mdir" 2>/dev/null \
    && printf '{"ts":"%s","loop":"%s","session":"%s","window":"%s","seat":"%s","model":"%s","source":"%s","observed_model":"%s","mismatch":%s,"result":"%s"}\n' \
         "$(date -u +%FT%TZ)" "$LOOP" "$SESSION" "$WINDOW" "$MODEL_SEAT" \
         "$MODEL" "$MODEL_SOURCE" "$OBSERVED_MODEL" "$_mm" "$result" >> "$_mfile" 2>/dev/null ; } \
    || note "model-record failed (model=$MODEL result=$result, non-fatal)"
  local _lines
  _lines=$(wc -l < "$_mfile" 2>/dev/null || echo 0)
  if [ "${_lines:-0}" -gt "$MODEL_MAX_LINES" ] 2>/dev/null; then
    tail -n $((MODEL_MAX_LINES / 2)) "$_mfile" > "$_mfile.tmp" 2>/dev/null \
      && mv -f "$_mfile.tmp" "$_mfile" 2>/dev/null \
      && note "model ledger trimmed to the newest $((MODEL_MAX_LINES / 2)) lines (was $_lines)"
  fi
}

# resolve_model — decide THIS tick's pin, before any tmux window is touched.
#
# Precedence: an explicit --model wins outright (it is the operator saying so on
# this invocation); otherwise the ROSTER is asked, via agents/lib/seat-resolve.sh
# — the merged resolver, invoked as a subprocess rather than sourced so nothing
# it defines can leak into this script's namespace or change an unpinned tick.
# There is exactly ONE roster parser on this box and it is not here.
#
# Every failure is "no pin", never a guess and never a hard stop: an
# unregistered window, a missing roster, a resolver refusal (R7 session
# mismatch), or a seat with no `model:` all land on today's behaviour.
resolve_model() {
  if [ -n "$MODEL" ]; then
    MODEL_SOURCE=flag
  else
    [ -f "$SEAT_RESOLVE_BIN" ] || {
      note "model: no pin — seat resolver not found at $SEAT_RESOLVE_BIN (behaving as before)"
      return 0
    }
    local _out _rc _errf
    _errf="${TMPDIR:-/tmp}/pulse-inject-seat.$$"
    # stderr is CAPTURED, not discarded: a roster parse error is exactly the
    # thing that must not read as "this window has no pin" with no explanation.
    _out=$(bash "$SEAT_RESOLVE_BIN" --quiet --window "$WINDOW" --session "$SESSION" 2>"$_errf")
    _rc=$?
    [ -s "$_errf" ] && note "  seat-resolve: $(tr '\n' ' ' < "$_errf")"
    rm -f "$_errf"
    if [ "$_rc" -ne 0 ]; then
      note "model: no pin — window '$WINDOW' did not resolve to a seat (seat-resolve rc=$_rc); behaving as before"
      return 0
    fi
    MODEL_SEAT=$(printf '%s\n' "$_out" | awk -F= '$1=="seat"{print $2; exit}')
    MODEL=$(printf '%s\n' "$_out" | awk -F= '$1=="model"{print $2; exit}')
    if [ -z "$MODEL" ]; then
      note "model: no pin — seat '${MODEL_SEAT:-?}' (window '$WINDOW') declares no model: in the roster; behaving as before"
      return 0
    fi
    MODEL_SOURCE=roster
  fi

  # CANONICALISE (dotfiles-lstn). The roster's vocabulary is the ALIAS —
  # `fable`/`opus`/`sonnet`/`haiku`, which is what validate-seats.py's
  # KNOWN_MODELS gates and what the hall's court view shows — but an alias on a
  # LAUNCH STRING silently drops the 1M context window: `claude --model fable`
  # and `claude --model claude-fable-5` both run Fable 5 at 200,000 tokens, and
  # only `claude-fable-5[1m]` gets 1,000,000 (measured; the table and its
  # evidence live in agents/lib/model-canon.sh). Alias resolution is also
  # PROVIDER-dependent — the client's catalog maps `opus` to a different model
  # id per provider — so a full id is the only launch argument that means one
  # thing everywhere. The roster keeps the short name; the boundary names the
  # literal, so the long id lives in exactly one file.
  #
  # A missing table is a WARN and a passthrough, never a refusal: an injector
  # that stops pinning because a sibling file moved would take the whole fleet
  # off its pins at once, which is strictly worse than the 200k it would avoid.
  MODEL_RAW="$MODEL"
  if [ -f "$MODEL_CANON_BIN" ]; then
    _mcanon=$(bash "$MODEL_CANON_BIN" canon "$MODEL")
    if [ -n "$_mcanon" ] && [ "$_mcanon" != "$MODEL" ]; then
      note "model: canonicalised '$MODEL' -> '$_mcanon' (alias/bare ids drop the extended context window)"
      MODEL="$_mcanon"
    fi
  else
    note "WARN: model canon table not found at $MODEL_CANON_BIN — pinning '$MODEL' verbatim, which for a bare alias is the 200k context window (dotfiles-lstn)"
  fi

  # The pin is about to be TYPED INTO A SHELL as part of the launch string, so it
  # is validated as a token before it goes anywhere near send-keys. seats.yml is
  # gated by validate-seats.py at commit time, but this injector must not depend
  # on a data file's other gate for its own shell safety — a hand-edited roster
  # or a --model from a script is the same keystroke sequence either way.
  #
  # The ONE tag allowed through is a trailing `[1m]`, stripped before the
  # bare-token test rather than folded into the character class — `[` and `]`
  # inside a shell bracket expression is exactly the sort of quoting puzzle that
  # produces a guard nobody can read and everybody trusts. So the accepted
  # grammar is precisely `<bare-token>` or `<bare-token>[1m]`, and a pin like
  # `sonnet$(touch /tmp/pwn)` is refused the same as before.
  case "${MODEL%'[1m]'}" in
    *[!A-Za-z0-9._-]*|"")
      note "WARN: refusing model pin '$MODEL' (source=$MODEL_SOURCE) — not a bare [A-Za-z0-9._-] token with an optional [1m] tag, and it would be typed into a shell. No pin applied."
      MODEL=""; MODEL_SOURCE=""; MODEL_SEAT=""
      return 0 ;;
  esac
  note "model: pin '$MODEL' (source=$MODEL_SOURCE${MODEL_SEAT:+ seat=$MODEL_SEAT}${MODEL_RAW:+ roster=$MODEL_RAW} window=$WINDOW)"
}

# _proc_model <pid> — the `--model <x>` / `--model=<x>` that process was STARTED
# with, from its own cmdline. Empty output + rc 0 means "no explicit --model",
# which is NOT a mismatch (see the header): it is the normal state of every pane
# launched before pins existed. rc 1 means "could not read", a different outcome.
#
# cmdline, not environ, because the pin travels as an ARGUMENT: the identity
# wrapper's `claude()` function passes "$@" through to `command claude`, so the
# flag survives into the real binary's argv. It is a LOWER BOUND on truth — an
# in-session `/model` switch never appears here — and the gateway cross-check,
# not this, is what closes that gap.
_proc_model() {
  [ -r "/proc/$1/cmdline" ] || return 1
  tr '\0' '\n' < "/proc/$1/cmdline" | awk '
    prev == "--model" { print; exit }
    /^--model=/       { sub(/^--model=/, ""); print; exit }
                      { prev = $0 }'
  return 0
}

# verify_model <context> — read the launcher's effective model where it is
# verifiable and RECORD the comparison. Unlike assert_seat this returns on a
# mismatch by default: wrong model is a quality tier, not a billing identity,
# and the header carries the full argument. PULSE_MODEL_ON_MISMATCH=fail is the
# escape hatch that turns a PROVEN mismatch into a refusal.
verify_model() {
  local ctx=$1 pid seen
  if ! pid=$(_pane_launcher_pid); then
    note "model: unverifiable ($ctx): no foreground launcher in pane $PANE — proceeding on pin '$MODEL'"
    return 0
  fi
  if ! seen=$(_proc_model "$pid"); then
    note "model: unverifiable ($ctx): /proc/$pid/cmdline unreadable — proceeding on pin '$MODEL'"
    return 0
  fi
  OBSERVED_MODEL="$seen"
  if [ -z "$seen" ]; then
    note "model: unverifiable ($ctx): pane $PANE pid $pid was started with no explicit --model (it inherits the machine default) — proceeding on pin '$MODEL'"
    return 0
  fi
  if [ "$seen" = "$MODEL" ]; then
    note "model verified ($ctx): pane $PANE pid $pid runs --model $seen"
    return 0
  fi
  MODEL_MISMATCH=1
  # SAME MODEL, DIFFERENT WINDOW is a real and, at rollout, the COMMON case
  # (dotfiles-lstn): every durable pane launched before canonicalisation carries
  # a bare `--model sonnet` on its cmdline while the pin now asks for
  # `claude-sonnet-5[1m]`. That IS a mismatch — 200k vs 1M — and it is
  # deliberately not normalised away, because normalising it is exactly how the
  # 200k form went unnoticed for hours on 2026-08-09. What it gets instead is a
  # sentence that says which kind of mismatch it is, so an operator reading the
  # log is not left thinking the pane is on the wrong TIER.
  local _why=""
  if [ -f "$MODEL_CANON_BIN" ] && [ "$(bash "$MODEL_CANON_BIN" canon "$seen")" = "$MODEL" ]; then
    _why=" SAME MODEL, DIFFERENT CONTEXT WINDOW: '$seen' is the 200k form of the pin '$MODEL' (the [1m] tag is what selects the 1M window). That pane was launched before the canonical pin, or by hand; exiting its session lets the next tick relaunch it pinned."
  fi
  if [ "${PULSE_MODEL_ON_MISMATCH:-warn}" = fail ]; then
    echo "pulse-inject: MODEL MISMATCH ($ctx). Pane $PANE runs pid $pid on --model $seen, but the pin asked for --model $MODEL.$_why PULSE_MODEL_ON_MISMATCH=fail, so nothing was typed. A warm launcher cannot change model mid-flight: exit that window's session and let the next tick launch it on the pinned model." >&2
    note "FAIL: wrong model ($ctx): pane $PANE pid $pid runs '$seen', wanted '$MODEL' (PULSE_MODEL_ON_MISMATCH=fail)"
    record_model failed-wrong-model
    emit_result failed-wrong-model
    exit 77
  fi
  echo "pulse-inject: MODEL MISMATCH ($ctx). Pane $PANE runs pid $pid on --model $seen, but the pin asked for --model $MODEL.$_why Proceeding on the warm launcher (a running launcher cannot change model mid-flight); the mismatch is recorded in the model ledger and is visible as gen_ai_request_model in the gateway's request_logs. Exit that window's session to let the next tick launch it pinned." >&2
  note "WARN: wrong model ($ctx): pane $PANE pid $pid runs '$seen', wanted '$MODEL' — proceeding (recorded)"
  return 0
}

if [ -z "$DIR" ] || [ -z "$CMD" ]; then
  echo "pulse-inject: --dir and --cmd are required" >&2
  emit_result failed-usage
  exit 64
fi
[ -d "$DIR" ] || { echo "pulse-inject: --dir $DIR does not exist" >&2; note "FAIL: dir missing: $DIR"; emit_result failed-no-dir; exit 66; }
[ -x "$TMUX_BIN" ] || { echo "pulse-inject: tmux not found" >&2; emit_result failed-no-tmux; exit 69; }

# Seat preflight — AT DISPATCH, before any tmux window is touched. A config dir
# that is absent or holds no credential does not fail: Claude Code cheerfully
# starts there and reports "Not logged in · Please run /login" (measured
# 2026-07-28 during the tick-jail work, which is how ~/.claude-tick was built).
# That is a tick that burns its window, produces nothing, and writes no ledger
# row — the "fired but no ledger row" shape again. Catching it here costs one
# stat and turns a mystery into a sentence with the login command in it.
if [ -n "$CONFIG_DIR" ]; then
  if [ ! -d "$CONFIG_DIR" ]; then
    echo "pulse-inject: --config-dir $CONFIG_DIR does not exist. Create the seat and log in first:  mkdir -p -m 700 $CONFIG_DIR && CLAUDE_CONFIG_DIR=$CONFIG_DIR claude   (then /login)" >&2
    note "FAIL: config-dir missing: $CONFIG_DIR"
    emit_result failed-no-config-dir
    exit 78
  fi
  CONFIG_DIR_ABS=$(cd "$CONFIG_DIR" 2>/dev/null && pwd -P) || CONFIG_DIR_ABS="$CONFIG_DIR"
  # Empty DISABLES the check, same idiom as PULSE_READY_MARKER. It is the escape
  # hatch for a Claude Code that moves its credential store (macOS already uses
  # the Keychain), so a storage change degrades to "unverified seat" rather than
  # to "every LinearB row bounces".
  CRED_FILE=${PULSE_CONFIG_CRED_FILE-.credentials.json}
  if [ -n "$CRED_FILE" ] && [ ! -s "$CONFIG_DIR_ABS/$CRED_FILE" ]; then
    echo "pulse-inject: --config-dir $CONFIG_DIR_ABS holds no credential ($CRED_FILE). A tick there would run 'Not logged in' and burn the window. Log in on that seat first:  CLAUDE_CONFIG_DIR=$CONFIG_DIR_ABS claude   (then /login)" >&2
    note "FAIL: config-dir has no credential: $CONFIG_DIR_ABS/$CRED_FILE"
    emit_result failed-no-config-dir
    exit 78
  fi
  note "seat requested: CLAUDE_CONFIG_DIR=$CONFIG_DIR_ABS"
fi

# Model pin — resolved AT DISPATCH, beside the seat preflight and for the same
# reason: it is a property of the row, decided before any window is touched, and
# a roster lookup must not depend on tmux being reachable. Nothing here can fail
# the tick; the worst case is "no pin", which is what every row does today.
resolve_model

# Hand the tick an ABSOLUTE project anchor. A long-lived pulse session's
# shell cwd can drift (a stray `cd` in one tick persists), so a bare
# relative `refs/pulse-ledger.jsonl` in the next tick silently resolves
# against another project — crossing ledgers. Only this injector knows the
# canonical --dir, so append it to every /pulse command; the /pulse skill
# anchors refs/pulse.md + refs/pulse-ledger.jsonl to this absolute path.
ABS_DIR=$(cd "$DIR" 2>/dev/null && pwd -P) || ABS_DIR="$DIR"
case "$CMD" in
  /pulse|/pulse\ *) CMD="$CMD $ABS_DIR" ;;
esac

note "tick: session=$SESSION window=$WINDOW dir=$DIR cmd=$CMD"
# Caller provenance (diagnostic): who invoked this injector? A systemd unit
# leaves a journal trail; a self-scheduling loop (the /pulse anti-pattern) does
# not, so log the parent + grandparent so a ghost cadence can be traced.
_pcmd() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | cut -c1-160; }
_gpid=$(awk '{print $4}' "/proc/$PPID/stat" 2>/dev/null)
note "  caller: ppid=$PPID ($(ps -o comm= -p "$PPID" 2>/dev/null)) [$(_pcmd "$PPID")] gpid=${_gpid:-?} ($(ps -o comm= -p "${_gpid:-0}" 2>/dev/null)) [$(_pcmd "${_gpid:-0}")]"

# 1. Ensure the session exists (detached creation survives reboots —
#    the window is there when Andrew attaches).
if ! "$TMUX_BIN" has-session -t "=$SESSION" 2>/dev/null; then
  "$TMUX_BIN" new-session -d -s "$SESSION" -c "$DIR" \
    || { note "FAIL: cannot create session"; emit_result failed-no-session; exit 70; }
  note "created session $SESSION (detached)"
fi

# 2. Find the dedicated window, lexicon-aware: the tmux-status hook
#    prefixes 🧠/✅/🔔/🌀, so "✅ pulse" must match "pulse".
strip_lexicon() { printf '%s' "$1" | sed -E 's/^(🧠|✅|🔔|🌀) ?//'; }

WIN_ID=""
while IFS=$'\t' read -r id name; do
  if [ "$(strip_lexicon "$name")" = "$WINDOW" ]; then
    WIN_ID=$id
    break
  fi
done < <("$TMUX_BIN" list-windows -t "=$SESSION" -F $'#{window_id}\t#{window_name}' 2>/dev/null)

if [ -z "$WIN_ID" ]; then
  WIN_ID=$("$TMUX_BIN" new-window -d -P -F '#{window_id}' -t "=$SESSION" -n "$WINDOW" -c "$DIR")
  note "created window $WINDOW ($WIN_ID)"
fi

PANE="$WIN_ID.0"

# 3. Ensure the launch program is running in the pane.
LAUNCH_BASE=$(basename "${LAUNCH%% *}")

# is_claude_launcher <basename> — true iff LAUNCH_BASE names a program the
# --model splice may safely rewrite (dotfiles-o9vi). Two members, both proven
# by reading the source they run, never assumed:
#   * `claude`         — the real binary; the flag is its own documented arg.
#   * `tick-jailed.sh` — tools/tick-jail/tick-jailed.sh's LAST line is
#     `exec bwrap ${BWRAP_ARGS[@]} -- claude --dangerously-skip-permissions
#     "$@"`, i.e. it forwards its own argv VERBATIM into the inner claude's
#     argv. `--model <pin>` typed onto the launch string therefore arrives as
#     one of tick-jailed.sh's OWN "$@" and rides that exec straight through —
#     it is never interpreted by tick-jailed.sh or by bwrap itself (bwrap only
#     sees the flags BWRAP_ARGS names, plus whatever follows the script's own
#     literal `--`).
# Deliberately NOT a wildcard/pattern match: only launchers this file has
# verified forward their argv belong here. Adding a third one means reading
# its source the same way and saying so in this comment, not loosening the
# case pattern.
is_claude_launcher() {
  case "$1" in
    claude|tick-jailed.sh) return 0 ;;
    *) return 1 ;;
  esac
}

# 3.1 Splice the model pin into the LAUNCH STRING — the same delivery the seat
#     gets, for the same reason: what a launched process was actually started
#     with is verifiable from /proc, and an ambient env is not (see the header).
#     Guarded by is_claude_launcher(), NOT the bare `claude` check the wrapper
#     re-source below still uses (that guard is unrelated — see its own
#     comment) — tick-jailed.sh is proven to forward the flag, so it is
#     admitted here; an unproven launcher would take `--model` as its own
#     argument and the splice must not risk that blindly.
#
#     SINGLE-QUOTED, ALWAYS (dotfiles-lstn). The canonical id carries a `[1m]`
#     tag and the launch string is TYPED INTO A SHELL — an unquoted
#     `claude-fable-5[1m]` is a GLOB (a one-character class matching `1` or
#     `m`), and this fleet's shell is zsh, where a glob that matches nothing is
#     a hard error: the whole launch line dies with `no matches found` and the
#     pane never starts a launcher at all. Quoting unconditionally rather than
#     only-when-tagged keeps one code path; resolve_model() has already proven
#     the pin is `<bare-token>` or `<bare-token>[1m]`, so it can contain no
#     single quote and the quoting cannot be escaped out of.
if [ -n "$MODEL" ]; then
  if is_claude_launcher "$LAUNCH_BASE"; then
    LAUNCH="$LAUNCH --model '$MODEL'"
    MODEL_ACTIVE=1
    note "model: launch string pinned -> $LAUNCH"
  else
    note "WARN: model pin '$MODEL' (source=$MODEL_SOURCE) NOT applied — launcher '$LAUNCH_BASE' is not a recognized claude launcher. The tick runs on the launcher's own model; nothing is recorded as requested."
  fi
fi
# EXPECT = the process name that means "the launcher is live in this pane".
# Defaults to the launcher basename; jailed loops override via --launch-detect
# (pane_current_command reads 'bwrap' under tick-jailed.sh, so without this a
# warm jailed session is never recognized and every tick re-types junk).
EXPECT="${LAUNCH_DETECT:-$LAUNCH_BASE}"
CURRENT_CMD=$("$TMUX_BIN" display-message -p -t "$PANE" '#{pane_current_command}' 2>/dev/null)

# Was the launcher ALREADY live when this tick arrived? (i.e. did we take the
# warm fall-through rather than the cold-launch branch). --fresh keys off this:
# a session we just launched is already at the onboard floor.
WAS_WARM=0
[ "$CURRENT_CMD" = "$EXPECT" ] && WAS_WARM=1

# 3.25 THE REUSE PATH, WHICH IS THE SILENT ONE (dotfiles-nnmm).
#
#   Reuse is the whole point of a durable per-row window — and it means the
#   branch below, where the seat gets set, DOES NOT RUN. A `di-monday` window
#   already holding a personal-seat claude would be reused with no launch, no
#   export, and no error: the LinearB tick would draft on Zig's personal
#   subscription and every mechanical signal would stay green. So when a seat is
#   named, a warm pane has to PROVE it is that seat before it is allowed to
#   receive anything.
#
#   Ordered BEFORE the 🔔 modal guard on purpose. Both paths type nothing, so
#   there is no harm either way — but a 🔔 defer is a normal, self-resolving
#   condition and a wrong seat is a misconfiguration that resolves only when a
#   human sees it. Reporting the self-resolving one first would hide it behind a
#   verdict that looks routine.
if [ -n "$CONFIG_DIR_ABS" ] && [ "$WAS_WARM" = 1 ]; then
  assert_seat "reuse"
fi

# 3.26 The same reuse hole, for the MODEL pin — and deliberately AFTER the seat
#      check, because identity outranks tier: if a pane is on the wrong account
#      that is the sentence the operator needs, and reporting a tier mismatch
#      first would bury it. Default outcome is warn-and-proceed (see --model in
#      the header for why this asymmetry is the right one).
if [ "$MODEL_ACTIVE" = 1 ] && [ "$WAS_WARM" = 1 ]; then
  verify_model "reuse"
fi

if [ "$CURRENT_CMD" != "$EXPECT" ]; then
  # cd first so a recycled shell pane anchors in the right project.
  "$TMUX_BIN" send-keys -t "$PANE" "cd $(printf '%q' "$DIR")" Enter
  sleep 0.5
  # Pin the seat for everything this pane's shell starts from here on. An
  # `export` typed into the pane, NOT `new-session -e` / `new-window -e` and not
  # an `env` prefix, for three measured reasons:
  #   * -e on new-session writes the SESSION environment, so every window
  #     created in `zig-computer` later would inherit this row's seat. Seven rows
  #     on one session is precisely where that leaks.
  #   * -e on new-window is pane-scoped and fine — but it only fires when the
  #     window is CREATED, so it does nothing for the durable window that
  #     already exists, which is the normal case after tick #1.
  #   * `env CLAUDE_CONFIG_DIR=… claude` would bypass the `claude` SHELL
  #     FUNCTION from claude-identity-wrapper.sh (env only resolves binaries),
  #     silently dropping the gateway base URL — the exact regression
  #     dotfiles-t6to was filed for. A prefix assignment is no better: in zsh
  #     (this box's shell) an assignment preceding a FUNCTION call is not
  #     exported to it the way bash exports it.
  # `export` is shell-agnostic, survives the wrapper, and reaches the launched
  # process — which the post-launch assert_seat below then proves from /proc.
  if [ -n "$CONFIG_DIR_ABS" ]; then
    "$TMUX_BIN" send-keys -t "$PANE" "export CLAUDE_CONFIG_DIR=$(printf '%q' "$CONFIG_DIR_ABS")" Enter
    sleep 0.3
  fi
  # Re-source the claude() wrapper before a COLD launch (2026-07-29, dotfiles-t6to).
  # A durable pane's shell is days old and holds the function body it read at shell
  # START — so a fix shipped to claude-identity-wrapper.sh reaches Zig's fresh shells
  # immediately but NEVER reaches the panes the harness actually launches ticks from.
  # That is precisely how the gateway base URL went missing for a day: the value moved
  # to a shell-tier file no live pane had ever sourced, and nothing alarmed because a
  # bypassed o11y proxy looks exactly like an idle one. Re-sourcing here makes a cold
  # launch pick up the CURRENT wrapper. Guarded to a `claude` launcher (a jailed or
  # goose launcher must not be prefixed) and `|| true`-ish by construction: the file is
  # absent -> the `.` fails -> the shell prints one line and still runs $LAUNCH.
  if [ "$LAUNCH_BASE" = "claude" ]; then
    "$TMUX_BIN" send-keys -t "$PANE" \
      '[ -f "$HOME/dotfiles/agents/lib/claude-identity-wrapper.sh" ] && . "$HOME/dotfiles/agents/lib/claude-identity-wrapper.sh"' Enter
    sleep 0.3
  fi
  "$TMUX_BIN" send-keys -t "$PANE" "$LAUNCH" Enter
  note "launched '$LAUNCH' in $PANE (was: ${CURRENT_CMD:-empty})"
  # Wait for the launch PROCESS to come up — this is LIVENESS, not readiness
  # (bounded poll, then proceed). Claude Code's pane_current_command flips to
  # 'claude' within a second or two of exec.
  for _ in $(seq 1 30); do
    sleep 1
    NOW=$("$TMUX_BIN" display-message -p -t "$PANE" '#{pane_current_command}' 2>/dev/null)
    [ "$NOW" = "$EXPECT" ] && break
  done
  NOW=$("$TMUX_BIN" display-message -p -t "$PANE" '#{pane_current_command}' 2>/dev/null)
  [ "$NOW" = "$EXPECT" ] \
    || note "WARN: '$EXPECT' not detected after 30s (pane runs '$NOW')"

  # The export above is a keystroke sequence typed into somebody else's shell —
  # it can be eaten by a shell that was mid-prompt, by a wrapper that resets the
  # environment, or by a launcher that re-execs through something that scrubs
  # it. Asserting the RESULT rather than trusting the ACT is the difference
  # between this flag and the unit-level Environment= it replaces, and it means
  # the production path carries the same proof the suite does: the thing that
  # started in the pane has the seat. A cold launch that still lands on the
  # wrong seat is a hard failure, not a warning — there is nothing to retry into.
  if [ -n "$CONFIG_DIR_ABS" ]; then
    assert_seat "launched"
  fi

  # Same proof for the model, on the process we just started: the flag was typed
  # into somebody else's shell and can be eaten by a wrapper, a re-exec, or a
  # launcher that rewrites its own argv. Asserting the RESULT is what makes the
  # ledger row below a claim about the process rather than about our intention.
  if [ "$MODEL_ACTIVE" = 1 ]; then
    verify_model "launched"
  fi

  # Liveness (the process exists) is NOT readiness (the TUI can accept typed
  # input). pane_current_command flips to 'claude' within ~1-4s of exec, but the
  # interactive TUI needs longer to draw its composer; typing before then drops
  # the keystrokes SILENTLY. The old cold-boot path detected the process, slept a
  # fixed 3s, then injected — an UNGUARDED timing race that never checked whether
  # the composer was actually up. Whether the 3s lands after-ready varies with
  # boot load, session weight, and attachment, so the SAME injector wins some cold
  # boots and loses others. Evidence (pulse-inject.log): weekly-report cold-boots
  # a fresh window + fresh claude every week (it does NOT reuse a warm session)
  # into the DETACHED, lighter `work` session and injected at +4s/+5s — after
  # ready. The ha-portal button cold-boots into the ATTACHED, heavier ~/explore
  # session (bigger CLAUDE.md + SessionStart) and injected at +5s/+6s/+7s — the
  # +7s run landed BEFORE ready, so '/ha-serve' was eaten and the homeowner queue
  # never drained (a later press into the now-warm session worked). Note the
  # FAILING boot waited LONGER than the winners — so a bigger fixed sleep is not
  # the fix, and the on-demand button (no next-tick retry to paper over a miss) is
  # just what surfaced the race. FIX: poll the pane for an input-READY marker
  # (Claude Code's composer footer) before typing, then a small settle.
  #
  # ON TIMEOUT WE NOW BOUNCE, NOT INJECT (dotfiles-mrta). The original gate fell
  # back to "inject anyway", reasoning that a marker miss should degrade to "try
  # late" rather than "never". Observed 2026-07-25 on a cold boot: the composer
  # took ~60s to paint, the gate timed out at its 60s ceiling, typed into an
  # empty composer, and the tick was EATEN — 0% context, no work, no ledger row.
  # "Inject anyway" is not "try late": there is nothing to type into, so it is a
  # SILENT loss, and it is a concrete mechanism for the "fired but no ledger row"
  # class (harnessd-h14z; the two explore ticks that vanished over 16 days).
  # Bouncing costs nothing by comparison — pulse-retry.timer fires every 2 min
  # and the pane is warm by then — and it leaves a record, which is the whole
  # difference between a tick that produced no work and a tick that never fired.
  #   PULSE_READY_MARKER     — ERE matched against capture-pane. Empty DISABLES
  #                            the gate (non-TUI launches / tests). Default = CC
  #                            composer footer.
  #   PULSE_READY_TIMEOUT    — ceiling in seconds (default 90; see below). The
  #                            first match returns immediately.
  #   PULSE_READY_ON_TIMEOUT — bounce (default) | inject. `inject` restores the
  #                            pre-mrta behavior. It exists as an escape hatch
  #                            for exactly one failure mode: Claude Code changing
  #                            its footer text, which would make the marker never
  #                            match and bounce EVERY tick. Reach for it to
  #                            unblock, then fix the marker — do not leave it on.
  #
  # THE 60 -> 90 DEFAULT, and what it is (and is not) based on. The honest
  # answer is that the ceiling is no longer load-bearing: once a timeout bounces
  # instead of injecting blind, being wrong costs one retry cycle rather than a
  # lost tick. 90 is chosen as: comfortably past the single observed failure
  # (~60s, a first-run-in-a-new-project cold boot — the slowest possible case),
  # while keeping the injector's worst case inside the 120s TimeoutStartSec on
  # pulse-retry.service, which invokes loop units with a BLOCKING
  # `systemctl --user start`. It is NOT a measured percentile: /tmp/pulse-inject.log
  # holds only 3 gated claude cold boots since the gate shipped (two at +2s, one
  # timing out at 60s), and the remaining 23 `launched 'claude'` entries predate
  # the gate entirely. Rather than guess harder, the success path below now logs
  # the OBSERVED seconds, so the distribution accumulates for free and the next
  # person to touch this number can set it from data.
  READY_MARKER=${PULSE_READY_MARKER-'shift\+tab to cycle|\? for shortcuts|for agents|bypass permissions|accept edits on|plan mode on'}
  READY_TIMEOUT=${PULSE_READY_TIMEOUT:-90}
  READY_ON_TIMEOUT=${PULSE_READY_ON_TIMEOUT:-bounce}
  if [ -n "$READY_MARKER" ]; then
    # Deadline, not `seq 1 $N` + `sleep 1`: each iteration also pays for a
    # capture-pane and a grep, so the counting loop overshot its own advertised
    # ceiling — the 2026-07-25 incident logged "not seen after 60s" 63 seconds
    # after launch. A wall-clock deadline makes the number in the message true,
    # which matters now that the same number decides whether to bounce.
    _ready_t0=$(date +%s)
    _ready_deadline=$(( _ready_t0 + READY_TIMEOUT ))
    _ready=""
    while [ "$(date +%s)" -lt "$_ready_deadline" ]; do
      if "$TMUX_BIN" capture-pane -p -t "$PANE" 2>/dev/null | grep -Eq "$READY_MARKER"; then
        _ready=1; break
      fi
      sleep 1
    done
    _ready_elapsed=$(( $(date +%s) - _ready_t0 ))
    if [ -n "$_ready" ]; then
      # The elapsed seconds are the measurement PULSE_READY_TIMEOUT should be
      # set from; log them so the sample grows without anyone instrumenting.
      note "input-ready marker seen after ${_ready_elapsed}s (ceiling ${READY_TIMEOUT}s); settling before inject"
      sleep 2
    elif [ "$READY_ON_TIMEOUT" = "inject" ]; then
      note "WARN: input-ready marker not seen after ${_ready_elapsed}s — injecting anyway (PULSE_READY_ON_TIMEOUT=inject)"
    else
      note "BOUNCED: input-ready marker not seen after ${_ready_elapsed}s — NOT injecting '$CMD'; next timer retries"
      record_bounce "not_ready"
      # Exit 0 is deliberate (a bounce is a deferral, not a unit failure — see
      # test case 13), so the VERDICT is the only thing that tells a caller
      # nothing was typed. record_bounce() is loop-scoped and best-effort; this
      # marker is unconditional and in-band.
      emit_result bounced-not-ready
      exit 0
    fi
  else
    sleep 3
  fi
fi

# 3.5 Modal-safety guard. Do NOT inject into a window that's blocked on
#    Andrew. The tmux-status hook prefixes "🔔 " when the session is
#    waiting on an AskUserQuestion / ExitPlanMode / permission prompt
#    (PreToolUse + permission Notification), and clears it only when work
#    resumes (PostToolUse -> 🧠 / Stop -> ✅) — so "🔔 " is present for
#    exactly the blocked-modal duration. send-keys here would feed the
#    command into the MODAL DIALOG (not the message composer): the text is
#    eaten and the trailing Enter resolves the dialog with the wrong/default
#    answer — losing the tick AND mis-answering Andrew's open question. The
#    text is NOT queued (queuing only happens at the composer). So defer:
#    log and exit 0; the next timer retries once Andrew has answered. This
#    is 🔔-specific — 🧠 (mid-turn, the composer cleanly queues), ✅, 🌀, and
#    a bare/fresh window all still inject.
WIN_NAME=$("$TMUX_BIN" display-message -p -t "$PANE" '#{window_name}' 2>/dev/null)
if [ "$WIN_NAME" != "${WIN_NAME#🔔}" ]; then
  note "deferred: window '$WIN_NAME' is blocked on Andrew (🔔) — not injecting '$CMD'; next timer retries"
  # Record the bounce where the state bus can read it (harnessd-gf6). A deferred
  # tick never ran, so the bus must render 'bounced' — not a false 'tick in flight'.
  # The writer is shared with the not_ready bounce above (dotfiles-mrta): both are
  # "the tick did not get delivered", and one implementation means the two paths
  # cannot drift into different record shapes.
  record_bounce "blocked_on_andrew"
  # Same reasoning as the not_ready bounce above: exit 0 is right for /pulse and
  # useless to a one-shot caller, so the verdict carries the outcome. This is the
  # path that silently ate picod's homeowner button press (dotfiles-q0qi).
  emit_result deferred-blocked-on-human
  exit 0
fi

# 3.6 --fresh NEVER QUEUES /clear BEHIND A LIVE SAME-LOOP RUN (dotfiles-t5fj).
#
#   ORDERING, and both halves are load-bearing. AFTER the 🔔 guard, because a
#   blocked window is a different and older answer and must keep its own verdict
#   (a 🔔 pane is not "running our tick", it is waiting on Zig). BEFORE the
#   --fresh block below, because the whole point is that the /clear is never
#   typed — by the time send-keys has run, the wipe is already queued and there
#   is nothing to take back.
#
#   ONLY --fresh, and only a WARM pane. A plain tick queueing behind a live turn
#   is the composer working as designed; a cold launch has no prior turn of ours
#   to collide with. Without --loop there is no delivery identity to check, so
#   the guard says it could not look rather than pretending it did.
if [ "$FRESH" = 1 ] && [ "$WAS_WARM" = 1 ]; then
  if [ -z "$LOOP" ]; then
    note "same-loop check: SKIPPED — no --loop, so a delivery cannot be attributed to a loop. A --fresh tick with no loop id can still queue /clear behind a live run; pass --loop (units pass %p)."
  elif _same_loop_running "$WIN_NAME"; then
    note "deferred: window '$WIN_NAME' is mid-turn on THIS loop's own tick — not sending /clear or '$CMD'. Queuing them behind a live same-loop run is a delayed context wipe, not a delivery (dotfiles-t5fj). The bounce is recorded; pulse-retry re-delivers once the turn ends."
    # Recorded through the SAME writer as the other two non-delivery paths, so the
    # three cannot drift into different record shapes, and so the state bus renders
    # this tick 'bounced' rather than a false 'tick in flight'.
    record_bounce "already_running"
    emit_result deferred-already-running
    exit 0
  fi
fi

# 3.75 --fresh: warm process, COLD CONTEXT (dotfiles-6ycc).
#
#   ORDERING IS LOAD-BEARING — this MUST come after the 🔔 guard above, not
#   before it (the decision brief's §6 sketch put it before, at the old line
#   ~199; that is wrong). A 🔔 window is sitting in a modal dialog: send-keys
#   there feeds the DIALOG, not the composer, and the trailing Enter resolves it
#   with the default answer. Clearing before the guard would therefore
#   mis-answer Andrew's open question AND wipe the context of the session that
#   was waiting on him — strictly worse than the tick we were already deferring.
#   Deferred ticks must leave the pane untouched, /clear included.
#
#   Only fires on a WARM pane: a cold launch is already at the onboard floor.
#   Sent exactly like the tick command below (text, pause, Enter) — the same
#   path that delivers `/pulse tick` in production, so the slash-command palette
#   behaves identically. Nothing about the window changes: same pane, same
#   scrollback, same process; only the model's context resets.
if [ "$FRESH" = 1 ] && [ "$WAS_WARM" = 1 ]; then
  "$TMUX_BIN" send-keys -t "$PANE" -- "/clear"
  sleep 0.3
  "$TMUX_BIN" send-keys -t "$PANE" Enter
  note "fresh: sent /clear to $PANE (warm session -> cold context)"
  # NOT covered by the readiness gate above, and it cannot be: that gate polls
  # for the composer FOOTER, and the footer never disappears during a /clear
  # repaint — the marker matches instantly and proves nothing. So this settle is
  # still a fixed sleep, i.e. the same unguarded timing race the cold-boot path
  # had before dotfiles-6ycc. Raise PULSE_FRESH_SETTLE if a --fresh loop starts
  # losing ticks; closing it properly needs a post-/clear marker that is
  # distinguishable from the pre-/clear one (dotfiles-mrta, unresolved).
  sleep "${PULSE_FRESH_SETTLE:-2}"
elif [ "$FRESH" = 1 ]; then
  note "fresh: skipped /clear (cold launch — context already fresh)"
fi

# 4. Inject the command. Text first, Enter separately — some TUIs
#    mis-handle a combined burst.
"$TMUX_BIN" send-keys -t "$PANE" -- "$CMD"
sleep 0.3
"$TMUX_BIN" send-keys -t "$PANE" Enter
note "injected into $PANE"

# The delivery row (dotfiles-t5fj) — written HERE and only here, on the one path
# where something was actually typed. It is what lets the next tick's same-loop
# guard, and pulse-retry.sh's staleness check, distinguish "this loop was already
# delivered" from "this loop's bounce is still live".
record_injection

# The ledger row, written only on the path where a pinned tick was actually
# delivered — a bounce or a defer produces no gateway request to join against,
# so recording one there would manufacture rows with no counterpart.
record_model injected

emit_result injected
exit 0
