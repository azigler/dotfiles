# Experiment protocol (MANDATORY for /research arcs that generate data)

Research **reads** existing sources; an experiment **generates new
data** from a live system (benchmarks, probes at scale, A/B runs,
matrix sweeps). The /research pipeline (dispatch → verify → scrutinize
→ fold) is sufficient for reading. It is NOT sufficient for
experiments. Every experiment additionally runs this protocol.

Written from the local-coding-models matrix post-mortem (2026-06-10):
two matrix launches (~270 trials each) produced garbage that passed
every check the harness had. Twelve distinct failure modes traced to
the same root: **rich observability, no mechanical enforcement, and
success defined as absence-of-error instead of presence-of-evidence.**
(Full taxonomy: `~/explore/local-coding-models/refs/matrix-postmortem-2026-06.md`.)

## The prime directive

> **A result is evidence only if the pipeline that produced it has
> been shown to distinguish success from failure.**

Uniform results are not clean results. 270 trials that all "passed"
with identical wall times were 270 identical infrastructure errors
wrapped as OK. Before trusting any run, you must have watched the
pipeline correctly classify a known-good AND a known-bad case.

## Phase E0 — Pre-registration (before touching the substrate)

Create a bead (`-t spec` for a full experiment design, `-t task` for a
small probe) and record, BEFORE the run:

1. **Hypothesis** — what you expect and why. One sentence.
2. **Method** — exact procedure: components, commands, scenario list,
   trial count.
3. **Version manifest** — pinned version of EVERY component in the
   chain (client CLI, proxy/router, serving stack, model + quant,
   OS-level daemons). Version churn broke the CCR tag contract
   silently; a recorded manifest makes "what changed?" answerable.
4. **Expected-outcome ranges** — wall-time range per unit, expected
   pass-rate band, expected variance shape. Anomaly = outside range.
   (Pre-registered ranges would have flagged 270 uniform ~180s trials
   instantly.)
5. **Success evidence** — the ARTIFACT that proves the work happened
   (file contents matching spec, output marker, response body), never
   an exit code alone. Bead e21: a model renamed the file correctly
   and was verdict-tagged TIMEOUT because only the exit code was read.
6. **Abort criteria** — the conditions under which the run stops
   itself: pass-rate floor (e.g. abort cohort if <20% trials show the
   success artifact), consecutive-anomaly budget, resource ceilings.
7. **Sample size + justification** — N=3 cannot support variance
   claims with a 2× threshold. Fewer cells with N≥5 beat more cells
   with N=3.

## Phase E1 — Calibration (controls; the gate most worth keeping)

Before ANY scaled run, push two canaries through the FULL pipeline —
including the analysis/verdict layer, not just the execution layer:

- **Positive control** — a configuration known to work. Must come out
  PASS with the success artifact present.
- **Negative control** — a configuration deliberately broken (wrong
  endpoint, dead model, intentionally failing task). Must come out
  FAIL, flagged by the same checks that will guard the real run.

If the pipeline cannot tell these apart, the experiment does not
start. This is ~20 minutes and would have prevented both matrix
disasters. Re-run calibration after ANY component version change
(see manifest) — that's the regression test for the version contract.

## Phase E2 — Pre-flight invariants (mechanical, blocking)

Immediately before launch, assert — script-enforced, exit non-zero,
not prose in a doc:

- **Exclusive access** — lock acquired on the shared substrate; no
  other consumers scheduled in the window (crons paused, no stray
  clients in flight). The matrix assumed exclusivity; a concurrent
  worker wedged the backend mid-run.
- **Substrate health** — healthcheck green (reachability + functional
  roundtrip + resource headroom + orphan-process audit: `pgrep` count
  of serving processes matches expectation).
- **Routing verification** — an end-to-end probe confirming requests
  land on the INTENDED target (parse the response's model field, not
  just "got a 200"). Misrouting sent an entire cohort to the wrong
  model with every status code green.

## Phase E3 — Scale ladder (with human checkpoint)

Never jump from calibration to the full run:

1. **1 trial** of one real cell — inspect the raw artifact by hand.
2. **1 full cohort** — run the analysis gate on it; verify verdicts
   against artifacts manually for at least 2 trials.
3. **Checkpoint** — any run longer than ~1 hour unattended requires a
   human go/no-go with the calibration + cohort evidence attached.
4. **Full run** — with per-cohort blocking gates (below).

## Phase E4 — In-run gates (enforcement, not reporting)

A check that prints a warning into a log nobody reads during a 100h
run is not a check. Every gate ABORTS or BLOCKS:

- **Per-cohort analysis gate** — strict-mode analyzer between cohorts;
  non-zero exit halts the matrix.
- **Absolute success floor** — ≥N% of trials must contain the success
  artifact, else the cohort is declared systemically failing and the
  run stops. (Relative/variance checks alone validate uniformity —
  which uniform failure also satisfies.)
- **Transition hygiene** — resource cleanup verified between
  heterogeneous phases (e.g. backend eviction confirmed by probe, not
  assumed), with the post-cleanup state asserted.
- **Stall watchdogs** — every long-running unattended step (pull,
  cohort, warm-up) gets a liveness watchdog whose exit is the alarm:
  probe a true progress signal (disk growth, result count — not
  process aliveness; hung processes are alive), exit loudly after N
  flat checks, heartbeat-exit at the time budget so the maximum
  signal-free window is bounded. Completion notifications only fire
  on exit; hangs never exit. (See healthcheck-pattern.md §Liveness.)

## Phase E5 — Provenance (or the data never existed)

- **Raw results are committed to version control** (or synced off the
  remote host into a tracked tree) BEFORE analysis is trusted. The
  arc's v4 partial results lived in a default dir on the remote host
  and were lost in a machine reset. If it isn't in git, it's one
  `rm -rf` from never having happened.
- Each run directory carries its **version manifest + pre-registration
  bead ID + raw outputs + analyzer verdicts** — enough for a stranger
  to reproduce or audit the run cold.
- Analysis scripts are versioned alongside the data they judged.

## Verdict discipline

- Every claim in a verdict/synthesis doc carries **provenance**: which
  run, which gate it passed, and a confidence tag (validated /
  inferred / untested). The old verdict table claimed a model
  "tool-capable" from a suite that never exercised tools.
- Verdicts from a run later found contaminated get a `REVISED` callout
  in place — never silently edited, never silently retained.

## Circuit breakers (autonomous mode)

- **Anomaly budget:** two consecutive iterations producing
  out-of-range or garbage results → STOP. File a P1 `human:` bead +
  push notification; do not "fix and relaunch" a scaled run
  autonomously more than once.
- **No layering on an unvalidated foundation:** if downstream research
  (pivots, follow-up arcs, verdict-consuming decisions) depends on
  experimental results, those results must have passed calibration +
  gates first. Momentum is not progress.
- **Foundation re-check:** at each wave start, re-verify that the
  empirical results the wave builds on are still believed-valid (not
  superseded, not from a contaminated run).
