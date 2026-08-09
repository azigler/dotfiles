#!/usr/bin/env bash
# test-tap-headroom.sh — the per-POOL headroom contract (dotfiles-kecb).
#
#   bash agents/lib/test-tap-headroom.sh
#
# HERMETIC: no network, no ssh, no real account. `curl` and `ssh` are both
# STUBS on PATH (the library's documented seams), the conf is a fixture, and
# `~` resolves against a fixture home. Nothing here reads the live gateway or
# a live credential.
#
# WHAT IS NOT A STUB, and why it matters: the three OAuth usage documents in
# tap-headroom-fixtures/ are REAL RESPONSES, captured 2026-08-09 from
# api.anthropic.com/api/oauth/usage against three actual accounts. Every claim
# this library makes about the shape of that document — that the model-scoped
# Fable allotment lives in `limits[]` under kind=weekly_scoped with
# scope.model.display_name, that percentages are 0-100 there while the
# gateway's captured attributes are 0-1, that an expired token answers 401 with
# an `authentication_error` body — is asserted against those bytes rather than
# against a hand-written guess at them. A parser tested only on fixtures
# somebody invented is a parser tested against its own author's assumptions.
#
# THE REGRESSIONS THIS GUARDS, each of which passes a source read:
#   H1  a failed read scored as headroom. The endpoint answers 401 for an
#       expired token (measured on the linearb tap the day this was written);
#       "no data" read as "0% used" would declare an unusable account wide open
#       and roll the fleet's billing into it.  (G6, G7)
#   H2  the empty string read as zero. The gateway writes "" — not NULL — when
#       Anthropic sends no ratelimit header (measured on the secondary tap's
#       one logged request), so `IS NOT NULL` passes it and awk compares it as
#       0.  (G8, G9)
#   H3  the started_at comparison unwrapped. `started_at > datetime('now',…)`
#       silently matches EVERY row with today's date — 2903 rows vs 18,
#       measured — so a stale utilization reads as current.  (G10)
#   H4  the model-scoped dimension quietly ignored. The gateway arm has no
#       model dimension AT ALL, so a fable-scoped consult answered from it must
#       be `unavailable`, never `ok`.  (G12)
#   H5  the tilde in a config_dir left unexpanded — an UNQUOTED `~/` inside
#       ${d#~/} is tilde-expanded before it is used as a pattern, matches
#       nothing, and yields $HOME/~/.claude-… . Measured on the first live
#       run.  (G4)
#   H6  the preference order or the per-seat override lost, so a rollover
#       lands on the wrong subscription.  (G13, G14, G15)

DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
LIB="$DIR/tap-headroom.sh"
FIX="$DIR/tap-headroom-fixtures"
FAILS=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n       expected: [%s]\n       got:      [%s]\n' "$1" "$2" "$3"; FAILS=$((FAILS+1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }
contains() { # <label> <needle> <haystack>
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "*$2*" "$3" ;; esac
}
lacks() { # <label> <needle> <haystack>
  case "$3" in *"$2"*) fail "$1" "NOT *$2*" "$3" ;; *) pass "$1" ;; esac
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
BIN="$TMPROOT/bin"; mkdir -p "$BIN"
FHOME="$TMPROOT/home"
mkdir -p "$FHOME/.claude" "$FHOME/.claude-secondary" "$FHOME/.claude-work"
CACHE="$TMPROOT/cache"

# --- fixture credentials ----------------------------------------------------
# accessToken is a ROUTING MARKER for the stub curl, not a secret. `primary`
# and `secondary` are far-future; `linearb` is deliberately EXPIRED, which is
# the state the real one was in on 2026-08-09 and the state G6 drives.
cred() { printf '{"claudeAiOauth":{"accessToken":"FIXTURE-%s","expiresAt":%s}}\n' "$1" "$2"; }
cred PRIMARY   99999999999999 > "$FHOME/.claude/.credentials.json"
cred SECONDARY 99999999999999 > "$FHOME/.claude-secondary/.credentials.json"
cred LINEARB   1              > "$FHOME/.claude-work/.credentials.json"

# --- the stub curl ----------------------------------------------------------
# Routes on the fixture token in its own argv, records every call, and answers
# with a REAL captured document (or a real captured 401). $STUB_<POOL> unset
# means "this pool answers nothing" — the unmeasurable case.
cat > "$BIN/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMPROOT/curl.calls"
who=UNKNOWN
for a in "\$@"; do
  case "\$a" in
    *FIXTURE-PRIMARY*)   who=PRIMARY ;;
    *FIXTURE-SECONDARY*) who=SECONDARY ;;
    *FIXTURE-LINEARB*)   who=LINEARB ;;
  esac
done
eval "shape=\\\${STUB_\$who:-}"
case "\$shape" in
  "")       printf 'stub curl: no shape for \$who\n' >&2; exit 7 ;;
  fixture-primary)   cat "$FIX/usage-primary-2026-08-09.json";   printf '\n200' ;;
  fixture-secondary) cat "$FIX/usage-secondary-2026-08-09.json"; printf '\n200' ;;
  fixture-401)       cat "$FIX/usage-401-expired-token-2026-08-09.json"; printf '\n401' ;;
  notjson)  printf 'this is not json\n200' ;;
  *)
    f5=\${shape%%,*}; rest=\${shape#*,}; f7=\${rest%%,*}; ff=\${rest#*,}
    printf '{"limits":[{"kind":"session","percent":%s},{"kind":"weekly_all","percent":%s},{"kind":"weekly_scoped","percent":%s,"scope":{"model":{"display_name":"Fable"}}}]}\n200' "\$f5" "\$f7" "\$ff" ;;
esac
exit 0
EOF
chmod +x "$BIN/curl"

# --- the stub ssh -----------------------------------------------------------
# Records the FULL remote command (G10 reads the SQL out of it) and answers
# with a raw sqlite3 pipe-separated row. Per-pool via $STUB_SQL_<POOL>, keyed
# on the epoch-3 group value the query carries, falling back to $STUB_SQL — the
# per-pool form is what lets one case make ONE pool full while the others stay
# open, which is the only way to tell `ceiling` from `degraded`.
cat > "$BIN/ssh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMPROOT/ssh.calls"
who=""
case "\$*" in
  *"'primary'"*)   who=PRIMARY ;;
  *"'secondary'"*) who=SECONDARY ;;
  *"'linearb'"*)   who=LINEARB ;;
esac
row=""
[ -n "\$who" ] && eval "row=\\\${STUB_SQL_\$who:-}"
printf '%s' "\${row:-\${STUB_SQL:-}}"
exit 0
EOF
chmod +x "$BIN/ssh"

CONF="$TMPROOT/taps.conf"
cat > "$CONF" <<'EOF'
order=primary,secondary,linearb
pool.primary.taps=primary,tick
pool.primary.config_dir=~/.claude
pool.primary.groups=primary,personal
pool.secondary.taps=secondary
pool.secondary.config_dir=~/.claude-secondary
pool.secondary.groups=secondary
pool.linearb.taps=linearb
pool.linearb.config_dir=~/.claude-work
pool.linearb.groups=linearb,work
seat_home.desk=linearb
ceiling=1.0
fable_scope=Fable
fable_models=fable
fable_ceiling=1.0
cache_ttl_seconds=120
timeout_seconds=4
EOF

export PATH="$BIN:$PATH"
export TAP_HEADROOM_CONF="$CONF" TAP_HEADROOM_HOME="$FHOME" \
       TAP_HEADROOM_CACHE_DIR="$CACHE" TAP_HEADROOM_NO_CACHE=1

echo "test-tap-headroom"

# === the conf grammar =======================================================

# G1 — the committed conf's own grammar. The shipped file is DATA on the launch
# path of every claude on the box; a key that silently does not parse leaves
# the whole mechanism running on its defaults.
REALCONF="$DIR/../scheduler/taps.conf"
if [ -f "$REALCONF" ]; then
  out=$(TAP_HEADROOM_CONF="$REALCONF" bash "$LIB" --lint 2>&1); rc=$?
  check 'G1 the COMMITTED agents/scheduler/taps.conf parses clean' '0|' "$rc|$out"
  out=$(TAP_HEADROOM_CONF="$REALCONF" bash "$LIB" --order 2>&1)
  check 'G1b the committed conf carries the RULED order' 'primary secondary linearb' "$out"
else
  fail 'G1 the committed taps.conf exists' "$REALCONF" '<missing>'
fi

# G2 — the grammar REFUSES. A conf that can execute is a conf that can be an
# incident: command substitution, backticks and expansions are not values.
BADCONF="$TMPROOT/bad.conf"
printf '%s\n' 'order=primary' 'evil=$(touch /tmp/pwned)' 'ceiling=`id`' 'noequals' > "$BADCONF"
out=$(TAP_HEADROOM_CONF="$BADCONF" bash "$LIB" --lint 2>&1); rc=$?
check 'G2 a conf with an executable-looking value is REFUSED' '1' "$rc"
contains 'G2b and the refusal names the line' 'bad value' "$out"
contains 'G2c and the non-key=value line too' 'not key=value' "$out"

# G3 — a refused VALUE is not a silently-accepted one: the key reads as absent.
out=$(TAP_HEADROOM_CONF="$BADCONF" bash "$LIB" --order 2>&1)
check 'G3 a refused value yields no value at all' 'primary' "$out"

# === pool resolution ========================================================

src_call() { bash -c ". \"\$1\"; $2" _ "$LIB"; }

# G4 — H5. The tilde MUST resolve against $TAP_HEADROOM_HOME, with no `~`
# surviving anywhere in the result.
out=$(src_call "" 'th_pool_config_dir primary')
check 'G4 [H5] ~ in a config_dir resolves against the fixture home' \
  "$FHOME/.claude" "$out"
lacks 'G4b [H5] and no literal ~ survives' '~' "$out"

# G5 — tick draws on PRIMARY's ceiling. It is a jailed grant of the same
# account, so a primary->tick "failover" would move nothing; the conf says so
# and this is where that stays true.
check 'G5 tap tick -> pool primary (same account, one ceiling)' \
  'primary' "$(src_call "" 'th_pool_of_tap tick')"
check 'G5b tap linearb -> pool linearb' \
  'linearb' "$(src_call "" 'th_pool_of_tap linearb')"
check 'G5c an unknown tap resolves to nothing' \
  '' "$(src_call "" 'th_pool_of_tap nonsense || true')"

# === the OAuth arm, against REAL captured documents =========================

# G6 — H1. An EXPIRED access token is refused BEFORE the request. Two
# assertions, and the second is the one that proves it: the stub curl must not
# have been called AT ALL for that pool.
: > "$TMPROOT/curl.calls"
out=$(STUB_LINEARB=fixture-401 bash "$LIB" --pool linearb 2>&1); rc=$?
contains 'G6 [H1] an expired credential is UNAVAILABLE' 'state=unavailable' "$out"
contains 'G6b [H1] and the refusal names expiry, not a network error' 'EXPIRED' "$out"
check 'G6c [H1] and no request was made with the dead token' '0' \
  "$(grep -c FIXTURE-LINEARB "$TMPROOT/curl.calls")"

# G7 — H1 again, this time a live-looking token whose request 401s (the real
# captured body). Still unavailable; still not a zero.
out=$(STUB_PRIMARY=fixture-401 bash "$LIB" --pool primary 2>&1); rc=$?
contains 'G7 [H1] a 401 response is UNAVAILABLE' 'state=unavailable' "$out"
contains 'G7b [H1] and says which http code it got' 'http 401' "$out"
lacks 'G7c [H1] and never reports a utilization for it' 'u5h=0.0000' "$out"
check 'G7d [H1] exit code is 1 — this reader could not measure' '1' "$rc"

# G8 — THE REAL PRIMARY DOCUMENT. Zig's live numbers, 2026-08-09: unified 5h
# 72%, unified weekly 75%, and the FABLE-scoped weekly 81% — the third of which
# exists nowhere in the gateway's captured attributes and is the whole reason
# this endpoint had to be found. Percentages there, fractions here.
out=$(STUB_PRIMARY=fixture-primary bash "$LIB" --pool primary --fable 2>&1)
contains 'G8 real primary fixture: 5h 72% -> 0.7200' 'u5h=0.7200' "$out"
contains 'G8b real primary fixture: weekly 75% -> 0.7500' 'u7d=0.7500' "$out"
contains 'G8c real primary fixture: the FABLE weekly_scoped 81% -> 0.8100' 'fable=0.8100' "$out"
contains 'G8d and none of the three is at the ceiling' 'state=ok' "$out"

# G8e — the real SECONDARY document: a fresh account, every number 0. The
# distinction G8e pins is the one H1 is about — a real, measured 0.0000 looks
# nothing like the `-` an unmeasured pool reports.
out=$(STUB_SECONDARY=fixture-secondary bash "$LIB" --pool secondary --fable 2>&1)
contains 'G8e real secondary fixture: a measured zero is a NUMBER' 'u5h=0.0000' "$out"
contains 'G8f real secondary fixture: state ok' 'state=ok' "$out"

# G8g — an unmeasured pool reports `-`, never 0.0000. Same line format, and
# telling them apart is the entire point of the four-valued vocabulary.
out=$(bash "$LIB" --pool secondary 2>&1)
contains 'G8g an UNMEASURED window is `-`, not 0.0000' 'u5h=-' "$out"
contains 'G8h and the verdict says so' 'state=unavailable' "$out"

# G8i — a response that is not JSON at all is unavailable, not a parse that
# happens to yield nothing.
out=$(STUB_PRIMARY=notjson bash "$LIB" --pool primary 2>&1)
contains 'G8i a non-JSON 200 is UNAVAILABLE' 'state=unavailable' "$out"

# === the gateway arm ========================================================

# G9 — H2. The gateway writes the EMPTY STRING (not NULL) when Anthropic sends
# no ratelimit header — measured on the secondary tap's one logged request. A
# reader that lets "" through compares it as 0 and declares a full account
# empty. The stub returns no row at all here, which is what the `<> ''` filter
# produces for a pool whose only rows are empty.
out=$(TAP_HEADROOM_SOURCE=gateway STUB_SQL='' bash "$LIB" --pool secondary 2>&1)
contains 'G9 [H2] no usable gateway row -> UNAVAILABLE' 'state=unavailable' "$out"
lacks 'G9b [H2] and never a zero' 'u5h=0' "$out"

# G9c — an empty-string PAIR that does reach the comparison must still not read
# as a ceiling or as ok. This is the belt for the `<> ''` braces: the number
# comparison itself refuses an empty operand.
out=$(TAP_HEADROOM_SOURCE=gateway STUB_SQL='|' bash "$LIB" --pool secondary 2>&1)
contains 'G9c [H2] an empty-string row is UNAVAILABLE, not ok and not ceiling' \
  'state=unavailable' "$out"

# G10 — H3. The SQL is read out of the stub's recorded argv. Three properties,
# all of which have already cost this fleet something:
: > "$TMPROOT/ssh.calls"
TAP_HEADROOM_SOURCE=gateway STUB_SQL='0.5|0.6' bash "$LIB" --pool primary >/dev/null 2>&1
SQL=$(cat "$TMPROOT/ssh.calls")
contains 'G10 [H3] started_at is wrapped in datetime()' "datetime(started_at)" "$SQL"
contains 'G10b [H2] the empty string is filtered, not just NULL' "<> ''" "$SQL"
contains 'G10c both epochs of the group value are queried' "'primary','personal'" "$SQL"
contains 'G10d the table is request_logs' 'request_logs' "$SQL"

# G11 — a real gateway reading, and the ceiling it implies.
out=$(TAP_HEADROOM_SOURCE=gateway STUB_SQL='0.5|0.6' bash "$LIB" --pool primary 2>&1)
contains 'G11 a gateway reading is reported with src=gateway' 'src=gateway' "$out"
contains 'G11b and its numbers' 'u5h=0.5 u7d=0.6' "$out"
out=$(TAP_HEADROOM_SOURCE=gateway STUB_SQL='0.4|1.0' bash "$LIB" --pool primary 2>&1); rc=$?
contains 'G11c the 7d window ALONE is enough for a ceiling (OQ-5: both windows)' \
  'state=ceiling' "$out"
check 'G11d and a ceiling exits 10, a real finding' '10' "$rc"

# G12 — H4. The gateway arm has NO model dimension. A fable-scoped consult
# answered from it must be `unavailable`, never `ok`: silently passing here is
# exactly "the fable dimension ignored", and it is invisible — the unified
# windows really do have headroom.
out=$(TAP_HEADROOM_SOURCE=gateway STUB_SQL='0.4|0.4' bash "$LIB" --pool primary --fable 2>&1)
contains 'G12 [H4] --fable on a gateway-only reading is UNAVAILABLE' 'state=unavailable' "$out"
contains 'G12b [H4] and says why' 'no model-scoped reading' "$out"
# The control: the SAME reading without --fable is fine. Without this, G12
# would also pass against a reader that called every gateway row unavailable.
out=$(TAP_HEADROOM_SOURCE=gateway STUB_SQL='0.4|0.4' bash "$LIB" --pool primary 2>&1)
contains 'G12c [H4] the same reading WITHOUT --fable is ok' 'state=ok' "$out"

# G12d — the fable allotment at its ceiling with both unified windows open.
out=$(STUB_PRIMARY=40,40,100 bash "$LIB" --pool primary --fable 2>&1); rc=$?
contains 'G12d [H4] fable allotment exhausted -> ceiling' 'state=ceiling' "$out"
contains 'G12e [H4] and the reason names the model-scoped window' 'model-scoped' "$out"
out=$(STUB_PRIMARY=40,40,100 bash "$LIB" --pool primary 2>&1)
contains 'G12f [H4] the same pool WITHOUT --fable has headroom' 'state=ok' "$out"

# === the order, the override, and the pick ==================================

# G13 — H6. The candidate order: home first, then the global order.
check 'G13 [H6] candidates from primary' 'primary secondary linearb' \
  "$(src_call "" 'th_candidates primary ""')"
check 'G13b [H6] candidates from linearb keep the global order behind home' \
  'linearb primary secondary' "$(src_call "" 'th_candidates linearb ""')"

# G14 — H6. The per-seat override orders what comes BEHIND home. Seat `desk`
# is seat_home.desk=linearb, so a desk launch that is home on primary prefers
# linearb over secondary — LinearB's own overflow does not land on Zig's
# personal subscription while LinearB's sits idle.
check 'G14 [H6] the seat override reorders the candidates behind home' \
  'primary linearb secondary' "$(src_call "" 'th_candidates primary desk')"
check 'G14b [H6] a seat with no override takes the global order' \
  'primary secondary linearb' "$(src_call "" 'th_candidates primary someoneelse')"

# G15 — H6, end to end. primary full, secondary and linearb both open: the
# global order picks secondary, the desk override picks linearb. Two calls
# differing ONLY in the seat.
out=$(STUB_PRIMARY=100,0,0 STUB_SECONDARY=0,0,0 STUB_LINEARB=0,0,0 \
      bash "$LIB" --pick primary '' 2>&1); rc=$?
contains 'G15 [H6] global order picks secondary' 'secondary' "$out"
check 'G15b a rollover exits 10' '10' "$rc"
out=$(STUB_PRIMARY=100,0,0 STUB_SECONDARY=0,0,0 STUB_LINEARB=0,0,0 \
      bash "$LIB" --pick primary desk 2>&1)
contains 'G15c [H6] the desk override picks linearb instead' 'linearb' "$out"

# G16 — FAIL TOWARDS HOME. Home is full and nothing else can be measured: the
# answer is home, and the exit code says "could not". A stalled launch on the
# right account is recoverable; a silently cross-billed one is not.
out=$(STUB_PRIMARY=100,0,0 bash "$LIB" --pick primary '' 2>&1); rc=$?
contains 'G16 home full + no measurable candidate -> home' 'primary' "$out"
check 'G16b and it exits 1 (could not), never 10 (rolled)' '1' "$rc"

# G16c — home cannot be measured at all: still home, and nothing is rolled on
# ignorance.
out=$(STUB_SECONDARY=0,0,0 bash "$LIB" --pick primary '' 2>&1); rc=$?
contains 'G16c home UNMEASURABLE -> home' 'primary' "$out"
check 'G16d and exits 1' '1' "$rc"

# G16e — home has headroom: home, exit 0, and the candidates are never even
# consulted (a consult that probes every pool on every launch is a consult
# nobody will leave switched on).
: > "$TMPROOT/curl.calls"
out=$(STUB_PRIMARY=10,10,10 STUB_SECONDARY=0,0,0 bash "$LIB" --pick primary '' 2>&1); rc=$?
check 'G16e home has headroom -> home, exit 0' '0' "$rc"
check 'G16f and NO candidate pool was probed' '0' \
  "$(grep -c FIXTURE-SECONDARY "$TMPROOT/curl.calls")"

# === the outcome contract ===================================================

# G17 — the house shape: the LAST line is always TAP_HEADROOM_RESULT=<v>, and
# the exit code separates "a real finding" from "this checker is broken".
# The gateway arm drives these three: the fixture linearb credential is
# EXPIRED on purpose (G6), so the oauth arm can never report all three pools
# measurable — which is the honest state of the estate today and exactly why
# `degraded` had to exist as a separate verdict.
out=$(TAP_HEADROOM_SOURCE=gateway STUB_SQL='0.1|0.1' bash "$LIB" 2>&1); rc=$?
check 'G17 all pools ok -> last line ok, exit 0' 'TAP_HEADROOM_RESULT=ok|0' \
  "$(printf '%s' "$out" | tail -1)|$rc"
out=$(TAP_HEADROOM_SOURCE=gateway STUB_SQL='0.1|0.1' STUB_SQL_PRIMARY='1.0|0.1' \
      bash "$LIB" 2>&1); rc=$?
check 'G17b one pool at its ceiling -> ceiling, exit 10' 'TAP_HEADROOM_RESULT=ceiling|10' \
  "$(printf '%s' "$out" | tail -1)|$rc"
out=$(STUB_PRIMARY=10,10,10 bash "$LIB" 2>&1); rc=$?
check 'G17c some measured, some not -> degraded, exit 10' 'TAP_HEADROOM_RESULT=degraded|10' \
  "$(printf '%s' "$out" | tail -1)|$rc"
out=$(bash "$LIB" 2>&1); rc=$?
check 'G17d nothing measurable at all -> unavailable, exit 1 (the CHECKER)' \
  'TAP_HEADROOM_RESULT=unavailable|1' "$(printf '%s' "$out" | tail -1)|$rc"

# G17e — every unavailable is LOUD. The verdict line is stdout; the naming of
# the failure is stderr, so an operator watching a pane sees it without
# grepping.
err=$(bash "$LIB" --pool secondary 2>&1 >/dev/null)
contains 'G17e an unavailable pool names itself on stderr' 'UNAVAILABLE' "$err"
contains 'G17f and says it will not decide on it' 'No rollover decision' "$err"

# === the cache ==============================================================

# G18 — a fresh cache entry is reused and costs no request; a bypassed cache
# always re-reads. The consult runs on every claude launch, so this is what
# keeps it off the network.
rm -rf "$CACHE"; : > "$TMPROOT/curl.calls"
STUB_PRIMARY=10,10,10 TAP_HEADROOM_NO_CACHE='' bash "$LIB" --pool primary >/dev/null 2>&1
STUB_PRIMARY=10,10,10 TAP_HEADROOM_NO_CACHE='' bash "$LIB" --pool primary >/dev/null 2>&1
check 'G18 two consults inside the TTL make ONE request' '1' \
  "$(grep -c FIXTURE-PRIMARY "$TMPROOT/curl.calls")"
: > "$TMPROOT/curl.calls"
STUB_PRIMARY=10,10,10 bash "$LIB" --pool primary >/dev/null 2>&1
check 'G18b TAP_HEADROOM_NO_CACHE=1 always re-reads' '1' \
  "$(grep -c FIXTURE-PRIMARY "$TMPROOT/curl.calls")"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; fi
[ "$FAILS" -eq 0 ]
