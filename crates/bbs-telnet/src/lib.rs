//! Raw TCP listener with VT100 state machine.
//! Accepts connections on the telnet port and pipes I/O to bbs-runtime.

use anyhow::Result;
use tokio::net::TcpListener;
use tracing::info;

pub async fn serve(addr: &str) -> Result<()> {
    let listener = TcpListener::bind(addr).await?;
    info!("Telnet listening on {addr}");
    loop {
        let (socket, peer) = listener.accept().await?;
        info!("Telnet connection from {peer}");
        tokio::spawn(async move {
            if let Err(e) = handle_connection(socket).await {
                tracing::error!("Telnet session error: {e}");
            }
        });
    }
}

async fn handle_connection(_socket: tokio::net::TcpStream) -> Result<()> {
    // TODO: VT100 state machine + bbs-runtime session handoff
    Ok(())
}
