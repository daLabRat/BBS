-- boards.lua: Message board reader/poster.

local M = {}

local function list_boards()
    local boards = bbs.boards.list()
    if #boards == 0 then
        bbs.writeln("No boards available.")
        return nil
    end
    bbs.writeln("")
    bbs.writeln("Message Boards:")
    for i, b in ipairs(boards) do
        bbs.writeln(string.format("  [%d] %-20s %s", i, b.name, b.description))
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
    bbs.writeln("")
    bbs.writeln(bbs.ansi("bold") .. board.name .. bbs.ansi("reset"))
    bbs.writeln(string.rep("-", 60))
    for _, msg in ipairs(messages) do
        bbs.writeln(string.format("[%d] %s", msg.id, msg.subject))
        bbs.writeln("    From: " .. (msg.author or "Unknown"))
        bbs.writeln("")
        bbs.pager(msg.body)
        bbs.writeln(string.rep("-", 60))
    end
end

local function post_message(board)
    bbs.writeln("")
    local subject = bbs.read_line("Subject: ")
    if not subject or #subject == 0 then
        bbs.writeln("Cancelled.")
        return
    end
    bbs.writeln("Body (end with a line containing only '.'): ")
    local lines = {}
    while true do
        local line = bbs.read_line("")
        if line == "." then break end
        if line == nil then break end
        table.insert(lines, line)
    end
    local body = table.concat(lines, "\n")
    bbs.boards.post(board.id, subject, body)
    bbs.writeln("Message posted!")
end

function M.run()
    local boards = list_boards()
    if not boards then return end

    local choice = bbs.read_line("Select board (or Enter to cancel): ")
    local n = tonumber(choice)
    if not n or not boards[n] then return end

    local board = boards[n]
    bbs.writeln("")
    bbs.writeln("[R]ead messages  [P]ost  [Q]uit")
    local key = bbs.read_key()
    if key == nil then return end
    key = key:upper()

    if key == "R" then
        read_board(board)
    elseif key == "P" then
        post_message(board)
    end
end

return M
