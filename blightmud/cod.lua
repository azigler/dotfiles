-- Cleft of Dimensions — Matango Summoner.
-- See ~/Blightmud/refs/cod.md for the game's command vocabulary and
-- ~/Blightmud/.claude/skills/alias/SKILL.md for the alias/trigger rules.

-- Per-game alias + trigger groups. game_groups("cod") creates them
-- on first /load, or clears them on re-load — leaving plugin
-- bindings (blightmud_mcp etc.) untouched.
local g_alias, g_trigger = game_groups("cod")

-- ─── helpers ────────────────────────────────────────────────────────

-- Forward-declared cross-section state. Fields are populated by the
-- HUD prompt-trigger (see "rich HUD" section ~line 200) and read by
-- aliases defined further down (e.g., `burst`'s no-target guard).
-- Declared here so all closures below can see it as an upvalue —
-- Lua resolves upvalues at function-definition time, so a `local`
-- declared after a closure is NOT visible inside it.
local cod_state = {
    ring = {},              -- ring buffer of recent server lines
    ring_max = 12,
    room_title = "—",
    room_exits = "",
    -- Cached value of the prompt's T:%o field. "None" when not in
    -- combat, or a percentage string like "50%" when targeting a mob.
    -- nil means we haven't seen a prompt yet (e.g., user is on the
    -- simple prompt and hasn't run `setprompt`) — in that case the
    -- `burst` guard falls through and casts unconditionally to preserve
    -- backward compatibility.
    last_target = nil,
}

local function cast(spell, target)
    if target and target ~= "" then
        mud.send("c '" .. spell .. "' " .. target)
    else
        mud.send("c '" .. spell .. "'")
    end
end

-- Returns true if the prompt's T:%o field indicates an active combat
-- target. Conservative: if we've never seen a prompt (last_target nil),
-- we return true so the caller doesn't break on users with the simple
-- prompt. Only "None" (the value CoD sends when no target is engaged)
-- counts as a definitive no-target signal.
local function cod_has_target()
    local t = cod_state.last_target
    if t == nil then return true end          -- no prompt seen yet — don't block
    if t == "" then return true end           -- defensive
    if t == "None" then return false end      -- CoD's explicit "no target"
    return true
end

-- ─── login ──────────────────────────────────────────────────────────
g_alias:add("^login$", function()
    local user, pass = creds("cod")
    if not user or not pass then
        blight.output("[cod] no creds — set COD_USER + COD_PASS in .env.local")
        return
    end
    mud.send(user, { gag = true, skip_log = true })
    -- Blightmud distinguishes "regular line" (has trailing newline) from
    -- "prompt" (no newline). trigger.add { prompt = true } matches ONLY
    -- prompts, not regular lines. To be robust across MUDs that send the
    -- password prompt either way, register BOTH and guard against firing
    -- twice.
    local sent = false
    local on_pass_prompt = function()
        if sent then return end
        sent = true
        mud.send(pass, { gag = true, skip_log = true })
        mud.send("", { gag = true, skip_log = true })  -- advance any post-auth screen
    end
    trigger.add("Please enter your password:", { count = 1, gag = true }, on_pass_prompt)
    trigger.add("Please enter your password:", { count = 1, gag = true, prompt = true }, on_pass_prompt)
end)

-- ─── reconnaissance ─────────────────────────────────────────────────
g_alias:add("^co (.+)$", function(m) mud.send("consider " .. m[2]) end)
g_alias:add("^an (.+)$", function(m) cast("analyze", m[2]) end)

-- ─── pet recruitment ────────────────────────────────────────────────
g_alias:add("^tm (.+)$", function(m) cast("tame", m[2]) end)
g_alias:add("^hy (.+)$", function(m) cast("hypnotize", m[2]) end)

-- ─── summon stacking (active-combat-only spells) ────────────────────
g_alias:add("^lg (.+)$", function(m) cast("legionnaire", m[2]) end)
g_alias:add("^ou (.+)$", function(m) cast("orb user", m[2]) end)
-- `burst <mob>` stacks Legionnaire + Orb User on the current target.
-- Both spells require active combat — if the target died between the
-- player typing `burst` and the cast resolving (or if there's no fight
-- at all), the server replies `You aren't fighting anyone.` but the
-- ~30 MP per cast is still consumed. Guard via the HUD prompt's T:%o
-- field: if it reads "None", abort. Bead blightmud-ba2; episode 09
-- (2026-05-18) lost ~30 MP twice to this.
g_alias:add("^burst (.+)$", function(m)
    if not cod_has_target() then
        blight.output("[burst] no target (T:None in prompt) — won't cast, saving ~30 MP")
        return
    end
    local t = m[2]
    cast("legionnaire", t)
    cast("orb user", t)
end)

-- ─── racial: spore (Matango poison) ─────────────────────────────────
g_alias:add("^sp (.+)$", function(m) mud.send("spore " .. m[2]) end)

-- ─── pet control ────────────────────────────────────────────────────
g_alias:add("^op (\\S+) (.+)$", function(m)
    mud.send("order " .. m[2] .. " kill " .. m[3])
end)
g_alias:add("^oa (.+)$", function(m)
    mud.send("order all kill " .. m[2])
end)
g_alias:add("^g$", function() mud.send("group") end)

-- ─── defense / escape ───────────────────────────────────────────────
g_alias:add("^fb (.+)$", function(m) mud.send("fallback " .. m[2]) end)
g_alias:add("^rec$", function() mud.send("recall") end)
g_alias:add("^wr$", function() cast("word of recall") end)
g_alias:add("^wr (.+)$", function(m) cast("word of recall", m[2]) end)

-- ─── housekeeping ───────────────────────────────────────────────────
g_alias:add("^gc$", function() mud.send("get all corpse") end)
g_alias:add("^il$", function() cast("illuminate") end)
g_alias:add("^sc$", function() mud.send("score") end)
g_alias:add("^rd$", function() mud.send("report defense") end)

-- ─── auto-survival (edge-detected, persistent food/drink) ──────────
-- Default enabled = true. food + drink preferences persist to disk
-- (store.disk_write) so they survive Blightmud restarts.

local SURVIVAL_KEY = "cod_survival"  -- store key: "<food>|<drink>"

local function load_survival_prefs()
    local raw = store.disk_read(SURVIVAL_KEY) or ""
    local food, drink = raw:match("^(.-)|(.*)$")
    return
        (food and food ~= "" and food) or "ration",
        (drink and drink ~= "" and drink) or "water"
end

local function save_survival_prefs(s)
    store.disk_write(SURVIVAL_KEY, s.food .. "|" .. s.drink)
end

local food0, drink0 = load_survival_prefs()
local survival = {
    enabled = true,  -- ALWAYS start enabled on (re)load
    food    = food0,
    drink   = drink0,
    hungry  = false,
    thirsty = false,
}

g_trigger:add(".+", { prompt = true }, function(_, line)
    if not survival.enabled then return end
    local text = line:line()

    local has_hunger = text:find("HUNGER", 1, true) ~= nil
    if has_hunger and not survival.hungry then
        survival.hungry = true
        mud.send("eat " .. survival.food, { gag = true })
    elseif not has_hunger then
        survival.hungry = false
    end

    local has_thirst = text:find("THIRST", 1, true) ~= nil
    if has_thirst and not survival.thirsty then
        survival.thirsty = true
        mud.send("drink " .. survival.drink, { gag = true })
    elseif not has_thirst then
        survival.thirsty = false
    end
end)

g_alias:add("^survival$", function()
    blight.output(string.format(
        "[survival] enabled=%s  food=%q  drink=%q  hungry=%s  thirsty=%s",
        tostring(survival.enabled), survival.food, survival.drink,
        tostring(survival.hungry), tostring(survival.thirsty)))
end)
g_alias:add("^survival (on|off)$", function(m)
    survival.enabled = (m[2] == "on")
    survival.hungry, survival.thirsty = false, false
    blight.output("[survival] " .. (survival.enabled and "ENABLED" or "DISABLED"))
end)
g_alias:add("^survival food (.+)$", function(m)
    survival.food = m[2]
    save_survival_prefs(survival)
    blight.output("[survival] food = " .. m[2] .. " (saved)")
end)
g_alias:add("^survival drink (.+)$", function(m)
    survival.drink = m[2]
    save_survival_prefs(survival)
    blight.output("[survival] drink = " .. m[2] .. " (saved)")
end)

-- Optional low-HP auto-flee. Off by default; enable once you've set
-- a prompt like:  prompt <%h/%H hp %m/%M mp %v/%V mv %u %U>
-- Then uncomment.
--
-- g_trigger:add("<(\\d+)/(\\d+) hp", { prompt = true }, function(matches)
--     local hp, max = tonumber(matches[2]), tonumber(matches[3])
--     if hp and max and (hp / max) < 0.20 then
--         mud.send("flee")
--     end
-- end)

-- ─── rich HUD (status_area, prompt-driven) ─────────────────────────
-- Sets the player's in-game prompt to a detailed format, then parses
-- it once per round and renders to Blightmud's top status_area.
-- The prompt itself is gagged from screen so it doesn't clutter
-- scrollback — the HUD shows the same info.
--
-- See .claude/skills/rich-cod/SKILL.md for the design + roadmap.
-- See refs/cod.md for the prompt code reference.

-- Detailed prompt format. Set once via the `setprompt` alias.
-- Note: dropped %A (Super bar — Gladiator-only, useless for Summoner).
-- Replaced with %X (XP to next level — gold for tracking grinding).
local COD_HUD_PROMPT = "<HP:%h/%H MP:%m/%M MV:%v/%V T:%o X:%X %u %U>"

g_alias:add("^setprompt$", function()
    mud.send("prompt " .. COD_HUD_PROMPT)
    blight.output("[cod] prompt set to HUD format — top bar should populate after next action")
end)

-- Colored ASCII bar. ANSI: green (full-ish) / yellow (mid) / red (low).
-- The trailing reset is critical — without it, the rest of the status
-- line keeps the color.
local function bar(cur, max, width)
    if not max or max == 0 then return string.rep(" ", width) end
    local pct = cur / max
    local filled = math.floor(pct * width + 0.5)
    if filled > width then filled = width end
    if filled < 0 then filled = 0 end
    local color
    if pct >= 0.66 then color = "\27[32m"      -- green
    elseif pct >= 0.33 then color = "\27[33m"  -- yellow
    else color = "\27[31m" end                  -- red
    return color .. string.rep("=", filled) .. string.rep(" ", width - filled) .. "\27[0m"
end

-- Shared state for the 3-row HUD: rows 0+1 driven by prompt
-- regex (HP/MP/MV/Target/Super/Flags); row 2 driven by the exits
-- trigger (Room title + Exits). `cod_state` is forward-declared at
-- the top of the file (see "helpers" section) so aliases defined
-- ABOVE this point (e.g., `burst`) can also read its fields as an
-- upvalue.

-- Pet tracking — populated by the `group` trigger below. Tracks
-- each pet's name + current/max HP. HUD shows lowest pet HP% as
-- a quick "are pets ok?" indicator.
--
-- `flash` is set by the pet-loss triggers (see "pet-loss surfacing"
-- section below). When non-nil, the HUD's `Pets:` cell is replaced
-- with a bright "LOST <name>" banner for ~5 seconds so a pet drop
-- can't be invisible. After the deadline passes, the next prompt
-- render falls back to the normal stars+lo% display.
local cod_pets = {
    count = 0,
    names = {},
    pets = {},      -- [i] = { name, hp, hpmax }
    min_hp_pct = nil,
    flash = nil,    -- { text = "LOST X", until_ts = os.time() + 5 }
}

-- Disk key: persist a transient "last loss" marker so a fresh session
-- can show in the boot banner that pets were down at last shutdown.
local PET_STATE_KEY = "cod_pets_state"

local function cod_pets_recompute_min()
    local m = nil
    for _, p in ipairs(cod_pets.pets) do
        if p.hpmax and p.hpmax > 0 then
            local pct = p.hp / p.hpmax
            if not m or pct < m then m = pct end
        end
    end
    cod_pets.min_hp_pct = m
end

local function cod_hud_render(hp, hpmax, mp, mpmax, mv, mvmax, target, xpnext, flags)
    blight.status_height(3)
    blight.status_line(0, string.format(
        "HP [%s] %d/%d   MP [%s] %d/%d   MV [%s] %d/%d",
        bar(hp, hpmax, 16), hp, hpmax,
        bar(mp, mpmax, 16), mp, mpmax,
        bar(mv, mvmax, 16), mv, mvmax))
    local target_display = (target and target ~= "") and target or "--"
    local flag_display = flags or ""
    local pet_display
    -- Flash takes priority: if a pet-loss event fired in the last 5s
    -- we replace the normal Pets cell with a bright LOST banner so
    -- Andrew can't miss it. The flash auto-expires on the NEXT prompt
    -- after `until_ts`, no explicit timer-clear needed.
    if cod_pets.flash and os.time() < cod_pets.flash.until_ts then
        -- Bright red + bold for maximum visibility. Append remaining
        -- count so we don't lose the running tally during the flash.
        pet_display = string.format(
            "\27[1;31mPets: %s\27[0m (%d left)",
            cod_pets.flash.text, cod_pets.count)
    elseif cod_pets.count == 0 then
        pet_display = "Pets: --"
        -- Clear the stale flash so the renderer settles.
        cod_pets.flash = nil
    else
        cod_pets.flash = nil
        local stars = string.rep("*", math.min(cod_pets.count, 5))
        local pct = cod_pets.min_hp_pct
        if pct then
            local color
            if pct >= 0.66 then color = "\27[32m"      -- green
            elseif pct >= 0.33 then color = "\27[33m"  -- yellow
            else color = "\27[31m" end                  -- red
            pet_display = string.format("Pets: %s%s\27[0m (%d, lo=%d%%)",
                color, stars, cod_pets.count, math.floor(pct * 100))
        else
            pet_display = "Pets: " .. stars .. " (" .. cod_pets.count .. ")"
        end
    end
    blight.status_line(1, string.format(
        "Target: %s   %s   XP→%s   %s",
        target_display, pet_display, xpnext or "?", flag_display))
    blight.status_line(2, string.format(
        "Room: %s   Exits: %s",
        cod_state.room_title, cod_state.room_exits))
end

-- Trigger matches the detailed-prompt format the `setprompt` alias
-- installs. If the user keeps the simple prompt, this trigger
-- silently doesn't match — no harm done.
-- Regex notes:
--   * No `$` anchor — server sends a trailing space after `>`.
--   * `T:(\S+)` — when no target, server sends `T:None` (one word).
--   * `(.*?)\s*>` — non-greedy flag capture, trailing spaces tolerated.
-- We also register both line+prompt variants so prompts sent either
-- way (with or without trailing newline) get caught.
local cod_hud_re = "^<HP:(\\d+)/(\\d+) MP:(\\d+)/(\\d+) MV:(\\d+)/(\\d+) T:(\\S+) X:(\\d+) (.*?)\\s*>"

local cod_hud_cb = function(m)
    -- Cache the target field for non-HUD consumers (e.g., the `burst`
    -- alias's no-target guard — see bead blightmud-ba2). When no
    -- target is engaged, CoD sends "T:None"; otherwise "T:50%" etc.
    cod_state.last_target = m[8]
    cod_hud_render(
        tonumber(m[2]), tonumber(m[3]),   -- HP cur/max
        tonumber(m[4]), tonumber(m[5]),   -- MP cur/max
        tonumber(m[6]), tonumber(m[7]),   -- MV cur/max
        m[8],                              -- Target (enemy HP % or "None")
        m[9],                              -- XP to next level (was Super %)
        m[10]                              -- Flags (HUNGER/THIRST tokens)
    )
end

g_trigger:add(cod_hud_re, { prompt = true, gag = true }, cod_hud_cb)
g_trigger:add(cod_hud_re, { gag = true }, cod_hud_cb)

-- Optional: toggle the HUD off if user wants the prompt visible
-- in scroll temporarily (e.g., for debugging).
g_alias:add("^hud (on|off)$", function(m)
    if m[2] == "off" then
        blight.status_height(0)
        blight.output("[cod] HUD hidden")
    else
        blight.status_height(3)
        blight.output("[cod] HUD enabled (3 rows, will populate on next prompt)")
    end
end)

-- ─── room-graph mapper ─────────────────────────────────────────────
-- Ported (data-layer only) from cleftmapper.lua. Tracks rooms by
-- title, builds a graph from observed movement, persists to disk.
-- mapper_new() is exposed globally by mapper.lua (loaded from config.lua).
-- See ~/dotfiles/blightmud/mapper.lua and bead blightmud-0tk.
local cod_mapper = (_G.mapper_new and _G.mapper_new("cod")) or nil
if cod_mapper then
    _G.cod_mapper = cod_mapper
    -- Side-pane file: profiles/cod.sh tails this in a tmux split.
    cod_mapper.dump_path = "/tmp/cod-mapper.txt"
    pcall(cod_mapper.dump, cod_mapper.dump_path)
else
    blight.output("[cod] mapper not available (mapper.lua didn't expose mapper_new)")
end

-- Direction aliases — instrument the mapper so it learns edges,
-- AND auto-fire `map` so the right-side atlas pane refreshes after
-- every step (gagged from main pane via cod_auto_map_fire).
-- mud.send for the direction is gagged so the alias's resend doesn't
-- produce a second `> <dir>` echo on top of Blightmud's input echo.
for _, dir in ipairs({"n", "s", "e", "w", "u", "d", "ne", "nw", "se", "sw",
                     "north", "south", "east", "west", "up", "down",
                     "northeast", "northwest", "southeast", "southwest"}) do
    g_alias:add("^" .. dir .. "$", function()
        if cod_mapper then cod_mapper.note_move(dir) end
        mud.send(dir, { gag = true })
        cod_auto_map_fire()
    end)
end

-- Mapper introspection / speedwalk. `map` itself stays passthrough
-- to the CoD server-side `map` command (current-area printout).
g_alias:add("^mp$", function()
    if cod_mapper then cod_mapper.show() else blight.output("[mapper] not loaded") end
end)
g_alias:add("^mp go (.+)$", function(m)
    if cod_mapper then cod_mapper.go(m[2]) else blight.output("[mapper] not loaded") end
end)
g_alias:add("^mp clear$", function()
    if cod_mapper then cod_mapper.clear() end
end)
g_alias:add("^mp save$", function()
    if cod_mapper then blight.output("[mapper] persisted on every note_room") end
end)
g_alias:add("^mp where$", function()
    if cod_mapper then cod_mapper.where() end
end)
g_alias:add("^mp find (.+)$", function(m)
    if not cod_mapper then return end
    local hits = cod_mapper.find(m[2])
    if #hits == 0 then
        blight.output("[mapper:cod] no match for '" .. m[2] .. "'")
        return
    end
    blight.output("[mapper:cod] " .. #hits .. " match" .. (#hits == 1 and "" or "es") .. ":")
    for _, t in ipairs(hits) do blight.output("  " .. t) end
end)
g_alias:add("^mp zone$", function()
    if not cod_mapper then return end
    local hits = cod_mapper.same_zone()
    blight.output("[mapper:cod] same-zone rooms (" .. #hits .. "):")
    for _, t in ipairs(hits) do
        blight.output((t == cod_mapper.current and "  * " or "    ") .. t)
    end
end)
-- `mp zones` (plural) lists ALL distinct zones parsed from titles,
-- with room counts. Useful for "what areas have I explored?" and as
-- input to `mp go` since zone-aware resolution prefers in-zone matches.
g_alias:add("^mp zones$", function()
    if not cod_mapper then return end
    local zs = cod_mapper.zones()
    blight.output("[mapper:cod] " .. #zs .. " zone" .. (#zs == 1 and "" or "s") .. " known:")
    for _, z in ipairs(zs) do
        blight.output(string.format("    %s  (%d room%s)",
            z.zone, z.count, z.count == 1 and "" or "s"))
    end
end)
g_alias:add("^mp render$", function()
    if cod_mapper then cod_mapper.render() end
end)
g_alias:add("^mpr$", function()
    if cod_mapper then cod_mapper.render() end
end)

-- Cancel a recorded movement when CoD rejects the direction —
-- prevents phantom edges in the mapper graph.
g_trigger:add("Alas, you cannot go that way", {}, function()
    if cod_mapper then cod_mapper.cancel_move() end
end)
g_trigger:add("You can't go that way", {}, function()
    if cod_mapper then cod_mapper.cancel_move() end
end)

-- ─── room banner (3rd status row) ──────────────────────────────────
-- CoD doesn't expose %r in its prompt codes, so we parse the room
-- title from text output. CoD's room block is:
--     <title line>                       (not indented, short, no period)
--       <first description line>         (indented with two spaces)
--     <continuation lines>               (no leading spaces)
--     <blank line>
--     (] Exits: <dirs> [)
-- We maintain a ring buffer of the last few server lines. When the
-- exits-trigger fires, we walk backwards to find the FIRST 2-space-
-- indented line (the start of the description block); the line just
-- before that is the title. Updates feed mapper.lua too.
-- (cod_state is declared above so cod_hud_render can render row 2.)

-- Map-capture state. While `active`, the output_listener appends
-- raw lines (color-preserving) to `buffer` AND gags them from screen
-- so they only land in the right-side atlas pane file, not the main
-- scroll. The HUD prompt marker ends the capture and writes the file.
local cod_map_capture = {
    active = false,
    buffer = {},
    out_path = "/tmp/cod-atlas.txt",
}

-- Auto-fire `map` after each movement so the right pane stays current.
-- Toggled by `automap on|off`. On by default.
_G.cod_auto_map = (_G.cod_auto_map ~= false)

local function cod_map_capture_finish()
    if not cod_map_capture.active then return end
    cod_map_capture.active = false
    local f = io.open(cod_map_capture.out_path, "w")
    if f then
        f:write("\27[1;35m─── CoD atlas (last `map` " .. os.date("%H:%M:%S")
                .. ") ───\27[0m\n\n")
        for _, l in ipairs(cod_map_capture.buffer) do
            f:write(l .. "\n")
        end
        f:close()
    end
    cod_map_capture.buffer = {}
end

-- Global (not local) so the movement aliases defined earlier in
-- this file can resolve it at CALL time, not at closure-creation
-- time. Lua locals must be lexically before their use; globals
-- resolve dynamically and are fine.
--
-- Guards: (a) skip if cod_auto_map disabled; (b) skip if a capture
-- is already active (the auto-map's OWN output contains an exits
-- line — without this guard, the exits-trigger would feedback-loop).
function cod_auto_map_fire()
    if not _G.cod_auto_map then return end
    if cod_map_capture.active then return end
    -- Delay so the move's room block reaches the screen BEFORE we
    -- start gagging map output. 0.4s is empirically enough for the
    -- room description + exits line to render uncaptured.
    timer.add(0.4, 1, function()
        if cod_map_capture.active then return end  -- re-check at fire time
        cod_map_capture.active = true
        cod_map_capture.buffer = {}
        mud.send("map", { gag = true, skip_log = true })
    end)
end

mud.add_output_listener(function(line)
    if _G.bm_current_game ~= "cod" then return line end
    local text = line:line()

    -- Map-capture: append raw lines (with color) AND gag from screen +
    -- log. The dedicated right-pane atlas tail is the only place this
    -- content surfaces, until the HUD prompt arrives.
    if cod_map_capture.active then
        if text and text:match("^<HP:") then
            cod_map_capture_finish()
        else
            table.insert(cod_map_capture.buffer, line:raw())
            line:gag(true)
            line:skip_log(true)
        end
    end

    -- Ring buffer for room-title extraction (existing behavior).
    if text and #text > 0 then
        table.insert(cod_state.ring, text)
        if #cod_state.ring > cod_state.ring_max then
            table.remove(cod_state.ring, 1)
        end
    end
    return line
end)

-- Explicit `map` / `atlas` aliases — also capture + gag to the right
-- pane. The output goes ONLY to the dedicated atlas pane, not the
-- main scroll. Type these manually if you want to refresh the pane.
g_alias:add("^map$", function()
    cod_map_capture.active = true
    cod_map_capture.buffer = {}
    mud.send("map", { gag = true, skip_log = true })
end)

g_alias:add("^atlas$", function()
    cod_map_capture.active = true
    cod_map_capture.buffer = {}
    mud.send("atlas", { gag = true, skip_log = true })
end)

g_alias:add("^automap (on|off)$", function(m)
    _G.cod_auto_map = (m[2] == "on")
    blight.output("[cod] auto-map " .. (_G.cod_auto_map and "ENABLED" or "DISABLED"))
end)

local function cod_room_banner()
    blight.status_line(2, string.format(
        "Room: %s   Exits: %s",
        cod_state.room_title, cod_state.room_exits))
end

-- Trigger regex uses Rust regex flavor (NOT Lua patterns). Match the
-- CoD exits format `(] Exits: <dirs> [)`.
local cod_exits_re = "^\\(\\]\\s*Exits:\\s*(.+?)\\s*\\[\\)"
g_trigger:add(cod_exits_re, {}, function(matches)
    local exits = matches[2]
    if not exits then return end
    cod_state.room_exits = exits

    -- Find the title: in CoD, room blocks look like:
    --     <title>
    --       <first description line, 2-space indented>
    --     <continuation>
    --     <continuation>
    --     <blank>
    --     (] Exits: ... [)
    -- Continuation lines have NO indent — only the FIRST description
    -- line starts with two spaces. So: walking backwards from the
    -- exits line, find the first line that starts with "^  ", then
    -- the line just before it in the ring is the title.
    -- (Lua-side match below uses Lua patterns — that's correct.)
    local title = nil
    local first_desc_idx = nil
    for i = #cod_state.ring, 1, -1 do
        local t = cod_state.ring[i]
        if t:match("^  ") and not t:match("^%(%]") then
            first_desc_idx = i
            break
        end
    end
    if first_desc_idx and first_desc_idx > 1 then
        local candidate = cod_state.ring[first_desc_idx - 1]
        if candidate
           and not candidate:match("^%s*$")
           and not candidate:match("^%(%]")
           and not candidate:match("^<%d+/%d+")
           and not candidate:match("^>")
           and #candidate < 100 then
            title = candidate
        end
    end

    if title and #title > 0 and #title < 80 then
        cod_state.room_title = title
        if _G.cod_mapper and _G.cod_mapper.note_room then
            pcall(_G.cod_mapper.note_room, title, exits)
        end
    end
    blight.status_height(3)
    cod_room_banner()
    -- Auto-refresh the atlas pane on ANY room change — recall,
    -- speedwalk, server-side teleport, and direct movement all
    -- funnel through this trigger when a new (] Exits: ... [) line
    -- arrives. The auto-map function self-guards against firing
    -- during its own capture window (so this doesn't feedback-loop).
    cod_auto_map_fire()
end)

-- Manual peek of current banner state (debug)
g_alias:add("^banner$", function()
    blight.output(string.format(
        "[banner] title=%q exits=%q ring=%d",
        cod_state.room_title, cod_state.room_exits, #cod_state.ring))
end)

-- ─── pet counter (via `group` output) ──────────────────────────────
-- CoD has no prompt code for pet count. We parse the `group` command's
-- output: it lists "[<level> <class>] <name>" rows; the first is the
-- player themselves, the rest are pets / group-mates. We auto-run
-- `group` after pet-summoning aliases and on demand via `pets`.
--
-- Group output format (one row per member):
--   Zig's group:
--   [14 Sum] Zig         226/226 hp  154/154 mana  213/213 mv  28812 xp
--   [10 Pet] Rolyrider   42/42 hp    0/0 mana     30/30 mv    0 xp
local cod_group_in_progress = false

g_trigger:add("^Zig's group:", { gag = false }, function()
    cod_group_in_progress = true
    cod_pets.count = 0
    cod_pets.names = {}
    cod_pets.pets = {}
end)

-- Parse a `group` row:
--   "[14 Sum] Zig                 226/ 226 hp  154/ 154 mana ..."
--   "[ 1 Mob] The pudgy rabite     15/  15 hp  102/ 102 mana ..."
-- Multi-word names need non-greedy `(.+?)` (was \S+ which broke).
-- Skip rows where the captured name is exactly "Zig" (the player
-- himself appears in the group output; everyone else is a pet/ally).
g_trigger:add("^\\[\\s*\\d+\\s+\\S+\\]\\s+(.+?)\\s+(\\d+)/\\s*(\\d+)\\s+hp", {}, function(m)
    if not cod_group_in_progress then return end
    local who = m[2]:gsub("%s+$", "")  -- trim trailing space (rare)
    local hp = tonumber(m[3])
    local hpmax = tonumber(m[4])
    if who == "Zig" then return end  -- it's me, not a pet
    cod_pets.count = cod_pets.count + 1
    table.insert(cod_pets.names, who)
    table.insert(cod_pets.pets, { name = who, hp = hp, hpmax = hpmax })
end)

-- Empty line ends the group block (per CoD convention).
g_trigger:add("^$", {}, function()
    if cod_group_in_progress then
        cod_group_in_progress = false
        cod_pets_recompute_min()
    end
end)

-- `pets` prints the INTERNAL state without polling. This is a
-- sanity check on the HUD: if HUD says "Pets: *** (3)" but `pets`
-- lists the wrong names (or none), the trigger pipeline drifted
-- and `pets refresh` should reconcile by polling `group`.
g_alias:add("^pets$", function()
    if cod_pets.count == 0 then
        blight.output("[pets] none — internal count=0")
    else
        blight.output(string.format("[pets] count=%d", cod_pets.count))
        for i, p in ipairs(cod_pets.pets) do
            if p.hp and p.hpmax then
                blight.output(string.format(
                    "  %d. %s  %d/%d hp", i, p.name, p.hp, p.hpmax))
            else
                blight.output(string.format("  %d. %s", i, p.name))
            end
        end
        for _, n in ipairs(cod_pets.names) do
            local in_pets = false
            for _, p in ipairs(cod_pets.pets) do
                if p.name == n then in_pets = true break end
            end
            if not in_pets then
                blight.output(string.format("  ?. %s  (no hp data)", n))
            end
        end
    end
    if cod_pets.flash then
        blight.output(string.format("[pets] flash=%q (expires in %ds)",
            cod_pets.flash.text,
            math.max(0, cod_pets.flash.until_ts - os.time())))
    end
end)

-- `pets refresh` does the server-side reconciliation poll. Kept
-- separate so the cheap `pets` doesn't have a network round-trip.
g_alias:add("^pets refresh$", function()
    cod_pets.count = 0
    cod_pets.names = {}
    cod_pets.pets = {}
    mud.send("group", { gag = true })
end)

-- Refresh pet count after any successful summon/tame/hypnotize.
-- (The summon spells take a few seconds to resolve; auto-poll group
-- 3 seconds later.)
local function refresh_pets_soon()
    timer.add(3, 1, function() mud.send("group", { gag = true }) end)
end

-- ─── pet-loss surfacing ────────────────────────────────────────────
-- The HUD `Pets:` cell shows count + lowest HP% — but those numbers
-- only updated on the next `group` poll, so an invisible pet-follow
-- break (verified in diary 2026-05-18-02 / 06) used to manifest as
-- "I thought I had 3 pets but Pets: --". The triggers below catch
-- the realistic message set that CoD emits when a pet leaves:
--
--   `<Pet> stops following you.`     -- follow-chain break or fade
--   `<Pet> slowly fades away.`       -- transient summon expired
--   `<Pet> hits the ground...DEAD.`  -- pet died
--   `<Pet> is starting to look restless.` -- (warning only, no loss)
--
-- All four were grepped out of
--   ~/.local/share/blightmud/logs/cleftofdimensions.net/*.log
-- on 2026-05-18 before being trusted as authoritative patterns.
--
-- On loss: decrement count + names + pets list (if name match),
-- emit a `[pet lost]` line to scrollback (it WILL be noticed even
-- when scrolling fast), and set cod_pets.flash so the next HUD
-- render (next prompt) shows a bright LOST banner for 5 seconds.

-- Persist the "you have 0 pets right now" transition so the next
-- session's banner can note "last shutdown had 0 pets". Cheap. We
-- only persist on edge transitions (>0 → 0), not on every loss.
local function cod_pets_persist_if_zero()
    if cod_pets.count <= 0 then
        local ts = os.date("%Y-%m-%d %H:%M:%S")
        store.disk_write(PET_STATE_KEY,
            "zero|" .. ts .. "|last_lost=" ..
            (cod_pets.names[#cod_pets.names] or "unknown"))
    end
end

-- Drop a pet by exact name (case-sensitive, leading-article aware).
-- Returns true if the name was in our tracked list, false otherwise
-- (a pet whose name we never captured via `group`).
local function cod_pets_drop_named(name)
    if not name or name == "" then return false end
    local hit = false
    for i = #cod_pets.names, 1, -1 do
        if cod_pets.names[i] == name then
            table.remove(cod_pets.names, i)
            hit = true
            break
        end
    end
    for i = #cod_pets.pets, 1, -1 do
        if cod_pets.pets[i].name == name then
            table.remove(cod_pets.pets, i)
            hit = true
            break
        end
    end
    if hit then
        cod_pets.count = math.max(0, cod_pets.count - 1)
        cod_pets_recompute_min()
    end
    return hit
end

-- Common helper: handle a pet-loss event identified by a name + verb.
-- `verb` describes the loss type, used in the flash banner and the
-- scrollback line. Always emits the scrollback line, even when the
-- name isn't in our internal list — that way an untracked pet drop
-- (e.g., we missed the `group` poll) still surfaces.
local function cod_pets_record_loss(name, verb)
    local was_tracked = cod_pets_drop_named(name)
    -- Flash banner — 5 seconds, replaces the Pets: cell in the HUD.
    -- Trim name for the banner (CoD names like "A large Rabillion"
    -- are wordy; we keep the first 24 chars).
    local short = name
    if #short > 24 then short = short:sub(1, 23) .. "…" end
    cod_pets.flash = {
        text = string.format("%s %s", verb:upper(), short),
        until_ts = os.time() + 5,
    }
    -- Scrollback line: bright magenta so it stands out from combat spam.
    blight.output(string.format(
        "\27[1;35m[pet lost] %s %s%s\27[0m",
        name, verb,
        was_tracked and "" or " (untracked)"))
    -- Persist if we just hit zero. The reconciliation poll below will
    -- correct the count if the trigger was wrong; this is best-effort.
    cod_pets_persist_if_zero()
end

-- Pet-loss triggers. Regex uses Rust-flavor (per Blightmud's
-- trigger.add — see resources/help/regex.md). `(.+?)` for the pet
-- name is non-greedy to avoid swallowing trailing text.
--
-- "<Pet> stops following you." — broad fail mode: follow-chain break,
--    OR (rare) pet was dismissed. We don't try to distinguish.
g_trigger:add("^(.+?) stops following you\\.$", {}, function(m)
    cod_pets_record_loss(m[2], "stopped following")
    -- Still reconcile via group poll in case multiple drops cascade.
    refresh_pets_soon()
end)

-- "<Pet> slowly fades away." — transient summon (palico, etc.) faded.
g_trigger:add("^(.+?) slowly fades away\\.$", {}, function(m)
    cod_pets_record_loss(m[2], "faded")
    refresh_pets_soon()
end)

-- "<Pet> hits the ground...DEAD." — pet died. This message ALSO
-- fires for mobs we kill, so we only treat it as a loss if the name
-- matches a tracked pet. cod_pets_drop_named's return value is used
-- by the helper to suppress the flash for non-pet kills.
g_trigger:add("^(.+?) hits the ground\\.\\.\\.DEAD\\.$", {}, function(m)
    -- Mob deaths shouldn't flash, so we only fire the loss path if
    -- the name is in our tracked list.
    local name = m[2]
    local tracked = false
    for _, n in ipairs(cod_pets.names) do
        if n == name then tracked = true break end
    end
    if tracked then
        cod_pets_record_loss(name, "died")
        refresh_pets_soon()
    end
end)

-- Tame-fade warning. NOT a loss — we surface it as a yellow note so
-- Andrew knows to re-tame before the pet wanders off.
g_trigger:add("^(.+?) is starting to look restless\\.$", {}, function(m)
    blight.output(string.format(
        "\27[1;33m[pet warn] %s is restless — re-tame soon\27[0m", m[2]))
end)

-- CoD's actual messages on successful tame/hypnotize/dismiss
-- (verified live 2026-05-17). Each fires an auto-`group` poll
-- so the HUD's Pets indicator updates within a couple seconds.
-- These are GAINS — clear any active flash so the user sees the
-- new state immediately.
g_trigger:add("(now follows you|is now hypnotized|joins your group|looks at you with obedient eyes)", {}, function()
    cod_pets.flash = nil
    refresh_pets_soon()
end)

-- Reconcile-only triggers (no flash, no direct mutation — just poll).
-- "leaves your group" / "stops fighting" can happen for non-loss
-- reasons (orderly dismiss); we don't trust them as direct decrements.
g_trigger:add("(leaves your group|has died|stops fighting)", {}, function()
    refresh_pets_soon()
end)

blight.output(string.format(
    "[cod] matango summoner loaded — survival=%s (food=%s, drink=%s) — try: burst <mob>, oa <mob>, tm <mob>, fb <pet>, rec  |  survival on/off, survival food <item>",
    tostring(survival.enabled), survival.food, survival.drink))
