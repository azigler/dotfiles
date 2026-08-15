# re/ — the opt-in reverse-engineering tier

Scaffolding for `/cleanroom` (oracle-driven clean-room reverse engineering).
This directory holds no config of its own; it is the index for a tier that is
spread across several tool directories, and the note explaining why the tier is
opt-in.

## ⛔ The inventory is NOT here

Which tools exist, at which versions, with which gotchas, and which are
**absent** — all of that lives in exactly one file:

    agents/skills/cleanroom/reference/tool-shelf.md

It is empirically verified (zig-computer, 2026-08-07) and it is a snapshot, so
re-verify before depending on a fact. **Do not copy any of it into this repo.**
A second copy of a fast-moving fact is a copy that rots, and the rotted one is
indistinguishable from the fresh one at the point of use.

## Install

Opt-in, never part of baseline provisioning:

```bash
bash re.setup.sh --dry-run     # print the plan, touch nothing
bash re.setup.sh               # install; idempotent, safe to re-run
```

It installs a deliberately cheap apt set plus `frida-tools` into `~/.venvs/re`
(PEP 668 blocks a bare `pip install` on this box). It prints
`RE_SETUP_RESULT=<verdict>` on every terminal path — a caller must treat exit 0
without that marker as failure.

It **does not** install Ghidra, angr, Qiling, qemu, AFL++, or any emulator.
Those are per-tier decisions, made when a target actually demands one. The
whole point of the opt-in split is that we never carry a 400 MB dependency we
adopted speculatively.

Re-running `re.setup.sh` is also this tier's upgrade path; there is no
`re.upgrade.sh` (repo rule 6: upgrade ≠ vendor ≠ provision — this script is
provision, and it upgrades in place because the tier is one apt set and one
venv).

## Link the configs

```bash
./sync.sh gdb
./sync.sh radare2
./sync.sh frida
```

Destinations are declared in `sync.sh`'s `sync()` case statement — read them
there rather than trusting a table in this file.

| Directory | What it is |
|---|---|
| `gdb/` | `.gdbinit` — commented stub; the one live gotcha is that stock gdb here is **x86-64 only** |
| `radare2/` | `radare2rc` — commented stub; it is read by scripted `r2 -q -c` runs too |
| `frida/agents/` | instrumentation agents; the `__handlers__` staleness trap |

Ghidra has no config dir here (dropped 2026-08-16, `dotfiles-vpae`): on an
actual install, `mkdir ~/ghidra_scripts` — the full headless guidance lives
in the agent tier's cleanroom tool-shelf, reached through `~/.agents`.

## Why every config here is an inert stub

None of these tools has been exercised on this box — most are not installed.
A config file full of untested settings is worse than an empty one: it runs on
every invocation, including the unattended ones, and a setting that changes
output format changes what a scripted parse reads **without changing whether it
succeeds**. So each file ships commented-out, saying what belongs there and
carrying the one gotcha that matters. Uncomment a line after you have watched
it work here, not before.
