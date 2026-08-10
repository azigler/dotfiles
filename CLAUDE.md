# dotfiles — program configuration for this machine

This repo is the **public tier**: shell, tmux, editors, language toolchains,
and the scripts that install them (`sync.sh` links, `download.sh` vendors, the
per-machine `*.setup.sh` / `*.upgrade.sh` provision and upgrade). See
`README.md` for the user-facing version of all of that.

## The agent tier is NOT here

The always-loaded instruction file, the skills, the hooks, the schedulers and
the machine reference material live in a **separate repository**, installed by
`./bootstrap-agents.sh` and resolved through one symlink, `~/.agents`. Two
consequences for anyone editing this repo:

- **Editing anything here does not change agent behaviour.** If you came to
  change a rule, a skill, or a hook, you are in the wrong repository.
- **Every agent-tier reference goes through `~/.agents`**, never through a path
  inside this repo. `sync.sh` (`sync_agent_source`), `zsh/.zshenv`
  (`AGENTS_ROOT`), `bash/.bash_aliases` (the `claude` wrapper),
  `tmux/tmux.conf` (the `prefix W` binding) and `ubuntu.setup.sh` (the journald
  drop-in) are the five places that do it. Each one is a **silent no-op or a
  single warning** when no tier is installed — keep it that way. A machine with
  only these dotfiles must sync cleanly and have no harness, not a wall of
  errors about missing files it was never going to have.

## The commit gate

`tools/githooks/` holds a `pre-commit`. **Activate it per clone:**

```bash
git config core.hooksPath tools/githooks
```

It is a per-clone local setting, so a fresh clone starts ungated until that
line runs. It checks that every staged `*.sh` parses — these scripts run on a
machine being provisioned, sometimes piped straight to `bash`, where a syntax
error lands halfway through. The hook's own header records what it used to be
and why it is small now; read it before adding to it.

## Rules specific to this repo

1. **A documented EXAMPLE is executable.** Agents and humans copy examples
   verbatim, so a wrong example is a defect that replicates itself — invisible
   to code review, invisible to tests, and it *scales with adoption*. Four
   confirmed instances as of 2026-07-25 (`dotfiles-mlti`), including a mandated
   markdown link form that didn't resolve and a commit template hardcoding a
   stale model name. **Before committing an example, run it** — and run it **as
   committed**, extracting the block from the file by regex or line range
   (`git show HEAD:<path> | awk …`) and executing *those bytes*, never a
   retyped copy, because the detail that breaks an example is usually a quoting
   or substitution one that retyping silently repairs.

2. **Don't blanket-suppress stderr** (`2>/dev/null`) on anything state-changing
   or output-bearing: the error then reads as an empty result ("no data")
   instead of the error it was. Filter the specific noise line instead. Pure
   existence checks may append `# allow-suppress`.

3. **`git add <specific-files>` only** — never `git add -A` / `git add .`, and
   never a bare directory (that stages deletions you did not choose).

4. **Upgrade ≠ vendor ≠ provision — keep the scripts separate.** `download.sh`
   once did upgrades too, in a branch reachable only with NO argument, so you
   got binary upgrades and destructive repo regeneration together or neither
   (`dotfiles-7bij`). Binary upgrades live only in `mac.upgrade.sh` /
   `ubuntu.upgrade.sh` / `pico.upgrade.sh`; `download.sh` only vendors. When
   adding a tool, add it to **every** upgrade script it applies to — and
   remember the asset names differ (`darwin_arm64`, not `linux_x64`), BSD grep
   has no `-oP`, and macOS has no `sha256sum`. `mac.upgrade.sh --dry-run`
   exercises every section without touching the machine; use it before
   committing a change there.

5. **This is a PUBLIC repository.** No hostnames, no tailnet addresses, no
   ports, no service topology, no machine inventory — that material is exactly
   what the agent tier was split out to hold. A config that needs a real
   address reads it from the environment or from a machine-local file
   (`.secrets`, `~/.gitconfig.local`, `.servers.bash_aliases` — all
   gitignored), never from a committed line.

## Beads

Prefix `dotfiles`. The orchestrator owns the lifecycle. For what is live, run
the query — `br list --type epic` / `br ready` — never a citation here.
