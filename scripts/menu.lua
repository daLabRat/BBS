-- menu.lua: Main menu loop.

local boards    = require("boards")
local bulletins = require("bulletins")
local mail      = require("mail")
local profile   = require("profile")
local sysop     = require("sysop")
local who       = require("who")

local M = {}

local MAIN_MENU = {
    title = "Main Menu",
    items = {
        { key = "B", label = "Bulletins",         action = "bulletins" },
        { key = "M", label = "Message boards",  action = "boards"  },
        { key = "D", label = "Door games",       action = "doors"   },
        { key = "E", label = "E-mail / Mail",    action = "mail"    },
        { key = "U", label = "User profile",     action = "profile" },
        { key = "W", label = "Who's online",     action = "who"     },
        { key = "S", label = "System info",      action = "sysinfo" },
        { key = "A", label = "Admin panel",      action = "admin",  sysop_only = true },
        { key = "Q", label = "Quit / Logoff",    action = "quit"    },
    },
}

local function show_menu(def)
    bbs.writeln("")
    local unread = bbs.mail.unread()
    if unread > 0 then
        bbs.writeln(bbs.ansi("bold") .. "  *** " .. unread .. " unread mail ***" .. bbs.ansi("reset"))
    end
    bbs.writeln(bbs.ansi("bold") .. "[ " .. def.title .. " ]" .. bbs.ansi("reset"))
    bbs.writeln("")
    for _, item in ipairs(def.items) do
        if not item.sysop_only or bbs.user.is_sysop then
            bbs.writeln(string.format("  [%s] %s", item.key, item.label))
        end
    end
    bbs.writeln("")
end

local function sysinfo()
    bbs.writeln("")
    bbs.writeln("System info:")
    bbs.writeln("  Time: " .. os.date("%Y-%m-%d %H:%M:%S", bbs.time()))
    if bbs.user.is_sysop then
        bbs.writeln("  Role: Sysop")
    end
    bbs.writeln("")
end

local function doors_menu()
    local list = bbs.doors.list()
    if #list == 0 then
        bbs.writeln("No doors installed.")
        return
    end
    bbs.writeln("")
    bbs.writeln("Available doors:")
    for i, name in ipairs(list) do
        bbs.writeln(string.format("  [%d] %s", i, name))
    end
    local choice = bbs.read_line("Launch door (or Enter to cancel): ")
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
