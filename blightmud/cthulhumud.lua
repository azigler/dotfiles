-- CthulhuMUD (cthulhumud.com:8889)
-- Diku/Merc/Sunder/ROM derivative with a Lovecraftian register.

local g_alias, g_trigger = game_groups("cthulhumud")

-- ─── login (persistent triggers, not alias-registered) ──────────
-- CthulhuMUD has a 4-prompt flow:
--   1. "If the word COLOR is in color, enter Y..." — answer Y for ANSI
--   2. "Please enter your name:" — send character name
--   3. "Password:" — send password
--   4. Menu with "P ... Play the Game" — send `p`
--
-- PROBLEM with the old alias-registered approach: triggers were
-- registered when the `login` alias was called, but the alias only
-- ran 3 seconds after on_connect (via bm_auto_login_pending in
-- config.lua). Cthulhumud sends the entire banner + name prompt
-- within ~1 second of TCP connect. Result: alias runs at t+3s,
-- registers triggers, but the name prompt fired at t+1s — already
-- in the past. Triggers cannot fire on past lines. Login stalled
-- repeatedly after reconnects.
--
-- FIX (bead-8b9 / repeat occurrence 2026-05-18): persistent
-- g_trigger:add for the entire login chain, registered at
-- file-LOAD time. Triggers exist before the banner arrives, so
-- they catch the prompts whenever they fire — first connect,
-- reconnect, manual /load, doesn't matter. State is kept in a
-- module-level `login_state` table so we don't double-send
-- per session, but the state RESETS on every COLOR prompt
-- (which marks the start of a fresh login flow).

local login_state = { color_done = false, name_done = false, pass_done = false, menu_done = false }

local function reset_login_state()
    login_state.color_done = false
    login_state.name_done = false
    login_state.pass_done = false
    login_state.menu_done = false
end

g_trigger:add("If the word COLOR is in color", { gag = true }, function()
    -- COLOR prompt marks the very start of the login flow — reset
    -- all guards so this connect goes through cleanly even if a
    -- prior connect was partial.
    reset_login_state()
    login_state.color_done = true
    mud.send("y", { gag = true, skip_log = true })
end)

g_trigger:add("Please answer .Y/N.", { gag = true }, function()
    -- Server retries the COLOR prompt if the initial y was missed.
    if not login_state.color_done then
        login_state.color_done = true
        mud.send("y", { gag = true, skip_log = true })
    end
end)

g_trigger:add("Please enter your name:", { gag = true }, function()
    if login_state.name_done then return end
    local user, _ = creds("cthulhumud")
    if not user then
        blight.output("[cthulhumud] no creds — set CTHULHUMUD_USER + CTHULHUMUD_PASS in .env.local")
        return
    end
    login_state.name_done = true
    mud.send(user, { gag = true, skip_log = true })
end)

g_trigger:add("Password:", { gag = true }, function()
    -- Only fire during the login flow (color_done && name_done
    -- but !pass_done). Post-login, "Password:" might appear in
    -- channel text — we don't want to leak the password.
    if login_state.pass_done then return end
    if not (login_state.color_done and login_state.name_done) then return end
    local _, pass = creds("cthulhumud")
    if not pass then return end
    login_state.pass_done = true
    mud.send(pass, { gag = true, skip_log = true })
end)

g_trigger:add("P \\.\\.\\. Play the Game", { gag = true }, function()
    if login_state.menu_done then return end
    if not login_state.pass_done then return end
    login_state.menu_done = true
    mud.send("p", { gag = true, skip_log = true })
    -- CthulhuMUD's post-menu MOTD/welcome screens each need an
    -- Enter to advance. Several spaced gagged empty sends.
    timer.add(0.5, 1, function() mud.send("", { gag = true, skip_log = true }) end)
    timer.add(1.2, 1, function() mud.send("", { gag = true, skip_log = true }) end)
    timer.add(2.0, 1, function() mud.send("", { gag = true, skip_log = true }) end)
    timer.add(3.0, 1, function() mud.send("", { gag = true, skip_log = true }) end)
end)

-- Manual `login` alias — best-effort to nudge a stuck login.
-- The persistent triggers above handle the happy path; this is
-- only for "I just reloaded the .lua and the previous prompts
-- are already past, what now?" cases. Heuristic: replay every
-- stage that isn't done yet, with small delays between.
g_alias:add("^login$", function()
    local user, pass = creds("cthulhumud")
    if not user or not pass then
        blight.output("[cthulhumud] no creds — set CTHULHUMUD_USER + CTHULHUMUD_PASS in .env.local")
        return
    end
    blight.output("[cthulhumud] nudging login chain (state: color=" .. tostring(login_state.color_done)
        .. " name=" .. tostring(login_state.name_done)
        .. " pass=" .. tostring(login_state.pass_done)
        .. " menu=" .. tostring(login_state.menu_done) .. ")")
    -- Send each missing stage with spacing. The server will ignore
    -- extras (e.g. an unexpected `y` at the in-game prompt is just
    -- a "What?" reply). The persistent triggers will mark each
    -- stage done as the corresponding prompt is seen.
    local t = 0
    if not login_state.color_done then
        timer.add(t, 1, function() login_state.color_done = true; mud.send("y", { gag = true, skip_log = true }) end)
        t = t + 0.4
    end
    if not login_state.name_done then
        timer.add(t, 1, function() login_state.name_done = true; mud.send(user, { gag = true, skip_log = true }) end)
        t = t + 0.4
    end
    if not login_state.pass_done then
        timer.add(t, 1, function() login_state.pass_done = true; mud.send(pass, { gag = true, skip_log = true }) end)
        t = t + 0.4
    end
    if not login_state.menu_done then
        timer.add(t, 1, function() login_state.menu_done = true; mud.send("p", { gag = true, skip_log = true }) end)
    end
end)

-- ─── conveniences ────────────────────────────────────────────────
g_alias:add("^san$", function() mud.send("score") end)

g_trigger:add("^You feel your sanity slipping", {}, function()
    blight.output("[!] sanity warning")
end)

-- ─── rich HUD (status_area, prompt-driven) ─────────────────────────
-- CthulhuMUDs `help prompt` documents %h %H %m %M %v %V %l %n %b
-- %s %p %w %g %r — a rich set including sanity, position, wait
-- states, gold, and room name. We set a detailed prompt via the
-- `setprompt` alias, parse it in a trigger, render 3 status rows.
-- Blightmud's status_area lives at the BOTTOM of the output area
-- (just above the input line), bracketed by horizontal bars.

local CTHU_HUD_PROMPT = "%n [%b] L%l %h/%H hp %m/%M mn %v/%V mv san:%s pos:%p w:%w gold:%g [%r]%c"

g_alias:add("^setprompt$", function()
    mud.send("prompt " .. CTHU_HUD_PROMPT)
    blight.output("[cthulhumud] prompt set to HUD format — bottom bar should populate after next action")
end)

-- Colored ASCII bar. Green >=66%, yellow 33-66%, red <33%.
local function bar(cur, max, width)
    if not max or max == 0 then return string.rep(" ", width) end
    local pct = cur / max
    local filled = math.floor(pct * width + 0.5)
    if filled > width then filled = width end
    if filled < 0 then filled = 0 end
    local color
    if pct >= 0.66 then color = "\27[32m"
    elseif pct >= 0.33 then color = "\27[33m"
    else color = "\27[31m" end
    return color .. string.rep("=", filled) .. string.rep(" ", width - filled) .. "\27[0m"
end

-- Sanity threshold colorizer. CthulhuMUD's sanity field can be a number
-- like "134" or "0", or a flavor word like "Doomed". We color the
-- whole row 1 string based on the parsed numeric value when possible.
local function sanity_color_prefix(sanity_str)
    local n = tonumber(sanity_str)
    if not n then return "" end
    if n < 25 then return "\27[1;31m[!!! INSANE] \27[0m"   -- bright red
    elseif n < 50 then return "\27[31m[! LOW SANITY] \27[0m"
    elseif n < 75 then return "\27[33m[low] \27[0m"
    end
    return ""
end

local function cthu_hud_render(name, race, level, hp, hpmax, mp, mpmax, mv, mvmax, sanity, pos, wait, gold, room)
    blight.status_height(3)
    blight.status_line(0, string.format(
        "%s [%s] L%s   HP [%s] %d/%d   MN [%s] %d/%d   MV [%s] %d/%d",
        name, race, level,
        bar(hp, hpmax, 14), hp, hpmax,
        bar(mp, mpmax, 14), mp, mpmax,
        bar(mv, mvmax, 14), mv, mvmax))
    blight.status_line(1, string.format(
        "%sSanity: %s   Pos: %s   Wait: %s   Gold: %s",
        sanity_color_prefix(sanity),
        sanity, pos, wait, gold))
    blight.status_line(2, "Room: " .. (room or ""))
end

-- Prompt format we send: "Zig [Yithian] L18 141/141 hp 282/282 mn 236/236 mv san:100 pos:Standing w:0 gold:0 [Temple of Ulthar - Main Hall]"
-- Regex captures: name, race, level, hp/max, mn/max, mv/max, sanity, pos, wait, gold, room.
-- Anchored at start; allows trailing space/newline after `]`.
local cthu_re = "^(\\S+) \\[(\\S+)\\] L(\\S+) (\\d+)/(\\d+) hp (\\d+)/(\\d+) mn (\\d+)/(\\d+) mv san:(\\S+) pos:(\\S+) w:(\\S+) gold:(\\S+) \\[(.+)\\]"

local cthu_cb = function(m)
    cthu_hud_render(
        m[2], m[3], m[4],
        tonumber(m[5]), tonumber(m[6]),  -- hp
        tonumber(m[7]), tonumber(m[8]),  -- mn
        tonumber(m[9]), tonumber(m[10]), -- mv
        m[11], m[12], m[13], m[14],      -- sanity, pos, wait, gold
        m[15]                             -- room
    )
end

-- Trigger registration is moved below the mapper hookup so the
-- callback can call into the mapper. See "room-graph mapper" section.

g_alias:add("^hud (on|off)$", function(m)
    if m[2] == "off" then
        blight.status_height(0)
        blight.output("[cthulhumud] HUD hidden")
    else
        blight.status_height(3)
        blight.output("[cthulhumud] HUD enabled (will populate on next prompt)")
    end
end)

-- ─── room-graph mapper ─────────────────────────────────────────────
-- cthulhumud's prompt exposes %r (room name), so we don't need the
-- ring-buffer title extraction that cod.lua does. The HUD trigger
-- captures the room directly from m[15]; we just feed it to the mapper.

local cthu_mapper = (_G.mapper_new and _G.mapper_new("cthulhumud")) or nil
if cthu_mapper then
    _G.cthu_mapper = cthu_mapper
    cthu_mapper.dump_path = "/tmp/cthu-mapper.txt"
    pcall(cthu_mapper.dump, cthu_mapper.dump_path)
end

-- Wrap the HUD callback to also note the room into the mapper. We
-- register the wrapped callback as the sole HUD trigger (earlier
-- inline registrations were removed to avoid double-firing).
local cthu_cb_with_mapper = function(m)
    cthu_cb(m)
    if cthu_mapper then
        pcall(cthu_mapper.note_room, m[15], "")
    end
end

g_trigger:add(cthu_re, { gag = true }, cthu_cb_with_mapper)
g_trigger:add(cthu_re, { prompt = true, gag = true }, cthu_cb_with_mapper)

-- Movement aliases — instrument note_move; gag the resend so the
-- alias doesn't print a second `> <dir>` on top of the user's input echo.
for _, dir in ipairs({"n", "s", "e", "w", "u", "d", "ne", "nw", "se", "sw",
                     "north", "south", "east", "west", "up", "down"}) do
    g_alias:add("^" .. dir .. "$", function()
        if cthu_mapper then cthu_mapper.note_move(dir) end
        mud.send(dir, { gag = true })
    end)
end

-- Mapper introspection (same naming as cod for muscle memory).
g_alias:add("^mp$", function() if cthu_mapper then cthu_mapper.show() end end)
g_alias:add("^mp where$", function() if cthu_mapper then cthu_mapper.where() end end)
g_alias:add("^mp find (.+)$", function(m)
    if not cthu_mapper then return end
    for _, t in ipairs(cthu_mapper.find(m[2])) do blight.output("  " .. t) end
end)
g_alias:add("^mp zone$", function()
    if not cthu_mapper then return end
    for _, t in ipairs(cthu_mapper.same_zone()) do
        blight.output((t == cthu_mapper.current and "  * " or "    ") .. t)
    end
end)
g_alias:add("^mp go (.+)$", function(m) if cthu_mapper then cthu_mapper.go(m[2]) end end)
g_alias:add("^mp clear$", function() if cthu_mapper then cthu_mapper.clear() end end)
g_alias:add("^mpr$", function() if cthu_mapper then cthu_mapper.render() end end)
g_alias:add("^mp render$", function() if cthu_mapper then cthu_mapper.render() end end)

g_trigger:add("You can't go that way", {}, function()
    if cthu_mapper then cthu_mapper.cancel_move() end
end)

blight.output("[cthulhumud] loaded — type `login` at the welcome screen, then `setprompt` for HUD")
