-- Discworld MUD (discworld.starturtle.net:4242)
-- Pratchett-themed LPMud. 7 guilds, over a million rooms.
-- NOTE: port 4242 (not the default 23). atuin.net is an alias.

local g_alias, g_trigger = game_groups("dw")

-- ─── login ────────────────────────────────────────────────────────
-- DW shows a menu: Q/M/D/R/U/L/P/F/N/G OR type your character name.
-- For an existing character, just send the name; password prompt follows.
g_alias:add("^login$", function()
    local user, pass = creds("dw")
    if not user or not pass then
        blight.output("[dw] no creds — set DW_USER + DW_PASS in .env.local")
        return
    end
    mud.send(user, { gag = true, skip_log = true })
    local sent = false
    local on_pass_prompt = function()
        if sent then return end
        sent = true
        mud.send(pass, { gag = true, skip_log = true })
        mud.send("", { gag = true, skip_log = true })
    end
    trigger.add("[Pp]assword[: ]", { count = 1, gag = true }, on_pass_prompt)
    trigger.add("[Pp]assword[: ]", { count = 1, gag = true, prompt = true }, on_pass_prompt)
end)

-- ─── conveniences ────────────────────────────────────────────────
g_alias:add("^gn$", function() mud.send("get all from corpse") end)

g_trigger:add("HP:(\\d+)/\\d+", { prompt = true }, function(matches)
    local hp = tonumber(matches[2])
    if hp and hp < 50 then blight.output("[!] low hp: " .. hp) end
end)

-- ─── Quow's Cow Bar: item/NPC/place lookup ─────────────────────────
-- Quow's Cow Bar (https://quow.co.uk/cow.php) is the canonical item /
-- NPC / location DB for DW. Query shape: ?s=<term>&t=Items|NPCs|Places.
-- Random-color items: search the colorless root (e.g. `silk trousers`
-- not `black silk trousers`) — Quow lists them as `[colour] silk trousers`.
--
-- Usage:
--   q  <term>   — search items
--   qn <term>   — search NPCs
--   qp <term>   — search places

local function quow_url(query, qtype)
    local enc = query:gsub("[^%w%s'-]", ""):gsub("%s+", "+")
    return string.format("https://quow.co.uk/cow.php?s=%s&t=%s", enc, qtype)
end

local function quow_search(query, qtype)
    local url = quow_url(query, qtype)
    blight.output("[quow:" .. qtype .. "] " .. query)
    blight.output("       " .. url)
    -- Parse Quow's results-table rows. Each result row has the shape:
    --   <tr><td>N:</td><td><a ...>Name</a></td><td>:</td>
    --   <td>Weight</td><td>Value</td><td>:</td><td>...details link...</td></tr>
    -- We pull out N, Name, Weight, Value, then format for the screen.
    local cmd = string.format("curl -sL --max-time 8 %q 2>/dev/null", url)
    local f = io.popen(cmd)
    if not f then return end
    local html = f:read("*a") or ""
    f:close()

    -- Did the query match anything?
    if html:find("Your search string is too short") then
        blight.output("  (Quow says: search string too short)")
        return
    end
    local results = html:match("([^>]+) Results for '[^']*':") or ""
    if html:find("Result for '") and not html:find("Results for '") then
        results = "(single result)"
    end

    local count = 0
    -- Strip newlines so the row regex matches across the source.
    local flat = html:gsub("[\n\r]", " ")
    for row in flat:gmatch("<tr[^>]*>(.-)</tr>") do
        local idx = row:match("(%d+):")
        local name = row:match('<a href="cow%.php[^"]*">([^<]+)</a>')
        local weight = row:match(">%s*([%d/%s]+%s*lb)%s*<")
        local value = row:match(">%s*(A%$[%d.,]+)%s*<")
        if idx and name and not name:match("^Item Details$") then
            count = count + 1
            local line = string.format("%3s. %s", idx, name)
            if weight and value then
                line = line .. string.format("  (%s, %s)", weight, value)
            elseif value then
                line = line .. string.format("  (%s)", value)
            end
            blight.output(line)
            if count >= 15 then
                blight.output("  ... (truncated; open URL for full list)")
                break
            end
        end
    end

    if count == 0 then
        -- Maybe NPC or place — different row shape
        for row in flat:gmatch("<tr[^>]*>(.-)</tr>") do
            local idx = row:match("(%d+):")
            local name = row:match('<a href="cow%.php[^"]*">([^<]+)</a>')
            if idx and name and not name:match("Details$") then
                count = count + 1
                blight.output(string.format("%3s. %s", idx, name))
                if count >= 15 then
                    blight.output("  ... (truncated; open URL for full list)")
                    break
                end
            end
        end
    end

    if count == 0 then
        -- Last-ditch fallback: shell-strip HTML + surface first 25 visible
        -- lines. Matches the implementation hint in the rich-dw skill —
        -- useful when Quow changes its table markup and the row-parser
        -- above stops matching. We don't recompute the html locally here
        -- (cheaper to pipe through sed once on the already-fetched body).
        blight.output("  (no structured matches — falling back to raw strip)")
        local fb_cmd = string.format(
            "curl -sL --max-time 8 %q 2>/dev/null "
            .. "| sed 's/<[^>]*>//g' "
            .. "| grep -v '^[[:space:]]*$' "
            .. "| head -25",
            url)
        local fh = io.popen(fb_cmd)
        if fh then
            for line in fh:lines() do
                blight.output("  " .. line)
            end
            fh:close()
        end
    else
        local total = flat:match("%[(%d+) total results%]") or tostring(count)
        blight.output(string.format("  [%s match%s]", total, total == "1" and "" or "es"))
    end
end

g_alias:add("^q (.+)$", function(m) quow_search(m[2], "Items") end)
g_alias:add("^qn (.+)$", function(m) quow_search(m[2], "NPCs") end)
g_alias:add("^qp (.+)$", function(m) quow_search(m[2], "Places") end)

-- ─── Daftjunk: region maps ─────────────────────────────────────────
-- Print the Daftjunk hand-drawn map URL for a region. Use names like
-- `Ankh-Morpork`, `Sto_Lat`, `Klatch`, `Ramtops`, `Counterweight`,
-- `Genua`, etc. (underscores for multi-word). Terminal can't render
-- the PNG, but the URL is one click in a browser. We also cache the
-- PNG locally for convenience.
--
-- Usage:
--   map <Region>

local function dw_map_url(region)
    -- Spaces → underscores so `map Ankh Morpork` resolves to the
    -- canonical `Ankh-Morpork.png`-style filename. User can still
    -- type underscores or hyphens explicitly.
    local clean = region:gsub("%s+", "_")
    return string.format("https://dw.daftjunk.com/%s.png", clean), clean
end

g_alias:add("^map (.+)$", function(m)
    local url, region = dw_map_url(m[2])
    blight.output("[daftjunk] map: " .. url)
    -- Cache to ~/.local/share/blightmud/dw-maps/ for browser access.
    -- Background curl: we don't block the input pane on a slow fetch.
    local home = os.getenv("HOME") or "/tmp"
    local dir = home .. "/.local/share/blightmud/dw-maps"
    os.execute("mkdir -p '" .. dir .. "'")
    local out = dir .. "/" .. region .. ".png"
    os.execute(string.format(
        "curl -sL --max-time 10 -o %q %q 2>/dev/null &", out, url))
    blight.output("       cached to " .. out)
end)

-- ─── Bonuses: stat calculator ──────────────────────────────────────
g_alias:add("^bonus$", function()
    blight.output("[bonuses] http://bonuses.irreducible.org/")
end)

-- ─── Wiki + atlas shortcuts ────────────────────────────────────────
g_alias:add("^wiki (.+)$", function(m)
    local term = m[2]:gsub("%s+", "_")
    blight.output(string.format(
        "[dwwiki] https://dwwiki.mooo.com/wiki/Special:Search?search=%s",
        m[2]:gsub("%s+", "+")))
    blight.output(string.format(
        "         https://dwwiki.mooo.com/wiki/%s", term))
end)

-- ─── GMCP Phase 1: register + echo ─────────────────────────────────
-- DW advertises GMCP on the connect banner. Register the core packages
-- on gmcp.on_ready and surface every received packet as a `[gmcp dw]`-
-- prefixed line. NO HUD yet (no character to test against) — Phase 2
-- (Char.Vitals → HP/MP/MV bar) and Phase 3 (Room.Info → Room row) wait
-- on `blightmud-nk5` (DW character onboarding).
--
-- Tolerance contract: every `gmcp.receive` handler wraps `json.decode`
-- in pcall so a malformed packet doesn't crash the script. Missing
-- fields are surfaced verbatim — we want to SEE what DW actually sends
-- before designing the HUD against it.

local DW_GMCP_PACKAGES = {
    "Char.Vitals",
    "Char.Status",
    "Char.StatusVars",
    "Room.Info",
    "Comm.Channel.Text",
}

-- Helper: echo a raw GMCP packet with the `[gmcp dw]` prefix. We
-- attempt a json.decode for pretty-printing but fall back to the
-- raw string on parse failure (the implementation contract says
-- "bail silently" — here that means "still surface the raw data
-- so the operator sees something", just without trying to walk
-- a busted object).
local function dw_gmcp_echo(pkg, data)
    local ok, obj = pcall(json.decode, data)
    if ok and type(obj) == "table" then
        -- Re-encode in a stable form for readability. json.encode is
        -- the inverse of json.decode in rxi/json.lua — round-trips
        -- cleanly. If encode itself fails we fall back to the raw
        -- string.
        local enc_ok, enc = pcall(json.encode, obj)
        if enc_ok then
            blight.output(string.format("[gmcp dw] %s %s", pkg, enc))
            return
        end
    end
    -- pcall returned not-ok, or the value wasn't a table, or encode
    -- failed. Surface the raw payload — never crash the listener.
    blight.output(string.format("[gmcp dw] %s (raw) %s", pkg, tostring(data)))
end

if gmcp and gmcp.on_ready then
    gmcp.on_ready(function()
        for _, pkg in ipairs(DW_GMCP_PACKAGES) do
            if gmcp.register then pcall(gmcp.register, pkg) end
        end
        blight.output("[dw] GMCP registered: "
            .. table.concat(DW_GMCP_PACKAGES, ", "))
    end)
end

-- Receive handlers — each just echoes. When a DW character exists we
-- replace these with HUD updaters (Phase 2/3 in rich-dw SKILL.md).
if gmcp and gmcp.receive then
    for _, pkg in ipairs(DW_GMCP_PACKAGES) do
        local p = pkg  -- capture for closure
        pcall(gmcp.receive, p, function(data)
            -- Tolerance: don't crash on malformed JSON or missing fields.
            -- The whole handler is also wrapped in pcall when invoked
            -- from native code, but belt-and-suspenders never hurts.
            local ok, err = pcall(dw_gmcp_echo, p, data)
            if not ok then
                -- Bail silently per the Phase 1 contract — but log a
                -- one-line hint so we can debug if echo itself breaks.
                blight.output("[dw] gmcp echo failed for " .. p .. ": " .. tostring(err))
            end
        end)
    end
end

-- ─── Phase 1 stub: region transition auto-map (commented out) ──────
-- Once a character exists and Room.Info packets are flowing, this
-- handler will detect region transitions (Ankh-Morpork → Sto Lat,
-- Klatch → Ramtops, …) and auto-print the Daftjunk map URL for the
-- new region. The check is "did the area/region field change since
-- the last packet?" — that field is one of `area`, `region`, or
-- nested in `coords` depending on DW's exact schema. We can't pin
-- the field name without a live character, so this stays commented
-- until `blightmud-nk5` resolves.
--
-- local dw_last_region = nil
-- if gmcp and gmcp.receive then
--     pcall(gmcp.receive, "Room.Info", function(data)
--         local ok, obj = pcall(json.decode, data)
--         if not ok or type(obj) ~= "table" then return end
--         -- TODO: pick the right field — likely obj.area or obj.region.
--         local region = obj.area or obj.region or (obj.coords and obj.coords.area)
--         if region and region ~= dw_last_region then
--             dw_last_region = region
--             local url, clean = dw_map_url(region)
--             blight.output("[dw] entered region: " .. region)
--             blight.output("     daftjunk map:  " .. url)
--             -- Background-cache the PNG too (same pattern as `map` alias).
--             local home = os.getenv("HOME") or "/tmp"
--             local dir = home .. "/.local/share/blightmud/dw-maps"
--             os.execute("mkdir -p '" .. dir .. "'")
--             local out = dir .. "/" .. clean .. ".png"
--             os.execute(string.format(
--                 "curl -sL --max-time 10 -o %q %q 2>/dev/null &", out, url))
--         end
--     end)
-- end

blight.output("[dw] loaded — type `login` at the menu (port 4242, NOT 23)")
blight.output("[dw] tools: q <item>, qn <npc>, qp <place>, map <region>, wiki <term>, bonus")
blight.output("[dw] gmcp: echoing Char.Vitals/Status/StatusVars + Room.Info + Comm.Channel.Text (Phase 1)")
