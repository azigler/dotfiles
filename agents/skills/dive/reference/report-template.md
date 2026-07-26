# /explore report template — canonical section structure

The shape that's been working across this session's /explore runs
(Talkie, Pi/DeepAgents, Open Models, Mycroft). Use it as the default
skeleton; deviate only when the topic genuinely demands.

## Section headers (use `== Title ==` form for plaintext scannability)

```
== TL;DR ==

[2-4 sentences: what the cluster of sources is about, what the
strongest takeaway is, what the user's specific question maps to.
Lead w/ the verdict if there's a yes/no question. Quote the
sharpest single line from the sources if there is one.]

== What each is ==

[Per-source detail. One titled subsection per source.]

SOURCE NAME (Author, date, license)
- Bullet 1 (capability / scope)
- Bullet 2 (architecture / parameter count / specific number)
- Bullet 3 (license / pricing / availability)
- Bullet 4 (target deployment / hardware / audience)
- Bullet 5+ (specific quotes, novel claims, surprising findings)
- Caveats / limitations / vendor-supplied stats flagged as such

[Repeat for each source. Keep names ALL CAPS for scan-ability.]

== Pattern across them ==

[Numbered list of cross-cuts. What's converging? What's diverging?
What's the SHAPE of the moment? Architectural / licensing / pricing
/ deployment / methodology patterns that show up in multiple sources.
3-7 bullets — if you find more than 7, you're padding.]

== Yes/no answer ==

[ONLY if the user asked a specific question. Lead w/ yes or no in the
first sentence, then the qualified answer. If the user just said
"explore these", skip this section.]

== Models / projects / sources you missed ==

[ALWAYS include this section. The user gave you N URLs. There are
adjacent N more that belong in the picture. Name them, link them,
say briefly why each belongs. This is /explore's signature value-add
— it's the section that proves you went past the brief.]

== Related explorations ==

[REQUIRED in archival mode (the Step 3.5 output). The prior
~/explore/<sibling>/ explorations this topic connects to. One bullet
each: the sibling (relative link in the FINDINGS.md copy) + the
CONNECTION in one line — agrees / extends / contradicts / remixes.
This is the connective tissue; "see also" with no stated connection
does NOT count. If the grep genuinely found no siblings, say so
explicitly ("no adjacent prior explorations — this opens a new
cluster") rather than omitting the section.]

== What you should learn ==

[Numbered, 4-7 takeaways tied to the user's broader work — their
harness, their content lineage, their LinkedIn cadence, their LinearB
context, their research interests. Be specific about applicability:
"you can map this to /grok writing -t note beads", not "this is
relevant to your work".]

== Novel opportunities ==

[REQUIRED in archival mode. The max-effort ideation output (see
/explore Effort §: a fresh Workflow agent at effort:'max', unpolluted
by the convergent writeup). Each opportunity: the non-obvious idea /
connection, the concrete move it implies, rough effort
(weekend/week/month/research-arc), and the main risk / reason-not-to.
This is where the loop EXTRACTS opportunity instead of just cataloguing
"what is this." Historically skipped 100% of the time — do not skip it.
AIM the actionable upside per the "Where the opportunity should land"
section: at an ACTIVE arc (LinearB / AAIF / the harness / a recently-
touched ~/explore folder, decided by recency), as a GENERAL harness move,
or NOT AT ALL — the mud/golem/local-coding-models/Hermes-local arc is
TABLED (a source to reason from, never a destination). And "interesting
for its own sake — no build here, the value is comprehension" is a valid,
honest entry; never manufacture a strained tie-back to justify the run.]

== Possible social-post angles ==

[Always include for /explore — the user's content cadence is part of
their workflow. Suggest STRONGEST → SECONDARY → AVOID. Be honest
about which angles fit your audience and which are weaker. Don't
pitch a post you wouldn't write yourself.]

== Sources ==

Provided:
- url 1 (note if fetch failed and how recovered)
- url 2
- ...

Adjacent / additional:
- url
- ...

[Background / infrastructure if relevant:]
- url
- ...

[Archival mode only — the final line:]
Archived: ~/explore/<topic>/ (FINDINGS.md)
```

## Tone in the report

- Plaintext, no markdown bold/italic. Section headers use `== Title ==`.
- Address the user as "you" — CLEAN PROFESSIONAL PROSE, not zig voice. The
  report is a work artifact read by future agents + the brain, not a post.
  (The old "u"/"ur" casual register was legacy drift that contradicted
  SKILL.md's CRITICAL voice-scope section; corrected 2026-06-29. Zig voice is
  ONLY for the Step 6 LinkedIn-post deliverable.)
- Don't pad. Cite what you found. Leave gaps as gaps.
- Quote specific numbers + named individuals where they sharpen the
  point. ("Vinod Khosla quote", "Sebastian Raschka analysis", "Will
  Brown said") beats "an investor noted."
- Vendor-supplied stats: flag them as such ("vendor-supplied, no
  methodology") so the reader knows what to discount.
- Length: 3000-15000 chars typical. Beyond that you're probably padding;
  shorter than 2000 you probably underdid the cross-cuts.
- ALL CAPS sparingly for category names within bullets ("APACHE 2.0",
  "MULTI-SCALE", "ON-DEVICE") — it's a scan-ability tool, not emphasis.

## What goes in TL;DR vs Pattern

- **TL;DR** = the verdict. The reader who reads only this paragraph
  walks away knowing the headline. Lead w/ "Yes" / "No" if there's a
  question.
- **Pattern across them** = the WHY behind the verdict. Convergence
  reasons, structural shifts, who's adopting what.

## What to put in "What you should learn" vs "Possible social-post angles"

- **What you should learn** = applicability to the user's work. Their
  harness, research, content. Specific cross-references to other
  sessions / skills they own.
- **Possible social-post angles** = the audience-facing framing. What
  would you write if you were Andrew? Always honest about which angles fit
  vs which would feel forced.

## Anti-patterns

- ❌ "It's important to note that..." / "It's worth noting..." — pad.
- ❌ Burying the verdict in the third paragraph. Lead w/ TL;DR.
- ❌ Forgetting the "you missed these" section. That section IS the value.
- ❌ Equal weighting of every source. Some sources are richer than
  others. Lean into the richest.
- ❌ Padding "what you should learn" w/ generic AI-trends commentary.
  Tie every bullet to the user's actual work.
- ❌ Suggesting social-post angles you wouldn't actually write. The user
  trusts your taste; don't burn it w/ filler suggestions.
- ❌ Inventing details when a fetch failed. Note the failure honestly,
  link to alternates.

## Reference: this session's runs (use as exemplars)

- **Talkie + Mr. Chatterbox**: Asana task 1208774875668858. Topic:
  vintage LLMs trained on pre-cutoff data. Strong "you missed these"
  layer (nanochat ecosystem, anachronism classifier methodology). Post
  angle: builder-devlog about $500-and-a-weekend scratch-trained model.
- **Pi vs Deep Agents**: Asana task 1214460863767831. Topic: open
  agent harnesses. Sharp "are they interchangeable?" verdict (no,
  different categories). Built side-by-side comparison table. Post
  angle: AGENTS.md convergence story.
- **Open Models cluster**: Asana task 1213911980284273. Topic: April
  2026 open-model wave. Strong consumer-app examples section. "Models
  you missed" surfaced Qwen3 + Phi-4 + Liquid + OLMo + Granite + Nemotron.
  Pairs w/ Mycroft post for concrete-then-abstract LinkedIn series.
- **Mycroft**: Asana task 1208774875668861. Topic: journalism-specific
  AI assistant as the early-mover archetype. Lean report (single primary
  source); leaned on the Open Models report as the broader-context
  cross-reference. Paired post w/ Open Models post.
