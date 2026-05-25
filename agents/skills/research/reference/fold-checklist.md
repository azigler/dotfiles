# Fold checklist (Step 4 of /research)

When a research agent returns and you've verified + scrutinized, fold
the findings to durable state. This is the ordered checklist.

## 1. Save the report

```bash
cp /tmp/research-<topic>.md <project>/refs/research/<topic>.md
```

`refs/research/` is the canonical archive convention. One file per
research question. Named by topic (not by date — date is in git
history).

## 2. Update the bead's --notes

```bash
cd <target-repo>     # bead-location discipline
br update <bead-id> --notes "$(cat <project>/refs/research/<topic>.md)"
br sync --flush-only
```

The bead's notes carry the full report for posterity (in case the
refs file moves later).

## 3. Close the bead (if research IS the deliverable)

```bash
br close <bead-id>
br sync --flush-only
```

Don't close if the research is one step of a larger work item with
implementation still ahead.

## 4. Update GUARDRAILS (if invariant)

If the finding is a **cross-arc invariant** (not just a one-off), add
a new G<N> section. See `guardrails-template.md`.

Test: would another orchestrator picking up this project need to know
this BEFORE touching the relevant subsystem?
- Yes → GUARDRAILS
- No → Bead notes only

## 5. Cross-link related beads

If the finding affects other beads (e.g., research on framework A
changes the spec for system B that uses A), update those beads' `--notes`
with a pointer back:

```bash
cd <related-repo>
br update <related-bead> --notes "$(br show <related-bead> --format json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0][\"notes\"] or \"\")')

## REFERENCE — <date> 
<one-line summary of new finding>
See: $(realpath <refs/research/<topic>.md>)"
br sync --flush-only
```

## 6. Update cross-epic / overlap docs (if cross-arc)

If the finding changes how multiple epics interact, update the
project-level cross-epic / cross-arc overlap doc (e.g.,
`refs/cross-epic-overlap-<date>.md`).

## 7. Commit

Group all the above into a single semantic commit per bead:

```bash
cd <target-repo>
git add .beads/issues.jsonl refs/research/<topic>.md
# also add: GUARDRAILS.md if updated, overlap doc if updated
git commit -m "$(cat <<EOF
:white_check_mark: <bead-id> CLOSED: <one-line finding>

[Multi-paragraph body covering: what was researched, key findings
(with bullet points), what was reversed (if any), where artifacts
live, cross-references.]

Co-Authored-By: <agent-id> <email>
EOF
)"
git push
```

If submodules involved, bump pointers in parent repo too.

## 8. Push milestone notification + SendUserFile (if material)

```
PushNotification "<finding headline, <200 chars, one line>"
SendUserFile "<report.md>" "<one-line caption with the punchline>"
```

Save these for findings that:
- Reverse a prior belief
- Unblock something we were stuck on
- Surface a NEW issue to track
- Complete a major arc

Don't push for routine progress.

## 9. Update task-tracker if you're using one

```
TaskUpdate(taskId: <id>, status: completed)
```

(For ephemeral session task tracking, not the durable bead state.)

## 10. Layer (Step 5 in SKILL.md)

After folding, IMMEDIATELY ask: what NEW questions did this surface?
What follow-up beads should exist?

Bead them now. Dispatch the next layer of research.

**Don't stop and wait for the user to prompt the next step** — the
arc has its own momentum and you're driving it.

## Common fold mistakes

| Mistake | Fix |
|---|---|
| Forgetting `br sync --flush-only` | Bead state silently doesn't persist |
| Wrong cwd for `br create/update` | Bead lands in wrong repo's .beads/ |
| Skipping refs/research/ save | Findings die when conversation compacts |
| Not closing bead when it's done | `br list` cluttered; ambiguous what's still open |
| Folding without scrutinizing | Bad findings calcify; cascade into bad downstream work |
| Closing bead before commit | Audit trail incomplete |
