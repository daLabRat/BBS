-- main.lua: BBS session entry point.
-- Called once per user connection by bbs-runtime.

local auth      = require("auth")
local bulletins = require("bulletins")
local menu      = require("menu")

-- ANSI helpers
local ESC  = string.char(27)
local function A(c) return ESC.."["..c.."m" end
local RST  = A("0")
local BOL  = A("1")
local DIM  = A("2")
local RED  = A("31"); local GRN = A("32"); local YEL = A("33")
local BLU  = A("34"); local MAG = A("35"); local CYN = A("36"); local WHT = A("37")
local BRED = BOL..A("31"); local BGRN = BOL..A("32"); local BYEL = BOL..A("33")
local BBLU = BOL..A("34"); local BMAG = BOL..A("35"); local BCYN = BOL..A("36")
local BWHT = BOL..A("37")

local function W(s)  bbs.write(s)         end
local function WL(s) bbs.writeln(s or "") end

local function show_welcome()
    bbs.clear()
    -- ── Banner ────────────────────────────────────────────────────────────
    WL("")
    WL(BCYN.."  ╔══════════════════════════════════════════════════════════╗"..RST)
    WL(BCYN.."  ║"..RST..BRED.."  ██████╗ ██████╗ ███████╗"..RST..
            "                                   "..BCYN.."║"..RST)
    WL(BCYN.."  ║"..RST..BRED.."  ██╔══██╗██╔══██╗██╔════╝"..RST..
            "  "..DIM..WHT.."Bulletin Board System"..RST..
            "            "..BCYN.."║"..RST)
    WL(BCYN.."  ║"..RST..BRED.."  ██████╔╝██████╔╝███████╗"..RST..
            "  "..YEL.."Est. 2026"..RST..
            "                        "..BCYN.."║"..RST)
    WL(BCYN.."  ║"..RST..BRED.."  ██╔══██╗██╔══██╗╚════██║"..RST..
            "                                   "..BCYN.."║"..RST)
    WL(BCYN.."  ║"..RST..BRED.."  ██████╔╝██████╔╝███████║"..RST..
            "                                   "..BCYN.."║"..RST)
    WL(BCYN.."  ║"..RST..BRED.."  ╚═════╝ ╚═════╝ ╚══════╝"..RST..
            "  "..DIM..CYN.."SSH · Telnet · WWW · NNTP"..RST..
            "         "..BCYN.."║"..RST)
    WL(BCYN.."  ╚══════════════════════════════════════════════════════════╝"..RST)
    WL("")

    -- ── Last callers ─────────────────────────────────────────────────────
    local callers = bbs.callers.recent(5)
    if #callers > 0 then
        WL(DIM..WHT.."  Last callers:"..RST)
        for _, c in ipairs(callers) do
            WL(string.format("  "..CYN.."%-20s"..RST.."  "..DIM.."%s"..RST,
                c.name, os.date("%Y-%m-%d %H:%M", c.time)))
        end
        WL("")
    end
end

local function main()
    show_welcome()

    -- Authenticate (or register)
    local ok = auth.login()
    if not ok then
        WL(RED.."Goodbye."..RST)
        return
    end

    WL("")
    WL(BGRN.."  Welcome back, "..BWHT..bbs.user.name..BGRN.."!"..RST)

    -- Register in the who's-online list for this session
    bbs.who.checkin(bbs.user.name)

    -- Show any active bulletins after login
    bulletins.show_new()

    -- Hand off to the main menu loop
    menu.run()

    WL("")
    WL(CYN.."  Thanks for calling.  "..BWHT.."Goodbye!"..RST)
    WL("")
end

main()
