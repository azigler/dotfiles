#!/bin/bash
# SessionEnd: persist bead state.

if command -v br &>/dev/null; then
  br sync --flush-only 2>/dev/null
fi

exit 0
