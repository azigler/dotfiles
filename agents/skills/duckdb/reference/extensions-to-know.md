# DuckDB extensions worth knowing

Pattern for loading:

```sql
INSTALL <name>;
LOAD <name>;
```

Many core extensions **autoload** in DuckDB v1.4+ — `SELECT * FROM
read_parquet('s3://...')` triggers `httpfs` + `parquet` auto-install. The
manual `INSTALL/LOAD` is for cases where the autoload heuristic doesn't
fire (uncommon).

## Core (autoload, MIT-license, ship with the engine)

| Extension | What it does | Reach for it when... |
|---|---|---|
| `parquet` | Read/write Parquet | Querying or writing Parquet files |
| `json` | Read/write JSON, JSON path operators | Querying JSONL, configs, API dumps |
| `httpfs` | S3 / GCS / Azure / HTTP file access via range reads | Querying remote Parquet / CSV / JSON without downloading |
| `sqlite` | Read/write SQLite files (and libSQL / Turso files) | Federating across an OLTP store; see `pairing-with-turso.md` |
| `excel` | Read Excel via spatial dependencies | One-off Excel dumps from vendors |
| `fts` | Full-text search (BM25) | Document search inside DuckDB |
| `icu` | International collation, locale-aware operations | Non-ASCII string handling |
| `inet` | Network types (INET, CIDR) | IP-address analysis |
| `tpch` / `tpcds` | TPC benchmark generators | Smoke-testing performance |

## High-leverage extras (worth `INSTALL`ing on demand)

### Analytics / search

| Extension | What it does | Reach for it when... |
|---|---|---|
| **`vss`** | Vector similarity search w/ HNSW indexes | RAG, embeddings, similarity queries; the agent-substrate killer feature |
| **`llm`** | Call OpenAI / Anthropic / Cloudflare LLMs from SQL | RAG-in-one-query (see `rag-pattern.md`); summarize columns; classify rows |
| `spatial` | GIS types + functions (GDAL-backed) | Geographic queries, mapping data |
| `aws` | AWS SDK integration (credentials, regions) | Heavy S3 work; SSO-managed creds |

### Federation (read from other databases)

| Extension | What it does |
|---|---|
| `postgres_scanner` | Read from PostgreSQL |
| `mysql_scanner` | Read from MySQL |
| `sqlite` (already core) | Read from SQLite / libSQL / Turso |

### Lakehouse formats

| Extension | What it does |
|---|---|
| `iceberg` | Read/write Apache Iceberg tables |
| `delta` | Read Delta Lake tables |
| **`ducklake`** | DuckDB Labs' own lakehouse format — SQL-database catalog instead of file-based metadata. v1.0 GA Apr 2026. |

### Cloud / hosted

| Extension | What it does |
|---|---|
| `motherduck` | Connect a local DuckDB session to MotherDuck-hosted databases (hybrid local + cloud execution) |

### Substrait (query plan portability)

| Extension | What it does |
|---|---|
| `substrait` | Emit / consume Substrait query plans |

## Community extensions (the long tail)

Browse the full list at https://duckdb.org/community_extensions/list_of_extensions

Categories worth knowing exist there:

- **AI/ML**: `faiss`, `hnsw_acorn`, `vindex`, `quackformers` (BERT
  embeddings), `pic2vec` (ONNX image embeddings), `infera` (in-DB
  inference), `whisper` (speech-to-text), **`duckdb_mcp`** (DuckDB as
  MCP server — an alternative to standalone MCP servers; see
  `mcp-implementations.md`)
- **DB integration**: `bigquery`, `snowflake`, `mongo`, `elasticsearch`,
  `mssql`, `hive_metastore`, `airport` (Arrow Flight SQL)
- **File formats**: `read_stat` (SAS/Stata/SPSS), `anndata` (genomics),
  `pbix` (PowerBI), `pst` (Outlook PST email), `rusty_sheet` / `sheetreader`
  (Excel), `markdown`, `webbed` (XML/HTML), `ion` (AWS Ion), `protoduck`
  (Protobuf)
- **Geospatial**: `h3` (hex grid), `duck_dggs`, `pdal` (point clouds),
  `overture` (Overture Maps), `raster`, `valhalla_routing`
- **Web / API**: `crawler` (SQL-native web crawler), `web_archive`
  (Common Crawl / Wayback), `web_search` (Google Custom Search),
  `gsheets` (Google Sheets), `http_client`, `sitemap`, `dns`
- **Scripting**: `lua`, `quickjs` (JS UDFs), `minijinja`, `tera`,
  `evalexpr_rhai`, `dplyr` (R-pipeline-to-SQL)
- **Time series**: `anofox_forecast` (ARIMA/SARIMA/ETS), `datasketches`
  (HLL, t-digest), `talib` (100+ TA indicators)
- **Storage / FS**: `cache_httpfs` (cached remote files),
  `curl_httpfs` (HTTP/2 + pooling), `delta_classic`, `delta_export`,
  `duck_lineage` (OpenLineage), `ducksync` (DuckDB ↔ Snowflake cache),
  `hostfs`, `shellfs`, `sshfs`
- **Observability**: `otlp` (OpenTelemetry metrics/logs/traces),
  `observefs` (I/O observability), `duck_hunt` (CI/CD log parsing)

## The pattern this enables

DuckDB extensions stack on top of each other in one query. A non-obvious
example combining four extensions:

```sql
-- 1. Read Parquet from S3 (parquet + httpfs)
-- 2. Federate with PostgreSQL (postgres_scanner)
-- 3. Search via embeddings (vss)
-- 4. Summarize via LLM (llm)
INSTALL httpfs; LOAD httpfs;
INSTALL postgres_scanner; LOAD postgres_scanner;
INSTALL vss; LOAD vss;
INSTALL llm; LOAD llm;

ATTACH 'postgresql://...' AS pg (TYPE postgres);

WITH similar_docs AS (
  SELECT chunk_id, content, source_url,
         array_distance(embedding, $1::FLOAT[1024]) AS distance
  FROM read_parquet('s3://kb-bucket/chunks-*.parquet')
  ORDER BY distance LIMIT 5
),
context AS (
  SELECT s.content, u.name AS author
  FROM similar_docs s
  LEFT JOIN pg.public.users u ON u.id = s.author_id
)
SELECT openai_chat(
  'gpt-4o-mini',
  'Summarize using these excerpts:\n' || string_agg(content, E'\n')
) AS answer
FROM context;
```

Four extensions, one query, multiple data sources, complete RAG with
provenance. **The agent doesn't write loaders — DuckDB does.**

## What's NOT in extensions

Things you might assume are extensions but ship in core:

- Window functions (`OVER (...)`)
- CTEs (recursive too)
- Lists / structs / maps / unions (complex types)
- Date/time functions
- `SUMMARIZE` table command
- `FROM x` (omitting `SELECT *`)
- `GROUP BY ALL` / `ORDER BY ALL`
- `* EXCLUDE (col)` / `* REPLACE (...)`
- `QUALIFY` (filter after window)

These are core DuckDB SQL and don't need anything installed.
