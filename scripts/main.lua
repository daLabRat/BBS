-- main.lua: BBS session entry point.
-- Called once per user connection by bbs-runtime.

local auth      = require("auth")
local bulletins = require("bulletins")
local menu      = require("menu")

-- ── ANSI helpers ──────────────────────────────────────────────────────────
local ESC  = string.char(27)
local function A(c) return ESC.."["..c.."m" end
local RST  = A("0")
local BOL  = A("1")
local DIM  = A("2")
local RED  = A("31"); local GRN = A("32"); local YEL = A("33")
local CYN  = A("36"); local WHT = A("37")
local BRED = BOL..A("31")
local BGRN = BOL..A("32")
local BCYN = BOL..A("36")
local BWHT = BOL..A("37")

local function WL(s) bbs.writeln(s or "") end

-- Return the number of visible (non-ANSI) Unicode codepoints in s.
local function vis(s)
    local stripped = s:gsub("\27%[[%d;]*m", "")
    return utf8.len(stripped) or #stripped
end

-- A box row: left border + content + auto-padding to BOX_INNER + right border.
local BOX_INNER = 58    -- inner width (between the two │ chars)
local function brow(content)
    local pad = string.rep(" ", math.max(0, BOX_INNER - vis(content)))
    return BCYN.."  ║"..RST..content..pad..BCYN.."║"..RST
end

local function show_welcome()
    bbs.clear()

    local rule = string.rep("═", BOX_INNER)
    WL(BCYN.."  ╔"..rule.."╗"..RST)
    WL(brow(""))
    WL(brow(BRED.."  ██████╗ ██████╗ ███████╗"..RST))
    WL(brow(BRED.."  ██╔══██╗██╔══██╗██╔════╝"..RST..
            "  "..DIM..WHT.."Bulletin Board System"..RST))
    WL(brow(BRED.."  ██████╔╝██████╔╝███████╗"..RST..
            "  "..YEL.."SSH · Telnet · WWW · NNTP"..RST))
    WL(brow(BRED.."  ██╔══██╗██╔══██╗╚════██║"..RST))
    WL(brow(BRED.."  ██████╔╝██████╔╝███████║"..RST))
    WL(brow(BRED.."  ╚═════╝ ╚═════╝ ╚══════╝"..RST..
            "  "..DIM..CYN.."Est. 2026"..RST))
    WL(brow(""))
    WL(BCYN.."  ╚"..rule.."╝"..RST)
    WL("")

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

    local ok = auth.login()
    if not ok then
        WL(RED.."Goodbye."..RST)
        return
    end

    WL("")
    WL(BGRN.."  Welcome back, "..BWHT..bbs.user.name..BGRN.."!"..RST)

    bbs.who.checkin(bbs.user.name)
    bulletins.show_new()
    menu.run()

    WL("")
    WL(CYN.."  Thanks for calling.  "..BWHT.."Goodbye!"..RST)
    WL("")
end

main()
