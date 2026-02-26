-- main.lua: BBS session entry point.
-- Called once per user connection by bbs-runtime.

local auth      = require("auth")
local bulletins = require("bulletins")
local menu      = require("menu")

local function show_welcome()
    bbs.clear()
    bbs.writeln(bbs.ansi("bold") .. "Welcome to the BBS!" .. bbs.ansi("reset"))
    bbs.writeln("")
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

    -- Show any active bulletins after login
    bulletins.show_new()

    -- Hand off to the main menu loop
    menu.run()

    bbs.writeln("")
    bbs.writeln("Thanks for calling. Goodbye!")
end

main()
