# IN CASE OF RETREAT — removing Zig's debris from marketing-vps

**Canonical, and CURRENT as of 2026-08-05 23:50Z.** Originally written 2026-08-04
on marketing-vps as `~/.in-case-of-retreat.txt`, tracked here 2026-08-05
(`dotfiles-oj2s`), and **rewritten here** once most of it had been executed.

> The original verbatim text is preserved in git — `git show 72eb426:refs/in-case-of-retreat.md`.
> It is kept because it records what was believed before the work was done; it is no
> longer the thing to execute. `zig-computer:~/.in-case-of-retreat.txt` points here.

The original's phase ORDER and its standing decisions are unchanged and still govern.
What changed: **the pulse migration is done**, and **the data-loss question is answered**
— which together retire most of Phase 1.

---

## STANDING DECISIONS — do not re-litigate

1. **NO CREDENTIAL ROTATION** (Zig, 2026-08-04). The credential files on that box are
   debris and go with the home. Do not open a rotation workstream.
2. **THE GITHUB ARCHIVE STAYS, INTACT.** `azigler/claude-memory` and
   `azigler/claude-transcripts` keep every marketing-vps-origin session. No history
   rewrite, no selective purge. Remove only LOCAL copies.
3. **An account cannot delete itself.** Route that step to `ubuntu` or the box owner.
4. **End state = emptied-but-present**, not `userdel` (Zig, 2026-08-05). Reversible,
   quiet, and does not need the box owner.
5. **The seven pulse rows run on zig-computer in the `work` tmux session**, one window
   per row, on a LinearB work seat — *not* `zig-computer:` (Zig, 2026-08-05).

---

## STATE

### DONE — the migration (the real work that was hiding inside this retreat)

- **All seven rows cut over.** `pulse-di-{monday..friday}`, `pulse-weekly-report`,
  `pulse-biweekly-content` now run
  `pulse-inject.sh … --session work --window <row> --config-dir %h/.claude-work --cmd "/pulse tick"`.
  `--row`, `--with-fleet-token` and `. %h/.secrets` are gone. Verified with a positive
  control (the old line still flags all five removed tokens); `systemd-analyze verify`
  clean ×7; backups in `/tmp/pulse-units-bak/`.
- **A work seat exists**: `~/.claude-work` (0700), its own OAuth lineage, minted by Zig.
  A fresh seat needs TWO first-run flags or it hangs forever at a dialog with
  `bounced-not-ready` as the only symptom — `projects["<path>"].hasTrustDialogAccepted`
  in `.claude.json`, and `skipDangerousModePermissionPrompt` in `settings.json`. Both set.
- **Proven end to end**: a work-seat tick ran in `work:di-thursday` and pico's gateway
  logged `group=zig-computer user=work:di-thursday`, 76 requests — right seat, right
  machine label, right window, requests arriving, and **no** `ANTHROPIC_AUTH_TOKEN`
  (so it bills the subscription, not an API key).
- **`lb-claude`** — on-demand work-seat session in any window (`zsh/.zig-computer.zshenv`).
  A subshell, not an alias: `claude` is a shell FUNCTION, so a script or an `env` prefix
  silently loses gateway routing, and a non-subshell `export` leaks the seat.
- **Status line** shows the seat: `(me)` / `(lb)` / `(tick)`.
- **Monday routing regression found and fixed** (`dotfiles-q93s`). Dropping `--row`
  deleted the time-of-day half — both Monday rows checked only `date +%u`, both are
  priority 2, so both units selected `di-monday` and the rows swapped units. The checks
  now carry the hour; proven by simulation rather than by waiting for Monday.

### ⚠️ OUTSTANDING ON THE MIGRATION

- **`pulse-di-thursday.timer` is DISABLED.** Deliberate — its work ran manually on
  2026-08-05 and the remote would have re-fired. **Re-enable once Thursday 2026-08-06
  passes**: `systemctl --user enable --now pulse-di-thursday.timer`.
- **The work seat is not yet wired into the harness.** `CLAUDE_CONFIG_DIR` relocates the
  WHOLE config tree, so the seat has none of `~/.claude`'s symlinks (`CLAUDE.md`→AGENTS.md,
  `skills`, `hooks`, `agents`, `statusline.sh`, `settings.json`) and writes transcripts to
  its own `projects/`. Consequences: no tmux glyphs, invisible to the Harness app, no
  memory — and **`/pulse tick` cannot resolve without `skills`**, which is a Monday
  blocker. Intent: the seat should mirror `~/.claude` in everything EXCEPT
  `.credentials.json` and `.claude.json`. Work in flight.

### ANSWERED — the data-loss question. This is the big change.

Measured on marketing-vps 2026-08-05:

| measure | value |
|---|---|
| `.jsonl` under `-home-andrew-*` slugs | **0** |
| memory files under `-home-andrew-*` | 391 — **all byte-identical** to their `-home-ubuntu-*` twins |
| memory files unique to this box | **0** |
| git repos with commits on no remote | **0** |

`~/.claude` here is 6.7G of **zig-computer's** corpus, pulled through the shared vault —
not this box's own work. **So Phase 1a's final vault sync is a formality now, not the
load-bearing step it was written as.** Run it anyway (cheap, and `deferred ≠ pushed`
still holds), but the delete-then-discover-it-never-synced risk is retired for `~/.claude`.

⚠️ The last two `claude-vault-sync` rows read `transcripts=deferred (exit 0)`, outcome
`quiet` — the exact shape the original warns about. It endangers nothing here (nothing
unique to push) but understand it before relying on that sync elsewhere.

### STILL UNREPLICATED — the only genuine loss risk left

| path | size | git? | note |
|---|---|---|---|
| `~/marketing-vps` | 628K | **NOT a repo** | holds its own `.beads/` — **6 rows, no remote, replicated NOWHERE** |
| `~/work` | 11M | **NOT a repo** | tick run dirs |
| `~/bin` | 16K | **NOT a repo** | |
| `~/.secrets` | 8K | not a repo | debris by decision 1 |

⚠️ `~/.secrets` is a **DIRECTORY** here and a **FILE** on zig-computer (every unit does
`. ~/.secrets`), so `~/.secrets/anything` is not a valid destination there.

### DONE — repo hygiene, both boxes

- marketing-vps: every repo has 0 commits on no remote.
- zig-computer brought current: **imc-aug26 +91**, pipeline-website +25, imc-july26 +1.
- `lb-granola`: 11 commits (07-30 → 08-05) rescued and pushed. Root cause was **a red
  that erases itself** — `commit` only pushes when something is staged, so the next
  no-op tick exits 0 and overwrites the failure. A oneshot has one state bit. Guarded
  now (`dotfiles-1o9t`); the lesson generalizes to any conditional oneshot.
- `skills-library`: 3 stale commits dropped at Zig's instruction. Its push remote is
  deliberately `DISABLED://repo-archived-2026-06-09` — that is not a fault.
- **`plugins` — UNRESOLVED.** Local `distribute-agent-discipline-toolkit` and
  `origin/main` share **no common ancestor**: 9 local commits on no remote, 8 remote
  commits not local. Lives on zig-computer, so not a retreat blocker.
- Removed as dead: the `pulse-elevate` units, and **7 Hermes units** the substrate
  uninstall left behind. ⚠️ **`~/.hermes/node` is NOT dead** — `tick-jailed.sh:671`
  ro-binds it for the live dive jail. Do not "finish" that cleanup.

---

## WHAT REMAINS — in order. Do not reorder.

### Phase 1 RESCUE — only the non-git dirs are left
- `scp marketing-vps:'~/marketing-vps/.beads/issues.jsonl'` off; decide where the 6 rows live.
- Decide `~/work` (11M) and `~/bin` (16K): keep or discard.

### Phase 2 STOP — ⚠️ NEW ORDERING HAZARD
- Safe now: `lb-granola-pull`, `imc-pull`, `vps-repo-refresh`.
- **`claude-gateway-tunnel` and `claude-vault-sync` go LAST**, after the final sync and
  after the last session on this box ends. Disabling the tunnel kills `claude` here by
  policy (`dotfiles-ucl4` — fail-hard, no fallback), *including the session running the
  retreat*.
- `loginctl disable-linger andrew` — Linger=yes, so disabling timers alone is not enough.
- Kill the two `ssh -L` tunnels (127.0.0.1:7100, :17017), then `tmux kill-server`.

### Phase 3 WIPE
`~/.claude` (6.7G) · `~/.claude.json*` · `~/.config/gh` · `~/.secrets` · `~/work` ·
`~/linearb` · `~/dotfiles` · `~/marketing-vps` · `~/bin` · `~/.gnupg` · shell history.
Then the tooling remainder, or leave it for `userdel -r`.

### Phase 4 SEVER — 4a → 4b → 4c → 4d, and the order is the defense
4a runs ON marketing-vps and needs the connection 4b/4c destroy. **After 4b+4c there is
no way back in.** 4d (the sudoers drop-in) has the highest blast radius in the plan —
a malformed `/etc/sudoers.d` locks out kevin, mike and ben too. `sudo visudo -c`, without
exception.

### Phase 5 ACCOUNT — nothing to do (decision 4: emptied-but-present).

### Phase 7 PAPERWORK — part of the job, not a follow-up
- Delete or archive deliberately, saying which: `pulse-dispatch-remote.sh` (~2,300 lines),
  `vps-preflight.sh`, `vps-repo-refresh.sh`, `fleet-creds.sh`'s peer, `vps-repo-manifest.txt`,
  the deferred-surface / `surface_request` round-trip.
  ⚠️ **`pulse-retry.sh` also consumes the surface-queue machinery** — check callers first
  or retry loses a limb.
- Fold `work:pulse` and `work:🗼 vps`. Verified safe: no other unit targets `--window pulse`.
  ⚠️ `--window pulse` is still pulse-inject's built-in DEFAULT; folding the window does
  not change that.
- Strip marketing-vps from `agents/infra.md`, **including the two-writers warnings**.
- `dotfiles-hi81` (lb-granola here was deliberate) — say so against that bead.
- The 2026-08-03 hostname rename — leaving it is harmless, reverting is a courtesy. Say
  which; do not do it silently.
- File a `-t decision` bead recording what was removed and what was deliberately left.

## HOW YOU KNOW YOU'RE OUT

```bash
ssh -o BatchMode=yes -o ConnectTimeout=8 marketing-vps true      # MUST fail
grep -c 'marketing-vps' ~/.ssh/authorized_keys                   # 0
systemctl --user list-timers --all | grep -E 'pulse-di-|weekly-report|biweekly'
```
⚠️ The third check **inverted**. It used to expect empty. Those timers now live on
zig-computer and must be **present and running** — they moved, they did not stop.

## DO NOT TOUCH

`/home/{ubuntu,kevin,mike,ben}` · sshd config · the firewall · any system service other
than the one sudoers file in 4d · the GitHub repos · **`~/.hermes/node` on zig-computer**
(live tick-jail dependency).
