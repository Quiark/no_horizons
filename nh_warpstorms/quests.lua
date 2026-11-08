-- Candles quest page for the base game's questbook, registered through
-- sbz_api.register_quest. sbz_progression loads before this mod (see
-- mod.conf) so the API is guaranteed to exist here.
--

local S = core.get_translator("nh_warpstorms")

local function register_candles_quests()
    if not (sbz_api and sbz_api.register_quest) then
        core.log(
            "warning",
            "[nh_warpstorms] sbz_progression not loaded, skipping candles quest page"
        )
        return
    end

    sbz_api.register_quest({
        id = "qid_ql_candles",
        type = "text", -- questline banner
        title = S("Candles"),
        text = "Just something to help you keep peace.",
    })

    sbz_api.register_quest({
        id = "qid_candles",
        type = "text",
        info = true, -- quest page (shows as a "!" info entry)
        title = S("Candles"),
        text = "Candles can be crafted from paper and fiberweed. They can be placed on any solid surface "
		.. "and can be lit with an igniter. They provide peace and calm for a stormy night... in 50 block range"
    })

    -- Secret page about the Mote Catcher. It shows as "???" in the book
    -- until the player has a flesh block in inventory (see the inventory
    -- hook below), at which point unlock_achievement reveals this page.
    sbz_api.register_quest({
        id = "qid_mote_catcher",
        type = "secret",
        title = S("Mote Catcher"),
        text = "The Mote Catcher is a machine that collects warp motes that drift in when a warp storm rages nearby. "
		.. "It needs power to run.",
    })
end

register_candles_quests()

-- ======================================================================
-- Reveal the Mote Catcher secret page only once the player has a flesh
-- block in inventory. 
-- ======================================================================

local flesh_tracked = {
    ["nh_warpstorms:warp_flesh"] = "qid_mote_catcher",
    ["nh_warpstorms:warp_meat"] = "qid_mote_catcher",
}

core.register_on_player_inventory_action(function(player, action, inv, inv_info)
    if not (sbz_api and sbz_api.register_quest) then return end
    if not (unlock_achievement and is_achievement_unlocked) then return end

    if action ~= "move" and action ~= "move_one" then return end

    -- inv_info.to_inv is the destination inventory location as a plain string
    -- (e.g. "current_player" or "player:<name>").
    local to_inv = inv_info.to_inv
    if type(to_inv) ~= "string" then return end
    if not (to_inv == "current_player" or to_inv:find("^player:")) then return end

    -- Fall through to check the moved stack now that it rests in the player's
    -- own main inventory.
    local itemstack = inv:get_stack(inv_info.to_list, inv_info.to_index)
    if not itemstack or itemstack:is_empty() then return end

    local player_name = player:get_player_name()
    local flesh_qid = flesh_tracked[itemstack:get_name()]
    if flesh_qid then
        unlock_achievement(player_name, flesh_qid)
    end
end)
