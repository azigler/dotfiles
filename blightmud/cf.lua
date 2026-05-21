-- Carrion Fields (carrionfields.net:4449)
-- Heavily modified ROM. Hardcore RP + PK + permadeath + aging.
--
-- CF has NO GMCP/MSDP — everything is text-parsed from a custom prompt.
-- We use the CFGUI-style "invisible prompt" technique: configure CF's
-- `prompt` to start with a sentinel-wrapped machine-readable block
-- (`||...||`), gag that block from screen, render its contents to a
-- 3-row HUD via Blightmud's `status_area`.
--
-- Once you have a CF character logged in, run `help prompt` to confirm
-- the % codes this MUD exposes, then in-game type:
--
--     setprompt
--
-- which sends:
--
--     prompt ||%h|%H|%m|%M|%v|%V|%x|%g|%w|%r||< %hhp %mm %vmv %xxp >
--
-- Ten pipe-separated fields wrapped in `||...||` for the parser, then
-- a clean visible `< NNhp NNm NNmv NNxp >` for the eye. Tune the field
-- list once `help prompt` confirms exactly which codes CF supports —
-- ROM-family codes vary between forks.
--
-- See .claude/skills/rich-cf/SKILL.md for the design + roadmap.
-- See refs/cf.md for game context.

local g_alias, g_trigger = game_groups("cf")

-- ─── login ────────────────────────────────────────────────────────
-- ROM-style two-step: "By what name do you wish to be known?" → password.
-- Twin line+prompt triggers on `[Pp]assword[: ]` with a one-shot guard,
-- since different MUDs send prompts with or without trailing newlines.
g_alias:add("^login$", function()
    local user, pass = creds("cf")
    if not user or not pass then
        blight.output("[cf] no creds — set CF_USER + CF_PASS in .env.local")
        return
    end
    mud.send(user, { gag = true, skip_log = true })
    local sent = false
    local on_pass_prompt = function()
        if sent then
            return
        end
        sent = true
        mud.send(pass, { gag = true, skip_log = true })
        mud.send("", { gag = true, skip_log = true })
    end
    trigger.add("[Pp]assword[: ]", { count = 1, gag = true }, on_pass_prompt)
    trigger.add("[Pp]assword[: ]", { count = 1, gag = true, prompt = true }, on_pass_prompt)
end)

-- ─── conveniences ────────────────────────────────────────────────
g_alias:add("^gn$", function() mud.send("get all corpse") end)
g_alias:add("^sc$", function() mud.send("score") end)
g_alias:add("^eq$", function() mud.send("equipment") end)
g_alias:add("^inv$", function() mud.send("inventory") end)

-- ─── auto-survival (edge-detected, off by default) ─────────────────
-- Modeled after cod.lua's survival, but defaults to OFF since CF
-- prompt-code semantics aren't yet confirmed — we don't yet know
-- exactly which token CF emits for "hungry" / "thirsty" status,
-- nor whether the trigger surface (visible prompt vs custom flag)
-- exposes them. Once we have a CF char and have observed the actual
-- output, set survival on with `survival on` and tune the patterns.
--
-- Food + drink preferences persist to disk so they survive restarts.

local CF_SURVIVAL_KEY = "cf_survival" -- store key: "<food>|<drink>"

local function cf_load_survival_prefs()
    local raw = store.disk_read(CF_SURVIVAL_KEY) or ""
    local food, drink = raw:match("^(.-)|(.*)$")
    return (food and food ~= "" and food) or "ration", (drink and drink ~= "" and drink) or "water"
end

local function cf_save_survival_prefs(s)
    store.disk_write(CF_SURVIVAL_KEY, s.food .. "|" .. s.drink)
end

local cf_food0, cf_drink0 = cf_load_survival_prefs()
local cf_survival = {
    enabled = false, -- OFF by default — enable with `survival on` once verified
    food = cf_food0,
    drink = cf_drink0,
    hungry = false,
    thirsty = false,
}

-- Watch every prompt line for HUNGER/THIRST tokens (case-insensitive
-- substring). CF may emit different exact wording — adjust the
-- needles below once observed in live play.
g_trigger:add(".+", { prompt = true }, function(_, line)
    if not cf_survival.enabled then
        return
    end
    local text = line:line()

    local has_hunger = text:find("HUNGER", 1, true) ~= nil or text:find("Hungry", 1, true) ~= nil
    if has_hunger and not cf_survival.hungry then
        cf_survival.hungry = true
        mud.send("eat " .. cf_survival.food, { gag = true })
    elseif not has_hunger then
        cf_survival.hungry = false
    end

    local has_thirst = text:find("THIRST", 1, true) ~= nil or text:find("Thirsty", 1, true) ~= nil
    if has_thirst and not cf_survival.thirsty then
        cf_survival.thirsty = true
        mud.send("drink " .. cf_survival.drink, { gag = true })
    elseif not has_thirst then
        cf_survival.thirsty = false
    end
end)

g_alias:add("^survival$", function()
    blight.output(string.format(
        "[survival] enabled=%s  food=%q  drink=%q  hungry=%s  thirsty=%s",
        tostring(cf_survival.enabled), cf_survival.food, cf_survival.drink,
        tostring(cf_survival.hungry), tostring(cf_survival.thirsty)))
end)
g_alias:add("^survival (on|off)$", function(m)
    cf_survival.enabled = (m[2] == "on")
    cf_survival.hungry, cf_survival.thirsty = false, false
    blight.output("[survival] " .. (cf_survival.enabled and "ENABLED" or "DISABLED"))
end)
g_alias:add("^survival food (.+)$", function(m)
    cf_survival.food = m[2]
    cf_save_survival_prefs(cf_survival)
    blight.output("[survival] food = " .. m[2] .. " (saved)")
end)
g_alias:add("^survival drink (.+)$", function(m)
    cf_survival.drink = m[2]
    cf_save_survival_prefs(cf_survival)
    blight.output("[survival] drink = " .. m[2] .. " (saved)")
end)

-- ─── rich HUD (status_area, prompt-driven, invisible-block) ────────
-- See .claude/skills/rich-cf/SKILL.md "fundamental design" section.
-- The prompt we ship has TWO segments:
--
--   * Invisible machine block, anchored at start, sentinel-wrapped:
--       ||%h|%H|%m|%M|%v|%V|%x|%g|%w|%r||
--     10 pipe-separated fields. Captured by a trigger anchored at `^`
--     and `gag = true` so the block never reaches the screen.
--
--   * Visible part, after the machine block:
--       < %hhp %mm %vmv %xxp >
--     What the user actually reads when looking at the prompt line
--     (also visible in the HUD's bars, but readable in scrollback).
--
-- Field index → meaning:
--   1 %h   current HP
--   2 %H   max HP
--   3 %m   current mana
--   4 %M   max mana
--   5 %v   current move
--   6 %V   max move
--   7 %x   current XP (or XP-to-next; CF-specific — verify with `help prompt`)
--   8 %g   gold
--   9 %w   wait state / lag (combat tick countdown)
--  10 %r   room name

local CF_HUD_PROMPT = "||%h|%H|%m|%M|%v|%V|%x|%g|%w|%r||< %hhp %mm %vmv %xxp >"

g_alias:add("^setprompt$", function()
    mud.send("prompt " .. CF_HUD_PROMPT)
    blight.output("[cf] prompt set to HUD format — bottom bar should populate after next action")
end)

-- Colored ASCII bar. Green >=66%, yellow 33-66%, red <33%.
-- The trailing reset is critical so the rest of the status line
-- doesn't inherit the color.
local function cf_bar(cur, max, width)
    if not max or max == 0 then
        return string.rep(" ", width)
    end
    local pct = cur / max
    local filled = math.floor(pct * width + 0.5)
    if filled > width then
        filled = width
    end
    if filled < 0 then
        filled = 0
    end
    local color
    if pct >= 0.66 then
        color = "\27[32m"
    elseif pct >= 0.33 then
        color = "\27[33m"
    else
        color = "\27[31m"
    end
    return color .. string.rep("=", filled) .. string.rep(" ", width - filled) .. "\27[0m"
end

-- Wait-state colorizer. CF's %w is the lag tick countdown; 0 = action
-- ready (green bold), >0 = recovering (yellow dim).
local function cf_wait_display(wait_str)
    local n = tonumber(wait_str)
    if not n or n == 0 then
        return "\27[1;32mREADY\27[0m"
    elseif n <= 2 then
        return "\27[33mw:" .. wait_str .. "\27[0m"
    else
        return "\27[2;33mw:" .. wait_str .. "\27[0m"
    end
end

local function cf_hud_render(hp, hpmax, mp, mpmax, mv, mvmax, xp, gold, wait, room)
    blight.status_height(3)
    blight.status_line(0, string.format(
        "HP [%s] %d/%d   MN [%s] %d/%d   MV [%s] %d/%d",
        cf_bar(hp, hpmax, 16), hp, hpmax,
        cf_bar(mp, mpmax, 16), mp, mpmax,
        cf_bar(mv, mvmax, 16), mv, mvmax))
    blight.status_line(1, string.format(
        "XP: %s   Gold: %s   %s",
        xp or "?", gold or "?", cf_wait_display(wait)))
    blight.status_line(2, "Room: " .. (room or ""))
end

-- Regex for the invisible block. Anchored at `^`, captures the 10
-- pipe-separated fields, then allows the visible suffix to follow.
-- Each field is `[^|]+` (non-pipe run) so we don't have to know
-- which fields are numeric vs string up front.
local cf_hud_re =
    "^\\|\\|([^|]+)\\|([^|]+)\\|([^|]+)\\|([^|]+)\\|([^|]+)\\|([^|]+)\\|([^|]+)\\|([^|]+)\\|([^|]+)\\|([^|]+)\\|\\|"

local cf_hud_cb = function(m)
    cf_hud_render(
        tonumber(m[2]), tonumber(m[3]), -- hp cur/max
        tonumber(m[4]), tonumber(m[5]), -- mp cur/max
        tonumber(m[6]), tonumber(m[7]), -- mv cur/max
        m[8], -- xp
        m[9], -- gold
        m[10], -- wait
        m[11] -- room
    )
end

-- Register both line+prompt variants with `gag = true` so the
-- sentinel-wrapped machine block never lands on screen. The visible
-- `< NNhp ... >` suffix lives on the same line, so it will also be
-- gagged by `gag = true` (it covers the whole line). That's
-- intentional — the HUD shows the same info more richly. Toggle
-- with `hud off` to restore raw prompt visibility.
g_trigger:add(cf_hud_re, { prompt = true, gag = true }, cf_hud_cb)
g_trigger:add(cf_hud_re, { gag = true }, cf_hud_cb)

g_alias:add("^hud (on|off)$", function(m)
    if m[2] == "off" then
        blight.status_height(0)
        blight.output("[cf] HUD hidden (raw prompt still gagged — type `prompt default` in-game to restore)")
    else
        blight.status_height(3)
        blight.output("[cf] HUD enabled (will populate on next prompt)")
    end
end)

blight.output("[cf] loaded — type `login` at the welcome screen")
blight.output("[cf] after login, run `setprompt` to install the HUD prompt:")
blight.output("[cf]   prompt ||%h|%H|%m|%M|%v|%V|%x|%g|%w|%r||< %hhp %mm %vmv %xxp >")
blight.output("[cf] verify codes with in-game `help prompt`; tune CF_HUD_PROMPT if any are unsupported")
blight.output("[cf] `survival on` enables auto-eat/drink (OFF by default — verify prompt codes first)")
