# Answer key — frozen before grading

Derived from each bug bead's own `## Problem` / root-cause prose (written by a human when
the bug was fixed, long before this eval existed), not from my reading of the file.

A rollout **catches** a positive only if its findings state the claim below **in the right
direction**. Touching the key lines with a different claim is **not** a catch — recorded as
`near-miss` in the verdicts file so the distinction is auditable.

---

**P1 — `dotfiles-c7j`** (key lines 58–59)
> ID extraction takes *everything* after `br close` up to the first shell separator —
> **including the `-r "<reason>"` string and its flag** — and then filters tokens against
> the bead-ID regex. A hyphenated word or dotted filename inside the close reason
> (`"Fixed fleet-wide via the new driver"`) matches, is linted as a bead ID, is not found,
> and the close is **false-positive blocked**.

CATCH requires: naming that reason-string / post-flag tokens leak into the ID set and cause
a spurious block. NOT a catch: "the regex misses valid IDs" (opposite direction), or
"`head -1` picks the wrong `cd`", or generic looseness of the `case` glob.

---

**P2 — `hevyd-zrd`** (key lines 56, 60, 126)
> The client's token redaction is **method-set-limited**: the redacting method is declared
> on a pointer receiver (and/or `fmt`'s `Stringer` does not cover `%#v`), so a **value copy
> of the client — or a `%#v`-style print — spills the raw bearer token**.

CATCH requires: naming that redaction fails for a value copy / non-pointer use / a verb the
`String()` method does not cover, leaking the token. NOT a catch: "the token is stored in a
struct field" or generic "log hygiene" advice with no receiver/verb mechanism.

---

**P3 — `harnessd-sl6`** (key line 156)
> `writeSSEFrame` writes the payload verbatim as `data: %s`. A **multi-line** payload
> therefore emits continuation lines with **no `data: ` prefix**, which the SSE parser
> drops — the client sees a truncated entry. Fix: split on `\n`, prefix each line.

CATCH requires: naming multi-line/embedded-newline data breaking the SSE framing. NOT a
catch: "no flush", "no error check on Fprintf", "event name not escaped".

---

**P4 — `bd-xtm9`** (key lines 426, 495)
> The final summary log interpolates `CAMP_CHANGED` — an **eligibility/intent** flag — into
> the `README pushed=` field, rather than whether the push actually ran and succeeded. The
> push lives inside a branch that can be skipped entirely, and the `|| log "WARNING …"`
> makes a real failure non-fatal, so the line can report `pushed=true` when nothing pushed.

CATCH requires: naming that the reported `README pushed` value does not track the actual
push (wrong variable / intent-not-action / swallowed failure). NOT a catch: generic "add
more logging" or "this script has no `set -e`".

---

**P5 — `dotfiles-0lm3`** (key line 78)
> `note()`'s `>> "$LOG"` append is **not concurrency-safe**. Two timers firing in the same
> second interleave and mangle each other's lines, so a tick's record becomes unreadable
> and reads downstream as a *missing* row.

CATCH requires: naming the concurrent-append / no-locking hazard on the log write. NOT a
catch: "the log has no rotation", "timestamps lack sub-second precision".

---

**N1 / N2 / N3 — canaries** (post-fix revisions of P2 / P3 / P5)

Ground truth is **scoped**: "the named defect is absent, and a regression test asserts so"
— *not* "this file is flawless" (corpus README, threat 6).

A **false positive** is recorded only when the review asserts the **paired defect is still
present** (N1: the token still spills on a value copy / uncovered verb; N2: multi-line SSE
data still loses its continuation lines; N3: the note append is still unsynchronised).

Recorded separately, as a secondary over-flagging measure: the **raw non-SHIP rate** on
canaries, whatever the finding was about.
