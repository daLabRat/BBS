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
