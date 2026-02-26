//! NNTP server. Maps BBS message boards to newsgroups.
//!
//! Boards with a non-null `newsgroup_name` column appear in NNTP.
//! Article IDs use the format `<{message_id}@bbs>`.

use std::sync::Arc;

use anyhow::Result;
use bbs_core::{Board, Database};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tracing::{error, info};

pub async fn serve(addr: &str, db: Arc<Database>) -> Result<()> {
    let listener = TcpListener::bind(addr).await?;
    info!("NNTP listening on {addr}");
    loop {
        let (socket, peer) = listener.accept().await?;
        info!("NNTP connection from {peer}");
        let db = Arc::clone(&db);
        tokio::spawn(async move {
            if let Err(e) = handle_connection(socket, db).await {
                error!("NNTP session error from {peer}: {e}");
            }
        });
    }
}

// ── State ────────────────────────────────────────────────────────────────────

struct NntpState {
    db: Arc<Database>,
    current_board: Option<Board>,
    current_article_id: Option<i64>,
    pending_auth_user: Option<String>,
    authed_user_id: Option<i64>,
}

// ── Connection handler ───────────────────────────────────────────────────────

async fn handle_connection(socket: TcpStream, db: Arc<Database>) -> Result<()> {
    let (reader, mut writer) = socket.into_split();
    let mut reader = BufReader::new(reader);

    writer
        .write_all(b"200 BBS NNTP Service ready - posting allowed\r\n")
        .await?;

    let mut state = NntpState {
        db,
        current_board: None,
        current_article_id: None,
        pending_auth_user: None,
        authed_user_id: None,
    };

    let mut line = String::new();
    loop {
        line.clear();
        let n = reader.read_line(&mut line).await?;
        if n == 0 {
            break;
        }
        let trimmed = line.trim_end_matches(['\r', '\n']);
        let response = dispatch(&mut state, trimmed, &mut reader).await?;
        writer.write_all(response.as_bytes()).await?;
        if trimmed.to_uppercase().starts_with("QUIT") {
            break;
        }
    }

    Ok(())
}

// ── Command dispatcher ───────────────────────────────────────────────────────

async fn dispatch<R: AsyncBufReadExt + Unpin>(
    state: &mut NntpState,
    line: &str,
    reader: &mut R,
) -> Result<String> {
    let parts: Vec<&str> = line.splitn(3, ' ').collect();
    let cmd = parts.first().unwrap_or(&"").to_uppercase();

    match cmd.as_str() {
        "CAPABILITIES" => Ok(capabilities()),
        "DATE" => Ok(cmd_date()),
        "QUIT" => Ok("205 Closing connection\r\n".to_string()),
        "MODE" => Ok("200 Posting allowed\r\n".to_string()),

        "LIST" => {
            let arg = parts.get(1).map(|s| s.to_uppercase()).unwrap_or_default();
            if arg.is_empty() || arg == "ACTIVE" {
                cmd_list(state).await
            } else if arg == "OVERVIEW.FMT" {
                Ok("215 Order of fields in overview database.\r\nSubject:\r\nFrom:\r\nDate:\r\nMessage-ID:\r\nReferences:\r\nBytes:\r\nLines:\r\n.\r\n".to_string())
            } else {
                Ok("503 Feature not supported\r\n".to_string())
            }
        }

        "GROUP" => {
            let ng = parts.get(1).copied().unwrap_or("");
            cmd_group(state, ng).await
        }

        "ARTICLE" | "HEAD" | "BODY" | "STAT" => {
            let arg = parts.get(1).copied().unwrap_or("");
            cmd_article(state, &cmd, arg).await
        }

        "NEXT" => cmd_next(state).await,
        "LAST" => cmd_last(state).await,

        "OVER" | "XOVER" => {
            let range = parts.get(1).copied().unwrap_or("");
            cmd_over(state, range).await
        }

        "HDR" | "XHDR" => {
            // Minimal: return empty list
            Ok("224 No headers\r\n.\r\n".to_string())
        }

        "AUTHINFO" => {
            let sub = parts.get(1).map(|s| s.to_uppercase()).unwrap_or_default();
            let val = parts.get(2).copied().unwrap_or("");
            cmd_authinfo(state, &sub, val).await
        }

        "POST" => cmd_post(state, reader).await,

        _ => Ok("500 Unknown command\r\n".to_string()),
    }
}

// ── CAPABILITIES ─────────────────────────────────────────────────────────────

fn capabilities() -> String {
    "101 Capability list:\r\nVERSION 2\r\nREADER\r\nOVER\r\nHDR\r\nLIST ACTIVE OVERVIEW.FMT\r\nAUTHINFO\r\nPOST\r\n.\r\n".to_string()
}

// ── DATE ─────────────────────────────────────────────────────────────────────

fn cmd_date() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    let (y, mo, d, h, mi, s) = unix_to_ymdhms(secs);
    format!("111 {:04}{:02}{:02}{:02}{:02}{:02}\r\n", y, mo, d, h, mi, s)
}

// ── LIST ACTIVE ──────────────────────────────────────────────────────────────

async fn cmd_list(state: &mut NntpState) -> Result<String> {
    let boards = state.db.list_boards_with_newsgroups().await?;
    let mut out = "215 List of newsgroups follows\r\n".to_string();
    for b in boards {
        if let Some(ng) = &b.newsgroup_name {
            let count = state.db.count_messages(b.id).await.unwrap_or(0);
            let first = state
                .db
                .first_message_id(b.id)
                .await
                .unwrap_or(None)
                .unwrap_or(0);
            let last = state
                .db
                .last_message_id(b.id)
                .await
                .unwrap_or(None)
                .unwrap_or(0);
            out.push_str(&format!("{ng} {last} {first} y\r\n"));
            let _ = count;
        }
    }
    out.push_str(".\r\n");
    Ok(out)
}

// ── GROUP ─────────────────────────────────────────────────────────────────────

async fn cmd_group(state: &mut NntpState, newsgroup: &str) -> Result<String> {
    let board = state.db.find_board_by_newsgroup(newsgroup).await?;
    match board {
        None => Ok("411 No such newsgroup\r\n".to_string()),
        Some(b) => {
            let count = state.db.count_messages(b.id).await?;
            let first = state.db.first_message_id(b.id).await?.unwrap_or(0);
            let last = state.db.last_message_id(b.id).await?.unwrap_or(0);
            let ng = b.newsgroup_name.clone().unwrap_or_default();
            state.current_article_id = if count > 0 { Some(first) } else { None };
            state.current_board = Some(b);
            Ok(format!("211 {count} {first} {last} {ng}\r\n"))
        }
    }
}

// ── ARTICLE / HEAD / BODY / STAT ─────────────────────────────────────────────

async fn cmd_article(state: &mut NntpState, cmd: &str, arg: &str) -> Result<String> {
    // Resolve article ID
    let article_id = if arg.is_empty() {
        match state.current_article_id {
            Some(id) => id,
            None => return Ok("420 No current article selected\r\n".to_string()),
        }
    } else if arg.starts_with('<') {
        // message-id format: <123@bbs>
        parse_message_id(arg).unwrap_or(0)
    } else {
        arg.parse::<i64>().unwrap_or(0)
    };

    let result = state.db.find_message_by_id(article_id).await?;
    match result {
        None => Ok("430 No article with that message-id\r\n".to_string()),
        Some((msg, author)) => {
            let ng = state
                .current_board
                .as_ref()
                .and_then(|b| b.newsgroup_name.as_deref())
                .unwrap_or("misc.bbs");
            let msg_id = format!("<{}@bbs>", msg.id);
            let date = unix_to_rfc2822(msg.created_at);
            let (code, label) = match cmd {
                "HEAD" => (221, "Headers follow"),
                "BODY" => (222, "Body follows"),
                "STAT" => (223, "Article exists"),
                _ => (220, "Article follows"),
            };
            let mut out = format!("{code} {} {msg_id} {label}\r\n", msg.id);
            if cmd == "ARTICLE" || cmd == "HEAD" {
                out.push_str(&format!("From: {author}\r\n"));
                out.push_str(&format!("Subject: {}\r\n", msg.subject));
                out.push_str(&format!("Date: {date}\r\n"));
                out.push_str(&format!("Message-ID: {msg_id}\r\n"));
                out.push_str(&format!("Newsgroups: {ng}\r\n"));
                out.push_str("\r\n");
            }
            if cmd == "ARTICLE" || cmd == "BODY" {
                for line in msg.body.lines() {
                    if line.starts_with('.') {
                        out.push('.');
                    }
                    out.push_str(line);
                    out.push_str("\r\n");
                }
                out.push_str(".\r\n");
            } else if cmd == "HEAD" {
                out.push_str(".\r\n");
            }
            state.current_article_id = Some(article_id);
            Ok(out)
        }
    }
}

// ── NEXT / LAST ──────────────────────────────────────────────────────────────

async fn cmd_next(state: &mut NntpState) -> Result<String> {
    let board = match &state.current_board {
        Some(b) => b.clone(),
        None => return Ok("412 No newsgroup selected\r\n".to_string()),
    };
    let cur = match state.current_article_id {
        Some(id) => id,
        None => return Ok("420 No current article\r\n".to_string()),
    };
    let last = state.db.last_message_id(board.id).await?.unwrap_or(0);
    if cur >= last {
        return Ok("421 No next article\r\n".to_string());
    }
    // Find next article in this board with id > cur
    let rows = state
        .db
        .list_messages_range(board.id, cur + 1, i64::MAX)
        .await?;
    match rows.into_iter().next() {
        None => Ok("421 No next article\r\n".to_string()),
        Some((msg, _)) => {
            state.current_article_id = Some(msg.id);
            Ok(format!("223 {} <{}@bbs> Next article\r\n", msg.id, msg.id))
        }
    }
}

async fn cmd_last(state: &mut NntpState) -> Result<String> {
    let board = match &state.current_board {
        Some(b) => b.clone(),
        None => return Ok("412 No newsgroup selected\r\n".to_string()),
    };
    let cur = match state.current_article_id {
        Some(id) => id,
        None => return Ok("420 No current article\r\n".to_string()),
    };
    let first = state.db.first_message_id(board.id).await?.unwrap_or(0);
    if cur <= first {
        return Ok("422 No previous article\r\n".to_string());
    }
    // Find previous article with id < cur
    let rows = state
        .db
        .list_messages_range(board.id, first, cur - 1)
        .await?;
    match rows.into_iter().last() {
        None => Ok("422 No previous article\r\n".to_string()),
        Some((msg, _)) => {
            state.current_article_id = Some(msg.id);
            Ok(format!(
                "223 {} <{}@bbs> Previous article\r\n",
                msg.id, msg.id
            ))
        }
    }
}

// ── OVER ─────────────────────────────────────────────────────────────────────

async fn cmd_over(state: &mut NntpState, range: &str) -> Result<String> {
    let board = match &state.current_board {
        Some(b) => b.clone(),
        None => return Ok("412 No newsgroup selected\r\n".to_string()),
    };

    let (from_id, to_id) = parse_range(range, state.current_article_id.unwrap_or(1));
    let messages = state
        .db
        .list_messages_range(board.id, from_id, to_id)
        .await?;

    if messages.is_empty() {
        return Ok("420 No articles in range\r\n".to_string());
    }

    let mut out = "224 Overview information follows\r\n".to_string();
    for (msg, author) in messages {
        let date = unix_to_rfc2822(msg.created_at);
        let msg_id = format!("<{}@bbs>", msg.id);
        let bytes = msg.body.len();
        let lines = msg.body.lines().count();
        out.push_str(&format!(
            "{}\t{}\t{}\t{}\t{}\t\t{}\t{}\r\n",
            msg.id, msg.subject, author, date, msg_id, bytes, lines
        ));
    }
    out.push_str(".\r\n");
    Ok(out)
}

// ── AUTHINFO ─────────────────────────────────────────────────────────────────

async fn cmd_authinfo(state: &mut NntpState, sub: &str, val: &str) -> Result<String> {
    match sub {
        "USER" => {
            state.pending_auth_user = Some(val.to_string());
            Ok("381 Enter password\r\n".to_string())
        }
        "PASS" => match &state.pending_auth_user.take() {
            None => Ok("482 Authentication commands issued out of sequence\r\n".to_string()),
            Some(username) => {
                let user = state.db.find_user_by_username(username).await?;
                match user {
                    Some(u)
                        if bbs_core::verify_password(val, &u.password_hash).unwrap_or(false) =>
                    {
                        let _ = state.db.update_last_login(u.id).await;
                        state.authed_user_id = Some(u.id);
                        Ok("281 Authentication accepted\r\n".to_string())
                    }
                    _ => Ok("481 Authentication failed\r\n".to_string()),
                }
            }
        },
        _ => Ok("501 Syntax error\r\n".to_string()),
    }
}

// ── POST ─────────────────────────────────────────────────────────────────────

async fn cmd_post<R: AsyncBufReadExt + Unpin>(
    state: &mut NntpState,
    reader: &mut R,
) -> Result<String> {
    if state.authed_user_id.is_none() {
        return Ok("440 Posting not permitted\r\n".to_string());
    }

    // Signal ready to receive
    // (The caller writes "340 …" but we need to signal that inline here.
    // We return a multi-part string: the 340 response plus the final 240/441.)
    // Collect article until ".\r\n"
    let mut subject = String::new();
    let mut newsgroup = String::new();
    let mut body_lines: Vec<String> = Vec::new();
    let mut in_body = false;
    let mut article_line = String::new();

    loop {
        article_line.clear();
        if reader.read_line(&mut article_line).await? == 0 {
            break;
        }
        let trimmed = article_line.trim_end_matches(['\r', '\n']).to_string();
        if trimmed == "." {
            break;
        }
        let content = if trimmed.starts_with("..") {
            &trimmed[1..]
        } else {
            &trimmed
        };
        if !in_body {
            if content.is_empty() {
                in_body = true;
            } else if let Some(val) = content.strip_prefix("Subject:") {
                subject = val.trim().to_string();
            } else if let Some(val) = content.strip_prefix("Newsgroups:") {
                newsgroup = val.trim().to_string();
            }
        } else {
            body_lines.push(content.to_string());
        }
    }

    // Find the board by newsgroup name
    let board = state.db.find_board_by_newsgroup(&newsgroup).await?;
    match board {
        None => Ok("441 Posting failed: unknown newsgroup\r\n".to_string()),
        Some(b) => {
            let author_id = state.authed_user_id.unwrap();
            let body = body_lines.join("\n");
            state
                .db
                .post_message(b.id, author_id, &subject, &body)
                .await?;
            Ok("240 Article received OK\r\n".to_string())
        }
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn parse_message_id(s: &str) -> Option<i64> {
    // Format: <123@bbs>
    let inner = s.trim_start_matches('<').trim_end_matches('>');
    inner.split('@').next()?.parse().ok()
}

fn parse_range(range: &str, current: i64) -> (i64, i64) {
    if range.is_empty() {
        return (current, current);
    }
    if let Some(dash) = range.find('-') {
        let low: i64 = range[..dash].parse().unwrap_or(1);
        let high_str = &range[dash + 1..];
        let high: i64 = if high_str.is_empty() {
            i64::MAX
        } else {
            high_str.parse().unwrap_or(i64::MAX)
        };
        (low, high)
    } else {
        let n: i64 = range.parse().unwrap_or(current);
        (n, n)
    }
}

/// Format a unix timestamp as RFC 2822 (e.g. "Mon, 01 Jan 2024 00:00:00 +0000").
fn unix_to_rfc2822(ts: i64) -> String {
    if ts < 0 {
        return "Thu, 01 Jan 1970 00:00:00 +0000".to_string();
    }
    let (y, mo, d, h, mi, s) = unix_to_ymdhms(ts);
    let dow_names = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"];
    let mon_names = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let dow = dow_names[((ts as u64 / 86400) % 7) as usize];
    let mon = mon_names[(mo as usize).saturating_sub(1).min(11)];
    format!(
        "{dow}, {:02} {mon} {:04} {:02}:{:02}:{:02} +0000",
        d, y, h, mi, s
    )
}

/// Decompose a unix timestamp into (year, month, day, hour, min, sec).
fn unix_to_ymdhms(ts: i64) -> (i32, i32, i32, i32, i32, i32) {
    let ts = ts.max(0) as u64;
    let s = (ts % 60) as i32;
    let mi = ((ts / 60) % 60) as i32;
    let h = ((ts / 3600) % 24) as i32;
    let days = (ts / 86400) as i64;
    let (y, mo, d) = civil_from_days(days + 719468);
    (y, mo, d, h, mi, s)
}

/// Howard Hinnant's algorithm: days since proleptic epoch → (year, month, day).
fn civil_from_days(z: i64) -> (i32, i32, i32) {
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if mo <= 2 { y + 1 } else { y };
    (y as i32, mo as i32, d as i32)
}
