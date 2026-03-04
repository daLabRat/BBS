CREATE TABLE IF NOT EXISTS door_example_stats (
    user_id      INTEGER PRIMARY KEY,
    visits       INTEGER NOT NULL DEFAULT 0,
    best_guesses INTEGER
);
