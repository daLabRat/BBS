-- lib/research.lua — research breakthroughs and active effect management.
local db = require("lib.db")
local M  = {}

local EFFECTS = {
    -- { type, description, permanent_chance, magnitude_range, target_planet }
    { "food_yield",      "Protein synthesis boosts food planet yield",    0.2, {5,20},  "food"         },
    { "tourism_attract", "New tourist attraction opens",                   0.1, {10,30}, "tourism"      },
    { "ore_efficiency",  "Mining efficiency improves",                     0.3, {5,15},  "ore"          },
    { "pollution_scrub", "Atmospheric scrubber technology discovered",     0.4, {10,25}, "anti_pollution"},
    { "urban_commerce",  "Urban commerce network upgraded",                0.2, {5,15},  "urban"        },
    { "supply_output",   "Supply planet automation improved",              0.3, {5,20},  "supply"       },
    { "research_boost",  "Scientific breakthrough accelerates research",   0.1, {10,40}, "research"     },
    { "petroleum_drill", "Deep-core drilling increases petroleum output",  0.2, {5,15},  "petroleum"    },
}

-- Roll for a breakthrough given research points this turn.
-- Returns effect table or nil.
function M.roll_breakthrough(research_pts, empire_id)
    local chance = math.min(0.8, research_pts / 1000)
    if math.random() > chance then return nil end

    local eff_def   = EFFECTS[math.random(#EFFECTS)]
    local is_perm   = math.random() < eff_def[3]
    local magnitude = math.random(eff_def[4][1], eff_def[4][2])
    local game_day  = tonumber(db.galaxy_get("game_day") or "1")
    local expires   = is_perm and nil or (game_day + math.random(5, 15))

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

-- Apply active research effects to planet production_short values.
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
