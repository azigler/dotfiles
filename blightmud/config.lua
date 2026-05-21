-- Blightmud master config.
-- Provides:
--   * .env.local credential loader + creds(game)
--   * Per-server dispatcher (on_connect loads <game>.lua)
--   * game_groups(name) — per-game alias + trigger groups
--   * game_timer(name, secs, cb) — per-game timer that auto-replaces
--     prior registrations (idempotent across /load cycles)
--   * Parallel timestamped log file alongside Blightmud's default log.
--     Default log stays raw; a sibling .ts.log gets every server line
--     prefixed with [YYYY-MM-DD HH:MM:SS]. Strip with:
--       sed -E 's/^\[[0-9-]+ [0-9:]+\] //' < <date>.ts.log

-- ─── secret management ─────────────────────────────────────────────

local function load_env(path)
    local env = {}
    local f = io.open(path, "r")
    if not f then
        blight.output("[env] no " .. path .. " — login aliases will be inert until you create it")
        return env
    end
    for line in f:lines() do
        if not line:match("^%s*#") and line:match("%S") then
            local k, v = line:match("^%s*([A-Z_][A-Z0-9_]*)%s*=%s*(.-)%s*$")
            if k then
                v = v:gsub('^"(.-)"$', "%1"):gsub("^'(.-)'$", "%1")
                env[k] = v
            end
        end
    end
    f:close()
    return env
end

local env = load_env(blight.config_dir() .. "/.env.local")

function creds(game)
    local g = game:upper()
    local user, pass = env[g .. "_USER"], env[g .. "_PASS"]
    if user == "" then user = nil end
    if pass == "" then pass = nil end
    return user, pass
end

-- ─── per-game alias/trigger groups ─────────────────────────────────

_G.bm_groups = _G.bm_groups or {}

function game_groups(name)
    local g = _G.bm_groups[name]
    if g then
        g.alias:clear()
        g.trigger:clear()
        g.alias:set_enabled(true)
        g.trigger:set_enabled(true)
    else
        g = {
            alias = alias.add_group(),
            trigger = trigger.add_group(),
        }
        _G.bm_groups[name] = g
    end
    return g.alias, g.trigger
end

local function disable_all_game_groups()
    for _, g in pairs(_G.bm_groups) do
        g.alias:set_enabled(false)
        g.trigger:set_enabled(false)
    end
end

-- ─── mapper library ────────────────────────────────────────────────
-- Load the room-graph mapper module once at startup so per-game .lua
-- can call mapper_new("cod") etc. without needing its own script.load.

pcall(script.load, blight.config_dir() .. "/mapper.lua")

-- ─── per-game timers ───────────────────────────────────────────────

_G.bm_timer_ids = _G.bm_timer_ids or {}

function game_timer(name, secs, callback)
    if _G.bm_timer_ids[name] then
        timer.remove(_G.bm_timer_ids[name])
    end
    _G.bm_timer_ids[name] = timer.add(secs, 0, callback)
end

-- ─── current game tracking ─────────────────────────────────────────

_G.bm_current_game = _G.bm_current_game or nil

-- ─── parallel timestamped log ──────────────────────────────────────
-- Blightmud writes its default log BEFORE Lua scripts fire (see
-- src/event.rs handle_output_events: log first, then on_mud_output).
-- That means line:replace can't touch the log. We write a parallel
-- log file alongside Blightmud's default — one per connection.
-- Format: [YYYY-MM-DD HH:MM:SS] <server line>

_G.bm_ts_handle = _G.bm_ts_handle or nil

local function bm_ts_close()
    if _G.bm_ts_handle then
        pcall(function() _G.bm_ts_handle:close() end)
        _G.bm_ts_handle = nil
    end
end

local function bm_ts_open(host)
    bm_ts_close()
    local home = os.getenv("HOME") or "/tmp"
    local logdir = home .. "/.local/share/blightmud/logs/" .. host
    os.execute("mkdir -p '" .. logdir .. "'")
    local path = logdir .. "/" .. os.date("%Y%m%d.%H:%M:%S") .. ".ts.log"
    _G.bm_ts_handle = io.open(path, "a")
end

-- Single output listener for the parallel log. Guarded to survive
-- /load config.lua without piling up listeners.
if not _G.bm_ts_listener_installed then
    _G.bm_ts_listener_installed = true
    mud.add_output_listener(function(line)
        -- Respect skip_log flag — gagged-from-log lines (e.g. keep-alive
        -- responses) don't pollute the .ts.log either.
        if _G.bm_ts_handle and not line:skip_log() then
            local content = line:line()
            if content and content ~= "" then
                _G.bm_ts_handle:write("[" .. os.date("%Y-%m-%d %H:%M:%S") .. "] " .. content .. "\n")
                _G.bm_ts_handle:flush()
            end
        end
        return line
    end)
end

-- ─── per-server dispatcher ─────────────────────────────────────────

local servers = {
    ["cleftofdimensions.net"]    = "cod.lua",
    ["chatmud.com"]              = "chatmud.lua",
    ["carrionfields.net"]        = "cf.lua",
    ["ifmud.port4000.com"]       = "ifmud.lua",
    ["discworld.starturtle.net"] = "dw.lua",
    ["cthulhumud.com"]           = "cthulhumud.lua",
}

-- ─── auto-reconnect ────────────────────────────────────────────────
-- DESIGN (bead blightmud-8ud / 92z):
--
-- Two failure modes this handler must avoid:
--
--   1. **Mid-connection /load of config.lua loses reconnect target.**
--      When a /load config.lua happens while a connection is live,
--      the NEW on_connect handler never fires (we're already
--      connected), so it has no `host/port` to record. Fix:
--      bm_last_host/port are read from store.disk_* at config load
--      time (block above on_connect), and written on every connect.
--      Disk-state survives /load. So a subsequent drop still finds
--      a valid host to retry against.
--
--   2. **on_disconnect fires multiple times during close-down.**
--      Observed live on cthulhumud: "Connection closed" was followed
--      by "Disconnecting from: ..." and then THREE-FOUR
--      "[reconnect] dropped" lines for the same drop. Each one
--      armed a fresh 5s timer; all of them then raced into
--      mud.connect, and the first attempt hit "[!!] Failed to get
--      connection stream" because the prior socket hadn't fully
--      torn down yet. Fix: a one-shot `bm_reconnect_pending` guard
--      so only ONE timer is armed per disconnect. The reconnect
--      timer also checks mud.is_connected() before firing
--      mud.connect (someone could have manually reconnected during
--      the 5s window), and uses mud.reconnect() (which is
--      Blightmud-native and handles the previous-server bookkeeping
--      itself) rather than a raw mud.connect().
--
--   3. **Reconnect can still fail on a slow socket teardown.**
--      Even with the multi-fire guard, the 5s window may not be
--      long enough on TLS connections. If mud.is_connected() still
--      reports true at fire time, we wait another 5s and retry up
--      to RECONNECT_MAX_RETRIES times before giving up.
--
-- Every state transition logs `[reconnect] state: ...` so future
-- failures leave a trace without source-diving.

local LAST_HOST_KEY = "bm_last_host"
local LAST_PORT_KEY = "bm_last_port"
local RECONNECT_DELAY = 5            -- seconds between drop and retry
local RECONNECT_MAX_RETRIES = 6      -- give up after ~30s of failed retries

if _G.bm_last_host == nil then
    local stored_host = store.disk_read(LAST_HOST_KEY)
    local stored_port = store.disk_read(LAST_PORT_KEY)
    if stored_host and stored_host ~= "" then
        _G.bm_last_host = stored_host
        _G.bm_last_port = tonumber(stored_port) or 23
        blight.output(string.format(
            "[reconnect] state: restored last_host=%s last_port=%s from disk",
            _G.bm_last_host, tostring(_G.bm_last_port)))
    end
end
_G.bm_manual_disconnect = _G.bm_manual_disconnect or false
_G.bm_auto_reconnect_enabled = (_G.bm_auto_reconnect_enabled ~= false)  -- on by default
_G.bm_reconnect_pending = _G.bm_reconnect_pending or false              -- one-shot guard
_G.bm_reconnect_attempts = _G.bm_reconnect_attempts or 0                 -- retry counter

-- Forward-declared so on_disconnect can call schedule_reconnect.
local schedule_reconnect

mud.on_connect(function(host, port)
    bm_ts_open(host)
    _G.bm_last_host = host
    _G.bm_last_port = port
    store.disk_write(LAST_HOST_KEY, host)
    store.disk_write(LAST_PORT_KEY, tostring(port))
    -- A successful connection clears any in-flight reconnect bookkeeping.
    _G.bm_reconnect_pending = false
    _G.bm_reconnect_attempts = 0
    local file = servers[host]
    if file then
        disable_all_game_groups()
        _G.bm_current_game = file:gsub("%.lua$", "")
        script.load(blight.config_dir() .. "/" .. file)
    end
    -- Auto-fire `login` if this connect was the result of an auto-
    -- reconnect (set by on_disconnect below). Each per-game .lua's
    -- `login` alias handles the credential flow. 3s delay so the
    -- server's welcome screen has fully arrived before we type.
    if _G.bm_auto_login_pending then
        _G.bm_auto_login_pending = false
        blight.output("[reconnect] state: connected — firing `login` in 3s…")
        timer.add(3, 1, function() mud.input("login") end)
    end
end)

-- schedule_reconnect: arm a single timer to reconnect. Safe to call
-- multiple times — repeat calls are no-ops while a reconnect is
-- already pending. Also handles "socket not yet free" retries.
schedule_reconnect = function(host, port, was)
    if _G.bm_reconnect_pending then
        blight.output("[reconnect] state: already pending — skipping duplicate")
        return
    end
    if _G.bm_reconnect_attempts >= RECONNECT_MAX_RETRIES then
        blight.output(string.format(
            "[reconnect] state: gave up after %d attempts. Run /connect manually.",
            _G.bm_reconnect_attempts))
        _G.bm_reconnect_attempts = 0
        return
    end
    _G.bm_reconnect_pending = true
    _G.bm_reconnect_attempts = _G.bm_reconnect_attempts + 1
    _G.bm_auto_login_pending = true  -- on_connect fires `login` once
    blight.output(string.format(
        "[reconnect] state: %s dropped — attempt %d/%d to %s:%s in %ds",
        was or host, _G.bm_reconnect_attempts, RECONNECT_MAX_RETRIES,
        host, tostring(port), RECONNECT_DELAY))
    timer.add(RECONNECT_DELAY, 1, function()
        _G.bm_reconnect_pending = false
        -- If the user (or another path) brought the connection back
        -- already, do nothing.
        if mud.is_connected and mud.is_connected() then
            blight.output("[reconnect] state: already connected — aborting retry")
            _G.bm_reconnect_attempts = 0
            return
        end
        blight.output(string.format(
            "[reconnect] state: firing now (attempt %d/%d)…",
            _G.bm_reconnect_attempts, RECONNECT_MAX_RETRIES))
        -- Prefer mud.reconnect() (Blightmud-native, knows the prior
        -- saved-server metadata so name/tls/etc. carry through).
        -- Falls back to mud.connect for older Blightmud versions.
        local ok, err
        if mud.reconnect then
            ok, err = pcall(mud.reconnect)
        else
            ok, err = pcall(mud.connect, host, port)
        end
        if not ok then
            blight.output(string.format(
                "[reconnect] state: connect attempt threw (%s) — will retry",
                tostring(err)))
            -- Don't reset attempts; on_disconnect (if it fires) or
            -- a manual schedule_reconnect will pick up next.
            schedule_reconnect(host, port, was)
        end
    end)
end

mud.on_disconnect(function()
    bm_ts_close()
    local was = _G.bm_current_game
    _G.bm_current_game = nil
    disable_all_game_groups()

    -- Diagnostic logging (bead blightmud-8ud / 92z): print every
    -- branch's decision so any future failure leaves a trace.
    blight.output(string.format(
        "[reconnect] state: on_disconnect fired game=%s enabled=%s manual=%s pending=%s last_host=%s last_port=%s",
        tostring(was), tostring(_G.bm_auto_reconnect_enabled),
        tostring(_G.bm_manual_disconnect),
        tostring(_G.bm_reconnect_pending),
        tostring(_G.bm_last_host), tostring(_G.bm_last_port)))

    if not _G.bm_auto_reconnect_enabled then
        blight.output("[reconnect] state: disabled — no retry. Use `autoreconnect on` to re-enable.")
    elseif _G.bm_manual_disconnect then
        blight.output("[reconnect] state: manual disconnect (bye) — no retry.")
        _G.bm_reconnect_attempts = 0
    elseif not _G.bm_last_host then
        blight.output("[reconnect] state: no last_host — can't retry. Run /connect <name> manually.")
    else
        -- schedule_reconnect is itself idempotent against duplicate
        -- on_disconnect fires via the bm_reconnect_pending guard.
        schedule_reconnect(_G.bm_last_host, _G.bm_last_port, was)
    end
    _G.bm_manual_disconnect = false  -- reset for next cycle
end)

-- Manual-disconnect alias. Use `bye` instead of /disconnect for a
-- clean logout that doesn't trigger auto-reconnect.
alias.add("^bye$", function()
    _G.bm_manual_disconnect = true
    _G.bm_reconnect_pending = false      -- cancel any in-flight retry
    _G.bm_reconnect_attempts = 0
    mud.input("/disconnect")
end)
alias.add("^autoreconnect (on|off)$", function(m)
    _G.bm_auto_reconnect_enabled = (m[2] == "on")
    blight.output("[reconnect] state: " ..
        (_G.bm_auto_reconnect_enabled and "ENABLED" or "DISABLED"))
end)

-- Diagnostic alias — print current reconnect state on demand.
alias.add("^reconnect-status$", function()
    blight.output(string.format(
        "[reconnect] state: enabled=%s pending=%s attempts=%d last_host=%s last_port=%s connected=%s",
        tostring(_G.bm_auto_reconnect_enabled),
        tostring(_G.bm_reconnect_pending),
        _G.bm_reconnect_attempts or 0,
        tostring(_G.bm_last_host),
        tostring(_G.bm_last_port),
        tostring(mud.is_connected and mud.is_connected())))
end)
