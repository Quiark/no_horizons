-- Nebulas: filamentary warp glass clouds that build themselves from world
-- gen. See nebula.lua and nebula.md.
dofile(core.get_modpath("nh_nebula") .. "/nebula.lua")

-- Warp Glass: textureless, colourable glass you can walk through, the
-- block the nebula fields are grown out of. See warp_glass.lua.
dofile(core.get_modpath("nh_nebula") .. "/warp_glass.lua")

-- Tinted glass panes for the base game's tinted glass. See panes.lua.
dofile(core.get_modpath("nh_nebula") .. "/panes.lua")
