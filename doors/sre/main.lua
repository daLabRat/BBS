-- doors/sre/main.lua  (stub — Phase 3 smoke test)
local ui     = require("lib.ui")
local db     = require("lib.db")
local empire = require("lib.empire")

ui.CLS()
ui.WL(ui.BYEL.."  Solar Realms Elite -- loading..."..ui.RST)

local e, planets = empire.load()
if not e then
    ui.WL(ui.CYN.."  No empire registered for this account yet."..ui.RST)
else
    ui.WL(ui.GRN..string.format("  Welcome back, %s (Empire %s)  Net worth: %s credits",
        e.name, e.letter, ui.commas(e.net_worth))..ui.RST)
end

ui.WL("")
ui.pause()
door.exit()
