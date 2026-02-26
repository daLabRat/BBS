-- Track the last time each user visited each board (for "new messages" counts).

CREATE TABLE IF NOT EXISTS board_visits (
    user_id    INTEGER NOT NULL REFERENCES users(id)  ON DELETE CASCADE,
    board_id   INTEGER NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
    visited_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY (user_id, board_id)
);
