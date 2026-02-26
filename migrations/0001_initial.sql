-- BBS initial schema

CREATE TABLE IF NOT EXISTS users (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    username      TEXT    NOT NULL UNIQUE,
    password_hash TEXT    NOT NULL,
    created_at    INTEGER NOT NULL DEFAULT (unixepoch()),
    last_login    INTEGER,
    is_sysop      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS boards (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    name           TEXT    NOT NULL UNIQUE,
    description    TEXT    NOT NULL DEFAULT '',
    newsgroup_name TEXT
);

CREATE TABLE IF NOT EXISTS messages (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    board_id   INTEGER NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
    author_id  INTEGER NOT NULL REFERENCES users(id)  ON DELETE CASCADE,
    subject    TEXT    NOT NULL,
    body       TEXT    NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    parent_id  INTEGER REFERENCES messages(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    id         TEXT    PRIMARY KEY,  -- UUID
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token      TEXT    NOT NULL UNIQUE,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    expires_at INTEGER NOT NULL
);

-- Per-user per-door persistent key-value store (used by door.data API)
CREATE TABLE IF NOT EXISTS door_data (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    door_name TEXT    NOT NULL,
    user_id   INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    key       TEXT    NOT NULL,
    value     TEXT    NOT NULL,
    UNIQUE (door_name, user_id, key)
);

-- Seed default boards
INSERT OR IGNORE INTO boards (name, description, newsgroup_name) VALUES
    ('General',       'General discussion',          'local.general'),
    ('Announcements', 'Sysop announcements',         'local.announce'),
    ('Tech Talk',     'Programming and technology',  'local.tech');
