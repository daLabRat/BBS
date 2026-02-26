//! axum HTTP + WebSocket terminal bridge.
//! Serves a web-based terminal that forwards I/O to bbs-runtime.

use anyhow::Result;
use tracing::info;

pub async fn serve(addr: &str) -> Result<()> {
    info!("HTTP/WebSocket listening on {addr}");
    // TODO: axum router + WebSocket terminal bridge to bbs-runtime
    Ok(())
}
