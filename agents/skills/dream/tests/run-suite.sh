#!/usr/bin/env bash
# The dream helper's pytest suite, wrapped so `tools/githooks/pre-commit` can
# call it the way it calls every other suite (`bash <path>`).
#
# Why a wrapper at all: the gate's convention is shell suites under
# agents/{hooks,scheduler,lib,doclint}. dream.py is a Python skill helper with a
# pytest suite and matches no convention arm, so before this file every edit to
# it was gated on NOTHING — the exact dotfiles-dijt shape ("no suite found" and
# "suite passed" being indistinguishable). It is wired in mapped_suites_for().
#
# A MISSING pytest FAILS rather than skips. A gate that cannot run is broken,
# and a silent skip here would restore the very invisibility this file removes.
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if ! python3 -c 'import pytest' >/dev/null 2>&1; then  # allow-suppress
  echo "run-suite: FAIL — pytest is not importable by python3." >&2
  echo "  The dream suite is the only gate on dream.py; refusing to pass" >&2
  echo "  without running it. Install pytest (pip install --user pytest)." >&2
  exit 1
fi

echo "run-suite: $DIR/tests (pytest)"
cd "$DIR" || exit 1
python3 -m pytest tests -q
