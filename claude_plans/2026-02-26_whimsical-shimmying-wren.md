# Plan: Terminal Size Awareness

## Context

The BBS has no concept of terminal dimensions. `bbs.pager()` is a stub that dumps text without
pagination. SSH's `pty_request` discards col/row. Telnet parses NAWS but only logs the values.
WebSocket (xterm.js) calls `fitAddon.fit()` client-side but never informs the server.

Goal: per-session terminal size tracking wired through all three protocol handlers, exposed to
Lua as `bbs.terminal.cols()` / `bbs.terminal.rows()`, and a real paginating `bbs.pager()`.

---

## Design

Size lives in `Terminal` as `Arc<(AtomicU16, AtomicU16)>` (default 80×24). Since `Terminal` is
`Clone` and all clones share the same `Arc`, any handler holding a clone can call `set_size()`
and the session sees the update immediately — no separate channels or config fields needed.

WebSocket resize framing: `fitAddon.onResize` sends a 5-byte binary frame
`[0x01, ch, cl, rh, rl]` (type byte `1` + cols BE u16 + rows BE u16).
All other frames remain raw input — unambiguous, no JSON parsing.

---

## Files to Modify

| File | Change |
|---|---|
| `crates/bbs-tui/src/terminal.rs` | Add `size: Arc<(AtomicU16, AtomicU16)>`; add `set_size()` / `size()` |
| `crates/bbs-telnet/src/lib.rs` | Pass `Terminal` clone to `read_pump`; call `set_size` in `process_subneg` |
| `crates/bbs-ssh/src/lib.rs` | Capture size in `pty_request`; store terminal clone; handle `window_change_request` |
| `crates/bbs-web/src/lib.rs` | JS: send resize frame on open/resize; Rust: detect `[0x01,…]` and call `set_size` |
| `crates/bbs-runtime/src/api.rs` | Register `bbs.terminal` table with `cols()`/`rows()`; implement real `bbs.pager()` |
| `crates/bbs-doors/src/api.rs` | Register `door.terminal` table with `cols()`/`rows()` |

---

## Phase 1 — `crates/bbs-tui/src/terminal.rs`

Add `size` field using `std::sync::atomic::AtomicU16`:

```rust
use std::sync::atomic::{AtomicU16, Ordering};

#[derive(Clone)]
pub struct Terminal {
    writer: mpsc::Sender<Bytes>,
    reader: Arc<Mutex<mpsc::Receiver<u8>>>,
    size:   Arc<(AtomicU16, AtomicU16)>,   // (cols, rows), default 80×24
}

impl Terminal {
    pub fn new(writer: mpsc::Sender<Bytes>, reader: mpsc::Receiver<u8>) -> Self {
        Self {
            writer,
            reader: Arc::new(Mutex::new(reader)),
            size: Arc::new((AtomicU16::new(80), AtomicU16::new(24))),
        }
    }

    pub fn set_size(&self, cols: u16, rows: u16) {
        self.size.0.store(cols, Ordering::Relaxed);
        self.size.1.store(rows, Ordering::Relaxed);
    }

    pub fn size(&self) -> (u16, u16) {
        (self.size.0.load(Ordering::Relaxed), self.size.1.load(Ordering::Relaxed))
    }

    // existing writer() and reader() methods unchanged
}
```

---

## Phase 2 — `crates/bbs-telnet/src/lib.rs`

Pass a terminal clone to `read_pump` so NAWS updates reach the live session:

```rust
// In handle_connection:
let terminal = Terminal::new(out_tx, byte_rx);
tokio::spawn(write_pump(write_half, out_rx));
tokio::spawn(read_pump(read_half, byte_tx, terminal.clone()));  // add clone
bbs_runtime::spawn_session(terminal, config);
```

Update signatures:
```rust
async fn read_pump(reader: OwnedReadHalf, tx: mpsc::Sender<u8>, terminal: Terminal)
```

Call site: `process_subneg(&subneg, &terminal);`

```rust
fn process_subneg(buf: &[u8], terminal: &Terminal) {
    if buf.first() == Some(&OPT_NAWS) && buf.len() >= 5 {
        let cols = u16::from_be_bytes([buf[1], buf[2]]);
        let rows = u16::from_be_bytes([buf[3], buf[4]]);
        terminal.set_size(cols, rows);
        debug!("NAWS: terminal size {cols}x{rows}");
    }
}
```

---

## Phase 3 — `crates/bbs-ssh/src/lib.rs`

Add fields to `SshHandler`:
```rust
struct SshHandler {
    config:       Arc<RuntimeConfig>,
    byte_tx:      Option<mpsc::Sender<u8>>,
    pending_size: (u16, u16),          // from pty_request, applied in shell_request
    terminal:     Option<Terminal>,    // kept for window_change_request
}
```

Default in `new_client`: `pending_size: (80, 24), terminal: None`

`pty_request`: `self.pending_size = (col_width as u16, row_height as u16);`

`shell_request`:
```rust
let terminal = Terminal::new(out_tx, byte_rx);
terminal.set_size(self.pending_size.0, self.pending_size.1);
self.terminal = Some(terminal.clone());
self.byte_tx = Some(byte_tx);
// ... write pump + spawn_session as before ...
```

Add `window_change_request`:
```rust
async fn window_change_request(
    &mut self, _channel: ChannelId,
    col_width: u32, row_height: u32,
    _pix_width: u32, _pix_height: u32,
    _session: &mut Session,
) -> Result<(), Self::Error> {
    if let Some(term) = &self.terminal {
        term.set_size(col_width as u16, row_height as u16);
    }
    Ok(())
}
```

---

## Phase 4 — `crates/bbs-web/src/lib.rs`

**Rust `handle_socket`**: hold terminal for resize detection:
```rust
async fn handle_socket(socket: WebSocket, config: Arc<RuntimeConfig>) {
    // ... channel setup, spawn write pump, spawn_session as before ...
    // terminal is now kept in scope for the read loop:

    while let Some(msg) = receiver.next().await {
        match msg {
            Ok(Message::Binary(data)) => {
                if data.len() == 5 && data[0] == 1 {
                    let cols = u16::from_be_bytes([data[1], data[2]]);
                    let rows = u16::from_be_bytes([data[3], data[4]]);
                    terminal.set_size(cols, rows);
                    continue;
                }
                for &b in &data { byte_tx.send(b).await.ok(); }
            }
            // text, close, err unchanged
        }
    }
}
```

**JavaScript additions** in `XTERM_HTML`:
```javascript
function sendResize() {
    if (ws.readyState !== WebSocket.OPEN) return;
    const buf = new Uint8Array(5);
    buf[0] = 1;
    buf[1] = term.cols >> 8;  buf[2] = term.cols & 0xff;
    buf[3] = term.rows >> 8;  buf[4] = term.rows & 0xff;
    ws.send(buf);
}

ws.onopen = () => { fitAddon.fit(); sendResize(); term.focus(); };
window.addEventListener('resize', () => { fitAddon.fit(); sendResize(); });
```

---

## Phase 5 — `crates/bbs-runtime/src/api.rs`

### `bbs.terminal` table
```rust
let term_tbl = lua.create_table()?;
{
    let t = terminal.clone();
    term_tbl.set("cols", lua.create_function(move |_, ()| Ok(t.size().0 as i64))?)?;
}
{
    let t = terminal.clone();
    term_tbl.set("rows", lua.create_function(move |_, ()| Ok(t.size().1 as i64))?)?;
}
bbs.set("terminal", term_tbl)?;
```

### Real `bbs.pager(text)` — replace the stub

Replace the current 3-line stub with a paginating implementation that:
1. Splits `text` on `\n`
2. Writes lines one at a time, counting rows shown on the current page
3. At `rows - 2` lines per page shows: `\r\x1b[7m-- More (N%) [Space=page Enter=line Q=quit] --\x1b[0m`
4. Reads one byte from `rx`: Space/other = next full page; Enter = one more line; Q = abort
5. Clears the prompt with `\r\x1b[2K` before continuing

The function needs to capture both `tx` (already captured) and `rx` (needs to be added) plus
`terminal.clone()` for live row count. Uses `rx.lock().await.recv().await` for the keypress,
same pattern as `bbs.read_key()`.

---

## Phase 6 — `crates/bbs-doors/src/api.rs`

Mirror of Phase 5 — add `door.terminal` table with `cols()` and `rows()` functions using the
same `terminal.clone()` pattern already present in the file.

---

## Verification

```bash
cargo build
cargo clippy --all -- -D warnings

RUST_LOG=info cargo run -p bbs-server

# Telnet: connect with a client that sends NAWS (most do automatically)
# After connecting: bbs.writeln(tostring(bbs.terminal.cols()) .. "x" .. tostring(bbs.terminal.rows()))

# SSH: pty size sent on connect
ssh -p 2222 -o StrictHostKeyChecking=no -o PreferredAuthentications=none bbs@localhost

# WebSocket: open http://localhost:8080, resize window — server updates live

# Pager test: post a long message to a board, then read it — should paginate
```
