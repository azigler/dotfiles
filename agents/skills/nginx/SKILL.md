---
description: Global nginx reverse proxy — site layout, TLS via certbot, adding a new project vhost, testing + reload discipline. Auto-loads when working with nginx vhost configs, sites-enabled, or ops/nginx project subdirs.
paths: "**/nginx.conf,**/*.nginx.conf,**/sites-available/**,**/sites-enabled/**,**/ops/nginx/**,**/etc/nginx/**"
allowed-tools: Bash(sudo nginx -t) Bash(sudo nginx -T) Bash(sudo systemctl reload nginx) Bash(sudo systemctl restart nginx) Bash(sudo systemctl status nginx) Bash(sudo tail*nginx*) Bash(sudo certbot *)
---

# nginx

This host runs a single system-wide nginx as the HTTP(S) edge for
multiple projects. Every project gets one or more vhosts under
`/etc/nginx/sites-available/`, enabled via symlink into
`/etc/nginx/sites-enabled/`. TLS is managed by certbot (Let's Encrypt)
with auto-renewal.

## Layout

```
/etc/nginx/
  nginx.conf                     # core; includes sites-enabled/*
  sites-available/               # all vhost configs live here
    default                      # Debian default (can stay disabled)
    <host>.conf                  # one file per public host
  sites-enabled/                 # symlinks to active vhosts
    <host>.conf -> ../sites-available/<host>.conf
  conf.d/                        # global snippets (rate limits, maps)
  snippets/                      # includable bits (ssl params, headers)
```

Projects should keep the source-of-truth for their own vhost in
their own repo (e.g. `<project>/ops/nginx/<host>.conf`) and either
symlink or `install -m 0644` it into `/etc/nginx/sites-available/`
during deploy.

## Quick reference

```bash
sudo nginx -t                    # validate config; ALWAYS before reload
sudo systemctl reload nginx      # graceful reload (preserves connections)
sudo systemctl restart nginx     # hard restart (drops connections)
sudo tail -f /var/log/nginx/error.log /var/log/nginx/access.log
sudo nginx -T 2>/dev/null | less # dump resolved config (useful for debugging)
```

**Never skip `nginx -t`** before reload. An invalid config that reaches
a reload will return an error; a restart with bad config leaves nginx
off. `-t` catches both cases cheaply.

## Trailing-slash discipline

A `location /foo/ { ... }` block only matches `/foo/` and below. Nginx
does NOT automatically redirect `/foo` (no trailing slash) to `/foo/` —
it falls through to the catch-all 404. Users hitting the bare URL (typed,
pasted, shared without the slash) see a broken site.

**Every browsable `location /<name>/` MUST have a companion exact-match
redirect:**

```nginx
# Group these at the top of the server {} block so they're easy to
# audit as a single list. Every new path-served app adds one line.
location = /recipes    { return 301 /recipes/; }
location = /guidebook  { return 301 /guidebook/; }
location = /myapp      { return 301 /myapp/; }

# Then each full block:
location /myapp/ {
    alias /var/www/myapp/;
    try_files $uri $uri/ /myapp/index.html;
}
```

Exceptions: narrow `location = /some-callback { ... }` endpoints and
API-only paths (`/api/`) don't need redirects — API clients pass full
paths and browsers don't hit them directly.

How this fails silently if you forget: `nginx -t` passes, HTTPS serves,
the with-slash URL works fine. Only the bare URL 404s, which nobody
tests because install-script curl probes default to the with-slash
target. Smoke-test with-AND-without slash every time:

```bash
for p in /myapp /otherapp /thirdapp; do
    printf "%-14s no-slash: " "$p"
    curl -sS -o /dev/null -w "%{http_code}  " "https://${HOST}${p}"
    printf "with-slash: "
    curl -sS -o /dev/null -w "%{http_code}\n" "https://${HOST}${p}/"
done
# Expect: no-slash 301, with-slash 200.
```

## Adding a new project vhost

1. Write the vhost in the project repo (e.g. `myproj/ops/nginx/myproj.example.com.conf`).
2. Install into nginx:

```bash
sudo install -m 0644 ./ops/nginx/myproj.example.com.conf \
    /etc/nginx/sites-available/myproj.example.com.conf
sudo ln -sf /etc/nginx/sites-available/myproj.example.com.conf \
    /etc/nginx/sites-enabled/myproj.example.com.conf
sudo nginx -t && sudo systemctl reload nginx
```

3. If it's a new public hostname, either:
   - DNS the host at this server's IP first, THEN
   - `sudo certbot --nginx -d myproj.example.com` — certbot edits the
     vhost in place to add the `listen 443 ssl` block + cert paths.

See the "TLS" section below for the cert flow.

## Minimal vhost template

HTTP-only for initial DNS propagation testing:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name myproj.example.com;

    location / {
        proxy_pass http://127.0.0.1:<BACKEND_PORT>;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_buffering off;
    }
}
```

Path-based routing (one host, multiple backends):

```nginx
server {
    listen 80;
    server_name myproj.example.com;

    # Public download — one narrow path, rewrite-proxy to backend
    location = /client.zip {
        proxy_pass http://127.0.0.1:5000/internal/path/to/client.zip;
    }

    # Admin API — gated by the backend's own auth; HTTPS gives wire protection
    location /admin/ {
        proxy_pass http://127.0.0.1:5000/;
    }

    # Block anything else
    location / {
        return 404;
    }
}
```

## TLS via certbot

```bash
# One-time install
sudo apt-get install -y certbot python3-certbot-nginx

# Issue + install cert for an HTTP-configured vhost
sudo certbot --nginx -d myproj.example.com

# Test renewal (dry-run)
sudo certbot renew --dry-run
```

Certbot installs a systemd timer (`certbot.timer`) that renews certs
twice daily automatically. The timer status is idempotent — safe to
check:

```bash
systemctl list-timers certbot.timer
```

To add a second domain to an existing cert: re-run certbot with the
combined `-d` flags; certbot reissues one multi-SAN cert.

## Updating a certbot-managed vhost (DON'T just `sudo install`)

After certbot has shaped a vhost, **the live file diverges from the
repo source**. The live file at `/etc/nginx/sites-available/<host>.conf`
contains:

- The original repo-tracked HTTP-only `server { listen 80; ... }` block
- Plus a certbot-added `listen 443 ssl;` block with `ssl_certificate
  ... # managed by Certbot` lines
- Plus a certbot-added redirect-to-HTTPS `server { ... }` block at
  the end

The repo source intentionally stays HTTP-only stub (certbot's edits
are owned by certbot, not by us). **Doing `sudo install` of the repo
file over the live config WIPES certbot's edits and takes HTTPS down.**

This is a real failure mode — caught mid-deploy on a real project.
The site stayed up only because the agent backed up the live config
to `/tmp` first and rolled back
when `nginx -t` flagged the missing TLS stanzas.

### The surgical-edit pattern (use this for every certbot vhost change)

```bash
# 1. Snapshot the live config
sudo cp /etc/nginx/sites-available/<host>.conf /tmp/<host>.conf.bak.$(date +%s)

# 2. Edit IN PLACE on the live file. Use sed/python/awk on the
#    specific block you want to change (e.g., the apex `location /`).
#    NEVER overwrite the whole file from the repo source.

# 3. Validate
sudo nginx -t

# 4. If clean, reload. If not, restore from /tmp and investigate.
sudo systemctl reload nginx

# 5. Smoke test the public URL with a curl. Keep the /tmp backup
#    until you've confirmed no regressions, then delete it.
```

### Cleaner pattern: include files

For projects expected to receive frequent vhost updates, structure
the certbot-managed parent file to `include` an app-specific block:

```nginx
# /etc/nginx/sites-available/<host>.conf  — certbot-managed parent
server {
    listen 443 ssl;
    server_name <host>;
    ssl_certificate ... # managed by Certbot
    include /etc/nginx/snippets/<host>.app.conf;  # YOUR routes go here
}
```

Then your repo can ship `ops/nginx/<host>.app.conf`, and `sudo install`
ONTO the include file path is safe — certbot never touches it.

## SSL hardening snippet

Create `/etc/nginx/snippets/ssl-params.conf` once, include from each
vhost after the `listen 443 ssl` line:

```nginx
# In /etc/nginx/snippets/ssl-params.conf:
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;
add_header Strict-Transport-Security "max-age=63072000" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
```

Then in each vhost's 443 block:

```nginx
include snippets/ssl-params.conf;
```

## Removing a project

```bash
sudo rm /etc/nginx/sites-enabled/myproj.example.com.conf
# Optional: also remove from sites-available/
sudo nginx -t && sudo systemctl reload nginx

# Revoke the cert
sudo certbot delete --cert-name myproj.example.com
```

## Troubleshooting

| Symptom | Check |
|---|---|
| `nginx -t` says "host not found in upstream" | backend service down, or DNS lookup in a `proxy_pass http://name` instead of an IP |
| 502 Bad Gateway | backend isn't listening on the expected port; check `ss -tlnp` |
| 413 Request Entity Too Large | add `client_max_body_size 100M;` (or as needed) in the vhost `server` block |
| Certbot fails on "Could not connect" | DNS not propagated yet, or ufw blocking 80/443 |
| Config change doesn't take effect | missed a `reload`, or the vhost isn't symlinked into `sites-enabled/` |
| Site intermittently 404s | competing `server_name` in another vhost; `nginx -T \| grep server_name` to find dupes |

## Don't

- Don't edit files directly under `/etc/nginx/sites-available/` if a
  repo owns them — changes will be lost on the next deploy.
- Don't enable a vhost before its DNS has propagated; certbot will fail.
- Don't run `systemctl restart nginx` as a "fix it" reflex; use `-t`
  + `reload` instead. A bad config + restart takes the whole edge down.
- Don't commit the default SSL private key or issued certs to any repo.
  They live at `/etc/letsencrypt/` and stay there.
- Don't `sudo install` a repo vhost file over a certbot-managed live
  config — it wipes certbot's TLS stanzas and takes HTTPS down. Use
  the surgical-edit pattern (or the include-file pattern) from
  "Updating a certbot-managed vhost" above.
- Don't manually edit `listen 443 ssl` vhost blocks after certbot has
  shaped them — certbot tracks ownership via comments and will rewrite.
  If you need custom 443 config, structure it via `include` or
  add-on `location` blocks.

## Adopting this skill in a project

Each project that uses nginx should:
1. Keep its vhost config in `ops/nginx/<host>.conf`.
2. Add a deploy script (or at least documentation) that installs the
   vhost into `/etc/nginx/sites-available/` and symlinks into
   `/etc/nginx/sites-enabled/`.
3. Cross-link to this skill from the project's own docs rather than
   duplicating nginx knowledge.

The host is authoritative for live config — the repo is authoritative
for the template. Keep them aligned by having a deploy step that
installs the repo's copy over the host's copy.
