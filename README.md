# BBS

A Bulletin Board System written in Rust with Lua scripting.

**Rust is the engine. Lua is the BBS.**

All menus, navigation, message boards, and user flows live in `scripts/*.lua`. Door games are drop-in `doors/<name>/main.lua` scripts. The Rust crates handle protocol servers, terminal I/O, SQLite, auth, and Lua VM hosting — nothing more.

## Features

- **Telnet, SSH, and Web** (WebSocket) access
- **NNTP** server — message boards exposed as newsgroups
- **Message boards** with per-board read tracking
- **Private mail** between users
- **Bulletins** (sysop announcements)
- **Door games** via a clean, portable Lua API (`door.*`)
- **DOS game support** via DOSBox-X PTY bridge (`door.launch_dos()`)
- **Sysop tools** — user management, board management
- **SQLite** persistence via sqlx

## Quick Start

```bash
# Build
cargo build --release

# Apply database migrations
DATABASE_URL=sqlite:bbs.db sqlx migrate run

# Run
cargo run -p bbs-server
```

Connect via:
- **Telnet:** `telnet localhost 2323`
- **SSH:** `ssh -p 2222 localhost`
- **Web:** `http://localhost:8088`

## Configuration

Edit `config/default.toml`:

```toml
[server]
name = "My BBS"
sysop = "sysop"

[database]
url = "sqlite:bbs.db"

[telnet]
enabled = true
bind    = "0.0.0.0:2323"

[ssh]
enabled = true
bind    = "0.0.0.0:2222"

[http]
enabled = true
bind    = "0.0.0.0:8088"

[nntp]
enabled = true
bind    = "0.0.0.0:1119"

[dos]
bin = "dosbox-x"
```

For SSH, generate a host key:
```bash
ssh-keygen -t ed25519 -f config/host_key
```
Then uncomment `host_key = "config/host_key"` in `config/default.toml`.

## Architecture

```
bbs-server      Binary entry point; config loading; spawns protocol listeners
bbs-telnet      Raw TCP listener; VT100 state machine
bbs-ssh         SSH server (russh)
bbs-web         axum HTTP + WebSocket terminal bridge
bbs-nntp        NNTP server; maps boards to newsgroups
bbs-runtime     Lua VM host; exposes bbs.* API; loads scripts/
bbs-doors       Portable door crate; exposes door.* API; loads doors/*/main.lua
bbs-core        Domain types (User, Board, Message); SQLite layer; argon2 auth
bbs-tui         Shared ANSI/VT100 utilities
```

## Lua API

### `bbs.*` — BBS system scripts (`scripts/*.lua`)

```lua
bbs.write(text)
bbs.writeln(text)
bbs.read_line(prompt)
bbs.read_key()
bbs.clear()
bbs.menu(definition)        -- render a menu, return selection
bbs.pager(text)             -- scrollable text viewer
bbs.user.name / .id / .is_sysop
bbs.boards.list()
bbs.boards.post(board_id, subject, body)
bbs.boards.read(board_id)
bbs.doors.list()
bbs.doors.launch(name)
bbs.ansi(name)
bbs.time()
```

### `door.*` — Door game API (`doors/*/main.lua`)

```lua
door.write(text)
door.writeln(text)
door.read_line()
door.read_key()
door.clear()
door.user.name / .id / .is_sysop
door.data.get(key)          -- per-user per-door KV store (SQLite)
door.data.set(key, value)
door.ansi(name)
door.sleep(ms)
door.time()
door.exit()
door.launch_dos(game_path, drop_file_type)   -- DOSBox-X bridge
```

## Writing a Door Game

Create `doors/<name>/main.lua`. Use only the `door.*` API — no `bbs.*` access inside a door. See `doors/example/main.lua` for a working example with KV persistence.

## Included Doors

| Door | Description |
|------|-------------|
| `dragonsbane` | A full RPG door game |
| `example` | Minimal example with persistent KV storage |

## Development

```bash
cargo build                          # build all crates
cargo test                           # run all tests
cargo clippy --all -- -D warnings    # lint
cargo fmt --all                      # format
```

## License

Licensed under either of:

- [MIT License](LICENSE-MIT)
- [Apache License, Version 2.0](LICENSE-APACHE)

at your option.

Copyright (c) 2026 LabRat
