//! Loads a door's main.lua, registers the door.* API, and runs it.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::Result;
use bbs_core::Database;
use bbs_tui::Terminal;
use mlua::Lua;
use tracing::info;

use crate::api;
use crate::dos::DosConfig;
use crate::session::DoorUser;
use crate::store::DoorStore;

pub struct DoorRunner {
    db: Arc<Database>,
    terminal: Terminal,
    dos_config: DosConfig,
}

impl DoorRunner {
    pub fn new(db: Arc<Database>, terminal: Terminal, dos_config: DosConfig) -> Self {
        Self { db, terminal, dos_config }
    }

    /// Run a door for the given user.
    ///
    /// `door_name` is used as the key for the per-door KV store.
    /// `lua_path`  is the path to the door's `main.lua`.
    ///
    /// A clean `door.exit()` call inside the script is treated as success.
    pub async fn run(&self, door_name: &str, lua_path: &str, user: &DoorUser) -> Result<()> {
        info!("Launching door '{}' for user '{}'", door_name, user.name);

        let store = Arc::new(DoorStore::new(self.db.pool.clone(), door_name, user.id));

        let exit_flag = Arc::new(AtomicBool::new(false));

        let lua = Lua::new();
        api::register(
            &lua,
            self.terminal.clone(),
            user,
            Arc::clone(&store),
            Arc::clone(&exit_flag),
            self.dos_config.clone(),
        )?;

        let src = tokio::fs::read_to_string(lua_path).await?;
        let result = lua
            .load(&src)
            .set_name(lua_path)
            .call_async::<(), ()>(())
            .await;

        // A door.exit() call sets the flag and throws an error to unwind Lua.
        // Treat that as a clean exit.
        if exit_flag.load(Ordering::Relaxed) {
            return Ok(());
        }

        result.map_err(Into::into)
    }
}
