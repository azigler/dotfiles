#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$scratch/.agents/claude" "$scratch/.agents/agents/hooks" "$scratch/.agents/agents/skills" "$scratch/.gemini"
touch "$scratch/.agents/claude/settings.json" "$scratch/.agents/agents/AGENTS.md"
for name in hooks skills GEMINI.md; do
    ln -s "$scratch/old-tier/$name" "$scratch/.gemini/$name"
done

HOME="$scratch" bash "$repo/sync.sh" gemini

for pair in 'hooks:hooks' 'skills:skills' 'GEMINI.md:AGENTS.md'; do
    name="${pair%%:*}"
    source="${pair#*:}"
    link="$scratch/.gemini/$name"
    test -L "$link"
    test -e "$link"
    test "$(readlink "$link")" = "$scratch/.agents/agents/$source"
done

echo 'PASS: sync.sh replaces dangling Gemini vendor links in a scratch HOME'
