use anyhow::Result;
use sqlx::{sqlite::SqlitePoolOptions, SqlitePool};

#[derive(Clone, Debug)]
pub struct Database {
    pub pool: SqlitePool,
}

impl Database {
    pub async fn connect(url: &str) -> Result<Self> {
        let pool = SqlitePoolOptions::new()
            .max_connections(5)
            .connect(url)
            .await?;
        Ok(Self { pool })
    }

    pub async fn migrate(&self) -> Result<()> {
        sqlx::migrate!("../../migrations").run(&self.pool).await?;
        Ok(())
    }
}
