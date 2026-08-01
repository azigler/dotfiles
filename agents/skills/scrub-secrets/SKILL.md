---
description: Detect + redact secrets in the claude-vault tiers (memory files and transcript JSONL / tool-results) with two detectors — high-confidence provider-prefix patterns AND a live-value denylist derived at runtime from `~/.secrets`. Stdlib CLI — `scan` (nonzero-exit gate), `redact` (atomic, validity-checked JSON-safe rewrite), `denylist` (decision table — names + verdicts, never values).
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
                                   [--secrets-file P] [--no-denylist]
python3 scrub.py redact <paths...> [--apply]  [--exclude P] [--quiet]
                                   [--secrets-file P] [--no-denylist]
python3 scrub.py denylist          [--secrets-file P]
```
(`scrub.py` carries a `#!/usr/bin/env python3` shebang, so `./scrub.py …` works too.)

| Mode / flag | Effect |
|---|---|
| `scan` | Report each file + per-detector match counts. **Exit 1 if any found, 0 if clean** — drop-in as a gate. Never echoes the raw secret value. |
| `redact` | Replace each secret with the marker `[REDACTED-SECRET]`. **Dry-run by default** (prints what it *would* change, writes nothing). |
| `denylist` | Print the live-value denylist decision table — variable NAME, value length, and the filter verdict (`ADMIT` / `too-short` / `integer` / `url` / `whitespace` / `pointer`). Never prints a value. Exit 0, or 2 if the source file is unreadable. |
| `--apply` | `redact`: actually perform the write (atomic + validity-checked, below). |
| `--exclude P` | Skip file `P` (repeatable) — e.g. the active session mid-write. |
| `--secrets-file P` | Source for the live-value denylist. Default `$SCRUB_SECRETS_FILE`, else `~/.secrets`. |
| `--no-denylist` | Disable the live-value denylist (prefix patterns only). |
| `--entropy` | `scan` only: ALSO report high-entropy token runs, allowlist-filtered (below). Detect-only — never used by redact. |
| `--gitleaks` | `scan` only: ALSO fold in gitleaks findings (maintained ruleset), deduped by file:line. Falls back to the custom scan if gitleaks is absent. |
| `--quiet` | Suppress per-file lines; keep the summary + exit code. |

Paths may be files or directories; directories are walked for `*.jsonl`,
`*.txt`, `*.md`.

**Exit-code contract (unchanged, and load-bearing for the vault):** `scan` and
`redact` return **0 = clean**, **1 = found**, anything else = the tool is broken
(`scrub-continue.sh` fails the run rather than committing blind). Adding the
denylist did not widen that set: an unreadable `~/.secrets` degrades to
"denylist unavailable" and is *reported*, never an exit-code change.

## The two detectors

`scan` and `redact` both run **two** detectors. Neither subsumes the other —
patterns cover credentials this box has never seen; the denylist covers
credentials with no recognisable shape.

| | 1. PATTERNS | 2. LIVE VALUE DENYLIST |
|---|---|---|
| What | distinctive provider prefixes / shapes | the actual values in `~/.secrets` |
| Sees | any issuer's `sk-ant-…`, `ghp_…`, `AKIA…` | anything on this box, prefix or not |
| Misses | a token with no prefix (an opaque 64-hex API key) | a credential not in `~/.secrets` (a colleague's key pasted into a session) |
| FP risk | very low (shape-anchored) | **none** (verbatim equality with a known credential) |
| In `redact`? | yes | **yes** — see below |

### Why the denylist exists (explore-wmlc, 2026-07-28)

Measured against the real `~/.secrets`: **22** exported variables, **3** detected
by the patterns. The vault's admission gate consumed that exit code, so a file
carrying the other 19 passed as clean.

The dangerous part was the *fix*, not the failure. The gate and the redactor share
the detector. A transcript that had captured the whole of `~/.secrets` was
correctly **BLOCKED** — but the moment the deferred redaction ran it would have
stripped the 3 visible credentials, the gate would then have **passed**, and the
transcript (still carrying the rest) would have been committed and pushed to git
permanently. *A blocked tier that later self-clears into a push is worse than one
that stays blocked.* "Gate passed" meant "no high-confidence prefix matched", not
"no secret present", and the vault treated those as the same sentence.

### Why it is safe in `redact` too — and why that is the point

Exact equality with a value that is *known* to be a credential cannot false-
positive, so the objection that keeps entropy out of redact does not apply. That
is not a nicety: a detector that can only **detect** what it cannot **remove**
stalls the vault forever (the 121-run stall of 2026-07-26). The denylist closes
the loop — the blocked transcript gets scrubbed clean instead of merely flagged.

### The shape rule (inspect it with `scrub.py denylist`)

A parsed `export NAME=VALUE` is ADMITTED unless it is obviously a non-credential
that would collide with ordinary content:

| Verdict | Rejects | Real example |
|---|---|---|
| `too-short` | `len < 20` | `R2_BUCKET`, `GAMMA_DEFAULT_THEME_ID` |
| `integer` | all digits | `HEVY_TOKEN_EXPIRES_AT` |
| `url` | `scheme://…` | `CDN_BASE_URL` |
| `whitespace` | contains any whitespace | a phrase, not a token |
| `pointer` | `$VAR` / `${VAR}` / `~/…` / `/…` | a reference, not a literal |

The rule is **shape-based on purpose — it never looks at the variable name**, so
it cannot be fooled by a credential that happens to be called `…_ID`
(`R2_ACCESS_KEY_ID` is a real credential; `R2_ACCOUNT_ID` is a quasi-public
identifier and *is* admitted). Erring that way is deliberate: a false positive
costs one redacted identifier inside a private vault; a false negative costs a
live credential in permanent git history.

⚠️ **The ALLOWLIST is deliberately NOT applied to the denylist.** `is_allowlisted`
exists to tame a *heuristic* (entropy); its `git-sha` rule matches any 40/64-hex
run, and three of the real credentials in `~/.secrets` are exactly 64 hex
characters. Filtering the denylist through it would silently discard them
(`test_allowlist_does_not_eat_hex_credentials`).

### The privacy contract

The list is built **at run time and discarded**. It is never written to disk, a
temp file, a ledger, or a log. A hit is reported as the key
`secrets-file:<NAME>` — the variable **name** and a count. `denylist` mode prints
names, lengths and verdicts. **No value ever reaches stdout, stderr, or the vault
redaction ledger.** Two tests assert exactly this by scanning the whole combined
output for each fixture value.

### The third state — "unavailable" is reported, not silently clean

Every summary line names the detectors that actually ran:

```
== scan: 0 files with matches, 0 secret matches  [detectors: 13 patterns + 16 live-values from /home/ubuntu/.secrets] ==
== scan: 0 files with matches, 0 secret matches  [detectors: 13 patterns; live-value denylist UNAVAILABLE:FileNotFoundError] ==
```

and the unavailable case additionally prints a greppable
`WARN: scrub: live-value denylist UNAVAILABLE …` to stderr, which the vault call
sites forward to `~/.claude/vault-sync.log`. This is the three-valued rule: a
reader can tell *clean under both detectors* from *clean under a narrow one*. The
line is deliberately brace-free — `scrub-continue.sh`'s per-file parser keys on a
trailing `{...}` counts dict (`test_summary_line_has_no_braces`).

**Measured cost:** one `str.count` pass per admitted value. On the largest
transcript on this box (95 MiB, 16 admitted values) a scan went from **7.8 s to
8.7 s** — about +12%. The vault scans an hourly delta, not the 3.7 GB corpus.

**Residual gap, stated plainly:** the denylist covers credentials **that are in
`~/.secrets` at scan time**. A credential that lives somewhere else — a `.env` in
a project, a key a human pasted straight into a session, a colleague's token —
is still only covered by the prefix patterns. Point `--secrets-file` at another
file to widen it; `SCRUB_SECRETS_FILE` sets the default.

### Why `--entropy` is still NOT on in gate mode

Tempting, and wrong here. Measured on one 1.8 MB session transcript: **573**
high-entropy hits versus 3 real pattern matches. Under scrub-and-continue an
entropy hit cannot be redacted (false positives corrupt content), so it would
survive the redact pass, reach the fail-closed pre-commit hook, and block —
every run, forever. That is precisely the 121-consecutive-run stall that
`dotfiles-t6sd` fixed. Entropy stays opt-in and human-reviewed; the denylist is
the instrument that widens the gate *without* re-arming the stall.

## What the patterns detect — deliberately HIGH-CONFIDENCE only

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
mode *corrupts real content*. So redaction is prefix/shape-only **plus exact
live-value matches** (which carry no false-positive risk). Entropy is a
scan-only concern, opt-in behind `--entropy`, for human review — never a write
(`test_redact_still_refuses_entropy`).

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

It is **never** applied to the live-value denylist — see the ⚠️ above; `git-sha`
would eat any 64-hex credential.

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
- **Layer 1 — scrub-and-continue, then block what could not be scrubbed**
  (revised 2026-07-26, dotfiles-t6sd; Zig's call as owner of these PRIVATE vaults).
  Before staging, `agents/vault/scrub-continue.sh` runs `scan` over the staged set
  and `redact --apply` over the hits, so the vault **keeps pushing** with the
  secret removed. The `scrub.py scan` pre-commit hook on both vaults is unchanged
  and still fail-closed — it is now the **backstop** for what redaction could not
  fix (an unparseable `.jsonl` that `safe_rewrite` refuses to rewrite, a live
  transcript excluded from rewriting, a broken redactor). The prior behaviour —
  block first and only — stalled the transcripts vault for 121 consecutive runs
  over five days, with nothing able to clear it unattended. Redaction is not
  rotation: every redaction row lands in `~/.claude/vault-redactions.jsonl` and
  in the sync verdict precisely so the event stays visible now that it no longer
  halts anything.
- **Layer 2 — detect:** a session-end / daily-pulse `scrub.py scan` of the
  memory tier (cheap, ~1.4 MB); a NEW secret vs a last-clean baseline files a P1
  `human:` bead + push.
- **Layer 3 — prevent:** the memory-writing convention (secrets live in
  `~/.secrets`, referenced by `$ENV` / pointer, never a literal).

For what is ALREADY in committed transcript history, redaction can't un-write
git — **rotation** is the backstop; `scan` is how you find what to rotate.

## Tests

`pytest -q tests/` — **70 tests**. Subprocess-drives `scan`/`redact` against a tmp
fixture tree (never a real memory file), plus import-level guards for the
allowlist, `safe_rewrite`'s validity contract, and the splitlines regression. The
gitleaks tests skip cleanly when the binary is absent; a fallback test forces
absence (`PATH`/`HOME` override) to prove the never-hard-fail contract.

`tests/test_denylist.py` (27) covers the live-value denylist and never reads the
real `~/.secrets` — every test points `--secrets-file` at a synthetic file it
wrote itself, which is what proves the rule **generalises** instead of
special-casing one machine. It asserts the shape rule case by case, the
allowlist-must-not-apply trap, that the same fixture passes under
`--no-denylist` (the regression itself), that no fixture value ever appears in
the combined output, that `redact --apply` removes the values and the re-scan is
then clean with the line count and JSONL validity intact, and that entropy is
still refused in redact.

## Callable by other skills

`scrub.py` is a plain stdlib CLI. Callers branch on the exit code (1 = secret
found, 0 = clean, anything else = broken) — the gate contract Layers 1 and 2
build on, unchanged by the denylist. Callers that log the run should keep the
`[detectors: …]` summary line: it is the only thing that distinguishes a real
all-clear from an all-clear produced by a narrowed detector.
