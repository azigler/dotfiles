#!/usr/bin/env bash
# Cross-compile the ss14-wrapper daemon for pico (Apple Silicon).
#
# This script targets darwin-arm64 from any host (Linux laptop, CI, etc.)
# — pure-Go (no CGO) means the binary is a static Mach-O that runs on
# pico unchanged.
#
# On an Apple-Silicon Mac the same wrapper is built natively by
# mac.setup.sh (`go build -o ss14-wrapper .` in this directory); this
# script is the "from-Linux" cross-compile entry point used when the
# operator wants to scp a pre-built binary instead of cloning dotfiles
# on pico.
#
# Output: ./ss14-wrapper-darwin-arm64 (gitignored — never committed).
#
# Per spec dotfiles-9g1 §3.6 (Go was chosen specifically because it
# cross-compiles cleanly to darwin-arm64 with no runtime dependencies).

set -euo pipefail

cd "$(dirname "$0")"

OUTPUT="ss14-wrapper-darwin-arm64"

echo "ss14-wrapper: cross-compiling for darwin-arm64..."

# CGO_ENABLED=0 enforces pure-Go (the wrapper has no C deps anyway —
# this is a belt-and-suspenders guard against a future contributor
# pulling in a CGO library and silently breaking cross-compile).
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build \
    -trimpath \
    -ldflags="-s -w" \
    -o "${OUTPUT}" \
    .

echo "ss14-wrapper: built ${OUTPUT}"
file "${OUTPUT}" || true
ls -lh "${OUTPUT}"

echo ""
echo "next: scp ${OUTPUT} pico:~/ss14-wrapper/ss14-wrapper"
echo "      (see deploy.sh for the full live-deploy recipe)"
