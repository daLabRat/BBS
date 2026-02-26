//! Loads a door's main.lua, registers the door.* API, and runs it.

use anyhow::Result;
use tracing::info;

use crate::session::DoorUser;

pub struct DoorRunner {
    // TODO: mlua::Lua instance, DoorStore, I/O handles
}

impl DoorRunner {
    pub fn new() -> Self {
        Self {}
    }

    pub async fn run(&self, lua_path: &str, user: &DoorUser) -> Result<()> {
        info!("Launching door {} for user {}", lua_path, user.name);
        // TODO: create Lua VM, register door.* API, load + execute main.lua
        Ok(())
    }
}

impl Default for DoorRunner {
    fn default() -> Self {
        Self::new()
    }
}
