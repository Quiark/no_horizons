--[[
    mote_catcher.lua
    ================

    Warp Mote item and Mote Catcher machine for Skyblock: Zero.

    The Mote Catcher is a machine that passively collects warp motes when
    a warp storm manifests within a radius of 3 nodes. It requires 200 Cj
    to run and has a 9-slot inventory compatible with pipeworks tubes.
--]]

local S = core.get_translator("no_horizons")

-- ======================================================================
-- 1. WARP MOTE ITEM
-- ======================================================================

core.register_craftitem("no_horizons:warp_mote", {
    description = S("Warp Mote"),
    inventory_image = "mote.png",
    stack_max = 256,
})

-- ======================================================================
-- 2. MOTE CATCHER MACHINE
-- ======================================================================

local POWER_NEEDED = 200

local formspec = [[
formspec_version[7]
size[8.2,9]
label[0.2,0.2;%s]
style_type[list;spacing=.2;size=.8]
list[context;main;1.5,1;3,3;]
list[current_player;main;0.2,5;8,4;]
listring[context;main]
listring[current_player;main]
]]

sbz_api.register_stateful_machine("no_horizons:mote_catcher", {
    description = S("Mote Catcher"),
    sounds = sbz_audio.machine(),
    tiles = { "partcatch.png" },
    groups = { matter = 1 },
    paramtype2 = "facedir",
    sunlight_propagates = true,
    walkable = true,

    on_construct = function(pos)
        local meta = core.get_meta(pos)
        local inv = meta:get_inventory()
        inv:set_size("main", 9)
        meta:set_string("formspec", formspec:format(S("Mote Catcher")))
    end,

    on_rightclick = function(pos, node, player, pointed_thing)
        core.get_meta(pos):set_string("formspec", formspec:format(S("Mote Catcher")))
    end,

    input_inv = "main",
    output_inv = "main",

    autostate = true,

    -- Same trick as the breaker vacuum: a Power Relay powers this without
    -- ever touching base-grid state, so undo the "Machine timeout check"
    -- ABM's switch-off the instant it happens.
    on_timeout = function(pos)
        sbz_api.turn_on(pos)
        core.get_meta(pos):set_string("infotext", S("Running"))
    end,

    action = function(pos, node, meta, supply, demand)
        -- Manual power check so autostate turns us visibly off when the
        -- network can not supply the required 200 Cj.
        if demand + POWER_NEEDED > supply then
            meta:set_string("infotext", S("Not enough power"))
            return 0
        end
        meta:set_string("infotext", S("Running"))
        -- Actual mote collection happens in the ABM below.
        return POWER_NEEDED
    end,
}, {
    -- "on" variant: subtle glow when powered
    tiles = { "partcatch.png" },
    light_source = 4,
})

-- ======================================================================
-- 3. ABM: COLLECT MOTES FROM NEARBY STORMS
-- ======================================================================

-- Without power the catcher would be looted by chance storms miles away
-- from a player.  Only the powered "_on" node collects.  Runs every 3
-- seconds.
core.register_abm({
    label = "Mote catcher storm proximity",
    nodenames = { "no_horizons:mote_catcher_on" },
    interval = 3,
    chance = 1,
    action = function(pos, node)
        -- The catcher reaches a few nodes past the literal storm volume, so
        -- a catcher parked just outside the cuboid still collects motes.
        local margin = 2
        local now_us = core.get_us_time()
        local lifetime_us = sbz_api.storm_activity_duration_us or 20e6
        local storms = sbz_api.active_storms or {}
        if #storms == 0 then
            return
        end
        -- Debug log: how many storm records this catcher sees each tick, so
        -- it is obvious when a single storm is registered more than once.
        core.log("action", string.format(
            "[no_horizons] mote_catcher at %s: %d storm(s) tracked",
            core.pos_to_string(pos), #storms
        ))
        for i, storm in ipairs(storms) do
            if now_us - storm.time > lifetime_us then
                goto continue -- stale entries are skipped, never collected from
            end
            local smin, smax = storm.minp, storm.maxp
            if pos.x >= smin.x - margin and pos.x <= smax.x + margin
                    and pos.y >= smin.y - margin and pos.y <= smax.y + margin
                    and pos.z >= smin.z - margin and pos.z <= smax.z + margin then
                local meta = core.get_meta(pos)
                local inv = meta:get_inventory()
                local count = math.random(1, 3)
                local stack = ItemStack("no_horizons:warp_mote " .. count)
                if inv:room_for_item("main", stack) then
                    inv:add_item("main", stack)

                    core.log("action", string.format(
                        "[no_horizons] mote_catcher at %s: storm #%d (%s, "
                            .. "entry %d/%d) matches; collected %d motes",
                        core.pos_to_string(pos), storm.id or -1, storm.name or "?",
                        i, #storms, count
                    ))

                    core.add_particlespawner({
                        amount = 8,
                        time = 1,
                        minpos = vector.subtract(pos, 0.5),
                        maxpos = vector.add(pos, 0.5),
                        minvel = { x = -1, y = 1, z = -1 },
                        maxvel = { x = 1, y = 3, z = 1 },
                        minexptime = 0.5,
                        maxexptime = 1.0,
                        minsize = 1,
                        maxsize = 2,
                        texture = "mote.png^[multiply:#c8a0ff",
                        glow = 12,
                    })
                end
                break -- one collection per tick even if several storms overlap
            end
            ::continue::
        end
    end,
})

-- ======================================================================
-- 4. CRAFTING RECIPE
-- ======================================================================

do
    local TB = "sbz_chem:titanium_block"
    local PC = "sbz_resources:phlogiston_circuit"
    local AM = "sbz_resources:antimatter_dust"
    local WC = "sbz_resources:warp_crystal"
    core.register_craft({
        output = "no_horizons:mote_catcher_off",
        recipe = {
            { TB, PC, TB },
            { AM, "",  AM },
            { TB, WC, TB },
        },
    })
end
