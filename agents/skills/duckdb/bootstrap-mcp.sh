#!/usr/bin/env bash
# Bootstrap the MotherDuck official DuckDB MCP server into the current
# Claude Code project. Idempotent-ish: re-running with the same server
# name will fail loudly (use `claude mcp remove <name>` first to re-wire).
#
# Usage:
#   bootstrap-mcp.sh [DB_PATH] [--read-write|-w] [--name NAME] [--help]
#
# Examples:
#   bootstrap-mcp.sh                                   # ./data/analytics.duckdb, read-only
#   bootstrap-mcp.sh /tmp/my.duckdb                    # specific path, read-only
#   bootstrap-mcp.sh /tmp/my.duckdb --read-write       # specific path, writable
#   bootstrap-mcp.sh --name kb -- ./kb.duckdb          # custom server name

set -euo pipefail

DB_PATH=""
READ_WRITE_FLAG=""
SERVER_NAME="duckdb-analytics"

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --read-write|-w)
      READ_WRITE_FLAG="--read-write"
      ;;
    --name)
      shift
      SERVER_NAME="${1:?--name requires a value}"
      ;;
    --help|-h)
      cat <<EOF
Usage: bootstrap-mcp.sh [DB_PATH] [--read-write|-w] [--name NAME]

Wires the official MotherDuck DuckDB MCP server into the current Claude
Code project at local scope (.claude/settings.local.json).

Arguments:
  DB_PATH         Path to .duckdb file (default: ./data/analytics.duckdb).
                  Will be created if it doesn't exist.

Options:
  --read-write    Allow the agent to write to the DB (default: read-only).
                  In-memory DBs (:memory:) are always writable.
  --name NAME     MCP server name (default: duckdb-analytics).
                  Use this if you're wiring multiple DuckDB MCP servers.
  -h, --help      Show this help.

Verification after running:
  claude mcp list                  # should show your server
  Ask the agent: "list the tables in the $SERVER_NAME database"

Removal:
  claude mcp remove $SERVER_NAME
EOF
      exit 0
      ;;
    --)
      # Skip explicit separator
      ;;
    -*)
      echo "ERROR: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [ -z "$DB_PATH" ]; then
        DB_PATH="$1"
      else
        echo "ERROR: extra positional argument: $1" >&2
        exit 2
      fi
      ;;
  esac
  shift
done

DB_PATH="${DB_PATH:-./data/analytics.duckdb}"

# Verify uvx
if ! command -v uvx >/dev/null 2>&1; then
  echo "ERROR: uvx not found in PATH." >&2
  echo "  Install uv first: https://docs.astral.sh/uv/" >&2
  exit 1
fi

# Verify claude CLI
if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: claude CLI not found in PATH." >&2
  echo "  Install Claude Code first." >&2
  exit 1
fi

# Handle :memory: as a special path
if [ "$DB_PATH" = ":memory:" ] || [ "$DB_PATH" = "md:" ] || [[ "$DB_PATH" == md:* ]]; then
  DB_PATH_ABS="$DB_PATH"
  # In-memory always writable; MotherDuck connections handled by --motherduck-token
  echo "Using special db-path: $DB_PATH_ABS"
else
  # Resolve to absolute path so the MCP server starts from any cwd
  DB_PATH_ABS="$(realpath -m "$DB_PATH")"
  DB_DIR="$(dirname "$DB_PATH_ABS")"

  if [ ! -d "$DB_DIR" ]; then
    echo "Creating parent dir: $DB_DIR"
    mkdir -p "$DB_DIR"
  fi

  # If the DB file doesn't exist and we're in read-only mode, the server
  # will fail to connect. Pre-create it.
  if [ ! -f "$DB_PATH_ABS" ]; then
    if [ -z "$READ_WRITE_FLAG" ]; then
      echo "Pre-creating empty DB at $DB_PATH_ABS (read-only mode won't auto-create)..."
      python3 -c "import duckdb; duckdb.connect('$DB_PATH_ABS').close()" 2>/dev/null || \
      duckdb "$DB_PATH_ABS" -c ".tables" >/dev/null 2>&1 || {
        echo "WARNING: couldn't pre-create $DB_PATH_ABS. Server may fail on first connect." >&2
      }
    fi
  fi
fi

# Pre-warm uvx so the first MCP request isn't a 60s install
echo "Pre-warming mcp-server-motherduck via uvx..."
uvx --quiet mcp-server-motherduck --help >/dev/null 2>&1 || {
  echo "WARNING: uvx couldn't pre-fetch mcp-server-motherduck. First MCP request may be slow." >&2
}

# Add the MCP server
echo
echo "Adding MCP server '$SERVER_NAME' pointed at $DB_PATH_ABS"
if [ -n "$READ_WRITE_FLAG" ]; then
  echo "  Mode: READ-WRITE (agent can modify the DB)"
  claude mcp add "$SERVER_NAME" -- uvx mcp-server-motherduck \
    --db-path "$DB_PATH_ABS" --read-write
else
  echo "  Mode: READ-ONLY (default; pass --read-write to enable writes)"
  claude mcp add "$SERVER_NAME" -- uvx mcp-server-motherduck \
    --db-path "$DB_PATH_ABS"
fi

echo
echo "Done. Verify with:"
echo "  claude mcp list"
echo
echo "Test by asking the agent:"
echo "  \"list the tables in the $SERVER_NAME database\""
echo
echo "Remove later with:"
echo "  claude mcp remove $SERVER_NAME"
