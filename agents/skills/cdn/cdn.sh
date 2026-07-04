#!/usr/bin/env bash
# cdn.sh — Cloudflare R2 CDN helper for the harness (served at cdn.zig.computer).
#
# Full object lifecycle against the `zig-cdn` R2 bucket:
#   up      upload a local file  -> stable PUBLIC url        (default)
#   get     download an object   -> local file              ("load" it back)
#   ls      list objects (size + key), for inspection/cleanup
#   rm      delete object(s)      (cleanup)
#   purge   bust the CDN edge cache for a url/key (optional; needs a token)
#
# STATELESS + SECURE: no `rclone config`, no persistent config file. R2 creds
# are read from ~/.secrets (a source-able export file) and handed to rclone via
# env-var backend config, so no secret ever lands in argv (nothing to leak via
# `ps`). See SKILL.md for the one-time Cloudflare setup + the ~/.secrets vars.
#
# KEY DESIGN — content-addressed by default => immutable, idempotent urls:
#   (default)   img/<sha16>.<ext>            same bytes => same url; re-runs free
#   --review    review/<YYYY-MM>/<sha8>.<ext>  the scp->view-loop killer lane
#   --key <k>   <k> exactly                  meaningful tutorial path
#
# Verification is done AUTHORITATIVELY against R2 (rclone), never by probing the
# public CDN url — a HEAD on a not-yet-cached key negative-caches a 404 at the
# Cloudflare edge for hours, poisoning the very url you just minted.
#
# Output discipline: ONLY the final public url(s) go to STDOUT (one per line,
# pipeable); every diagnostic / progress / ✅ line goes to STDERR. Exit 0 only
# on success; exit 3 = missing required secrets, exit 2 = usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── pure helpers (unit-tested by test/test-cdn.sh via `source`) ──────────────

# Lowercased extension of a path, or "" if the basename has no dot.
ext_of() {
  local base="${1##*/}"
  case "$base" in
    *.*) printf '%s' "${base##*.}" | tr '[:upper:]' '[:lower:]' ;;
    *)   printf '' ;;
  esac
}

# Content-Type for a (lowercased) extension.
content_type_of() {
  case "$1" in
    png)      printf 'image/png' ;;
    jpg|jpeg) printf 'image/jpeg' ;;
    gif)      printf 'image/gif' ;;
    webp)     printf 'image/webp' ;;
    svg)      printf 'image/svg+xml' ;;
    avif)     printf 'image/avif' ;;
    *)        printf 'application/octet-stream' ;;
  esac
}

# Strip ALL trailing slashes from a base url.
strip_trailing_slash() {
  local b="$1"
  while [ "$b" != "${b%/}" ]; do b="${b%/}"; done
  printf '%s' "$b"
}

# Derive the object key for a file. Precedence: --key > --review > default.
#   $1 file   $2 lowercased-ext   $3 key-override ("" if none)   $4 review-flag (1/0)
derive_key() {
  local file="$1" ext="$2" override="$3" review="$4"
  if [ -n "$override" ]; then
    printf '%s' "$override"
    return 0
  fi
  local sha dotext=""
  sha="$(sha256sum "$file" | cut -d' ' -f1)"
  [ -n "$ext" ] && dotext=".$ext"
  if [ "$review" = "1" ]; then
    printf 'review/%s/%s%s' "$(date +%Y-%m)" "${sha:0:8}" "$dotext"
  else
    printf 'img/%s%s' "${sha:0:16}" "$dotext"
  fi
}

# Resolve the rclone binary (PATH first, then the known ~/.local/bin spot).
rclone_bin() {
  if command -v rclone >/dev/null 2>&1; then
    printf 'rclone'
  elif [ -x "$HOME/.local/bin/rclone" ]; then
    printf '%s' "$HOME/.local/bin/rclone"
  else
    return 1
  fi
}

# ── creds ───────────────────────────────────────────────────────────────────

# Source ~/.secrets (overridable via CDN_SECRETS_FILE) into the CURRENT shell,
# recording the path in the global SECRETS_FILE. MUST be called plainly — never
# in $(...), which sources into a subshell and loses the exports.
SECRETS_FILE=""
load_secrets() {
  SECRETS_FILE="${CDN_SECRETS_FILE:-$HOME/.secrets}"
  if [ -f "$SECRETS_FILE" ]; then
    set +u                    # the user's file may reference unset vars
    # shellcheck disable=SC1090
    . "$SECRETS_FILE"
    set -u
  fi
  return 0
}

# Fail (exit 3) unless all five required R2/CDN vars are set.
require_secrets() {
  local secrets_file="${SECRETS_FILE:-$HOME/.secrets}" v
  local -a missing=()
  for v in R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET CDN_BASE_URL; do
    [ -z "${!v:-}" ] && missing+=("$v")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    {
      echo "ERROR: missing required env var(s): ${missing[*]}"
      echo "  cdn.sh reads R2 creds from a source-able export file: $secrets_file"
      echo "  Add these to ~/.secrets and re-run:"
      echo "    export R2_ACCOUNT_ID=...          # Cloudflare account id"
      echo "    export R2_ACCESS_KEY_ID=...       # R2 S3 API token access key (32 hex)"
      echo "    export R2_SECRET_ACCESS_KEY=...   # R2 S3 API token secret (64 hex)"
      echo "    export R2_BUCKET=zig-cdn"
      echo "    export CDN_BASE_URL=https://cdn.zig.computer"
      echo "  Full one-time Cloudflare runbook: see the 'Setup' section of"
      echo "    $SCRIPT_DIR/SKILL.md"
    } >&2
    exit 3
  fi
}

# Export rclone's env-var S3 backend config from the loaded R2_* vars, so no
# secret ever appears in argv. Call AFTER require_secrets.
r2_env() {
  export RCLONE_S3_PROVIDER=Cloudflare
  export RCLONE_S3_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export RCLONE_S3_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export RCLONE_S3_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  export RCLONE_S3_NO_CHECK_BUCKET=true
}

# ── subcommands ─────────────────────────────────────────────────────────────

# up: upload file(s). Idempotent + authoritative (rclone copyto skips the
# transfer if the identical object already exists, and its success means the
# object is in R2 — no public-url probe, so no negative-cache poisoning).
cmd_up() {
  local review=0 dry_run=0 key_override=""
  local -a files=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --review)  review=1 ;;
      --dry-run) dry_run=1 ;;
      --key)     shift; key_override="${1:?--key requires a value}" ;;
      --) shift; while [ $# -gt 0 ]; do files+=("$1"); shift; done; break ;;
      -*) echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
      *)  files+=("$1") ;;
    esac
    shift
  done

  [ "${#files[@]}" -eq 0 ] && { echo "ERROR: up: no input file(s)." >&2; exit 2; }
  if [ -n "$key_override" ] && [ "${#files[@]}" -gt 1 ]; then
    echo "ERROR: --key names one object but ${#files[@]} files were given." >&2; exit 2
  fi

  local base_url
  load_secrets
  if [ "$dry_run" -eq 1 ]; then
    base_url="$(strip_trailing_slash "${CDN_BASE_URL:-https://cdn.zig.computer}")"
  else
    require_secrets; r2_env
    base_url="$(strip_trailing_slash "$CDN_BASE_URL")"
  fi

  local overall_rc=0 file ext ct key url bin
  bin="$(rclone_bin)" || { [ "$dry_run" -eq 1 ] || { echo "ERROR: rclone not found." >&2; exit 2; }; }
  for file in "${files[@]}"; do
    if [ "$dry_run" -eq 0 ] && [ ! -f "$file" ]; then
      echo "ERROR: no such file: $file" >&2; overall_rc=1; continue
    fi
    ext="$(ext_of "$file")"; ct="$(content_type_of "$ext")"
    key="$(derive_key "$file" "$ext" "$key_override" "$review")"
    url="${base_url}/${key}"

    if [ "$dry_run" -eq 1 ]; then
      printf 'dry-run: file=%s key=%s content-type=%s url=%s\n' "$file" "$key" "$ct" "$url" >&2
      printf '%s\n' "$url"; continue
    fi

    # rclone copyto is idempotent (skips if the identical object exists) and its
    # success is the authoritative proof the object is in R2.
    echo "⇡ $file -> :s3:${R2_BUCKET}/${key} ($ct)" >&2
    if ! "$bin" copyto "$file" ":s3:${R2_BUCKET}/${key}" --header-upload "Content-Type: ${ct}" >&2; then
      echo "ERROR: upload failed: $file -> $key" >&2; overall_rc=1; continue
    fi

    # Soft reachability check — CACHE-BUSTED so it never poisons the canonical
    # url. Non-fatal: R2 already has the object; the edge may still be warming.
    if curl -fsS -o /dev/null "${url}?_cb=${RANDOM}${RANDOM}" 2>/dev/null; then
      echo "✅ uploaded + reachable: $key" >&2
    else
      echo "⚠ uploaded to R2 (stored OK) but CDN fetch was non-200 — the edge may be" >&2
      echo "  propagating; the canonical url will serve shortly: $url" >&2
    fi
    printf '%s\n' "$url"
  done
  exit "$overall_rc"
}

# get: download an object from R2 to a local file ("load" it back).
cmd_get() {
  local key="${1:?usage: cdn.sh get <key> [dest]}" dest="${2:-}"
  [ -z "$dest" ] && dest="${key##*/}"
  local bin; load_secrets; require_secrets; r2_env
  bin="$(rclone_bin)" || { echo "ERROR: rclone not found." >&2; exit 2; }
  echo "⇣ :s3:${R2_BUCKET}/${key} -> $dest" >&2
  "$bin" copyto ":s3:${R2_BUCKET}/${key}" "$dest"
  echo "✅ downloaded: $dest" >&2
}

# ls: list objects (size + key). Optional key prefix filter.
cmd_ls() {
  local prefix="${1:-}"
  local bin; load_secrets; require_secrets; r2_env
  bin="$(rclone_bin)" || { echo "ERROR: rclone not found." >&2; exit 2; }
  "$bin" lsl ":s3:${R2_BUCKET}/${prefix}"   # lsl recurses by default
}

# rm: delete object(s). Cheap (DeleteObject is a FREE R2 op). NOTE: the CDN edge
# may keep serving a cached copy until its TTL — `purge` if you need it gone now.
cmd_rm() {
  [ $# -gt 0 ] || { echo "usage: cdn.sh rm <key> [<key>...]" >&2; exit 2; }
  local bin; load_secrets; require_secrets; r2_env
  bin="$(rclone_bin)" || { echo "ERROR: rclone not found." >&2; exit 2; }
  local k
  for k in "$@"; do
    if "$bin" deletefile ":s3:${R2_BUCKET}/${k}" 2>/dev/null; then
      echo "🗑  deleted: $k  (edge cache may serve it until TTL — 'purge' to force)" >&2
    else
      echo "ERROR: delete failed (missing?): $k" >&2
    fi
  done
}

# purge: bust the Cloudflare edge cache for a url/key. OPTIONAL — needs a
# cache-purge token; without one, content-addressed keys make purge unnecessary.
cmd_purge() {
  local target="${1:?usage: cdn.sh purge <url-or-key>}"
  load_secrets; require_secrets
  local url; case "$target" in http*://*) url="$target" ;; *) url="$(strip_trailing_slash "$CDN_BASE_URL")/${target}" ;; esac
  if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] || [ -z "${CF_ZONE_ID:-}" ]; then
    {
      echo "purge needs a cache-purge token, which is NOT configured. Add to ~/.secrets:"
      echo "    export CLOUDFLARE_API_TOKEN=...   # a token with Zone > Cache Purge on zig.computer"
      echo "    export CF_ZONE_ID=...             # the zig.computer zone id"
      echo "Or purge in the dashboard: zig.computer > Caching > Configuration > Purge by URL:"
      echo "    $url"
      echo "TIP: you rarely need this — prefer content-addressed keys (new bytes => new url)."
    } >&2
    exit 3
  fi
  echo "purging edge cache for: $url" >&2
  curl -fsS -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json" \
    --data "{\"files\":[\"${url}\"]}" >&2 && echo "✅ purged: $url" >&2
}

usage() {
  sed -n '2,33p' "$SCRIPT_DIR/cdn.sh" | sed 's/^# \{0,1\}//' >&2
}

# ── dispatch ────────────────────────────────────────────────────────────────
# `up` is the default: a bare `cdn.sh file.png` (or `cdn.sh --review f.png`)
# routes to upload for ergonomics/back-compat.
main() {
  local sub="${1:-}"
  case "$sub" in
    up)            shift; cmd_up "$@" ;;
    get)           shift; cmd_get "$@" ;;
    ls)            shift; cmd_ls "$@" ;;
    rm)            shift; cmd_rm "$@" ;;
    purge)         shift; cmd_purge "$@" ;;
    -h|--help|help) usage; exit 0 ;;
    "")            usage; exit 2 ;;
    *)             cmd_up "$@" ;;   # back-compat: treat as `up <args>`
  esac
}

# Run main only when executed directly; stay quiet when sourced (tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
