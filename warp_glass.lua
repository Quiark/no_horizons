--[[
    warp_glass.lua
    ==============

    Warp Glass for Skyblock: Zero.

    A textureless, flat-coloured glass block. The face texture is a plain
    sheet of white (see tools/make_warp_glass.py) and the unifieddyes
    palette tint multiplies straight over it, so a whole face ends up one
    single colour with no pattern in it. It is walk-through and lets
    sunlight through, which makes it handy for stained-glass walls, force
    fields and coloured floor markers.
--]]

local S = core.get_translator("no_horizons")

local WARP_GLASS = "no_horizons:warp_glass"

-- How see-through the glass is, 0-255. Because the texture is solid white
-- the opacity modifier is the only thing shaping it: lower this for a
-- frostier block, 255 for perfectly clear.
local ALPHA = 150

-- One flat sheet of white, used for all six faces. drawtype is plain
-- "glasslike" rather than one of the framed variants: glasslike draws the
-- cube with no frame and no bevel, so a face is one uninterrupted colour
-- with no edge outline anywhere on the block.
local FACE = "nh_solid.png^[opacity:" .. ALPHA

core.register_node(WARP_GLASS, unifieddyes.def({
    description = S("Warp Glass"),
    drawtype = "glasslike",
    tiles = { FACE },
    inventory_image = "nh_warp_glass_inv.png",
    use_texture_alpha = "blend",
    backface_culling = true,
    paramtype = "light",
    sunlight_propagates = true,
    -- Same value unifieddyes uses for its colorium lines. core.LIGHT_MAX is
    -- 14, one below the 15 that open sky gives by day, so a pane of warp
    -- glass reads as a lit surface at night and inside dark builds instead
    -- of vanishing into them. The nebula fields are built out of this node,
    -- so this is what makes them glow rather than just tint the background.
    light_source = core.LIGHT_MAX,
    -- walkable = false is the whole trick: it is the same field air itself
    -- is defined with, and it is what the base game's co2_compactor uses to
    -- be "passed through". Players drift straight in instead of bumping.
    walkable = false,
    is_ground_content = false,
    groups = {
        cracky = 3,
        oddly_breakable_by_hand = 3,
        transparent = 1, -- draw in the translucent pass, not the opaque one
        explody = 100,
    },
    sounds = sbz_audio.glass(),
    info_extra = S("A pane of flat coloured light. You can walk right through it."),
}))

do -- Warp Glass recipe scope
    local EG = "sbz_resources:emittrium_glass"
    local WM = "no_horizons:warp_mote"
    core.register_craft({
        output = WARP_GLASS .. " 8",
        recipe = {
            { EG, EG, EG },
            { EG, WM, EG },
            { EG, EG, EG },
        },
    })
end

-- The base game only auto-files sbz_decor items under "deco", so warp glass
-- has to be added by hand. Deferred to on_mods_loaded so unified_inventory
-- is guaranteed to have its category table by then.
core.register_on_mods_loaded(function()
    if not unified_inventory or not unified_inventory.add_category_item then
        return
    end
    unified_inventory.add_category_item("deco", WARP_GLASS)
end)
