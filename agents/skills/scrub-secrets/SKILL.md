---
description: Detect + redact high-confidence secrets in the claude-vault tiers (memory files and transcript JSONL / tool-results). A stdlib CLI with two modes — `scan` (report + nonzero exit, usable as a gate) and `redact` (replace each secret with a JSON-safe marker via an atomic, validity-checked rewrite). Layer 0 of the secret-hygiene system (explore-r2iq); the pre-commit hook + periodic memory scan call it.
when_to_use: Before a vault commits (block a secret entering permanent history), on a periodic sweep of the memory tier (catch a leaked literal between commits), or any time you need to find/strip provider credentials that landed in memory/notes/transcripts. Callable by other skills as a CLI — check the exit code (1 = found, 0 = clean).
---

# /scrub-secrets — detect + redact high-confidence secrets

`scrub.py` is the reusable scanner/scrubber that keeps provider credentials out
of the two claude-vault tiers — the tiny curated **memory** files and the
lossy-firehose **transcript** JSONL / `tool-results`. It is Layer 0 of the
secret-hygiene system (spec `explore-r2iq`): the linchpin primitive the higher
layers call — the **pre-commit hook** (Layer 1, block a secret from entering
git history on either vault) and the **periodic memory scan** (Layer 2, catch a
leaked literal between commits and file a P1 `human:` bead).

Stdlib-only (the optional gitleaks backend is a subprocess). No daemon, no index.

## CLI

```
python3 scrub.py scan   <paths...> [--entropy] [--gitleaks] [--exclude P] [--quiet]
python3 scrub.py redact <paths...> [--apply]  [--exclude P] [--quiet]
```
(`scrub.py` carries a `#!/usr/bin/env python3` shebang, so `./scrub.py …` works too.)

| Mode / flag | Effect |
|---|---|
| `scan` | Report each file + per-pattern match counts. **Exit 1 if any found, 0 if clean** — drop-in as a gate. Never echoes the raw secret value. |
| `redact` | Replace each secret with the marker `[REDACTED-SECRET]`. **Dry-run by default** (prints what it *would* change, writes nothing). |
| `--apply` | `redact`: actually perform the write (atomic + validity-checked, below). |
| `--exclude P` | Skip file `P` (repeatable) — e.g. the active session mid-write. |
| `--entropy` | `scan` only: ALSO report high-entropy token runs, allowlist-filtered (below). Detect-only — never used by redact. |
| `--gitleaks` | `scan` only: ALSO fold in gitleaks findings (maintained ruleset), deduped by file:line. Falls back to the custom scan if gitleaks is absent. |
| `--quiet` | Suppress per-file lines; keep the summary + exit code. |

Paths may be files or directories; directories are walked for `*.jsonl`,
`*.txt`, `*.md`.

## What it detects — deliberately HIGH-CONFIDENCE only

The patterns are distinctive secret shapes, each unambiguous enough that a match
is overwhelmingly a real credential (safe to overwrite in place):

- `Bearer <40+ token>` (redaction keeps the `Bearer ` prefix, strips only the token)
- Google client secret `GOCSPX-…`, refresh token `1//0…`, API key `AIza…`
- GitHub `ghp_/gho_/ghu_/ghs_/ghr_…` + `github_pat_…`
- Anthropic `sk-ant-…`, OpenAI `sk-proj-…`
- AWS access-key id `AKIA…`, Slack `xox[baprs]-…`, GitLab `glpat-…`
- `-----BEGIN … PRIVATE KEY-----` blocks

**Why no entropy in `redact`:** at 2 GB transcript scale a raw entropy scan
false-positives on doc-ids / base64 / hashes, and a false positive in REDACT
mode *corrupts real content*. So redaction is prefix/shape-only. Entropy is a
scan-only concern, opt-in behind `--entropy`, for human review — never a write.

## The safety guarantee — JSON-safe atomic rewrite

`redact --apply` never leaves a file half-written or a JSONL line broken:

1. The marker `[REDACTED-SECRET]` is **JSON-safe** — no quotes, backslashes, or
   control chars — so a raw byte-replace *inside* a JSON string value keeps the
   line valid.
2. Per file it writes a temp copy, then verifies **(a)** the `\n` line count is
   unchanged and **(b)** for a `.jsonl`, every line still `json.loads()`-parses —
   and only then `os.replace()`s atomically. Any check fails → the temp is
   discarded and the **original is untouched** (reported as `SKIP(unsafe)`).
3. The validity check splits on `"\n"` **only**, never `str.splitlines()` —
   which over-splits on `\r` / U+2028 / U+2029 / U+0085 that legitimately appear
   *inside* a JSON string value, producing a false "unparseable" that would skip
   a perfectly safe redact. (This was a real bug; `tests/test_scrub.py` guards
   it — `test_splitlines_regression_*` and `test_safe_rewrite_no_splitlines_oversplit`.)

## The benign-shape ALLOWLIST

A module-level allowlist names the shapes today's manual scan had to
hand-classify as *not* secrets, so a broader/entropy scan won't false-positive
on them. A token is suppressed iff it FULLMATCHES one:

- **Google Doc / Drive IDs** — 44 chars, `1[A-Za-z0-9_-]{43}`
- **`$ENV_VAR` / `${ENV_VAR}` refs** — the good pattern (pointer, not literal)
- **`~/…` path pointers** — a location, never the secret itself
- **git shas** — 40-hex sha1 / 64-hex sha256
- **UUIDs** — `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`

The high-confidence patterns already avoid these (distinctive prefixes), so on
the default scan the allowlist is a no-op. It becomes load-bearing under
`--entropy`: a high-entropy 44-char Doc ID *would* trip an entropy detector, and
the allowlist is what suppresses it (`test_entropy_hits_filters_allowlisted_tokens`).

## The gitleaks backend (optional, detect-only)

`--gitleaks` additionally runs `gitleaks detect --source <path> --no-git
--redact --report-format json` (using `gitleaks` on PATH, else
`~/.local/bin/gitleaks`) and folds its findings into the scan report, **deduped
by file:line** against the custom scan's hits. This gives Layer 0 a maintained
ruleset as a second opinion. It is **detect-only** — gitleaks findings raise the
scan's match count / exit code but `redact` still operates on the custom
high-confidence patterns only (never gitleaks output). If gitleaks isn't
installed, the custom scan is the fallback and the run **never hard-fails** —
it warns `gitleaks: not-found (custom scan only)` and continues.

## Role in the system (explore-r2iq)

- **Layer 0 (this tool)** — the reusable scan/redact primitive.
- **Layer 1 — block:** wire `scrub.py scan` as a pre-commit hook on both vaults
  (memory + transcripts); any commit introducing a secret is blocked.
- **Layer 2 — detect:** a session-end / daily-pulse `scrub.py scan` of the
  memory tier (cheap, ~1.4 MB); a NEW secret vs a last-clean baseline files a P1
  `human:` bead + push.
- **Layer 3 — prevent:** the memory-writing convention (secrets live in
  `~/.secrets`, referenced by `$ENV` / pointer, never a literal).

For what is ALREADY in committed transcript history, redaction can't un-write
git — **rotation** is the backstop; `scan` is how you find what to rotate.

## Tests

`pytest -q tests/` — subprocess-drives `scan`/`redact` against a tmp fixture
tree (never a real memory file), plus import-level guards for the allowlist,
`safe_rewrite`'s validity contract, and the splitlines regression. The gitleaks
tests skip cleanly when the binary is absent; a fallback test forces absence
(`PATH`/`HOME` override) to prove the never-hard-fail contract.

## Callable by other skills

`scrub.py` is a plain stdlib CLI. Callers branch on the exit code (1 = secret
found, 0 = clean) — the gate contract Layers 1 and 2 build on.
