--[[
    warp_storm.lua
    ==============

    Warp storms for Skyblock: Zero - random lightning storms that briefly
    appear near a player, strike their island and rearrange it a little.

    A warp storm ...
      1. ... picks a random spot close to a random online player and reads
         a cuboid around it (its side length depends on the storm severity)
         with a VoxelManip.
      2. ... spawns several jagged lightning "bolts", each growing from the
         TOP of the cuboid downwards (like a tree), into air nodes only.
      3. ... if the cuboid contains non-air blocks, up to N of them are
         teleported to random empty spots (using the game's high-level mover
         so machines / pipes / inventories keep all their contents) and up
         to N blocks of "warp flesh" may materialise.
      4. ... the lightning flickers through two animation frames, is tinted
         in one of three severity colours (mild green, storm orange, rare
         purple) shared by every bolt of the same storm, deals damage, and
         vanishes again shortly afterwards (handled by an ABM).
      5. ... motes spawn scattered through the whole volume, sink slowly and
         fade mid-air, so they sprinkle through the storm next to the bolts
         instead of raining down on it from above.

    The three severities are defined in STORM_TYPES: the rarer the storm
    the bigger its cuboid and the more blocks it displaces / flesh it grows.

    Every tunable number lives in one place - the constant block right at
    the top - and is written in human terms (hours, seconds, "1 in 8", ...)
    instead of raw engine numbers.
--]]

-- ======================================================================
-- 0. TUNABLE CONSTANTS (adjust these, not the code below)
-- ======================================================================

-- How often a warp storm strikes, on average. "Once every 2 hours".
local STORM_EVERY_HOURS = 0.5

-- Storms do not run like clockwork: each one is delayed by +/- this
-- fraction of the average interval (0.5 = between -50% and +50%).
local STORM_INTERVAL_JITTER = 0.5

-- How far (in nodes) a storm may appear from the player it picks.
local STORM_MIN_DISTANCE = 5
local STORM_MAX_DISTANCE = 250

-- Warp storms come in three flavours, one per bolt colour. Each flavour is a
-- severity: the higher the severity, the bigger the affected cuboid, the more
-- blocks it displaces and the more warp flesh it grows - but the rarer it is
-- (weight is on a 0-100 scale where higher = more frequent).
--   * mild     - pale green,  small area, gentle warping,  very common
--   * moderate - storm orange, medium area (the classic storm), occasional
--   * severe   - storm purple, large area, heavy warping,  rare
-- area_size is the side length of the affected cuboid; it is always a cube.
local STORM_TYPES = {
    {
        name = "mild",
        hex = "#93ff7f",             -- pale warp-green
        weight = 60,                 -- ~60% of all storms
        area_size = 5,
        min_bolts = 2,
        max_bolts = 3,
        bolt_min_length = 3,
        bolt_max_length = 6,
        max_moved_blocks = 2,
        move_chance_1_in = 12,
        max_flesh_blocks = 2,
        flesh_chance_1_in = 12,
        rain_per_second = 8,
    },
    {
        name = "moderate",
        hex = "#ffa53d",             -- the classic storm-orange
        weight = 30,                 -- ~30% of all storms
        area_size = 8,
        min_bolts = 3,
        max_bolts = 4,
        bolt_min_length = 4,
        bolt_max_length = 8,
        max_moved_blocks = 3,
        move_chance_1_in = 8,
        max_flesh_blocks = 3,
        flesh_chance_1_in = 8,
        rain_per_second = 12,
    },
    {
        name = "severe",
        hex = "#b689ff",             -- deep storm-purple
        weight = 10,                 -- ~10% of all storms
        area_size = 12,
        min_bolts = 4,
        max_bolts = 6,
        bolt_min_length = 6,
        bolt_max_length = 12,
        max_moved_blocks = 6,
        move_chance_1_in = 4,
        max_flesh_blocks = 6,
        flesh_chance_1_in = 4,
        rain_per_second = 18,
    },
}

-- How long each bolt of lightning stays before disappearing. The rain below
-- is timed to finish at exactly this moment so no mote outlives the storm.
local LIGHTNING_LIFETIME = 18 -- seconds

-- Health removed per second while a player stands inside a bolt.
local LIGHTNING_DAMAGE = 6

-- Brightness of the lightning itself (0-14, 14 equals full daylight).
local LIGHTNING_LIGHT = 12

-- A bolt kinks sideways with this probability at every step while growing
-- down (that makes the "tree"). Bolt counts and lengths live in STORM_TYPES.
local BOLT_BRANCH_CHANCE = 0.3 -- 30% per step

-- The storm "rains" motes: particles spawn scattered through the whole
-- storm volume, sink slowly and fade mid-air, so they sprinkle THROUGH the
-- storm (next to the bolts) instead of raining down on it from above. The
-- spawn rate is per storm type (it grows with severity).
local RAIN_MIN_SPEED = 1 -- slowest sink, nodes/second
local RAIN_MAX_SPEED = 3 -- fastest sink, nodes/second
local RAIN_MIN_FADE = 0.4 -- earliest a mote fades, seconds after spawn
local RAIN_MAX_FADE = 1.2 -- latest a mote fades (keeps motes inside the volume)

-- How long (seconds) a storm centre stays "active" for mote catchers.
-- Slightly longer than LIGHTNING_LIFETIME so catchers near the tail end
-- still register the storm.
local STORM_ACTIVITY_DURATION = 20

-- Active storm volumes, exposed on sbz_api for the mote catcher.
-- Each entry: { minp = {x,y,z}, maxp = {x,y,z}, time = core.get_us_time() }
-- minp/maxp are the literal storm volume; consumers negotiate their own
-- reach (the mote catcher expands it by a margin when checking).
-- Consumers treating a storm as "gone" prune entries older than
-- sbz_api.storm_activity_duration_us themselves.
local active_storms = {}
sbz_api.active_storms = active_storms
sbz_api.storm_activity_duration_us = STORM_ACTIVITY_DURATION * 1e6

-- ======================================================================
-- 1. LIGHTNING NODE SETUP
-- ======================================================================

-- The two animation frames used by the two bolt "types".
-- Type A flickers between lightn1.png and lightn2.png,
-- type B flickers between lightn3.png and lightn4.png.
-- (lightn5.png is a spare variant and is not used by the storms.)
local BOLT_A_FRAMES = { "lightn1.png", "lightn2.png" }
local BOLT_B_FRAMES = { "lightn3.png", "lightn4.png" }

-- VARIANT_HEX[i] = "#rrggbb" tint for storm severity i (see STORM_TYPES).
local VARIANT_HEX = {}
for i = 1, #STORM_TYPES do
    VARIANT_HEX[i] = STORM_TYPES[i].hex
end

-- Names of the registered nodes for each severity (two per severity, one per
-- bolt "type"). These get stored so the storm code knows what to place.
local LIGHTNING_A_NAMES = {}
local LIGHTNING_B_NAMES = {}

-- Build one tile that animates between frame_top and frame_bottom:
-- `[combine` stacks both 16x16 frames into a single 16x32 sheet, `[multiply`
-- tints the whole sheet with the storm's colour, and vertical_frames replays
-- the two-frame animation in a loop (like a flickering bolt).
local function bolt_tile(frame_top, frame_bottom, hex)
    local name = "[combine:16x32:0,0=" .. frame_top .. ":0,16=" .. frame_bottom
        .. "^[multiply:" .. hex
    return {
        name = name,
        animation = {
            type = "vertical_frames",
            aspect_w = 16,
            aspect_h = 16,
            length = 0.6, -- seconds for the full flicker cycle
        },
    }
end

local LIGHTNING_SOUNDS = {
    dig = { name = "gen_zap_short", gain = 0.6, pitch = 1.0 },
    dug = { name = "gen_zap_short", gain = 0.8, pitch = 1.2 },
    place = { name = "gen_simple_charged_field_placement_zap", gain = 0.6, pitch = 1.0 },
}

-- Shared node definition for both bolt types. The only difference between
-- the two is which animation frames they use.
local function make_lightning_definition(frames, hex)
    return {
        description = "Warp Lightning",
        drawtype = "plantlike", -- drawn flat, exactly like plants / grass
        tiles = { bolt_tile(frames[1], frames[2], hex) },
        inventory_image = frames[1] .. "^[multiply:" .. hex,
        paramtype = "light", -- the node may receive and emit light
        light_source = LIGHTNING_LIGHT,
        sunlight_propagates = true, -- do not block the sun
        walkable = false, -- no collision: the player falls right through
        buildable_to = true, -- placing a block over it replaces it
        use_texture_alpha = "clip", -- keep the bolt's transparency
        damage_per_second = LIGHTNING_DAMAGE, -- zaps a player standing inside
        groups = {
            skyblktwo_warp_lightning = 1, -- lets the decay ABM find every bolt
            not_in_creative_inventory = 1,
            dig_immediate = 3,
        },
        drop = "", -- digging a bolt gives nothing
        sounds = LIGHTNING_SOUNDS,
    }
end

for i = 1, #STORM_TYPES do
    local hex = VARIANT_HEX[i]
    LIGHTNING_A_NAMES[i] = "skyblktwo:warp_lightning_a_" .. i
    LIGHTNING_B_NAMES[i] = "skyblktwo:warp_lightning_b_" .. i
    core.register_node(LIGHTNING_A_NAMES[i], make_lightning_definition(BOLT_A_FRAMES, hex))
    core.register_node(LIGHTNING_B_NAMES[i], make_lightning_definition(BOLT_B_FRAMES, hex))
end

-- Content ids of every registered bolt variant, so VoxelManip cleanup knows
-- exactly which nodes in a chunk are lightning and may be swapped back to air.
-- This is what lets bolts die even inside mapblocks that are rendered but not
-- active enough for the decay ABM to run (see section 5 below).
local LIGHTNING_CONTENT_IDS = {}
for i = 1, #LIGHTNING_A_NAMES do
    LIGHTNING_CONTENT_IDS[core.get_content_id(LIGHTNING_A_NAMES[i])] = true
    LIGHTNING_CONTENT_IDS[core.get_content_id(LIGHTNING_B_NAMES[i])] = true
end

local WARP_FLESH_SOUNDS = {
    dig = { name = "foley_matter_hit_thunky", gain = 0.8, pitch = 0.8 },
    dug = { name = "mix_sad_crackly_poof", gain = 1.0, pitch = 0.9 },
    place = { name = "foley_matter_hit_thunky", gain = 0.6, pitch = 0.8 },
}

local WARP_FLESH_GROUPS = {
    cracky = 2,
    oddly_breakable_by_hand = 2,
    not_in_creative_inventory = 1,
}

-- The storm may leave behind one of two fleshy variants.
local WARP_FLESH_VARIANTS = {
    "skyblktwo:warp_flesh",
    "skyblktwo:warp_meat",
}

core.register_node("skyblktwo:warp_flesh", {
    description = "Warp Flesh",
    tiles = { "fleshblock.png" },
    groups = WARP_FLESH_GROUPS,
    sounds = WARP_FLESH_SOUNDS,
    is_ground_content = false,
})

core.register_node("skyblktwo:warp_meat", {
    description = "Warp Meat",
    tiles = {
        {
            name = "meat.png",
            animation = {
                type = "vertical_frames",
                aspect_w = 16,
                aspect_h = 16,
                length = 1.0,
            },
        },
    },
    groups = WARP_FLESH_GROUPS,
    sounds = WARP_FLESH_SOUNDS,
    is_ground_content = false,
})

-- ======================================================================
-- 2. ABM: make the lightning disappear
-- ======================================================================

-- While a bolt exists this ABM counts its age in node metadata until
-- LIGHTNING_LIFETIME seconds have passed, then removes the bolt. Because
-- the counter is stored in the node, a server restart can not accidentally
-- resurrect or "freeze" bolts. (The motes that rain through the storm are
-- spawned by a single particlespawner when the storm manifests; see
-- spawn_warp_storm_at step 4.)
core.register_abm({
    label = "Warp lightning decay",
    nodenames = { "group:skyblktwo_warp_lightning" },
    interval = 1, -- run once per second ...
    chance = 1, -- ... for every bolt in loaded mapblocks
    action = function(pos, node)
        local meta = core.get_meta(pos)

        -- Age the bolt; remove it once it has lived long enough.
        local age = meta:get_int("skyblktwo:lightning_age") + 1
        meta:set_int("skyblktwo:lightning_age", age)
        if age >= LIGHTNING_LIFETIME then
            core.remove_node(pos)
        end
    end,
})

-- ======================================================================
-- 2b. GUARANTEED BOLT CLEANUP (works on inactive / far-away blocks)
-- ======================================================================

-- Bolts are supposed to vanish after LIGHTNING_LIFETIME seconds. The decay
-- ABM above only runs on ACTIVE mapblocks (those near a player), so a storm
-- that manifests inside a visible but inactive chunk would otherwise stay
-- frozen there forever. Because the bolts were placed with a VoxelManip, the
-- same tool can erase them: a VoxelManip reads and writes map data regardless
-- of whether a block is active, loaded or far away.
--
-- This callback is fire-and-forget and idempotent: if the block was active
-- and the ABM already removed a bolt, its position is simply air now and the
-- pass leaves it alone.
local function erase_bolts_at(positions)
    if not positions or #positions == 0 then
        return
    end

    -- Keep the read cuboid tight: one mapblock around the whole bolt set is
    -- plenty (bolts never stray farther than the storm volume from centre).
    local minp = vector.new(positions[1])
    local maxp = vector.new(positions[1])
    for i = 2, #positions do
        for _, axis in ipairs({ "x", "y", "z" }) do
            minp[axis] = math.min(minp[axis], positions[i][axis])
            maxp[axis] = math.max(maxp[axis], positions[i][axis])
        end
    end

    local manip = core.get_voxel_manip()
    local emin, emax = manip:read_from_map(minp, maxp)
    local data = manip:get_data()
    local area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
    local air = core.CONTENT_AIR

    local changed = false
    for i = 1, #positions do
        local idx = area:indexp(positions[i])
        if LIGHTNING_CONTENT_IDS[data[idx]] then
            data[idx] = air
            changed = true
        end
    end

    if changed then
        manip:set_data(data)
        manip:write_to_map(true) -- true = also recalculate light
    end
end

-- ======================================================================
-- 3. STORM PLACEMENT
-- ======================================================================

local function hash(pos)
    return core.hash_node_position(pos)
end

-- Pick where a storm will appear: somewhere horizontally near a random
-- online player. No ground scan is needed here because this game happens in
-- open space and storms are allowed to manifest in mid-air.
local function choose_storm_center(players)
    local player = players[math.random(#players)]
    local ppos = player:get_pos()
    if not ppos then
        return nil
    end

    -- Random direction + distance from the player.
    local angle = math.random() * 2 * math.pi
    local dist = STORM_MIN_DISTANCE + math.random() * (STORM_MAX_DISTANCE - STORM_MIN_DISTANCE)
    local cx = math.floor(ppos.x + math.cos(angle) * dist)
    local cz = math.floor(ppos.z + math.sin(angle) * dist)

    return { x = cx, y = math.floor(ppos.y), z = cz }
end

-- The storm cuboid is wider horizontally than it is tall, giving bolts a
-- chance to spread. Vertically it reaches a little below the surface so
-- bolts "grow" from the top down and stand on the ground.
local function storm_volume(center, area_size)
    local half = math.floor(area_size / 2)
    local height = area_size + 3
    local minp = {
        x = center.x - half,
        y = center.y - 1,
        z = center.z - half,
    }
    local maxp = {
        x = minp.x + area_size - 1,
        y = minp.y + height - 1,
        z = minp.z + area_size - 1,
    }
    return minp, maxp
end

-- Read the whole storm cuboid through a VoxelManip and split its nodes into
-- "air" (where lightning/flesh can appear) and "solid" (pre-existing blocks
-- that may be warped away). The manipulator/data are returned as well so the
-- lightning can be written back in a single pass.
local function scan_storm_area(minp, maxp)
    local manip = core.get_voxel_manip()
    local emin, emax = manip:read_from_map(minp, maxp) -- may expand to block borders
    local data = manip:get_data()
    local area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })

    local air_list = {}
    local air_map = {} -- hashed positions, so membership tests are fast
    local solid_positions = {}

    for x = minp.x, maxp.x do
        for y = minp.y, maxp.y do
            for z = minp.z, maxp.z do
                local cid = data[area:index(x, y, z)]
                if cid == core.CONTENT_AIR then
                    local pos = { x = x, y = y, z = z }
                    air_list[#air_list + 1] = pos
                    air_map[hash(pos)] = true
                elseif cid ~= core.CONTENT_IGNORE then
                    solid_positions[#solid_positions + 1] = { x = x, y = y, z = z }
                end
            end
        end
    end

    return {
        manip = manip,
        area = area,
        data = data,
        air_list = air_list,
        air_map = air_map,
        solid_positions = solid_positions,
    }
end

-- Decide where bolts go. Each bolt is a jagged line that starts at the top
-- of the cuboid and grows downwards, kinking sideways every now and then so
-- it looks like a lightning "tree". Bolts are allowed to use air nodes only,
-- and the two bolt types alternate along the bolt for visual variety.
local function build_lightning_plan(minp, maxp, scan, ty)
    local plan = {}
    local used = {}
    local bolt_count = math.random(ty.min_bolts, ty.max_bolts)

    for _ = 1, bolt_count do
        local pos = {
            x = minp.x + math.random(0, ty.area_size - 1),
            y = maxp.y,
            z = minp.z + math.random(0, ty.area_size - 1),
        }
        local length = math.random(ty.bolt_min_length, ty.bolt_max_length)

        for step = 1, length do
            if pos.y < minp.y then
                break -- grew through the bottom of the cuboid
            end

            local h = hash(pos)
            if scan.air_map[h] and not used[h] then
                used[h] = true
                plan[#plan + 1] = {
                    pos = { x = pos.x, y = pos.y, z = pos.z },
                    type_a = (step % 2 == 1), -- alternate bolt types
                }
            end

            -- Opportunity to "branch": kink the bolt sideways one node.
            if step < length and math.random() < BOLT_BRANCH_CHANCE then
                local dir = math.random() < 0.5 and -1 or 1
                if math.random() < 0.5 then
                    pos.x = math.max(minp.x, math.min(maxp.x, pos.x + dir))
                else
                    pos.z = math.max(minp.z, math.min(maxp.z, pos.z + dir))
                end
            end

            pos.y = pos.y - 1 -- grow downwards
        end
    end

    return plan
end

-- Grab a free air position that has not been claimed yet, and mark it used.
-- Returns nil when the cuboid has no more free air left.
local function take_free_air(scan, taken)
    local free = {}
    for i = 1, #scan.air_list do
        local pos = scan.air_list[i]
        local h = hash(pos)
        if not taken[h] then
            free[#free + 1] = pos
        end
    end
    if #free == 0 then
        return nil
    end
    local pos = free[math.random(#free)]
    taken[hash(pos)] = true
    return pos
end

-- Decide which pre-existing blocks get teleported. The storm type decides
-- how many are picked, each moving only if its "1 in N" chance passes, to a
-- random free air spot. Using the game's high-level mover keeps machine
-- contents intact.
local function plan_block_moves(scan, taken, ty)
    local moves = {}
    if #scan.solid_positions == 0 then
        return moves -- nothing pre-existing to warp
    end

    -- Work on a private copy so storms may re-use the scan data.
    local solids = table.copy(scan.solid_positions)
    for _ = 1, ty.max_moved_blocks do
        if #solids == 0 then
            break
        end
        local picked = table.remove(solids, math.random(#solids))
        if math.random() < 1 / ty.move_chance_1_in then
            local target = take_free_air(scan, taken)
            if target then
                moves[#moves + 1] = { from = picked, to = target }
            end
        end
    end
    return moves
end

-- Decide where warp flesh appears. Same "1 in N per attempt" pattern; only
-- happens when the cuboid actually contained pre-existing blocks.
local function plan_warp_flesh(scan, taken, ty)
    local spots = {}
    if #scan.solid_positions == 0 then
        return spots
    end
    for _ = 1, ty.max_flesh_blocks do
        if math.random() < 1 / ty.flesh_chance_1_in then
            local target = take_free_air(scan, taken)
            if target then
                spots[#spots + 1] = target
            end
        end
    end
    return spots
end

-- Roll which severity strikes: weighted so mild storms are common and severe
-- ones are rare. Returns the 1-based index into STORM_TYPES.
local function pick_storm_type()
    local total = 0
    for i = 1, #STORM_TYPES do
        total = total + STORM_TYPES[i].weight
    end
    local roll = math.random() * total
    for i = 1, #STORM_TYPES do
        roll = roll - STORM_TYPES[i].weight
        if roll <= 0 then
            return i
        end
    end
    return #STORM_TYPES -- fallback (e.g. empty table)
end

-- Spawn a warp storm with its cuboid centred on the given point. The ambient
-- scheduler hands it a random player offset; the orbplant (orbplant.lua)
-- hands it a spot near the plant itself, so it is exposed on sbz_api below.
local function spawn_warp_storm_at(center)
    if not center then
        return
    end

    -- Each storm is one of the three severities: colour, area and warping
    -- are all set by STORM_TYPES. Every bolt and every spark shares it.
    local variant = pick_storm_type()
    local ty = STORM_TYPES[variant]
    local hex = ty.hex

    local minp, maxp = storm_volume(center, ty.area_size)
    local scan = scan_storm_area(minp, maxp)

    -- 1. Plan the lightning bolts ...
    local bolt_plan = build_lightning_plan(minp, maxp, scan, ty)

    -- Reserve bolt positions so the warping below can not collide with them.
    local taken = {}
    for i = 1, #bolt_plan do
        taken[hash(bolt_plan[i].pos)] = true
    end

    -- 2. Only warp terrain if the scanned cube already contains real blocks.
    --    This keeps completely empty space from getting polluted with flesh.
    local moves = {}
    local flesh_spots = {}
    if #scan.solid_positions > 0 then
        moves = plan_block_moves(scan, taken, ty)
        flesh_spots = plan_warp_flesh(scan, taken, ty)
    end

    -- 3. Write every bolt into the VoxelManip data in one pass ...
    local data = scan.data
    for i = 1, #bolt_plan do
        local bolt = bolt_plan[i]
        local name = bolt.type_a and LIGHTNING_A_NAMES[variant] or LIGHTNING_B_NAMES[variant]
        data[scan.area:indexp(bolt.pos)] = core.get_content_id(name)
    end
    scan.manip:set_data(data)
    scan.manip:write_to_map(true) -- true = also recalculate light

    -- 4. Tag each bolt with its age counter.  Also remember every bolt
    --    position so a scheduled cleanup can erase them even if their
    --    mapblock never becomes active (see section 2b).
    local bolt_positions = {}
    for i = 1, #bolt_plan do
        bolt_positions[i] = bolt_plan[i].pos
        local meta = core.get_meta(bolt_plan[i].pos)
        meta:set_int("skyblktwo:lightning_age", 0)
    end

    -- 4b. Rain: motes spawn scattered anywhere inside the storm volume, sink a
    --    little and fade, so they drift through the storm next to the bolts
    --    instead of raining down on it from above. The shower STOPS early
    --    enough that its last motes fade at just about the same moment the
    --    last bolt disappears - the storm always gets the last word, never
    --    the particles.
    local rain_time = LIGHTNING_LIFETIME - RAIN_MAX_FADE
    core.add_particlespawner({
        amount = math.floor(ty.rain_per_second * rain_time),
        time = rain_time,
        minpos = { x = minp.x, y = minp.y, z = minp.z },
        maxpos = { x = maxp.x, y = maxp.y, z = maxp.z },
        minvel = { x = 0, y = -RAIN_MAX_SPEED, z = 0 },
        maxvel = { x = 0, y = -RAIN_MIN_SPEED, z = 0 },
        minexptime = RAIN_MIN_FADE,
        maxexptime = RAIN_MAX_FADE,
        minsize = 1,
        maxsize = 2,
        texture = "mote.png^[multiply:" .. hex,
        glow = 14,
    })

    -- The decay ABM handles active blocks; this scheduled pass guarantees
    -- every bolt disappears after LIGHTNING_LIFETIME even inside chunks that
    -- stay visible-but-inactive (or completely unloaded) the whole time. It
    -- intentionally runs slightly later than the ABM so active blocks are
    -- usually already cleaned and the extra pass is a cheap no-op.
    core.after(LIGHTNING_LIFETIME + 1, function()
        erase_bolts_at(bolt_positions)
    end)

    -- 5. Teleport pre-existing blocks. High-level API keeps inventories and
    --    machine/piping state intact, which is exactly what we want.
    for i = 1, #moves do
        if sbz_api and sbz_api.move_node then
            sbz_api.move_node(moves[i].from, moves[i].to)
        else
            core.log(
                "warning",
                "[skyblktwo] warp storm: sbz_api.move_node is unavailable, skipping a block move"
            )
        end
    end

    -- 6. Materialise a random flesh variant with high-level set_node so it is
    --    fully constructed like a normal placed block.
    for i = 1, #flesh_spots do
        core.set_node(flesh_spots[i], {
            name = WARP_FLESH_VARIANTS[math.random(#WARP_FLESH_VARIANTS)],
        })
    end

    -- 7. Record the storm volume so mote catchers can detect it.
    --    Prune entries older than STORM_ACTIVITY_DURATION first.
    local now = core.get_us_time()
    for i = #active_storms, 1, -1 do
        if (now - active_storms[i].time) > STORM_ACTIVITY_DURATION * 1e6 then
            table.remove(active_storms, i)
        end
    end
    active_storms[#active_storms + 1] = {
        minp = { x = minp.x, y = minp.y, z = minp.z },
        maxp = { x = maxp.x, y = maxp.y, z = maxp.z },
        time = now,
    }

    -- 8. A touch of ambience and a log line.
    core.sound_play({ name = "gen_zap_short", gain = 0.7, max_hear_distance = 48 }, { pos = center })
    core.log(
        "action",
        "[skyblktwo] Warp storm manifested at " .. core.pos_to_string(center)
            .. " (" .. ty.name .. " storm, " .. #bolt_plan .. " bolts)"
    )
end

-- Ambient storms: pick a random spot near a random online player and storm
-- them. The orbplant uses spawn_warp_storm_at() directly instead.
local function spawn_warp_storm()
    local players = core.get_connected_players()
    if #players == 0 then
        return -- nothing on the server worth storming
    end

    local center = choose_storm_center(players)
    if not center then
        return
    end

    spawn_warp_storm_at(center)
end

-- Let other nodes (the orbplant) trigger a storm at a position of their own
-- choice instead of a random one near a player.
sbz_api.spawn_warp_storm_at = spawn_warp_storm_at

-- ======================================================================
-- 3b. STORM TRIGGER BLOCK
-- ======================================================================

-- A block that summons a warp storm when punched. Useful for testing or
-- building "storm callers" in-game.
core.register_node("skyblktwo:storm_trigger", {
    description = "Warp Storm Trigger",
    tiles = {
        "skyblktwo_storm_trigger_top.png",
        "skyblktwo_storm_trigger_bottom.png",
        "skyblktwo_storm_trigger_side.png",
    },
    groups = { cracky = 2, oddly_breakable_by_hand = 2 },
    sounds = {
        dig = { name = "gen_zap_short", gain = 0.6, pitch = 1.0 },
        dug = { name = "gen_zap_short", gain = 0.8, pitch = 1.2 },
    },
    on_punch = function(pos, node, puncher, pointed_thing)
        if puncher and puncher:is_player() then
            local ppos = puncher:get_pos()
            local center = {
                x = math.floor(ppos.x),
                y = math.floor(ppos.y),
                z = math.floor(ppos.z),
            }
            spawn_warp_storm_at(center)
            core.chat_send_player(puncher:get_player_name(), "Warp storm summoned!")
        end
    end,
})

-- ======================================================================
-- 4. SCHEDULING
-- ======================================================================

-- Re-arm the next storm once this one has happened. The delay is based on
-- STORM_EVERY_HOURS and jiggled by STORM_INTERVAL_JITTER so storms do not
-- strike at perfectly regular intervals.
local function schedule_next_storm()
    local average_seconds = STORM_EVERY_HOURS * 60 * 60
    local jitter = STORM_INTERVAL_JITTER * (math.random() * 2 - 1)
    local delay = average_seconds * (1 + jitter)

    core.after(delay, function()
        spawn_warp_storm()
        schedule_next_storm()
    end)
end

-- Mods load in dependency order; waiting until they are all registered then
-- starting the schedule is the standard, safe place to begin.
core.register_on_mods_loaded(function()
    schedule_next_storm()
end)
