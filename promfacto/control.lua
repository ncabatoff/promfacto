-- Plan: 
--  - count chunks with aliens + pollutions
--  - sample input inventory: when zero, indicates a potentially starved/idle machine
--  - sample input inventory: when nonzero, indicates a potentially blocked machine
--  - try counting enemies via surface rather than game.force

-- require "defines"

prometheus = require("prometheus/tarantool-prometheus")
count_deaths = prometheus.counter("factorio_deaths", "entity died", {"entity_name"})
gauge_objects = prometheus.gauge("factorio_objects", "items owned by player", {"force", "name", "placement"})
count_sectors_scanned = prometheus.counter("factorio_sectors_scanned", "radar sectors scanned")
gauge_chunks_generated = prometheus.gauge("factorio_chunks_generated", "number of active 32x32-tile chunks")
gauge_pollution_total = prometheus.gauge("factorio_pollution_total", "total pollution")
gauge_evolution_factor = prometheus.gauge("factorio_evolution_factor", "evolution_factor")
gauge_fluid_stored = prometheus.gauge("factorio_fluid_stored", "fluid stored", {"force", "resource_name"})
gauge_energy = prometheus.gauge("factorio_energy", "energy", {"force", "entity_name"})
gauge_crafting = prometheus.gauge("factorio_crafting", "crafting", {"force", "entity_name"})
gauge_hasoutput = prometheus.gauge("factorio_hasoutput", "has output", {"force", "entity_name"})
gauge_hasinput = prometheus.gauge("factorio_hasinput", "has output", {"force", "entity_name"})
gauge_builders = prometheus.gauge("factorio_assemblers", "assemblers", {"force", "recipe_name"})
gauge_furnaces = prometheus.gauge("factorio_furnaces", "furnaces", {"force", "product", "status"})

---  Enable/Disable Debugging
local DEV = true

local XY = {}
XY.__index = XY

setmetatable(XY, {
    __call = function (cls, ...)
        return cls.new(...)
    end,
    __eq = function (c1, c2)
        return (c1.x == c2.x) and (c1.y == c2.y)
    end,
})

function XY.new(x, y)
    local self = setmetatable({}, XY)
    self.x = x
    self.y = y
    return self
end

function XY:tostr()
    return self.x .. "," .. self.y
end

--- on_init event
script.on_init(function()
    init()
    -- init player specific globals
    initPlayers()
end)

--- on_load event
script.on_load(function()
    init()
end)

function init()
    global.fluidEntities = global.fluidEntities or {}
    global.furnaces = global.furnaces or {}
    global.furnaceDetails = global.furnaceDetails or {}
    global.batteries = global.batteries or {}
    global.builders = global.builders or {}
end

script.on_event(defines.events.on_sector_scanned, function(event)
    count_sectors_scanned:inc(1)
    -- TODO use event.radar entity as part of label of count_sectors_scanned
    -- TODO can we get the sector in question from event?  should we distinguish new sectors from repeats?
    -- TODO hook up enemy entity counting?
end)

--- Player Related Events
script.on_event(defines.events.on_player_created, function(event)
    playerCreated(event)
end)

--
--- Entity Related Events
script.on_event(defines.events.on_built_entity, function(event)
    entityBuilt(event, event.created_entity)
end)

script.on_event(defines.events.on_robot_built_entity, function(event)
    entityBuilt(event, event.created_entity)
end)

script.on_event(defines.events.on_preplayer_mined_item, function(event)
    entityMined(event, event.entity)
end)

script.on_event(defines.events.on_robot_pre_mined, function(event)
    entityMined(event, event.entity)
end)

script.on_event(defines.events.on_entity_died, function(event)
    count_deaths:inc(1, {event.entity.name})
    entityMined(event, event.entity)
end)


local initdone=false
script.on_event(defines.events.on_tick, function(event)
    if ( not initdone ) or ( event.tick % 600 == 0 ) then
        if not initdone then
            initdone = true
            initPlayers()
        end
        updatePlayers()
        writeMetrics()
    end
end)

--- init all players
function initPlayers()
    for _,player in pairs(game.players) do
        initPlayer(player)
    end
end

--- init new players
function playerCreated(event)
    local player = game.players[event.player_index]
    initPlayer(player)
end
--
--- init player specific global values
function initPlayer(player)
    global.fluidEntities = getEntities(player.force, {'storage-tank'})
    global.seenFluids = {}
    reportFluids(player.force.name)

    global.furnaces = getEntities(player.force, {'furnace'})
    reportFurnaces(player.force.name)

    global.batteries = getEntities(player.force, {'accumulator'})
    reportBatteries(player.force.name)

    global.builders = getEntities(player.force, {'assembling-machine'})
    reportBuilders(player.force.name)
end

function updatePlayers()
    for _,player in pairs(game.players) do
        updatePlayer(player)
    end
end

function updatePlayer(player)
    local force = player.force
    local forceName = force.name
    local index = player.index

    -- print("updatePlayer " .. forceName)

    if player.controller_type == defines.controllers.character then
        local invs = {defines.inventory.player_main, defines.inventory.player_quickbar, defines.inventory.player_guns,
                      defines.inventory.player_ammo, defines.inventory.player_armor, defines.inventory.player_tools,
                      defines.inventory.player_trash,}
        for _, invid in ipairs(invs) do
            inventory = player.get_inventory(invid)
            for n,v in pairs(inventory.get_contents()) do
                gauge_objects:set(v, {forceName, n, "inventory"})
            end
        end
    end

    -- TODO add gauge for current tick (or counter for ticks passed?)
    gauge_evolution_factor:set(game.evolution_factor)
    getPollution()
    reportFluids(forceName)
    reportFurnaces(forceName)
    reportBatteries(forceName)
    reportBuilders(forceName)

    -- print "updatePlayer done"
end

function reportFluids(forceName)
    local seen = {}
    for resname, amount in pairs(getStoredFluids(global.fluidEntities)) do
        gauge_fluid_stored:set(amount, {forceName, resname})
        seen[resname] = true
    end

    for resname, _ in pairs(global.seenFluids) do
        if not seen[resname] then
            gauge_fluid_stored:set(0, {forceName, resname})
        end
    end
    global.seenFluids = seen
end

-- Categories of interest: 
-- 1. crafting
-- 2. not crafting, non-empty output (implies there's no demand)
-- 2. not crafting, no input (implies there's no supply) -- TODO refine for multi-input case
function reportFurnaces(forceName)
    local totEnergy = 0
    local furnaces = {}
    local surface = game.surfaces["nauvis"]
    for xys,ent in pairs(global.furnaces) do
        local details = global.furnaceDetails[xys] or {name = ent.name}
        if (not ent.valid) and details then
            ent = surface.find_entity(details.name, str2pos(xys))
        end
        if ent then
            totEnergy = totEnergy + ent.energy

            local inpinv = ent.get_inventory(defines.inventory.furnace_source)
            for k,v in pairs(inpinv.get_contents()) do
                details.product = k
            end

            local outpinv = ent.get_output_inventory()
            local gotoutp = not outpinv.is_empty()
            local maxedout
            if gotoutp then
                for k,v in pairs(outpinv.get_contents()) do
                    details.product = k
                    if v == 100 then
                        maxedout = true
                    end
                    break
                end
            end
            local product = string.match(details.product, "[^-]+") or "unknown"

            local status = "idle"
            if ent.is_crafting() and not maxedout then
                status = "crafting"
            end
            if outpinv.is_empty() then
                status = status .. " no outputs"
            else
                status = status .. " with outputs"
            end

            furnaces[product] = furnaces[product] or {}
            furnaces[product][status] = 1 + (furnaces[product][status] or 0)

            global.furnaceDetails[xys] = details
        elseif details then
            global.furnaceDetails[xys] = nil
        end
    end

    gauge_energy:set(totEnergy, {forceName, "furnaces"})

    for product,states in pairs(furnaces) do
        for state, n in pairs(states) do
            gauge_furnaces:set(n, {forceName, product, state})
        end
    end
end

function reportBatteries(forceName)
    local totEnergy = 0
    local surface = game.surfaces["nauvis"]
    for xys,ent in pairs(global.batteries) do
        if not ent.valid then
            ent = surface.find_entity("basic-accumulator", str2pos(xys))
        end
        if ent then
            totEnergy = totEnergy + ent.energy
        end
    end
    gauge_energy:set(totEnergy, {forceName, "accumulators"})
end

function reportBuilders(forceName)
    local countByRecipe = {}
    local hasoutput = {}
    local hasinput = {}
    local crafting = {}
    local surface = game.surfaces["nauvis"]
    for xys,ent in pairs(global.builders) do
        if not ent.valid then
            for i = 1,3 do
                ent = surface.find_entity("assembling_machine-" .. i, str2pos(xys))
                if ent then
                    break
                end
            end
        end
        if ent then
            local recipe = ent.recipe
            if ent.recipe then
                local name = ent.recipe.name
                countByRecipe[name] = 1 + ( countByRecipe[name] or 0 )

                if ent.is_crafting() then
                    crafting[name] = 1 + (crafting[name] or 0)
                end
                if not ent.get_output_inventory().is_empty() then
                    hasoutput[name] = 1 + (hasoutput[name] or 0)
                end
                if not ent.get_inventory(defines.inventory.assembling_machine_input).is_empty() then
                    hasinput[name] = 1 + (hasinput[name] or 0)
                end
            end
        end
    end
    for recipe, count in pairs(countByRecipe) do
        gauge_builders:set(count, {forceName, recipe})
    end

    for recipe, count in pairs(hasoutput) do
        gauge_hasoutput:set(count, {forceName, recipe})
    end
    for recipe, count in pairs(hasinput) do
        gauge_hasinput:set(count, {forceName, recipe})
    end
    for recipe, count in pairs(crafting) do
        gauge_crafting:set(count, {forceName, recipe})
    end
end


function getPollution()
    local surface = game.surfaces["nauvis"]
    local pollutionTotal = 0
    local chunks = 0
    forEachChunk(function(chunk_coord, area)
        local samplePos = area[1]
        pollution = surface.get_pollution(samplePos)
        pollutionTotal = pollutionTotal + pollution
        chunks = chunks + 1
        return pollution
    end)
    gauge_chunks_generated:set(chunks)
    gauge_pollution_total:set(pollutionTotal)
end

function forEachChunk(f)
    local surface = game.surfaces["nauvis"]

    for coord in surface.get_chunks() do
        local X,Y = coord.x, coord.y

        if surface.is_chunk_generated{X,Y} then
            local area = {{X*32, Y*32}, {X*32 + 32, Y*32 + 32}}
            f(coord,area)
        end
    end
end

function getEntities(force, types)
    -- print("getEntities " .. serpent.line(types))

    local surface = game.surfaces["nauvis"]

    local ents = {}
    forEachChunk(function(chunk_coord, area)
        for _,type in pairs(types) do
            -- print("scanning for type " .. type .. " at " .. serpent.line(area))
            for _,ent in pairs(surface.find_entities_filtered{area=area, type=type, force=force.name}) do
                local xy = XY(ent.position.x, ent.position.y)
                -- print("found ent at " .. xy:tostr())
                ents[xy:tostr()] = ent
            end
        end
    end)
    -- print("getEntities " .. serpent.line(types) .. " done")
    return ents
end

function getStoredFluids(storageTanksByPos)
    local count_by_name_total = {}
    local surface = game.surfaces["nauvis"]

    for xys,ent in pairs(storageTanksByPos) do
        if ent then
            if not ent.valid then
                ent = surface.find_entity("storage-tank", str2pos(xys))
            end
            if ent then
                -- print("checking fluid at " .. xys)
                local fb = ent.fluidbox[1]
                if fb then
                    count_by_name_total[fb.type] = fb.amount + (count_by_name_total[fb.type] or 0)
                end
            end
        end
    end

    return count_by_name_total
end

function entityBuilt(event, ent)
    if ent.type == "storage-tank" then
        local xy = XY(ent.position.x, ent.position.y)
        global.fluidEntities[xy:tostr()] = ent
    end
    if ent.type == "furnace" then
        local xy = XY(ent.position.x, ent.position.y)
        global.furnaces[xy:tostr()] = ent
    end
    if ent.type == "accumulator" then
        local xy = XY(ent.position.x, ent.position.y)
        global.batteries[xy:tostr()] = ent
    end
    if ent.type == "assembling-machine" then
        local xy = XY(ent.position.x, ent.position.y)
        global.builders[xy:tostr()] = ent
    end
end

function entityMined(event, ent)
    if ent.type == "storage-tank" then
        local xy = XY(ent.position.x, ent.position.y)
        if global.fluidEntities[xy:tostr()] == nil then
            -- print("mined tank we didn't know about? pos=" .. xy:tostr())
        else
            -- print("mined tank pos=" .. xy:tostr())
        end

        global.fluidEntities[xy:tostr()] = nil
    end

    if ent.type == "furnace" then
        local xy = XY(ent.position.x, ent.position.y)
        global.furnaces[xy:tostr()] = nil
    end

    if ent.type == "accumulator" then
        local xy = XY(ent.position.x, ent.position.y)
        global.batteries[xy:tostr()] = nil
    end

    if ent.type == "assembling-machine" then
        local xy = XY(ent.position.x, ent.position.y)
        global.builders[xy:tostr()] = nil
    end
end

function xy2str(x,y)
    return string.gsub('@' .. x .. "," .. y, "-", "_")
end

function pos2str(pos)
    return pos.x .. "," .. pos.y
end

function str2pos(str)
    local xy = str:split(",")
    return {x = xy[1], y = xy[2]}
end

function cpos2str(pos)
    return string.gsub('C' .. pos.x .. "," .. pos.y, "-", "_")
end

function getCenterTile(entity)
    local rX, rY = entity.position.x, entity.position.y
    return {{rX-0.5, rY-0.5}, {rX+0.5, rY+0.5}}
end

function pos2cpos(x, y)
    return x / 32, y / 32
end

function forEachCoord(area, f)
    for x = area.left_top.x, area.right_bottom.x do
        for y = area.left_top.y, area.right_bottom.y do
            f(x,y)
        end
    end
end

function genarea(area)
    local lt = {}
    if area.left_top then
        lt.x = area.left_top.x
        lt.y = area.left_top.y
    else
        lt.x = area[1][1]
        lt.y = area[1][2]
    end

    local rb = {}
    if area.right_bottom then
        rb.x = area.right_bottom.x
        rb.y = area.right_bottom.y
    else
        rb.x = area[2][1]
        rb.y = area[2][2]
    end
    return {left_top = lt, right_bottom = rb}
end

function rectInset(area, n)
    local a = genarea(area)
    a.left_top.x = a.left_top.x + n
    a.left_top.y = a.left_top.y + n
    a.right_bottom.x = a.right_bottom.x + n
    a.right_bottom.y = a.right_bottom.y + n
    return a
end

function rectAdd(area,x,y)
    local a = genarea(area)
    a.left_top.x = a.left_top.x + x
    a.left_top.y = a.left_top.y + y
    a.right_bottom.x = a.right_bottom.x + x
    a.right_bottom.y = a.right_bottom.y + y
    return a
end

-- debugging tools
function debugLog(msg, force)
    if (DEV or force) and msg then
            for i,player in pairs(game.players) do
                if player and player.valid then
                    if type(msg) == "string" then
                        player.print(msg)
                    else
                        player.print(serpent.dump(msg))
                    end
                end
            end
    end
end

function writeMetrics()
  game.write_file("metrics/game.prom", prometheus.collect(), false)
end

--http://lua-users.org/wiki/SplitJoin 
--Written for 5.0; could be made slightly cleaner with 5.1
--Splits a string based on a separator string or pattern;
--returns an array of pieces of the string.
--(May optionally supply a table as the third parameter which will be filled 
--with the results.)
function string:split( inSplitPattern, outResults )
  if not outResults then
    outResults = { }
  end
  local theStart = 1
  local theSplitStart, theSplitEnd = string.find( self, inSplitPattern, theStart )
  while theSplitStart do
    table.insert( outResults, string.sub( self, theStart, theSplitStart-1 ) )
    theStart = theSplitEnd + 1
    theSplitStart, theSplitEnd = string.find( self, inSplitPattern, theStart )
  end
  table.insert( outResults, string.sub( self, theStart ) )
  return outResults
end
