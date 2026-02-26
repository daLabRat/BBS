# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project

A BBS (Bulletin Board System) written in Rust with Lua scripting.

**Architectural intent:**
- **Rust** = engine only (protocol servers, terminal I/O bridge, SQLite, auth primitives, Lua VM host)
- **Lua** = the entire BBS experience (menus, navigation, boards, user flows — all in `scripts/*.lua`)
- **Door API** = a clean, portable Lua API (`door.*`) in its own crate (`bbs-doors`), designed to be published independently; doors are drop-in `.lua` scripts in `doors/`
- **DOS game support** = architecture reserves a `door.launch_dos()` hook; not implemented in phase 1

## Commands

```bash
cargo build                          # build all crates
cargo build --release
cargo test                           # all tests
cargo test -p bbs-core               # single crate
cargo clippy --all -- -D warnings
cargo fmt --all
cargo run -p bbs-server              # run the BBS
sqlx migrate run                     # apply migrations (requires DATABASE_URL=sqlite:bbs.db)
```

## Architecture

Rust is the engine; Lua is the BBS.

### Layers

1. **Protocol crates** (`bbs-telnet`, `bbs-ssh`, `bbs-web`, `bbs-nntp`) accept connections
   and pipe terminal I/O to `bbs-runtime`.
2. **`bbs-runtime`** hosts one Lua VM per user session (isolated), exposes `bbs.*` API,
   loads `scripts/`.
3. **BBS logic** (menus, boards, auth flow) lives in `scripts/*.lua`.
4. When a user launches a door, `bbs-runtime` hands off to `bbs-doors`.
5. **`bbs-doors`** hosts one Lua VM per door session (isolated), exposes `door.*` API,
   loads `doors/<name>/main.lua`. Designed as a portable/publishable crate.
6. **`bbs-core`** owns all domain types and the sqlx database layer.
7. **`bbs-tui`** provides shared ANSI/VT100 utilities used by telnet and SSH crates.

### Crate Map

| Crate | Role |
|---|---|
| `bbs-core` | Domain types (User, Board, Message); sqlx DB layer; argon2 auth |
| `bbs-runtime` | Embeds Lua VM; exposes `bbs.*` API; loads `scripts/*.lua`; bridges terminal I/O |
| `bbs-doors` | **Portable door crate.** Embeds its own Lua VM; exposes `door.*` API; loads `doors/*/main.lua`; manages door lifecycle; reserves `door.launch_dos()` stub |
| `bbs-server` | Binary entry point; config loading; spawns all protocol listeners |
| `bbs-telnet` | Raw TCP listener; VT100 state machine; feeds I/O to bbs-runtime |
| `bbs-ssh` | SSH server (russh); reuses bbs-tui after handshake |
| `bbs-web` | axum HTTP + WebSocket terminal bridge |
| `bbs-nntp` | NNTP server; maps boards to newsgroups |
| `bbs-tui` | Shared ANSI art renderer, menu primitives, pager — used by telnet and SSH crates |

### Ports (default)

| Protocol | Port |
|---|---|
| Telnet | 2323 |
| SSH | 2222 |
| HTTP | 8080 |
| NNTP | 1119 |

### Configuration

`config/default.toml` — ports, DB path, scripts dir, doors dir.

`DATABASE_URL=sqlite:bbs.db` (for sqlx CLI tools).

## Two Lua API Surfaces

### `bbs.*` — BBS system API (`scripts/*.lua`)

```lua
bbs.write(text)              -- send text/ANSI to terminal
bbs.writeln(text)
bbs.read_line(prompt)        -- blocking line read
bbs.read_key()               -- single keypress
bbs.clear()
bbs.menu(definition)         -- render a menu, return selection
bbs.pager(text)              -- scrollable text viewer
bbs.user.name / .id / .is_sysop
bbs.boards.list()
bbs.boards.post(board_id, subject, body)
bbs.boards.read(board_id)
bbs.doors.list()
bbs.doors.launch(name)
bbs.ansi(name)
bbs.time()
```

### `door.*` — Door game API (`doors/*/main.lua`, in `bbs-doors` crate)

```lua
door.write(text)              -- send text/ANSI to terminal
door.writeln(text)
door.read_line()
door.read_key()
door.clear()
door.user.name / .id / .is_sysop   -- read-only snapshot
door.data.get(key)            -- per-user per-door KV (SQLite)
door.data.set(key, value)
door.ansi(name)
door.sleep(ms)
door.time()
door.exit()
-- door.launch_dos(game_path, drop_file_type)  [STUB -- phase 2]
```

## Door System

`doors/` contains one subdirectory per door, each with `main.lua`.

The `door.*` Lua API is defined in `crates/bbs-doors`.

`door.launch_dos()` is stubbed for future DOS game support via DOSBox-X.

### Writing a door

See `doors/example/main.lua`. Use only the `door.*` API — no `bbs.*` access inside a door.

## Permissions

The `.claude/settings.local.json` restricts auto-approved Bash commands to `test:*` patterns only. Other shell commands will require user approval.
