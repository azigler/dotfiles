# local-models/tests

Test suite for the bench harness and its guard scripts. Everything runs
offline — no pico, no ssh (a PATH-shimmed fake), no models.

## How to run

From the repo root:

```bash
pytest local-models/tests/ -v          # Python suites (analyze-bench, analyze-variance, dashboard, watchdog)
bats local-models/tests/*.bats         # bash suites (pico_lock.sh, safe_remote.sh)
```

Legacy bash harnesses (pre-bats) run directly:

```bash
bash local-models/tests/test_bench_matrix.sh
bash local-models/tests/test_run_scenario.sh
```

## What lives here

| File | Under test | Notes |
|---|---|---|
| `conftest.py` | — | Shared fixtures (sample scenarios/results, `DOTFILES_ROOT` paths) |
| `test_analyze_bench.py`, `test_edges.py` | `analyze-bench.py` | Tier 1 grep-runner (spec dotfiles-ukx.13) |
| `test_analyze_variance.py` | `analyze-variance.py` | Cohort variance + PASS-rate guard; includes the rw2 uniform-failure regression |
| `test_pico_lock.bats` | `lib/pico_lock.sh` | Exclusive-access lock contract |
| `test_safe_remote.bats` | `lib/safe_remote.sh` | Verify-the-negation remote kills (fake ssh) |
| `test_bench_dashboard.py` | `bench-dashboard.py` | Dashboard SPA (retired 2026-06-06, tests kept) |
| `test_zig_watchdog.py` | `zig-watchdog.py` | Watchdog |
| `test_bench_matrix.sh`, `test_run_scenario.sh` | drivers | Legacy bash harnesses |
| `KNOWN-GAPS.md` | — | Real bugs found by the guard-script suite; each is pinned by a "KNOWN GAP" test, scripts deliberately left unfixed |

`DOTFILES_ROOT` env var overrides which tree the suites exercise
(defaults to the tree the test file lives in — see conftest.py).
