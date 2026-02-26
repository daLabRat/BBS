//! DOSBox-X integration for `door.launch_dos()`.
//!
//! Writes a drop file into the game directory, creates a PTY, spawns DOSBox-X
//! headlessly with COM1 bridged to the PTY slave, then shuttles bytes between
//! the PTY master and the BBS terminal until DOSBox-X exits.

use std::fs::File;
use std::os::unix::io::{AsRawFd, FromRawFd, IntoRawFd};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Result};
use bytes::Bytes;
use nix::fcntl::{FcntlArg, OFlag};
use nix::pty;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;

use bbs_tui::Terminal;

use crate::session::DoorUser;

/// Configuration for launching DOS games via DOSBox-X.
#[derive(Debug, Clone)]
pub struct DosConfig {
    /// Path to the DOSBox-X binary. Defaults to `"dosbox-x"` (searched on PATH).
    pub dosbox_bin: PathBuf,
    /// Directory for temporary per-session DOSBox-X config files.
    /// Defaults to [`std::env::temp_dir()`].
    pub temp_dir: PathBuf,
}

impl Default for DosConfig {
    fn default() -> Self {
        Self {
            dosbox_bin: PathBuf::from("dosbox-x"),
            temp_dir: std::env::temp_dir(),
        }
    }
}

impl DosConfig {
    /// Launch a DOS game for the given user, bridging I/O through the BBS terminal.
    ///
    /// 1. Writes the requested drop file into the game directory.
    /// 2. Opens a PTY master/slave pair.
    /// 3. Writes a temporary DOSBox-X `.conf` with COM1 → slave PTY.
    /// 4. Spawns DOSBox-X headlessly.
    /// 5. Bridges PTY↔terminal until the child exits.
    /// 6. Cleans up the temp config.
    pub async fn launch(
        &self,
        exe_path: &Path,
        drop_file_type: &str,
        user: &DoorUser,
        terminal: &Terminal,
    ) -> Result<()> {
        let game_dir = exe_path
            .parent()
            .ok_or_else(|| anyhow!("exe_path has no parent directory"))?;
        let exe_name = exe_path
            .file_name()
            .ok_or_else(|| anyhow!("exe_path has no file name"))?
            .to_string_lossy()
            .into_owned();

        // 1. Write drop file.
        let drop_filename = canonical_drop_filename(drop_file_type)?;
        let drop_path = game_dir.join(drop_filename);
        write_drop_file(&drop_path, drop_file_type, user)?;

        // 2. Create PTY master/slave.
        let master =
            pty::posix_openpt(OFlag::O_RDWR | OFlag::O_NOCTTY | OFlag::O_CLOEXEC)?;
        pty::grantpt(&master)?;
        pty::unlockpt(&master)?;
        let slave_name = pty::ptsname_r(&master)?;

        // Set master fd non-blocking before handing to tokio.
        {
            let raw = master.as_raw_fd();
            let flags = nix::fcntl::fcntl(raw, FcntlArg::F_GETFL)?;
            let new_flags = OFlag::from_bits_truncate(flags) | OFlag::O_NONBLOCK;
            nix::fcntl::fcntl(raw, FcntlArg::F_SETFL(new_flags))?;
        }

        // Convert to tokio async file.
        let master_raw = master.into_raw_fd();
        let std_file = unsafe { File::from_raw_fd(master_raw) };
        let pty_file = tokio::fs::File::from_std(std_file);
        let (mut pty_read, mut pty_write) = tokio::io::split(pty_file);

        // 3. Write temp DOSBox-X config.
        let cfg_filename = format!("dosbox_node_{}.conf", user.id);
        let cfg_path = self.temp_dir.join(&cfg_filename);
        let game_dir_str = game_dir.display().to_string();
        let cfg_content = format!(
            "[sdl]\n\
             output=dummy\n\
             fullscreen=false\n\
             \n\
             [dosbox]\n\
             memsize=16\n\
             \n\
             [cpu]\n\
             cycles=auto\n\
             \n\
             [serial]\n\
             serial1=directserial realport:{slave_name}\n\
             \n\
             [autoexec]\n\
             mount C \"{game_dir}\"\n\
             C:\n\
             {exe_name}\n\
             exit\n",
            slave_name = slave_name,
            game_dir = game_dir_str,
            exe_name = exe_name,
        );
        tokio::fs::write(&cfg_path, cfg_content).await?;

        // 4. Spawn DOSBox-X headlessly.
        let mut child = Command::new(&self.dosbox_bin)
            .arg("-conf")
            .arg(&cfg_path)
            .arg("-noprimaryconf")
            .arg("-nolocalconf")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()?;

        // 5. Bridge PTY ↔ terminal with two concurrent tasks.
        let tx = terminal.writer().clone();
        let rx = terminal.reader();

        // PTY → terminal
        let task_pty_to_term = tokio::spawn(async move {
            let mut buf = [0u8; 4096];
            loop {
                match pty_read.read(&mut buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if tx.send(Bytes::copy_from_slice(&buf[..n])).await.is_err() {
                            break;
                        }
                    }
                }
            }
        });

        // terminal → PTY
        let task_term_to_pty = tokio::spawn(async move {
            loop {
                let b = rx.lock().await.recv().await;
                match b {
                    Some(b) => {
                        if pty_write.write_all(&[b]).await.is_err() {
                            break;
                        }
                    }
                    None => break,
                }
            }
        });

        // Wait for DOSBox-X to exit.
        child.wait().await?;

        // Abort bridge tasks and remove temp config.
        task_pty_to_term.abort();
        task_term_to_pty.abort();
        let _ = tokio::fs::remove_file(&cfg_path).await;

        Ok(())
    }
}

/// Return the canonical filename for a given drop file type.
fn canonical_drop_filename(drop_file_type: &str) -> Result<&'static str> {
    match drop_file_type.to_lowercase().as_str() {
        "door.sys" | "doorsys" => Ok("DOOR.SYS"),
        "dorinfo1.def" | "dorinfo" => Ok("DORINFO1.DEF"),
        "chain.txt" => Ok("CHAIN.TXT"),
        other => Err(anyhow!("unknown drop file type: '{other}'")),
    }
}

/// Write the appropriate drop file at `path` for the given user.
fn write_drop_file(path: &Path, drop_file_type: &str, user: &DoorUser) -> Result<()> {
    let content = match drop_file_type.to_lowercase().as_str() {
        "door.sys" | "doorsys" => make_door_sys(user),
        "dorinfo1.def" | "dorinfo" => make_dorinfo(user),
        "chain.txt" => make_chain_txt(user),
        other => return Err(anyhow!("unknown drop file type: '{other}'")),
    };
    std::fs::write(path, content)?;
    Ok(())
}

/// DOOR.SYS drop file (one value per CRLF-terminated line, DOS format).
fn make_door_sys(user: &DoorUser) -> Vec<u8> {
    let (year, month, day) = current_date();
    let lines: &[&dyn std::fmt::Display] = &[
        &"COM1:",
        &38400_u32,
        &8_u32,
        &1_u32,
        &38400_u32,
        &"YYYY",
        &"Y",
        &"Y",
        &user.name as &dyn std::fmt::Display,
        &"Unknown City, ST",
        &"555-1234",
        &"PASSWORD",
        &100_u32,
        &1_u32,
        &format!("{month:02}/{day:02}/{year:04}") as &dyn std::fmt::Display,
        &60_u32,
        &0_u32,
        &0_u32,
        &0_u32,
        &60_u32,
        &"Y",
        &25_u32,
        &1000_u32,
        &0_u32,
        &user.name as &dyn std::fmt::Display,
        &user.id,
    ];
    crlf_join(lines)
}

/// DORINFO1.DEF drop file (CRLF-terminated lines).
fn make_dorinfo(user: &DoorUser) -> Vec<u8> {
    let lines: &[&dyn std::fmt::Display] = &[
        &"BBS NAME",
        &"Sysop",
        &"User",
        &"COM1",
        &"38400 BAUD,8,N,1",
        &1_u32,
        &user.name as &dyn std::fmt::Display,
        &"",
        &"Unknown City, ST",
        &1_u32,
        &100_u32,
        &60_u32,
        &-1_i32,
    ];
    crlf_join(lines)
}

/// CHAIN.TXT drop file (CRLF-terminated lines).
fn make_chain_txt(user: &DoorUser) -> Vec<u8> {
    let (year, month, day) = current_date();
    let (hour, minute) = current_time();
    let time_str = format!("{hour:02}:{minute:02}");
    let date_str = format!("{month:02}/{day:02}/{:02}", year % 100);
    let lines: &[&dyn std::fmt::Display] = &[
        &user.name as &dyn std::fmt::Display,
        &user.id,
        &100_u32,
        &60_u32,
        &time_str as &dyn std::fmt::Display,
        &date_str as &dyn std::fmt::Display,
    ];
    crlf_join(lines)
}

/// Join display values with CRLF line endings.
fn crlf_join(lines: &[&dyn std::fmt::Display]) -> Vec<u8> {
    let mut out = String::new();
    for line in lines {
        out.push_str(&line.to_string());
        out.push_str("\r\n");
    }
    out.into_bytes()
}

// ── Date/time helpers (no external dep) ─────────────────────────────────────

fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719_468;
    let era: i64 = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y as i32, m as u32, d as u32)
}

fn current_date() -> (i32, u32, u32) {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    civil_from_days((secs / 86400) as i64)
}

fn current_time() -> (u32, u32) {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let sod = secs % 86400;
    ((sod / 3600) as u32, ((sod % 3600) / 60) as u32)
}
