# Handoff from /cfp

How `/talk` picks up from `/cfp`'s handoff. The CFP project ended at
acceptance + cross-link; the talk project starts here.

`/cfp`'s handoff checklist is at `~/.claude/skills/cfp/reference/handoff-checklist.md`.
Read that first; it tells you what `/cfp` left behind. This document
is the mirror — what `/talk` does on day one to pick up cold.

---

## What `~/cfp/<slug>/` should provide

Per `/cfp`'s handoff:

- [ ] **CLAUDE.md is mineable** — locked decisions complete, audience
      profile clear, thesis explicit
- [ ] **`refs/` is verbatim** — CFP form, conference theme docs,
      acceptance email, reviewer comments (if any), prep emails
- [ ] **`research/angle-options.md`** shows the 3-5 framings considered
      and which one won
- [ ] **`proposal.md` (or `paper/main.pdf`)** preserves the as-accepted
      version
- [ ] **`<conf>-submitted` tag** marks the as-submitted commit
- [ ] **Beads honest** — `br ready` returns zero or only post-acceptance
      follow-ups; no orphans; `.beads/issues.jsonl` committed
- [ ] **Logistics noted** — registration confirmed, travel arrangements
      noted, in-person policy confirmed in writing

If any of these are missing, **fix the CFP repo first.** The talk
project depends on the CFP repo as source-material-to-mine via paths;
gaps in the CFP repo become gaps in the talk's spec.

---

## Step-by-step pickup

### 1. Read the CFP repo cold

```bash
cd ~/cfp/<slug>
cat CLAUDE.md
ls refs/
br list                                  # CFP-side bead state
git tag                                  # confirm <conf>-submitted exists
```

Spend 60 seconds reading CLAUDE.md cold. Could you build the talk from
this without asking the user clarifying questions about the *thesis*,
*audience*, or *trajectory*? If yes, proceed. If no, the CFP repo
needs more before the talk starts.

### 2. Bootstrap `~/cfp/talk-<slug>/`

Per `/talk`'s Step 1:

```bash
SLUG="<same-as-cfp-slug>"
mkdir -p ~/cfp/talk-$SLUG && cd ~/cfp/talk-$SLUG
git init
br init                                  # UNCONDITIONAL
mkdir refs deck gamma

cat > .gitignore <<'EOF'
.beads/.br_history/
.env.local
EOF

cp ~/.claude/skills/talk/reference/claude-md-template.md CLAUDE.md
# Edit placeholders per the upstream CFP repo's locked-decisions table
```

### 3. Cross-link via `## Source material to mine`

The talk repo's CLAUDE.md has a `## Source material to mine` table.
This is where the CFP repo gets cited — **via paths, not copies**.

```markdown
## Source material to mine

| Source | Why it matters |
|---|---|
| `refs/<conf>-page.md` | Verbatim public talk metadata |
| `refs/final-prep-email.md` | Locked logistics |
| `refs/screening-call-<host>.md` | Trajectory framing |
| `../<slug>/proposal.md` | UPSTREAM — the as-accepted proposal |
| `../<slug>/refs/` | UPSTREAM — full verbatim CFP refs |
| `../<slug>/research/angle-options.md` | UPSTREAM — angle decision history |
| `../<slug>/.beads/issues.jsonl` | UPSTREAM — full bead trail of CFP work |
| `../<closest-talk-neighbor>/` | Closest talk-shape neighbor (visual arc patterns) |
| `../<methodology-paper>/` | Backing peer-reviewed paper for any quantitative claim |
```

**Don't copy refs from the CFP repo to the talk repo.** The CFP repo
is the verbatim source-of-truth. The talk repo points at it.

### 4. Capture talk-specific verbatim refs

The talk-specific refs that `/cfp` didn't capture:

| Ref | Where it comes from | Why |
|---|---|---|
| `refs/<conf>-page.md` | The public talk page (URL on the conference site) | Title, abstract, track, dates, format the page surfaces |
| `refs/final-prep-email.md` | The organizer's pre-event email (subject usually "Final Prep" or similar) | Locked runtime, slide format, A/V, Q&A format, upload mechanism |
| `refs/screening-call-<host>.md` | The screening-call transcript (Granola / Otter / human-typed) | Trajectory framing committed verbally |
| `refs/talk-beats.md` (optional) | Borrowed narrative scaffolding from another project | Hidden structural metaphor (Magic School Bus episode shape, hero's journey, etc.) |
| `refs/<aesthetic>/` (optional) | Curated reference image set | Image-to-image inputs for nano-banana fusion |

These are what differ between the CFP and the talk — the CFP captured
the form / abstract / theme docs; the talk captures the post-acceptance
logistics + verbal commitments + aesthetic sources.

### 5. Cross-link back from the CFP repo

Add to `~/cfp/<slug>/CLAUDE.md`'s `## See also` section:

```markdown
## See also

- ...existing entries...
- `../talk-<slug>/` — DOWNSTREAM talk-build project (`/talk`'s scope)
```

Drop a typed `note` bead in the CFP repo:

```bash
cd ~/cfp/<slug>
br create -t note -p 3 "handoff: /talk picked up at ~/cfp/talk-<slug>/ on $(date +%Y-%m-%d)"
br update <id> --description "Talk-build project bootstrapped at ~/cfp/talk-<slug>/. \
This CFP repo is now mineable historical state — verbatim refs, angle \
decision history, as-accepted proposal. Cross-link added to CLAUDE.md."
```

This bead is permanent in the CFP repo (never closed) and marks the
moment the project transitioned from CFP-phase to talk-phase.

### 6. Initial commit on the talk repo

```bash
cd ~/cfp/talk-<slug>
git add CLAUDE.md .gitignore .beads/ refs/
git commit -m ":seedling: bootstrap: new talk project picking up from /cfp's handoff"
```

### 7. Run Step 2 — Discover constraints

The CFP repo gave us the abstract, the angle, the locked decisions.
Now go capture the talk-specific constraints (runtime, A/V, Q&A
format, recording venue, Asana hub gid). See `/talk`'s Step 2.

### 8. Lock the talk spec

Talk spec ≠ CFP spec. Even if the CFP had a `-t spec` bead with the
proposal's spec, the **talk** spec is its own bead — the talk has
beat-by-beat timing, runtime budget, slide doctrine, visual arc
choices the CFP didn't have.

Cite the CFP's spec bead in the talk spec's Section 2 (Baseline) — but
don't copy. The talk spec evolves on its own track.

---

## What changes between CFP and talk

The CFP and the talk are different deliverables. The handoff respects
that.

| Dimension | CFP | Talk |
|---|---|---|
| Deliverable | proposal.md OR paper/main.pdf | deck + script + image narrative + day-of artifacts |
| Hard limits | char counts on form fields | runtime + slide aspect + final-deliverable format |
| Critic loop | naive student / cold reader / voice — read-only | dry-run clock + flag + voice audit (different shape) |
| Iteration cost | text edits are free | image generation costs Gamma credits per fire |
| Source of truth | the CFP form + acceptance email | the prep email + screening call + Asana planning hub |
| End state | accepted, registered, proceedings-included | deck uploaded to organizer, dry-run-validated, day-of locked |
| Downstream | `/talk` | delivery (human) → `/zig-voice` (post-talk content) |

The CFP repo is **mineable historical state** for the talk. The talk
repo is **active execution state** through delivery. After delivery,
both become mineable for the next neighbor.

---

## Common pitfalls at handoff

- ❌ **Copying refs into the talk repo.** Don't. The CFP repo is the
  source-of-truth; the talk repo points at it. Copies drift.
- ❌ **Treating the CFP's spec as the talk's spec.** The talk has its
  own spec — beat-by-beat timing, slide doctrine, visual arc choices.
  Cite, don't copy.
- ❌ **Skipping the screening-call transcript.** Even if `/cfp`
  captured the acceptance email, the screening call is talk-specific
  (verbal commitments + format choices). Capture it in the talk repo.
- ❌ **Forgetting to cross-link.** The CFP repo's `## See also` should
  add `../talk-<slug>/`; the talk repo's `## Source material to mine`
  should reference `../<slug>/`. Both directions.
- ❌ **Not dropping the handoff note bead in the CFP repo.** The bead
  is permanent — the project's transition moment.
- ❌ **Bootstrapping the talk repo without `br init`.** Beads is
  load-bearing in `/talk`. `br init` runs unconditionally at Step 1.
- ❌ **Resuming the CFP's beads instead of starting fresh in the talk
  repo.** Each project has its own `.beads/`. The CFP's beads stay in
  the CFP repo; the talk's beads start fresh.

---

## When there's no `/cfp` repo to mine

Sometimes the user comes to `/talk` mid-stream — accepted talk that
wasn't `/cfp`'d. In that case:

1. **Skip the upstream cross-link** — there's no `~/cfp/<slug>/` to
   point at
2. **Capture the abstract verbatim from the public talk page** —
   that's the de-facto baseline since there's no proposal.md
3. **Capture the screening call + prep email + Asana hub** — same as
   any `/talk` Step 2
4. **Lock the talk spec from the public-page abstract** —
   Section 2 (Baseline) cites the page directly instead of an upstream
   proposal

The pipeline is the same; the source-material-to-mine table just has
fewer rows. Future `/cfp`-then-`/talk` runs of the same author at the
same conference will benefit from the talk repo as historical state
even if the CFP wasn't tracked at acceptance time.
