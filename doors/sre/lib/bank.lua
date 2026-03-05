-- lib/bank.lua — savings, loans, and Galactic Coordinator bonds.
local db = require("lib.db")
local M  = {}

local BOND_COST   = 8500
local BOND_RETURN = 10000
local BOND_DAYS   = { 10, 20 }   -- maturity range in game days

-- Load bank record for empire, creating it if absent.
function M.load(empire_id)
    local rows = door.db.query(
        "SELECT * FROM door_sre_bank WHERE empire_id = ?", { empire_id })
    if rows[1] then return rows[1] end
    door.db.execute(
        "INSERT INTO door_sre_bank (empire_id) VALUES (?)", { empire_id })
    return { empire_id=empire_id, savings=0, savings_rate=5,
             loan=0, loan_rate=10, bonds=0, bond_maturity_day=nil }
end

function M.save(b)
    door.db.execute([[
        INSERT INTO door_sre_bank
            (empire_id, savings, savings_rate, loan, loan_rate, bonds, bond_maturity_day)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(empire_id) DO UPDATE SET
            savings=excluded.savings, savings_rate=excluded.savings_rate,
            loan=excluded.loan, loan_rate=excluded.loan_rate,
            bonds=excluded.bonds, bond_maturity_day=excluded.bond_maturity_day
    ]], { b.empire_id, b.savings, b.savings_rate, b.loan,
          b.loan_rate, b.bonds, b.bond_maturity_day })
end

-- Accrue interest on savings and loans. Called once per daily reset.
function M.accrue_interest(b)
    if b.savings > 0 then
        b.savings = math.floor(b.savings * (1 + b.savings_rate / 100))
    end
    if b.loan > 0 then
        b.loan = math.floor(b.loan * (1 + b.loan_rate / 100))
    end
end

-- Loan interest rate scales with number of active borrowers.
function M.current_loan_rate()
    local rows = door.db.query(
        "SELECT COUNT(*) as cnt FROM door_sre_bank WHERE loan > 0", {})
    local borrowers = (rows[1] and rows[1].cnt) or 0
    local empires   = door.db.query(
        "SELECT COUNT(*) as cnt FROM door_sre_empires WHERE is_active=1", {})
    local total = (empires[1] and empires[1].cnt) or 1
    local ratio = borrowers / math.max(1, total)
    -- Base 8%, rises to 20% as more empires borrow
    return math.floor(8 + ratio * 12)
end

-- ── Player actions ─────────────────────────────────────────────────────────────

function M.deposit(e, b, amount)
    amount = math.min(amount, e.credits)
    if amount <= 0 then return "Nothing to deposit." end
    e.credits = e.credits - amount
    b.savings = b.savings + amount
    return nil
end

function M.withdraw(e, b, amount)
    amount = math.min(amount, b.savings)
    if amount <= 0 then return "No savings to withdraw." end
    b.savings = b.savings - amount
    e.credits = e.credits + amount
    return nil
end

function M.take_loan(e, b, amount)
    if b.loan > 0 then return "Repay your current loan before taking another." end
    if amount <= 0 then return "Invalid loan amount." end
    b.loan      = amount
    b.loan_rate = M.current_loan_rate()
    e.credits   = e.credits + amount
    return nil
end

function M.repay_loan(e, b, amount)
    amount = math.min(amount, math.min(b.loan, e.credits))
    if amount <= 0 then return "Nothing to repay." end
    e.credits = e.credits - amount
    b.loan    = math.max(0, b.loan - amount)
    return nil
end

-- Bonds: cost 8500, return 10000 after 10-20 game days. Hidden from attackers.
function M.buy_bond(e, b)
    if e.credits < BOND_COST then
        return string.format("Bonds cost %d credits.", BOND_COST)
    end
    local game_day = tonumber(db.galaxy_get("game_day") or "1")
    e.credits = e.credits - BOND_COST
    b.bonds   = b.bonds + 1
    -- All bonds for a player mature together (simplification matching original)
    local maturity  = game_day + math.random(BOND_DAYS[1], BOND_DAYS[2])
    b.bond_maturity_day = math.max(b.bond_maturity_day or 0, maturity)
    return nil
end

-- Called at daily reset: pay out matured bonds.
function M.check_bond_maturity(e, b, game_day)
    if b.bonds <= 0 then return 0 end
    if not b.bond_maturity_day or game_day < b.bond_maturity_day then return 0 end
    local payout = b.bonds * BOND_RETURN
    e.credits = e.credits + payout
    b.bonds   = 0
    b.bond_maturity_day = nil
    return payout
end

return M
