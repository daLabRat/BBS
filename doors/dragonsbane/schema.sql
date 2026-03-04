CREATE TABLE IF NOT EXISTS door_dragonsbane_characters (
    user_id   INTEGER PRIMARY KEY,
    level     INTEGER NOT NULL DEFAULT 1,
    xp        INTEGER NOT NULL DEFAULT 0,
    max_hp    INTEGER NOT NULL DEFAULT 25,
    hp        INTEGER NOT NULL DEFAULT 25,
    strength  INTEGER NOT NULL DEFAULT 5,
    defense   INTEGER NOT NULL DEFAULT 2,
    gold      INTEGER NOT NULL DEFAULT 50,
    watk      INTEGER NOT NULL DEFAULT 0,
    ddef      INTEGER NOT NULL DEFAULT 0,
    wname     TEXT    NOT NULL DEFAULT 'Rusty Dagger',
    aname     TEXT    NOT NULL DEFAULT 'Tattered Cloth',
    kills     INTEGER NOT NULL DEFAULT 0,
    deaths    INTEGER NOT NULL DEFAULT 0,
    turns     INTEGER NOT NULL DEFAULT 10,
    tdate     TEXT    NOT NULL DEFAULT ''
);
