# Phase 3: SRE Data Layer — Implementation Plan

> **For Claude:** Use superpowers:executing-plans to implement task-by-task.

**Goal:** Create the SRE door directory, schema, UI helpers, SQL query layer, and empire load/save.

**Architecture:** `schema.sql` defines all tables. `lib/db.lua` centralises every SQL query (no raw SQL elsewhere). `lib/ui.lua` is pure ANSI helpers. `lib/empire.lua` loads/saves empire state via `lib/db.lua`.

**Prerequisite:** Phase 1 complete.

---

## Task 1: Directory structure + `schema.sql`

**Files:**
- Create: `doors/sre/schema.sql`

```sql
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

-- Per-day covert op tracking (prevents >1 of each op per target)
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
```

### Commit
```bash
git add doors/sre/schema.sql
git commit -m "feat(sre): add schema.sql with all door_sre_* tables"
```

---

## Task 2: `lib/ui.lua` — ANSI helpers

**Files:**
- Create: `doors/sre/lib/ui.lua`

```lua
-- lib/ui.lua — ANSI colour helpers and common UI primitives
local M = {}

local ESC = string.char(27)
local function a(code) return ESC.."["..code.."m" end

M.RST  = a("0");  M.BOL = a("1")
M.RED  = a("31"); M.GRN = a("32"); M.YEL = a("33")
M.BLU  = a("34"); M.MAG = a("35"); M.CYN = a("36"); M.WHT = a("37")
M.BRED = M.BOL..M.RED;  M.BGRN = M.BOL..M.GRN
M.BYEL = M.BOL..M.YEL;  M.BCYN = M.BOL..M.CYN
M.BMAG = M.BOL..M.MAG;  M.BWHT = M.BOL..M.WHT

function M.W(s)   door.write(s)         end
function M.WL(s)  door.writeln(s or "") end
function M.CLS()  door.clear()          end
function M.KEY()  return door.read_key() end
function M.INPUT(prompt)
    M.W(prompt)
    return door.read_line()
end

function M.pause()
    M.WL(M.CYN.."\r\n  [ press any key ]"..M.RST)
    M.KEY()
end

function M.divider()
    M.WL(M.CYN..string.rep("-", 60)..M.RST)
end

function M.header(title)
    M.WL("")
    M.WL(M.BCYN..string.rep("=", 60)..M.RST)
    M.WL(M.BCYN.."  "..title..M.RST)
    M.WL(M.BCYN..string.rep("=", 60)..M.RST)
    M.WL("")
end

-- Simple bar graph: val/max, width w, colours based on fill ratio
function M.bar(val, max, w)
    w = w or 20
    local fill = math.max(0, math.floor(val / math.max(1, max) * w))
    local col = fill > w * 0.5 and M.GRN
             or fill > w * 0.25 and M.YEL
             or M.BRED
    return "["..col..string.rep("#", fill)..M.RST..string.rep(".", w - fill).."]"
end

-- Comma-format large numbers
function M.commas(n)
    local s = tostring(math.floor(n))
    return s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

-- Centred text in a field of width w
function M.centre(s, w)
    local pad = math.max(0, w - #s)
    return string.rep(" ", math.floor(pad/2))..s..string.rep(" ", math.ceil(pad/2))
end

-- Pager: show long text one screen at a time
function M.pager(text)
    local lines = {}
    for ln in (text.."\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, ln)
    end
    local rows = 22
    local i = 1
    while i <= #lines do
        for j = i, math.min(i + rows - 1, #lines) do
            M.WL(lines[j])
        end
        i = i + rows
        if i <= #lines then
            M.W(M.CYN.."-- more -- (any key) --"..M.RST)
            M.KEY()
            M.WL("")
        end
    end
end

return M
```

### Commit
```bash
git add doors/sre/lib/ui.lua
git commit -m "feat(sre): add lib/ui.lua ANSI helpers"
```

---

## Task 3: `lib/db.lua` — centralised SQL queries

**Files:**
- Create: `doors/sre/lib/db.lua`

```lua
-- lib/db.lua — all door_sre_* SQL queries in one place.
-- No other module issues raw SQL.
local M = {}

-- ── Galaxy ────────────────────────────────────────────────────────────────────
function M.galaxy_get(key)
    local rows = door.db.query(
        "SELECT value FROM door_sre_galaxy WHERE key = ?", {key})
    return rows[1] and rows[1].value
end

function M.galaxy_set(key, value)
    door.db.execute([[
        INSERT INTO door_sre_galaxy (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
    ]], {key, tostring(value)})
end

function M.galaxy_get_all()
    local rows = door.db.query("SELECT key, value FROM door_sre_galaxy", {})
    local t = {}
    for _, r in ipairs(rows) do t[r.key] = r.value end
    return t
end

-- ── Empires ───────────────────────────────────────────────────────────────────
function M.empire_by_user(user_id)
    local rows = door.db.query(
        "SELECT * FROM door_sre_empires WHERE user_id = ?", {user_id})
    return rows[1]
end

function M.empire_by_id(empire_id)
    local rows = door.db.query(
        "SELECT * FROM door_sre_empires WHERE id = ?", {empire_id})
    return rows[1]
end

function M.empire_by_letter(letter)
    local rows = door.db.query(
        "SELECT * FROM door_sre_empires WHERE letter = ?", {letter})
    return rows[1]
end

function M.empire_list_active()
    return door.db.query(
        "SELECT * FROM door_sre_empires WHERE is_active = 1 ORDER BY net_worth DESC", {})
end

function M.empire_insert(user_id, name, letter)
    door.db.execute([[
        INSERT INTO door_sre_empires (user_id, name, letter) VALUES (?, ?, ?)
    ]], {user_id, name, letter})
    return M.empire_by_user(user_id)
end

function M.empire_update(e)
    door.db.execute([[
        UPDATE door_sre_empires SET
            turns_remaining=?, turns_date=?, protection_turns=?,
            credits=?, food=?, population=?, tax_rate=?, draft_rate=?,
            internal_violence=?,
            soldiers=?, fighters=?, defense_stations=?, heavy_cruisers=?,
            light_cruisers=?, carriers=?, generals=?, covert_agents=?,
            command_ship=?, net_worth=?, last_played_at=?
        WHERE id=?
    ]], {
        e.turns_remaining, e.turns_date, e.protection_turns,
        e.credits, e.food, e.population, e.tax_rate, e.draft_rate,
        e.internal_violence,
        e.soldiers, e.fighters, e.defense_stations, e.heavy_cruisers,
        e.light_cruisers, e.carriers, e.generals, e.covert_agents,
        e.command_ship, e.net_worth, door.time(),
        e.id
    })
end

function M.next_free_letter()
    local used = {}
    for _, r in ipairs(door.db.query(
            "SELECT letter FROM door_sre_empires WHERE is_active=1", {})) do
        used[r.letter] = true
    end
    for c = string.byte("A"), string.byte("Z") do
        local ch = string.char(c)
        if not used[ch] then return ch end
    end
    return nil  -- galaxy full (26 empires max)
end

-- ── Planets ───────────────────────────────────────────────────────────────────
local PLANET_TYPES = {
    "food","ore","tourism","supply","government",
    "education","research","urban","petroleum","anti_pollution"
}

function M.planets_for(empire_id)
    -- Returns table keyed by planet_type
    local rows = door.db.query(
        "SELECT * FROM door_sre_planets WHERE empire_id = ?", {empire_id})
    local t = {}
    for _, r in ipairs(rows) do t[r.planet_type] = r end
    -- Ensure all types present
    for _, pt in ipairs(PLANET_TYPES) do
        if not t[pt] then
            t[pt] = { empire_id=empire_id, planet_type=pt, count=0,
                      production_long=100, production_short=100, supply_config="soldiers" }
        end
    end
    return t
end

function M.planet_total(empire_id)
    local rows = door.db.query(
        "SELECT SUM(count) as total FROM door_sre_planets WHERE empire_id=?", {empire_id})
    return (rows[1] and rows[1].total) or 0
end

function M.planet_upsert(empire_id, planet_type, count, p_long, p_short, supply_cfg)
    door.db.execute([[
        INSERT INTO door_sre_planets
            (empire_id, planet_type, count, production_long, production_short, supply_config)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(empire_id, planet_type) DO UPDATE SET
            count=excluded.count,
            production_long=excluded.production_long,
            production_short=excluded.production_short,
            supply_config=excluded.supply_config
    ]], {empire_id, planet_type, count, p_long, p_short, supply_cfg or "soldiers"})
end

-- ── Treaties ──────────────────────────────────────────────────────────────────
function M.treaty_between(a_id, b_id)
    local lo, hi = math.min(a_id,b_id), math.max(a_id,b_id)
    local rows = door.db.query(
        "SELECT * FROM door_sre_treaties WHERE empire_a=? AND empire_b=?", {lo, hi})
    return rows[1]
end

function M.treaties_for(empire_id)
    return door.db.query([[
        SELECT * FROM door_sre_treaties
        WHERE (empire_a=? OR empire_b=?) AND accepted=1
    ]], {empire_id, empire_id})
end

function M.treaty_upsert(a_id, b_id, type, soldier_pct, cruiser_pct, duration, proposed_by)
    local lo, hi = math.min(a_id,b_id), math.max(a_id,b_id)
    door.db.execute([[
        INSERT INTO door_sre_treaties
            (empire_a, empire_b, type, soldier_pct, cruiser_pct, duration, proposed_by, accepted)
        VALUES (?,?,?,?,?,?,?,0)
        ON CONFLICT(empire_a,empire_b) DO UPDATE SET
            type=excluded.type, soldier_pct=excluded.soldier_pct,
            cruiser_pct=excluded.cruiser_pct, duration=excluded.duration,
            proposed_by=excluded.proposed_by, accepted=0,
            expires_at=NULL
    ]], {lo, hi, type, soldier_pct, cruiser_pct, duration, proposed_by})
end

function M.treaty_accept(a_id, b_id, duration_days)
    local lo, hi = math.min(a_id,b_id), math.max(a_id,b_id)
    local expires = duration_days > 0 and (door.time() + duration_days * 86400) or nil
    door.db.execute([[
        UPDATE door_sre_treaties SET accepted=1, expires_at=?
        WHERE empire_a=? AND empire_b=?
    ]], {expires, lo, hi})
end

function M.treaty_delete(a_id, b_id)
    local lo, hi = math.min(a_id,b_id), math.max(a_id,b_id)
    door.db.execute(
        "DELETE FROM door_sre_treaties WHERE empire_a=? AND empire_b=?", {lo, hi})
end

-- ── Events ────────────────────────────────────────────────────────────────────
function M.events_unread(empire_id)
    local gday = tonumber(M.galaxy_get("game_day") or "1")
    return door.db.query([[
        SELECT * FROM door_sre_events
        WHERE empire_id=? AND read_at IS NULL
        ORDER BY created_at ASC
    ]], {empire_id})
end

function M.event_post(empire_id, event_type, description)
    local gday = tonumber(M.galaxy_get("game_day") or "1")
    door.db.execute([[
        INSERT INTO door_sre_events (empire_id, event_type, description, game_day)
        VALUES (?,?,?,?)
    ]], {empire_id, event_type, description, gday})
end

function M.events_mark_read(empire_id)
    door.db.execute([[
        UPDATE door_sre_events SET read_at=? WHERE empire_id=? AND read_at IS NULL
    ]], {door.time(), empire_id})
end

-- ── Covert op daily limit ─────────────────────────────────────────────────────
function M.covert_used_today(empire_id, target_id, op_type)
    local gday = tonumber(M.galaxy_get("game_day") or "1")
    local rows = door.db.query([[
        SELECT 1 FROM door_sre_covert_ops
        WHERE empire_id=? AND target_empire_id=? AND op_type=? AND game_day=?
    ]], {empire_id, target_id, op_type, gday})
    return #rows > 0
end

function M.covert_record(empire_id, target_id, op_type)
    local gday = tonumber(M.galaxy_get("game_day") or "1")
    door.db.execute([[
        INSERT OR IGNORE INTO door_sre_covert_ops
            (empire_id, target_empire_id, op_type, game_day)
        VALUES (?,?,?,?)
    ]], {empire_id, target_id, op_type, gday})
end

return M
```

### Commit
```bash
git add doors/sre/lib/db.lua
git commit -m "feat(sre): add lib/db.lua centralised SQL query layer"
```

---

## Task 4: `lib/empire.lua` — empire load/save + registration

**Files:**
- Create: `doors/sre/lib/empire.lua`

```lua
-- lib/empire.lua — load, save, register, and net-worth calculation for empires.
local db = require("lib.db")
local M  = {}

local PLANET_PRICES = {
    food=1200, ore=1000, tourism=1500, supply=2000, government=1800,
    education=1600, research=2500, urban=1100, petroleum=1400, anti_pollution=900
}
local UNIT_PRICES = {
    soldiers=5, fighters=8, defense_stations=200,
    heavy_cruisers=300, light_cruisers=120, carriers=150,
    generals=100, covert_agents=250
}

-- Compute net worth from empire row + planet rows
function M.calc_net_worth(e, planets)
    local nw = e.credits
    -- Military
    nw = nw + e.soldiers      * UNIT_PRICES.soldiers
    nw = nw + e.fighters      * UNIT_PRICES.fighters
    nw = nw + e.defense_stations * UNIT_PRICES.defense_stations
    nw = nw + e.heavy_cruisers * UNIT_PRICES.heavy_cruisers
    nw = nw + e.light_cruisers * UNIT_PRICES.light_cruisers
    nw = nw + e.carriers      * UNIT_PRICES.carriers
    nw = nw + e.generals      * UNIT_PRICES.generals
    nw = nw + e.covert_agents * UNIT_PRICES.covert_agents
    -- Planets
    for pt, p in pairs(planets) do
        nw = nw + p.count * (PLANET_PRICES[pt] or 1000)
    end
    return math.max(0, nw)
end

-- Load empire for current user. Returns empire table + planets table, or nil if
-- the user hasn't registered yet.
function M.load()
    local e = db.empire_by_user(door.user.id)
    if not e then return nil, nil end
    local planets = db.planets_for(e.id)
    e.net_worth = M.calc_net_worth(e, planets)
    return e, planets
end

-- Save empire (and net_worth) back to DB.
function M.save(e, planets)
    e.net_worth = M.calc_net_worth(e, planets)
    db.empire_update(e)
    -- Persist each planet type
    for pt, p in pairs(planets) do
        db.planet_upsert(e.id, pt, p.count, p.production_long, p.production_short, p.supply_config)
    end
end

-- Register a new empire for the current user.
-- Returns the new empire + default planets, or nil + error string.
function M.register(empire_name)
    if #empire_name < 2 or #empire_name > 30 then
        return nil, "Empire name must be 2–30 characters."
    end
    local letter = db.next_free_letter()
    if not letter then
        return nil, "The galaxy is full (26 empires maximum)."
    end
    local e = db.empire_insert(door.user.id, empire_name, letter)
    -- Give starting planets: 3 ore, 2 food, 1 government
    local planets = db.planets_for(e.id)
    planets.ore.count        = 3
    planets.food.count       = 2
    planets.government.count = 1
    local nw = M.calc_net_worth(e, planets)
    e.net_worth = nw
    db.empire_update(e)
    for pt, p in pairs(planets) do
        db.planet_upsert(e.id, pt, p.count, p.production_long, p.production_short, p.supply_config)
    end
    return e, planets
end

-- Reset daily turns if it's a new day.
function M.refresh_turns(e)
    local today = os.date("%Y-%m-%d")
    if e.turns_date ~= today then
        e.turns_remaining = 5
        e.turns_date = today
    end
end

return M
```

### Commit
```bash
git add doors/sre/lib/empire.lua
git commit -m "feat(sre): add lib/empire.lua load/save/register"
```

---

## Task 5: Stub `main.lua` + smoke test

Create a minimal `main.lua` that loads all three modules and prints a status line —
just enough to confirm `require()`, `schema.sql` auto-run, and DB access all work.

**Files:**
- Create: `doors/sre/main.lua`

```lua
-- doors/sre/main.lua  (stub — Phase 3 smoke test)
local ui     = require("lib.ui")
local db     = require("lib.db")
local empire = require("lib.empire")

ui.CLS()
ui.WL(ui.BYEL.."  Solar Realms Elite — loading..."..ui.RST)

local e, planets = empire.load()
if not e then
    ui.WL(ui.CYN.."  No empire registered for this account yet."..ui.RST)
else
    ui.WL(ui.GRN..string.format("  Welcome back, %s (Empire %s)  Net worth: %s credits",
        e.name, e.letter, ui.commas(e.net_worth))..ui.RST)
end

ui.WL("")
ui.pause()
door.exit()
```

### Step: Connect and launch the SRE door from the BBS menu to verify:
- No Lua errors
- Schema tables created
- Empire load returns nil for a fresh user (expected)
- `require()` resolves correctly

### Commit
```bash
git add doors/sre/main.lua
git commit -m "feat(sre): stub main.lua for Phase 3 smoke test"
```

---

## Task 6: Final check

```bash
cargo build --all
cargo clippy --all -- -D warnings
cargo test -p bbs-doors
```

All green → Phase 3 complete.
