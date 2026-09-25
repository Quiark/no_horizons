-- Warp storms: random lightning storms that briefly appear near players,
-- strike the area with VoxelManip-placed bolts, warp a few existing
-- blocks around and can leave warp flesh behind. See warp_storm.lua.
dofile(core.get_modpath("no_horizons") .. "/warp_storm.lua")

-- Candles: colorable light sources, lit with igniter. See candles.lua.
dofile(core.get_modpath("no_horizons") .. "/candles.lua")

-- Candles quest page in the base game's questbook. See quests.lua.
dofile(core.get_modpath("no_horizons") .. "/quests.lua")

-- Orbplant: a flesh-grown plant that needs CO₂ and calls down warp storms
-- when mature. See orbplant.lua.
dofile(core.get_modpath("no_horizons") .. "/orbplant.lua")

-- Mote Catcher: a machine that collects warp motes from nearby storms.
-- See mote_catcher.lua.
dofile(core.get_modpath("no_horizons") .. "/mote_catcher.lua")

-- Breaker Vacuum: a machine that pulls drops out of nearby Node Breakers.
-- See breaker_vacuum.lua.
dofile(core.get_modpath("no_horizons") .. "/breaker_vacuum.lua")

-- Ultra Node Breaker: breaks any node and keeps drops for the vacuum.
-- See ultra_node_breaker.lua.
dofile(core.get_modpath("no_horizons") .. "/ultra_node_breaker.lua")

-- Pusher: a powered piston that pushes blocks AND itself, marching forward
-- indefinitely. See pusher.lua.
dofile(core.get_modpath("no_horizons") .. "/pusher.lua")

-- Power Relay: a self-contained mini switching station for mobile rigs that
-- can be safely shoved around by a Pusher. See power_relay.lua.
dofile(core.get_modpath("no_horizons") .. "/power_relay.lua")

local pane_nodebox = {
    type = "connected",
    fixed = {{-1 / 16, -1 / 2, -1 / 16, 1 / 16, 1 / 2, 1 / 16}},
    connect_front = {{-1 / 16, -1 / 2, -1 / 2, 1 / 16, 1 / 2, -1 / 16}},
    connect_left = {{-1 / 2, -1 / 2, -1 / 16, -1 / 16, 1 / 2, 1 / 16}},
    connect_back = {{-1 / 16, -1 / 2, 1 / 16, 1 / 16, 1 / 2, 1 / 2}},
    connect_right = {{1 / 16, -1 / 2, -1 / 16, 1 / 2, 1 / 2, 1 / 16}},
}

local flat_pane_nodebox = {
    type = "fixed",
    fixed = {{-1 / 2, -1 / 2, -1 / 16, 1 / 2, 1 / 2, 1 / 16}},
}

local pane_neighbors = {
    vector.new(1, 0, 0),
    vector.new(0, 0, 1),
    vector.new(-1, 0, 0),
    vector.new(0, 0, -1),
}

local function pane_connects_to(pos)
    local node = core.get_node_or_nil(pos)
    if not node then
        return false
    end

    if core.get_item_group(node.name, "pane") > 0 then
        return true
    end

    return core.get_item_group(node.name, "matter") > 0
        or core.get_item_group(node.name, "antimatter") > 0
        or core.get_item_group(node.name, "wall") > 0
        or core.get_item_group(node.name, "tree") > 0
        or core.get_item_group(node.name, "wood") > 0
end

local function get_colorbits(param2)
    if core.strip_param2_color then
        return core.strip_param2_color(param2, "colorfacedir") or 0
    end
    return 0
end

local function register_tinted_panes(tinted_glass_name)
    local tinted_glass_def = core.registered_nodes[tinted_glass_name]
    if not tinted_glass_def then
        return
    end

    local pane_name = tinted_glass_name .. "_pane"
    local pane_name_flat = pane_name .. "_flat"

    local pane_side = tinted_glass_def.tiles and tinted_glass_def.tiles[2] or "amethyst_tinted_glass.png"
    local pane_top = pane_side
    local pane_cap = "blank.png^[opacity:0"
    local pane_sounds = tinted_glass_def.sounds
    local pane_alpha = tinted_glass_def.use_texture_alpha or "blend"
    local pane_sunlight = tinted_glass_def.sunlight_propagates == true

    local function update_tinted_pane(pos)
        local node = core.get_node(pos)
        if node.name ~= pane_name and node.name ~= pane_name_flat then
            return
        end

        local color = get_colorbits(node.param2)
        local any_dir = node.param2 - color
        local connections = {}
        local count = 0

        for i, dir in pairs(pane_neighbors) do
            connections[i] = pane_connects_to(vector.add(pos, dir))
            if connections[i] then
                any_dir = dir
                count = count + 1
            end
        end

        if count == 2 and (
                (connections[1] and connections[3]) or
                (connections[2] and connections[4])
            ) then
            core.swap_node(pos, {
                name = pane_name_flat,
                param2 = ((core.dir_to_facedir(any_dir) + 1) % 4) + color,
            })
            return
        end

        core.swap_node(pos, {
            name = pane_name,
            param2 = color,
        })
    end

    core.register_on_placenode(function(pos)
        for _, dir in pairs(pane_neighbors) do
            update_tinted_pane(vector.add(pos, dir))
        end
    end)

    core.register_on_dignode(function(pos)
        for _, dir in pairs(pane_neighbors) do
            update_tinted_pane(vector.add(pos, dir))
        end
    end)

    local pane_groups_flat = table.copy(tinted_glass_def.groups or {matter = 3})
    pane_groups_flat.pane = 1
    pane_groups_flat.ud_param2_colorable = 1

    local pane_groups = table.copy(pane_groups_flat)
    pane_groups.not_in_creative_inventory = 1

    core.register_node(":" .. pane_name_flat, {
        description = (tinted_glass_def.description or "Tinted Glass") .. " Pane",
        drawtype = "nodebox",
        paramtype = "light",
        paramtype2 = "colorfacedir",
        palette = "unifieddyes_palette_colorfacedir.png",
        tiles = {pane_top, pane_top, pane_cap, pane_cap, pane_side, pane_side},
        use_texture_alpha = pane_alpha,
        backface_culling = true,
        sunlight_propagates = pane_sunlight,
        groups = pane_groups_flat,
        sounds = pane_sounds,
        node_box = flat_pane_nodebox,
        connects_to = {
            "group:pane",
            "group:matter",
            "group:antimatter",
            "group:wall",
            "group:tree",
            "group:wood",
        },
        on_construct = function(pos)
            update_tinted_pane(pos)
        end,
    })

    core.register_node(":" .. pane_name, {
        drawtype = "nodebox",
        paramtype = "light",
        paramtype2 = "colorfacedir",
        palette = "unifieddyes_palette_colorfacedir.png",
        tiles = {pane_top, pane_top, pane_side},
        use_texture_alpha = pane_alpha,
        backface_culling = true,
        sunlight_propagates = pane_sunlight,
        groups = pane_groups,
        sounds = pane_sounds,
        drop = pane_name_flat,
        node_box = pane_nodebox,
        connects_to = {
            "group:pane",
            "group:matter",
            "group:antimatter",
            "group:wall",
            "group:tree",
            "group:wood",
        },
        on_construct = function(pos)
            update_tinted_pane(pos)
        end,
    })

    core.register_craft({
        output = pane_name_flat .. " 16",
        recipe = {
            {tinted_glass_name, tinted_glass_name, tinted_glass_name},
            {tinted_glass_name, tinted_glass_name, tinted_glass_name},
        },
    })

    if core.get_modpath("unified_inventory") then
        unified_inventory.add_category_item("deco", pane_name_flat)
    end
end

core.register_on_mods_loaded(function()
    local found = false

    for name, def in pairs(core.registered_nodes) do
        local desc = def.description or ""
        local is_base_game = name:find("^sbz_") ~= nil
        local is_tinted = name:find("tinted_glass", 1, true) ~= nil or desc:find("Tinted Glass", 1, true) ~= nil

        if is_base_game and is_tinted and not name:find("_pane", 1, true) then
            register_tinted_panes(name)
            found = true
        end
    end

    if core.registered_nodes["sbz_resources:stained_colorium_glass"] then
        register_tinted_panes("sbz_resources:stained_colorium_glass")
        found = true
    end

    if not found then
        core.log("error", "[no_horizons] No base-game tinted glass node found; panes were not registered")
    end
end)
