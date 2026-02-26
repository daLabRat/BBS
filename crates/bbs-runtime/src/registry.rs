//! Shared session registry — tracks who is currently online.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Debug)]
pub struct SessionEntry {
    pub name: String,
    pub connected_at: u64,
}

/// Process-wide registry of active sessions.  Clone-cheap (inner Arc).
#[derive(Clone, Default)]
pub struct SessionRegistry(Arc<Mutex<Vec<(u64, SessionEntry)>>>);

impl SessionRegistry {
    /// Record a logged-in user and return a handle.  Dropping the handle
    /// removes the entry automatically.
    pub fn checkin(&self, name: String) -> SessionHandle {
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        let connected_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        self.0
            .lock()
            .unwrap()
            .push((id, SessionEntry { name, connected_at }));
        SessionHandle {
            id,
            inner: Arc::clone(&self.0),
        }
    }

    /// Snapshot of currently online users, sorted by connect time.
    pub fn list(&self) -> Vec<SessionEntry> {
        let mut entries: Vec<SessionEntry> = self
            .0
            .lock()
            .unwrap()
            .iter()
            .map(|(_, e)| e.clone())
            .collect();
        entries.sort_by_key(|e| e.connected_at);
        entries
    }
}

/// Returned by `SessionRegistry::checkin`.  Deregisters the session on drop.
pub struct SessionHandle {
    id: u64,
    inner: Arc<Mutex<Vec<(u64, SessionEntry)>>>,
}

impl Drop for SessionHandle {
    fn drop(&mut self) {
        self.inner.lock().unwrap().retain(|(id, _)| *id != self.id);
    }
}
