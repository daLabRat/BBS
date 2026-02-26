//! SSH server using russh 0.44.
//! Accepts SSH connections and pipes I/O to a bbs-runtime session.

use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::Result;
use async_trait::async_trait;
use bytes::Bytes;
use russh::server::{Auth, Msg, Server as _, Session};
use russh::{Channel, ChannelId};
use tokio::sync::mpsc;
use tracing::info;

use bbs_runtime::{RuntimeConfig, Terminal};

pub async fn serve(addr: &str, config: Arc<RuntimeConfig>) -> Result<()> {
    info!("SSH listening on {addr}");

    let host_key = get_host_key()?;

    let ssh_config = Arc::new(russh::server::Config {
        inactivity_timeout: Some(std::time::Duration::from_secs(3600)),
        auth_rejection_time: std::time::Duration::from_secs(1),
        auth_rejection_time_initial: Some(std::time::Duration::from_secs(0)),
        keys: vec![host_key],
        ..Default::default()
    });

    let mut server = SshServer { config };
    server
        .run_on_address(ssh_config, addr)
        .await
        .map_err(|e| anyhow::anyhow!("SSH server error: {e}"))
}

fn get_host_key() -> Result<russh_keys::key::KeyPair> {
    let path = std::path::Path::new("config/host_key");
    if path.exists() {
        return russh_keys::load_secret_key(path, None)
            .map_err(|e| anyhow::anyhow!("Failed to load host key: {e}"));
    }
    let key = russh_keys::key::KeyPair::generate_ed25519()
        .ok_or_else(|| anyhow::anyhow!("Failed to generate Ed25519 host key"))?;
    // Best-effort save so the fingerprint is stable across restarts.
    if let Ok(mut f) = std::fs::File::create(path) {
        let _ = russh_keys::encode_pkcs8_pem(&key, &mut f);
    }
    Ok(key)
}

// ── Server ───────────────────────────────────────────────────────────────────

struct SshServer {
    config: Arc<RuntimeConfig>,
}

impl russh::server::Server for SshServer {
    type Handler = SshHandler;

    fn new_client(&mut self, _addr: Option<SocketAddr>) -> SshHandler {
        SshHandler {
            config: Arc::clone(&self.config),
            byte_tx: None,
        }
    }
}

// ── Handler ──────────────────────────────────────────────────────────────────

struct SshHandler {
    config: Arc<RuntimeConfig>,
    byte_tx: Option<mpsc::Sender<u8>>,
}

#[async_trait]
impl russh::server::Handler for SshHandler {
    type Error = anyhow::Error;

    async fn auth_none(&mut self, _user: &str) -> Result<Auth, Self::Error> {
        Ok(Auth::Accept)
    }

    async fn auth_password(&mut self, _user: &str, _password: &str) -> Result<Auth, Self::Error> {
        Ok(Auth::Accept)
    }

    async fn auth_publickey(
        &mut self,
        _user: &str,
        _public_key: &russh_keys::key::PublicKey,
    ) -> Result<Auth, Self::Error> {
        Ok(Auth::Accept)
    }

    async fn channel_open_session(
        &mut self,
        _channel: Channel<Msg>,
        _session: &mut Session,
    ) -> Result<bool, Self::Error> {
        Ok(true)
    }

    async fn pty_request(
        &mut self,
        _channel: ChannelId,
        _term: &str,
        _col_width: u32,
        _row_height: u32,
        _pix_width: u32,
        _pix_height: u32,
        _modes: &[(russh::Pty, u32)],
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        Ok(())
    }

    async fn shell_request(
        &mut self,
        channel: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        let (byte_tx, byte_rx) = mpsc::channel::<u8>(1024);
        let (out_tx, mut out_rx) = mpsc::channel::<Bytes>(64);

        self.byte_tx = Some(byte_tx);

        let terminal = Terminal::new(out_tx, byte_rx);
        let handle = session.handle();

        // Write pump: drain the output channel → SSH channel data
        tokio::spawn(async move {
            while let Some(data) = out_rx.recv().await {
                let cv = russh::CryptoVec::from_slice(&data);
                if handle.data(channel, cv).await.is_err() {
                    break;
                }
            }
        });

        bbs_runtime::spawn_session(terminal, Arc::clone(&self.config));

        Ok(())
    }

    async fn data(
        &mut self,
        _channel: ChannelId,
        data: &[u8],
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        if let Some(tx) = &self.byte_tx {
            for &b in data {
                if tx.send(b).await.is_err() {
                    break;
                }
            }
        }
        Ok(())
    }

    async fn channel_eof(
        &mut self,
        _channel: ChannelId,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        Ok(())
    }

    async fn channel_close(
        &mut self,
        _channel: ChannelId,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        Ok(())
    }
}
