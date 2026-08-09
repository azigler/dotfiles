#!/usr/bin/env bash
# tap-headroom.sh — the ONE per-POOL headroom reader (dotfiles-kecb, building
# dotfiles-rbci's ruled spec; partially delivers dotfiles-yrsg's reader —
# integrate here, never fork a second one).
#
# Sourced as a library by the launch seam (agents/lib/claude-identity-wrapper.sh)
# and runnable as an operator command:
#
#     bash agents/lib/tap-headroom.sh              # every pool, verdict last line
#     bash agents/lib/tap-headroom.sh --pool primary
#     bash agents/lib/tap-headroom.sh --fable      # include the model-scoped arm
#
# OUTCOME CONTRACT (the house shape — pico-health.sh, backup-health.sh). The
# last line is always
#
#     TAP_HEADROOM_RESULT=<ok|ceiling|degraded|unavailable>
#
# Exit codes: 0 every consulted pool has headroom · 10 a real finding (at least
# one pool is AT ITS CEILING) · 1 THIS READER could not measure. The four-valued
# vocabulary keeps "I could not measure" (`unavailable`) distinguishable from
# "measured, and it is full" (`ceiling`) — collapsing those two is precisely how
# a headroom reader starts authorising rollovers it has no evidence for.
# `degraded` is the mixed case: some pool measured, some did not.
#
# ---------------------------------------------------------------------------
# TWO SOURCES, AND WHY BOTH EXIST
# ---------------------------------------------------------------------------
# 1. THE ACCOUNT'S OWN USAGE DOCUMENT (`oauth`) — GET /api/oauth/usage on
#    api.anthropic.com with the pool's own OAuth access token. Discovered
#    empirically 2026-08-09 (this bead); real captured responses live beside
#    this file in tap-headroom-fixtures/. It is the ONLY source for the
#    MODEL-SCOPED weekly allotment (the Fable dimension): its `limits[]` array
#    carries `{kind: weekly_scoped, scope.model.display_name: "Fable",
#    percent: 81}` where the unified weekly read 75. Percentages are 0-100
#    there and normalised to 0-1 here.
#
# 2. THE GATEWAY'S REQUEST LOG (`gateway`) — the per-request
#    anthropic.ratelimit.{5h,7d} attributes pico captures into
#    request_logs.attributes_json (dotfiles-7qi7, live 16:23Z 2026-08-09).
#    Unified windows only, no model dimension, but it needs no credential and
#    it keeps working when a tap's access token has gone stale.
#
# The default is `both`: oauth first, gateway as the fallback. That ordering is
# not a preference for freshness, it is the only order that can see the Fable
# dimension at all.
#
# ---------------------------------------------------------------------------
# THE POOL IS THE UNIT (see agents/scheduler/taps.conf for the full ruling)
# ---------------------------------------------------------------------------
# primary{primary,tick} · secondary{secondary} · linearb{linearb}. tick shares
# primary's ACCOUNT and therefore primary's ceiling, so a primary->tick
# "failover" moves nothing; the conf encodes that and this file never reasons
# about taps individually.
#
# ---------------------------------------------------------------------------
# EVERY DEGRADE IS LOUD, AND `unavailable` NEVER MEANS ZERO
# ---------------------------------------------------------------------------
# Measured on the day this was written, both directions:
#   * pool `linearb`'s access token was EXPIRED — the usage endpoint answered
#     401 `authentication_error`. A reader that treated a failed read as "0%
#     used" would have declared the LinearB subscription wide open on the
#     strength of a credential that cannot make a request.
#   * pool `secondary` had exactly one logged request and its captured
#     ratelimit attributes were the EMPTY STRING, not NULL — the gateway's
#     `default()` guard writes `""` when Anthropic sends no header. A
#     `json_extract(...) IS NOT NULL` filter passes those rows, and `""`
#     compares as 0 in awk. Both traps have the same shape and the same fix:
#     an unmeasured window is `unavailable`, never a number.
#
# KNOBS (all env, all with defaults):
#   TAP_HEADROOM_CONF          the conf                (<agents>/scheduler/taps.conf)
#   TAP_HEADROOM_SOURCE        oauth|gateway|both      (both)
#   TAP_HEADROOM_CURL          the curl binary — SEAM  (curl)
#   TAP_HEADROOM_USAGE_URL     the usage document      (https://api.anthropic.com/api/oauth/usage)
#   TAP_HEADROOM_SSH           the ssh binary — SEAM   (ssh)
#   TAP_HEADROOM_GATEWAY_HOST  where requests.db lives (pico)
#   TAP_HEADROOM_DB            its path ON THAT HOST   (~/.local/share/agentgateway/requests.db)
#   TAP_HEADROOM_MAX_AGE_MIN   gateway freshness window (360)
#   TAP_HEADROOM_HOME          $HOME for ~ expansion   ($HOME)
#   TAP_HEADROOM_CACHE_DIR     per-pool reading cache  (~/.local/share/fleet-health/tap-headroom)
#   TAP_HEADROOM_NO_CACHE      any non-empty value bypasses the cache

# --- conf ------------------------------------------------------------------

_th_self="${BASH_SOURCE[0]:-$0}"
_th_dir="$(cd "$(dirname -- "$_th_self")" 2>/dev/null && pwd)"
if [ -n "$_th_dir" ] && [ -f "$_th_dir/agents-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$_th_dir/agents-root.sh"
fi
if ! declare -F agents_root >/dev/null 2>&1; then
  # shellcheck disable=SC2119,SC2120  # same fallback shape as the wrapper's
  agents_root() { [ -d "$HOME/dotfiles/${1:-agents}" ] && printf '%s\n' "$HOME/dotfiles/${1:-agents}"; }
fi
if [ -z "${TAP_HEADROOM_CONF:-}" ]; then
  if [ -n "$_th_dir" ] && [ -f "$_th_dir/../scheduler/taps.conf" ]; then
    TAP_HEADROOM_CONF="$_th_dir/../scheduler/taps.conf"
  else
    TAP_HEADROOM_CONF="$(agents_root)/scheduler/taps.conf"
  fi
fi
unset _th_self _th_dir

TH_HOME="${TAP_HEADROOM_HOME:-$HOME}"

# th_conf_get <key> — one value out of the conf, or "" when absent.
#
# STRICT GRAMMAR, and the refusal is the point: `key=value`, key
# [a-z][a-z0-9_.-]*, value [A-Za-z0-9_,./~:-]+ . Nothing is expanded and
# nothing is executed. A line that does not match is IGNORED here and REPORTED
# by th_conf_lint — this file is read on the launch path of every claude on the
# box, and a conf that can execute is a conf that can be an incident
# (marshal.conf's rule, same words).
th_conf_get() {
  [ -f "$TAP_HEADROOM_CONF" ] || return 1
  awk -v want="$1" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      i = index(line, "=")
      if (i < 2) next
      k = substr(line, 1, i-1)
      v = substr(line, i+1)
      if (k !~ /^[a-z][a-z0-9_.-]*$/) next
      if (v !~ /^[A-Za-z0-9_,.\/~:-]+$/) next
      if (k == want) { print v; found=1; exit }
    }
    END { if (!found) exit 1 }
  ' "$TAP_HEADROOM_CONF"
}

# th_conf_lint — every line the grammar refuses, one per line of output. Used
# by the suite and by --lint; a conf whose keys silently do not parse is the
# failure mode that leaves the whole mechanism reading its defaults.
th_conf_lint() {
  [ -f "$TAP_HEADROOM_CONF" ] || { echo "missing conf: $TAP_HEADROOM_CONF"; return 1; }
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      line=$0
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      i = index(line, "=")
      if (i < 2) { print NR ": not key=value: " line; bad=1; next }
      k = substr(line, 1, i-1); v = substr(line, i+1)
      if (k !~ /^[a-z][a-z0-9_.-]*$/) { print NR ": bad key: " k; bad=1; next }
      if (v !~ /^[A-Za-z0-9_,.\/~:-]+$/) { print NR ": bad value: " v; bad=1; next }
    }
    END { exit (bad ? 1 : 0) }
  ' "$TAP_HEADROOM_CONF"
}

# th_pools — the preference order, space separated.
th_pools() { th_conf_get order | tr ',' ' '; }

# th_pool_of_tap <tap> — the pool a tap or profile draws on, or "" .
th_pool_of_tap() {
  local p t
  [ -n "${1:-}" ] || return 1
  for p in $(th_pools); do
    for t in $(th_conf_get "pool.$p.taps" | tr ',' ' '); do
      [ "$t" = "$1" ] && { printf '%s' "$p"; return 0; }
    done
  done
  return 1
}

# th_pool_config_dir <pool> — with ~ resolved against $TH_HOME.
th_pool_config_dir() {
  local d
  d=$(th_conf_get "pool.$1.config_dir") || return 1
  # The quotes on the pattern are load-bearing: an UNQUOTED `~/` inside
  # ${d#~/} is TILDE-EXPANDED before it is used as a pattern, so it matches
  # nothing and the value silently comes back as $HOME/~/.claude-… . Measured
  # here on the first live run.
  case "$d" in
    '~'/*) d="$TH_HOME/${d#'~'/}" ;;
    '~')   d="$TH_HOME" ;;
  esac
  printf '%s' "$d"
}

# th_home_pool <seat> — the seat's home pool: its `seat_home.<seat>` override,
# else the first pool in the global order. The override moves the seat's FIRST
# choice only; the rest of the order still applies behind it (a linearb seat at
# its ceiling rolls linearb > primary > secondary).
th_home_pool() {
  local o
  if [ -n "${1:-}" ] && o=$(th_conf_get "seat_home.$1"); then
    printf '%s' "$o"; return 0
  fi
  th_pools | awk '{print $1}' | tr -d '\n'
}

# th_order_from <home-pool> — the candidate order for a launch: home first,
# then the global order with home removed.
th_order_from() {
  local home=$1 p out=""
  [ -n "$home" ] && out="$home"
  for p in $(th_pools); do
    [ "$p" = "$home" ] && continue
    out="$out${out:+ }$p"
  done
  printf '%s' "$out"
}

# th_candidates <home-pool> [seat] — the full candidate order for ONE launch.
#
# Two facts compose here and they are not the same fact:
#   * the HOME pool is whatever this launch is ACTUALLY configured for
#     (derived from its own CLAUDE_CONFIG_DIR — the wrapper's founding
#     invariant: derived from what runs, never asserted from the roster), so it
#     is always first;
#   * the SEAT's `seat_home.<seat>` override, when it has one, orders what
#     comes BEHIND home — so a linearb seat that somehow launched on primary
#     still prefers linearb over secondary for its rollover, and never has its
#     work quietly migrate onto Zig's personal subscription while LinearB's
#     sits idle.
th_candidates() {
  local home=$1 seat="${2:-}" p out=""
  [ -n "$home" ] && out="$home"
  for p in $(th_order_from "$(th_home_pool "$seat")"); do
    [ "$p" = "$home" ] && continue
    out="$out${out:+ }$p"
  done
  printf '%s' "$out"
}

# --- the readings ----------------------------------------------------------

# th_num_ge <a> <b> — float compare without bc. Empty is NEVER >= anything:
# that is the `""`-compares-as-zero trap in one place instead of five.
th_num_ge() {
  [ -n "${1:-}" ] || return 1
  [ -n "${2:-}" ] || return 1
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'
}

# th_read_oauth <pool> — `u5h u7d fable` (0-1 floats), or non-zero with a
# reason on stdout prefixed `ERR `.
#
# The token is read from the pool's credential file and passed to curl through
# a header ARGUMENT. It is never printed, never logged and never written
# anywhere by this file. A credential whose `expiresAt` is in the past is
# refused BEFORE the request: a stale token answers 401 and 401 must never be
# mistaken for headroom (measured on `linearb`, 2026-08-09).
th_read_oauth() {
  local pool=$1 cfg
  cfg=$(th_pool_config_dir "$pool") || { echo "ERR no config_dir for pool $pool"; return 1; }
  [ -f "$cfg/.credentials.json" ] || { echo "ERR no credential at $cfg/.credentials.json"; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "ERR python3 unavailable"; return 1; }
  TH_CURL="${TAP_HEADROOM_CURL:-curl}" \
  TH_URL="${TAP_HEADROOM_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}" \
  TH_TIMEOUT="$(th_conf_get timeout_seconds || echo 4)" \
  TH_SCOPE="$(th_conf_get fable_scope || echo Fable)" \
  python3 - "$cfg/.credentials.json" <<'PY'
import json, os, subprocess, sys, time

cred_path = sys.argv[1]
try:
    cred = json.load(open(cred_path))["claudeAiOauth"]
except Exception as e:                                   # noqa: BLE001
    print("ERR credential unreadable: %s" % type(e).__name__); sys.exit(1)

exp = cred.get("expiresAt")
if isinstance(exp, (int, float)) and exp / 1000.0 < time.time():
    # The 401 this would produce is indistinguishable from a real answer of
    # "no usage", so it is refused here rather than parsed there.
    print("ERR credential access token EXPIRED (refresh by using this tap)")
    sys.exit(1)
token = cred.get("accessToken")
if not token:
    print("ERR credential has no accessToken"); sys.exit(1)

try:
    proc = subprocess.run(
        [os.environ["TH_CURL"], "-sS", "--max-time", os.environ.get("TH_TIMEOUT", "4"),
         "-w", "\n%{http_code}",
         "-H", "Authorization: Bearer %s" % token,
         "-H", "anthropic-beta: oauth-2025-04-20",
         "-H", "anthropic-version: 2023-06-01",
         os.environ["TH_URL"]],
        capture_output=True, text=True, timeout=30)
except Exception as e:                                   # noqa: BLE001
    print("ERR usage request failed: %s" % type(e).__name__); sys.exit(1)

body, _, code = proc.stdout.rpartition("\n")
code = code.strip()
if code != "200":
    print("ERR usage endpoint http %s" % (code or "<none>")); sys.exit(1)
try:
    doc = json.loads(body)
except Exception:                                        # noqa: BLE001
    print("ERR usage response is not JSON"); sys.exit(1)


def pct(v):
    """0-100 -> 0-1. None/absent stays absent — never 0."""
    return None if v is None else float(v) / 100.0


u5h = u7d = fable = None
for lim in doc.get("limits") or []:
    kind = lim.get("kind")
    if kind == "session":
        u5h = pct(lim.get("percent"))
    elif kind == "weekly_all":
        u7d = pct(lim.get("percent"))
    elif kind == "weekly_scoped":
        scope = (lim.get("scope") or {}).get("model") or {}
        if (scope.get("display_name") or "") == os.environ.get("TH_SCOPE", "Fable"):
            fable = pct(lim.get("percent"))
# The top-level blocks are the older shape of the same two numbers; used only
# when limits[] did not carry them, never in preference to it.
if u5h is None:
    u5h = pct((doc.get("five_hour") or {}).get("utilization"))
if u7d is None:
    u7d = pct((doc.get("seven_day") or {}).get("utilization"))
if u5h is None and u7d is None and fable is None:
    print("ERR usage document carried no utilization at all"); sys.exit(1)


def fmt(x):
    return "" if x is None else ("%.4f" % x)


print("%s %s %s" % (fmt(u5h), fmt(u7d), fmt(fable)))
PY
}

# th_read_gateway <pool> — `u5h u7d ""` from pico's request log, or non-zero
# with `ERR ...`. No model dimension exists here; the third field is always
# empty and the caller must not read it as zero.
#
# TWO QUERY TRAPS, both paid for already (infra.md, dotfiles-9o46):
#   * the table is `request_logs` and the time column is `started_at`, which is
#     ISO8601 with a `T` — a bare string comparison against datetime('now',…)
#     matches EVERY row with today's date. Always datetime(started_at).
#   * `json_extract(...) IS NOT NULL` is not enough: the gateway's default()
#     guard writes the EMPTY STRING when Anthropic sends no header, and "" is
#     not null. Hence the `<> ''` half of the filter.
th_read_gateway() {
  local pool=$1 groups glist g maxage db host out
  groups=$(th_conf_get "pool.$pool.groups") || { echo "ERR no groups for pool $pool"; return 1; }
  glist=""
  for g in $(printf '%s' "$groups" | tr ',' ' '); do
    case "$g" in
      *[!A-Za-z0-9_-]*) echo "ERR refusing non-token group '$g'"; return 1 ;;
    esac
    glist="$glist${glist:+,}'$g'"
  done
  [ -n "$glist" ] || { echo "ERR pool $pool has no group values"; return 1; }
  maxage="${TAP_HEADROOM_MAX_AGE_MIN:-360}"
  db="${TAP_HEADROOM_DB:-~/.local/share/agentgateway/requests.db}"
  host="${TAP_HEADROOM_GATEWAY_HOST:-pico}"
  out=$("${TAP_HEADROOM_SSH:-ssh}" -o ConnectTimeout="$(th_conf_get timeout_seconds || echo 4)" "$host" \
      "sqlite3 $db \"select json_extract(attributes_json,'\\\$.\\\"anthropic.ratelimit.5h\\\"'), json_extract(attributes_json,'\\\$.\\\"anthropic.ratelimit.7d\\\"') from request_logs where agentgateway_group in ($glist) and datetime(started_at) > datetime('now','-$maxage minutes') and json_extract(attributes_json,'\\\$.\\\"anthropic.ratelimit.5h\\\"') is not null and json_extract(attributes_json,'\\\$.\\\"anthropic.ratelimit.5h\\\"') <> '' order by started_at desc limit 1;\"") || {
    echo "ERR gateway read failed (host $host)"; return 1; }
  out=$(printf '%s' "$out" | tail -1)
  [ -n "$out" ] || { echo "ERR no utilization logged for pool $pool in the last ${maxage}m"; return 1; }
  printf '%s %s ' "${out%%|*}" "${out##*|}"
  printf '\n'
}

# --- the verdict -----------------------------------------------------------

# th_pool_headroom <pool> [--fable] — ONE pool's reading as a single line:
#
#   pool=<p> state=<ok|ceiling|unavailable> src=<oauth|gateway|none> \
#     u5h=<> u7d=<> fable=<> reason=<>
#
# rc 0 ok · 10 ceiling · 1 unavailable. Every unavailable also names itself on
# stderr: this reader's whole job is to be believed, so it says out loud when
# it could not measure rather than returning a number nobody can distinguish
# from a measurement.
th_pool_headroom() {
  local pool=$1 want_fable=0 src="none" line="" rc u5h="" u7d="" fable="" reason="" state
  [ "${2:-}" = "--fable" ] && want_fable=1
  local ceiling fceiling
  ceiling=$(th_conf_get ceiling || echo 1.0)
  fceiling=$(th_conf_get fable_ceiling || echo 1.0)

  local cache ttl now mtime
  cache="${TAP_HEADROOM_CACHE_DIR:-$TH_HOME/.local/share/fleet-health/tap-headroom}/pool-$pool"
  ttl=$(th_conf_get cache_ttl_seconds || echo 120)
  if [ -z "${TAP_HEADROOM_NO_CACHE:-}" ] && [ -f "$cache" ]; then
    now=$(date +%s)
    mtime=$(date -r "$cache" +%s 2>/dev/null || stat -c %Y "$cache" 2>/dev/null || echo 0)
    if [ $((now - mtime)) -lt "$ttl" ]; then
      line=$(cat "$cache")
      src=$(printf '%s' "$line" | awk '{print $1}')
      u5h=$(printf '%s' "$line" | awk '{print $2}')
      u7d=$(printf '%s' "$line" | awk '{print $3}')
      fable=$(printf '%s' "$line" | awk '{print $4}')
      [ "$u5h" = "-" ] && u5h=""; [ "$u7d" = "-" ] && u7d=""; [ "$fable" = "-" ] && fable=""
    fi
  fi

  if [ -z "$line" ]; then
    local want="${TAP_HEADROOM_SOURCE:-both}" out
    if [ "$want" = "oauth" ] || [ "$want" = "both" ]; then
      out=$(th_read_oauth "$pool"); rc=$?
      if [ "$rc" -eq 0 ]; then
        src=oauth
        u5h=$(printf '%s' "$out" | awk '{print $1}')
        u7d=$(printf '%s' "$out" | awk '{print $2}')
        fable=$(printf '%s' "$out" | awk '{print $3}')
      else
        reason="${out#ERR }"
      fi
    fi
    if [ "$src" = "none" ] && { [ "$want" = "gateway" ] || [ "$want" = "both" ]; }; then
      out=$(th_read_gateway "$pool"); rc=$?
      if [ "$rc" -eq 0 ]; then
        src=gateway
        u5h=$(printf '%s' "$out" | awk '{print $1}')
        u7d=$(printf '%s' "$out" | awk '{print $2}')
        fable=""
        reason=""
      else
        reason="${reason:+$reason; }${out#ERR }"
      fi
    fi
    if [ "$src" != "none" ]; then
      mkdir -p "$(dirname "$cache")" && \
        printf '%s %s %s %s\n' "$src" "${u5h:--}" "${u7d:--}" "${fable:--}" > "$cache"
    fi
  fi

  # THE VERDICT. Unmeasured is `unavailable`, never `ok` — a pool nobody could
  # read must not be rolled into, and a home pool nobody could read must not be
  # rolled OUT of either.
  if [ "$src" = "none" ]; then
    state=unavailable
    reason="${reason:-no source answered}"
  elif [ -z "$u5h" ] && [ -z "$u7d" ] && [ -z "$fable" ]; then
    state=unavailable
    reason="${reason:-source $src returned no numbers}"
  elif th_num_ge "$u5h" "$ceiling"; then
    state=ceiling; reason="5h window at $u5h (ceiling $ceiling)"
  elif th_num_ge "$u7d" "$ceiling"; then
    state=ceiling; reason="7d window at $u7d (ceiling $ceiling)"
  elif [ "$want_fable" -eq 1 ] && [ -z "$fable" ]; then
    # A fable-scoped launch whose fable allotment could NOT be read is
    # unavailable, not ok: the gateway arm has no model dimension at all, so
    # silently passing here is exactly "the fable dimension ignored".
    state=unavailable
    reason="no model-scoped reading from src=$src (the gateway arm has no model dimension)"
  elif [ "$want_fable" -eq 1 ] && th_num_ge "$fable" "$fceiling"; then
    state=ceiling; reason="model-scoped weekly allotment at $fable (ceiling $fceiling)"
  else
    state=ok; reason=""
  fi

  printf 'pool=%s state=%s src=%s u5h=%s u7d=%s fable=%s reason=%s\n' \
    "$pool" "$state" "$src" "${u5h:--}" "${u7d:--}" "${fable:--}" "${reason:--}"
  case "$state" in
    ok)     return 0 ;;
    ceiling) return 10 ;;
    *)
      echo "tap-headroom: pool '$pool' UNAVAILABLE — $reason. No rollover decision will be made on it." >&2
      return 1 ;;
  esac
}

# th_pick_pool <home-pool> [--fable] — THE CONSULT. Prints the pool a launch
# should use. rc 0 the home pool (the overwhelming case), 10 a ROLLOVER, 1
# nothing could be measured (caller stays home — see below).
#
# CEILING ONLY (Zig, OQ-2). Nothing here spreads load, warms a reserve or
# balances anything: the home pool is returned unless it is measurably AT its
# ceiling, and then the first candidate behind it with measured headroom is.
#
# FAIL TOWARDS HOME, ALWAYS. If the home pool cannot be measured, the answer is
# home — an unmeasured pool is never evidence for moving Zig's billing. If home
# is at its ceiling and NO candidate can be measured, the answer is still home:
# a stalled launch on the right account is recoverable (dotfiles-yrsg waits out
# the reset); a silent cross-billed one is not.
th_pick_pool() {
  local home=$1 seat="${2:-}" fable_flag="${3:-}" p rc
  [ -n "$home" ] || return 1
  th_pool_headroom "$home" $fable_flag >/dev/null; rc=$?
  if [ "$rc" -ne 10 ]; then
    printf '%s' "$home"
    [ "$rc" -eq 0 ] && return 0
    return 1
  fi
  for p in $(th_candidates "$home" "$seat"); do
    [ "$p" = "$home" ] && continue
    if th_pool_headroom "$p" $fable_flag >/dev/null; then
      printf '%s' "$p"
      return 10
    fi
  done
  printf '%s' "$home"
  return 1
}

# --- CLI -------------------------------------------------------------------

th_main() {
  local only="" fable_flag="" p rc worst=0 any_ok=0 any_unavail=0 any_ceiling=0
  local pick_home="" pick_seat=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pool) only="$2"; shift 2 ;;
      --fable) fable_flag="--fable"; shift ;;
      --lint) th_conf_lint; return $? ;;
      --order) th_order_from "$(th_home_pool "${2:-}")"; echo; return 0 ;;
      --candidates) th_candidates "${2:-}" "${3:-}"; echo; return 0 ;;
      --pick) pick_home="${2:-}"; pick_seat="${3:-}"; shift 3 ;;
      -h|--help) sed -n '2,12p' "$0"; return 0 ;;
      *) echo "tap-headroom: unknown argument '$1'" >&2; return 1 ;;
    esac
  done
  if [ -n "$pick_home" ]; then
    th_pick_pool "$pick_home" "$pick_seat" "$fable_flag"; rc=$?
    echo
    case "$rc" in
      0)  echo "TAP_HEADROOM_RESULT=ok" ;;
      10) echo "TAP_HEADROOM_RESULT=ceiling" ;;
      *)  echo "TAP_HEADROOM_RESULT=unavailable" ;;
    esac
    return $rc
  fi
  if ! th_conf_lint >/dev/null; then
    echo "tap-headroom: the conf does not parse — $TAP_HEADROOM_CONF" >&2
    th_conf_lint >&2
    echo "TAP_HEADROOM_RESULT=unavailable"
    return 1
  fi
  for p in ${only:-$(th_pools)}; do
    th_pool_headroom "$p" $fable_flag; rc=$?
    case "$rc" in
      0)  any_ok=1 ;;
      10) any_ceiling=1 ;;
      *)  any_unavail=1 ;;
    esac
  done
  if [ "$any_ok" -eq 0 ] && [ "$any_ceiling" -eq 0 ]; then
    echo "TAP_HEADROOM_RESULT=unavailable"; worst=1
  elif [ "$any_ceiling" -eq 1 ]; then
    echo "TAP_HEADROOM_RESULT=ceiling"; worst=10
  elif [ "$any_unavail" -eq 1 ]; then
    echo "TAP_HEADROOM_RESULT=degraded"; worst=10
  else
    echo "TAP_HEADROOM_RESULT=ok"; worst=0
  fi
  return $worst
}

# Run only when EXECUTED, never when sourced — the launch seam sources this
# file and must get functions and nothing else. `return` outside a function is
# an error in a script but not in a sourced file, which is the portable
# bash-and-zsh way to ask "was I sourced?".
#
# ⚠️ THE LAST STATEMENT'S EXIT STATUS IS THE SOURCED FILE'S. Written as `[ … ]
# && { th_main; }` this file returned 1 to every caller that sourced it — the
# `&&` is false in exactly the sourced case — so the launch seam's `. "$lib" ||
# exit 0` bailed out before the consult ever ran, silently, with the whole
# library working perfectly when driven by hand. Caught by T20 on the first run
# of the wrapper suite; keep the explicit `if`/`fi` and the trailing `:`.
_th_sourced=1
if [ -n "${BASH_SOURCE:-}" ]; then
  if [ "${BASH_SOURCE[0]}" = "$0" ]; then _th_sourced=0; fi
else
  case "${ZSH_EVAL_CONTEXT:-}" in
    *:file:*|*:file) : ;;               # sourced under zsh
    *) _th_sourced=0 ;;
  esac
fi
if [ "$_th_sourced" -eq 0 ]; then
  unset _th_sourced
  th_main "$@"
  exit $?
fi
unset _th_sourced
:
