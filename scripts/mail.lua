-- mail.lua: Private messaging module.

local M = {}

local function show_inbox()
    local msgs = bbs.mail.inbox()
    if #msgs == 0 then
        bbs.writeln("  (empty)")
        return
    end
    for i, m in ipairs(msgs) do
        local flag = m.read and " " or "*"
        bbs.writeln(string.format("  [%2d]%s From: %-16s  %s", i, flag, m["from"], m.subject))
    end
    bbs.writeln("")
    local choice = bbs.read_line("Read # (or Enter to cancel): ")
    local n = tonumber(choice)
    if not n or not msgs[n] then return end
    local m = msgs[n]
    bbs.writeln(string.rep("-", 60))
    bbs.writeln("From   : " .. m["from"])
    bbs.writeln("Subject: " .. m.subject)
    bbs.writeln(os.date("Date   : %Y-%m-%d %H:%M", m.sent_at))
    bbs.writeln(string.rep("-", 60))
    bbs.pager(m.body)
    bbs.mail.mark_read(m.id)
end

local function show_sent()
    local msgs = bbs.mail.sent()
    if #msgs == 0 then
        bbs.writeln("  (empty)")
        return
    end
    for i, m in ipairs(msgs) do
        bbs.writeln(string.format("  [%2d] To: %-16s  %s", i, m["to"], m.subject))
    end
end

local function compose()
    local to = bbs.read_line("To (username): ")
    if not to or #to == 0 then bbs.writeln("Cancelled.") return end
    local subject = bbs.read_line("Subject: ")
    if not subject or #subject == 0 then bbs.writeln("Cancelled.") return end
    bbs.writeln("Body (end with a line containing only '.'):")
    local lines = {}
    while true do
        local line = bbs.read_line("")
        if line == "." or line == nil then break end
        table.insert(lines, line)
    end
    local ok, err = bbs.mail.send(to, subject, table.concat(lines, "\n"))
    if ok then
        bbs.writeln("Message sent!")
    else
        bbs.writeln("Error: " .. (err or "unknown"))
    end
end

function M.run()
    local unread = bbs.mail.unread()
    bbs.writeln("")
    bbs.writeln(bbs.ansi("bold") .. "[ Mail ]" .. bbs.ansi("reset"))
    if unread > 0 then
        bbs.writeln("  You have " .. unread .. " unread message(s).")
    end
    bbs.writeln("")
    bbs.writeln("  [I] Inbox   [S] Sent   [C] Compose   [Q] Back")
    bbs.writeln("")
    local key = bbs.read_key()
    if key == nil then return end
    key = key:upper()
    if key == "I" then
        show_inbox()
    elseif key == "S" then
        show_sent()
    elseif key == "C" then
        compose()
    end
end

return M
