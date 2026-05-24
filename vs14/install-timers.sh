#!/bin/bash
# Install 7 vs14/ss14 timer LaunchAgents on pico.
#
# Each timer runs a build/maintenance script from /opt/vacation-station/
# (symlinked → /Users/pico/vacation-station-14) at a fixed schedule.
# Times are PDT (pico's local TZ) — derived from the UTC schedules the
# systemd timers used on zig-computer. DST will shift the actual UTC
# time of execution by an hour twice a year; cadence stays daily/weekly
# either way.
#
# Run from pico, after path symlinks (/opt/vacation-station, /var/www)
# are set up. Idempotent — overwrites existing plists.

set -euo pipefail

USER_HOME="${HOME}"
LAUNCH_AGENTS="${USER_HOME}/Library/LaunchAgents"

# Newest nvm node bin, for build scripts that need npm but spawn
# under launchd's minimal PATH.
NODE_BIN=""
if [ -d "${USER_HOME}/.nvm/versions/node" ]; then
  NODE_BIN=$(ls -1dt "${USER_HOME}"/.nvm/versions/node/*/bin 2>/dev/null | head -1)
fi
PATH_VAL="/opt/homebrew/bin:${USER_HOME}/.bun/bin:${NODE_BIN:+${NODE_BIN}:}/usr/local/bin:/usr/bin:/bin"

# Backup destination (pico-local; avoids /var/backups perm dance)
mkdir -p "${USER_HOME}/backups/vacation-station"
mkdir -p "${USER_HOME}/var/lib"

# format: label|script|hour|minute|weekday|env_overrides
TIMERS=(
  "com.zig.ss14-backup|/opt/vacation-station/ops/postgres/backup.sh|20|15||BACKUP_DIR=${USER_HOME}/backups/vacation-station"
  "com.zig.vs14-postgres-retention|/opt/vacation-station/ops/postgres/retention.sh|20|30||"
  "com.zig.vs14-cookbook-build|/opt/vacation-station/ops/cookbook/build.sh|22|0||REPO_ROOT=/opt/vacation-station;COOKBOOK_SOURCE_DIR=${USER_HOME}/var/lib/vs14-cookbook-source;WEB_ROOT=/var/www/vs14-recipes"
  "com.zig.vs14-guidebook-build|/opt/vacation-station/ops/guidebook/build.sh|22|15||REPO_ROOT=/opt/vacation-station;WEB_ROOT=/var/www/vs14-guidebook"
  "com.zig.vs14-nurseshark-build|/opt/vacation-station/ops/nurseshark/build.sh|22|30||REPO_ROOT=/opt/vacation-station"
  "com.zig.vs14-writer-build|/opt/vacation-station/ops/document-simu/build.sh|21|45|6|REPO_ROOT=/opt/vacation-station;WEB_ROOT=/var/www/vs14-writer"
  "com.zig.vs14-map-render|/opt/vacation-station/ops/map-render/build.sh|21|30|6|REPO_ROOT=/opt/vacation-station;MAPSERVER_URL=http://localhost:5218"
  # NOTE: ss14-replay-rotate stays on zig-computer (with ss14-watchdog) —
  # Phase 4 SS14-on-pico migration rolled back per canonical SS14 reverse-
  # proxy architecture (UDP must be direct, not stream-proxied). See bead
  # dotfiles-hdo / dotfiles-ier for the full investigation.
)

emit_plist() {
  local label="$1" script="$2" hour="$3" minute="$4" weekday="$5" env_overrides="$6"
  local plist="${LAUNCH_AGENTS}/${label}.plist"

  # Env vars block
  local env_xml="    <key>PATH</key><string>${PATH_VAL}</string>"
  if [ -n "${env_overrides}" ]; then
    IFS=';' read -ra OVERRIDES <<< "${env_overrides}"
    for kv in "${OVERRIDES[@]}"; do
      local k="${kv%%=*}"
      local v="${kv#*=}"
      env_xml="${env_xml}
    <key>${k}</key><string>${v}</string>"
    done
  fi

  # StartCalendarInterval block (with optional Weekday)
  local weekday_xml=""
  if [ -n "${weekday}" ]; then
    weekday_xml="    <key>Weekday</key><integer>${weekday}</integer>"
  fi

  cat > "${plist}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${script}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
${env_xml}
    </dict>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key><integer>${hour}</integer>
        <key>Minute</key><integer>${minute}</integer>
${weekday_xml}
    </dict>
    <key>StandardOutPath</key><string>/tmp/${label}.log</string>
    <key>StandardErrorPath</key><string>/tmp/${label}.log</string>
</dict>
</plist>
PLIST

  plutil -lint "${plist}" > /dev/null
  launchctl unload "${plist}" 2>/dev/null || true
  launchctl load -w "${plist}"
  echo "loaded ${label}"
}

for entry in "${TIMERS[@]}"; do
  IFS='|' read -r label script hour minute weekday env_overrides <<< "${entry}"
  emit_plist "${label}" "${script}" "${hour}" "${minute}" "${weekday}" "${env_overrides}"
done

echo "==="
echo "All vs14/ss14 timer LaunchAgents installed and loaded."
echo "Verify: launchctl list | grep com.zig"
