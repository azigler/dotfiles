# DuckDB MCP — wiring recipe

How to add the MotherDuck DuckDB MCP server to a Claude Code project so
the agent can query a local `.duckdb` file (and attached Parquet / CSV /
JSON / SQLite / S3 files) via SQL.

## Prereqs

- `uv` / `uvx` installed (https://docs.astral.sh/uv/)
- `claude` CLI installed and logged in
- A target `.duckdb` file (or be ready to create one; `:memory:` works
  for ephemeral exploration)

## One-liner via bootstrap-mcp.sh

The fastest path:

```bash
~/.claude/skills/duckdb/bootstrap-mcp.sh ./data/analytics.duckdb
```

That adds a `duckdb-analytics` MCP server in **read-only** mode pointing
at `./data/analytics.duckdb`. Pass `--read-write` if the agent should be
allowed to write.

The script is idempotent-ish (re-running with the same name fails loudly
rather than silently re-adding — `claude mcp remove duckdb-analytics`
first if you need to re-wire).

## Manual via `claude mcp add`

```bash
# Read-only against a specific file
claude mcp add duckdb-analytics -- uvx mcp-server-motherduck \
  --db-path ./data/analytics.duckdb

# Read-write
claude mcp add duckdb-analytics -- uvx mcp-server-motherduck \
  --db-path ./data/analytics.duckdb --read-write

# Ephemeral in-memory (always writable, lost on session end)
claude mcp add duckdb-mem -- uvx mcp-server-motherduck \
  --db-path :memory: --read-write

# Connecting to MotherDuck (hosted) instead of a local file
export MOTHERDUCK_TOKEN=...
claude mcp add duckdb-hosted -- uvx mcp-server-motherduck \
  --db-path md: --motherduck-token "$MOTHERDUCK_TOKEN"
```

The `--` separator passes the rest of the command line through to the
spawned server process.

### Scopes

Claude Code MCP scopes:

- **local** (default) — current project only; stored in
  `.claude/settings.local.json`
- **project** — committed to `.claude/settings.json` (shared via git)
- **user** — global across all projects

```bash
# Project-scoped (committed; useful for repos where every checkout
# should have DuckDB MCP wired)
claude mcp add --scope project duckdb-analytics -- uvx mcp-server-motherduck \
  --db-path ./data/analytics.duckdb
```

## Manual via JSON (settings.local.json or settings.json)

If you'd rather hand-edit:

```json
{
  "mcpServers": {
    "duckdb-analytics": {
      "command": "uvx",
      "args": [
        "mcp-server-motherduck",
        "--db-path",
        "./data/analytics.duckdb"
      ]
    }
  }
}
```

Add to `.claude/settings.local.json` for local scope, or `.claude/settings.json`
for project scope.

Equivalent via `claude mcp add-json`:

```bash
claude mcp add-json duckdb-analytics '{
  "command": "uvx",
  "args": ["mcp-server-motherduck", "--db-path", "./data/analytics.duckdb"]
}'
```

## Verifying

```bash
# List configured MCP servers
claude mcp list

# Should include something like:
#   duckdb-analytics: uvx mcp-server-motherduck --db-path ... - ✓ Connected
```

Then in the active Claude Code session, ask:

> List the tables in the duckdb-analytics database.

The agent should call the server's `list_tables` tool and respond. If
the DB is empty, it'll say so honestly.

## Parallel servers — Turso MCP alongside DuckDB MCP

The strongest pattern for agent-driven apps with both transactional and
analytical surfaces. Turso DB ships with a built-in MCP server; wire both:

```bash
# OLTP side (app state, sessions, config)
claude mcp add turso-app -- turso mcp --db app.db

# OLAP side (events, traces, analytics)
claude mcp add duckdb-analytics -- uvx mcp-server-motherduck \
  --db-path analytics.duckdb
```

The agent gets two MCP servers; it picks the right one per query. See
[`pairing-with-turso.md`](pairing-with-turso.md) Pattern G for the
deeper architecture.

## Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `Error: db path does not exist` | File doesn't exist; default is read-only so DuckDB won't create it | Pre-create the file: `python3 -c "import duckdb; duckdb.connect('./data/analytics.duckdb').close()"`, or pass `--read-write` |
| Agent tries to write but gets "read-only" | Default is read-only for file-based DBs | Re-add with `--read-write` |
| First query takes 30–60s | uvx is downloading `mcp-server-motherduck` (73 packages) on first run | Pre-warm: `uvx --quiet mcp-server-motherduck --help` |
| `claude mcp list` shows `! Failed to connect` | Likely `uvx` not in `PATH` for the Claude Code session | Use the absolute path: `claude mcp add duckdb -- /home/USER/.local/bin/uvx mcp-server-motherduck --db-path ...` |
| Agent can't see new data | Server caches the file handle | `claude mcp remove duckdb-analytics && bootstrap-mcp.sh ...` to recycle |
| Need MotherDuck connection in addition | `--db-path md:DBNAME` works, but in-memory + MotherDuck can't coexist in one server invocation | Run two MCP servers — one local-file, one MotherDuck — under different names |

## Removing

```bash
claude mcp remove duckdb-analytics
```

Or edit `.claude/settings.local.json` directly to remove the entry under
`mcpServers`.

## Read-only vs read-write — choose deliberately

**Default to read-only.** The agent can `execute_query` (SELECT,
DESCRIBE, SUMMARIZE) but cannot INSERT / UPDATE / DELETE / DROP / CREATE.
This is the right default for almost all agent-driven analytics work —
the agent explores, you mutate.

Reach for `--read-write` when:
- You want the agent to materialize intermediate tables across turns
  (`CREATE TEMP TABLE filtered AS SELECT ...`)
- The agent is doing iterative data cleanup ("save the cleaned version
  as `clean_products`")
- You're explicitly building an agent-driven ETL pipeline

For in-memory DBs (`--db-path :memory:`), DuckDB always allows writes
regardless of the flag.

## Removing the cost surface (when the agent is too curious)

If the agent keeps invoking the `llm` extension or making expensive S3
range reads, restrict at the MCP layer rather than fighting at the prompt
layer:

```bash
# Tighter caps
claude mcp add duckdb-analytics -- uvx mcp-server-motherduck \
  --db-path ./data/analytics.duckdb \
  --max-rows 100 \
  --max-chars 5000 \
  --query-timeout 30
```

This limits both how much the agent can pull per query and how long any
single query can run. Useful in long agent loops where one runaway query
can be expensive.
