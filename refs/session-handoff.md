# Session handoff — 2026-08-01 7f58f468

## State at offboard
- Current branch: `main`, pushed and clean
- Last commit: `4ec891d` :card_file_box: beads: gitignore the fsqlite namespace sidecars
- Open beads: 54; in-progress: 0
- In-flight subagents: none — all five worktrees merged, unlocked and removed
- Dirty files: none tracked (`sketchybar/hooks/` remains untracked, pre-existing, Zig's local)
- Markers: `.offboard-pending` cleared

## What happened this session

Started as "pull latest and update the binaries on this Mac." The pull was 723 commits
behind and `.beads/` arrived with it. The upgrade question turned into a portability audit.

**The pull.** Six files had local edits that were mostly *reverting* newer machinery to
older versions (the tmux TTY guard, the `$HOME`-not-hardcoded fixes). Stashed, pulled, and
re-applied only the two genuinely-local preferences. `cursor/settings.json`'s
`autoDetectColorScheme` turned out to already be upstream. Stash `stash@{0}` still exists —
drop it when satisfied.

**Binary upgrades.** Answered the actual question first: `sync.sh` is a **no-op** here (every
target already symlinked), and bare `download.sh` is **unsafe** — its upgrade block is
unreachable without also running destructive repo regeneration. Ran the upgrades directly
instead: 40 brew formulae, bun 1.3.9→1.3.14, deno 2.6→2.9.4, uv 0.8.11→0.12.1,
br 0.1.7→**0.2.19**, bv→0.18.0.

**Then the audit cascaded.** A stray `.gitattributes-E` file led to `sed -i -E` being a BSD
no-op, which led to a whole defect **class**: GNU-only coreutils + `2>/dev/null` + a
plausible fallback = a confident wrong answer with no error anywhere.

Shipped, all with before/after suite evidence verified independently (not just agent-claimed):

| what | evidence |
|---|---|
| `session-start.sh` `sed -i` (`ce5f531`) | merge-driver 1/14 FAIL → 14/14 |
| `_al_mtime` GNU `stat -Lc` + `declare -A` (`d063a13`) | staleness **9/25 FAIL → 25/25** |
| githooks gated **7** scripts on nothing (`3fe8494`) | staging `session-start.sh`: 0 suites → 4 suites / 65 cases |
| portability shim, guards fail closed (`6a46488`) | worktree-guard **4/9 FAIL → 12/12**; stop-context 3/16 → 18/18; shared-tree 2/2+1skip → **37/37 0 skipped**; new `test-portable` 34/34 |
| `mac.upgrade.sh` created + `download.sh` vendor-only (`85000d4`) | script actually executed, not just written |
| `mac.setup.sh` parity, all 3 boxes probed (`db183e0`) | 12 tools added; `set -euo pipefail` + helpers |

**The one that matters most:** `pre-tool-use-worktree-guard.sh` used `realpath -m` (GNU-only)
with a `|| echo "$FILE_PATH"` fallback — so on **every Mac** the guard that stops a subagent
writing into the main repo was prefix-checking an *unnormalized* path, and reporting success.
It now fails closed. Isolation enforcement on this machine was degraded the whole time.

## Decisions made this session
None filed as `-t decision` beads (harvest receipt: `0 … 19 scanned` — a genuine zero).

One judgment call worth noting narratively: I held `tmux` back from the first `brew upgrade`
to protect a Jun-3 durable session, on the theory that a protocol-version bump would strand
it. Zig overrode it; I upgraded, and **measured that the concern was unfounded** — a 3.7b
client attaches to the 3.6a server fine. Recorded in `dotfiles-3iyn` so the next person
doesn't re-derive the fear. The running server stays on 3.6a until restarted.

## Proposed practices — where each one landed
- Upgrade ≠ vendor ≠ provision → **written into `CLAUDE.md` as rule #6** (`85000d4`)
- Guards must fail closed on normalization failure → **landed as code + asserted as an
  invariant** by `agents/hooks/test/test-portable.sh`
- One portability implementation, not N → **landed as `agents/hooks/lib/portable.sh`**
- Upgrade scripts should verify a formula's tap is present → filed as `dotfiles-0fdc`
- An upgrade that dirties a tracked dotfile should fail loudly → filed as `dotfiles-1cg0`

## What's next
1. **`dotfiles-2ap6`** — three `SKILL.md` bodies hand agents GNU-only `stat -c`/`date -d`
   snippets. Hit live during *this* offboard. Widest blast radius left: it is CLAUDE.md
   rule #2 (a documented example is executable) in the always-loaded tier.
2. **`dotfiles-cs8p`** — `pre-commit-checks` 11/85 on macOS. Verified **PRE-EXISTING**
   (identical at `164b161`), so not a regression — but the pulse ledger schema gate
   currently *does not block* on a Mac, and `"row":null` is exactly what it exists to stop.
3. **`dotfiles-pryc`** → unblocks the second half of **`dotfiles-ren9`**, which is the only
   partially-landed bead.

## Warnings / watch-outs
- **`brew outdated` lies here.** It returns empty, rc=0, while formulae from an untapped
  tap are invisible. `koekeishiya/formulae` is gone, so **yabai 7.1.16 and skhd 0.3.9 are
  frozen and unreportable**. A clean `brew outdated` is not evidence (`dotfiles-0fdc`).
- **`bun upgrade` writes into the tracked repo.** `~/.zshrc` is a symlink, so bun appended a
  hardcoded `/Users/zig/.bun/_bun` — re-introducing the exact anti-pattern the repo had
  deliberately removed. Reverted; it will come back on every upgrade (`dotfiles-1cg0`).
- **`core.hooksPath` was UNSET on this clone** until today. `tools/githooks/pre-commit` had
  never gated a commit here — which is *why* the `sed`/`stat` bugs survived locally. It is a
  per-clone setting; check it first on any other machine.
- **This Mac is `zig`, not `zig-computer`** (that's the Ubuntu box). There is no
  `zsh/.zig.zshenv`, so `ANTHROPIC_BASE_URL` is unset and this box is **not gateway-routed**.
  May be deliberate — `dotfiles-406` says the laptop was deferred from the tailnet — but
  there is also **no `tailscale` binary at all** here, which the `ssh-zig`/`ssh-pico` aliases
  quietly paper over with a hostname fallback (`dotfiles-4vzy`).
- **`br` jumped 0.1.7 → 0.2.19.** `.beads/config.yaml` had `issue_prefix` commented out, so a
  fresh clone minted one `bd-*` id before it was caught; an inert tombstone remains in the
  JSONL (`--hard` did not prune it, contrary to its own `--help`).
