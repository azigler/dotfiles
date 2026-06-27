# <project> — Data & Memory Posture

**Decided <date>.** Default shape (proven on hevyd): SQLite is the write store;
**DuckDB is the analytics engine**; MEMORY.md + beads hold qualitative memory.
Bias: boring, single-file, zero-ops — capable, not heavy. Match the tool to the
WORKLOAD SHAPE (analytical? nested JSON? time-series? → DuckDB), not the data size.

## Tier 1 — SQLite (WAL), the write store  `./var/<project>.db`
- Written ONLY by the daemon, via `modernc.org/sqlite` (pure-Go, no CGO → static
  binary). WAL → daemon writes while the agent reads, concurrently.
- Store raw JSON (lossless) **+** flattened rows (fast queries).
- System-of-record for data the upstream doesn't hold; a re-pullable cache for
  data it does.

## Tier 2 — DuckDB, the analytics engine (the agent's brain)
- CLI, separate binary (NOT linked into the daemon). Query via
  `ATTACH './var/<project>.db' AS d (TYPE sqlite, READ_ONLY)`.
- DuckDB v1.5.4+ reads through the SQLite WAL correctly — no checkpoint dance.
- Canned views/macros in `sql/`. **Vet builtins before hand-rolling**
  (`arg_max`, `regr_slope`, `fts`, `vss`, window fns) — see hevyd's
  `refs/duckdb-toolkit.md`.

## Tier 3 — MEMORY.md + beads, qualitative memory
- The agent's reasoning (observations, patterns, the arc) as prose, not rows.
  Heavyweight memory layers (Letta/Honcho) are overkill for a single-user box.

## Persist vs re-pull
- Persist (mirror): <the bulk immutable data>. Persist (SoR): <what upstream
  lacks>. Re-pull on demand: <anything that might be stale>.

## SQLite schema sketch
```
<table>(id PK, …, raw_json)     -- raw_json = full payload, lossless
<flattened child rows>
webhook_events(event_id PK, …, status)   -- idempotency/audit
sync_state(key PK, value)                -- e.g. last events cursor
```
