# Warp storm feature - what I had to look up

Record of the research done before implementing warp_storm.lua, so it does not
have to be repeated. Each item is the thing I did not already know and where I
found the answer.

## High-level node mover (block randomization / machine movement)
- The game already has a metadata-safe mover: `sbz_api.move_node(from, to)`.
  - Defined in `../skyblock_zero/mods/mesecons_mvps/init.lua`.
  - Preserves metadata, node timers, moves nearby entities, and refuses to move
    into non-`buildable_to` nodes or mvps "stoppers".
  - Found by grepping for `move_node` (`sbz_luacontroller_devices/node_mover.lua`
    is a usage example).
- `sbz_api` is a global table created by `sbz_base` (`mods/sbz_base/init.lua`).
  It is always present when `skyblktwo` runs, because the game loads it earlier
  (verified in the server log: `skyblktwo` loads right after `mesecons_mvps`).

## VoxelManip usage (the 6x6x6 read/write)
- The canonical pattern is `core.get_voxel_manip()` + `read_from_map(minp, maxp)`,
  then `VoxelArea:new({MinEdge=emin, MaxEdge=emax})` and `area:index(x,y,z)`.
- Write back with `manip:set_data(data)` then `manip:write_to_map(true)` - the
  `true` recalculates light, so light-source nodes placed via VM glow (see
  `../skyblock_zero/mods/sbz_power/lights.lua`).
- The engine exposes `core.CONTENT_AIR` and `core.CONTENT_IGNORE` constants.
- The game also has higher-level VM transactions in `sbz_base/vm.lua`
  (`sbz_api.vm_begin/vm_swap_node/vm_commit`) if you want to mix VM and swap
  node-by-node instead of editing data arrays.

## Animating a node between two separate texture files
- A tile can animate with `animation = {type="vertical_frames", aspect_w=16,
  aspect_h=16, length=N}` but expects a single sheet image.
- Two 16x16 PNGs become a 16x32 sheet using the `[combine` texture modifier.
  Its syntax uses **`=` after the coordinates**, not `:`:
  `[combine:16x32:0,0=lightn1.png:0,16=lightn2.png`.
  Confirmed by in-repo examples: `sbz_decor/signs.lua`
  (`[combine:32x32:0,0=antimatter_sign.png^[makealpha:0,0,0`) and
  `sbz_meteorites/attractor.lua`.
- Chaining modifiers after `[combine` works: `...^[multiply:#hex`.

## Tinting grayscale textures per-storm (three severity colours)
- `^[multiply:#rrggbb` multiplies a texture's RGB by a colour - ideal for
  recolouring the grayscale `lightn*.png` bolts.
- There are exactly three bolt colours, one per storm severity (defined in the
  `STORM_TYPES` table): mild green, moderate orange and severe purple. A storm
  rolls its severity first (weighted so brighter storms are rarer), then uses
  that colour for all its bolts, instead of using `paramtype2="color"` + a
  generated palette (kept it simple).

## Node properties / damage
- `damage_per_second` must be a top-level node field (the engine treats it as a
  group). Convention from the base game: `sbz_bio/fire.lua` (`damage_per_second
  = 4`) and `sbz_planets/planet_nodes.lua` (`= 20`).
- Plantlike (grass/leaves style) rendering uses `drawtype = "plantlike"` and
  `use_texture_alpha = "clip"` (see `sbz_bio/trees.lua`).

## Particles (like the antimatter generator)
- `sbz_power/antimatter_generator.lua` re-adds a short-lived spawner every
  tick: `core.add_particlespawner({amount, time=1, glow=14, size, pos, vel={min,
  max}, exptime, texture})`. I mirror that from an ABM so sparks only run while
  a bolt exists.

## ABM specifics
- `nodenames = {"group:<name>"}` matches any node carrying that group.
- `interval` + `chance` control how often nodes are processed; `chance` 1 means
  every matching node every interval.
- I store an age counter in node metadata (so expiry survives server restarts;
  `core.get_us_time()` resets on restart and was rejected for that reason).

## Sounds
- Sound names are global media from `sbz_audio`; found available files with
  `find` over `mods/sbz_audio/sounds` (e.g. `gen_zap_short.ogg`,
  `gen_simple_charged_field_placement_zap.ogg`, `mix_sad_crackly_poof.ogg`).
  Pick names from actual file names - there is no API to list them at runtime.

## No flesh/skin node existed
- Grepping `register_node(...flesh/skin)` across all three projects found
  nothing usable, so `skyblktwo:warp_flesh` + `skyblktwo_warp_flesh.png` were
  created. No ImageMagick/PIL on the machine, so the texture is produced by a
  pure-python PNG writer (`tools/make_warp_flesh.py`, zlib + struct).

## Server / testing mechanics
- `run_lserver.sh` runs game `skyblock_zero`, world `sbzdev`. The running
  server predates code edits, so a `pkill -f luantiserver` + rerun is needed to
  test. There must be a connected player for a storm to pick a location; for
  headless verification I temporarily forced a storm at a fixed position near
  the origin, checked the log, then reverted (server log confirms nodes were
  placed and the ABM expired them ~15s later).