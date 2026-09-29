# Intro
We are working on some additional mods to the space themed skyblock crafting game Skyblock: Zero for the engine Luanti (open source minecraft-like clone).
This is my work dir. ../skyblock_zero is the base game. ../mineclonia is minecraft clone for the same engine. ../skyblkone is another mod. You can refer to these as needed.

# Process
To test, run `run_lserver.sh` (on PATH, the script lives in `/Users/Shared/sv-roman/bin/`, **not** in this repo). It gracefully restarts the server as a detached process and waits until it is ready. Use `run_lserver.sh --log` to follow output, `run_lserver.sh --status` to check it, and `run_lserver.sh --stop` to stop it. After finishing leave it running so the user can try the result too.

# Project facts to know before starting work
- Engine is **Luanti 5.16.1** (LuaJIT). `core.*` is the API namespace (`minetest.*` aliased).
- **Mod changes only load on server restart.** Run `run_lserver.sh` to reload them. The wrapper log is `/tmp/sbz_server.log`, the server debug log is `~/Library/Application Support/minetest/debug.txt`, the world lives under `~/Library/Application Support/minetest/worlds/sbzdev`, and clients auto-reconnect within seconds.
- The base game exposes a **shared global table `sbz_api`** (defined in `sbz_base`). Reuse its helpers instead of rolling your own; add `sbz_base` and friends to `optional_depends` in `mod.conf` so load order is correct (the log shows `no_horizons` loading right after `mesecons_mvps`).
- `sbz_api.move_node(from, to)` is the **metadata-safe node mover** (keeps inventories, machine/pipes state, timers; moves entities) and lives in `mesecons_mvps`. Node data can be read/moved off-map via `sbz_api.get_or_load_node` / `sbz_api.swap_node_force` (sbz_base/vm.lua).
- Audio comes from the `sbz_audio` mod: helpers like `sbz_audio.machine()`, and sound *names* are global media strings (`gen_zap_short`, `mix_*`, `foley_*`) usable directly in node `sounds`.
- Game model conventions worth mirroring: `damage_per_second` is set as a **top-level node field** (engine reads it as a group); plantlike nodes use `use_texture_alpha = "clip"`; `light_source`/`paramtype="light"` pair up; particles via `core.add_particlespawner` (see `sbz_power/antimatter_generator.lua`).
