# DRAFT — upstream report: `br list --status <unrecognized>` silently returns empty

Bead: `dotfiles-aavn` (rescoped from `dotfiles-dbrq`, cross-referenced
`autonoveld-08uj`). Filed upstream: see "Filed" section below.

## Summary

`br list --status <value>` treats any unrecognized status value — including
the intuitive guess `all` — exactly like a real filter that happens to match
zero issues: exit code 0, empty result. There is no error, warning, or hint
that the value was invalid. This is silent-empty-on-typo, and it bit twice
independently (`dotfiles-dbrq`, `autonoveld-08uj`) in decision-harvest code
that treats "empty" as "nothing to report" — a caller cannot distinguish a
real empty result from a rejected filter.

The inconsistency that makes `all` a natural guess in the first place: `br
lint --status` **does** support the literal value `all` and documents it
("`-s, --status <STATUS> Filter by status (default: open, use 'all' for
all)`" — from `br lint --help`), while `br list --status` has no such
sentinel and no such documentation ("`-s, --status <STATUS> Filter by status
(can be repeated)`" — from `br list --help`). Two subcommands of the same
CLI, same flag name, different accepted vocabulary, no cross-reference in
either `--help` output.

## Environment

- `br --version` → `br 0.2.16`
- Reproduced in `~/dotfiles` (578 total issues via `br list -a`) and
  independently in `~/autonoveld` (9 decision-type issues total).

## Repro

```console
$ br list --status all
$ echo $?
0
$ br list --status zzzz
$ echo $?
0
$ br list -a | wc -l
578
$ br list --status open --status closed | wc -l
578
```

`all` and `zzzz` (an unambiguous typo) produce byte-identical output: nothing,
rc 0. There is no way, from the output alone, to tell "filter matched zero
issues" apart from "filter was not a real status and therefore matched
nothing by construction."

Contrast with `br lint`, where `all` is a real, documented sentinel:

```console
$ br lint --status all | head -1
Template warnings (57 issues, 70 warnings):
```

## Impact

`/offboard`'s decision-harvest step (this repo) and an equivalent step in
`autonoveld` both independently reached for `--status all` as the obvious way
to say "don't filter by status, give me open and closed decision beads."
Caught live in `autonoveld` on 2026-07-28: a `mail` pulse tick's harvest
query returned empty while `autonoveld-f7co` (a decision bead) was visible in
that same tick's own `br list` output — the only reason the silent failure
surfaced was a coincidental cross-check, not any signal from `br` itself. A
session without that coincidence would truthfully report "no decisions made"
into a durable handoff note while real decision beads sat in the database.

## Fix options (either resolves the silent-empty; (1) is stronger)

1. **Reject an unrecognized `--status` value** on `br list` (and any other
   subcommand accepting `--status` without the `all` sentinel) with a
   nonzero exit and the list of valid status values. This is the general
   fix — it also catches plain typos (`--status opne`), not just the `all`
   guess.
2. **Make `all` a recognized sentinel on `br list`**, matching `br lint`'s
   existing behavior, and document it in `br list --help`. This closes the
   specific footgun but leaves every other typo silently green.

## Workaround (in use now)

```bash
br list -a                              # explicit "all statuses" flag
# or
br list --status open --status closed   # explicit union
```

`~/dotfiles/agents/skills/offboard/SKILL.md` (this repo's decision-harvest
step) already uses `-a` — fixed at commit `8b5017c`, 2026-07-27, predating
this report. A repo-wide grep on 2026-08-09 (`dotfiles-aavn`) found no other
live caller in `~/dotfiles` still passing `--status all`; the `autonoveld`
catch on 2026-07-28 post-dates that fix chronologically but reflects a
session running on a stale pre-fix snapshot of the (globally symlinked)
skill, not a second bug site in code.

## Filed

Filed against `Dicklesworthstone/beads_rust` under Zig's (`azigler`) `gh`
identity: **https://github.com/Dicklesworthstone/beads_rust/issues/418**
