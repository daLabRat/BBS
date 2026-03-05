-- lib/lottery.lua — daily lottery with negative-feedback jackpot mechanics.
local db = require("lib.db")
local M  = {}

local TICKET_COST       = 5000
local TICKET_TO_JACKPOT = 4500   -- house keeps 500 per ticket
local SUPER_COST        = 25000
local SUPER_ENTRIES     = 10
local SEED_JACKPOT      = 500000

-- Ensure today's jackpot record exists.
local function ensure_jackpot(game_day)
    door.db.execute([[
        INSERT OR IGNORE INTO door_sre_lottery_results (game_day, jackpot)
        VALUES (?, ?)
    ]], { game_day, SEED_JACKPOT })
end

function M.current_jackpot()
    local game_day = tonumber(db.galaxy_get("game_day") or "1")
    ensure_jackpot(game_day)
    local rows = door.db.query(
        "SELECT jackpot FROM door_sre_lottery_results WHERE game_day = ?", { game_day })
    return (rows[1] and rows[1].jackpot) or SEED_JACKPOT
end

-- Buy a ticket. Returns nil on success or error string.
function M.buy_ticket(e, ticket_type)
    ticket_type = ticket_type or "standard"
    local cost   = ticket_type == "super" and SUPER_COST or TICKET_COST
    local to_pot = ticket_type == "super" and math.floor(SUPER_COST * 0.9) or TICKET_TO_JACKPOT

    if e.credits < cost then
        return string.format("A %s ticket costs %d credits.", ticket_type, cost)
    end

    local game_day = tonumber(db.galaxy_get("game_day") or "1")
    ensure_jackpot(game_day)

    e.credits = e.credits - cost

    local entries = ticket_type == "super" and SUPER_ENTRIES or 1
    for _ = 1, entries do
        door.db.execute([[
            INSERT INTO door_sre_lottery_tickets (empire_id, game_day, ticket_type)
            VALUES (?, ?, ?)
        ]], { e.id, game_day, ticket_type })
    end

    -- Grow jackpot
    door.db.execute([[
        UPDATE door_sre_lottery_results SET jackpot = jackpot + ? WHERE game_day = ?
    ]], { math.floor(to_pot * entries), game_day })

    return nil
end

-- Draw the lottery for game_day. Returns winner empire or nil if no tickets.
-- Called once per daily reset. Posts events to all players.
function M.draw(game_day)
    ensure_jackpot(game_day)

    -- Already drawn?
    local rows = door.db.query(
        "SELECT winner_empire_id FROM door_sre_lottery_results WHERE game_day = ?",
        { game_day })
    if rows[1] and rows[1].winner_empire_id then return nil end

    local tickets = door.db.query(
        "SELECT id, empire_id FROM door_sre_lottery_tickets WHERE game_day = ?",
        { game_day })
    if #tickets == 0 then return nil end

    local winning = tickets[math.random(#tickets)]
    local winner  = door.db.query(
        "SELECT * FROM door_sre_empires WHERE id = ?", { winning.empire_id })
    winner = winner[1]
    if not winner then return nil end

    local jackpot = M.current_jackpot()

    -- Pay winner
    door.db.execute(
        "UPDATE door_sre_empires SET credits = credits + ? WHERE id = ?",
        { jackpot, winner.id })

    -- Record result
    door.db.execute([[
        UPDATE door_sre_lottery_results
        SET winner_empire_id = ?, drawn_at = ?
        WHERE game_day = ?
    ]], { winner.id, door.time(), game_day })

    -- Notify all active empires
    local all = door.db.query(
        "SELECT id FROM door_sre_empires WHERE is_active = 1", {})
    for _, emp in ipairs(all) do
        db.event_post(emp.id, "lottery_result",
            string.format("LOTTERY: Empire %s won the jackpot of %d credits!",
                winner.letter, jackpot))
    end

    return winner
end

return M
