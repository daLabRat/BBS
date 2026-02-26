//! SSH server using russh.
//! Reuses bbs-tui after handshake; pipes I/O to bbs-runtime.

use anyhow::Result;
use tracing::info;

pub async fn serve(addr: &str) -> Result<()> {
    info!("SSH listening on {addr}");
    // TODO: russh server setup + bbs-runtime session handoff
    Ok(())
}
