# azigler/dotfiles

> [!NOTE]
> Developer bliss: dotfiles, configs, keys, fonts, themes, and plugins 💠

<!-- omit from toc -->
## Table of Contents

- [Background](#background)
- [Usage](#usage)
  - [Install](#install)
  - [Add or remove dotfiles](#add-or-remove-dotfiles)
  - [Add or remove resources](#add-or-remove-resources)
  - [Uninstall](#uninstall)

## Background

This repository contains dotfiles[^1] for [azigler](https://github.com/azigler). By managing dotfiles in a centralized repository, it becomes easier to synchronize and share these configurations across different machines. This repository serves as a reference for [azigler](https://github.com/azigler)'s preferred settings and can be used as a starting point for others to customize their own dotfiles.

## Usage

> [!WARNING]
>
> - The `sync.sh` script will create backups in the `$SCRIPT_DIR/.backup` folder before attempting to create a symlink, but it is recommended to create your own backups before executing `sync.sh`.
> - The `sync.sh` script will move your `$HOME/.ssh/config` file to `$HOME/.ssh/local`, which is included in the `$SCRIPT_DIR/ssh/config` file synchronized from this repository.
> - The `download.sh` script will create a copy of your public SSH key at `$SCRIPT_DIR/ssh/$(hostname -s).pub` and your default public GPG key at `$SCRIPT_DIR/gnupg/$(hostname -s).asc`, where `$(hostname -s)` resolves to your machine's hostname without domain information. Remove those lines from the script to disable this behavior.
> - Be careful not to expose sensitive information or credentials if publishing your copy of this repository.

`sync.sh` and `download.sh` are two bash scripts to assist with managing your dotfiles. In both scripts, `$SCRIPT_DIR` resolves to the location of the script (the root of the repository).

- `sync.sh` is used to synchronize your machine's dotfiles with your local clone of this repository. It creates symlinks from your home directory to the dotfiles in this repository. In most cases, you only need to run this script once per machine. If existing dotfiles are found in your home directory, they are backed up to the `$SCRIPT_DIR/.backup` directory.
- `download.sh` is used to download supporting resources, such as plugins and fonts, for the dotfiles synchronized by this repository. This script also updates the `$SCRIPT_DIR/vscode/install_extensions.sh` script with your machine's installed VS Code extensions. Depending on how you use the repository, you may wish to run this script at regular intervals to keep your downloaded resources up to date.

Both scripts are idempotent[^2]. You should [fork this repository](https://github.com/azigler/dotfiles/fork) to save any modifications.

### Install

> [!IMPORTANT]
> The `download.sh` script requires `curl`.

To synchronize your machine's dotfiles to this repository and download the latest supporting resources, run the following commands in a terminal:

```bash
git clone https://github.com/azigler/dotfiles
cd dotfiles
./sync.sh
./download.sh
```

### Add or remove dotfiles

To add or remove dotfiles synchronized by this repository, edit the `sync.sh` script's case statement that iterates over all folders in this repository. Ensure there is a corresponding folder in the repository to correspond with your entry in the case statement. For example, to synchronize the `$SCRIPT_DIR/new_dotfile_folder/new_dotfile` file to `$HOME/.new_dotfile`:

```sh
"new_dotfile_folder")
    sync_source "$SCRIPT_DIR/new_dotfile_folder/new_dotfile" "$HOME/.new_dotfile"
    ;;
```

To synchronize the entire `$SCRIPT_DIR/new_dotfile_folder` folder and its contents to `$HOME/.new_dotfile_folder`:

```sh
"new_dotfile_folder")
    sync_source "$SCRIPT_DIR/new_dotfile_folder" "$HOME/.new_dotfile_folder"
    ;;
```

### Add or remove resources

>[!TIP]
> To reduce repository clutter and exclude duplicate source code, add downloaded resources (like cloned repositories) to the `.gitignore` file.

To add or remove supporting resources, edit the `download.sh` script's case statement that iterates over all folders in this repository. Ensure there is a corresponding folder in the repository to correspond with your entry in the case statement. For example, to download `https://url-to-download.com` to `$SCRIPT_DIR/new_dotfile_folder`:

```sh
"new_dotfile_folder")
    fetch_file "https://url-to-download.com" "$SCRIPT_DIR/new_dotfile_folder"
    ;;
```

### Uninstall

To uninstall, replace the symlinks with your original dotfiles from the `$SCRIPT_DIR/.backup` directory or otherwise break the symlinks.

[^1]: Dotfiles are configuration files that customize the behavior and appearance of various software applications and tools. While traditionally referring only to a file or folder with a name that starts with `.`, in this repository a dotfile refers to any kind of configuration file or folder.

[^2]: Idempotence is defined as a function that can be executed several times without changing the final result beyond its first iteration.
