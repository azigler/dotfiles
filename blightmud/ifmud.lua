-- ifMUD (ifmud.port4000.com:4000)
-- An interactive-fiction community MUD. LPC-based. Channels-heavy.

local g_alias, g_trigger = game_groups("ifmud")

-- ─── login ────────────────────────────────────────────────────────
-- ifMUD uses a single-line connect: `connect <name> <password>`
-- Type `login` at the welcome screen.
g_alias:add("^login$", function()
    local user, pass = creds("ifmud")
    if not user or not pass then
        blight.output("[ifmud] no creds — set IFMUD_USER + IFMUD_PASS in .env.local")
        return
    end
    mud.send("connect " .. user .. " " .. pass, { gag = true, skip_log = true })
end)

-- ─── conveniences ────────────────────────────────────────────────
g_alias:add("^l$", function() mud.send("look") end)
g_alias:add("^w$", function() mud.send("who") end)

-- Track last user who paged so `r <text>` can reply directly.
local last_pager = nil

g_trigger:add("^(\\w+) pages, \"(.*)\"$", {}, function(matches)
    last_pager = matches[2]
    blight.output("[page from " .. matches[2] .. "] " .. matches[3])
end)

g_alias:add("^r (.+)$", function(m)
    if not last_pager then
        blight.output("[r] no one has paged you yet this session")
        return
    end
    mud.send("page " .. last_pager .. " = " .. m[2])
    blight.output("[r→" .. last_pager .. "] " .. m[2])
end)

g_alias:add("^who$", function() mud.send("who") end)
g_alias:add("^bb$", function() mud.send("bb") end)
g_alias:add("^mail$", function() mud.send("mail") end)

-- ─── keep-alive (data-bearing + activity-reset) ───────────────────
-- TWO problems to solve, both with the same 90s timer:
--
--   1. WIRE-LEVEL: OVH's stateful firewalls upstream of our VPS don't
--      refresh path-state on zero-byte TCP keepalives — they need
--      real payload bytes. Any small request/response pair handles
--      this. The `idle` command (== `who me`, see ifmud help) is
--      cheap and was the original choice.
--
--   2. CHARACTER-LEVEL: ifMUD's `idle` and `qidle` commands are
--      DELIBERATELY designed to NOT reset the per-character idle
--      timer (help/idle: "does the same as 'who me' ... without
--      resetting your idle flag"). They short-circuit BEFORE the
--      `last = now()` update in input.mudmod:1193-1235. So after 60
--      minutes the server's zoneFolks() sweep (utils.mudmod:2031)
--      still flips Zig's `zoned` flag and channels keep firing
--      `idle!` warnings to anyone watching the who-list.
--
-- APPROACH CHOSEN: alternate between `idle` and `who me` on each
-- tick (option 1 from bead blightmud-ozl). Why this works:
--
--   - `idle` (odd ticks): still sees OTHER users' idle times —
--     useful socially, surfaces who-just-deidled patterns.
--   - `who me` (even ticks): the SAME query Zig-only, but it does
--     NOT short-circuit in input.mudmod, so it falls through to
--     the regular command path and updates `objects[me]{last}`.
--     Result: every 180s Zig's idle timer resets to zero, which is
--     well under the 3600s zone-threshold.
--
-- Both commands produce the same compact table shape ("User" header,
-- "End of List." footer), so the existing gag state machine handles
-- both with no changes — only the command being sent alternates.
--
-- Trade-offs:
--   - Extra round-trip every 180s (vs. just keeping `idle`): negligible
--     on a 26-user MUD with 293-day uptime — the server isn't load-
--     constrained.
--   - `who me` does NOT update the `zoned` flag on its own (that
--     happens via zoneFolks()'s 1-hr-since-`last` check), but it
--     DOES reset `last`, so the flag never gets set in the first
--     place as long as keepalive keeps ticking.
--   - No channel noise: both commands are private replies to Zig,
--     no broadcast.
--   - If we ever WANT to be zoned/away deliberately, set
--     `_G.bm_ifmud_state.suppress_until = os.time() + <secs>` to
--     pause the keepalive (same mechanism the manual `idle!` uses).

-- The gag trigger is registered ONCE inside g_trigger (the per-game
-- group). On reload, game_groups("ifmud") clears the group, so we
-- never accumulate stale triggers across /load cycles. The trigger
-- is always-on and uses a SUPPRESS FLAG to bypass during a manual
-- `idle!` send.

_G.bm_ifmud_state = _G.bm_ifmud_state or {}
local s = _G.bm_ifmud_state
-- Backfill any new fields (handles /load over an older state table).
s.saw_start = false -- always reset on (re)load
if s.suppress_until == nil then s.suppress_until = 0 end
if s.tick == nil then s.tick = 0 end

-- Persistent gag trigger (in g_trigger so it's group-managed).
-- Matches the User-On-Idle header → gags subsequent lines until
-- "End of List" or the saw_start flag is reset. Bypassed entirely
-- when suppress_until is in the future (manual idle! window).
g_trigger:add(".+", {}, function(_, line)
    if os.time() < s.suppress_until then
        return
    end -- manual idle! bypass
    local text = line:line()
    if not s.saw_start then
        if text:match("^%s*User%s+On%s+Idle") then
            s.saw_start = true
            line:gag(true)
            line:skip_log(true)
        end
        return
    end
    line:gag(true)
    line:skip_log(true)
    if text:match("^End of List") then
        s.saw_start = false
    end
end)

-- Auto-keepalive: send `idle` every 90s. This is the PROBE command
-- (lists who's idle and their times) and crucially does NOT reset
-- Zig's own `last` timestamp on the server — so Andrew shows as
-- idle to others as he naturally accrues idle time. Per Andrew
-- 2026-05-18: we explicitly DO NOT want activity-reset behavior;
-- the bead-ozl `who me` alternation has been removed.
--
-- Trade-off: after ~1 hour of pure `idle` keepalive, ifmud may
-- set the zoned flag on Zig. The wire stays alive (OVH stateful
-- firewall problem solved) but the server-side bookkeeping shows
-- zoned. Re-engage via any actual command (typing in the pane)
-- to clear the zoned flag.
game_timer("ifmud_keepalive", 90, function()
    if _G.bm_current_game ~= "ifmud" then
        return
    end
    if os.time() < s.suppress_until then
        return
    end -- don't keepalive during manual flow
    mud.send("idle", { gag = true, skip_log = true })
end)

-- Manual `idle!` — see the real `idle` response. Sets a 5-second
-- suppress window so the gag trigger lets the response through
-- and prevents an auto-keepalive from firing in between.
g_alias:add("^idle!$", function()
    s.suppress_until = os.time() + 5
    s.saw_start = false
    mud.send("idle")
end)

blight.output("[ifmud] loaded — type `login`; keep-alive sends `idle`/90s (does NOT reset Zig's idle timer; you accrue idle naturally)")
