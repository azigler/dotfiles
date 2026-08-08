# frida/agents/

Frida instrumentation scripts. `./sync.sh frida` symlinks `dotfiles/frida/` to
`$HOME/.config/frida`, so these land at `$HOME/.config/frida/agents/`.

**Empty on purpose.** Frida is **not installed** on this box — not the CLI, not
the Python module, and there is **no `python3-frida` in apt**. PEP 668 blocks a
bare `pip install` (`/usr/lib/python3.13/EXTERNALLY-MANAGED`), so it lives in
its own venv: `bash re.setup.sh` creates `~/.venvs/re` and installs
`frida-tools` there. Nothing is put on `PATH`; invoke `~/.venvs/re/bin/frida`.

Full inventory — versions, flags, what else is absent — in one place only:

    agents/skills/cleanroom/reference/tool-shelf.md

## The two things to know before you write a script here

**1. `__handlers__` is stale by default — this is the trap.** `frida-trace`
generates one editable JavaScript handler stub per matched function into
`__handlers__/<module>/<function>.js` (e.g. `__handlers__/libc.so.6/statx.js`),
each exporting `onEnter(log, args, state)` / `onLeave(log, retval, state)`, and
auto-reloads each file as you save it.

⚠️ **It REUSES an existing handler file rather than regenerating it.** Change
your template, re-run, and you silently keep running the old handlers — the run
succeeds, the trace is wrong, and nothing says so. **Delete `__handlers__`**
after any template change.

The agent-friendly lever that avoids the whole problem: `-P '{"json":true}'`
passes parameters into handlers without editing them at all. (`-S` seeds
`state`.) Note that `-i` / `-I` / `-a` include-exclude flags are **procedural —
order counts.**

Generated `__handlers__/` trees are scratch. Never commit one here.

**2. The Python bindings, not the REPL, are the agent-drivable form.** The
`frida` REPL and `frida-trace` are interactive/streaming by nature. Unattended
work uses the bindings:

```python
session = frida.attach("target")
script  = session.create_script(js)
script.on('message', handler)
script.load()
```

A `.js` agent in this directory is the payload; a small Python driver loads it,
collects `message` events, and writes JSON the caller reads back — the same
script-writes-JSON pattern the Ghidra scripts use, for the same reason.

⚠️ `ptrace_scope=1` here: attaching to a process that is not a descendant needs
sudo (passwordless on this box). Spawning with `-f` does not.
