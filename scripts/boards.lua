-- boards.lua: Message board reader/poster with threaded display.

local M = {}

-- Build a depth-first ordered list from a flat message array.
-- Each entry gets a _depth field added in place.
local function build_thread_order(messages)
    local by_id = {}
    for _, m in ipairs(messages) do by_id[m.id] = m end

    local children = {}
    local roots = {}
    for _, m in ipairs(messages) do
        local pid = m.parent_id
        if pid and pid ~= 0 and by_id[pid] then
            if not children[pid] then children[pid] = {} end
            table.insert(children[pid], m)
        else
            table.insert(roots, m)
        end
    end

    local ordered = {}
    local function traverse(msg, depth)
        msg._depth = depth
        table.insert(ordered, msg)
        if children[msg.id] then
            for _, child in ipairs(children[msg.id]) do
                traverse(child, depth + 1)
            end
        end
    end
    for _, root in ipairs(roots) do traverse(root, 0) end
    return ordered
end

local function list_boards()
    local boards = bbs.boards.list()
    if #boards == 0 then
        bbs.writeln("No boards available.")
        return nil
    end
    bbs.writeln("")
    bbs.writeln(bbs.ansi("bold") .. "Message Boards:" .. bbs.ansi("reset"))
    bbs.writeln(string.format("  %-3s  %-20s  %5s  %5s  %s",
        "#", "Name", "Total", "New", "Description"))
    bbs.writeln("  " .. string.rep("-", 58))
    for i, b in ipairs(boards) do
        local new_col
        if b.new > 0 then
            new_col = bbs.ansi("bold") .. string.format("%5d", b.new) .. bbs.ansi("reset")
        else
            new_col = string.format("%5d", b.new)
        end
        bbs.writeln(string.format("  [%d] %-20s  %5d  %s  %s",
            i, b.name, b.total, new_col, b.description))
    end
    bbs.writeln("")
    return boards
end

local function read_board(board)
    local messages = bbs.boards.read(board.id)
    if #messages == 0 then
        bbs.writeln("No messages in " .. board.name .. ".")
        return
    end

    local ordered = build_thread_order(messages)

    -- Show threaded index
    bbs.writeln("")
    bbs.writeln(bbs.ansi("bold") .. board.name .. bbs.ansi("reset"))
    bbs.writeln(string.rep("-", 60))
    for i, msg in ipairs(ordered) do
        local indent = string.rep("  ", msg._depth)
        local prefix = msg._depth > 0 and "\xC2\xBB " or ""   -- » for replies
        bbs.writeln(string.format("  [%2d] %s%s%s  (%s)",
            i, indent, prefix, msg.subject, msg.author or "?"))
    end
    bbs.writeln("")

    local choice = bbs.read_line("Read # (or Enter to cancel): ")
    local n = tonumber(choice)
    if not n or not ordered[n] then return end

    local msg = ordered[n]
    bbs.writeln(string.rep("-", 60))
    bbs.writeln("Subject: " .. msg.subject)
    bbs.writeln("From   : " .. (msg.author or "Unknown"))
    bbs.writeln(os.date("Date   : %Y-%m-%d %H:%M", msg.created_at))
    bbs.writeln(string.rep("-", 60))
    bbs.pager(msg.body)
    bbs.writeln("")
    bbs.writeln("  [R] Reply   [Q] Back")
    local key = bbs.read_key()
    if key and key:upper() == "R" then
        reply_to(board, msg)
    end
end

function reply_to(board, parent)
    local default_subject = parent.subject:match("^Re:") and parent.subject
                            or ("Re: " .. parent.subject)
    bbs.writeln("")
    local subject = bbs.read_line("Subject [" .. default_subject .. "]: ")
    if subject == nil then bbs.writeln("Cancelled.") return end
    if #subject == 0 then subject = default_subject end
    bbs.writeln("Body (end with a line containing only '.'):")
    local lines = {}
    while true do
        local line = bbs.read_line("")
        if line == "." or line == nil then break end
        table.insert(lines, line)
    end
    bbs.boards.post_reply(board.id, parent.id, subject, table.concat(lines, "\n"))
    bbs.writeln("Reply posted!")
end

local function search_messages()
    local query = bbs.read_line("Search: ")
    if not query or #query == 0 then return end
    local results = bbs.boards.search(query)
    if #results == 0 then
        bbs.writeln("No results for '" .. query .. "'.")
        return
    end
    bbs.writeln("")
    bbs.writeln(string.format("  %-3s  %-16s  %-28s  %s", "#", "Board", "Subject", "From"))
    bbs.writeln("  " .. string.rep("-", 60))
    for i, r in ipairs(results) do
        bbs.writeln(string.format("  [%2d] %-16s  %-28s  %s",
            i, r.board_name:sub(1,16), r.subject:sub(1,28), r.author))
    end
    bbs.writeln("")
    local choice = bbs.read_line("Read # (or Enter to cancel): ")
    local n = tonumber(choice)
    if not n or not results[n] then return end
    local r = results[n]
    bbs.writeln(string.rep("-", 60))
    bbs.writeln("Board  : " .. r.board_name)
    bbs.writeln("Subject: " .. r.subject)
    bbs.writeln("From   : " .. r.author)
    bbs.writeln(os.date("Date   : %Y-%m-%d %H:%M", r.created_at))
    bbs.writeln(string.rep("-", 60))
    bbs.pager(r.body)
end

local function post_message(board)
    bbs.writeln("")
    local subject = bbs.read_line("Subject: ")
    if not subject or #subject == 0 then
        bbs.writeln("Cancelled.")
        return
    end
    bbs.writeln("Body (end with a line containing only '.'):")
    local lines = {}
    while true do
        local line = bbs.read_line("")
        if line == "." or line == nil then break end
        table.insert(lines, line)
    end
    bbs.boards.post(board.id, subject, table.concat(lines, "\n"))
    bbs.writeln("Message posted!")
end

function M.run()
    local boards = list_boards()
    if not boards then return end

    bbs.writeln("  Select a board #, or [F] to search all boards.")
    bbs.writeln("")
    local choice = bbs.read_line("Choice: ")
    if not choice then return end
    if choice:upper() == "F" then
        search_messages()
        return
    end
    local n = tonumber(choice)
    if not n or not boards[n] then return end

    local board = boards[n]
    bbs.writeln("")
    bbs.writeln("  [R] Read   [P] Post   [F] Find   [Q] Back")
    local key = bbs.read_key()
    if key == nil then return end
    key = key:upper()

    if key == "R" then
        bbs.boards.mark_visited(board.id)
        read_board(board)
    elseif key == "P" then
        post_message(board)
    elseif key == "F" then
        search_messages()
    end
end

return M
