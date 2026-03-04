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
    -- Ensure all types present with defaults
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

function M.treaty_upsert(a_id, b_id, ttype, soldier_pct, cruiser_pct, duration, proposed_by)
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
    ]], {lo, hi, ttype, soldier_pct, cruiser_pct, duration, proposed_by})
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
