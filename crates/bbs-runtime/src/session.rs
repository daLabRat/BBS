//! One Lua VM per user session.  Loads scripts/main.lua and runs it.

use std::sync::Arc;

use anyhow::Result;
use bbs_tui::Terminal;

use crate::{api, RuntimeConfig};

pub struct Session {
    terminal: Terminal,
    config: Arc<RuntimeConfig>,
}

impl Session {
    pub fn new(terminal: Terminal, config: Arc<RuntimeConfig>) -> Self {
        Self { terminal, config }
    }

    pub async fn run(self) -> Result<()> {
        let lua = mlua::Lua::new();

        // Set package.path so require("auth") etc. resolve from scripts_dir.
        let scripts_dir = self.config.scripts_dir.clone();
        let pkg: mlua::Table = lua.globals().get("package")?;
        pkg.set("path", format!("{}/?.lua", scripts_dir.display()))?;

        api::register(&lua, self.terminal, &self.config)?;

        let src = tokio::fs::read_to_string(scripts_dir.join("main.lua")).await?;
        lua.load(&src)
            .set_name("main.lua")
            .call_async::<(), ()>(())
            .await?;

        Ok(())
    }
}
