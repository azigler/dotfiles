---
description: Session exit -- summarize state, write handoff note, commit. Paired with /onboard.
when_to_use: Session end, before context compaction, or any natural handoff point. Orchestrator-only (skip inside worktrees). Paired with /onboard, which retroactively honors .offboard-pending.
---

# /offboard

Run at session end, before context compaction, or at any natural handoff
point. Captures the session's state in a durable form so the next
session (or another person) can pick up cleanly.

Paired with `/onboard` (run at session start).

## When to run

- **Natural end-of-session** — before closing the terminal
- **Before context auto-compaction** — compaction can lose the thread;
  capture state in a handoff note before it happens
- **When handing off to another person** — the handoff note summarizes
  state for the new owner

## Step 1: Verify you're not inside a worktree

Offboard is for orchestrator sessions, not subagents. Check:

```bash
branch=$(git branch --show-current)
case "$branch" in
  worktree-agent-*)
    echo "You're inside a subagent worktree — offboard is orchestrator-only. Skip."
    exit 0
    ;;
esac
```

## Step 2: Identify the session ID

Find the live session JSONL — its id stamps the handoff note title and the
`.claude/last-offboard-session` marker (Step 4):

```bash
PROJECT_SLUG=$(pwd | sed 's|/|-|g')                 # e.g. -home-ubuntu-myproj
SESSION_JSONL=$(ls -t "$HOME/.claude/projects/${PROJECT_SLUG}/"*.jsonl 2>/dev/null | head -1)
SESSION_ID=$(basename "$SESSION_JSONL" .jsonl 2>/dev/null)
echo "Session: ${SESSION_ID:-(none found)}"
```

If no JSONL is found, use the date alone in the handoff title; the marker
step just skips.

## Step 2.5: Harvest this-session decision records

Autonomous "decide-and-proceed" calls are logged as `-t decision` beads
during the session (see AGENTS.md "when you decide-and-proceed, leave a
durable record"). Collect the ones created since the last offboard —
**open AND closed** — so they land in the handoff instead of dissolving in
compaction:

```bash
_HP="$HOME/.agents/agents/lib/handoff-path.sh"; [ -f "$_HP" ] && . "$_HP"
type last_offboard_path >/dev/null 2>&1 || last_offboard_path() { printf '%s/.claude/last-offboard-session' "${1:-.}"; }
# Pass data via env vars — NOT `br … | python3 - <<HEREDOC` (the pipe and the
# heredoc both claim stdin, so python reads the JSON as its program). Verified.
#
# The CUTOFF comes from the SESSION, never the calendar. `date -d 'today 00:00'`
# was the old fallback and it silently dropped every decision a session filed on
# its own first day whenever the session ran past midnight (`bd-y12t`, measured
# live 2026-08-04: 0 hits over 14 scanned while bd-hsym / bd-v69y / bd-ge34 sat
# right there). Do NOT set SINCE_EPOCH here — the python block derives it and
# PRINTS it. (Set it only to deliberately override the window; the block then
# warns if your override postdates the session.)
PROJECT_SLUG=$(pwd | sed 's|/|-|g')
export SESSION_JSONL=$(ls -t "$HOME/.claude/projects/${PROJECT_SLUG}/"*.jsonl 2>/dev/null | head -1)
export MARKER_EPOCH=$(stat -c %Y "$(last_offboard_path .)" 2>/dev/null || true)
# `-a` is LOAD-BEARING: `br list` excludes closed by default, so a decision
# created AND closed inside this session — the cleanly-resolved kind, the most
# worth recording — is invisible without it (`explore-7ogz`). And it fails
# SILENTLY: the harvest just prints nothing, which reads like "no decisions."
# `-s open -s closed` is an equivalent union form. Do NOT reach for
# `--status all`: it is not a status, matches nothing, and exits 0 with an empty
# result — same silent-empty failure, one layer deeper (br 0.2.16).
# Project to id/title/created_at/status: the raw `--json` inlines every bead's
# full description (99 KB vs 5 KB on a real store, and it only grows with `-a`),
# which ~/explore/CLAUDE.md's bead-context-hygiene rule forbids carrying around.
export DECISIONS_JSON=$(br list --type decision -a --json 2>/dev/null \
  | jq -c '[.issues[]? | {id, title, created_at, status}]' 2>/dev/null)
# fallback if jq is absent — correct, just fatter
[ -n "$DECISIONS_JSON" ] || export DECISIONS_JSON=$(br list --type decision -a --json 2>/dev/null)
python3 <<'PY'
import os, json, datetime as dt

def _session_start(path, max_lines=500):
    """Earliest record timestamp in the session transcript, or None.

    NOT `stat`: %Y is the last APPEND and %W/btime is the last ROTATION, not the
    session's start — measured 2026-08-04, btime said 17:15 for a transcript
    whose first record was 17:06 the PREVIOUS day. NOT line 1 either: the
    opening records are untimestamped metadata (`last-prompt`, `mode`,
    `permission-mode`, `file-history-snapshot`), so the first record carrying a
    `timestamp` is typically line 3-5. Bounded prefix scan; min, not first, so
    an out-of-order transcript can't narrow the window."""
    if not path or not os.path.exists(path):
        return None
    best = None
    with open(path, errors="replace") as fh:
        for i, line in enumerate(fh):
            if i >= max_lines:
                break
            try:
                ts = json.loads(line).get("timestamp")
            except Exception:
                continue
            if not ts:
                continue
            try:
                t = dt.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
            except ValueError:
                continue
            if best is None or t < best:
                best = t
    return best

def _int(name):
    v = (os.environ.get(name) or "").strip()
    return int(v) if v.lstrip("-").isdigit() else None

sess, marker = _session_start(os.environ.get("SESSION_JSONL")), _int("MARKER_EPOCH")
override, warn = _int("SINCE_EPOCH"), []
if override is not None:
    cut, src = override, "explicit SINCE_EPOCH override"
elif sess is not None and marker is not None:
    # EARLIER of the two, never the later. An over-wide window shows you a bead
    # you can judge and discard; a too-narrow one shows you nothing and looks
    # exactly like calm. Cost of the choice: re-offboarding the same session
    # re-lists decisions already harvested. Duplicates are safe, silence is not.
    cut, src = min(sess, marker), "earlier of session start and last-offboard marker"
elif sess is not None:
    cut, src = sess, "session JSONL first record"
elif marker is not None:
    cut, src = marker, "last-offboard marker (no session JSONL found)"
    warn.append("no session JSONL found — the cutoff could not be checked against session start.")
else:
    cut = dt.datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp() - 86400
    src = "FALLBACK: yesterday 00:00 (no session JSONL, no marker)"
    warn.append("cutoff is a GUESS (no JSONL, no marker). Anything filed before it is "
                "INVISIBLE — widen it with SINCE_EPOCH before believing a zero.")
if sess is not None and cut > sess:
    warn.append("cutoff POSTDATES the session's first record ({}) — this is exactly the "
                "bd-y12t false-zero condition. Do NOT trust a zero here.".format(
                    dt.datetime.fromtimestamp(sess).astimezone().isoformat(timespec="seconds")))

try:
    rows = json.loads(os.environ.get("DECISIONS_JSON") or "[]")
except Exception:
    rows = []
rows = rows if isinstance(rows, list) else rows.get("issues", [])
hits = 0
for r in rows:
    ca = (r.get("created_at") or "").replace("Z", "+00:00")
    try:
        if ca and dt.datetime.fromisoformat(ca).timestamp() >= cut:
            closed = " _(closed this session)_" if r.get("status") == "closed" else ""
            print(f"- `{r.get('id')}` — {r.get('title','')}{closed}")
            hits += 1
    except ValueError:
        pass

def _iso(e):
    return dt.datetime.fromtimestamp(e).astimezone().isoformat(timespec="seconds") if e else "unknown"
print(f"# {hits} decision bead(s) since {_iso(cut)} ({len(rows)} scanned, open+closed)")
print(f"# cutoff source: {src} | session start: {_iso(sess)}")
for w in warn:
    print(f"# WARNING: {w}")
PY
```

The receipt is now **two lines, and you must read both.** The count line alone
is not a verdict:

| Receipt | Means |
|---|---|
| `0 … (0 scanned)` | the QUERY came back empty — re-run before believing it |
| `0 … (37 scanned) ` + cutoff ≈ session start | genuinely no decisions this session |
| `0 … (37 scanned) ` + cutoff **after** session start | **the false zero.** The query worked and the window was wrong |

That third row is the whole reason the second line exists. The old receipt
printed only "0 … (14 scanned)" and its own documented rule certified that as a
genuine zero — the guard against a silent empty *confirmed* the wrong answer,
because it checked the query and never the cutoff. A receipt that cannot see the
input it filtered on is not a receipt. Any `WARNING:` line means the harvest is
not trustworthy: fix the window and re-run rather than writing the note.

Put each result under the handoff's **Decisions made this session** section
(Step 3). If none, the section says "none this session." These are a durable
ADR log — leave the **open** ones open unless a later decision supersedes one;
a decision already closed within this session still belongs in the handoff
(mark it `(closed this session)`), because the record is what matters, not the
bead's remaining lifecycle.

## Step 2.6: Promote any proposed STANDING practice out of the handoff

The handoff note is a **per-session snapshot** — Step 3 overwrites it, and a
`/clear` (or a `--fresh` tick) leaves nothing else behind. So a practice
proposed only here is **homeless**: one session later it is indistinguishable
from a practice that was actually adopted, except that nothing enforces it and
nobody will ever read it again.

The handoff's job — "what the next run needs to know" — is exactly the shape of
a proposed standing practice, so the temptation lands here every time. Before
writing the note, scan what you're about to write for anything phrased as
durable: *worth adopting*, *should become*, *going forward*, *from now on*,
*always*, *the standing X*, *next run should*. **Every hit needs a home that is
not this file:**

| The proposal is… | Its home |
|---|---|
| mechanical and unambiguous | edit the SKILL / contract / registry **now**, this session |
| a judgment call, or bigger than this session | `br create` a bead **now**, and cite its id |
| genuinely one-run-only ("re-check X tomorrow") | fine to leave in the note — it isn't standing |

Then record the disposition in the handoff's **Proposed practices** section
(Step 3) — each line naming *where it landed*, not what it is. That section is a
**receipt, not an inbox**: an entry with no destination means the promotion
didn't happen, which is the bug. If nothing was proposed, it says "none this
session."

(Filed as `explore-zl07` after exactly this failure: a "standing second check"
lived in one loop's handoff for a day, was never promoted, and survived only
because the next run happened to read the note.)

## Step 2.6.5: Give every Friction bullet a destination

Same failure as Step 2.6, one section over: a friction noted only in the
handoff is a friction the NEXT session either re-discovers cold or never
sees again — Audit N found the same YAML trap warned three times across
three separate handoffs, each one pleading "worth filing as a bead," each
one overwritten before it became one. A noted friction is still an unfiled
friction.

Before writing the Friction section (Step 3), give every bullet a
destination:

| The friction… | Ends with |
|---|---|
| already has a bead | `→ bd-xxxx` |
| is new and worth tracking | `→ filed bd-yyyy` (label it `friction` at CREATE time — `br create -t bug -l friction "scope: title"` — see `/beads` Labels) |
| is genuinely one-off | `→ one-off` |

The label is what makes this mechanical rather than prose: `br list --label
friction` is how the harness-friction seam (and `/triage`) pulls the set,
not a title grep. A friction bead filed without the label is invisible to
that query even though it reads exactly like one — dotfiles-iypf found zero
beads using this convention despite it being documented, which is what
"prose, not mechanical" looks like in practice.

**Wire provenance on every `filed bd-yyyy`.** If the friction surfaced while
working a specific bead this session, mint the edge so the new bead's
ancestry is queryable — `br dep tree bd-yyyy` then shows exactly which piece
of work turned it up:

```bash
br dep add bd-yyyy <bead-you-were-working> -t discovered-from
```

Skip it only when the friction genuinely wasn't tied to any single bead
(e.g. found during general session cleanup, not mid-task).

**The `one-off` valve is load-bearing, not an escape hatch to abuse.**
Without it, every trivial hiccup would need a bead and the channel trains
itself to stop reporting friction at all — that failure mode is worse than
a few unfiled one-offs. The bar for real recurrence: **it recurred this
session or a prior one, or you predict it will** → `→ filed bd-yyyy`. A
single freak occurrence you don't expect again → `→ one-off`.

No blocking hook enforces this — a mechanical gate here just produces
empty sections instead of honest ones. This is a discipline, same as
Step 2.6; recurrence detection across handoffs (dream fleet-scope) is the
machine-side half.

## Step 3: Write the session handoff note

Write the handoff note (overwrite, don't append — it's a snapshot, not a
log; history lives in git). Session artifacts live in `refs/` at the
project root (standardized 2026-06-09).

**Per-window scoping (multi-session projects).** A project that runs more
than one durable session — the pulse model: e.g. `~/explore` has a pulse
window AND an elevate window — opts in via `refs/.handoff-per-window`, and
the note is then `refs/session-handoff--<window>.md` so the parallel
sessions don't clobber each other's resume doc. Single-session projects
keep plain `refs/session-handoff.md`. The shared `handoff-path.sh` helper
resolves the right path (keyed by the tmux window name); always go through
it, never hardcode the filename:

```bash
mkdir -p refs
_HP="$HOME/.agents/agents/lib/handoff-path.sh"; [ -f "$_HP" ] && . "$_HP"
type handoff_path >/dev/null 2>&1 || handoff_path() { printf '%s/refs/session-handoff.md' "${1:-.}"; }
HANDOFF=$(handoff_path .)            # refs/session-handoff.md  OR  refs/session-handoff--<window>.md
# one-time legacy migration (pre-2026-06-09 location):
[ -f .claude/plans/session-handoff.md ] && git mv .claude/plans/session-handoff.md "$HANDOFF"
echo "handoff -> $HANDOFF"
```

Write the markdown below to `$HANDOFF`:

```markdown
# Session handoff — YYYY-MM-DD <session-id-short>

## State at offboard
- Current branch: <branch>
- Last commit: <hash> <subject>
- Open beads: <count>; in-progress: <count>
- In-flight subagents: <list or none>
- Dirty files: <list or none>
- Markers: `.offboard-pending` <cleared | still-present>

## What happened this session (bullets)
- <key accomplishments, decisions, merges>
- <anything load-bearing for next session>

## Friction
- <what fought you this session — hook rejections, retries, workarounds you
  had to reach for. This is for the NEXT reader and for /dream's
  harness-friction seam, not a complaint box. End every bullet with its
  destination (Step 2.6.5): `→ bd-xxxx` (existing bead), `→ filed bd-yyyy`
  (new, labeled `friction`), or `→ one-off` (it did NOT recur and you don't
  predict it will).>
- <"nothing notable" is a legitimate entry — an empty section is a datum too>

## Decisions made this session (autonomous decide-and-proceed calls)
- <the `-t decision` beads harvested in Step 2.5, one bullet each; or "none this session">
- <INCLUDING the ones created AND closed inside this session — mark those
  `(closed this session)`. A decision that was made, acted on, and closed is
  exactly as worth recording here as one left open; it is the cleanly-resolved
  ones this section used to drop (`explore-7ogz`).>

## Proposed practices — where each one landed (Step 2.6)
- <one line per standing proposal, naming its DESTINATION: "X → written into
  <skill/contract/registry>" or "Y → filed as `<bead-id>`"; or "none this session">
- <a line with no destination means it did not get promoted — that is the bug,
  not a note. This section is a receipt, not an inbox.>

## What's next
- <the next 1–3 actions the next session should take>

## Warnings / watch-outs
- <anything unusual the next session needs to know>
```

## Step 4: Clear markers and commit

```bash
# Markers are window-scoped too (handoff-path.sh), so two durable sessions
# in one project don't trip each other's safety net. Falls back to legacy
# single-file when not opted in / not in tmux. (Both markers are gitignored.)
_HP="$HOME/.agents/agents/lib/handoff-path.sh"; [ -f "$_HP" ] && . "$_HP"
type handoff_path          >/dev/null 2>&1 || handoff_path()          { printf '%s/refs/session-handoff.md' "${1:-.}"; }
type offboard_pending_path >/dev/null 2>&1 || offboard_pending_path() { printf '%s/.offboard-pending' "${1:-.}"; }
type last_offboard_path    >/dev/null 2>&1 || last_offboard_path()    { printf '%s/.claude/last-offboard-session' "${1:-.}"; }
HANDOFF=$(handoff_path .)
rm -f "$(offboard_pending_path .)"

# Record this session as offboarded — session-end.sh compares this to
# its own session_id and skips dropping the pending marker on a match.
mkdir -p .claude
PROJECT_SLUG=$(pwd | sed 's|/|-|g')
SESSION_ID=$(basename "$(ls -t "$HOME/.claude/projects/${PROJECT_SLUG}/"*.jsonl 2>/dev/null | head -1)" .jsonl)
[ -n "$SESSION_ID" ] && echo "$SESSION_ID" > "$(last_offboard_path .)"

git add "$HANDOFF"
git commit -m "$(cat <<'EOF'
:card_file_box: offboard: handoff note (<session-id-short>)

<one-line summary of what shipped this session>

EOF
)"
git push
```

## Step 5: Brief the user

One short paragraph:

- What shipped this session (1–2 bullets)
- What `/onboard` should pick up on next time

This is the last orchestrator action before context compaction or
session close.

## Edge cases

- **Session JSONL missing** — use the date alone in the handoff title and
  skip the `.claude/last-offboard-session` marker; still write the note
  and clear markers.
- **Multiple sessions in one day** — each gets its own handoff note,
  overwriting the prior one. The git history preserves the chain.

## Don't skip

Even short sessions deserve a handoff note. A two-line "I checked X, no
action" is honest and useful — better than no note at all.

## The `.offboard-pending` marker

`session-end.sh` (the `SessionEnd` hook) drops a `.offboard-pending`
file at the repo root when a session ends **without** `/offboard`
having run — detected primarily by `.claude/last-offboard-session`
matching the ending session's id (Step 4 writes it), with
HEAD-committed-the-handoff-note as fallback. The next session's
`/onboard` Step 0 finds the marker, runs `/offboard` retroactively,
then clears it.

`pre-compact.sh` deliberately does NOT drop the marker: compaction
keeps the same session alive, and that session's own post-compaction
`/onboard` would misread its own marker as a prior session's.

If `session-end.sh` isn't wired in your project, manual `/offboard`
discipline is the only safety net.

## Pair with /onboard

`/onboard` checks for `.offboard-pending` at session start and runs
this skill retroactively if found. The two skills together bracket
every orchestrator session and keep handoffs continuous.
