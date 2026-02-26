pub mod api;
pub mod session;

use std::path::PathBuf;

/// Shared configuration passed to every user session.
pub struct RuntimeConfig {
    pub scripts_dir: PathBuf,
}

pub use bbs_tui::Terminal;
pub use session::Session;
