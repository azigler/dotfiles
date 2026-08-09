#!/usr/bin/env bash
# gateway-health — the keep watches the fleet's ONE door, and opens it again.
#
# WHY THIS EXISTS. 2026-08-09, 12:36–15:08Z (dotfiles-kviw): pico rebooted into
# Tahoe and launchd came back WITHOUT any of the `com.zig.*` LaunchAgents. The
# agentgateway relay on :17017 was simply not there. Routing is deliberately
# fail-hard (dotfiles-ucl4), so every seat on the fleet lost claude at once —
# and stayed lost for two and a half hours, because nothing on the keep was
# watching the door and nothing was allowed to re-open it. pico-health SEES this
# (30-min cadence) but is READ-ONLY BY CHARTER; it is the detector, not the
# recovery. This is the recovery arm.
#
# It is a deliberate CLONE of pico-health.sh in posture — same outcome contract,
# same exit codes, same ledger discipline, same unit posture — and differs in
# exactly one way: it is WRITE-CAPABLE on pico, for ONE verb, restarting one job.
#
# 🚫 IT NEVER RUNS gateway-switch.sh. Flipping the fleet from the gateway to
# direct routing changes where every seat's traffic goes, what gets attributed,
# and which key pays; that is an operator/orchestrator decision with a human in
# it. A 2-minute timer must not make it. This guard's whole authority is
# "restart the thing that is supposed to be running" — nothing else.
#
# OUTCOME CONTRACT. The last line is always
#
#     GATEWAY_HEALTH_RESULT=<ok|restored|down-unrecovered|pico-unreachable>
#
# Exit codes: 0 the door is open · 10 a real finding (INCLUDING `restored` — a
# fleet-wide outage that had to be repaired is news, not a quiet success) ·
# anything else, THIS CHECKER is broken. The unit deliberately does NOT list 10
# in SuccessExitStatus, so a finding lands in `systemctl --user --failed`, the
# surface the fleet already reads.
#
# THE HEALTHY SIGNATURE IS 401, AND ANY HTTP STATUS MEANS UP. :17017 is a
# transparent passthrough to api.anthropic.com with no key attached
# (agents/infra.md), so an unauthenticated probe of /claude/v1/models gets 401
# from Anthropic — which proves the relay is listening AND forwarding. Do not
# "fix" this to expect 200, and do not narrow it to 401 either: a 429, a 500, a
# 200 all mean the door is open. ONLY a connect failure (curl prints 000) means
# down. Narrowing the accepted set would turn an Anthropic-side blip into a
# launchctl kickstart of a perfectly healthy gateway.
#
# THE RECOVERY, in the order the incident actually needed:
#   1. `launchctl kickstart -k <job>` — the ordinary case, a wedged/crashed job.
#   2. If launchctl answers "Could not find service", the job is not LOADED at
#      all — the 2026-08-09 shape exactly — so `launchctl bootstrap gui/501
#      <plist>` first, then kickstart again.
#   3. Re-probe (settle, then up to GW_PROBE_TRIES times). Up ⇒ `restored`.
#      Still down ⇒ `down-unrecovered`: this guard has spent its authority and a
#      human is needed.
# An ssh that cannot connect at all is `pico-unreachable` — a DIFFERENT fact
# from "the gateway is down", and the one where waking a human is right.
#
# DURABILITY. Every non-ok verdict appends one JSON object to $GW_LEDGER, and so
# does the first `ok` AFTER a non-ok — that row IS the recovery record, and
# without it the ledger would show an outage that never ended. A plain `ok` with
# an `ok` before it appends nothing: 720 runs a day would otherwise bury the
# ledger in the good news nobody reads. An unwritable ledger is a BROKEN
# CHECKER (exit 1), never a healthy fleet.
#
# LLM-FREE. One curl and at most three ssh commands need no model; an agent is
# summoned by the finding, not by the schedule. Deliberately NOT a /pulse row.
#
# Knobs (all env, all with defaults, each one a test seam):
#   GW_PROBE_URL        the door                  (http://100.72.47.4:17017/claude/v1/models)
#   GW_CURL             the probe binary          (curl)
#   GW_SSH              the ssh binary            (ssh)
#   GW_HOST             ssh target                (pico)
#   GW_JOB              launchd service target    (gui/501/com.zig.agentgateway)
#   GW_PLIST            plist for the bootstrap   (/Users/pico/Library/LaunchAgents/com.zig.agentgateway.plist)
#   GW_LEDGER           durable verdict ledger    (~/.local/share/fleet-health/gateway.jsonl)
#   GW_CONNECT_TIMEOUT  ssh ConnectTimeout, secs  (15)
#   GW_SETTLE           seconds before a re-probe (5)
#   GW_PROBE_TRIES      re-probes after a restart (2)

set -uo pipefail

PROBE_URL="${GW_PROBE_URL:-http://100.72.47.4:17017/claude/v1/models}"
CURL_BIN="${GW_CURL:-curl}"
SSH_BIN="${GW_SSH:-ssh}"
HOST="${GW_HOST:-pico}"
JOB="${GW_JOB:-gui/501/com.zig.agentgateway}"
PLIST="${GW_PLIST:-/Users/pico/Library/LaunchAgents/com.zig.agentgateway.plist}"
LEDGER="${GW_LEDGER:-$HOME/.local/share/fleet-health/gateway.jsonl}"
CONNECT_TIMEOUT="${GW_CONNECT_TIMEOUT:-15}"
SETTLE="${GW_SETTLE:-5}"
TRIES="${GW_PROBE_TRIES:-2}"
# The launchd DOMAIN is the job target minus its label — derived, never a second
# literal, so GW_JOB and the bootstrap domain cannot drift apart.
DOMAIN="${JOB%/*}"

# Fail-closed: until a probe answers, the honest statement is "the door has not
# been proven open and nothing has re-opened it" — which is what
# down-unrecovered means. A checker killed mid-run therefore says so.
VERDICT="down-unrecovered"
CHECKER_BROKEN=0
FINDINGS=()
M_CODE=""      # last HTTP code seen; empty ⇒ never measured ⇒ null in the ledger
M_KICKSTARTS=0
M_BOOTSTRAPS=0

say() { printf '%s\n' "$*"; }
note() { printf '  note: %s\n' "$*"; }
finding() {
  printf '  FINDING: %s\n' "$*"
  FINDINGS+=("$*")
}
broken() {
  printf '  CHECKER BROKEN: %s\n' "$*"
  FINDINGS+=("checker broken: $*")
  CHECKER_BROKEN=1
}

# Everything from here to the trap is reached only through the EXIT trap, which
# the linter's reachability analysis cannot see — hence the per-function
# disables below (same directive, same reason, as pico-backup-pull.sh).
# shellcheck disable=SC2317  # invoked via the EXIT trap
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'; }
# shellcheck disable=SC2317  # invoked via the EXIT trap
str_or_null() { if [ -z "$1" ]; then printf 'null'; else printf '"%s"' "$(json_escape "$1")"; fi; }

# The verdict of the newest ledger row, or empty if there is no ledger yet. This
# is the ONLY state this guard keeps between runs, and it exists for exactly one
# decision: whether an `ok` is a recovery worth recording.
# shellcheck disable=SC2317  # invoked via the EXIT trap
last_ledger_verdict() {
  [ -s "$LEDGER" ] || return 0
  tail -n 1 "$LEDGER" | sed -n -E 's/.*"verdict":"([^"]*)".*/\1/p'
}

# shellcheck disable=SC2317  # invoked via the EXIT trap
ledger_append() {
  local dir line f first=1
  dir=$(dirname "$LEDGER")
  mkdir -p "$dir" || {
    broken "cannot create the ledger directory $dir"
    return
  }
  line='{"ts":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"'
  line="$line"',"host":"'"$(json_escape "$HOST")"'"'
  line="$line"',"verdict":"'"$VERDICT"'"'
  line="$line"',"http_code":'"$(str_or_null "$M_CODE")"
  line="$line"',"kickstarts":'"$M_KICKSTARTS"
  line="$line"',"bootstraps":'"$M_BOOTSTRAPS"
  line="$line"',"findings":['
  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    [ "$first" -eq 1 ] || line="$line,"
    first=0
    line="$line"'"'"$(json_escape "$f")"'"'
  done
  line="$line"']}'
  printf '%s\n' "$line" >>"$LEDGER" || broken "cannot append to the ledger $LEDGER"
}

# shellcheck disable=SC2317  # invoked via the EXIT trap
finish() {
  rc=$?
  local prev
  prev=$(last_ledger_verdict)
  if [ "$VERDICT" != "ok" ] || { [ -n "$prev" ] && [ "$prev" != "ok" ]; }; then
    ledger_append
  fi
  # The diagnostic goes BEFORE the result line: the contract is that the LAST
  # line is always GATEWAY_HEALTH_RESULT=, and a consumer reading `tail -1` of
  # the merged stream must not get a sentence instead.
  if [ "$CHECKER_BROKEN" -ne 0 ]; then
    printf 'gateway-health: THIS CHECKER is broken (see CHECKER BROKEN above). The\n' >&2
    printf '                verdict below is what is KNOWN about the door, not a judgement.\n' >&2
  fi
  printf 'GATEWAY_HEALTH_RESULT=%s\n' "$VERDICT"
  [ "$CHECKER_BROKEN" -ne 0 ] && exit 1
  case "$VERDICT" in
  ok) exit 0 ;;
  restored | down-unrecovered | pico-unreachable) exit 10 ;;
  *) exit "$((rc == 0 ? 1 : rc))" ;; # the checker itself lost the plot
  esac
}
trap finish EXIT

# Exactly one HTTP code, or 000 when nothing answered. No `2>/dev/null`: curl is
# output-bearing here and a suppressed failure would read as "no data", i.e. as
# an outage (repo rule 3). `-s` already keeps the ordinary refused path quiet.
probe() {
  local code rc
  code=$("$CURL_BIN" -s -o /dev/null -m 8 -w '%{http_code}' "$PROBE_URL")
  rc=$?
  if [ "$rc" -ge 126 ] && [ "$rc" -le 127 ]; then
    broken "cannot execute the probe binary '$CURL_BIN' (rc=$rc) — a 'down' verdict here would be this checker's fault, not the gateway's"
    printf 'broken'
    return
  fi
  printf '%s' "${code:-000}"
}

# One remote command, output merged and surfaced as a note (never swallowed).
# ssh reserves 255 for its OWN failures, which is how "pico is unreachable" is
# told apart from "launchctl said no".
SSH_OUT=""
ssh_run() {
  local rc
  SSH_OUT=$("$SSH_BIN" -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT" "$HOST" "$1" 2>&1)
  rc=$?
  [ -n "$SSH_OUT" ] && note "$HOST: $SSH_OUT"
  return $rc
}
unreachable() {
  finding "cannot reach ${HOST} over ssh — the gateway cannot be restarted from the keep"
  VERDICT="pico-unreachable"
  exit 10
}

say "gateway-health — ${PROBE_URL} @ $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- 1. is the door open? ---------------------------------------------------
CODE=$(probe)
[ "$CODE" = "broken" ] && exit 1
M_CODE="$CODE"
if [ "$CODE" != "000" ]; then
  say "  gateway answered HTTP ${CODE} — up (any status means the relay is listening; 401 is the healthy signature)"
  VERDICT="ok"
  exit 0
fi
finding "no answer from ${PROBE_URL} — the relay is not listening (connect failure)"

# --- 2. kickstart ------------------------------------------------------------
ssh_run "launchctl kickstart -k $JOB"
[ $? -eq 255 ] && unreachable
M_KICKSTARTS=$((M_KICKSTARTS + 1))

# --- 2b. not merely wedged — not LOADED (the 2026-08-09 shape) --------------
case "$SSH_OUT" in
*"Could not find service"*)
  note "launchctl does not know ${JOB} — the job is not loaded at all, so bootstrap ${PLIST} into ${DOMAIN} first"
  ssh_run "launchctl bootstrap $DOMAIN $PLIST"
  [ $? -eq 255 ] && unreachable
  M_BOOTSTRAPS=$((M_BOOTSTRAPS + 1))
  ssh_run "launchctl kickstart -k $JOB"
  [ $? -eq 255 ] && unreachable
  M_KICKSTARTS=$((M_KICKSTARTS + 1))
  ;;
esac

# --- 3. did it come back? ----------------------------------------------------
try=1
while [ "$try" -le "$TRIES" ]; do
  sleep "$SETTLE"
  CODE=$(probe)
  [ "$CODE" = "broken" ] && exit 1
  M_CODE="$CODE"
  if [ "$CODE" != "000" ]; then
    finding "gateway was DOWN and has been RESTARTED: HTTP ${CODE} on try ${try}/${TRIES} after ${M_KICKSTARTS} kickstart(s), ${M_BOOTSTRAPS} bootstrap(s)"
    VERDICT="restored"
    exit 10
  fi
  note "still no answer after the restart (try ${try}/${TRIES})"
  try=$((try + 1))
done

finding "gateway STILL not answering after restarting ${JOB} on ${HOST} — this guard's authority is spent; a human is needed (flipping the fleet to direct routing is theirs to decide, never a timer's)"
VERDICT="down-unrecovered"
exit 10
