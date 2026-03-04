# Phase 4c: SRE Support Systems — Implementation Plan

> **For Claude:** Use superpowers:executing-plans to implement task-by-task.

**Goal:** Implement bank, lottery, pirates, and inter-empire messaging.

**Architecture:** Four self-contained modules. All SQL through `lib/db.lua` patterns (direct `door.db.*` calls are fine here since these are leaf modules with no shared queries). Daily reset logic for lottery/pirates lives here and is called from `main.lua`.

**Prerequisite:** Phase 3 complete.

---

## Task 1: `lib/bank.lua`

**Files:**
- Create: `doors/sre/lib/bank.lua`

```lua
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

-- ── Player actions ────────────────────────────────────────────────────────────

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
    e.credits       = e.credits - BOND_COST
    b.bonds         = b.bonds + 1
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
```

### Commit
```bash
git add doors/sre/lib/bank.lua
git commit -m "feat(sre): add lib/bank.lua savings/loans/bonds"
```

---

## Task 2: `lib/lottery.lua`

**Files:**
- Create: `doors/sre/lib/lottery.lua`

```lua
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

-- Buy a standard ticket. Returns nil on success or error string.
function M.buy_ticket(e, ticket_type)
    ticket_type = ticket_type or "standard"
    local cost    = ticket_type == "super" and SUPER_COST or TICKET_COST
    local to_pot  = ticket_type == "super" and (SUPER_COST * 0.9) or TICKET_TO_JACKPOT

    if e.credits < cost then
        return string.format("A %s ticket costs %d credits.", ticket_type, cost)
    end

    local game_day = tonumber(db.galaxy_get("game_day") or "1")
    ensure_jackpot(game_day)

    e.credits = e.credits - cost

    -- Add entries (super = 10 tickets)
    local entries = ticket_type == "super" and SUPER_ENTRIES or 1
    for _ = 1, entries do
        door.db.execute([[
            INSERT INTO door_sre_lottery_tickets (empire_id, game_day, ticket_type)
            VALUES (?, ?, ?)
        ]], { e.id, game_day, ticket_type })
    end

    -- Grow jackpot (house keeps the rest)
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
    if rows[1] and rows[1].winner_empire_id then return nil end  -- already done

    -- Get all tickets for this day
    local tickets = door.db.query(
        "SELECT id, empire_id FROM door_sre_lottery_tickets WHERE game_day = ?",
        { game_day })
    if #tickets == 0 then return nil end

    -- Pick a winner
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
```

### Commit
```bash
git add doors/sre/lib/lottery.lua
git commit -m "feat(sre): add lib/lottery.lua jackpot mechanics and daily draw"
```

---

## Task 3: `lib/pirates.lua`

**Files:**
- Create: `doors/sre/lib/pirates.lua`

```lua
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
    if (rows[1] and rows[1].cnt or 0) >= 4 then return end

    for i = 1, 4 do
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
        local loot_c = math.floor(target.credits * math.random() * 0.05)
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

-- Spy on all pirates. Free. Returns list of { name, planets, net_worth }.
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

-- Raid a pirate team. Costs a battle turn.
-- empire: mutable empire row. pirate_id: target pirate.
-- Returns result table or nil + error string.
function M.raid(e, pirate_id)
    local rows = door.db.query(
        "SELECT * FROM door_sre_pirates WHERE id=? AND is_active=1", { pirate_id })
    local p = rows[1]
    if not p then return nil, "Pirate team not found." end

    -- Simple combat: send soldiers + credits, win if soldiers > pirates
    local sent_soldiers = math.floor(e.soldiers * 0.20)
    local sent_credits  = math.floor(e.credits  * 0.05)  -- bribe/logistics cost
    e.soldiers = math.max(0, e.soldiers - sent_soldiers)
    e.credits  = math.max(0, e.credits  - sent_credits)

    local won = sent_soldiers > p.soldiers * 0.6

    if won then
        local recovered_c = p.loot_credits
        local recovered_s = p.loot_soldiers
        e.credits  = e.credits  + recovered_c
        e.soldiers = e.soldiers + recovered_s

        -- Weaken pirate
        door.db.execute([[
            UPDATE door_sre_pirates
            SET soldiers=MAX(0,soldiers-?), loot_credits=0, loot_soldiers=0
            WHERE id=?
        ]], { sent_soldiers, pirate_id })

        return { won=true, recovered_credits=recovered_c, recovered_soldiers=recovered_s }, nil
    else
        -- Pirate wins: lose some of your sent forces
        return { won=false, lost_soldiers=sent_soldiers }, nil
    end
end

return M
```

### Commit
```bash
git add doors/sre/lib/pirates.lua
git commit -m "feat(sre): add lib/pirates.lua NPC raid and counter-raid"
```

---

## Task 4: `lib/messages.lua`

**Files:**
- Create: `doors/sre/lib/messages.lua`

```lua
-- lib/messages.lua — inter-empire messaging (private and public broadcasts).
local db = require("lib.db")
local M  = {}

-- Send a message. recipient_ids: list of empire IDs, or empty for public.
-- is_public: if true, all active empires receive it.
-- anonymous: sender recorded as NULL.
function M.send(sender_empire, recipient_ids, subject, body, is_public, anonymous)
    local from_id = anonymous and nil or sender_empire.id

    door.db.execute([[
        INSERT INTO door_sre_messages (from_empire, subject, body, is_public)
        VALUES (?, ?, ?, ?)
    ]], { from_id, subject or "(no subject)", body, is_public and 1 or 0 })

    -- Get the message id
    local rows = door.db.query(
        "SELECT MAX(id) as id FROM door_sre_messages", {})
    local msg_id = rows[1] and rows[1].id
    if not msg_id then return end

    -- Determine recipients
    local targets = {}
    if is_public then
        local all = door.db.query(
            "SELECT id FROM door_sre_empires WHERE is_active=1", {})
        for _, r in ipairs(all) do table.insert(targets, r.id) end
    else
        targets = recipient_ids
    end

    for _, eid in ipairs(targets) do
        door.db.execute([[
            INSERT INTO door_sre_message_recipients (message_id, empire_id)
            VALUES (?, ?)
        ]], { msg_id, eid })
    end
end

-- Get unread messages for an empire. Returns list ordered by sent_at ASC.
function M.inbox(empire_id)
    return door.db.query([[
        SELECT m.id, m.subject, m.body, m.sent_at, m.is_public,
               e.letter as from_letter, e.name as from_name
        FROM door_sre_messages m
        JOIN door_sre_message_recipients r ON r.message_id = m.id
        LEFT JOIN door_sre_empires e ON e.id = m.from_empire
        WHERE r.empire_id = ? AND r.read_at IS NULL
        ORDER BY m.sent_at ASC
    ]], { empire_id })
end

-- Mark a message as read for this empire.
function M.mark_read(empire_id, message_id)
    door.db.execute([[
        UPDATE door_sre_message_recipients
        SET read_at = ?
        WHERE empire_id = ? AND message_id = ?
    ]], { door.time(), empire_id, message_id })
end

-- Mark all messages read for this empire.
function M.mark_all_read(empire_id)
    door.db.execute([[
        UPDATE door_sre_message_recipients
        SET read_at = ?
        WHERE empire_id = ? AND read_at IS NULL
    ]], { door.time(), empire_id })
end

-- Show messages paged through ui.pager.
function M.show_inbox(empire_id, ui)
    local msgs = M.inbox(empire_id)
    if #msgs == 0 then
        ui.WL(ui.CYN.."  No new messages."..ui.RST)
        ui.pause()
        return
    end
    for _, msg in ipairs(msgs) do
        local from = msg.from_letter
            and string.format("Empire %s (%s)", msg.from_letter, msg.from_name)
            or  "Anonymous"
        local header = string.format(
            "From: %s\nSubject: %s\n%s\n",
            from, msg.subject, string.rep("-", 40))
        ui.pager(header .. msg.body)
        M.mark_read(empire_id, msg.id)
    end
end

-- Compose UI: prompt for recipients and body, then send.
-- Returns nil on success or error string.
function M.compose(sender, ui)
    ui.header("Send Message")
    ui.WL("  Enter empire letters to send to (e.g. ABC), or * for all, or blank to cancel.")
    local dest = ui.INPUT("  To: ")
    if not dest or dest == "" then return nil end

    local is_public = dest == "*"
    local recipient_ids = {}
    if not is_public then
        for c in dest:upper():gmatch("%u") do
            local target = door.db.query(
                "SELECT id FROM door_sre_empires WHERE letter=? AND is_active=1", { c })
            if target[1] then
                table.insert(recipient_ids, target[1].id)
            end
        end
        if #recipient_ids == 0 then return "No valid recipients found." end
    end

    local subject = ui.INPUT("  Subject: ")
    if not subject or subject == "" then subject = "(no subject)" end

    ui.WL("  Message body (enter /S on a blank line to send):")
    local lines = {}
    while true do
        local line = ui.INPUT("  ")
        if not line then break end
        if line:upper() == "/S" then break end
        table.insert(lines, line)
        if #lines >= 99 then break end
    end
    local body = table.concat(lines, "\n")

    local anon_ans = ui.INPUT("  Send anonymously? [y/N] ")
    local anonymous = anon_ans and anon_ans:upper() == "Y"

    M.send(sender, recipient_ids, subject, body, is_public, anonymous)
    ui.WL(ui.GRN.."  Message sent."..ui.RST)
    ui.pause()
    return nil
end

return M
```

### Commit
```bash
git add doors/sre/lib/messages.lua
git commit -m "feat(sre): add lib/messages.lua private and public inter-empire messaging"
```

---

## Task 5: Final check

```bash
cargo build --all
cargo clippy --all -- -D warnings
```

Launch door in BBS — verify no `require` errors loading the four new modules.

All green → Phase 4c complete.
