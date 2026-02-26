//! NNTP server. Maps BBS boards to newsgroups.

use anyhow::Result;
use tokio::net::TcpListener;
use tracing::info;

pub async fn serve(addr: &str) -> Result<()> {
    let listener = TcpListener::bind(addr).await?;
    info!("NNTP listening on {addr}");
    loop {
        let (socket, peer) = listener.accept().await?;
        info!("NNTP connection from {peer}");
        tokio::spawn(async move {
            if let Err(e) = handle_connection(socket).await {
                tracing::error!("NNTP session error: {e}");
            }
        });
    }
}

async fn handle_connection(_socket: tokio::net::TcpStream) -> Result<()> {
    // TODO: NNTP command handler + board/message mapping
    Ok(())
}
