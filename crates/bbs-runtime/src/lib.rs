pub mod api;
pub mod registry;
pub mod session;

use std::path::PathBuf;
use std::sync::Arc;

pub use registry::SessionRegistry;

/// Shared configuration passed to every user session.
pub struct RuntimeConfig {
    pub scripts_dir: PathBuf,
    pub doors_dir: PathBuf,
    pub db: Arc<bbs_core::Database>,
    pub registry: SessionRegistry,
}

pub use bbs_tui::Terminal;
pub use session::Session;

/// Spawn a new BBS session on a dedicated OS thread with its own single-threaded
/// Tokio runtime.  This sidesteps the `!Send` constraint of `mlua::AsyncThread`
/// while keeping all I/O pumps on the main multi-thread runtime.
pub fn spawn_session(terminal: Terminal, config: Arc<RuntimeConfig>) {
    std::thread::Builder::new()
        .name("bbs-session".into())
        .spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("build session runtime");
            let local = tokio::task::LocalSet::new();
            rt.block_on(local.run_until(async move {
                if let Err(e) = Session::new(terminal, config).run().await {
                    tracing::error!("session error: {e}");
                }
            }));
        })
        .expect("thread spawn");
}
