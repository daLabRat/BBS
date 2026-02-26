//! Cloneable channel-based terminal I/O handle.
//! Shared between bbs-tui, bbs-telnet, and bbs-runtime.

use std::sync::atomic::{AtomicU16, Ordering};
use std::sync::Arc;

use bytes::Bytes;
use tokio::sync::{mpsc, Mutex};

/// A cloneable handle to a user's terminal.
///
/// `writer` — send [`Bytes`] to the TCP write pump.
/// `reader` — receive raw input bytes from the TCP read pump (IAC-stripped).
/// `size`   — live terminal dimensions, updated by protocol handlers.
#[derive(Clone)]
pub struct Terminal {
    writer: mpsc::Sender<Bytes>,
    reader: Arc<Mutex<mpsc::Receiver<u8>>>,
    size:   Arc<(AtomicU16, AtomicU16)>, // (cols, rows), default 80×24
}

impl Terminal {
    pub fn new(writer: mpsc::Sender<Bytes>, reader: mpsc::Receiver<u8>) -> Self {
        Self {
            writer,
            reader: Arc::new(Mutex::new(reader)),
            size: Arc::new((AtomicU16::new(80), AtomicU16::new(24))),
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

    /// Update the terminal dimensions.  All clones share the same `Arc` so
    /// changes are immediately visible across protocol handlers and the session.
    pub fn set_size(&self, cols: u16, rows: u16) {
        self.size.0.store(cols, Ordering::Relaxed);
        self.size.1.store(rows, Ordering::Relaxed);
    }

    /// Return the current `(cols, rows)`.
    pub fn size(&self) -> (u16, u16) {
        (
            self.size.0.load(Ordering::Relaxed),
            self.size.1.load(Ordering::Relaxed),
        )
    }
}
