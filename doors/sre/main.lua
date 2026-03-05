-- doors/sre/main.lua — Solar Realms Elite session entry point.
local ui       = require("lib.ui")
local db       = require("lib.db")
local emp      = require("lib.empire")
local econ     = require("lib.economy")
local pop      = require("lib.population")
local research = require("lib.research")
local combat   = require("lib.combat")
local dip      = require("lib.diplomacy")
local covert   = require("lib.covert")
local bank     = require("lib.bank")
local lottery  = require("lib.lottery")
local pirates  = require("lib.pirates")
local msg      = require("lib.messages")

math.randomseed(door.time() + door.user.id * 9973)

-- ── Galaxy init (first-ever run) ──────────────────────────────────────────────
local function galaxy_init()
    if db.galaxy_get("game_day") then return end
    db.galaxy_set("game_day",          "1")
    db.galaxy_set("mode",              "non_inflationary")
    db.galaxy_set("food_market_stock", "500000")
    db.galaxy_set("pollution_level",   "0")
    db.galaxy_set("gc_goodwill",       "100")
    pirates.seed()
    -- Seed lottery jackpot row for day 1
    door.db.execute([[
        INSERT OR IGNORE INTO door_sre_lottery_results (game_day, jackpot)
        VALUES (1, 500000)
    ]], {})
end

-- ── Daily reset (fires once per real day, guarded by unique insert) ───────────
local function daily_reset()
    local today    = os.date("%Y-%m-%d")
    local last_day = db.galaxy_get("last_reset_date") or ""
    if last_day == today then return end

    -- Guard: only one session wins the race
    local ok = pcall(function()
        door.db.execute([[
            INSERT INTO door_sre_galaxy (key, value) VALUES ('last_reset_date', ?)
            ON CONFLICT(key) DO UPDATE SET value=?
            WHERE value != ?
        ]], { today, today, today })
    end)
    -- Re-check after potential race
    if db.galaxy_get("last_reset_date") == last_day then return end

    local game_day = tonumber(db.galaxy_get("game_day") or "1") + 1
    db.galaxy_set("game_day", game_day)

    -- Refill turns for all empires
    door.db.execute([[
        UPDATE door_sre_empires SET turns_remaining=5, turns_date='' WHERE is_active=1
    ]], {})

    -- Accrue bank interest + check bond maturity for each empire
    local all = door.db.query("SELECT id FROM door_sre_empires WHERE is_active=1", {})
    for _, row in ipairs(all) do
        local b = bank.load(row.id)
        bank.accrue_interest(b)
        local e2 = db.empire_by_id(row.id)
        if e2 then
            local payout = bank.check_bond_maturity(e2, b, game_day)
            if payout > 0 then
                db.event_post(row.id, "bond_maturity",
                    string.format("Your GC Bonds matured! Received %s credits.",
                        ui.commas(payout)))
                door.db.execute(
                    "UPDATE door_sre_empires SET credits=credits+? WHERE id=?",
                    { payout, row.id })
            end
            db.empire_update(e2)
        end
        bank.save(b)
    end

    -- Expire research effects
    research.expire_effects(game_day)

    -- Pirate raids
    pirates.raid_empires()

    -- Draw lottery
    lottery.draw(game_day - 1)  -- draw for yesterday

    -- Advance petroleum pollution
    local rows = door.db.query([[
        SELECT SUM(CASE WHEN planet_type='petroleum'      THEN count ELSE 0 END) as pet,
               SUM(CASE WHEN planet_type='anti_pollution' THEN count ELSE 0 END) as anti
        FROM door_sre_planets
    ]], {})
    local r    = rows[1]
    local poll = tonumber(db.galaxy_get("pollution_level") or "0")
    poll = math.max(0, poll + (r and r.pet or 0) - (r and r.anti or 0) * 3)
    db.galaxy_set("pollution_level", poll)
end

-- ── Title screen ──────────────────────────────────────────────────────────────
local function title_screen(e)
    ui.CLS()
    ui.WL(ui.BRED.."  ███████╗ ██████╗ ██╗      █████╗ ██████╗ "..ui.RST)
    ui.WL(ui.BRED.."  ██╔════╝██╔═══██╗██║     ██╔══██╗██╔══██╗"..ui.RST)
    ui.WL(ui.BRED.."  ███████╗██║   ██║██║     ███████║██████╔╝"..ui.RST)
    ui.WL(ui.BRED.."  ╚════██║██║   ██║██║     ██╔══██║██╔══██╗"..ui.RST)
    ui.WL(ui.BRED.."  ███████║╚██████╔╝███████╗██║  ██║██║  ██║"..ui.RST)
    ui.WL(ui.BRED.."  ╚══════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝"..ui.RST)
    ui.WL(ui.BYEL.."         ██████╗ ███████╗ █████╗ ██╗      ███████╗███████╗"..ui.RST)
    ui.WL(ui.BYEL.."         ██╔══██╗██╔════╝██╔══██╗██║      ██╔════╝██╔════╝"..ui.RST)
    ui.WL(ui.BYEL.."         ██████╔╝█████╗  ███████║██║      ███████╗███████╗"..ui.RST)
    ui.WL(ui.BYEL.."         ██╔══██╗██╔══╝  ██╔══██║██║      ╚════██║╚════██║"..ui.RST)
    ui.WL(ui.BYEL.."         ██║  ██║███████╗██║  ██║███████╗ ███████║███████║"..ui.RST)
    ui.WL(ui.BYEL.."         ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝"..ui.RST)
    ui.WL("")
    ui.WL(ui.BCYN.."              ███████╗██╗     ██╗████████╗███████╗"..ui.RST)
    ui.WL(ui.BCYN.."              ██╔════╝██║     ██║╚══██╔══╝██╔════╝"..ui.RST)
    ui.WL(ui.BCYN.."              █████╗  ██║     ██║   ██║   █████╗  "..ui.RST)
    ui.WL(ui.BCYN.."              ██╔══╝  ██║     ██║   ██║   ██╔══╝  "..ui.RST)
    ui.WL(ui.BCYN.."              ███████╗███████╗██║   ██║   ███████╗"..ui.RST)
    ui.WL(ui.BCYN.."              ╚══════╝╚══════╝╚═╝   ╚═╝   ╚══════╝"..ui.RST)
    ui.WL("")
    if e then
        ui.WL(ui.GRN..string.format("  Welcome back, %s  (Empire %s)  Net worth: %s cr",
            e.name, e.letter, ui.commas(e.net_worth))..ui.RST)
    else
        ui.WL(ui.CYN.."  A new emperor arrives at the edge of the galaxy..."..ui.RST)
    end
    ui.WL("")
    ui.pause()
end

-- ── Registration ──────────────────────────────────────────────────────────────
local function register_empire()
    ui.CLS()
    ui.header("New Empire Registration")
    ui.WL("  You will rule a solar empire of planets, armies, and starships.")
    ui.WL("  Your goal: become and remain the most powerful empire in the galaxy.")
    ui.WL("")
    local name = ui.INPUT("  Choose your empire name: ")
    if not name or name == "" then return nil end
    local e2, err = emp.register(name)
    if err then
        ui.WL(ui.RED.."  "..err..ui.RST)
        ui.pause()
        return nil
    end
    ui.WL("")
    ui.WL(ui.BGRN..string.format(
        "  Empire '%s' registered as Empire %s!", e2.name, e2.letter)..ui.RST)
    ui.WL(ui.GRN.."  You start with 3 ore planets, 2 food planets, 1 government planet."..ui.RST)
    ui.WL(ui.YEL.."  You have 20 turns of protection. Use them to build your empire."..ui.RST)
    ui.WL("")
    ui.pause()
    return e2
end
-- ── Status screen ─────────────────────────────────────────────────────────────
local VIOLENCE_LABEL = {
    "Peaceful","Mild Insurgencies","Occasional Riots","Violent Demonstrations",
    "Political Conflicts","Internal Violence","Revolutionary Warfare","Under Coup"
}

local function show_status(e, planets)
    local total_planets = db.planet_total(e.id)
    ui.CLS()
    ui.header("Empire Status: "..e.name.." ["..e.letter.."]")
    ui.WL(string.format("  %sCredits:%s %-14s  %sFood:%s %-10s  %sPopulation:%s %s",
        ui.CYN, ui.RST, ui.commas(e.credits),
        ui.CYN, ui.RST, ui.commas(e.food),
        ui.CYN, ui.RST, ui.commas(e.population)))
    ui.WL(string.format("  %sNet worth:%s %-12s  %sTax rate:%s %d%%  %sDraft:%s %d%%",
        ui.CYN, ui.RST, ui.commas(e.net_worth),
        ui.CYN, ui.RST, e.tax_rate,
        ui.CYN, ui.RST, e.draft_rate))
    ui.WL(string.format("  %sTurns left:%s %s%d%s  %sProtection:%s %d turns  %sViolence:%s %s",
        ui.CYN, ui.RST,
        e.turns_remaining > 0 and ui.BGRN or ui.BRED, e.turns_remaining, ui.RST,
        ui.CYN, ui.RST, e.protection_turns,
        ui.CYN, ui.RST, VIOLENCE_LABEL[e.internal_violence + 1] or "Unknown"))
    ui.divider()
    ui.WL(string.format("  %sPlanets:%s %d total",
        ui.CYN, ui.RST, total_planets))
    -- Planet breakdown
    local line = "  "
    for pt, p in pairs(planets) do
        if p.count > 0 then
            line = line .. string.format("%s:%d  ", pt:sub(1,3):upper(), p.count)
        end
    end
    ui.WL(line)
    ui.divider()
    ui.WL(string.format("  %sMilitary:%s  Soldiers:%s  Fighters:%s  Stations:%s  HCruisers:%s",
        ui.CYN, ui.RST,
        ui.commas(e.soldiers), ui.commas(e.fighters),
        ui.commas(e.defense_stations), ui.commas(e.heavy_cruisers)))
    ui.WL(string.format("  LCruisers:%s  Carriers:%s  Generals:%s  Agents:%s  CmdShip:%d%%",
        ui.commas(e.light_cruisers), ui.commas(e.carriers),
        ui.commas(e.generals), ui.commas(e.covert_agents),
        e.command_ship))
    ui.WL("")
end

-- ── Earnings report (step 1 of each turn) ────────────────────────────────────
local function earnings_report(e, planets, galaxy)
    research.apply_effects(e.id, planets)
    local income = econ.planet_income(e, planets, galaxy)

    -- Apply supply output to empire military
    for unit, qty in pairs(income.supply) do
        if e[unit] ~= nil then e[unit] = e[unit] + qty end
    end

    -- Apply income
    e.credits = e.credits + income.credits
    e.food    = e.food    + income.food_prod

    -- Update pollution
    local poll = tonumber(db.galaxy_get("pollution_level") or "0")
    poll = math.max(0, poll + income.poll_delta)
    db.galaxy_set("pollution_level", poll)

    -- Research breakthrough?
    local bt = research.roll_breakthrough(income.research_pts, e.id)

    -- Tariff income from free trade agreements
    local tariff = dip.tariff_income(e)
    e.credits = e.credits + tariff

    -- Command ship auto-growth
    if e.command_ship > 0 then
        e.command_ship = math.min(500, math.floor(e.command_ship * 1.05))
    end

    -- Display
    ui.CLS()
    ui.header("Earnings Report")
    ui.WL(string.format("  Planet income:    %s%s credits%s",
        ui.GRN, ui.commas(income.credits), ui.RST))
    ui.WL(string.format("  Food produced:    %s%d megatons%s",
        ui.GRN, income.food_prod, ui.RST))
    if income.research_pts > 0 then
        ui.WL(string.format("  Research points:  %d", income.research_pts))
    end
    if tariff > 0 then
        ui.WL(string.format("  Trade tariffs:    %s credits", ui.commas(tariff)))
    end
    for unit, qty in pairs(income.supply) do
        if qty > 0 then
            ui.WL(string.format("  Supply planets:   +%s %s", ui.commas(qty), unit))
        end
    end
    if bt then
        ui.WL("")
        ui.WL(ui.BYEL.."  *** RESEARCH BREAKTHROUGH ***"..ui.RST)
        ui.WL(ui.YEL.."  "..bt.description..string.format(
            " (+%d%% %s)", bt.magnitude, bt.permanent and "permanent" or "temporary")..ui.RST)
    end
    ui.WL("")
    ui.pause()
    return income
end
-- ── Maintenance payment (step 3) ─────────────────────────────────────────────
local function pay_maintenance(e, planets, galaxy)
    local total_planets = db.planet_total(e.id)
    local mode = galaxy.mode or "non_inflationary"
    local maint = econ.maintenance_cost(e, total_planets, mode)

    ui.CLS()
    ui.header("Maintenance")
    ui.WL(string.format("  Army maintenance:   %s credits", ui.commas(maint)))
    ui.WL(string.format("  Your credits:       %s", ui.commas(e.credits)))
    ui.WL("")

    if e.credits >= maint then
        ui.W(ui.CYN.."  Pay all at once? [Y/n] "..ui.RST)
        local k = ui.KEY()
        ui.WL("")
        if not k or k:upper() ~= "N" then
            e.credits = e.credits - maint
            ui.WL(ui.GRN.."  Maintenance paid."..ui.RST)
            ui.pause()
            return
        end
    end

    -- Partial payment or forced sale
    if e.credits < maint then
        ui.WL(ui.BRED.."  WARNING: Cannot afford full maintenance!"..ui.RST)
        local affordable = math.min(e.credits, maint)
        e.credits = e.credits - affordable
        -- Sell soldiers at 1/3 price to cover remainder
        local shortfall = maint - affordable
        local sell_soldiers = math.min(e.soldiers, math.ceil(shortfall / (5/3)))
        e.soldiers = e.soldiers - sell_soldiers
        e.credits  = e.credits + math.floor(sell_soldiers * 5 / 3)
        ui.WL(ui.YEL..string.format(
            "  Sold %s soldiers to cover costs.", ui.commas(sell_soldiers))..ui.RST)
    else
        e.credits = e.credits - maint
        ui.WL(ui.GRN.."  Maintenance paid."..ui.RST)
    end
    ui.pause()
end

-- ── Food market (step 4) ──────────────────────────────────────────────────────
local function food_market_screen(e, planets)
    local food_needed = econ.food_consumed(e)
    ui.CLS()
    ui.header("Food Market")
    ui.WL(string.format("  Food needed this turn:  %d megatons", food_needed))
    ui.WL(string.format("  Food in stores:         %d megatons", e.food))
    ui.WL(string.format("  Market price:           %d credits/megaton", econ.food_price()))
    ui.WL("")

    -- Auto-advise
    if e.food < food_needed then
        local deficit = food_needed - e.food
        ui.WL(ui.BYEL..string.format(
            "  ADVISOR: You need %d more megatons to feed everyone!", deficit)..ui.RST)
    end

    ui.WL("  [B]uy  [S]ell  [D]one")
    local k = ui.KEY()
    if not k then return end
    k = k:upper()

    if k == "B" then
        local default = math.max(0, food_needed - e.food)
        local amt_s = ui.INPUT(string.format("  Buy how many megatons? [%d] ", default))
        local amt = tonumber(amt_s) or default
        local got, err = econ.food_buy(e, amt)
        if err then ui.WL(ui.RED.."  "..err..ui.RST)
        else ui.WL(ui.GRN..string.format("  Bought %d megatons.", got)..ui.RST) end
        ui.pause()
    elseif k == "S" then
        local amt_s = ui.INPUT("  Sell how many megatons? ")
        local amt = tonumber(amt_s) or 0
        local rev = econ.food_sell(e, amt)
        ui.WL(ui.GRN..string.format("  Sold for %s credits.", ui.commas(rev))..ui.RST)
        ui.pause()
    end

    -- Feed army and population
    local warn = pop.check_starvation(e, food_needed)
    if warn then
        ui.WL(ui.BRED.."  "..warn..ui.RST)
        ui.pause()
    end
end

-- ── Covert operations screen (step 5) ────────────────────────────────────────
local function covert_screen(e)
    if e.covert_agents <= 0 then return end
    while true do
        ui.CLS()
        ui.header("Covert Operations  (Agents: "..e.covert_agents..")")
        for i, op in ipairs(covert.OPS) do
            local avail = (not op.protected or e.protection_turns == 0)
            ui.WL(string.format("  [%d] %s%s",
                i, op.label, avail and "" or ui.CYN.."  (requires out of protection)"..ui.RST))
        end
        ui.WL("  [0] Done")
        ui.WL("")
        local choice = ui.INPUT("  Choice: ")
        local n = tonumber(choice)
        if not n or n == 0 then return end
        local op_def = covert.OPS[n]
        if not op_def then goto continue end

        -- Pick target empire
        local target_letter = ui.INPUT("  Target empire letter: ")
        if not target_letter or target_letter == "" then goto continue end
        local target = db.empire_by_letter(target_letter:upper())
        if not target then
            ui.WL(ui.RED.."  Empire not found."..ui.RST); ui.pause()
            goto continue
        end

        local extra = nil
        if op_def.id == "setup" then
            local v = ui.INPUT("  Frame which empire letter: ")
            local victim = v and db.empire_by_letter(v:upper())
            extra = victim and victim.id
        end

        local result, err = covert.perform(op_def.id, e, target, extra)
        if err then
            ui.WL(ui.RED.."  "..err..ui.RST)
        else
            ui.WL(ui.GRN.."  Operation performed."..ui.RST)
            if op_def.id == "spy" and result then
                ui.WL(string.format(
                    "  %s [%s]  Credits:%s  Soldiers:%s  Net worth:%s",
                    result.name, result.letter,
                    ui.commas(result.credits), ui.commas(result.soldiers),
                    ui.commas(result.net_worth)))
                ui.WL(string.format(
                    "  Fighters:%s  Stations:%s  HCruisers:%s  Agents:%s  Planets:%d",
                    ui.commas(result.fighters), ui.commas(result.defense_stations),
                    ui.commas(result.heavy_cruisers), ui.commas(result.covert_agents),
                    result.planet_count))
                ui.WL("  Violence: "..(VIOLENCE_LABEL[result.internal_violence+1] or "?"))
            elseif op_def.id == "rel_spy" and type(result) == "table" then
                for _, t in ipairs(result) do
                    ui.WL(string.format("  Empire %s: %s", t.partner, t.type:gsub("_"," ")))
                end
            end
        end
        ui.pause()
        ::continue::
    end
end
-- ── Government spending (step 7) ──────────────────────────────────────────────
local UNIT_LABELS = {
    { key="soldiers",        label="Soldiers",          price_key="soldiers"        },
    { key="fighters",        label="Fighters",          price_key="fighters"        },
    { key="defense_stations",label="Defense Stations",  price_key="defense_stations"},
    { key="heavy_cruisers",  label="Heavy Cruisers",    price_key="heavy_cruisers"  },
    { key="light_cruisers",  label="Light Cruisers",    price_key="light_cruisers"  },
    { key="carriers",        label="Carriers",          price_key="carriers"        },
    { key="generals",        label="Generals",          price_key="generals"        },
    { key="covert_agents",   label="Covert Agents",     price_key="covert_agents"   },
}
local PLANET_LABELS = {
    "food","ore","tourism","supply","government",
    "education","research","urban","petroleum","anti_pollution"
}

local function spending_menu(e, planets, galaxy)
    local mode = galaxy.mode or "non_inflationary"
    while true do
        ui.CLS()
        ui.header("Government Spending")
        ui.WL(string.format("  Credits: %s", ui.commas(e.credits)))
        ui.WL("")
        ui.WL("  ── Military ──────────────────────────────────────────")
        for i, u in ipairs(UNIT_LABELS) do
            local price = econ.buy_price(u.price_key, e.net_worth, mode)
            ui.WL(string.format("  [%d] %-20s  have: %-8s  cost: %s ea",
                i, u.label, ui.commas(e[u.key] or 0), ui.commas(price)))
        end
        ui.WL("")
        ui.WL("  ── Planets ───────────────────────────────────────────")
        for i, pt in ipairs(PLANET_LABELS) do
            local price = econ.buy_price(pt, e.net_worth, mode)
            local cnt   = planets[pt] and planets[pt].count or 0
            ui.WL(string.format("  [%d] %-20s  have: %-8d  cost: %s",
                i + #UNIT_LABELS, pt:gsub("_"," "), cnt, ui.commas(price)))
        end
        ui.WL("")
        ui.WL("  [S]ell unit  [*] Operations menu  [D]one")
        ui.WL("")
        local choice = ui.INPUT("  Buy # (or command): ")

        if not choice or choice:upper() == "D" then
            return false  -- done, no ops menu
        elseif choice == "*" then
            return true   -- caller should show ops menu
        elseif choice:upper() == "S" then
            local what = ui.INPUT("  Sell what? (unit name): ")
            if what and e[what] then
                local qty_s = ui.INPUT("  How many? ")
                local qty   = tonumber(qty_s) or 0
                qty = math.min(qty, e[what])
                local price = econ.buy_price(what, e.net_worth, mode)
                local revenue = math.floor(qty * price / 3)
                e[what]    = e[what] - qty
                e.credits  = e.credits + revenue
                ui.WL(ui.GRN..string.format("  Sold %s %s for %s credits.",
                    ui.commas(qty), what, ui.commas(revenue))..ui.RST)
                ui.pause()
            end
        else
            local n = tonumber(choice)
            if not n then goto cont end
            local qty_s = ui.INPUT("  How many? ")
            local qty   = tonumber(qty_s) or 0
            if qty <= 0 then goto cont end

            if n <= #UNIT_LABELS then
                local u     = UNIT_LABELS[n]
                local price = econ.buy_price(u.price_key, e.net_worth, mode)
                local cost  = price * qty
                if cost > e.credits then
                    ui.WL(ui.RED.."  Not enough credits."..ui.RST); ui.pause()
                else
                    e.credits  = e.credits - cost
                    e[u.key]   = (e[u.key] or 0) + qty
                    ui.WL(ui.GRN..string.format("  Purchased %s %s.",
                        ui.commas(qty), u.label)..ui.RST)
                    ui.pause()
                end
            else
                local pt    = PLANET_LABELS[n - #UNIT_LABELS]
                if not pt then goto cont end
                local price = econ.buy_price(pt, e.net_worth, mode)
                local cost  = price * qty
                if cost > e.credits then
                    ui.WL(ui.RED.."  Not enough credits."..ui.RST); ui.pause()
                else
                    e.credits           = e.credits - cost
                    planets[pt].count   = (planets[pt].count or 0) + qty
                    ui.WL(ui.GRN..string.format("  Colonized %d %s planet(s).",
                        qty, pt)..ui.RST)
                    ui.pause()
                end
            end
        end
        ::cont::
    end
end

-- ── Operations menu ───────────────────────────────────────────────────────────
local function operations_menu(e, planets, galaxy)
    while true do
        ui.CLS()
        ui.header("Operations Menu")
        ui.WL("  [1] Messages        [2] Bank")
        ui.WL("  [3] Covert Ops      [4] Status Screen")
        ui.WL("  [5] Scores          [6] Config (tax/draft/supply)")
        ui.WL("  [7] Lottery Ticket  [Q] Back to Spending")
        ui.WL("")
        local k = ui.KEY()
        if not k then return end
        k = k:upper()

        if k == "1" then
            msg.show_inbox(e.id, ui)
            msg.compose(e, ui)
        elseif k == "2" then
            local b = bank.load(e.id)
            -- Bank sub-menu
            ui.CLS(); ui.header("Solar Bank")
            ui.WL(string.format("  Savings: %s cr (rate %d%%)",
                ui.commas(b.savings), b.savings_rate))
            ui.WL(string.format("  Loan:    %s cr (rate %d%%)",
                ui.commas(b.loan), b.loan_rate))
            ui.WL(string.format("  Bonds:   %d  (cost 8500, return 10000)",
                b.bonds))
            ui.WL("")
            ui.WL("  [D]eposit  [W]ithdraw  [L]oan  [R]epay  [B]ond  [Q]uit")
            local bk = ui.KEY()
            if bk then bk = bk:upper() end
            if bk == "D" then
                local amt = tonumber(ui.INPUT("  Amount: ")) or 0
                local err = bank.deposit(e, b, amt)
                if err then ui.WL(ui.RED..err..ui.RST) end
            elseif bk == "W" then
                local amt = tonumber(ui.INPUT("  Amount: ")) or 0
                local err = bank.withdraw(e, b, amt)
                if err then ui.WL(ui.RED..err..ui.RST) end
            elseif bk == "L" then
                local amt = tonumber(ui.INPUT("  Loan amount: ")) or 0
                local err = bank.take_loan(e, b, amt)
                if err then ui.WL(ui.RED..err..ui.RST) end
            elseif bk == "R" then
                local amt = tonumber(ui.INPUT("  Repay amount: ")) or 0
                local err = bank.repay_loan(e, b, amt)
                if err then ui.WL(ui.RED..err..ui.RST) end
            elseif bk == "B" then
                local err = bank.buy_bond(e, b)
                if err then ui.WL(ui.RED..err..ui.RST)
                else ui.WL(ui.GRN.."  Bond purchased."..ui.RST) end
            end
            bank.save(b)
            ui.pause()
        elseif k == "3" then
            covert_screen(e)
        elseif k == "4" then
            show_status(e, planets); ui.pause()
        elseif k == "5" then
            -- Scoreboard
            ui.CLS(); ui.header("Galactic Scoreboard")
            local all = db.empire_list_active()
            for rank, row in ipairs(all) do
                ui.WL(string.format("  #%-3d [%s] %-25s  %s credits",
                    rank, row.letter, row.name, ui.commas(row.net_worth)))
            end
            ui.pause()
        elseif k == "6" then
            -- Config
            local tax_s = ui.INPUT(string.format("  Tax rate [%d%%]: ", e.tax_rate))
            local tax   = tonumber(tax_s)
            if tax and tax >= 0 and tax <= 95 then e.tax_rate = tax end
            local draft_s = ui.INPUT(string.format("  Draft rate [%d%%]: ", e.draft_rate))
            local draft   = tonumber(draft_s)
            if draft and draft >= 0 and draft <= 50 then e.draft_rate = draft end
        elseif k == "7" then
            local t = ui.INPUT("  Ticket type [S]tandard or [U]per: ")
            local tt = (t and t:upper() == "U") and "super" or "standard"
            local err = lottery.buy_ticket(e, tt)
            if err then ui.WL(ui.RED..err..ui.RST)
            else ui.WL(ui.GRN..string.format(
                "  Ticket purchased! Jackpot: %s cr", ui.commas(lottery.current_jackpot()))..ui.RST)
            end
            ui.pause()
        elseif k == "Q" then
            return
        end
    end
end
-- ── Battle menu (step 8) ──────────────────────────────────────────────────────
local function battle_menu(e, planets, galaxy)
    ui.CLS()
    ui.header("Battle Command")
    if e.protection_turns > 0 then
        ui.WL(ui.YEL..string.format(
            "  You have %d turns of protection remaining.", e.protection_turns)..ui.RST)
        ui.WL("  [V]oid protection to enable attacks  [D]one")
        local k = ui.KEY()
        if not k or k:upper() ~= "V" then return end
        local err = dip.void_protection(e, planets)
        if err then ui.WL(ui.RED..err..ui.RST); ui.pause(); return end
        ui.WL(ui.BRED.."  Protection voided. You may now attack and be attacked."..ui.RST)
        ui.pause()
    end

    while true do
        ui.CLS()
        ui.header("Battle Command")
        ui.WL("  [1] Conventional Attack    [2] Guerilla Ambush")
        ui.WL("  [3] Psionic Bombs          [4] Nuclear Offensive")
        ui.WL("  [5] Raid Pirates           [6] Spy on Pirates")
        ui.WL("  [D] Done")
        ui.WL("")
        local k = ui.KEY()
        if not k or k:upper() == "D" then return end
        k = k:upper()

        if k == "6" then
            local info = pirates.spy()
            ui.CLS(); ui.header("Pirate Intelligence")
            for _, p in ipairs(info) do
                ui.WL(string.format("  %-30s  Planets: %d  Net worth: %s",
                    p.name, p.planets, ui.commas(p.net_worth)))
            end
            ui.pause()
            goto continue
        end

        if k == "5" then
            -- Raid pirate
            local all_pirates = door.db.query(
                "SELECT id, name FROM door_sre_pirates WHERE is_active=1", {})
            for i, p in ipairs(all_pirates) do
                ui.WL(string.format("  [%d] %s", i, p.name))
            end
            local choice = tonumber(ui.INPUT("  Raid which: "))
            if not choice or not all_pirates[choice] then goto continue end
            local result, err = pirates.raid(e, all_pirates[choice].id)
            if err then ui.WL(ui.RED..err..ui.RST)
            elseif result.won then
                ui.WL(ui.BGRN..string.format(
                    "  Victory! Recovered %s credits and %s soldiers.",
                    ui.commas(result.recovered_credits),
                    ui.commas(result.recovered_soldiers))..ui.RST)
            else
                ui.WL(ui.BRED..string.format(
                    "  Defeat! Lost %s soldiers.", ui.commas(result.lost_soldiers))..ui.RST)
            end
            ui.pause()
            goto continue
        end

        -- All other attacks need a target empire
        local target_l = ui.INPUT("  Target empire letter: ")
        if not target_l or target_l == "" then goto continue end
        local target = db.empire_by_letter(target_l:upper())
        if not target then
            ui.WL(ui.RED.."  Empire not found."..ui.RST); ui.pause(); goto continue
        end
        if target.id == e.id then
            ui.WL(ui.RED.."  Cannot attack yourself."..ui.RST); ui.pause(); goto continue
        end

        local block = dip.attack_allowed(e, target.id)
        if block then
            ui.W(ui.YEL.."  "..block.."  Proceed anyway? [y/N] "..ui.RST)
            local confirm = ui.KEY()
            if not confirm or confirm:upper() ~= "Y" then goto continue end
        end

        local target_planets = db.planets_for(target.id)
        local result

        if k == "1" then
            result = combat.conventional(e, target, target_planets)
            if result.won then
                ui.WL(ui.BGRN..string.format(
                    "  VICTORY after %d rounds! Looted %s credits, captured %d planets.",
                    result.rounds, ui.commas(result.loot_credits), result.planets_taken)..ui.RST)
                db.event_post(target.id, "attacked",
                    string.format("Empire %s launched a conventional attack! Lost %d planets.",
                        e.letter, result.planets_taken))
            else
                ui.WL(ui.BRED..string.format(
                    "  DEFEAT after %d rounds. Your forces were repelled.", result.rounds)..ui.RST)
                db.event_post(target.id, "repelled_attack",
                    string.format("You repelled an attack by Empire %s!", e.letter))
            end
        elseif k == "2" then
            result = combat.guerilla(e, target)
            ui.WL(ui.GRN..string.format(
                "  Guerilla strike: %s soldiers and %s stations damaged.",
                ui.commas(result.dmg_soldiers), ui.commas(result.dmg_stations))..ui.RST)
            if result.identified then
                ui.WL(ui.BRED.."  Your soldiers were captured and identified!"..ui.RST)
                db.event_post(target.id, "guerilla_attack",
                    string.format("Empire %s launched a guerilla attack on you!", e.letter))
            else
                db.event_post(target.id, "guerilla_attack",
                    "An unknown empire launched a guerilla attack on you!")
            end
        elseif k == "3" then
            result = combat.psionic(e, target)
            ui.WL(ui.MAG..string.format(
                "  Psionic bombs detonated! Chaos spreads (violence +%d, %s soldiers fled).",
                result.violence_spike, ui.commas(result.soldiers_fled))..ui.RST)
            db.event_post(target.id, "psionic_attack",
                string.format("Empire %s hit you with psionic bombs! Mass confusion erupts.", e.letter))
        elseif k == "4" then
            ui.WL(ui.BRED.."  WARNING: Nuclear weapons are banned. The GC will penalise you."..ui.RST)
            ui.W("  Proceed? [y/N] ")
            local confirm = ui.KEY()
            if confirm and confirm:upper() == "Y" then
                result = combat.nuclear(e, target)
                ui.WL(ui.BRED..string.format(
                    "  Nuclear strike! %d planets destroyed.",
                    result.planets_destroyed)..ui.RST)
                db.event_post(target.id, "nuclear_attack",
                    string.format("Empire %s launched a NUCLEAR attack! Planets destroyed.", e.letter))
            end
        end

        -- Save target changes
        if target then db.empire_update(target) end
        ui.pause()
        ::continue::
    end
end

-- ── Trading (step 9) ──────────────────────────────────────────────────────────
local function trading_screen(e)
    local treaties = db.treaties_for(e.id)
    if #treaties == 0 then
        ui.WL(ui.CYN.."  No treaty partners to trade with."..ui.RST)
        ui.pause()
        return
    end

    ui.CLS()
    ui.header("Trading Post")
    ui.WL("  Treaty partners:")
    for i, t in ipairs(treaties) do
        local partner_id = (t.empire_a == e.id) and t.empire_b or t.empire_a
        local partner = db.empire_by_id(partner_id)
        ui.WL(string.format("  [%d] Empire %s (%s)  — %s",
            i, partner and partner.letter or "?",
            partner and partner.name or "?",
            t.type:gsub("_"," ")))
    end
    ui.WL("  [0] Skip trading")
    ui.WL("")
    local choice = tonumber(ui.INPUT("  Trade with: "))
    if not choice or choice == 0 or not treaties[choice] then return end

    local partner_id = (treaties[choice].empire_a == e.id)
        and treaties[choice].empire_b or treaties[choice].empire_a
    local partner = db.empire_by_id(partner_id)
    if not partner then return end

    -- What to send
    ui.WL(string.format("  Trading with Empire %s (%s)", partner.letter, partner.name))
    local send_cr = tonumber(ui.INPUT("  Send credits: ")) or 0
    local send_fd = tonumber(ui.INPUT("  Send food (mt): ")) or 0
    local send_sl = tonumber(ui.INPUT("  Send soldiers: ")) or 0

    send_cr = math.min(send_cr, e.credits)
    send_fd = math.min(send_fd, e.food)
    send_sl = math.min(send_sl, e.soldiers)

    -- Transfer
    e.credits  = e.credits  - send_cr
    e.food     = e.food     - send_fd
    e.soldiers = e.soldiers - send_sl
    partner.credits  = partner.credits  + send_cr
    partner.food     = partner.food     + send_fd
    partner.soldiers = partner.soldiers + send_sl
    db.empire_update(partner)

    db.event_post(partner_id, "trade_received",
        string.format("Empire %s sent you: %s credits, %d food, %s soldiers.",
            e.letter, ui.commas(send_cr), send_fd, ui.commas(send_sl)))

    ui.WL(ui.GRN.."  Trade complete."..ui.RST)
    ui.pause()
end
-- ── Final status (step 10) ────────────────────────────────────────────────────
local function final_status(e, planets)
    local pop_chg = pop.tick(e, planets)
    -- Apply draft
    local drafted = pop.apply_draft(e)

    ui.CLS()
    ui.header("End of Turn Report")
    ui.WL(string.format("  Population: %s  (net change: %s%+d%s)",
        ui.commas(e.population),
        pop_chg.net >= 0 and ui.GRN or ui.RED,
        pop_chg.net, ui.RST))
    ui.WL(string.format("  Births: %d  Immigration: %d  Deaths: %d  Emigration: %d",
        pop_chg.births, pop_chg.immigration, pop_chg.deaths, pop_chg.emigration))
    if drafted > 0 then
        ui.WL(ui.YEL..string.format("  Drafted %s citizens into the army.", ui.commas(drafted))..ui.RST)
    end
    -- Violence natural decay
    if e.internal_violence > 0 and math.random() < 0.15 then
        e.internal_violence = e.internal_violence - 1
        ui.WL(ui.GRN.."  Internal tensions ease slightly."..ui.RST)
    end
    ui.WL("")
    ui.pause()
end

-- ── Diplomacy menu (accessible from main menu) ────────────────────────────────
local function diplomacy_menu(e)
    while true do
        ui.CLS()
        ui.header("Diplomatic Relations")
        -- Show pending proposals
        local pending = dip.pending_proposals(e.id)
        if #pending > 0 then
            ui.WL(ui.BYEL.."  Pending treaty proposals:"..ui.RST)
            for _, p in ipairs(pending) do
                ui.WL(string.format("  Empire %s proposes: %s",
                    p.proposer_letter, p.type:gsub("_"," ")))
            end
            ui.WL("")
        end
        -- Current treaties
        local active = db.treaties_for(e.id)
        if #active > 0 then
            ui.WL(ui.CYN.."  Active treaties:"..ui.RST)
            for _, t in ipairs(active) do
                local partner_id = (t.empire_a == e.id) and t.empire_b or t.empire_a
                local partner = db.empire_by_id(partner_id)
                ui.WL(string.format("  Empire %s — %s",
                    partner and partner.letter or "?", t.type:gsub("_"," ")))
            end
            ui.WL("")
        end
        ui.WL("  [P]ropose treaty  [A]ccept proposal  [B]reak treaty  [Q]uit")
        local k = ui.KEY()
        if not k or k:upper() == "Q" then return end
        k = k:upper()

        if k == "P" then
            local tl = ui.INPUT("  Target empire letter: ")
            local target = tl and db.empire_by_letter(tl:upper())
            if not target then ui.WL(ui.RED.."  Not found."..ui.RST); ui.pause(); goto cont end
            ui.WL("  Treaty types:")
            for i, t in ipairs(dip.TYPES) do
                ui.WL(string.format("  [%d] %s — %s", i, t.label, t.desc))
            end
            local tn = tonumber(ui.INPUT("  Type: "))
            local td = dip.TYPES[tn]
            if not td then goto cont end
            local dur = tonumber(ui.INPUT("  Duration in days (0=indefinite): ")) or 0
            local sp, cp = 0, 0
            if td.id == "custom" then
                sp = tonumber(ui.INPUT("  Soldier % to send in defence: ")) or 0
                cp = tonumber(ui.INPUT("  Cruiser % to send in defence: ")) or 0
            end
            local err = dip.propose(e, target.id, td.id, dur, sp, cp)
            if err then ui.WL(ui.RED..err..ui.RST)
            else ui.WL(ui.GRN.."  Proposal sent."..ui.RST) end
            ui.pause()
        elseif k == "A" then
            local pl = ui.INPUT("  Accept proposal from empire letter: ")
            local proposer = pl and db.empire_by_letter(pl:upper())
            if not proposer then goto cont end
            local err = dip.accept(e.id, proposer.id, 0)
            if err then ui.WL(ui.RED..err..ui.RST)
            else ui.WL(ui.GRN.."  Treaty accepted."..ui.RST) end
            ui.pause()
        elseif k == "B" then
            local bl = ui.INPUT("  Break treaty with empire letter: ")
            local other = bl and db.empire_by_letter(bl:upper())
            if not other then goto cont end
            local err = dip.break_treaty(e.id, other.id)
            if err then ui.WL(ui.RED..err..ui.RST)
            else ui.WL(ui.YEL.."  Treaty broken."..ui.RST) end
            ui.pause()
        end
        ::cont::
    end
end

-- ── MAIN LOOP ─────────────────────────────────────────────────────────────────
galaxy_init()
daily_reset()

-- Load or register empire
local e, planets = emp.load()
if not e then
    title_screen(nil)
    e = register_empire()
    if not e then door.exit() end
    planets = db.planets_for(e.id)
end

-- Show offline events and process delayed covert ops
local events = db.events_unread(e.id)
covert.process_delayed(e, events)
if #events > 0 then
    ui.CLS()
    ui.header("Messages Waiting")
    for _, ev in ipairs(events) do
        local icon = ev.event_type:find("attack") and ui.BRED.."[!]"..ui.RST
                  or ui.CYN.."[i]"..ui.RST
        ui.WL("  "..icon.." "..ev.description)
    end
    db.events_mark_read(e.id)
    ui.pause()
end

emp.refresh_turns(e)
title_screen(e)

-- Buy lottery ticket at session start (optional)
ui.W(string.format(
    ui.CYN.."  Jackpot: %s cr — Buy a lottery ticket? [y/N] "..ui.RST,
    ui.commas(lottery.current_jackpot())))
local lt = ui.KEY()
ui.WL("")
if lt and lt:upper() == "Y" then
    lottery.buy_ticket(e, "standard")
end

-- ── TURN LOOP ─────────────────────────────────────────────────────────────────
local galaxy = db.galaxy_get_all()

while true do
    -- Main menu
    ui.CLS()
    show_status(e, planets)
    ui.WL(string.format(
        "  [P] Play turn (%s%d left%s)  [D] Diplomacy  [M] Messages  [Q] Quit",
        e.turns_remaining > 0 and ui.BGRN or ui.BRED,
        e.turns_remaining, ui.RST))
    ui.WL("")
    local k = ui.KEY()
    if not k or k:upper() == "Q" then break end
    k = k:upper()

    if k == "D" then
        diplomacy_menu(e)
    elseif k == "M" then
        msg.show_inbox(e.id, ui)
        msg.compose(e, ui)
    elseif k == "P" then
        if e.turns_remaining <= 0 then
            ui.WL(ui.BRED.."  No turns left today. Come back tomorrow."..ui.RST)
            ui.pause()
            goto continue_main
        end

        e.turns_remaining = e.turns_remaining - 1
        if e.protection_turns > 0 then
            e.protection_turns = e.protection_turns - 1
        end

        -- Steps 1-10
        galaxy = db.galaxy_get_all()
        earnings_report(e, planets, galaxy)          -- 1: earnings
        show_status(e, planets); ui.pause()           -- 2: status
        pay_maintenance(e, planets, galaxy)           -- 3: maintenance
        food_market_screen(e, planets)                -- 4: food market
        covert_screen(e)                              -- 5: covert ops

        -- 6: bank (accessed from ops menu)
        -- 7: government spending ↔ ops menu
        local show_ops = spending_menu(e, planets, galaxy)
        if show_ops then operations_menu(e, planets, galaxy) end

        battle_menu(e, planets, galaxy)               -- 8: battles
        trading_screen(e)                             -- 9: trading
        final_status(e, planets)                      -- 10: final status

        -- Save empire and planets after every turn
        emp.save(e, planets)
    end
    ::continue_main::
end

-- ── LOGOUT ────────────────────────────────────────────────────────────────────
emp.save(e, planets)
ui.CLS()
ui.WL("")
ui.WL(ui.BCYN.."  Farewell, "..e.name.." ["..e.letter.."]"..ui.RST)
ui.WL(ui.YEL..string.format("  Net worth: %s  |  Planets: %d  |  Protection: %d turns",
    ui.commas(e.net_worth), db.planet_total(e.id), e.protection_turns)..ui.RST)
ui.WL("")
ui.WL(ui.GRN.."  Your empire awaits your return..."..ui.RST)
ui.WL("")
door.sleep(1500)
door.exit()