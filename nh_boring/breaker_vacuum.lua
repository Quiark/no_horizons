--[[
    breaker_vacuum.lua
    ==================

    Breaker Vacuum for Skyblock: Zero.

    A small machine, similar to the Item Vacuum, but instead of picking up
    loose item entities it only pulls items out of the drop-buffer inventory
    ("main") of Node Breakers (pipeworks:nodebreaker) and Ultra Node Breakers
    (nh_boring:ultra_node_breaker) within a radius of 3 nodes. It requires
    20 Cj and has a 16-slot inventory compatible with pipeworks tubes.
--]]

local S = core.get_translator("nh_boring")

local RADIUS = 3
local POWER_NEEDED = 20

local formspec = [[
formspec_version[7]
size[8.2,9]
label[0.2,0.2;%s]
style_type[list;spacing=.2;size=.8]
list[context;main;0.2,0.2;8,2;]
list[current_player;main;0.2,5;8,4;]
listring[context;main]
listring[current_player;main]
]]

-- Move everything we can carry out of the drop-buffer of every Node Breaker
-- and Ultra Node Breaker within RADIUS onto our own inventory.
local function collect_from_breakers(pos, inv)
    iterate_around_radius(pos, function(bpos)
        local node = sbz_api.get_node_force(bpos)
        if node and (node.name == "pipeworks:nodebreaker"
                or node.name == "nh_boring:ultra_node_breaker") then
            local binv = core.get_meta(bpos):get_inventory()
            local drops = binv:get_list("main")
            if drops then
                for i, stack in ipairs(drops) do
                    if not stack:is_empty() then
                        binv:set_stack("main", i, inv:add_item("main", stack))
                    end
                end
            end
        end
    end, RADIUS)
end

sbz_api.register_stateful_machine("nh_boring:breaker_vacuum", {
    description = S("Breaker Vacuum"),
    sounds = sbz_audio.machine(),
    tiles = { "breaker_vacuum.png" },
    groups = { matter = 2, cracky = 3 },

    on_construct = function(pos)
        local meta = core.get_meta(pos)
        local inv = meta:get_inventory()
        inv:set_size("main", 16)
        meta:set_string("formspec", formspec:format(S("Breaker Vacuum")))
    end,

    on_rightclick = function(pos, node, player, pointed_thing)
        core.get_meta(pos):set_string("formspec", formspec:format(S("Breaker Vacuum")))
    end,

    input_inv = "main",
    output_inv = "main",

    get_power_needed = function()
        return POWER_NEEDED
    end,

    autostate = true,

    -- A Power Relay (which never "touches" nodes) can power this machine.
    -- The base grid's 3 s "Machine timeout check" ABM would otherwise keep
    -- swapping us off expecting a switching station's tick; flip right back
    -- on the moment that happens.
    on_timeout = function(pos)
        sbz_api.turn_on(pos)
        core.get_meta(pos):set_string("infotext", S("Running"))
    end,

    action = function(pos, node, meta, supply, demand)
        -- Manual power check so autostate turns us visibly off when the
        -- network can not supply the required 20 Cj.
        if demand + POWER_NEEDED > supply then
            meta:set_string("infotext", S("Not enough power"))
            return 0
        end
        collect_from_breakers(pos, meta:get_inventory())
        meta:set_string("infotext", S("Running"))
        return POWER_NEEDED
    end,
}, {
    -- "on" variant: subtle glow when powered
    tiles = { "breaker_vacuum.png" },
    light_source = 4,
})

do -- Breaker Vacuum recipe scope
    local BV = "nh_boring:breaker_vacuum_off"
    local NB = "pipeworks:nodebreaker"
    local I_V = "sbz_power:item_vacuum"
    local BT = "pipeworks:tube_1"
    local RC = "sbz_resources:retaining_circuit"
    local AI = "sbz_chem:aluminum_ingot"
    core.register_craft({
        output = BV,
        recipe = {
            { AI, NB, AI },
            { BT, I_V, BT },
            { AI, RC, AI },
        },
    })
end
