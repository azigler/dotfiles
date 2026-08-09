# Gateway attribution, epoch 2 — `user` = seat address, `group` = tap

**Landed 2026-08-09** · bead `dotfiles-jbnp` · implementation
`agents/lib/claude-identity-wrapper.sh`, guarded by
`agents/lib/test-claude-identity-wrapper.sh` (T15–T19).

## The scheme

| header (emitted by the wrapper) | pico CEL → column | epoch-2 value |
|---|---|---|
| `X-Session-Identity` | `user` → `agentgateway_user` | `<host>:<seat>` |
| `X-Machine-Origin` | `group` → `agentgateway_group` | `<tap>` |
| `X-Seat-Address` | *(nothing yet)* | `<host>:<seat>` |
| `X-Tap` | *(nothing yet)* | `<tap>` |

Address grammar — `?` is the NOT-DERIVED marker and cannot occur in a seat name,
a hostname or a tap name (every field goes through the same
`tr -cd '[:alnum:]._-'` sanitizer, which drops it):

```
zig-computer:dotfiles     the window resolved to a registered seat, or its alias
zig-computer:?zsh         the window is NOT a registered seat, or the resolver
                          is unavailable — explicit, never silently seat-shaped
zig-computer:?            no window could be resolved at all (jail, cron, daemon)
?:dotfiles                `hostname -s` failed
<no header>               nothing at all was derivable — fail open, as before
```

so **`agentgateway_user LIKE '%?%'` IS the unattributed bucket**, by construction
rather than by convention. The same marker appears in the tap (`?nonsense`) when
`CLAUDE_CONFIG_DIR` does not follow the `~/.claude-<tap>` convention.

## Why these two dimensions

### `user` = the seat address, DERIVED

Epoch 1's `user` was raw tmux `<session>:<window>`. Zig abolished the second
session on 2026-08-09 — one tmux session per server, named after the host — so
`session:window` now **equals** `host:seat` for every registered seat. The
elegant part is that this makes the change nearly value-invisible; the important
part is that **an equality produced by a naming ruling is a coincidence, not an
identity**. The raw string is right only while every durable window happens to
be named exactly after its seat. It is wrong, seat-*shaped*, and undetectable for:

* a window that was renamed (the `di->pulse` failure, `bd-msi5`, which seat
  aliases exist to survive) — raw tmux says `di-monday`, the seat is `linearb`;
* a window that was never given a seat at all — raw tmux says `zsh`, and
  `zig-computer:zsh` reads exactly like a seat in every group-by. 676 such rows
  are the largest single slice of `dotfiles-jbnp`'s 1216-row unknown bucket.

Epoch 2 resolves through `seat_resolve` (`agents/lib/seat-resolve.sh`, uikg
R5/R13) and marks every failure. The change is **making the address derived
rather than coincidental, and making failure explicit** — not changing what a
correctly-seated window reports.

Rejected alternative — `tap:host:seat` as a single `user` value. It puts the tap
in both columns, so the billing rollup could be read two ways that can silently
disagree (the two-copies defect), and it makes `user` a 3-field string that every
consumer must parse. Two orthogonal columns, one fact each.

### `group` = the tap, DERIVED FROM WHAT ACTUALLY RUNS

`group` was `hostname -s`. The host now lives in field 1 of `user`, so the
machine dimension is not lost — it moves. That frees `group` for the **tap**
(`personal` / `work` / `tick` / …), which turns per-tap spend and headroom
(harnessd `aj08` / `b1v6` / `4icj`, the hall's tap column) from a text-parse into
`GROUP BY agentgateway_group`.

The tap is read from **`CLAUDE_CONFIG_DIR` in the launching process's own
environment** — the same variable `pulse-inject` exports into the pane, that
`tick-jailed.sh` sets through bwrap, and that `assert_seat` reads back out of
`/proc`. Unset means the vendor default `~/.claude`, i.e. `personal`.

It is **never read from the roster**. The roster says what a seat is *supposed*
to bill to; `group` must say what it *is* billing to, and the whole reason
`pulse-inject`'s `assert_seat` exists is that those two come apart. The roster
supplies only the naming convention (`~/.claude-<tap>`), and that convention is
asserted at test time instead of trusted at launch time: **T19 feeds every
`taps:` row of the live `agents/seats.yml` through the wrapper and requires each
to derive to its own name.** Derive → assert, with no roster parse on the launch
path.

### Why the header NAMES still lie (and the two extra headers)

`X-Machine-Origin` now carries a tap. That misnomer is deliberate and temporary:
pico's `config.standardAttributes` CEL reads those two names, this change is
**wrapper-only by requirement**, and a rename cannot be atomic across a fleet
whose tmux panes hold shells that are days old. So the wrapper emits the same
two values a second time under honest names (`X-Seat-Address`, `X-Tap`). The
gateway-side rename then becomes **config-only**: flip the CEL to the canonical
names, let the shells cycle, drop the legacy pair. Nothing reads the canonical
pair today; they cost ~60 bytes per request and buy a migration that is otherwise
impossible to sequence.

## The epoch seam — and why the boundary is NOT a date

**History is never rewritten.** Epoch-1 rows stay exactly as logged.

| | `agentgateway_group` | `agentgateway_user` |
|---|---|---|
| epoch 1 | `<host>` (`zig-computer`), or `unknown` / `''` when the client sent no header | `<tmux session>:<window>` — incl. the `work:*` split of `dotfiles-fo5l` |
| epoch 2 | `<tap>` (`personal`/`work`/`tick`/`?x`) | `<host>:<seat>` / `<host>:?<window>` |

⚠️ **The cutover is ROLLING, not instantaneous.** The wrapper is sourced at
*shell start* and read at *claude launch*, and the harness's durable panes hold
zsh processes that are days old (the same shell-age trap that blinded pico's
request log on 2026-07-28 and that `gateway-switch.sh` step 3 exists for). A pane
emits epoch-1 values until its shell is replaced. So a query that splits the
epochs **by timestamp alone will mis-bucket every long-lived pane** for as long
as it survives.

Split by **value shape**, which is exact — the hostname and tap namespaces are
disjoint, and nothing plans to name a host `personal`:

```sql
-- epoch of each row, from the row itself. Cross-check against the date; do not
-- key on the date.
SELECT CASE WHEN agentgateway_group IN ('personal','work','tick') THEN 'epoch2'
            ELSE 'epoch1' END AS epoch,
       count(*), min(datetime(completed_at)), max(datetime(completed_at))
FROM request_logs GROUP BY 1;
```

Unioning the two epochs on the *seat* dimension (the `dotfiles-fo5l` question,
now with a third form to carry — cite that bead, this doc does not restate it):

```sql
-- every row for the linearb seat, across both epochs and the one-session split
SELECT datetime(completed_at), agentgateway_group, agentgateway_user, total_tokens
FROM request_logs
WHERE agentgateway_user =    'zig-computer:linearb'   -- epoch 2
   OR agentgateway_user LIKE 'work:di-%'              -- epoch 1, pre-ruling
   OR agentgateway_user =    'work:weekly-report'     -- epoch 1, pre-ruling
ORDER BY 1 DESC LIMIT 5;
```

⚠️ Always wrap the time column in `datetime()` — `started_at`/`completed_at` are
ISO8601 with a `T`, and a bare string compare silently matches every row with
today's date (`dotfiles-9o46`; 2903 rows vs 18, measured).

## Blast radius, enumerated

| consumer | keys on `group`? | disposition |
|---|---|---|
| pico `config.standardAttributes` | reads the two header NAMES, not their values | **no change needed** — verified by reading the live config: `user`/`group` are the only CEL uses of these headers, and no `frontendPolicies`, route, `mcpAuthorization` rule or backend policy references `group` at all. Routing cannot break. |
| harnessd `internal/agentgateway/analytics.go` | **no** — it sums pico's `groups` roll-up into one Totals line and drops the per-bucket `group` object | no break; per-tap grouping becomes available for free when the tab wants it |
| `agents/scheduler/gateway-switch.sh` | no attribution logic at all | unaffected. Its `work:di-monday.0` fixtures are **tmux pane labels** (`session:window.pane`), not requests.db rows — a distinct namespace that this change does not touch. Left alone deliberately. |
| `agents/lib/test-claude-identity-wrapper.sh` | asserts the emitted bytes | **updated** — every expectation moved (that IS the change), plus T15–T19 for the epoch-2 guards |
| `agents/infra.md` "Request attribution" | documents `user`=session, `group`=machine | **updated** with the epoch table |
| `~/aaif/refs/gateway-request-log-cookbook.md` | describes the columns; its group-bys are shape-agnostic | **out of repo — bead proposed**, not edited here |
| `metis`'s stale wrapper | sends epoch-1 `session:window`, no machine header | benign: metis contributes 0 of 112k rows. Its rows would classify as epoch 1 by the value rule, correctly. |
| non-claude clients (harnessd's Go client, romd) | send neither header → `group='unknown'` | unchanged by this diff; that is the rest of `dotfiles-jbnp`. Epoch 2 improves the diagnosis: `unknown` now means "not a tap-attributed client" rather than "wrapper predates the machine header". |

## Live proof (2026-08-09, zero tokens)

`GET /claude/v1/models` is **not logged any more** (last logged 401: 2026-08-01),
so it proves nothing about the columns. The LLM route *is* logged, and a POST to
it with **no credential at all** is rejected 401 by Anthropic *before* inference:
a real logged row, no tokens, no pool, no billing. The headers replayed were the
exact bytes the real wrapper exported in a live pane (a fake `claude` on PATH
printed `ANTHROPIC_CUSTOM_HEADERS`; `od -c` confirmed the newline separator).

```
requests.db, read back over ssh (sqlite3 -readonly, datetime()):
2026-08-09 04:42:15|401|work    |zig-computer:linearb |epoch2-proof-work
2026-08-09 04:41:49|401|personal|zig-computer:dotfiles|epoch2-proof
```

Two points, so `group` is shown to **track** the tap rather than be constant. The
second row is the seam in one line: window `di-monday` with
`CLAUDE_CONFIG_DIR=~/.claude-work` — epoch 1 logged that as
`group=zig-computer user=work:di-monday`; epoch 2 logs
`group=work user=zig-computer:linearb`. The two columns did not merely change
values, they **exchanged which fact they carry**, and the seat name is one the
raw tmux window never contained.

Seam this does NOT cover: the `claude` binary's own forwarding of
`ANTHROPIC_CUSTOM_HEADERS` onto the wire. That half is unchanged by this diff and
is already evidenced by 112k epoch-1 rows.

## The codex mapping (`dotfiles-d3ky`)

A codex tap has no wrapper process — the probe found `model_providers.<id>` with
`env_http_headers`, an env-var → header map applied at request time. The scheme
is expressible there **unchanged**, because it is two values and four header
names:

```toml
[model_providers.gateway]
name     = "claude-via-agentgateway"
base_url = "<the gateway URL for this tap>"      # per d3ky's probe cell
env_http_headers = { "X-Session-Identity" = "AGW_SEAT_ADDRESS",
                     "X-Machine-Origin"   = "AGW_TAP",
                     "X-Seat-Address"     = "AGW_SEAT_ADDRESS",
                     "X-Tap"              = "AGW_TAP" }
```

with `AGW_SEAT_ADDRESS` / `AGW_TAP` exported by the launcher. **The structural
difference to hold on to:** for a claude tap the derivation happens *in process*
at launch (the wrapper resolves the seat and reads its own `CLAUDE_CONFIG_DIR`);
for a codex tap it must happen in **the launcher** (`pulse-inject`'s codex
strategy) and be handed over as environment. Two implementations of one contract
— exactly d3ky's strategy-dispatch shape — and the derivation rule must stay the
same one: the tap comes from the config dir the process actually runs on
(`CODEX_HOME` for codex), never from the roster row that requested it.

Note `d3ky` records `type: codex` config_dir as `CODEX_HOME` — a codex tap's
directory will **not** be `~/.claude-<tap>`, so `_ciw_tap`'s claude-only
convention does not extend to it. That is why T19's assertion is written against
the roster: the day a codex tap lands, T19 goes red and forces the per-type
derivation rather than silently deriving `?codex` for it.
