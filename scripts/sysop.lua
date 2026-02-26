-- sysop.lua: Sysop administration panel.

local M = {}

local function require_sysop()
    if not bbs.user.is_sysop then
        bbs.writeln("Access denied.")
        return false
    end
    return true
end

local function list_users()
    local users = bbs.sysop.users()
    bbs.writeln("")
    bbs.writeln(bbs.ansi("bold") .. "[ User List ]" .. bbs.ansi("reset"))
    bbs.writeln("")
    bbs.writeln(string.format("  %-4s  %-20s  %-6s  %-6s  %s",
        "#", "Username", "Sysop", "Banned", "Last Login"))
    bbs.writeln("  " .. string.rep("-", 54))
    for i, u in ipairs(users) do
        local sysop  = u.is_sysop and "yes" or ""
        local banned = u.banned   and "yes" or ""
        local last   = u.last_login
            and os.date("%Y-%m-%d", u.last_login) or "never"
        bbs.writeln(string.format("  [%2d] %-20s  %-6s  %-6s  %s",
            i, u.name, sysop, banned, last))
    end
    bbs.writeln("")
    return users
end

local function ban_user(users)
    local choice = bbs.read_line("Ban user # (or Enter to cancel): ")
    local n = tonumber(choice)
    if not n or not users[n] then bbs.writeln("Cancelled.") return end
    local u = users[n]
    if u.is_sysop then bbs.writeln("Cannot ban a sysop.") return end
    local ok, err = bbs.sysop.ban(u.name)
    if ok then bbs.writeln(u.name .. " banned.")
    else bbs.writeln("Error: " .. (err or "unknown")) end
end

local function unban_user(users)
    local choice = bbs.read_line("Unban user # (or Enter to cancel): ")
    local n = tonumber(choice)
    if not n or not users[n] then bbs.writeln("Cancelled.") return end
    local u = users[n]
    local ok, err = bbs.sysop.unban(u.name)
    if ok then bbs.writeln(u.name .. " unbanned.")
    else bbs.writeln("Error: " .. (err or "unknown")) end
end

function M.run()
    if not require_sysop() then return end

    local users = list_users()
    bbs.writeln("  [B] Ban   [U] Unban   [Q] Back")
    bbs.writeln("")
    local key = bbs.read_key()
    if key == nil then return end
    key = key:upper()
    if key == "B" then
        ban_user(users)
    elseif key == "U" then
        unban_user(users)
    end
end

return M
