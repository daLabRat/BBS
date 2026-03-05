-- lib/pirates.lua — NPC pirate teams that raid empires and can be counter-raided.
local db = require("lib.db")
local M  = {}

local PIRATE_NAMES = {
    "The Void Raiders", "Crimson Fleet", "Dark Matter Syndicate",
    "Neutron Buccaneers", "The Asteroid Gang", "Solar Pirates",
    "Black Hole Corsairs", "Comet Chasers",
}

-- Seed initial pirate teams at game start. Safe to call multiple times.
function M.seed()
    local rows = door.db.query(
        "SELECT COUNT(*) as cnt FROM door_sre_pirates WHERE is_active=1", {})
    if ((rows[1] and rows[1].cnt) or 0) >= 4 then return end

    for _ = 1, 4 do
        local name = PIRATE_NAMES[math.random(#PIRATE_NAMES)]
        door.db.execute([[
            INSERT INTO door_sre_pirates (name, planets, soldiers, credits, food)
            VALUES (?, ?, ?, ?, ?)
        ]], {
            name,
            math.random(2, 6),
            math.random(500, 3000),
            math.random(5000, 30000),
            math.random(20, 100),
        })
    end
end

-- Pirates raid a random active empire each daily reset.
function M.raid_empires()
    local pirates = door.db.query(
        "SELECT * FROM door_sre_pirates WHERE is_active=1", {})
    if #pirates == 0 then return end

    local empires = door.db.query(
        "SELECT id, name, letter, credits, food, soldiers FROM door_sre_empires WHERE is_active=1", {})
    if #empires == 0 then return end

    for _, p in ipairs(pirates) do
        local target = empires[math.random(#empires)]
        local loot_c = math.floor(target.credits  * math.random() * 0.05)
        local loot_s = math.floor(target.soldiers * math.random() * 0.03)
        local loot_f = math.floor(target.food     * math.random() * 0.05)

        -- Take from empire
        door.db.execute([[
            UPDATE door_sre_empires
            SET credits  = MAX(0, credits  - ?),
                soldiers = MAX(0, soldiers - ?),
                food     = MAX(0, food     - ?)
            WHERE id = ?
        ]], { loot_c, loot_s, loot_f, target.id })

        -- Add to pirate loot
        door.db.execute([[
            UPDATE door_sre_pirates
            SET loot_credits  = loot_credits  + ?,
                loot_soldiers = loot_soldiers + ?,
                credits       = credits       + ?
            WHERE id = ?
        ]], { loot_c, loot_s, math.floor(loot_c * 0.5), p.id })

        -- Notify victim
        db.event_post(target.id, "pirate_raid",
            string.format('"%s" raided your empire! Lost %d credits, %d soldiers, %d food.',
                p.name, loot_c, loot_s, loot_f))
    end
end

-- Spy on all pirates. Returns list of { name, planets, net_worth }.
function M.spy()
    local rows = door.db.query(
        "SELECT name, planets, credits, loot_credits FROM door_sre_pirates WHERE is_active=1", {})
    local out = {}
    for _, p in ipairs(rows) do
        table.insert(out, {
            name      = p.name,
            planets   = p.planets,
            net_worth = p.credits + p.loot_credits,
        })
    end
    return out
end

-- Raid a pirate team. Returns result table or nil + error string.
function M.raid(e, pirate_id)
    local rows = door.db.query(
        "SELECT * FROM door_sre_pirates WHERE id=? AND is_active=1", { pirate_id })
    local p = rows[1]
    if not p then return nil, "Pirate team not found." end

    local sent_soldiers = math.floor(e.soldiers * 0.20)
    local sent_credits  = math.floor(e.credits  * 0.05)  -- logistics cost
    e.soldiers = math.max(0, e.soldiers - sent_soldiers)
    e.credits  = math.max(0, e.credits  - sent_credits)

    local won = sent_soldiers > p.soldiers * 0.6

    if won then
        local recovered_c = p.loot_credits
        local recovered_s = p.loot_soldiers
        e.credits  = e.credits  + recovered_c
        e.soldiers = e.soldiers + recovered_s

        door.db.execute([[
            UPDATE door_sre_pirates
            SET soldiers=MAX(0,soldiers-?), loot_credits=0, loot_soldiers=0
            WHERE id=?
        ]], { sent_soldiers, pirate_id })

        return { won=true, recovered_credits=recovered_c, recovered_soldiers=recovered_s }, nil
    else
        return { won=false, lost_soldiers=sent_soldiers }, nil
    end
end

return M
