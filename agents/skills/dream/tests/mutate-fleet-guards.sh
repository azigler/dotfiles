#!/usr/bin/env bash
# Mutation harness for the FLEET-SCOPE guards in dream.py (dotfiles-xicr).
#
# WHY. This repo's rule 1: a green suite is not evidence that a guard bites;
# only a mutant that dies is. The guards here are the ones whose failure mode is
# SILENCE — a denylist that stops denying still emits clean JSON and exit 0, a
# cap that stops capping just costs more, a --dry-run that starts writing looks
# exactly like one that does not. None of those turn a suite red on their own.
#
# Modelled on agents/scheduler/mutate-tunnel-ownership.sh, including both
# clauses burned in during the dotfiles-ogkz arc:
#
#   * ASSERT THE MUTATION APPLIED. An unapplied pattern makes a red suite
#     indistinguishable from a real kill by exit code alone (dotfiles-47nf), so
#     a pattern that does not match — or a file unchanged afterwards — is a
#     HARNESS ERROR, not a kill.
#   * A KILLED MUTANT MUST FAIL THE CASE(S) IT NAMES. Red-somewhere says nothing
#     about the guard under test and is usually evidence the mutant broke
#     something else (dotfiles-77s4). Each mutant below names its detectors and
#     ONLY those are run.
#
# Two mutants deliberately name FEWER cases than they break, and the comments
# say why: a case that survives because a SECOND layer held is the
# defence-in-depth claim working, not a weak test. `denylist-both` is the mutant
# that removes every layer at once.
#
# Usage:  bash agents/skills/dream/tests/mutate-fleet-guards.sh [skill-dir]
# Runtime: ~25s (17 mutants, each running only its named cases).
set -uo pipefail

SRC=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
[ -f "$SRC/dream.py" ] || {
  echo "mutate: FAIL — no dream.py under $SRC" >&2
  exit 1
}
if ! python3 -c 'import pytest' >/dev/null 2>&1; then  # allow-suppress
  echo "mutate: FAIL — pytest is not importable; the harness cannot run" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILED=0
KILLED=0
SEP='|@MUT@|'

echo "=== BASELINE (must be green, or every kill below is meaningless) ==="
cp -a "$SRC" "$WORK/baseline"
if ! (cd "$WORK/baseline" && python3 -m pytest tests -q | tail -2); then
  echo "mutate: FAIL — baseline suite is not green; fix that first" >&2
  exit 1
fi

echo "=== MUTANTS ==="
mutant() { # <name> <old|@MUT@|new> <named test id> [more ids...]
  local name=$1 expr=$2
  shift 2
  local d="$WORK/$name"
  rm -rf "$d"
  cp -a "$SRC" "$d"

  MUT_EXPR=$expr MUT_SEP=$SEP python3 - "$d/dream.py" <<'PY'
import os, sys
path = sys.argv[1]
old, new = os.environ["MUT_EXPR"].split(os.environ["MUT_SEP"])
src = open(path, encoding="utf-8").read()
if old not in src:
    sys.stderr.write("HARNESS ERROR: mutation pattern not found in source\n")
    sys.exit(9)
open(path, "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "!! $name: HARNESS ERROR — mutation did not apply"
    FAILED=1
    return
  fi
  if diff -q "$SRC/dream.py" "$d/dream.py" >/dev/null; then
    echo "!! $name: HARNESS ERROR — file unchanged after mutation"
    FAILED=1
    return
  fi

  local out
  out=$(cd "$d" && python3 -m pytest "$@" -q 2>&1 | tail -3)
  if echo "$out" | grep -qE '^[0-9]+ passed'; then
    echo "!! $name: SURVIVED — its named case(s) still pass"
    echo "$out" | sed 's/^/     /'
    FAILED=1
  else
    KILLED=$((KILLED + 1))
    echo "OK $name — killed by: $*"
    echo "$out" | grep -oE '[0-9]+ failed[^,]*' | head -1 | sed 's/^/     /'
  fi
}

F=tests/test_dream_fleet.py

# 1. the slug-level denylist stops denying.
# NOT named against test_denylisted_slug_dir_is_never_traversed, which survives
# this CORRECTLY: guard_path() is the second layer and still refuses the dir.
mutant denylist-slug \
  $'            if is_confidential_path(slug):|@MUT@|            if False:' \
  $F::test_denylisted_slug_never_appears_in_fleet_output

# 2. the content-level layer stops dropping denied mentions
mutant denylist-text \
  $'    kept = [\n        c for c in candidates if not is_confidential_path(c.get("text", ""))\n    ]|@MUT@|    kept = list(candidates)' \
  $F::test_denied_text_is_dropped_from_candidates \
  $F::test_drop_confidential_text_unit

# 3. fleet stops being the default — the silent regression to CURRENT-SLUG-ONLY
mutant fleet-default \
  $'    fleet = args.slug is None if args.fleet is None else bool(args.fleet)|@MUT@|    fleet = False if args.fleet is None else bool(args.fleet)' \
  $F::test_fleet_iterates_every_permitted_slug

# 4. every slug's proposals get planned into every repo (bead-location violation)
mutant filing-target \
  $'        cands = by_slug.get(sc.slug, [])|@MUT@|        cands = list(candidates)' \
  $F::test_filing_plan_targets_each_repos_own_store \
  $F::test_storeless_repo_is_a_loud_skip

# 5. the loud skip goes quiet
mutant loud-skip \
  $'        if row["store_ok"] or not row["n_candidates"]:\n            continue|@MUT@|        if True:\n            continue' \
  $F::test_storeless_repo_is_a_loud_skip

# 6. an ambiguous store gets a guessed --db instead of cwd-filing
mutant store-guess \
  $'    db = dbs[0] if len(dbs) == 1 else None|@MUT@|    db = dbs[0] if dbs else None' \
  $F::test_ambiguous_store_offers_cwd_not_a_guessed_db

# 7. the cross-slug self-flag never fires
mutant cross-slug-flag \
  $'        if len(set(slugs)) >= 2:|@MUT@|        if False:' \
  $F::test_cross_slug_recurrence_self_flags

# 8. the cross-slug clause of the recurrence bar never fires
mutant cross-slug-bar \
  $'    if len(slugs) >= 2:|@MUT@|    if False:' \
  $F::test_bar_two_slugs_qualifies \
  $F::test_remember_records_slugs_and_qualifies_cross_slug

# 9. the per-slug cap is ignored (one loud slug spends the global budget)
mutant per-slug-cap \
  $'        cands, _ = interleave_by_seam(cands, max(0, args.max_per_slug))|@MUT@|        pass' \
  $F::test_max_per_slug_caps_each_slug_independently

# 10. --max-slugs is ignored (18 slugs = 18x the tick)
mutant max-slugs \
  $'        chosen = scan.slugs[: max(0, args.max_slugs)]|@MUT@|        chosen = list(scan.slugs)' \
  $F::test_max_slugs_caps_iteration_newest_first

# 11. the global cap sorts-then-truncates instead of round-robining (explore-j2p9)
mutant round-robin \
  $'        buckets.setdefault(k, []).append(c)|@MUT@|        buckets.setdefault(("all", "all"), []).append(c)' \
  $F::test_global_cap_round_robins_across_slugs

# 12. --dry-run's write guard stops refusing
mutant write-guard \
  $'    if _NO_WRITE:\n        raise WriteRefused(f"--dry-run: refusing to write {what}")|@MUT@|    return' \
  $F::test_dry_run_write_guard_actually_bites

# 13. skill-history becomes per-slug: N copies of one harness finding, and the
# self-corroboration inflates n_sources, which the recurrence bar reads.
# (test_global_seam_files_into_the_harness_repo is NOT named — the seam passes
# slug=FLEET_SLUG itself, so the filing target survives this mutant.)
mutant global-seam \
  $'GLOBAL_SEAMS = frozenset({"skill-history"})|@MUT@|GLOBAL_SEAMS = frozenset()' \
  $F::test_global_seam_runs_once_not_once_per_slug

# 14. denied slugs get NAMED in the emitted artifact. Note the shape: this
# mutant must stay a WORKING program (it reports names instead of a count), not
# a NameError — a mutant that breaks the script globally kills tests for the
# wrong reason and proves nothing about the guard (dotfiles-77s4).
mutant denied-names \
  $'    return SlugScan(ordered, len(denied), len(seen) + len(denied))|@MUT@|    return SlugScan(ordered, sorted(denied), len(seen) + len(denied))' \
  $F::test_denylisted_slug_never_appears_in_fleet_output

# 15. the aggregated seam report keeps the LAST scope's `searched` instead of ANY
mutant report-conflate \
  $'            cur["searched"] = cur["searched"] or bool(r["searched"])|@MUT@|            cur["searched"] = bool(r["searched"])' \
  $F::test_seam_report_aggregates_without_conflating_searched_and_found

# 16. the lossy slug reverse becomes a naive replace('-','/')
mutant slug-resolver \
  $'def slug_to_path(slug: str, max_depth: int = 12) -> Path | None:\n    """The directory ``slug`` was derived from, or ``None`` if it is gone."""\n    return _slug_paths(slug, max_depth)[0]|@MUT@|def slug_to_path(slug: str, max_depth: int = 12) -> Path | None:\n    """The directory ``slug`` was derived from, or ``None`` if it is gone."""\n    p = Path(slug.replace("-", "/"))\n    return p if p.is_dir() else None' \
  $F::test_slug_to_path_resolves_dashed_and_dotted_names

# 17. EVERY confidentiality layer removed at once. This is what the traversal
# case actually pins: no permitted traversal ever names a denied project.
mutant denylist-both \
  $'    return any(\n        t.lower().startswith(CONFIDENTIAL_PREFIXES) for t in path_tokens(value)\n    )|@MUT@|    return False' \
  $F::test_denylisted_slug_dir_is_never_traversed \
  $F::test_denylisted_slug_never_appears_in_fleet_output \
  $F::test_explicit_denied_slug_is_still_a_hard_refusal

echo
if [ $FAILED -eq 0 ]; then
  echo "mutate: ALL $KILLED MUTANTS KILLED BY THEIR NAMED CASES"
else
  echo "mutate: FAIL — a mutant survived or the harness misfired" >&2
fi
exit $FAILED
