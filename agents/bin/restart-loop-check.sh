#!/usr/bin/env bash
# restart-loop-check — find supervised jobs stuck in a PERMANENT restart loop.
#
# WHY (dotfiles-wtrr, 2026-07-26). Three jobs on pico were looping, each around
# a quarter of a million attempts, none of them alarming:
#
#   com.zig.vs14-web         237,737  exit 1   an orphan squatting its port
#   homebrew.mxcl.tailscale  242,422  exit 78  duplicate of the system daemon
#   com.zig.tmux             242,224  exit 1   new-session on an existing session
#
# Two looked healthy from every casual angle — label listed, process present,
# port answering. The tell was free and unread: a healthy long-lived supervised
# service has a restart count of 1 (tailscaled on pico: runs=1 since May 28).
#
# ACTIVE vs SCAR — the distinction that keeps this check trustworthy. A high
# count is not proof of a live loop: vs14-web sits at 237,744 and is now
# healthy, because launchd does not reset the counter until the job is
# re-bootstrapped. Flagging that would train the reader to ignore this script,
# which is the exact failure it exists to prevent. So we sample TWICE and flag
# only counts that climbed. High-but-static is reported as history, not a fault.
#
# Emits RESTART_LOOP_RESULT= on every terminal path. 0 clean / 10 found / 1 blocked.
set -uo pipefail

THRESHOLD="${RESTART_LOOP_THRESHOLD:-100}"
GAP="${RESTART_LOOP_GAP:-15}"
FOUND=0; SCARS=0; CHECKED=0

echo "restart-loop-check — a loop is a count that is still CLIMBING (${GAP}s window)"
echo

echo "== zig-computer (systemd user units, NRestarts) =="
for unit in $(systemctl --user list-units --type=service --all --no-legend | awk '{print $1}'); do
    n=$(systemctl --user show "$unit" -p NRestarts --value 2>/dev/null)
    case "$n" in ''|*[!0-9]*) continue ;; esac
    CHECKED=$((CHECKED+1))
    if [ "$n" -gt "$THRESHOLD" ]; then
        printf "  LOOP  %-38s NRestarts=%s\n" "$unit" "$n"; FOUND=$((FOUND+1))
    fi
done
echo "  checked $CHECKED units"

echo
echo "== pico (launchd, runs) =="
read -r -d '' SAMPLE <<'REMOTE' || true
export PATH=/opt/homebrew/bin:$PATH
for L in $(launchctl list | awk 'NR>1 && $3 !~ /^com\.apple/ {print $3}'); do
    R=$(launchctl print gui/$(id -u)/"$L" 2>/dev/null | grep -oE 'runs = [0-9]+' | head -1 | grep -oE '[0-9]+')
    [ -n "$R" ] && echo "$L $R"
done
REMOTE

if ! ssh -o ConnectTimeout=8 -o BatchMode=yes pico true 2>/dev/null; then
    echo "  pico unreachable"
    echo; echo "RESTART_LOOP_RESULT=blocked (pico unreachable)"; exit 1
fi
A=$(ssh pico "$SAMPLE" 2>/dev/null)
sleep "$GAP"
B=$(ssh pico "$SAMPLE" 2>/dev/null)
if [ -z "$A" ] || [ -z "$B" ]; then
    echo "  sampling produced no data — refusing to report clean"
    echo; echo "RESTART_LOOP_RESULT=blocked (empty sample)"; exit 1
fi

while read -r label now; do
    [ -n "${label:-}" ] && [ -n "${now:-}" ] || continue
    prev_line=$(grep -m1 -- "^$label " <<<"$A") || prev_line=""
    [ -n "$prev_line" ] || continue
    prev="${prev_line##* }"
    CHECKED=$((CHECKED+1))
    if [ "$now" -gt "$prev" ]; then
        printf "  LOOP  %-38s runs %s -> %s in %ss  ACTIVELY LOOPING\n" "$label" "$prev" "$now" "$GAP"
        FOUND=$((FOUND+1))
    elif [ "$now" -gt "$THRESHOLD" ]; then
        printf "  scar  %-38s runs=%s static — healed, counter not reset\n" "$label" "$now"
        SCARS=$((SCARS+1))
    fi
done <<<"$B"

echo
[ "$SCARS" -gt 0 ] && echo "$SCARS healed scar(s) — history, not a fault."
if [ "$FOUND" -gt 0 ]; then
    echo "$FOUND job(s) ACTIVELY looping."
    echo "RESTART_LOOP_RESULT=found ($FOUND of $CHECKED)"; exit 10
fi
echo "No active restart loops. $CHECKED jobs checked."
echo "RESTART_LOOP_RESULT=clean (0 of $CHECKED)"; exit 0
