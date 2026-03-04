-- lib/empire.lua — load, save, register, and net-worth calculation for empires.
local db = require("lib.db")
local M  = {}

local PLANET_PRICES = {
    food=1200, ore=1000, tourism=1500, supply=2000, government=1800,
    education=1600, research=2500, urban=1100, petroleum=1400, anti_pollution=900
}
local UNIT_PRICES = {
    soldiers=5, fighters=8, defense_stations=200,
    heavy_cruisers=300, light_cruisers=120, carriers=150,
    generals=100, covert_agents=250
}

-- Compute net worth from empire row + planet rows
function M.calc_net_worth(e, planets)
    local nw = e.credits
    -- Military
    nw = nw + e.soldiers         * UNIT_PRICES.soldiers
    nw = nw + e.fighters         * UNIT_PRICES.fighters
    nw = nw + e.defense_stations * UNIT_PRICES.defense_stations
    nw = nw + e.heavy_cruisers   * UNIT_PRICES.heavy_cruisers
    nw = nw + e.light_cruisers   * UNIT_PRICES.light_cruisers
    nw = nw + e.carriers         * UNIT_PRICES.carriers
    nw = nw + e.generals         * UNIT_PRICES.generals
    nw = nw + e.covert_agents    * UNIT_PRICES.covert_agents
    -- Planets
    for pt, p in pairs(planets) do
        nw = nw + p.count * (PLANET_PRICES[pt] or 1000)
    end
    return math.max(0, nw)
end

-- Load empire for current user.
-- Returns empire table + planets table, or nil if not registered yet.
function M.load()
    local e = db.empire_by_user(door.user.id)
    if not e then return nil, nil end
    local planets = db.planets_for(e.id)
    e.net_worth = M.calc_net_worth(e, planets)
    return e, planets
end

-- Save empire (and net_worth) back to DB.
function M.save(e, planets)
    e.net_worth = M.calc_net_worth(e, planets)
    db.empire_update(e)
    for pt, p in pairs(planets) do
        db.planet_upsert(e.id, pt, p.count, p.production_long, p.production_short, p.supply_config)
    end
end

-- Register a new empire for the current user.
-- Returns the new empire + default planets, or nil + error string.
function M.register(empire_name)
    if #empire_name < 2 or #empire_name > 30 then
        return nil, "Empire name must be 2-30 characters."
    end
    local letter = db.next_free_letter()
    if not letter then
        return nil, "The galaxy is full (26 empires maximum)."
    end
    local e = db.empire_insert(door.user.id, empire_name, letter)
    -- Give starting planets: 3 ore, 2 food, 1 government
    local planets = db.planets_for(e.id)
    planets.ore.count        = 3
    planets.food.count       = 2
    planets.government.count = 1
    e.net_worth = M.calc_net_worth(e, planets)
    db.empire_update(e)
    for pt, p in pairs(planets) do
        db.planet_upsert(e.id, pt, p.count, p.production_long, p.production_short, p.supply_config)
    end
    return e, planets
end

-- Reset daily turns if it's a new day.
function M.refresh_turns(e)
    local today = os.date("%Y-%m-%d")
    if e.turns_date ~= today then
        e.turns_remaining = 5
        e.turns_date = today
    end
end

return M
