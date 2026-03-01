# Plan: door.launch_dos() — DOSBox-X Integration

## Context

The `bbs-doors` crate has a `door.launch_dos(exe_path, drop_file_type)` stub that
throws "not implemented (phase 2)". This plan replaces it with a working
implementation: write a drop file into the game's directory, create a PTY,
spawn DOSBox-X headlessly with COM1 bridged to the PTY slave, then shuttle
bytes between the PTY master and the BBS terminal channels until DOSBox-X exits.
Target environment: Linux / WSL2, DOSBox-X built for Linux with `output=dummy`.

---

## Files to Create / Modify

| File | Change |
|---|---|
| `crates/bbs-doors/Cargo.toml` | Add `nix` dependency |
| `crates/bbs-doors/src/dos.rs` | **New**: `DosConfig`, drop file writers, DOSBox-X launcher |
| `crates/bbs-doors/src/lib.rs` | Expose `pub mod dos; pub use dos::DosConfig;` |
| `crates/bbs-doors/src/runner.rs` | Add `dos_config: DosConfig` field; pass to API |
| `crates/bbs-doors/src/api.rs` | Replace `launch_dos` stub with real implementation |
| `crates/bbs-runtime/src/lib.rs` | Add `pub dos_config: bbs_doors::DosConfig` to `RuntimeConfig` |
| `crates/bbs-runtime/src/api.rs` | Pass `config.dos_config.clone()` to `DoorRunner::new()` |
| `config/default.toml` | Add `[dos]` section (`bin`, `temp_dir`) |
| `crates/bbs-server/src/main.rs` | Read `[dos]` config, populate `RuntimeConfig.dos_config` |

---

## Phase 1 — `crates/bbs-doors/Cargo.toml`

```toml
nix = { version = "0.29", features = ["pty", "fs"] }
```

---

## Phase 2 — `crates/bbs-doors/src/dos.rs` (new file)

### `DosConfig` struct

```rust
#[derive(Debug, Clone)]
pub struct DosConfig {
    pub dosbox_bin: PathBuf,   // default: "dosbox-x"
    pub temp_dir: PathBuf,     // default: std::env::temp_dir()
}
impl Default for DosConfig { ... }
```

### Drop file writer

`write_drop_file(path, type, user)` dispatches on `type.to_lowercase()`:

- **`"door.sys"`** / **`"doorsys"`** → `DOOR.SYS` (one value per line, CRLF):
  `COM1:`, baud=38400, data bits, node=1, baud×2, flags YYYY, user.name,
  city/phone placeholders, 100 sec-level, 1 call, MM/DD/YYYY date, 60 min,
  ANSI=Y, 25 lines, account=1000, handle=user.name, user.id.

- **`"dorinfo1.def"`** / **`"dorinfo"`** → `DORINFO1.DEF` (CRLF):
  BBS NAME, SYSOP×2, COM1, `38400 BAUD,8,N,1`, 1, first, last, city, 1, 100, 60, -1.

- **`"chain.txt"`** → `CHAIN.TXT` (CRLF):
  user.name, user.id, 100, 60, HH:MM, MM/DD/YY.

Date/time formatting uses an inlined `civil_from_days()` algorithm (no extra deps).
`canonical_drop_filename(type) -> &str` returns `"DOOR.SYS"` / `"DORINFO1.DEF"` / `"CHAIN.TXT"`.

### `DosConfig::launch()` async function

```rust
pub async fn launch(&self, exe_path: &Path, drop_file_type: &str,
                    user: &DoorUser, terminal: &Terminal) -> Result<()>
```

**Steps:**
1. `game_dir = exe_path.parent()`; `exe_name = exe_path.file_name()`
2. Write drop file: `game_dir / canonical_drop_filename(drop_file_type)`
3. Create PTY master:
   ```rust
   let master = nix::pty::posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC)?;
   nix::pty::grantpt(&master)?; nix::pty::unlockpt(&master)?;
   let slave_name = unsafe { nix::pty::ptsname(&master)? }; // "/dev/pts/N"
   ```
4. Set master fd non-blocking:
   ```rust
   let flags = OFlag::from_bits_truncate(fcntl(master_fd, F_GETFL)?);
   fcntl(master_fd, F_SETFL(flags | O_NONBLOCK))?;
   ```
5. Convert to async tokio file:
   ```rust
   let master_fd = master.into_raw_fd();
   let pty_file  = tokio::fs::File::from_std(unsafe { File::from_raw_fd(master_fd) });
   let (mut pty_read, mut pty_write) = tokio::io::split(pty_file);
   ```
6. Write temp DOSBox-X config to `temp_dir/dosbox_node_{user.id}.conf`:
   ```ini
   [sdl]
   output=dummy
   fullscreen=false

   [dosbox]
   memsize=16

   [cpu]
   cycles=auto

   [serial]
   serial1=directserial realport:{slave_name}

   [autoexec]
   mount C "{game_dir}"
   C:
   {exe_name}
   exit
   ```
7. Spawn DOSBox-X:
   ```rust
   Command::new(&self.dosbox_bin)
       .args(["-conf", cfg_path, "-noprimaryconf", "-nolocalconf"])
       .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
       .spawn()?
   ```
8. Bridge I/O with two `tokio::spawn` tasks:
   - **PTY→term**: `pty_read.read(&mut buf)` → `terminal.writer().send(Bytes)`
   - **term→PTY**: `terminal.reader().lock().recv()` → `pty_write.write_all(&[b])`
9. `child.wait().await` — blocks until DOSBox-X exits
10. Abort both tasks; remove temp config file

---

## Phase 3 — `crates/bbs-doors/src/runner.rs`

Add `dos_config: DosConfig` to `DoorRunner`. Update constructor:
```rust
pub fn new(db: Arc<Database>, terminal: Terminal, dos_config: DosConfig) -> Self
```
Pass `dos_config` into `api::register(...)`.

---

## Phase 4 — `crates/bbs-doors/src/api.rs`

Replace the `launch_dos` stub:
```rust
// door.launch_dos(exe_path, drop_file_type) -> nil
{
    let dos_config = dos_config.clone();
    let terminal   = terminal.clone();
    door.set("launch_dos", lua.create_async_function(
        move |lua, (exe_path, drop_file_type): (String, String)| {
            let dos_config = dos_config.clone();
            let terminal   = terminal.clone();
            async move {
                // Read user snapshot from door.user Lua table
                let door_tbl: LuaTable = lua.globals().get("door")?;
                let user_tbl: LuaTable = door_tbl.get("user")?;
                let user = DoorUser { id: user_tbl.get("id")?, ... };
                dos_config
                    .launch(Path::new(&exe_path), &drop_file_type, &user, &terminal)
                    .await
                    .map_err(LuaError::external)
            }
        }
    )?)?;
}
```

---

## Phase 5 — `crates/bbs-runtime/src/lib.rs`

```rust
pub dos_config: bbs_doors::DosConfig,
```

---

## Phase 6 — `crates/bbs-runtime/src/api.rs`

Change one line in the `bbs.doors.launch` block:
```rust
let runner = bbs_doors::DoorRunner::new(db, terminal, config.dos_config.clone());
```

---

## Phase 7 — `config/default.toml`

```toml
[dos]
# Path to the DOSBox-X binary.  Must be on PATH or provide an absolute path.
bin = "dosbox-x"
# Where to write temporary per-session DOSBox configs.
# temp_dir = "/tmp"
```

---

## Phase 8 — `crates/bbs-server/src/main.rs`

```rust
let dos_config = bbs_doors::DosConfig {
    dosbox_bin: cfg.get_string("dos.bin")
        .unwrap_or_else(|_| "dosbox-x".into()).into(),
    temp_dir: cfg.get_string("dos.temp_dir")
        .map(PathBuf::from)
        .unwrap_or_else(|_| std::env::temp_dir()),
};
// Pass into RuntimeConfig { ..., dos_config }
```

---

## Verification

```bash
cargo build                              # must compile clean
cargo clippy --all -- -D warnings       # warning-free
cargo test -p bbs-core --lib            # 21 tests still pass

# Manual end-to-end (requires dosbox-x installed and a DOS .COM/.EXE):
# In a Lua door (doors/testgame/main.lua):
#   door.launch_dos("/abs/path/to/doors/testgame/HELLO.COM", "door.sys")
# Verify:
#   - DOOR.SYS appears in the game directory with correct user fields
#   - DOSBox-X process spawns (visible in ps)
#   - Game I/O flows through the terminal (text appears on screen)
#   - door.launch_dos() returns after game exits
```
