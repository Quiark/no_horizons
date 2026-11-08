-- Shared module table for this mod.
nh_boring = {}

-- Shared list of nodes that the boring machines must never move or dig.
-- See protected.lua.
dofile(core.get_modpath("nh_boring") .. "/protected.lua")

-- Breaker Vacuum: a machine that pulls drops out of nearby Node Breakers.
-- See breaker_vacuum.lua.
dofile(core.get_modpath("nh_boring") .. "/breaker_vacuum.lua")

-- Ultra Node Breaker: breaks any node and keeps drops for the vacuum.
-- See ultra_node_breaker.lua.
dofile(core.get_modpath("nh_boring") .. "/ultra_node_breaker.lua")

-- Pusher: a powered piston that pushes blocks AND itself, marching forward
-- indefinitely. See pusher.lua.
dofile(core.get_modpath("nh_boring") .. "/pusher.lua")

-- Power Relay: a self-contained mini switching station for mobile rigs that
-- can be safely shoved around by a Pusher. See power_relay.lua.
dofile(core.get_modpath("nh_boring") .. "/power_relay.lua")
