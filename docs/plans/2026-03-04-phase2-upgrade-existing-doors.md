# Phase 2: Upgrade Existing Doors to `door.db.*` — Implementation Plan

> **For Claude:** Use superpowers:executing-plans to implement task-by-task.

**Goal:** Migrate dragonsbane and example doors from `door.data` string KV to typed SQL via `door.db.*`.

**Architecture:** Each door gets a `schema.sql` with `CREATE TABLE IF NOT EXISTS`. `main.lua` is refactored to use `door.db.query/execute` with typed columns. `door.data` calls are removed.

**Prerequisite:** Phase 1 complete (`door.db.*` registered and schema auto-run working).

---

## Task 1: dragonsbane `schema.sql`

**Files:**
- Create: `doors/dragonsbane/schema.sql`

```sql
CREATE TABLE IF NOT EXISTS door_dragonsbane_characters (
    user_id     INTEGER PRIMARY KEY,
    level       INTEGER NOT NULL DEFAULT 1,
    xp          INTEGER NOT NULL DEFAULT 0,
    max_hp      INTEGER NOT NULL DEFAULT 25,
    hp          INTEGER NOT NULL DEFAULT 25,
    str         INTEGER NOT NULL DEFAULT 5,
    def         INTEGER NOT NULL DEFAULT 2,
    gold        INTEGER NOT NULL DEFAULT 50,
    weapon_atk  INTEGER NOT NULL DEFAULT 0,
    weapon_name TEXT    NOT NULL DEFAULT 'Rusty Dagger',
    armor_def   INTEGER NOT NULL DEFAULT 0,
    armor_name  TEXT    NOT NULL DEFAULT 'Tattered Cloth',
    kills       INTEGER NOT NULL DEFAULT 0,
    deaths      INTEGER NOT NULL DEFAULT 0,
    turns       INTEGER NOT NULL DEFAULT 10,
    turns_date  TEXT    NOT NULL DEFAULT ''
);
```

### Commit
```bash
git add doors/dragonsbane/schema.sql
git commit -m "feat(dragonsbane): add schema.sql for door.db migration"
```

---

## Task 2: Refactor dragonsbane `main.lua` — load/save character

**Files:**
- Modify: `doors/dragonsbane/main.lua`

Replace the `gn()` helper and `load_char()` / `save_char()` functions.

**Remove** `gn()`, `load_char()`, `save_char()` (lines 98–141). Replace with:

```lua
local function load_char()
    local today = os.date("%Y-%m-%d")
    local rows = door.db.query(
        "SELECT * FROM door_dragonsbane_characters WHERE user_id = ?",
        { door.user.id }
    )
    if #rows == 0 then
        -- First visit: insert defaults
        door.db.execute(
            [[INSERT INTO door_dragonsbane_characters (user_id) VALUES (?)]],
            { door.user.id }
        )
        C.level       = 1;  C.xp       = 0
        C.max_hp      = 25; C.hp       = 25
        C.str         = 5;  C.def      = 2
        C.gold        = 50
        C.watk        = 0;  C.wname    = "Rusty Dagger"
        C.ddef        = 0;  C.aname    = "Tattered Cloth"
        C.kills       = 0;  C.deaths   = 0
        C.turns       = DAILY_TURNS
    else
        local r = rows[1]
        C.level  = r.level;   C.xp     = r.xp
        C.max_hp = r.max_hp;  C.hp     = r.hp
        C.str    = r.str;     C.def    = r.def
        C.gold   = r.gold
        C.watk   = r.weapon_atk;  C.wname = r.weapon_name
        C.ddef   = r.armor_def;   C.aname = r.armor_name
        C.kills  = r.kills;   C.deaths = r.deaths
        if r.turns_date ~= today then
            C.turns = DAILY_TURNS
        else
            C.turns = r.turns
        end
    end
    C.tdate = today
end

local function save_char()
    door.db.execute([[
        UPDATE door_dragonsbane_characters SET
            level = ?, xp = ?, max_hp = ?, hp = ?,
            str = ?, def = ?, gold = ?,
            weapon_atk = ?, weapon_name = ?,
            armor_def = ?, armor_name = ?,
            kills = ?, deaths = ?,
            turns = ?, turns_date = ?
        WHERE user_id = ?
    ]], {
        C.level, C.xp, C.max_hp, math.max(1, C.hp),
        C.str, C.def, C.gold,
        C.watk, C.wname,
        C.ddef, C.aname,
        C.kills, C.deaths,
        C.turns, C.tdate,
        door.user.id
    })
end
```

Also update the weapon/armor purchase lines in `shop()` — remove the individual
`door.data.set(...)` calls (lines 364–371), since `save_char()` now handles
everything in one UPDATE.

### Step: Smoke-test manually
Connect to BBS, launch dragonsbane, verify character loads, fights work, and stats
persist across sessions.

### Commit
```bash
git add doors/dragonsbane/main.lua
git commit -m "feat(dragonsbane): migrate from door.data to door.db typed SQL"
```

---

## Task 3: example `schema.sql`

**Files:**
- Create: `doors/example/schema.sql`

```sql
CREATE TABLE IF NOT EXISTS door_example_stats (
    user_id      INTEGER PRIMARY KEY,
    visits       INTEGER NOT NULL DEFAULT 0,
    best_guesses INTEGER
);
```

### Commit
```bash
git add doors/example/schema.sql
git commit -m "feat(example): add schema.sql for door.db migration"
```

---

## Task 4: Refactor example `main.lua`

**Files:**
- Modify: `doors/example/main.lua`

Replace `show_stats()` and the `best_guesses` save logic:

```lua
local function show_stats()
    -- Upsert visit count
    door.db.execute([[
        INSERT INTO door_example_stats (user_id, visits) VALUES (?, 1)
        ON CONFLICT(user_id) DO UPDATE SET visits = visits + 1
    ]], { door.user.id })

    local rows = door.db.query(
        "SELECT visits, best_guesses FROM door_example_stats WHERE user_id = ?",
        { door.user.id }
    )
    local r = rows[1]
    door.writeln("Your visit count: " .. r.visits)
    door.writeln("Server time:      " .. os.date("%Y-%m-%d %H:%M:%S", door.time()))
    if door.user.is_sysop then
        door.writeln("(You are the sysop)")
    end
    if r.best_guesses then
        door.writeln("Best guesses:     " .. r.best_guesses)
    end
    door.writeln("")
end
```

Replace the best_guesses save block inside `guessing_game()`:

```lua
-- was: door.data.get/set("best_guesses", ...)
local rows = door.db.query(
    "SELECT best_guesses FROM door_example_stats WHERE user_id = ?",
    { door.user.id }
)
local best = rows[1] and rows[1].best_guesses
if best == nil or guesses < best then
    door.db.execute(
        "UPDATE door_example_stats SET best_guesses = ? WHERE user_id = ?",
        { guesses, door.user.id }
    )
    door.writeln("New personal best: " .. guesses .. " guess(es)!")
end
```

Remove all remaining `door.data.*` calls.

### Step: Smoke-test manually
Connect, launch example door, verify visit counter increments and best_guesses persists.

### Commit
```bash
git add doors/example/main.lua
git commit -m "feat(example): migrate from door.data to door.db typed SQL"
```

---

## Task 5: Final check

```bash
cargo build --all
cargo clippy --all -- -D warnings
cargo test -p bbs-doors
```

All green → Phase 2 complete.
