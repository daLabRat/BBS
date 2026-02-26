# BBS Project Initialization Plan

## Context

The `/mnt/unraid/CLAUDE/BBS` directory is an empty workspace for a new Rust + Lua BBS system. This initialization creates the git repo, Cargo workspace, directory skeleton, database migration, example Lua scripts, and an updated CLAUDE.md.

**Architectural intent:**
- **Rust** = engine only (protocol servers, terminal I/O bridge, SQLite, auth primitives, Lua VM host)
- **Lua** = the entire BBS experience (menus, navigation, boards, user flows — all in `scripts/*.lua`)
- **Door API** = a clean, portable Lua API (`door.*`) in its own crate (`bbs-doors`), designed to be published independently; doors are drop-in `.lua` scripts in `doors/`
- **DOS game support** = architecture reserves a `door.launch_dos()` hook; not implemented in this phase

---

## Phase 1: Git Initialization

```bash
git init
```

`.gitignore`:
```
/target/
**/*.rs.bk
.env
*.env.local
bbs.db
```

`Cargo.lock` is committed (binary project).

---

## Phase 2: Cargo Workspace

### `Cargo.toml` (workspace root)

```toml
[workspace]
members = [
    "crates/bbs-core",
    "crates/bbs-runtime",
    "crates/bbs-doors",
    "crates/bbs-server",
    "crates/bbs-telnet",
    "crates/bbs-ssh",
    "crates/bbs-web",
    "crates/bbs-nntp",
    "crates/bbs-tui",
]
resolver = "2"

[workspace.dependencies]
tokio        = { version = "1", features = ["full"] }
anyhow       = "1"
thiserror    = "1"
tracing      = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
serde        = { version = "1", features = ["derive"] }
serde_json   = "1"
sqlx         = { version = "0.7", features = ["sqlite", "runtime-tokio", "migrate", "macros"] }
mlua         = { version = "0.9", features = ["lua54", "vendored", "async", "send"] }
```

### Crate responsibilities

| Crate | Role |
|---|---|
| `bbs-core` | Domain types (User, Board, Message, Session); sqlx DB layer; argon2 auth |
| `bbs-runtime` | Embeds Lua VM; exposes `bbs.*` API to BBS scripts; loads `scripts/*.lua`; bridges terminal I/O |
| `bbs-doors` | **Portable door crate.** Embeds its own Lua VM; exposes `door.*` API; loads `doors/*/main.lua`; manages door lifecycle; reserves `door.launch_dos()` stub |
| `bbs-server` | Binary entry point; config loading; spawns all protocol listeners + Lua runtime |
| `bbs-telnet` | Raw TCP listener; VT100 state machine; feeds I/O to bbs-runtime |
| `bbs-ssh` | SSH server (russh); reuses bbs-tui after handshake |
| `bbs-web` | axum HTTP + WebSocket terminal bridge |
| `bbs-nntp` | NNTP server; maps boards to newsgroups |
| `bbs-tui` | Shared ANSI art renderer, menu primitives, pager — used by telnet and SSH |

---

## Phase 3: Two Lua API Surfaces

### `bbs.*` — BBS system API (used by `scripts/*.lua`)

```lua
-- Terminal I/O
bbs.write(text)           -- send text/ANSI to current user's terminal
bbs.writeln(text)
bbs.read_line(prompt)     -- prompt + blocking line read
bbs.read_key()            -- single keypress
bbs.clear()

-- Navigation
bbs.menu(definition)      -- render a menu, return selection
bbs.pager(text)           -- scrollable text viewer

-- User
bbs.user.name             -- current username
bbs.user.id
bbs.user.is_sysop

-- Boards & messages
bbs.boards.list()         -- returns table of {id, name, description}
bbs.boards.post(board_id, subject, body)
bbs.boards.read(board_id) -- returns messages table

-- Doors
bbs.doors.list()          -- available doors from doors/ directory
bbs.doors.launch(name)    -- hand off session to bbs-doors crate

-- System
bbs.ansi(name)            -- ANSI escape helper
bbs.time()                -- Unix timestamp
```

### `door.*` — Door game API (used by `doors/*/main.lua`, in `bbs-doors` crate)

```lua
-- Terminal I/O
door.write(text)
door.writeln(text)
door.read_line()
door.read_key()
door.clear()

-- User info (read-only snapshot passed at launch)
door.user.name
door.user.id
door.user.is_sysop

-- Persistent KV store (per-user per-door, backed by SQLite)
door.data.get(key)
door.data.set(key, value)

-- Utilities
door.ansi(name)
door.sleep(ms)
door.time()
door.exit()

-- DOS hook (stub — reserved, not implemented in phase 1)
-- door.launch_dos(game_path, drop_file_type)
```

---

## Phase 4: Directory Structure

```
BBS/
├── .gitignore
├── CLAUDE.md
├── Cargo.toml               ← workspace root
├── Cargo.lock
├── config/
│   └── default.toml         ← ports, DB path, scripts path, doors path
├── migrations/
│   └── 0001_initial.sql
├── assets/
│   └── welcome.ans
├── scripts/                 ← Lua BBS logic (loaded by bbs-runtime)
│   ├── main.lua             ← entry point (called per session)
│   ├── auth.lua
│   ├── menu.lua
│   └── boards.lua
├── doors/                   ← Lua door games (loaded by bbs-doors)
│   └── example/
│       └── main.lua
└── crates/
    ├── bbs-core/src/{lib,db,user,board,message}.rs
    ├── bbs-runtime/src/{lib,api,session}.rs
    ├── bbs-doors/src/{lib,registry,runner,session,store,api}.rs
    ├── bbs-server/src/main.rs
    ├── bbs-telnet/src/lib.rs
    ├── bbs-ssh/src/lib.rs
    ├── bbs-web/src/lib.rs
    ├── bbs-nntp/src/lib.rs
    └── bbs-tui/src/lib.rs
```

---

## Phase 5: Database Migration (`migrations/0001_initial.sql`)

- `users`: id, username, password_hash, created_at, last_login, is_sysop
- `boards`: id, name, description, newsgroup_name
- `messages`: id, board_id, author_id, subject, body, created_at, parent_id
- `sessions`: id, user_id, token, created_at, expires_at
- `door_data`: id, door_name, user_id, key, value ← door KV store

---

## Phase 6: CLAUDE.md (updated)

```markdown
# CLAUDE.md
...

## Commands
cargo build                          # build all crates
cargo build --release
cargo test                           # all tests
cargo test -p bbs-core               # single crate
cargo clippy --all -- -D warnings
cargo fmt --all
cargo run -p bbs-server              # run the BBS
sqlx migrate run                     # apply migrations (requires DATABASE_URL=sqlite:bbs.db)

## Architecture
Rust is the engine; Lua is the BBS.

### Layers
1. Protocol crates (bbs-telnet, bbs-ssh, bbs-web, bbs-nntp) accept connections
   and pipe terminal I/O to bbs-runtime.
2. bbs-runtime hosts one Lua VM per user session (isolated), exposes bbs.* API, loads scripts/.
3. BBS logic (menus, boards, auth flow) lives in scripts/*.lua.
4. When a user launches a door, bbs-runtime hands off to bbs-doors.
5. bbs-doors hosts one Lua VM per door session (isolated), exposes door.* API,
   loads doors/<name>/main.lua. Designed as a portable/publishable crate.
6. bbs-core owns all domain types and the sqlx database layer.
7. bbs-tui provides shared ANSI/VT100 utilities used by telnet and SSH crates.

### Ports (default)
- Telnet: 2323
- SSH:    2222
- HTTP:   8080
- NNTP:   1119

### Configuration
config/default.toml — ports, db path, scripts dir, doors dir.
DATABASE_URL=sqlite:bbs.db (for sqlx CLI tools).

### Door system
doors/ contains one subdirectory per door, each with main.lua.
The door.* Lua API is defined in crates/bbs-doors.
door.launch_dos() is stubbed for future DOS game support via DOSBox-X.

### Writing a door
See doors/example/main.lua. Use only the door.* API — no bbs.* access.
```

---

## Verification

1. `cargo build` succeeds (stubs compile cleanly)
2. `cargo clippy --all -- -D warnings` passes
3. `git status` shows all files tracked; `git log` shows initial commit
4. `doors/example/main.lua` is a working example runnable by bbs-doors
5. CLAUDE.md accurately describes the two-layer Lua architecture
