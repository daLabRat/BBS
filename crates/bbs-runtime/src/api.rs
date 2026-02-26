//! Registers the `bbs.*` Lua API into a Lua VM.

use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use bbs_tui::Terminal;
use bytes::Bytes;
use mlua::prelude::*;

pub fn register(lua: &Lua, terminal: Terminal) -> Result<()> {
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
    // Receives one byte from the input channel with no echo.
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
    // Sends prompt, then echoes printable input until Enter.
    // Returns nil on Ctrl-C / Ctrl-D / connection close.
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
                                3 | 4 => return Ok(None), // Ctrl-C / Ctrl-D
                                b'\n' | b'\r' => {
                                    tx.send(Bytes::from_static(b"\r\n")).await.ok();
                                    break;
                                }
                                8 | 127 => {
                                    // Backspace / DEL
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

    // --- bbs.pager(text) --- (simple: just print, no scrolling yet)
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

    // --- bbs.menu(_) --- (stub)
    bbs.set("menu", lua.create_function(|_lua, _def: LuaValue| Ok(()))?)?;

    // --- bbs.user {name, id, is_sysop} ---
    // Mutable table — auth.lua sets these after login.
    let user = lua.create_table()?;
    user.set("name", "guest")?;
    user.set("id", 0i64)?;
    user.set("is_sysop", false)?;
    bbs.set("user", user)?;

    // --- bbs.boards ---
    let boards = lua.create_table()?;
    boards.set("list", lua.create_function(|lua, ()| lua.create_table())?)?;
    boards.set(
        "read",
        lua.create_function(|lua, _id: LuaValue| lua.create_table())?,
    )?;
    boards.set(
        "post",
        lua.create_function(|_lua, (_id, _subject, _body): (LuaValue, LuaValue, LuaValue)| Ok(()))?,
    )?;
    bbs.set("boards", boards)?;

    // --- bbs.doors ---
    let doors = lua.create_table()?;
    doors.set("list", lua.create_function(|lua, ()| lua.create_table())?)?;
    doors.set("launch", lua.create_function(|_lua, _name: String| Ok(()))?)?;
    bbs.set("doors", doors)?;

    lua.globals().set("bbs", bbs)?;

    Ok(())
}
