//! Raw TCP listener with telnet IAC state machine.
//! Accepts connections on the telnet port and runs a bbs-runtime Session per connection.

use std::sync::Arc;

use anyhow::Result;
use bbs_runtime::{RuntimeConfig, Session, Terminal};
use bytes::Bytes;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tracing::{debug, error, info};

// Telnet protocol constants
const IAC: u8 = 255;
const WILL: u8 = 251;
const WONT: u8 = 252;
const DO: u8 = 253;
const DONT: u8 = 254;
const SB: u8 = 250;
const SE: u8 = 240;
const OPT_ECHO: u8 = 1;
const OPT_SGA: u8 = 3;
const OPT_NAWS: u8 = 31;

/// Start the telnet listener and accept connections forever.
///
/// Connections are handled inside a [`tokio::task::LocalSet`] so that each
/// session's mlua Lua VM (which is `!Send`) can use `call_async` freely.
pub async fn serve(addr: &str, config: Arc<RuntimeConfig>) -> Result<()> {
    let listener = TcpListener::bind(addr).await?;
    info!("Telnet listening on {addr}");

    let local = tokio::task::LocalSet::new();
    local
        .run_until(async move {
            loop {
                let (socket, peer) = listener.accept().await?;
                info!("Telnet connection from {peer}");
                let cfg = Arc::clone(&config);
                tokio::task::spawn_local(async move {
                    if let Err(e) = handle_connection(socket, cfg).await {
                        error!("Telnet session error from {peer}: {e}");
                    }
                    info!("Telnet connection closed: {peer}");
                });
            }
            #[allow(unreachable_code)]
            Ok::<(), anyhow::Error>(())
        })
        .await
}

async fn handle_connection(
    socket: tokio::net::TcpStream,
    config: Arc<RuntimeConfig>,
) -> Result<()> {
    socket.set_nodelay(true)?;
    let (read_half, mut write_half) = socket.into_split();

    // Send initial telnet option negotiations:
    //   WILL ECHO — server will echo characters
    //   WILL SGA  — suppress go-ahead (full-duplex)
    //   DO   SGA  — ask client to suppress go-ahead
    //   DO   NAWS — ask client to report window size
    let negot: &[u8] = &[
        IAC, WILL, OPT_ECHO, IAC, WILL, OPT_SGA, IAC, DO, OPT_SGA, IAC, DO, OPT_NAWS,
    ];
    write_half.write_all(negot).await?;

    // Channels: TCP read → byte_tx → (IAC stripped, CR/LF normalised) → Session
    //           Session → out_tx → out_rx → TCP write
    let (byte_tx, byte_rx) = mpsc::channel::<u8>(1024);
    let (out_tx, out_rx) = mpsc::channel::<Bytes>(64);

    let terminal = Terminal::new(out_tx, byte_rx);

    tokio::spawn(write_pump(write_half, out_rx));
    tokio::spawn(read_pump(read_half, byte_tx));

    Session::new(terminal, config).run().await
}

/// Write pump: drain the output channel and send to TCP.
async fn write_pump(mut writer: OwnedWriteHalf, mut rx: mpsc::Receiver<Bytes>) {
    while let Some(data) = rx.recv().await {
        if writer.write_all(&data).await.is_err() {
            break;
        }
    }
}

/// Read pump: read from TCP, strip telnet IAC sequences, normalise CR/LF,
/// and forward raw input bytes to the session channel.
async fn read_pump(mut reader: OwnedReadHalf, tx: mpsc::Sender<u8>) {
    #[derive(Debug)]
    enum State {
        Data,
        Iac,
        Cmd(u8), // verb (WILL/WONT/DO/DONT), waiting for option byte
        Sb,      // inside subnegotiation
        SbIac,   // IAC seen inside subnegotiation (expecting SE or escape)
    }

    let mut state = State::Data;
    let mut subneg: Vec<u8> = Vec::new();
    let mut prev_cr = false;
    let mut buf = [0u8; 256];

    'outer: loop {
        let n = match reader.read(&mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };

        for &byte in &buf[..n] {
            match state {
                State::Data => {
                    if byte == IAC {
                        // Flush any pending bare CR before entering IAC
                        if prev_cr {
                            prev_cr = false;
                            if tx.send(b'\r').await.is_err() {
                                break 'outer;
                            }
                        }
                        state = State::Iac;
                    } else {
                        // CR/LF normalisation
                        if prev_cr {
                            prev_cr = false;
                            match byte {
                                b'\n' => {
                                    // CR LF → \n
                                    if tx.send(b'\n').await.is_err() {
                                        break 'outer;
                                    }
                                }
                                b'\0' => {
                                    // CR NUL → drop (bare Enter on some clients)
                                }
                                _ => {
                                    // Bare CR followed by something else — emit CR then fall through
                                    if tx.send(b'\r').await.is_err() {
                                        break 'outer;
                                    }
                                    if emit_data_byte(byte, &mut prev_cr, &tx).await {
                                        break 'outer;
                                    }
                                }
                            }
                        } else if emit_data_byte(byte, &mut prev_cr, &tx).await {
                            break 'outer;
                        }
                    }
                }

                State::Iac => {
                    state = match byte {
                        WILL | WONT | DO | DONT => State::Cmd(byte),
                        SB => {
                            subneg.clear();
                            State::Sb
                        }
                        IAC => {
                            // Escaped IAC — emit a literal 0xFF
                            if tx.send(IAC).await.is_err() {
                                break 'outer;
                            }
                            State::Data
                        }
                        _ => State::Data,
                    };
                }

                State::Cmd(_verb) => {
                    // Option byte — silently accept all options for now
                    state = State::Data;
                }

                State::Sb => {
                    if byte == IAC {
                        state = State::SbIac;
                    } else {
                        subneg.push(byte);
                    }
                }

                State::SbIac => {
                    if byte == SE {
                        process_subneg(&subneg);
                        subneg.clear();
                        state = State::Data;
                    } else {
                        // IAC inside subneg that isn't SE — keep collecting
                        subneg.push(IAC);
                        subneg.push(byte);
                        state = State::Sb;
                    }
                }
            }
        }
    }
}

/// Emit a single data byte, handling the CR flag.
/// Returns `true` if the channel is closed (caller should break).
async fn emit_data_byte(byte: u8, prev_cr: &mut bool, tx: &mpsc::Sender<u8>) -> bool {
    match byte {
        b'\r' => {
            *prev_cr = true;
            false
        }
        b'\n' => tx.send(b'\n').await.is_err(),
        b => tx.send(b).await.is_err(),
    }
}

/// Handle a completed subnegotiation buffer.
fn process_subneg(buf: &[u8]) {
    if buf.first() == Some(&OPT_NAWS) && buf.len() >= 5 {
        let w = u16::from_be_bytes([buf[1], buf[2]]);
        let h = u16::from_be_bytes([buf[3], buf[4]]);
        debug!("NAWS: terminal size {w}x{h}");
    }
}
