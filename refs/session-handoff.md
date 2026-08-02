# Session handoff — 2026-08-01 (metis)

Machine: **metis** (personal Mac). The note previously in this slot was written the
same day from **zig** (work Mac) — same task shape, different box, and its warnings
were load-bearing here. Recover it with `git show 976710f:refs/session-handoff.md`;
the `core.hooksPath` item in it is the reason this session found a live gap.

## State at offboard

- Branch: `main`, pushed and clean (`0 0` vs origin), last commit `2c70a59`
- Open beads: 7 pre-existing, untouched. `dotfiles-v26x` created AND closed this session
- In-flight subagents: none — one worktree merged, branch deleted, worktree removed
- Dirty: `sketchybar/sketchybarrc` (modified) + `sketchybar/hooks/` (untracked) —
  **deliberately left uncommitted**, see below
- Markers: stale `.offboard-pending` (0 bytes, dated 2026-06-05) cleared

## What happened this session

Task: pull latest dotfiles onto metis, walk the conflicts, then upgrade the binaries.

### The pull — 515 commits, zero real conflicts

metis was pinned at `3c1ab2f` (2026-06-05), **515 behind and 0 ahead**, so a pure
fast-forward. Five tracked files were dirty. The useful finding: **four of the five were
already upstream, byte-identical** — the `~/.local/bin` PATH line in `bash/.profile`,
`zsh/.zprofile`, `zsh/.zshrc`, and a two-key reorder in `claude/settings.json`. zig had
committed the same edits months earlier. Each was verified against
`git show origin/main:<file>` *before* discarding, so nothing was lost.

The only genuine local change was `sketchybar/sketchybarrc` (dynamic hook glob → curated
`ts4`/`zig-computer`/`ss14` list) plus the untracked `sketchybar/hooks/` (5 scripts).
Upstream has **0 commits** touching either path, so both survived untouched. Zig chose
not to commit them — they stay metis-local, consistent with what the prior note already
recorded about `sketchybar/hooks/`.

### The upgrade — `mac.upgrade.sh --trust-taps --casks`

66 formulae + 3 casks. All four window-manager services came back healthy (rc=0). The
final sweep — including third-party taps probed by **full name**, since bare
`brew outdated` cannot be trusted here (`dotfiles-0fdc`) — shows nothing outdated.
`sf-symbols` was completed by Zig by hand; it needs interactive sudo, which a
non-interactive run cannot supply.

Three sections reported failure. **None were broken binaries:**

1. **A real defect, now fixed — `dotfiles-v26x`.** See below.
2. **`pnpm self-update`** failed on `/home/ubuntu/.local/share/pnpm`. **Not a dotfile
   bug** — under `env -i zsh -l` the var is correctly unset. It is a stale `PNPM_HOME`
   baked into the long-running tmux server's environment, inherited by every child.
   Same reason the server was still tmux 3.6b. ⚠️ The first probe of this was **invalid**:
   plain `zsh -l -c` inherits the parent's exported env and merely echoed the stale value
   back. `env -i` is the correct probe — worth remembering, it nearly produced a
   confident wrong diagnosis.
3. **`sf-symbols`** needed interactive sudo, and `brew update` itself errored on a dead
   `homebrew/cask-fonts` tap.

### Cleanups applied

- `brew untap homebrew/cask-fonts` — dead tap; `brew update` now exits 0 clean
- `brew uninstall bv` — dropped brew's frozen 0.16.4. The curl-installed 0.18.0 at
  `~/.local/bin/bv` already won on PATH; this is `mac.upgrade.sh`'s own documented
  decision and makes `br`/`bv` agree with the pico + ubuntu boxes
- **`git config core.hooksPath tools/githooks`** — see below

## `core.hooksPath` was UNSET on metis too

The prior handoff said: *"It is a per-clone setting; check it first on any other
machine."* Checked — **unset here**. So `tools/githooks/pre-commit` had never gated a
commit on this clone, and the guard added below would have had no caller on the very
machine that found the bug.

Now set. Proven to fire, not assumed: staging an unmodified file exits 0 **silently**
(nothing staged → nothing checked), which is *not* evidence. With a real staged diff:

```
pre-commit: running agents/hooks/test/test-mac-upgrade-brew-order.sh
PASS: 20/20 sec_brew() ordering cases
```

Note this is local git config, so it is **not** carried by a pull. Any further clone —
including a fresh one on this box — needs it again. CLAUDE.md rule 1 documents it.

## The fix (`dotfiles-v26x`, merged `6e7db80`, pushed in `2c70a59`)

**Symptom:** the script printed `✓ no untrusted taps blocking upgrades` and then, in the
same run, brew printed `Skipping sketchybar / bv / yabai / borders: tap formula is not
trusted`. `--trust-taps` was passed, found nothing to trust, and silently no-opped —
the exact silent-no-op class the script's own header was written to prevent.

**Root cause:** the untrusted-tap probe ran *before* `brew update`, reading stale tap
metadata. Proof, same formula either side of the refresh:

```
at probe time : brew outdated --verbose dicklesworthstone/tap/bv -> (empty)
after update  : ...                                              -> 0.16.4 < 0.18.0
```

**Fix:** reorder to update → migrate → probe → trust → upgrade. Verified independently
on merged main (not taken on the subagent's word): `update`(26) → `probe`(47) →
`trust`(61) → `upgrade`(80), suite 20/20.

The subagent also found something the bead missed: **`tools/githooks/pre-commit` had no
arm reaching `mac.upgrade.sh`**, so a new guard there would have had no caller — the same
failure mode as `dotfiles-dijt`. It added a `mapped_suites_for` entry.

`agents/hooks/test/test-mac-upgrade-brew-order.sh` — 20 cases in three layers: static
anchor-ordering; a runtime layer driving the script against a **stub `brew`** that
reproduces the measured staleness; and a mutant-dies check. The guard was **observed
failing** (9/20) against a deliberately reintroduced bug, reproducing the original
symptom end to end. A guard never seen to fail is not a guard.

Nuances worth keeping:

- Both detection branches are stale-sensitive but fail *differently*. The
  `trust|No available formula` branch fires off **error text**, which is
  metadata-independent, so a tap whose formulae fail to load is caught either way. The
  branch that genuinely goes silent under stale metadata is the second one (the `bv`
  case). Blast radius is taps whose formulae still load — which is why `--dry-run` on
  this box reports one tap rather than four.
- **`--dry-run` cannot exercise the fix's happy path.** `run brew update` is withheld, so
  the probe still sees the pre-run index. Dry run proves ordering and inertness only; the
  stub-driven suite is what proves behavior. Do not read a green `--dry-run` as evidence.
- `shellcheck` is not installed on this box, so that check did not run.

Related and still open: **`dotfiles-0fdc`** (bare `brew outdated` returns rc=0 while
formulae from an *untapped* tap are invisible). Distinct from `v26x` — that one is about
taps being absent, this one about metadata being stale. They compose badly: either alone
makes a clean `brew outdated` untrustworthy.

## What's next

- **tmux server restart.** Zig elected to `tmux kill-server` to adopt 3.7b (binary 3.7b,
  server 3.6b) and clear the stale `PNPM_HOME`. Deferred to the very end of the session
  because it ends every window, including the one this session ran in. If it did not
  happen, it is **not urgent** — `dotfiles-3iyn` records the measurement that a 3.7b
  client attaches to a 3.6x server fine. After a restart, `pnpm self-update` should
  succeed; it is also simply unnecessary, since pnpm 10.28.1 at `~/Library/pnpm/pnpm`
  is not brew-managed and works.
- **`sketchybar/sketchybarrc` + `hooks/` remain uncommitted by choice.** If they should
  reach the other machines they need a commit; until then, dirty state here is expected
  and is not something to "clean up".
- `brew update` still emits `gh auth git-credential get: gh: command not found` during a
  private-tap credential fetch — brew sanitizes PATH, so the bare `gh` credential helper
  (from `3c1ab2f`) is not found. Harmless for public taps; unresolved, not filed.
- 7 pre-existing open beads untouched (`ukx.6`, `ukx`, `cl8`, `ukx.10`, `5e2`, `st2`,
  `406`) — the local-models arc. Nothing here blocks them.

## Warnings / watch-outs

- **`env -i` when probing whether a dotfile fix took.** A plain login shell inherits the
  caller's exported environment and will happily confirm your bug still exists when it
  does not, or vice versa. This session nearly mis-filed the pnpm failure as a dotfile
  defect on exactly that mistake.
- **A gate that exits 0 with no output has not run.** Staging an unmodified file produces
  a clean, silent, meaningless pass. Force a real staged diff before believing a hook.
- **`core.hooksPath` is per-clone and invisible to `git pull`.** Two machines have now
  been found with it unset. Check it on any box before trusting that commit-time
  guards ran there.
