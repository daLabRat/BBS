CREATE TABLE IF NOT EXISTS mail (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    sender_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipient_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    subject      TEXT    NOT NULL,
    body         TEXT    NOT NULL,
    sent_at      INTEGER NOT NULL DEFAULT (unixepoch()),
    read_at      INTEGER          -- NULL = unread
);

CREATE INDEX IF NOT EXISTS mail_recipient ON mail(recipient_id, sent_at);
CREATE INDEX IF NOT EXISTS mail_sender    ON mail(sender_id,    sent_at);
