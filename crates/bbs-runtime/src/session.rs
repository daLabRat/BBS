use anyhow::Result;
use bbs_core::User;

/// One Lua VM instance per connected user session.
/// Loads scripts/main.lua and calls it with the session context.
pub struct Session {
    pub user: Option<User>,
    // TODO: mlua::Lua instance, I/O sender/receiver
}

impl Session {
    pub fn new() -> Self {
        Self { user: None }
    }

    pub async fn run(&mut self, _scripts_dir: &str) -> Result<()> {
        // TODO: create Lua VM, register bbs.* API, load main.lua, call main()
        Ok(())
    }
}

impl Default for Session {
    fn default() -> Self {
        Self::new()
    }
}
