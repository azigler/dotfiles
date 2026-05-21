---
description: Frontend craft library — opinionated design foundations (typography, color, motion, spatial, interaction, responsive, ux-writing) plus refinement operations (arrange, audit, clarify, colorize, critique, delight, distill, extract, harden, normalize, optimize, overdrive, polish, typeset) for taking interfaces from functional to impeccable. Use when building, refining, auditing, or critiquing any web UI / frontend code, or when the user asks anything about design quality, visual polish, accessibility, or style.
when_to_use: User asks to build/redesign a page, audit accessibility, polish details, fix design system drift, add color, simplify, or any "make this design better" request. Also load when writing CSS, JSX/TSX, or any frontend code so the AI-slop anti-patterns are top of mind.
arguments: [operation, target]
---

# /impeccable — Frontend Craft Library

A single skill that bundles design foundations and refinement operations
for building distinctive, production-grade frontend work that doesn't
look AI-generated.

The library has two parts:

- **Foundations** (`reference/foundations/*.md`) — the design knowledge.
  Typography, color, motion, spatial, interaction, responsive, ux-writing.
  Read the relevant ones before making decisions in that area.
- **Operations** (`reference/operations/*.md`) — refinement passes.
  Each one is a focused playbook for a specific quality dimension.

## Invocation

Two patterns:

- **`/impeccable`** with no args — load the AI-slop checklist below and
  apply it to whatever the user just asked for. Use when they want
  general design quality without naming a specific operation.
- **`/impeccable <operation> [target]`** — run a specific refinement
  pass. Operations: `arrange`, `audit`, `clarify`, `colorize`,
  `critique`, `delight`, `distill`, `extract`, `harden`, `normalize`,
  `optimize`, `overdrive`, `polish`, `typeset`. Examples:

  ```
  /impeccable audit dashboard
  /impeccable critique
  /impeccable polish "the new pricing page"
  /impeccable colorize buttons
  ```

When invoked with an operation, **read the matching playbook at
`${CLAUDE_SKILL_DIR}/reference/operations/$operation.md`** before doing
anything. The playbooks contain the full procedure, severity rubrics,
report formats, and operation-specific anti-patterns.

When in doubt about a foundation (e.g., "what color should this be?",
"how big should the touch target be?"), read
`${CLAUDE_SKILL_DIR}/reference/foundations/<topic>.md`. The foundations
are 100–130 lines each and cover the non-obvious decisions.

## The AI Slop Test

**Critical quality check.** If you showed this interface to someone and
said "AI made this," would they believe you immediately? If yes, that's
the problem. A distinctive interface should make someone ask "how was
this made?" not "which AI made this?"

The fingerprints of AI-generated work from 2024–2026:

### Color

- Cyan-on-dark, purple-to-blue gradients, neon accents on dark backgrounds
- Pure black (`#000`) or pure white (`#fff`) anywhere
- Gray text on colored backgrounds (washed out, dead)
- Gradient text for "impact" (especially on metrics or headings)
- Default to dark mode with glowing accents
- Untinted neutrals (true gray)

### Typography

- Inter, Roboto, Open Sans, Lato, Montserrat (overused defaults)
- Monospace as lazy shorthand for "technical/developer"
- Large rounded-corner icons above every heading
- Same font weight everywhere (no hierarchy contrast)

### Layout

- Wrap everything in cards
- Nest cards inside cards
- Identical card grids (same-sized cards with icon + heading + text,
  repeated endlessly)
- Hero metric layout (big number + small label + supporting stats +
  gradient accent)
- Center everything (left-aligned with asymmetric layouts feels more
  designed)
- Same spacing everywhere (no rhythm)

### Visual details

- Glassmorphism everywhere (blur effects, glass cards, glow borders
  used decoratively)
- Rounded elements with thick colored border on one side (lazy accent)
- Sparklines as decoration (tiny charts that look sophisticated but
  convey nothing)
- Rounded rectangles with generic drop shadows
- Modals when there's a better alternative

### Motion

- Animating layout properties (width, height, padding, margin)
- Bounce or elastic easing (dated, tacky)
- The same animation everywhere
- No `prefers-reduced-motion` handling

### Interaction

- Repeat the same information (redundant headers, intros that restate
  the heading)
- Every button as primary (no hierarchy)
- Hover state without focus state
- `outline: none` without replacement

If the work has any of these, fix them before shipping. Reach for the
matching foundation file or run the matching operation.

## Foundations

Each foundation is loaded as needed; they're not in this SKILL.md to
keep the entry tight.

| Topic | When to load `reference/foundations/<file>.md` |
|---|---|
| `typography.md` | Picking fonts, sizes, line height, font loading, OpenType features |
| `color-and-contrast.md` | OKLCH palette design, dark mode, WCAG contrast, tinted neutrals |
| `motion-design.md` | Animation timing/easing, perceived performance, reduced motion |
| `spatial-design.md` | Grid systems, spacing tokens, container queries, optical adjustments |
| `interaction-design.md` | The 8 interactive states, focus rings, forms, modals, popover API |
| `responsive-design.md` | Mobile-first, breakpoints, pointer/hover queries, safe areas, srcset |
| `ux-writing.md` | Button labels, error messages, empty states, voice/tone, i18n |

Read the relevant foundation BEFORE designing in that area, not after.

## Operations

Each operation has a full playbook in `reference/operations/<op>.md`.
The tagline is what the operation does at a glance:

| Operation | Tagline | When |
|---|---|---|
| `arrange` | Improve layout, spacing, visual rhythm | Monotonous grids, weak hierarchy, lifeless composition |
| `audit` | Diagnostic scan across a11y, perf, theming, responsive | Before a release; suspect AI-slop tells |
| `clarify` | Improve UX copy: errors, labels, empty states | Microcopy is vague, jargon-heavy, blame-y |
| `colorize` | Strategic color introduction (palette, semantic, hierarchy) | Design feels gray, washed out, monochrome |
| `critique` | Holistic design critique, design-director POV | Mid-build sanity check; "is this distinctive?" |
| `delight` | Add personality — micro-interactions, copy, surprises | Functional but flat |
| `distill` | Strip to essence, remove unnecessary complexity | Design feels cluttered, overloaded |
| `extract` | Pull reusable components/tokens into the design system | Patterns repeat 3+ times |
| `harden` | Edge cases: long text, i18n, errors, network failures | Demo polish but not production-ready |
| `normalize` | Align with design system tokens and conventions | One-off styles, hard-coded values |
| `optimize` | Performance: loading, rendering, animations, bundle | LCP/INP/CLS regressions, slow feel |
| `overdrive` | Push past conventional limits — ambitious technical implementation | Make people ask "how did they do that?" |
| `polish` | Final detail pass — alignment, states, micro-interactions | Last 10% before shipping |
| `typeset` | Improve typography — font choices, hierarchy, sizing, weight | Body feels generic, hierarchy unclear, weights inconsistent |

### Mandatory preparation for refinement operations

Before running `colorize`, `distill`, or `delight` (and any other
operation that requires brand context), gather:

- Target audience (critical)
- Desired use cases (critical)
- Brand personality and tone
- For `colorize`: existing brand colors

If these are not in the codebase, the conversation, or `MEMORY.md`,
**STOP and call AskUserQuestion to clarify**. Do not guess — guessing
leads to generic AI slop.

The operation playbooks in `reference/operations/` repeat this guidance
because it's load-bearing.

## Workflow patterns

### Building a new page from scratch

1. Read the relevant foundations BEFORE designing (typography, color,
   spatial at minimum).
2. Build with the AI Slop Test in mind throughout (don't reach for the
   anti-patterns).
3. Run `/impeccable polish` as the final pass.
4. Run `/impeccable audit` if a11y / performance gates matter.

### Refining an existing page

1. Run `/impeccable critique` for an honest design read.
2. Run `/impeccable audit` for measurable issues (a11y, perf, theming).
3. Apply the recommended operations in priority order.
4. Run `/impeccable polish` last.

### Single-axis refinement

Skip critique/audit and go straight to the operation:
`/impeccable colorize`, `/impeccable distill`, `/impeccable harden`, etc.

## Extension

If a project has its own design tokens, brand identity, or aesthetic
anchors, they should live in the project's CLAUDE.md (or
`.claude/refs/design-brief.md`). This skill provides the universal
craft layer; project-specific context layers on top.

## Anti-anti-patterns

Some practices the foundations reject have legitimate uses:

- **Pure black `#000`**: in print where ink is monochromatic
- **Inter / Roboto**: in tools and dashboards where personality isn't
  the goal (Linear, GitHub, etc.)
- **Modals**: for genuinely blocking flows (irreversible deletes,
  payment confirmation)
- **Bounce easing**: in toy / game / kid-targeted contexts where the
  feel is intentional

The foundations name these as defaults to AVOID, not absolute bans.
Designers with intent can override; AI defaults reach for them
unconsciously.

## See also

- `/zig-voice` — written voice (independent of visual craft)
- `/linearb-brand` — when working in LinearB context
- `/apex` — LinearB's APEX framework (load when copy mentions pillars or metrics)
