-- doors/sre/main.lua  (stub — Phase 4a smoke test)
local ui       = require("lib.ui")
local db       = require("lib.db")
local empire   = require("lib.empire")
local economy  = require("lib.economy")
local pop      = require("lib.population")
local research = require("lib.research")

-- Initialise galaxy defaults if first run
if not db.galaxy_get("game_day") then
    db.galaxy_set("game_day",          "1")
    db.galaxy_set("mode",              "non_inflationary")
    db.galaxy_set("food_market_stock", "500000")
    db.galaxy_set("food_price",        "10")
    db.galaxy_set("pollution_level",   "0")
end

ui.CLS()
ui.WL(ui.BYEL.."  Solar Realms Elite -- engine test"..ui.RST)
ui.WL("")

local e, planets = empire.load()
if not e then
    ui.WL(ui.CYN.."  No empire yet. (Registration coming in Phase 4d)"..ui.RST)
else
    local galaxy    = db.galaxy_get_all()
    local income    = economy.planet_income(e, planets, galaxy)
    local pop_chg   = pop.tick(e, planets)
    local breakthru = research.roll_breakthrough(income.research_pts, e.id)

    ui.WL(ui.GRN..string.format("  Empire: %s  Credits: %s  Food: %s",
        e.name, ui.commas(e.credits), ui.commas(e.food))..ui.RST)
    ui.WL(ui.YEL..string.format("  Turn income: %s cr  Food prod: %d mt  Research: %d pts",
        ui.commas(income.credits), income.food_prod, income.research_pts)..ui.RST)
    ui.WL(ui.CYN..string.format("  Pop change: +%d births +%d immigr -%d deaths -%d emig  (net %d)",
        pop_chg.births, pop_chg.immigration, pop_chg.deaths, pop_chg.emigration, pop_chg.net)..ui.RST)
    if breakthru then
        ui.WL(ui.BYEL.."  BREAKTHROUGH: "..breakthru.description..ui.RST)
    end
end

ui.WL("")
ui.pause()
door.exit()
