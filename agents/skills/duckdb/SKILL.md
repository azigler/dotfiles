---
description: DuckDB — in-process columnar analytical SQL engine. Reach for it for any "analyze tabular data," "query Parquet on S3," "SQL over my CSVs," or "agent needs a queryable substrate" task. Wire it into a project via the MotherDuck MCP server (`bootstrap-mcp.sh`) so the agent can introspect schema, run SQL, and join across files / databases / object stores in one statement — way cheaper than chained tool calls. Not for OLTP (pair with Turso DB / SQLite / Postgres for transactional state; see reference/pairing-with-turso.md).
when_to_use: User mentions Parquet, multi-GB CSVs, .duckdb files, lakehouse formats (Iceberg / Delta / DuckLake), MotherDuck, "I have this data and want SQL over it," or any analytical-shaped query that would otherwise live in Pandas / Polars / a warehouse. Also fire when an agent needs to query its own knowledge base (vss + llm extensions for RAG-in-one-query), when packaging a desktop / CLI / agent app that needs embedded analytics, or when comparing data tools for an analytical workload. Run reference/mcp-setup.md or bootstrap-mcp.sh to wire DuckDB MCP into the current project.
allowed-tools: Bash(claude mcp *) Bash(uvx mcp-server-motherduck*) Bash(uvx mcp-server-duckdb*) Bash(duckdb *) Bash(python3 *) Bash(uv *) Bash(/home/ubuntu/dotfiles/agents/skills/duckdb/bootstrap-mcp.sh*) WebFetch
---

# /duckdb — Analytical SQL substrate

DuckDB is an **in-process SQL OLAP database** — a 50 MB shared library
you link into your app or query via a CLI. It's MIT-licensed, columnar,
vectorized, ACID, runs on Linux / macOS / Windows × x86 + ARM (and in
the browser via Wasm), reads Parquet / CSV / JSON / Excel / SQLite /
Iceberg / Delta / DuckLake natively, and scales single-node from tiny
local files to multi-terabyte Parquet on object storage. The framing
"SQLite for analytics" undersells it — the community extension surface
has made it a generalist substrate for analytics + AI + integration
work.

This skill is for **agents that want SQL over data**, whatever the data
shape. Wire the MCP server into a project once and the agent gains a
typed, queryable, stateful, joinable, extension-rich substrate.

## Six pillars (DuckDB's own positioning)

Simple · Feature-rich · Fast · Free · Portable · Extensible

## When this skill fires

**Strong fires** — invoke without ceremony:
- User wants to query Parquet / CSV / JSON at scale
- User mentions DuckDB, MotherDuck, DuckLake, Iceberg, Delta Lake
- User has a `.duckdb` file or wants one
- User is comparing analytical engines (vs Pandas / Polars / Spark / Snowflake / ClickHouse)
- Agent needs a queryable knowledge base (RAG-in-one-query via vss + llm)
- App design conversation that includes "embedded analytics" or "tiny shippable warehouse"

**Soft fires** — consider:
- User wants to ad-hoc explore a messy CSV / Parquet from a vendor
- Agent needs to analyze logs / events / traces stored anywhere
- User asks about "what database for an analytical workload"
- User is building a desktop / Electron / Tauri app with a data tab

**Skip** — wrong tool:
- OLTP workloads (user accounts, sessions, config, queues) → use Turso DB / SQLite / Postgres; see [`reference/pairing-with-turso.md`](reference/pairing-with-turso.md)
- Real-time event ingestion >10K/sec → use ClickHouse / TimescaleDB / Kafka
- Petabyte multi-engine governance → use Iceberg + Snowflake / BigQuery
- Multi-process concurrent writes → wait for DuckDB's Quack remote protocol (beta) or use Postgres

## Quickstart — wire DuckDB MCP into the current project

```bash
~/.claude/skills/duckdb/bootstrap-mcp.sh ./data/analytics.duckdb
```

That installs the MotherDuck official MCP server (`uvx mcp-server-motherduck`)
in **read-only** mode against the given file. Pass `--read-write` if the agent
should be allowed to write.

After running, `claude mcp list` should show `duckdb-analytics`. Then ask the
agent something like "list the tables in the duckdb-analytics database" or
"summarize the schema."

Why MotherDuck's server (vs the three alternatives): the server's
`initialize` response includes a **60+ line DuckDB SQL cheat sheet** the
agent reads on every connect — covering name qualification, advanced
column selection (`* EXCLUDE`, `* REPLACE`, `COLUMNS('pat')`), shortcuts
(`GROUP BY ALL`, `FROM x WHERE y`), complex types, date/time, schema
exploration, and best practices. None of the alternatives bake in this
much agent ergonomics. See [`reference/mcp-implementations.md`](reference/mcp-implementations.md)
for the comparison.

## Canonical patterns

### Pattern 1 — Ad-hoc data exploration

The agent reads CSVs, Parquets, JSON files, or SQLite databases directly
from disk or object storage, with full SQL. Most natural agent-shaped
use case.

```sql
-- The MCP server takes care of attaching paths to query
SELECT * FROM read_csv_auto('logs/*.csv') WHERE level = 'ERROR' LIMIT 20;
SELECT category, COUNT(*) FROM read_parquet('s3://bucket/events-*.parquet') GROUP BY category;
SELECT * FROM read_json_auto('agent-traces.jsonl') WHERE duration_ms > 1000;
```

The agent doesn't write loaders. DuckDB's file-reading prowess becomes the
agent's. See [`reference/extensions-to-know.md`](reference/extensions-to-know.md).

### Pattern 2 — DuckDB on Parquet on S3 (the cost-and-perf wedge)

The killer architecture for analytics under ~1 TB: Parquet on R2 / S3 / GCS,
DuckDB on a small VM reading via the `httpfs` extension. Predicate pushdown
+ column pruning + row-group skipping mean the agent (or your app) pays
network cost only for the columns + row-groups the query actually needs.
Per public case studies, this comes out ~5–10× faster and ~70% cheaper than
Snowflake-class warehouses for the median <1 TB analytical workload.

### Pattern 3 — RAG-in-one-query

The strongest agent-substrate pattern. With `vss` (vector search) + `llm`
(in-SQL LLM calls), a complete RAG pipeline fits in one statement — vector
search + metadata filter + LLM summarize + provenance. No separate vector
DB, no orchestration framework, full reproducibility via SQL.

See [`reference/rag-pattern.md`](reference/rag-pattern.md) for the full
worked example + caveats.

### Pattern 4 — Pair with Turso DB for OLTP

DuckDB doesn't do OLTP. Pair it with **Turso Database** (the active Rust
rewrite of SQLite; SQLite file-format compatible, ships with its own MCP
server) for state + sessions + config + queues, and let DuckDB attach the
Turso file via `sqlite_scanner` for cross-store analytical queries. Best
of both: microsecond OLTP reads + DuckDB's full analytical surface.

See [`reference/pairing-with-turso.md`](reference/pairing-with-turso.md)
for the four base patterns + the parallel-MCP-servers pattern (Pattern G).

If Turso DB's beta status is a concern (shipping to customers, mission-
critical), fall back to libSQL or stock SQLite — the patterns work
identically because all three speak the same file format.

### Pattern 5 — Embedded in a shipping app

DuckDB is **always embedded** — that's its only mode. Link the C/Python/
Node/Rust/Go/Java binding into your app and you have analytics without a
server. Combined with Turso DB the OLTP store, total binary footprint is
~30–80 MB depending on language. Backup is `cp data.db analytics.duckdb
/backup/`. No daemon. No port. No installer for end users to run.

This is the framing for desktop / CLI / agent / mobile / edge apps that
need real analytics without spinning up infrastructure.

## When NOT to use DuckDB

| Workload | Use this instead |
|---|---|
| User accounts / sessions / config | Turso DB / SQLite / Postgres |
| High-write OLTP (many concurrent writers) | Postgres / Turso server mode / DuckDB Quack (beta) |
| Tiny embedded (config store, mobile cache) | SQLite (smaller binary, OLTP-tuned) |
| Real-time event ingestion >10K/sec | ClickHouse / TimescaleDB / Kafka |
| Petabyte multi-engine governance | Iceberg + Snowflake / BigQuery |
| Strong relational integrity across many txns | Postgres |

## Cost awareness

- **DuckDB itself**: free, MIT-licensed. Run anywhere.
- **MotherDuck (hosted)**: free tier (10 GB / 10h compute/mo), Business
  $250/mo + per-second compute ($0.60–$36/hr by instance size), AI Units
  $1 each. Lock-in is shallow — data sits in open formats on neutral
  object storage; engine is OSS.
- **The `llm` extension** makes OpenAI / Anthropic / Cloudflare calls
  from SQL — **each row in a `SELECT openai_chat(...) FROM ...` is a real
  API call billed to the configured key**. Use `LIMIT` aggressively
  during exploration, especially in agent-driven sessions where loops
  are easy to write by accident.
- **The MCP server itself**: free (Python via `uvx`).

## Versions to know (as of 2026-05-18)

- DuckDB: **v1.5.2** (Apr 2026) stable; v1.4 LTS (Sep 2025) with 1-year
  community support. LTS cadence introduced in v1.4 — every other major
  version is LTS.
- DuckLake: **v1.0** (Apr 2026) — production-ready lakehouse format
  with SQL-database catalog (vs Iceberg / Delta's file-based metadata).
- MotherDuck: GA.
- Turso DB: **v0.6.0** (May 2026) — beta but actively shipping.
- MCP protocol: this skill targets **2025-03-26**.

## Skills this composes with

- [`/openrouter`](../openrouter/SKILL.md) — pair with `llm` extension; LLM calls in SQL
- [`/asana`](../asana/SKILL.md) — drop query results into Asana planning hubs
- [`/explore`](../explore/SKILL.md) — multi-source research compile; DuckDB is the local-analytics tier
- [`/beads`](../beads/SKILL.md) — track DuckDB exploration / experimentation work

## See also

- [`reference/mcp-setup.md`](reference/mcp-setup.md) — full wiring recipe for `claude mcp add` + JSON config
- [`reference/extensions-to-know.md`](reference/extensions-to-know.md) — core + community extensions
- [`reference/rag-pattern.md`](reference/rag-pattern.md) — canonical RAG-in-one-query, with code
- [`reference/pairing-with-turso.md`](reference/pairing-with-turso.md) — DuckDB + Turso DB design patterns
- [`reference/mcp-implementations.md`](reference/mcp-implementations.md) — the four MCP server options compared
- [`bootstrap-mcp.sh`](bootstrap-mcp.sh) — one-liner to wire MotherDuck MCP into the current project
- [DuckDB docs](https://duckdb.org/docs/) — official documentation
- [DuckDB community extensions](https://duckdb.org/community_extensions/list_of_extensions) — ~150 extensions worth browsing once

## Authored

Distilled from a focused workshop exploration of DuckDB + MotherDuck for
production, research, and embedded use, plus an MCP server smoke test
(JSON-RPC initialize + tools/list against four candidate servers).
