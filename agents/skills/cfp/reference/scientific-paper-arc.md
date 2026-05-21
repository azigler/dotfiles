# Scientific paper sub-arc — full how-to

This is the deep reference for the peer-reviewed-paper extension to `/cfp`'s post-acceptance flow. Triggers when the venue is academic (workshop / conference / journal with reviewer comments + camera-ready cycles + accepted-with-revisions outcomes).

The flagship worked example is `~/cfp/mise/` — *Mise en Place for Agentic Coding*, accepted at VibeX 2026 (EASE 2026, Glasgow). End-to-end walkthrough on a real paper: read its `CLAUDE.md`, `.beads/issues.jsonl`, and the `mp-9m1` spec bead before firing this sub-arc the first time.

The discipline matches the rest of `/cfp`: every step is bead-driven, drafts go through critic agents, decisions land in beads (not separate decision documents). The sub-arc adds steps; it doesn't change the methodology.

## When this sub-arc fires

The interview (Step 2 of `/cfp`) determines whether the venue is peer-reviewed. Concrete signals:

- Reviewer comments arrive with the acceptance / rejection (not just an accept/reject verdict)
- The venue requires a camera-ready cycle distinct from the original submission
- The venue is co-located with or part of an academic conference (ESEC/FSE, ICSE, EASE, FSE, OOPSLA, CHI, etc.)
- The venue's CFP names a publisher (ACM, IEEE, Springer LNCS) for the proceedings
- The venue has Open Science / artifact compliance language in its CFP

If any of these apply, this sub-arc lands on top of the universal post-acceptance flow.

## Prerequisites

Before the sub-arc fires, the universal post-acceptance steps (Step 8.1 – 8.4) should already be done:

- Acceptance email captured verbatim in `refs/acceptance-email.md`
- `<conf>-submitted` tag pushed
- Conference logistics tracked as typed `note` beads
- Registration logged as a typed `note` bead with the deadline in the title

The `paper/` directory should exist from the original bootstrap (Step 1) with the venue's class file (e.g., `acmart.cls`), `.bst`, `main.tex`, and section files.

## Phase 1 — Capture reviewer comments verbatim

Each reviewer's comments go into `refs/reviewer-comments.md` (one file, multi-reviewer) OR as separate typed `note` beads (one per reviewer). Verbatim source-of-truth — never paraphrase reviewer language.

The mise project used a single file with sections per reviewer. Either pattern works; pick one and stick with it.

## Phase 2 — Spec the revisions (`/spec`)

Fire `/spec` with the revision brief. The spec bead's `--description` carries:

- **Overview** — what venue, what acceptance, what's the revision target (camera-ready / minor revisions / accept-with-revisions)
- **Per-reviewer comment table** — Reviewer N said X, our response is Y, change at file Z. Every reviewer comment gets a row, even ones we're not actioning.
- **Compliance items** — open-science policy artifacts, format conversions, page-limit shifts, ORCID linking, copyright block requirements
- **Out-of-scope items** — what reviewers asked for that we are NOT going to do, with reasoning. ("Don't fake new empirical work" is a typical scope exclusion when a reviewer asks for comparative experiments the paper's timeline can't support.)
- **Test cases** — concrete grep-able tests for each revision item:
  - "Acronym MEP introduced on first use → `grep -n 'mise en place (MEP)' paper/sections/*.tex`"
  - "Bibliography has Brown 2020, Wei 2022, Liu 2023 → `grep -E '(brown2020|wei2022|liu2023)' paper/references.bib | wc -l`"
  - "PDF builds clean → `cd paper && latexmk -pdf main.tex 2>&1 | tail -3`"
  - "Page count ≤ N → `pdfinfo paper/main.pdf | grep Pages`"
  - "No `[TBD]` strings remain in PDF → `pdftotext paper/main.pdf - | grep -i TBD`"

The `mp-9m1` spec bead in `~/cfp/mise/.beads/issues.jsonl` is the worked example of this shape. It captured 14 test cases for the revision; every one was checked before merge.

## Phase 3 — Dispatch revision agents (worktree subagents)

Per `/orchestrator` and `/dispatch` discipline:

- One feature bead per major change (or one feature bead for the whole revision if scope is small — the mise project used `mp-8fr` for the paper revision and `mp-ok7` for the artifact bundle, parallel)
- Branch off a `camera-ready` (or similar) version branch — NOT main. The revisions land on the version branch; the version branch merges to main at the end as a single PR.
- Worktree subagents do the writing. They claim their bead, do the work, run the spec test cases, return a `/handoff` summary.
- Critic agents review the result before merge.
- Final PDF rebuild verifies all spec test cases pass.
- Open a PR `camera-ready → main` with the spec test results in the body.

The branch tag for the final post-revision state is `<conf>-camera-ready`, pushed after the merge.

## Phase 4 — Open-science artifact bundle

Many academic venues (ACM SIGSOFT, IEEE) require an Open Science compliance step. Build an `artifact/` directory at the project root:

```
artifact/
├── README.md                           description, dual-license, BibTeX, Zenodo upload steps
├── LICENSE-CC-BY-4.0                   for data + prose
├── LICENSE-MIT                         for code / configs / scaffolds
├── data/                               anonymized data files (timing, metrics, etc.)
├── prompts/  (or  code/)               agent contract, configs, planning corpus
└── agent-harness/                      portable docs of the methodology
```

The mise project's `artifact/` is the worked example.

### Anonymization discipline (read this before dispatching the agent)

When the artifact bundle anonymizes a file containing third-party PII (collaborator names, emails, LinkedIn URLs, Slack handles), the worktree subagent doing the anonymization can trip Anthropic's content filter — not on the file changes (those succeed) but on the **wrap-up summary message** the agent emits at the end. The filter blocks what looks like concentrated PII even when the agent is legitimately reporting "I anonymized the following entries: [list of names]."

To avoid this, instruct the agent explicitly in the dispatch prompt:

> *"In your final summary, do NOT recite names / emails / handles you redacted. Report counts only — say `N entries anonymized` instead of listing them. Don't inline full license texts in your summary either; use the file tool to write licenses, then report file size / line count."*

Without this, you'll see the agent's final message blocked by the filter, which is recoverable but annoying — the file changes are committed, just the summary is gone.

### Zenodo upload via GitHub integration

For a clean GitHub-Zenodo integration:

1. Write `.zenodo.json` at the repo root using the template at [`zenodo-json-template.json`](zenodo-json-template.json). This gives Zenodo clean metadata at release time (title, ORCID-attributed creator, keywords, CC-BY 4.0 license, dataset upload type).
2. Commit + push.
3. Owner enables https://zenodo.org/account/settings/github/ for the repo — toggle the switch ON.
4. Cut a GitHub release tagged `artifact-v1.0`:
   ```bash
   gh release create artifact-v1.0 \
     --target camera-ready \
     --title "Research artifact v1.0 — <PAPER_TITLE>" \
     --notes "<inventory + license + citation; see artifact/README.md>"
   ```
5. Zenodo auto-mints a DOI within ~10 minutes. Owner gets an email at the address tied to their GitHub-Zenodo integration.
6. Replace `[TBD]` placeholders in the paper's Artifact Availability section + the `artifact/README.md` BibTeX block with the live DOI. Rebuild the PDF.

### Watch out: paper PDF in the release tarball

GitHub releases include the entire repo at the tagged commit by default. If you cut the release BEFORE replacing `[TBD]` in the paper, the Zenodo-archived snapshot will include a draft PDF with `[TBD]` in the Artifact Availability subsection. This is mostly cosmetic — the canonical paper of record is the publisher's typeset version, and the Zenodo description can clarify — but it's worth noting the chain:

```
cut release → Zenodo mints DOI → update paper with real DOI → rebuild PDF
                                                                  ↑
                                                   the camera-ready PDF you upload
                                                   to EasyChair has the real DOI;
                                                   the Zenodo snapshot has [TBD]
```

If you want a clean Zenodo snapshot too, cut a v1.1 release after the DOI is back in the paper. Cosmetic; not blocking.

## Phase 5 — arXiv preprint

If the venue allows / encourages a preprint (most do; some require it for promotional purposes — VibeX 2026 explicitly asked for an arXiv URL via an MS form for social-media promotion):

### Endorsement (first-time submitters in cs.SE)

arXiv requires endorsement for first-time submitters in many categories including `cs.SE`. The endorser must have 3+ papers in that category in the last 5 years.

Path to endorsement:

1. Owner starts the arXiv submission; arXiv tells them they need endorsement
2. arXiv provides a unique endorsement code via email
3. Owner forwards the code to a colleague who qualifies (workshop chairs are often willing if they've asked you to upload to arXiv anyway; LinkedIn / academic network is the alternative)
4. Endorser visits `arxiv.org/auth/endorse?x=CODE` and approves
5. Owner is then cleared to submit; ID issues 1–3 business days after submission

**Endorsement is async and NOT a proceedings blocker.** The venue's hard deadlines are camera-ready upload + registration, not arXiv preprint. Don't let the endorsement loop block the camera-ready submission.

### Building the source tarball

arXiv strongly prefers source over PDF for archival, HTML conversion, and hyperref preservation. Full how-to at [`arxiv-tarball-build.md`](arxiv-tarball-build.md). Key points:

- Ship LaTeX source + pre-generated `.bbl` + class files + sections
- Exclude `.aux`, `.log`, `.fdb_latexmk`, `.fls`, `.out`, the compiled `.pdf`, hidden files
- Include the venue's class file (`acmart.cls`, `IEEEtran.cls`, etc.) to lock against TeX Live drift
- License: CC-BY 4.0 to match the artifact bundle and most open-access venues
- Primary category: `cs.SE` typically; cross-list `cs.AI`, `cs.HC` as appropriate
- Comments field: cite the venue + accepted status + Zenodo artifact DOI

### Common arXiv compile gotchas

| Symptom | Cause | Fix |
|---|---|---|
| BibTeX errors despite shipping `.bbl` | Stale `.bbl` from a different version | Rebuild `.bbl` from current `references.bib` and ship the fresh one |
| `acmart`-related "file not found" warnings | acmart references CC-license / journal logos statically | Informational; PDF still renders if `printacmref=false` is set |
| "Token not allowed in PDF string" hyperref warnings | Special chars (kerning, italics) in author names | Cosmetic; hyperref strips formatting from PDF metadata bookmarks |
| ORCID iD invisible | acmart's `\orcid{}` only links the author NAME — no visible icon | Load `\usepackage{orcidlink}` and use `\orcidlink{<id>}` next to the name. **Remove `\orcid{}` if you also want an inline visible href to the ID number** — they conflict because nested hrefs aren't allowed and the inner text gets stripped |
| `[TBD]` strings still in the PDF | Forgot to replace placeholders before final rebuild | `pdftotext paper/main.pdf - | grep -i TBD` is your final-final gate. Run after every rebuild. |

### Hyperlink audit before submission

To catch "linked but invisible" issues like the canonical ORCID rendering bug:

```bash
pip install --break-system-packages --user pypdf -q
python3 <<'EOF'
from pypdf import PdfReader
r = PdfReader('paper/main.pdf')
for i, page in enumerate(r.pages):
    if '/Annots' in page:
        for a in page['/Annots']:
            obj = a.get_object()
            if obj.get('/Subtype') == '/Link' and '/A' in obj:
                action = obj['/A'].get_object()
                if '/URI' in action:
                    print(f'page {i+1}: {action["/URI"]}')
EOF
```

This shows every clickable link in the PDF. Cross-reference with what's *visible* in the rendering (use `pdftoppm -r 200 -f 1 -l 1 -png paper/main.pdf /tmp/p1` and inspect). If a URL appears in the link list but doesn't appear visibly anywhere on the page, that's a bug — readers can't see or click an invisible link.

## Phase 6 — Camera-ready upload

Most venues run a separate camera-ready cycle on EasyChair (or HotCRP, OpenReview, Sessionize). The flow:

1. Re-upload the post-revision PDF (the final-final version with real DOIs and no `[TBD]`)
2. Integrity check runs server-side (anti-plagiarism, format compliance, ACM/IEEE policy alignment). Takes 1–2 weeks typically.
3. After integrity passes, publisher sends an e-rights form. Owner signs.
4. Final copyright block (`\acmDOI`, `\acmISBN`, `\setcopyright`) gets injected by the publisher's typesetting. **You usually don't need to re-upload anything after e-rights — the publisher handles the copyright-block insertion themselves.**

If the publisher's copy of `acmart` (or equivalent) is newer than yours, that's fine. They will rebuild from your source.

## Phase 7 — ORCID linking discipline

ACM ICPS (and most academic publishers) collect ORCID iDs for all authors. The `\orcid{}` command in `acmart` makes the author NAME an invisible hyperlink to the ORCID URL — but renders no visible iD icon. Reviewers and readers can't see that ORCID is included.

Fix (verified working on the mise project, post-organizers reminder):

```latex
% In the preamble:
\usepackage{orcidlink}

% In the author block (replace your existing \author + \orcid):
\author{<Author Name>\,\orcidlink{XXXX-XXXX-XXXX-XXXX}\,\href{https://orcid.org/XXXX-XXXX-XXXX-XXXX}{XXXX-XXXX-XXXX-XXXX}}
\email{<email>}
% Note: \orcid{} is REMOVED. Why: \orcid{} wraps the entire author content
% in an outer href. You can't nest hrefs, so the inner visible \href on
% the ORCID number gets silently stripped. Removing \orcid{} resolves
% the conflict; \orcidlink + inline \href together produce icon + visible
% ID, both clickable.
```

Verify the rendering after rebuild:

```bash
# Visual: render page 1, crop to author block, eyeball
pdftoppm -r 200 -f 1 -l 1 -png paper/main.pdf /tmp/p1
convert /tmp/p1-1.png -crop 800x80+450+330 /tmp/p1-name.png
# (Open /tmp/p1-name.png — should show "Author Name [iD] XXXX-XXXX-XXXX-XXXX")

# Programmatic: check the hyperlinks
python3 -c "
from pypdf import PdfReader
r = PdfReader('paper/main.pdf')
for a in r.pages[0].get('/Annots', []):
    obj = a.get_object()
    if obj.get('/Subtype') == '/Link' and '/A' in obj:
        action = obj['/A'].get_object()
        if '/URI' in action:
            print(action['/URI'])
"
# Should print 2 ORCID URLs (icon + visible href) — both targeting the same ID
```

Running heads on subsequent pages inherit the author rendering automatically; verify by repeating the visual check on page 2.

## Phase 8 — Final state for handoff to /talk

When the sub-arc completes, the project should have:

- `<conf>-submitted` tag (as-submitted)
- `<conf>-camera-ready` tag (final post-revision)
- `paper/main.pdf` final-final, no `[TBD]`, real ORCID + DOIs visible, page count within limit
- `artifact/` published, Zenodo DOI live, BibTeX block in `artifact/README.md` populated
- arXiv ID public (or marked as deferred — endorsement still in flight)
- E-rights signed (or marked as awaiting publisher email)
- All revision beads closed; the spec bead carries the full revision history in `--notes`
- A typed `note` bead in the project records ongoing follow-ups (arXiv link share, Zenodo cross-link, ACM publication tracking)

After this, run the handoff checklist at [`handoff-checklist.md`](handoff-checklist.md) and bootstrap `~/cfp/talk-<slug>/` for the `/talk` skill to pick up.

## Cross-reference

- [`zenodo-json-template.json`](zenodo-json-template.json) — Zenodo metadata for the GitHub-Zenodo integration
- [`arxiv-tarball-build.md`](arxiv-tarball-build.md) — full arXiv source tarball build procedure
- [`handoff-checklist.md`](handoff-checklist.md) — verifies the project is mineable for `/talk`
- `~/cfp/mise/` — the worked example (read its CLAUDE.md, mp-9m1 spec bead, `paper/main.tex`, `artifact/README.md`)

## Discipline summary

The sub-arc adds steps; it doesn't change the methodology. Every revision is bead-tracked. Every diff is critic-reviewed. Every claim has a test case. Every placeholder is verified gone before submission. Every venue-specific gotcha (ORCID rendering, content-filter PII trips, `[TBD]` leakage, BibTeX `.bbl` freshness) has a programmatic check that catches it before reviewers do. The mise project ran this sub-arc end-to-end without losing the discipline — that's the proof it scales.
