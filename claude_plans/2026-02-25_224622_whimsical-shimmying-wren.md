# Plan: BBS Full Feature Implementation

## Context

Telnet works end-to-end. This implements all remaining features:
real DB auth, password masking, message boards, the door system, SSH, web terminal, and NNTP.

---

## Key Architectural Decision: Thread-per-session

`mlua::AsyncThread` is `!Send`, so the BBS session Lua VM cannot run inside a `tokio::spawn`.
Solution: every BBS session gets a `std::thread::spawn` with an embedded
`tokio::runtime::current_thread` + `LocalSet`. All I/O pumps (read/write/WebSocket/SSH) stay
in the main multi-thread runtime and talk to the session via `tokio::sync::mpsc` channels
(which are runtime-agnostic).

Consequence: all `serve()` functions become `Send` futures and can be `tokio::try_join!`'d.
The current `LocalSet` hack in bbs-telnet is removed.

Session spawn helper (reused in telnet, ssh, web):
```rust
fn spawn_session(terminal: Terminal, config: Arc<RuntimeConfig>) {
    std::thread::Builder::new()
        .name("bbs-session".into())
        .spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all().build().unwrap();
            let local = tokio::task::LocalSet::new();
            rt.block_on(local.run_until(async move {
                if let Err(e) = Session::new(terminal, config).run().await {
                    tracing::error!("session error: {e}");
                }
            }));
        }).expect("thread spawn");
}
```

---

## Files to Create / Modify

| File | Action |
|---|---|
| `crates/bbs-core/src/auth.rs` | **New** — argon2 hash/verify |
| `crates/bbs-core/src/db.rs` | Add query methods (users/boards/messages) |
| `crates/bbs-core/src/user.rs` | Add `sqlx::FromRow` derive |
| `crates/bbs-core/src/board.rs` | Add `sqlx::FromRow` derive |
| `crates/bbs-core/src/message.rs` | Add `sqlx::FromRow` derive |
| `crates/bbs-core/src/lib.rs` | Export `auth` module |
| `crates/bbs-core/Cargo.toml` | Add `rand = "0.8"` |
| `crates/bbs-runtime/src/lib.rs` | Add `db: Arc<Database>` + `doors_dir: PathBuf` to `RuntimeConfig`; add `spawn_session` helper |
| `crates/bbs-runtime/src/session.rs` | Pass config (with db+doors_dir) to `api::register` |
| `crates/bbs-runtime/src/api.rs` | Wire real auth, boards, doors; add `bbs.read_pass` |
| `crates/bbs-telnet/src/lib.rs` | Remove LocalSet; `tokio::spawn` for I/O, `spawn_session` for Lua |
| `crates/bbs-doors/src/api.rs` | Full `door.*` Lua API implementation |
| `crates/bbs-doors/src/runner.rs` | Full DoorRunner (mlua VM, api::register, DoorExit) |
| `crates/bbs-doors/src/store.rs` | Use non-macro sqlx queries |
| `crates/bbs-doors/Cargo.toml` | Add `bbs-tui`, `bytes` |
| `crates/bbs-ssh/src/lib.rs` | Full russh 0.44 server |
| `crates/bbs-ssh/Cargo.toml` | Add `bytes`, `russh-keys`, `async-trait` |
| `crates/bbs-web/src/lib.rs` | Full axum + WebSocket terminal bridge |
| `crates/bbs-web/Cargo.toml` | `axum = { features = ["ws"] }`, `bytes`, `futures-util` |
| `crates/bbs-nntp/src/lib.rs` | Full NNTP server |
| `crates/bbs-server/src/main.rs` | Connect DB, migrate, `try_join!` all listeners |
| `scripts/auth.lua` | Use `bbs.auth.login/register` + `bbs.read_pass` |

---

## Phase 1 — bbs-core: auth + query methods

### `crates/bbs-core/src/auth.rs` (new)
```rust
pub fn hash_password(password: &str) -> Result<String>    // argon2 hash
pub fn verify_password(password: &str, hash: &str) -> Result<bool>
```
Deps: `argon2 = "0.5"` (already present), add `rand = "0.8"` for `rand::rngs::OsRng`.

### Domain structs: add `#[derive(sqlx::FromRow)]` to User, Board, Message.

### `crates/bbs-core/src/db.rs` — add to `impl Database`:
```rust
// Users
pub async fn find_user_by_username(&self, u: &str) -> Result<Option<User>>
pub async fn create_user(&self, u: &str, hash: &str) -> Result<User>
pub async fn update_last_login(&self, id: i64) -> Result<()>

// Boards
pub async fn list_boards(&self) -> Result<Vec<Board>>

// Messages (returns Vec<(Message, author_username)>)
pub async fn list_messages(&self, board_id: i64) -> Result<Vec<(Message, String)>>
pub async fn post_message(&self, board_id: i64, author_id: i64, subject: &str, body: &str) -> Result<i64>
```
Use non-macro `sqlx::query_as::<_, T>(sql).bind(...)` (no compile-time DB required).
`list_messages` does `JOIN users ON users.id = messages.author_id` and maps rows manually.

---

## Phase 2 — bbs-runtime: wire auth, boards, doors, read_pass

### `RuntimeConfig`
```rust
pub struct RuntimeConfig {
    pub scripts_dir: PathBuf,
    pub doors_dir:   PathBuf,
    pub db:          Arc<Database>,
}
```

### `api::register` signature change
```rust
pub fn register(lua: &Lua, terminal: Terminal, config: &RuntimeConfig) -> Result<()>
```

### New/changed bbs.* API items

| Lua call | Implementation |
|---|---|
| `bbs.read_pass(prompt)` | Same as `read_line` but **no echo** (don't send chars back) |
| `bbs.auth.login(u, p)` | `db.find_user_by_username` + `auth::verify_password` → `{name,id,is_sysop}` or nil |
| `bbs.auth.register(u, p)` | `auth::hash_password` + `db.create_user` → `{name,id,is_sysop}` or nil on duplicate |
| `bbs.boards.list()` | `db.list_boards()` → `[{id,name,description}]` |
| `bbs.boards.read(id)` | `db.list_messages(id)` → `[{id,subject,author,created_at,body}]` |
| `bbs.boards.post(id,s,b)` | read `bbs.user.id` from lua globals → `db.post_message` |
| `bbs.doors.list()` | `DoorRegistry::new(&doors_dir).list()` → string array |
| `bbs.doors.launch(name)` | build `DoorUser` from `bbs.user`; `DoorRunner::new(db,terminal).run(path,user).await` |

`bbs.auth.register` returns nil (not an error) on username collision so Lua can handle it gracefully.

---

## Phase 3 — bbs-telnet: remove LocalSet

```rust
// handle_connection: spawn I/O pumps as tokio tasks (unchanged),
// then call the session helper instead of run().await:
bbs_runtime::spawn_session(terminal, config);
// Return Ok(()) immediately — pumps + session thread manage their own lifetime
```

---

## Phase 4 — bbs-doors: full implementation

### `src/api.rs` — `pub fn register(lua, terminal, user: &DoorUser, store: Arc<DoorStore>) -> Result<()>`

Mirror of bbs-runtime api.rs but for the `door` global:
- `write/writeln/clear/read_key/read_line/ansi/time` — same channel pattern
- `sleep(ms)` — `tokio::time::sleep(Duration::from_millis(ms))`
- `exit()` — `Err(LuaError::ExternalError(Arc::new(DoorExit)))` where `DoorExit: pub std::error::Error`
- `user` — read-only table from `DoorUser` snapshot (no writes allowed)
- `data.get(key)` / `data.set(key, val)` — delegate to `Arc<DoorStore>`

### `src/runner.rs` — `impl DoorRunner`
```rust
pub fn new(db: Arc<Database>, terminal: Terminal) -> Self
pub async fn run(&self, lua_path: &str, user: &DoorUser) -> Result<()>
// Creates Lua VM, builds DoorStore, calls api::register, loads+runs main.lua,
// catches DoorExit sentinel as Ok(())
```

### `src/store.rs` — replace `sqlx::query!` macros with non-macro `sqlx::query()`

---

## Phase 5 — bbs-ssh: russh 0.44

**Host key**: try `config/host_key.pem`; if missing, generate Ed25519 + write PEM to that file.

```
SshServer { config: Arc<RuntimeConfig> }
  → new_client() → SshHandler { config, byte_tx: None, channel_id: None, handle: None }

Handler::auth_password   → Auth::Accept (BBS auth happens inside main.lua)
Handler::channel_open_session → store channel_id + session.handle()
Handler::data            → forward bytes to byte_tx
Handler::shell_request   → create channels + Terminal; spawn tokio write pump
                           (reads out_rx → handle.data(channel, CryptoVec));
                           call spawn_session(terminal, config)
```

Cargo additions: `russh-keys` (for key gen/load), `async-trait`, `bytes`.

---

## Phase 6 — bbs-web: axum WebSocket

```
GET /   → serve inline HTML (xterm.js 5.x from CDN, WebSocket client)
GET /ws → WebSocket upgrade
```

WebSocket handler:
- Split socket; spawn tokio write pump (out_rx → ws binary frame)
- Spawn tokio read pump (ws binary/text frames → byte_tx per byte)
- Call `spawn_session(terminal, config)`

HTML embeds a minimal xterm.js terminal that connects to `ws://{host}/ws` and passes binary frames directly.

Cargo: `axum = { version = "0.7", features = ["ws"] }`, add `bytes`, `futures-util`.

---

## Phase 7 — bbs-nntp: NNTP server

Stateful per-connection handler. State: `{ db, server_name, current_group_id, current_article_id, pending_auth_user }`.

Line-by-line command loop. Supported commands:

| Command | Response |
|---|---|
| `CAPABILITIES` | 101 + VERSION 2, READER, OVER, HDR |
| `LIST [ACTIVE]` | 215 + one line per board |
| `GROUP <newsgroup>` | 211 count first last name |
| `ARTICLE/HEAD/BODY/STAT [n]` | 220/221/222/223 with proper headers |
| `OVER <range>` | 224 + tab-separated overview lines |
| `NEXT` / `LAST` | 223 or 421 |
| `AUTHINFO USER <u>` / `AUTHINFO PASS <p>` | 381 / 281 or 481 |
| `POST` | 340 → read article → 240 or 441 |
| `DATE` | 111 YYYYMMDDHHmmss |
| `QUIT` | 205 |

Article IDs: `<{id}@bbs>`. Dates: RFC 2822.
Newsgroups come from `boards.newsgroup_name` (non-null boards only in LIST).

---

## Phase 8 — bbs-server: wire everything

```rust
let db = Arc::new(Database::connect(&db_url).await?);
db.migrate().await?;
let cfg = Arc::new(RuntimeConfig { scripts_dir, doors_dir, db: Arc::clone(&db) });

tokio::try_join!(
    bbs_telnet::serve(&telnet_bind, Arc::clone(&cfg)),
    bbs_ssh::serve(&ssh_bind,       Arc::clone(&cfg)),
    bbs_web::serve(&http_bind,      Arc::clone(&cfg)),
    bbs_nntp::serve(&nntp_bind,     Arc::clone(&db)),
)?;
```

---

## Phase 9 — scripts/auth.lua

```lua
-- login (replaces stub):
local user = bbs.auth.login(username, bbs.read_pass("Password: "))
if user then
    bbs.user.name, bbs.user.id, bbs.user.is_sysop = user.name, user.id, user.is_sysop
    return true
end
bbs.writeln("Invalid credentials.")
return false

-- register (replaces stub):
local user = bbs.auth.register(username, bbs.read_pass("Choose a password: "))
if user then
    bbs.user.name, bbs.user.id, bbs.user.is_sysop = user.name, user.id, user.is_sysop
    return true
end
bbs.writeln("Registration failed (username taken).")
return false
```

---

## Verification

```bash
cargo build
cargo clippy --all -- -D warnings

DATABASE_URL=sqlite:bbs.db sqlx migrate run
RUST_LOG=info cargo run -p bbs-server

telnet localhost 2323                              # register, boards, doors
ssh -p 2222 -o StrictHostKeyChecking=no x@localhost  # SSH session
open http://localhost:8080                         # web xterm.js

# NNTP:
telnet localhost 1119
LIST
GROUP local.general
OVER 1-100
QUIT
```
