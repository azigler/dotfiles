# Migrating to the managed-config layout (dotfiles-tihhn)

This branch renames `codex/config.toml` to `codex/managed_config.toml` and
symlinks it to `/etc/codex/config.toml` (the System layer Codex reads but
never writes). `sync.sh codex` will try to migrate the live
`~/.codex/config.toml` symlink automatically, but the live `main` checkout
on this box has **uncommitted drift** in `codex/config.toml` right now (Codex
wrote project-trust/`[tui]` state into it, same as the bug this bead fixes).
A plain `git merge` will refuse with local changes in the way. Do the steps
in this order — do **not** `git stash` the drift, it is Codex's own runtime
state, already captured by step 1:

1. **Capture first**, before touching the repo at all:
   ```bash
   cp ~/.codex/config.toml /tmp/codex-config-pre-merge.toml
   ```
2. **Discard the drift by name** (it is now captured, not lost):
   ```bash
   git -C ~/dotfiles checkout -- codex/config.toml
   ```
3. **Merge** this branch into `main` as usual.
4. **Run** `sync.sh codex` (or `bash ~/dotfiles/sync.sh codex`). It will:
   - symlink `/etc/codex/config.toml` -> `codex/managed_config.toml` (needs
     passwordless sudo; if that's not available it WARNS and skips the
     `/etc` link rather than failing the whole sync — run the printed
     `sudo ln -sfn …` by hand afterward);
   - find `~/.codex/config.toml`'s old symlink is now dangling (the rename
     deleted `codex/config.toml` from the tree) and fall back to git
     history for its last content automatically — the manual capture in
     step 1 is a safety net for that lookup, not the primary path;
   - run it through `codex/migrate-user-config.py`, which keeps only
     Codex-written keys (`[projects.*]`, `[tui]`) and drops every tracked
     policy key plus any `[projects.*]` entry under `/tmp` or pointing at a
     path that no longer exists;
   - write the result as a plain (non-symlink) `~/.codex/config.toml` that
     Codex owns from then on.

If `sync.sh codex` exits with "pre-deletion content can't be found", use the
step-1 capture directly: `python3 ~/dotfiles/codex/migrate-user-config.py
/tmp/codex-config-pre-merge.toml ~/.codex/config.toml`.
