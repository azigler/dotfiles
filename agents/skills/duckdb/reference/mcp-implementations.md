# DuckDB MCP server implementations — compared

There are at least **four** DuckDB MCP server implementations in the
wild as of 2026-05-18. Plus Turso DB ships its own MCP server, relevant
for the parallel-MCP-servers pattern (see
[`pairing-with-turso.md`](pairing-with-turso.md) Pattern G).

This skill recommends **`mcp-server-motherduck`** (the official server)
as the default. Reasoning + comparison below.

## Comparison table

| Server | Install | Tools | Bakes in SQL primer? | Recent activity | When to pick |
|---|---|---|---|---|---|
| **`mcp-server-motherduck`** (motherduckdb) | `uvx`, ~73 pkgs | 4 (`execute_query`, `list_databases`, `list_tables`, `list_columns`) | **Yes — 60+ lines** in `initialize.instructions` | Active, v1.0.6 | **Default**. Best agent ergonomics. |
| `mcp-server-duckdb` (ktanaka101) | `uvx`, ~31 pkgs | 1 (`query`) | No | Active | Minimal alternative if MotherDuck's footprint feels heavy |
| `duckdb_mcp` extension (teaguesterling) | `git clone + make` | 6 + custom-tool publishing | No (but custom tool descriptions work) | Active community extension | Power-user. When you want bespoke per-table tools the agent calls by name. |
| `duckdb-mcp-server` (mustafahasankhan) | `pip` | 4 with "friendly SQL" wrappers | No | Low (16 stars, no recent releases) | Skip. Friendly-SQL is redundant — DuckDB has those features natively. |
| **Turso DB built-in MCP** | Comes with Turso | (Turso-side tools) | n/a | Active, ships with Turso v0.6.0+ | Pair with DuckDB MCP for the OLTP side of an agent app |

## Why MotherDuck's wins

Smoke-tested via JSON-RPC initialize against `/tmp/smoke-test.duckdb`:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": { "protocolVersion": "2025-03-26", "clientInfo": {...} }
}
```

MotherDuck's `initialize` response includes an `instructions` field —
a 60+ line DuckDB SQL primer the agent reads on **every** connect:

- Name qualification rules (`db.schema.table`, default schemas)
- Identifiers (`"`) vs string literals (`'`)
- Flexible query structure (`FROM x WHERE y` without `SELECT`, `SELECT 1`)
- Advanced column selection (`* EXCLUDE`, `* REPLACE`, `COLUMNS('pat')`)
- Shortcuts (`GROUP BY ALL`, `ORDER BY ALL`)
- Complex types (lists `[1,2,3]`, structs `{'k': v}`, maps, JSON path)
- Date/time (`strptime`, `strftime`, `EXTRACT`)
- Schema exploration (`duckdb_databases()`, `duckdb_tables()`,
  `duckdb_columns()`, `SUMMARIZE`)
- Best practices (filter early, CTEs, `QUALIFY`, `arg_max`)
- Persisting in-memory data to file via `ATTACH` + `COPY FROM DATABASE`

**None of the other servers bake in this much context.** The agent gets
better SQL the moment it connects. That's a meaningful ergonomic advantage,
not just convenience — it reduces hallucination on DuckDB-specific syntax.

Other reasons MotherDuck's server is the right default:

- **Official** — made by MotherDuck (DuckDB Labs), most likely to track
  DuckDB core best
- **One binary, two backends** — supports local `.duckdb` files AND
  MotherDuck-hosted databases via `--db-path md:...`
- **Read-only safe default** — `--read-write` required explicitly
- **Configurable caps** — `--max-rows`, `--max-chars`, `--query-timeout`
  let you bound cost when the agent loops
- **Multiple transports** — stdio (default), HTTP, SSE
- **Active development** — v1.0.6 mature, ongoing releases

## The alternatives — when they make sense

### `mcp-server-duckdb` (ktanaka101)

```bash
uvx mcp-server-duckdb --db-path ./data/analytics.duckdb --readonly
```

Exposes a single `query` tool. ~31 packages installed (less than
MotherDuck's 73). Pick this if:

- You want the smallest possible MCP server footprint
- You only need agent SQL access (no schema-discovery convenience helpers)
- The agent will be writing all its own SQL anyway and doesn't need the
  baked-in instructions

### `duckdb_mcp` extension (teaguesterling)

```sql
-- Inside a DuckDB session:
LOAD 'duckdb_mcp';
PRAGMA mcp_server_start('stdio');
```

A DuckDB *extension* that runs inside an existing DuckDB session, not as
a separate process. **Unique capability**: custom-tool publishing via
`PRAGMA mcp_publish_tool(name, description, sql_template, ...)` — you
register SQL-template-backed tools the agent calls by name.

Pick this when:

- You want bespoke per-table / per-task tools the agent calls explicitly
  (e.g., `get_user_activity_summary(user_id)` as a first-class tool)
- You're already running a long-lived DuckDB session (e.g., a daemon)
  and want to add MCP without spawning a separate process

Install requires `git clone + make` — not currently distributed via the
standard DuckDB extension repository (community extension, build from
source).

### `duckdb-mcp-server` (mustafahasankhan)

Skip. The "friendly SQL" extensions it adds (`GROUP BY ALL`, `* EXCLUDE`,
etc.) are already core DuckDB features. The MotherDuck server's
`execute_query` covers the same surface with better baked-in guidance.

## Bonus — Turso DB's built-in MCP

Turso DB v0.6+ ships with an MCP server built into the binary. Relevant
for the parallel-MCP-servers pattern: wire BOTH Turso MCP (OLTP) and
DuckDB MCP (OLAP) into the same project, and the agent picks the right
one per query.

See [`pairing-with-turso.md`](pairing-with-turso.md) Pattern G.

## Reproducing the smoke test

The MCP JSON-RPC initialize + tools/list probe used to verify the
findings above is reproducible. Probe script:

```bash
#!/usr/bin/env bash
# Send MCP initialize + tools/list to a server's stdin, capture stdout.
set -uo pipefail
name="$1"; shift
echo "=== $name ==="
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0.1"}}}'
  echo '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  sleep 1
} | timeout 8s "$@" 2>/tmp/mcp-$name.stderr | head -300
```

Run against any candidate:

```bash
./probe-mcp.sh motherduck uvx mcp-server-motherduck --db-path ./test.duckdb
./probe-mcp.sh ktanaka uvx mcp-server-duckdb --db-path ./test.duckdb --readonly
```

The protocol's `initialize` response is the most informative artifact —
look for `serverInfo.name`, `serverInfo.version`, `capabilities.tools`,
and especially `instructions` (where MotherDuck shines).

## When to re-evaluate

This recommendation reflects 2026-05-18 state. Worth revisiting if:

- A new "official" DuckDB MCP server lands at duckdb/duckdb
- The MCP protocol changes incompatibly (currently targeting 2025-03-26)
- A new community server emerges with better baked-in agent ergonomics
- DuckDB v2.0 ships and the protocol-server interface changes
