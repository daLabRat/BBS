-- lib/diplomacy.lua — treaty proposals, acceptance, breaking, and ally queries.
local db = require("lib.db")
local M  = {}

-- Treaty type display names and descriptions
M.TYPES = {
    { id="neutrality",         label="Neutrality Treaty",       desc="No attacks; enables trading." },
    { id="free_trade",         label="Free Trade Agreement",    desc="No attacks; tariff income." },
    { id="minor_alliance",     label="Minor Alliance",          desc="Auto-sends 10% soldiers/5% cruisers in defence." },
    { id="total_defense",      label="Total Defense",           desc="Sends 20% soldiers/10% cruisers in defence." },
    { id="armed_defense",      label="Armed Defense Pact",      desc="Sends 30% soldiers/5% cruisers in defence." },
    { id="cruiser_protection", label="Cruiser Protection Plan", desc="Sends 5% soldiers/20% cruisers in defence." },
    { id="custom",             label="Custom Treaty",           desc="Set your own defence percentages." },
}

-- Propose a treaty. Stores it as accepted=0 (pending).
-- Returns nil on success or an error string.
function M.propose(proposer, target_id, treaty_type, duration, s_pct, c_pct)
    if proposer.id == target_id then return "Cannot propose a treaty with yourself." end
    if proposer.protection_turns > 0 then return "Cannot form treaties while under protection." end
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
    db.event_post(other_id, "treaty_accepted",
        string.format("Empire %s has accepted your %s.",
            (db.empire_by_id(empire_id) or {}).letter or "?",
            t.type:gsub("_"," ")))
    return nil
end

-- Break a treaty.
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
    -- Expired but still marked active: attacking cancels it
    db.treaty_delete(attacker.id, target_id)
    db.event_post(target_id, "treaty_broken",
        string.format("Empire %s broke your %s by attacking you!",
            attacker.letter, t.type:gsub("_"," ")))
    return nil
end

-- Void protection (requires adequate size/defence). Returns error or nil.
function M.void_protection(e)
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
