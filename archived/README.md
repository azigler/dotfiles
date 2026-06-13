# archived/ — retired explorations kept for the record

## bench-arc-2026-06 (`local-models/`, `sandbox/`)
The round-1/round-2 local-model **benchmark-matrix** harness (the matrix
driver, scenario runner, variance analysis, serving registry, safe-remote
and pico-lock libs, guard tests) and its scenario sandbox. Retired
2026-06-13 when the project reoriented away from "find a Frontier-replacement
local model via benchmarking" toward "always-on Hermes orchestrator that
dispatches smart models on demand."

- The findings/data/canon live in `~/explore/local-coding-models/` (not here).
- The matrix post-mortem (`refs/matrix-postmortem-2026-06.md` there) is the
  honest record of why the benchmarking arc was hard.
- `git log --follow archived/local-models/<file>` recovers full history.
- The `/research` skill's reference docs still cite some of these as worked
  examples; that's documentation, not a live dependency.

Nothing here is wired to a running service (the `zig-watchdog.service` static
unit was removed from `~/.config/systemd/user/` on archival).
