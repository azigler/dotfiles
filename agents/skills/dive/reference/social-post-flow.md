# /explore — Social post deliverable pipeline

When /explore is run in deliverable mode (user says "make a post about
it", "do the same treatment", "put this on a subtask"), this is the
4-step pipeline.

The deliverable is a Zig-voice LinkedIn-ready post AS A PLAINTEXT COMMENT
on a new SUBTASK under the parent /explore task, with a randomize-driven
SPECIFIC-SUBJECT image as an ATTACHMENT.

"Surprise me" is the underpinning. The user should not be able to predict
the image subject before the randomize roll. Neither should the agent.

## CRITICAL: voice scope

Zig voice applies to EXACTLY ONE artifact in this pipeline: the
plaintext comment posted on the LinkedIn-post subtask in Step 4. That
comment is the deliverable the user will copy-paste to LinkedIn.

Every other artifact in this pipeline uses clean professional prose:
- The subtask name (Step 1)
- The subtask `html_notes` description (Step 1) — this is metadata for
  future agents to read, not content
- The randomize provenance block (Step 3) — this is technical record-keeping
- The image prompt (Step 3) — this is a generation prompt, not content
- The chat-side narration to the user as the pipeline runs

Conflating these is the over-rotation failure mode caught on 2026-05-07
where multiple Asana descriptions and reports drifted into casual
zig-voice register that read as sloppy on work artifacts other people
needed to consume. The post itself is the only thing the user publishes
under his name; everything else is supporting infrastructure that
should read like a professional handoff.

## Pipeline overview

1. Create subtask (POST `/api/asana/tasks` w/ `parent` = parent /explore task GID)
2. Draft the post in /zig-voice (builder devlog or interview field notes typically)
3. randomize-roll the image axes, generate image via /openrouter
4. Attach image (multipart) + post the post as a plaintext comment

Each step has a section below.

## Step 1: Create the subtask

```bash
cat > /tmp/subtask.json <<EOF
{
  "name": "LinkedIn post: <topic> — <one-line angle>",
  "parent": "<parent-explore-task-gid>",
  "assignee": "1208749853950521",
  "due_on": "$(TZ=America/Los_Angeles date +%Y-%m-%d)",
  "html_notes": "<body>Brief context for what this subtask is. randomize provenance for the image goes here. Plain-by-design post is in the comment below — paste straight to LinkedIn.</body>"
}
EOF

curl -sS -X POST "$FLEET_URL/api/asana/tasks" \
  -H "Authorization: Bearer $FLEET_TOKEN" \
  -H "X-Agent-Name: claude-code" \
  -H "Content-Type: application/json" \
  -d @/tmp/subtask.json
```

The subtask's `html_notes` is a brief description for context. It CAN
use html_notes since u're not copy-pasting the description content.
The COMMENT goes plaintext (next step). Save the subtask GID — u need
it for steps 3 + 4.

## Step 2: Draft the post in /zig-voice

Read the full /zig-voice SKILL before drafting if the topic is anything
other than a pure builder devlog. Ten anti-patterns are easy to trip
on by accident.

### Genre selection

- **Builder devlog** (~200-300 words): u tinkered w/ X, here's what
  worked. In-progress warmth, contradiction or scene opener, specific
  protocol details, resource stack at the bottom. **Default for /explore
  posts** unless the topic demands different.
- **Interview field notes** (~250-350 words): u talked to someone, here
  are the rule-bullets. Time marker + scene + compressed credential
  line + 3-5 emoji-bullet field notes + subject-quote outro + merged
  credits.
- **Narrative-story** (~250-350 words): same shape as field notes but
  rule-bullets replaced w/ 1-2 hyperspecific anecdotes that CARRY the
  thesis. Bobcat-in-house energy.
- **Whimsical thesis post** (~120-180 words): Seussian packaging around
  a real thesis. Cross-domain analogy as the proof. Pun-chain naming
  gambit. Asterisked-footnote-as-closer.

For /explore-driven posts, builder devlog fits 80% of the time.

### Voice rules to honor (from /zig-voice)

Required:
- Specific moment opener, NOT a thesis or topic statement
- Casual register: u, ur, w/, btw, pls, da
- Plaintext only — no markdown bold/italic, plain URLs in resource stack
- Em-dash budget ~1 per 200 words in flow prose (bullet labels don't count)
- Selective ALL CAPS on 2-3 words for emphasis
- At least one crystallizing flip line per post
- Identity stamps where they fit (🐸 ✨)
- Resource stack on consecutive lines w/ thematic emojis
- Closer is a peer question, NOT a corporate CTA

Hard avoid:
- "Here's the thing" / "Plot twist" / "Let's break this down" / "Here's the kicker"
- Magic adverbs: quietly, deeply, fundamentally
- Apology-register openers ("the obligatory X plug")
- "Not X. Not Y. Just Z." false-suspense triple negation
- Trailing summaries ("In summary, we can observe...")
- Rhetorical questions as hooks (mid-piece is fine)
- Performative quote intros ("a line living rent-free in my head")
- "It's not X, it's Y" constructions

### Post-as-series discipline

When /explore creates multiple posts that pair (this session: Mycroft +
Open Models built on each other), the LATER posts should reference the
EARLIER posts in their opener. The thread should be visible to anyone
who reads them in order. Concrete example:
- Mycroft post: opens w/ "Watch this council website..."
- Open Models post: opens w/ "Mycroft is one example. The wave under it is bigger."

## Step 3: randomize-roll the image axes, generate via /openrouter

THIS IS THE LOAD-BEARING STEP. Past /explore-style sessions have produced
abstract/simple images (neural networks, glowing brains, text bubbles)
which is exactly the AI-slop imagery the user rejects.

### The canonical randomize axes for /explore images

Always roll these 6 axes. Generate `openssl rand -hex 12` (24 hex chars
= 6 distinct 4-char slices = 6 axes). Compute integer + modulo for each
axis. Write the provenance block BEFORE composing the prompt.

**SUBJECT** is topic-aware — u (the agent) populate the candidates based
on the post topic, picking 8 distinct SPECIFIC subjects. NOT abstract.
Specifics like "1990s newsroom desk", "craftsman's pegboard", "apothecary
shelf w/ labeled jars", "courthouse steps in late afternoon light".
Avoid abstract: "neural network", "glowing brain", "data city".

**MEDIUM** (n=10):
0. oil painting
1. pencil sketch
2. watercolor
3. ink and cross-hatching
4. linocut
5. mid-century editorial illustration
6. art deco poster
7. risograph two-color print
8. gouache
9. scientific botanical-plate

**ERA / SETTING** (n=8) — topic-aware augmentation. Default candidates:
0. 1920s industrial
1. 1940s war reporter
2. 1960s investigative
3. 1970s analog
4. 1990s pre-internet
5. contemporary minimalist
6. timeless workshop
7. dusk Victorian study

**COMPOSITION** (n=8):
0. close-up still-life
1. wide-angle environmental
2. portrait framing
3. top-down flatlay
4. side-angle medium shot
5. dutch-angle dramatic
6. table-edge w/ hanging items
7. shelf cross-section

**COLOR PALETTE** (n=8):
0. warm sepia + cream
1. cool monochrome blue
2. high-contrast black + red
3. muted earth tones
4. saturated mid-century
5. desaturated film noir
6. brass + walnut + cream
7. botanical-plate forest greens

**LIGHT + MOOD** (n=8):
0. late-night fluorescent + urgent investigation
1. morning window + quiet concentration
2. golden-hour west + warm humanism
3. overhead studio + detached documentary
4. candlelit + wonder
5. overcast diffuse + melancholy
6. brass-lamp focus + thoughtful gravity
7. dawn pale + tired determination

**ANCHORING DETAIL** (n=6) — the surprise element:
0. one anachronistic object (period-mismatched)
1. hand-lettered label visible
2. steam or dust mote in air
3. small live creature (bird, cat, insect)
4. open book or scroll w/ readable diagram
5. crumpled paper / discarded draft

### Provenance block format

```
randomize provenance — <subject summary>, <date>
  seed: 0d645737bd1e4eb7978b1b78  [openssl rand -hex 12]
  axis 1 (subject, n=8): int(0d64,16)=3428, 3428 % 8 = 4 → workshop pegboard w/ tools + one circuit board
  axis 2 (medium, n=10): int(5737,16)=22327, 22327 % 10 = 7 → pencil-and-watercolor field journal
  axis 3 (era/setting, n=8): int(bd1e,16)=48414, 48414 % 8 = 6 → timeless workshop
  axis 4 (composition, n=8): int(4eb7,16)=20151, 20151 % 8 = 7 → shelf cross-section
  axis 5 (palette, n=8): int(978b,16)=38795, 38795 % 8 = 3 → muted earth tones
  axis 6 (light + mood, n=8): int(1b78,16)=7032, 7032 % 8 = 0 → late-night fluorescent + urgent
  axis 7 (anchoring detail, n=6): int(1b78,16)=... [reuse last slice or generate longer seed]
```

For 7 axes, use `openssl rand -hex 14` (28 hex chars / 4 = 7 axes).
For 6 axes, `openssl rand -hex 12` is enough.

### Compose the image prompt from the rolled choices

Layer them into a prompt that names every chosen specific. Don't
generalize the rolled choices — name them concretely:

```
[MEDIUM] in [PALETTE]: a [COMPOSITION] view of [SUBJECT] in a [SETTING/ERA].
Specific elements: [list 4-6 props that fit the SUBJECT + ERA].
[LIGHT] with [MOOD] atmosphere. [ANCHORING DETAIL] worked into the
scene as [where it sits]. Style: [further texture / brushwork notes].
No text, no logos.
```

Keep "No text, no logos, no readable labels" at the end — nano-banana
sometimes hallucinates text otherwise. If u WANT text in the image,
name it explicitly AND audit the words for alternate meanings BEFORE
generation. Real examples to learn from:

- A "labeled apothecary jar" prompt produced a jar reading "salvia"
  (drug-slang ambiguity in some contexts). Caught after generation.
- Generic "vintage signage" can produce period-inappropriate political
  text or corporate logos.

Mitigations:
- Default rule: NO readable text in any image. Prompt-end ban.
- If a label / sign / book spine is composition-load-bearing, specify
  exact safe text in the prompt: "a leather book spine reading 'FIELD
  NOTES' in gold lettering."
- Avoid abstract noun nouns that match drug names, slurs, or political
  slogans even on accident: salvia, kratom, blue, etc. If the randomize roll
  picks an "anchoring detail" that involves text-bearing objects,
  override it w/ a non-text variant of the same motif.
- After generation, audit the image for any text that did slip through
  before showing the user.

### Generate via openrouter-image.sh

```bash
~/.claude/skills/openrouter/openrouter-image.sh \
  "<the rolled prompt>" \
  /tmp/<topic>-img.png
```

After generation, ALWAYS verify the file is the format the extension
claims:

```bash
file /tmp/<topic>-img.png
# If it says JPEG, rename:
mv /tmp/<topic>-img.png /tmp/<topic>-img.jpg
```

### Cost calibration (read this before u generate)

The /openrouter SKILL says ~$0.004 per 1K image. **That's stale.** Actual
nano-banana 2 (Gemini 3.1 Flash Image Preview) cost as of May 2026 is
~$0.05-0.07 per 1K image. Two images = ~$0.10-0.14.

Always state the real cost in ur acknowledgment:
> "I'm about to generate two 1K images via nano-banana. Expected cost:
> ~$0.10-0.14 total. Confirming before I fire?"

NEVER generate variants without explicit confirmation. If a generation
comes back unsatisfactory, regenerate the randomize seed once and try again
ONLY w/ user confirmation. Never silently iterate on prompts.

## Step 4: Attach image + post comment

```bash
# Attach image (multipart)
curl -sS -X POST "$FLEET_URL/api/asana/tasks/<subtask-gid>/attachments" \
  -H "Authorization: Bearer $FLEET_TOKEN" \
  -H "X-Agent-Name: claude-code" \
  -F "file=@/tmp/<topic>-img.png;type=image/png"

# Build comment payload via Python (for clean escaping)
python3 <<'PY'
import json
post = """<the LinkedIn-ready post content>"""
with open("/tmp/comment.json", "w") as f:
    json.dump({"text": post}, f)
PY

# Post comment as plaintext
curl -sS -X POST "$FLEET_URL/api/asana/tasks/<subtask-gid>/comment" \
  -H "Authorization: Bearer $FLEET_TOKEN" \
  -H "X-Agent-Name: claude-code" \
  -H "Content-Type: application/json" \
  -d @/tmp/comment.json
```

## Anti-patterns specific to the deliverable pipeline

- ❌ **Abstract image subject.** "Neural network with text bubbles."
  "Glowing brain over a city." "Futuristic data flow." All AI-slop.
  randomize-roll a SPECIFIC subject every time.
- ❌ **Skipping the randomize provenance block.** Without the block, u've
  prior-collapsed and only pretended to randomize. The arithmetic IS the discipline.
- ❌ **Generating image variants without asking.** Cost adds up. One
  generation per post unless user confirms more.
- ❌ **Posting the post as a comment w/ html_text.** Plaintext only —
  the user copy-pastes to LinkedIn.
- ❌ **Forgetting to verify file format after openrouter.** JPEG-content-
  with-png-extension breaks Asana rendering.
- ❌ **Naming the subtask vaguely.** "LinkedIn post about Mycroft" is
  worse than "LinkedIn post: Mycroft — Tom Vaillant's journalism AI as
  the early-mover archetype." The angle should be in the title.
- ❌ **Missing the post-as-series link.** When two posts pair, the later
  one should open w/ a reference to the earlier.
- ❌ **Using built-in Anthropic emoji defaults like ✨🚀💡.** Pick
  thematic emojis that earn their place.

## Worked example: this session's two posts

The Mycroft + Open Models pair from the May 2026 session is the canonical
exemplar. Both posts:
- Plain-text, no HTML
- Specific moment opener (Mycroft: "Watch this council website..."; Open Models: "Mycroft is one example.")
- Resource stack w/ thematic emojis (📓 🔗 🪶 for Mycroft; 🌳 🪶 🤖 🧠 🌊 for Open Models)
- Crystallizing flip lines ("The model is the typeface. The craft is the typography." / "Tom shipped his. Ur craft is next.")
- Closer = peer question
- Frog 🐸 identity stamp before closer

Images generated:
- Mycroft: oil painting, cool monochrome blue, 1990s newsroom desk, urgent investigation mood. Specific props: leather notebook, fountain pen, brass magnifying glass, rotary phone, manila file folder, beige desktop computer.
- Open Models: pencil-and-watercolor field journal, botanical forest greens, craftsman's workshop pegboard, table-edge composition. Anchoring detail: apothecary jar w/ hand-lettered label.

Both randomize seeds + arithmetic preserved in the subtask descriptions for
provenance.

## See also

- [/zig-voice](../../zig-voice/SKILL.md) — full voice rules + genre matrix
- [/randomize](../../randomize/SKILL.md) — the protocol this references
- [/openrouter](../../openrouter/SKILL.md) — image-gen mechanics
- [reference/asana-fleet-cheatsheet.md](asana-fleet-cheatsheet.md) — fleet endpoint reference
