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

1. **`daily-ao3`** — a background agent was consolidating autonoveld's four pulses into
   one row/one session (`mail → voice-correction → conceive → write`), folding in
   `autonoveld-zx5m`, and wiring the metis conduit. **Verify it landed**: `refs/pulse.md`
   has one row, `list-timers` shows `pulse-daily-ao3` and none of the four old ones, and
   the ledger lint accepts the new row name. **Then register it in
   `~/harnessd/refs/harness-manifest.json`** — that was NOT done.
2. **`dotfiles-2smz`** — the marketing-vps auth decision.
3. **`dotfiles-nneb`** — the close gate has no escape hatch. It cost two cycles today, and
   note the second trap: the hook blocks the *whole chained command*, so
   `br update … && br close …` never runs the update.
4. **`dotfiles-9gyl`** — `/scrutinize` prompt-size is still UNPROVEN. The corpus is sound
   (catchability gate passed); the rig can't separate the arms. 39/39 rollouts returned
   FIX-FIRST including a control told to sign off.
5. `dotfiles-q9tr` (doclint lints an eval corpus), `dotfiles-du2y` (2 skills fail strict
   YAML), `dotfiles-dpbn` (hevyd wildcard bind).

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
