-- Galaxy-wide key/value state
CREATE TABLE IF NOT EXISTS door_sre_galaxy (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- One row per registered player
CREATE TABLE IF NOT EXISTS door_sre_empires (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id              INTEGER NOT NULL UNIQUE,
    name                 TEXT    NOT NULL,
    letter               TEXT    NOT NULL UNIQUE,
    turns_remaining      INTEGER NOT NULL DEFAULT 5,
    turns_date           TEXT    NOT NULL DEFAULT '',
    protection_turns     INTEGER NOT NULL DEFAULT 20,
    credits              INTEGER NOT NULL DEFAULT 5000,
    food                 INTEGER NOT NULL DEFAULT 100,
    population           INTEGER NOT NULL DEFAULT 1000000,
    tax_rate             INTEGER NOT NULL DEFAULT 25,
    draft_rate           INTEGER NOT NULL DEFAULT 0,
    internal_violence    INTEGER NOT NULL DEFAULT 0,
    soldiers             INTEGER NOT NULL DEFAULT 0,
    fighters             INTEGER NOT NULL DEFAULT 0,
    defense_stations     INTEGER NOT NULL DEFAULT 0,
    heavy_cruisers       INTEGER NOT NULL DEFAULT 0,
    light_cruisers       INTEGER NOT NULL DEFAULT 0,
    carriers             INTEGER NOT NULL DEFAULT 0,
    generals             INTEGER NOT NULL DEFAULT 0,
    covert_agents        INTEGER NOT NULL DEFAULT 0,
    command_ship         INTEGER NOT NULL DEFAULT 0,
    net_worth            INTEGER NOT NULL DEFAULT 5000,
    is_active            INTEGER NOT NULL DEFAULT 1,
    last_played_at       INTEGER
);

-- Planet counts per empire per type
CREATE TABLE IF NOT EXISTS door_sre_planets (
    empire_id        INTEGER NOT NULL,
    planet_type      TEXT    NOT NULL,
    count            INTEGER NOT NULL DEFAULT 0,
    production_long  INTEGER NOT NULL DEFAULT 100,
    production_short INTEGER NOT NULL DEFAULT 100,
    supply_config    TEXT    NOT NULL DEFAULT 'soldiers',
    PRIMARY KEY (empire_id, planet_type)
);

-- Diplomatic treaties
CREATE TABLE IF NOT EXISTS door_sre_treaties (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    empire_a    INTEGER NOT NULL,
    empire_b    INTEGER NOT NULL,
    type        TEXT    NOT NULL,
    soldier_pct INTEGER NOT NULL DEFAULT 0,
    cruiser_pct INTEGER NOT NULL DEFAULT 0,
    duration    INTEGER NOT NULL DEFAULT 0,
    proposed_by INTEGER NOT NULL,
    accepted    INTEGER NOT NULL DEFAULT 0,
    expires_at  INTEGER,
    UNIQUE (empire_a, empire_b)
);

-- Inter-empire messages
CREATE TABLE IF NOT EXISTS door_sre_messages (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    from_empire INTEGER,
    subject     TEXT,
    body        TEXT    NOT NULL,
    is_public   INTEGER NOT NULL DEFAULT 0,
    sent_at     INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

CREATE TABLE IF NOT EXISTS door_sre_message_recipients (
    message_id INTEGER NOT NULL,
    empire_id  INTEGER NOT NULL,
    read_at    INTEGER,
    PRIMARY KEY (message_id, empire_id)
);

-- Lottery
CREATE TABLE IF NOT EXISTS door_sre_lottery_tickets (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    empire_id   INTEGER NOT NULL,
    game_day    INTEGER NOT NULL,
    ticket_type TEXT    NOT NULL DEFAULT 'standard',
    bought_at   INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

CREATE TABLE IF NOT EXISTS door_sre_lottery_results (
    game_day         INTEGER PRIMARY KEY,
    jackpot          INTEGER NOT NULL DEFAULT 500000,
    winner_empire_id INTEGER,
    drawn_at         INTEGER
);

-- Bank
CREATE TABLE IF NOT EXISTS door_sre_bank (
    empire_id          INTEGER PRIMARY KEY,
    savings            INTEGER NOT NULL DEFAULT 0,
    savings_rate       INTEGER NOT NULL DEFAULT 5,
    loan               INTEGER NOT NULL DEFAULT 0,
    loan_rate          INTEGER NOT NULL DEFAULT 10,
    bonds              INTEGER NOT NULL DEFAULT 0,
    bond_maturity_day  INTEGER
);

-- NPC pirate teams
CREATE TABLE IF NOT EXISTS door_sre_pirates (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    name          TEXT    NOT NULL,
    planets       INTEGER NOT NULL DEFAULT 3,
    soldiers      INTEGER NOT NULL DEFAULT 1000,
    credits       INTEGER NOT NULL DEFAULT 10000,
    food          INTEGER NOT NULL DEFAULT 50,
    loot_credits  INTEGER NOT NULL DEFAULT 0,
    loot_soldiers INTEGER NOT NULL DEFAULT 0,
    is_active     INTEGER NOT NULL DEFAULT 1
);

-- Per-day covert op tracking (prevents >1 of each op per target per day)
CREATE TABLE IF NOT EXISTS door_sre_covert_ops (
    empire_id        INTEGER NOT NULL,
    target_empire_id INTEGER NOT NULL,
    op_type          TEXT    NOT NULL,
    game_day         INTEGER NOT NULL,
    PRIMARY KEY (empire_id, target_empire_id, op_type, game_day)
);

-- Active research effects
CREATE TABLE IF NOT EXISTS door_sre_research_effects (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    empire_id    INTEGER NOT NULL,
    effect_type  TEXT    NOT NULL,
    magnitude    INTEGER NOT NULL DEFAULT 10,
    is_permanent INTEGER NOT NULL DEFAULT 0,
    expires_turn INTEGER
);

-- Offline event notifications
CREATE TABLE IF NOT EXISTS door_sre_events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    empire_id   INTEGER NOT NULL,
    event_type  TEXT    NOT NULL,
    description TEXT    NOT NULL,
    game_day    INTEGER NOT NULL,
    created_at  INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    read_at     INTEGER
);
