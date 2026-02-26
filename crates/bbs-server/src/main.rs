use std::{path::Path, sync::Arc};

use anyhow::Result;
use bbs_core::Database;
use bbs_runtime::{LoginThrottle, RuntimeConfig, SessionRegistry};
use config::{Config, File};
use tracing::{info, warn};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    info!("BBS server starting");

    let cfg = Config::builder()
        .add_source(File::with_name("config/default").required(false))
        .build()?;

    // ── Database ─────────────────────────────────────────────────────────────

    let db_url = cfg
        .get_string("database.url")
        .unwrap_or_else(|_| "sqlite:bbs.db".into());

    let db = Arc::new(Database::connect(&db_url).await?);
    db.migrate().await?;
    info!("Database ready at {db_url}");

    // ── Runtime config ───────────────────────────────────────────────────────

    let scripts_dir = cfg
        .get_string("paths.scripts")
        .unwrap_or_else(|_| "scripts".into());
    let doors_dir = cfg
        .get_string("paths.doors")
        .unwrap_or_else(|_| "doors".into());
    let ansi_dir = cfg
        .get_string("paths.ansi")
        .unwrap_or_else(|_| "ansi".into());

    let registry = SessionRegistry::default();
    let throttle = LoginThrottle::default();

    let runtime_config = Arc::new(RuntimeConfig {
        scripts_dir: scripts_dir.into(),
        doors_dir: doors_dir.into(),
        ansi_dir: ansi_dir.into(),
        db: Arc::clone(&db),
        registry,
        throttle,
    });

    // ── Path validation ──────────────────────────────────────────────────────

    validate_paths(&runtime_config)?;

    // ── Bind addresses ───────────────────────────────────────────────────────

    let telnet_bind = cfg
        .get_string("telnet.bind")
        .unwrap_or_else(|_| "0.0.0.0:2323".into());
    let ssh_bind = cfg
        .get_string("ssh.bind")
        .unwrap_or_else(|_| "0.0.0.0:2222".into());
    let http_bind = cfg
        .get_string("http.bind")
        .unwrap_or_else(|_| "0.0.0.0:8080".into());
    let nntp_bind = cfg
        .get_string("nntp.bind")
        .unwrap_or_else(|_| "0.0.0.0:1119".into());

    // ── Start all listeners ──────────────────────────────────────────────────

    tokio::try_join!(
        bbs_telnet::serve(&telnet_bind, Arc::clone(&runtime_config)),
        bbs_ssh::serve(&ssh_bind, Arc::clone(&runtime_config)),
        bbs_web::serve(&http_bind, Arc::clone(&runtime_config)),
        bbs_nntp::serve(&nntp_bind, Arc::clone(&db)),
    )?;

    Ok(())
}

/// Validate runtime paths, creating optional directories when missing.
fn validate_paths(cfg: &RuntimeConfig) -> Result<()> {
    // scripts_dir must exist and contain main.lua (the session entry point).
    if !cfg.scripts_dir.is_dir() {
        anyhow::bail!(
            "Scripts directory not found: '{}'. \
             Set [paths] scripts in config/default.toml.",
            cfg.scripts_dir.display()
        );
    }
    let entry = cfg.scripts_dir.join("main.lua");
    if !entry.exists() {
        anyhow::bail!(
            "Entry point '{}' not found. \
             The scripts directory must contain main.lua.",
            entry.display()
        );
    }
    info!("Scripts dir OK: {}", cfg.scripts_dir.display());

    // doors_dir: create if absent (no doors configured yet is fine).
    ensure_dir(&cfg.doors_dir, "Doors")?;

    // ansi_dir: create if absent (art is optional).
    ensure_dir(&cfg.ansi_dir, "ANSI art")?;

    Ok(())
}

fn ensure_dir(path: &Path, label: &str) -> Result<()> {
    if path.exists() {
        if !path.is_dir() {
            anyhow::bail!("{} path '{}' exists but is not a directory.", label, path.display());
        }
        info!("{} dir OK: {}", label, path.display());
    } else {
        std::fs::create_dir_all(path)?;
        warn!("{} directory '{}' did not exist — created.", label, path.display());
    }
    Ok(())
}
