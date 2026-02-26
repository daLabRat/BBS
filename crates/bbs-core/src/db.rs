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
            "SELECT id, username, password_hash, is_sysop, created_at, last_login
             FROM users WHERE username = ?",
        )
        .bind(username)
        .fetch_optional(&self.pool)
        .await?;
        Ok(user)
    }

    pub async fn find_user_by_id(&self, id: i64) -> Result<Option<User>> {
        let user = sqlx::query_as::<_, User>(
            "SELECT id, username, password_hash, is_sysop, created_at, last_login
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
}
