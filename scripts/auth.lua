-- auth.lua: Login and registration flow.

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

    local password = bbs.read_line("Password: ")
    if password == nil then
        return false
    end

    -- TODO: call bbs.auth.login(username, password) once Rust API is wired
    -- For now, accept any credentials for development
    bbs.writeln("[auth stub] Logged in as: " .. username)
    return true
end

function M.register()
    bbs.writeln("--- New User Registration ---")
    bbs.writeln("")

    local username = bbs.read_line("Choose a username: ")
    if not username or #username < 2 then
        bbs.writeln("Username too short.")
        return false
    end

    local password = bbs.read_line("Choose a password: ")
    if not password or #password < 6 then
        bbs.writeln("Password must be at least 6 characters.")
        return false
    end

    -- TODO: call bbs.auth.register(username, password) once Rust API is wired
    bbs.writeln("Account created! Welcome, " .. username .. "!")
    return true
end

return M
