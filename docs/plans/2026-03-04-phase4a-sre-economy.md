# Phase 4a: SRE Economy, Population & Research — Implementation Plan

> **For Claude:** Use superpowers:executing-plans to implement task-by-task.

**Goal:** Implement the per-turn income engine: planet production, food market, maintenance costs, population dynamics, and research breakthroughs.

**Architecture:** Three modules — `lib/economy.lua` (planet income + pricing + maintenance + food), `lib/population.lua` (births/deaths/immigration), `lib/research.lua` (breakthroughs + effect management). All SQL goes through `lib/db.lua`.

**Prerequisite:** Phase 3 complete.

---

## Task 1: `lib/economy.lua`

**Files:**
- Create: `doors/sre/lib/economy.lua`

```lua
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

-- Gaussian approximation using Box-Muller (seeded from door.time + empire id)
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
-- Returns: { credits, food_produced, research_pts, supply_units, pollution_delta }
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

return M
```

### Commit
```bash
git add doors/sre/lib/economy.lua
git commit -m "feat(sre): add lib/economy.lua planet income, food market, pricing"
```

---

## Task 2: `lib/population.lua`

**Files:**
- Create: `doors/sre/lib/population.lua`

```lua
-- lib/population.lua — birth, death, immigration, emigration each turn.
local M = {}

-- Violence emigration multipliers (0=peaceful .. 7=under coup)
local VIOLENCE_EMIG = { 0.0, 0.005, 0.01, 0.02, 0.04, 0.08, 0.15, 0.30 }
local VIOLENCE_MORT = { 0.0, 0.001, 0.002, 0.004, 0.008, 0.015, 0.025, 0.05 }

-- Returns net population change and a breakdown table for the status screen.
function M.tick(e, planets)
    math.randomseed(door.time() + e.id * 99991)

    local urban_count = planets.urban and planets.urban.count or 0
    local edu_count   = planets.education and planets.education.count or 0
    local iv          = math.max(0, math.min(7, e.internal_violence))

    -- Births: proportional to population and urban planets (exponential driver)
    local birth_rate  = 0.005 + urban_count * 0.0005
    local births      = math.floor(e.population * birth_rate * (0.8 + math.random() * 0.4))

    -- Immigration: linear with education planets, suppressed by violence
    local peace_factor = math.max(0, 1.0 - iv * 0.15)
    local immigration  = math.floor(edu_count * 500 * peace_factor * (0.7 + math.random() * 0.6))

    -- Deaths: overcrowding + violence
    local overcrowd   = math.max(0, (e.population - 5000000) / 50000000)
    local mort_rate   = 0.003 + overcrowd + (VIOLENCE_MORT[iv + 1] or 0)
    local deaths      = math.floor(e.population * mort_rate * (0.8 + math.random() * 0.4))

    -- Emigration: driven by violence and high taxes
    local tax_push    = math.max(0, (e.tax_rate - 40) * 0.001)
    local emig_rate   = (VIOLENCE_EMIG[iv + 1] or 0) + tax_push
    local emigration  = math.floor(e.population * emig_rate * (0.8 + math.random() * 0.4))

    local net = births + immigration - deaths - emigration
    e.population = math.max(1000, e.population + net)

    return {
        births      = births,
        immigration = immigration,
        deaths      = deaths,
        emigration  = emigration,
        net         = net,
    }
end

-- Draft: convert draft_rate % of population to soldiers.
function M.apply_draft(e)
    if e.draft_rate <= 0 then return 0 end
    local drafted = math.floor(e.population * e.draft_rate / 100)
    e.soldiers   = e.soldiers + drafted
    e.population = math.max(1000, e.population - drafted)
    return drafted
end

-- Starvation: if food runs out, soldiers and population suffer.
-- Returns description of what happened (or nil if fine).
function M.check_starvation(e, food_needed)
    if e.food >= food_needed then
        e.food = e.food - food_needed
        return nil
    end
    local shortfall = food_needed - e.food
    e.food = 0
    -- Soldiers desert when unfed
    local desertions = math.floor(e.soldiers * 0.1 * (shortfall / food_needed))
    e.soldiers = math.max(0, e.soldiers - desertions)
    -- Population drops
    local starved = math.floor(e.population * 0.02)
    e.population = math.max(1000, e.population - starved)
    -- Violence rises
    e.internal_violence = math.min(7, e.internal_violence + 1)
    return string.format(
        "FAMINE: %d soldiers deserted, %d people starved.", desertions, starved)
end

return M
```

### Commit
```bash
git add doors/sre/lib/population.lua
git commit -m "feat(sre): add lib/population.lua birth/death/immigration/draft/starvation"
```

---

## Task 3: `lib/research.lua`

**Files:**
- Create: `doors/sre/lib/research.lua`

```lua
-- lib/research.lua — research breakthroughs and active effect management.
local db = require("lib.db")
local M  = {}

local EFFECTS = {
    -- { type, description, permanent_chance, magnitude_range, target_planet }
    { "food_yield",      "Protein synthesis boosts food planet yield",    0.2, {5,20},  "food"        },
    { "tourism_attract", "New tourist attraction opens",                   0.1, {10,30}, "tourism"     },
    { "ore_efficiency",  "Mining efficiency improves",                     0.3, {5,15},  "ore"         },
    { "pollution_scrub", "Atmospheric scrubber technology discovered",     0.4, {10,25}, "anti_pollution"},
    { "urban_commerce",  "Urban commerce network upgraded",                0.2, {5,15},  "urban"       },
    { "supply_output",   "Supply planet automation improved",              0.3, {5,20},  "supply"      },
    { "research_boost",  "Scientific breakthrough accelerates research",   0.1, {10,40}, "research"    },
    { "petroleum_drill", "Deep-core drilling increases petroleum output",  0.2, {5,15},  "petroleum"   },
}

-- Roll for a breakthrough given research points this turn.
-- Returns effect table or nil.
function M.roll_breakthrough(research_pts, empire_id)
    local chance = math.min(0.8, research_pts / 1000)
    if math.random() > chance then return nil end

    local eff_def    = EFFECTS[math.random(#EFFECTS)]
    local is_perm    = math.random() < eff_def[3]
    local magnitude  = math.random(eff_def[4][1], eff_def[4][2])
    local game_day   = tonumber(db.galaxy_get("game_day") or "1")
    local expires    = is_perm and nil or (game_day + math.random(5, 15))

    door.db.execute([[
        INSERT INTO door_sre_research_effects
            (empire_id, effect_type, magnitude, is_permanent, expires_turn)
        VALUES (?,?,?,?,?)
    ]], { empire_id, eff_def[1], magnitude, is_perm and 1 or 0, expires })

    return {
        type        = eff_def[1],
        description = eff_def[2],
        magnitude   = magnitude,
        permanent   = is_perm,
        expires     = expires,
        target      = eff_def[5],
    }
end

-- Apply active research effects to planet production_long values.
-- Called at turn start after loading planets.
function M.apply_effects(empire_id, planets)
    local game_day = tonumber(db.galaxy_get("game_day") or "1")
    local rows = door.db.query([[
        SELECT * FROM door_sre_research_effects
        WHERE empire_id = ?
          AND (is_permanent = 1 OR expires_turn > ?)
    ]], { empire_id, game_day })

    for _, eff in ipairs(rows) do
        local pt = nil
        -- Map effect_type to planet_type
        if eff.effect_type == "food_yield"      then pt = "food"
        elseif eff.effect_type == "tourism_attract" then pt = "tourism"
        elseif eff.effect_type == "ore_efficiency"  then pt = "ore"
        elseif eff.effect_type == "pollution_scrub" then pt = "anti_pollution"
        elseif eff.effect_type == "urban_commerce"  then pt = "urban"
        elseif eff.effect_type == "supply_output"   then pt = "supply"
        elseif eff.effect_type == "research_boost"  then pt = "research"
        elseif eff.effect_type == "petroleum_drill" then pt = "petroleum"
        end
        if pt and planets[pt] and planets[pt].count > 0 then
            local boost = math.floor(planets[pt].production_long * eff.magnitude / 100)
            planets[pt].production_short = planets[pt].production_short + boost
        end
    end
end

-- Expire old temporary effects. Call once per daily reset.
function M.expire_effects(game_day)
    door.db.execute([[
        DELETE FROM door_sre_research_effects
        WHERE is_permanent = 0 AND expires_turn <= ?
    ]], { game_day })
end

return M
```

### Commit
```bash
git add doors/sre/lib/research.lua
git commit -m "feat(sre): add lib/research.lua breakthrough rolls and effect management"
```

---

## Task 4: Smoke test all three modules from `main.lua`

Update the stub `main.lua` to exercise the new modules:

```lua
local ui       = require("lib.ui")
local db       = require("lib.db")
local empire   = require("lib.empire")
local economy  = require("lib.economy")
local pop      = require("lib.population")
local research = require("lib.research")

-- Initialise galaxy defaults if first run
if not db.galaxy_get("game_day") then
    db.galaxy_set("game_day",            "1")
    db.galaxy_set("mode",                "non_inflationary")
    db.galaxy_set("food_market_stock",   "500000")
    db.galaxy_set("food_price",          "10")
    db.galaxy_set("pollution_level",     "0")
end

ui.CLS()
ui.WL(ui.BYEL.."  Solar Realms Elite — engine test"..ui.RST)
ui.WL("")

local e, planets = empire.load()
if not e then
    ui.WL(ui.CYN.."  No empire yet. (Registration coming in Phase 4e)"..ui.RST)
else
    local galaxy  = db.galaxy_get_all()
    local income  = economy.planet_income(e, planets, galaxy)
    local pop_chg = pop.tick(e, planets)
    local breakthru = research.roll_breakthrough(income.research_pts, e.id)

    ui.WL(ui.GRN..string.format("  Empire: %s  Credits: %s  Food: %s",
        e.name, ui.commas(e.credits), ui.commas(e.food))..ui.RST)
    ui.WL(ui.YEL..string.format("  Turn income: %s cr  Food prod: %d mt  Research: %d pts",
        ui.commas(income.credits), income.food_prod, income.research_pts)..ui.RST)
    ui.WL(ui.CYN..string.format("  Pop change: +%d births +%d immigr -%d deaths -%d emig  (net %d)",
        pop_chg.births, pop_chg.immigration, pop_chg.deaths, pop_chg.emigration, pop_chg.net)..ui.RST)
    if breakthru then
        ui.WL(ui.BYEL.."  BREAKTHROUGH: "..breakthru.description..ui.RST)
    end
end

ui.WL("")
ui.pause()
door.exit()
```

### Verify:
- No Lua errors
- Numbers look reasonable for a starting empire
- Breakthrough fires occasionally

### Commit
```bash
git add doors/sre/main.lua
git commit -m "feat(sre): update stub main.lua to smoke-test economy/population/research"
```

---

## Task 5: Final check

```bash
cargo build --all
cargo clippy --all -- -D warnings
```

All green → Phase 4a complete.
