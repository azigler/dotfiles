# KNOWN-GAPS — real bugs found while writing the guard-script test suite

Found during bead `dotfiles-t4k` (implements `local-coding-models-wkw`,
postmortem failure mode #12). Per the task contract the scripts under
test were NOT modified; each gap below is pinned by a test marked
"KNOWN GAP" so a future fix flips a deliberately-failing pin instead of
landing silently. Severity is relative to the guard's own purpose.

Entries marked **FIXED** have been repaired and their pins flipped to
assert the fixed behavior (the test names cited below are the original
pin names; the flipped tests carry a `FIXED: KNOWN-GAPS #n` marker).

## safe_remote.sh

### 1. `safe_pgrep_remote` fails OPEN on an unreachable host (HIGH) — FIXED

**FIXED 2026-06-10 (`dotfiles-afx`):** transport failure (nonzero ssh exit
OR missing remote run-proof sentinel) now fails CLOSED with exit 2 and a
`VERIFY IMPOSSIBLE` stderr message — never reported as all-clear.

`ssh` transport failure (exit 255, e.g. host down, tailnet drop) produces
empty captured output — indistinguishable from "zero matches". The
`|| true` + empty-string check returns **0 = all clear** when the host
was never checked at all. The verify-the-negation discipline this lib
exists for (postmortem #3, the 7-orphan-ollama case) silently passes
during exactly the infra failures it should be loudest about.

- Pin: `test_safe_remote.bats` — "pgrep: unreachable host reports 'all clear'"
- Fix sketch: capture ssh's exit status separately; treat transport
  failure as a third outcome (exit 2, "VERIFY IMPOSSIBLE"), never as
  success.

### 2. `safe_pkill_remote` inherits the fail-open (HIGH) — FIXED

**FIXED 2026-06-10 (`dotfiles-afx`):** both the kill (`KILL UNVERIFIABLE`)
and each verification (`VERIFY IMPOSSIBLE`) detect transport failure and
propagate exit 2 instead of 0.

Kill and verification ride the same dead transport: the function returns
0 having killed nothing and verified nothing.

- Pin: `test_safe_remote.bats` — "pkill: unreachable host reports success"
- Fix sketch: same as #1; propagate "verify impossible" instead of 0.

## analyze-variance.py

### 3. Cohort-name substring contamination (MEDIUM)

A `--cohort` value that is a hyphen-suffix of another candidate's name
matches that candidate's files: cohort `mini` finds anchor `-mini-trial`
inside `01-trivial-rename-trinity-mini-trial1-...` and accepts the file
with a mangled scenario name (`01-trivial-rename-trinity`, which still
satisfies `SCEN_RE`). A typo'd or truncated cohort name silently
analyzes another candidate's trials.

- Pin: `test_analyze_variance.py::test_parse_cohort_substring_contamination_known_gap`
- Fix sketch: require the scenario prefix to match a known scenarios
  list (when `--scenarios-dir` is given), or validate the cohort against
  the candidate roster.

### 4. `TAIL_RE` caps trials at 1–9; trial10+ silently dropped (MEDIUM)

`trial(?P<trial>[1-9])-` is a single-digit class. The postmortem's own
conclusion is that N=3 was too low and N≥5–10 is wanted; at trial10 and
beyond, files vanish from the cohort with no warning — the silent-miss
class (postmortem #12) at a different layer.

- Pin: `test_analyze_variance.py::test_parse_trial_ten_dropped_known_gap`
- Fix sketch: `[1-9]\d*` plus a collected-vs-on-disk count assertion.

### 5. Zero-median short-circuit hides an infinite cross-scenario anomaly (LOW)

`detect_cross_scenario_anomaly` guards division by setting `ratio = 0`
when the fastest scenario's median is 0s. A cohort where one scenario
short-circuits instantly (0s walls) against long scenarios is the most
extreme anomaly possible, and it is the one shape the check can never
flag.

- Pin: `test_analyze_variance.py::test_cross_scenario_zero_median_known_gap`
- Fix sketch: a 0s median with a non-zero sibling median is itself a flag.

### 6. The PASS-rate gate is still opt-in (structural, MEDIUM)

Failure mode #10's residual: without `--scenarios-dir`, `--strict` exits
0 on a cohort where every trial failed identically (the rw2 / v2-garbage
shape — uniform error text, verdict_tag OK, uniform walls). The script
prints a SKIPPED warning, but warnings scroll past unattended runs;
`detect_systemic_failure()` exists and catches the shape, yet is not
wired into `main()` at all.

- Pins: `test_cli_uniform_failure_without_scenarios_dir_passes_strict_known_gap`
  (CLI) and `test_uniform_failure_passes_all_variance_detectors` (unit);
  the guarded path is `test_cli_uniform_failure_strict_exits_nonzero`.
- Fix sketch: make `--strict` without a PASS-rate source an error, or
  run `detect_systemic_failure()` as a default backstop.

## pico_lock.sh

### 7. Release does not check the PID — acquire/release asymmetry (MEDIUM) — FIXED

**FIXED 2026-06-10 (`dotfiles-afx`):** `pico_release` now requires owner
AND pid to match; non-holder release is REFUSED (stale locks: acquire-side
steal path; manual cleanup: `rm -f`).

`pico_acquire` refuses same-owner-different-PID (two matrix instances
must not overlap), but `pico_release` checks only the owner *name*. The
refused second instance's cleanup trap (`pico_release bench-matrix`)
releases the RUNNING first instance's lock out from under it — exactly
the overlap the acquire-side check exists to prevent.

- Pin: `test_pico_lock.bats` — "release: same-owner-DIFFERENT-PID succeeds"
- Fix sketch: release requires owner AND pid match (stale locks already
  have the steal path; manual cleanup already has `rm -f`).

### 8. CLI-mode `acquire` writes an instantly-stale lock (LOW) — FIXED

**FIXED 2026-06-10 (`dotfiles-afx`):** CLI mode now acts as `$PPID` (the
invoking shell), overridable via `PICO_LOCK_SELF_PID` for the
supervisor-acquires-on-behalf pattern; sourced usage still records `$$`.

The CLI wrapper records `$$` of the short-lived `pico_lock.sh` process;
by the next command that PID is dead, so the lock is immediately
stealable. The script's own usage example
(`acquire bench-matrix-phase3 108000 ...`) therefore protects nothing.
Sourced usage (the real bench-matrix.sh path) is unaffected.

- Pin: `test_pico_lock.bats` — "CLI: acquire records a transient PID"
- Fix sketch: CLI mode should record `$PPID` (the invoking shell), or
  refuse `acquire` with a pointer to sourced usage.

### 9. Unescaped shell→python interpolation in the JSON writer (LOW, hardening)

`pico_acquire` builds Python source by interpolating `$owner` / `$reason`
inside `'''...'''`. An owner or reason containing `'''`, a trailing
backslash, or a newline breaks the writer (exit 2); crafted input could
inject Python. All current callers pass fixed strings, so this is
hardening, not a live bug — noted, not pinned.

- Fix sketch: pass values via `sys.argv` / environment instead of source
  interpolation.
