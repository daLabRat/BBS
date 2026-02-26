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

// TODO: implement using mlua UserData and async Lua functions
