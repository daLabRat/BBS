//! Shared per-door SQL access backed by the BBS SQLite database.
//! Implements door.db.query(sql, params) / door.db.execute(sql, params).
//! Enforces that all table names in SQL start with `door_<doorname>_`.

use anyhow::{bail, Result};
use sqlx::sqlite::{SqliteArguments, SqliteRow};
use sqlx::{Arguments, Column, Row, SqlitePool};
use std::collections::HashMap;

pub struct DoorDb {
    pub(crate) pool: SqlitePool,
    pub(crate) door_name: String,
}

impl DoorDb {
    pub fn new(pool: SqlitePool, door_name: impl Into<String>) -> Self {
        Self { pool, door_name: door_name.into() }
    }

    /// Required prefix for all table names.
    fn prefix(&self) -> String {
        format!("door_{}_", self.door_name)
    }

    /// Parse SQL words and reject any table name that doesn't start with our prefix.
    pub fn check_prefix(&self, sql: &str) -> Result<()> {
        let prefix = self.prefix();
        let words: Vec<&str> = sql.split_ascii_whitespace().collect();
        let mut i = 0;
        while i < words.len() {
            let up = words[i].to_uppercase();
            let keyword = up.trim_end_matches(['(', ';']);
            // "DO UPDATE SET" is upsert syntax — UPDATE here is not followed by a table name.
            let prev_up = i.checked_sub(1).and_then(|p| words.get(p)).map(|w| w.to_uppercase());
            let is_do_update = keyword == "UPDATE" && prev_up.as_deref() == Some("DO");
            if !is_do_update && matches!(keyword, "FROM" | "JOIN" | "INTO" | "UPDATE" | "TABLE") {
                // Skip qualifiers: IF NOT EXISTS, OR IGNORE, etc.
                let mut j = i + 1;
                while j < words.len() {
                    let w = words[j].to_uppercase();
                    if matches!(w.as_str(), "IF" | "NOT" | "EXISTS" | "OR" | "IGNORE" | "REPLACE") {
                        j += 1;
                    } else {
                        break;
                    }
                }
                if let Some(table) = words.get(j) {
                    let table = table.trim_matches(|c: char| !c.is_alphanumeric() && c != '_');
                    if !table.is_empty() && !table.to_lowercase().starts_with(&prefix) {
                        bail!(
                            "door.db: table '{}' not allowed — must start with '{}'",
                            table, prefix
                        );
                    }
                }
            }
            i += 1;
        }
        Ok(())
    }

    /// Execute INSERT/UPDATE/DELETE. Returns rows affected.
    pub async fn execute(&self, sql: &str, params: Vec<DbValue>) -> Result<u64> {
        self.check_prefix(sql)?;
        let mut args = SqliteArguments::default();
        for p in &params {
            match p {
                DbValue::Int(i)  => args.add(*i),
                DbValue::Real(f) => args.add(*f),
                DbValue::Text(s) => args.add(s.as_str()),
                DbValue::Null    => args.add(Option::<String>::None),
            }
        }
        let result = sqlx::query_with(sql, args).execute(&self.pool).await?;
        Ok(result.rows_affected())
    }

    /// Execute SELECT. Returns rows as Vec<HashMap<column, DbValue>>.
    pub async fn query(&self, sql: &str, params: Vec<DbValue>) -> Result<Vec<HashMap<String, DbValue>>> {
        self.check_prefix(sql)?;
        let mut args = SqliteArguments::default();
        for p in &params {
            match p {
                DbValue::Int(i)  => args.add(*i),
                DbValue::Real(f) => args.add(*f),
                DbValue::Text(s) => args.add(s.as_str()),
                DbValue::Null    => args.add(Option::<String>::None),
            }
        }
        let rows: Vec<SqliteRow> = sqlx::query_with(sql, args).fetch_all(&self.pool).await?;
        let mut out = Vec::with_capacity(rows.len());
        for row in &rows {
            let mut map = HashMap::new();
            for col in row.columns() {
                let name = col.name().to_string();
                let val = if let Ok(v) = row.try_get::<i64, _>(col.ordinal()) {
                    DbValue::Int(v)
                } else if let Ok(v) = row.try_get::<f64, _>(col.ordinal()) {
                    DbValue::Real(v)
                } else if let Ok(v) = row.try_get::<Option<String>, _>(col.ordinal()) {
                    match v { Some(s) => DbValue::Text(s), None => DbValue::Null }
                } else {
                    DbValue::Null
                };
                map.insert(name, val);
            }
            out.push(map);
        }
        Ok(out)
    }

    /// Run a schema.sql file — splits on ';' and executes each statement.
    pub async fn run_schema(&self, sql: &str) -> Result<()> {
        for stmt in sql.split(';') {
            let stmt = stmt.trim();
            if stmt.is_empty() { continue; }
            self.check_prefix(stmt)?;
            sqlx::query(stmt).execute(&self.pool).await?;
        }
        Ok(())
    }
}

/// A SQL parameter or column value.
#[derive(Debug, Clone)]
pub enum DbValue {
    Int(i64),
    Real(f64),
    Text(String),
    Null,
}

#[cfg(test)]
mod tests {
    use super::*;
    use sqlx::SqlitePool;

    async fn make_db(door: &str) -> DoorDb {
        let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
        DoorDb::new(pool, door)
    }

    #[tokio::test]
    async fn test_prefix_ok() {
        let db = make_db("sre").await;
        assert!(db.check_prefix("SELECT * FROM door_sre_empires").is_ok());
        assert!(db.check_prefix(
            "CREATE TABLE IF NOT EXISTS door_sre_empires (id INTEGER PRIMARY KEY)"
        ).is_ok());
    }

    #[tokio::test]
    async fn test_prefix_rejected() {
        let db = make_db("sre").await;
        assert!(db.check_prefix("SELECT * FROM users").is_err());
        assert!(db.check_prefix("DROP TABLE door_other_stuff").is_err());
    }

    #[tokio::test]
    async fn test_on_conflict_do_update_set() {
        let db = make_db("sre").await;
        // "DO UPDATE SET" must not trigger table-name check on "SET"
        assert!(db.check_prefix(
            "INSERT INTO door_sre_galaxy (key, value) VALUES (?, ?) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        ).is_ok());
    }

    #[tokio::test]
    async fn test_execute_and_query() {
        let db = make_db("sre").await;
        db.run_schema(
            "CREATE TABLE IF NOT EXISTS door_sre_test (id INTEGER PRIMARY KEY, name TEXT)"
        ).await.unwrap();

        db.execute(
            "INSERT INTO door_sre_test (id, name) VALUES (?, ?)",
            vec![DbValue::Int(1), DbValue::Text("hello".into())],
        ).await.unwrap();

        let rows = db.query(
            "SELECT id, name FROM door_sre_test WHERE id = ?",
            vec![DbValue::Int(1)],
        ).await.unwrap();

        assert_eq!(rows.len(), 1);
        assert!(matches!(rows[0]["id"], DbValue::Int(1)));
        assert!(matches!(&rows[0]["name"], DbValue::Text(s) if s == "hello"));
    }
}
