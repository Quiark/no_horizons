-- Candles, adapted from mineclonia's mcl_candles for Skyblock: Zero
-- Uses unifieddyes for coloring, sbz_bio:igniter for lighting

local S = core.get_translator("nh_warpstorms")

local candle_boxes = {
	{-0.0625, -0.5, -0.0625, 0.0625, -0.125, 0.0625},
	{-0.1875, -0.5, -0.0625, 0.1875, -0.125, 0.125},
	{-0.1875, -0.5, -0.1875, 0.125, -0.125, 0.125},
	{-0.1875, -0.5, -0.125, 0.1875, -0.125, 0.1875}
}

local function drop_candles(pos, node, _, digger)
	if digger and digger:is_player() and core.is_creative_enabled(digger:get_player_name()) then return end

	if not node then node = core.get_node(pos) end

	local group = core.get_item_group(node.name, "candles")
	if group == 0 then return end

	local item = ItemStack("nh_warpstorms:candle_1 " .. group)
	local color_index = node.param2 > 0 and node.param2
	if color_index and color_index ~= 240 then
		item:get_meta():set_int("palette_index", color_index)
	end

	return core.add_item(pos, item)
end

local function ignite_candle(pos)
	local n = core.get_node(pos)
	local g = core.get_item_group(n.name, "candles")
	if g > 0 then
		n.name = "nh_warpstorms:candle_lit_" .. tostring(g)
		core.swap_node(pos, n)
		core.sound_play("gen_zap_short", { pos = pos, gain = 0.3, max_hear_distance = 8 })
		return true
	end
end

local function extinguish_candle(pos, node, clicker)
	if not clicker then return end
	if core.is_protected(pos, clicker:get_player_name()) then return end

	local group = core.get_item_group(node.name, "lit_candles")
	if group > 0 then
		node.name = "nh_warpstorms:candle_" .. group
		core.swap_node(pos, node)
	end
end

local function candle_on_place(itemstack, placer, pointed_thing)
	if not placer then return end
	if core.is_protected(pointed_thing.under, placer:get_player_name()) then return end

	local unode = core.get_node(pointed_thing.under)
	local group = core.get_item_group(unode.name, "candles")
	local param2 = tonumber(itemstack:get_meta():get("palette_index")) or 240

	if group > 0 and group < #candle_boxes then
		unode.name = "nh_warpstorms:candle_" .. math.min(4, group + 1)
		if param2 == unode.param2 or unode.param2 == 240 then
			unode.param2 = param2
			core.swap_node(pointed_thing.under, unode)
		end

		if not core.is_creative_enabled(placer:get_player_name()) then
			itemstack:take_item()
		end
	else
		itemstack:get_meta():set_int("palette_index", param2)
		return core.item_place_node(itemstack, placer, pointed_thing)
	end

	return itemstack
end

for i = 1, #candle_boxes do
	local creative_group = {}
	if i ~= 1 then
		creative_group = { not_in_creative_inventory = 1 }
	end

	local groups = {
		candles = i, dig_immediate = 3, attached_node = 0,
	}
	if i ~= 1 then
		groups.not_in_creative_inventory = 1
	end
	for k, v in pairs(creative_group) do groups[k] = v end

	core.register_node("nh_warpstorms:candle_" .. i, {
		description = S("Candle"),
		drawtype = "mesh",
		paramtype = "light",
		paramtype2 = "color",
		palette = "unifieddyes_palette_extended.png",
		use_texture_alpha = "clip",
		sunlight_propagates = true,
		drop = "",
		sounds = sbz_audio.blank(),
		mesh = "mcl_candles_candle_" .. i .. ".obj",
		tiles = {"mcl_candles_candle.png", "blank.png^[opacity:0"},
		inventory_image = "mcl_candles_item.png",
		wield_image = "mcl_candles_item.png",
		collision_box = {fixed = candle_boxes[i], type = "fixed"},
		selection_box = {fixed = candle_boxes[i], type = "fixed"},
		groups = groups,
		node_placement_prediction = "",
		on_destruct = drop_candles,
		on_place = candle_on_place,
		on_ignite = function(pos)
			return ignite_candle(pos)
		end,
	})

	core.register_node("nh_warpstorms:candle_lit_" .. i, {
		description = S("Lit Candle"),
		drawtype = "mesh",
		paramtype = "light",
		paramtype2 = "color",
		palette = "unifieddyes_palette_extended.png",
		use_texture_alpha = "clip",
		sunlight_propagates = true,
		drop = "",
		sounds = sbz_audio.blank(),
		mesh = "mcl_candles_candle_lit_" .. i .. ".obj",
		light_source = 3 * i,
		tiles = {
			"mcl_candles_candle.png",
			{
				animation = {
					aspect_h = 16,
					aspect_w = 16,
					length = 1,
					type = "vertical_frames"
				},
				color = "white",
				name = "mcl_candles_flames.png"
			}
		},
		collision_box = {fixed = candle_boxes[i], type = "fixed"},
		selection_box = {fixed = candle_boxes[i], type = "fixed"},
		groups = {
			candles = i, lit_candles = i, dig_immediate = 3,
			not_in_creative_inventory = 1,
		},
		on_destruct = drop_candles,
		on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
			extinguish_candle(pos, node, clicker)
			return itemstack
		end,
	})
end

-- Crafting: paper + fiberweed = candle
core.register_craft({
	output = "nh_warpstorms:candle_1",
	recipe = {
		{"sbz_bio:paper"},
		{"sbz_bio:fiberweed"},
	}
})

