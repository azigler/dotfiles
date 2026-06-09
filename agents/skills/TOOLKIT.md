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

### /cost-tracking
**Job:** Per-session inference-only cost ledger from session JSONL (sidechains filtered).
**Fire when:** User asks about spend; auto via /offboard if refs/cost-tracking.md exists (legacy .claude/plans path honored).
**Prereqs/side-effects:** Bootstrap ledger once; rows appended by /offboard; verify the script's rate table covers the model actually run.
**Anti-pattern:** Trusting totals priced with a stale per-model rate table; counting cache infra in the headline cost.

### /dispatch
**Job:** Canonical subagent prompt template (bead ID, merge target, wave position, verification gates).
**Fire when:** Before every worktree-subagent dispatch; skip for built-in read-only types.
**Prereqs/side-effects:** No-nested-agents + path discipline are structurally enforced (subagent definition + hooks) — prompts carry task-specific content only.
**Anti-pattern:** Ambiguous merge target; dispatching code-writing work to built-in agent types (no Hard Rules, no hooks).

### /distribute
**Job:** Mirror dotfiles harness (skills, hooks, CLAUDE.md) into a coworker-shaped tree (default ~/linearb/skills).
**Fire when:** After editing any paragon skill / hook / CLAUDE.md.
**Prereqs/side-effects:** Runs zig-computer.distribute.sh; touches destination .claude/ + CLAUDE.md only; skips settings.json.
**Anti-pattern:** Adding destination-specific overrides to the dotfiles paragons; running from a subagent worktree.

### /explore
**Job:** Multi-source URL research → structured plaintext report into an Asana task; archival (~/explore/<topic>/) or publishing (Zig-voice post + SSoT image) shapes.
**Fire when:** Explicit-invoke; user hands over URLs + an Asana destination.
**Prereqs/side-effects:** Asana task GID; plaintext-only notes field; POST /update (PUT returns 405).
**Anti-pattern:** HTML in Asana fields; abstract image subjects (force specificity via SSoT).

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
**Anti-pattern:** Per-tab write with tabId (known-incomplete — use full-doc write via Drive HTML importer).

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
**Anti-pattern:** Deleting code without grepping for importers; doing design work under the housekeeping banner (mechanical-only).

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
**Prereqs/side-effects:** Overwrites refs/session-handoff.md (snapshot, not log); writes .claude/last-offboard-session so session-end.sh knows offboard ran; migrates legacy .claude/plans paths via git mv on first touch.
**Anti-pattern:** Skipping short sessions — a two-line honest note beats no note.

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

### /research
**Job:** Autonomous layered research harness — parallel research subagents, empirical verification, fold to canon, layer next questions.
**Fire when:** "Research X" / "stay autonomous"; proactively on operational blockers, new substrates, doubted findings.
**Prereqs/side-effects:** refs/research/ archive; findings verified empirically before becoming load-bearing; notifications for material results.
**Anti-pattern:** Letting an agent's unverified claim become a load-bearing assumption; quiet edits on reversed findings (use REVISED callouts).

### /scrutinize
**Job:** Adversarial read-only gate after an impl wave — disprove "done": stub bodies, mock-the-unit tests, unverified criteria, composition gaps.
**Fire when:** After every impl-wave merge, before merge-to-main / bead close. Skip only for atomic mechanical changes.
**Prereqs/side-effects:** Panel mode (default for substantial waves): saved workflow scrutinize-panel.workflow.mjs — 5 parallel hunt lenses + per-finding refuters. Single-agent mode for small waves (general-purpose/Explore, never worktree). Verdict SHIP / FIX-FIRST / REJECT recorded on the impl bead (hook-enforced for close).
**Anti-pattern:** Skipping because the report looked clean — that's exactly when the gate earns its keep; inventing findings ("found nothing" is valid).

### /spec
**Job:** Formal specification as a typed `spec` BEAD (not a file) — Overview/Baseline/Changes/Formal Spec/Test Cases/OQs/Future in --description.
**Fire when:** Defined work needs a spec before /check → /test → /impl.
**Prereqs/side-effects:** Creates -t spec bead; ≥10 test cases; optional Interrogator pass to surface OQs outside the author's blind spot.
**Anti-pattern:** Writing Section 6 without the Interrogator pass; creating spec FILES (specs/ folders are legacy-only).

### /ssot
**Job:** String Seed of Thought — real randomness (seed → modulo → choice) for every discretionary creative decision, with a provenance block.
**Fire when:** Creative generation where the model would collapse to the modal answer. NOT for single-correct-answer tasks.
**Prereqs/side-effects:** openssl rand seed; arithmetic must be re-runnable by a reviewer; provenance block written BEFORE prose.
**Anti-pattern:** Narrating "committed choices" without running the arithmetic — no provenance block means it wasn't SSoT.

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
