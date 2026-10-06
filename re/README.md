# re/ — the opt-in reverse-engineering tier

This directory supports `/cleanroom` (oracle-driven clean-room reverse engineering). It has no settings files of its own. It indexes a tier that spans several tool directories. It also explains why you must choose to install this tier.

## ⛔ The inventory is NOT here

Find the installed tools, their versions, their limits, and the **absent** tools in one file:

    agents/skills/cleanroom/reference/tool-shelf.md

The file records checks on zig-computer from 2026-08-07. It is a snapshot. Check a fact again before you rely on it. **Do not copy its contents into this repository.** Tool facts can change quickly. An old copy can look current when you use it.

## Install

Choose to install this tier separately. The baseline setup does not install it:

```bash
bash re.setup.sh --dry-run     # print the plan, touch nothing
bash re.setup.sh               # install; idempotent, safe to re-run
```

The script installs a deliberately low-cost apt set and installs `frida-tools` into `~/.venvs/re`. PEP 668 blocks a bare `pip install` on this box. The script prints `RE_SETUP_RESULT=<verdict>` on every terminal path. A caller must treat exit `0` without that marker as failure.

The script **does not** install Ghidra, angr, Qiling, qemu, AFL++, or any emulator. Choose those tools for a tier when a target needs them. This separate installation avoids a speculative 400 MB dependency.

Run `re.setup.sh` again to upgrade this tier. There is no `re.upgrade.sh`. Repository rule 6 says upgrade ≠ vendor ≠ provision. This script provisions the tier. It upgrades in place because the tier is one apt set and one venv.

## Link the configs

```bash
./sync.sh gdb
./sync.sh radare2
./sync.sh frida
```

Read the destinations in the `sync()` case statement in `sync.sh` rather than trusting a table in this file.

| Directory | What it is |
|---|---|
| `gdb/` | `.gdbinit` is a commented stub. The stock gdb here supports **x86-64 only**. |
| `radare2/` | `radare2rc` is a commented stub. Scripted `r2 -q -c` runs read it too. |
| `frida/agents/` | Frida agents instrument programs. Existing `__handlers__` files can become stale. |

Ghidra has no settings directory here. `dotfiles-vpae` removed it on 2026-08-16. When you install Ghidra, run `mkdir ~/ghidra_scripts`. Find the full headless guidance in the agent tier's cleanroom tool-shelf through `~/.agents`.

## Why every config here is an inert stub

No one has used these tools on this box. Most are not installed. A config file full of untested settings is worse than an empty one. The tools read their config files every time they run, including unattended runs.

An untested setting can change the output format that a script reads. The script can still report success. Therefore, each file contains only comments about its intended settings and the one gotcha that matters. Uncomment a line only after you see it work on this box.
