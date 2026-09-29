# Nebula generator - design notes and plan

Settling the noise for a ~200 block diameter nebula, before wiring up any
gameplay. Target look is filamentary/wispy, built out of `no_horizons:warp_glass`,
built instantly with one acceptable lag spike.

## The problem to solve

A nebula that is a solid mass of blocks reads as one uniform blob: no internal
density variation and no visible colour variation. We need gaps at a scale the
eye reads as *structure* rather than as dither.

## The noise answer

Use a **ridged field, subtractively, as lanes**. Not a blob field thresholded.

The subtle part: `flags = "absvalue"` makes `|n|` peak at the *extrema* of the
smooth noise, so thresholding it high gives **blobs**, not strands. What we want
is the complement `ridge = 1 - |n|`, which peaks on the *zero level sets* of `n`,
i.e. **sheets**. So:

    lane field  L(p) = 1 - LANES(p)          -- peaks on sheets
    mass        M(p) = envelope(p)           -- smooth blobby volume
    density     D(p) = M(p) * (1 - LANE_DEPTH * max(0, L(p) - LANE_T))

The gradient idea is right, and it comes for free. A lane is the region
`|n| < LANE_T`, so its thickness is `2 * LANE_T / |grad n|`: thin where the
noise is steep, thick where it is flat. No explicit gradient computation, no
extra samples. That is strictly better than contour-banding the value with
`frac(n*K)`, which produces shells around the *centre* - a preferred
orientation, so it reads as rings or a bubble rather than as wisps.

It also answers "random missing blocks isn't convincing". Lane structure comes
from the **low** octaves of the lane field, so lanes are broad and smooth, while
the **high** octaves only wobble their edges by a few blocks. Gap size is set by
the single number `LANE_T`, not by however the noise happens to fall.

## The three fields

| Field        | NoiseParams                                                  | Wavelengths | Job |
|--------------|---------------------------------------------------------------|-------------|-----|
| `ENVELOPE`   | `spread {260,200,260}`, octaves 2, persist 0.5, seed S3       | 260, 130    | Lobed non-spherical silhouette |
| `LANES`      | `spread {170,130,170}`, octaves 3, persist 0.42, `absvalue`, seed S  | 170, 85, 42 | **The gaps**, 15-40 block sheets |
| `STRANDS`    | `spread {70,55,70}`, octaves 2, persist 0.5, `absvalue`, seed S2    | 70, 35      | Internal density/colour variation |

Per voxel:

    d   = |p - C| / R                                 -- R = 100, so 200 diameter
    env = smoothstep(1.0, 0.12, d) * (1 + SHAPE_AMT * ENVELOPE(p))
    if env <= 0 -> skip
    lane = 1 - LANES(p)
    str  = 1 - STRANDS(p)
    D    = env * (1 - LANE_DEPTH * max(0, lane - LANE_T))
              * (STRAND_FLOOR + (1 - STRAND_FLOOR) * str)

`STRAND_FLOOR` is the answer to the "bigger internal density / varying colours"
requirement: it varies density **without creating new gaps**, so the density
gradient is visible *through* the gaps rather than as more holes.

`SHAPE_AMT ~ 0.45`, `STRAND_FLOOR ~ 0.55`.

## Colour tiers

Three thresholds on `D` map to three colour bytes on `warp_glass`.
`unifieddyes.def` (`api.lua:629`) gives it `paramtype2 = "color"` and
`palette = unifieddyes_palette_extended.png`, whose 0-239 range is
`hue_index * 10 + shade_index` over `unifieddyes.HUES_EXTENDED` (24 hues,
`color-tables.lua:3`). 240-255 is a greyscale ramp and is not wanted here.

E.g. `magenta` bright = 20*10+4 = 204, `indigo` medium = 180,
`violet` dark = 184.

## Thresholds as dials, not magic numbers

Both thresholds are raw outputs of `absvalue` noise, whose range depends on
`octaves` and `persist`. So one **probe pass** over ~20k points inside the sphere
collects the lane and strand fields, sorts them, and logs percentiles. Then
`LANE_T` is the requested `LANE_FRACTION` percentile directly, and `FILL` is
solved so the total fill hits a requested `FILL_PCT`.

The dials then mean "30% of the blob is gap" and "8% of the sphere is block"
rather than being bare numbers, and because they are re-derived every run,
changing `octaves` cannot silently break the tuning.

## Build path

A 201^3 box is 8.1M voxels. Per-voxel `ValueNoise:get_3d` costs roughly 2 us, so
sampling five fields that way would take about 80 s. Unacceptable. Use the bulk
C++ path instead, following `sbz_planets/mapgen.lua:102`.

- **Y-slabs of 32.** `ValueNoiseMap(np, {x=N, y=32, z=N})`, then per slab
  `nmap:get_3d_map_flat({x=ox,y=oy,z=oz}, buf)` into a reused buffer.
  `src/noise.cpp:595` confirms the flat result is x-fastest, so the index is
  `x + (y-1)*N + (z-1)*N*32`. Because it is absolute-position based, slabs are
  seamless.
- **Disc culling per slab.** For a slab at `dy` from centre, clamp the horizontal
  radius to `sqrt(R^2 - dy^2)`. Cuts the Lua loop from 8.1M to ~4.2M iterations
  (the sphere volume).
- **One VoxelManip per slab:** `read_from_map` -> `get_data` /
  `get_param2_data` -> modify -> `set_data` / `set_param2_data` ->
  `write_to_map(true)` -> `update_map()`. Same pattern as `warp_storm.lua:340`
  and `warp_storm.lua:665`.
- **Buffers reused across slabs:** ~5 MB per noise field, ~9 MB per slab data
  table, so memory stays flat instead of allocating a ~94 MB table.

Noise objects are created lazily inside the command, not at load time
(`lua_api.md:9720`), so retuning rebuilds them.

### Budget, honestly

3-5 s wall clock. At 8% fill it writes **~335,000 nodes** across ~2,200
mapblocks. The node count is the real cost here, larger than the compute.
`RADIUS` is a dial so this can be tested at 60 (diameter 120) first.

## Files

**`no_horizons/nebula.lua`** (new) - the whole prototype:

- `local FIELDS = {...}` - every tunable in one table at the top: `RADIUS`, the
  per-field spread/octaves/persist/seeds, `LANE_FRACTION`, `LANE_DEPTH`,
  `STRAND_FLOOR`, `FILL_PCT`, `SLAB`, `TIER_COLOURS`, `SHAPE_AMT`.
- `build_nebula(centre, opts)` - slab loop, noise maps, VoxelManip writes.
  Returns `{blocks, ms}`.
- `clear_nebula(centre, radius)` - re-reads the same bounds and air's out only
  `warp_glass` nodes, so a nebula can be re-rendered in place.
- `probe_fields(centre, opts)` - the percentile pass.
- `render_ascii(centre, opts)` - dry run. Prints a density-character
  cross-section (`#` block, `+` strand, `-` lane, ` ` empty) to chat/log. This
  is the fast iteration loop: gap structure and fill fraction can be judged
  from text without writing a single node.
- `/nh_nebula [radius]`, `/nh_nebula_clear`, `/nh_nebula --dry` -
  `privileges = {privs = {interact = true}}`, positioned at the player and
  offset up so it does not bury them.

**`no_horizons/init.lua`** - one `dofile` line, matching the existing comment
style.

No node registration, no recipe, no `unified_inventory` entry. `warp_glass`
already exists.

## Iteration loop

`run_lserver.sh` -> `/nh_nebula --dry 60` -> read the ASCII slice and the
percentile table -> adjust `LANE_FRACTION` / octaves -> `/nh_nebula_clear` ->
`/nh_nebula 100` to see it in 3D.

Mods only load on restart, so `LANE_T` and `FILL` are also accepted as command
args, which allows sweeping them **without a restart**. Only structural changes
(octaves, spread, seeds) need one.

## Engine facts verified

Checked in the engine source at `../roman/install/minetest` (5.16) so the design
does not rest on assumptions.

- `src/script/lua_api/l_noise.cpp` - `l_get_value_noise`, `l_get_value_noise_map`,
  `calc_3d_map`, `get_3d_map_flat` and `get_map_slice` are all
  `NO_MAP_LOCK_REQUIRED`, so they work from a chat command, not only from
  mapgen.
- `src/noise.cpp:733` (`Noise::updateResults`) - `absvalue` is applied **per
  octave, before weighting**, giving
  `result = scale * (|o1| + p*|o2| + p^2*|o3|) + offset`. So the field is
  positively biased and its range depends on `octaves`/`persist`, which is why
  thresholds have to be probed rather than guessed.
- `src/noise.cpp:686` (`noiseMap3D`) and `:595` - `result` is indexed x-fastest,
  the same linear order as `VoxelArea:index(x,y,z)`. Slice origin is absolute
  world position, so adjacent slabs line up.
- `src/script/lua_api/l_vmanip.cpp:92` - `get_data()` returns a **table** of
  content ids, not a string. (Older engines returned a raw buffer, which is why
  `warp_storm.lua:342` indexing it works but is worth knowing about.)
- `map_meta.txt` - this world runs `mg_name = singlenode`, `chunksize = 5`, and
  `mg_flags` includes **`nolight`**.
- `sbz_planets/biomes.lua:5` - a scatter ore in `air`
  (`clust_scarcity = 80^3`) placing `sbz_resources:emitter`. It only ever
  *places*, never overwrites, so nebula nodes survive re-emerge. If fill is
  raised later, expect stray emitters inside the cloud.
- `sbz_base/init.lua:300` - sun, moon, stars and sky are disabled and time is
  frozen. Combined with `nolight` this means all light values are 0, so
  `write_to_map(true)` is cheap. It is also why a *dark* nebula reads correctly:
  there is no ambient light to flatten it.
- No nebula, asteroid, gas-layer or cloud node exists anywhere in the base game.
  The only volumetric generation anywhere is `sbz_planets` writing ~1300
  spherical planets in `register_on_generated`.

## Deferred until the noise is settled

- **Domain warping.** It would break the regular-grid bulk path, because the
  filament sample position becomes irregular. The correct form is a **coarse
  warp grid**: precompute a 27^3 warp field with per-point `get_3d` (19.7k
  calls, trivial) and bilinearly interpolate it across the slab, keeping the
  main sampling on a grid. It is the single biggest "looks organic" upgrade
  after the lanes are right.
- How a nebula gets triggered, and by what.
- How space is reserved so a nebula cannot swallow player builds.
- How a nebula is removed, other than the debug clear.
- Whether a tier should have a `light_source`, which would be the only way to
  get any actual glow in a `nolight` world.
