-- lib/economy.lua — planet production, maintenance, food market, pricing.
local db = require("lib.db")
local M  = {}

-- Planet base production values (credits or megatons per turn per planet)
local BASE_PROD = {
    ore          = 120,
    tourism      = 180,
    petroleum    = 150,
    urban        = 80,
    food         = 50,   -- megatons
    supply       = 0,    -- produces units, not credits
    government   = 0,
    education    = 0,
    research     = 10,   -- research points
    anti_pollution = 0,
}

-- Violence multipliers for tourism (internal_violence 0..7)
local TOURISM_MULT = { 1.5, 1.2, 0.8, 0.4, 0.1, 0.05, 0.01, 0.0 }

-- Gaussian approximation using Box-Muller
local function gauss(mean, sigma)
    local u1 = math.random() + 1e-10
    local u2 = math.random()
    local z  = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
    return math.floor(mean + sigma * z)
end

-- Mean-reversion: move production_short 10% toward production_long each turn.
function M.tick_production(p)
    local diff = p.production_long - p.production_short
    p.production_short = p.production_short + math.ceil(math.abs(diff) * 0.1) * (diff >= 0 and 1 or -1)
end

-- Count total petroleum planets across all empires (for price calculation).
local function galaxy_petroleum_ratio()
    local rows = door.db.query([[
        SELECT SUM(CASE WHEN planet_type='petroleum' THEN count ELSE 0 END) as pet,
               SUM(count) as total
        FROM door_sre_planets
    ]], {})
    local r = rows[1]
    local pet   = (r and r.pet)   or 0
    local total = (r and r.total) or 1
    if total == 0 then return 1.0 end
    -- At ratio 1:10 petroleum planet income == ore income
    -- demand_factor = (1/10) / (pet/total)  clamped 0.2..3.0
    local ratio = pet / total
    if ratio <= 0 then return 3.0 end
    return math.max(0.2, math.min(3.0, 0.1 / ratio))
end

-- Returns total pollution level (sum of all empire petroleum planets minus anti-pollution)
local function galaxy_pollution()
    local rows = door.db.query([[
        SELECT
            SUM(CASE WHEN planet_type='petroleum'      THEN count ELSE 0 END) as pet,
            SUM(CASE WHEN planet_type='anti_pollution' THEN count ELSE 0 END) as anti
        FROM door_sre_planets
    ]], {})
    local r = rows[1]
    local pet  = (r and r.pet)  or 0
    local anti = (r and r.anti) or 0
    return math.max(0, pet - anti * 3)
end

-- Compute buy price for a unit/planet type under the current pricing mode.
-- mode: "inflationary" or "non_inflationary"
local UNIT_BASE = {
    soldiers=5, fighters=8, defense_stations=200,
    heavy_cruisers=300, light_cruisers=120, carriers=150,
    generals=100, covert_agents=250, command_ship=50000,
}
local PLANET_BASE = {
    food=1200, ore=1000, tourism=1500, supply=2000, government=1800,
    education=1600, research=2500, urban=1100, petroleum=1400, anti_pollution=900
}

function M.buy_price(item, net_worth, mode)
    local base = UNIT_BASE[item] or PLANET_BASE[item] or 0
    if mode == "inflationary" then
        local mult = math.max(1.0, math.sqrt(net_worth / 10000))
        return math.floor(base * mult)
    else
        -- non-inflationary: price fixed; maintenance scales instead
        return base
    end
end

-- Maintenance cost per turn for the whole empire.
function M.maintenance_cost(e, planet_count, mode)
    local army =
        e.soldiers       * 5  +
        e.fighters       * 8  +
        e.defense_stations * 8  +
        e.heavy_cruisers * 12 +
        e.light_cruisers * 6  +
        e.carriers       * 4  +
        e.generals       * 3  +
        e.covert_agents  * 5
    local planet_maint
    if mode == "inflationary" then
        planet_maint = planet_count * 1000
    else
        -- scales with log(net_worth)
        local scale = math.max(1, math.log(math.max(1, e.net_worth)))
        planet_maint = math.floor(planet_count * (500 + scale * 50))
    end
    return army + planet_maint
end

-- Food consumed per turn: 1 megaton per 33 soldiers; population eats 1mt per 50k people.
function M.food_consumed(e)
    local army_food = math.ceil(e.soldiers / 33)
    local pop_food  = math.ceil(e.population / 50000)
    return army_food + pop_food
end

-- ── Planet income for one empire per turn ────────────────────────────────────
-- Returns: { credits, food_prod, research_pts, supply, poll_delta }
function M.planet_income(e, planets, galaxy)
    math.randomseed(door.time() + e.id * 31337)
    local credits   = 0
    local food_prod = 0
    local res_pts   = 0
    local supply    = { soldiers=0, fighters=0, defense_stations=0,
                        heavy_cruisers=0, light_cruisers=0 }
    local poll_delta = 0

    local mode        = galaxy.mode or "non_inflationary"
    local pet_factor  = galaxy_petroleum_ratio()
    local poll_level  = tonumber(galaxy.pollution_level or "0")
    local tourism_mod = 1.0 - math.min(0.5, poll_level / 200)  -- pollution hurts tourism

    for pt, p in pairs(planets) do
        if p.count <= 0 then goto continue end
        M.tick_production(p)  -- mean-reversion each turn

        if pt == "ore" then
            credits = credits + p.count * gauss(p.production_short, p.production_short * 0.05)

        elseif pt == "tourism" then
            local mult = (TOURISM_MULT[e.internal_violence + 1] or 0) * tourism_mod
            credits = credits + math.floor(p.count * gauss(p.production_short, p.production_short * 0.1) * mult)

        elseif pt == "petroleum" then
            credits = credits + math.floor(p.count * gauss(p.production_short, p.production_short * 0.08) * pet_factor)
            poll_delta = poll_delta + p.count  -- 1 pollution per petroleum planet per turn

        elseif pt == "anti_pollution" then
            poll_delta = poll_delta - p.count * 3  -- absorbs 3 pollution per planet

        elseif pt == "urban" then
            -- Sales tax income; population growth handled in population.lua
            local tax_income = math.floor(e.population * (e.tax_rate / 100) * 0.002 * p.count)
            credits = credits + gauss(tax_income, tax_income * 0.05)

        elseif pt == "food" then
            food_prod = food_prod + p.count * gauss(p.production_short, p.production_short * 0.05)

        elseif pt == "research" then
            res_pts = res_pts + p.count * p.production_short

        elseif pt == "supply" then
            -- Produce military units at 60% of buy price value
            local unit     = p.supply_config or "soldiers"
            local val      = (UNIT_BASE[unit] or 5)
            local produced = math.floor(p.count * p.production_short / val * 0.6)
            supply[unit]   = (supply[unit] or 0) + produced

        elseif pt == "education" then
            -- No direct income; immigration handled in population.lua
        elseif pt == "government" then
            -- No income; general capacity
        end

        ::continue::
    end

    return {
        credits      = math.max(0, credits),
        food_prod    = math.max(0, food_prod),
        research_pts = math.max(0, res_pts),
        supply       = supply,
        poll_delta   = poll_delta,
    }
end

-- ── Food market ───────────────────────────────────────────────────────────────
-- Price = f(market_stock + all_empire_food_holdings)
-- Prevents buy-all/sell-all exploit by including empire holdings in price calc.
function M.food_price()
    local market = tonumber(db.galaxy_get("food_market_stock") or "100000")
    local rows   = door.db.query("SELECT SUM(food) as total FROM door_sre_empires WHERE is_active=1", {})
    local held   = (rows[1] and rows[1].total) or 0
    local total  = market + held
    -- Base price 10 credits/mt; drops as supply increases; floor 2, cap 50
    local price  = math.floor(500000 / math.max(1, total))
    return math.max(2, math.min(50, price))
end

function M.food_buy(e, megatons)
    local price   = M.food_price()
    local cost    = megatons * price
    local market  = tonumber(db.galaxy_get("food_market_stock") or "100000")
    megatons = math.min(megatons, market)
    if megatons <= 0 then return 0, "No food available in the market." end
    if cost > e.credits then return 0, "Not enough credits." end
    e.credits = e.credits - cost
    e.food    = e.food + megatons
    db.galaxy_set("food_market_stock", market - megatons)
    return megatons, nil
end

function M.food_sell(e, megatons)
    megatons  = math.min(megatons, e.food)
    if megatons <= 0 then return 0 end
    local price   = M.food_price()
    local revenue = math.floor(megatons * price * 0.9)  -- 10% market fee
    e.food    = e.food - megatons
    e.credits = e.credits + revenue
    local market = tonumber(db.galaxy_get("food_market_stock") or "100000")
    db.galaxy_set("food_market_stock", market + megatons)
    return revenue
end

-- suppress unused warning for BASE_PROD (used as documentation)
local _ = BASE_PROD

return M
