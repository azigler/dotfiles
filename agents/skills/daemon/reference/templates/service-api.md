# <Service> API — Reference

Distilled from <docs URL / OpenAPI>. **Verified live <date>:** <what you
confirmed with a real call — account, tier, data exists>.

## Auth & base
- Base URL, auth header/scheme, key source, where ours lives (`~/.secrets` as
  `<KEY>`). Rate limits (or "not documented" — be conservative). Tier required?
- **Units** — note canonical units (SI?) and convert at presentation.

## Endpoints (the surface that matters)
| Method+Path | Notes |
|---|---|
| `GET /…/{id}` | the hydration call |
| `GET /…/events?since=` | incremental sync — the only source of edits/deletes |
| … | … |

## The event/webhook contract (often NOT in the formal spec)
- **Configure:** <API call and/or dashboard field>.
- **Trigger:** <what fires it>.
- **Payload** (thin id-only, or full?): 
  ```json
  { "id": "<event-id>", "payload": { "<thingId>": "…" } }
  ```
  → hydrate via `GET /…/{thingId}` if thin. Code defensively for shape variants.
- **Delivery contract:** ack <HTTP 200 within Ns> or it **resends** ⇒ ack fast,
  process async.
- **Verification:** <HMAC? or an echoed auth header/token you set?>.

## Data model (what the agent reasons over)
<The core object + nested children + the enum fields that change interpretation.>

## Build implications
- Real-time path: webhook → ack fast → hydrate → upsert.
- Reconciliation path: `events?since=<cursor>` on a timer (edits/deletes/backfill).
- **Don't guess** undocumented behavior (rate limits, retry semantics) — say so.
