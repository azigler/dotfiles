# azigler/dotfiles

> [!NOTE]
> Dotfiles, settings, keys, fonts, themes, and plugins for developers 💠

<!-- omit from toc -->
## Table of Contents

- [Background](#background)
- [Two tiers](#two-tiers)
- [Usage](#usage)
  - [Three jobs, three scripts](#three-jobs-three-scripts)
  - [Extension lists are additive](#extension-lists-are-additive)
  - [Install](#install)
  - [Add or remove dotfiles](#add-or-remove-dotfiles)
  - [Add or remove resources](#add-or-remove-resources)
  - [Uninstall](#uninstall)

## Background

This repository contains dotfiles[^1] for [azigler](https://github.com/azigler). One repository makes these settings easier to share and synchronize across machines. The repository records [azigler](https://github.com/azigler)'s preferred settings. Others can use it as a starting point for their own dotfiles.

## Two tiers

These dotfiles form the **public tier**. It contains only program settings for the shell, tmux, editors, and language toolchains. It also contains scripts that install them. Nothing here needs an agent. A machine can clone only this repository and get a complete, working environment.

The **agent tier** — the always-loaded instruction file, the skills, the hooks, the schedulers, and the machine-specific reference material they read — lives in a **separate repository**, because it describes real hosts and real services. At runtime, the `~/.agents` symlink points to the tier. Every line in `sync.sh` that uses the tier goes through that one symlink.

The public tier works even when the agent tier is absent:

| | with an agent tier installed | without one |
|---|---|---|
| `./sync.sh` | links settings **and** connects `~/.claude`, `~/.codex`, `~/.cursor`, `~/.gemini` | links settings; agent-tier lines do nothing and print nothing |
| shell startup | exports `AGENTS_ROOT`; gives `claude` the session-identity wrapper | leaves `AGENTS_ROOT` unset; runs plain `claude` with one warning line |
| `prefix W` in tmux | opens the agent roster | keeps the binding, but has no target |

To install an agent tier, give its repository to `bootstrap-agents.sh`. You must provide this input. This repository does not hardcode it:

```bash
AGENTS_REPO=owner/repo            ./bootstrap-agents.sh   # short form: cloned with `gh`, so a private repo works
AGENTS_REPO=git@host:owner/repo   ./bootstrap-agents.sh   # any git URL: cloned with `git`
AGENTS_REPO=/path/to/local/clone  ./bootstrap-agents.sh   # a local checkout works too
```

The script clones the repository into `~/<repo>` by default. Set `AGENTS_DIR` to change that location. The script refuses a repository that has no agent tier. It creates `~/.agents` and runs `./sync.sh claude` again. You can run the script more than once without changing the result after its first run. It never pulls a clone that you already have.

## Usage

> [!WARNING]
>
> - Create your own backups before you run `sync.sh`. The script also creates backups in `$SCRIPT_DIR/.backup` before it creates a symlink.
> - Expect `sync.sh` to move `$HOME/.ssh/config` to `$HOME/.ssh/local`. The `$SCRIPT_DIR/ssh/config` file from this repository includes that local file.
> - Expect `download.sh` to copy your public SSH key to `$SCRIPT_DIR/ssh/$(hostname -s).pub`. It also copies your default public GPG key to `$SCRIPT_DIR/gnupg/$(hostname -s).asc`. The `$(hostname -s)` command gives your machine's hostname without its domain. Remove those lines from the script to stop these copies.
> - Check for sensitive information and credentials before you publish your copy of this repository.

Use the bash scripts `sync.sh` and `download.sh` to manage your dotfiles. In both scripts, `$SCRIPT_DIR` means the script's location, which is the repository root.

- Run `sync.sh` to synchronize your machine's dotfiles with your local clone. The script creates symlinks from your home directory to this repository. Usually, you only need to run it once per machine. If dotfiles already exist in your home directory, the script saves them in `$SCRIPT_DIR/.backup`.
- Run `download.sh` to download resources, such as plugins and fonts, for these dotfiles. The script also updates `$SCRIPT_DIR/vscode/install_extensions.sh` and `$SCRIPT_DIR/cursor/install_extensions.sh` with extensions installed on your machine. You may want to run it regularly to keep resources current, depending on how you use the repository.

Both scripts are idempotent[^2]. [Fork this repository](https://github.com/azigler/dotfiles/fork) to save your changes.

### Three jobs, three scripts

`sync.sh` links dotfiles. `download.sh` downloads supporting resources. The per-machine `*.upgrade.sh` scripts upgrade software. These jobs are separate by design. Previously, `download.sh` also upgraded software, but only when you ran it without an argument. You could not upgrade binaries without also regenerating every downloaded resource. You could not regenerate one resource and also run the upgrades.

| Script | Job |
|---|---|
| `sync.sh` | link dotfiles from this repository into `$HOME` |
| `download.sh` | download resources (plugins, fonts, keys, extension lists) |
| `mac.setup.sh` / `ubuntu.setup.sh` | prepare a new machine for its first use |
| `mac.upgrade.sh` | upgrade every off-the-shelf binary on a macOS workstation |
| `ubuntu.upgrade.sh` | do the same on Linux |
| `pico.upgrade.sh` | do the same on a headless macOS server |
| `bootstrap-agents.sh` | install the separate agent tier and connect `~/.agents` (see [Two tiers](#two-tiers)) |

`mac.upgrade.sh` lets you list and select sections. It also supports a dry run:

```bash
bash mac.upgrade.sh --dry-run          # print every command, change nothing
bash mac.upgrade.sh --list             # section names
bash mac.upgrade.sh --only brew        # one section
bash mac.upgrade.sh --casks            # also upgrade casks (force-quits GUI apps)
bash mac.upgrade.sh --trust-taps       # unblock third-party taps first (see below)
```

Know these two behaviors before you run it:

- On Homebrew 6, `brew outdated` and `brew upgrade` silently exclude formulae from an **untrusted third-party tap**. Both commands still exit `0`. `mac.upgrade.sh` detects and names the upgrades that could not run. Use `--trust-taps` to fix them.
- The script **skips `claude update` when `CLAUDECODE=1`**. This prevents it from replacing the binary during a live Claude Code session. Pass `--claude` to force the update.

### Extension lists are additive

The `cursor` and `vscode` cases of `download.sh` write files that git tracks. If a machine has only some extensions, these cases **add** them and remove nothing. Such a machine cannot silently shorten the canonical list. To make the tracked list match the current machine exactly, request it:

```bash
./download.sh cursor --prune     # deliberate removal; review the diff before committing
```

If the editor CLI is missing or reports zero extensions, the script leaves the tracked file alone.

### Install

> [!IMPORTANT]
> The `download.sh` script requires `curl`.

Run these commands in a terminal to synchronize your machine's dotfiles and download the latest supporting resources:

```bash
git clone https://github.com/azigler/dotfiles
cd dotfiles
./sync.sh
./download.sh
```

The install is complete without an agent tier. To add one later, see [Two tiers](#two-tiers):

```bash
AGENTS_REPO=owner/repo ./bootstrap-agents.sh
```

### Add or remove dotfiles

Edit the `sync.sh` case statement to add or remove synchronized dotfiles. The statement checks the folders in this repository. Make sure each entry has a matching folder. For example, to synchronize `$SCRIPT_DIR/new_dotfile_folder/new_dotfile` to `$HOME/.new_dotfile`:

```sh
"new_dotfile_folder")
    sync_source "$SCRIPT_DIR/new_dotfile_folder/new_dotfile" "$HOME/.new_dotfile"
    ;;
```

To synchronize all of `$SCRIPT_DIR/new_dotfile_folder` to `$HOME/.new_dotfile_folder`:

```sh
"new_dotfile_folder")
    sync_source "$SCRIPT_DIR/new_dotfile_folder" "$HOME/.new_dotfile_folder"
    ;;
```

### Add or remove resources

>[!TIP]
> Add downloaded resources, such as cloned repositories, to `.gitignore`. This keeps duplicate source code out of the repository and reduces clutter.

Edit the `download.sh` case statement to add or remove supporting resources. The statement checks the folders in this repository. Make sure each entry has a matching folder. For example, to download `https://url-to-download.com` to `$SCRIPT_DIR/new_dotfile_folder`:

```sh
"new_dotfile_folder")
    fetch_file "https://url-to-download.com" "$SCRIPT_DIR/new_dotfile_folder"
    ;;
```

### Uninstall

To uninstall, replace the symlinks with your original dotfiles from `$SCRIPT_DIR/.backup`. You can also remove the symlinks.

[^1]: Dotfiles are settings files that change how software and tools work and look. Traditionally, a dotfile is a file or folder whose name starts with `.`. In this repository, a dotfile is any settings file or folder.

[^2]: Idempotence means that running a function more than once does not change the result after its first run.
