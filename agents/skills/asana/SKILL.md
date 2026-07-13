---
description: Asana rich-text mechanics — how html_notes (task bodies) vs plaintext text (comments) render, the strict-XML tag rules, and the gotchas that trip up every first attempt. The LinearB fleet-proxy workflow is a separate, private reference.
when_to_use: Working with Asana rich-text fields — load before any html_notes (task body) or text (comment) write so the strict-XML rules are in context. Reference for all Asana API integrations.
---

# /asana — Asana rich-text mechanics

This skill covers the **portable** part of working with Asana: how its
two rich-text surfaces render, and the strict-XML rules behind them.
The knowledge here is empirical — Asana's rendering does not match its
API's acceptance, and the gotchas are not in the official docs.

<!-- private-start -->
**LinearB note:** the `lb-agent-fleet` proxy, the workspace + agent
GIDs, and the daily-bead-log / receipt-of-work workflows are
LinearB-internal — they live in `~/linearb/refs/asana-fleet.md`. Load
that ref when doing LinearB Asana work; it builds on the mechanics
below.
<!-- private-end -->

## html_notes for task bodies, plaintext `text` for comments

Asana's two rich-text surfaces behave differently:

- **Task create/update**: use **`html_notes`** (not `notes`). HTML
  renders as styled rich text in the task body.
- **Task comment**: `html_text` renders rich text in comments —
  `<strong>`, `<em>`, `<ul>`, `<a href>`, `<code>` all work. **But
  `<h1>`, `<h2>`, and `<img>` are task/brief-only**: put one in a
  comment and Asana shows the raw tag. (An early test here did exactly
  that on 2026-05-07 and the skill briefly over-generalized it to
  "comments render plaintext only" — corrected.) Use comment-legal
  tags in `html_text`, or plain `text` when you don't need formatting.

### Comments — plaintext

Send the `text` field with bare ASCII, line breaks, and dashes. Asana
auto-linkifies HTTPS URLs in plaintext, so links work without markup.
Use line breaks + indentation + dashes for structure. Markdown does
NOT render — `**bold**` ships as literal asterisks. For section
headers, use a label line followed by a blank line.

### Task bodies — html_notes (rich text DOES render)

`html_notes` IS rendered as styled HTML in the task description. Wrap
it in `<body>…</body>`; Asana parses it as **strict XML, not loose
HTML5**.

Supported tags in `html_notes`:

```
<body>   <h1>   <h2>   <strong>   <em>   <u>   <s>   <code>   <pre>
<ul>     <ol>   <li>   <a href>   <img/>
```

`<h3>`, `<br/>`, `<br>`, `<br />` are **not** supported — they return
`400 Validation error: xml_parsing_error: XML is invalid`. Self-closing
form is **mandatory** for `<img/>`; text-content tags close normally
with paired tags.

Because `html_notes` rejects `<p>`, every `<br>` form, and `<h3>`, the
only paragraph-level visual separation is the natural spacing between
`<h1>`/`<h2>` headings and `<ul>`/`<ol>` blocks — body text flows
between them. Where you'd reach for `<h3>`, use another `<h2>` and let
title context carry the hierarchy.

## Anti-patterns

- ❌ **`notes` instead of `html_notes`** for a task body — renders as a
  wall of raw markup.
- ❌ **Both `text` and `html_text`** on one comment — the API rejects
  the ambiguity (`400`).
- ❌ **Unsupported tags** (`<p>`, any `<br>`, `<h3>`) in `html_notes` —
  `400 xml_parsing_error`.
- ❌ **Bare `<img>`** — it must self-close: `<img/>`.
- ❌ **`GID` / `TID` as a card-loop variable in zsh** — `GID` is a
  reserved/setgid special var and `TID` collides; assigning them
  silently misbehaves (the gid/tid gets mangled, the write hits the
  wrong task or errors). Name the per-card loop variable `CARD` (or any
  non-reserved word). Recurred twice in vibe-explore card-marking loops.

## See also

<!-- private-start -->
- `~/linearb/refs/asana-fleet.md` — the LinearB fleet-proxy workflow:
  endpoints, workspace + agent GIDs, daily bead-log, receipt-of-work.
  Load it for any LinearB Asana work.
<!-- private-end -->
