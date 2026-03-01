# Plan: Private Messaging (Mail)

## Context

The BBS has public message boards but no user-to-user communication. A private
mail system is a core BBS feature. The implementation follows the exact same
layering already used for boards: new DB migration → new `Database` methods in
`bbs-core` → `bbs.mail.*` Lua API in `bbs-runtime` → `scripts/mail.lua` module
→ new `[E]` entry in the main menu.

---

## Files to Create / Modify

| File | Change |
|---|---|
| `migrations/0002_mail.sql` | New `mail` table + indexes |
| `crates/bbs-core/src/db.rs` | Five new `Database` methods |
| `crates/bbs-runtime/src/api.rs` | Register `bbs.mail` sub-table |
| `scripts/mail.lua` | New Lua mail module (create) |
| `scripts/menu.lua` | Add `[E] Mail` item + handler |

---

## Phase 1 — `migrations/0002_mail.sql` (new file)

Separate table from `messages` to keep board queries untouched:

```sql
CREATE TABLE IF NOT EXISTS mail (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    sender_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipient_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    subject      TEXT    NOT NULL,
    body         TEXT    NOT NULL,
    sent_at      INTEGER NOT NULL DEFAULT (unixepoch()),
    read_at      INTEGER          -- NULL = unread
);

CREATE INDEX IF NOT EXISTS mail_recipient ON mail(recipient_id, sent_at);
CREATE INDEX IF NOT EXISTS mail_sender    ON mail(sender_id,    sent_at);
```

`read_at` is NULL when unread; set to `unixepoch()` on first open.

---

## Phase 2 — `crates/bbs-core/src/db.rs`

Add five methods to `impl Database`, following the `sqlx::query` + manual
row-mapping pattern used by `list_messages()`.

```rust
// ── Mail ─────────────────────────────────────────────────────────────────

/// Inbox for recipient_id, newest first.
/// Returns (id, sender_name, subject, sent_at, is_read, body).
pub async fn mail_inbox(
    &self, recipient_id: i64,
) -> Result<Vec<(i64, String, String, i64, bool, String)>> {
    let rows = sqlx::query(
        "SELECT m.id, u.username AS sender, m.subject, m.sent_at,
                m.read_at, m.body
         FROM mail m
         JOIN users u ON u.id = m.sender_id
         WHERE m.recipient_id = ?
         ORDER BY m.sent_at DESC",
    )
    .bind(recipient_id)
    .fetch_all(&self.pool).await?;
    Ok(rows.into_iter().map(|r| (
        r.get("id"),
        r.get::<String, _>("sender"),
        r.get::<String, _>("subject"),
        r.get::<i64, _>("sent_at"),
        r.get::<Option<i64>, _>("read_at").is_some(),
        r.get::<String, _>("body"),
    )).collect())
}

/// Sent items for sender_id, newest first.
/// Returns (id, recipient_name, subject, sent_at).
pub async fn mail_sent(
    &self, sender_id: i64,
) -> Result<Vec<(i64, String, String, i64)>> {
    let rows = sqlx::query(
        "SELECT m.id, u.username AS recipient, m.subject, m.sent_at
         FROM mail m
         JOIN users u ON u.id = m.recipient_id
         WHERE m.sender_id = ?
         ORDER BY m.sent_at DESC",
    )
    .bind(sender_id)
    .fetch_all(&self.pool).await?;
    Ok(rows.into_iter().map(|r| (
        r.get("id"),
        r.get::<String, _>("recipient"),
        r.get::<String, _>("subject"),
        r.get::<i64, _>("sent_at"),
    )).collect())
}

/// Send a mail message; returns new id.
pub async fn mail_send(
    &self, sender_id: i64, recipient_id: i64, subject: &str, body: &str,
) -> Result<i64> {
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO mail (sender_id, recipient_id, subject, body)
         VALUES (?, ?, ?, ?) RETURNING id",
    )
    .bind(sender_id).bind(recipient_id).bind(subject).bind(body)
    .fetch_one(&self.pool).await?;
    Ok(id)
}

/// Mark a mail item as read (no-op if already read; checks recipient ownership).
pub async fn mail_mark_read(&self, mail_id: i64, reader_id: i64) -> Result<()> {
    sqlx::query(
        "UPDATE mail SET read_at = unixepoch()
         WHERE id = ? AND recipient_id = ? AND read_at IS NULL",
    )
    .bind(mail_id).bind(reader_id)
    .execute(&self.pool).await?;
    Ok(())
}

/// Count unread mail for a user.
pub async fn mail_unread_count(&self, recipient_id: i64) -> Result<i64> {
    let n: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM mail WHERE recipient_id = ? AND read_at IS NULL",
    )
    .bind(recipient_id)
    .fetch_one(&self.pool).await?;
    Ok(n)
}
```

---

## Phase 3 — `crates/bbs-runtime/src/api.rs`

Add a `// --- bbs.mail ---` block before the final `lua.globals().set("bbs", bbs)?;`.
Pattern is identical to the existing `bbs.boards` block.

```rust
// --- bbs.mail ---
{
    let db = Arc::clone(&config.db);
    let mail_tbl = lua.create_table()?;

    // bbs.mail.unread() -> integer
    // bbs.mail.inbox()  -> [{id, from, subject, sent_at, read, body}]
    // bbs.mail.sent()   -> [{id, to, subject, sent_at}]
    // bbs.mail.send(to_name, subject, body) -> true | nil, errmsg
    // bbs.mail.mark_read(id) -> nil

    // All functions get current user id via:
    //   let bbs_tbl: LuaTable = lua.globals().get("bbs")?;
    //   let user_tbl: LuaTable = bbs_tbl.get("user")?;
    //   let my_id: i64 = user_tbl.get("id")?;

    bbs.set("mail", mail_tbl)?;
}
```

`bbs.mail.send` resolves the recipient with the existing
`db.find_user_by_username()`, returns `(nil, "No such user")` on failure via
mlua multi-return `Ok((LuaValue::Nil, LuaValue::String(...)))`.

---

## Phase 4 — `scripts/mail.lua` (new file)

```lua
local M = {}

local function show_inbox()
    local msgs = bbs.mail.inbox()
    if #msgs == 0 then bbs.writeln("  (empty)") return end
    for i, m in ipairs(msgs) do
        local flag = m.read and " " or "*"
        bbs.writeln(string.format("  [%2d]%s From: %-16s  %s", i, flag, m.from, m.subject))
    end
    bbs.writeln("")
    local choice = bbs.read_line("Read # (or Enter to cancel): ")
    local n = tonumber(choice)
    if not n or not msgs[n] then return end
    local m = msgs[n]
    bbs.writeln(string.rep("-", 60))
    bbs.writeln("From   : " .. m.from)
    bbs.writeln("Subject: " .. m.subject)
    bbs.writeln(os.date("Date   : %Y-%m-%d %H:%M", m.sent_at))
    bbs.writeln(string.rep("-", 60))
    bbs.pager(m.body)
    bbs.mail.mark_read(m.id)
end

local function show_sent()
    local msgs = bbs.mail.sent()
    if #msgs == 0 then bbs.writeln("  (empty)") return end
    for i, m in ipairs(msgs) do
        bbs.writeln(string.format("  [%2d] To: %-16s  %s", i, m.to, m.subject))
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
    if ok then bbs.writeln("Message sent!")
    else bbs.writeln("Error: " .. (err or "unknown")) end
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
    if     key == "I" then show_inbox()
    elseif key == "S" then show_sent()
    elseif key == "C" then compose()
    end
end

return M
```

---

## Phase 5 — `scripts/menu.lua`

1. Add `local mail = require("mail")` at the top with the other requires.
2. Add menu item (between `[D]` Doors and `[S]` System info):
   ```lua
   { key = "E", label = "E-mail / Mail", action = "mail" },
   ```
3. Add case in `M.run()` switch:
   ```lua
   elseif key == "E" then
       mail.run()
   ```

---

## Verification

```bash
cargo build
cargo clippy --all -- -D warnings

DATABASE_URL=sqlite:bbs.db sqlx migrate run
cargo run -p bbs-server

# 1. Log in as user A -> [E] -> [C] compose -> send to user B
# 2. Log in as user B -> [E] -> should show "1 unread message"
# 3. [I] inbox -> * flag on unread, open it -> mark read, flag clears
# 4. Back to user A -> [E] -> [S] sent folder shows the message
```
