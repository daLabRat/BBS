//! Per-username login throttle — 5 failures within 15 minutes locks the
//! account for 15 minutes from the last failure.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const MAX_FAILS: u32 = 5;
const WINDOW: Duration = Duration::from_secs(900); // 15 minutes

struct FailRecord {
    count: u32,
    last_fail: Instant,
}

/// Clone-cheap (inner Arc) throttle shared across all sessions.
#[derive(Clone, Default)]
pub struct LoginThrottle(Arc<Mutex<HashMap<String, FailRecord>>>);

impl LoginThrottle {
    /// Returns `Some(seconds_remaining)` if the username is currently locked.
    pub fn locked_for(&self, username: &str) -> Option<u64> {
        let map = self.0.lock().unwrap();
        let rec = map.get(username)?;
        if rec.count < MAX_FAILS {
            return None;
        }
        let elapsed = rec.last_fail.elapsed();
        if elapsed >= WINDOW {
            None
        } else {
            Some((WINDOW - elapsed).as_secs() + 1)
        }
    }

    /// Record a failed attempt.
    pub fn record_fail(&self, username: &str) {
        let mut map = self.0.lock().unwrap();
        let rec = map.entry(username.to_lowercase()).or_insert(FailRecord {
            count: 0,
            last_fail: Instant::now(),
        });
        // Reset window if previous failures have expired
        if rec.last_fail.elapsed() >= WINDOW {
            rec.count = 0;
        }
        rec.count += 1;
        rec.last_fail = Instant::now();
    }

    /// Clear failures on successful login.
    pub fn record_success(&self, username: &str) {
        self.0.lock().unwrap().remove(username);
    }
}
