# Gateway attribution, epoch 3 — the TAP NAMES moved; nothing else did

**Landed 2026-08-09** · bead `dotfiles-kecb` (Zig's naming ruling ~19:1xZ, recorded
on `dotfiles-rbci`) · implementation `agents/lib/claude-identity-wrapper.sh`,
guarded by `agents/lib/test-claude-identity-wrapper.sh` (T15, T15z, T19) and
`agents/lib/mutate-tap-failover.sh`.

Epoch 2 (`refs/probes/gateway-attribution-epoch2.md`) is the scheme; this note is
**only the value rename plus the two headers that were added beside it**. Header
names, the newline separator, the CEL mapping and the `?` NOT-DERIVED convention
are all unchanged.

## The rename

| epoch-2 `group` | epoch-3 `group` | config dir | account |
|---|---|---|---|
| `personal` | **`primary`** | `~/.claude` | andrewzigler@gmail.com |
| `personal` (profile `tick`) | **`primary`** | `~/.claude-tick` | andrewzigler@gmail.com — a jailed GRANT of the same account, not a tap |
| — (new) | **`secondary`** | `~/.claude-secondary` | zig@zigler.ai — the second Max 20x, provisioned 19:21Z |
| `work` | **`linearb`** | `~/.claude-work` | andrew.zigler@linearb.io |

`~/.claude-work → linearb` is the one arm that is **not** derivable by the
`~/.claude-<tap>` convention: the DIRECTORY name did not move, only the tap name
did. It is an explicit `case` arm in `_ciw_tap` and an explicit case in the
suite, because getting it wrong is silent — `work` is a perfectly plausible tap
name and the rollup would simply carry two names for one account forever.

Two headers are ADDED, and only on a rollover (see below): `X-Home-Tap` and
`X-Tap-Rollover: 1`. Neither is read by pico's CEL today; they are in the request
so that the eventual gateway-side capture is a config-only change, exactly as
`X-Seat-Address` / `X-Tap` were in epoch 2.

## ⚠️ CLASSIFY BY VALUE, NEVER BY DATE — both epochs stay queryable

The cutover is **rolling**, not instantaneous: the wrapper is sourced at shell
start and the fleet's durable tmux panes hold zsh processes that are days old
(the always-loaded-snapshot problem, `explore-6wwu`). A pane started before this
change keeps emitting `personal` until it is replaced. So on any given day the
table holds both epochs at once, and **nothing is ever rewritten** — epoch-1 rows
(`group` = a hostname) and epoch-2 rows (`group` = `personal`/`work`) stay exactly
as logged.

The mapping is DATA, not prose, so the queries and the failover machinery read
one copy of it — `pool.<p>.groups` in `agents/scheduler/taps.conf`:

```
primary   <- agentgateway_group IN ('primary','personal')
secondary <- agentgateway_group  = 'secondary'
linearb   <- agentgateway_group IN ('linearb','work')
```

Hostnames and tap names remain disjoint namespaces, so `group IN
('primary','secondary','linearb','personal','work')` is still an exact
"epoch 2 or 3" test, and anything else in that column is epoch 1 or `unknown`.

Live census at the time of writing (`ssh pico`, 6-hour window):

```
personal|1579|2026-08-09T19:26:45Z      <- epoch 2, days-old panes
zig-computer|959|2026-08-09T19:29:02Z   <- epoch 1, header-less clients
secondary|1|2026-08-09T19:22:04Z        <- the new tap's first attributed request
unknown|2|2026-08-09T16:51:14Z
```

## ⚠️ The query traps have NOT changed — and there is a third

The two from `infra.md` still apply and are re-verified here: the table is
**`request_logs`**, the time column is **`started_at`**, and it is ISO8601 with a
`T`, so a bare string comparison against `datetime('now',…)` matches **every row
with today's date** (2903 rows vs 18, measured). Always `datetime(started_at)`.

**The third, found 2026-08-09 and new here.** `json_extract(attributes_json,
'$."anthropic.ratelimit.5h"') IS NOT NULL` is **not enough**: the gateway's
`default()`-guarded CEL writes the **EMPTY STRING** when Anthropic sends no
ratelimit header, and `''` is not `NULL`. Measured on the `secondary` tap's one
logged request:

```json
{"g":"secondary","started_at":"2026-08-09T19:22:04.639244+00:00","u5h":"","u7d":""}
```

An empty string compares as **0** in awk, so a headroom reader that lets those
rows through reports a brand-new account as 0% used and a stalled one as wide
open. Every utilization query must carry `<> ''` beside its `IS NOT NULL`;
`agents/lib/tap-headroom.sh` does, and `test-tap-headroom.sh` G10b reads the SQL
out of the stub's own argv to prove it.

## The Fable dimension is NOT in the gateway — it is in the account's own usage document

The gateway captures `anthropic.ratelimit.5h` and `anthropic.ratelimit.7d` and
**nothing else** (`dotfiles-7qi7`, live 16:23Z). There is no model dimension in
`attributes_json` at all, so the model-scoped weekly allotment Zig watches — he
was at 78% on the evening of 2026-08-09 — is **unobservable from the request log
by construction**, not merely absent from it.

It was found empirically, 2026-08-09, at:

```
GET https://api.anthropic.com/api/oauth/usage
  Authorization: Bearer <claudeAiOauth.accessToken from <config-dir>/.credentials.json>
  anthropic-beta: oauth-2025-04-20
  anthropic-version: 2023-06-01
```

Real captured responses live in `agents/lib/tap-headroom-fixtures/` and are what
the suite parses. The shape that matters is the `limits[]` array:

```json
{"kind":"session",       "group":"session","percent":72,"resets_at":"2026-08-09T21:20:00Z"}
{"kind":"weekly_all",    "group":"weekly", "percent":75,"resets_at":"2026-08-14T06:00:00Z"}
{"kind":"weekly_scoped", "group":"weekly", "percent":81,"resets_at":"2026-08-14T05:59:59Z",
 "scope":{"model":{"id":null,"display_name":"Fable"}},"is_active":true}
```

Notes that cost something to learn:

* **Percentages are 0-100 here and 0-1 in `attributes_json`.** `72` and `0.72`
  are the same window. `tap-headroom.sh` normalises to 0-1 at the boundary.
* The nearby sibling endpoint `/api/oauth/profile` answers the ACCOUNT identity
  (`email`, `rate_limit_tier`, `organization.name`) — useful for proving which
  account a config dir actually holds without launching anything. `/v1/usage`,
  `/api/usage` and `/api/oauth/claude_cli/usage` all 404; don't go looking.
* **A 401 here is an EXPIRED ACCESS TOKEN, not "no usage".** Measured on
  `~/.claude-work`, whose `expiresAt` was ~12h in the past:
  `{"type":"error","error":{"type":"authentication_error"}}`. A reader that scores
  a failed read as 0% declares an account it cannot even authenticate to wide
  open. `tap-headroom.sh` checks `expiresAt` locally and refuses BEFORE spending
  a request; the suite asserts the request was never made.
* Do **not** try to read the ceiling by POSTing to `/v1/messages` with a raw
  curl: it is client-shape 429'd with no ratelimit headers. Measured; don't
  re-spend the time.

## The env-bypass defect, and where it is closed

**Measured 19:23Z, 2026-08-09.** `env -u CC_NO_GATEWAY CLAUDE_CONFIG_DIR=~/.claude-secondary claude -p …`
run from inside a Claude Code session BILLED to `secondary` while the logged
attribution said `personal`. Two facts compose into it:

1. `claude` is a shell FUNCTION, and `env` runs the BINARY — a function is not
   inherited by `env`, so the wrapper never executes. (Already documented as a
   wrong idiom in `~/.zig-computer.zshenv`'s `lb-claude` note, for a different
   reason.)
2. **Claude Code EXPORTS `ANTHROPIC_CUSTOM_HEADERS` to its own children**, so
   every Bash-tool shell inside a session starts life carrying its parent's
   `X-Tap`. Verify in any session: `printenv ANTHROPIC_CUSTOM_HEADERS`.

So the bypassed launch sends the PARENT's header block and is attributed to the
parent's tap while spending the other account's quota. Closed in two places:

* **`agents/lib/claude-identity-wrapper.sh`** — the launch branches that send NO
  header now `env -u ANTHROPIC_CUSTOM_HEADERS` rather than letting an inherited
  one through (the same argument as the `ANTHROPIC_BASE_URL` 2u/4u cases of
  `dotfiles-20rx`). Cases 3s/4s/4us; T25/T25b/T25c.
* **`zsh/.zshenv`** — a wrapper-shaped inherited block is DROPPED in every zsh,
  including the non-interactive Bash-tool shell where the poison lives. A
  bypassed launch then sends nothing and logs as `unknown`: **visibly
  unattributed, which is recoverable, instead of confidently wrong, which is
  not.** T26 executes the committed block by line-range extraction.

**Still open, deliberately:** a raw-binary launch from a shell that never sourced
either file (a foreign script, a cron entry, another machine) still sends no
header and lands in `unknown`. That is the correct failure — an absent claim, not
a false one — and a mechanical refusal of the `env … claude` idiom is filed as
its own bead rather than smuggled in here.

## The rollover, and how to find one

`agents/scheduler/taps.conf` holds the pools, the ruled order (`primary >
secondary > linearb`), the per-seat home-tap overrides and the ceiling. A launch
whose home POOL is measurably at its ceiling runs on the first candidate behind
it that has measured headroom — **ceiling only**, never proactively, and never on
data that could not be read.

Every rollover leaves four marks, and each is independently sufficient:

```sql
-- 1. the request itself carries the tap that RAN
SELECT agentgateway_group, count(*) FROM request_logs
 WHERE datetime(started_at) > datetime('now','-1 day') GROUP BY 1;
```

2. `X-Home-Tap` + `X-Tap-Rollover: 1` ride along in the request (not captured by
   pico's CEL yet — see above);
3. one line on stderr in the pane, naming both taps and the ledger path;
4. a JSONL row in `~/.local/share/fleet-health/tap-rollover.jsonl`:

```json
{"ts":"2026-08-09T19:40:00Z","event":"tap_rollover","home_tap":"primary",
 "used_tap":"secondary","pool":"secondary","seat_address":"zig-computer:dive"}
```

## Carry note for `~/.agents/infra.md`

This repo does not write the demesne. The §"Request attribution" table there
still says *"`<tap>` — personal/work/tick"*; the exact replacement text is in this
bead's handoff and should be carried by whoever owns that file next.

## What did NOT move, and why

`agents/seats.yml` still carries the **epoch-2** tap names in its `taps:` block
and in every seat's `tap:` value. Several consumers read those strings —
`marshal.conf`'s tap filter and `pulse-inject.sh`'s seat pinning among them — and
both files were owned by other lanes on the day this landed. The roster rename is
therefore sequenced separately. Until it happens, the mapping lives in exactly one
place in this repo's tests: `epoch3_of()` in
`agents/lib/test-claude-identity-wrapper.sh`, which is deliberately an EXPLICIT
map rather than a pass-through — the whole value of T19 is that it fails when the
roster gains a tap the wrapper derives differently, and a pass-through would agree
with the wrapper by construction.
