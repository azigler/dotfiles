# Pairing DuckDB with Turso DB (or libSQL, or SQLite)

The two-database design pattern for shipping a single app with one OLTP
store + one OLAP store, both embedded, both file-based, both zero-config.

## TL;DR

Use **Turso Database for OLTP** (state, sessions, config, queues, per-user
lookups). Use **DuckDB for OLAP** (events, traces, analytics that join
across stores). DuckDB attaches the Turso file via the `sqlite` extension
and queries it transparently — no separate plugin needed, because Turso
maintains SQLite on-disk format compatibility by design.

If Turso DB's beta status is a concern (shipping to customers, mission-
critical), fall back to **libSQL** (production-ready SQLite fork, MIT) or
**stock SQLite**. The patterns below work identically for all three —
substitute the OLTP-side library; the DuckDB side is unchanged.

## Which OLTP engine

Verified 2026-05-18 via repo metadata:

| | Turso DB | libSQL | SQLite |
|---|---|---|---|
| Maturity | Beta (v0.6.0 May 2026) | Production (v0.24.32 Feb 2025) | Mature (25+ years) |
| Active development | **Yes, 100+ commits/30 days** | No, 0 commits/30 days | Yes (closed-development model) |
| Language | Rust | C | C |
| License | MIT | MIT | Public domain |
| Native vector type | ✅ | ✅ | — |
| Embedded replicas | ✅ | ✅ | — |
| Built-in MCP server | ✅ | — | — |
| Memory-safe runtime | ✅ | — | — |
| Position | Forward-looking; Turso team's stated direction | Maintenance | Universal default |

Turso's own README: *"replaces libSQL as the intended direction."*

The escape hatch is real: Turso, libSQL, and SQLite all share on-disk file
format. Switching among them is a file copy + a library swap. Bet
forward; the downside is bounded.

## How DuckDB sees a Turso (or libSQL, or SQLite) file

```sql
INSTALL sqlite;          -- autoloads in DuckDB v1.4+
LOAD sqlite;

ATTACH 'app.db' AS app (TYPE sqlite, READ_ONLY);
SELECT * FROM app.users LIMIT 5;
```

Works against a file created by any of the three. Full read; full write
if you drop `READ_ONLY` (writes need coordination — see "Concurrency").

### The vector caveat

Turso's native vector columns are stored such that DuckDB can't natively
query them as vectors via `sqlite_scanner` — DuckDB sees BLOB. The split:

- Embeddings searched within OLTP queries → store in Turso, search with
  Turso's `vector_distance_cos` functions
- Embeddings joined with analytical data → store in DuckDB with `vss`
  extension (the RAG-in-one-query pattern; see [`rag-pattern.md`](rag-pattern.md))

## Four base patterns

### Pattern A — Federated (start here)

App writes Turso normally. DuckDB attaches the Turso file read-only and
joins it against DuckDB-native tables. No ETL, no sync. Real-time
analytical reads.

```sql
-- In DuckDB:
ATTACH 'app.db' AS app (TYPE sqlite, READ_ONLY);

SELECT u.name,
       COUNT(*) FILTER (WHERE e.kind = 'login') AS logins_7d
FROM app.users u
LEFT JOIN events e          -- DuckDB-native table
  ON e.user_id = u.id
 AND e.at > NOW() - INTERVAL 7 DAY
GROUP BY u.id, u.name;
```

Use when: small-to-medium Turso DB (<1 GB), occasional analytics, want
minimum operational complexity.

### Pattern B — CQRS-lite (event log split)

Turso holds the **current state** (mutable). DuckDB holds the **event
log** (append-only). App writes both. Analytics queries DuckDB; OLTP
queries Turso. If you ever need to rebuild state, replay events.

Use when: event volume is high enough to bloat your OLTP store;
analytical queries would otherwise contend with OLTP writes.

### Pattern C — Periodic snapshot

App's hot path stays Turso-only. A periodic worker exports Parquet
snapshots. DuckDB queries the snapshots, never touching live Turso.

```bash
# Inside the snapshot worker:
sqlite3 app.db ".dump users" | duckdb -c "
  COPY (SELECT * FROM read_csv_auto('/dev/stdin')) TO
  'snapshots/users-$(date +%Y-%m-%d).parquet';
"
```

Use when: analytics workload is heavy enough you don't want it touching
OLTP at all; you want point-in-time history.

### Pattern D — DuckDB primary, Turso as cache

Inverted: analytics is most of the workload; OLTP-shaped lookups are the
exception, cached in Turso for sub-millisecond reads.

Use when: building an analytical product (BI tool, log explorer) that
occasionally needs "get this row by ID."

## Turso-specific patterns

### Pattern E — Embedded replica + local analytics

Turso Cloud replicates a primary to your local file in real time. App
reads + writes go through Turso; DuckDB attaches the replica file for
analytics. Edge deployments, mobile sync, CDN-adjacent backends.

### Pattern F — Vector dual-store

Per-user lookups (small N, OLTP-shaped) → Turso native vector type.
Knowledge-base similarity (large N, joined with metadata) → DuckDB `vss`.

### Pattern G — Parallel MCP servers (the agent-substrate pattern)

The strongest argument for Turso + DuckDB specifically. Both ship MCP
servers; wire both into the agent:

```bash
# OLTP side (app state, sessions)
claude mcp add turso-app -- turso mcp --db app.db

# OLAP side (events, traces, analytics)
~/.claude/skills/duckdb/bootstrap-mcp.sh ./data/analytics.duckdb
```

The agent has two MCP servers, picks the right one per query. Microsecond
OLTP reads + DuckDB's full analytical surface, both natively SQL.

## Concurrency — the load-bearing constraint

Both DuckDB and Turso DB have single-writer concurrency. Stacking two
single-writer DBs in one app process **separates the writers cleanly**
(OLTP vs ingestion) but doesn't multiply your concurrency budget.

- One app process, one Turso writer + one DuckDB writer: fine
- Many app processes writing the same DB: needs server-mode DB (Postgres,
  libsql server, DuckDB's Quack remote protocol)
- DuckDB attaching Turso read-only while Turso accepts writes: fine
  (WAL gives reader consistency)
- DuckDB attaching Turso writable while Turso writes: conflicts; queue
  one or use Pattern C

## Packaging story

```toml
# Rust
[dependencies]
duckdb = "1.5"
turso = "0.6"        # or "libsql = ..." or "rusqlite = ..."
tokio = "1"
```

```toml
# Python
dependencies = [
  "duckdb>=1.5",
  "pyturso",         # or "libsql-experimental" or stdlib sqlite3
]
```

```go
// Go
import (
  _ "github.com/marcboeker/go-duckdb/v2"
  _ "github.com/tursodatabase/turso-go"   // or libsql-client-go, or mattn/go-sqlite3
)
```

```ts
// Bun / Node
import duckdb from "@duckdb/node-api";
import { Database } from "@tursodatabase/turso";    // or "@libsql/client", or "bun:sqlite"
```

Binary footprint typically 30–80 MB combined depending on language.

Backup: copy the files. Multi-tenant: one folder per tenant.

## When the pairing is wrong

- Many app processes writing the same store → Postgres / libsql server
  mode / DuckDB Quack
- Strict ACID across both stores → there's no cross-DB transaction; use
  one store
- Binary budget <10 MB → drop DuckDB, use Turso/SQLite alone
- Heavy multi-engine analytics → lakehouse format (Iceberg) is the right
  answer
- Mission-critical, no-bugs-allowed contexts before Turso v1.0 → use
  libSQL or stock SQLite

## See also

- [`rag-pattern.md`](rag-pattern.md) — the parallel-MCP-servers Pattern G
  shines for agent RAG workflows
- [`mcp-setup.md`](mcp-setup.md) — wiring the DuckDB MCP server (and
  Turso's alongside it)
- [Turso DB COMPAT.md](https://github.com/tursodatabase/turso/blob/main/COMPAT.md)
  — the SQLite-format-compatibility guarantee
