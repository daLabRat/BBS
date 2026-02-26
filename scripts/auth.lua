-- auth.lua: Login and registration flow using the real bbs.auth API.

local M = {}

function M.login()
    bbs.writeln("Please log in. Type 'new' to register.")
    bbs.writeln("")

    local username = bbs.read_line("Username: ")
    if username == nil or username == "" then
        return false
    end

    if username:lower() == "new" then
        return M.register()
    end

    local password = bbs.read_pass("Password: ")
    if password == nil then
        return false
    end

    local user = bbs.auth.login(username, password)
    if user then
        bbs.user.name     = user.name
        bbs.user.id       = user.id
        bbs.user.is_sysop = user.is_sysop
        return true
    end

    bbs.writeln("Invalid credentials.")
    return false
end

function M.register()
    bbs.writeln("--- New User Registration ---")
    bbs.writeln("")

    local username = bbs.read_line("Choose a username: ")
    if not username or #username < 2 then
        bbs.writeln("Username too short.")
        return false
    end

    local password = bbs.read_pass("Choose a password: ")
    if not password or #password < 6 then
        bbs.writeln("Password must be at least 6 characters.")
        return false
    end

    local confirm = bbs.read_pass("Confirm password: ")
    if confirm ~= password then
        bbs.writeln("Passwords do not match.")
        return false
    end

    local user = bbs.auth.register(username, password)
    if user then
        bbs.user.name     = user.name
        bbs.user.id       = user.id
        bbs.user.is_sysop = user.is_sysop
        bbs.writeln("Account created! Welcome, " .. user.name .. "!")
        return true
    end

    bbs.writeln("Registration failed (username already taken).")
    return false
end

return M
