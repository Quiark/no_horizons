--[[
    power_relay.lua
    ===============

    The Power Relay: a compact, fully self-contained mini switching-station
    for mobile builds, e.g. a walker rig shoved around by a Pusher.

    A real Switching Station (sbz_power:switching_station) is the anchor of
    a whole power grid and is tracked in a pile of global tables
    (all_switching_stations, pos2network/networks, touched_nodes, ...).  It
    is NOT safe to shove: moving it with a Pusher can occasionally eat it.
    The Power Relay is the opposite - it keeps NO global state at all.  Every
    tick it re-scans the small wired clump around itself (a bounded BFS over
    conducting/connecting nodes) and drives the `sbz_machine` actions it
    finds exactly like a switching station does, but starting from scratch at
    whatever position it currently sits.  Shove the whole rig with a Pusher
    and the relay simply picks up where it landed; there is nothing to go
    stale.

    Because it is not a real switching station it never "touches" the base
    grid's `touched_nodes`, so the 3 s "Machine timeout check" ABM would
    normally try to switch our rig machines off.  The rig machines in this
    mod therefore declare an `on_timeout` hook that flips them straight back
    on, making that check harmless to them.

    Power: the relay generates no power of its own; it collects whatever the
    batteries and generators wired into the rig produce each tick (a Teleport
    Battery, for example, shares the power pool of its channel with your
    base).  Batteries are drained to cover the rig's shortage and recharged
    with any surplus exactly like a real switching station does.  Machines
    that sit on a REAL switching-station grid are skipped, so a rig parked
    against or wired into a stationary base never gets double-driven.

    All-or-nothing: before running anything the relay probes what the whole
    rig would draw this tick (machines declare it via a get_power_needed
    hook, a static power_needed, or the last tick's measured draw) and only
    drives the machines when the pool covers every one of them.  One
    under-fed machine stalls the whole rig instead of some machines winning
    a first-come-first-served race.  When stalled the relay turns itself
    dark so the outage is readable at a glance.

    Hover: the relay's infotext is refreshed every tick with how much power
    is available and how much the rig is using, so pointing at it always
    shows live numbers.

    If several relays are wired into one clump, the one with the lowest
    position hash runs the rig and the others just report "Bridging"; this
    keeps one rig from being piloted by two relays at once.
--]]

local S = core.get_translator("nh_boring")

local GENERATION = 0 -- the relay makes no power; feed it batteries/generators
local SCAN_BUDGET = 64 -- most nodes the local scan may touch before giving up
local BLOCK_SIZE = 16
local AUTONOMOUS_KEY = "autonomous"
local RELAY_NAME = "nh_boring:power_relay"
local RELAY_ON = RELAY_NAME .. "_on"
local RELAY_OFF = RELAY_NAME .. "_off"

local relay_forceloads = {}
local block_forceload_refs = {}

local function relay_position_hash(pos)
    return core.hash_node_position(pos)
end

local function mapblock_hash(pos)
    return core.hash_node_position({
        x = math.floor(pos.x / BLOCK_SIZE),
        y = math.floor(pos.y / BLOCK_SIZE),
        z = math.floor(pos.z / BLOCK_SIZE),
    })
end

local function is_relay_name(name)
    return name == RELAY_ON or name == RELAY_OFF
end

local function release_relay_forceload(pos)
    local relay_key = relay_position_hash(pos)
    local block = relay_forceloads[relay_key]
    if not block then
        return
    end

    relay_forceloads[relay_key] = nil
    local refs = block_forceload_refs[block] or 0
    if refs > 1 then
        block_forceload_refs[block] = refs - 1
    else
        block_forceload_refs[block] = nil
        core.forceload_free_block(pos, false)
    end
end

local function acquire_relay_forceload(pos)
    local relay_key = relay_position_hash(pos)
    local block = mapblock_hash(pos)
    local old_block = relay_forceloads[relay_key]

    if old_block == block then
        return true
    end
    if old_block then
        release_relay_forceload(pos)
    end

    local refs = block_forceload_refs[block] or 0
    if refs == 0 and not core.forceload_block(pos, false) then
        return false
    end

    block_forceload_refs[block] = refs + 1
    relay_forceloads[relay_key] = block
    return true
end

local function move_relay_forceload(old_pos, new_pos)
    local old_key = relay_position_hash(old_pos)
    local new_key = relay_position_hash(new_pos)
    local new_block = mapblock_hash(new_pos)
    local old_block = relay_forceloads[old_key]

    if not old_block then
        return acquire_relay_forceload(new_pos)
    end
    if old_block == new_block then
        relay_forceloads[old_key] = nil
        relay_forceloads[new_key] = new_block
        return true
    end

    release_relay_forceload(old_pos)
    return acquire_relay_forceload(new_pos)
end

local function relay_formspec(enabled)
    return table.concat({
        "formspec_version[4]",
        "size[6,3.2]",
        "label[0.4,0.2;" .. S("Power Relay") .. "]",
        "label[0.4,0.7;" .. S("Keep this rig running without a nearby player?") .. "]",
        ("button[0.4,1.4;5.2,0.9;toggle_autonomous;%s]"):format(
            enabled and S("Disable autonomous operation") or S("Enable autonomous operation")),
        "label[0.4,2.4;" .. (enabled and S("Autonomous operation is enabled")
            or S("Autonomous operation is disabled")) .. "]",
    })
end

-- Last measured per-tick draw of each machine this relay drove, so the gate
-- can predict total demand even for machines that expose neither a
-- get_power_needed hook nor a static power_needed.  Rebuilt every tick.
local known_demand = {}

-- How much a machine "would" draw this tick, without running it.  Falls back
-- up the chain to whatever the relay can still learn about the machine.
local function estimate_demand(pos, node, mdef, meta, supply)
    if type(mdef.get_power_needed) == "function" then
        return tonumber(mdef.get_power_needed(pos, node, meta, supply)) or 0
    end
    if mdef.power_needed then
        return mdef.power_needed
    end
    local consumed = meta:get_int("power_consumed")
    if consumed > 0 then
        return consumed
    end
    return known_demand[core.hash_node_position(pos)] or 0
end

local function format_power(n)
    if sbz_api.format_power then
        return sbz_api.format_power(n)
    end
    return tostring(n)
end

-- Is this position already served by somebody else's switching station?
local function on_real_grid(pos)
    local get_net = sbz_api.get_switching_station_network
    if not get_net then
        return false
    end
    return get_net(pos) ~= nil
end

-- BFS over conducting/connecting nodes starting at `start`.  Returns
-- { generators, machines, batteries, relays }: lists of { pos, node } for
-- everything worth driving, plus the other Power Relays found in the clump.
-- Batteries and generators also carry the `sbz_machine` group, so they must
-- be checked BEFORE machines here.
local function scan_rig(start)
    local generators, machines, batteries, relays = {}, {}, {}, {}
    local seen = { [core.hash_node_position(start)] = true }
    local queue = { start }
    local head = 1
    local budget = SCAN_BUDGET

    while head <= #queue and budget > 0 do
        local pos = queue[head]
        head = head + 1
        budget = budget - 1

        iterate_around_pos(pos, function(npos)
            local key = core.hash_node_position(npos)
            if seen[key] then
                return
            end
            seen[key] = true

            local node = sbz_api.get_node_force(npos)
            if node == nil or node.name == "ignore" then
                return
            end
            if not core.registered_nodes[node.name] then
                return
            end

            -- Hop through whatever conducts or connects power (cables,
            -- machines, connectors).  This is what defines "the rig".
            if core.get_item_group(node.name, "pipe_connects") > 0
                    or core.get_item_group(node.name, "pipe_conducts") > 0 then
                queue[#queue + 1] = vector.copy(npos)
            end

            if core.get_item_group(node.name, "nh_boring_relay") > 0 then
                relays[#relays + 1] = { pos = vector.copy(npos), node = node }
            elseif core.get_item_group(node.name, "sbz_battery") > 0 then
                batteries[#batteries + 1] = { pos = vector.copy(npos), node = node }
            elseif core.get_item_group(node.name, "sbz_generator") > 0 then
                generators[#generators + 1] = { pos = vector.copy(npos), node = node }
            elseif core.get_item_group(node.name, "sbz_machine") > 0 then
                machines[#machines + 1] = { pos = vector.copy(npos), node = node }
            end
        end)
    end

    return generators, machines, batteries, relays
end

local function relay_tick(pos)
    local ok, err = pcall(function()
        local generators, machines, batteries, relays = scan_rig(pos)
        local meta = core.get_meta(pos)
        if meta:get_int(AUTONOMOUS_KEY) == 1 then
            acquire_relay_forceload(pos)
        end

        -- One master relay per clump: the lowest position hash wins, the
        -- others only bridge so two relays never drive the same machines.
        local master_hash = core.hash_node_position(pos)
        for _, r in ipairs(relays) do
            local h = core.hash_node_position(r.pos)
            if h < master_hash then
                master_hash = h
            end
        end
        if master_hash ~= core.hash_node_position(pos) then
            sbz_api.turn_on(pos)
            core.get_meta(pos):set_string("infotext", S("Bridging to another Power Relay"))
            return
        end

        local supply = GENERATION
        local demand = 0
        local required = 0
        local battery_supply_only = 0

        -- Batteries wired into the rig donate their stored power to the pool
        -- and get metered so the surplus/shortfall can be written back later.
        local battery_entries = {}
        for _, b in ipairs(batteries) do
            if not on_real_grid(b.pos) then
                local bnode = sbz_api.get_node_force(b.pos)
                local bname = bnode and bnode.name
                local bdef = bname and core.registered_nodes[bname]
                local bmeta = bname and core.get_meta(b.pos)
                if bdef and bmeta and bmeta:get_int("force_off") ~= 1 then
                    local max = bdef.battery_max or 0
                    if bdef.get_battery_max then
                        max = tonumber(bdef.get_battery_max(b.pos, bmeta)) or 0
                    end
                    local power = 0
                    if bdef.get_power then
                        power = tonumber(bdef.get_power(b.pos, bname, bmeta, supply, demand)) or 0
                    else
                        power = bmeta:get_int("power")
                    end
                    battery_entries[#battery_entries + 1] = {
                        pos = vector.copy(b.pos),
                        node = bname,
                        def = bdef,
                        max = max,
                    }
                    battery_supply_only = battery_supply_only + power
                    supply = supply + power
                end
            end
        end

        -- Generators wired into the rig add their output to our pool.
        for _, g in ipairs(generators) do
            if not on_real_grid(g.pos) then
                local gnode = sbz_api.get_node_force(g.pos)
                local gname = gnode and gnode.name
                local gdef = gname and core.registered_nodes[gname]
                local gmeta = gname and core.get_meta(g.pos)
                if gdef and gmeta and gdef.action and gmeta:get_int("force_off") ~= 1 then
                    local r = gdef.action(g.pos, gname, gmeta, supply, demand)
                    supply = supply + (tonumber(r) or 0)
                end
            end
        end

        -- Probe what the whole rig would draw this tick before running
        -- anything.  If the pool can't feed every machine, run none of them
        -- instead of letting some win on scan order.
        for _, m in ipairs(machines) do
            if not on_real_grid(m.pos) then
                local mnode = sbz_api.get_node_force(m.pos)
                local mname = mnode and mnode.name
                local mdef = mname and core.registered_nodes[mname]
                local mmeta = mname and core.get_meta(m.pos)
                if mdef and mmeta and mdef.action and mmeta:get_int("force_off") ~= 1 then
                    required = required + estimate_demand(m.pos, mname, mdef, mmeta, supply)
                end
            end
        end

        if required > supply then
            local stalled = S("Not enough power (needs @1, available @2)",
                format_power(required), format_power(supply))
            for _, m in ipairs(machines) do
                if not on_real_grid(m.pos) then
                    local mmeta = core.get_meta(m.pos)
                    if mmeta:get_int("force_off") ~= 1 then
                        mmeta:set_string("infotext", stalled)
                    end
                end
            end
            sbz_api.turn_off(pos)
            meta:set_string("infotext", stalled)
            return
        end

        -- Enough power for every machine: run the rig as one unit.
        local next_known = {}
        local driven = 0
        for _, m in ipairs(machines) do
            if not on_real_grid(m.pos) then
                local mnode = sbz_api.get_node_force(m.pos)
                local mname = mnode and mnode.name
                local mdef = mname and core.registered_nodes[mname]
                local mmeta = mname and core.get_meta(m.pos)
                if mdef and mmeta and mdef.action and mmeta:get_int("force_off") ~= 1 then
                    local r = mdef.action(m.pos, mname, mmeta, supply, demand)
                    local draw = tonumber(r) or 0
                    demand = demand + draw
                    next_known[core.hash_node_position(m.pos)] = draw
                    driven = driven + 1
                end
            end
        end
        known_demand = next_known

        -- Reconcile the batteries: charge them with any local surplus or
        -- drain them to cover the shortfall, mirroring the base switching
        -- station.  (Excess is local generation minus what machines used.)
        local excess = (supply - battery_supply_only) - demand
        for _, b in ipairs(battery_entries) do
            if excess == 0 then
                break
            end
            local bdef = b.def
            local bmeta = core.get_meta(b.pos)
            local current = 0
            if bdef.get_power then
                current = tonumber(bdef.get_power(b.pos, b.node, bmeta, supply, demand)) or 0
            else
                current = bmeta:get_int("power")
            end
            if b.max > 0 then
                local set_power = bdef.set_power
                    or function(pos, node, m, current_power, supplied_power)
                        m:set_int("power", supplied_power)
                    end
                if excess > 0 then -- charging
                    local power_add = b.max - current
                    if power_add > excess then power_add = excess end
                    excess = excess - power_add
                    set_power(b.pos, b.node, bmeta, current, current + power_add)
                else -- discharging
                    local power_remove = current
                    if power_remove > -excess then power_remove = -excess end
                    excess = excess + power_remove
                    set_power(b.pos, b.node, bmeta, current, current - power_remove)
                end
            end
        end

        -- Refresh every battery's display so the base "Machine timeout
        -- check" ABM doesn't clobber it with "No network found".
        for _, b in ipairs(battery_entries) do
            if b.def.action then
                b.def.action(b.pos, b.node, core.get_meta(b.pos), supply, demand)
            end
        end

        -- The relay is stateful (lit while running); it powers itself so it
        -- is always on.
        sbz_api.turn_on(pos)

        -- `@1`/`@2` placeholders must be handed to S() as arguments;
        -- core.translate substitutes them itself (a trailing :format() would
        -- throw "not enough arguments").
        meta:set_string("infotext",
            S("Available @1, used @2 (@3 machines)",
                format_power(supply), format_power(demand), driven))
    end)
    if not ok then
        core.log("error", "[nh_boring] power_relay tick failed: " .. tostring(err))
    end
end

if mesecon and mesecon.register_on_mvps_move then
    mesecon.register_on_mvps_move(function(moved_nodes)
        for _, moved in ipairs(moved_nodes) do
            if moved.node and is_relay_name(moved.node.name) then
                local meta = core.get_meta(moved.pos)
                if meta:get_int(AUTONOMOUS_KEY) == 1 then
                    if not move_relay_forceload(moved.oldpos, moved.pos) then
                        meta:set_int(AUTONOMOUS_KEY, 0)
                        meta:set_string("formspec", relay_formspec(false))
                    end
                else
                    release_relay_forceload(moved.oldpos)
                end
            end
        end
    end)
end

sbz_api.register_stateful("nh_boring:power_relay", {
    description = S("Power Relay"),
    sounds = sbz_audio.machine(),
    tiles = { "power_relay.png" },
    groups = { matter = 1, cracky = 2, pipe_connects = 1, pipe_conducts = 1, nh_boring_relay = 1 },
    paramtype = "light",
    sunlight_propagates = true,
    is_ground_content = false,
    on_construct = function(pos)
        local meta = core.get_meta(pos)
        meta:set_string("infotext", S("Power Relay"))
        meta:set_string("formspec", relay_formspec(meta:get_int(AUTONOMOUS_KEY) == 1))
    end,
    on_destruct = function(pos)
        release_relay_forceload(pos)
    end,
    on_rightclick = function(pos, _, clicker)
        if not clicker then
            return
        end
        local meta = core.get_meta(pos)
        meta:set_string("formspec", relay_formspec(meta:get_int(AUTONOMOUS_KEY) == 1))
    end,
    on_receive_fields = function(pos, _, fields, sender)
        if not sender or not fields.toggle_autonomous then
            return
        end

        local meta = core.get_meta(pos)
        if meta:get_int(AUTONOMOUS_KEY) == 1 then
            release_relay_forceload(pos)
            meta:set_int(AUTONOMOUS_KEY, 0)
        elseif acquire_relay_forceload(pos) then
            meta:set_int(AUTONOMOUS_KEY, 1)
        else
            local name = sender:get_player_name()
            if name and name ~= "" then
                core.chat_send_player(name, S("Could not enable autonomous operation; the forceload limit was reached."))
            end
        end
        meta:set_string("formspec", relay_formspec(meta:get_int(AUTONOMOUS_KEY) == 1))
    end,
    info_extra = S(
        "A pocket switching station for mobile builds. Feeds every machine "
            .. "wired to it through cables, connectors or direct contact. "
            .. "Makes no power of its own - wire in batteries (a Teleport "
            .. "Battery works great on a moving rig) or generators to feed "
            .. "it. Safe to shove with a Pusher - the whole rig can walk. "
            .. "Only runs the rig when it can power every machine at once; "
            .. "hover it to see power available and in use."
    ),
    _doc_items_longdesc = S(
        "A self-contained mini switching-station. Each tick it scans the "
            .. "wired clump around it and powers every machine it can reach, "
            .. "feeding off the batteries and generators wired into the rig "
            .. "(draining them when needed, charging them with any surplus). "
            .. "If the rig needs more power than those can supply, none of "
            .. "the machines run - the relay waits until it can feed them "
            .. "all. Unlike a real Switching Station it keeps no global "
            .. "state, so a Pusher can march the entire rig - relay included "
            .. "- forward without anything breaking. Machines already on a "
            .. "real switching-station grid are ignored, so a rig can be "
            .. "parked against a base without fighting it. Pointing at the "
            .. "relay shows how much power is available and how much the rig "
            .. "uses."
    ),
    _doc_items_usagehelp = S(
        "Place it on the rig, wire machines to it with power cables (or just "
            .. "stack them adjacent), and keep a Pusher pushing the whole "
            .. "assembly. Feed it with batteries or generators - a Teleport "
            .. "Battery is a good fit for a roaming rig since it shares one "
            .. "power pool with your base. Several relays on one rig "
            .. "cooperate; the lowest one does the work. If the rig's total "
            .. "demand exceeds the power available, the relay turns dark and "
            .. "everything stops; add batteries or generators to feed it."
    ),
}, {
    tiles = { "power_relay.png" },
    light_source = 4,
})

-- The relay drives its rig entirely on its own, so it can't wait for a
-- switching station's tick.  A fast ABM IS the tick.  It must run on both the
-- dark and the lit variant - a freshly placed relay arrives as "_off" and the
-- tick is what flips it on.
core.register_abm({
    label = "Power Relay tick",
    nodenames = { "nh_boring:power_relay_off", "nh_boring:power_relay_on" },
    interval = 0.5,
    chance = 1,
    catch_up = false,
    action = function(pos)
        relay_tick(pos)
    end,
})

do -- Power Relay recipe: a miniaturised switching station.
    local PR = "nh_boring:power_relay_off"
    local SS = "sbz_power:switching_station"
    local MP = "sbz_resources:matter_plate"
    local RC = "sbz_resources:retaining_circuit"
    local PC = "sbz_power:power_pipe"
    local AL = "sbz_chem:aluminum_ingot"
    core.register_craft({
        output = PR,
        recipe = {
            { MP, RC, MP },
            { PC, SS, PC },
            { AL, AL, AL },
        },
    })
end
