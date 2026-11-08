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

local S = core.get_translator("nh_boring")
local ULTRA_POWER_NEEDED = 30

pipeworks.register_wielder({
    name = "nh_boring:ultra_node_breaker",
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
        local node = sbz_api.get_node_force(pointed.under)
        if not node or node.name == "air" or node.name == "ignore" then
            return false
        end
        local node_def = core.registered_nodes[node.name]
        if not node_def or not node_def.on_dig then
            return false
        end
        if nh_boring.is_protected_node(node) then
            return false
        end
        local sound = node_def.sounds and node_def.sounds.dug
        if node_def.on_dig(pointed.under, node, fakeplayer) == false then
            return false
        end
        if sound then core.sound_play(sound, { pos = pointed.under }, true) end
        -- pipeworks hands us a "pointed" thing with under/above deliberately
        -- switched around: under = pos - dir, above = pos - 2 * dir, so
        -- under - above is the facing and one more step along it is the
        -- digger itself.  The dust belongs to the machine doing the digging,
        -- not to whatever it just ate.
        local facing = vector.subtract(pointed.under, pointed.above)
        local digger = vector.add(pointed.under, facing)
        core.add_particlespawner({
            amount = 64,
            time = 0.25,
            minpos = vector.subtract(digger, 0.4),
            maxpos = vector.add(digger, 0.4),
            minvel = { x = -0.5, y = 0.5, z = -0.5 },
            maxvel = { x = 0.5, y = 1.5, z = 0.5 },
            minexptime = 0.4,
            maxexptime = 0.9,
            minsize = 0.5,
            maxsize = 1,
            node = node,
        })
        return true
    end,
    cost = ULTRA_POWER_NEEDED,
})

-- pipeworks.register_wielder hardcodes this node's definition, so the base
-- grid's "Machine timeout check" ABM hook has to be bolted on afterward.
-- When powered by a Power Relay (which never "touches" base-grid state) that
-- ABM fires "No network found"; restore a sane infotext immediately.
local un_def = core.registered_nodes["nh_boring:ultra_node_breaker"]
if un_def then
    un_def.get_power_needed = function()
        return ULTRA_POWER_NEEDED
    end
    un_def.on_timeout = function(pos)
        core.get_meta(pos):set_string("infotext", S("Running"))
    end
end

do -- Ultra Node Breaker recipe scope
    local UNB = "nh_boring:ultra_node_breaker"
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
