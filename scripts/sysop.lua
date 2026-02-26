-- sysop.lua: Sysop administration panel.

local M = {}

local function require_sysop()
    if not bbs.user.is_sysop then
        bbs.writeln("Access denied.")
        return false
    end
    return true
end

-- ── Users ─────────────────────────────────────────────────────────────────────

local function list_users()
    local users = bbs.sysop.users()
    bbs.writeln("")
    bbs.writeln(bbs.ansi("bold") .. "[ User List ]" .. bbs.ansi("reset"))
    bbs.writeln("")
    bbs.writeln(string.format("  %-4s  %-20s  %-6s  %-6s  %s",
        "#", "Username", "Sysop", "Banned", "Last Login"))
    bbs.writeln("  " .. string.rep("-", 54))
    for i, u in ipairs(users) do
        local sysop_f  = u.is_sysop and "yes" or ""
        local banned_f = u.banned   and "yes" or ""
        local last     = u.last_login
            and os.date("%Y-%m-%d", u.last_login) or "never"
        bbs.writeln(string.format("  [%2d] %-20s  %-6s  %-6s  %s",
            i, u.name, sysop_f, banned_f, last))
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

local function users_panel()
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

-- ── Boards ────────────────────────────────────────────────────────────────────

local function list_boards_admin()
    local boards = bbs.boards.list()
    bbs.writeln("")
    bbs.writeln(bbs.ansi("bold") .. "[ Board List ]" .. bbs.ansi("reset"))
    bbs.writeln("")
    if #boards == 0 then
        bbs.writeln("  (no boards)")
    else
        for i, b in ipairs(boards) do
            bbs.writeln(string.format("  [%2d] %-20s  %s", i, b.name, b.description))
        end
    end
    bbs.writeln("")
    return boards
end

local function create_board()
    local name = bbs.read_line("Board name: ")
    if not name or #name == 0 then bbs.writeln("Cancelled.") return end
    local desc = bbs.read_line("Description: ")
    if not desc then desc = "" end
    bbs.sysop.create_board(name, desc)
    bbs.writeln("Board '" .. name .. "' created.")
end

local function delete_board(boards)
    if #boards == 0 then bbs.writeln("No boards to delete.") return end
    local choice = bbs.read_line("Delete board # (or Enter to cancel): ")
    local n = tonumber(choice)
    if not n or not boards[n] then bbs.writeln("Cancelled.") return end
    local b = boards[n]
    local confirm = bbs.read_line("Delete '" .. b.name .. "' and ALL its messages? [y/N]: ")
    if confirm ~= "y" and confirm ~= "Y" then bbs.writeln("Cancelled.") return end
    bbs.sysop.delete_board(b.id)
    bbs.writeln("Board deleted.")
end

local function boards_panel()
    local boards = list_boards_admin()
    bbs.writeln("  [C] Create   [D] Delete   [Q] Back")
    bbs.writeln("")
    local key = bbs.read_key()
    if key == nil then return end
    key = key:upper()
    if key == "C" then
        create_board()
    elseif key == "D" then
        delete_board(boards)
    end
end

-- ── Main panel ────────────────────────────────────────────────────────────────

function M.run()
    if not require_sysop() then return end

    bbs.writeln("")
    bbs.writeln(bbs.ansi("bold") .. "[ Admin Panel ]" .. bbs.ansi("reset"))
    bbs.writeln("")
    bbs.writeln("  [U] Users   [B] Boards   [Q] Back")
    bbs.writeln("")
    local key = bbs.read_key()
    if key == nil then return end
    key = key:upper()
    if key == "U" then
        users_panel()
    elseif key == "B" then
        boards_panel()
    end
end

return M
