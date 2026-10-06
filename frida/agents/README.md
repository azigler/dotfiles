# frida/agents/

This directory contains Frida scripts for instrumenting programs. `./sync.sh frida` links `dotfiles/frida/` to `$HOME/.config/frida`. The scripts then appear at `$HOME/.config/frida/agents/`.

**This directory is empty on purpose.** This box does **not have Frida installed**. It has neither the CLI nor the Python module. Apt has **no `python3-frida`**. PEP 668 blocks a bare `pip install` (`/usr/lib/python3.13/EXTERNALLY-MANAGED`). Therefore, Frida uses its own venv.

`bash re.setup.sh` creates `~/.venvs/re` and installs `frida-tools` there. The script adds nothing to `PATH`. Run `~/.venvs/re/bin/frida` directly.

Find the full inventory, including versions, flags, and absent tools, in one place only:

    agents/skills/cleanroom/reference/tool-shelf.md

## The two things to know before you write a script here

**1. `__handlers__` is stale by default. This is the trap.** `frida-trace` creates one editable JavaScript handler stub for each matched function. It writes each stub to `__handlers__/<module>/<function>.js`, such as `__handlers__/libc.so.6/statx.js`. Each stub exports `onEnter(log, args, state)` and `onLeave(log, retval, state)`. `frida-trace` reloads a file automatically when you save it.

⚠️ **`frida-trace` reuses an existing handler file instead of regenerating it.** If you change the template and run the tool again, it still uses the old handlers. The run succeeds, but the trace is wrong. The tool gives no warning. **Delete `__handlers__`** after each template change.

The agent-friendly lever is `-P '{"json":true}'`. It passes parameters to handlers without editing them, so it avoids stale handler files. The `-S` flag seeds `state`. The `-i`, `-I`, and `-a` include-exclude flags act in order. **Their order matters.**

Treat generated `__handlers__/` trees as temporary files. Never commit one here.

**2. Use the Python bindings for agent-driven work.** The `frida` REPL and `frida-trace` are interactive and stream output. Use the bindings for unattended work:

```python
session = frida.attach("target")
script  = session.create_script(js)
script.on('message', handler)
script.load()
```

A `.js` agent in this directory is the payload. A small Python driver loads it and collects `message` events. The driver writes JSON for the caller to read. The former Ghidra scripts used the same pattern for the same reason. `dotfiles-vpae` removed that directory. `re/README.md` still explains the pattern.

⚠️ This box has `ptrace_scope=1`. Use sudo to attach to a process that is not a descendant. Sudo requires no password on this box. Spawning with `-f` does not need sudo.
