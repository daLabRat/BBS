//! axum HTTP + WebSocket terminal bridge.
//! Serves a minimal xterm.js web page at GET / and upgrades GET /ws to a
//! WebSocket that pipes bytes to a bbs-runtime session.

use std::sync::Arc;

use anyhow::Result;
use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    response::{Html, IntoResponse},
    routing::get,
    Router,
};
use bytes::Bytes;
use futures_util::StreamExt;
use tokio::sync::mpsc;
use tracing::info;

use bbs_runtime::{RuntimeConfig, Terminal};

pub async fn serve(addr: &str, config: Arc<RuntimeConfig>) -> Result<()> {
    let app = Router::new()
        .route("/", get(index_handler))
        .route("/ws", get(ws_handler))
        .with_state(config);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    info!("HTTP/WebSocket listening on {addr}");
    axum::serve(listener, app).await?;
    Ok(())
}

async fn index_handler() -> Html<&'static str> {
    Html(XTERM_HTML)
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    State(config): State<Arc<RuntimeConfig>>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, config))
}

async fn handle_socket(socket: WebSocket, config: Arc<RuntimeConfig>) {
    let (mut sender, mut receiver) = socket.split();

    let (byte_tx, byte_rx) = mpsc::channel::<u8>(1024);
    let (out_tx, mut out_rx) = mpsc::channel::<Bytes>(64);

    let terminal = Terminal::new(out_tx, byte_rx);

    // Write pump: session output → WebSocket binary frames
    tokio::spawn(async move {
        while let Some(data) = out_rx.recv().await {
            use futures_util::SinkExt;
            if sender.send(Message::Binary(data.to_vec())).await.is_err() {
                break;
            }
        }
    });

    // Launch the BBS session on a dedicated thread.
    bbs_runtime::spawn_session(terminal, config);

    // Read pump: WebSocket frames → byte channel
    while let Some(msg) = receiver.next().await {
        match msg {
            Ok(Message::Binary(data)) => {
                for &b in &data {
                    if byte_tx.send(b).await.is_err() {
                        return;
                    }
                }
            }
            Ok(Message::Text(text)) => {
                for b in text.as_bytes() {
                    if byte_tx.send(*b).await.is_err() {
                        return;
                    }
                }
            }
            Ok(Message::Close(_)) | Err(_) => return,
            _ => {}
        }
    }
}

// ── Inline HTML ──────────────────────────────────────────────────────────────

const XTERM_HTML: &str = r#"<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>BBS</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5/css/xterm.css" />
  <script src="https://cdn.jsdelivr.net/npm/xterm@5/lib/xterm.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.8/lib/xterm-addon-fit.js"></script>
  <style>
    html, body { margin: 0; padding: 0; background: #000; height: 100%; }
    #terminal  { height: 100vh; }
  </style>
</head>
<body>
  <div id="terminal"></div>
  <script>
    const term = new Terminal({ cursorBlink: true, convertEol: false });
    const fitAddon = new FitAddon.FitAddon();
    term.loadAddon(fitAddon);
    term.open(document.getElementById('terminal'));
    fitAddon.fit();
    window.addEventListener('resize', () => fitAddon.fit());

    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    const ws = new WebSocket(proto + '://' + location.host + '/ws');
    ws.binaryType = 'arraybuffer';

    ws.onopen  = () => term.focus();
    ws.onclose = () => term.write('\r\n\x1b[31mConnection closed.\x1b[0m\r\n');
    ws.onerror = () => term.write('\r\n\x1b[31mConnection error.\x1b[0m\r\n');

    ws.onmessage = (event) => {
      if (event.data instanceof ArrayBuffer) {
        term.write(new Uint8Array(event.data));
      } else {
        term.write(event.data);
      }
    };

    term.onData((data) => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(new TextEncoder().encode(data));
      }
    });
  </script>
</body>
</html>
"#;
