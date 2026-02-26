use anyhow::Result;
use sqlx::{
    sqlite::{SqliteConnectOptions, SqlitePoolOptions},
    Row, SqlitePool,
};
use std::str::FromStr;

use crate::{Board, Message, User};

#[derive(Clone, Debug)]
pub struct Database {
    pub pool: SqlitePool,
}

impl Database {
    pub async fn connect(url: &str) -> Result<Self> {
        let opts = SqliteConnectOptions::from_str(url)?.create_if_missing(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(5)
            .connect_with(opts)
            .await?;
        Ok(Self { pool })
    }

    pub async fn migrate(&self) -> Result<()> {
        sqlx::migrate!("../../migrations").run(&self.pool).await?;
        Ok(())
    }

    // ── Users ────────────────────────────────────────────────────────────────

    pub async fn find_user_by_username(&self, username: &str) -> Result<Option<User>> {
        let user = sqlx::query_as::<_, User>(
            "SELECT id, username, password_hash, is_sysop, banned, created_at, last_login
             FROM users WHERE username = ?",
        )
        .bind(username)
        .fetch_optional(&self.pool)
        .await?;
        Ok(user)
    }

    pub async fn find_user_by_id(&self, id: i64) -> Result<Option<User>> {
        let user = sqlx::query_as::<_, User>(
            "SELECT id, username, password_hash, is_sysop, banned, created_at, last_login
             FROM users WHERE id = ?",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(user)
    }

    pub async fn create_user(&self, username: &str, password_hash: &str) -> Result<User> {
        let id: i64 = sqlx::query_scalar(
            "INSERT INTO users (username, password_hash) VALUES (?, ?) RETURNING id",
        )
        .bind(username)
        .bind(password_hash)
        .fetch_one(&self.pool)
        .await?;

        self.find_user_by_id(id)
            .await?
            .ok_or_else(|| anyhow::anyhow!("user not found after insert"))
    }

    pub async fn update_last_login(&self, id: i64) -> Result<()> {
        sqlx::query("UPDATE users SET last_login = unixepoch() WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // ── Boards ───────────────────────────────────────────────────────────────

    pub async fn list_boards(&self) -> Result<Vec<Board>> {
        let boards = sqlx::query_as::<_, Board>(
            "SELECT id, name, description, newsgroup_name FROM boards ORDER BY id",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(boards)
    }

    pub async fn list_boards_with_newsgroups(&self) -> Result<Vec<Board>> {
        let boards = sqlx::query_as::<_, Board>(
            "SELECT id, name, description, newsgroup_name
             FROM boards WHERE newsgroup_name IS NOT NULL ORDER BY id",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(boards)
    }

    pub async fn find_board_by_newsgroup(&self, newsgroup: &str) -> Result<Option<Board>> {
        let board = sqlx::query_as::<_, Board>(
            "SELECT id, name, description, newsgroup_name
             FROM boards WHERE newsgroup_name = ? LIMIT 1",
        )
        .bind(newsgroup)
        .fetch_optional(&self.pool)
        .await?;
        Ok(board)
    }

    // ── Messages ─────────────────────────────────────────────────────────────

    pub async fn list_messages(&self, board_id: i64) -> Result<Vec<(Message, String)>> {
        let rows = sqlx::query(
            "SELECT m.id, m.board_id, m.author_id, m.subject, m.body,
                    m.created_at, m.parent_id, u.username
             FROM messages m
             JOIN users u ON u.id = m.author_id
             WHERE m.board_id = ?
             ORDER BY m.created_at",
        )
        .bind(board_id)
        .fetch_all(&self.pool)
        .await?;

        let result = rows
            .into_iter()
            .map(|row| {
                let msg = Message {
                    id: row.get("id"),
                    board_id: row.get("board_id"),
                    author_id: row.get("author_id"),
                    subject: row.get("subject"),
                    body: row.get("body"),
                    created_at: row.get("created_at"),
                    parent_id: row.get("parent_id"),
                };
                let author: String = row.get("username");
                (msg, author)
            })
            .collect();

        Ok(result)
    }

    pub async fn list_messages_range(
        &self,
        board_id: i64,
        from_id: i64,
        to_id: i64,
    ) -> Result<Vec<(Message, String)>> {
        let rows = sqlx::query(
            "SELECT m.id, m.board_id, m.author_id, m.subject, m.body,
                    m.created_at, m.parent_id, u.username
             FROM messages m
             JOIN users u ON u.id = m.author_id
             WHERE m.board_id = ? AND m.id >= ? AND m.id <= ?
             ORDER BY m.id",
        )
        .bind(board_id)
        .bind(from_id)
        .bind(to_id)
        .fetch_all(&self.pool)
        .await?;

        let result = rows
            .into_iter()
            .map(|row| {
                let msg = Message {
                    id: row.get("id"),
                    board_id: row.get("board_id"),
                    author_id: row.get("author_id"),
                    subject: row.get("subject"),
                    body: row.get("body"),
                    created_at: row.get("created_at"),
                    parent_id: row.get("parent_id"),
                };
                let author: String = row.get("username");
                (msg, author)
            })
            .collect();

        Ok(result)
    }

    pub async fn find_message_by_id(&self, id: i64) -> Result<Option<(Message, String)>> {
        let row = sqlx::query(
            "SELECT m.id, m.board_id, m.author_id, m.subject, m.body,
                    m.created_at, m.parent_id, u.username
             FROM messages m
             JOIN users u ON u.id = m.author_id
             WHERE m.id = ?",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;

        Ok(row.map(|row| {
            let msg = Message {
                id: row.get("id"),
                board_id: row.get("board_id"),
                author_id: row.get("author_id"),
                subject: row.get("subject"),
                body: row.get("body"),
                created_at: row.get("created_at"),
                parent_id: row.get("parent_id"),
            };
            let author: String = row.get("username");
            (msg, author)
        }))
    }

    pub async fn count_messages(&self, board_id: i64) -> Result<i64> {
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM messages WHERE board_id = ?")
            .bind(board_id)
            .fetch_one(&self.pool)
            .await?;
        Ok(count)
    }

    pub async fn first_message_id(&self, board_id: i64) -> Result<Option<i64>> {
        let id: Option<i64> = sqlx::query_scalar("SELECT MIN(id) FROM messages WHERE board_id = ?")
            .bind(board_id)
            .fetch_one(&self.pool)
            .await?;
        Ok(id)
    }

    pub async fn last_message_id(&self, board_id: i64) -> Result<Option<i64>> {
        let id: Option<i64> = sqlx::query_scalar("SELECT MAX(id) FROM messages WHERE board_id = ?")
            .bind(board_id)
            .fetch_one(&self.pool)
            .await?;
        Ok(id)
    }

    pub async fn post_message(
        &self,
        board_id: i64,
        author_id: i64,
        subject: &str,
        body: &str,
    ) -> Result<i64> {
        let id: i64 = sqlx::query_scalar(
            "INSERT INTO messages (board_id, author_id, subject, body) VALUES (?, ?, ?, ?)
             RETURNING id",
        )
        .bind(board_id)
        .bind(author_id)
        .bind(subject)
        .bind(body)
        .fetch_one(&self.pool)
        .await?;
        Ok(id)
    }

    pub async fn post_reply(
        &self,
        board_id: i64,
        parent_id: i64,
        author_id: i64,
        subject: &str,
        body: &str,
    ) -> Result<i64> {
        let id: i64 = sqlx::query_scalar(
            "INSERT INTO messages (board_id, parent_id, author_id, subject, body)
             VALUES (?, ?, ?, ?, ?) RETURNING id",
        )
        .bind(board_id)
        .bind(parent_id)
        .bind(author_id)
        .bind(subject)
        .bind(body)
        .fetch_one(&self.pool)
        .await?;
        Ok(id)
    }

    // ── Mail ─────────────────────────────────────────────────────────────────

    /// Inbox for recipient_id, newest first.
    /// Returns (id, sender_name, subject, sent_at, is_read, body).
    pub async fn mail_inbox(
        &self,
        recipient_id: i64,
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
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| {
                (
                    r.get("id"),
                    r.get::<String, _>("sender"),
                    r.get::<String, _>("subject"),
                    r.get::<i64, _>("sent_at"),
                    r.get::<Option<i64>, _>("read_at").is_some(),
                    r.get::<String, _>("body"),
                )
            })
            .collect())
    }

    /// Sent items for sender_id, newest first.
    /// Returns (id, recipient_name, subject, sent_at).
    pub async fn mail_sent(
        &self,
        sender_id: i64,
    ) -> Result<Vec<(i64, String, String, i64)>> {
        let rows = sqlx::query(
            "SELECT m.id, u.username AS recipient, m.subject, m.sent_at
             FROM mail m
             JOIN users u ON u.id = m.recipient_id
             WHERE m.sender_id = ?
             ORDER BY m.sent_at DESC",
        )
        .bind(sender_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| {
                (
                    r.get("id"),
                    r.get::<String, _>("recipient"),
                    r.get::<String, _>("subject"),
                    r.get::<i64, _>("sent_at"),
                )
            })
            .collect())
    }

    /// Send a mail message; returns new id.
    pub async fn mail_send(
        &self,
        sender_id: i64,
        recipient_id: i64,
        subject: &str,
        body: &str,
    ) -> Result<i64> {
        let id: i64 = sqlx::query_scalar(
            "INSERT INTO mail (sender_id, recipient_id, subject, body)
             VALUES (?, ?, ?, ?) RETURNING id",
        )
        .bind(sender_id)
        .bind(recipient_id)
        .bind(subject)
        .bind(body)
        .fetch_one(&self.pool)
        .await?;
        Ok(id)
    }

    /// Mark a mail item as read (no-op if already read; checks recipient ownership).
    pub async fn mail_mark_read(&self, mail_id: i64, reader_id: i64) -> Result<()> {
        sqlx::query(
            "UPDATE mail SET read_at = unixepoch()
             WHERE id = ? AND recipient_id = ? AND read_at IS NULL",
        )
        .bind(mail_id)
        .bind(reader_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Count unread mail for a user.
    pub async fn mail_unread_count(&self, recipient_id: i64) -> Result<i64> {
        let n: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM mail WHERE recipient_id = ? AND read_at IS NULL",
        )
        .bind(recipient_id)
        .fetch_one(&self.pool)
        .await?;
        Ok(n)
    }

    // ── Bulletins ─────────────────────────────────────────────────────────────

    /// All active bulletins, newest first.
    /// Returns (id, author_name, title, posted_at).
    pub async fn list_bulletins(&self) -> Result<Vec<(i64, String, String, i64)>> {
        let rows = sqlx::query(
            "SELECT b.id, u.username AS author, b.title, b.posted_at
             FROM bulletins b
             JOIN users u ON u.id = b.author_id
             WHERE b.is_active = 1
             ORDER BY b.posted_at DESC",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| {
                (
                    r.get("id"),
                    r.get::<String, _>("author"),
                    r.get::<String, _>("title"),
                    r.get::<i64, _>("posted_at"),
                )
            })
            .collect())
    }

    /// Fetch a single bulletin by id (active or not).
    /// Returns (id, author_name, title, body, posted_at).
    pub async fn get_bulletin(&self, id: i64) -> Result<Option<(i64, String, String, String, i64)>> {
        let row = sqlx::query(
            "SELECT b.id, u.username AS author, b.title, b.body, b.posted_at
             FROM bulletins b
             JOIN users u ON u.id = b.author_id
             WHERE b.id = ?",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| {
            (
                r.get("id"),
                r.get::<String, _>("author"),
                r.get::<String, _>("title"),
                r.get::<String, _>("body"),
                r.get::<i64, _>("posted_at"),
            )
        }))
    }

    /// Post a new bulletin; returns new id.
    pub async fn post_bulletin(&self, author_id: i64, title: &str, body: &str) -> Result<i64> {
        let id: i64 = sqlx::query_scalar(
            "INSERT INTO bulletins (author_id, title, body) VALUES (?, ?, ?) RETURNING id",
        )
        .bind(author_id)
        .bind(title)
        .bind(body)
        .fetch_one(&self.pool)
        .await?;
        Ok(id)
    }

    /// Soft-delete a bulletin (sets is_active = 0).
    pub async fn delete_bulletin(&self, id: i64) -> Result<()> {
        sqlx::query("UPDATE bulletins SET is_active = 0 WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // ── Search ────────────────────────────────────────────────────────────────

    /// Full-text search across message subjects and bodies, newest first.
    /// Returns (Message, board_name, author_name).  Capped at 50 results.
    pub async fn search_messages(
        &self,
        query: &str,
    ) -> Result<Vec<(Message, String, String)>> {
        let pattern = format!("%{query}%");
        let rows = sqlx::query(
            "SELECT m.id, m.board_id, m.author_id, m.subject, m.body,
                    m.created_at, m.parent_id, u.username, b.name AS board_name
             FROM messages m
             JOIN users  u ON u.id = m.author_id
             JOIN boards b ON b.id = m.board_id
             WHERE m.subject LIKE ? OR m.body LIKE ?
             ORDER BY m.created_at DESC
             LIMIT 50",
        )
        .bind(&pattern)
        .bind(&pattern)
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|row| {
                let msg = Message {
                    id: row.get("id"),
                    board_id: row.get("board_id"),
                    author_id: row.get("author_id"),
                    subject: row.get("subject"),
                    body: row.get("body"),
                    created_at: row.get("created_at"),
                    parent_id: row.get("parent_id"),
                };
                let board_name: String = row.get("board_name");
                let author: String = row.get("username");
                (msg, board_name, author)
            })
            .collect())
    }

    // ── Board management ──────────────────────────────────────────────────────

    pub async fn create_board(&self, name: &str, description: &str) -> Result<i64> {
        let id: i64 = sqlx::query_scalar(
            "INSERT INTO boards (name, description) VALUES (?, ?) RETURNING id",
        )
        .bind(name)
        .bind(description)
        .fetch_one(&self.pool)
        .await?;
        Ok(id)
    }

    /// Hard-delete a board and all its messages (ON DELETE CASCADE).
    pub async fn delete_board(&self, id: i64) -> Result<()> {
        sqlx::query("DELETE FROM boards WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // ── Sysop ─────────────────────────────────────────────────────────────────

    /// All users, ordered by id.
    /// Returns (id, username, is_sysop, banned, created_at, last_login).
    pub async fn list_users(&self) -> Result<Vec<(i64, String, bool, bool, i64, Option<i64>)>> {
        let rows = sqlx::query(
            "SELECT id, username, is_sysop, banned, created_at, last_login
             FROM users ORDER BY id",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| {
                (
                    r.get::<i64, _>("id"),
                    r.get::<String, _>("username"),
                    r.get::<bool, _>("is_sysop"),
                    r.get::<bool, _>("banned"),
                    r.get::<i64, _>("created_at"),
                    r.get::<Option<i64>, _>("last_login"),
                )
            })
            .collect())
    }

    /// Set the is_sysop flag for a user.
    pub async fn set_sysop(&self, user_id: i64, is_sysop: bool) -> Result<()> {
        sqlx::query("UPDATE users SET is_sysop = ? WHERE id = ?")
            .bind(is_sysop)
            .bind(user_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Set the banned flag for a user.
    pub async fn set_banned(&self, user_id: i64, banned: bool) -> Result<()> {
        sqlx::query("UPDATE users SET banned = ? WHERE id = ?")
            .bind(banned)
            .bind(user_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // ── Profile ───────────────────────────────────────────────────────────────

    /// Stats for a user: (created_at, last_login, post_count, mail_sent, mail_received).
    pub async fn user_stats(&self, user_id: i64) -> Result<(i64, Option<i64>, i64, i64, i64)> {
        let row = sqlx::query(
            "SELECT u.created_at, u.last_login,
                    (SELECT COUNT(*) FROM messages  WHERE author_id    = u.id) AS post_count,
                    (SELECT COUNT(*) FROM mail      WHERE sender_id    = u.id) AS mail_sent,
                    (SELECT COUNT(*) FROM mail      WHERE recipient_id = u.id) AS mail_received
             FROM users u WHERE u.id = ?",
        )
        .bind(user_id)
        .fetch_one(&self.pool)
        .await?;
        Ok((
            row.get::<i64, _>("created_at"),
            row.get::<Option<i64>, _>("last_login"),
            row.get::<i64, _>("post_count"),
            row.get::<i64, _>("mail_sent"),
            row.get::<i64, _>("mail_received"),
        ))
    }

    /// Update a user's password hash.
    pub async fn change_password(&self, user_id: i64, new_hash: &str) -> Result<()> {
        sqlx::query("UPDATE users SET password_hash = ? WHERE id = ?")
            .bind(new_hash)
            .bind(user_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // ── Callers ───────────────────────────────────────────────────────────────

    /// Most recent callers, newest first.
    /// Returns (username, last_login unix timestamp).
    pub async fn last_callers(&self, limit: i64) -> Result<Vec<(String, i64)>> {
        let rows = sqlx::query(
            "SELECT username, last_login FROM users
             WHERE last_login IS NOT NULL
             ORDER BY last_login DESC
             LIMIT ?",
        )
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| (r.get::<String, _>("username"), r.get::<i64, _>("last_login")))
            .collect())
    }
}
