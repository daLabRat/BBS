-- menu.lua: Main menu loop.

local boards    = require("boards")
local bulletins = require("bulletins")
local mail      = require("mail")
local profile   = require("profile")
local sysop     = require("sysop")
local who       = require("who")

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

local M = {}

local MAIN_MENU = {
    title = "Main Menu",
    items = {
        { key = "B", label = "Bulletins",       action = "bulletins", color = YEL  },
        { key = "M", label = "Message boards",  action = "boards",    color = GRN  },
        { key = "D", label = "Door games",       action = "doors",     color = MAG  },
        { key = "E", label = "E-mail / Mail",    action = "mail",      color = CYN  },
        { key = "U", label = "User profile",     action = "profile",   color = BLU  },
        { key = "W", label = "Who's online",     action = "who",       color = BGRN },
        { key = "S", label = "System info",      action = "sysinfo",   color = DIM..WHT },
        { key = "A", label = "Admin panel",      action = "admin",     color = BRED, sysop_only = true },
        { key = "Q", label = "Quit / Logoff",    action = "quit",      color = RED  },
    },
}

local function show_menu(def)
    bbs.clear()

    -- Header bar
    local user_line = BCYN..bbs.user.name..RST
    if bbs.user.is_sysop then
        user_line = user_line .. "  "..BYEL.."[Sysop]"..RST
    end
    local unread = bbs.mail.unread()
    local mail_tag = ""
    if unread > 0 then
        mail_tag = "  "..BRED.."["..unread.." new mail]"..RST
    end

    bbs.writeln("")
    bbs.writeln(BCYN.."  ┌──────────────────────────────────────────────────────────┐"..RST)
    bbs.writeln(BCYN.."  │"..RST.."  "..BWHT.."[ "..def.title.." ]"..RST..
        "  "..user_line..mail_tag)
    bbs.writeln(BCYN.."  └──────────────────────────────────────────────────────────┘"..RST)
    bbs.writeln("")

    -- Menu items in two columns
    local visible = {}
    for _, item in ipairs(def.items) do
        if not item.sysop_only or bbs.user.is_sysop then
            visible[#visible + 1] = item
        end
    end

    local mid = math.ceil(#visible / 2)
    for i = 1, mid do
        local left  = visible[i]
        local right = visible[i + mid]
        local lc = left.color or CYN
        local ls = string.format("  "..BCYN.."["..RST..lc.."%s"..RST..BCYN.."]"..RST.."  %-18s",
            left.key, left.label)
        if right then
            local rc = right.color or CYN
            local rs = string.format("  "..BCYN.."["..RST..rc.."%s"..RST..BCYN.."]"..RST.."  %s",
                right.key, right.label)
            bbs.writeln("  "..ls..rs)
        else
            bbs.writeln("  "..ls)
        end
    end

    bbs.writeln("")
    bbs.write(BCYN.."  Your choice: "..RST)
end

local function sysinfo()
    bbs.writeln("")
    bbs.writeln(BCYN.."  ┌─ System Info ──────────────────────────────┐"..RST)
    bbs.writeln(string.format("  │  "..YEL.."%-12s"..RST.."  %s",
        "Time:", os.date("%Y-%m-%d %H:%M:%S", bbs.time())))
    if bbs.user.is_sysop then
        bbs.writeln(string.format("  │  "..YEL.."%-12s"..RST.."  %s",
            "Role:", BYEL.."Sysop"..RST))
    end
    bbs.writeln("  └───────────────────────────────────────────┘"..RST)
    bbs.writeln("")
end

local function doors_menu()
    local list = bbs.doors.list()
    bbs.clear()
    if #list == 0 then
        bbs.writeln("")
        bbs.writeln(YEL.."  No doors installed."..RST)
        bbs.writeln("")
        return
    end
    bbs.writeln("")
    bbs.writeln(BMAG.."  ┌─ Door Games ───────────────────────────────┐"..RST)
    for i, name in ipairs(list) do
        bbs.writeln(string.format("  │  "..BCYN.."[%d]"..RST.."  %s", i, name))
    end
    bbs.writeln("  └───────────────────────────────────────────┘"..RST)
    bbs.writeln("")
    bbs.write(BCYN.."  Launch door # (or Enter to cancel): "..RST)
    local choice = bbs.read_line("")
    local n = tonumber(choice)
    if n and list[n] then
        bbs.doors.launch(list[n])
    end
end

function M.run()
    local running = true
    while running do
        show_menu(MAIN_MENU)
        local key = bbs.read_key()
        if key == nil then
            running = false
        else
            key = key:upper()
            bbs.writeln("")
            if key == "B" then
                bulletins.run()
            elseif key == "M" then
                boards.run()
            elseif key == "D" then
                doors_menu()
            elseif key == "E" then
                mail.run()
            elseif key == "U" then
                profile.run()
            elseif key == "W" then
                who.run()
            elseif key == "S" then
                sysinfo()
            elseif key == "A" then
                sysop.run()
            elseif key == "Q" then
                running = false
            end
        end
    end
end

return M
