//! Cloneable channel-based terminal I/O handle.
//! Shared between bbs-tui, bbs-telnet, and bbs-runtime.

use std::sync::Arc;

use bytes::Bytes;
use tokio::sync::{mpsc, Mutex};

/// A cloneable handle to a user's terminal.
///
/// `writer` — send [`Bytes`] to the TCP write pump.
/// `reader` — receive raw input bytes from the TCP read pump (IAC-stripped).
#[derive(Clone)]
pub struct Terminal {
    writer: mpsc::Sender<Bytes>,
    reader: Arc<Mutex<mpsc::Receiver<u8>>>,
}

impl Terminal {
    pub fn new(writer: mpsc::Sender<Bytes>, reader: mpsc::Receiver<u8>) -> Self {
        Self {
            writer,
            reader: Arc::new(Mutex::new(reader)),
        }
    }

    /// Cheap clone of the sender — use to write to the terminal.
    pub fn writer(&self) -> &mpsc::Sender<Bytes> {
        &self.writer
    }

    /// Arc clone of the reader — lock to read a byte from the terminal.
    pub fn reader(&self) -> Arc<Mutex<mpsc::Receiver<u8>>> {
        Arc::clone(&self.reader)
    }
}
