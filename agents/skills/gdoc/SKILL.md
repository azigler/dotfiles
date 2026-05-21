---
name: gdoc
description: Read, write, format, and collaborate on Google Docs from Claude Code — the gdoc.sh shim, the Tabs API, service-account auth, and a canonical styling contract (Arial 11pt, 20/16/13pt headings). LinearB connector specifics are a separate private reference.
---

# /gdoc — Google Docs

Read, write, format, and collaborate on Google Docs from Claude Code. Two
concerns live in this skill:

- **Mechanics** — auth, the `gdoc.sh` shim, tabs, comments, the
  inline-bun fallback for advanced ops
- **Styling contract** — the canonical font/size/spacing rules every
  doc an agent produces should follow

If you're writing a new doc, **read the styling contract first**. The
mechanics get you a doc on the page; the contract is how that doc looks
like every other doc in the fleet.

## Prerequisites

1. **A Google service account key** — set `GDOC_SA_KEY` to its path,
   or place it at `~/.config/gcloud/service-account.json`.
2. **bun** installed (the connector is TypeScript, run via bun).
3. **The target document shared** with the service account's
   `client_email` (in the key file — typically
   `*@*.iam.gserviceaccount.com`).

> **LinearB:** the factory connector + its service-account key
> locations are in `~/linearb/refs/gdoc-connector.md`.

## Quick setup (per project)

Symlink the global shim into your project so it can call out from CI / scripts:

```bash
mkdir -p scripts
ln -sf ~/.claude/skills/gdoc/gdoc.sh scripts/gdoc.sh
```

Or invoke `~/.claude/skills/gdoc/gdoc.sh` directly without copying.

---

## Styling Contract

Every Google Doc an agent produces should look like it came from the same
hand. These are the rules.

| Element | Font | Size | Spacing |
|---|---|---|---|
| Body paragraph | Arial | 11pt | lineSpacing 1.15, spaceBelow 6pt |
| Bullet item | Arial | 11pt | lineSpacing 1.15, spaceBelow 2pt |
| Heading 1 | Arial | 20pt | spaceAbove 12pt, spaceBelow 6pt, lineSpacing 1.15 |
| Heading 2 | Arial | 16pt | spaceAbove 12pt, spaceBelow 6pt, lineSpacing 1.15 |
| Heading 3 | Arial | 13pt | spaceAbove 12pt, spaceBelow 6pt, lineSpacing 1.15 |
| Inline hyperlink | inherit | inherit | underline, color rgb(0.06, 0.36, 0.8) |

### Why these values

- **Arial** — Google Docs' default, reads clean at all sizes, ships
  everywhere. No exotic fonts.
- **11pt body** — dense enough to fit a deal timeline without ballooning
  to five pages, light enough to skim.
- **20 / 16 / 13pt hierarchy** — distinct but not aggressive. H1 for one
  top-line title per tab; H2 for section banners; H3 for numbered
  sub-steps. If you want a fourth level, reach for bold body text, not a
  shrunken heading.
- **spaceAbove 12pt on headings** — prevents headings sitting flush
  against the previous paragraph's last line.
- **lineSpacing 1.15** — tighter than Docs default (1.5) but still
  breathable. Memo-like.
- **Bullet spaceBelow 2pt** — lets bullets breathe *as a group* without
  each item looking isolated.

### Two implementation paths

#### Path A (preferred) — a shared op emitter

If your writer takes Slack mrkdwn or markdown, drive the Docs API with
a shared op-emitter library that pre-encodes the styling contract
above, rather than re-deriving it per agent. (The LinearB factory
ships one — see `~/linearb/refs/gdoc-connector.md` for the import path
and call shape.)

#### Path B — HTML importer fallback

If your writer uses Drive's HTML importer (`drive.files.update` with
`media.mimeType = "text/html"`), inline the styles on import:

```html
<html>
  <body style="font-family: Arial, sans-serif; font-size: 11pt; line-height: 1.15;">
    <h1 style="font-family: Arial, sans-serif; font-size: 20pt; margin-top: 12pt; margin-bottom: 6pt;">Title</h1>
    <h2 style="font-family: Arial, sans-serif; font-size: 16pt; margin-top: 12pt; margin-bottom: 6pt;">Section</h2>
    <p style="margin-bottom: 6pt;">Body paragraph text.</p>
    <ul style="margin-bottom: 6pt;">
      <li style="margin-bottom: 2pt;">Bullet item</li>
    </ul>
  </body>
</html>
```

Or apply ops in a second pass after import (heavier; same output as Path A).

### When to deviate

Rarely. Reasons:

- **External template contract** (e.g., PMM monthly release notes
  doc has a specific typographic treatment) — respect the template,
  document the exception in the agent's CLAUDE.md.
- **Stakeholder ask** — explicit request for different styling. One-off,
  don't change the contract.
- **Medium-specific** — Gamma presentations have their own theme; this
  contract doesn't apply there.

Anything else is drift. Bring it back to the contract.

---

## Shell Shim Usage

The `gdoc.sh` script (lives at `~/.claude/skills/gdoc/gdoc.sh`) wraps
all common operations:

```bash
# List tabs in a document
./scripts/gdoc.sh tabs <docId>

# Read a document (or specific tab) as markdown
./scripts/gdoc.sh read <docId>
./scripts/gdoc.sh read <docId> <tabId>

# Write markdown to a document (full replacement of doc content)
./scripts/gdoc.sh write <docId> /path/to/content.md

# ⚠️ DO NOT pass <tabId> to write. The connector's per-tab path is
# known-incomplete and inserts the HTML as literal text — your headings
# render as `<h1>...</h1>` strings instead of styled headings. The
# default (no tabId) uses Drive's HTML importer and produces correct
# rich text. For single-tab docs, omitting tabId is the right call;
# for multi-tab docs that need targeted writes, see "Per-tab writes
# (use bun inline)" below.

# Read comments on a document
./scripts/gdoc.sh comments <docId>

# Post a new comment on a document
./scripts/gdoc.sh comment <docId> "Your comment text here"

# Reply to an existing comment
./scripts/gdoc.sh reply <docId> <commentId> "Your reply text here"

# Create a new tab
./scripts/gdoc.sh add-tab <docId> "Tab Title"
```

### Extracting a Doc ID

From a Google Docs URL:
`https://docs.google.com/document/d/1wfhHghZ0hXs_6Pk_UiBN-hHoPMHVINuExgQVV9rHlOg/edit`

The doc ID is: `1wfhHghZ0hXs_6Pk_UiBN-hHoPMHVINuExgQVV9rHlOg`.

---

### Per-tab writes (use bun inline, not the shim)

The shim's `gdoc.sh write` with a `tabId` arg routes to the connector's
legacy `insertText` path, which inserts the markdown→HTML output as a
literal text blob — readers see `<h1>...</h1>` and `<p>...</p>` as
visible characters, no styling at all. This is documented as
known-incomplete in `connectors/google/docs/write.ts`.

Use the no-tabId form whenever the doc has a single tab (the common
case for blog drafts, briefs, and single-page deliverables). For
genuine multi-tab docs that need targeted writes, drop down to bun
inline and either (a) parse markdown into native Docs `insertText` /
`updateParagraphStyle` requests with `tabId` on the location, or (b)
pre-create the doc via Drive HTML import (which writes to tab one),
then move/restructure the tabs.

## Advanced Operations (inline bun)

For operations not covered by the shim, run bun inline against the
`googleapis` library. The examples below assume two vars you set for
your environment:

```bash
AGENT_DIR="<a directory with googleapis installed>"
SA_KEY="<path to your service-account .json>"
```
(LinearB factory paths: `~/linearb/refs/gdoc-connector.md`.)

### Create a new tab

```bash
cd "$AGENT_DIR" && bun -e "
import { readFileSync } from 'fs';
import { google } from 'googleapis';

const key = JSON.parse(readFileSync('$SA_KEY', 'utf-8'));
const auth = new google.auth.GoogleAuth({
  credentials: key,
  scopes: ['https://www.googleapis.com/auth/documents']
});
const docs = google.docs({ version: 'v1', auth });

const res = await docs.documents.batchUpdate({
  documentId: '<DOC_ID>',
  requestBody: {
    requests: [{
      addDocumentTab: {
        tabProperties: { title: 'My New Tab' },
      },
    }],
  },
});
console.log('Tab created:', JSON.stringify(res.data.replies, null, 2));
"
```

### Apply formatting to a tab (matches contract above)

```bash
cd "$AGENT_DIR" && bun -e "
import { readFileSync } from 'fs';
import { google } from 'googleapis';

const key = JSON.parse(readFileSync('$SA_KEY', 'utf-8'));
const auth = new google.auth.GoogleAuth({
  credentials: key,
  scopes: ['https://www.googleapis.com/auth/documents']
});
const docs = google.docs({ version: 'v1', auth });

const tabId = '<TAB_ID>';

await docs.documents.batchUpdate({
  documentId: '<DOC_ID>',
  requestBody: {
    requests: [
      // H1 — Arial 20pt
      {
        updateParagraphStyle: {
          range: { startIndex: 1, endIndex: 30, tabId },
          paragraphStyle: {
            namedStyleType: 'HEADING_1',
            spaceAbove: { magnitude: 12, unit: 'PT' },
            spaceBelow: { magnitude: 6, unit: 'PT' },
            lineSpacing: 115,
          },
          fields: 'namedStyleType,spaceAbove,spaceBelow,lineSpacing',
        },
      },
      {
        updateTextStyle: {
          range: { startIndex: 1, endIndex: 30, tabId },
          textStyle: {
            weightedFontFamily: { fontFamily: 'Arial' },
            fontSize: { magnitude: 20, unit: 'PT' },
          },
          fields: 'weightedFontFamily,fontSize',
        },
      },
    ],
  },
});
console.log('Heading formatted');
"
```

---

## Google Docs API: Tab Reference

Tabs were added to the Docs API in 2024. Key points:

- **List tabs:** `documents.get` with `includeTabsContent: true` returns
  `document.tabs[]` with `tabProperties` (id, title) and `documentTab` (body)
- **Target a tab in batchUpdate:** Add `tabId` to any `location` or `range`
  object. If omitted, defaults to the first tab.
- **Create tabs:** Use `addDocumentTab` request in batchUpdate
- **Delete tabs:** Use `deleteTab` request — child tabs are deleted along with it
- **Rename tabs:** Use `updateDocumentTabProperties` request
- **Tab content:** Access via `document.tabs[i].documentTab.body` (not
  `document.body` which only returns first tab when `includeTabsContent`
  is false)

## Connector API Reference

The lb-agent-di Google connector's function surface — read / write /
drive / auth — is documented in `~/linearb/refs/gdoc-connector.md`.

---

## Workflow Pattern

A typical editing workflow:

1. **Read** the doc to see current state
2. **Read comments** to see reviewer feedback
3. **Reply** to each comment acknowledging the feedback
4. **Edit locally** in a markdown file
5. **Write** the updated markdown back to the doc (Path A — styling
   contract is automatic)
6. **Reply** again confirming the change was made
7. Reviewer sees changes in Google Docs and leaves more comments
8. Repeat until approved

The agent can also **post comments** proactively to flag issues, ask
questions, or leave notes. Comments appear under the service account
identity.

For multi-section documents, use **tabs** to separate concerns (e.g.,
article draft in Tab 1, social media drafts in Tab 2, reviewer notes
in Tab 3).

## Guardrails

- **Don't change the styling values** without `/distribute` and a sample
  doc for review. The point of a contract is that it's shared.
- **Don't inline hex colors or custom font sizes per agent.** If a new
  element type needs a rule (callout boxes, footnotes), extend this
  contract; don't special-case inside an agent.
- **Don't write plain `notes` or untyped HTML.** Both paths above have
  specific shapes. The deviations are unsupported.
- **Asana tickets are not Docs.** Use `/asana` for Asana — that has its
  own `html_notes` shape.
- **Gamma presentations are not Docs.** Gamma has its own theme.
