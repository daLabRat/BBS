-- lib/combat.lua — conventional attack, guerilla ambush, and special attacks.
local db  = require("lib.db")
local M   = {}

-- Cross-effectiveness matrix: attacker[type][target] = multiplier
local ATK = {
    soldiers       = { soldiers=3, defense_stations=1, heavy_cruisers=1 },
    fighters       = { soldiers=1, defense_stations=4, heavy_cruisers=1 },
    heavy_cruisers = { soldiers=2, defense_stations=2, heavy_cruisers=10 },
}
-- Defence strength multipliers per type
local DEF = { soldiers=10, defense_stations=25, heavy_cruisers=15 }

-- One round of combat. Modifies atk/def tables in place.
-- Returns true if combat should continue.
local function combat_round(atk, def)
    -- Calculate total attack power toward each defender group
    local function attack_to(defender_type)
        local dmg = 0
        for atype, acnt in pairs(atk) do
            if ATK[atype] then
                dmg = dmg + acnt * (ATK[atype][defender_type] or 0)
            end
        end
        return math.max(0, dmg - (def[defender_type] or 0) * (DEF[defender_type] or 1) * 0.01)
    end

    -- Attacker damages defender
    def.soldiers         = math.max(0, def.soldiers         - math.floor(attack_to("soldiers")))
    def.defense_stations = math.max(0, def.defense_stations - math.floor(attack_to("defense_stations")))
    def.heavy_cruisers   = math.max(0, def.heavy_cruisers   - math.floor(attack_to("heavy_cruisers")))

    -- Defender damages attacker (same formula reversed)
    local function def_attack_to(at)
        local dmg = 0
        for dtype, dcnt in pairs(def) do
            if ATK[dtype] then
                dmg = dmg + dcnt * (ATK[dtype][at] or 0)
            end
        end
        return math.max(0, dmg - (atk[at] or 0) * 0.005)
    end
    atk.soldiers       = math.max(0, atk.soldiers       - math.floor(def_attack_to("soldiers")))
    atk.fighters       = math.max(0, atk.fighters       - math.floor(def_attack_to("fighters")))
    atk.heavy_cruisers = math.max(0, atk.heavy_cruisers - math.floor(def_attack_to("heavy_cruisers")))

    -- Combat ends when one side is zeroed or after max 20 rounds (caller tracks)
    local atk_total = (atk.soldiers or 0) + (atk.fighters or 0) + (atk.heavy_cruisers or 0)
    local def_total = (def.soldiers or 0) + (def.defense_stations or 0) + (def.heavy_cruisers or 0)
    return atk_total > 0 and def_total > 0
end

-- Notify allies per treaty terms. Called before a conventional attack resolves.
local function call_allies(defender, attacker_id)
    local treaties = db.treaties_for(defender.id)
    for _, t in ipairs(treaties) do
        local ally_id = (t.empire_a == defender.id) and t.empire_b or t.empire_a
        if ally_id == attacker_id then goto skip end

        local ally = db.empire_by_id(ally_id)
        if not ally or ally.is_active == 0 then goto skip end

        local s_pct, c_pct = 0, 0
        if t.type == "minor_alliance"      then s_pct, c_pct = 10, 5
        elseif t.type == "total_defense"   then s_pct, c_pct = 20, 10
        elseif t.type == "armed_defense"   then s_pct, c_pct = 30, 5
        elseif t.type == "cruiser_protection" then s_pct, c_pct = 5, 20
        elseif t.type == "custom"          then s_pct, c_pct = t.soldier_pct, t.cruiser_pct
        end

        local sent_s = math.floor(ally.soldiers       * s_pct / 100)
        local sent_c = math.floor(ally.heavy_cruisers * c_pct / 100)

        if sent_s > 0 or sent_c > 0 then
            -- Transfer forces to defender temporarily (add to defender pool)
            defender.soldiers       = defender.soldiers       + sent_s
            defender.heavy_cruisers = defender.heavy_cruisers + sent_c
            -- Deduct from ally
            ally.soldiers           = math.max(0, ally.soldiers - sent_s)
            ally.heavy_cruisers     = math.max(0, ally.heavy_cruisers - sent_c)
            db.empire_update(ally)
            db.event_post(ally_id, "alliance_defence",
                string.format("You sent %d soldiers and %d cruisers to defend %s against attack.",
                    sent_s, sent_c, defender.name))
        end
        ::skip::
    end
end

-- ── Conventional Attack ───────────────────────────────────────────────────────
-- attacker/defender: empire rows (mutable).
-- Returns result table with won/loot fields.
function M.conventional(attacker, defender)
    -- Generals needed: 1 per 50 soldiers (cap attack soldiers if short)
    local max_soldiers = attacker.generals * 50
    local eff_soldiers = math.min(attacker.soldiers, max_soldiers)

    -- Carriers needed: 1 per 100 fighters
    local max_fighters = attacker.carriers * 100
    local eff_fighters = math.min(attacker.fighters, max_fighters)

    -- Notify allies (modifies defender in-place before battle)
    call_allies(defender, attacker.id)

    -- Command ship bonus: +5% per 100 strength to heavy cruiser attacks
    local cs_bonus = 1.0 + (attacker.command_ship / 100) * 0.05

    local atk = {
        soldiers       = eff_soldiers,
        fighters       = eff_fighters,
        heavy_cruisers = math.floor(attacker.heavy_cruisers * cs_bonus),
    }
    local def = {
        soldiers         = defender.soldiers,
        defense_stations = defender.defense_stations,
        heavy_cruisers   = defender.heavy_cruisers,
    }

    -- Light cruisers: 5 free rounds for attacker before defender responds
    local lc_dmg = 0
    for _ = 1, 5 do
        lc_dmg = lc_dmg + math.floor(attacker.light_cruisers * 1.2)
    end
    def.heavy_cruisers = math.max(0, def.heavy_cruisers - lc_dmg)

    -- Battle rounds (max 20)
    local rounds = 0
    repeat
        rounds = rounds + 1
    until not combat_round(atk, def) or rounds >= 20

    -- Determine outcome
    local atk_remaining = atk.soldiers + atk.fighters + atk.heavy_cruisers
    local def_remaining = def.soldiers + def.defense_stations + def.heavy_cruisers
    local won = atk_remaining > def_remaining

    -- Apply losses back to attacker
    attacker.soldiers       = attacker.soldiers - (eff_soldiers - atk.soldiers)
    attacker.fighters       = attacker.fighters - (eff_fighters - atk.fighters)
    attacker.heavy_cruisers = math.max(0, attacker.heavy_cruisers -
        (math.floor(attacker.heavy_cruisers * cs_bonus) - atk.heavy_cruisers))

    -- Apply losses to defender
    defender.soldiers         = def.soldiers
    defender.defense_stations = def.defense_stations
    defender.heavy_cruisers   = def.heavy_cruisers

    local result = { won = won, rounds = rounds, loot_credits = 0, planets_taken = 0 }

    if won then
        -- Loot: take up to 30% of defender credits
        local loot = math.floor(defender.credits * 0.3)
        attacker.credits = attacker.credits + loot
        defender.credits = defender.credits - loot
        result.loot_credits = loot

        -- Capture planets proportional to margin of victory
        local margin = math.max(0, atk_remaining - def_remaining)
        local total_def_planets = db.planet_total(defender.id)
        local take = math.max(0, math.min(
            math.floor(total_def_planets * margin / (atk_remaining + 1) * 0.1),
            math.floor(total_def_planets * 0.25)  -- cap at 25% per attack
        ))
        if take > 0 then
            local def_planets = db.planets_for(defender.id)
            local atk_planets = db.planets_for(attacker.id)
            local remaining   = take
            for pt, p in pairs(def_planets) do
                if remaining <= 0 then break end
                if p.count > 0 then
                    local n = math.min(p.count, remaining)
                    p.count = p.count - n
                    atk_planets[pt].count = (atk_planets[pt].count or 0) + n
                    db.planet_upsert(defender.id, pt, p.count,
                        p.production_long, p.production_short, p.supply_config)
                    db.planet_upsert(attacker.id, pt, atk_planets[pt].count,
                        atk_planets[pt].production_long, atk_planets[pt].production_short,
                        atk_planets[pt].supply_config)
                    remaining = remaining - n
                end
            end
            result.planets_taken = take - remaining
        end

        -- Raise defender internal violence
        defender.internal_violence = math.min(7, defender.internal_violence + 2)
    end

    return result
end

-- ── Guerilla Ambush ───────────────────────────────────────────────────────────
-- Damage proportional to DEFENDER army size. No allies. No planet capture.
-- 10% chance attacker is identified.
function M.guerilla(attacker, defender)
    local def_size     = defender.soldiers + defender.heavy_cruisers
    local dmg_soldiers = math.floor(def_size * 0.05 * (0.5 + math.random()))
    local dmg_spread   = math.floor(defender.defense_stations * 0.03 * math.random())

    defender.soldiers         = math.max(0, defender.soldiers         - dmg_soldiers)
    defender.defense_stations = math.max(0, defender.defense_stations - dmg_spread)

    -- Attacker loses a small random number of soldiers (caught in crossfire)
    local atk_loss = math.floor(attacker.soldiers * 0.02 * math.random())
    attacker.soldiers = math.max(0, attacker.soldiers - atk_loss)

    -- Violence rises in defender
    defender.internal_violence = math.min(7, defender.internal_violence + 1)

    local identified = math.random() < 0.10

    return {
        dmg_soldiers = dmg_soldiers,
        dmg_stations = dmg_spread,
        atk_loss     = atk_loss,
        identified   = identified,
    }
end

-- ── Psionic Bombs ─────────────────────────────────────────────────────────────
-- Mass confusion: spikes internal violence, demoralises troops.
function M.psionic(attacker, defender)
    defender.internal_violence = math.min(7, defender.internal_violence + 3)
    local fled = math.floor(defender.soldiers * 0.20)
    defender.soldiers = math.max(0, defender.soldiers - fled)
    return { violence_spike = 3, soldiers_fled = fled }
end

-- ── Nuclear / Chemical ────────────────────────────────────────────────────────
function M.nuclear(attacker, defender)
    local def_planets = db.planets_for(defender.id)
    local types = {}
    for pt, p in pairs(def_planets) do
        if p.count > 0 then table.insert(types, pt) end
    end
    local destroyed = 0
    if #types > 0 then
        local pt = types[math.random(#types)]
        destroyed = math.floor(def_planets[pt].count * 0.40)
        def_planets[pt].count = def_planets[pt].count - destroyed
        db.planet_upsert(defender.id, pt, def_planets[pt].count,
            def_planets[pt].production_long, def_planets[pt].production_short,
            def_planets[pt].supply_config)
    end
    defender.food = 0
    -- GC goodwill penalty
    local goodwill = tonumber(db.galaxy_get("gc_goodwill") or "100")
    db.galaxy_set("gc_goodwill", math.max(0, goodwill - 15))
    return { planets_destroyed = destroyed }
end

return M
