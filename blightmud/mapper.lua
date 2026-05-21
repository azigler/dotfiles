-- mapper.lua — Blightmud room-graph mapper, v2.
-- Ported from CleftMUSH's cleftmapper.lua (Nick Gammon, Fiendish, Asmodeus)
-- with all MUSHclient GUI/draw code removed. Data layer + speedwalk only.
--
-- v2 schema: rooms keyed by (title, exits_signature), not title alone.
-- CoD has many rooms sharing titles (4× "Truce - Leene Square" etc.);
-- title-only keying collapsed them into one entry with merged edges and
-- broke speedwalk. v2 distinguishes physical rooms by the exits string,
-- which differs even when titles match.
--
-- Disk-store key bumped to `mapper2_<name>` so old v1 data is orphaned
-- (not migrated — schema diff is structural). Re-walking populates fresh.
--
-- Usage from a per-game .lua:
--   local m = mapper_new("cod")
--   m.note_room(title, exits_string)   -- after each (] Exits: ... [)
--   m.note_move(direction)             -- after user sends n/s/e/w/u/d
--   m.go(target_title_or_substring)    -- speedwalk to a known room
--   m.cancel_move()                    -- on "can't go that way"
--   m.show() / m.where() / m.find() / m.same_zone() / m.zones() / m.render() / m.clear()

-- ─── singleton registry (one mapper per game name) ─────────────────

_G.bm_mappers = _G.bm_mappers or {}

-- Always build a fresh instance — disk persistence handles continuity.
-- In-memory `current` rebuilds on next note_room() after a fresh load.
function mapper_new(name)
    local self = {
        name = name,
        rooms = {},           -- [key] = { title, exits, edges = { dir = key } }
        current = nil,        -- key of the room the player is in
        last_dir = nil,       -- last direction the user sent
        store_key = "mapper2_" .. name,  -- v2 schema (was "mapper_")
        fuzzy_max = 3,        -- default Levenshtein distance threshold
    }

    -- ─── key encoding ────────────────────────────────────────────
    -- The KEY distinguishes physical rooms by (title, exits). Pipe
    -- is the separator because CoD room titles + exits use letters,
    -- spaces, dashes, commas, parens — never pipes.
    local function room_key(title, exits)
        return (title or "") .. "|" .. (exits or "")
    end

    local function key_title(key)
        return (key or ""):match("^([^|]*)") or ""
    end

    -- ─── zone parsing ────────────────────────────────────────────
    -- CoD titles often follow `Zone, Sub-Zone - Room` (e.g.,
    -- `Free City, Truce - Fountain`) or `Zone - Room` (e.g.,
    -- `Sulfataska Mountains - Trail`). We split on the FIRST ` - `
    -- (space-dash-space) so a title like `Free City, Truce - Fountain`
    -- yields zone=`Free City, Truce` (the comma is part of the zone
    -- name, not a sub-split). Titles without ` - ` are zone-less —
    -- they get the whole title as both zone and room so they only
    -- match themselves under current-zone filtering.
    local function parse_zone(title)
        if not title or title == "" then return "", "" end
        local zone, room = title:match("^(.-)%s%-%s(.+)$")
        if zone and room then return zone, room end
        return title, title
    end

    local function zone_of(title)
        local z, _ = parse_zone(title)
        return z
    end

    -- ─── Levenshtein distance (iterative DP) ─────────────────────
    -- Hand-rolled because Lua has no built-in. Uses two-row rolling
    -- buffer for O(min(m,n)) extra space. Early-out if min row >
    -- threshold (we don't need exact distance beyond fuzzy_max).
    local function levenshtein(a, b, threshold)
        if a == b then return 0 end
        local la, lb = #a, #b
        if la == 0 then return lb end
        if lb == 0 then return la end
        if math.abs(la - lb) > threshold then
            -- Can't possibly be within threshold (each extra char
            -- costs at least 1 insert/delete).
            return threshold + 1
        end
        -- Make `a` the shorter string to minimize row width.
        if la > lb then a, b, la, lb = b, a, lb, la end
        local prev, curr = {}, {}
        for j = 0, la do prev[j] = j end
        for i = 1, lb do
            curr[0] = i
            local bi = b:sub(i, i)
            local row_min = curr[0]
            for j = 1, la do
                local cost = (a:sub(j, j) == bi) and 0 or 1
                local del  = prev[j] + 1
                local ins  = curr[j - 1] + 1
                local sub  = prev[j - 1] + cost
                local v = del
                if ins < v then v = ins end
                if sub < v then v = sub end
                curr[j] = v
                if v < row_min then row_min = v end
            end
            -- Early-out: if EVERY value in this row exceeds the
            -- threshold, the final answer can only grow from here.
            if row_min > threshold then return threshold + 1 end
            prev, curr = curr, prev
        end
        return prev[la]
    end

    -- ─── persistence ─────────────────────────────────────────────
    -- Disk format (tab-separated; keys appear verbatim, contain pipes):
    --   ROOM\t<title>\t<exits>           -- the canonical room entry
    --   EDGE\t<from_key>\t<dir>\t<to_key>  -- key includes title|exits
    -- Reads handle malformed lines silently.

    local function save()
        local buf = {}
        for key, r in pairs(self.rooms) do
            table.insert(buf, "ROOM\t" .. (r.title or "") .. "\t" .. (r.exits or ""))
            for dir, dest_key in pairs(r.edges or {}) do
                table.insert(buf, "EDGE\t" .. key .. "\t" .. dir .. "\t" .. dest_key)
            end
        end
        store.disk_write(self.store_key, table.concat(buf, "\n"))
    end

    local function load()
        local raw = store.disk_read(self.store_key)
        if not raw or raw == "" then return end
        for line in raw:gmatch("[^\n]+") do
            local parts = {}
            for f in line:gmatch("[^\t]*") do table.insert(parts, f) end
            local kind = parts[1]
            if kind == "ROOM" then
                local title = parts[2] or ""
                local exits = parts[3] or ""
                local key = room_key(title, exits)
                self.rooms[key] = self.rooms[key] or { title = title, exits = exits, edges = {} }
                self.rooms[key].title = title
                self.rooms[key].exits = exits
            elseif kind == "EDGE" then
                local from_key = parts[2] or ""
                local dir = parts[3] or ""
                local to_key = parts[4] or ""
                if from_key ~= "" and dir ~= "" and to_key ~= "" then
                    self.rooms[from_key] = self.rooms[from_key]
                        or { title = key_title(from_key), exits = "", edges = {} }
                    self.rooms[from_key].edges = self.rooms[from_key].edges or {}
                    self.rooms[from_key].edges[dir] = to_key
                end
            end
        end
    end

    load()

    -- ─── direction reversal table ────────────────────────────────
    local REVERSE = {
        north="south", south="north", east="west", west="east",
        up="down", down="up",
        northeast="southwest", southwest="northeast",
        northwest="southeast", southeast="northwest",
    }

    -- ─── learn ───────────────────────────────────────────────────

    -- Cancel a pending movement intent (call on "can't go that way").
    function self.cancel_move()
        self.last_dir = nil
    end

    -- Note that the user just sent a direction. Doesn't actually move
    -- — just records intent so the NEXT note_room() can finalize edge.
    function self.note_move(direction)
        local short_dirs = {
            n = "north", s = "south", e = "east", w = "west",
            u = "up", d = "down",
            ne = "northeast", nw = "northwest",
            se = "southeast", sw = "southwest",
            north = "north", south = "south", east = "east", west = "west",
            up = "up", down = "down",
            northeast = "northeast", northwest = "northwest",
            southeast = "southeast", southwest = "southwest",
        }
        self.last_dir = short_dirs[direction:lower()] or direction:lower()
    end

    -- Note the current room. If we just sent a movement (last_dir),
    -- record the edge from the previous room AND infer a reverse.
    -- Keying by (title, exits) means rooms with identical titles but
    -- different exits stay distinct.
    function self.note_room(title, exits)
        if not title or title == "" then return end
        local key = room_key(title, exits)
        self.rooms[key] = self.rooms[key]
            or { title = title, exits = exits or "", edges = {} }
        self.rooms[key].title = title
        self.rooms[key].exits = exits or self.rooms[key].exits

        if self.current and self.last_dir and self.current ~= key then
            local from = self.rooms[self.current]
            if from then
                from.edges = from.edges or {}
                from.edges[self.last_dir] = key
            end
            local rev = REVERSE[self.last_dir]
            if rev then
                local here = self.rooms[key]
                here.edges = here.edges or {}
                if not here.edges[rev] then
                    here.edges[rev] = self.current
                end
            end
        end
        self.current = key
        self.last_dir = nil
        save()
        if self.dump_path then pcall(self.dump, self.dump_path) end
    end

    -- ─── pathfind ────────────────────────────────────────────────

    -- BFS from current key to target key. Returns list of dirs, or nil.
    function self.find_path(target_key)
        if not self.current or not self.rooms[target_key] then return nil end
        if self.current == target_key then return {} end
        local visited = { [self.current] = true }
        local queue = { { key = self.current, path = {} } }
        while #queue > 0 do
            local node = table.remove(queue, 1)
            local r = self.rooms[node.key]
            if r and r.edges then
                for dir, dest in pairs(r.edges) do
                    if not visited[dest] then
                        visited[dest] = true
                        local newpath = {}
                        for _, d in ipairs(node.path) do table.insert(newpath, d) end
                        table.insert(newpath, dir)
                        if dest == target_key then return newpath end
                        table.insert(queue, { key = dest, path = newpath })
                    end
                end
            end
        end
        return nil
    end

    -- ─── resolution ──────────────────────────────────────────────
    --
    -- Resolve a target string to a KEY. Priority order:
    --   (1)  Exact title match (case-sensitive)
    --   (2)  Exact title match within current zone (case-insensitive)
    --   (3)  Case-insensitive exact title across all zones
    --   (4)  Substring match within current zone
    --   (5)  Substring match across all zones
    --   (6)  All-words match (every input word appears somewhere)
    --   (7)  Levenshtein fuzzy (distance ≤ fuzzy_max, default 3)
    --
    -- Within each bucket, if more than one candidate qualifies we
    -- prefer the one with the SHORTEST BFS path from current; if no
    -- candidate has a path, the bucket returns ("ambiguous", list).
    --
    -- Note on priority change vs v2-prior: exact-title now ALWAYS
    -- wins over substring, even if the exact-title room has no
    -- shorter path than a substring candidate. This fixes the
    -- 2026-05-18 mis-route where `mp go border gate` matched
    -- "Peaceful Fields of Guardia" via an incidental substring
    -- instead of "Sulfataska Border Gate" (exact match).
    function self.resolve(target)
        if not target or target == "" then return nil end
        local lneedle = target:lower()
        local words = {}
        for w in lneedle:gmatch("%S+") do table.insert(words, w) end

        local current_zone = nil
        if self.current and self.rooms[self.current] then
            current_zone = zone_of(self.rooms[self.current].title or "")
        end

        -- Bucket keys by match quality (lowest = best).
        --   1: exact (case-sensitive)
        --   2: exact case-insensitive within current zone
        --   3: exact case-insensitive across all zones
        --   4: substring within current zone
        --   5: substring across all zones
        --   6: all-words match (across all zones)
        --   7: Levenshtein fuzzy
        local buckets = { {}, {}, {}, {}, {}, {}, {} }
        for key, r in pairs(self.rooms) do
            local title = r.title or key_title(key)
            local lt = title:lower()
            local tz = zone_of(title)
            local in_zone = (current_zone and tz == current_zone)

            if title == target then
                table.insert(buckets[1], key)
            elseif lt == lneedle and in_zone then
                table.insert(buckets[2], key)
            elseif lt == lneedle then
                table.insert(buckets[3], key)
            elseif lt:find(lneedle, 1, true) and in_zone then
                table.insert(buckets[4], key)
            elseif lt:find(lneedle, 1, true) then
                table.insert(buckets[5], key)
            elseif #words > 1 then
                local all = true
                for _, w in ipairs(words) do
                    if not lt:find(w, 1, true) then all = false; break end
                end
                if all then table.insert(buckets[6], key) end
            end
        end

        -- Fuzzy bucket (only populated if all earlier buckets are
        -- empty — Levenshtein over every known title is expensive
        -- enough we skip it when something already matched).
        local any_hit = false
        for i = 1, 6 do
            if #buckets[i] > 0 then any_hit = true; break end
        end
        if not any_hit then
            local best, best_d = nil, self.fuzzy_max + 1
            local tied = {}
            for key, r in pairs(self.rooms) do
                local lt = (r.title or key_title(key)):lower()
                local d = levenshtein(lt, lneedle, self.fuzzy_max)
                if d <= self.fuzzy_max then
                    if d < best_d then
                        best, best_d = key, d
                        tied = { key }
                    elseif d == best_d then
                        table.insert(tied, key)
                    end
                end
            end
            buckets[7] = tied
        end

        local function pick(bucket)
            if #bucket == 1 then return bucket[1] end
            if not self.current then return "ambiguous", bucket end
            local best_key, best_len = nil, math.huge
            for _, k in ipairs(bucket) do
                local path = self.find_path(k)
                if path and #path < best_len then
                    best_key, best_len = k, #path
                end
            end
            if best_key then return best_key end
            return "ambiguous", bucket
        end

        for _, bucket in ipairs(buckets) do
            if #bucket > 0 then
                local r, c = pick(bucket)
                return r, c
            end
        end
        return nil
    end

    -- ─── speedwalk abort plumbing ────────────────────────────────
    -- A speedwalk lasts a few hundred ms per step. The server may
    -- reject a step ("You almost go se, but suddenly realize that
    -- there's no exit there.") mid-walk. Without an abort, the
    -- queued remaining steps keep firing into stale rooms and the
    -- player ends up far from the planned path. We solve this by:
    --   1. tagging each scheduled timer with the walk's generation
    --      ID; the timer no-ops if the generation has been cancelled
    --   2. registering per-walk one-shot triggers for the known
    --      movement-failure messages — first one to fire calls
    --      cancel_walk(reason) which bumps the generation
    -- The triggers are count=1 so each self-removes after firing;
    -- any that never fire are removed by the "drain" timer queued
    -- at walk-end so they don't accumulate across walks.
    self.walk_gen = self.walk_gen or 0
    self.walk_active = false

    -- Cancel any in-flight speedwalk. Safe to call when no walk is
    -- active (no-op). `reason` is shown in the abort message.
    function self.cancel_walk(reason)
        if not self.walk_active then return end
        self.walk_active = false
        self.walk_gen = self.walk_gen + 1  -- invalidates pending timer cbs
        self.last_dir = nil                 -- the failed step left it stale
        blight.output("[mapper:" .. self.name .. "] walk aborted: "
            .. (reason or "unknown"))
    end

    -- Speedwalk to a known room. Accepts exact title or substring.
    -- Aborts the remaining path on movement-failure messages
    -- (no-exit-there / door closed / drunken wall slam / too dark /
    -- "cannot go that way" / "can't go that way").
    function self.go(target_title, pause)
        -- If a previous walk is somehow still active, hard-reset it
        -- before starting the new one. The generation bump
        -- invalidates any lingering scheduled callbacks.
        if self.walk_active then
            self.walk_active = false
            self.walk_gen = self.walk_gen + 1
        end

        local resolved, candidates = self.resolve(target_title)
        if resolved == "ambiguous" then
            blight.output("[mapper:" .. self.name .. "] '" .. target_title
                .. "' is ambiguous and no candidates are reachable. Candidates:")
            for _, k in ipairs(candidates) do
                local r = self.rooms[k]
                blight.output("  " .. (r and r.title or k) .. "  (exits: " .. (r and r.exits or "?") .. ")")
            end
            return
        end
        if not resolved then
            blight.output("[mapper:" .. self.name .. "] no known room matching '"
                .. target_title .. "'. Try `mp find <substr>` or `mp` to list.")
            return
        end
        if resolved == self.current then
            local r = self.rooms[resolved]
            blight.output("[mapper:" .. self.name .. "] already at " .. (r and r.title or resolved))
            return
        end
        local path = self.find_path(resolved)
        if not path then
            local r = self.rooms[resolved]
            blight.output("[mapper:" .. self.name .. "] no path to "
                .. (r and r.title or resolved)
                .. " (walk part of the route to learn edges)")
            return
        end
        local r = self.rooms[resolved]
        blight.output("[mapper:" .. self.name .. "] going to '" .. (r and r.title or resolved)
            .. "' via " .. table.concat(path, ", ") .. " (" .. #path .. " steps)")

        -- Start a new walk generation. Every scheduled step captures
        -- `gen`; a cancel_walk bumps self.walk_gen, so all pending
        -- steps no-op cleanly without needing per-step timer.remove.
        self.walk_active = true
        self.walk_gen = self.walk_gen + 1
        local gen = self.walk_gen

        local trigger_ids = {}

        local function abort(reason)
            -- Only abort if this walk is still the current one. A
            -- stale trigger from a previous (drained-but-mid-flight)
            -- walk should never reach here, but guard anyway.
            if gen ~= self.walk_gen then return end
            self.cancel_walk(reason)
        end

        local function add_fail(pattern, reason_fn)
            local id = trigger.add(pattern, { count = 1 }, function(m)
                abort(reason_fn(m))
            end)
            table.insert(trigger_ids, id)
        end

        -- Movement-failure patterns observed live on CoD (bead
        -- blightmud-qa7 + episode 10 diary 2026-05-18). Patterns are
        -- regex (Rust regex engine — escape backslashes for Lua).
        add_fail("You almost go (\\S+), but suddenly realize that there's no exit there\\.",
            function(m) return "no exit " .. (m[2] or "?") end)
        add_fail("You almost go (\\S+), but suddenly realize that the door is closed\\.",
            function(m) return "door closed " .. (m[2] or "?") end)
        add_fail("You drunkenly slam face-first into the wall on your way (\\S+)\\.",
            function(m) return "drunk wall " .. (m[2] or "?") end)
        add_fail("It's too dark to see without a light\\.",
            function() return "too dark — need a light" end)
        add_fail("Alas, you cannot go that way",
            function() return "cannot go that way" end)
        add_fail("You can't go that way",
            function() return "can't go that way" end)

        local delay = pause or 0.5
        for i, dir in ipairs(path) do
            timer.add(delay * (i - 1), 1, function()
                -- Generation check: if cancel_walk fired (or another
                -- go() superseded us), bail without sending.
                if gen ~= self.walk_gen or not self.walk_active then
                    return
                end
                if self.name == "cod" or self.name == "cthulhumud" then
                    self.note_move(dir)
                end
                mud.send(dir)
            end)
        end

        -- Drain timer fires shortly after the last step. If the walk
        -- finished cleanly (no failure trigger fired), clear the
        -- still-armed failure triggers so they don't fire on a later
        -- unrelated movement failure. If the walk was already
        -- cancelled, the triggers that fired self-removed via
        -- count=1; remove the rest defensively.
        timer.add(delay * #path + 0.2, 1, function()
            if gen == self.walk_gen then
                self.walk_active = false
            end
            for _, tid in ipairs(trigger_ids) do
                pcall(trigger.remove, tid)
            end
        end)
    end

    -- ─── introspection ───────────────────────────────────────────

    function self.list_rooms()
        local titles = {}
        local seen = {}
        for _, r in pairs(self.rooms) do
            local t = r.title or "?"
            if not seen[t] then
                seen[t] = true
                table.insert(titles, t)
            end
        end
        table.sort(titles)
        return titles
    end

    function self.show(max)
        max = max or 30
        local keys = {}
        for k, _ in pairs(self.rooms) do table.insert(keys, k) end
        table.sort(keys, function(a, b)
            return (self.rooms[a].title or "") < (self.rooms[b].title or "")
        end)
        blight.output(string.format("[mapper:%s] %d physical rooms known. Current: %s",
            self.name, #keys,
            self.current and (self.rooms[self.current] and self.rooms[self.current].title or self.current)
                or "(unknown)"))
        for i, k in ipairs(keys) do
            if i > max then
                blight.output("  ... (" .. (#keys - max) .. " more)")
                break
            end
            local r = self.rooms[k]
            local edges = {}
            for d, _ in pairs(r.edges or {}) do table.insert(edges, d) end
            blight.output(string.format("  %s%s  [exits: %s]  [edges: %s]",
                (k == self.current) and "* " or "  ",
                r.title or "?",
                r.exits or "?",
                table.concat(edges, ", ")))
        end
    end

    function self.clear()
        self.rooms = {}
        self.current = nil
        self.last_dir = nil
        save()
        blight.output("[mapper:" .. self.name .. "] cleared")
    end

    function self.where()
        if not self.current then
            blight.output("[mapper:" .. self.name .. "] not in a known room yet")
            return
        end
        local r = self.rooms[self.current] or {}
        local edges = {}
        for d, _ in pairs(r.edges or {}) do table.insert(edges, d) end
        blight.output(string.format("[mapper:%s] * %s  [%d rooms | exits: %s | known: %s]",
            self.name, r.title or "?",
            #self.list_rooms(),
            r.exits or "?",
            table.concat(edges, ", ")))
    end

    function self.find(needle)
        if not needle or needle == "" then return self.list_rooms() end
        local lneedle = needle:lower()
        local hits = {}
        local seen = {}
        for _, r in pairs(self.rooms) do
            local t = r.title or "?"
            if t:lower():find(lneedle, 1, true) and not seen[t] then
                seen[t] = true
                table.insert(hits, t)
            end
        end
        table.sort(hits)
        return hits
    end

    -- List all distinct zones (parsed from titles via parse_zone)
    -- with the count of rooms in each. Sorted by room count desc
    -- so the busiest zones are at the top — useful when scoping a
    -- `mp go <substr>` to find a place you remember being big.
    function self.zones()
        local counts = {}
        local seen_room = {}    -- avoid double-counting (title,exits) variants
        for _, r in pairs(self.rooms) do
            local t = r.title or "?"
            if not seen_room[t] then
                seen_room[t] = true
                local z = zone_of(t)
                counts[z] = (counts[z] or 0) + 1
            end
        end
        local zones = {}
        for z, n in pairs(counts) do
            table.insert(zones, { zone = z, count = n })
        end
        table.sort(zones, function(a, b)
            if a.count == b.count then return a.zone < b.zone end
            return a.count > b.count
        end)
        return zones
    end

    -- ─── ASCII compass + dump (ANSI-colored) ─────────────────────

    local function color(code, text) return "\27[" .. code .. "m" .. text .. "\27[0m" end
    local CYAN_B  = function(t) return color("1;36", t) end
    local YELLOW_B= function(t) return color("1;33", t) end
    local GREEN   = function(t) return color("32",   t) end
    local CYAN    = function(t) return color("36",   t) end
    local DIM     = function(t) return color("2",    t) end
    local MAG     = function(t) return color("35",   t) end

    local function trim(text, width)
        text = tostring(text or "")
        if #text <= width then return text end
        return text:sub(1, width - 2) .. ".."
    end

    -- Look up a neighbor's display title given an edge destination key.
    local function neighbor_title(dest_key)
        local r = self.rooms[dest_key]
        return r and r.title or key_title(dest_key)
    end

    function self.render()
        if not self.current then
            blight.output("[mapper:" .. self.name .. "] not in a known room yet")
            return
        end
        local r = self.rooms[self.current] or {}
        local e = r.edges or {}

        local function cell(dest, width)
            if not dest then return string.rep(" ", width + 2) end
            local title = neighbor_title(dest)
            return "[" .. trim(title, width) .. string.rep(" ", math.max(0, width - #trim(title, width))) .. "]"
        end

        if e.north then
            blight.output("                 " .. cell(e.north, 28))
            blight.output("                          |")
        end
        local w_cell = cell(e.west, 14)
        local e_cell = cell(e.east, 14)
        local west_arrow = e.west and "<-" or "  "
        local east_arrow = e.east and "->" or "  "
        blight.output(string.format("%s %s   %s   %s %s",
            w_cell, west_arrow,
            "* " .. trim(r.title or "?", 24),
            east_arrow, e_cell))
        if e.south then
            blight.output("                          |")
            blight.output("                 " .. cell(e.south, 28))
        end

        local extras = {}
        for _, d in ipairs({"northeast", "northwest", "southeast", "southwest", "up", "down"}) do
            if e[d] then table.insert(extras, "  " .. d .. " -> " .. neighbor_title(e[d])) end
        end
        if #extras > 0 then
            blight.output("")
            for _, x in ipairs(extras) do blight.output(x) end
        end

        if r.exits then
            local missing = {}
            for dir in r.exits:gmatch("(%S+)") do
                if dir ~= "and" and not e[dir] then table.insert(missing, dir) end
            end
            if #missing > 0 then
                blight.output("")
                blight.output("Unwalked exits: " .. table.concat(missing, ", "))
            end
        end
    end

    function self.dump(path)
        if not path then return end
        local f = io.open(path, "w")
        if not f then return end
        local now = os.date("%H:%M:%S")
        f:write(CYAN_B("─── " .. self.name .. " mapper v2 @ " .. now .. " ───") .. "\n")
        if not self.current then
            f:write(DIM("(not in a known room yet — walk to populate)") .. "\n")
            f:close()
            return
        end
        local r = self.rooms[self.current] or {}
        local e = r.edges or {}
        f:write("\n" .. YELLOW_B("ROOM: " .. (r.title or "?")) .. "\n")
        f:write(DIM("Exits (server): ") .. (r.exits or "?") .. "\n")
        local known = {}
        for d, _ in pairs(e) do table.insert(known, d) end
        table.sort(known)
        f:write(DIM("Known edges:    ") .. CYAN(table.concat(known, ", ")) .. "\n\n")

        local function lbl(dir)
            return e[dir] and CYAN(trim(neighbor_title(e[dir]), 28)) or DIM("─")
        end
        f:write("                    " .. lbl("north") .. "\n")
        f:write("                         " .. DIM("|") .. "\n")
        f:write(string.format("  %-30s %s  %s  %s  %s\n",
            lbl("west"), DIM("←"),
            YELLOW_B("*here*"),
            DIM("→"), lbl("east")))
        f:write("                         " .. DIM("|") .. "\n")
        f:write("                    " .. lbl("south") .. "\n\n")

        for _, d in ipairs({"northeast", "northwest", "southeast", "southwest", "up", "down"}) do
            if e[d] then f:write(string.format("  %s %s %s\n",
                CYAN(d), DIM("→"), neighbor_title(e[d]))) end
        end

        -- Same-zone listing (uses unified parse_zone — was inline before).
        local zone = zone_of(r.title or "")
        local zone_rooms = {}
        local seen = {}
        for _, rr in pairs(self.rooms) do
            local tt = rr.title or "?"
            if zone_of(tt) == zone and not seen[tt] then
                seen[tt] = true
                table.insert(zone_rooms, tt)
            end
        end
        table.sort(zone_rooms)
        f:write("\n" .. MAG("─── zone (" .. zone .. ") — " .. #zone_rooms .. " rooms ───") .. "\n")
        for _, t in ipairs(zone_rooms) do
            if t == r.title then
                f:write(YELLOW_B("* " .. t) .. "\n")
            else
                f:write("  " .. GREEN(t) .. "\n")
            end
        end

        local total = #self.list_rooms()
        f:write("\n" .. DIM("─── total unique titles known: " .. total .. " ───") .. "\n")
        f:close()
    end

    function self.same_zone()
        if not self.current then return self.list_rooms() end
        local r = self.rooms[self.current]
        if not r then return self.list_rooms() end
        local zone = zone_of(r.title or "")
        local hits = {}
        local seen = {}
        for _, rr in pairs(self.rooms) do
            local tt = rr.title or "?"
            if zone_of(tt) == zone and not seen[tt] then
                seen[tt] = true
                table.insert(hits, tt)
            end
        end
        table.sort(hits)
        return hits
    end

    _G.bm_mappers[name] = self
    return self
end

blight.output("[mapper] mapper_new() v2 ready — per-(title, exits) keying, zone-aware mp go, Levenshtein fuzzy fallback.")
