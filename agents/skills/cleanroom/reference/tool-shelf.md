# The forensic + instrumentation shelf

Companion to `/cleanroom`. Read when choosing instruments; do not guess
command forms from memory.

**Verified empirically on zig-computer 2026-08-07** (Ubuntu, kernel 6.17,
x86_64, Python 3.13.7, binutils 2.45, OpenJDK 21, Rust 1.97.1, Node
v22.22.3, passwordless sudo, docker usable, `ptrace_scope=1`). Anything
marked NOT INSTALLED was checked, not assumed. **Re-verify before relying
on this — a shelf is a snapshot.**

> **The organizing axis is agent-drivability.** A worse tool the agent can
> drive unattended beats a better tool that needs a human at a GUI. This is
> the single highest-leverage lens when picking instruments for a loop.

## Headline, this box, today

| Tier | State |
|---|---|
| 0 recon | **Complete and excellent** — everything present |
| 1 static structure | **EMPTY** — no Ghidra, radare2, capstone, angr |
| 2 dynamic observation | **Half** — strace/gdb/bpftrace/tcpdump yes; **no Frida**, ltrace, valgrind, lldb, rr |
| 3 controlled execution | **EMPTY** — no Unicorn, Qiling, qemu-user, qemu-system |
| 4 differential/fuzz | **EMPTY** except `jq` + `diff` |
| emulators | **NONE installed** |

So: recon and differential comparison work today with zero setup. Anything
needing disassembly, hooking, or isolated CPU execution needs an install
first — plan for it rather than discovering it mid-loop.

---

## Tier 0 — recon. "What am I even looking at?"

All present, all trivially agent-drivable (deterministic stdout).

**Run this tier first, always.** The Atlassian Rovo "reverse engineering"
result was `file` + `strings` + `hexdump` finding an embedded ZIP, then
`python3 zipfile` extracting 100+ source files. Someone could have spent a
month disassembling instead. Ten seconds of recon is the highest
expected-value action in the whole method.

| Tool | Version | Real invocation | Notes |
|---|---|---|---|
| `file` | 5.46 | `file /usr/bin/jq` | → `ELF 64-bit LSB pie executable, x86-64 … stripped` |
| `strings` | binutils 2.45 | `strings -n 8 target` | **`strings -e l -n 6 target` for UTF-16/wide** — verified; this is the flag people forget and it is where Windows/embedded strings hide |
| `xxd` | 2024-12-07 | `xxd -l 32 target` | |
| `hexdump` | bsdmainutils | `hexdump -C -n 32 target` | |
| `nm` | 2.45 | `nm -D target` | dynamic symbols |
| `objdump` | 2.45 | `objdump -d --start-address=0x4000 --stop-address=0x4020 target` | **the only disassembler on this box, and x86-64 only** |
| `readelf` | 2.45 | `readelf -h target` | |
| `ldd` | — | `ldd target` | |
| `unzip` / `zipinfo` | 6.00 | `unzip -l t.zip` | |

**Gaps and substitutes:**

- **`binwalk` — NOT INSTALLED.** `apt install binwalk` (2.4.3, lightweight).
  The notable Tier-0 gap: carving unknown blobs and firmware for embedded
  archives/filesystems. Install it before any unknown-container work.
- **`7z` — NOT INSTALLED.** `apt install 7zip`. Python `zipfile`/`tarfile`
  cover common cases with no install.
- **`ent` — NOT INSTALLED.** Substitute verified inline: ~10 lines of stdlib
  Python for Shannon entropy (measured `/usr/bin/jq` = 4.8880 bits/byte).
  Entropy tells you packed/encrypted vs plain — worth knowing before you
  waste a day on a disassembler.

**Highest-yield recon habit:** grep `strings` output for **error messages**.
They name internal functions, describe invariants, and are the closest thing
to documentation a stripped binary carries.

---

## Tier 1 — static structure. "What is the shape?"

**Entirely absent on this box.** This is the weakest tier and needs a
deliberate install decision.

- **Ghidra — NOT INSTALLED, and NOT IN APT.** Java 21 is present so a manual
  release-zip install runs. Heavyweight (~400 MB + ~2 GB workspaces). Docker
  is a viable delivery path.

  **`analyzeHeadless` is the agent-drivable path**, and the reason Ghidra is
  worth the weight:

  ```bash
  <GHIDRA>/support/analyzeHeadless <project_dir> <project_name> \
    -import <binary> -deleteProject \
    -log ghidra.log -scriptlog script.log \
    -scriptPath <dir_with_script> \
    -postScript MyScript.java <args…>
  ```

  - `-import <file|dir>` for new binaries; `-process <project_file>` for
    something already in the project.
  - `-preScript` runs before default analysis, `-postScript` after;
    `-noanalysis` skips analysis entirely.
  - **`-scriptPath` is required** — scripts resolve **by name, not path**,
    and must be in the default package. `$GHIDRA_HOME`/`$USER_HOME` inside a
    script path must be backslash-escaped.
  - **The durable automation pattern:** the script writes JSON to a temp dir,
    `-deleteProject` cleans up, the agent reads the JSON back.

- **radare2 — NOT INSTALLED.** `apt install radare2` (5.9.8, moderate).
  **By far the cheapest way to close this tier**, and fully agent-drivable:
  `r2 -q -c 'aaa; afl; pdf @ main' -A binary`. Prefer this over Ghidra unless
  you specifically need the decompiler. (rizin not in apt on this release.)
- **capstone (Python) — NOT INSTALLED.** `apt install python3-capstone`
  (5.0.6) or `uv pip install capstone`. Lightweight.
- **angr — NOT INSTALLED**, not in apt, pip/uv only. Heavyweight (pulls its
  own capstone/unicorn/z3/pyvex, several hundred MB).

⚠️ **PEP 668:** `/usr/lib/python3.13/EXTERNALLY-MANAGED` exists, so bare
`pip install` is **blocked**. Use `apt`, `uv` (installed at
`~/.local/bin/uv`), or a venv. Expect this to bite on frida/unicorn/angr.

**Remember what this tier is for:** decompiler output is *spec input*, never
an oracle. It tells you what the code probably does. Only execution tells
you what it does.

---

## Tier 2 — dynamic observation. "What does it do when it runs?"

| Tool | State | Invocation | Agent-drivable |
|---|---|---|---|
| `strace` | **YES** 6.16 | `strace -e trace=openat /bin/echo hi` · `strace -f -c cmd` for a summary table | **Yes, fully.** Best-in-class here |
| `gdb` | **YES** 16.3 | `gdb -q -batch -ex "…"` · `-x script.py` | Yes — Python API verified working |
| `bpftrace` | **YES** 0.23.5 | `sudo bpftrace -e 'BEGIN { printf("x\n"); exit(); }'` | Yes, **via sudo only** — refuses as non-root |
| `tcpdump` | **YES** 4.99.5 | `tcpdump -D` unprivileged; `sudo tcpdump -i lo -c 2 -n` to capture | Yes via sudo; `-c N` gives a bounded exit |
| `ltrace` | NO | `apt install ltrace` (0.7.3) | Upstream is stale, often unreliable on modern glibc |
| `lldb` | NO | `apt install lldb` (1:20.0) | `rust-lldb` wrapper exists but the underlying tool does not |
| `rr` | NO | `apt install rr` (5.9.0) | Needs perf counters — **unverified on this host**, and VPS hosts often lack them |
| `valgrind` | NO | `apt install valgrind` (3.25.1) | |
| `mitmproxy` | NO | `apt install mitmproxy` (8.1.1 — old) | The agent-drivable member is **`mitmdump`**, not the TUI |

⚠️ **`gdb` here is a single-target build.** `gdb -batch -ex "set
architecture"` lists **only** `i386, i386:x86-64, i386:x64-32`. **No m68k, no
ARM, no MIPS, no SH.** For any retro or embedded work: `apt install
gdb-multiarch` (16.3, available). `target remote` support *is* present, so
the emulator-stub path works once multiarch lands.

⚠️ `ptrace_scope=1`: launching a child under strace is unrestricted;
**attaching to a non-descendant needs sudo** (available, passwordless).

### Frida — NOT INSTALLED, and it is the notable gap

Checked every form: `frida`, `frida-trace`, `frida-ps` absent from PATH; the
Python `frida` module absent; **`python3-frida` is not in apt.** Install is
`uv pip install frida-tools` (~50–100 MB; needs a venv per PEP 668).

**Agent-drivability if installed: partial-to-high.** The `frida` REPL and
`frida-trace` are interactive/streaming by nature — but the **Python bindings
are fully scriptable and unattended**, and that is the form to use in a loop:

```python
session = frida.attach("target")
script  = session.create_script(js)
script.on('message', handler)
script.load()
```

**`frida-trace` workflow**, precisely: it generates one editable JavaScript
handler stub per matched function into `__handlers__/<module>/<function>.js`
(e.g. `__handlers__/libc.so.6/statx.js`), each exporting
`onEnter(log, args, state)` / `onLeave(log, retval, state)`, and it
**auto-reloads each file as you save it**.

⚠️ **It reuses an existing handler file rather than regenerating it** — so
after changing your template you must **delete `__handlers__`** or you will
silently keep running the old handlers.

```bash
frida-trace --decorate -i "recv*" -i "send*" Safari
frida-trace -U -f com.example.app -I "libcommonCrypto*"
```

Flags: `-i` glob on functions (`MODULE!FUNCTION`), `-I` whole module,
`-a MODULE!OFFSET` for unexported functions, `-f` spawn / `-n` attach-by-name
/ `-p` pid, **`-P '{"json":true}'` to parameterize handlers without editing
them** (the agent-friendly lever), `-S` to seed `state`.
⚠️ **Include/exclude flags are procedural — order counts.**

---

## Tier 3 — controlled execution. "Run a piece of it under a microscope"

**Entirely absent.** This is the tier that manufactures re-runnability and
observability for targets that have neither (see `/cleanroom` §2).

- **Unicorn (Python) — NOT INSTALLED.** `apt install python3-unicorn`
  (2.1.1). Lightweight.
  ⚠️ **Architecture support could not be verified, m68k included.** Unicorn
  2.x builds an m68k backend upstream, but treat that as **UNVERIFIED on this
  box** until you have installed it and successfully imported
  `unicorn.UC_ARCH_M68K`. Do not plan a 68000 oracle around an assumption.
- **Qiling — NOT INSTALLED**, not in apt, pip/uv only. Moderate-heavy
  (depends on unicorn + capstone, and rootfs blobs download separately).
  This is the layer that makes Unicorn usable on *userland* binaries — OS
  emulation, syscalls, a filesystem.
- **qemu-user / qemu-system — NOT INSTALLED.** `dpkg -l` shows only
  `qemu-guest-agent` (a VM guest daemon, **not** emulation — easy to
  misread). Available: `apt install qemu-user`, `qemu-system-x86`, and
  **`qemu-system-misc` for m68k/sh4/etc.** The `-s -S` gdb stub on port 1234
  is standard in these builds but **unverified here**.

**Choosing between them:** Unicorn for a bare-metal routine with no OS
underneath. Qiling when the code expects syscalls. qemu-user when you want
to run a whole foreign-arch binary rather than instrument one function.

---

## Tier 4 — differential and fuzzing harness

| Tool | State | Notes |
|---|---|---|
| `jq` + `diff` | **YES** (jq 1.8.1, GNU diffutils) | **The differential spine.** `jq -S .` (sort keys) is what makes JSON byte-diffs stable — verified end to end, clean hunk + exit 1 |
| `hypothesis` | NO | `apt install python3-hypothesis` (6.130.5). Lightweight — the cheapest property-testing win |
| `fast-check` | NO | `npm i fast-check`. Node v22.22.3 present |
| AFL++ | NO | `apt install afl++` (4.21c) |
| honggfuzz | NO | Not in apt; source build only. Heavyweight |
| cargo-fuzz / proptest | NO | Rust 1.97.1 present, and **`cargo-miri` + `cargo-llvm-cov` ARE installed** — a partial base for coverage-guided differential work in Rust already exists |

Remember the lineage (`/cleanroom` §4): Csmith, SQLancer, jsfunfuzz, Diffy.
Differential testing is mature; you are not inventing it.

---

## Emulator debug interfaces

**No emulator is installed** — `retroarch`, `mgba`, `mesen`, `dosbox`,
`fceux`, `snes9x` all missing. apt has `retroarch` 1.20.0 and
`mgba-sdl`/`mgba-qt` 0.10.5.

This section exists because for ROM work the emulator *is* the oracle, and
they differ enormously in whether an agent can drive them.

### Mesen — the strongest agent-drivable story

**It runs headless**: load a game plus a Lua script, run at max speed until
the script calls `emu.stop()`, **which sets the process exit code.** That is
a pass/fail oracle you can drop straight into a shell pipeline — the single
most useful property on this page.

```
emu.addMemoryCallback(fn, type, startAddr [, endAddr])
memCallbackType: cpuRead 0 · cpuWrite 1 · cpuExec 2 · ppuRead 3 · ppuWrite 4
```

Callback receives `(address, value)`. **Reads fire AFTER the read; writes
fire BEFORE the write** — get this backwards and your trace is subtly wrong.
Use `emu.debugRead`/`emu.debugWrite` inside callbacks to avoid re-triggering
hooks. Event hooks: `startFrame`, `endFrame`, `codeBreak`, `stateLoaded`,
`stateSaved`. LuaSocket embedded (`require("socket.core")`).
⚠️ The Lua API is explicitly documented as **not-quite-stable across
versions** — pin the emulator build, exactly as `/cleanroom` pins everything
else.

### mGBA — two mechanisms, both real

**(a) GDB remote serial protocol stub.** Tools → "Start GDB server…" (bind
address + port), default **2345**; also `mgba -g game.elf`. Client:
`target remote localhost:2345`.
⚠️ `info proc mappings` returns nothing — GDB cannot infer GBA layout. The
standard fix is declaring the full 32-bit range mapped, which is also what
makes Ghidra's debugger work against mGBA.

**(b) Lua scripting** (0.10+, Tools → Scripting…). `emu:read8/16/32(addr)`,
`emu:readRange(addr, len)`, `emu:write8/16/32`, plus TCP sockets
(bind/listen/connect, polled once per frame) — the standard way to build an
external bridge.
⚠️ **No execution-position/PC callback** — only input-poll and frame-complete,
so PC checks require manual `step()`.

The stub halts emulation and has no scripting hook; Lua observes without
stopping. Combining them (Lua socket server + external process) is the common
pattern.

### BizHawk — powerful, but blocked on Linux

Lua via the `event` library: RAM/ROM/bus read/write callbacks **plus execute
callbacks that fire immediately before the given address executes**. Memory
accessors are domain-aware (`memory.read_u8(addr, domain)`, full
s8/u8/s16_be/le/…/u32/readfloat family, default = main memory).
⚠️ **Reading the wrong domain silently returns garbage** (255, 0xFFFFFFFF) —
a textbook shared-failure-mode trap.
⚠️ Scripts run top-to-bottom once; per-frame logic needs
`emu.frameadvance`/`emu.yield` or EmuHawk hangs.
⛔ **Hard blocker: BizHawk Lua scripting is Windows-only.** Linux/macOS needs
Wine, and no documented `--lua` CLI switch or true headless mode was found.

### RetroArch / libretro — weakest, and partly broken

**No general guest-side GDB stub.** The official "Debugging" docs are about
gdb/rr/ASAN on the RetroArch *process*, not the emulated guest.

The portable scriptable path is the **Network Control Interface** over UDP
(default port **55355**, requires `network_cmd_enable = "true"`):

```
READ_CORE_MEMORY <hexaddr> <nbytes>
WRITE_CORE_MEMORY <hexaddr> <byte…>
```

backed by the core's `SET_MEMORY_MAPS` descriptors. Response:
`READ_CORE_MEMORY <addr> <b1> <b2> …` or `<addr> -1 <error>`.

⚠️ **Legacy `READ_CORE_RAM`/`WRITE_CORE_RAM` are reported BROKEN since the
rc_client merge** — they route through the CHEEVOS path and return `-1`
(RetroArch issue #16392). Also issue #13664: **non-contiguous memory
descriptors translate to the wrong location** — a silent-wrong-answer bug,
the worst kind for an oracle.
⚠️ **UDP datagrams drop even on loopback** — build retry-on-timeout in, or
your oracle reports "no data" for what was really a lost packet.

Guest breakpoints exist only per-core: BlastEm (Genesis) can act as a GDB
remote stub (its libretro port's debugger is limited); Citra exposes
`citra_use_gdbstub`.

**Verdict for ROM oracles:** prefer **Mesen** (headless + exit code) where the
system is supported, **mGBA** where it is not, and treat **RetroArch's network
interface as a last resort** — it has two open silent-wrong-answer bugs, which
is disqualifying for an instrument whose entire job is being trusted.

---

## Installing for a real run

Minimum sensible additions on this box, cheapest-first:

```bash
sudo apt install binwalk radare2 python3-capstone python3-unicorn \
                 gdb-multiarch ltrace python3-hypothesis
# Frida needs a venv (PEP 668):
uv venv ~/.venvs/re
uv pip install --python ~/.venvs/re/bin/python frida-tools
```

⚠️ `uv venv` does **not** place a `uv` binary inside the venv, so
`~/.venvs/re/bin/uv pip install …` fails — target the venv's interpreter with
`--python` instead. Verified empirically against uv 0.11.32; this file carried
the broken form until 2026-08-08.

On this box the whole tier is wrapped: **`~/dotfiles/re.setup.sh`** (idempotent,
`--dry-run`, one `RE_SETUP_RESULT=` on every path) installs exactly the packages
above and builds that venv. Prefer it over running these by hand.

Then **verify, do not assume** — especially
`python3 -c "import unicorn; print(unicorn.UC_ARCH_M68K)"` before planning a
68000 oracle, and `gdb-multiarch -batch -ex "set architecture"` before
planning any cross-arch debugging.

## Sources

mgba.io/docs/scripting.html · felixjones.co.uk/mgba_gdb/vscode.html ·
mesen.ca/docs/apireference/callbacks.html · mesen.ca/docs/debugging/scriptwindow.html ·
tasvideos.org/Bizhawk/LuaFunctions · docs.libretro.com/development/retroarch/network-control-interface/ ·
docs.libretro.com/development/retroarch/debugging/ ·
github.com/libretro/RetroArch/issues/16392 · github.com/libretro/RetroArch/issues/13664 ·
frida.re/docs/frida-trace/ · sensepost.com/blog/2025/using-improving-frida-trace/ ·
ghidra.re/ghidra_docs/api/ghidra/app/util/headless/AnalyzeHeadless.html
