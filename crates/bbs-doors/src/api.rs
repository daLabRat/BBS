//! Registers the `door.*` Lua API into a Lua VM.
//!
//! API surface:
//!   door.write(text)          -- send text/ANSI to terminal
//!   door.writeln(text)
//!   door.read_line()          -- blocking line read
//!   door.read_key()           -- single keypress
//!   door.clear()
//!   door.user.name            -- read-only snapshot
//!   door.user.id
//!   door.user.is_sysop
//!   door.data.get(key)        -- per-user per-door KV store (SQLite)
//!   door.data.set(key, value)
//!   door.ansi(name)
//!   door.sleep(ms)
//!   door.time()
//!   door.exit()
//!   door.launch_dos(game_path, drop_file_type)

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::Result;
use bbs_tui::Terminal;
use bytes::Bytes;
use mlua::prelude::*;

use crate::db::{DbValue, DoorDb};
use crate::dos::DosConfig;
use crate::session::DoorUser;
use crate::store::DoorStore;

pub fn register(
    lua: &Lua,
    terminal: Terminal,
    user: &DoorUser,
    store: Arc<DoorStore>,
    db: Arc<DoorDb>,
    exit_flag: Arc<AtomicBool>,
    dos_config: DosConfig,
) -> Result<()> {
    let door = lua.create_table()?;

    let tx = terminal.writer().clone();
    let rx = terminal.reader();

    // door.write(s)
    {
        let tx = tx.clone();
        door.set(
            "write",
            lua.create_async_function(move |_lua, text: String| {
                let tx = tx.clone();
                async move {
                    tx.send(Bytes::from(text)).await.ok();
                    Ok(())
                }
            })?,
        )?;
    }

    // door.writeln(s)
    {
        let tx = tx.clone();
        door.set(
            "writeln",
            lua.create_async_function(move |_lua, text: String| {
                let tx = tx.clone();
                async move {
                    tx.send(Bytes::from(format!("{text}\r\n"))).await.ok();
                    Ok(())
                }
            })?,
        )?;
    }

    // door.clear()
    {
        let tx = tx.clone();
        door.set(
            "clear",
            lua.create_async_function(move |_lua, ()| {
                let tx = tx.clone();
                async move {
                    tx.send(Bytes::from_static(b"\x1b[2J\x1b[H")).await.ok();
                    Ok(())
                }
            })?,
        )?;
    }

    // door.read_key() -> string|nil
    {
        let rx = rx.clone();
        door.set(
            "read_key",
            lua.create_async_function(move |_lua, ()| {
                let rx = rx.clone();
                async move {
                    let mut guard = rx.lock().await;
                    match guard.recv().await {
                        Some(b) => Ok(Some(String::from(b as char))),
                        None => Ok(None),
                    }
                }
            })?,
        )?;
    }

    // door.read_line() -> string|nil
    {
        let tx = tx.clone();
        let rx = rx.clone();
        door.set(
            "read_line",
            lua.create_async_function(move |_lua, ()| {
                let tx = tx.clone();
                let rx = rx.clone();
                async move {
                    let mut buf = String::new();
                    let mut guard = rx.lock().await;
                    loop {
                        match guard.recv().await {
                            None => return Ok(None),
                            Some(b) => match b {
                                3 | 4 => return Ok(None),
                                b'\n' | b'\r' => {
                                    tx.send(Bytes::from_static(b"\r\n")).await.ok();
                                    break;
                                }
                                8 | 127 => {
                                    if !buf.is_empty() {
                                        buf.pop();
                                        tx.send(Bytes::from_static(b"\x08 \x08")).await.ok();
                                    }
                                }
                                b if (32..127).contains(&b) => {
                                    buf.push(b as char);
                                    tx.send(Bytes::from(vec![b])).await.ok();
                                }
                                _ => {}
                            },
                        }
                    }
                    Ok(Some(buf))
                }
            })?,
        )?;
    }

    // door.terminal {cols(), rows()}
    {
        let term_tbl = lua.create_table()?;
        {
            let t = terminal.clone();
            term_tbl.set(
                "cols",
                lua.create_function(move |_, ()| Ok(t.size().0 as i64))?,
            )?;
        }
        {
            let t = terminal.clone();
            term_tbl.set(
                "rows",
                lua.create_function(move |_, ()| Ok(t.size().1 as i64))?,
            )?;
        }
        door.set("terminal", term_tbl)?;
    }

    // door.ansi(name) -> string
    door.set(
        "ansi",
        lua.create_function(|_lua, name: String| Ok(bbs_tui::ansi::named(&name).to_string()))?,
    )?;

    // door.time() -> integer
    door.set(
        "time",
        lua.create_function(|_lua, ()| {
            let secs = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            Ok(secs as i64)
        })?,
    )?;

    // door.sleep(ms)
    door.set(
        "sleep",
        lua.create_async_function(move |_lua, ms: u64| async move {
            tokio::time::sleep(Duration::from_millis(ms)).await;
            Ok(())
        })?,
    )?;

    // door.exit() — sets the exit flag then throws an error to unwind Lua
    {
        let exit_flag = Arc::clone(&exit_flag);
        door.set(
            "exit",
            lua.create_function(move |_lua, ()| {
                exit_flag.store(true, Ordering::Relaxed);
                Err::<(), _>(LuaError::external(anyhow::anyhow!("door exit")))
            })?,
        )?;
    }

    // door.user — read-only snapshot of user context
    {
        let user_tbl = lua.create_table()?;
        user_tbl.set("name", user.name.clone())?;
        user_tbl.set("id", user.id)?;
        user_tbl.set("is_sysop", user.is_sysop)?;
        door.set("user", user_tbl)?;
    }

    // door.data.get(key) / door.data.set(key, value)
    {
        let data_tbl = lua.create_table()?;

        {
            let store = Arc::clone(&store);
            data_tbl.set(
                "get",
                lua.create_async_function(move |_lua, key: String| {
                    let store = Arc::clone(&store);
                    async move {
                        let val = store.get(&key).await.map_err(LuaError::external)?;
                        Ok(val)
                    }
                })?,
            )?;
        }

        {
            let store = Arc::clone(&store);
            data_tbl.set(
                "set",
                lua.create_async_function(move |_lua, (key, value): (String, String)| {
                    let store = Arc::clone(&store);
                    async move {
                        store.set(&key, &value).await.map_err(LuaError::external)?;
                        Ok(())
                    }
                })?,
            )?;
        }

        door.set("data", data_tbl)?;
    }

    // door.launch_dos(exe_path, drop_file_type) -> nil
    {
        let dos_config = dos_config.clone();
        let terminal = terminal.clone();
        let user_snapshot = DoorUser {
            id: user.id,
            name: user.name.clone(),
            is_sysop: user.is_sysop,
        };
        door.set(
            "launch_dos",
            lua.create_async_function(
                move |_lua, (exe_path, drop_file_type): (String, String)| {
                    let dos_config = dos_config.clone();
                    let terminal = terminal.clone();
                    let user = user_snapshot.clone();
                    async move {
                        dos_config
                            .launch(Path::new(&exe_path), &drop_file_type, &user, &terminal)
                            .await
                            .map_err(LuaError::external)
                    }
                },
            )?,
        )?;
    }

    // door.db.query(sql, params?) -> array of row tables
    // door.db.execute(sql, params?) -> rows_affected
    {
        let db_tbl = lua.create_table()?;

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
                                let lv = dbvalue_to_lua(lua, v)?;
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

    lua.globals().set("door", door)?;

    Ok(())
}

fn lua_params_to_vec(params: Option<LuaTable>) -> LuaResult<Vec<DbValue>> {
    let mut out = Vec::new();
    if let Some(tbl) = params {
        for val in tbl.sequence_values::<LuaValue>() {
            let val = val?;
            out.push(match val {
                LuaValue::Integer(i) => DbValue::Int(i),
                LuaValue::Number(f)  => DbValue::Real(f),
                LuaValue::String(s)  => DbValue::Text(s.to_str()?.to_string()),
                LuaValue::Nil        => DbValue::Null,
                LuaValue::Boolean(b) => DbValue::Int(if b { 1 } else { 0 }),
                other => return Err(LuaError::external(anyhow::anyhow!(
                    "unsupported param type: {:?}", other
                ))),
            });
        }
    }
    Ok(out)
}

fn dbvalue_to_lua(lua: &Lua, v: DbValue) -> LuaResult<LuaValue<'_>> {
    Ok(match v {
        DbValue::Int(i)  => LuaValue::Integer(i),
        DbValue::Real(f) => LuaValue::Number(f),
        DbValue::Text(s) => LuaValue::String(lua.create_string(&s)?),
        DbValue::Null    => LuaValue::Nil,
    })
}
