# Audit A — the always-loaded tier

Bead `dotfiles-499d`. Read-only. Every number below is from a command in this file.

---

## 1. Headline numbers

| File | Loaded when | Now | Cut | Keep | % cut |
|---|---|---|---|---|---|
| `/home/ubuntu/dotfiles/agents/AGENTS.md` | every session, every project | **5,525** | **3,640** | 1,885 | 66% |
| `/home/ubuntu/dotfiles/CLAUDE.md` | every dotfiles session | **782** | **150** | 632 | 19% |
| `/home/ubuntu/dotfiles/agents/skills/TOOLKIT.md` | every `/onboard` | **4,748** | **2,000** | 2,748 | 42% |
| `~/.claude/projects/-home-ubuntu-dotfiles/memory/MEMORY.md` | every session (index only) | **504** | **120** | 384 | 24% |
| — its 17 `feedback_*.md` bodies | **on demand only, not auto-loaded** | 5,458 | 0 | 5,458 | n/a |

**Total always-loaded now: 11,559 words. Proposed: 5,649 (−51%).**

**The growth curve** (`git cat-file -p "<sha>:agents/AGENTS.md" | wc -w`):

```
2026-05-21  1,194     2026-07-08  3,045     2026-07-27  4,919
2026-06-09  1,483     2026-07-13  3,356     2026-08-01  5,525
2026-06-28  2,252     2026-07-25  3,672
```

**4.6× in 72 days, monotonic — no commit in the file's history ever made it smaller.** That is the finding behind every finding below: the tier has an accrual mechanism and no drain.

### The empirical duplication result (the question you asked for evidence on)

Claude Code injects **every skill's frontmatter into the system prompt automatically**. Measured: **3,558 words across 37 skills** (`agents/skills/*/SKILL.md` frontmatter blocks). I can see all 36 non-path-triggered ones in my own system prompt right now.

AGENTS.md L501–552 re-lists **31 of those same skills in 750 words** — describing content already present at **2,793 words of fidelity**. The restatement is strictly *lower* resolution than the copy that arrives free.

It is also **wrong in both directions**:

- **Lists a skill that does not exist:** `/bd-to-br-migration` (L532). `find ~/.claude/skills dotfiles/agents/skills -maxdepth 1 -name '*bd-to-br*'` → nothing.
- **Omits 6 skills that do exist and that AGENTS.md itself repeatedly invokes by name:** `/pulse`, `/scrutinize`, `/research`, `/talk`, `/gamma`, `/openrouter`. `/scrutinize` is named 5× in the body and appears in no list.

A hand-maintained index of an auto-injected list has drifted in the only two ways an index can. `TOOLKIT.md`, by contrast, covers all 37 with zero misses — so the AGENTS.md listing is not even the accurate copy.

**`dotfiles/CLAUDE.md` vs `AGENTS.md` overlap:** one rule is stated in both — the stderr rule (AGENTS.md L210–225, 127w; CLAUDE.md rule 3, 30w) — and *also* enforced by `pre-bash-stderr-guard.sh` (wired PreToolUse in `~/.claude/settings.json`). Triple statement, hook-backed. Otherwise CLAUDE.md is clean: it is almost entirely LOCAL-FACT about this repo.

---

## 2. Findings table (ordered by words saved)

| Location | Words | Class | Verdict | Rationale |
|---|---|---|---|---|
| AGENTS.md L363–471 "Delegation" | 945 | REDUNDANT | **CUT → 90** | The merge/cleanup bash block, `--force --force`, and the cross-repo warning are duplicated in `orchestrator/SKILL.md` L79–93 + `dispatch/SKILL.md`. `/orchestrator`'s own frontmatter already says "read the body before the session's first dispatch." |
| AGENTS.md L42–140 "Effort" | 847 | STALE + MODEL-SCAFFOLD | **COMPRESS → 130** | 4 of 6 sub-blocks are argument for a decision already made. Keep only the 400-error fact + the "Workflow is the only lever" fact. |
| AGENTS.md L501–552 "Global skills" | 750 | REDUNDANT + STALE | **CUT → 45** | Lower-fidelity restatement of 2,793w of auto-injected frontmatter; lists a dead skill, omits 6 live ones. |
| AGENTS.md L283–330 "Surfacing to Zig" | 508 | REDUNDANT (hook) | **COMPRESS → 150** | L303–314 (149w) is verbatim the text `post-push-fallback.sh` L25 injects *at the exact moment it applies*. Prose copy fires 100% of sessions for a 0.1% event. |
| AGENTS.md L164–209 "Verification" | 411 | SCAR-TISSUE | **COMPRESS → 60** | One commit (`e7b7aba`, 2026-07-27) — a *meta-argument about a prompt edit already applied*. The operative rule is 2 sentences; 350w is the defense of it. |
| AGENTS.md L226–261 "Two writers" | 348 | REDUNDANT (hook) | **COMPRESS → 45** | `pre-shared-tree-guard.sh` contains the same measured table in its header AND blocks the destructive verbs AND emits the merge-not-rebase guidance at block time (L271). Commit `1f23c02`: "make the hazard *unreachable*." |
| TOOLKIT.md — 20 short entries | ~1,347 | REDUNDANT | **COMPRESS → ~500** | For 20 of 37 skills the TOOLKIT entry is *smaller* than the frontmatter already in the system prompt (e.g. `cfp` 56 vs 151; `gamma` 51 vs 114; `nginx` 48 vs 73). Only the Anti-pattern line is additive. |
| AGENTS.md L141–163 "four loop costs" | 270 | MODEL-SCAFFOLD | **CUT → 0 (TEST)** | Cited to an external paper, not an incident. `git log -S "four loop costs"` → one commit, `fee4bc8`. The ritual ("periodically explain 2–3 loop outputs") has no trigger, no owner, no proof — unfireable as written. |
| AGENTS.md L331–362 "decide-and-proceed" | 269 | CTX-SCARCITY (partly) | **COMPRESS → 70** | The `br create -t decision` template is 8 lines; the other 180w argues *why*. `/offboard` already harvests these. |
| AGENTS.md L365–379 "3 delegation tendencies" | 236 | MODEL-SCAFFOLD | **CUT → 0 (TEST)** | Instructions telling the model to be less eager. Exactly the class Anthropic's guide says can degrade output. Same commit as the section that says to strip that class. |
| AGENTS.md L577–608 "Reference conventions" | 236 | LOCAL-FACT + STALE | **COMPRESS → 90** | The `refs/`/`specs/`/`docs/`/beads mapping is irreducible. The deprecation notice for `.claude/refs`/`.claude/plans`/`PLAN.md` and the project-specific-skills list are cold storage. |
| AGENTS.md L262–282 "Secrets" | 198 | LOCAL-FACT | **COMPRESS → 60** | The rule is real and the `~/.secrets` pointer is a local fact. But it names the wrong path: L279 says `~/explore/.claude/skills/scrub-secrets/` — that dir **does not exist**; it graduated to `~/.claude/skills/scrub-secrets` (commit `5b7d8cf`, 2026-07-08 — same day, never updated). |
| AGENTS.md L553–576 "Skill libraries" | 170 | LOCAL-FACT | **COMPRESS → 55** | `~/explore/.claude/skills/INDEX.md` exists and is a genuine pointer. The graduation-policy paragraph is process narration. |
| AGENTS.md L25–41 "At session start" | 122 | LOCAL-FACT | **COMPRESS → 45** | Keep "run /onboard", "read agents/infra.md for infra work". Cut the justification of the TOOLKIT design. |
| AGENTS.md L5–16 "The user — Zig" | 105 | LOCAL-FACT | **KEEP** | Irreducible. No model knows he's on SSH+tmux or that markdown links don't render. |
| AGENTS.md L210–225 "stderr" | 127 | REDUNDANT (hook) | **COMPRESS → 35** | Hook-enforced + restated in `CLAUDE.md` rule 3. Keep the `# allow-suppress` escape hatch, which is a local fact. |
| AGENTS.md L472–483 "Worktree beads symlink" | 83 | LOCAL-FACT | **COMPRESS → 25** | Verified real (`session-start.sh`). But it ends "No manual setup required" — a section whose payload is "nothing for you to do." |
| AGENTS.md L484–500 "Beads lifecycle" | 71 | REDUNDANT | **COMPRESS → 30** | `beads/SKILL.md` frontmatter already in system prompt: "Orchestrator creates and closes beads; subagents claim and reference them." |
| AGENTS.md L17–24 "Subagent rule" | 51 | REDUNDANT (structural) | **COMPRESS → 18** | `~/.claude/agents/subagent.md` grants `tools: Read, Write, Edit, Glob, Grep, Bash` — **no Agent tool**. Also Hard Rule 4 in that same file. Prose only matters for built-in types, which do get Agent. |
| MEMORY.md — 5 dead-substrate entries | ~120 | STALE | **CUT** | `~/hermes` and `~/autonovel` do not exist on disk. |

---

## 3. Top 10 cuts by leverage

**1 — Delete AGENTS.md L411–470 (the merge/cleanup bash block + its three explanatory paragraphs). −444w.**
Replace with:
> After a worktree subagent finishes: merge, close the bead, commit `.beads/issues.jsonl`, remove the worktree. The exact sequence, with its guards, is in `/orchestrator` — run it, don't retype it.

Evidence it's a duplicate: `grep -n "merge-base --is-ancestor\|force --force" agents/skills/orchestrator/SKILL.md` → L79, L93, L437.

**2 — Delete the AGENTS.md skill listing, L501–552. −705w.**
Replace with:
> Global skills live in `~/.claude/skills/` (symlinked from `dotfiles/agents/skills/`). Their descriptions are already in your system prompt; `TOOLKIT.md` carries each one's anti-patterns. Project-scoped sets are documented in their own project's CLAUDE.md.

This also *fixes* the two defects: no hand-maintained list, nothing to drift.

**3 — Collapse "Effort" L42–140 to L93–116's fact plus one policy line. −717w.**
Keep, verbatim in spirit:
> **Effort is per-dispatch, never a session setting.** Session stays `high` (the Opus 5 vendor default; `effortLevel` is absent from every settings file). Escalate one step via a Workflow `agent(…, {effort:'xhigh'|'max'})` — the plain `Agent` tool has no effort parameter. ⚠️ **Opus 5 returns 400 on `xhigh`/`max` when thinking is disabled, and Claude Code disables thinking on the WebSearch path** — a session pinned above `high` has no working web search, and in a scheduled loop that failure is silent (the tick answers from weights and logs `done`).

Cut: the vendor-quote block (L71–83), the "re-run the sweep" meditation (L85–91), the levers section's rationale, the naming norm. The 400 is the only irreducible local fact in 847 words.

**4 — Cut "The four loop costs" + the cognitive-surrender ritual, L141–163. −270w.** No originating incident: `git log -S "four loop costs" -- agents/AGENTS.md` returns exactly `fee4bc8` (2026-06-28), sourced to a paper, not a failure. Per your rule, **strip candidate by default**. Flag for A/B (§4).

**5 — Cut "Opus 5's three delegation tendencies", L365–379. −236w.** It is a table of "be less eager" instructions, added by `e7b7aba` — the *same commit* that deleted per-task self-checking on the grounds that that class degrades output. Flag for A/B.

**6 — Collapse "Verification" L164–209 to two sentences. −351w.**
> Never ask an agent to double-check its own work mid-task. **Do** require evidence at every checkpoint — a command run, a number re-derived, a target re-read. Adversarial review is a *different* agent (`/scrutinize`), and it stays.

The 411w version is a defense of a decision already shipped; the provenance belongs on bead `explore-8hs7`, where it already is.

**7 — Collapse "Two writers" L226–261 to −303w.**
> Another writer (a `/pulse` tick) can enter your checkout on a timer. To absorb a moved remote: `git fetch origin && git merge --no-edit origin/main`. Never `stash` / `reset --hard` / `checkout .` / `clean -fd` unscoped, and never enable `rebase.autoStash`. `pre-shared-tree-guard.sh` blocks these while another writer is provably mid-run.

The measured table lives in the hook header (`agents/hooks/pre-shared-tree-guard.sh` L18–25) and the guidance is emitted at block time (L271).

**8 — Cut the push-fallback paragraph, L303–314. −149w.** `agents/hooks/post-push-fallback.sh` L20–25 greps for `Remote Control inactive` and injects the identical instruction as `additionalContext` at exactly the moment it applies. Keep one clause: "if a PushNotification reports *Remote Control inactive*, it did not deliver — a hook will tell you what to do."

**9 — Fix and shrink the secrets section, L262–282, to −138w.** The rule stays; the path is wrong. Correct `~/explore/.claude/skills/scrub-secrets/` → `~/.claude/skills/scrub-secrets/` (verified: the `~/explore` path does not exist). This is a live instance of your own CLAUDE.md rule 2 — a documented example that is executable and wrong.

**10 — TOOLKIT: drop `**Job:**` and `**Fire when:**` from the 20 entries whose frontmatter is already longer. −~700w.** Measured field split across all 37 entries: Job 790w (17%), Fire-when 534w (12%), Prereqs 1,242w (28%), Anti-pattern 1,834w (41%). **Job + Fire-when = 1,324w and is a paraphrase of `description` + `when_to_use`, both already in the system prompt.** Anti-pattern and Prereqs are the file's actual reason to exist. Cutting the first two fields wholesale would save ~1,300w and lose nothing you don't already have — except for the ~8 long entries (`desk`, `daemon`, `pulse`, `dive`, `scrub-secrets`, `elevate`, `dream`, `commit`) where the Job line carries real architecture.

---

### TOOLKIT drift found (spot-check of 12 entries)

| Entry | Drift | Evidence |
|---|---|---|
| **`/commit`** | **Live contradiction with AGENTS.md.** TOOLKIT says "**`git pull --rebase` THEN push**"; `commit/SKILL.md` L15 says "Always pull --rebase, THEN push." AGENTS.md L247 says "`git fetch && git merge` — **NOT** `git pull --rebase`." Both are always-loaded/onboard-loaded. **Two global tiers give opposite git instructions for the same operation.** This is the single most consequential finding in the audit. | `grep -n "rebase" agents/skills/commit/SKILL.md` L15, L96 vs AGENTS.md L247 |
| **`/desk`** | Missing the newest mechanism. `refs/crosslink.md` became a Pass A input with an 8-day freshness gate on **2026-08-01** (commit `10358b6`); `desk/SKILL.md` L195, L713–722, L814 all carry it. The TOOLKIT entry (563w, the longest) never mentions `crosslink`. Drifted the same day it was regenerated. | `grep -n crosslink desk/SKILL.md` vs TOOLKIT L59–62 |
| `/scrutinize` | Says "saved workflow `scrutinize-panel.workflow.mjs`". `~/.claude/workflows/` does not exist; the file lives at `skills/scrutinize/scrutinize-panel.workflow.mjs`. Not wrong, but "saved workflow" implies a registry that isn't there. | `ls ~/.claude/workflows` → no such dir |
| `/gdoc` | Cites `bd-3w8a` — the pre-migration bead prefix. Unresolvable via `br show`. Cosmetic. | `grep -n bd-3w8a gdoc/SKILL.md` |
| `/triage`, `/beads`, `/onboard`, `/offboard`, `/dispatch`, `/lint`, `/fix`, `/grok` | **No drift.** `br ready > 30` nudge confirmed at `post-orchestrator-action.sh` L39–40; `br sync --flush-only` confirmed at `beads/SKILL.md` L27; TOOLKIT read-in-main-session confirmed at `onboard/SKILL.md` L109, L135. | as cited |

Coverage is clean: TOOLKIT has exactly 37 entries for exactly 37 skill dirs, no misses, no orphans.

**Does the 2026-06-09 rationale still hold?** Partly, and the surviving half is not the one written down. The stated reason — "~3k tokens vs ~80k measured" — is the CTX-SCARCITY half, and under 1M it is weak. But `bead dotfiles-q702` names the nuance explicitly ("do not relax a rule just because one of its two justifications expired"), and TOOLKIT has a second justification its header never states: **41% of its words are Anti-patterns, which are not in the frontmatter and not in the system prompt.** That content is the asset. **Verdict: keep TOOLKIT, rewrite it as an anti-pattern digest, drop the Job/Fire-when fields, and rewrite the header's stated WHY** — it currently defends the file on the one ground that expired.

### Memory tier

Only `MEMORY.md` (504w, an index of links) is auto-loaded — the 17 `feedback_*.md` bodies (5,458w) are **not** in context; they load on demand. So the memory tier is already cheap and is *not* a priority target.

Of its 17 entries: **12 are still true and not hook-enforced** (keep). **5 are about dead substrates** — `~/hermes` and `~/autonovel` do not exist on disk (`ls -d` → no such file): `substrate_kill_criterion`, `pattern_n_means_substrate_wrong`, `silent_fabrication_disqualifying`, `sidestep_is_not_validation`, `tabula_rasa_cross_arc_convergence`. Their *lessons* are transferable; their *examples* are archaeology. Compress the five index lines to one: "Substrate discipline (Hermes/autonovel post-mortems, 2026-05/06) — name the kill criterion first; 3+ named patterns on one substrate means the substrate is wrong; silent success-shaped output on an error path is disqualifying." **−~120w, five files stay on disk.**
One entry is already hook-enforced and the prose says so: `scrutinize_inline_fixes` describes `pre-bead-close.sh`'s behavior accurately (verified L13–14) — keep, it names the gap the hook *doesn't* cover.

---

## 4. The empirical test list — cuts I am NOT confident about

Each row: the cut, the failure it guards against, and what an A/B would look for in an unprompted Opus 5.

| # | Cut | The failure it guards | Test |
|---|---|---|---|
| T1 | "Four loop costs" (270w) | Orchestrator stops noticing that output nobody reads is a cost; ships volume. | Give an unprompted Opus 5 a week of loop output + "what should I worry about?" Does it name comprehension rot / unverified accumulation on its own? |
| T2 | "Three delegation tendencies" (236w) | The named Opus 5 defaults: 6 agents where 2 would do; scope creep; 900-line files for 40-line asks. | Dispatch-planning task with no caps. Count agents spawned, out-of-scope files touched, output length vs ask. **This is the one I'd test first** — it's the only MODEL-SCAFFOLD block whose guarded failure is vendor-documented as a *real Opus 5 behavior*, which makes it the least obviously safe to cut. |
| T3 | "Verification" → 2 sentences (−351w) | Checkpoints stop carrying evidence; `done` becomes self-report. | Subagent task with an implicit verification need. Does the report contain a run command / re-derived number without being asked? |
| T4 | AGENTS.md skill listing (−705w) | Model doesn't reach for `/desk`, `/dive`, `/elevate` because the frontmatter is terser than the prose. | 10 prompts that should trigger a skill. Compare invocation rate with/without the listing. **Low risk** — frontmatter is 3.7× longer than the listing, and 6 skills already have no listing and still fire. |
| T5 | Push-fallback paragraph (−149w) | An "inactive" push gets treated as delivered; Zig never sees the question. | Fire a push that returns the marker with the paragraph removed. Does the hook's `additionalContext` alone produce the AskUserQuestion fallback? (Hook text is a superset of the prose — expected pass, but it's a Zig-visible failure, so verify.) |
| T6 | "Two writers" → 45w (−303w) | Reflex `git stash` under a second writer — the one destructive verb. | Only outside the hook's window. Construct a dirty tree + moved remote with no other writer running, and see whether the model reaches for stash. |

Not on this list because I'm confident: the Delegation bash block (duplicated verbatim in a skill), the Effort compression (the surviving text keeps the only unguessable fact), the secrets path fix (a straight correction), TOOLKIT Job/Fire-when removal (strictly dominated by frontmatter).

---

## 5. What I would NOT touch

- **`## The user — Zig` (105w).** Pure LOCAL-FACT. SSH+tmux, no rendered links, no inline images, "Zig" not "Andrew", commit-and-push-as-you-go. No model derives any of this. If anything it should be *first* in the file, which it is.
- **The Opus 5 400-error paragraph** (the ~60 load-bearing words of L93–116). An API behavior that changed under this fleet, with a silent-failure mode in scheduled loops. Irreducible.
- **`agents/infra.md` pointer** (L36–38). One line, high value, correctly conditional.
- **All of `dotfiles/CLAUDE.md` rules 1, 2, 5, 6.** Rule 6 (`$0`/`$N` skill-arg substitution, verified against `claude` 2.1.220) is the best single paragraph in the entire tier — a harness quirk that is invisible to grep, invisible to review, and cost `/desk` 99.9% of its corpus. Rule 1's `git config core.hooksPath tools/githooks` is a per-clone fact nothing else records. Rule 2 (a documented example is executable) is *why* this audit found real bugs. Keep verbatim.
- **The stale-snapshot warning** at CLAUDE.md L6–20. It is the single most important thing to know before editing this tier, and it explains why a cut takes days to take effect in the pulse windows.
- **TOOLKIT's Anti-pattern lines (1,834w, 41%).** Nothing else in the harness carries them. This is the file's whole justification and it should get *longer* relative to the rest, not shorter.
- **The 12 live memory entries.** Cheap (index-only), and several encode things a hook can't: "read transcripts before guessing", "long jobs to log files", "preserve process artifacts".
- **`## Beads` in CLAUDE.md.** Four lines, names the prefix and the live epic. Irreducible local fact.

The honest summary of the shape: **almost nothing in this tier is wrong, and about half of it is somewhere else already** — in a hook that fires at the right moment, in a skill body one call away, or in frontmatter the system prompt injects for free. The cut list is dominated by *relocation*, not deletion. The two things that are genuinely wrong — the `/commit` rebase-vs-merge contradiction and the dead `~/explore/.claude/skills/scrub-secrets/` path — were both found by checking claims against disk, not by reading for bloat.
