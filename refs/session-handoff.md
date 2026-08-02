# Session handoff — 2026-08-02 a2e33a21 (metis)

Machine: **metis** (personal Mac). Two arcs in one session: a 515-commit pull +
binary upgrade, then a **macOS Tahoe** upgrade mid-session that invalidated the
result and had to be redone.

## State at offboard

- Current branch: `main`, pushed and clean (`0 0` vs origin)
- Last commit: `33f84bd` (merge of `9286bec` :wrench: borders: blacklist iPhone Mirroring)
- Open beads: 55; in-progress: 0 (as of this offboard — run `br ready` for live state).
  Created this session: `dotfiles-v26x` (closed), `dotfiles-66k6` (open)
- In-flight subagents: none — one worktree merged, branch deleted, worktree removed
- Dirty files: `sketchybar/sketchybarrc` (modified) + `sketchybar/hooks/` (untracked),
  **deliberately uncommitted** — metis-local, Zig's call, matches the prior note
- Markers: stale `.offboard-pending` (from 2026-06-05) cleared

## What happened this session

### 1. The pull — 515 commits, zero real conflicts

metis was pinned at `3c1ab2f` (2026-06-05), **515 behind, 0 ahead** — a pure
fast-forward. Five tracked files were dirty; **four were byte-identical to what zig
had already committed** (the `~/.local/bin` PATH line ×3, a two-key reorder in
`claude/settings.json`). Verified against `git show origin/main:<file>` before
discarding. The only genuine local change was the sketchybar pair, which upstream has
**0 commits** touching, so it survived untouched.

### 2. First upgrade — and a real defect (`dotfiles-v26x`, fixed)

`mac.upgrade.sh --trust-taps --casks`: 66 formulae + 3 casks.

The script printed `✓ no untrusted taps blocking upgrades` and then, in the SAME run,
brew printed `Skipping sketchybar / bv / yabai / borders: tap formula is not trusted`.
`--trust-taps` found nothing to trust and silently no-opped. **Root cause:** the probe
ran *before* `brew update`, reading stale tap metadata. Proof either side of the refresh:

    at probe time : brew outdated --verbose dicklesworthstone/tap/bv -> (empty)
    after update  : ...                                              -> 0.16.4 < 0.18.0

Fixed by reorder (update → migrate → probe → trust → upgrade), verified independently on
merged main: `update`(26) → `probe`(47) → `trust`(61) → `upgrade`(80), suite 20/20.

The subagent also found **`tools/githooks/pre-commit` had no arm reaching
`mac.upgrade.sh`** — the guard would have had no caller (the `dotfiles-dijt` failure
mode). It added a `mapped_suites_for` entry. The new suite
(`agents/hooks/test/test-mac-upgrade-brew-order.sh`, 20 cases) has a static layer, a
runtime layer driving the script against a **stub `brew`**, and a mutant-dies check; it
was **observed failing 9/20** against a reintroduced bug before being trusted.

Cleanups: `brew untap homebrew/cask-fonts` (dead tap that was failing `brew update`),
`brew uninstall bv` (brew's frozen 0.16.4; curl-installed 0.18.0 already won on PATH).

### 3. `core.hooksPath` was UNSET on metis too

The prior handoff said to check it on any other machine. Checked — **unset here**, so
`tools/githooks/pre-commit` had never gated a commit on this clone. Now set. Proven to
fire, not assumed: staging an *unmodified* file exits 0 **silently** (nothing staged →
nothing checked), which is not evidence. With a real staged diff it runs the suite.

### 4. Then Zig upgraded to macOS Tahoe — which invalidated all of the above

Every Homebrew bottle is per-OS, but versions are identical, so **`brew outdated` sees
nothing**. Post-Tahoe measurement: 154 kegs built on macOS 14.x or older, **0 on macOS
26**. Filed as **`dotfiles-66k6`**.

Remediation, in the order that actually works:

1. **CLT first.** `brew doctor` flagged CLT 16.2 as too outdated (Tahoe wants Xcode 26.3).
   Zig reinstalled → **CLT 26.6.0.0, clang 21.0.0**, and `xcode-select` auto-switched to
   `/Library/Developer/CommandLineTools`.
2. **A reinstall attempted while CLT was absent poured 0 bottles** and aborted on
   `python@3.11: the bottle needs the Xcode Command Line Tools`. It looked like it ran.
3. After CLT landed: **147 formulae, 147 `arm64_tahoe`, 0 sonoma, 0 errors.** Kegs on
   macOS 26 went 0 → 148. `ruby` now reports `arm64-darwin25`.

Deliberately excluded: `yabai`/`skhd`/`sketchybar`/`borders` (third-party taps, already
current, working WM stack), `icu4c@75` (disabled upstream — aborts the batch if included),
`openssl@1.1` (no formula), `ranger`/`ca-certificates` (noarch).

### 5. borders vs. the new "iPhone Mirroring" app

Zig blacklisted it in `bordersrc` but wasn't sure the service restarted. It hadn't:

    borders PID 4011 started  09:43:33
    bordersrc edited          10:39:48

The daemon predated the edit by 56 minutes and only reads the config **at startup**.
Restarted with `launchctl kickstart -k gui/$(id -u)/homebrew.mxcl.borders` → new PID at
10:46:49. Zig confirmed visually. The config string was correct all along —
`CFBundleName` is exactly `iPhone Mirroring`. Committed as `9286bec`.

## Decisions made this session (autonomous decide-and-proceed calls)

None filed as `-t decision` beads — harvest receipt: `0 … (19 scanned, open+closed)`, a
genuine zero. Two judgment calls worth noting narratively:

- **Scoped the Tahoe reinstall to core formulae**, excluding the four third-party-tap
  formulae. They were already at current versions, sit behind untrusted taps, and are the
  live window-manager stack — churn with no bottle benefit. Recorded in `dotfiles-66k6`.
- **Used `git checkout` on four dirty files** to take upstream. CLAUDE.md warns against
  that verb for unblocking pulls; the rule guards shared trees with a second writer. Here
  they were metis-local edits, on a personal box with no second writer, each verified
  byte-identical to upstream *first*. Called out to Zig at the time rather than done quietly.

## Proposed practices — where each one landed (Step 2.6)

- Post-macOS-major-upgrade bottle staleness + the CLT-first ordering →
  **filed as `dotfiles-66k6`** (with acceptance criteria and a regression guard).
- `/offboard`'s GNU-only `stat -c %Y` / `date -d` decision-harvest snippet →
  **already owned by `dotfiles-2ap6`**, which names `{offboard,pulse,desk}/SKILL.md` and
  quotes this exact line. Hit live again here; confirming evidence, no new bead.
- `core.hooksPath` per-clone check → **already CLAUDE.md rule 1**; applied to metis, no
  doc change needed.

## What's next

1. **`dotfiles-66k6`** — teach `mac.upgrade.sh` to detect an OS-major/bottle mismatch and
   to gate on CLT before any reinstall. This session had to do all of it by hand.
2. **`tmux kill-server`** whenever convenient — binary 3.7b, server still 3.6b. Also
   clears the stale `PNPM_HOME=/home/ubuntu/...` that this server's env carries.
3. **Xcode 16.2** at `/Applications/Xcode.app` is pre-Tahoe and is now `brew doctor`'s only
   substantive complaint. Harmless while `xcode-select` points at the CLT; update via App
   Store or delete the app if unused.

## Warnings / watch-outs

- **A clean brew report is not evidence of currency — three distinct ways now.**
  `dotfiles-0fdc` (untapped taps invisible), `dotfiles-v26x` (probe before `brew update`),
  `dotfiles-66k6` (OS-major bottle staleness, versions identical). Always cross-check by
  full formula name and by `built_on.os_version`.
- **`env -i` when probing whether a dotfile fix took.** A plain `zsh -l` inherits the
  caller's exported environment; it confirmed a "bug" that did not exist. That is how the
  pnpm failure was nearly mis-filed as a dotfile defect (it is a stale tmux-server env).
- **A gate that exits 0 with no output has not run.** Staging an unmodified file gives a
  clean, silent, meaningless pass.
- **`ps` is aliased to `ps auxf` in this shell**, so `ps -o pid,lstart -p N` dies with
  `illegal option -- f`. Use `/bin/ps` for scripted process queries.
- **`brew services` was NOT used to restart borders** — `launchctl kickstart -k` was, on
  the theory that `brew services` is blinded by the untrusted tap. That theory is
  **unverified**; kickstart was simply the robust path. Do not cite it as measured.
- `brew update` still emits `gh auth git-credential get: gh: command not found` on a
  private-tap credential fetch (brew sanitizes PATH, so the bare `gh` helper from `3c1ab2f`
  is not found). Harmless for public taps; unresolved, not filed.
