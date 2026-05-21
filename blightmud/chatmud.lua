-- ChatMUD (chatmud.com:7777, or chatmud.com:7443 for TLS)
-- MOO-based community MUD. Builder/programmer culture.
--
-- ─── MCP plugin DISABLED globally (bead-49z, 2026-05-18) ──────────
-- The `blightmud_mcp` plugin is no longer autoloaded — see
-- `~/dotfiles/blightmud/autoload_plugins.ron` (now `[]`). Reason:
-- the plugin's heavy global state + trigger-stacking + lack of
-- nil-guards reliably corrupted the Lua VM with
-- `error converting Lua nil to table` after any /load perturbation.
-- Restart-only recovery (the old workaround in
-- ~/.claude/projects/-home-ubuntu-Blightmud/memory/reference_chatmud_mcp.md)
-- was too disruptive; we chose Option B (disable plugin) over
-- Option A (fork + nil-guard the plugin source).
--
-- WHAT WE LOSE: simpleedit (external-editor verb edits), /linelen,
-- /mcp, /flush, /editing slash-commands, dns-com-awns-status bar
-- updates. Verb edits still work via @program (interactive entry).
--
-- TO RE-ENABLE (if simpleedit becomes load-bearing — see bead-532):
--   1. /enable_plugin blightmud_mcp     (or edit autoload_plugins.ron)
--   2. /quit + relaunch Blightmud
--
-- /quit-restart NOTE: Blightmud does not expose `/quit` from Lua
-- (it's a top-level UI command, not a `mud.*` API). If we ever want
-- a `restart` alias in this file, it would have to use mud.input("/quit")
-- and rely on the surrounding shell (`coplay.sh`) to relaunch the
-- binary — not bound here because pane-level restart is Andrew's
-- decision, not chatmud-specific.
-- ──────────────────────────────────────────────────────────────────

local g_alias, g_trigger = game_groups("chatmud")

-- ─── login ────────────────────────────────────────────────────────
-- ChatMUD has a two-step login: character name prompt → password prompt.
-- Type `login` at the welcome screen.
g_alias:add("^login$", function()
    local user, pass = creds("chatmud")
    if not user or not pass then
        blight.output("[chatmud] no creds — set CHATMUD_USER + CHATMUD_PASS in .env.local")
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
    trigger.add("Password:", { count = 1, gag = true }, on_pass_prompt)
    trigger.add("Password:", { count = 1, gag = true, prompt = true }, on_pass_prompt)
end)

-- ─── conveniences ────────────────────────────────────────────────
g_alias:add("^w$", function() mud.send("who") end)

-- `restart-hint` prints the manual recovery procedure (Lua can't
-- restart the host process; this is documentation-on-demand).
g_alias:add("^restart-hint$", function()
    blight.output("[chatmud] To restart Blightmud cleanly:")
    blight.output("  1. /quit            (this Blightmud process)")
    blight.output("  2. ./target/release/blightmud   (relaunch from shell)")
    blight.output("  3. /connect chatmud + login")
    blight.output("  (MCP plugin is disabled — corruption should not recur.")
    blight.output("   If it does, capture the log and update bead-49z.)")
end)

blight.output("[chatmud] loaded — type `login` at the welcome screen")
blight.output("[chatmud] MCP plugin disabled (bead-49z); `restart-hint` for recovery info")
