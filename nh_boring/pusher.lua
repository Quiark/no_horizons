--[[
    pusher.lua
    ==========

    The Pusher: a piston-like block that walks.

    Like a Minecraft/Mineclonia piston it shoves the blocks in front of it
    one cell at a time, but unlike a piston it also pushes *itself*, so a
    single Pusher keeps marching forward - and can repeat indefinitely as
    long as it stays fed with power and has an opening to march into.

    Blocks are moved with sbz_api.move_node (from mesecons_mvps), which is
    metadata-safe: inventories, node timers, pipes state and entities are all
    carried along.  Nothing is dug, so cargo keeps its contents.

    Power: the Pusher is a normal sbz power-grid machine.  Because it moves,
    the feed must follow it - run an Emittrium Power Cable under the whole
    path it will travel so it always has a feed to tap at its feet.  If it
    steps off the grid it stops and waits for power.

    Facing: the Pusher points where it was placed against (click a block
    face); it shoves in that direction.  It respects mesecons mvps stoppers
    (unloadable/ignored chunks, protected areas, registered unmovables) and
    never pushes into an unloaded mapblock.
--]]

local S = core.get_translator("nh_boring")

local PUSHER = "nh_boring:pusher"

local POWER_PER_BLOCK = 50 -- Cj drained per shove per unit of push depth
local MAX_DEPTH = 5 -- configurable push depth (blocks pushed, not counting the pusher)
local DEFAULT_DEPTH = 1
local LOOP_DELAY = 1.5 -- seconds to wait between shoves
local SELECTED_COLOR = "#98971a" -- matches sbz_ui default palette neutral_green

local function pusher_power(depth)
    return depth * POWER_PER_BLOCK
end

-- Invalidate the cached power network touching a position so a moved Pusher
-- is picked up by the next switching-station assembly.
local function mark_network_dirty(pos)
    local get_net = sbz_api.get_switching_station_network
    if not get_net then
        return
    end
    local net = get_net(pos)
    if net then
        net.dirty = true
    end
end

-- Scan the line the pusher will shove.  Returns the list of cells to move
-- (starting at `pusher_pos`) and the open cell they will land on, or
-- nil + reason when the shove is impossible.  `depth` is how many blocks in
-- front to push, not counting the pusher itself.
local function build_chain(pusher_pos, dir, owner, depth)
    local chain = { pusher_pos }
    local front = vector.add(pusher_pos, dir)

    for i = 2, depth + 1 do
        local node = sbz_api.get_node_force(front)
        if node == nil or node.name == "ignore" then
            return nil, "unloaded"
        end
        local def = core.registered_nodes[node.name]
        if not def then
            return nil, "unknown"
        end
        if def.buildable_to then
            if core.is_protected(front, owner) then
                return nil, "protected"
            end
            return chain, front
        end
        if nh_boring.is_protected_node(node) then
            return nil, "protected"
        end
        if mesecon and mesecon.is_mvps_stopper(node, front, vector.add(front, dir)) then
            return nil, "blocked"
        end
        if core.is_protected(front, owner) then
            return nil, "protected"
        end
        chain[#chain + 1] = vector.copy(front)
        front = vector.add(front, dir)
    end

    -- Hit the shove limit; the very next cell must be open to receive the line
    local node = sbz_api.get_node_force(front)
    if node == nil or node.name == "ignore" then
        return nil, "unloaded"
    end
    local def = core.registered_nodes[node.name]
    if not def or not def.buildable_to then
        return nil, "blocked"
    end
    if core.is_protected(front, owner) then
        return nil, "protected"
    end
    return chain, front
end

-- Move the whole line in one batch. `sbz_api.move_node` is deliberately used
-- for single-node moves and emits world updates per call; using it for a row
-- exposes those intermediate empty cells to clients. Snapshot all node state
-- first, then write the destinations and clear the sources as one shove.
local function do_shove(chain, dir)
    local moved = {}

    for i = #chain, 1, -1 do
        local from = chain[i]
        local to = vector.add(from, dir)
        local node = sbz_api.get_node_force(from)
        if not node then
            return false
        end
        local meta = core.get_meta(from):to_table()
        local timer = core.get_node_timer(from)
        moved[#moved + 1] = {
            oldpos = vector.copy(from),
            pos = to,
            node = node,
            meta = meta,
            timer_started = timer:is_started(),
            timer_timeout = timer:get_timeout(),
            timer_elapsed = timer:get_elapsed(),
        }
    end

    -- Keep `move_node`'s pre-move hook ordering for multiblocks.
    for _, move in ipairs(moved) do
        local node_def = core.registered_nodes[move.node.name]
        if node_def and node_def.before_movenode then
            node_def.before_movenode(move.oldpos, move.pos)
        end
    end

    for _, move in ipairs(moved) do
        core.set_node(move.pos, move.node)
        core.get_meta(move.pos):from_table(move.meta)
        if move.timer_started then
            core.get_node_timer(move.pos):set(move.timer_timeout, move.timer_elapsed)
        end
    end

    -- Clear only the cells not overwritten by another member of the row.
    -- With an adjacent one-cell shove this is the original pusher position.
    local destinations = {}
    for _, move in ipairs(moved) do
        destinations[core.hash_node_position(move.pos)] = true
    end
    for _, move in ipairs(moved) do
        if not destinations[core.hash_node_position(move.oldpos)] then
            core.remove_node(move.oldpos)
        end
        mark_network_dirty(move.oldpos)
        mark_network_dirty(move.pos)
    end

    for _, callback in ipairs(sbz_api.on_mvps_move or {}) do
        callback(moved)
    end

    return true
end

local function pusher_action(pos, node, meta, supply, demand)
    -- The grid can still hold our old position after we walked away, and the
    -- `node` argument is only the node *name* (the grid passes just that).
    local here = sbz_api.get_node_force(pos)

    -- Push depth is configured per block (1..MAX_DEPTH via the formspec).
    -- Power scales with it: depth * POWER_PER_BLOCK per shove.
    local depth = meta:get_int("push_depth")
    if depth < 1 or depth > MAX_DEPTH then
        depth = DEFAULT_DEPTH
    end
    local needed = pusher_power(depth)

    if not here or here.name ~= PUSHER then
        return needed
    end

    -- Do not run unless the network can afford this depth.
    if (demand + needed) > supply then
        meta:set_string("infotext", "Not enough power, needs: " .. needed)
        return needed
    end

    -- OUTER LOOP: this gate is the only delay.  The grid calls the action
    -- every tick; while next_push_us is still in the future we do nothing,
    -- so the pause is exactly LOOP_DELAY between shoves.
    local now_us = core.get_us_time()
    if (tonumber(meta:get_string("next_push_us")) or 0) > now_us then
        return needed
    end

    local owner = meta:get_string("owner")
    if core.is_protected(pos, owner) then
        return needed
    end

    -- The moving pusher keeps its param2, but guard anyway: a nil here would
    -- abort the whole server (fatal), not just this block.
    if not here.param2 then
        return needed
    end

    -- Push direction is the opposite of the facedir back: the front texture
    -- (tiles[6]) faces where the pusher shoves.
    local dir = vector.multiply(core.facedir_to_dir(here.param2), -1)
    if not dir or (dir.x == 0 and dir.y == 0 and dir.z == 0) then
        return needed
    end

    local chain = build_chain(pos, dir, owner, depth)
    if not chain then
        -- Blocked (wall, range limit, protected or unloaded ahead): retry
        -- when the grid calls us again.
        return needed
    end

    -- Arm the loop delay *before* moving: the pusher's metadata rides along
    -- in the shove, so the delay survives the relocation.
    meta:set_string("next_push_us", tostring(now_us + LOOP_DELAY * 1e6))

    if not do_shove(chain, dir) then
        return needed
    end

    local moved_meta = core.get_meta(vector.add(pos, dir))
    moved_meta:set_string("infotext", ("Running (depth %d, %d Cj)"):format(depth, needed))

    local front = vector.add(chain[#chain], dir)
    core.sound_play("mix_compressor_twice", {
        pos = front,
        gain = 0.5,
        max_hear_distance = 24,
    }, true)

    -- little dust puff where the line landed
    core.add_particlespawner({
        amount = 6,
        time = 0.25,
        minpos = vector.subtract(front, 0.4),
        maxpos = vector.add(front, 0.4),
        minvel = { x = -0.5, y = 0.5, z = -0.5 },
        maxvel = { x = 0.5, y = 1.5, z = 0.5 },
        minexptime = 0.4,
        maxexptime = 0.9,
        minsize = 0.5,
        maxsize = 1,
        texture = "pusher_front.png^[opacity:120",
        glow = 4,
    })

    return needed
end

local function pusher_formspec(depth)
    local row = {}
    for d = 1, MAX_DEPTH do
        row[#row + 1] = ("button[%d,1.2;1,0.9;push_%d;%d]"):format(
            0.4 + (d - 1) * 1.15, d, d)
    end
    return table.concat({
        "formspec_version[3]",
        "size[6,3.2]",
        "label[0.4,0.2;" .. S("Push depth") .. "]",
        "label[0.4,0.7;" .. S("Blocks pushed per move (not counting itself)") .. "]",
        -- Keep the button matching the saved depth highlighted.
        "style[push_" .. depth .. ";bgcolor=" .. SELECTED_COLOR .. "]",
        table.concat(row),
        "label[0.4,2.4;" .. ("%s: %d block - %d Cj"):format(
            S("Current"), depth, pusher_power(depth)) .. "]",
    })
end

sbz_api.register_machine("nh_boring:pusher", {
    description = S("Pusher"),
    _tt_help = S("Powered piston that pushes blocks and itself"),
    _doc_items_longdesc = S(
        "A piston-like machine. When powered it shoves the whole row in "
            .. "front of it forward in one go, then shoves itself forward too, "
            .. "repeating forever with a 1.5 s pause in between. Right-click to "
            .. "set the push depth (1-5 blocks, not counting itself); power "
            .. "drawn scales with depth (50 Cj per block per move). Cargo keeps "
            .. "its inventory and metadata. It needs a power feed that follows "
            .. "it - lay an Emittrium Power Cable under its whole path so it "
            .. "keeps contact as it walks."
    ),
    sounds = sbz_audio.machine(),
    tiles = {
        "pusher_top.png",
        "pusher_side.png",
        "pusher_side.png",
        "pusher_side.png",
        "pusher_back.png",
        "pusher_front.png",
    },
    groups = { matter = 1, cracky = 2 },
    paramtype = "light",
    paramtype2 = "facedir",
    sunlight_propagates = true,
    walkable = true,
    is_ground_content = false,

    on_construct = function(pos)
        local meta = core.get_meta(pos)
        if meta:get_int("push_depth") < 1 then
            meta:set_int("push_depth", DEFAULT_DEPTH)
        end
        meta:set_string("formspec", pusher_formspec(meta:get_int("push_depth")))
    end,

    on_receive_fields = function(pos, _, fields, player)
        if not player then
            return
        end
        local depth
        for d = 1, MAX_DEPTH do
            if fields["push_" .. d] then
                depth = d
                break
            end
        end
        if not depth then
            return
        end
        local meta = core.get_meta(pos)
        meta:set_int("push_depth", depth)
        -- Updating the stored formspec is enough: the engine re-renders an
        -- open node formspec when its metadata changes.
        meta:set_string("formspec", pusher_formspec(depth))
    end,

    after_place_node = function(pos, placer, itemstack, pointed_thing)
        if not placer then
            return
        end
        local meta = core.get_meta(pos)
        meta:set_string("owner", placer:get_player_name())
        if not pointed_thing or pointed_thing.type ~= "node" then
            return
        end

        local dir = vector.subtract(pointed_thing.above, pointed_thing.under)
        local node = core.get_node(pos)
        -- The distinct front texture is tiles[6]; with facedir that face
        -- points at -facedir_to_dir(param2), so store the negated push
        -- direction and read it back negated in pusher_action.
        node.param2 = core.dir_to_facedir(vector.multiply(dir, -1), true)
        core.swap_node(pos, node)
    end,

    -- The base grid's "Machine timeout check" ABM runs on every
    -- group:sbz_machine node and expects a switching station's tick to keep
    -- it alive.  When this pusher is powered by a Power Relay (which never
    -- "touches" nodes), that check would keep clobbering our infotext with
    -- "No network found"; restore a useful one the instant it fires.
    on_timeout = function(pos)
        core.get_meta(pos):set_string("infotext", S("Pusher"))
    end,

    action = pusher_action,
    control_action_raw = true,

    -- Lets a Power Relay probe this machine's per-tick draw without actually
    -- running it, so the rig's all-or-nothing gate can sum up the demand of
    -- every machine before switching anything on.
    get_power_needed = function(_, _, meta)
        local depth = meta:get_int("push_depth")
        if depth < 1 or depth > MAX_DEPTH then
            depth = DEFAULT_DEPTH
        end
        return pusher_power(depth)
    end,
})

do -- Pusher recipe scope
    local PU = "nh_boring:pusher"
    local MP = "sbz_resources:matter_plate"
    local RC = "sbz_resources:retaining_circuit"
    local AL = "sbz_chem:aluminum_ingot"
    local PC = "sbz_power:power_pipe"
    core.register_craft({
        output = PU,
        recipe = {
            { MP, RC, MP },
            { AL, PC, AL },
            { MP, RC, MP },
        },
    })
end

-- The base Switching Station is a fragile network anchor tracked in global
-- tables (all_switching_stations, pos2network/networks, touched_nodes ...) -
-- it was never meant to move, and a Pusher shoving it can occasionally eat
-- it.  Treat it like the base game treats its other immovable infrastructure
-- (the_core, meteorite makers, elevators): register it as an mvps stopper so
-- the Pusher simply refuses to shove it.  Use a Power Relay on mobile rigs
-- instead.
if mesecon and mesecon.register_mvps_stopper then
    mesecon.register_mvps_stopper("sbz_power:switching_station")
end
