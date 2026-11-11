#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/repo/codex" "$scratch/repo/gemini" "$scratch/bin"
cp "$repo/sync.sh" "$scratch/repo/sync.sh"
cp "$repo/codex/managed_config.toml" "$scratch/repo/codex/managed_config.toml"
cp "$repo/gemini/settings.json" "$scratch/repo/gemini/settings.json"
# A Codex sync must never write the real /etc/codex/config.toml.
cat > "$scratch/bin/sudo" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$scratch/bin/sudo"

make_tier() {
    local home=$1
    mkdir -p "$home/.agents/claude" "$home/.agents/agents/hooks" "$home/.agents/agents/skills"
    touch "$home/.agents/claude/settings.json" "$home/.agents/agents/AGENTS.md"
}

gemini_home="$scratch/gemini-home"
make_tier "$gemini_home"
mkdir -p "$gemini_home/.gemini"
for name in hooks skills GEMINI.md; do
    ln -s "$gemini_home/old-tier/$name" "$gemini_home/.gemini/$name"
done

HOME="$gemini_home" bash "$scratch/repo/sync.sh" gemini

for pair in 'hooks:hooks' 'skills:skills' 'GEMINI.md:AGENTS.md'; do
    name="${pair%%:*}"
    source="${pair#*:}"
    link="$gemini_home/.gemini/$name"
    test -L "$link"
    test -e "$link"
    test "$(readlink "$link")" = "$gemini_home/.agents/agents/$source"
done

echo 'PASS: sync.sh replaces dangling Gemini vendor links in a scratch HOME'

old_home="$scratch/codex-old"
make_tier "$old_home"
mkdir -p "$old_home/.codex"
ln -s "$old_home/.agents/agents/skills" "$old_home/.codex/skills"
HOME="$old_home" PATH="$scratch/bin:$PATH" bash "$scratch/repo/sync.sh" codex
test -d "$old_home/.codex/skills"
test ! -L "$old_home/.codex/skills"
test -L "$old_home/.codex/skills/shared"
test "$(readlink -f "$old_home/.codex/skills/shared")" = "$old_home/.agents/agents/skills"
echo 'PASS: sync.sh converts the old Codex skills link in a scratch HOME'

live_home="$scratch/codex-live"
make_tier "$live_home"
mv "$live_home/.agents" "$live_home/tier"
ln -s "$live_home/tier" "$live_home/.agents"
mkdir -p "$live_home/.codex/skills/.system"
printf 'Codex state\n' > "$live_home/.codex/skills/.system/marker"
ln -s "$live_home/tier/agents/skills" "$live_home/.codex/skills/shared"
HOME="$live_home" PATH="$scratch/bin:$PATH" bash "$scratch/repo/sync.sh" codex
test ! -L "$live_home/.codex/skills"
test "$(cat "$live_home/.codex/skills/.system/marker")" = 'Codex state'
test "$(readlink -f "$live_home/.codex/skills/shared")" = "$live_home/tier/agents/skills"
test ! -e "$scratch/repo/.backup"
echo 'PASS: sync.sh preserves Codex state and creates no backup for the live layout'

missing_home="$scratch/codex-missing"
make_tier "$missing_home"
rm -r "$missing_home/.agents/agents/skills"
if HOME="$missing_home" PATH="$scratch/bin:$PATH" bash "$scratch/repo/sync.sh" codex; then
    echo 'FAIL: a missing skill source returned success' >&2
    exit 1
fi
test -L "$missing_home/.codex/AGENTS.md"
test ! -e "$missing_home/.codex/skills/shared"
echo 'PASS: a missing source fails after other Codex links are processed'
