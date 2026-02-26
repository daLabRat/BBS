-- bulletins.lua: Bulletin board / MOTD module.

local M = {}

local SEP = string.rep("-", 60)

local function show_bulletin(b)
    bbs.writeln(SEP)
    bbs.writeln("Title : " .. b.title)
    bbs.writeln("From  : " .. b.author)
    bbs.writeln(os.date("Date  : %Y-%m-%d %H:%M", b.posted_at))
    bbs.writeln(SEP)
    bbs.pager(b.body)
    bbs.writeln("")
end

local function compose_bulletin()
    local title = bbs.read_line("Title: ")
    if not title or #title == 0 then bbs.writeln("Cancelled.") return end
    bbs.writeln("Body (end with a line containing only '.'):")
    local lines = {}
    while true do
        local line = bbs.read_line("")
        if line == "." or line == nil then break end
        table.insert(lines, line)
    end
    bbs.bulletins.post(title, table.concat(lines, "\n"))
    bbs.writeln("Bulletin posted.")
end

local function delete_bulletin(list)
    local choice = bbs.read_line("Delete bulletin # (or Enter to cancel): ")
    local n = tonumber(choice)
    if not n or not list[n] then bbs.writeln("Cancelled.") return end
    bbs.bulletins.delete(list[n].id)
    bbs.writeln("Bulletin deleted.")
end

-- Called from main menu: full interactive bulletin browser.
function M.run()
    local list = bbs.bulletins.list()
    bbs.writeln("")
    bbs.writeln(bbs.ansi("bold") .. "[ Bulletins ]" .. bbs.ansi("reset"))
    bbs.writeln("")
    if #list == 0 then
        bbs.writeln("  No bulletins posted.")
    else
        for i, b in ipairs(list) do
            bbs.writeln(string.format("  [%2d] %-30s  %s",
                i, b.title, os.date("%Y-%m-%d", b.posted_at)))
        end
    end
    bbs.writeln("")

    if bbs.user.is_sysop then
        bbs.writeln("  [R] Read   [P] Post   [D] Delete   [Q] Back")
    else
        bbs.writeln("  [R] Read   [Q] Back")
    end
    bbs.writeln("")

    local key = bbs.read_key()
    if key == nil then return end
    key = key:upper()

    if key == "R" then
        if #list == 0 then return end
        local choice = bbs.read_line("Read # (or Enter to cancel): ")
        local n = tonumber(choice)
        if not n or not list[n] then return end
        local b = bbs.bulletins.get(list[n].id)
        if b then show_bulletin(b) end

    elseif key == "P" and bbs.user.is_sysop then
        compose_bulletin()

    elseif key == "D" and bbs.user.is_sysop then
        if #list == 0 then return end
        for i, b in ipairs(list) do
            bbs.writeln(string.format("  [%2d] %s", i, b.title))
        end
        delete_bulletin(list)
    end
end

-- Called at login: display all active bulletins in sequence.
-- Skips silently if there are none.
function M.show_new()
    local list = bbs.bulletins.list()
    if #list == 0 then return end

    bbs.writeln("")
    bbs.writeln(bbs.ansi("bold") .. "*** " .. #list .. " bulletin(s) ***" .. bbs.ansi("reset"))
    bbs.writeln("")

    for _, b in ipairs(list) do
        local full = bbs.bulletins.get(b.id)
        if full then show_bulletin(full) end
    end

    bbs.write("Press any key to continue...")
    bbs.read_key()
    bbs.writeln("")
end

return M
