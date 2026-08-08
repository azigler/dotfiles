# TOOLKIT — global skills digest

The per-skill digest `/onboard` Step 2 reads instead of all 37 full
bodies. Each entry: what the skill does, when it fires, what it
needs/touches, and the single most load-bearing anti-pattern. Full
bodies still load on invocation (progressive disclosure) — read a body
up front only when today's work leans on that skill.

**Size, measured 2026-08-01 — and the METHOD, so the next drift is
checkable rather than re-guessed:**

```bash
wc -cw agents/skills/TOOLKIT.md          # 37,756 bytes / 5,076 words
cat agents/skills/*/SKILL.md | wc -cw    # 664,599 bytes / 99,174 words
```

Tokens estimated at **bytes ÷ 4** (no local tokenizer; this is the
conservative direction — a word-based 1.33× estimate gives ~6.8k / ~132k):
the digest is **≈9.4k tokens against ≈166k for the bodies, i.e. ~6% of
the cost.** The `~3k vs ~80k` this line carried from 2026-06-09 was stale
in both terms — the digest had roughly tripled and the corpus doubled —
and `/onboard` Step 2 quoted the stale number as its whole justification
(`explore-cs5i`). Re-run the two commands above when you touch this file;
if the ratio drifts past ~10% the digest is no longer a digest.

**Maintenance:** when you edit a SKILL.md, update its entry here
(post-write-skill.sh reminds you). Regenerate wholesale if drift
accumulates. Generated 2026-06-09 from full-body extraction.

---

### /asana
**Job:** Asana rich-text mechanics (html_notes vs plaintext text, strict-XML rules) for reliable task/comment formatting.
**Fire when:** Working with Asana task bodies or comments; load before any html_notes write.
**Prereqs/side-effects:** Asana API access; LinearB fleet-proxy workflow is a separate private ref (~/linearb/refs/asana-fleet.md).
**Anti-pattern:** Using `notes` instead of `html_notes` for task bodies, or tags Asana rejects (`<h3>`, `<br>`, `<p>`).

### /beads
**Job:** Task tracking with `br` (beads-rust) — typed beads, full lifecycle, one bead = one commit.
**Fire when:** Constant reference throughout any project; lifecycle mandatory for spec/test/impl pipelines.
**Prereqs/side-effects:** `br` binary + `.beads/`; commits carry `Bead: <id>` trailer; JSONL flushed via `br sync --flush-only`.
**Anti-pattern:** Subagent mutating bead state (orchestrator-only); `br update --notes` in a loop — notes are REPLACE-only, read-then-rewrite.

### /cdn
**Job:** Upload a local file to Cloudflare R2 → stable PUBLIC url (`cdn.zig.computer`). Full lifecycle: `up`/`get`/`ls`/`rm`/`purge`. Content-addressed keys => idempotent, immutable urls. Hosts published/AAIF/blog images (Zig won't put images in his site folder) + kills the scp->view review loop.
**Fire when:** A local image/file needs a public embeddable url (screenshot/figure in a gist/post/tutorial), or you want to hand Zig an openable link instead of scp'ing. Also get/ls/rm/purge for retrieval + cleanup.
**Prereqs/side-effects:** creds in `~/.secrets` (R2_ACCOUNT_ID/R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY/R2_BUCKET/CDN_BASE_URL) + `rclone`, handed over via env-var backend config so no secret lands in `argv`; the bucket is PUBLIC; free-tier caps (10 GB storage, 1M Class-A, 10M Class-B ops, egress free — storage is the real cap).
**Anti-pattern:** Uploading private/sensitive files (public bucket); overwriting a fixed key and expecting an instant refresh (edge caches until TTL — use content-addressed keys or `purge`); HEAD/GET-ing the canonical url right after upload to "verify" (negative-caches a 404 for hours — verify via R2, cache-bust any public probe).

### /cfp
**Job:** Conference proposal / paper-submission orchestrator — bootstraps ~/cfp/<slug>/, interview→research→draft→critic→submit loop, post-acceptance shepherd.
**Fire when:** Explicit-invoke; user wants a CFP, paper submission, Sessionize form, camera-ready revision.
**Prereqs/side-effects:** Beads unconditional; creates refs/ + research/; Asana planning hub is canonical for milestones; peer-reviewed venues fire the sub-arc in `reference/scientific-paper-arc.md` (revision specs, artifact bundles, arXiv); hands off to /talk on acceptance.
**Anti-pattern:** Drafting from cold — angle-exploration step first; it's a multi-week arc, not a one-shot.

### /cleanroom
**Job:** Oracle-driven clean-room reimplementation — rebuild an artifact you can observe but have no (usable) source for, verified continuously against the ORIGINAL rather than against your own belief about it. Target selection, oracle construction, the observer/implementer split, the agent loop. A.k.a. the "reverse Ralph loop".
**Fire when:** Porting a binary to a new language, rebuilding a legacy system from behaviour, recovering a spec from a running service, writing a reader for an undocumented format. ALSO fire when someone proposes an autonomous rebuild loop and you need to establish whether they have an oracle — usually they do not.
**Prereqs/side-effects:** The loop is public and trivial (`while :; do cat PROMPT.md | claude -p …; done`, context resets each pass, filesystem+git are the memory layer) — the ORACLE is the entire job. Verified tool shelf in `reference/tool-shelf.md`, ranked by AGENT-DRIVABILITY (a worse tool the agent can drive unattended beats a better one needing a GUI); re-verify before relying on it. Judge every oracle on fidelity / coverage / locality / **independence**, and build a LADDER (per-routine for locality + whole-system for coverage — neither substitutes for the other). Carries the unattended-reporting contract (`dotfiles-cxle`): `<NAME>_RESULT=` on every terminal path, iteration caps, a `human:`-bead escape hatch. Enforce disposal STRUCTURALLY (separate agents, separate directories — the literature enforces it with a prompt, which is not a wall).
**Anti-pattern:** **Starting the loop before the oracle exists** — the default outcome is confident garbage at ~$10/hr. A round-trip test where your own reader feeds your own writer (shared failure mode = decoration; ask "what would this report if the implementation were a stub?"). One context that ingests, abstracts AND implements. Screenshots as the verification channel (where you land when you skipped the oracle — it let a tax bracket silently change 25%→10% in the genre's flagship demo). Claiming clean-room without running the **leak detector** (does the implementation contain correct facts the spec does not state? then prior knowledge leaked). Picking the target by desire rather than oracle availability — reversibility is a property of determinism + observability, NOT of format. Citing ghuntley's Atlassian Rovo post as evidence the method works: it is `unzip` on an embedded ZIP.

### /check
**Job:** Walk a spec bead's open questions / conflicts / dependencies; record decisions ON the bead; emit Implementation Readiness child bead.
**Fire when:** After /spec, before /test and /impl.
**Prereqs/side-effects:** Spec bead with Section 6; writes decisions to --notes (REPLACE-only — read-then-rewrite).
**Anti-pattern:** Editing the spec's --description from inside /check (spec agent owns it); looping --notes updates wipes prior decisions.

### /commit
**Job:** Gitmoji commits with bead integration; autonomous at natural checkpoints.
**Fire when:** Autonomous-OK at bead closure / test pass / config update.
**Prereqs/side-effects:** `br close` BEFORE commit; stage specific files only; **never push blind** — a rejected push means another writer committed (a `/pulse` tick is a real session in the project root; multi-writer since 2026-07-28), so absorb it with **`git fetch origin && git merge --no-edit origin/<branch>`** (AGENTS.md's "Two writers" rule — merge, NEVER rebase, NEVER stash) and push again; worktrees don't push at all; Co-Authored-By trailer comes from the harness, never hardcoded.
**Anti-pattern:** Batching multiple beads into one commit; copying a model name from examples into the trailer. **Pushing blind** — a rejected push means another machine committed; fetch+merge and push again, never `--force` to shared main, and never `--rebase`/`stash` to unblock it. **`merge=union`** on a bead JSONL (git's built-in) is the resurrection bug — always the custom `jsonl-union` driver. **`git rev-parse HEAD` as push proof** — it prints your local (possibly DETACHED) head, not what the remote got, so it passes on the one failure it should catch; assert the branch before committing and compare to `git ls-remote` after pushing (a managed checkout can re-detach mid-session — 4 commits stranded 2026-07-31). **A push fallback behind a pipe** — `if ! git push … | tail -1` tests `tail`'s status (always 0), so the fetch+merge absorb path can NEVER fire and says nothing when it doesn't; write `git push origin "$BRANCH"; rc=$?` with no pipe — `${PIPESTATUS[0]}` is bash-only and expands EMPTY in this fleet's zsh, failing open the same way — and keep the `ls-remote` proof, which is the check that actually caught it (`dotfiles-xugk`).

### /daemon
**Job:** Bootstrap a daemon+agent hybrid — a thin, LLM-free ingress (webhook/poller/sensor) + the Claude Code harness holding all intelligence. Scaffolds the refs set, the 4 decision forks, the bead roadmap, the go-live sequence.
**Fire when:** First-session scaffold for "an always-on capture/trigger thing + an agent on top" (the hevyd shape).
**Prereqs/side-effects:** Creates refs/ + CLAUDE.md + beads (`br init`); templates in reference/templates/ (incl. `verdict-contract.sh`, the copy-paste unattended-reporting shape); default stack Go pure-static + SQLite(WAL) + DuckDB analytics lens; pairs with `agents/infra.md`. Carries the **unattended-reporting contract** (`dotfiles-cxle`, the fleet's #1 defect shape, and a daemon is its highest-risk host): a `<NAME>_RESULT=` verdict marker on EVERY terminal path + consumer fail-closed on exit-0-with-no-marker; post-write verification by re-read (not the 2xx); `processed/total` coverage reporting; cursors/hashes advance on verified OUTCOME only; probe the service port, not just the nginx edge. A daemon that triggers an agent via `pulse-inject.sh` reads that script's own last-stdout-line marker `PULSE_INJECT_RESULT=injected|bounced-not-ready|deferred-blocked-on-human|failed*` rather than its exit code (`dotfiles-q0qi` — it exits 0 on all three of injected/bounced/deferred). Go-live step 2 is now a **negative control** — break the check, watch it fail. Plus: absent-peer batch-drain (never poll-and-alarm), per-RUN artifact names, `Persistent=true` stamp-file carry on rename, tailnet/loopback bind as a checked assertion, secrets by pointer (`EnvironmentFile` / source-and-exec wrapper). Optional arc: `reference/pwa-cockpit-push.md` — a TLS PWA cockpit with cross-platform Web Push + badges (iPhone/Safari/Chrome, auto-updating) + the act-now watcher (diff-on-swap, in-memory dedup: prime-silent/clear-on-resolution/retry; full-detail since E2E to own devices), worked example harnessd.
**Anti-pattern:** Putting the LLM in the daemon's hot path; matching the store to data-SIZE not workload-SHAPE; skipping the live premise-check + topology discovery before designing. A best-effort trigger that exits 0 when the agent window is absent (the durable queue guarantees the DATA, never that the agent ACTS). Believing "the suite is green" instead of a test you have watched fail; `cmd && DID_IT=true` as a success flag; alarming on a peer that is legitimately away (metis); `"row":null` on a ledger line (only `"unattributed"`); a literal secret in a unit/config; `0.0.0.0` binds. For the push arc: using a DECLARATIVE Web Push payload (the `app_badge` is a no-op on iOS 18.7) instead of a CLASSIC one that fires the SW → `setAppBadge`.

### /desk
**Job:** The research lab's ALLOCATOR — weekly **two-pass** whole-corpus review over ~/explore that emits a <=1,200-word chief-of-research RESOURCING MEMO to Zig (`refs/desk/<date>.md`). The READ half of a compendium that had only a write half. Replaces /elevate's old weekly sweep (Mode B).
**Fire when:** `pulse-desk.timer` (Fri, LIVE — stamp carried from pulse-elevate.timer); or "run the desk" / "what should the lab work on next".
**Prereqs/side-effects:** ⚠️ **The pass RUNS TWO PRODUCERS ITSELF before dispatching anything** (step 2), so invoking `/desk` mutates `~/explore` before any agent starts: `python3 bin/crosslink.py` (**1-4 min**, 4m24s on a 206-bead cold start) rewrites `refs/crosslink.md`, and `python3 bin/hatchery-candidates.py` (~2 s) rewrites `refs/hatchery-candidates.md` — the Phase-1 HATCHERY NOMINATION surface (`explore-knxy`), a table of densely-linked bead neighbourhoods with cohesion numbers and a `decision` column **only Zig fills**. Both follow the house exit contract (`0` result · `1` nothing cleared the bar, section still written · `3` a control failed = BLOCKED pass); both are gated in the done-proof by an 8-day freshness clause, and the memo carries a `### HATCHERY NOMINATIONS` pointer line, never the table. **WIDE proposes, NARROW verifies and writes** (Amendment 2, `refs/lab-open-questions.md`). Pass A = fresh agent, corpus in <=4 BULK reads, emits a ~2k **candidate list only** (ids/paths/quoted spans), ~6 turns — two lenses: A1 axis scan at `effort:'high'`, A2 opportunity lens at `effort:'max'` via Workflow over the week's delta + 2-3 rotating INDEX.md clusters. Pass B = a **fresh agent holding NO corpus** that opens only the named files, re-verifies each quote in place, dedups, and writes (~40 turns x ~40k). Cadence splits by SECTION: §1/§2/§4/§5 weekly, §3 wide **monthly** (or `--wide`, or >28d since the last wide refresh recorded in `refs/desk/axes.md`). Two hard caps, the second binding: 1,200 words AND **<=3 asks / <=1 stop / <=1 connection / <=2 new beads**. Writes `refs/desk/<date>.md` + `axes.md` + `signals.md` (the §3 carrier) + `field-notes.md`; `controls.md` is frozen and is NOT a Pass A input. Also `desk:`-prefixed interlinked beads, a `"row":"desk"` pulse-ledger row with a re-run `kind:cmd` proof, and dated `Novel opportunities (desk pass <date>)` appends to FINDINGS — **only for explorations a surviving candidate names**, and Pass A's corpus load strips those dated appends so the loop never re-ingests its own prose. Push-notifies the top ask + the PATH. Never Asana.
**Anti-pattern:** **One context that loads, judges, AND writes** — 19.3M (over the 15M gate) and the writer anchors to what it read; this is the design REJECTED on review, don't quietly restore it. A Pass A that returns prose verdicts, or a Pass B that opens the corpus (kills both the cost model and the over-anchoring defense). **Open synthesis instead of closed axis questions** (returns the same three attractors weekly). `br list --json` on the whole backlog (60k tokens of identical tie-backs — it MANUFACTURES the over-anchoring this loop counters; titles in, `br show` on demand). **An ask (or a stop) resting on an already-CLOSED bead, or on an ABSENCE-claim with no positive control** — both shipped in the 2026-07-31 §1; `br show` every bead a candidate names whatever its status, and the `bin/check-memo-beads.py` clause in the done-proof now blocks the first (explore-6g3l). A memo with no §2 WHAT TO STOP (a chief who only proposes isn't allocating) — and §2 must admit **per-exploration** stop candidates + keep `/scrutinize` dispatch authority, else the delegated structural review has no home (OQ3). §3 must be **BIDIRECTIONAL** — beads silently answered AND **confirmed defects with no bead** (the original one-way spec missed the live instance). A ranked menu instead of a POSITION — Zig walks INTO this artifact to drive next steps, so it must take a stand and live on disk, not in the tick's transcript (explore-b47q). Auto-closing the "beads silently answered" (propose only — a wrong close is silent AND permanent; required form = id + path + quoted span as a copy-pasteable `br close` block). Uncited claims, or **claiming enumeration over a sample**. "Nothing to report" on an empty week (corpus-level signal still exists). Migrating the archived `elevate` ledger rows (they stay under the old name — explore-b47q). Re-inlining either POINTER section (dotfiles-oec6): "Where the opportunity can land" is owned by `skills/_shared/opportunity-landing.md`, the registration assertion by `/pulse` §5.5 — desk keeps only the `harness-assert-registration pulse-desk desk` call. **Elevating a hatchery candidate, or filling a `decision` cell** — Phase 1 is human nomination and the desk surfaces only; a loop that answers for Zig erases the training signal Phase 2 needs (`explore-knxy` OQ-2). Pasting the nomination TABLE into the memo instead of one pointer line — this artifact family grows whenever it is allowed to (1,460 -> 1,666 -> 2,190 words).

### /dispatch
**Job:** Canonical subagent prompt template (bead ID, merge target, wave position, verification gates).
**Fire when:** Before every worktree-subagent dispatch; skip for built-in read-only types.
**Prereqs/side-effects:** No-nested-agents + path discipline are structurally enforced (subagent definition + hooks) — prompts carry task-specific content only. **SOLE OWNER of prompt blocks** (2026-08-01): /impl's and /orchestrator's prompt templates are pointers here, so there is exactly one template to drift.
**Anti-pattern:** Ambiguous merge target; dispatching code-writing work to built-in agent types (no Hard Rules, no hooks); re-copying the template into another skill instead of pointing here.

### /dive
**Job:** The lab's EXECUTOR — dive ONE lead, bounded, surface and log it. Multi-source URL research → structured plaintext report into an Asana task; archival (`~/explore/<topic>/`) or publishing (Zig-voice post + randomize image) shapes. (Renamed from `/explore` 2026-07-26, explore-mqvu; the umbrella repo is still `~/explore`.)
**Fire when:** The `dive` pulse row fires; or user hands over URLs + an Asana destination ("dive X" / "explore X" / "research these").
**Prereqs/side-effects:** Asana task GID; plaintext-only notes field; POST /update (PUT returns 405). refs/ captures are VERBATIM-by-default (extracts flagged with a `capture: extract` first-line header) so `bin/verify-quotes.py <topic>` can grep every FINDINGS quoted span against them before the scrutiny gate — a paraphrased capture silently defeats quote-verification.
**Anti-pattern:** HTML in Asana fields; abstract image subjects (force specificity via the randomize roll). A dive that never surfaces — the verb is BOUNDED; that IS the time-box. Archival mode: skipping Step 3.5 (consult the compendium — INDEX.md + grep prior FINDINGS) or omitting the now-REQUIRED `Related explorations` + `Novel opportunities` sections — the two that make the double loop compound (both were skipped historically; audit explore-doj). End the Asana report with the `Archived: ~/explore/<topic>/` back-pointer. LEAD the Novel-opportunities pass with CURIOSITY, not a tie-back — over-anchoring to the real projects here misses novelty (Zig 2026-07-13): range with NO default ranking over NEW ideas / interlinks (explorations AND open-ended beads) / active-arc-when-real / interesting-for-its-own-sake, don't manufacture a tie-back, "NO adopt" != "NO build", and the tabled BUILD PROJECTS don't table their CONCEPTS. **Single owner of that steer: `skills/_shared/opportunity-landing.md`** (read before prompting the ideation agent) — /dive, /desk, /elevate all point at it; re-inlining a copy is what produced 1,637 drifted words (dotfiles-oec6).

### /dream
**Job:** The harness's weekly SLEEP-TIME CONSOLIDATION loop and the WRITE half of the claude-vault arc (spec explore-76oc §4.4): mines the sessions since its last run via `/recall`, judges conservatively, and drafts HUMAN-GATED proposal beads (`propose-memory:` / `propose-harden:`, label `dream-proposal`). (Renamed from `/recall-distill` 2026-07-27, explore-w1mn; unrelated to `mud-distill.*`.)
**Fire when:** `pulse-dream.timer` fires `/dream tick` (Sun 04:13 PT, the `dream` tmux window); or `/dream status` for a read-only ledger + open-proposal view. NEVER inline in an interactive session.
**Prereqs/side-effects:** stdlib-only `dream.py` shells out to `recall.py`; CURRENT SLUG ONLY (a pushed proposal bead must never carry `linearb*`/`cfp*` content); appends one row per run to `~/explore/refs/dream-ledger.jsonl` with a mandatory non-null `row: "dream"`; files beads, pushes nothing else.
**Anti-pattern:** Writing `MEMORY.md` or auto-promoting a proposal — the trust-ladder invariant; the bead IS the proposal and a human IS the gate. Also: opening an AskUserQuestion from a tick (freezes the window), over-proposing low-signal candidates (trains Zig to ignore the channel — under-proposing is cheap), re-proposing an already-shipped learning without the MEMORY.md + open-`propose-*` dedupe check, and a bare relative ledger path (anchor to `$PULSE_DIR`).

### /elevate
**Job:** Max-effort, fresh-eyes re-examination of **ONE** finished thing — the generative twin of /scrutinize (hunts MISSED opportunity, not what's WRONG). **Targeted only**; the old weekly compendium sweep (Mode B) is now /desk.
**Fire when:** A baseline-effort pass under-thought one specific subject; "elevate X" / "fresh eyes on max". On-demand and interactive — it is NOT scheduled and writes no ledger row.
**Prereqs/side-effects:** Runs subagents at effort:'max' via **Workflow** (bare Agent has no effort param). Output → a <=600-word chief-of-research pitch (ask / signal / expected return / honest risk / verdict) + interlinked `desk:`-prefixed beads. NOT Asana.
**Anti-pattern:** Running it at baseline effort, or reusing the original/anchored agent — defeats the whole point. Correctness review is /scrutinize; whole-corpus sweeps are /desk. Outgrowing its subject (>600 words means you wrote a memo, and memos are /desk's job — the old sweep grew 1,460→2,190 words and became the comprehension rot it was built to prevent, explore-jdgk). Closes the loop seam: opportunities become `📌 candidate Vibes card` lines on beads → HUMAN-GATED promotion (offer + add; never auto-write the board — proxy has no section-add route anyway). LEAD with CURIOSITY, not a tie-back (over-anchoring to real projects misses novelty, Zig 2026-07-13) — **single owner of that steer: `skills/_shared/opportunity-landing.md`**, shared with /dive + /desk; read it before fanning out the max-effort lenses, and never re-inline a copy.

### /fix
**Job:** Fix-and-guard — typed `bug` bead, subagent fixes it, regression test makes it un-regressable.
**Fire when:** Autonomous-OK the moment a fixable bug is identified; user-invocable on reports.
**Prereqs/side-effects:** Creates -t bug bead (P1 default); Phase A diagnose+fix, Phase B regression guard MANDATORY; merge (sequence owned by AGENTS.md "Delegation") + close + cleanup. **Step 3.5 records `## Guard — <path>:<test>` on the bug bead** (dotfiles-8l2a) — mirrors `## Scrutiny —` so the guard rate is greppable; `## Guard — none: <why>` when there genuinely is none.
**Anti-pattern:** Fix without the regression guard — the fix without the test is incomplete; refactoring while in there; closing a bug bead with no `## Guard —` line (an unguarded fix that no audit can see — only 25% of 637 bug beads named a test before this).

### /gamma
**Job:** Gamma deck/document/webpage generation via API; 3-style control framework; returns gammaUrl + exportUrl.
**Fire when:** EXPLICIT-INVOKE-ONLY, COST-AWARE — never autonomously, never in loops, never speculative variants.
**Prereqs/side-effects:** GAMMA_API_KEY; every call deducts credits; response JSON cached to ~/.cache/gamma/.
**Anti-pattern:** Fanning out A/B/C variants without cost confirmation — one generation per call.

### /gdoc
**Job:** Google Docs read/write/format from CLI — gdoc.sh shim, Tabs API, service-account auth, styling contract (Arial 11pt, 20/16/13pt headings).
**Fire when:** Any Google Docs collaboration task.
**Prereqs/side-effects:** Service-account key; target doc shared with the SA email; styling contract is non-negotiable.
**Anti-pattern:** Using the Drive HTML importer to target a tab (whole-doc only — per-tab writes go through the native-requests path, fixed bd-3w8a 2026-06-11).

### /grok
**Job:** Read-only walk of unfamiliar code BEFORE editing; ends with optional -t study bead so the next agent doesn't repeat the read.
**Fire when:** "What does this area do?"; proactively before dispatching work on code you don't understand.
**Prereqs/side-effects:** Reads top 5-10 files; chat summary with file:line refs; zero writes.
**Anti-pattern:** Reading every file — narrow the question to <10 files; skipping the summary (understanding dies in the context window).

### /handoff
**Job:** Subagent wrap-up gate — verifies the bead is genuinely handed-off-ready BEFORE the final commit.
**Fire when:** Subagent finishing its piece; orchestrator can self-fire before /offboard.
**Prereqs/side-effects:** Checklist over bead fields; runtime-verification block mandatory for user-facing impls; summary the orchestrator parses. **Step 4.5 appends `## Handoff — <date>: <n> criteria verified, <n> split` to the bead** (dotfiles-8l2a) — mirrors `## Scrutiny —`; without it a run is indistinguishable from ordinary bead hygiene (the skill had ZERO measurable invocations).
**Anti-pattern:** Checking acceptance criteria without verifying them; empty --notes when surprises surfaced mid-work; skipping the `## Handoff —` line (an unmeasurable gate is an unrunnable one).

### /housekeeping
**Job:** Fleet-wide mechanical hygiene — doc refresh, cross-repo state audit, CLAUDE.md/skill consistency, bead closure, lint fixes.
**Fire when:** Weekly ritual or pre-release; pairs with /triage.
**Prereqs/side-effects:** Dependency-check before deletions; deprecation markers; also re-verify/prune version-stamped harness-behavior claims older than ~6 weeks.
**Anti-pattern:** Deleting code without grepping for importers; doing design work under the housekeeping banner (mechanical-only). In ~/explore, regenerate `INDEX.md` (the theme-clustered concept-map) as part of the doc-refresh — new explorations placed in clusters, cross-cluster connections + unconnected-opportunities refreshed (seeds the next /desk pass).

### /impeccable
**Job:** Frontend craft library — 7 design foundations + 14 refinement operations for production-grade interfaces.
**Fire when:** Building/refining/auditing any web UI; load when writing CSS/JSX so the AI-slop anti-patterns are top of mind.
**Prereqs/side-effects:** Loads reference/foundations/*.md before decisions; brand context from CLAUDE.md/MEMORY.md.
**Anti-pattern:** AI-slop defaults — cyan-on-dark, gradient text, glassmorphism, bounce easing, default Inter everywhere.

### /impl
**Job:** Orchestrator playbook for test-first implementation — test+impl beads, wave order, quality gate.
**Fire when:** After /check readiness; orchestrator ready to dispatch implementation.
**Prereqs/side-effects:** Tests merge BEFORE impl dispatch; /scrutinize gates merge-to-main; impl beads need a recorded scrutiny verdict to close (hook-enforced). The stub-body + composition audits and the subagent prompt skeleton are POINTERS now — owned by /scrutinize and /dispatch respectively (2026-08-01). What stays here: wave order, readiness, and the outcome>artifact acceptance-criteria shape.
**Anti-pattern:** Dispatching test + impl in the same wave; merging on "tests pass" without reading function bodies; running the post-impl audit inline as the orchestrator (conflicted judge — that's /scrutinize's gate).

### /lint
**Job:** Code-quality policy reference — biome (JS/TS), ruff (Python), rustfmt+clippy (Rust), golangci-lint (Go); what auto-runs vs commit-gates.
**Fire when:** Reference; hooks run the actual checks automatically.
**Prereqs/side-effects:** lint-on-write auto-fixes on save (respects prettier-configured repos); pre-commit lints commit files; task-completed runs heavy checks.
**Anti-pattern:** Disabling rules to unblock without a root-cause justification; linting files you didn't modify.

### /nginx
**Job:** Global reverse-proxy ops — vhost layout, certbot TLS, test+reload discipline.
**Fire when:** Auto-loads on nginx config paths; any vhost/TLS task.
**Prereqs/side-effects:** System nginx at /etc/nginx/; per-project vhost in ops/nginx/; `nginx -t` before reload.
**Anti-pattern:** Overwriting a certbot-shaped live vhost (use the include-file pattern); forgetting trailing-slash redirects.

### /offboard
**Job:** Session exit — handoff note to refs/session-handoff.md, optional cost row, clear markers, commit.
**Fire when:** Session end, before compaction, any handoff point. Orchestrator-only (skip in worktrees).
**Prereqs/side-effects:** Overwrites the handoff note (snapshot, not log); writes the last-offboard marker so session-end.sh knows offboard ran; migrates legacy .claude/plans paths via git mv. Paths resolve through `agents/lib/handoff-path.sh`: a project that runs >1 durable session opts in with `refs/.handoff-per-window` → handoff + markers are window-scoped (`session-handoff--<window>.md`, keyed by the tmux window name) so parallel sessions (e.g. ~/explore's pulse + elevate windows) don't clobber each other; single-session projects keep the plain single file.
**Anti-pattern:** Skipping short sessions — a two-line honest note beats no note. Hardcoding `refs/session-handoff.md` instead of going through `handoff_path`/`handoff_read_path` (breaks per-window scoping).

### /onboard
**Job:** Session entry — honor pending offboard, read foundation + TOOLKIT digest, discover live state, classify, route.
**Fire when:** Start of every session; retroactively honors .offboard-pending.
**Prereqs/side-effects:** Reads CLAUDE.md, MEMORY.md, refs/session-handoff.md, skills/TOOLKIT.md in the MAIN session; full skill bodies only for skills today's work leans on.
**Anti-pattern:** Delegating the foundation/TOOLKIT reads to a subagent (its context is discarded); skipping Step 0's pending-offboard check.

### /openrouter
**Job:** OpenRouter API for image gen (nano-banana) and text completion via aggregated models; outputs saved locally.
**Fire when:** EXPLICIT-INVOKE-ONLY, COST-AWARE — never autonomously, never loops.
**Prereqs/side-effects:** OPENROUTER_API_KEY; helper script saves images (lost image = wasted credits); verify file extension matches actual bytes.
**Anti-pattern:** Speculative variant fan-out; copying pinned model ids from docs instead of the live catalog.

### /orchestrator
**Job:** The worktree-subagent delegation pattern — create beads, dispatch, merge, close, clean up.
**Fire when:** Standing pattern for any session that delegates implementation.
**Prereqs/side-effects:** Standalone `cd` to project root before merge; continue a returned agent via SendMessage instead of re-dispatching. Owned ELSEWHERE (2026-08-01): the guarded merge/close/cleanup sequence = AGENTS.md "Delegation", the prompt template = /dispatch, the pre-merge audit = /scrutinize. Here: cwd discipline, cross-repo recovery, submodule absorption, wave order, worktree hygiene.
**Anti-pattern:** Merging without the /scrutinize gate on impl waves; leaving stale worktrees between waves (nesting risk); a bare per-branch `git merge worktree-agent-XXX` instead of the guarded sequence (no-ops silently on cwd drift or an agent that committed nothing).

### /pulse
**Job:** One tick of a self-driving project — scheduled command lands in a durable tmux session, routes against refs/pulse.md, does at most ONE unit of work with full discipline, offboards, ends.
**Fire when:** "/pulse tick" arrives (timer-injected or typed); "/pulse setup" to opt a project in; "/pulse status" to report. NEVER self-loop — the systemd timer is the loop.
**Prereqs/side-effects:** refs/pulse.md routing table (Zig's steering wheel — ticks never edit it); appends refs/pulse-ledger.jsonl; per-project systemd units from agents/scheduler/templates/. A row `check` is **THREE-valued**: `0` fire | `1` genuinely didn't trigger → quiet | `3` could not be evaluated → **blocked, and it STOPS the tick** (never fall through to a lower row).
**Anti-pattern:** A **binary** row `check` that pipes `curl` into `jq -e` — a 403/timeout body then exits non-zero and reads as "nothing to do", so a broken loop logs `quiet` four times a day forever with nothing tripping (`explore-pksf`, the dive loop, 2026-07-27). Any check crossing a network needs all three rungs: `curl -sf … || exit 3`, a shape assertion `|| exit 3`, then the real count. Also: a bare `FLEET_URL=http://localhost:7100` in a skill a JAILED loop runs — it clobbers the tick-jail's setenv and every call 403s. Also: Blocking on AskUserQuestion in a tick — unstaffed sessions file a P1 `human:` bead + push notification and end the tick. Also: self-declaring `outcome:"done"` without proof — every `done` line needs a real-distance `proof` token (**cmd** = hook re-runs it | **scrutinize** = SHIP bead; `artifact`/`commit` are REJECTED as zero-distance no-ops a stub passes, `explore-len0`), **hook-enforced by pre-commit-checks.sh** (a done commit whose proof doesn't verify is blocked); else log blocked/quiet (the nodding loop). Also: `"row":null` on ANY ledger line — even a quiet stand-down names the row it EVALUATED (cap counters + every per-row analytic key on the row name, so a null row is an invisible tick); the only escape hatch is the literal `"unattributed"`, never null and never a guessed name (`explore-qdo5` — 23 null rows across 3 ledgers were copied from this skill's own example). Structural review nudge every 5th done tick.

### /randomize
**Job:** Force real-entropy diversity — real randomness (seed → modulo → choice) for every discretionary creative decision, with a provenance block.
**Fire when:** Creative generation where the model would collapse to the modal answer. NOT for single-correct-answer tasks.
**Prereqs/side-effects:** openssl rand seed; arithmetic must be re-runnable by a reviewer; provenance block written BEFORE prose. One seed, one worked example — Step 4's provenance block IS the canonical worked example (the duplicate second pass over the same seed was cut 2026-08-01).
**Anti-pattern:** Narrating "committed choices" without running the arithmetic — no provenance block means it wasn't a real randomize.

### /recall
**Job:** grep + expand over the transcript firehose (`~/.claude/projects/<slug>/**/*.jsonl` incl. subagent transcripts + `tool-results/*.txt`) — type-keyed render of matching turns; the read half of the claude-vault arc (spec explore-76oc §4.2).
**Fire when:** "what did we decide about X", "find where I said Y", search past sessions for the actual transcript TEXT (not curated memory); the read primitive other skills call (the Phase-4 learning loop).
**Prereqs/side-effects:** stdlib-only Python CLI (`recall.py`), reads LIVE local files (no vault needed); exit 0=hit/1=none/2=error + `--json` `{slug,session,ts,role,line,text}`; `--regex` ReDoS-guarded (aborts LOUD on a pathological pattern); `--root`/`CLAUDE_PROJECTS_ROOT`/`RECALL_MAX_LINE_BYTES` overrides.
**Anti-pattern:** Using it when the question needs REASONING/synthesis (that's an agent — which may call /recall to ground itself); treating a `role="unrenderable"` loud line as noise — it's the drift detector firing on a genuinely-new record type.

### /research
**Job:** Autonomous layered research harness — parallel research subagents, empirical verification, independent scrutiny gate, fold to canon, layer next questions. Data-GENERATING items (benchmarks, scaled probes) additionally run reference/experiment-protocol.md: pre-registration, positive+negative calibration controls, blocking gates, raw-data provenance.
**Fire when:** "Research X" / "stay autonomous"; proactively on operational blockers, new substrates, doubted findings.
**Prereqs/side-effects:** refs/research/ archive; findings verified empirically before becoming load-bearing; independent scrutinizer (refute-framed) is the DEFAULT at the fold-to-canon boundary; autonomous mode has circuit breakers (2 consecutive anomalous iters → stop + P1 human: bead); notifications for material results.
**Anti-pattern:** Success defined as absence-of-error instead of presence-of-evidence — uniform failure passes uniformity checks; scaling an experiment whose pipeline never classified a known-good AND known-bad canary correctly.

### scrub-secrets
**Job:** Detect + redact secrets in the claude-vault tiers (memory files + transcript JSONL/tool-results) with TWO detectors: (1) high-confidence provider-prefix PATTERNS, (2) the LIVE VALUE DENYLIST — every `export NAME=VALUE` in `~/.secrets`, shape-filtered, matched verbatim, computed at runtime and never persisted. `scan` (report + nonzero exit = gate) / `redact` (JSON-safe atomic rewrite: temp → verify \n-line-count + per-line JSON parse → os.replace). Both detectors run in both modes.
**Fire when:** Before a vault commits (block a secret entering permanent history), on a periodic memory-tier sweep (catch a leaked literal), or to strip a credential that landed in memory/notes/transcripts. Layer 0 of the secret-hygiene system (explore-r2iq); callable by other skills (exit 1=found/0=clean).
**Prereqs/side-effects:** stdlib-only CLI (`~/.claude/skills/scrub-secrets/scrub.py`); `--apply` mutates files (dry-run default); `--exclude` skips the active session; denylist on by default (`--secrets-file` / `$SCRUB_SECRETS_FILE`, `--no-denylist`, `scrub.py denylist` prints the decision table — NAMES + verdicts, never values; hits report as `secrets-file:NAME`); `--entropy` scan-only (+ an allowlist for Doc IDs/$env/~paths/shas/uuids); `--gitleaks` folds the maintained-ruleset backend (opt-in, detect-only). Every summary line names the detectors in use, so "clean" is distinguishable from "clean under a narrow detector". Pairs with the "secrets never go in memory" AGENTS.md policy.
**Anti-pattern:** Entropy patterns in REDACT mode (a false positive corrupts real content — redact is prefix-patterns + exact-value only by design); running the denylist through `is_allowlisted` (its git-sha rule eats any 64-hex credential); wiring a NARROW detector to an admission gate and reading its exit 0 as "no secret present" (explore-wmlc: 3 of 22 real credentials detected, and redacting the visible 3 would have unblocked a push carrying the other 19); relying on redaction instead of PREVENTION (secrets belong in `~/.secrets`, referenced by pointer) — and redaction is never rotation.

### /scrutinize
**Job:** Adversarial read-only gate after an impl wave — disprove "done": stub bodies, mock-the-unit tests, unverified criteria, composition gaps.
**Fire when:** After every impl-wave merge, before merge-to-main / bead close. Skip only for atomic mechanical changes.
**Prereqs/side-effects:** Panel mode (default for substantial waves): saved workflow scrutinize-panel.workflow.mjs — 5 parallel hunt lenses + per-finding refuters. Single-agent mode for small waves (general-purpose/Explore, never worktree). Verdict SHIP / FIX-FIRST / REJECT recorded on the impl bead (hook-enforced for close). For user-facing surfaces: EXECUTE & OBSERVE (run/Playwright-click/inspect real output), don't certify by reading. Structural separation (fresh agent) is the primary mechanism; different-model is a supplementary lever. **SOLE OWNER of the post-impl audit** (2026-08-01, dotfiles-oec6): "The audit checklist" §1 stub bodies (+ triage greps) and §2 composition — absorbed from /impl and /orchestrator, which now point here; the `skills-library-8l6` incident is told once, there.
**Anti-pattern:** Skipping because the report looked clean — that's exactly when the gate earns its keep; inventing findings ("found nothing" is valid). Certifying a user-facing change by reading code instead of running it. Re-copying the audit checklist into an orchestrator-side skill (that's how it drifted into 3 copies).

### /spec
**Job:** Formal specification as a typed `spec` BEAD (not a file) — Overview/Baseline/Changes/Formal Spec/Test Cases/OQs/Future in --description.
**Fire when:** Defined work needs a spec before /check → /test → /impl.
**Prereqs/side-effects:** Creates -t spec bead; ≥10 test cases; optional Interrogator pass to surface OQs outside the author's blind spot.
**Anti-pattern:** Writing Section 6 without the Interrogator pass; creating spec FILES (specs/ folders are legacy-only).

### /talk
**Job:** Talk-prep orchestrator from acceptance to ready-to-deliver — spec → critic → slide-plan → visual-arc → image-narrative → script → aesthetic iteration → dry-runs.
**Fire when:** Accepted talk needs deck + script; tuning from dry-run feedback. Stops at delivery.
**Prereqs/side-effects:** Bootstraps ~/cfp/talk-<slug>/; beads load-bearing; two-tab Google Doc; Gamma renders smoke→batch→full (cost-aware).
**Anti-pattern:** Drafting slides without the visual arc; generating images before the image-narrative is reviewed.

### /test
**Job:** Convert a spec bead's Section 5 into executable tests + ≥5 edge/error tests beyond the spec.
**Fire when:** Test wave of TDD — before any impl dispatch.
**Prereqs/side-effects:** Imports point at real module paths (impl agent makes them pass); delegation-assertion tests mandatory; conventional test paths per language.
**Anti-pattern:** Touching implementation source files — tests-only output; skipping delegation-assertion tests (stubs pass mock-the-unit tests).

### /triage
**Job:** Bead-state hygiene — walk ready/stale/orphans/epic-close-eligible; close, defer, escalate, or do-the-work per bead.
**Fire when:** "Triage the beads"; weekly via /housekeeping; when `br ready` exceeds ~30 (hook nudges).
**Prereqs/side-effects:** Closures carry --notes rationale; commit the JSONL after (or beads reappear next session).
**Anti-pattern:** Deferring everything to escape triage — defer means "yes but not now," not "never".

### /zig-voice
**Job:** Andrew's published-writing voice — tone, rhythm cascade, structure, anti-pattern lexicon.
**Fire when:** ONLY for content Andrew publishes under his name (LinkedIn, blog, newsletter). Never for work artifacts, Asana, chat, reports.
**Prereqs/side-effects:** Specific-moment openers; banned-word list (delve, leverage, "here's the thing"); emoji as comedic timing.
**Anti-pattern:** Over-rotation — casual register bleeding into professional artifacts; the test is "will Andrew publish this verbatim?"
