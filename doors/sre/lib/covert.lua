-- lib/covert.lua — 9 covert operation types with daily limits and delayed effects.
local db = require("lib.db")
local M  = {}

-- Op definitions: id, label, requires_out_of_protection, has_delay
M.OPS = {
    { id="spy",        label="Send Spy",            protected=false, delay=false },
    { id="insurgent",  label="Insurgent Aid",       protected=true,  delay=false },
    { id="setup",      label="Set Up",              protected=true,  delay=false },
    { id="dissension", label="Support Dissension",  protected=true,  delay=true  },
    { id="demoralize", label="Demoralize Troops",   protected=true,  delay=true  },
    { id="bombing",    label="Bombing Operations",  protected=true,  delay=true  },
    { id="rel_spy",    label="Relations Spying",    protected=false, delay=false },
    { id="hostage",    label="Take Hostages",       protected=true,  delay=true  },
    { id="bribe",      label="Bribe Personnel",     protected=false, delay=false },
}

-- Can the empire perform this op? Returns nil on ok, or error string.
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
    local bribed  = db.covert_used_today(empire.id, target.id, "bribe")
    local success = bribed or math.random() < 0.80
    if not success then return nil, "Your spy was captured and executed." end
    return {
        name              = target.name,
        letter            = target.letter,
        credits           = target.credits,
        food              = target.food,
        population        = target.population,
        soldiers          = target.soldiers,
        fighters          = target.fighters,
        defense_stations  = target.defense_stations,
        heavy_cruisers    = target.heavy_cruisers,
        light_cruisers    = target.light_cruisers,
        covert_agents     = target.covert_agents,
        net_worth         = target.net_worth,
        internal_violence = target.internal_violence,
        planet_count      = db.planet_total(target.id),
    }, nil
end

local function op_insurgent(empire, target)
    target.internal_violence = math.min(7, target.internal_violence + 1)
    db.empire_update(target)
    db.event_post(target.id, "insurgent_aid",
        "Rebel troublemakers have infiltrated your empire! (Violence +1)")
    db.covert_record(empire.id, target.id, "insurgent")
    return { effect = "violence +1" }, nil
end

local function op_setup(empire, target, victim_id)
    local victim = db.empire_by_id(victim_id)
    if not victim then return nil, "Target empire not found." end
    db.event_post(target.id, "setup",
        string.format("Intelligence reports: Empire %s attacked you! (Source may be unreliable.)",
            victim.letter))
    db.covert_record(empire.id, target.id, "setup")
    return { framed = victim.letter }, nil
end

local function op_dissension(empire, target)
    db.event_post(target.id, "covert_dissension",
        "COVERT: Soldiers are deserting their posts. Lose 5% soldiers.")
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

-- ── Process delayed events on login ──────────────────────────────────────────
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
            local ransom = tonumber(ev.description:match("pay (%d+)")) or 0
            e.credits = math.max(0, e.credits - ransom)
        end
    end
end

-- ── Public dispatch ────────────────────────────────────────────────────────────
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
