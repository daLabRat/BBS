CREATE TABLE IF NOT EXISTS bulletins (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    author_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title     TEXT    NOT NULL,
    body      TEXT    NOT NULL,
    posted_at INTEGER NOT NULL DEFAULT (unixepoch()),
    is_active INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS bulletins_active ON bulletins(is_active, posted_at);
