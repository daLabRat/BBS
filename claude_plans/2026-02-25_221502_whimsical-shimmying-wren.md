# Plan: Implement Telnet Listener (end-to-end)

## Context

The `bbs-telnet`, `bbs-runtime`, and `bbs-server` crates are stubs. This implements the full
path: TCP accept → telnet IAC parsing → tokio channels → mlua Lua VM → `scripts/main.lua` →
interactive BBS session. After this, `telnet localhost 2323` should reach the login prompt and
main menu.

---

## Files to modify

| File | Change |
|---|---|
| `Cargo.toml` | Add `bytes = "1"` to `[workspace.dependencies]` |
| `crates/bbs-tui/Cargo.toml` | Add `bytes = { workspace = true }` |
| `crates/bbs-tui/src/lib.rs` | Add `pub mod terminal` + `pub use terminal::Terminal` |
| `crates/bbs-tui/src/terminal.rs` | New: `Terminal` struct (cloneable channel pair) |
| `crates/bbs-telnet/Cargo.toml` | Add `bytes = { workspace = true }` |
| `crates/bbs-telnet/src/lib.rs` | Full telnet implementation |
| `crates/bbs-runtime/Cargo.toml` | Add `bytes = { workspace = true }` |
| `crates/bbs-runtime/src/lib.rs` | Export `RuntimeConfig`; re-export `Terminal` from bbs-tui |
| `crates/bbs-runtime/src/session.rs` | Replace stub with real Lua VM session |
| `crates/bbs-runtime/src/api.rs` | Implement full `bbs.*` API |
| `crates/bbs-server/src/main.rs` | Load config, build `RuntimeConfig`, spawn telnet listener |
| `scripts/auth.lua` | Set `bbs.user.name/id/is_sysop` after successful login |

---

## Design

### 1. Terminal I/O abstraction (`crates/bbs-tui/src/terminal.rs`)

```rust
#[derive(Clone)]
pub struct Terminal {
    writer: mpsc::Sender<Bytes>,
    reader: Arc<tokio::sync::Mutex<mpsc::Receiver<u8>>>,
}
impl Terminal {
    pub fn new(writer: mpsc::Sender<Bytes>, reader: mpsc::Receiver<u8>) -> Self
    pub fn writer(&self) -> &mpsc::Sender<Bytes>
    pub fn reader(&self) -> Arc<tokio::sync::Mutex<mpsc::Receiver<u8>>>
}
```

Lives in `bbs-tui` (no circular deps). Cloneable because `Sender` is Clone and `reader` is
behind `Arc`.

---

### 2. Telnet protocol (`crates/bbs-telnet/src/lib.rs`)

**`pub async fn serve(addr: &str, config: Arc<RuntimeConfig>) -> Result<()>`**

Per connection:
1. `socket.set_nodelay(true)`, split into `OwnedReadHalf` / `OwnedWriteHalf`
2. Create channels: `(byte_tx, byte_rx): mpsc::channel::<u8>(1024)`, `(out_tx, out_rx): mpsc::channel::<Bytes>(64)`
3. `Terminal::new(out_tx, byte_rx)`
4. Write initial negotiation: `[IAC WILL ECHO, IAC WILL SGA, IAC DO SGA, IAC DO NAWS]`
5. Spawn **read pump** task (`OwnedReadHalf` → `byte_tx`)
6. Spawn **write pump** task (`out_rx` → `OwnedWriteHalf`)
7. `Session::new(terminal, config).run().await` in the connection task

**Read pump — IAC state machine:**
```
States: Data | Iac | Cmd(u8) | Sb | SbIac
```
- `Data`: byte < 255 → emit (with CR/LF normalisation); 255 → `Iac`
- `Iac`: WILL/WONT/DO/DONT → `Cmd(verb)`; SB → `Sb`; IAC → emit IAC, `Data`; else → `Data`
- `Cmd(_)`: consume option byte, back to `Data` (accept silently)
- `Sb`: collect into subneg buf; IAC → `SbIac`
- `SbIac`: SE → process subneg (log NAWS width×height), `Data`; else → back to `Sb`

**CR/LF normalisation** (prev_cr flag):
- `CR LF` → emit `\n`
- `CR NUL` → drop
- bare `CR` → set flag, emit nothing yet
- bare `LF` → emit `\n`

---

### 3. RuntimeConfig + Session (`crates/bbs-runtime`)

```rust
// lib.rs exports:
pub struct RuntimeConfig { pub scripts_dir: PathBuf }
pub use session::Session;
pub use bbs_tui::terminal::Terminal;
```

```rust
// session.rs
pub struct Session { terminal: Terminal, config: Arc<RuntimeConfig> }
impl Session {
    pub fn new(terminal: Terminal, config: Arc<RuntimeConfig>) -> Self
    pub async fn run(self) -> Result<()> {
        let lua = mlua::Lua::new();
        // set package.path = "{scripts_dir}/?.lua"
        api::register(&lua, self.terminal)?;
        let src = tokio::fs::read_to_string(scripts_dir.join("main.lua")).await?;
        lua.load(&src).set_name("main.lua").call_async::<()>(()).await
    }
}
```

---

### 4. bbs.* API (`crates/bbs-runtime/src/api.rs`)

`pub fn register(lua: &mlua::Lua, terminal: Terminal) -> Result<()>`

mlua pattern — capture Arc-wrapped channel handles in `'static + Send` closures; clone before
any `.await`:

```rust
let tx = terminal.writer().clone();   // Sender<Bytes> — cheap clone
let rx = terminal.reader();           // Arc<Mutex<Receiver<u8>>>

let tx1 = tx.clone();
let write_fn = lua.create_async_function(move |_lua, text: String| {
    let tx = tx1.clone();
    async move { tx.send(Bytes::from(text)).await.ok(); Ok(()) }
})?;
```

**API table:**

| Lua call | Implementation |
|---|---|
| `bbs.write(s)` | `tx.send(Bytes::from(s))` |
| `bbs.writeln(s)` | `tx.send(Bytes::from(s + "\r\n"))` |
| `bbs.clear()` | send `"\x1b[2J\x1b[H"` |
| `bbs.read_key()` | lock rx, recv 1 byte → `Option<String>` (**no echo**) |
| `bbs.read_line(prompt)` | send prompt; loop: printable→echo+append, `\x08`/DEL→erase, `\n`→break, `Ctrl-C/D`→nil |
| `bbs.ansi(name)` | `bbs_tui::ansi::named(name)` |
| `bbs.time()` | `SystemTime::now()` as `i64` unix secs |
| `bbs.pager(text)` | `tx.send(text + "\r\n")` (simple, no paging yet) |
| `bbs.menu(_)` | stub no-op (not called by current scripts) |
| `bbs.user` | mutable Lua table `{name="guest", id=0, is_sysop=false}` |
| `bbs.boards.list()` | empty Lua table (DB not wired yet) |
| `bbs.boards.read(id)` | empty Lua table |
| `bbs.boards.post(id,s,b)` | no-op |
| `bbs.doors.list()` | empty Lua table |
| `bbs.doors.launch(name)` | no-op |

---

### 5. bbs-server wiring (`crates/bbs-server/src/main.rs`)

```rust
let cfg = Config::builder()
    .add_source(File::with_name("config/default").required(false))
    .build()?;
let telnet_bind  = cfg.get_string("telnet.bind").unwrap_or("0.0.0.0:2323");
let scripts_dir  = cfg.get_string("paths.scripts").unwrap_or("scripts");
let runtime_config = Arc::new(RuntimeConfig { scripts_dir: scripts_dir.into() });
bbs_telnet::serve(&telnet_bind, runtime_config).await?;
```

---

### 6. scripts/auth.lua update

After accepting credentials in both `M.login()` and `M.register()`, add:
```lua
bbs.user.name     = username
bbs.user.id       = 0
bbs.user.is_sysop = (username:lower() == "sysop")
```

---

## Verification

```bash
cargo build
cargo clippy --all -- -D warnings
RUST_LOG=info cargo run -p bbs-server
# In another terminal:
telnet localhost 2323
# Expected: ANSI banner, "Please log in", username/password prompts,
#           "Hello, <name>!", main menu ([M] [D] [S] [Q])
```
