#!/bin/bash
# Pre-commit hook: Run quality checks before allowing commit
# Exit code 1 = blocking (prevents commit)

set -euo pipefail

FAILED=0

# 1. Sync beads (so bead state is included in commit)
if command -v br &> /dev/null; then
  br sync --flush-only 2>/dev/null || true
  git add .beads/issues.jsonl 2>/dev/null || true
fi

# 2. TypeScript type check
if [[ -f "tsconfig.json" ]]; then
  echo "Running TypeScript type check..."
  if ! npx tsc --noEmit 2>&1; then
    echo "TypeScript type check failed"
    FAILED=1
  fi
fi

if [[ $FAILED -ne 0 ]]; then
  echo ""
  echo "Pre-commit checks failed. Fix errors before committing."
  exit 1
fi

exit 0
