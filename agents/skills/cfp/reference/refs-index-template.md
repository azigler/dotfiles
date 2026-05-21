# refs/ index

Quick map of reference material in this project. Maintained by `/cfp` and
`/housekeeping`. Format: one line per file, action-friendly description.

## Generation pattern

```bash
{
  echo "# refs/ index"
  echo ""
  echo "Quick map of reference material in this project."
  echo ""
  for f in refs/*.md; do
    name=$(basename "$f")
    first=$(head -1 "$f" | sed 's/^# *//')
    echo "- [$name]($name) — $first"
  done
} > refs/INDEX.md
```

After regenerating, eyeball the descriptions — first-line headers are
usually accurate but may need clarification.

## Files (replace at fill time)

- [{{filename1}}.md]({{filename1}}.md) — {{one-line description}}
- [{{filename2}}.md]({{filename2}}.md) — {{one-line description}}

## Binary attachments (not greppable)

- `{{form.docx}}` — original CFP form (markdown rendering at `{{form.md}}`)
- `{{paper.pdf}}` — venue paper PDF (markdown synopsis at `{{paper-summary.md}}`)

## When to maintain this file

Skip for `refs/` directories under 10 files — listing is still cheap there.
Generate / refresh when the count exceeds the threshold or when a new
agent has to load the directory and is wasting tokens scanning it.
