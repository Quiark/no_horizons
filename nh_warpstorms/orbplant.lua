-- Orbplant: a warp-flesh plant that needs no habitat, no soil and no CO₂, but
-- still craves light like any other plant. It spontaneously sprouts out of the
-- two flesh blocks the warp storms leave behind (on average once every 60
-- minutes per flesh block), grows through three stages on its own, and when
-- mature its eye periodically calls down a warp storm somewhere within a few
-- blocks of itself.
--
-- See warp_storm.lua for the storm it triggers; textures are the three
-- eyeplant*.png frames.

local S = core.get_translator("nh_warpstorms")

-- ======================================================================
-- 0. TUNABLE CONSTANTS (adjust these, not the code below)
-- ======================================================================

-- How many growth stages the plant runs through before it is mature.
local ORBPLANT_STAGES = 3

-- Flesh blocks that an orbplant can sprout out of.
local ORBPLANT_FLESH_NODES = {
    "nh_warpstorms:warp_flesh",
    "nh_warpstorms:warp_meat",
}

-- Median time before a given flesh block sprouts an orbplant. Because the
-- abandonment of chance-based ABMs is exponential, the median wait is
-- interval * chance * ln(2), so chance is derived below to hit this target.
local ORBPLANT_SPROUT_MEDIAN_SECONDS = 60 * 60 -- 60 minutes

-- Median time before a sprouted plant advances from one stage to the next.
local ORBPLANT_GROW_MEDIAN_SECONDS = 180 -- 3 minutes per stage

-- Brightness a plant needs before it may sprout or grow, matching the other
-- plants in the game (sbz_bio's saplings need light level 8).
local ORBPLANT_MIN_LIGHT = 8

-- Mature orbplants call down a warp storm on average once every this many
-- seconds each (the median storm timing is not critical here, so this is
-- kept as straight "once per N seconds", see the ABM below).
local ORBPLANT_STORM_EVERY_SECONDS = 400

-- How far from the plant a storm may materialise (in nodes, spherical).
local ORBPLANT_STORM_RADIUS = 6

-- All plant ABMs share this check cadence; per-ABM probabilities are then
-- derived from the median targets above.
local ABM_INTERVAL = 10

local LOG2 = math.log(2)
local function chance_for_median(median_seconds)
    return math.max(1, math.floor(median_seconds / (ABM_INTERVAL * LOG2)))
end

-- Light at a position, treating "not bright enough to matter" (nil, i.e.
-- unloaded or not light-aware) as darkness so plants still need actual light.
local function get_light(pos)
    return core.get_node_light(pos) or 0
end

-- ======================================================================
-- 1. NODES
-- ======================================================================

local ORBPLANT_SELECTION_BOX = {
    type = "fixed",
    fixed = { -0.25, -0.5, -0.25, 0.25, 0.75, 0.25 },
}

local ORBPLANT_GROUPS_FINAL = {
    oddly_breakable_by_hand = 3,
    matter = 3,
    attached_node = 1,
    transparent = 1,
    not_in_creative_inventory = 1,
    burn = 1,
}

for i = 1, ORBPLANT_STAGES - 1 do
    local stage = i
    core.register_node("nh_warpstorms:orbplant_" .. stage, {
        description = S("Orbplant"),
        drawtype = "plantlike",
        tiles = { "eyeplant" .. stage .. ".png" },
        inventory_image = "eyeplant" .. stage .. ".png",
        paramtype = "light",
        use_texture_alpha = "clip",
        sunlight_propagates = true,
        walkable = false,
        selection_box = ORBPLANT_SELECTION_BOX,
        groups = {
            dig_immediate = 2,
            attached_node = 1,
            transparent = 1,
            not_in_creative_inventory = 1,
            burn = 1,
        },
        drop = {},
        sounds = sbz_audio.blank(),
        grow = sbz_api.plant_grow("nh_warpstorms:orbplant_" .. (stage + 1)),
    })
end

-- Mature orbplant: no longer grows, but its eye starts calling down warp
-- storms. See the storm ABM below.
core.register_node("nh_warpstorms:orbplant_" .. ORBPLANT_STAGES, {
    description = S("Orbplant"),
    drawtype = "plantlike",
    tiles = { "eyeplant" .. ORBPLANT_STAGES .. ".png" },
    inventory_image = "eyeplant" .. ORBPLANT_STAGES .. ".png",
    paramtype = "light",
    use_texture_alpha = "clip",
    sunlight_propagates = true,
    walkable = false,
    selection_box = ORBPLANT_SELECTION_BOX,
    groups = ORBPLANT_GROUPS_FINAL,
    drop = "nh_warpstorms:orbplant",
    sounds = sbz_audio.blank(),
})

-- The pick-up-able item. Planting it on either flesh type places stage one;
-- it cannot be placed on dirt or any soil.
core.register_craftitem("nh_warpstorms:orbplant", {
    description = S("Orbplant"),
    inventory_image = "eyeplant" .. ORBPLANT_STAGES .. ".png",
    groups = { ui_bio = 1 },
    on_place = sbz_api.plant_plant("nh_warpstorms:orbplant_1", ORBPLANT_FLESH_NODES),
})

-- ======================================================================
-- 2. ABM: FLESH SPROUTS ORBPLANTS
-- ======================================================================

-- Every flesh block independently grows an orbplant on its top surface with
-- a median wait of ORBPLANT_SPROUT_MEDIAN_SECONDS. The spot above the block
-- must be empty AND lit for the sprout to appear.
core.register_abm({
    label = "Orbplant sprouting",
    nodenames = ORBPLANT_FLESH_NODES,
    interval = ABM_INTERVAL,
    chance = chance_for_median(ORBPLANT_SPROUT_MEDIAN_SECONDS),
    action = function(pos)
        local above = vector.add(pos, vector.new(0, 1, 0))
        if core.get_node(above).name ~= "air" then
            return
        end
        if get_light(above) < ORBPLANT_MIN_LIGHT then
            return -- too dark to sprout, like any other plant
        end

        core.set_node(above, { name = "nh_warpstorms:orbplant_1" })
        core.sound_play(
            { name = "mix_sad_crackly_poof", gain = 0.5, max_hear_distance = 8 },
            { pos = pos }
        )
    end,
})

-- ======================================================================
-- 3. ABM: GROWTH
-- ======================================================================

-- A sprouted orbplant grows through its stages on its own: no habitat, no
-- water and no CO₂ needed, but still no growth in the dark. Each stage
-- advances after a median wait of ORBPLANT_GROW_MEDIAN_SECONDS.
core.register_abm({
    label = "Orbplant growth",
    nodenames = { "nh_warpstorms:orbplant_1", "nh_warpstorms:orbplant_2" },
    interval = ABM_INTERVAL,
    chance = chance_for_median(ORBPLANT_GROW_MEDIAN_SECONDS),
    action = function(pos, node)
        if get_light(pos) < ORBPLANT_MIN_LIGHT then
            return -- too dark to grow, like any other plant
        end
        local grow = core.registered_nodes[node.name].grow
        if grow then
            grow(pos, node)
        end
    end,
})

-- ======================================================================
-- 4. ABM: MATURE ORBPLANTS CALL DOWN WARP STORMS
-- ======================================================================

-- A mature orbplant summons a warp storm somewhere within a spherical radius
-- of itself. On average that happens once per ORBPLANT_STORM_EVERY_SECONDS
-- per plant: with interval I, a chance of "1 in N" per check means an event
-- every I * N seconds, so we derive N from the target period.
local STORM_CHANCE = math.max(1, math.floor(ORBPLANT_STORM_EVERY_SECONDS / ABM_INTERVAL))

core.register_abm({
    label = "Orbplant warp storms",
    nodenames = { "nh_warpstorms:orbplant_" .. ORBPLANT_STAGES },
    interval = ABM_INTERVAL,
    chance = STORM_CHANCE,
    action = function(pos)
        if not sbz_api.spawn_warp_storm_at then
            return
        end

        -- A random point inside a sphere of the given radius around the
        -- plant. The azimuth is uniform and the distance is r * sqrt(u),
        -- which fills the sphere uniformly instead of crowding its centre.
        local azimuth = math.random() * 2 * math.pi
        local elevation = math.random() * 2 * math.pi
        local dist = ORBPLANT_STORM_RADIUS * math.sqrt(math.random())

        local center = vector.add(pos, {
            x = dist * math.cos(azimuth) * math.sin(elevation),
            y = dist * math.cos(elevation),
            z = dist * math.sin(azimuth) * math.sin(elevation),
        })

        sbz_api.spawn_warp_storm_at(center)
    end,
})
