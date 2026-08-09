#!/bin/bash
# marshal-drain.sh — THE FLEET DRAIN's deciding half (dotfiles-69qr).
#
# The estate has produced all night for months (dive, desk, dream, digest) and
# consumed nothing: `br ready` grew while every loop wrote more into it. This
# is the consumer. It does NOT dispatch — a worktree subagent is spawned by the
# MARSHAL SESSION's own Agent tool, which is a thing only a live Claude session
# has. What this script owns is the two halves a 3am loop must not improvise:
#
#   THE DECIDING — what tonight's budget is, which beads are eligible, in what
#   order, on which model, in which lane.
#   THE LEDGER — an EXPLAINABLE audit trail. Every pick carries `br scheduler`'s
#   own rationale lines, every refusal carries the rule that refused it, and
#   both land in ~/.local/state/harness/drain-ledger.jsonl. An autonomous drain
#   that cannot say WHY it picked a bead is not reviewable by exception, and
#   review-by-exception is the whole trust model after the 05:11 amendment
#   deleted the review-every-diff rung.
#
# The /marshal skill (agents/skills/marshal/SKILL.md) is the prose half: it
# drives these subcommands and does the parts that need a session — dispatch,
# the guarded merge, close-with-evidence, the molt. WHAT-not-HOW lives there;
# mechanics live here.
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
# ---------------------------------------------------------------------------
#   budget [--weekly-cap N]
#       Compute tonight's TOKEN BUDGET from pico's requests.db (read-only,
#       over ssh) and print the full derivation as JSON, then the verdict.
#
#   plan [--budget N] [--limit N] [--scan-limit N] [--night ID]
#       Freeze check -> budget -> mail -> selection -> a dispatch plan the
#       marshal session executes, with a `verify` invocation per pick.
#
#   record --outcome <o> [--bead ID] [--repo NAME] ...
#       Append one row to the drain ledger and answer the R6 question the
#       marshal must not eyeball at 3am: is this a continue, a park, or the
#       end of the night?
#
#   verify --repo PATH --bead ID --before SHA --agent-sha SHA [--target BR]
#       Read-only post-merge assertions on the TARGET branch. "Already up to
#       date" is a SUCCESS exit code for a merge that did nothing; this is
#       what makes that visible.
#
# Every terminal path prints exactly ONE machine-readable verdict line, LAST on
# stdout (the fleet's daemon-skill verdict discipline — a caller greps the last
# line, never parses prose):
#
#   MARSHAL_BUDGET=<tokens> status=computed
#   MARSHAL_BUDGET=degraded fallback_tokens=<n> reason=<why>
#   MARSHAL_PLAN_RESULT=planned:<n> | frozen | no-budget | empty-queue | failed-<why>
#   MARSHAL_RECORD_RESULT=recorded streak=<n> | park-repeat-failure | three-strikes
#   MARSHAL_VERIFY_RESULT=ok | abort-<why>
#
# ---------------------------------------------------------------------------
# WHAT THIS SCRIPT WILL NOT DO — the R10 list, mechanized
# ---------------------------------------------------------------------------
# It never calls `br close`, `br update --status`, `br create`, `git merge`,
# `git push`, `git worktree remove`, or `kill`. It reads beads, reads a sqlite
# db over ssh, reads git state, and appends to its own ledger. The destructive
# verbs belong to the marshal session under the AGENTS.md guarded-merge
# sequence, where a human-legible refusal can stop them.
#
# ---------------------------------------------------------------------------
# TEST SEAMS (the suite is hermetic — no pico, no real beads, no real repos)
# ---------------------------------------------------------------------------
#   MARSHAL_CONF          config path (default: marshal.conf beside this file)
#   MARSHAL_SQL_CMD       command that reads SQL on stdin and prints rows
#                         (default: ssh <pico_host> sqlite3 <requests_db>).
#                         The suite points it at a local fixture db.
#   MARSHAL_BR_BIN        `br` binary (default: br)
#   MARSHAL_BV_BIN        `bv` binary (default: bv) — cross-check only, never
#                         the planner (bv --robot-plan is measured degenerate:
#                         135 tracks over 184 beads, 133 of them singletons)
#   MARSHAL_FREEZE_SCRIPT demesne-freeze.sh (default: beside this file)
#   MARSHAL_MARKERS_LIB   bead-markers.sh (default: ../lib/bead-markers.sh)
#   MARSHAL_MOLT_LIB      molt-thresholds.sh (default: ../lib/molt-thresholds.sh)
#   MARSHAL_POST_LIB      post.sh (default: ../lib/post.sh — may not exist yet)
#   MARSHAL_LEDGER        drain ledger path
#   HARNESS_STATE_DIR     state dir (ledger + the freeze marker live under it)
#   MARSHAL_NOW           ISO8601 UTC "now" override, for deterministic tests

set -uo pipefail

_MD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONF="${MARSHAL_CONF:-$_MD_DIR/marshal.conf}"
BR_BIN="${MARSHAL_BR_BIN:-br}"
BV_BIN="${MARSHAL_BV_BIN:-bv}"
FREEZE_SCRIPT="${MARSHAL_FREEZE_SCRIPT:-$_MD_DIR/demesne-freeze.sh}"
MARKERS_LIB="${MARSHAL_MARKERS_LIB:-$_MD_DIR/../lib/bead-markers.sh}"
MOLT_LIB="${MARSHAL_MOLT_LIB:-$_MD_DIR/../lib/molt-thresholds.sh}"
POST_LIB="${MARSHAL_POST_LIB:-$_MD_DIR/../lib/post.sh}"
STATE_DIR="${HARNESS_STATE_DIR:-$HOME/.local/state/harness}"
LEDGER="${MARSHAL_LEDGER:-$STATE_DIR/drain-ledger.jsonl}"
FREEZE_MARKER="$STATE_DIR/demesne-freeze-active"

info() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

VERDICT_SENT=0
verdict() {
  [ "$VERDICT_SENT" -eq 1 ] && return 0
  VERDICT_SENT=1
  printf '%s\n' "$1"
}

# --- THE MOLT PACING (dotfiles-9060) --------------------------------------
# NOT a literal here. One constant, two consumers: molt-thresholds.sh owns the
# 75 backstop and DERIVES the 50 pacing from it, so the pair cannot drift.
# The fallback exists only so a tree without the lib still plans; it is the
# same derivation, spelled out.
if [ -r "$MOLT_LIB" ]; then
  # shellcheck source=../lib/molt-thresholds.sh
  . "$MOLT_LIB"
else
  MOLT_BACKSTOP_PCT="${MOLT_BACKSTOP_PCT:-75}"
  MOLT_HEADROOM_PCT="${MOLT_HEADROOM_PCT:-25}"
  MOLT_PACING_PCT=$(( MOLT_BACKSTOP_PCT - MOLT_HEADROOM_PCT ))
fi

# ---------------------------------------------------------------------------
# CONFIG — key=value only, and the parser REFUSES anything else.
# A config file that can execute is a config file that can be an incident, and
# this one is read by an unattended 01:07 loop. `source`ing it would make every
# line arbitrary code; instead each line is matched against a strict grammar
# and assigned through a name whitelist.
# ---------------------------------------------------------------------------
declare -A CFG=()
CONF_ERROR=""

conf_load() {
  local file=$1 line key value n=0
  [ -r "$file" ] || { CONF_ERROR="config not readable: $file"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in
      ''|'#'*) continue ;;
    esac
    if ! printf '%s' "$line" | grep -qE '^[a-z][a-z0-9_]*=[A-Za-z0-9_:,./~+-]*$'; then
      CONF_ERROR="config line $n is not a plain key=value: $line"
      return 1
    fi
    key=${line%%=*}
    value=${line#*=}
    CFG[$key]=$value
  done < "$file"
  return 0
}

cfg() { # cfg <key> [default]
  local k=$1 d=${2:-}
  if [ -n "${CFG[$k]+set}" ] && [ -n "${CFG[$k]}" ]; then
    printf '%s' "${CFG[$k]}"
  else
    printf '%s' "$d"
  fi
}

# ---------------------------------------------------------------------------
# JSON — one emitter, python3 (already a hard dependency of this tree via
# bead-markers.sh and validate-seats.py). Never hand-rolled string concat:
# a rationale line contains quotes, em-dashes and newlines by construction.
# ---------------------------------------------------------------------------
json_escape() { python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))'; }

# ---------------------------------------------------------------------------
# THE BUDGET CALCULATOR
# ---------------------------------------------------------------------------
# night_budget = weekly_remaining / days_to_reset
#                - zig_daytime_reserve
#                - safety_margin
#
# Every input is either config (stated) or MEASURED off pico's requests.db.
# Nothing is inferred, and every failure path degrades to the config floor
# with a named reason. THE ONE THING IT MUST NEVER DO is emit a large number
# it cannot defend: a silent huge budget is a night that spends Zig's week.
#
# ⚠️ TWO requests.db TRAPS, both paid for already (agents/infra.md):
#   1. `started_at` is ISO8601 WITH a `T` and an offset, so a bare string
#      comparison against a `datetime()` value compares 'T' > ' ' at position
#      10 and silently matches every row with today's DATE. Measured side by
#      side: 2903 rows vs 18. ALWAYS wrap the column in datetime().
#   2. The tap is NOT a date-delimited fact. The attribution epoch flipped on
#      2026-08-09 (epoch 1: group=hostname, user=session:window; epoch 2:
#      group=tap, user=host:seat) and the cutover is ROLLING — a durable pane
#      emits epoch-1 values for days. So rows are classified BY VALUE, never
#      by date: `group IN ('personal','work','tick')` is an exact epoch-2
#      test, and epoch-1 rows fall back to the user-column split.

tap_predicate() { # tap_predicate <tap> -> SQL boolean, or return 1
  local tap=$1
  case "$tap" in
    personal)
      # epoch 2: group is the tap. epoch 1: group is a hostname, so anything
      # outside the tap namespace that is not the work split is personal.
      printf '%s' "(COALESCE(agentgateway_group,'') = 'personal' OR (COALESCE(agentgateway_group,'') NOT IN ('personal','work','tick') AND COALESCE(agentgateway_user,'') NOT LIKE 'work:%'))"
      ;;
    work)
      printf '%s' "(COALESCE(agentgateway_group,'') = 'work' OR (COALESCE(agentgateway_group,'') NOT IN ('personal','work','tick') AND COALESCE(agentgateway_user,'') LIKE 'work:%'))"
      ;;
    tick)
      # epoch 1 carried NO signal that could distinguish the tick jail, so this
      # one is epoch-2-only and says so rather than guessing.
      printf '%s' "(COALESCE(agentgateway_group,'') = 'tick')"
      ;;
    *) return 1 ;;
  esac
}

sql_cmd_default() {
  printf 'ssh -o ConnectTimeout=10 %s sqlite3 %s' "$(cfg pico_host pico)" "$(cfg requests_db '~/.local/share/agentgateway/requests.db')"
}

# window_math — prints four lines: window_start_utc, days_to_reset,
# trailing_start_utc, now_utc. All date arithmetic in one place, in python,
# because "most recent Wednesday 00:00 PT, expressed in UTC" is exactly the
# computation a shell gets subtly wrong once a week.
window_math() {
  MD_NOW="${MARSHAL_NOW:-}" \
  MD_OFF="$(cfg tz_offset_hours -7)" \
  MD_DOW="$(cfg week_reset_dow 3)" \
  MD_HOUR="$(cfg week_reset_hour 0)" \
  MD_TRAIL="$(cfg zig_reserve_trailing_days 7)" \
  python3 - <<'PY'
import os, sys
from datetime import datetime, timedelta, timezone

now_s = os.environ.get("MD_NOW") or ""
if now_s:
    now = datetime.fromisoformat(now_s.replace("Z", "+00:00"))
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    now = now.astimezone(timezone.utc)
else:
    now = datetime.now(timezone.utc)

try:
    off = int(os.environ["MD_OFF"])
    dow = int(os.environ["MD_DOW"])          # 0=Sunday .. 6=Saturday
    hour = int(os.environ["MD_HOUR"])
    trail = int(os.environ["MD_TRAIL"])
except (KeyError, ValueError):
    sys.exit(3)
if not (0 <= dow <= 6 and 0 <= hour <= 23 and trail >= 1):
    sys.exit(3)

local = now + timedelta(hours=off)
# python weekday(): Monday=0..Sunday=6 -> convert to Sunday=0..Saturday=6
local_dow = (local.weekday() + 1) % 7
candidate = local.replace(hour=hour, minute=0, second=0, microsecond=0)
back = (local_dow - dow) % 7
candidate = candidate - timedelta(days=back)
if candidate > local:
    candidate = candidate - timedelta(days=7)
window_start_utc = candidate - timedelta(hours=off)
next_reset_utc = window_start_utc + timedelta(days=7)

secs = (next_reset_utc - now).total_seconds()
days_to_reset = int(-(-secs // 86400))       # ceil
if days_to_reset < 1:
    days_to_reset = 1

trailing_start_utc = now - timedelta(days=trail)

fmt = "%Y-%m-%d %H:%M:%S"
print(window_start_utc.strftime(fmt))
print(days_to_reset)
print(trailing_start_utc.strftime(fmt))
print(now.strftime(fmt))
PY
}

# budget_compute — sets BUDGET_JSON and BUDGET_STATUS/BUDGET_TOKENS/BUDGET_REASON.
BUDGET_JSON=""
BUDGET_STATUS=""
BUDGET_TOKENS=0
BUDGET_REASON=""

budget_compute() { # budget_compute [weekly_cap_override]
  local cap_override=${1:-}
  local tap cap floor margin pred sqlcmd math
  local window_start days_to_reset trailing_start now_utc
  local spent daytime rows

  tap=$(cfg tap personal)
  floor=$(cfg budget_floor_tokens 0)
  margin=$(cfg safety_margin_pct 20)
  cap=${cap_override:-$(cfg weekly_cap_tokens '')}

  if ! pred=$(tap_predicate "$tap"); then
    budget_degrade "$floor" "unknown-tap:$tap" ""
    return 0
  fi

  math=$(window_math) || { budget_degrade "$floor" "bad-window-config" ""; return 0; }
  window_start=$(printf '%s\n' "$math" | sed -n 1p)
  days_to_reset=$(printf '%s\n' "$math" | sed -n 2p)
  trailing_start=$(printf '%s\n' "$math" | sed -n 3p)
  now_utc=$(printf '%s\n' "$math" | sed -n 4p)
  [ -n "$window_start" ] && [ -n "$days_to_reset" ] || {
    budget_degrade "$floor" "bad-window-config" ""; return 0; }

  sqlcmd="${MARSHAL_SQL_CMD:-$(sql_cmd_default)}"

  local dstart dend sql
  dstart=$(cfg zig_daytime_start_hour 8)
  dend=$(cfg zig_daytime_end_hour 22)
  sql="SELECT COALESCE(SUM(total_tokens),0) FROM request_logs WHERE datetime(started_at) >= '$window_start' AND $pred;
SELECT COALESCE(SUM(total_tokens),0) FROM request_logs WHERE datetime(started_at) >= '$trailing_start' AND $pred AND CAST(strftime('%H', datetime(started_at, '$(cfg tz_offset_hours -7) hours')) AS INTEGER) >= $dstart AND CAST(strftime('%H', datetime(started_at, '$(cfg tz_offset_hours -7) hours')) AS INTEGER) < $dend;"

  rows=$(printf '%s\n' "$sql" | $sqlcmd)
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    budget_degrade "$floor" "db-unreachable" "$window_start"
    return 0
  fi
  spent=$(printf '%s\n' "$rows" | grep -E '^[0-9]+$' | sed -n 1p)
  daytime=$(printf '%s\n' "$rows" | grep -E '^[0-9]+$' | sed -n 2p)
  if [ -z "$spent" ] || [ -z "$daytime" ]; then
    budget_degrade "$floor" "db-unusable-result" "$window_start"
    return 0
  fi

  if [ -z "$cap" ]; then
    # The honest degrade. requests.db can say what was SPENT; only the vendor
    # (4icj's header capture) can say what the CAP is. Without it there is no
    # remaining-tokens number that is not invented.
    budget_degrade "$floor" "weekly-cap-unset" "$window_start" "$spent" "$daytime"
    return 0
  fi

  local out
  out=$(MD_CAP="$cap" MD_SPENT="$spent" MD_DAYS="$days_to_reset" \
        MD_DAYTIME="$daytime" MD_TRAIL="$(cfg zig_reserve_trailing_days 7)" \
        MD_MARGIN="$margin" python3 - <<'PY'
import os, sys
cap = int(os.environ["MD_CAP"]); spent = int(os.environ["MD_SPENT"])
days = int(os.environ["MD_DAYS"]); daytime = int(os.environ["MD_DAYTIME"])
trail = int(os.environ["MD_TRAIL"]); margin = int(os.environ["MD_MARGIN"])
if days < 1 or trail < 1 or not (0 <= margin < 100):
    sys.exit(3)
remaining = max(0, cap - spent)
share = remaining // days
reserve = daytime // trail
raw = share - reserve
budget = 0 if raw <= 0 else (raw * (100 - margin)) // 100
print(remaining); print(share); print(reserve); print(raw); print(budget)
PY
  ) || { budget_degrade "$floor" "bad-budget-inputs" "$window_start" "$spent" "$daytime"; return 0; }

  local remaining share reserve raw budget
  remaining=$(printf '%s\n' "$out" | sed -n 1p)
  share=$(printf '%s\n' "$out" | sed -n 2p)
  reserve=$(printf '%s\n' "$out" | sed -n 3p)
  raw=$(printf '%s\n' "$out" | sed -n 4p)
  budget=$(printf '%s\n' "$out" | sed -n 5p)

  BUDGET_STATUS=computed
  BUDGET_TOKENS=$budget
  BUDGET_REASON=""
  BUDGET_JSON=$(MD_J_STATUS=computed MD_J_TAP="$tap" MD_J_WS="$window_start" \
    MD_J_NOW="$now_utc" MD_J_DAYS="$days_to_reset" MD_J_CAP="$cap" \
    MD_J_SPENT="$spent" MD_J_REMAIN="$remaining" MD_J_SHARE="$share" \
    MD_J_DAYTIME="$daytime" MD_J_TRAIL="$(cfg zig_reserve_trailing_days 7)" \
    MD_J_RESERVE="$reserve" MD_J_MARGIN="$margin" MD_J_RAW="$raw" \
    MD_J_BUDGET="$budget" MD_J_FLOOR="$floor" \
    MD_J_DSTART="$dstart" MD_J_DEND="$dend" \
    MD_J_CAPSRC="$([ -n "$cap_override" ] && echo flag || echo config)" \
    python3 - <<'PY'
import json, os
i = lambda k: int(os.environ[k])
print(json.dumps({
    "status": os.environ["MD_J_STATUS"],
    "tap": os.environ["MD_J_TAP"],
    "now_utc": os.environ["MD_J_NOW"],
    "weekly_window_start_utc": os.environ["MD_J_WS"],
    "days_to_reset": i("MD_J_DAYS"),
    "weekly_cap_tokens": i("MD_J_CAP"),
    "weekly_cap_source": os.environ["MD_J_CAPSRC"],
    "spent_this_window": i("MD_J_SPENT"),
    "weekly_remaining": i("MD_J_REMAIN"),
    "nightly_share": i("MD_J_SHARE"),
    "zig_daytime_window_local": [i("MD_J_DSTART"), i("MD_J_DEND")],
    "zig_daytime_spend_trailing": i("MD_J_DAYTIME"),
    "zig_reserve_trailing_days": i("MD_J_TRAIL"),
    "zig_daytime_reserve": i("MD_J_RESERVE"),
    "safety_margin_pct": i("MD_J_MARGIN"),
    "budget_before_margin": i("MD_J_RAW"),
    "budget_tokens": i("MD_J_BUDGET"),
    "budget_floor_tokens": i("MD_J_FLOOR"),
    "formula": "((weekly_cap - spent_this_window) / days_to_reset - zig_daytime_reserve) * (1 - safety_margin_pct/100)",
}, sort_keys=True))
PY
)
  return 0
}

budget_degrade() { # budget_degrade <floor> <reason> [window_start] [spent] [daytime]
  local floor=$1 reason=$2 ws=${3:-} spent=${4:-} daytime=${5:-}
  BUDGET_STATUS=degraded
  BUDGET_TOKENS=$floor
  BUDGET_REASON=$reason
  BUDGET_JSON=$(MD_J_REASON="$reason" MD_J_FLOOR="$floor" MD_J_WS="$ws" \
    MD_J_SPENT="$spent" MD_J_DAYTIME="$daytime" MD_J_TAP="$(cfg tap personal)" \
    python3 - <<'PY'
import json, os
def maybe_int(k):
    v = os.environ.get(k) or ""
    return int(v) if v.isdigit() else None
print(json.dumps({
    "status": "degraded",
    "reason": os.environ["MD_J_REASON"],
    "tap": os.environ["MD_J_TAP"],
    "weekly_window_start_utc": os.environ.get("MD_J_WS") or None,
    "spent_this_window": maybe_int("MD_J_SPENT"),
    "zig_daytime_spend_trailing": maybe_int("MD_J_DAYTIME"),
    "budget_tokens": int(os.environ["MD_J_FLOOR"]),
    "budget_floor_tokens": int(os.environ["MD_J_FLOOR"]),
    "note": "degraded: the floor is a CONSERVATIVE fallback, never an inferred cap",
}, sort_keys=True))
PY
)
}

cmd_budget() {
  local cap_override=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --weekly-cap) cap_override=${2:-}; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) warn "budget: unknown argument '$1'"; verdict "MARSHAL_BUDGET=degraded fallback_tokens=0 reason=usage"; return 64 ;;
    esac
  done
  conf_load "$CONF" || {
    warn "budget: $CONF_ERROR"
    verdict "MARSHAL_BUDGET=degraded fallback_tokens=0 reason=bad-config"
    return 78
  }
  budget_compute "$cap_override"
  info "$BUDGET_JSON"
  if [ "$BUDGET_STATUS" = "computed" ]; then
    verdict "MARSHAL_BUDGET=$BUDGET_TOKENS status=computed"
  else
    verdict "MARSHAL_BUDGET=degraded fallback_tokens=$BUDGET_TOKENS reason=$BUDGET_REASON"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# ELIGIBILITY (R1 + R10)
# ---------------------------------------------------------------------------
# The marker grammar is NOT re-implemented here. agents/lib/bead-markers.sh is
# the ONE implementation (dotfiles-dh89) and this file imports its ID-BASED
# api — marker_is_fleet / marker_get — deliberately, not its pure text half.
# The label-backed upgrade of that library is a parallel bead; consuming the
# ID-based API is what makes the drain INHERIT it instead of needing a second
# edit here. A hand-rolled grep for `Fleet:` would be a second grammar, and a
# second grammar is a divergence with a fuse.
FLEET_ELIGIBLE_TYPES="task bug feature"
# R10, and the case the marker cannot buy its way out of: the marshal is not
# an author. A decision/spec/epic bead is REFUSED even when it carries
# `Fleet: yes` — the marker does not outrank the type.
FLEET_REFUSED_TYPES="decision spec epic"

markers_available=0
if [ -r "$MARKERS_LIB" ]; then
  # shellcheck source=../lib/bead-markers.sh
  . "$MARKERS_LIB"
  markers_available=1
fi

# classify_bead <repo-path> <id> <type> <title> -> prints "<decision> <reason>"
# decision: eligible | refused | skipped
classify_bead() {
  local repo=$1 id=$2 btype=$3 title=$4
  local marked=1 outward=1

  case " $FLEET_REFUSED_TYPES " in
    *" $btype "*)
      if (cd "$repo" && marker_is_fleet "$id"); then
        printf 'refused type-outranks-marker(%s)' "$btype"
      else
        printf 'refused type-not-drainable(%s)' "$btype"
      fi
      return 0
      ;;
  esac
  case " $FLEET_ELIGIBLE_TYPES " in
    *" $btype "*) ;;
    *) printf 'refused type-not-drainable(%s)' "$btype"; return 0 ;;
  esac

  # `human:` beads are Zig's, by construction — an autonomous loop that claims
  # one has claimed the escalation itself.
  case "$title" in
    human:*|HUMAN:*|Human:*) printf 'skipped human-tagged'; return 0 ;;
  esac

  if [ "$markers_available" -ne 1 ]; then
    printf 'skipped markers-lib-missing'
    return 0
  fi

  (cd "$repo" && marker_is_fleet "$id") && marked=0
  if [ "$marked" -ne 0 ]; then
    printf 'skipped unmarked'
    return 0
  fi

  # htqt: an outward-marked bead is skipped UNCONDITIONALLY — no outward
  # authority from a timer tick, ever (R8, Art. III).
  local ov
  ov=$( cd "$repo" && marker_get "$id" outward )
  if [ -n "$ov" ] && marker_bool_from_value "$ov"; then
    printf 'skipped outward-marked'
    return 0
  fi

  printf 'eligible marked'
  return 0
}

bead_model() { # bead_model <repo> <id> -> model token
  local repo=$1 id=$2 m=""
  if [ "$markers_available" -eq 1 ]; then
    m=$( cd "$repo" && marker_get "$id" fleet-model )
  fi
  [ -n "$m" ] || m=$(cfg default_model sonnet)
  printf '%s' "$m"
}

# ---------------------------------------------------------------------------
# PLAN
# ---------------------------------------------------------------------------

freeze_state() { # prints active|clear
  if [ -x "$FREEZE_SCRIPT" ]; then
    local out last
    # stderr merged, not discarded: the verdict is grepped out of the stream,
    # and anything else the script says stays visible to the caller's log.
    out=$("$FREEZE_SCRIPT" status 2>&1)
    last=$(printf '%s\n' "$out" | grep '^DEMESNE_FREEZE_RESULT=' | tail -n1)
    case "$last" in
      *status-frozen) printf 'active'; return 0 ;;
      *status-unfrozen) printf 'clear'; return 0 ;;
    esac
  fi
  # Fall back to the marker file demesne-freeze.sh itself writes. Fail CLOSED
  # is wrong here (a missing freeze script must not stop every night forever)
  # but a PRESENT marker always wins.
  if [ -f "$FREEZE_MARKER" ]; then printf 'active'; else printf 'clear'; fi
}

read_mail() { # prints a note line describing what the mail read did
  if [ ! -r "$POST_LIB" ]; then
    printf 'post-spool-absent (agents/lib/post.sh does not exist yet — the POST may land later; no mail read)'
    return 0
  fi
  # shellcheck source=/dev/null
  . "$POST_LIB"
  if command -v post_read_spool >/dev/null 2>&1; then # allow-suppress: existence probe
    local out
    out=$(post_read_spool marshal)
    printf 'post-spool-read (%s line(s))' "$(printf '%s' "$out" | grep -c . )"
    return 0
  fi
  printf 'post-spool-present-but-no-reader (post.sh defines no post_read_spool(); nothing read, nothing guessed)'
}

# triage_map <repo-path> -> JSON object id -> unblocks_ids, or {} on any
# failure. bv is a CROSS-CHECK, never the planner and never a blocker: it is
# broken in several robot modes on the installed 0.18.0 (--robot-file-hotspots
# / --robot-impact / --robot-file-beads report a false safe-to-proceed, #184)
# and --robot-plan is measured degenerate. Only --robot-triage's
# recommendations[].unblocks_ids is consumed.
triage_map() {
  local repo=$1
  command -v "$BV_BIN" >/dev/null 2>&1 || { # allow-suppress: existence probe
    warn "triage: $BV_BIN not on PATH — cross-check skipped"; printf '{}'; return 0; }
  local out map
  # stderr MERGED, never discarded: a bv that fails must not look like a bv
  # that found nothing. The parse below decides, and the first line of a
  # non-JSON answer is echoed to the caller's log.
  out=$( (cd "$repo" && timeout 120 "$BV_BIN" --robot-triage) 2>&1 )
  map=$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    recs = d.get("triage", {}).get("recommendations") or []
    print(json.dumps({r["id"]: r.get("unblocks_ids") or [] for r in recs if r.get("id")}))
except Exception:
    sys.exit(1)
')
  if [ -z "$map" ]; then
    warn "triage: $BV_BIN --robot-triage gave no usable JSON in $repo -- $(printf '%s' "$out" | head -n1)"
    printf '{}'
    return 0
  fi
  printf '%s' "$map"
}

cmd_plan() {
  local budget_override="" limit=12 scan_limit=60 night=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --budget)     budget_override=${2:-}; shift 2 ;;
      --limit)      limit=${2:-12}; shift 2 ;;
      --scan-limit) scan_limit=${2:-60}; shift 2 ;;
      --night)      night=${2:-}; shift 2 ;;
      -h|--help)    usage; return 0 ;;
      *) warn "plan: unknown argument '$1'"; verdict "MARSHAL_PLAN_RESULT=failed-usage"; return 64 ;;
    esac
  done
  conf_load "$CONF" || {
    warn "plan: $CONF_ERROR"
    verdict "MARSHAL_PLAN_RESULT=failed-config"
    return 78
  }
  [ -n "$night" ] || night=$(date -u +%Y-%m-%d)

  # --- R8: freeze first. A frozen demesne means ZERO dispatches, and the
  # ledger says frozen. Nothing below this line runs.
  if [ "$(freeze_state)" = "active" ]; then
    info "{\"night\":\"$night\",\"status\":\"frozen\",\"picks\":[],\"note\":\"demesne freeze active — zero dispatches (R8)\"}"
    verdict "MARSHAL_PLAN_RESULT=frozen"
    return 0
  fi

  # --- budget
  local budget budget_json
  if [ -n "$budget_override" ]; then
    budget=$budget_override
    budget_json="{\"status\":\"provided\",\"budget_tokens\":$budget_override}"
  else
    budget_compute ""
    budget=$BUDGET_TOKENS
    budget_json=$BUDGET_JSON
  fi
  if [ "${budget:-0}" -le 0 ] 2>/dev/null; then
    info "$budget_json"
    verdict "MARSHAL_PLAN_RESULT=no-budget"
    return 0
  fi

  local mail_note
  mail_note=$(read_mail)

  # --- selection, repo by repo, rank order, br scheduler as the ranker
  local picks_file refused_file
  picks_file=$(mktemp "${TMPDIR:-/tmp}/marshal-picks.XXXXXX")
  refused_file=$(mktemp "${TMPDIR:-/tmp}/marshal-refused.XXXXXX")
  local repo_notes=""
  local picked=0 scanned_total=0

  local home_repo entry name path
  home_repo=$(cfg home_repo dotfiles)
  local IFS_SAVE=$IFS
  IFS=,
  # shellcheck disable=SC2086  # the config value is comma-separated by design
  set -- $(cfg repos '')
  IFS=$IFS_SAVE
  for entry in "$@"; do
    [ -n "$entry" ] || continue
    name=${entry%%:*}
    path=${entry#*:}
    if [ ! -d "$path/.beads" ]; then
      repo_notes="$repo_notes${repo_notes:+; }$name:no-beads-db"
      continue
    fi
    # THE RANKER. `br scheduler --json` (br.scheduler.v1) and nothing else:
    # per-pick rank + score + an EXPLAINABLE rationale built from
    # dependency_impact / stale_claim / domain_contention. Its rationale lines
    # are what land in the drain ledger, which is the audit trail an
    # autonomous drain owes a reviewer who was asleep.
    local sched
    sched=$( (cd "$path" && "$BR_BIN" scheduler --json --limit "$scan_limit") 2>&1 )
    case "$sched" in
      '{'*) ;;
      *) repo_notes="$repo_notes${repo_notes:+; }$name:scheduler-unavailable"
         warn "plan: br scheduler gave no JSON in $path -- $(printf '%s' "$sched" | head -n1)"
         continue ;;
    esac
    local tmap
    tmap=$(triage_map "$path")

    # Flatten the scheduler's ranked candidates to TSV: rank, score, id, type,
    # rationale (joined). The description never leaves python — the marker
    # check goes back through the library's ID-based API on purpose.
    local flat
    flat=$(printf '%s' "$sched" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in d.get("recommendations") or []:
    iss = r.get("issue") or {}
    rid = iss.get("id") or ""
    if not rid:
        continue
    rat = " | ".join(r.get("rationale") or [])
    fields = [str(r.get("rank", "")), str(r.get("score", "")), rid,
              iss.get("issue_type") or "", (iss.get("title") or "").replace("\t", " "),
              rat.replace("\t", " ")]
    print("\t".join(f.replace("\n", " ") for f in fields))
')
    local scanned=0 repo_picked=0
    while IFS=$'\t' read -r rank score id btype title rationale; do
      [ -n "$id" ] || continue
      [ "$scanned" -ge "$scan_limit" ] && break
      [ "$picked" -ge "$limit" ] && break
      scanned=$((scanned + 1))
      local cls decision reason
      cls=$(classify_bead "$path" "$id" "$btype" "$title")
      decision=${cls%% *}
      reason=${cls#* }
      if [ "$decision" = "eligible" ]; then
        repo_picked=$((repo_picked + 1))
        picked=$((picked + 1))
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$name" "$path" "$id" "$btype" "$rank" "$score" \
          "$(bead_model "$path" "$id")" "$title" "$rationale" >> "$picks_file"
      else
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$id" "$btype" "$decision" "$reason" >> "$refused_file"
      fi
    done <<< "$flat"
    scanned_total=$((scanned_total + scanned))
    repo_notes="$repo_notes${repo_notes:+; }$name:scanned=$scanned,picked=$repo_picked"

    # Attach triage cross-check ids for this repo's picks.
    printf '%s' "$tmap" > "$picks_file.triage.$name"
  done

  # awk, not `grep -c || printf 0`: grep exits 1 on an empty file AFTER
  # printing its 0, so the `||` fallback appends a SECOND zero and the verdict
  # line becomes two lines — which breaks the one-verdict-last discipline in
  # exactly the case (an empty queue) nobody watches.
  local n
  n=$(awk 'NF{c++} END{print c+0}' "$picks_file")

  MD_NIGHT="$night" MD_BUDGET="$budget" MD_BUDGET_JSON="$budget_json" \
  MD_MAIL="$mail_note" MD_PICKS="$picks_file" MD_REFUSED="$refused_file" \
  MD_HOME="$home_repo" MD_NOTES="$repo_notes" MD_SCANNED="$scanned_total" \
  MD_SCANLIMIT="$scan_limit" MD_LIMIT="$limit" MD_PACING="$MOLT_PACING_PCT" \
  MD_BACKSTOP="$MOLT_BACKSTOP_PCT" MD_SELF="$_MD_DIR/marshal-drain.sh" \
  python3 - <<'PY'
import json, os, pathlib

picks_path = pathlib.Path(os.environ["MD_PICKS"])
refused_path = pathlib.Path(os.environ["MD_REFUSED"])
home = os.environ["MD_HOME"]
self_path = os.environ["MD_SELF"]

triage = {}
for p in picks_path.parent.glob(picks_path.name + ".triage.*"):
    try:
        triage.update(json.loads(p.read_text() or "{}"))
    except Exception:
        pass

picks = []
lane_seq = {}
for line in (picks_path.read_text().splitlines() if picks_path.exists() else []):
    if not line.strip():
        continue
    repo, path, bid, btype, rank, score, model, title, *rest = line.split("\t")
    rationale = rest[0] if rest else ""
    lane = "home:parallel" if repo == home else f"serial:{repo}"
    lane_seq[lane] = lane_seq.get(lane, 0) + 1
    picks.append({
        "bead": bid,
        "repo": repo,
        "repo_path": path,
        "type": btype,
        "scheduler_rank": int(rank) if rank.isdigit() else None,
        "scheduler_score": int(score) if score.isdigit() else None,
        "rationale": [s.strip() for s in rationale.split(" | ") if s.strip()],
        "triage_unblocks": triage.get(bid, []),
        "model": model,
        "title": title,
        "lane": lane,
        "wave": 1 if lane.startswith("home:") else lane_seq[lane],
        "verify_cmd": (f"{self_path} verify --repo {path} --bead {bid} "
                       f"--before <BEFORE_SHA> --agent-sha <AGENT_SHA>"),
    })

refused = []
for line in (refused_path.read_text().splitlines() if refused_path.exists() else []):
    if not line.strip():
        continue
    repo, bid, btype, decision, reason = line.split("\t")
    refused.append({"repo": repo, "bead": bid, "type": btype,
                    "decision": decision, "reason": reason})

try:
    budget_json = json.loads(os.environ["MD_BUDGET_JSON"])
except Exception:
    budget_json = {"status": "unparsed"}

print(json.dumps({
    "schema": "marshal.plan.v1",
    "night": os.environ["MD_NIGHT"],
    "budget_tokens": int(os.environ["MD_BUDGET"]),
    "budget": budget_json,
    "mail": os.environ["MD_MAIL"],
    "molt_pacing_pct": int(os.environ["MD_PACING"]),
    "molt_backstop_pct": int(os.environ["MD_BACKSTOP"]),
    "home_repo": home,
    "scanned": int(os.environ["MD_SCANNED"]),
    "scan_limit": int(os.environ["MD_SCANLIMIT"]),
    "pick_limit": int(os.environ["MD_LIMIT"]),
    "scan_truncated": int(os.environ["MD_SCANNED"]) >= int(os.environ["MD_SCANLIMIT"]),
    "repo_notes": os.environ["MD_NOTES"],
    "dispatch_until": "budget | queue | window — whichever exhausts first (R2 amendment: count is an outcome, not a cap)",
    "picks": picks,
    "refused": refused,
}, indent=2, sort_keys=True))
PY

  rm -f "$picks_file" "$refused_file" "$picks_file".triage.*

  if [ "$n" -eq 0 ]; then
    verdict "MARSHAL_PLAN_RESULT=empty-queue"
  else
    verdict "MARSHAL_PLAN_RESULT=planned:$n"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# RECORD — the ledger, and the R6 convergence answer
# ---------------------------------------------------------------------------
# R6 in one place, so the marshal never has to count failures by memory at 3am:
#   one failure          -> continue (comment the bead, unclaim)
#   the SAME bead twice  -> park it with `human:`
#   three consecutive
#   across DIFFERENT beads -> end the night with a P1 incident bead
# The streak is read back off the ledger, not held in a variable, because the
# marshal molts between beads and a molted session remembers nothing.

cmd_record() {
  local night="" bead="" repo="" outcome="" reason="" tokens="" model=""
  local rank="" score="" rationale="" evidence=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --night)     night=${2:-}; shift 2 ;;
      --bead)      bead=${2:-}; shift 2 ;;
      --repo)      repo=${2:-}; shift 2 ;;
      --outcome)   outcome=${2:-}; shift 2 ;;
      --reason)    reason=${2:-}; shift 2 ;;
      --tokens)    tokens=${2:-}; shift 2 ;;
      --model)     model=${2:-}; shift 2 ;;
      --rank)      rank=${2:-}; shift 2 ;;
      --score)     score=${2:-}; shift 2 ;;
      --rationale) rationale=${2:-}; shift 2 ;;
      --evidence)  evidence=${2:-}; shift 2 ;;
      -h|--help)   usage; return 0 ;;
      *) warn "record: unknown argument '$1'"; verdict "MARSHAL_RECORD_RESULT=failed-usage"; return 64 ;;
    esac
  done
  case "$outcome" in
    night-start|night-end|dispatched|merged|parked|failed|refused|skipped|molt) ;;
    *) warn "record: --outcome must be one of night-start night-end dispatched merged parked failed refused skipped molt (got '${outcome:-}')"
       verdict "MARSHAL_RECORD_RESULT=failed-usage"; return 64 ;;
  esac
  conf_load "$CONF" || { warn "record: $CONF_ERROR"; verdict "MARSHAL_RECORD_RESULT=failed-config"; return 78; }
  [ -n "$night" ] || night=$(date -u +%Y-%m-%d)

  mkdir -p "$(dirname "$LEDGER")" || {
    verdict "MARSHAL_RECORD_RESULT=failed-ledger-dir"; return 74; }

  local row
  row=$(MD_R_NIGHT="$night" MD_R_BEAD="$bead" MD_R_REPO="$repo" \
        MD_R_OUT="$outcome" MD_R_REASON="$reason" MD_R_TOKENS="$tokens" \
        MD_R_MODEL="$model" MD_R_RANK="$rank" MD_R_SCORE="$score" \
        MD_R_RAT="$rationale" MD_R_EV="$evidence" \
        MD_R_TS="${MARSHAL_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
        MD_R_LEDGER="$LEDGER" \
        python3 - <<'PY'
import json, os, pathlib
def s(k):
    v = os.environ.get(k) or ""
    return v or None
def n(k):
    v = os.environ.get(k) or ""
    return int(v) if v.lstrip("-").isdigit() else None

row = {
    "ts": os.environ["MD_R_TS"],
    "night": os.environ["MD_R_NIGHT"],
    "outcome": os.environ["MD_R_OUT"],
    "bead": s("MD_R_BEAD"),
    "repo": s("MD_R_REPO"),
    "reason": s("MD_R_REASON"),
    "tokens": n("MD_R_TOKENS"),
    "model": s("MD_R_MODEL"),
    "scheduler_rank": n("MD_R_RANK"),
    "scheduler_score": n("MD_R_SCORE"),
    "rationale": [x.strip() for x in (os.environ.get("MD_R_RAT") or "").split(" | ") if x.strip()] or None,
    "evidence": s("MD_R_EV"),
}

# A night-end row carries the night's TALLY, computed from the ledger rather
# than counted by a session that has molted twice since the first dispatch.
if row["outcome"] == "night-end":
    led = pathlib.Path(os.environ["MD_R_LEDGER"])
    rows = []
    if led.exists():
        for line in led.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("night") == row["night"]:
                rows.append(r)
    def count(o):
        return sum(1 for r in rows if r.get("outcome") == o)
    attempted = {r.get("bead") for r in rows
                 if r.get("outcome") in ("dispatched", "merged", "parked", "failed") and r.get("bead")}
    row["tally"] = {
        "attempted": len(attempted),
        "dispatched": count("dispatched"),
        "merged": count("merged"),
        "parked": count("parked"),
        "failed": count("failed"),
        "refused": count("refused"),
        "molts": count("molt"),
        "tokens_spent": sum(r.get("tokens") or 0 for r in rows),
    }
print(json.dumps(row, sort_keys=True))
PY
) || { verdict "MARSHAL_RECORD_RESULT=failed-encode"; return 70; }

  printf '%s\n' "$row" >> "$LEDGER" || {
    verdict "MARSHAL_RECORD_RESULT=failed-ledger-write"; return 74; }

  # --- R6, read back off the ledger
  local r6
  r6=$(MD_R_NIGHT="$night" MD_R_LEDGER="$LEDGER" \
       MD_R_MAX="$(cfg max_consecutive_failures 3)" \
       python3 - <<'PY'
import json, os, pathlib
led = pathlib.Path(os.environ["MD_R_LEDGER"])
night = os.environ["MD_R_NIGHT"]
maxfail = int(os.environ["MD_R_MAX"])
rows = []
for line in (led.read_text().splitlines() if led.exists() else []):
    line = line.strip()
    if not line:
        continue
    try:
        r = json.loads(line)
    except Exception:
        continue
    if r.get("night") == night:
        rows.append(r)

# The tail streak: consecutive `failed` rows at the end of tonight.
# ⚠️ ONLY a `merged` row breaks it. Every attempt writes a `dispatched` row
# BEFORE its outcome, so treating dispatch as a break would make the streak
# permanently 1 and three-strikes unreachable — a convergence rule that
# silently never fires, which is the failure mode R6 exists to prevent.
# A molt, a refusal, a skip and a park are all neutral: none of them is
# evidence the night is converging, and none is evidence it is not.
streak = []
for r in reversed(rows):
    o = r.get("outcome")
    if o == "failed":
        streak.append(r.get("bead"))
        continue
    if o == "merged":
        break
    # night-start / dispatched / parked / refused / skipped / molt: neutral
seen = [b for b in streak if b]
fails_for_last = sum(1 for r in rows
                     if r.get("outcome") == "failed" and r.get("bead") and r.get("bead") == (rows[-1].get("bead") if rows else None))
distinct = len(set(seen))

verdict = "recorded"
if rows and rows[-1].get("outcome") == "failed" and fails_for_last >= 2:
    verdict = "park-repeat-failure"
elif len(seen) >= maxfail and distinct >= maxfail:
    verdict = "three-strikes"
print(f"{verdict} {len(seen)}")
PY
) || { verdict "MARSHAL_RECORD_RESULT=recorded streak=?"; return 0; }

  local v n_streak
  v=${r6%% *}
  n_streak=${r6##* }
  case "$v" in
    three-strikes)       verdict "MARSHAL_RECORD_RESULT=three-strikes streak=$n_streak" ;;
    park-repeat-failure) verdict "MARSHAL_RECORD_RESULT=park-repeat-failure streak=$n_streak" ;;
    *)                   verdict "MARSHAL_RECORD_RESULT=recorded streak=$n_streak" ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# VERIFY — the post-merge assertions, read-only
# ---------------------------------------------------------------------------
# AGENTS.md's guarded-merge sequence ends in two assertions that exist because
# "Already up to date" is a SUCCESS exit code for a merge that did nothing —
# cwd drift into the agent's own branch, or an agent that committed nothing,
# both land there silently. This runs them, in one place, so a 3am loop cannot
# skip the half that catches its own no-op.
cmd_verify() {
  local repo="" bead="" before="" agent_sha="" target=main
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)      repo=${2:-}; shift 2 ;;
      --bead)      bead=${2:-}; shift 2 ;;
      --before)    before=${2:-}; shift 2 ;;
      --agent-sha) agent_sha=${2:-}; shift 2 ;;
      --target)    target=${2:-main}; shift 2 ;;
      -h|--help)   usage; return 0 ;;
      *) warn "verify: unknown argument '$1'"; verdict "MARSHAL_VERIFY_RESULT=abort-usage"; return 64 ;;
    esac
  done
  [ -n "$repo" ] && [ -n "$before" ] && [ -n "$agent_sha" ] || {
    warn "verify: --repo, --before and --agent-sha are all required"
    verdict "MARSHAL_VERIFY_RESULT=abort-usage"; return 64; }

  if [ ! -d "$repo/.git" ] && ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    verdict "MARSHAL_VERIFY_RESULT=abort-not-a-repo"; return 1
  fi

  local cur after
  cur=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ "$cur" != "$target" ]; then
    warn "verify: on branch '$cur', expected '$target' — a merge verified from the agent's own branch proves nothing"
    verdict "MARSHAL_VERIFY_RESULT=abort-wrong-branch"; return 1
  fi

  after=$(git -C "$repo" rev-parse HEAD 2>/dev/null)
  if [ "$after" = "$before" ]; then
    warn "verify: HEAD did not move — the merge silently no-oped ('Already up to date' exits 0)"
    verdict "MARSHAL_VERIFY_RESULT=abort-sha-unmoved"; return 1
  fi

  if ! git -C "$repo" merge-base --is-ancestor "$agent_sha" "$after" 2>/dev/null; then
    warn "verify: $agent_sha is not an ancestor of $after — the agent's commit is not in the target"
    verdict "MARSHAL_VERIFY_RESULT=abort-not-ancestor"; return 1
  fi

  info "{\"repo\":\"$repo\",\"bead\":\"$bead\",\"target\":\"$target\",\"before\":\"$before\",\"after\":\"$after\",\"agent_sha\":\"$agent_sha\",\"assertions\":[\"branch\",\"sha-moved\",\"ancestor\"]}"
  verdict "MARSHAL_VERIFY_RESULT=ok"
  return 0
}

usage() {
  cat >&2 <<'EOF'
Usage: marshal-drain.sh <budget|plan|record|verify> [options]

  budget [--weekly-cap N]
      Tonight's token budget from pico's requests.db + marshal.conf.
      Prints the derivation as JSON; last line MARSHAL_BUDGET=...

  plan [--budget N] [--limit N] [--scan-limit N] [--night ID]
      Freeze -> budget -> mail -> selection. Prints marshal.plan.v1 JSON;
      last line MARSHAL_PLAN_RESULT=...

  record --outcome <night-start|dispatched|merged|parked|failed|refused|
                    skipped|molt|night-end>
         [--night ID] [--bead ID] [--repo NAME] [--reason S] [--tokens N]
         [--model M] [--rank N] [--score N] [--rationale S] [--evidence S]
      Appends one drain-ledger row; last line MARSHAL_RECORD_RESULT=...

  verify --repo PATH --bead ID --before SHA --agent-sha SHA [--target BRANCH]
      Read-only post-merge assertions; last line MARSHAL_VERIFY_RESULT=...
EOF
}

main() {
  local verb=${1:-}
  case "$verb" in
    budget) shift; cmd_budget "$@" ;;
    plan)   shift; cmd_plan "$@" ;;
    record) shift; cmd_record "$@" ;;
    verify) shift; cmd_verify "$@" ;;
    -h|--help|help) usage; return 0 ;;
    '') usage; return 64 ;;
    *) warn "marshal-drain.sh: unknown subcommand '$verb'"; usage; return 64 ;;
  esac
}

main "$@"
