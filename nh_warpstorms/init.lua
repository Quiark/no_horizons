-- Warp storms: random lightning storms that briefly appear near players,
-- strike the area with VoxelManip-placed bolts, warp a few existing
-- blocks around and can leave warp flesh behind. See warp_storm.lua.
-- Loaded first: the other files below use the storm API it publishes
-- through sbz_api (spawn_warp_storm_at, active_storms, ...).
dofile(core.get_modpath("nh_warpstorms") .. "/warp_storm.lua")

-- Candles: colorable light sources, lit with igniter. See candles.lua.
dofile(core.get_modpath("nh_warpstorms") .. "/candles.lua")

-- Quest pages in the base game's questbook. See quests.lua.
dofile(core.get_modpath("nh_warpstorms") .. "/quests.lua")

-- Orbplant: a flesh-grown plant that sprouts out of the flesh the storms
-- leave behind and calls down warp storms when mature. See orbplant.lua.
dofile(core.get_modpath("nh_warpstorms") .. "/orbplant.lua")

-- Mote Catcher: a machine that collects warp motes from nearby storms.
-- See mote_catcher.lua.
dofile(core.get_modpath("nh_warpstorms") .. "/mote_catcher.lua")
