# Session handoff — 2026-07-28 · vps-8a9eb245 becomes Zig's own machine

Session id: `7f6d0b60-cfc5-467c-9931-3240fb6e0cc2`

## State at offboard

- **Branch**: main @ `c78e533`, working tree clean, pushed
- **Open beads**: 34 (1 in-progress: `dotfiles-mhn`, the /pulse spec — pre-existing)
- **In-flight subagents**: none. No worktrees.
- **Markers**: `.offboard-pending` cleared
- **Box**: `vps-8a9eb245`. `agents/infra.md` documents **zig-computer** and does
  NOT describe this machine — different IP, ports, timers.

## The one idea that explains the whole session

This box was provisioned as a **marketing-vps PEER**: a coworker-facing,
read-only consumer scoped to seven LinearB slugs. Zig's instruction was to make
it **his own machine**. Every single problem found was the same shape — something
scoped narrowly for the peer role, silently excluding his own work — and every
one of them **reported success while doing nothing**:

| Layer | Symptom | Silent because |
|---|---|---|
| `~/dotfiles` repo | shell tier still served by `~/marketing-vps` | sparse cone = `agents`,`claude` |
| transcripts vault | 64/93 slugs absent | cone was an allowlist of 7 |
| slug transform | `~/dotfiles` sessions never synced at all | alias covered `linearb*` only |
| alias creation | 78 projects on disk but unreachable | alias was created LAZILY at SessionStart |
| mtimes | whole back-catalogue read "1 day ago" | git does not carry mtimes |

The hourly timer logged `OK` throughout all of it. This is `dotfiles-cxle`
(consumer-reports-success) with five fresh instances.

## What happened

**Shell + tmux** (`2b8d22a`) — full checkout; `zsh/.vps-8a9eb245.zsh`,
`bash/.vps-8a9eb245.bashrc`, and a NEW tier `zsh/.vps-8a9eb245.zshenv` (`ssh host
"cmd"` reads `.zshenv`, not `.zshrc`, so remote dispatch needs PATH there; that
content had been written straight to `~/.zshenv` where the first `sync.sh zsh`
would have silently reverted it). All hooks guarded — this box has no keyboard.
Also fixed `sync.sh gnupg` writing a macOS-only `pinentry-mac` line on Linux.

**tmux ownership** — `tmux/tmux.service`. Zig ran the cutover; PROVEN:
server pid's parent is `/usr/lib/systemd/systemd --user`, cgroup
`user@1002.service/app.slice/tmux.service`, no `session-*.scope` left.
Side effect: continuum/resurrect are live for the first time.

**Vault, four rounds** (`88e0eae`, `6ea8081`, `3a311bb`) — universal
`-home-andrew*` → `-home-ubuntu*` transform; full mirror (93/93 slugs, 4.6 GB);
78 aliases; `restore-mtimes.py` (7,334 files, largest 183 days). All durable in
`vault-sync.sh` step 1a, peer-guarded.

## Decisions made this session

- `dotfiles-qydv` — ANTHROPIC_BASE_URL moved to a per-host file rather than
  dropped fleet-wide. Zig's removal was correct for this box but `settings.json`
  is fleet-wide; preserved for zig-computer in `zsh/.zig-computer.zshenv`.

Zig decided directly (not autonomous, so no ADR): full checkout, the tmux restart
timing, the force-push, and codifying the peer→own-machine role change.

## Proposed practices — where each landed

- Allowlist-vs-transform reasoning ("a missing entry costs invisible data loss, an
  over-broad match costs an unread symlink — not symmetric") → **written into
  `agents/hooks/session-start.sh`** at the site it governs.
- "Keep the two cones identical" → **written into both cone files and
  `vps-peer-bootstrap.sh`**.
- "If a shared coworker box ever needs narrow scope, make it an opt-in FLAG, never
  the default" → **written into `vps-peer-bootstrap.sh`** header.
- Negative-control setup must be asserted (a shell-aliased `rm -i` silently
  no-opped a break step and the test "passed") → **appended to the
  `feedback-silent-success-pattern` memory** as habit §4.

## What's next

1. **`dotfiles-qcfx` (P2)** — the hourly timer still runs a 49-line untracked stub
   at `~/bin/vps-repo-refresh.sh` instead of the tracked 447-line script with
   receipts, fail-closed `--assert`, and live `ls-remote` staleness checks. Works
   today; fails silently when it stops. Blocked on deciding what
   `readonly $HOME/dotfiles` means now the box is a working checkout —
   `e14c5ac` already relaxed the identity half.
2. `dotfiles-6wdw` (P0, pre-existing) — unauthenticated internet→tailnet pivot on
   :7575. Untouched this session; predates it.
3. Consider whether `agents/infra.md` should gain a section for this box, or
   whether a second file is cleaner.

## Warnings / watch-outs

- **`main` was force-pushed** (`13879a7` → `4461a22`) to fix a machine-derived
  author email. Trees verified identical first. Any other dotfiles checkout needs
  `git fetch && git reset --hard origin/main`. The box that pushed `741c1e8`
  reconciled correctly already.
- **NEW HAZARD, introduced by the aliasing.** `~/.claude/projects/-home-andrew-*`
  are now symlinks into shared `-home-ubuntu-*` dirs, so a slug directory holds
  sessions from BOTH machines. `/offboard` Step 2 and `session-end.sh` pick the
  session id via `ls -t *.jsonl | head -1`. That is no longer reliably "this
  session" — it matched today only because this session was actively writing. A
  concurrent dotfiles session on zig-computer could win the race and stamp the
  wrong id into `.claude/last-offboard-session`. Not yet filed; worth a bead if it
  ever misfires.
- `restore-mtimes.py` fixes **mtime only**. ctime is unavoidably the checkout
  moment on a mirror — nothing short of shipping metadata alongside content fixes
  that. 161 files carry no embedded timestamp and are left alone, not guessed.
- **`~/.secrets` does not exist here.** Guarded everywhere, so no shell errors —
  but anything needing a credential comes up empty.
- `~/marketing-vps` still exists and is still the coworkers' repo. It is simply no
  longer wired into Zig's shell.
- `claude/settings.json` no longer sets `ANTHROPIC_BASE_URL` fleet-wide; a machine
  needing the pico proxy must have run `sync.sh zsh` since (see `dotfiles-qydv`).
