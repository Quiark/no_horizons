--[[
    protected.lua
    =============

    Nodes the boring machines (Pusher, Ultra Node Breaker) must never move or
    dig.  Moving them either breaks global/multiblock state or lets automation
    relocate what a player cannot.
--]]

nh_boring = nh_boring or {}

local EXPLICIT = {
    -- Running/off reactors are radioactive and explode if handled wrongly.
    ["sbz_chem:nuclear_reactor_off"] = true,
    ["sbz_chem:nuclear_reactor_on"] = true,
    ["sbz_chem:xray_off"] = true,
    ["sbz_chem:xray_on"] = true,
}

local PREFIXES = {
    "sbz_multiblocks:", -- formed multiblocks break when one part moves
    "sbz_power:reactor_", -- emittrium reactor parts carry positional links
}

local GROUPS = {
    "unbreakable",
    "multiblock_controller",
    "multiblock_power_port",
    "multiblock_item_input",
    "multiblock_item_output",
}

local function has_protected_prefix(name)
    for _, prefix in ipairs(PREFIXES) do
        if name:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
end

function nh_boring.is_protected_node(node)
    local name = type(node) == "string" and node or node.name
    if EXPLICIT[name] or has_protected_prefix(name) then
        return true
    end
    for _, group in ipairs(GROUPS) do
        if core.get_item_group(name, group) > 0 then
            return true
        end
    end
    local def = core.registered_nodes[name]
    return def ~= nil and def.diggable == false
end
