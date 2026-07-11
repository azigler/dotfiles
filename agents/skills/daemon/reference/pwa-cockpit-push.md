# Optional arc — a PWA cockpit with cross-platform Web Push + badges

A daemon that already serves an HTTP surface can grow a **installable web-app
cockpit** with **real push notifications and app-icon badges on every platform**
(iPhone Home Screen, macOS Safari, desktop Chrome/Edge/Firefox — tab AND installed
PWA) that **auto-updates on use** with no app-store, no native build, and no manual
cache-busting. This is a critical part of the daemon pattern: the thin service can
*reach* the human, not just wait to be visited.

Worked example: **harnessd** (`github.com/azigler/harnessd`) — the whole arc shipped
+ on-device-validated 2026-07-11. Read `internal/push/`, `dashboard/sw.js`,
`dashboard/app.mjs`, and the `harnessd-lry*` / `bxz` / `jje` / `2fc` / `xwl` / `3zf`
/ `8l3` beads for the blow-by-blow.

**The single most expensive lesson, up front:** on iOS, use a **CLASSIC** Web Push
payload, not the "Declarative Web Push" format — the declarative `app_badge` does
NOT set the Home Screen badge on iOS 18.7 (even with `mutable:true`), because iOS
doesn't reliably fire the service worker for it. A classic push ALWAYS fires the
SW, so `navigator.setAppBadge()` runs and the badge appears. Everything else below
is prerequisites and gotchas around that.

---

## The stack (what to build)

- **TLS is mandatory.** Service Workers + the Push API require a secure context —
  everywhere, including static assets (even an HTTP→HTTPS redirect can break SW
  registration). On a tailnet box: `tailscale cert <host>.ts.net` → a real
  Let's-Encrypt cert. Run **dual listeners** (plain HTTP for same-tailnet
  convenience + HTTPS for the PWA) and **install a cert-renewal timer** (the
  `.ts.net` cert is ~90 days). If you add a CSRF `Origin` allowlist, it MUST
  include the **https** origin or the client's authed POSTs 403.
- **VAPID keypair** (RFC 8292) for signing pushes. Secrets-by-pointer: the daemon
  reads the private key from an env-var *name* (`EnvironmentFile=` a 0600
  `secrets.env`), NEVER a literal in git/memory. Serve the public key at an
  endpoint; the client passes it as `applicationServerKey` at subscribe time.
- **A subscription store** (a JSON file is plenty — small N, single writer, atomic
  rewrite). Upsert by endpoint. It holds the endpoint + the browser's public
  encryption keys (`p256dh`/`auth`) + a UA string (to name the device) — never the
  VAPID private key.
- **`webpush-go`** (or any RFC-8291/8292 lib) for the send. It is **browser-
  agnostic**: it POSTs to whatever push service the subscription names (Apple
  `web.push.apple.com`, Google `fcm.googleapis.com`, Mozilla). The SAME VAPID
  keypair works for all of them — **no server change to support a new browser.**
- **A service worker** (`sw.js`) + a small **client** (`app.mjs`) + a
  **manifest** (`display: standalone` — required, or `pushManager` is absent on
  iOS and badges don't work) + icons.

## The payload — CLASSIC, not declarative

Send this exact shape (proven on-device to badge iOS + desktop):

```json
{"title": "...", "body": "...", "url": "https://.../", "badge": 3}
```

- `badge` is a **JSON number**. (The declarative format wanted `app_badge` as a
  *string*; the classic `badge` is a number the SW coerces via `Number()`.)
- `badge: 0` **clears** the badge (meaningful — always emit it).
- Require a non-empty `title` (the notification needs one) and `url` (tap target).
- Enforce the RFC-8030 4096-octet body ceiling (Apple 413s an over-limit body).

Do **NOT** use `{"web_push":8030, "notification":{...,"app_badge":"1"}, "mutable":true}`
(Declarative Web Push). It renders notifications fine but the **badge silently
never applies on iOS 18.7** — the declarative-native path didn't set it, and
`mutable:true` (which should route to the SW) didn't reliably fire the SW either.
This cost multiple deploy cycles to discover; the classic payload just works.

## The service worker (`sw.js`)

- **`push` handler MUST call `showNotification()` on every push**, or iOS treats
  it as a silent push and **revokes the subscription** after ~3 offenses. A badge
  update alone does NOT satisfy the "user-visible" promise.
- Set the badge in the same handler, feature-detected, coerced, inside
  `event.waitUntil(Promise.all([...]))`:
  ```js
  const raw = data.badge ?? data.app_badge;          // accept number or legacy string
  const n = raw == null ? null : Number(raw);
  const badge = Number.isFinite(n) ? n : null;
  const tasks = [ self.registration.showNotification(title, { body, data:{url}, tag:'app', renotify:true }) ];
  if (badge !== null && 'setAppBadge' in self.navigator) tasks.push(self.navigator.setAppBadge(badge).catch(()=>{}));
  event.waitUntil(Promise.all(tasks));
  ```
- **`renotify: true`** (with a stable `tag`): a fixed tag coalesces alerts into ONE
  notification slot (good — no 30-deep stack), but Chrome *replaces a same-tag
  notification silently* (no new banner) until the old one is dismissed. `renotify`
  forces a re-alert each time. Safari re-alerts regardless.
- **Network-first self-update.** Serve the shell (`index.html`/`*.mjs`/`*.css`/
  manifest/icons) **network-first** (cache = offline fallback only) + `skipWaiting()`
  + `clients.claim()`, and have the page reload once on `controllerchange` with a
  small "new version — refreshing…" toast. Result: a daemon redeploy propagates on
  the next load with **no `CACHE_NAME` bump**. **NEVER cache the live data
  endpoint** (`state.json` etc.) — network-only, or you show stale state.

## Badges — the rules that bite

- Badges appear **only on an INSTALLED PWA** (Home Screen / dock), never a plain
  browser tab (a tab has no icon to badge). This is not a bug.
- The badge shows only with **notification permission granted** (iOS ties badging
  to notifications) AND the OS-level **Badges** toggle on (iOS Settings →
  Notifications → <app> → **Badges** is a *separate* switch from "Allow
  Notifications" — you can have notifications on and badges off).
- `setAppBadge` works in the **service-worker** context (WorkerNavigator) since iOS
  16.4 / desktop Chrome — same-origin only.
- **Clear-on-focus is by design.** The badge means "unread attention," so clear it
  on `load` + `focus` + `visibilitychange`(visible). Consequence when *testing*:
  the badge only stays visible while the app is **backgrounded/closed**; opening it
  wipes the badge instantly. A "why doesn't the badge show?" report is almost always
  the tester looking at a focused window.
- For a **test** push, floor the badge to `Math.max(1, realCount)` — the real
  attention count is often 0, which *clears* the badge, so a test would show nothing.

## The opt-in + test UX (client)

- **Platform-aware install gate.** iOS grants the push APIs ONLY to a Home-Screen
  install (require `display-mode: standalone`); desktop works in a plain tab.
  Detect iOS robustly: `/iP(ad|hone|od)/.test(ua) || (navigator.platform==='MacIntel'
  && navigator.maxTouchPoints>1)` (iPadOS 13+ reports as MacIntel). Gate the coach
  copy on it — never nag a desktop user to "Add to Home Screen."
- **Test button → target the LIVE subscription endpoint**, not a cached
  `localStorage` value (which is empty on Chrome-after-refresh → the test silently
  matches zero devices and lies "Sent"). Offer BOTH "test this device" and "test all
  devices" (the broadcast path a real alert uses).
- **Foreground-swallow delay is UNIVERSAL.** A *focused* window suppresses the
  banner on desktop too (not just iOS). Route the test send through a **server-side
  delay** (a detached goroutine that fires even if the user *closes* the window, not
  just unfocuses) + a countdown ("unfocus or close this window — arriving in Ns").

## Subscription lifecycle (send path)

Map each push-service HTTP status to an action: **201** → delivered; **404/410** →
the device is gone, `Delete` from the store (prune); **403** → a VAPID/JWT problem
but the device is LIVE — **keep + log, NEVER prune** (prune-on-403 silently drops
working phones); **429** → back off, keep. A *fresh* subscription can 410 once if it
went stale from re-subscribe/SW churn — re-subscribing yields a valid one.

`webpush-go` gotcha: it **prepends `mailto:`** to a non-https VAPID subscriber, so
pass the **bare email** (`andrewzigler@gmail.com`), not `mailto:...`, or you get
`mailto:mailto:...` → Apple 403 `BadJwtToken`.

## Deploy discipline

If the daemon `go:embed`s the `dashboard/` dir, **any Go OR dashboard change needs a
rebuild + restart** (`make deploy`) — a stale binary serves stale JS. Stamp the
binary with a `code_sha` (git HEAD) and a drift check (`live code_sha == HEAD`) so a
forgotten deploy is caught. Note: untracked files under the sha's watched paths make
the build `-dirty` — clean throwaway tools before the final deploy. After a deploy,
the daemon restart briefly drops connections; a client reloading at that instant can
fail its shell fetch and land on a white screen — a clean reload (or, for a stuck
PWA, remove + re-add the Home-Screen icon) recovers it.

## Debugging: split DELIVERY from DISPLAY first

The highest-leverage tool is a **controlled one-shot push** that sends to ONE device
(filter by endpoint host / UA) and prints the push service's **raw status + body** —
build it early (harnessd's throwaway `cmd/push-diag`). It instantly separates:

- **Not delivered** (`Pruned`/`Failed`, a 4xx from the service) → subscription /
  VAPID / payload problem (server side).
- **Delivered (201) but nothing shows** → a *display* problem: the SW isn't showing
  (check `showNotification` fires), the OS notification setting is off, or (badge
  only) the classic-vs-declarative issue, the Badges toggle, or clear-on-focus.

Watch the daemon log for the send tally (`{Sent, Pruned, Failed}`). And know that
`{Sent:1}` per press means the test targets one device (the caller), not a broadcast.

---

**Net:** the arc is ~1 push package + a SW + a small client on top of a daemon that
already serves HTTP. The traps are all above; the load-bearing one is **classic, not
declarative, payload**. Once it's in, the daemon has a real, self-updating,
cross-platform attention channel to the human — the thing that turns a dashboard into
a cockpit.
