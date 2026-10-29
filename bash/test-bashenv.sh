#!/usr/bin/env bash
# test-bashenv.sh — the bash per-host env tier (dotfiles-69tnl). Hermetic: a temp HOME
# holds only the repo's bash files, and every probe runs under env -i.
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"; REPO="${HERE%/bash}"
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
T=$(mktemp -d); trap 'rm -rf -- "${T:?}"' EXIT
H=$(hostname -s)
mkhome() { # mkhome <dir> <host-file-or-empty>
  mkdir -p "$1/.local/bin"; : > "$1/.local/bin/env"
  cp "$REPO/bash/.bash_profile" "$1/.bash_profile"
  [ -z "$2" ] || cp "$2" "$1/.$H.bashenv"
}
val_zsh=$(sed -n 's/^export ANTHROPIC_BASE_URL="\(.*\)"$/\1/p' "$REPO/zsh/.zig-computer.zshenv")
val_bash=$(sed -n 's/^export ANTHROPIC_BASE_URL="\(.*\)"$/\1/p' "$REPO/bash/.zig-computer.bashenv")
# B1: the bash value equals the zsh value, and neither is empty.
if [ -n "$val_zsh" ] && [ "$val_zsh" = "$val_bash" ]; then ok "B1 bash and zsh carry the same gateway value ($val_bash)"
else bad "B1 bash and zsh carry the same gateway value" "zsh='$val_zsh' bash='$val_bash'"; fi
# B2: a non-interactive login bash (bash -lc) gets the var from the host bashenv.
mkhome "$T/h1" "$REPO/bash/.zig-computer.bashenv"
got=$(env -i HOME="$T/h1" PATH=/usr/bin:/bin SHELL=/bin/bash bash -lc 'printf %s "${ANTHROPIC_BASE_URL-@@UNSET@@}"')
if [ "$got" = "$val_bash" ]; then ok "B2 bash -lc carries ANTHROPIC_BASE_URL"
else bad "B2 bash -lc carries ANTHROPIC_BASE_URL" "got '$got'"; fi
# B3: a host with no bashenv gets nothing (the hook is guarded, no error).
mkhome "$T/h2" ""
got=$(env -i HOME="$T/h2" PATH=/usr/bin:/bin SHELL=/bin/bash bash -lc 'printf %s "${ANTHROPIC_BASE_URL-@@UNSET@@}"' 2>&1)
if [ "$got" = "@@UNSET@@" ]; then ok "B3 no host bashenv: unset, no error"
else bad "B3 no host bashenv: unset, no error" "got '$got'"; fi
# B4: sync.sh links the host bashenv, the way it links the host bashrc.
if grep -qF '"$SCRIPT_DIR/bash/.$(hostname -s).bashenv" "$HOME/.$(hostname -s).bashenv"' "$REPO/sync.sh"; then ok "B4 sync.sh links the host bashenv"
else bad "B4 sync.sh links the host bashenv" "no sync_source line"; fi
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
