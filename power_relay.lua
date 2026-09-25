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

local S = core.get_translator("no_horizons")

local GENERATION = 0 -- the relay makes no power; feed it batteries/generators
local SCAN_BUDGET = 64 -- most nodes the local scan may touch before giving up

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

            local node = core.get_node_or_nil(npos)
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

            if core.get_item_group(node.name, "no_horizons_relay") > 0 then
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
                local bname = core.get_node(b.pos).name
                local bdef = core.registered_nodes[bname]
                local bmeta = core.get_meta(b.pos)
                if bdef and bmeta:get_int("force_off") ~= 1 then
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
                local gname = core.get_node(g.pos).name
                local gdef = core.registered_nodes[gname]
                local gmeta = core.get_meta(g.pos)
                if gdef and gdef.action and gmeta:get_int("force_off") ~= 1 then
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
                local mname = core.get_node(m.pos).name
                local mdef = core.registered_nodes[mname]
                local mmeta = core.get_meta(m.pos)
                if mdef and mdef.action and mmeta:get_int("force_off") ~= 1 then
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
                local mname = core.get_node(m.pos).name
                local mdef = core.registered_nodes[mname]
                local mmeta = core.get_meta(m.pos)
                if mdef and mdef.action and mmeta:get_int("force_off") ~= 1 then
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
        core.log("error", "[no_horizons] power_relay tick failed: " .. tostring(err))
    end
end

sbz_api.register_stateful("no_horizons:power_relay", {
    description = S("Power Relay"),
    sounds = sbz_audio.machine(),
    tiles = { "power_relay.png" },
    groups = { matter = 1, cracky = 2, pipe_connects = 1, pipe_conducts = 1, no_horizons_relay = 1 },
    paramtype = "light",
    sunlight_propagates = true,
    is_ground_content = false,
    on_construct = function(pos)
        core.get_meta(pos):set_string("infotext", S("Power Relay"))
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
    nodenames = { "no_horizons:power_relay_off", "no_horizons:power_relay_on" },
    interval = 0.5,
    chance = 1,
    catch_up = false,
    action = function(pos)
        relay_tick(pos)
    end,
})

do -- Power Relay recipe: a miniaturised switching station.
    local PR = "no_horizons:power_relay_off"
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
