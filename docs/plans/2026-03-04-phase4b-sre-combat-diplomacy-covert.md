# Phase 4b: SRE Combat, Diplomacy & Covert Ops — Implementation Plan

> **For Claude:** Use superpowers:executing-plans to implement task-by-task.

**Goal:** Implement the three player-interaction systems: 3-front battle engine, 7-type treaty system, and 9 covert operations.

**Architecture:** `lib/combat.lua` handles all attack types and loot. `lib/diplomacy.lua` manages treaty proposals, acceptance, and ally defence calls. `lib/covert.lua` handles all 9 ops with daily limits and queued delayed effects.

**Prerequisite:** Phase 3 complete (db.lua, empire.lua, events).

---

## Task 1: `lib/combat.lua`

**Files:**
- Create: `doors/sre/lib/combat.lua`

```lua
-- lib/combat.lua — conventional attack, guerilla ambush, and special attacks.
local db  = require("lib.db")
local ui  = require("lib.ui")
local dip = require("lib.diplomacy")
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
    def.soldiers          = math.max(0, def.soldiers          - math.floor(attack_to("soldiers")))
    def.defense_stations  = math.max(0, def.defense_stations  - math.floor(attack_to("defense_stations")))
    def.heavy_cruisers    = math.max(0, def.heavy_cruisers    - math.floor(attack_to("heavy_cruisers")))

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
    atk.soldiers          = math.max(0, atk.soldiers          - math.floor(def_attack_to("soldiers")))
    atk.fighters          = math.max(0, atk.fighters          - math.floor(def_attack_to("fighters")))
    atk.heavy_cruisers    = math.max(0, atk.heavy_cruisers    - math.floor(def_attack_to("heavy_cruisers")))

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
        if t.type == "minor_alliance"    then s_pct, c_pct = 10, 5
        elseif t.type == "total_defense"   then s_pct, c_pct = 20, 10
        elseif t.type == "armed_defense"   then s_pct, c_pct = 30, 5
        elseif t.type == "cruiser_protection" then s_pct, c_pct = 5, 20
        elseif t.type == "custom"          then s_pct, c_pct = t.soldier_pct, t.cruiser_pct
        end

        local sent_s = math.floor(ally.soldiers      * s_pct / 100)
        local sent_c = math.floor(ally.heavy_cruisers * c_pct / 100)

        if sent_s > 0 or sent_c > 0 then
            -- Transfer forces to defender temporarily (simplification: add to defender pool)
            defender.soldiers      = defender.soldiers      + sent_s
            defender.heavy_cruisers = defender.heavy_cruisers + sent_c
            -- Deduct from ally
            ally.soldiers          = math.max(0, ally.soldiers - sent_s)
            ally.heavy_cruisers    = math.max(0, ally.heavy_cruisers - sent_c)
            db.empire_update(ally)
            db.event_post(ally_id, "alliance_defence",
                string.format("You sent %d soldiers and %d cruisers to defend %s against attack.",
                    sent_s, sent_c, defender.name))
        end
        ::skip::
    end
end

-- ── Conventional Attack ───────────────────────────────────────────────────────
-- attacker/defender: empire rows (mutable); atk_planets: planet table for attacker.
-- Returns result table with won/lost/loot fields.
function M.conventional(attacker, defender, planets_def)
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
        soldiers          = defender.soldiers,
        defense_stations  = defender.defense_stations,
        heavy_cruisers    = defender.heavy_cruisers,
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
            -- Transfer random planet types from defender to attacker
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
    local def_size   = defender.soldiers + defender.heavy_cruisers
    local dmg_soldiers = math.floor(def_size * 0.05 * (0.5 + math.random()))
    local dmg_spread   = math.floor(defender.defense_stations * 0.03 * math.random())

    defender.soldiers         = math.max(0, defender.soldiers - dmg_soldiers)
    defender.defense_stations = math.max(0, defender.defense_stations - dmg_spread)

    -- Attacker loses a small random number of soldiers (caught in crossfire)
    local atk_loss = math.floor(attacker.soldiers * 0.02 * math.random())
    attacker.soldiers = math.max(0, attacker.soldiers - atk_loss)

    -- Violence rises in defender
    defender.internal_violence = math.min(7, defender.internal_violence + 1)

    local identified = math.random() < 0.10

    return {
        dmg_soldiers  = dmg_soldiers,
        dmg_stations  = dmg_spread,
        atk_loss      = atk_loss,
        identified    = identified,
    }
end

-- ── Psionic Bombs ─────────────────────────────────────────────────────────────
-- Mass confusion: spikes internal violence, demoralises troops (temp atk penalty).
function M.psionic(attacker, defender)
    defender.internal_violence = math.min(7, defender.internal_violence + 3)
    -- Demoralize: lose 20% of soldiers temporarily (flee in confusion)
    local fled = math.floor(defender.soldiers * 0.20)
    defender.soldiers = math.max(0, defender.soldiers - fled)
    return { violence_spike = 3, soldiers_fled = fled }
end

-- ── Nuclear / Chemical (placeholder — GC penalty accumulator) ────────────────
function M.nuclear(attacker, defender)
    -- Destroy 40% of random planet type + all food
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
```

### Commit
```bash
git add doors/sre/lib/combat.lua
git commit -m "feat(sre): add lib/combat.lua 3-front battle engine and attack types"
```

---

## Task 2: `lib/diplomacy.lua`

**Files:**
- Create: `doors/sre/lib/diplomacy.lua`

```lua
-- lib/diplomacy.lua — treaty proposals, acceptance, breaking, and ally queries.
local db = require("lib.db")
local M  = {}

-- Treaty type display names and descriptions
M.TYPES = {
    { id="neutrality",         label="Neutrality Treaty",      desc="No attacks; enables trading." },
    { id="free_trade",         label="Free Trade Agreement",   desc="No attacks; tariff income." },
    { id="minor_alliance",     label="Minor Alliance",         desc="Auto-sends 10% soldiers/5% cruisers in defence." },
    { id="total_defense",      label="Total Defense",          desc="Sends 20% soldiers/10% cruisers in defence." },
    { id="armed_defense",      label="Armed Defense Pact",     desc="Sends 30% soldiers/5% cruisers in defence." },
    { id="cruiser_protection", label="Cruiser Protection Plan",desc="Sends 5% soldiers/20% cruisers in defence." },
    { id="custom",             label="Custom Treaty",          desc="Set your own defence percentages." },
}

-- Propose a treaty. Stores it as accepted=0 (pending).
-- Returns nil on success or an error string.
function M.propose(proposer, target_id, treaty_type, duration, s_pct, c_pct)
    -- Can't propose to self
    if proposer.id == target_id then return "Cannot propose a treaty with yourself." end
    -- Can't propose during protection
    if proposer.protection_turns > 0 then return "Cannot form treaties while under protection." end
    -- Validate type
    local valid = false
    for _, t in ipairs(M.TYPES) do
        if t.id == treaty_type then valid = true; break end
    end
    if not valid then return "Unknown treaty type." end

    db.treaty_upsert(proposer.id, target_id, treaty_type,
        s_pct or 0, c_pct or 0, duration or 0, proposer.id)

    db.event_post(target_id, "treaty_proposal",
        string.format("Empire %s has proposed a %s with you. Review in Diplomacy.",
            proposer.letter, treaty_type:gsub("_", " ")))
    return nil
end

-- Accept a pending treaty.
function M.accept(empire_id, other_id, duration)
    local t = db.treaty_between(empire_id, other_id)
    if not t then return "No pending treaty found." end
    if t.accepted == 1 then return "Treaty already active." end
    db.treaty_accept(empire_id, other_id, duration or t.duration)

    local other = db.empire_by_id(other_id)
    db.event_post(other_id, "treaty_accepted",
        string.format("Empire %s has accepted your %s.",
            (db.empire_by_id(empire_id) or {}).letter or "?",
            t.type:gsub("_"," ")))
    return nil
end

-- Break a treaty. Immediate if expired/indefinite; deferred if binding.
function M.break_treaty(empire_id, other_id)
    local t = db.treaty_between(empire_id, other_id)
    if not t then return "No treaty to break." end
    db.treaty_delete(empire_id, other_id)
    db.event_post(other_id, "treaty_broken",
        string.format("Empire %s has broken your %s!",
            (db.empire_by_id(empire_id) or {}).letter or "?",
            t.type:gsub("_"," ")))
    return nil
end

-- Check whether an attack is allowed under current treaties.
-- Returns nil if allowed, or a string reason if blocked.
function M.attack_allowed(attacker, target_id)
    if attacker.protection_turns > 0 then
        return "You are under protection. Attacking will void your protection."
    end
    local t = db.treaty_between(attacker.id, target_id)
    if not t or t.accepted ~= 1 then return nil end  -- no active treaty
    -- Binding treaties block attacks
    if t.expires_at and t.expires_at > door.time() then
        return string.format("You have a binding %s with that empire.", t.type:gsub("_"," "))
    end
    -- Expired but still active: attacking cancels it
    db.treaty_delete(attacker.id, target_id)
    db.event_post(target_id, "treaty_broken",
        string.format("Empire %s broke your %s by attacking you!",
            attacker.letter, t.type:gsub("_"," ")))
    return nil
end

-- Void protection (requires adequate size/defence). Returns error or nil.
function M.void_protection(e, planets)
    local total_planets = db.planet_total(e.id)
    if total_planets < 10 then
        return "You need at least 10 planets to void protection."
    end
    if e.soldiers + e.heavy_cruisers < 500 then
        return "You need at least 500 soldiers + cruisers to void protection."
    end
    e.protection_turns = 0
    return nil
end

-- Get pending treaty proposals for an empire.
function M.pending_proposals(empire_id)
    return door.db.query([[
        SELECT t.*, e.name as proposer_name, e.letter as proposer_letter
        FROM door_sre_treaties t
        JOIN door_sre_empires e ON e.id = t.proposed_by
        WHERE (t.empire_a = ? OR t.empire_b = ?)
          AND t.accepted = 0
          AND t.proposed_by != ?
    ]], { empire_id, empire_id, empire_id })
end

-- Tariff income from Free Trade agreements (called each turn).
function M.tariff_income(e)
    local income = 0
    local treaties = db.treaties_for(e.id)
    for _, t in ipairs(treaties) do
        if t.type == "free_trade" then
            income = income + math.floor(e.credits * 0.002)
        end
    end
    return income
end

return M
```

### Commit
```bash
git add doors/sre/lib/diplomacy.lua
git commit -m "feat(sre): add lib/diplomacy.lua treaty proposals/acceptance/breaking"
```

---

## Task 3: `lib/covert.lua`

**Files:**
- Create: `doors/sre/lib/covert.lua`

```lua
-- lib/covert.lua — 9 covert operation types with daily limits and delayed effects.
local db  = require("lib.db")
local M   = {}

-- Op definitions: id, label, requires_out_of_protection, has_delay
M.OPS = {
    { id="spy",          label="Send Spy",            protected=false, delay=false },
    { id="insurgent",    label="Insurgent Aid",       protected=true,  delay=false },
    { id="setup",        label="Set Up",              protected=true,  delay=false },
    { id="dissension",   label="Support Dissension",  protected=true,  delay=true  },
    { id="demoralize",   label="Demoralize Troops",   protected=true,  delay=true  },
    { id="bombing",      label="Bombing Operations",  protected=true,  delay=true  },
    { id="rel_spy",      label="Relations Spying",    protected=false, delay=false },
    { id="hostage",      label="Take Hostages",       protected=true,  delay=true  },
    { id="bribe",        label="Bribe Personnel",     protected=false, delay=false },
}

-- Can the empire perform this op?
-- Returns nil on ok, or error string.
local function check_allowed(empire, target, op)
    if empire.covert_agents <= 0 then
        return "You have no covert agents."
    end
    if op.protected and empire.protection_turns > 0 then
        return "This operation requires you to be out of protection."
    end
    if op.id ~= "spy" and op.id ~= "rel_spy" and op.id ~= "bribe" then
        if db.covert_used_today(empire.id, target.id, op.id) then
            return "You have already performed this operation on that empire today."
        end
    end
    return nil
end

-- ── Op implementations ────────────────────────────────────────────────────────

local function op_spy(empire, target)
    -- Success guaranteed if bribe is active; otherwise 80% chance
    local bribed = db.covert_used_today(empire.id, target.id, "bribe")
    local success = bribed or math.random() < 0.80
    if not success then return nil, "Your spy was captured and executed." end
    return {
        name           = target.name,
        letter         = target.letter,
        credits        = target.credits,
        food           = target.food,
        population     = target.population,
        soldiers       = target.soldiers,
        fighters       = target.fighters,
        defense_stations = target.defense_stations,
        heavy_cruisers = target.heavy_cruisers,
        light_cruisers = target.light_cruisers,
        covert_agents  = target.covert_agents,
        net_worth      = target.net_worth,
        internal_violence = target.internal_violence,
        planet_count   = db.planet_total(target.id),
    }, nil
end

local function op_insurgent(empire, target)
    target.internal_violence = math.min(7, target.internal_violence + 1)
    db.empire_update(target)
    db.event_post(target.id, "insurgent_aid",
        string.format("Rebel troublemakers have infiltrated your empire! (Violence +1)"))
    db.covert_record(empire.id, target.id, "insurgent")
    return { effect = "violence +1" }, nil
end

local function op_setup(empire, target, victim_id)
    -- Frame 'victim' empire for attacking 'target'
    local victim = db.empire_by_id(victim_id)
    if not victim then return nil, "Target empire not found." end
    db.event_post(target.id, "setup",
        string.format("Intelligence reports: Empire %s attacked you! (Source may be unreliable.)",
            victim.letter))
    db.covert_record(empire.id, target.id, "setup")
    return { framed = victim.letter }, nil
end

local function op_dissension(empire, target)
    -- Queued: executes on target's next login
    db.event_post(target.id, "covert_dissension",
        string.format("COVERT: Soldiers are deserting their posts. Lose 5%% soldiers."))
    db.covert_record(empire.id, target.id, "dissension")
    return { queued = true }, nil
end

local function op_demoralize(empire, target)
    db.event_post(target.id, "covert_demoralize",
        "COVERT: Enemy distractions have demoralized your troops. Army effectiveness -10% this turn.")
    db.covert_record(empire.id, target.id, "demoralize")
    return { queued = true }, nil
end

local function op_bombing(empire, target)
    db.event_post(target.id, "covert_bombing",
        "COVERT: Saboteurs booby-trapped your food supply! Lose 20% food.")
    db.covert_record(empire.id, target.id, "bombing")
    return { queued = true }, nil
end

local function op_rel_spy(empire, target)
    local treaties = db.treaties_for(target.id)
    local result = {}
    for _, t in ipairs(treaties) do
        local ally_id = (t.empire_a == target.id) and t.empire_b or t.empire_a
        local ally = db.empire_by_id(ally_id)
        table.insert(result, {
            partner = ally and ally.letter or "?",
            type    = t.type,
        })
    end
    return result, nil
end

local function op_hostage(empire, target)
    local ransom = math.floor(target.credits * 0.10)
    db.event_post(target.id, "covert_hostage",
        string.format("COVERT: A hostage has been taken! You must pay %d credits.", ransom))
    db.covert_record(empire.id, target.id, "hostage")
    -- Actual credit transfer happens when target processes the event
    return { ransom = ransom, queued = true }, nil
end

local function op_bribe(empire, target)
    local cost = math.floor(target.covert_agents * 500)
    if empire.credits < cost then
        return nil, string.format("Bribing costs %d credits. You only have %d.", cost, empire.credits)
    end
    empire.credits = empire.credits - cost
    db.covert_record(empire.id, target.id, "bribe")
    return { cost = cost, guaranteed_spy = true }, nil
end

-- ── Process delayed events on login ─────────────────────────────────────────
-- Call this at session start after loading events. Mutates empire in place.
function M.process_delayed(e, events)
    for _, ev in ipairs(events) do
        if ev.event_type == "covert_dissension" then
            local loss = math.floor(e.soldiers * 0.05)
            e.soldiers = math.max(0, e.soldiers - loss)
        elseif ev.event_type == "covert_demoralize" then
            e.internal_violence = math.min(7, e.internal_violence + 1)
        elseif ev.event_type == "covert_bombing" then
            local loss = math.floor(e.food * 0.20)
            e.food = math.max(0, e.food - loss)
        elseif ev.event_type == "covert_hostage" then
            -- Extract ransom from description
            local ransom = tonumber(ev.description:match("pay (%d+)")) or 0
            e.credits = math.max(0, e.credits - ransom)
        end
    end
end

-- ── Public dispatch ───────────────────────────────────────────────────────────
-- Perform an operation. Returns result table or nil + error string.
function M.perform(op_id, empire, target, extra)
    local op = nil
    for _, o in ipairs(M.OPS) do
        if o.id == op_id then op = o; break end
    end
    if not op then return nil, "Unknown operation." end

    local err = check_allowed(empire, target, op)
    if err then return nil, err end

    if op_id == "spy"        then return op_spy(empire, target)
    elseif op_id == "insurgent"  then return op_insurgent(empire, target)
    elseif op_id == "setup"      then return op_setup(empire, target, extra)
    elseif op_id == "dissension" then return op_dissension(empire, target)
    elseif op_id == "demoralize" then return op_demoralize(empire, target)
    elseif op_id == "bombing"    then return op_bombing(empire, target)
    elseif op_id == "rel_spy"    then return op_rel_spy(empire, target)
    elseif op_id == "hostage"    then return op_hostage(empire, target)
    elseif op_id == "bribe"      then return op_bribe(empire, target)
    end
    return nil, "Operation not implemented."
end

return M
```

### Commit
```bash
git add doors/sre/lib/covert.lua
git commit -m "feat(sre): add lib/covert.lua 9 covert operations with daily limits"
```

---

## Task 4: Final check

```bash
cargo build --all
cargo clippy --all -- -D warnings
```

No Lua syntax is checked by Cargo — load the door in the BBS and verify no `require` errors on startup.

All green → Phase 4b complete.
