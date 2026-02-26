-- who.lua: Who's currently online.

local M = {}

function M.run()
    local list = bbs.who.list()
    bbs.writeln("")
    bbs.writeln(bbs.ansi("bold") .. "[ Who's Online ]" .. bbs.ansi("reset"))
    bbs.writeln("")
    if #list == 0 then
        bbs.writeln("  Nobody online.")
    else
        bbs.writeln(string.format("  %-20s  %s", "Handle", "Connected"))
        bbs.writeln("  " .. string.rep("-", 38))
        for _, u in ipairs(list) do
            bbs.writeln(string.format("  %-20s  %s",
                u.name, os.date("%Y-%m-%d %H:%M", u.connected_at)))
        end
        bbs.writeln("")
        bbs.writeln("  " .. #list .. " user(s) online.")
    end
    bbs.writeln("")
    bbs.write("Press any key...")
    bbs.read_key()
    bbs.writeln("")
end

return M
