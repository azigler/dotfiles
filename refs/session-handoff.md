# Session handoff — 2026-07-28 · vps-8a9eb245 becomes Zig's own machine

Session id: `7f6d0b60-cfc5-467c-9931-3240fb6e0cc2`

Supersedes the 2026-06-06 note (`beb8609d`), which described zig-computer work
and was seven weeks stale.

## State at offboard

- **Branch**: main @ `4461a22`, clean working tree, pushed
- **Box**: `vps-8a9eb245` (NOT the `zig-computer` that `agents/infra.md`
  documents — that file is a different machine's baseline and does not describe
  this box)
- **Beads**: closed `dotfiles-f8f2`; filed `dotfiles-qcfx` (P2)
- **`.offboard-pending`**: cleared

## The framing that explains everything below

This box was provisioned as a **marketing-vps PEER** — a coworker-facing,
read-only consumer scoped to seven LinearB slugs. Zig's instruction this session
was to make it **his own machine**. Nearly every problem found was the same
shape: something scoped narrowly for the peer role, silently excluding his own
work.

Three independent instances, none of which ever raised an error:

1. `~/dotfiles` was a **sparse checkout** (cone: `agents`, `claude`). The shell
   tier was still served by `~/marketing-vps`.
2. The **transcripts + memory vaults** were sparse to the same seven LinearB
   slugs. 387 dotfiles transcripts and the whole memory tier sat in the vault,
   unreachable here.
3. `~/bin/vps-repo-refresh.sh` is a 49-line stub of a tracked 447-line script.

## What changed

**Full checkout** — `git sparse-checkout disable`.

**Per-host shell files** (`2b8d22a`): `zsh/.vps-8a9eb245.zsh`,
`bash/.vps-8a9eb245.bashrc`, and a new tier `zsh/.vps-8a9eb245.zshenv`.

> The `.zshenv` tier is the non-obvious one. `ssh host "cmd"` reads `.zshenv`,
> not `.zshrc`, so remote pulse dispatch only resolves toolchains if PATH is set
> there. That content had been written straight to `~/.zshenv` during migration
> Phase 1.2 — where the very first `sync.sh zsh` would have silently reverted
> it, because sync symlinks the fleet-wide `zsh/.zshenv` over it. `zsh/.zshenv`
> now sources `.${HOST%%.*}.zshenv`.

All toolchain hooks here are **guarded**, unlike the laptop per-host files.
Those boxes have a physical keyboard; a hook that errors on every shell start on
this one is not locally fixable.

**tmux ownership** — `tmux/tmux.service`, a systemd USER unit. Installed and
enabled, deliberately **not started**. See "Open" below.

**Vault slug aliasing** (`88e0eae`) — the slug is path-derived, so `~/dotfiles`
is `-home-andrew-dotfiles` here but `-home-ubuntu-dotfiles` on zig-computer. The
peer wiring in `session-start.sh` aliased only `-home-andrew-linearb*`, so
dotfiles sessions wrote to a dir both `.excludes` files hard-exclude via
`/-home-andrew*`. Never staged, never pushed, and the hourly timer logged `OK`
throughout — the silent-success class this harness already has a bead about
(`dotfiles-cxle`).

A second bug fell out of the first: that block only ever appended to the
**transcripts** cone. linearb was covered in the memory vault by accident — its
cone is the glob `/-home-ubuntu-linearb*/`. dotfiles is the first shared
non-linearb project, so it would have synced transcripts while its memory tier
stayed dark. Both cones now.

**Two `/home/ubuntu` hardcodes** dropped from the fleet-wide `zsh/.zshrc`.

## Evidence

- `zsh -l -i -c` exits 0; 15/15 links resolve into `~/dotfiles`; zero
  `marketing-vps` symlinks left in `$HOME`
- tmux conf validated on a **throwaway `-L bootstrap` socket** so the live
  server was never touched — parsed clean, catppuccin applied, 7 plugins via tpm
- vault: commit `b3465af`, 389 jsonl in the canonical dir, 0 unpushed. The live
  session file grew 955305 → 956937 bytes across the rename, proving the open
  write handle survived and this transcript is in the vault.
- 22/22 hook tests pass; `test-vps-repo-refresh.sh` 39/39
- before/after probe of the slug wiring against a throwaway `$HOME`, with the
  block extracted by its own comment markers so the probe cannot drift from the
  file it tests

## Open

**The tmux restart is Zig's to run, and the ownership claim is UNPROVEN until he
does.** The server is still the old one in `session-140.scope`. It survives
logout today only because `KillUserProcesses` defaults to `no` and `Linger=yes`
— policy, not ownership.

```
systemd-run --user --collect --unit=tmux-cutover \
  /bin/sh -c 'tmux kill-server; sleep 2; systemctl --user start tmux.service'
```

Then reattach and run the proof:

```
systemctl --user show tmux.service -p ControlGroup
```

It must read `.../user@1002.service/tmux.service`, NOT `session-<n>.scope`.

**`dotfiles-qcfx`** — swap the timer off the `~/bin` stub. Not done on purpose:
the manifest's `readonly $HOME/dotfiles` also asserts no dirty tracked files,
which would fail loudly every hour while Zig has uncommitted work open. Needs a
decision about what `readonly` means now that the box is a working checkout.
`e14c5ac` (another session, same night) already relaxed the identity half.

## Warnings

- **`main` was force-pushed** (`13879a7` → `4461a22`) to fix a machine-derived
  author email on `2b8d22a`. Trees were verified identical beforehand; no
  content changed, only SHAs. **Any other checkout of dotfiles needs
  `git fetch && git reset --hard origin/main`** — notably whichever box pushed
  `741c1e8` tonight. Its `pull --ff-only` will fail loudly until it resets,
  which is the correct signal, not a bug.
- **`agents/infra.md` describes zig-computer, not this box.** Do not treat its
  IPs, ports, or timer list as this machine's baseline.
- **`~/.secrets` does not exist here** — several things reference it. The
  per-host zsh files guard on it, so it is not a shell error, but anything
  needing a credential will come up empty.
- **`claude/settings.json` no longer sets `ANTHROPIC_BASE_URL`.** It is
  fleet-wide, so that removal reaches every machine; preserved for zig-computer
  in `zsh/.zig-computer.zshenv`. A machine that needs the pico proxy and has not
  run `sync.sh zsh` since will lose it.
- `~/marketing-vps` still exists and is still the coworkers' repo. It is simply
  no longer wired into Zig's shell.
