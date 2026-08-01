# D — Fleet `CLAUDE.md` audit (43 project files + 2 symlinks)

Bead `dotfiles-563j`. Read-only. Every staleness row cites the command that proved it.
Box: `zig-computer`, 2026-08-01.

---

## 1. Headline numbers

| Metric | Words | Note |
|---|---:|---|
| All 45 discovered paths | **90,670** | includes the two symlinks twice |
| `/home/ubuntu/.claude/CLAUDE.md` + `/home/ubuntu/.claude-tick/CLAUDE.md` | 11,050 | **both are symlinks to `dotfiles/agents/AGENTS.md`** — `readlink -f` on each returns `/home/ubuntu/dotfiles/agents/AGENTS.md`. Not duplicates, not stale. `.claude-tick` is a second `CLAUDE_CONFIG_DIR` correctly wired to the same global tier. **Nothing to cut.** |
| **43 distinct project files** | **79,620** | the real always-loaded-per-project tax |
| Verifiably **STALE** | **~6,100** (7.7%) | §2 |
| **REDUNDANT** with `AGENTS.md` | **~5,100** (6.4%) | §4 |
| Stale **and** actively contradicting the global tier | **2,529** | `agent-dev-interrupted` alone |
| Proposed total after cuts | **~66,000** (−17%) | and −11,300 words concentrated in 4 files |

The distribution matters more than the total. **Six files hold 31,067 words (39%)**; the 20 smallest hold 12,600. This is not a fleet-wide bloat problem — it is four or five specific files.

---

## 2. The staleness table

| file | line | claim | verified how | verdict |
|---|---|---|---|---|
| `linearb/agent-dev-interrupted/CLAUDE.md` | 385 | `br new "Title"` | `br new` → `error: unrecognized subcommand 'new'`; `br --help` lists `create`, no `new` | **STALE — a broken executable example.** dotfiles Rule 2. |
| `linearb/agent-dev-interrupted/CLAUDE.md` | 122 | "Use tmux for subagents, **NOT the Task tool**"; session `agents-di-agent`; `--dangerously-skip-permissions --max-turns 100` | `AGENTS.md` §Delegation mandates `subagent_type:"subagent"` + `isolation:"worktree"`; `tmux ls` has no `agents-di-agent` | **STALE + CONTRADICTORY.** Teaches an orchestration model the global tier forbids. |
| `linearb/agent-dev-interrupted/CLAUDE.md` | 399–428 | a 250-word "Git Stash Protocol" | `AGENTS.md` §"Two writers…": "**NEVER stash** … fails DESTRUCTIVELY" | **STALE + CONTRADICTORY.** Directly inverts a hook-enforced fleet rule. |
| `linearb/agent-dev-interrupted/CLAUDE.md` | 360–370 | subagent-type table routing implementation to `general-purpose` / "`haiku` model" | `AGENTS.md`: built-ins are "for **read-only research** only — they lack hooks and cannot commit" | **STALE + CONTRADICTORY.** |
| `linearb/skills-library/CLAUDE.md` | whole file (3,279 w) | reads as a live project: "Maintenance loop", "Open questions", "Candidate first wave" | `git -C linearb/skills-library remote -v` → push remote is `DISABLED://repo-archived-2026-06-09-see-dotfiles-1nmb`; `linearb/CLAUDE.md` line 29 labels it `(archived)` | **STALE.** 3,279 words of live-voice brief in an archived repo. |
| `linearb/skills-library/CLAUDE.md` | 435 | "Sibling: `~/linearb/skills/`" | `ls ~/linearb/skills` → missing; `linearb/CLAUDE.md` line 38: "The former `skills/` submodule was removed 2026-07-10" | **STALE path.** |
| `cfp/mise/CLAUDE.md` | 1–1504 (856 w) | "DEADLINE: March 8, 2026"; "Status: … **Pipeline starts at Phase 1**" + a 4-phase plan | `git -C cfp/mise tag` → `vibex2026-submitted`, `vibex2026-camera-ready`, `artifact-v1.0`; `cfp/CLAUDE.md`: "**Submitted + camera-ready + arXiv**" | **STALE.** The whole file is a build plan for work finished ~5 months ago. |
| `cfp/mise/CLAUDE.md` | 94, 101, 1461 | `.claude/ref/published-article.md` | `ls cfp/mise/.claude/` → `plans/ research/ worktrees/ settings.local.json`. **No `ref/`.** | **STALE path** (3 references). |
| `cfp/mise/CLAUDE.md` | 1376, 1438, 1482 | data source `~/hackathon-infactory/` | `ls ~/hackathon-infactory` → missing. It is `~/coding-jams/the-atlantic/hackathon-infactory` | **STALE path** (3 refs). |
| `autonoveld/CLAUDE.md` | 224–250 | "**FOUR timers, one row each**" table, presented as live | `systemctl --user list-unit-files 'pulse-autonoveld-*'` → all four `.timer` files are **`disabled`**; none appear in `list-timers` | **STALE.** ~700 words describing a loop that is not scheduled. The single highest-value correction in the fleet. |
| `autonoveld/CLAUDE.md` | 765–815 | 362-word Hermes-archive section | `systemctl --user list-unit-files 'hermes*'` → 0 loaded, 0 timers (as documented). Accurate but the arc is 5 weeks closed | **STALE-BY-IRRELEVANCE.** Correct; no longer worth always-loading. Move to `archive/hermes-substrate/README.md`, which exists. |
| `autonoveld/CLAUDE.md` | 819 | "1074 green as of 2026-07-28" | file itself says "treat as a dated observation" | self-flagged; keep the caveat, drop the number |
| `linearb/weekly-reporting/CLAUDE.md` | 8–42 (242 w) | "Hermes substrate — DEPRECATED / PAUSED (2026-06-06)" | Hermes dead fleet-wide since 2026-06; `ls ~/explore/hermes-agent-trial` → missing | **STALE.** 2 months of tombstone in always-loaded context. |
| `linearb/weekly-reporting/CLAUDE.md` | 33 | handoff at `~/dotfiles/.claude/plans/session-handoff.md` | `ls` → **missing**. `.claude/plans/` is a deprecated convention per `AGENTS.md` §Reference material | **STALE path.** |
| `linearb/weekly-reporting/CLAUDE.md` | 589 | "`pulse-daily-digest.{service,timer}` … **still enabled**, 07:00 PT daily" | `systemctl --user list-unit-files` has **no `pulse-daily-digest*`**. The live unit is `pulse-digest.timer` (enabled, last ran Sat 14:00 UTC = 07:00 PT) | **STALE unit name.** |
| `explore/simon-willison/CLAUDE.md` | 1139 | "Driven daily by the `/daily-digest` harness in `~/linearb/weekly-reporting`" | `weekly-reporting/CLAUDE.md` line 576: "MOVED to `~/explore` (2026-07-07)"; live unit is `pulse-digest.timer` | **STALE.** Two files in the same fleet disagree. |
| `linearb/CLAUDE.md` | 111–114 | "zig-computer keeps `:7575` as the public granola webhook endpoint via system nginx (`sites-available/reef-router-7575.conf`, **enabled**)" | `ls /etc/nginx/sites-enabled/` → `default, granola…, hevyd…, vs14…, webmention…`. **No reef-router conf.** `ss -ltn` → nothing on 7575. `lb-granola/CLAUDE.md`: "✅ retired" | **STALE.** |
| `romd/CLAUDE.md` | 648 | "Live example on this box today: `ss -tlnH` shows hevyd on `*:14389` — wildcard, not tailnet" | `ss -ltnp` → `127.0.0.1:14389 users:(("hevyd"…))`. Fixed 2026-07-27 (`hevyd-bi9`), which `hevyd/CLAUDE.md` documents | **STALE.** A cited live measurement that is now false. |
| `romd/CLAUDE.md` | 595 | "`agents/infra.md` says '1.25 toolchain' — that is stale" | `go version` → `go1.24.4`; `grep 'go (1.25' dotfiles/agents/infra.md` → line 42 still says 1.25 | **CONFIRMED — and `infra.md` is still wrong.** romd is right; fix `infra.md`. |
| `linearb/reef/CLAUDE.md` | 651 | commit example: `Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>` | fleet default is Opus 5 since 2026-07-25; `AGENTS.md`/`/commit` use the current name | **STALE MODEL NAME in an executable example.** dotfiles Rule 2, 5th confirmed instance. |
| `linearb/reef/CLAUDE.md` | 707 / 737 | "`docs/` directory (**38 files**)" then "(**37 files**, moved from bootstrap…)" | internally contradictory in one file | **STALE count.** Drop the number. |
| `linearb/reef/CLAUDE.md` | 496–563 | its own orchestrator + "Subagent Beads Protocol (MANDATORY)" — subagents run `br update`/`br close` | `AGENTS.md` §Beads lifecycle: "**Subagents never run `br update` or `br close`**" | **CONTRADICTORY.** |
| `linearb/agent-factory/CLAUDE.md` | 480 | "Decisions are documented in **PLAN.md**" | file exists, but `AGENTS.md` §Reference material: "root-level `PLAN.md` … **deprecated**" | convention drift (file is real; the pattern is retired) |
| `cfp/CLAUDE.md` | 1092–1100 | Children table lists 5; "**All five are submodules**" | `ls -d ~/cfp/*/` → **8**: missing `review-flow-experience/`, `talk-mise-en-place/`, `zapconnect-2026/` — all three of which have their own `CLAUDE.md` | **STALE roster.** |
| `cfp/o11y/CLAUDE.md` | 1300–1301 | source material at `~/agent-dev-interrupted/` and `~/agent-dev-interrupted/CLAUDE.md` | `ls ~/agent-dev-interrupted` → missing. Real path `~/linearb/agent-dev-interrupted/` | **STALE path** (2 refs). |
| `linearb/agent-factory/CLAUDE.md` | 388 | `PHOENIX_COLLECTOR_URL` default `http://localhost:6006` | `ss -ltn sport = :6006` → nothing; `lb-phoenix.service` is `inactive`/`disabled` | correct-as-documented in `linearb/CLAUDE.md`; agent-factory omits the caveat |
| `linearb/okr-videos/CLAUDE.md` | 291 | "`lb-agent-scriptorium` is **stale and fully deprecated**" but `agent-factory/CLAUDE.md` line 469 still lists it in the live Agent Fleet table, ref project `~/downloads/Scriptorium` | `ls ~/downloads/Scriptorium` → **missing** | **STALE fleet row in agent-factory.** |
| `coding-jams/CLAUDE.md` | 1043 | "`.claude/templates/new-jam/` (**TODO: create when first new jam fires**)" | `ls coding-jams/.claude/templates/new-jam` → **exists** | stale TODO |
| `cfp/talk-checkmarx-summit-2026/CLAUDE.md` | 21–38, 195 | "Hard deadline … recording by ~2026-05-26; live air **2026-06-16**" | today is 2026-08-01 | past-tense event still written in future tense |
| `cfp/github-universe-2026/CLAUDE.md` | 13 | "Hard deadline May 1 2026 … Notifications **late July 2026**" | today is 2026-08-01 | notification window elapsed; status unrecorded |
| `cfp/talk-mise-en-place/CLAUDE.md` | 20 | "Submission deadline: **ASAP** … tentatively mid-May" | EASE 2026 ran June 9–12 | past-tense |

**Checked and clean** (worth stating, because they are the ones an untargeted "cleanup" would break):
`picod`'s 🛑 "the daily tick is OFF" — `pulse-picod.timer` is genuinely `disabled`, exactly as written. `hevyd`'s ports, TLS expiry (`openssl s_client` → `notAfter=Sep 25 18:51:44 2026`), `/healthz` 200, `127.0.0.1:14389`. `harnessd` `:14174`/`:14443` (both `LISTEN` on `100.98.174.21`, `curl` → 200). `vs14d-backup-health.timer`, `andrewzigler3-build.timer` (03:00 UTC = 20:00 PT, matches "8pm PT"). All six `pulse-di-*` timers match `dashboard-dev-interrupted`'s table. Every path in `explore/CLAUDE.md` (13/13 exist).

**A correction to the hunt brief:** `bd-` is **not** a stale prefix everywhere. `grep issue_prefix` shows `bd` is the *live configured prefix* in `picod`, `agent-dev-interrupted`, `dashboard-dev-interrupted`, and `cfp/mise`. Only `autonoveld` migrated (`bd-` → `autonoveld-`, 2026-07-26). Do not mass-rewrite `bd-` ids.

---

## 3. The liveness table

| repo | CLAUDE.md words | last commit | active timer / service | verdict |
|---|---:|---|---|---|
| `autonoveld` | 7,738 | 2026-07-29 | **4 pulse timers, ALL `disabled`** | ⚠️ heaviest file, dead loop |
| `hevyd` | 5,019 | 2026-08-01 | `hevyd.service` + 2 timers ✓ | LIVE |
| `linearb/agent-dev-interrupted` | 4,475 | **2026-06-10** | none | 🔴 **DORMANT 7.5 wks + contradicts global** |
| `harnessd` | 4,071 | 2026-08-01 | `harnessd.service`, `harnessd-tlscert.timer` ✓ | LIVE (fleet-central) |
| `andrewzigler3` | 3,761 | 2026-08-01 | 2 timers ✓ | LIVE |
| `linearb/skills-library` | 3,279 | 2026-07-28¹ | none | 🔴 **ARCHIVED REPO** |
| `cfp/talk-mise-en-place` | 2,624 | 2026-07-28¹ | none | delivered (June) |
| `explore` | 2,550 | 2026-08-01 | 5 timers ✓ | LIVE (lab hub) |
| `picod` | 2,451 | 2026-07-31 | `picod-health.timer`, `ha-portald` ✓ | LIVE (agent tick off by design) |
| `linearb/dashboard-dev-interrupted` | 2,366 | 2026-08-01 | 6 `pulse-di-*` ✓ | LIVE |
| `investd` | 2,326 | 2026-08-01 | none | active, no loop |
| `aaif` | 2,323 | 2026-07-31 | `pulse-aaif-radar.timer` ✓ | LIVE |
| `robloxd` | 2,293 | 2026-07-26 | none | scaffold |
| `vs14d` | 2,281 | 2026-08-01 | `vs14d-backup-health.timer` ✓ | LIVE |
| `linearb/reef` | 2,149 | 2026-07-28¹ | none (reef-router retired) | 🔴 **BEING RETIRED** |
| `cfp/talk-ai-council` | 2,144 | 2026-07-28¹ | none | **delivered** |
| `explore/blightmud` | 1,952 | 2026-07-28¹ | none | dormant |
| `linearb/imc-aug26` | 1,831 | 2026-07-30 | none | LIVE campaign |
| `romd` | 1,678 | 2026-07-28¹ | none | scaffold, OQ-1 open |
| `cfp/talk-checkmarx-summit-2026` | 1,600 | 2026-07-28¹ | none | aired 06-16 |
| `linearb` (umbrella) | 1,549 | 2026-08-01 | `lb-fleet`,`lb-listener` ✓ | LIVE |
| `ts4d` | 1,454 | 2026-07-28¹ | none | scaffold |
| `linearb/agent-factory` | 1,432 | 2026-07-28¹ | `lb-fleet`/`lb-listener` ✓ | semi-live |
| `linearb/weekly-reporting` | 1,409 | 2026-07-31 | `pulse-weekly-report.timer` ✓ | LIVE |
| `linearb/okr-videos` | 1,388 | 2026-07-28¹ | none | scaffold |
| `linearb/lb-granola` | 1,385 | 2026-07-30 | `lb-granola.service` + `.timer`/`.path` ✓ | LIVE |
| `cfp/github-universe-2026` | 1,363 | 2026-07-28¹ | none | awaiting notification |
| `cfp/zapconnect-2026` | 1,266 | 2026-07-28¹ | none | in-flight |
| `linearb/pipeline-website` | 982 | 2026-07-28¹ | none | oriented, not built |
| `linearb/imc-july26` | 915 | 2026-07-17 | none | campaign closed |
| `explore/afcl` | 871 | 2026-07-28¹ | none | dormant |
| `cfp/mise` | 856 | 2026-07-28¹ | none | 🔴 **COMPLETE (Mar 2026)** |
| `cfp` (umbrella) | 851 | 2026-07-28 | none | LIVE |
| `dotfiles` | 782 | 2026-08-01 | `pulse-retry`,`pulse-stall` ✓ | LIVE |
| `coding-jams` | 724 | 2026-08-01 | none | LIVE umbrella |
| `explore/smalltalk` | 634 | 2026-07-28¹ | none | dormant |
| `explore/duckdb` | 597 | 2026-07-28¹ | none | 🔴 "Active research phase. Started 2026-05-18", all 5 phases `pending`/`in progress` — **11 weeks with no movement** |
| `cfp/review-flow-experience` | 479 | 2026-07-28¹ | none | delivered (June 30) |
| `explore/simon-willison` | 468 | 2026-07-28¹ | none | dormant archive |
| `linearb/imp` | 465 | 2026-07-26 | none | awaiting offsite |
| `linearb/onboard-jamie` | 333 | **2026-06-29** | none | 🔴 dormant |
| `cfp/o11y` | 266 | 2026-07-28¹ | none | draft |
| `explore/fragments` | 240 | 2026-07-28¹ | none | dormant archive |

¹ **Read the `2026-07-28` cluster as dormancy, not activity.** 17 repos share that date, and the two I sampled are the same mechanical fleet-wide sweep (`skills-library`: `:lock: beads: use the jsonl-union merge driver`; `cfp/mise`: `:lock: beads: drop the stale plain-union line`). No human touched their content.

**Dormant list (no human content change + no timer):** `agent-dev-interrupted`, `onboard-jamie`, `skills-library`, `reef`, `cfp/mise`, `cfp/o11y`, `cfp/review-flow-experience`, `cfp/talk-ai-council`, `cfp/talk-checkmarx-summit-2026`, `cfp/talk-mise-en-place`, `explore/{blightmud, duckdb, smalltalk, simon-willison, fragments, afcl}`, `linearb/{okr-videos, pipeline-website, imc-july26}`. **19 repos, 21,900 words.** Cheap in practice — the cost is paid only when a session opens there — but `agent-dev-interrupted` is the exception: it is dormant *and* wrong.

---

## 4. The redundancy table

| file | words restating `AGENTS.md` | which sections |
|---|---:|---|
| `linearb/agent-dev-interrupted` | **2,529** | Tmux Subagent Pattern (L120–286), Orchestrator Workflow / Context Protection / Chained Subagents / Subagent Types / Beads-First / Git Stash / Parallel Execution / Traceability / Worktrees / Anti-Patterns (L287–525), JSONL merge (L539–563), Release Branch + build hooks (L590–670) |
| `linearb/reef` | **735** | Orchestrator Behavior + Subagent Beads Protocol (L496–563, 403 w); Git Workflow & Commit Convention + emoji tables (L596–652, 332 w) |
| `linearb/dashboard-dev-interrupted` | ~250 | Development Guidelines, Git Workflow, Session Protocol (the branch-assert block at L161–191 is a genuine local scar — **keep it**) |
| `linearb/okr-videos` | ~180 | "How we work here" — restates effort policy + delegation verbatim |
| `linearb/skills-library` | ~150 | Process discipline |
| `hevyd` | ~120 | Conventions bullets 1–3 |
| `harnessd` | ~110 | Conventions |
| `picod` | ~90 | Conventions bullets 1–2 |
| `explore/smalltalk` | ~90 | Conventions (task tracking / commits / code quality) |
| `linearb/pipeline-website` | ~90 | Conventions |
| `aaif` | ~80 | Conventions bullets 1–2, 4 |
| `linearb/agent-factory` | ~70 | Development Workflow |
| `explore` · `linearb` · `coding-jams` · `cfp` | ~60 each (**240**) | the identical "Universal conventions" 6-bullet block, duplicated across all four umbrellas |
| `vs14d`, `autonoveld`, `imp`, `duckdb`, `fragments`, `simon-willison`, `romd`, `ts4d`, `afcl` | ~40–60 each (**~440**) | Conventions one-liners |
| **Total** | **~5,100** | |

Two shapes here. The one-line "gitmoji + `Bead:` trailer, `refs/` at root, worktree subagents" pointer costs 40 words and is **worth keeping** — it tells a landing agent the project opted in. The 2,529-word `agent-dev-interrupted` block and the 735-word `reef` block are **full re-derivations that have since drifted into contradiction** — that is the real cost, not the tokens.

---

## 5. Per-file verdicts (all 43)

| file | words | proposed | main problem |
|---|---:|---:|---|
| `autonoveld` | 7,738 | 5,600 | dead timer table (700); Hermes section (362) → archive README; desk sections are dense LOCAL-FACT, keep |
| `hevyd` | 5,019 | 3,400 | changelog-as-brief: 11 dated "LIVE as of…" wave entries. Move wave history to `refs/waves.md`; keep the invariants |
| `linearb/agent-dev-interrupted` | 4,475 | 1,000 | **2,529 w contradicting the global tier**, dormant since 06-10 |
| `harnessd` | 4,071 | 2,900 | same changelog shape; Status section is 178 lines of dated push/badge archaeology |
| `andrewzigler3` | 3,761 | 3,400 | fine; commands + metis mechanics are LOCAL-FACT |
| `linearb/skills-library` | 3,279 | 250 | archived repo, live-voice brief |
| `cfp/talk-mise-en-place` | 2,624 | 2,624 | delivered; leave |
| `explore` | 2,550 | 2,400 | good file; the 2026-07-27 worked-example table already self-corrects |
| `picod` | 2,451 | 2,451 | **exemplary**; leave |
| `linearb/dashboard-dev-interrupted` | 2,366 | 2,100 | −250 redundant |
| `investd` | 2,326 | 2,326 | tier guardrails are irreducible |
| `aaif` | 2,323 | 2,240 | −80 |
| `robloxd` | 2,293 | 2,293 | scaffold, all LOCAL-FACT |
| `vs14d` | 2,281 | 2,230 | −50 |
| `linearb/reef` | 2,149 | 700 | retiring; −735 redundant, stale model name, contradicts bead lifecycle |
| `cfp/talk-ai-council` | 2,144 | 2,144 | delivered; leave |
| `explore/blightmud` | 1,952 | 1,952 | leave |
| `linearb/imc-aug26` | 1,831 | 1,831 | live campaign |
| `romd` | 1,678 | 1,620 | fix the hevyd wildcard claim |
| `cfp/talk-checkmarx-summit-2026` | 1,600 | 1,600 | add a one-line "aired" stamp |
| `linearb` | 1,549 | 1,440 | fix `:7575`; −60 universal-conventions |
| `ts4d` | 1,454 | 1,414 | −40 |
| `linearb/agent-factory` | 1,432 | 1,340 | drop scriptorium row, PLAN.md pointer, −70 |
| `linearb/weekly-reporting` | 1,409 | 780 | −242 Hermes, −190 daily-digest, fix unit name + dead path |
| `linearb/okr-videos` | 1,388 | 1,200 | −180 |
| `linearb/lb-granola` | 1,385 | 1,385 | **exemplary** (its "how it was wrong" section is the model) |
| `cfp/github-universe-2026` | 1,363 | 1,363 | record the notification outcome |
| `cfp/zapconnect-2026` | 1,266 | 1,266 | leave |
| `linearb/pipeline-website` | 982 | 890 | −90 |
| `linearb/imc-july26` | 915 | 915 | closed campaign, archival |
| `explore/afcl` | 871 | 830 | −40 |
| `cfp/mise` | 856 | 200 | complete since March; 6 dead paths |
| `cfp` | 851 | 800 | children roster is 3 short |
| `dotfiles` | 782 | 782 | **exemplary** |
| `coding-jams` | 724 | 660 | stale TODO, −60 |
| `explore/smalltalk` | 634 | 545 | −90 |
| `explore/duckdb` | 597 | 597 | status table stale but honest |
| `cfp/review-flow-experience` | 479 | 479 | leave |
| `explore/simon-willison` | 468 | 440 | fix daily-digest owner |
| `linearb/imp` | 465 | 415 | −50 |
| `linearb/onboard-jamie` | 333 | 333 | leave |
| `cfp/o11y` | 266 | 266 | fix 2 paths |
| `explore/fragments` | 240 | 200 | −40 |

---

## 6. Top 10 cuts by leverage

1. **`linearb/agent-dev-interrupted` — delete L120–525 and L590–670 (−3,000 w).** Highest leverage in the fleet: it is dormant, it teaches tmux-instead-of-Task, it teaches stashing, it teaches built-in subagents for implementation, and `br new` doesn't exist. Replace with 10 lines: "Orchestration follows `~/.claude/CLAUDE.md`. Project-specific: `/sprint-cleanup`, `/ralph`, `/create-prd`; release-branch flow in `docs/`."
2. **`linearb/skills-library` — collapse to ~250 w (−3,000).** Repo archived 2026-06-09 with a `DISABLED://` push remote. Replace with the archive banner + a pointer to git history.
3. **`autonoveld` L224–302 — correct the pulse table (−700, and fix a live lie).** Four timers are `disabled`. Either re-enable them or say the loop is off, as `picod` does. Right now the file programs every landing agent with a schedule that does not run.
4. **`cfp/mise` — collapse to ~200 w (−650).** The paper is submitted, camera-ready, arXiv'd and tagged; the file is a build plan with 6 dead paths.
5. **`hevyd` — move the wave changelog to `refs/waves.md` (−1,600).** Keep North star, guardrails, ports, the `refs/` index, Operate. The dated LIVE-as-of narratives are history, and history is what `refs/` is for.
6. **`harnessd` — same move (−1,200).** The 178-line Status section is push/badge archaeology; `refs/roadmap.md` already exists.
7. **`linearb/reef` — trim to ~700 (−1,450).** Retiring project; drop the orchestrator/beads protocol that contradicts the global tier, drop the Opus 4.5 example, drop the contradictory `docs/` counts.
8. **`linearb/weekly-reporting` — delete the Hermes section + fix 3 facts (−450).** Hermes has been dead 8 weeks; `pulse-daily-digest` is not a unit; the handoff path doesn't exist.
9. **`linearb/CLAUDE.md` — fix the `:7575` block.** Not big (90 w) but it is a *wrong infra fact in the umbrella file* every linearb child inherits by reading. `lb-granola` already knows the truth.
10. **Fix `dotfiles/agents/infra.md:42` ("go 1.25 toolchain" → `go1.24.4`).** Out of scope strictly, but `romd/CLAUDE.md` flagged it a week ago and nobody acted; `AGENTS.md` tells every infra session to read `infra.md` first.

---

## 7. What I would NOT touch, and why

- **`.claude-tick/CLAUDE.md`.** Not a stale duplicate — a symlink to `dotfiles/agents/AGENTS.md`, same inode target as `.claude/CLAUDE.md`. Deleting it would break the second config dir.
- **`picod`, `dotfiles`, `lb-granola`.** The three best files on the box. `picod` says out loud that its tick is off and how to re-arm it; `lb-granola` includes a "how this section was wrong, because the failure mode is the point" paragraph. That is exactly the anti-rot pattern the rest of the fleet needs *more* of. Adding words there is the right move, not cutting.
- **Every "what NOT to do here" block** (`robloxd`, `romd`, `vs14d`, `investd`, `explore`, `aaif`, `lb-granola`). These look like MODEL-SCAFFOLD and are not: each is a bright line with an incident behind it (AO3's five refusals, the `SavePlaceAsync` publish-by-default trap, the AGPL boundary, Tier A/B/C money guardrails, the unauthenticated `/api/transcripts` leak). They are the highest-value words in the corpus.
- **The dense `autonoveld` desk sections and `hevyd`'s day-boundary/energy-balance sections.** They read as bloat and are not — every paragraph names a defect that failed *green* (the `sent`→`archived` capture hook, the sticky note, `SET TimeZone` fixing 1 of 8 cast sites, `regr_r2` returning 1.0 not NULL). Cutting these re-opens bugs that exited 0.
- **All 10 delivered/past-deadline `cfp/*` files.** Dormant, yes — but they are archival records of shipped work, cost nothing outside their own directory, and `cfp/CLAUDE.md` explicitly says "Don't delete a delivered talk." Add a one-line status stamp; delete nothing.
- **The 40-word "Conventions" pointers.** Technically redundant, genuinely useful: they tell a landing agent this project opted into the fleet contract rather than having no opinion. Only the 700+ word re-derivations are waste.
- **`explore/duckdb`'s stale status table.** It honestly reports "in progress / pending" on an exploration that stalled 11 weeks ago. That is a true statement about a stalled project, not a stale one — the right fix is a `/triage` decision, not an edit.

**The structural finding, which no single cut addresses:** four of the six largest files (`hevyd`, `harnessd`, `autonoveld`, `lb-granola`) have become **changelogs in an always-loaded file**. Each new wave appends a dated "LIVE as of…" paragraph and nothing ever leaves. `refs/` already exists in all four for exactly this. The fleet needs a convention — *a CLAUDE.md states the current invariants; `refs/` holds how they got that way* — more than it needs any one deletion.
