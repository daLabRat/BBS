use anyhow::Result;
use tracing::info;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    info!("BBS server starting");

    // TODO: load config/default.toml
    // TODO: connect to DB + run migrations
    // TODO: spawn protocol listeners:
    //   bbs_telnet::serve("0.0.0.0:2323")
    //   bbs_ssh::serve("0.0.0.0:2222")
    //   bbs_web::serve("0.0.0.0:8080")
    //   bbs_nntp::serve("0.0.0.0:1119")

    info!("BBS server ready (stub — listeners not yet wired)");
    Ok(())
}
