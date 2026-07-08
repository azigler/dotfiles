# TOOLKIT — global skills digest

The per-skill digest `/onboard` Step 2 reads instead of all 31 full
bodies (~3k tokens vs ~80k measured 2026-06-09). Each entry: what the
skill does, when it fires, what it needs/touches, and the single most
load-bearing anti-pattern. Full bodies still load on invocation
(progressive disclosure) — read a body up front only when today's work
leans on that skill.

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
**Prereqs/side-effects:** creds in `~/.secrets` (R2_ACCOUNT_ID/R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY/R2_BUCKET/CDN_BASE_URL) + `rclone`; the bucket is PUBLIC; free-tier caps (10 GB storage, 1M Class-A, 10M Class-B ops, egress free — storage is the real cap).
**Anti-pattern:** Uploading private/sensitive files (public bucket); overwriting a fixed key and expecting an instant refresh (edge caches until TTL — use content-addressed keys or `purge`); HEAD/GET-ing the canonical url right after upload to "verify" (negative-caches a 404 for hours — verify via R2, cache-bust any public probe).

### /cfp
**Job:** Conference proposal / paper-submission orchestrator — bootstraps ~/cfp/<slug>/, interview→research→draft→critic→submit loop, post-acceptance shepherd.
**Fire when:** Explicit-invoke; user wants a CFP, paper submission, Sessionize form, camera-ready revision.
**Prereqs/side-effects:** Beads unconditional; creates refs/ + research/; Asana planning hub is canonical for milestones.
**Anti-pattern:** Drafting from cold — angle-exploration step first; it's a multi-week arc, not a one-shot.

### /check
**Job:** Walk a spec bead's open questions / conflicts / dependencies; record decisions ON the bead; emit Implementation Readiness child bead.
**Fire when:** After /spec, before /test and /impl.
**Prereqs/side-effects:** Spec bead with Section 6; writes decisions to --notes (REPLACE-only — read-then-rewrite).
**Anti-pattern:** Editing the spec's --description from inside /check (spec agent owns it); looping --notes updates wipes prior decisions.

### /commit
**Job:** Gitmoji commits with bead integration; autonomous at natural checkpoints.
**Fire when:** Autonomous-OK at bead closure / test pass / config update.
**Prereqs/side-effects:** `br close` BEFORE commit; stage specific files only; push (except worktrees); Co-Authored-By trailer comes from the harness, never hardcoded.
**Anti-pattern:** Batching multiple beads into one commit; copying a model name from examples into the trailer.

### /daemon
**Job:** Bootstrap a daemon+agent hybrid — a thin, LLM-free ingress (webhook/poller/sensor) + the Claude Code harness holding all intelligence. Scaffolds the refs set, the 4 decision forks, the bead roadmap, the go-live sequence.
**Fire when:** First-session scaffold for "an always-on capture/trigger thing + an agent on top" (the hevyd shape).
**Prereqs/side-effects:** Creates refs/ + CLAUDE.md + beads (`br init`); templates in reference/templates/; default stack Go pure-static + SQLite(WAL) + DuckDB analytics lens; pairs with `agents/infra.md`.
**Anti-pattern:** Putting the LLM in the daemon's hot path; matching the store to data-SIZE not workload-SHAPE; skipping the live premise-check + topology discovery before designing.

### /dispatch
**Job:** Canonical subagent prompt template (bead ID, merge target, wave position, verification gates).
**Fire when:** Before every worktree-subagent dispatch; skip for built-in read-only types.
**Prereqs/side-effects:** No-nested-agents + path discipline are structurally enforced (subagent definition + hooks) — prompts carry task-specific content only.
**Anti-pattern:** Ambiguous merge target; dispatching code-writing work to built-in agent types (no Hard Rules, no hooks).

### /distribute
**Job:** Mirror the dotfiles paragon skill set to the team. DEFAULT = plugin mode → the lb-marketing plugin marketplace (`~/linearb/plugins/linearb-marketing/skills`, served over MCP). `--tree` = legacy coworker-`.claude/` layout.
**Fire when:** After editing any paragon skill (so the team's MCP plugin stays current).
**Prereqs/side-effects:** Runs zig-computer.distribute.sh; plugin mode copies ONLY skills (no hooks/CLAUDE.md/settings), preserves `skills/.native-manifest` natives, removes `.distribute-exclude` personal-only skills (pulse/cfp/talk/…), strips private blocks; ship via the marketplace PR flow (CI validates manifests) + bump plugin.json version.
**Anti-pattern:** Pushing skill syncs straight to plugins `main` (CONTRIBUTING mandates a PR); adding destination-specific overrides to dotfiles paragons; running from a subagent worktree.

### /elevate
**Job:** Max-effort, fresh-eyes re-examination of FINISHED work — the generative twin of /scrutinize (hunts MISSED opportunity, not what's WRONG). Targeted (one project/exploration) or sweep (biweekly compendium-wide, pulse-elevate.timer).
**Fire when:** A baseline-effort pass under-thought something; "elevate X" / "fresh eyes on max"; or the biweekly sweep fires.
**Prereqs/side-effects:** Runs subagents at effort:'max' via **Workflow** (bare Agent has no effort param). Sweep → push-notify + beads (prefix `elevate:`), NOT Asana.
**Anti-pattern:** Running it at baseline effort, or reusing the original/anchored agent — defeats the whole point. Correctness review is /scrutinize, not this. Closes the loop seam: opportunities become `📌 candidate Vibes card` lines on beads → HUMAN-GATED promotion (interactive: offer + add; autonomous sweep: list in the push, never auto-write the board — proxy has no section-add route anyway). Sweep also writes a dated `Novel opportunities (elevate sweep <date>)` section back into each FINDINGS it examines — the BACKFILL for the ~40 pre-2026-06-29 explorations that predate the required-section rule.

### /explore
**Job:** Multi-source URL research → structured plaintext report into an Asana task; archival (~/explore/<topic>/) or publishing (Zig-voice post + randomize image) shapes.
**Fire when:** Explicit-invoke; user hands over URLs + an Asana destination.
**Prereqs/side-effects:** Asana task GID; plaintext-only notes field; POST /update (PUT returns 405).
**Anti-pattern:** HTML in Asana fields; abstract image subjects (force specificity via the randomize roll). Archival mode: skipping Step 3.5 (consult the compendium — INDEX.md + grep prior FINDINGS) or omitting the now-REQUIRED `Related explorations` + `Novel opportunities` sections — the two that make the double loop compound (both were skipped historically; audit explore-doj). End the Asana report with the `Archived: ~/explore/<topic>/` back-pointer. AIM the Novel-opportunities upside by recency at an ACTIVE arc (LinearB / AAIF / harness / recently-touched explore folder) or a general harness move — the mud/golem/local-coding-models/Hermes-local arc is TABLED (source to reason from, never a destination), and "interesting for its own sake, no build" is a valid honest entry (don't manufacture a tie-back). Mirrors /elevate's "Where to apply the upside"; keep in sync.

### /fix
**Job:** Fix-and-guard — typed `bug` bead, subagent fixes it, regression test makes it un-regressable.
**Fire when:** Autonomous-OK the moment a fixable bug is identified; user-invocable on reports.
**Prereqs/side-effects:** Creates -t bug bead (P1 default); Phase A diagnose+fix, Phase B regression guard MANDATORY; merge + close + cleanup.
**Anti-pattern:** Fix without the regression guard — the fix without the test is incomplete; refactoring while in there.

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
**Prereqs/side-effects:** Checklist over bead fields; runtime-verification block mandatory for user-facing impls; summary the orchestrator parses.
**Anti-pattern:** Checking acceptance criteria without verifying them; empty --notes when surprises surfaced mid-work.

### /housekeeping
**Job:** Fleet-wide mechanical hygiene — doc refresh, cross-repo state audit, CLAUDE.md/skill consistency, bead closure, lint fixes.
**Fire when:** Weekly ritual or pre-release; pairs with /triage.
**Prereqs/side-effects:** Dependency-check before deletions; deprecation markers; also re-verify/prune version-stamped harness-behavior claims older than ~6 weeks.
**Anti-pattern:** Deleting code without grepping for importers; doing design work under the housekeeping banner (mechanical-only). In ~/explore, regenerate `INDEX.md` (the theme-clustered concept-map) as part of the doc-refresh — new explorations placed in clusters, cross-cluster connections + unconnected-opportunities refreshed (seeds the next /elevate sweep).

### /impeccable
**Job:** Frontend craft library — 7 design foundations + 14 refinement operations for production-grade interfaces.
**Fire when:** Building/refining/auditing any web UI; load when writing CSS/JSX so the AI-slop anti-patterns are top of mind.
**Prereqs/side-effects:** Loads reference/foundations/*.md before decisions; brand context from CLAUDE.md/MEMORY.md.
**Anti-pattern:** AI-slop defaults — cyan-on-dark, gradient text, glassmorphism, bounce easing, default Inter everywhere.

### /impl
**Job:** Orchestrator playbook for test-first implementation — test+impl beads, wave order, quality gate.
**Fire when:** After /check readiness; orchestrator ready to dispatch implementation.
**Prereqs/side-effects:** Tests merge BEFORE impl dispatch; /scrutinize gates merge-to-main; impl beads need a recorded scrutiny verdict to close (hook-enforced).
**Anti-pattern:** Dispatching test + impl in the same wave; merging on "tests pass" without reading function bodies.

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
**Prereqs/side-effects:** Standalone `cd` to project root before merge; double `--force` worktree removal; continue a returned agent via SendMessage instead of re-dispatching.
**Anti-pattern:** Merging without the /scrutinize gate on impl waves; leaving stale worktrees between waves (nesting risk).

### /pulse
**Job:** One tick of a self-driving project — scheduled command lands in a durable tmux session, routes against refs/pulse.md, does at most ONE unit of work with full discipline, offboards, ends.
**Fire when:** "/pulse tick" arrives (timer-injected or typed); "/pulse setup" to opt a project in; "/pulse status" to report. NEVER self-loop — the systemd timer is the loop.
**Prereqs/side-effects:** refs/pulse.md routing table (Andrew's steering wheel — ticks never edit it); appends refs/pulse-ledger.jsonl; per-project systemd units from agents/scheduler/templates/.
**Anti-pattern:** Blocking on AskUserQuestion in a tick — unstaffed sessions file a P1 `human:` bead + push notification and end the tick. Also: self-declaring `outcome:"done"` without proof — every `done` line needs a `proof` token (artifact|commit|scrutinize|cmd), **hook-enforced by pre-commit-checks.sh** (a done commit whose proof doesn't verify is blocked); else log blocked/quiet (the nodding loop). Structural review nudge every 5th done tick.

### /randomize
**Job:** Force real-entropy diversity — real randomness (seed → modulo → choice) for every discretionary creative decision, with a provenance block.
**Fire when:** Creative generation where the model would collapse to the modal answer. NOT for single-correct-answer tasks.
**Prereqs/side-effects:** openssl rand seed; arithmetic must be re-runnable by a reviewer; provenance block written BEFORE prose.
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

### /scrutinize
**Job:** Adversarial read-only gate after an impl wave — disprove "done": stub bodies, mock-the-unit tests, unverified criteria, composition gaps.
**Fire when:** After every impl-wave merge, before merge-to-main / bead close. Skip only for atomic mechanical changes.
**Prereqs/side-effects:** Panel mode (default for substantial waves): saved workflow scrutinize-panel.workflow.mjs — 5 parallel hunt lenses + per-finding refuters. Single-agent mode for small waves (general-purpose/Explore, never worktree). Verdict SHIP / FIX-FIRST / REJECT recorded on the impl bead (hook-enforced for close). For user-facing surfaces: EXECUTE & OBSERVE (run/Playwright-click/inspect real output), don't certify by reading. Structural separation (fresh agent) is the primary mechanism; different-model is a supplementary lever.
**Anti-pattern:** Skipping because the report looked clean — that's exactly when the gate earns its keep; inventing findings ("found nothing" is valid). Certifying a user-facing change by reading code instead of running it.

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
