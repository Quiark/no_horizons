--[[
    ultra_node_breaker.lua
    ======================

    Ultra Node Breaker for Skyblock: Zero.

    Like a Node Breaker, but "ultra": it breaks every node in front of it
    regardless of groups or digging capabilities (air is ignored), and it
    does not eject its drops or send them out through tubes. Everything it
    breaks is kept in its own 4-slot inventory, ready to be collected by a
    Breaker Vacuum.
--]]

local S = core.get_translator("no_horizons")

pipeworks.register_wielder({
    name = "no_horizons:ultra_node_breaker",
    description = S("Ultra Node Breaker"),
    tiles = {
        "ultra_nodebreaker_side.png",
        "ultra_nodebreaker_side.png",
        "ultra_nodebreaker_side.png",
        "ultra_nodebreaker_side.png",
        "ultra_nodebreaker_back.png",
        "ultra_nodebreaker_front.png",
    },
    connect_sides = { top = 1, bottom = 1, left = 1, right = 1, back = 1 },
    wield_inv = { name = "main", width = 2, height = 2 },
    wield_hand = true,
    eject_drops = false,
    action = function(fakeplayer, pointed)
        local node = core.get_node(pointed.under)
        if node.name == "air" or node.name == "ignore" then
            return false
        end
        local node_def = core.registered_nodes[node.name]
        if not node_def or not node_def.on_dig then
            return false
        end
        local sound = node_def.sounds and node_def.sounds.dug
        if node_def.on_dig(pointed.under, node, fakeplayer) == false then
            return false
        end
        if sound then core.sound_play(sound, { pos = pointed.under }, true) end
        return true
    end,
    cost = 30,
})

-- pipeworks.register_wielder hardcodes this node's definition, so the base
-- grid's "Machine timeout check" ABM hook has to be bolted on afterward.
-- When powered by a Power Relay (which never "touches" base-grid state) that
-- ABM fires "No network found"; restore a sane infotext immediately.
local un_def = core.registered_nodes["no_horizons:ultra_node_breaker"]
if un_def then
    un_def.on_timeout = function(pos)
        core.get_meta(pos):set_string("infotext", S("Running"))
    end
end

do -- Ultra Node Breaker recipe scope
    local UNB = "no_horizons:ultra_node_breaker"
    local NB = "pipeworks:nodebreaker"
    local MA = "sbz_resources:matter_annihilator"
    local RC = "sbz_resources:retaining_circuit"
    local AI = "sbz_chem:aluminum_ingot"
    core.register_craft({
        output = UNB,
        recipe = {
            { MA, NB, MA },
            { AI, RC, AI },
            { AI, RC, AI },
        },
    })
end
