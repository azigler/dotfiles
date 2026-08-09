#!/bin/bash
# Test for seneschal-gather.py — the front desk's aggregation pass.
#
# What this suite is FOR. The brief's failure mode is silence: a source that is
# down, a repo that will not read, or a confidential subject that leaks all look
# like ordinary output on a screen nobody diffs. So the cases here are mostly
# NEGATIVE — they assert the degraded render happens, the unreadable source is
# NAMED, and the confidential string is ABSENT — rather than asserting a happy
# path that a stub could satisfy.
#
# Two of them are constitutional, not cosmetic:
#   * `no_dispatch_verbs` greps the runner for send-keys / br close / br update.
#     The seneschal holds NO dispatch authority (seats.yml charter line,
#     dotfiles-seat-address-spec-uikg); the marshal dispatches. The bead's
#     acceptance criterion says "grep-verifiable", so this is that grep.
#   * `no_foreign_brief_consumers` is the anti-LAUNDERING guard (bead
#     dotfiles-front-desk-faty, scrutiny C1). The threat was never send-keys in
#     the skill — it is some OTHER loop, one that DOES hold dispatch authority,
#     reading refs/seneschal-brief.md as a work queue and thereby giving the
#     brief teeth by the back door. Zero non-seneschal consumers, enforced here
#     so the pre-commit gate runs it on every edit to either file.
#
# Hermetic: fixture roster + fixture git repos + fixture bead ledgers + a fake
# systemctl, all in a per-run tmpdir. The state bus is a file:// URL for the
# healthy case and a closed port for the degraded one — no network, no systemd,
# no tmux, no real repo is touched.
#
# Convention matches test-pulse-ledger-lint.sh: executable bash, non-zero exit
# = failure, PASS/FAIL summary on the last line.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
GATHER="$HERE/seneschal-gather.py"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
PASS=0
FAIL=0
FAILED_NAMES=()

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$1")
  echo "FAIL $1: $2"
}

NOW_EPOCH=$(date -u +%s)
NOW_ISO=$(date -u -d "@$NOW_EPOCH" +%Y-%m-%dT%H:%M:%SZ)

# --- fixtures ----------------------------------------------------------------
mk_repo() { # $1 = dir, $2 = commit subject
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name Test
  echo x > "$1/f"
  git -C "$1" add f
  git -C "$1" commit -q -m "$2"
}

mk_bead() { # $1 = repo, $2 = id, $3 = status, $4 = title, $5 = ts
  mkdir -p "$1/.beads"
  printf '{"id":"%s","status":"%s","priority":1,"title":"%s","created_at":"%s","closed_at":"%s","updated_at":"%s"}\n' \
    "$2" "$3" "$4" "$5" "$5" "$5" >> "$1/.beads/issues.jsonl"
}

mk_roster() { # $1 = roster path, remaining args = name=home pairs
  local out=$1; shift
  {
    echo "schema: 1"
    echo "seats:"
    for pair in "$@"; do
      echo "  ${pair%%=*}:"
      echo "    home: ${pair#*=}"
      echo "    model: fable"
    done
  } > "$out"
}

PLAIN="$ROOT/plain"
SECRET="$ROOT/linearb-fixture"
BROKEN="$ROOT/broken"
mk_repo "$PLAIN" "visible subject alpha"
mk_repo "$SECRET" "SECRETSUBJECT client roadmap"
mk_repo "$BROKEN" "broken repo commit"
mk_bead "$PLAIN" "plain-1" open "human: answer the plain question" "$NOW_ISO"
mk_bead "$PLAIN" "plain-2" closed "did a thing" "$NOW_ISO"
mk_bead "$SECRET" "lb-1" open "human: SECRETTITLE approve the deck" "$NOW_ISO"
mkdir -p "$BROKEN/.beads" && echo '{not json' > "$BROKEN/.beads/issues.jsonl"

ROSTER="$ROOT/seats.yml"
# The seat is named `seneschal` because the header's `roster-model:` is read
# from that row — the brief must state which model produced it (bead C2).
mk_roster "$ROSTER" "seneschal=$PLAIN" "linearb=$SECRET" "broken=$BROKEN"

# fake systemctl: one timer inside the 24h horizon, one well outside it
cat > "$ROOT/systemctl" <<EOSH
#!/bin/bash
printf '[{"next":%s000000,"unit":"pulse-inside.timer"},{"next":%s000000,"unit":"pulse-outside.timer"},{"next":null,"unit":"pulse-dead.timer"}]\n' \\
  $((NOW_EPOCH + 3600)) $((NOW_EPOCH + 172800))
EOSH
chmod +x "$ROOT/systemctl"

# healthy state bus, served from a file:// URL
cat > "$ROOT/state.json" <<'EOJSON'
{"you":{"beads":[{"id":"bus-1","title":"human: from the bus","priority":1,"age_days":3.4}]},
 "fleet":[{"window":"autonoveld","glyph":"🔔","state":"idle","dwell_minutes":42},
          {"window":"dotfiles","glyph":"🧠","state":"working","dwell_minutes":3}]}
EOJSON

run() { # $@ = extra args; prints brief, sets $rc
  SENESCHAL_SYSTEMCTL="$ROOT/systemctl" \
  SENESCHAL_FLEET_HEALTH="$ROOT/no-such-fleet-health.jsonl" \
    python3 "$GATHER" --roster "$ROSTER" --out - --tz UTC --now "$NOW_ISO" "$@" 2>&1
}

DOWN_URL="http://127.0.0.1:1/state.json"
BUS_URL="file://$ROOT/state.json"

# --- 1. the degraded render is a RENDER, not a crash -------------------------
out=$(run --state-url "$DOWN_URL"); rc=$?
if [ "$rc" -eq 0 ] &&
   [[ "$out" == *"state bus DOWN"* ]] &&
   [[ "$out" == *"NEEDS YOU"* ]] && [[ "$out" == *"SHIPPED OVERNIGHT"* ]] &&
   [[ "$out" == *"THE WORKS"* ]] && [[ "$out" == *"TODAY"* ]]; then
  ok "bus_down_still_renders_all_four_sections"
else
  no "bus_down_still_renders_all_four_sections" "rc=$rc"
fi

# The degraded NEEDS YOU must SAY it is degraded. "0 blocked, nothing to do"
# and "I could not ask" are opposite facts that render identically otherwise.
if [[ "$out" == *"LOCAL roster scan"* ]] && [[ "$out" == *"human: answer the plain question"* || "$out" == *"answer the plain question"* ]]; then
  ok "bus_down_falls_back_to_local_scan_and_says_so"
else
  no "bus_down_falls_back_to_local_scan_and_says_so" "$(echo "$out" | head -8)"
fi

# --- 2. the healthy bus is PREFERRED over the local scan ---------------------
out_bus=$(run --state-url "$BUS_URL"); rc=$?
if [ "$rc" -eq 0 ] && [[ "$out_bus" == *"state bus OK"* ]] &&
   [[ "$out_bus" == *"bus-1"* ]] && [[ "$out_bus" != *"LOCAL roster scan"* ]]; then
  ok "bus_up_is_the_source_of_needs_you"
else
  no "bus_up_is_the_source_of_needs_you" "$(echo "$out_bus" | head -8)"
fi

if [[ "$out_bus" == *"🔔 autonoveld"* ]] && [[ "$out_bus" != *"🔔 dotfiles"* ]]; then
  ok "blocked_seats_come_from_the_fleet_glyph"
else
  no "blocked_seats_come_from_the_fleet_glyph" "$(echo "$out_bus" | grep -c 🔔)"
fi

# --- 3. fails loud: the unreadable ledger is NAMED ---------------------------
# PER SECTION, and that is the whole point of splitting these two. The first
# version asserted only that "UNREADABLE" and "broken" appeared SOMEWHERE, and a
# mutant that deleted the NEEDS-YOU accounting entirely SURVIVED it — the
# SHIPPED section's own unreadable line satisfied both substrings. Measured
# 2026-08-09 while landing this suite; the split is what killed the mutant.
if [[ "$out" == *"UNREADABLE: 1 ledger(s) — broken ("* ]]; then
  ok "needs_scan_names_its_unreadable_ledger"
else
  no "needs_scan_names_its_unreadable_ledger" "$(echo "$out" | grep -A3 'NEEDS YOU')"
fi

if [[ "$out" == *"broken/beads ("* ]]; then
  ok "shipped_names_its_unreadable_ledger"
else
  no "shipped_names_its_unreadable_ledger" "$(echo "$out" | grep -A3 'SHIPPED')"
fi

if [[ "$out" == *"of 3 repos read"* ]]; then
  ok "shipped_reports_N_of_M"
else
  no "shipped_reports_N_of_M" "$(echo "$out" | grep SHIPPED)"
fi

# --- 4. confidentiality: linearb*/cfp* are COUNTED, never QUOTED -------------
# refs/ is git-tracked and pushed; feedback_linearb_beads_confidential forbids
# that content reaching a pushed artifact. Both directions: commit subject
# (SHIPPED) and bead title (NEEDS YOU, on the local-scan path that reads it).
leak=0
for probe in SECRETSUBJECT SECRETTITLE; do
  [[ "$out" == *"$probe"* ]] && leak=1
  [[ "$out_bus" == *"$probe"* ]] && leak=1
done
if [ "$leak" -eq 0 ] && [[ "$out" == *"linearb-fixture"* ]]; then
  ok "confidential_repo_counted_never_quoted"
else
  no "confidential_repo_counted_never_quoted" "leak=$leak"
fi

# --- 5. the ADVISORY header is machine-readable ------------------------------
if [[ "$out" == *"seneschal-brief v1"* ]] && [[ "$out" == *"authority: none"* ]] &&
   [[ "$out" == *"dispatch: never"* ]] && [[ "$out" == *"roster-model: fable"* ]]; then
  ok "advisory_header_present_and_names_the_model"
else
  no "advisory_header_present_and_names_the_model" "$(echo "$out" | head -1)"
fi

# --- 6. holds NO dispatch authority (the grep-verifiable criterion) ----------
# Strip comments and triple-quoted blocks first: the runner's own header PROSE
# names the verbs it refuses to use, and a guard that cannot tell an executed
# verb from a documented refusal would force the documentation out — exactly
# backwards.
strip_prose() { # $1 = python file -> executable source only
  awk '
    /"""/ { n = gsub(/"""/, "&"); if (n % 2 == 1) ins = !ins; next }
    ins   { next }
    /^[[:space:]]*#/ { next }
    { print }
  ' "$1"
}
if strip_prose "$GATHER" | grep -nE 'send-keys|br (close|update)|"tmux"' > /dev/null; then
  no "no_dispatch_verbs" "$(strip_prose "$GATHER" | grep -nE 'send-keys|br (close|update)|"tmux"' | head -3)"
else
  ok "no_dispatch_verbs"
fi

# The stripper must actually strip — an awk that matched nothing would make the
# case above pass for the wrong reason (the dotfiles-47nf shape).
if [ "$(strip_prose "$GATHER" | wc -l)" -lt "$(wc -l < "$GATHER")" ] &&
   ! strip_prose "$GATHER" | grep -q 'the MARSHAL dispatches'; then
  ok "strip_prose_actually_strips"
else
  no "strip_prose_actually_strips" "prose survived the filter — case 6 proves nothing"
fi

SKILL="$REPO_ROOT/agents/skills/seneschal/SKILL.md"

# The skill's EXECUTABLE surface is its fenced blocks — that is where an agent
# copies from. Grepping the whole document instead was the first version, and it
# failed on the skill's own charter sentence ("never runs br update…"): a guard
# that cannot tell an executed verb from a documented refusal pushes the
# refusal out of the document, which is precisely backwards.
code_blocks() { awk '/^```/ { inb = !inb; next } inb { print }' "$1"; }
if [ ! -f "$SKILL" ]; then
  no "skill_code_blocks_hold_no_dispatch_verbs" "SKILL.md missing"
elif code_blocks "$SKILL" | grep -nE 'send-keys|br (close|update)|--claim|tmux ' > /dev/null; then
  no "skill_code_blocks_hold_no_dispatch_verbs" "$(code_blocks "$SKILL" | grep -nE 'send-keys|br (close|update)|--claim' | head -3)"
else
  ok "skill_code_blocks_hold_no_dispatch_verbs"
fi

# …and the positive half: the charter must be STATED, not merely not-violated.
if [ -f "$SKILL" ] && grep -qi 'no dispatch authority' "$SKILL"; then
  ok "skill_states_the_no_authority_invariant"
else
  no "skill_states_the_no_authority_invariant" "the charter sentence is missing"
fi

# --- 7. anti-laundering: no OTHER loop consumes the brief -------------------
# Scoped to the surfaces that can ACT on the path — other skills' bodies, the
# scheduler, the hooks. TOOLKIT.md is deliberately NOT scanned: it is the
# read-only digest, and prose that points AT the brief is the documented shape
# ("the doc names the query, it does not answer it"). A digest entry is not a
# consumer; a `read the brief and work it` line in another loop's SKILL.md is.
consumers=$(grep -rln 'seneschal-brief' \
  "$REPO_ROOT"/agents/skills/*/SKILL.md "$REPO_ROOT/agents/scheduler" "$REPO_ROOT/agents/hooks" 2>/dev/null |
  grep -v '/seneschal/' | grep -v 'seneschal-gather')
if [ -z "$consumers" ]; then
  ok "no_foreign_brief_consumers"
else
  no "no_foreign_brief_consumers" "$consumers"
fi

# --- 8. TODAY is a 24h horizon, not the whole timer list --------------------
if [[ "$out" == *"pulse-inside"* ]] && [[ "$out" != *"pulse-outside"* ]] &&
   [[ "$out" != *"pulse-dead"* ]]; then
  ok "timers_clipped_to_24h_horizon"
else
  no "timers_clipped_to_24h_horizon" "$(echo "$out" | grep -A4 TODAY)"
fi

# --- 9. THE WORKS degrades to the named bead, not to silence ----------------
if [[ "$out" == *"watcher not yet built (dotfiles-kkpq)"* ]]; then
  ok "works_absent_watcher_names_its_bead"
else
  no "works_absent_watcher_names_its_bead" "$(echo "$out" | grep -A2 'THE WORKS')"
fi

FH="$ROOT/pico.jsonl"
printf '{"host":"pico","check":"ollama","status":"ok"}\n{"host":"pico","check":"gateway","status":"ok"}\n' > "$FH"
out_fh=$(SENESCHAL_SYSTEMCTL="$ROOT/systemctl" SENESCHAL_FLEET_HEALTH="$FH" \
  python3 "$GATHER" --roster "$ROSTER" --out - --tz UTC --now "$NOW_ISO" --state-url "$DOWN_URL" 2>&1)
if [[ "$out_fh" == *"check=gateway"* ]] && [[ "$out_fh" != *"watcher not yet built"* ]]; then
  ok "works_reads_the_ledger_when_it_exists"
else
  no "works_reads_the_ledger_when_it_exists" "$(echo "$out_fh" | grep -A3 'THE WORKS')"
fi

# --- 10. empty-but-present: the file lands even with nothing blocked --------
# Absence of the file means the LOOP is broken; it must never be readable as
# "nothing needed you today".
EMPTY_ROSTER="$ROOT/empty.yml"
printf 'schema: 1\nseats:\n' > "$EMPTY_ROSTER"
OUTFILE="$ROOT/brief.md"
SENESCHAL_SYSTEMCTL="$ROOT/systemctl" SENESCHAL_FLEET_HEALTH="$ROOT/nope.jsonl" \
  python3 "$GATHER" --roster "$EMPTY_ROSTER" --out "$OUTFILE" --tz UTC --now "$NOW_ISO" \
  --state-url "$DOWN_URL" > /dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ -s "$OUTFILE" ] && grep -q "SENESCHAL BRIEF" "$OUTFILE" &&
   grep -q "roster parsed to 0 seats" "$OUTFILE"; then
  ok "empty_brief_is_written_dated_and_says_the_roster_was_empty"
else
  no "empty_brief_is_written_dated_and_says_the_roster_was_empty" "rc=$rc"
fi

# --- 11. the window is real: an old commit is not "overnight" --------------
# Ten days forward rather than a tiny --hours: `git log --since` has one-second
# granularity, so a sub-second window still catches a commit made in the same
# second and the case would pass with the bound doing nothing.
FUTURE_ISO=$(date -u -d "@$((NOW_EPOCH + 864000))" +%Y-%m-%dT%H:%M:%SZ)
out_narrow=$(SENESCHAL_SYSTEMCTL="$ROOT/systemctl" SENESCHAL_FLEET_HEALTH="$ROOT/nope.jsonl" \
  python3 "$GATHER" --roster "$ROSTER" --out - --tz UTC --now "$FUTURE_ISO" \
  --state-url "$DOWN_URL" 2>&1)
if [[ "$out_narrow" == *"no commits and no bead closures in the window"* ]]; then
  ok "hours_window_actually_bounds_the_scan"
else
  no "hours_window_actually_bounds_the_scan" "$(echo "$out_narrow" | grep -A2 SHIPPED)"
fi

# --- summary -----------------------------------------------------------------
echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: ${FAILED_NAMES[*]}"
fi
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
