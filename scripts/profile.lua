-- profile.lua: User profile viewer and settings.

local M = {}

local function view_stats()
    local s = bbs.profile.stats()
    bbs.writeln("")
    bbs.writeln(bbs.ansi("bold") .. "[ Profile: " .. bbs.user.name .. " ]" .. bbs.ansi("reset"))
    bbs.writeln("")
    bbs.writeln("  Handle   : " .. bbs.user.name)
    if bbs.user.is_sysop then
        bbs.writeln("  Role     : Sysop")
    end
    bbs.writeln(os.date("  Joined   : %Y-%m-%d", s.joined))
    if s.last_login then
        bbs.writeln(os.date("  Last on  : %Y-%m-%d %H:%M", s.last_login))
    end
    bbs.writeln("  Posts    : " .. s.post_count)
    bbs.writeln("  Mail sent: " .. s.mail_sent)
    bbs.writeln("  Mail rcvd: " .. s.mail_received)
    bbs.writeln("")
end

local function change_password()
    local old = bbs.read_pass("Current password: ")
    if not old or #old == 0 then bbs.writeln("Cancelled.") return end
    local new1 = bbs.read_pass("New password    : ")
    if not new1 or #new1 == 0 then bbs.writeln("Cancelled.") return end
    local new2 = bbs.read_pass("Confirm new     : ")
    if new1 ~= new2 then
        bbs.writeln("Passwords do not match.")
        return
    end
    local ok, err = bbs.profile.change_password(old, new1)
    if ok then
        bbs.writeln("Password changed.")
    else
        bbs.writeln("Error: " .. (err or "unknown"))
    end
end

function M.run()
    bbs.writeln("")
    bbs.writeln(bbs.ansi("bold") .. "[ Profile ]" .. bbs.ansi("reset"))
    bbs.writeln("")
    bbs.writeln("  [V] View stats   [P] Change password   [Q] Back")
    bbs.writeln("")
    local key = bbs.read_key()
    if key == nil then return end
    key = key:upper()
    if key == "V" then
        view_stats()
    elseif key == "P" then
        change_password()
    end
end

return M
