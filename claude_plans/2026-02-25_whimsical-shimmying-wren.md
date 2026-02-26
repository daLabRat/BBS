# BBS Project Initialization Plan

## Context

The `/mnt/unraid/CLAUDE/BBS` directory is an empty workspace intended for a new Rust-based Bulletin Board System. The user wants to:
1. Initialize a git repository
2. Scaffold a Cargo workspace with a multi-crate architecture
3. Update CLAUDE.md to reflect the actual project

**Stack:** Rust (async via Tokio)
**Protocols:** Telnet/raw TCP, SSH, HTTP/WebSocket, NNTP/FidoNet
**Initial features:** User auth & accounts, Message boards/forums, Door games

---

## Phase 1: Git Initialization

```bash
cd /mnt/unraid/CLAUDE/BBS
git init
```

Create `.gitignore`:
```
/target/
**/*.rs.bk
.env
*.env.local
Cargo.lock   # keep for binaries, omit for libraries — keep it here since this is a server binary
```

(Actually for a binary project, `Cargo.lock` should be committed. The `.gitignore` will NOT exclude it.)

---

## Phase 2: Cargo Workspace Scaffold

### `Cargo.toml` (workspace root)

```toml
[workspace]
members = [
    "crates/bbs-core",
    "crates/bbs-server",
    "crates/bbs-telnet",
    "crates/bbs-ssh",
    "crates/bbs-web",
    "crates/bbs-nntp",
    "crates/bbs-tui",
]
resolver = "2"

[workspace.dependencies]
tokio = { version = "1", features = ["full"] }
anyhow = "1"
thiserror = "1"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
sqlx = { version = "0.7", features = ["sqlite", "runtime-tokio", "migrate", "macros"] }
```

### Crate layout

| Crate | Purpose |
|---|---|
| `bbs-core` | Domain types: User, Message, Board, Session; database layer (sqlx + SQLite); auth (argon2 password hashing) |
| `bbs-server` | Binary entry point; wires up all protocol listeners; config loading |
| `bbs-telnet` | Raw TCP listener; VT100/ANSI terminal state machine; menu navigation |
| `bbs-ssh` | SSH server using `russh`; reuses telnet TUI layer after handshake |
| `bbs-web` | HTTP API + WebSocket terminal emulator via `axum`; serves a basic web terminal |
| `bbs-nntp` | NNTP server for message area access; maps boards to newsgroups |
| `bbs-tui` | Shared ANSI art renderer, menu system, pager; used by telnet and SSH crates |
| `bbs-doors` | Lua door game runtime using `mlua`; exposes the Door API to Lua scripts; manages door lifecycle |

Each crate gets a minimal `Cargo.toml` (with `bbs-core` as a dependency where needed) and a `src/lib.rs` stub.

`bbs-server/src/main.rs` is the binary that imports all protocol crates and spawns listeners concurrently via Tokio.

### Key external dependencies (per crate)

- **bbs-core**: `sqlx`, `argon2`, `uuid`, `chrono`
- **bbs-ssh**: `russh`, `russh-keys`
- **bbs-web**: `axum`, `tower`, `tokio-tungstenite`
- **bbs-telnet**: pure tokio (raw TCP)
- **bbs-nntp**: pure tokio
- **bbs-tui**: `crossterm` (for ANSI sequences)
- **bbs-doors**: `mlua` (Lua 5.4 embedded via feature `lua54,vendored`)

---

## Phase 3: Directory Structure

```
BBS/
├── .gitignore
├── CLAUDE.md
├── Cargo.toml               ← workspace root
├── config/
│   └── default.toml         ← ports, paths, feature flags
├── migrations/
│   └── 0001_initial.sql     ← users, boards, messages, sessions, door_data tables
├── assets/
│   └── welcome.ans          ← placeholder ANSI art
├── doors/                   ← Lua door games (each in its own subdirectory)
│   └── example/
│       └── main.lua
└── crates/
    ├── bbs-core/
    │   ├── Cargo.toml
    │   └── src/
    │       ├── lib.rs
    │       ├── db.rs
    │       ├── user.rs
    │       ├── board.rs
    │       └── message.rs
    ├── bbs-server/
    │   ├── Cargo.toml
    │   └── src/main.rs
    ├── bbs-telnet/
    │   ├── Cargo.toml
    │   └── src/lib.rs
    ├── bbs-ssh/
    │   ├── Cargo.toml
    │   └── src/lib.rs
    ├── bbs-web/
    │   ├── Cargo.toml
    │   └── src/lib.rs
    ├── bbs-nntp/
    │   ├── Cargo.toml
    │   └── src/lib.rs
    ├── bbs-tui/
    │   ├── Cargo.toml
    │   └── src/lib.rs
    └── bbs-doors/           ← Lua door runtime (mlua)
        ├── Cargo.toml
        └── src/
            ├── lib.rs
            ├── registry.rs  ← DoorRegistry
            ├── runner.rs    ← DoorRunner + Lua VM setup
            ├── session.rs   ← DoorSession I/O bridge
            └── store.rs     ← DoorDataStore (sqlx KV)
```

---

## Phase 3b: Lua Door API (`bbs-doors`)

### Architecture

Rust manages the door lifecycle. When a user launches a door:
1. `bbs-server` calls `bbs-doors::DoorRunner::launch(door_name, session)`
2. `DoorRunner` loads the `.lua` file from `doors/<name>/main.lua`
3. A fresh Lua VM is created per door session (no shared state between users)
4. The Rust Door API is registered into the VM as globals
5. The Lua script runs until it returns or calls `bbs.exit()`
6. I/O is bridged: Lua `bbs.write()` → terminal output; terminal input → Lua callbacks

### Lua Door API (exposed as `bbs.*` globals)

```lua
-- I/O
bbs.write(text)              -- send ANSI text to user's terminal
bbs.writeln(text)            -- write + newline
bbs.read_line()              -- blocking read of one line from user
bbs.read_key()               -- blocking read of single keypress
bbs.clear()                  -- clear screen

-- User info (read-only)
bbs.user.name                -- logged-in username
bbs.user.id                  -- user ID
bbs.user.is_sysop            -- boolean

-- Persistent door data (scoped to this door)
bbs.data.get(key)            -- retrieve a string value
bbs.data.set(key, value)     -- persist a string value (stored in SQLite)

-- Utilities
bbs.ansi(code)               -- helper: return ANSI escape string by name
bbs.sleep(ms)                -- pause execution
bbs.exit()                   -- cleanly end the door session
bbs.time()                   -- current Unix timestamp
```

### Door directory layout

```
doors/
├── tradewars/
│   └── main.lua
├── lord/
│   └── main.lua
└── example/
    ├── main.lua
    └── lib/
        └── utils.lua        -- doors can require local modules
```

### Minimal example door (`doors/example/main.lua`)

```lua
bbs.clear()
bbs.writeln("\027[1;33mWelcome to the Example Door!\027[0m")
bbs.writeln("Hello, " .. bbs.user.name .. "!")

local visits = tonumber(bbs.data.get("visits") or "0") + 1
bbs.data.set("visits", tostring(visits))
bbs.writeln("You have visited " .. visits .. " time(s).")

bbs.writeln("\nPress any key to exit...")
bbs.read_key()
bbs.exit()
```

### `bbs-doors` crate internals

- `DoorRegistry` — scans `doors/` directory, registers available doors
- `DoorRunner` — owns the `mlua::Lua` VM, injects API, executes `main.lua`
- `DoorSession` — holds the I/O bridge (tokio channel) between the Lua VM and the terminal handler
- `DoorDataStore` — thin sqlx wrapper for per-user-per-door persistent key/value data

---

## Phase 4: Initial Database Migration

`migrations/0001_initial.sql`:
- `users` table: id, username, password_hash, created_at, last_login, is_sysop
- `boards` table: id, name, description, newsgroup_name
- `messages` table: id, board_id, author_id, subject, body, created_at, parent_id (for threading)
- `sessions` table: id, user_id, token, created_at, expires_at
- `door_games` table: id, name, description, lua_path, enabled
- `door_data` table: id, door_name, user_id, key, value (per-user-per-door KV store)

---

## Phase 5: Update CLAUDE.md

Replace the placeholder CLAUDE.md with full project guidance:

### Commands section
```
cargo build                          # build all crates
cargo build --release                # optimized build
cargo test                           # run all tests
cargo test -p bbs-core               # test a single crate
cargo clippy --all -- -D warnings    # lint
cargo fmt --all                      # format
cargo run -p bbs-server              # run the server
sqlx migrate run                     # apply DB migrations (requires DATABASE_URL)
```

### Architecture section covering:
- Workspace structure and crate responsibilities (8 crates)
- Protocol port defaults (Telnet: 2323, SSH: 2222, HTTP: 8080, NNTP: 1119)
- How bbs-tui is shared between telnet and SSH paths
- SQLite as default DB; DATABASE_URL env var
- `config/default.toml` for runtime configuration
- Lua door system: `doors/` directory, `bbs.*` API, per-session Lua VMs
- `bbs-doors` crate: DoorRegistry, DoorRunner, DoorSession, DoorDataStore

---

## Verification

After implementation:
1. `cargo build` succeeds (no errors, may have warnings on stubs)
2. `cargo clippy --all -- -D warnings` passes
3. `git status` shows all files tracked
4. `git log` shows initial commit
5. CLAUDE.md accurately describes the project
