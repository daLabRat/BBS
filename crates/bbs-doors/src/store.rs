//! Persistent per-user per-door key-value store backed by SQLite.
//! Implements door.data.get(key) / door.data.set(key, value).

use anyhow::Result;
use sqlx::SqlitePool;

pub struct DoorStore {
    pool: SqlitePool,
    door_name: String,
    user_id: i64,
}

impl DoorStore {
    pub fn new(pool: SqlitePool, door_name: impl Into<String>, user_id: i64) -> Self {
        Self {
            pool,
            door_name: door_name.into(),
            user_id,
        }
    }

    pub async fn get(&self, key: &str) -> Result<Option<String>> {
        let row: Option<(String,)> = sqlx::query_as(
            "SELECT value FROM door_data WHERE door_name = ? AND user_id = ? AND key = ?",
        )
        .bind(&self.door_name)
        .bind(self.user_id)
        .bind(key)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|(v,)| v))
    }

    pub async fn set(&self, key: &str, value: &str) -> Result<()> {
        sqlx::query(
            "INSERT INTO door_data (door_name, user_id, key, value)
             VALUES (?, ?, ?, ?)
             ON CONFLICT (door_name, user_id, key) DO UPDATE SET value = excluded.value",
        )
        .bind(&self.door_name)
        .bind(self.user_id)
        .bind(key)
        .bind(value)
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}
