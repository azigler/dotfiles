# Session handoff — 2026-08-01 · the Opus-5 bloat audit, and what it turned up

Long session. It started as a harness-bloat audit and turned into a fleet audit, because
almost every "bloat" finding was really a **stale or false claim**, and checking those
against live state kept finding real defects.

## State at offboard

- **Branch**: `main`, clean, pushed. No worktrees. No unpushed commits.
- **Beads**: 49 open / 236 closed (287 total). **0 in_progress, 0 blocked.**
- **Both P0s closed** (`dotfiles-6wdw`, `dotfiles-2smz` is still open — see below).
- **In flight when this note was written**: one background agent finishing the
  `daily-ao3` consolidation in `~/autonoveld` (see "Unfinished" below).

## The headline: the premise was half right

Zig's framing was "Anthropic removed 80% of Opus 5's harness instructions; ours is
similarly bloated." The vendor guide's actual remove-list is **six named classes**, and
it opens by saying Opus 5 "performs well out of the box on existing Opus 4.8 prompts."
Across four independent audits the defensible cut was **14–27% per corpus, not 80%** —
because this harness is overwhelmingly *facts about this machine*, and Opus 5 being
smarter doesn't tell it that `marketing-vps` re-detaches HEAD.

**Audit B resolved all 39 inline bead citations: 27 of 27 scar-tissue rules trace to a
real, confirmed incident.** Not one invented.

Full report: `refs/opus5-bloat-audit-2026-08-01.md`. Working files:
`refs/audit-2026-08-01/`.

## What shipped

| | |
|---|---|
| `agents/AGENTS.md` | **5,525 → ~2,000 words**, re-scored 12/12 on a validated A/B rig |
| always-loaded tier | ~10,400 → ~6,670 words (−36%) |
| 4 fleet CLAUDE.md | −7,400 words (`agent-dev-interrupted` was teaching stash + tmux subagents + a `br` subcommand that errors) |
| skills dedup | −999 words, 45/45 distinctive phrases verified at their new owner |
| `agents/infra.md` | 595 → 2,300 words — retitled **"The computing demesne"**, now covers pico + marketing-vps |

## THE RECURRING DEFECT — read this before anything else

**Four separate instances in one day of: the mechanism exists, nothing calls it, and the
doc reads as though it's live.**

1. `pulse-ledger-lint.py` had **no hook caller** (`dotfiles-775y`)
2. `agentgateway-run` on pico sourced `~/.secrets` correctly — and the launchd plist
   invoked the raw binary instead. Written 2026-07-26, never wired.
3. `check-frontmatter` is deliberately advisory-only
4. `state-bus.timer` masked while a `KeepAlive` job served month-old state

**And its twin: the consumer asserts what the step never established.** `pulse-stall-
reconcile` claimed pulse-inject "reported INJECTED", that the tick "did not bounce" and
"did not block" — while reading only `LastTriggerUSec` and the ledger. Same class as the
open `dotfiles-kel5` and the P1 `dotfiles-cxle`.

**If you build one thing next, build the standing check for this class.** `dotfiles-cxle`
has 17 confirmed instances and no detector.

## Corrections I had to make to my own work

Recorded because the pattern matters more than the individual errors — **I twice inferred
a defect from systemd state without reading the owning project's records, and wrote it
into an always-loaded doc:**

- **harnessd "broken pipeline"** — retracted (`dotfiles-df88`). `state-bus` is masked
  *on purpose*; harnessd/CLAUDE.md:51 documents the migration to in-proc Go. The tell I
  walked past: the mask predates the "freeze" by three weeks.
- **autonoveld "silently OFF"** — corrected. The pause was commit `9888d0e` ("Zig's call,
  for the time being") **and** a PAUSED banner in `refs/pulse.md` carrying the exact
  stamp-first restore procedure I later "discovered" independently.
- **`git add agents/`** — a directory add, which `/commit:211` forbids. It swept two
  scratch files with a LinearB doc ID into this PUBLIC repo. Untracked + gitignored;
  Zig chose to leave history. Verified the doc is `linearb.io`-domain-only, no
  `type:anyone` permission.
- **frontmatter measured at 6,972 words** — wrong; `sed` between `---` also matched
  markdown rules in bodies. Real figure **3,362**.

## Fleet work

- **marketing-vps**: **10,635 failed SSH auths in 24h**, password auth on, no firewall,
  no fail2ban, 2 NOPASSWD-root accounts. **Not breached** (all successful logins were
  publickey from zig-computer, or one consistent teammate IP). **fail2ban installed and
  verified banning** — 3 IPs in nftables within a minute. `ignoreip` needed a second fix:
  `[DEFAULT]` isn't inherited at runtime, and without it zig-computer could self-ban and
  kill the hourly refresh. **`dotfiles-2smz` stays open** — password auth, ufw, and the
  sudo accounts are Zig's call (mike/ben have no SSH keys).
- **`qcfx` closed**: marketing-vps now runs the tracked 610-line refresh script, receipt
  written, `--assert` green. `readonly` → `watch` (old spelling kept as a silent alias).
- **picod**: drain loop retired from the harness manifest; `picod-health.timer` KEPT —
  it's a guard, not a heartbeat (`bd-zdj`).

## Unfinished — for the next session

**`daily-ao3` LANDED and is live**, and it runs in the **`autonoveld`** window with
`--fresh` (Zig's call — the project keeps one window under its own name regardless of
how its rows are packaged). The smoketest had created a separate `daily-ao3` window;
that one was renamed into place rather than left as a stray nothing targets. `--fresh`
is deliberate: warm process, cold context, so a tick starts near the onboard floor and
`refs/session-handoff.md` stays the only channel between yesterday's tick and today's.

**The shape:** One row, one session, four stages
(`mail → voice-correction → conceive → write`). `pulse-daily-ao3.timer` armed
stamp-first (next 09:07 PT); the four old timers are `disabled` with unit files
retained. Registered in `~/harnessd/refs/harness-manifest.json` — dashboard reads
`pulse-daily-ao3 | healthy`. autonoveld suite **1143 passed**, 12 mutants written
and 12 died.

**Smoketest ran** (`2026-08-02T00:06:57Z`): all four stages executed in one session,
`stages: {mail: blocked, voice-correction: quiet, conceive: quiet, write: quiet}`,
roll-up `blocked`. **Not green, and correctly so** — `mail` blocked because BOTH of
that day's fixes fired on real events: `zx5m`'s new check returned rc 2 naming
"Salt Comes Late" as an archived work with no digest, and the challenge detector
caught the **first live `AO3HumanGate`** this project has ever seen.

What is actually left:

1. **`/scrutinize` gate on three autonoveld impl beads** — `autonoveld-7d1f`,
   `-ma15`, `-mw3t`. The implementing agent correctly refused to self-certify;
   `pre-bead-close.sh` blocks the close until a fresh-context reviewer records a
   verdict. This is the only thing standing between them and closed.
2. **`autonoveld-i6ad`** — the tick found our conduit design is incomplete:
   *routing through metis does not clear a Cloudflare challenge, because a SOCKS
   tunnel carries no `cf_clearance` cookie.* Proxying the egress IP doesn't help;
   the challenge is cleared by a cookie a browser earns. A real conduit needs to
   capture `cf_clearance` after Zig solves the captcha and feed it to the client.
3. **`autonoveld-86hf`** — record the AO3 work URL for "Salt Comes Late". This is
   what lets `zx5m` close *completely* rather than just loudly.
4. **`dotfiles-nneb`** — the close gate has no escape hatch. It cost two cycles
   today. Second trap: the hook blocks the **whole chained command**, so
   `br update … && br close …` never runs the update.
5. **`dotfiles-cxle`** — the highest-value item in the backlog. 17 confirmed
   instances, no standing check. See the defect-class section above.
6. `dotfiles-9gyl` (scrutinize prompt-size UNPROVEN), `q9tr` (doclint lints an eval
   corpus), `du2y` (2 skills fail strict YAML), `dpbn` (hevyd wildcard bind).

**`dotfiles-2smz` was CLOSED as accepted risk**, not fixed: fail2ban is holding
(~440/hr → 66/hr, 7 IPs banned) but password auth, ufw and both NOPASSWD accounts
remain. Four reopen triggers are recorded on the bead — the cheapest is mike/ben
acquiring SSH keys, which makes `PasswordAuthentication no` free.

## Watch-outs

- **AO3 was genuinely down most of 2026-08-01** (525 = Cloudflare↔origin). A paired probe
  showed metis (residential) failing identically and a third-party monitor dark all day —
  so it was NOT an IP block. **But Zig hit a Cloudflare captcha in a browser on metis**,
  so both are true: struggling origin *and* defensive posture. Per his call, metis becomes
  the conduit he can unblock by hand.
- `ps -p <pid> --no-headers` **errors and still exits 0** on this box — it gave me a false
  "process alive" reading. Use `/proc`.
- `grep -c` prints `0` **and** exits 1, so `|| echo 0` emits `"0\n0"`.
- A mutant that doesn't mutate proves nothing — the formatter wrapped a constant across
  lines and my regex silently no-opped. `assert old in s` before writing.
