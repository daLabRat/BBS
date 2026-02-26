//! Registers the `bbs.*` Lua API into a Lua VM.

use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use bbs_tui::Terminal;
use bytes::Bytes;
use mlua::prelude::*;

use crate::RuntimeConfig;

pub fn register(lua: &Lua, terminal: Terminal, config: &RuntimeConfig) -> Result<()> {
    let bbs = lua.create_table()?;

    let tx = terminal.writer().clone();
    let rx = terminal.reader();

    // --- bbs.write(s) ---
    {
        let tx = tx.clone();
        bbs.set(
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

    // --- bbs.writeln(s) ---
    {
        let tx = tx.clone();
        bbs.set(
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

    // --- bbs.clear() ---
    {
        let tx = tx.clone();
        bbs.set(
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

    // --- bbs.read_key() -> string|nil ---
    {
        let rx = rx.clone();
        bbs.set(
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

    // --- bbs.read_line(prompt) -> string|nil ---
    {
        let tx = tx.clone();
        let rx = rx.clone();
        bbs.set(
            "read_line",
            lua.create_async_function(move |_lua, prompt: String| {
                let tx = tx.clone();
                let rx = rx.clone();
                async move {
                    tx.send(Bytes::from(prompt)).await.ok();
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

    // --- bbs.read_pass(prompt) -> string|nil ---
    // Like read_line but does NOT echo characters back.
    {
        let tx = tx.clone();
        let rx = rx.clone();
        bbs.set(
            "read_pass",
            lua.create_async_function(move |_lua, prompt: String| {
                let tx = tx.clone();
                let rx = rx.clone();
                async move {
                    tx.send(Bytes::from(prompt)).await.ok();
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
                                    buf.pop(); // silent backspace
                                }
                                b if (32..127).contains(&b) => {
                                    buf.push(b as char);
                                    // No echo
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

    // --- bbs.ansi(name) -> string ---
    bbs.set(
        "ansi",
        lua.create_function(|_lua, name: String| Ok(bbs_tui::ansi::named(&name).to_string()))?,
    )?;

    // --- bbs.time() -> integer (unix seconds) ---
    bbs.set(
        "time",
        lua.create_function(|_lua, ()| {
            let secs = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            Ok(secs as i64)
        })?,
    )?;

    // --- bbs.pager(text) ---
    {
        let tx = tx.clone();
        bbs.set(
            "pager",
            lua.create_async_function(move |_lua, text: String| {
                let tx = tx.clone();
                async move {
                    tx.send(Bytes::from(format!("{text}\r\n"))).await.ok();
                    Ok(())
                }
            })?,
        )?;
    }

    // --- bbs.menu(_) --- (stub — menus implemented in Lua)
    bbs.set("menu", lua.create_function(|_lua, _def: LuaValue| Ok(()))?)?;

    // --- bbs.user {name, id, is_sysop} ---
    // Mutable table — auth.lua sets these after login.
    let user = lua.create_table()?;
    user.set("name", "guest")?;
    user.set("id", 0i64)?;
    user.set("is_sysop", false)?;
    bbs.set("user", user)?;

    // --- bbs.auth ---
    {
        let db = Arc::clone(&config.db);
        let auth_tbl = lua.create_table()?;

        // bbs.auth.login(username, password) -> {name,id,is_sysop} | nil
        {
            let db = Arc::clone(&db);
            auth_tbl.set(
                "login",
                lua.create_async_function(move |lua, (username, password): (String, String)| {
                    let db = Arc::clone(&db);
                    async move {
                        let user = db
                            .find_user_by_username(&username)
                            .await
                            .map_err(LuaError::external)?;
                        match user {
                            Some(u) => {
                                match bbs_core::verify_password(&password, &u.password_hash) {
                                    Ok(true) => {
                                        let _ = db.update_last_login(u.id).await;
                                        let t = lua.create_table()?;
                                        t.set("name", u.username)?;
                                        t.set("id", u.id)?;
                                        t.set("is_sysop", u.is_sysop)?;
                                        Ok(LuaValue::Table(t))
                                    }
                                    _ => Ok(LuaValue::Nil),
                                }
                            }
                            None => Ok(LuaValue::Nil),
                        }
                    }
                })?,
            )?;
        }

        // bbs.auth.register(username, password) -> {name,id,is_sysop} | nil
        // Returns nil on duplicate username instead of erroring.
        {
            let db = Arc::clone(&db);
            auth_tbl.set(
                "register",
                lua.create_async_function(move |lua, (username, password): (String, String)| {
                    let db = Arc::clone(&db);
                    async move {
                        let hash =
                            bbs_core::hash_password(&password).map_err(LuaError::external)?;
                        match db.create_user(&username, &hash).await {
                            Ok(u) => {
                                let t = lua.create_table()?;
                                t.set("name", u.username)?;
                                t.set("id", u.id)?;
                                t.set("is_sysop", u.is_sysop)?;
                                Ok(LuaValue::Table(t))
                            }
                            Err(_) => Ok(LuaValue::Nil), // username taken
                        }
                    }
                })?,
            )?;
        }

        bbs.set("auth", auth_tbl)?;
    }

    // --- bbs.boards ---
    {
        let db = Arc::clone(&config.db);
        let boards_tbl = lua.create_table()?;

        // bbs.boards.list() -> [{id,name,description}]
        {
            let db = Arc::clone(&db);
            boards_tbl.set(
                "list",
                lua.create_async_function(move |lua, ()| {
                    let db = Arc::clone(&db);
                    async move {
                        let boards = db.list_boards().await.map_err(LuaError::external)?;
                        let result = lua.create_table()?;
                        for (i, b) in boards.into_iter().enumerate() {
                            let t = lua.create_table()?;
                            t.set("id", b.id)?;
                            t.set("name", b.name)?;
                            t.set("description", b.description)?;
                            result.set(i + 1, t)?;
                        }
                        Ok(result)
                    }
                })?,
            )?;
        }

        // bbs.boards.read(board_id) -> [{id,subject,author,created_at,body}]
        {
            let db = Arc::clone(&db);
            boards_tbl.set(
                "read",
                lua.create_async_function(move |lua, board_id: i64| {
                    let db = Arc::clone(&db);
                    async move {
                        let messages = db
                            .list_messages(board_id)
                            .await
                            .map_err(LuaError::external)?;
                        let result = lua.create_table()?;
                        for (i, (msg, author)) in messages.into_iter().enumerate() {
                            let t = lua.create_table()?;
                            t.set("id", msg.id)?;
                            t.set("subject", msg.subject)?;
                            t.set("author", author)?;
                            t.set("created_at", msg.created_at)?;
                            t.set("body", msg.body)?;
                            result.set(i + 1, t)?;
                        }
                        Ok(result)
                    }
                })?,
            )?;
        }

        // bbs.boards.post(board_id, subject, body) -> nil
        {
            let db = Arc::clone(&db);
            boards_tbl.set(
                "post",
                lua.create_async_function(
                    move |lua, (board_id, subject, body): (i64, String, String)| {
                        let db = Arc::clone(&db);
                        async move {
                            let bbs_tbl: LuaTable = lua.globals().get("bbs")?;
                            let user_tbl: LuaTable = bbs_tbl.get("user")?;
                            let author_id: i64 = user_tbl.get("id")?;
                            db.post_message(board_id, author_id, &subject, &body)
                                .await
                                .map_err(LuaError::external)?;
                            Ok(())
                        }
                    },
                )?,
            )?;
        }

        bbs.set("boards", boards_tbl)?;
    }

    // --- bbs.doors ---
    {
        let doors_dir = config.doors_dir.clone();
        let db = Arc::clone(&config.db);
        let doors_tbl = lua.create_table()?;

        // bbs.doors.list() -> [string]
        {
            let doors_dir = doors_dir.clone();
            doors_tbl.set(
                "list",
                lua.create_async_function(move |lua, ()| {
                    let doors_dir = doors_dir.clone();
                    async move {
                        let registry = bbs_doors::DoorRegistry::new(&doors_dir);
                        let names = registry.list().map_err(LuaError::external)?;
                        let result = lua.create_table()?;
                        for (i, name) in names.into_iter().enumerate() {
                            result.set(i + 1, name)?;
                        }
                        Ok(result)
                    }
                })?,
            )?;
        }

        // bbs.doors.launch(name) -> nil
        {
            let doors_dir = doors_dir.clone();
            let db = Arc::clone(&db);
            let terminal = terminal.clone();
            doors_tbl.set(
                "launch",
                lua.create_async_function(move |lua, name: String| {
                    let doors_dir = doors_dir.clone();
                    let db = Arc::clone(&db);
                    let terminal = terminal.clone();
                    async move {
                        let bbs_tbl: LuaTable = lua.globals().get("bbs")?;
                        let user_tbl: LuaTable = bbs_tbl.get("user")?;
                        let user = bbs_doors::session::DoorUser {
                            id: user_tbl.get("id")?,
                            name: user_tbl.get("name")?,
                            is_sysop: user_tbl.get("is_sysop")?,
                        };
                        let registry = bbs_doors::DoorRegistry::new(&doors_dir);
                        let lua_path = registry.main_lua(&name);
                        let runner = bbs_doors::DoorRunner::new(db, terminal);
                        runner
                            .run(&name, lua_path.to_str().unwrap_or(""), &user)
                            .await
                            .map_err(LuaError::external)?;
                        Ok(())
                    }
                })?,
            )?;
        }

        bbs.set("doors", doors_tbl)?;
    }

    lua.globals().set("bbs", bbs)?;

    Ok(())
}
