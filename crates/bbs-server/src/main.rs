use std::sync::Arc;

use anyhow::Result;
use bbs_runtime::RuntimeConfig;
use config::{Config, File};
use tracing::info;
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

    let telnet_bind = cfg
        .get_string("telnet.bind")
        .unwrap_or_else(|_| "0.0.0.0:2323".into());
    let scripts_dir = cfg
        .get_string("paths.scripts")
        .unwrap_or_else(|_| "scripts".into());

    let runtime_config = Arc::new(RuntimeConfig {
        scripts_dir: scripts_dir.into(),
    });

    info!("Scripts dir: {}", runtime_config.scripts_dir.display());

    // Telnet listener runs until process exits.
    bbs_telnet::serve(&telnet_bind, runtime_config).await?;

    Ok(())
}
