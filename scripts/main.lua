-- main.lua: BBS session entry point.
-- Called once per user connection by bbs-runtime.

local auth      = require("auth")
local bulletins = require("bulletins")
local menu      = require("menu")

local function show_welcome()
    bbs.clear()
    local art = bbs.art("welcome")
    if art then
        bbs.write(bbs.ansi("bold") .. bbs.ansi("cyan") .. art .. bbs.ansi("reset"))
    else
        bbs.writeln(bbs.ansi("bold") .. "Welcome to the BBS!" .. bbs.ansi("reset"))
        bbs.writeln("")
    end
    local callers = bbs.callers.recent(10)
    if #callers > 0 then
        bbs.writeln("Last callers:")
        for _, c in ipairs(callers) do
            bbs.writeln(string.format("  %-20s  %s",
                c.name, os.date("%Y-%m-%d %H:%M", c.time)))
        end
        bbs.writeln("")
    end
end

local function main()
    show_welcome()

    -- Authenticate (or register)
    local ok = auth.login()
    if not ok then
        bbs.writeln("Goodbye.")
        return
    end

    bbs.writeln("Hello, " .. bbs.user.name .. "!")

    -- Register in the who's-online list for this session
    bbs.who.checkin(bbs.user.name)

    -- Show any active bulletins after login
    bulletins.show_new()

    -- Hand off to the main menu loop
    menu.run()

    bbs.writeln("")
    bbs.writeln("Thanks for calling. Goodbye!")
end

main()
