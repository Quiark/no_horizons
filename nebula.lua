--[[
    nebula.lua
    =========

    Filamentary nebula generator for Skyblock: Zero.

    A nebula is a cloud of `no_horizons:warp_glass` RADIUS blocks in radius,
    built out of three smooth noise fields:

        ENVELOPE  lobed silhouette, decides where the cloud is at all
        LANES     the *gaps*: a ridged field, subtracted
        STRANDS   internal density variation, without making new gaps

    Per voxel, with d = |p - C| / RADIUS:

        env  = smoothstep(1, 0.12, d) * (1 + SHAPE_AMT * ENVELOPE(p))
        lane = 1 - LANES(p)                       -- peaks on n's zero level sets
        str  = 1 - STRANDS(p)
        D    = env * (1 - clamp(LANE_DEPTH * (lane - LANE_T)))
                  * (STRAND_FLOOR + (1 - STRAND_FLOOR) * str)

    and a voxel becomes a block where D >= FILL.

    The `1 - |n|` trick is the whole point. Both ridged fields use
    `flags = "absvalue"`, which the engine applies *per octave, before
    weighting* (Noise::updateResults, src/noise.cpp), so |n| peaks at the
    extrema of the smooth noise. Thresholding |n| high therefore gives you
    blobs. `1 - |n|` peaks on the zero level sets of n, i.e. on **sheets**,
    which is what reads as a filament. A lane is the region |n| < LANE_T, so
    its thickness is 2 * LANE_T / |grad n|: thin where the noise is steep,
    thick where it is flat. No gradient is ever computed, and gap size is set
    by the single number LANE_T instead of by however the noise happens to
    fall. (Contrast contour-banding the value with frac(n*K), which builds
    shells around the *centre* - a preferred orientation, so it reads as a
    bubble or rings rather than as wisps.)

    Because both ridged fields are positively biased and their range depends
    on octaves/persist, LANE_T and FILL are not hardcoded numbers. A probe
    pass samples the three fields inside the ball and the thresholds are
    solved as percentiles, so the dials mean "LANE_FRACTION of the ball is
    gap" and "FILL_PCT of the ball is block". They are re-derived on every
    run, so changing octaves cannot silently break the tuning.

    Building goes through the bulk C++ noise path (ValueNoiseMap +
    get_3d_map_flat) in Y-slabs, because a 201^3 box is 8.1M voxels and
    per-voxel get_3d would take a minute. See build_nebula.

    See nebula.md for the design notes and the engine facts behind it.
--]]

local S = core.get_translator("no_horizons")
local NEON = "no_horizons:warp_glass"

-- ======================================================================
-- 1. FIELDS - every tunable in one table
-- ======================================================================

-- LANE_FRACTION  fraction of the ball carved away by lanes
-- LANE_DEPTH     how hard a lane bites; the cut is clamped at fully empty
-- STRAND_FLOOR   0 = strands do nothing, 1 = strands dominate the density
-- FILL_PCT       fraction of the ball that ends up as nodes
-- TIER_SPLIT     where the two colour cuts fall inside the filled fraction
-- SHAPE_AMT      how much ENVELOPE deforms the sphere
-- SLAB           Y-slab height for the bulk noise path. Must stay >= 1; 16
--                keeps the noise map small, the slabs are absolute-position
--                based so they are seamless whatever it is.
local FIELDS = {
    RADIUS = 100,
    SLAB = 16,
    SHAPE_AMT = 0.45,
    LANE_FRACTION = 0.30,
    LANE_DEPTH = 0.95,
    STRAND_FLOOR = 0.55,
    FILL_PCT = 0.08,
    TIER_SPLIT = { 0.34, 0.67 },

    -- Lobed non-spherical silhouette. Deliberately not absvalue: we want
    -- signed lobes, so one side of the cloud can bulge past the sphere.
    ENVELOPE = {
        spread = { 260, 200, 260 },
        octaves = 2,
        persist = 0.5,
        seed = 5011,
    },

    -- The gaps. Wavelengths 170, 85, 42.
    LANES = {
        spread = { 170, 130, 170 },
        octaves = 3,
        persist = 0.42,
        seed = 1723,
        flags = "absvalue",
    },

    -- Internal density and colour variation. Wavelengths 70, 35.
    STRANDS = {
        spread = { 70, 55, 70 },
        octaves = 2,
        persist = 0.5,
        seed = 8837,
        flags = "absvalue",
    },

    -- One colour byte per density tier. Order matters, lowest density first.
    TIER_COLOURS = {
        { hue = "violet", shade = "dark" },
        { hue = "indigo", shade = "medium" },
        { hue = "magenta", shade = "bright" },
    },
}

-- Probe pass size. 20k samples costs about 0.15s in Lua.
local PROBE_SAMPLES = 20000

-- Build the debug set on load, so a fresh world has nebulae without anyone
-- typing anything. Restarts are free: a site whose signature is already in
-- mod storage is skipped.
local PRIME_ON_START = true

-- ======================================================================
-- 2. THE EIGHT DEBUG SITES
-- ======================================================================

-- One nebula per octant: every combination of signs on x, y and z. Each
-- preset changes one thing (or one small group) against the baseline, so
-- the eight read as a controlled comparison rather than as eight random
-- clouds. Preset N is the octant with index N.
local LAYOUT = {
    XZ = 620, -- horizontal distance from origin
    Y = 240, -- vertical distance from origin
}

local PRESETS = {
    {
        name = "baseline",
        note = "plan defaults, the control to compare everything against",
        radius = 100,
    },
    {
        name = "lanes-open",
        note = "over half the ball is gap, lanes cut all the way to empty",
        radius = 100,
        lane_fraction = 0.55,
        lane_depth = 1.0,
        fill_pct = 0.10,
    },
    {
        name = "lanes-tight",
        note = "lanes barely cut, thin sheets through a dense cloud",
        radius = 80,
        lane_fraction = 0.10,
        lane_depth = 0.80,
        fill_pct = 0.12,
    },
    {
        name = "no-strands",
        note = "STRAND_FLOOR 0, internal density variation off",
        radius = 80,
        strand_floor = 0.0,
    },
    {
        name = "max-strands",
        note = "STRAND_FLOOR 0.95, strong banding without new gaps",
        radius = 60,
        strand_floor = 0.95,
    },
    {
        name = "lanes-fine",
        note = "lane field up to 4 octaves, short wavelengths",
        radius = 100,
        lane_octaves = 4,
        lane_persist = 0.48,
        lane_spread = { 120, 92, 120 },
    },
    {
        name = "lanes-coarse",
        note = "lane field down to 2 octaves, very broad sheets",
        radius = 130,
        lane_octaves = 2,
        lane_persist = 0.42,
        lane_spread = { 250, 190, 250 },
    },
    {
        name = "solid-blob",
        note = "no lanes at all, the uniform blob this design escapes",
        radius = 60,
        lane_fraction = 0.0,
        fill_pct = 0.14,
    },
}

-- A distinct hue per site so they are tellable apart in flight. The three
-- tiers are always dark, medium and bright of that hue.
local HUES = {
    "magenta",
    "fuchsia",
    "mulberry",
    "violet",
    "indigo",
    "azure",
    "cyan",
    "turquoise",
}

-- ======================================================================
-- 3. COLOUR BYTES
-- ======================================================================

-- unifieddyes' extended palette is shade-major, not hue-major: 24 hues per
-- row and 10 shade rows, so index = shade * 24 + hue over the range 0-239.
-- 240-255 is a greyscale ramp and is not wanted here. See
-- unifieddyes/color-tables.lua (gpidx_hues_extended, gpidx_shades_extended)
-- and unifieddyes.getpaletteidx() in api.lua.
local function palette_index(hue, shade)
    local h = unifieddyes.gpidx_hues_extended[hue]
    local s = unifieddyes.gpidx_shades_extended[shade]
    if not h or not s then
        return 240 -- white
    end
    return s * 24 + h
end

-- ======================================================================
-- 4. PARAM RESOLUTION
-- ======================================================================

-- Flat override keys. Anything not listed is ignored, which is what lets a
-- command line sweep a single dial without a server restart.
--   radius slab shape_amt lane_fraction lane_depth strand_floor fill_pct
--   lane_t fill                        raw thresholds, skip the percentile solve
--   tier_hue                           one hue name for all three tiers
--   env_<k> lane_<k> strand_<k>        k = spread octaves persist seed flags
local SCALAR_FIELDS = {
    radius = "RADIUS",
    slab = "SLAB",
    shape_amt = "SHAPE_AMT",
    lane_fraction = "LANE_FRACTION",
    lane_depth = "LANE_DEPTH",
    strand_floor = "STRAND_FLOOR",
    fill_pct = "FILL_PCT",
}

local NOISE_KEYS = { "spread", "octaves", "persist", "seed", "flags" }
local NOISE_FIELDS = { env = "envelope", lane = "lanes", strand = "strands" }

-- The engine reads noise_params.spread as a strict vector: it looks up x, y
-- and z by name, so a plain {a, b, c} table is read as three nils. offset, in
-- contrast, is a scalar ("expected number"). Accept either spread shape here
-- and always hand back {x =, y =, z =}.
local function v3(v)
    if type(v) == "table" then
        if v.x ~= nil or v.y ~= nil or v.z ~= nil then
            return { x = v.x or 0, y = v.y or 0, z = v.z or 0 }
        end
        return { x = v[1] or 0, y = v[2] or 0, z = v[3] or 0 }
    end
    return { x = v or 0, y = 0, z = 0 }
end

local function copy_np(spec)
    return {
        spread = v3(spec.spread),
        octaves = spec.octaves,
        persist = spec.persist,
        seed = spec.seed,
        flags = spec.flags,
        offset = spec.offset or 0,
        scale = spec.scale or 1,
    }
end

-- Merge FIELDS with a flat override table into a resolved parameter set.
local function resolve(opts)
    opts = opts or {}

    local p = {
        lane_t = tonumber(opts.lane_t),
        fill = tonumber(opts.fill),
        tier_split = { FIELDS.TIER_SPLIT[1], FIELDS.TIER_SPLIT[2] },
        np = {
            envelope = copy_np(FIELDS.ENVELOPE),
            lanes = copy_np(FIELDS.LANES),
            strands = copy_np(FIELDS.STRANDS),
        },
        colours = {},
        tier_param2 = { 240, 240, 240 },
    }

    for key, source in pairs(SCALAR_FIELDS) do
        local v = opts[key]
        p[key] = (v ~= nil) and v or FIELDS[source]
    end

    for prefix, field in pairs(NOISE_FIELDS) do
        local np = p.np[field]
        for _, k in pairs(NOISE_KEYS) do
            local v = opts[prefix .. "_" .. k]
            if v ~= nil then
                np[k] = (k == "spread") and v3(v) or v
            end
        end
    end

    for i = 1, 3 do
        local c = {}
        for k, v in pairs(FIELDS.TIER_COLOURS[i]) do
            c[k] = v
        end
        if opts.tier_hue then
            c.hue = opts.tier_hue
        end
        p.colours[i] = c
        p.tier_param2[i] = palette_index(c.hue, c.shade)
    end

    p.radius = math.max(4, math.floor(p.radius + 0.5))
    p.slab = math.max(1, math.min(math.floor(p.slab + 0.5), 2 * p.radius + 1))
    p.lane_fraction = math.min(1, math.max(0, p.lane_fraction))
    p.lane_depth = math.max(0, p.lane_depth)
    p.strand_floor = math.min(1, math.max(0, p.strand_floor))
    p.fill_pct = math.min(1, math.max(0, p.fill_pct))

    return p
end

-- ======================================================================
-- 5. THE DENSITY FUNCTION
-- ======================================================================

-- Inverted smoothstep: 1 at the centre, 0 at and beyond the radius.
local function envelope_falloff(d)
    local t = (1.0 - d) / 0.88 -- smoothstep(1.0, 0.12, d)
    if t <= 0 then
        return 0
    elseif t >= 1 then
        return 1
    end
    return t * t * (3 - 2 * t)
end

-- Fold three sampled fields into the density D. `fall` is
-- envelope_falloff(|p - C| / RADIUS), `env_noise` the raw ENVELOPE value and
-- `lane_t` the solved lane threshold. The lane cut is clamped at 1 so a lane
-- core is fully empty however deep LANE_DEPTH is, and so D stays >= 0 and
-- the percentile solve downstream stays meaningful.
local function density(p, lane_t, fall, env_noise, lane, strand)
    local env = fall * (1 + p.shape_amt * env_noise)
    if env <= 0 then
        return 0
    end
    if lane > lane_t then
        local cut = (lane - lane_t) * p.lane_depth
        env = env * (1 - (cut > 1 and 1 or cut))
    end
    return env * (p.strand_floor + (1 - p.strand_floor) * strand)
end

-- ======================================================================
-- 6. PROBE - thresholds as dials
-- ======================================================================

local function percentile(sorted, frac)
    local n = #sorted
    if n == 0 then
        return 0
    end
    local i = math.floor(frac * (n - 1) + 0.5) + 1
    if i < 1 then
        i = 1
    elseif i > n then
        i = n
    end
    return sorted[i]
end

-- Rejection-sample the ball uniformly in volume and collect the three fields.
--
-- ValueNoise and ValueNoiseMap agree exactly, which is what makes the
-- percentiles solved here describe the very field the build samples. Both
-- hash at np.seed + world_seed + octave: l_get_value_noise folds the world
-- seed into np.seed and then calls NoiseFractal3D with a per-call seed of 0,
-- while l_get_value_noise_map passes the world seed as the per-call seed and
-- leaves np.seed alone. Both then apply absvalue per octave, before weighting.
local function sample_fields(centre, p, count)
    local r = p.radius
    local r2 = r * r
    local rng = PcgRandom(p.np.lanes.seed)
    local n_env = core.get_value_noise(p.np.envelope)
    local n_lane = core.get_value_noise(p.np.lanes)
    local n_str = core.get_value_noise(p.np.strands)

    local envs, falls, lanes, strs = {}, {}, {}, {}
    local cx, cy, cz = centre.x, centre.y, centre.z
    local at = { x = 0, y = 0, z = 0 } -- reused: get_3d takes a position
    local i, got = 1, 0
    while got < count do
        local dx = rng:next(-r, r)
        local dy = rng:next(-r, r)
        local dz = rng:next(-r, r)
        local d2 = dx * dx + dy * dy + dz * dz
        if d2 <= r2 then
            got = got + 1
            at.x, at.y, at.z = cx + dx, cy + dy, cz + dz
            envs[i] = n_env:get_3d(at)
            falls[i] = envelope_falloff(math.sqrt(d2) / r)
            lanes[i] = 1 - n_lane:get_3d(at)
            strs[i] = 1 - n_str:get_3d(at)
            i = i + 1
        end
    end

    return envs, falls, lanes, strs
end

-- LANE_T first, because it feeds D; then FILL and the two colour cuts as
-- percentiles of D. Every threshold comes out of the data, not the source.
local function solve(centre, p)
    local envs, falls, lanes, strs = sample_fields(centre, p, PROBE_SAMPLES)

    local sorted_lanes = table.copy(lanes)
    table.sort(sorted_lanes)
    local lane_t = p.lane_t or percentile(sorted_lanes, 1 - p.lane_fraction)

    local dens = {}
    for i = 1, #envs do
        dens[i] = density(p, lane_t, falls[i], envs[i], lanes[i], strs[i])
    end
    table.sort(dens)

    local fill = p.fill or percentile(dens, 1 - p.fill_pct)
    local t1 = percentile(dens, p.fill_pct + (1 - p.fill_pct) * p.tier_split[1])
    local t2 = percentile(dens, p.fill_pct + (1 - p.fill_pct) * p.tier_split[2])
    if t1 < fill then
        t1 = fill
    end
    if t2 < t1 then
        t2 = t1
    end

    return {
        lane_t = lane_t,
        fill = fill,
        tier1 = t1,
        tier2 = t2,
        lanes = sorted_lanes,
        density = dens,
        samples = #envs,
    }
end

local function report_line(name, sorted, fracs)
    local parts = {}
    for _, f in pairs(fracs) do
        parts[#parts + 1] = ("p%02d %.3f"):format(f * 100, percentile(sorted, f))
    end
    return ("  %-8s %s"):format(name, table.concat(parts, "  "))
end

-- ======================================================================
-- 7. BUILD
-- ======================================================================

-- Nodes that are free to overwrite. warp_glass itself counts as free, so a
-- re-render updates colours in place; anything else is a player build or a
-- planet and is left alone, which is how the debug set refuses to swallow
-- the island. The count of skipped voxels comes back in the result.
local FREE = { [core.CONTENT_AIR] = true }
if core.CONTENT_IGNORE then
    FREE[core.CONTENT_IGNORE] = true
end

-- Walk the ball in Y-slabs, refilling three bulk noise maps and one
-- VoxelManip per slab, and hand every voxel inside the disc to cb:
--
--   cb(env, lane, strand, data, param2, base_n, base_v, vstride, nrow, rows,
--      fall, d2)
--
-- env/lane/strand are the reusable noise buffers, data/param2 the reusable
-- voxelmanip buffers. base_n indexes the noise buffers (x fastest, then y,
-- then z, stride nrow). base_v indexes the voxelmanip data (1-based, x
-- fastest, then y, then z, stride vstride). fall and d2 are constant down a
-- column, so the sqrt and the smoothstep are paid once per (x, z).
local function each_slab(p, centre, cb)
    local r = p.radius
    local n = 2 * r + 1
    local slab = p.slab
    local minv = { x = centre.x - r, y = centre.y - r, z = centre.z - r }

    -- The noise maps need the mapgen environment, so they cannot be built at
    -- load time. Building them per run is what makes retuning a dial.
    local size = { x = n, y = slab, z = n }
    local map_env = core.get_value_noise_map(p.np.envelope, size)
    local map_lane = core.get_value_noise_map(p.np.lanes, size)
    local map_str = core.get_value_noise_map(p.np.strands, size)

    local buf_env, buf_lane, buf_str = {}, {}, {}
    local data_buf, param2_buf = {}, {}

    local noise_z_stride = n * slab
    local inv_r = 1 / r

    for oy = 0, n - 1, slab do
        local rows = math.min(slab, n - oy)
        -- Clamp the horizontal radius to the disc the ball has at this
        -- slab's mid height. Cuts the loop from n*rows*n to the ball volume.
        local dy = oy + (rows - 1) * 0.5 - r
        local hr2 = r * r - dy * dy
        if hr2 > 0 then
            local minp = { x = minv.x, y = minv.y + oy, z = minv.z }
            local maxp = { x = minv.x + n - 1, y = minp.y + rows - 1, z = minv.z + n - 1 }

            -- emerge = true by default, so this also works in unloaded space.
            -- A fresh VoxelManip per slab is required: read_from_map adds to
            -- the loaded area rather than replacing it.
            local vm = core.get_voxel_manip(minp, maxp)
            vm:read_from_map(minp, maxp)
            local emin, emax = vm:get_emerged_area()
            vm:get_data(data_buf)
            vm:get_param2_data(param2_buf)

            -- The emerged area is mapblock aligned, so it can be larger than
            -- the slab. Index off the returned edges rather than assuming.
            local ex = emax.x - emin.x + 1
            local ey = emax.y - emin.y + 1
            local xoff = minp.x - emin.x
            local yoff = minp.y - emin.y
            local zoff = (minp.z - emin.z) * ex * ey

            local origin = { x = minp.x, y = minp.y, z = minp.z }
            map_env:get_3d_map_flat(origin, buf_env)
            map_lane:get_3d_map_flat(origin, buf_lane)
            map_str:get_3d_map_flat(origin, buf_str)

            for z = 0, n - 1 do
                local zr2 = hr2 - (z - r) * (z - r)
                if zr2 > 0 then
                    local zbase_n = z * noise_z_stride
                    local zbase_v = zoff + (z * ex * ey)
                    for x = 0, n - 1 do
                        local r2 = zr2 - (x - r) * (x - r)
                        if r2 > 0 then
                            local d2 = r2 + dy * dy
                            local fall = envelope_falloff(math.sqrt(d2) * inv_r)
                            if fall > 0 then
                                cb(
                                    buf_env,
                                    buf_lane,
                                    buf_str,
                                    data_buf,
                                    param2_buf,
                                    x + 1 + zbase_n,
                                    xoff + yoff * ex + x + 1 + zbase_v,
                                    ex,
                                    n,
                                    rows,
                                    fall,
                                    d2
                                )
                            end
                        end
                    end
                end
            end

            vm:set_data(data_buf)
            vm:set_param2_data(param2_buf)
            -- true = also recalculate light. warp_glass is a light_source
            -- node, so without this the blocks keep the stale light the
            -- mapgen baked in and the nebula never actually glows.
            vm:write_to_map(true)
            vm:update_map() -- notify the clients
        end
    end
end

-- Render a nebula. Returns { blocks, skipped, ms, p, probe }.
local function build_nebula(centre, opts)
    local p = resolve(opts)
    local probe = solve(centre, p)
    local t0 = os.clock()

    local glass = core.get_content_id(NEON)
    local pr1, pr2, pr3 = p.tier_param2[1], p.tier_param2[2], p.tier_param2[3]
    local lane_t, lane_depth = probe.lane_t, p.lane_depth
    local fill, tier1, tier2 = probe.fill, probe.tier1, probe.tier2
    local sf, isf = p.strand_floor, 1 - p.strand_floor
    local shape = p.shape_amt
    local blocks, skipped = 0, 0

    each_slab(
        p,
        centre,
        function(env, lane_buf, str_buf, data, param2, base_n, base_v, vstride, nrow, rows, fall)
            local ni, vi = base_n, base_v
            for _ = 1, rows do
                local e = fall * (1 + shape * env[ni])
                -- The lane and strand factors are both <= 1 (absvalue noise
                -- is >= 0), so anything below the fill line here stays
                -- below it and the two reads can be skipped.
                if e >= fill then
                    local lane = 1 - lane_buf[ni]
                    if lane > lane_t then
                        local cut = (lane - lane_t) * lane_depth
                        e = e * (1 - (cut > 1 and 1 or cut))
                    end
                    if e >= fill then
                        local dens = e * (sf + isf * (1 - str_buf[ni]))
                        if dens >= fill then
                            local old = data[vi]
                            if old == glass or FREE[old] then
                                data[vi] = glass
                                -- TIER_COLOURS is ordered lowest density
                                -- first, so the faint outer wash is pr1 and
                                -- the dense core is the last, brightest one.
                                if dens >= tier2 then
                                    param2[vi] = pr3
                                elseif dens >= tier1 then
                                    param2[vi] = pr2
                                else
                                    param2[vi] = pr1
                                end
                                blocks = blocks + 1
                            else
                                skipped = skipped + 1
                            end
                        end
                    end
                end
                ni = ni + nrow
                vi = vi + vstride
            end
        end
    )

    return { blocks = blocks, skipped = skipped, ms = (os.clock() - t0) * 1000, p = p, probe = probe }
end

-- Air out the same bounds again, so a nebula can be re-rendered in place
-- while sweeping dials. Only warp_glass is touched.
local function clear_nebula(centre, opts)
    local p = resolve(opts)
    local t0 = os.clock()
    local glass = core.get_content_id(NEON)
    local removed = 0

    each_slab(
        p,
        centre,
        function(_, _, _, data, _, _, base_v, vstride, _, rows)
            local vi = base_v
            for _ = 1, rows do
                if data[vi] == glass then
                    data[vi] = core.CONTENT_AIR
                    removed = removed + 1
                end
                vi = vi + vstride
            end
        end
    )

    return { blocks = removed, ms = (os.clock() - t0) * 1000 }
end

-- ======================================================================
-- 8. ASCII DRY RUN
-- ======================================================================

-- The fast iteration loop: gap structure and fill fraction can be judged
-- from text without writing a single node.
--
--   #  filled, brightest tier
--   +  filled, mid or dark tier
--   -  not filled, but inside a lane (this is a gap)
--   .  not filled, inside the envelope, not a lane (thin skirt)
--   ' ' outside the envelope
local function slice(centre, p, probe, vertical, step)
    local n_env = core.get_value_noise(p.np.envelope)
    local n_lane = core.get_value_noise(p.np.lanes)
    local n_str = core.get_value_noise(p.np.strands)
    local r = p.radius
    local lane_t = probe.lane_t
    local lines = {}
    local at = { x = 0, y = 0, z = 0 } -- reused: get_3d takes a position

    for b = -r, r, step do
        local row = {}
        for a = -r, r, step do
            local dx, dy, dz
            if vertical then
                dx, dy, dz = a, b, 0
            else
                dx, dy, dz = a, 0, b
            end
            local d = math.sqrt(dx * dx + dy * dy + dz * dz) / r
            local ch = " "
            if d < 1 then
                at.x, at.y, at.z = centre.x + dx, centre.y + dy, centre.z + dz
                local fall = envelope_falloff(d)
                local env_noise = n_env:get_3d(at)
                if fall * (1 + p.shape_amt * env_noise) > 0 then
                    local lane = 1 - n_lane:get_3d(at)
                    local dens = density(p, lane_t, fall, env_noise, lane, 1 - n_str:get_3d(at))
                    if dens >= probe.fill then
                        ch = dens >= probe.tier2 and "#" or "+"
                    else
                        ch = lane > lane_t and "-" or "."
                    end
                end
            end
            row[#row + 1] = ch
        end
        lines[#lines + 1] = table.concat(row)
    end
    return lines
end

local function render_ascii(centre, opts)
    local p = resolve(opts)
    local probe = solve(centre, p)
    local step = math.max(1, math.ceil((2 * p.radius + 1) / 64))
    local out = {
        ("# top tier, + filled, - lane gap, . envelope only, blank empty (step %d)"):format(step),
        "--- horizontal slice at y = " .. centre.y .. " ---",
    }
    for _, l in pairs(slice(centre, p, probe, false, step)) do
        out[#out + 1] = l
    end
    out[#out + 1] = "--- vertical slice at z = " .. centre.z .. " ---"
    for _, l in pairs(slice(centre, p, probe, true, step)) do
        out[#out + 1] = l
    end
    return table.concat(out, "\n"), p, probe
end

-- ======================================================================
-- 9. SITES AND AUTOMATIC GENERATION
-- ======================================================================

local sites = {}

-- Site i takes its signs from the bits of i - 1: bit 0 is x, bit 1 is y,
-- bit 2 is z, so all eight octants are covered exactly once.
local function octant_signs(i)
    local b = i - 1
    local sx = (b % 2 == 0) and -1 or 1
    local sy = (b % 4 < 2) and -1 or 1
    local sz = (b < 4) and -1 or 1
    return sx, sy, sz
end

do
    for i = 1, 8 do
        local preset = PRESETS[i] or { name = "baseline" }
        local overrides = { tier_hue = HUES[i] }
        for k, v in pairs(preset) do
            if k ~= "name" and k ~= "note" then
                overrides[k] = v
            end
        end
        local sx, sy, sz = octant_signs(i)
        sites[i] = {
            id = i,
            name = preset.name,
            note = preset.note or "",
            pos = { x = sx * LAYOUT.XZ, y = sy * LAYOUT.Y, z = sz * LAYOUT.XZ },
            params = overrides,
        }
    end
end

-- Identity of a rendered site, so a restart can tell "already built" from
-- "built with different dials". Every parameter that reaches the voxels goes
-- in, in a fixed order. Computed once: register_on_generated runs this for
-- every generated chunk, so it must not allocate.
-- Bump when the voxel writing semantics change (index base, read/write
-- order, which layers get written). The signature is the cache key, so
-- without this a fixed build would keep serving the broken output.
local BUILD_VERSION = 6

local function site_signature(site)
    local p = resolve(site.params)
    local parts = {
        BUILD_VERSION,
        site.pos.x,
        site.pos.y,
        site.pos.z,
        p.radius,
        p.slab,
        p.shape_amt,
        p.lane_fraction,
        p.lane_depth,
        p.strand_floor,
        p.fill_pct,
        p.lane_t or "-",
        p.fill or "-",
        p.tier_split[1],
        p.tier_split[2],
    }
    for _, field in ipairs({ "envelope", "lanes", "strands" }) do
        local np = p.np[field]
        parts[#parts + 1] = table.concat({
            np.spread.x,
            np.spread.y,
            np.spread.z,
            np.octaves,
            np.persist,
            np.seed,
            np.flags or "-",
            np.offset,
            np.scale,
        }, ",")
    end
    for i = 1, 3 do
        parts[#parts + 1] = p.colours[i].hue .. "/" .. p.colours[i].shade
    end
    return table.concat(parts, "|")
end

for _, site in ipairs(sites) do
    site.sig = site_signature(site)
    site.radius = resolve(site.params).radius
end

local storage = core.get_mod_storage()
local queue = {}
local queued = {}

local function is_current(site)
    if site.done == nil then
        site.done = storage:get_string("built:" .. site.id) == site.sig
    end
    return site.done
end

local function enqueue(site, force)
    -- site.building matters: read_from_map emerges mapblocks, which re-enters
    -- register_on_generated, which would otherwise queue the very site being
    -- built and run it twice.
    if queued[site.id] or site.building or (not force and is_current(site)) then
        return
    end
    queued[site.id] = true
    queue[#queue + 1] = { site = site, force = force and true or false }
end

-- sbz_api.delay_if_laggy drains a task list out of a globalstep time budget,
-- so a nebula build never competes with mapgen for the same second. It
-- matters for correctness too, not just politeness: read_from_map throws if
-- called from an emerge thread, so the build cannot live in
-- register_on_generated.
local function defer(fn)
    if sbz_api and sbz_api.delay_if_laggy then
        sbz_api.delay_if_laggy(fn)
    else
        core.after(0, fn)
    end
end

local function pump()
    local entry = table.remove(queue)
    if not entry then
        return
    end
    local site = entry.site
    queued[site.id] = nil
    if site.building then
        return
    end
    if not entry.force and is_current(site) then
        return
    end

    site.building = true

    -- The area has to exist before a VoxelManip can write into it.
    -- read_from_map does not generate anything: on a fresh world the target
    -- mapblocks are absent, every voxel reads back as CONTENT_IGNORE, and
    -- write_to_map has nowhere to put the result. emerge_area forces the
    -- mapgen to actually produce the blocks first.
    local r = site.radius + 1
    local emin = { x = site.pos.x - r, y = site.pos.y - r, z = site.pos.z - r }
    local emax = { x = site.pos.x + r, y = site.pos.y + r, z = site.pos.z + r }
    local started = false
    core.emerge_area(emin, emax, function(_, _, remaining)
        if remaining ~= 0 or started then
            return
        end
        started = true
        -- Hop out of the emerge callback before touching a VoxelManip.
        core.after(0, function()
            site.building = false
            local ok, res = pcall(build_nebula, site.pos, site.params)
            if not ok then
                core.log(
                    "error",
                    ("[no_horizons] nebula %d (%s) failed: %s"):format(site.id, site.name, tostring(res))
                )
            else
                storage:set_string("built:" .. site.id, site.sig)
                site.done = true
                core.log(
                    "action",
                    ("[no_horizons] nebula %d %-13s @ (%d,%d,%d) r=%d: %d blocks, %d kept, lane_t %.4f, fill %.4f, %d ms"):format(
                        site.id,
                        site.name,
                        site.pos.x,
                        site.pos.y,
                        site.pos.z,
                        res.p.radius,
                        res.blocks,
                        res.skipped,
                        res.probe.lane_t,
                        res.probe.fill,
                        math.floor(res.ms)
                    )
                )
            end
            if #queue > 0 then
                defer(pump)
            end
        end)
    end)
end

local function kick()
    if #queue > 0 then
        defer(pump)
    end
end

-- Automatic: any mapgen touching a site's box enqueues it, so flying to one is
-- enough. No player action, no command.
--
-- Signature note: in the server env this callback is (minp, maxp, blockseed).
-- The four argument (vm, minp, maxp, blockseed) form belongs to the mapgen
-- env's register_on_generated, which is a different callback entirely.
core.register_on_generated(function(minp, maxp)
    for _, site in ipairs(sites) do
        local p, r = site.pos, site.radius
        if
            p.x - r <= maxp.x
            and p.x + r >= minp.x
            and p.y - r <= maxp.y
            and p.y + r >= minp.y
            and p.z - r <= maxp.z
            and p.z + r >= minp.z
        then
            enqueue(site)
        end
    end
end)

if PRIME_ON_START then
    for _, site in ipairs(sites) do
        enqueue(site)
    end
    kick()
end

core.log(
    "action",
    ("[no_horizons] %d nebula sites registered, priming at start: %s"):format(
        #sites,
        PRIME_ON_START and "yes" or "no"
    )
)

-- ======================================================================
-- 10. CHAT COMMANDS
-- ======================================================================

local NUMERIC_KEYS = {
    "radius",
    "slab",
    "shape_amt",
    "lane_fraction",
    "lane_depth",
    "strand_floor",
    "fill_pct",
    "lane_t",
    "fill",
}
for _, prefix in ipairs({ "env", "lane", "strand" }) do
    for _, k in ipairs({ "octaves", "persist", "seed" }) do
        NUMERIC_KEYS[#NUMERIC_KEYS + 1] = prefix .. "_" .. k
    end
end

-- A command line is a list of "key=value" overrides plus up to three bare
-- numbers, which mean radius, lane_t and fill. The two thresholds are
-- accepted raw so they can be swept without a server restart.
local function parse_args(words)
    local out, numbers = {}, {}
    for _, w in ipairs(words) do
        local key, val = w:match("^([%w_]+)=(.*)$")
        if key then
            if key:sub(-7) == "_spread" then
                local a, b, c = val:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
                if a then
                    out[key] = { tonumber(a), tonumber(b), tonumber(c) }
                end
            elseif key == "tier_hue" then
                out[key] = val
            else
                for _, k in ipairs(NUMERIC_KEYS) do
                    if k == key then
                        out[key] = tonumber(val)
                        break
                    end
                end
            end
        else
            numbers[#numbers + 1] = tonumber(w)
        end
    end
    out.radius = out.radius or numbers[1]
    out.lane_t = out.lane_t or numbers[2]
    out.fill = out.fill or numbers[3]
    return out
end

-- Target: a site number, "x,y,z", or nil for just above the player.
local function parse_target(spec)
    if spec == nil then
        return nil
    end
    local id = tonumber(spec)
    if id then
        local site = sites[id]
        if not site then
            return nil, S("no nebula site %s, want 1-8"):format(spec)
        end
        return site
    end
    local x, y, z = spec:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
    if x then
        return { pos = { x = tonumber(x), y = tonumber(y), z = tonumber(z) } }
    end
    return nil, S("cannot read target %q, want a site number or x,y,z"):format(spec)
end

-- Site params first, explicit overrides on top.
local function merged(target, overrides)
    if not target or not target.params then
        return overrides
    end
    local m = {}
    for k, v in pairs(target.params) do
        m[k] = v
    end
    for k, v in pairs(overrides) do
        if v ~= nil then
            m[k] = v
        end
    end
    return m
end

-- Split a command line into --flags, a leading target and key=value words.
local function split_words(param)
    local flags, words = {}, {}
    for w in param:gmatch("%S+") do
        if w:sub(1, 2) == "--" then
            flags[w:sub(3)] = true
        else
            words[#words + 1] = w
        end
    end
    -- A leading word is the target only if it actually names one: a site
    -- number, or an x,y,z triple. Everything else (notably a bare radius)
    -- stays in place so parse_args can pick it up.
    local target_word
    local w1 = words[1]
    if w1 and not w1:find("=") then
        local id = tonumber(w1)
        local is_site = id ~= nil and id == math.floor(id) and id >= 1 and id <= #sites
        local is_xyz = w1:match("^(%-?%d+),(%-?%d+),(%-?%d+)$") ~= nil
        if is_site or is_xyz then
            target_word = table.remove(words, 1)
        end
    end
    return flags, target_word, words
end

local function echo(player, lines)
    for _, l in ipairs(lines) do
        core.chat_send_player(player, "[nebula] " .. l)
    end
end

local function report(prefix, p, probe)
    return {
        ("%sradius %d, slab %d, %d probe samples"):format(prefix, p.radius, p.slab, probe.samples),
        report_line("lanes", probe.lanes, { 0.05, 0.25, 0.5, 0.75, 0.95 }),
        report_line("density", probe.density, { 0.5, 0.75, 0.9, 0.99 }),
        ("  solved   lane_t %.4f  fill %.4f  tier1 %.4f  tier2 %.4f"):format(
            probe.lane_t,
            probe.fill,
            probe.tier1,
            probe.tier2
        ),
        ("  colours  %s, %s, %s"):format(
            p.colours[1].hue .. "/" .. p.colours[1].shade,
            p.colours[2].hue .. "/" .. p.colours[2].shade,
            p.colours[3].hue .. "/" .. p.colours[3].shade
        ),
    }
end

core.register_chatcommand("nh_nebula", {
    description = S("Build, probe or dry-run a nebula. /nh_nebula --help"),
    privs = { interact = true },
    func = function(name, param)
        local flags, target_word, words = split_words(param)

        if flags.help then
            core.chat_send_player(
                name,
                S("/nh_nebula [--dry] [--sites] [--probe] [--force|--all] [site|x,y,z] [key=value ...] [radius] [lane_t] [fill]")
            )
            core.chat_send_player(
                name,
                S("a leading number 1-8 is a site, anything else numeric is a radius")
            )
            core.chat_send_player(
                name,
                S("keys: radius slab shape_amt lane_fraction lane_depth strand_floor fill_pct lane_t fill tier_hue")
            )
            core.chat_send_player(
                name,
                S("      env_spread env_octaves env_persist env_seed, and the same for lane_* and strand_*")
            )
            return
        end

        if flags.sites then
            local lines = {}
            for _, site in ipairs(sites) do
                local mark = (not queued[site.id]) and is_current(site) and " [built]" or " [pending]"
                lines[#lines + 1] = ("%d %-13s (%d,%d,%d) r=%d%s"):format(
                    site.id,
                    site.name,
                    site.pos.x,
                    site.pos.y,
                    site.pos.z,
                    site.radius,
                    mark
                )
                lines[#lines + 1] = ("    %s"):format(site.note)
            end
            echo(name, lines)
            if not flags.all then
                return
            end
        end

        local target, err = parse_target(target_word)
        if err then
            core.chat_send_player(name, "! " .. err)
            return
        end

        if flags.all or (flags.force and target and target.id) then
            for _, site in ipairs(sites) do
                enqueue(site, true)
            end
            kick()
            echo(name, { S("queued %d nebula sites, watch the server log"):format(#queue) })
            return
        end

        local overrides = parse_args(words)
        local pos
        if target then
            pos = target.pos
        else
            -- Above the player, so a debug build does not bury them.
            pos = vector.add(core.get_player_pos(name), { x = 0, y = 80, z = 0 })
        end
        local m = merged(target, overrides)

        if flags.dry then
            local text, p, probe = render_ascii(pos, m)
            core.log("action", "[no_horizons] nebula dry run at " .. core.pos_to_string(pos) .. "\n" .. text)
            for line in (text .. "\n"):gmatch("([^\n]*)\n?") do
                core.chat_send_player(name, line)
            end
            local out = report("", p, probe)
            echo(name, out)
            return
        end

        if flags.probe then
            local p = resolve(m)
            local probe = solve(pos, p)
            local out = report("", p, probe)
            out[1] = ("probe at (%d,%d,%d), no nodes written"):format(pos.x, pos.y, pos.z)
            echo(name, out)
            return
        end

        local res = build_nebula(pos, m)
        local out = report("  ", res.p, res.probe)
        table.insert(out, 1, ("%d blocks, %d kept, %d ms, at (%d,%d,%d)"):format(
            res.blocks,
            res.skipped,
            math.floor(res.ms),
            pos.x,
            pos.y,
            pos.z
        ))
        echo(name, out)
    end,
})

core.register_chatcommand("nh_nebula_clear", {
    description = S("Air out a nebula. /nh_nebula_clear [site|x,y,z] [radius]"),
    privs = { interact = true },
    func = function(name, param)
        local _, target_word, words = split_words(param)
        local target, err = parse_target(target_word)
        if err then
            core.chat_send_player(name, "! " .. err)
            return
        end
        local pos = target and target.pos
            or vector.add(core.get_player_pos(name), { x = 0, y = 80, z = 0 })
        local res = clear_nebula(pos, merged(target, parse_args(words)))
        if target and target.id then
            -- Force a rebuild next time the area comes through mapgen.
            storage:set_string("built:" .. target.id, "")
            target.done = false
        end
        echo(name, { S("cleared %d blocks in %d ms"):format(res.blocks, math.floor(res.ms)) })
    end,
})

-- Tell the user where the debug set is, once, so evaluating it is a matter of
-- flying there rather than of reading the log.
core.register_on_joinplayer(function(player)
    local name = player:get_player_name()
    local lines = { S("%d nebulae, one per octant around origin:"):format(#sites) }
    for _, site in ipairs(sites) do
        lines[#lines + 1] = ("  %d %-13s (%d,%d,%d) r=%d"):format(
            site.id,
            site.name,
            site.pos.x,
            site.pos.y,
            site.pos.z,
            site.radius
        )
    end
    lines[#lines + 1] = S("/nh_nebula --sites for what each one changes")
    echo(name, lines)
end)

