# RAG-in-one-query — the canonical pattern

DuckDB's killer agent-substrate pattern. A complete RAG pipeline —
vector search + metadata filter + LLM summarize with provenance — in
**one SQL statement**, against a single `.duckdb` file (or Parquet on
S3), with no separate vector DB.

## Why this is novel

The traditional RAG architecture: Pinecone / Weaviate / Qdrant for
vector search, plus a separate LLM call. **Two systems. Two SDKs. Two
failure modes. Two bills.**

The DuckDB shape: one process, one file, one SQL statement. The agent
writes the query, runs it, inspects the result, iterates — same
back-and-forth as any other SQL workflow, fully reproducible because
the SQL is the contract.

What's understated vs vendor demos:

- **Joins with metadata are free.** "Top-K chunks AND only from documents
  written after 2025-01-01 by author X with tag Y" is a `WHERE` clause,
  not a vector-DB-feature-request.
- **The agent can write it.** The MCP server gives the agent
  schema introspection; the agent doesn't hallucinate column names.
- **Fully inspectable.** No "what did Pinecone return?" mystery; the SQL
  shows you every step.

## Setup (one-time)

```sql
INSTALL vss; LOAD vss;
INSTALL llm; LOAD llm;

-- Chunks table — your docs are sliced into smaller pieces with embeddings.
CREATE TABLE chunks (
  chunk_id   INTEGER PRIMARY KEY,
  doc_id     VARCHAR,
  source_url VARCHAR,
  author     VARCHAR,
  created_at TIMESTAMP,
  tags       VARCHAR[],
  content    TEXT,
  embedding  FLOAT[1024]
);

-- Populate chunks externally (Python / Bun / wherever you ingest docs).
-- The `llm` extension can also generate embeddings:
--   UPDATE chunks SET embedding = openai_embedding(content)
--   WHERE embedding IS NULL;
-- but be careful in loops — each row is an API call.

-- HNSW index for fast similarity search.
CREATE INDEX chunks_hnsw ON chunks USING HNSW (embedding);
```

The HNSW index is the `vss` extension's core capability. Without it,
similarity search is a full table scan; with it, search is
sub-linear-time even on millions of chunks.

## The query

```sql
WITH query_emb AS (
  -- Compute the query's embedding inline.
  SELECT openai_embedding('How does Parquet predicate pushdown work?') AS v
),
similar AS (
  -- HNSW similarity search + optional metadata filters.
  SELECT c.chunk_id,
         c.content,
         c.source_url,
         c.author,
         array_distance(c.embedding, q.v) AS distance
  FROM chunks c, query_emb q
  WHERE c.created_at > '2025-01-01'       -- optional metadata filter
    AND 'database' = ANY(c.tags)           -- optional tag filter
  ORDER BY distance
  LIMIT 5
)
SELECT
  openai_chat(
    'gpt-4o-mini',
    'Answer using only these excerpts. If they don''t answer the ' ||
    'question, say so honestly.\n\n' || string_agg(content, E'\n---\n')
  ) AS answer,
  list(struct_pack(url := source_url, distance := distance)) AS sources
FROM similar;
```

One statement does:

1. Embed the query (`openai_embedding`)
2. Vector search via HNSW (`array_distance` + `ORDER BY ... LIMIT 5`)
3. Filter by metadata (`WHERE created_at > ...`)
4. Generate the answer (`openai_chat`)
5. Return the provenance (`list(struct_pack(...))`)

## What gets returned

```
answer                                           | sources
-------------------------------------------------|-------------------------------------------
Parquet predicate pushdown uses per-row-group    | [{url: 'parquet.md', distance: 0.12},
statistics (min, max, null count, optional      |  {url: 'duckdb-on-s3.md', distance: 0.15},
Bloom filter) to skip row groups whose values   |  {url: 'arch-summary.md', distance: 0.21},
can't match the WHERE clause. Combined with     |  {url: 'lakehouse-101.md', distance: 0.34},
column pruning, you read 1% of the file...      |  {url: 'pandas-vs-duck.md', distance: 0.41}]
```

The agent (or you) gets the answer AND the source URLs in one round-trip.
If the answer is wrong, the sources show what evidence was used; iterate
on the chunking or the query without leaving SQL.

## Cost awareness

**Every row that calls `openai_embedding(...)` or `openai_chat(...)` is a
real API call billed to your key.**

- A 5-chunk RAG query = 1 embedding call + 1 chat call ≈ $0.001–$0.01
  depending on model
- The same query in a loop over 10,000 questions = 20,000 calls = $10–$100
- `UPDATE chunks SET embedding = openai_embedding(content)` over 100K
  chunks = 100K calls (real money)

Mitigations:

```sql
-- Set env var first
SET VARIABLE openai_api_key = '<key>';

-- Always LIMIT during exploration
WITH similar AS (SELECT ... ORDER BY distance LIMIT 3) ...

-- Batch embeddings in a one-time backfill, not on every query
UPDATE chunks SET embedding = openai_embedding(content)
WHERE embedding IS NULL LIMIT 100;   -- rate-limit yourself in chunks
```

For agent-driven exploration: set tight `--max-rows` and `--query-timeout`
on the MCP server (see [`mcp-setup.md`](mcp-setup.md)) so a runaway agent
loop doesn't blow your OpenAI bill.

## When NOT to use this pattern

- **Embeddings are unstable** — if you switch embedding models, the
  whole `chunks.embedding` column needs reindexing. Plan for that.
- **You need the absolute lowest latency vector search** — Pinecone /
  Weaviate / Qdrant are genuinely faster at scale (10s of millions of
  vectors with sub-10ms p99). DuckDB+vss is great up to a few million
  chunks; beyond that, profile.
- **You need real-time updates** — DuckDB is single-writer; if your
  chunk corpus updates from many concurrent writers, you need a real
  vector DB or a queued single-writer ingester.
- **You don't want to track the OpenAI/Anthropic API key as a secret in
  your DuckDB process** — fair concern; do embeddings + LLM calls
  externally and store results.

## Variations

### Local embeddings (no API key needed)

Use the `quackformers` community extension for BERT-based embeddings
running in-process. Quality is lower than OpenAI's `text-embedding-3-*`
but it's free and doesn't leak data:

```sql
INSTALL quackformers FROM community;
LOAD quackformers;

UPDATE chunks SET embedding = quackformers_embed(content, 'all-MiniLM-L6-v2')
WHERE embedding IS NULL;
```

### Hybrid search (BM25 + vector)

The `fts` extension gives full-text BM25 search. Combine with vector
search by ranking with a weighted score:

```sql
WITH bm25 AS (
  SELECT chunk_id, fts_main_chunks.match_bm25(chunk_id, 'parquet pushdown') AS score
  FROM chunks WHERE score > 0
),
vec AS (
  SELECT chunk_id, array_distance(embedding, $query_emb) AS distance
  FROM chunks
)
SELECT c.content, (b.score * 0.4 + (1 - v.distance) * 0.6) AS hybrid_score
FROM chunks c
JOIN bm25 b USING (chunk_id)
JOIN vec  v USING (chunk_id)
ORDER BY hybrid_score DESC LIMIT 5;
```

### Multi-step reasoning

The agent can build up state across turns using temp tables:

```sql
-- Turn 1: agent finds candidates
CREATE TEMP TABLE candidates AS
SELECT chunk_id, content FROM chunks
WHERE array_distance(embedding, $q1) < 0.3 LIMIT 50;

-- Turn 2: agent filters by another dimension
CREATE TEMP TABLE shortlisted AS
SELECT * FROM candidates WHERE content ILIKE '%predicate pushdown%';

-- Turn 3: agent synthesizes
SELECT openai_chat('gpt-4o-mini', 'Synthesize:\n' || string_agg(content, E'\n'))
FROM shortlisted;
```

(Requires `--read-write` on the MCP server.)

## See also

- [`extensions-to-know.md`](extensions-to-know.md) — `vss`, `llm`,
  `quackformers`, `fts` details
- [`mcp-setup.md`](mcp-setup.md) — wiring the MCP server so the agent
  can run these queries
- [DuckDB vss docs](https://duckdb.org/docs/extensions/vss)
- [DuckDB community `llm` extension](https://duckdb.org/community_extensions/extensions/llm)
