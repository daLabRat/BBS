-- lib/messages.lua — inter-empire messaging (private and public broadcasts).
local M = {}

-- Send a message. recipient_ids: list of empire IDs, or empty for public.
-- is_public: if true, all active empires receive it.
-- anonymous: sender recorded as NULL.
function M.send(sender_empire, recipient_ids, subject, body, is_public, anonymous)
    local from_id = anonymous and nil or sender_empire.id

    door.db.execute([[
        INSERT INTO door_sre_messages (from_empire, subject, body, is_public)
        VALUES (?, ?, ?, ?)
    ]], { from_id, subject or "(no subject)", body, is_public and 1 or 0 })

    -- Get the message id
    local rows = door.db.query(
        "SELECT MAX(id) as id FROM door_sre_messages", {})
    local msg_id = rows[1] and rows[1].id
    if not msg_id then return end

    -- Determine recipients
    local targets = {}
    if is_public then
        local all = door.db.query(
            "SELECT id FROM door_sre_empires WHERE is_active=1", {})
        for _, r in ipairs(all) do table.insert(targets, r.id) end
    else
        targets = recipient_ids
    end

    for _, eid in ipairs(targets) do
        door.db.execute([[
            INSERT INTO door_sre_message_recipients (message_id, empire_id)
            VALUES (?, ?)
        ]], { msg_id, eid })
    end
end

-- Get unread messages for an empire. Returns list ordered by sent_at ASC.
function M.inbox(empire_id)
    return door.db.query([[
        SELECT m.id, m.subject, m.body, m.sent_at, m.is_public,
               e.letter as from_letter, e.name as from_name
        FROM door_sre_messages m
        JOIN door_sre_message_recipients r ON r.message_id = m.id
        LEFT JOIN door_sre_empires e ON e.id = m.from_empire
        WHERE r.empire_id = ? AND r.read_at IS NULL
        ORDER BY m.sent_at ASC
    ]], { empire_id })
end

-- Mark a message as read for this empire.
function M.mark_read(empire_id, message_id)
    door.db.execute([[
        UPDATE door_sre_message_recipients
        SET read_at = ?
        WHERE empire_id = ? AND message_id = ?
    ]], { door.time(), empire_id, message_id })
end

-- Mark all messages read for this empire.
function M.mark_all_read(empire_id)
    door.db.execute([[
        UPDATE door_sre_message_recipients
        SET read_at = ?
        WHERE empire_id = ? AND read_at IS NULL
    ]], { door.time(), empire_id })
end

-- Show messages paged through ui.pager.
function M.show_inbox(empire_id, ui)
    local msgs = M.inbox(empire_id)
    if #msgs == 0 then
        ui.WL(ui.CYN.."  No new messages."..ui.RST)
        ui.pause()
        return
    end
    for _, msg in ipairs(msgs) do
        local from = msg.from_letter
            and string.format("Empire %s (%s)", msg.from_letter, msg.from_name)
            or  "Anonymous"
        local hdr = string.format(
            "From: %s\nSubject: %s\n%s\n",
            from, msg.subject, string.rep("-", 40))
        ui.pager(hdr .. msg.body)
        M.mark_read(empire_id, msg.id)
    end
end

-- Compose UI: prompt for recipients and body, then send.
-- Returns nil on success or error string.
function M.compose(sender, ui)
    ui.header("Send Message")
    ui.WL("  Enter empire letters to send to (e.g. ABC), or * for all, or blank to cancel.")
    local dest = ui.INPUT("  To: ")
    if not dest or dest == "" then return nil end

    local is_public = dest == "*"
    local recipient_ids = {}
    if not is_public then
        for c in dest:upper():gmatch("%u") do
            local target = door.db.query(
                "SELECT id FROM door_sre_empires WHERE letter=? AND is_active=1", { c })
            if target[1] then
                table.insert(recipient_ids, target[1].id)
            end
        end
        if #recipient_ids == 0 then return "No valid recipients found." end
    end

    local subject = ui.INPUT("  Subject: ")
    if not subject or subject == "" then subject = "(no subject)" end

    ui.WL("  Message body (enter /S on a blank line to send):")
    local lines = {}
    while true do
        local line = ui.INPUT("  ")
        if not line then break end
        if line:upper() == "/S" then break end
        table.insert(lines, line)
        if #lines >= 99 then break end
    end
    local body = table.concat(lines, "\n")

    local anon_ans = ui.INPUT("  Send anonymously? [y/N] ")
    local anonymous = anon_ans and anon_ans:upper() == "Y"

    M.send(sender, recipient_ids, subject, body, is_public, anonymous)
    ui.WL(ui.GRN.."  Message sent."..ui.RST)
    ui.pause()
    return nil
end

return M
