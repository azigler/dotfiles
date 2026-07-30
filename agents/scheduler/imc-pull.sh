#!/usr/bin/env bash
# imc-pull.sh — keep marketing-vps's IMC campaign folders current from GitHub.
#
# WHY THIS EXISTS (2026-07-30). Each `~/linearb/imc-<month>` is its own repo with
# its own remote (lb-marketing/imc-<month>), gitignored by the umbrella. The vps
# manifest's `require-oob-untracked $HOME/linearb` complement rule therefore swept
# them into the out-of-band rsync tier, because that rule cannot tell "git does not
# own this" from "a DIFFERENT git owns this" — the same flaw lb-granola-pull.sh
# documents for the granola corpus.
#
# For granola the symptom was staleness. For the campaign folders it was
# DESTRUCTIVE. The out-of-band transport is:
#
#   rsync -az --delete --exclude='.git/'    zig-computer -> marketing-vps
#
# `--delete` removes anything the VPS has that zig does not, and `--exclude=.git/`
# leaves the repo metadata intact, so git reports the removals as deletions of
# tracked files. A subsequent `git add <dir>` then STAGES them. On 2026-07-30, with
# zig's imc-aug26 checkout 11 commits behind, this removed 12 committed script files
# from the working tree twice, and two commits captured the deletions as though they
# were intentional. The folders are now `oob-exclude`d and this script is their
# transport.
#
# WHY `pull --ff-only` AND NOT `reset --hard` (the opposite choice to granola):
# granola's box is a pure read-only consumer, so converging on origin unconditionally
# is correct there. Here the VPS is a WRITER — work on the campaign happens on this
# box and is committed and pushed from it (Zig, 2026-07-29: the VPS may write beads
# now, provided it always goes through git). `reset --hard` would silently discard a
# commit made here that had not yet been pushed. `--ff-only` refuses instead, the
# timer goes red, and the work survives. Loud beats convenient when the alternative
# is losing a commit.
#
# IT ALSO DELIVERS, not just refreshes. Excluding the folders from the rsync would
# otherwise trade destruction for ABSENCE: a campaign folder created on zig and never
# cloned here would simply not exist on the box, and refs/beats.md points pulse beats
# at `~/linearb/imc-<month>`, so guest-promo would draft with no campaign context and
# not notice. So this enumerates `imc-*` repos under the lb-marketing org and clones
# any that are missing. (The vps skill's note that this box's gh token has zero
# lb-marketing access is stale as of 2026-07-30: `gh repo view lb-marketing/imc-aug26`
# resolves, and this session pushed to that remote repeatedly.)
#
# A directory that exists WITHOUT .git is the rsync-era artifact (imc-july26 is one).
# It is never touched or clobbered: it logs loudly and asks a human to reconcile,
# because the copy may hold work that was never committed anywhere.
#
# It is deliberately tolerant per-repo: one dirty or diverged folder logs and is
# skipped, it does not abort the others.
set -uo pipefail

GLOB="${IMC_PULL_GLOB:-$HOME/linearb/imc-*}"
LOG="${IMC_PULL_LOG:-$HOME/imc-pull.log}"
rc=0
found=0
pulled=0
skipped=0

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; }

# --- delivery pass: clone any campaign repo the box is missing -----------------
PARENT="${IMC_PULL_PARENT:-$HOME/linearb}"
ORG="${IMC_PULL_ORG:-lb-marketing}"
if [ "${IMC_PULL_CLONE:-1}" = "1" ] && command -v gh >/dev/null 2>&1; then
  if remote_list=$(gh repo list "$ORG" --limit 200 --json name --jq '.[].name' 2>&1); then
    for name in $remote_list; do
      case "$name" in imc-*) ;; *) continue ;; esac
      dest="$PARENT/$name"
      if [ -d "$dest/.git" ]; then
        continue
      elif [ -d "$dest" ]; then
        log "$name: PRESENT WITHOUT .git — rsync-era copy, NOT touching it. Reconcile by hand (it may hold uncommitted work)."
        skipped=$((skipped + 1))
      else
        if out=$(gh repo clone "$ORG/$name" "$dest" -- --quiet 2>&1); then
          log "$name: CLONED from $ORG/$name"
          pulled=$((pulled + 1))
        else
          log "$name: CLONE FAILED: $out"
          rc=1
        fi
      fi
    done
  else
    log "org listing failed, skipping the delivery pass: $remote_list"
  fi
fi

# --- refresh pass: fast-forward what is already here ---------------------------
for repo in $GLOB; do
  [ -d "$repo" ] || continue
  found=$((found + 1))
  name=$(basename "$repo")

  if [ ! -d "$repo/.git" ]; then
    log "$name: SKIP, no .git (rsync copy or not initialised)"
    skipped=$((skipped + 1))
    continue
  fi

  # A dirty tracked tree means someone is mid-edit on the box. Do not touch it.
  if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    log "$name: SKIP, tracked files dirty (work in progress on this box)"
    skipped=$((skipped + 1))
    continue
  fi

  if ! out=$(git -C "$repo" fetch --quiet origin 2>&1); then
    log "$name: FETCH FAILED: $out"
    rc=1
    continue
  fi

  behind=$(git -C "$repo" rev-list --count HEAD..@{u} 2>/dev/null || echo 0)
  ahead=$(git -C "$repo" rev-list --count @{u}..HEAD 2>/dev/null || echo 0)

  if [ "$ahead" != "0" ]; then
    # Unpushed local commits. Never discard them; say so loudly instead.
    log "$name: AHEAD by $ahead unpushed commit(s) — not pulling. Push from this box."
    rc=1
    continue
  fi

  if [ "$behind" = "0" ]; then
    log "$name: up to date"
    continue
  fi

  if out=$(git -C "$repo" pull --ff-only --quiet origin 2>&1); then
    log "$name: pulled $behind commit(s) -> $(git -C "$repo" rev-parse --short HEAD)"
    pulled=$((pulled + 1))
  else
    log "$name: PULL FAILED: $out"
    rc=1
  fi
done

log "IMC_PULL_RESULT=$([ "$rc" -eq 0 ] && echo ok || echo failed) repos=$found pulled=$pulled skipped=$skipped"
exit "$rc"
