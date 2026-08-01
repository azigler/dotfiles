# Pre-registration — does the elaborate `/scrutinize` prompt beat a minimal one?

Written **before** any scored rollout. Frozen. One smoke rollout (`out/SMOKE-P1-B.txt`,
variant B on case P1) was run first to validate plumbing only; it is **excluded from
scoring** and its content did not inform any choice below except confirming the output
contract is obeyed.

## Question

Anthropic's Opus 5 guide says to strip "legacy harness scaffolding that adds separate
verification steps." Audit F (`refs/audit-2026-08-01/F-verification-evidence.md`) settled
the *existence* half against the vendor (56/132 gates non-SHIP). The unsettled half is the
*size* half: **does `/scrutinize`'s 1,446-word hunt-list catch defects a ~200-word
fresh-reviewer prompt misses?**

## Variants

Identical task framing, identical output contract, identical corpus. Only the reviewer
instruction differs.

| | what it is | `wc -w` |
|---|---|---:|
| **A** | the current `/scrutinize` SKILL.md body verbatim (lines 5–279, i.e. everything below the frontmatter) | 2,057 |
| **B** | a minimal fresh-reviewer prompt written for this experiment (`variants/B.md`) | 121 |
| **Z** | **positive-control arm.** Author-stake framing: "you wrote this, the suite passed, confirm it" | 62 |

`variants/CONTRACT.md` (72 words) is appended to all three, so SHIP / FIX-FIRST / REJECT
carry identical definitions and the final-line format is identical across arms.

## Corpus

`~/explore/.claude/skills/ab/evals/bugfix-harvest/` (built by `explore-ldfm`; 62 items
mined from 402 closed `-t bug` beads — nobody authored these for an eval). 8 cases
selected by hand from the 49 positives + 13 canaries, on two criteria:

1. **Inferable in principle from the file alone** — this is the floor guard `explore-lesd`
   demands. Cases whose defect turns on an unguessable external fact (e.g. `bd-fu2s`, a
   Vite/Rollup TDZ) were excluded on inspection.
2. **In the audit-F §2 shape** — a defect a passing test suite structurally cannot see.

| label | case | kind | truth | lines | lang | the defect |
|---|---|---|---|---:|---|---|
| P1 | `dotfiles-c7j` | positive | FIX-FIRST | 105 | bash | ID extraction scrapes the `-r` reason string, so a hyphenated word in the reason false-positive-blocks the close |
| P2 | `hevyd-zrd` | positive | FIX-FIRST | 487 | go | token redaction is pointer-receiver-only — a `Client` **value copy** spills the bearer |
| P3 | `harnessd-sl6` | positive | FIX-FIRST | 227 | go | SSE re-broadcast writes `data: %s` verbatim — a multi-line payload loses its continuation lines |
| P4 | `bd-xtm9` | positive | FIX-FIRST | 498 | bash | final log reports `CAMP_CHANGED` (intent) as "README pushed" (action) |
| P5 | `dotfiles-0lm3` | positive | FIX-FIRST | 239 | bash | `note()`'s `>>` append is not concurrency-safe; two timers in one second interleave |
| N1 | `hevyd-zrd-fixed` | canary | SHIP | 502 | go | paired post-fix revision of P2 |
| N2 | `harnessd-sl6-fixed` | canary | SHIP | 231 | go | paired post-fix revision of P3 |
| N3 | `dotfiles-0lm3-fixed` | canary | SHIP | 244 | bash | paired post-fix revision of P5 |

Cases are presented **line-numbered**, with the corpus's neutral handoff ("This file is
committed and in production use. It is claimed to be correct.") and **nothing else** — no
bead, no repo, no revision, no fleet checkout. The reviewer cannot look anything up.

## N and routing

3 variants × 8 cases × 1 rep = **24 scored rollouts** (rep 2 on A and B, +16, is
authorized up to the 40-rollout cap and will be run only if rep 1 leaves the primary gate
undecided). Each rollout is a fresh `claude -p --model opus` process under its own `HOME`
with credentials **symlinked**, no `CLAUDE.md`, no skills, no hooks, no MCP; cwd is an
empty directory. Frontier skill → frontier model, per `/ab`'s routing rule.

## Metrics — composite, both reported

- **Primary (catch-rate).** On P1–P5: the review **names the actual defect**, in the right
  direction, AND returns FIX-FIRST or REJECT. A finding that touches the key lines with a
  *different* claim is **not** a catch. (Scored `1` catch / `0` miss per rollout.)
- **Co-primary (false-positive rate).** On N1–N3: the review asserts the **paired defect is
  still present**. Per the corpus README, canary ground truth is scoped to the named
  defect, not "this file is flawless." Secondary, reported separately: the raw non-SHIP
  rate on canaries (over-flagging).

## Gates — declared now, not after

1. **Rig-validity gate (positive control), checked FIRST.** `catch(A) − catch(Z) ≥ 2`
   out of 5. If the rig cannot separate a fresh skeptic from an author rubber-stamping
   their own green suite — the single strongest claim the harness makes — then it cannot
   register a framing effect at all, **and the A-vs-B comparison is reported as UNPROVEN
   regardless of what it shows.** This is `explore-oqkq`'s failure mode, declared in
   advance.
2. **Catchability gate (floor guard), checked SECOND.** The best single arm must catch
   **≥ 3 of 5** positives. If both arms tie at the floor, the corpus is uncatchable and
   any null is meaningless — the mirror image of gate 1.
3. **Primary verdict.** Only if gates 1 and 2 pass: `A > B` iff `catch(A) − catch(B) ≥ 2`
   of 5 (≥ 3 of 10 if rep 2 runs); `B > A` symmetrically; otherwise **null on catch-rate**,
   in which case the false-positive axis decides, per `/ab` Step 4c / `explore-kgf0`.

## Grading

Blind. Every scored output is copied to a content-hashed filename with variant and case
stripped; I adjudicate each against the answer key above without knowing which arm produced
it; then unblind by the mapping file. The answer key is the *bug bead's own* `## Problem` /
root-cause prose, written by a human years before this eval existed — not my paraphrase.

## Known threats, declared in advance

- **No tools.** The file is inlined, so no arm can execute, grep the repo, or re-run a
  suite. This removes exactly the capability audit F credits for its strongest catches
  (`explore-p5uf`'s executed sandbox escape). The measurement is therefore about the
  hunt-list's effect on **reading** review only, and it is a bound on A's upside, not B's.
- **Language skew** — 3 bash / 2 go among positives; canaries 2 go / 1 bash.
- **I am the grader and I selected the corpus.** I did not write either variant's
  ancestor and have no stake in the outcome, but this is a single ungraded judge, and
  blind-then-unblind is a mitigation, not a fix.
- **n = 5 positives** is small; a 1-case swing is 20 points. The gates are set at 2 cases
  for that reason.
