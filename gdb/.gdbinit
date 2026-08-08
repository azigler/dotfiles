# ~/.gdbinit — dotfiles/gdb/.gdbinit, symlinked by `./sync.sh gdb`.
#
# Scaffolding for the opt-in reverse-engineering tier (`bash re.setup.sh`).
# See re/README.md; the tool inventory lives in
# agents/skills/cleanroom/reference/tool-shelf.md and only there.
#
# ⛔ DELIBERATELY EMPTY. Every line below is commented out.
#
# Nothing in this file has been exercised on this box. A .gdbinit full of
# untested pretty-printers and hooks is WORSE than an empty one: it runs on
# every gdb invocation, including batch ones an agent depends on, and a
# setting that changes output format silently changes what a scripted parse
# reads. Uncomment a line only after you have watched it work here.
#
# ⚠️ THE GOTCHA THAT MATTERS ON THIS BOX
#
#   The stock `gdb` here (16.3) is a SINGLE-TARGET build.
#   `gdb -batch -ex "set architecture"` lists only:
#       i386, i386:x86-64, i386:x64-32
#   No m68k. No ARM. No MIPS. No SH. Any retro-console or embedded work needs
#   `gdb-multiarch` (apt, 16.3) — which re.setup.sh installs. `target remote`
#   support IS present in both, so the emulator-gdb-stub path works once
#   multiarch is on the box.
#
#   This file is shared by both binaries. Do not put an `set architecture`
#   line here; it will break the one that cannot do it.
#
# ⚠️ ptrace_scope=1 on this host: launching a child under gdb is unrestricted,
#   but ATTACHING to a non-descendant needs sudo (passwordless here).

# --- batch/agent ergonomics -------------------------------------------------
# Untested here. `-batch` already implies most of this, so these mainly affect
# interactive use — which is the half no agent depends on. Measure before
# enabling, especially the two that change OUTPUT (a scripted parse reads it).
# set pagination off
# set confirm off
# set print pretty on
# set history save on
# set history filename ~/.cache/gdb_history

# --- disassembly ------------------------------------------------------------
# `set disassembly-flavor` is x86-only and errors on a multiarch target that is
# not x86 — the exact reason this file stays inert.
# set disassembly-flavor intel

# --- what does NOT belong here ---------------------------------------------
# Per-target setup (architecture, endianness, `target remote localhost:2345`
# for mGBA, a declared 32-bit memory map for a GBA) is TARGET state, not user
# state. It belongs in a per-run `-x script.gdb` next to the investigation,
# where it can be version-controlled with the finding it produced.
#
# gdb's Python API is verified working here — an unattended run is
#   gdb -q -batch -x analyze.py --args ./target
# and the durable pattern is the same one Ghidra uses: the script writes JSON,
# the agent reads the JSON back. Never scrape gdb's human-readable output.
