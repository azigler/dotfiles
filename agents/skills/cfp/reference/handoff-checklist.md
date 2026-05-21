# /cfp → /talk handoff checklist

When the CFP is accepted, the project is about to switch from "first half"
(submission) to "second half" (talk delivery). This checklist verifies the
CFP repo is in a state that the `/talk` skill can pick up cold.

Run this BEFORE creating the `~/cfp/talk-<slug>/` neighbor. If anything fails,
fix it inside the CFP repo first.

## CLAUDE.md is mineable

- [ ] `## Locked decisions` table is fully populated (no `TBD`s)
- [ ] `## What this proposal teaches / argues` reads clearly cold —
      thesis, framing, audience promise are explicit
- [ ] `## Credibility stack` lists the receipts (papers, awards,
      products) that backed the submission
- [ ] `## Author bio anchor` captures the bio framing decision (NOT
      just the bio text — the *reasoning* for that bio shape)
- [ ] `## Project layout` matches the actual on-disk layout
- [ ] `## See also` includes any sister CFPs and the upcoming
      `talk-<slug>/` cross-link

## refs/ is verbatim

- [ ] CFP form (binary + markdown rendering) present
- [ ] Conference theme / track / judging-criteria docs present
- [ ] Acceptance email captured (not paraphrased — verbatim)
- [ ] Reviewer comments captured verbatim (each in its own typed
      `note` bead OR in `refs/reviewer-comments.md`)
- [ ] Any post-acceptance organizer emails (camera-ready instructions,
      virtual-presentation policies, ORCID requirements)
- [ ] `refs/INDEX.md` exists if `refs/` has more than 10 files

## research/ is honest

- [ ] `research/angle-options.md` shows the 3–5 framings considered
      AND which one won — the talk will benefit from knowing why
      this angle beat the others
- [ ] Any conference-specific analysis (`research/<conf>-cfp-analysis.md`)
      is present and current

## Deliverable is preserved

For Shape A (proposal):
- [ ] `proposal.md` reflects the version actually submitted
- [ ] Char counts on every long field (`<!-- N / LIMIT -->`)
- [ ] Tag `<conf>-submitted` on the as-submitted commit
- [ ] Tag `<conf>-camera-ready` on the final accepted version (if a
      revision cycle happened)

For Shape B (paper):
- [ ] `paper/main.pdf` is the final-final accepted version
- [ ] No `[TBD]` strings in the PDF (`pdftotext paper/main.pdf - | grep -i TBD`)
- [ ] DOIs (Zenodo / ACM ICPS / arXiv) populated where issued
- [ ] `paper/main.tex` builds cleanly from a fresh checkout
- [ ] `artifact/` bundle (if Open Science venue) is published with a live DOI
- [ ] arXiv ID is captured (or marked as deferred)
- [ ] Class files shipped in repo (`acmart.cls`, `*.bst`)

## Beads are honest

- [ ] All in-flight beads are either closed or explicitly deferred
- [ ] `br ready` returns either zero items or only post-acceptance follow-ups
- [ ] Spec bead carries the full revision history in `--notes`
- [ ] No orphan beads (`br orphans` → empty)
- [ ] `.beads/issues.jsonl` is committed and pushed

## Logistics noted

- [ ] Conference registration confirmed (receipt in repo or in the
      human checklist bead)
- [ ] Travel / accommodation arrangements noted if relevant
- [ ] Visa requirements noted for non-domestic authors
- [ ] In-person vs. virtual presentation policy confirmed in writing
- [ ] Any organizer-side preferences noted (track host name + contact,
      stage tech, format constraints)

## Cross-link

- [ ] `~/cfp/talk-<slug>/` directory created
- [ ] Talk repo's `CLAUDE.md` has a `## Source material to mine` table
      pointing back at `../<slug>/` paths (NOT copies)
- [ ] CFP repo's `## See also` adds `../talk-<slug>/`
- [ ] A `note`-typed bead in the CFP repo records the handoff:
      "Handoff to /talk on YYYY-MM-DD; talk repo at ~/cfp/talk-<slug>/"

## Final sanity

- [ ] Read CLAUDE.md cold for 60 seconds. Could a fresh agent build
      a 35-minute talk from this without asking the user clarifying
      questions about the *thesis*, *audience*, or *trajectory*?
      If yes → ship the handoff. If no → fix the gaps in the CFP
      repo, then re-run this checklist.

The handoff is what /cfp's last commit looks like. After this, the project
is mineable historical state — /talk picks up from `~/cfp/talk-<slug>/`
and references the CFP repo via path.
