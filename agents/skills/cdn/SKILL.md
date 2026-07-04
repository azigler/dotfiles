---
name: cdn
description: Upload a local file to Cloudflare R2 and get back a stable PUBLIC url (served at cdn.zig.computer). Full lifecycle — up / get / ls / rm / purge — for two jobs: durable homes for PUBLISHED images (AAIF tutorials, andrewzigler.com/blog markdown; screenshots + generated art that need embeddable urls, since Zig won't put images in his site folder), and killing the scp->view loop (post an openable url instead of scp'ing a screenshot for review). Content-addressed keys => idempotent, IMMUTABLE urls; re-runs are free. Stateless + secure — creds read from ~/.secrets, handed to rclone via env-var backend config so no secret lands in argv.
when_to_use: You have a local image/file that needs a public url — embedding a screenshot or figure in a published markdown post/gist/tutorial, or you generated an image on this box and want to hand Zig an openable link instead of scp'ing it. Also to fetch an object back (get), audit/clean up what's stored (ls/rm), or force-refresh a cached url (purge). NOT for private/sensitive files — the bucket is PUBLIC.
argument-hint: "up <file> [--key aaif/x.png|--review] | get <key> [dest] | ls [prefix] | rm <key> | purge <url>"
allowed-tools: Bash(*/cdn.sh *) Bash(rclone *) Bash(curl *) Bash(sha256sum *) Bash(file *)
---

# /cdn — Cloudflare R2 CDN helper (cdn.zig.computer)

Upload a local file → get a stable **public** url fronted by the custom domain
`cdn.zig.computer`, backed by the `zig-cdn` R2 bucket. The tool is
`cdn.sh` (next to this file). Two jobs it exists for:

1. **Durable homes for published images.** AAIF tutorials + andrewzigler.com
   posts ship as flat markdown/gists; images can't be local files and Zig
   won't put them in his site folder. `/cdn` gives every screenshot / figure a
   permanent embeddable url.
2. **Kill the scp→view loop.** Generated an image on this box? Upload it and
   hand Zig an openable link instead of scp'ing the file for review.

## Free tier — stay under it (this is the whole cost model)

R2's free tier (https://developers.cloudflare.com/r2/pricing/#free-tier):

| Resource | Free allowance / month | What spends it here |
|---|---|---|
| **Storage** | **10 GB-month** | every object you keep (the binding constraint) |
| **Class A ops** (writes/lists) | **1 million / month** | `up` (PutObject), `ls` (ListObjects) |
| **Class B ops** (reads) | **10 million / month** | `get` (GetObject); CDN cache-misses |
| **Egress** (data to internet) | **Free** | serving images to viewers — **always free** |

**Reading the table:** egress is free, so *serving* images costs nothing no
matter how popular. `rm` (DeleteObject) is a **free** op. Ops are effectively
unlimited at our scale (millions/month vs a handful of uploads). **Storage is
the only real cap** — 10 GB holds thousands of screenshots/figures, but it's
not infinite, so:

- **Content-addressed keys dedup automatically** — re-uploading identical bytes
  is a no-op (same `img/<sha16>` key; rclone skips the transfer). You can't
  bloat storage by re-running.
- **Clean up the `review/` lane** — scp-loop-killer uploads are throwaway;
  `cdn.sh rm review/<...>` or sweep the prefix periodically. (A lifecycle rule
  on the `review/` prefix in the R2 dashboard can auto-expire them.)
- **`cdn.sh ls` to audit** what's stored before it adds up.

## Setup (one-time — already done on zig-computer)

Creds live in `~/.secrets` (mode 600, source-able). Required vars:

```sh
export R2_ACCOUNT_ID=...          # Cloudflare account id (the S3 endpoint host)
export R2_ACCESS_KEY_ID=...       # R2 S3 API token Access Key ID (32 hex)
export R2_SECRET_ACCESS_KEY=...   # R2 S3 API token Secret (64 hex)
export R2_BUCKET=zig-cdn
export CDN_BASE_URL=https://cdn.zig.computer
```

To reproduce from scratch (new box / rotated token), in the Cloudflare
dashboard: **R2 → enable** (needs a payment method even for the free tier) →
**create bucket `zig-cdn`** → **bucket → Settings → Custom Domains → add
`cdn.zig.computer`** (the `zig.computer` zone is already on Cloudflare, so this
auto-provisions DNS + TLS) → **R2 → Manage R2 API Tokens → Create** *Object Read
& Write* → copy the **Access Key ID** (32 hex — NOT the account id, NOT the
`cfat_` token value) and **Secret Access Key** (64 hex) into `~/.secrets`.
Requires `rclone` (PATH or `~/.local/bin/rclone`).

## Lifecycle

### Upload (`up`, the default)
```sh
cdn.sh some-shot.png                      # -> https://cdn.zig.computer/img/<sha16>.png
cdn.sh --key aaif/goose/fig1.png shot.png # meaningful tutorial path
cdn.sh --review screenshot.png            # -> review/<YYYY-MM>/<sha8>.png (throwaway lane)
cdn.sh --dry-run x.png                    # print key/url, no creds, no network
cdn.sh a.png b.png c.png                  # batch; one url per stdout line
```
`up` prints **only the url(s) to stdout** (pipeable); progress goes to stderr.
It's idempotent: identical bytes → identical key → the upload is skipped and the
same url returned. Verification is authoritative against R2 (a successful
`rclone copyto` *is* the proof it's stored) — the tool never HEADs the public
url (see Caching gotcha).

### Load it back (`get`)
```sh
cdn.sh get img/ab12cd34ef567890.png            # -> ./ab12cd34ef567890.png
cdn.sh get aaif/goose/fig1.png /tmp/fig1.png   # explicit dest
```

### Inspect / clean up (`ls`, `rm`)
```sh
cdn.sh ls                    # everything (size + key)
cdn.sh ls review/            # just the throwaway lane
cdn.sh rm review/2026-07/ab12cd34.png   # delete (free op)
```

### Force-refresh a cached url (`purge`) — optional
```sh
cdn.sh purge https://cdn.zig.computer/aaif/logo.png
```
Only needed when you **overwrite a fixed key** (see next). Needs a cache-purge
token in `~/.secrets` (`CLOUDFLARE_API_TOKEN` + `CF_ZONE_ID`); without one it
prints the dashboard purge path. You rarely need it — prefer content-addressed
keys.

## Re-uploading on top of a file (overwrite) — supported, but read this

**Yes, overwrite works at the storage layer** (empirically verified): a
`--key`-pinned upload with new bytes replaces the R2 object. **But the CDN edge
caches the old version** — the canonical url keeps serving the *stale* bytes
until the cache TTL expires (verified: after overwrite, `cf-cache-status: HIT`
returns the old md5; a cache-busted `?_cb=` GET returns the new one). So:

- **Default pattern — content-addressed keys (recommended):** new bytes produce
  a *new* url automatically (`img/<new-sha>`), so there's nothing stale to
  serve. This is why the default is immutable-by-design. Just upload the new
  file and use the new url.
- **If you must keep a fixed url** (e.g. `aaif/logo.png` that updates in place):
  overwrite, then `cdn.sh purge <url>` (or purge in the dashboard). Until
  purged, viewers see the old image.
- Immutable content-addressed keys are also safe to embed in published posts
  forever — the url can never silently change under you.

## Caching gotcha (why verification uses R2, not the public url)

Cloudflare **negative-caches a 404 for ~4 hours**. The original tool HEAD-probed
the public url right after upload to "verify" — but for a brand-new
content-addressed key that HEAD raced ahead of edge propagation, cached the
404, and poisoned the exact url just minted (image broken for 4h). Fixed: the
tool confirms uploads authoritatively via R2 (rclone), and only ever touches the
public url with a **cache-busted** `?_cb=` GET (separate cache key, never
poisons the canonical url). Don't reintroduce a bare HEAD/GET of the canonical
url around upload.

## AAIF consumer

This unblocks the AAIF Ambassador tutorial *"Every goose needs its plane"* — the
gist ships as markdown that can't embed local images (gist rejects binary), so
the screenshots need CDN urls. Consumer beads: `aaif-…18o.34` (publish-blocker:
images need CDN-hosted urls) feeding the P1 submission `aaif-…18o.28`. Host each
figure with a meaningful key, e.g. `cdn.sh --key aaif/goose/step3-logs.png shot.png`.

## Anti-patterns

- ❌ **Uploading anything private/sensitive** — the bucket is PUBLIC; any object
  is world-readable at its url. Screenshots must be redacted first.
- ❌ **Committing uploaded images into a git repo** — the whole point is to keep
  binaries OUT of the site/repo. Upload → embed the url.
- ❌ **Overwriting a fixed key and expecting an instant refresh** — the edge
  serves stale until TTL; purge, or use content-addressed keys.
- ❌ **HEAD/GET-ing the canonical public url right after upload to "verify"** —
  negative-caches a 404 for hours. Verify via R2; cache-bust any public probe.
- ❌ **Letting the `review/` lane pile up** — it's throwaway; sweep it so storage
  stays well under 10 GB.
- ❌ **Hardcoding creds** in the tool or a repo — they live only in `~/.secrets`.

## See also

- `cdn.sh` — the tool (next to this file); `cdn.sh --help` for the synopsis.
- R2 free tier: https://developers.cloudflare.com/r2/pricing/#free-tier
- Origin exploration: `~/explore` bead `explore-q9qb` (backend decision + the
  live setup + the cache-poisoning bug this graduated tool fixes).
