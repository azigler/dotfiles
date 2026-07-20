#!/usr/bin/env bash
# vps-phase2-symlinks.sh — Phase 2 of the Claude-state sync (spec lin-i2d.1).
# Runs ON marketing-vps. Symlinks the native -home-andrew-linearb* slug dirs ->
# the canonical -home-ubuntu-linearb* content, so the agent (cwd /home/andrew/
# linearb*) reads/writes the shared brain. Reversible; no commit/push.
set -euo pipefail
WT="$HOME/.claude/projects"

# active native<->canonical pairs (suffix shared; -home-andrew-X -> -home-ubuntu-X)
SUFFIXES=( "linearb" "linearb-marketing-vps" "linearb-imc-july26" "linearb-imc-aug26" )

echo "=== create canonical targets (if absent) + symlink native -> canonical ==="
for suf in "${SUFFIXES[@]}"; do
  canon="$WT/-home-ubuntu-$suf"
  native="$WT/-home-andrew-$suf"
  mkdir -p "$canon"
  if [ -L "$native" ]; then echo "  = $native -> $(readlink "$native")"; continue; fi
  if [ -e "$native" ]; then echo "  !! $native exists, NOT a symlink — skip (manual review)"; continue; fi
  ln -s "./-home-ubuntu-$suf" "$native"        # ./ prefix dodges the '-'-slug argv footgun
  echo "  + $native -> ./-home-ubuntu-$suf"
done

echo "=== verify: shared MEMORY.md readable THROUGH the native umbrella slug ==="
if head -1 "$WT/-home-andrew-linearb/memory/MEMORY.md" >/dev/null 2>&1; then
  echo "  OK: $(head -1 "$WT/-home-andrew-linearb/memory/MEMORY.md" | cut -c1-80)..."
else
  echo "  !! cannot read MEMORY.md through the symlink"
fi

echo "=== verify: symlinks NOT staged + still zero deletions (both vaults) ==="
for pair in "memory.git|memory.excludes" "transcripts.git|transcripts.excludes"; do
  g="${pair%%|*}"; ex="${pair##*|}"
  gd="$HOME/.claude/vaults/$g"; exf="$HOME/dotfiles/agents/vault/$ex"
  G=(git --git-dir="$gd" --work-tree="$WT" -c "core.excludesFile=$exf")
  "${G[@]}" add -A 2>/dev/null || true
  total=$("${G[@]}" diff --cached --name-only 2>/dev/null | wc -l)
  andrew=$("${G[@]}" diff --cached --name-only 2>/dev/null | grep -c '^-home-andrew-' || true)
  dels=$("${G[@]}" diff --cached --diff-filter=D --name-only 2>/dev/null | wc -l)
  echo "  $g: staged=$total  -home-andrew-* staged=$andrew (want 0)  deletions=$dels (want 0)"
  "${G[@]}" reset -q 2>/dev/null || true
done
echo "Phase 2 done — symlinks in place, shared brain reachable under native slug, nothing staged."
