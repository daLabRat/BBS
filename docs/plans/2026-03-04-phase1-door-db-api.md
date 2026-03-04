# Phase 1: `door.db.*` Rust API — Implementation Plan

> **For Claude:** Use superpowers:executing-plans to implement task-by-task.

**Goal:** Add `door.db.query/execute` to `bbs-doors`, auto-run `schema.sql` per door, and configure Lua `require()` support.

**Architecture:** New `DoorDb` struct in `crates/bbs-doors/src/db.rs` enforces table prefix at the Rust layer. `api.rs` registers it as `door.db.*`. `runner.rs` gains schema auto-run and Lua package path setup.

**Tech stack:** sqlx 0.7 (SqlitePool, query_with, SqliteArguments), mlua (LuaTable, async_function), tokio

---

## Task 1: Add `crates/bbs-doors/src/db.rs`

**Files:**
- Create: `crates/bbs-doors/src/db.rs`

### Step 1: Write the file

```rust
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
            let keyword = up.trim_end_matches(|c: char| c == '(' || c == ';');
            if matches!(keyword, "FROM" | "JOIN" | "INTO" | "UPDATE" | "TABLE") {
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
```

### Step 2: Add tests at the bottom of the file

```rust
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
```

### Step 3: Run tests

```bash
cargo test -p bbs-doors db::tests
```

Expected: 3 tests pass.

### Step 4: Commit

```bash
git add crates/bbs-doors/src/db.rs
git commit -m "feat(bbs-doors): add DoorDb with query/execute and table prefix enforcement"
```

---

## Task 2: Register `door.db.*` in `api.rs`

**Files:**
- Modify: `crates/bbs-doors/src/api.rs`

### Step 1: Add import and parameter

At the top of `api.rs`, add:
```rust
use crate::db::{DoorDb, DbValue};
```

Change the `register` signature to accept `DoorDb`:
```rust
pub fn register(
    lua: &Lua,
    terminal: Terminal,
    user: &DoorUser,
    store: Arc<DoorStore>,
    db: Arc<DoorDb>,           // ← add this
    exit_flag: Arc<AtomicBool>,
    dos_config: DosConfig,
) -> Result<()> {
```

### Step 2: Add `door.db` table before `lua.globals().set("door", door)?`

```rust
// door.db.query(sql, params?) -> array of row tables
// door.db.execute(sql, params?) -> rows_affected
{
    let db_tbl = lua.create_table()?;

    // Helper: convert LuaTable (or nil) of params to Vec<DbValue>
    // Used by both query and execute closures below.

    {
        let db = Arc::clone(&db);
        db_tbl.set(
            "query",
            lua.create_async_function(move |lua, (sql, params): (String, Option<LuaTable>)| {
                let db = Arc::clone(&db);
                async move {
                    let params = lua_params_to_vec(params)?;
                    let rows = db.query(&sql, params).await.map_err(LuaError::external)?;
                    let result = lua.create_table()?;
                    for (i, row) in rows.into_iter().enumerate() {
                        let row_tbl = lua.create_table()?;
                        for (k, v) in row {
                            let lv = dbvalue_to_lua(&lua, v)?;
                            row_tbl.set(k, lv)?;
                        }
                        result.set(i + 1, row_tbl)?;
                    }
                    Ok(result)
                }
            })?,
        )?;
    }

    {
        let db = Arc::clone(&db);
        db_tbl.set(
            "execute",
            lua.create_async_function(move |_lua, (sql, params): (String, Option<LuaTable>)| {
                let db = Arc::clone(&db);
                async move {
                    let params = lua_params_to_vec(params)?;
                    let affected = db.execute(&sql, params).await.map_err(LuaError::external)?;
                    Ok(affected as i64)
                }
            })?,
        )?;
    }

    door.set("db", db_tbl)?;
}
```

### Step 3: Add helper functions at the bottom of `api.rs`

```rust
fn lua_params_to_vec(params: Option<LuaTable>) -> LuaResult<Vec<DbValue>> {
    let mut out = Vec::new();
    if let Some(tbl) = params {
        for val in tbl.sequence_values::<LuaValue>() {
            let val = val?;
            out.push(match val {
                LuaValue::Integer(i)  => DbValue::Int(i),
                LuaValue::Number(f)   => DbValue::Real(f),
                LuaValue::String(s)   => DbValue::Text(s.to_str()?.to_string()),
                LuaValue::Nil         => DbValue::Null,
                LuaValue::Boolean(b)  => DbValue::Int(if b { 1 } else { 0 }),
                other => return Err(LuaError::external(anyhow::anyhow!(
                    "unsupported param type: {:?}", other
                ))),
            });
        }
    }
    Ok(out)
}

fn dbvalue_to_lua(lua: &Lua, v: DbValue) -> LuaResult<LuaValue> {
    Ok(match v {
        DbValue::Int(i)  => LuaValue::Integer(i),
        DbValue::Real(f) => LuaValue::Number(f),
        DbValue::Text(s) => LuaValue::String(lua.create_string(&s)?),
        DbValue::Null    => LuaValue::Nil,
    })
}
```

### Step 4: Build to check it compiles

```bash
cargo build -p bbs-doors
```

### Step 5: Commit

```bash
git add crates/bbs-doors/src/api.rs
git commit -m "feat(bbs-doors): register door.db.query/execute in Lua API"
```

---

## Task 3: Update `runner.rs` — schema auto-run + `require()` support

**Files:**
- Modify: `crates/bbs-doors/src/runner.rs`

### Step 1: Update `DoorRunner` to store doors_dir and create DoorDb

```rust
use std::path::{Path, PathBuf};
use crate::db::DoorDb;

pub struct DoorRunner {
    db: Arc<Database>,
    terminal: Terminal,
    dos_config: DosConfig,
    doors_dir: PathBuf,        // ← add
}

impl DoorRunner {
    pub fn new(
        db: Arc<Database>,
        terminal: Terminal,
        dos_config: DosConfig,
        doors_dir: impl AsRef<Path>,   // ← add
    ) -> Self {
        Self { db, terminal, dos_config, doors_dir: doors_dir.as_ref().to_owned() }
    }
```

### Step 2: Update `run()` to create DoorDb, run schema, set package.path

Replace the body of `run()`:

```rust
pub async fn run(&self, door_name: &str, lua_path: &str, user: &DoorUser) -> Result<()> {
    info!("Launching door '{}' for user '{}'", door_name, user.name);

    let store = Arc::new(DoorStore::new(self.db.pool.clone(), door_name, user.id));
    let door_db = Arc::new(DoorDb::new(self.db.pool.clone(), door_name));

    // Auto-run schema.sql if present (idempotent — uses CREATE TABLE IF NOT EXISTS)
    let schema_path = self.doors_dir.join(door_name).join("schema.sql");
    if schema_path.exists() {
        let sql = tokio::fs::read_to_string(&schema_path).await?;
        door_db.run_schema(&sql).await?;
    }

    let exit_flag = Arc::new(AtomicBool::new(false));

    let lua = Lua::new();

    // Configure require() to find modules in doors/<name>/ and doors/<name>/lib/
    let door_dir = self.doors_dir.join(door_name).to_string_lossy().to_string();
    let package: LuaTable = lua.globals().get("package")?;
    let existing_path: String = package.get("path")?;
    package.set(
        "path",
        format!("{door_dir}/?.lua;{door_dir}/lib/?.lua;{existing_path}"),
    )?;

    api::register(
        &lua,
        self.terminal.clone(),
        user,
        Arc::clone(&store),
        Arc::clone(&door_db),
        Arc::clone(&exit_flag),
        self.dos_config.clone(),
    )?;

    let src = tokio::fs::read_to_string(lua_path).await?;
    let result = lua
        .load(&src)
        .set_name(lua_path)
        .call_async::<(), ()>(())
        .await;

    if exit_flag.load(Ordering::Relaxed) {
        return Ok(());
    }
    result.map_err(Into::into)
}
```

### Step 3: Fix callers of `DoorRunner::new` (bbs-server)

```bash
grep -r "DoorRunner::new" /mnt/unraid/CLAUDE/BBS/crates/
```

Update the call site to pass `doors_dir` (it's already in config).

### Step 4: Build everything

```bash
cargo build --all
```

### Step 5: Expose `DoorDb` from lib.rs

In `crates/bbs-doors/src/lib.rs` add:
```rust
pub mod db;
pub use db::DoorDb;
```

### Step 6: Commit

```bash
git add crates/bbs-doors/src/
git commit -m "feat(bbs-doors): schema.sql auto-run and require() package path per door"
```

---

## Task 4: Final check

```bash
cargo build --all
cargo clippy --all -- -D warnings
cargo test -p bbs-doors
```

All green → Phase 1 complete.

```bash
git log --oneline -4
```
