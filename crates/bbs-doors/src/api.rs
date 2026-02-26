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
//!   -- door.launch_dos(game_path, drop_file_type)  [STUB — phase 2]

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::Result;
use bbs_tui::Terminal;
use bytes::Bytes;
use mlua::prelude::*;

use crate::session::DoorUser;
use crate::store::DoorStore;

pub fn register(
    lua: &Lua,
    terminal: Terminal,
    user: &DoorUser,
    store: Arc<DoorStore>,
    exit_flag: Arc<AtomicBool>,
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

    // door.launch_dos (stub — phase 2)
    door.set(
        "launch_dos",
        lua.create_function(|_lua, (_path, _drop_file): (String, String)| {
            Err::<(), _>(LuaError::external(anyhow::anyhow!(
                "DOS game launch not implemented (reserved for phase 2)"
            )))
        })?,
    )?;

    lua.globals().set("door", door)?;

    Ok(())
}
