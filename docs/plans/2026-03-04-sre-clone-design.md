# Solar Realms Elite Clone — Design Document

**Date:** 2026-03-04
**Status:** Approved
**References:**
- [SRE Documentation](http://www-cs-students.stanford.edu/~amitp/Articles/SRE-Documentation.html)
- [SRE Design Notes](http://www-cs-students.stanford.edu/~amitp/Articles/SRE-Design.html)

---

## Overview

A full faithful clone of Solar Realms Elite (1990–1994, Amit Patel) implemented as a
BBS door game in Lua. Players rule interstellar empires — colonizing planets, building
military, managing economies, forging alliances, and attacking rivals.

This work also introduces `door.db.*`, a generic SQL API for all BBS doors, and
upgrades the existing dragonsbane and example doors to use it.

---

## Scope

- Full faithful clone: all 10 planet types, all 9 covert ops, all 7 treaty types,
  all attack types, banking, lottery, pirates, population mechanics, research
- Multiplayer: all BBS users share one game world via SQLite
- Turn system: classic 5 turns per real day per player
- Pricing: both inflationary and non-inflationary modes, sysop-configurable
- Theme: space empire (faithful to original)

---

## Architecture

### Rust Layer — `door.db.*` API in `bbs-doors`

Generic SQL API available to **all** doors (not SRE-specific):

```lua
door.db.execute(sql, params)  -- INSERT/UPDATE/DELETE; returns rows_affected
door.db.query(sql, params)    -- SELECT; returns array of row tables
-- params: positional Lua table, e.g. {"A", 42, "neutrality"}
```

**Backed by the existing `bbs.db` SQLite database** in WAL mode for concurrent reads.

**Table prefix enforcement:** Rust parses each SQL statement and rejects any reference
to tables not prefixed `door_<doorname>_`. Doors cannot touch BBS core tables.

**Per-door schema:** `bbs-doors` auto-runs `doors/<name>/schema.sql` (if present) on
every door startup using `CREATE TABLE IF NOT EXISTS` — idempotent, no coordination
with the BBS migration sequence required.

**`door.data` (per-user KV):** Remains available for backward compatibility but is no
longer the recommended pattern. Existing doors are migrated to `door.db.*`.

### Lua Layer — Multi-file structure

```
doors/sre/
  schema.sql              -- CREATE TABLE IF NOT EXISTS for all door_sre_* tables
  main.lua                -- entry point, session loop
  lib/
    db.lua                -- all SQL queries centralized (no raw SQL elsewhere)
    empire.lua            -- load/save empire state
    economy.lua           -- planet income, food, maintenance, pricing modes
    combat.lua            -- 3-front battle engine
    covert.lua            -- 9 covert operation types
    diplomacy.lua         -- 7 treaty types + custom
    bank.lua              -- loans, savings, GC bonds
    lottery.lua           -- jackpot mechanics
    pirates.lua           -- NPC pirate teams
    population.lua        -- birth/death/immigration/emigration
    research.lua          -- breakthrough events, temporary/permanent effects
    messages.lua          -- inter-empire messaging (private + public)
    ui.lua                -- ANSI helpers, menus, pager, status screens
```

`main.lua` loads modules via `require()`. The `bbs-doors` Lua VM is configured with
`doors/sre/` on the package path.

### Existing Doors — Upgraded

| Door | Change |
|------|--------|
| `doors/dragonsbane` | Add `schema.sql` (`door_dragonsbane_characters`); refactor `main.lua` to `door.db.*` |
| `doors/example` | Add `schema.sql` (`door_example_stats`); refactor `main.lua` to `door.db.*` |

---

## Data Model

All tables prefixed `door_sre_*`.

### `door_sre_galaxy`
Key/value global state:
- `mode` — `inflationary` or `non_inflationary`
- `game_day` — current game day (integer, increments daily)
- `last_reset_date` — date of last daily reset (YYYY-MM-DD)
- `food_market_stock` — megatons in the Galactic Coordinator's market
- `food_price` — current credits/megaton
- `pollution_level` — galaxy-wide pollution (0–100)
- `lottery_jackpot` — current jackpot in credits
- `gc_goodwill` — Galactic Coordinator disposition (reduced by nuke/chem use)

### `door_sre_empires`
One row per registered player:

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK | |
| `user_id` | INTEGER UNIQUE | Links to BBS user |
| `name` | TEXT | Empire name |
| `letter` | TEXT UNIQUE | Single letter A–Z |
| `turns_remaining` | INTEGER | Resets to 5 daily |
| `turns_last_reset` | TEXT | YYYY-MM-DD |
| `protection_turns` | INTEGER | Starts at 20, counts down per turn played |
| `credits` | INTEGER | |
| `food` | INTEGER | Megatons |
| `population` | INTEGER | |
| `tax_rate` | INTEGER | Percent |
| `draft_rate` | INTEGER | Percent of population drafted to soldiers |
| `internal_violence` | INTEGER | 0=Peaceful … 7=Under Coup |
| `soldiers` | INTEGER | |
| `fighters` | INTEGER | |
| `defense_stations` | INTEGER | |
| `heavy_cruisers` | INTEGER | |
| `light_cruisers` | INTEGER | |
| `carriers` | INTEGER | 1 per 100 fighters transported |
| `generals` | INTEGER | 1 per 50 soldiers in conventional attack |
| `covert_agents` | INTEGER | |
| `command_ship_strength` | INTEGER | 0 = not built; grows 5%/turn auto |
| `net_worth` | INTEGER | Cached, updated each turn |
| `is_active` | INTEGER | 0 = abdicated |
| `last_played_at` | INTEGER | Unix timestamp |

### `door_sre_planets`
Planet counts per empire per type (planets of the same type are fungible):

| Column | Type | Notes |
|--------|------|-------|
| `empire_id` | INTEGER FK | |
| `planet_type` | TEXT | `ore`, `tourism`, `food`, `supply`, `government`, `education`, `research`, `urban`, `petroleum`, `anti_pollution` |
| `count` | INTEGER | |
| `production_long` | INTEGER | Long-term base production value |
| `production_short` | INTEGER | Current production (converges → long at 10%/turn) |
| `supply_config` | TEXT | For supply planets: unit type produced |

PRIMARY KEY (`empire_id`, `planet_type`)

### `door_sre_treaties`

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK | |
| `empire_a` | INTEGER FK | Lower letter empire |
| `empire_b` | INTEGER FK | Higher letter empire |
| `type` | TEXT | `neutrality`, `free_trade`, `minor_alliance`, `total_defense`, `armed_defense`, `cruiser_protection`, `custom` |
| `soldier_pct` | INTEGER | For custom treaties |
| `cruiser_pct` | INTEGER | For custom treaties |
| `duration_days` | INTEGER | 0 = indefinite |
| `proposed_by` | INTEGER FK | |
| `accepted` | INTEGER | 0=pending, 1=active, -1=rejected |
| `expires_at` | INTEGER | Unix timestamp; NULL = no expiry |

UNIQUE (`empire_a`, `empire_b`) — one treaty pair at a time.

### `door_sre_messages`
```
id, from_empire (nullable = anonymous), subject, body, is_public, sent_at
```
Plus `door_sre_message_recipients(message_id, empire_id, read_at)`.

### `door_sre_lottery`
```
id, empire_id, game_day, ticket_type (standard|super), purchased_at
```
Plus `door_sre_lottery_jackpot(game_day PK, jackpot, winner_empire_id, drawn_at)`.

### `door_sre_bank`
One row per empire:
```
empire_id PK, savings, savings_interest_rate, loan_amount, loan_interest_rate,
bonds (count), bond_maturity_day
```
GC Bonds: cost 8,500 credits, return 10,000 after 10–20 game days. Hidden from attackers.

### `door_sre_pirates`
NPC teams raiding the galaxy:
```
id, name, planets, soldiers, credits, food,
loot_credits, loot_food, loot_soldiers, is_active
```

### `door_sre_covert_ops`
Daily operation tracking (prevents >1 of each op per target per day):
```
PRIMARY KEY (empire_id, target_empire_id, op_type, game_day)
```

### `door_sre_research_effects`
Active research breakthroughs per empire:
```
id, empire_id, effect_type, magnitude (percent), is_permanent,
expires_at_turn (NULL if permanent)
```

### `door_sre_events`
Offline notification queue (attacks received, treaties broken, hostages, pirate raids):
```
id, empire_id, event_type, description, game_day, created_at, read_at
```
Shown to player at login; marked read immediately after display.

---

## Game Systems

### Session Flow

```
Login
  → Show unread events (attacks, treaty breaks, covert op results)
  → Lottery ticket purchase
  → FOR EACH TURN (up to 5/day):
      1. Earnings report      — planet income, research discoveries
      2. Status screen        — full empire overview
      3. Maintenance          — pay army + planets (pay-all shortcut if affordable)
      4. Food market          — buy/sell; feed population
      5. Covert operations    — if covert_agents > 0
      6. Bank                 — savings, loans, bonds
      7. Government spending ←→ Operations menu (messages, status, scores, config)
      8. Battles
      9. Trading
     10. Final status         — population change, civil war losses
  → Logout
```

Protection: starts at 20 turns, decrements each turn played. During protection: no
attacking, no being attacked, no covert ops except Spy.

### Economy

**Planet production per turn:**
```
production_short += ceil((production_long - production_short) * 0.1)
actual_output = gaussian(production_short, σ=5%)
```

| Type | Income source | Special |
|------|--------------|---------|
| Ore | Steady credits | Safe/boring; unaffected by violence |
| Tourism | Credits × peace_multiplier | 1.5× Peaceful → 0× Under Coup; damaged post-attack |
| Petroleum | Credits × demand_factor | demand = 1 / (petroleum_planets / total_planets); +1 pollution/turn |
| Anti-pollution | None | Absorbs 3 pollution/turn/planet |
| Urban | Sales tax + income tax | Births ∝ population (exponential growth) |
| Education | None | Immigration ∝ education_count (linear growth) |
| Food | 46–54 megatons/turn gaussian | Boosted by research |
| Supply | Military units at 60% cost | Configurable unit type |
| Government | None | Required for generals; covert agent cap 300/planet |
| Research | Research points → breakthroughs | 20% permanent, 80% temporary effects |

**Pricing modes (sysop-configurable in `door_sre_galaxy`):**
- *Inflationary:* buy prices ∝ `net_worth^0.5`; maintenance fixed ~1,000/planet
- *Non-inflationary:* buy prices fixed; maintenance = `base + log(net_worth) × scale`

**Food market:** price = f(market_stock + all_empire_food). Prevents buy-all/sell-all
price manipulation.

### Combat — 3-Front Battle

Each round both sides attack all three enemy groups simultaneously.

**Cross-effectiveness matrix:**

| Attacker \ Target | Soldiers | Defense Stations | Heavy Cruisers |
|-------------------|----------|-----------------|----------------|
| Soldiers | 3× | 1× | 1× |
| Fighters | 1× | 4× | 1× |
| Heavy Cruisers | 2× | 2× | 10× |

**Defense strength:** Soldiers = 10×, Stations = 25×, Heavy Cruisers = 15×

Light cruisers fight with heavy cruisers; get 5 free rounds before enemy responds;
no command ship bonus.

Command ship: +5% to heavy cruiser attack effectiveness/turn (auto); can be
manually boosted by spending credits.

**Attack types:**

| Type | Description |
|------|-------------|
| Conventional | 3-front battle; allies notified and send forces; planets/credits captured on win |
| Guerilla Ambush | Damage ∝ defender army size (equalizer); no allies; no planet capture; 10% id risk |
| Nuclear | High damage; GC goodwill penalty per use; enough uses → GC attacks you |
| Chemical | Higher damage; instant annihilation if caught |
| Psionic Bombs | Mass civilian confusion + troop demoralization |
| Pirate Raid | Spend credits + military to recapture loot from NPC pirates |
| Spy on Pirates | Free; reveals pirate planet count and net worth |

**Winning a conventional attack:** captures planets and credits proportional to
margin of victory. Looted planets are transferred; looted credits are halved (friction).

### Diplomacy

7 treaty types with escalating mutual defense:

1. Neutrality Treaty — no attacks; enables trading
2. Free Trade Agreement — no attacks; tariff income
3. Minor Alliance — auto-sends defense forces when ally attacked
4. Total Defense — sends more forces than Minor Alliance
5. Armed Defense Pact — soldiers only; higher commitment than Total Defense
6. Cruiser Protection Plan — heavy cruisers patrol both empires
7. Custom — player-set soldier% and cruiser% for mutual defense

Proposals stored with `accepted=0`; target sees proposal on next login.
Binding (duration > 0): attacks/covert ops blocked.
Expired: still exists; attacking cancels it immediately.

### Covert Operations

9 operations; 8 require being out of protection. Daily limits via `door_sre_covert_ops`.

| # | Operation | Limit | Delay |
|---|-----------|-------|-------|
| 1 | Send Spy | Unlimited | Immediate |
| 2 | Insurgent Aid* | 1/day/empire | Immediate |
| 3 | Set Up* | 1/day/pair | Queued until target plays |
| 4 | Support Dissension* | 1/day/empire | 12 real hours |
| 5 | Demoralize Troops* | 1/day/empire | 12 real hours |
| 6 | Bombing Operations* | 1/day/empire | 12 real hours |
| 7 | Relations Spying* | Unlimited | Immediate |
| 8 | Take Hostages* | 1/day/empire | 12 real hours |
| 9 | Bribe Personnel* | Unlimited | Immediate |

Delayed ops are queued as `door_sre_events` and executed when the target next logs in.

### Population

Each turn end:
```
births      = population × urban_factor × rand(0.8, 1.2)
immigration = education_planets × base_rate × peace_factor
deaths      = population × (overcrowding_factor + violence_factor)
emigration  = population × violence_factor × rand(0.5, 1.5)
net_change  = births + immigration − deaths − emigration
```

Draft rate converts a % of population to soldiers at turn start (before maintenance).

### Internal Violence

8 levels (0 = Peaceful → 7 = Under Coup). Increases from: covert attacks, guerilla
ambushes, civil war, high taxes/riots. Decreases naturally over turns. Each level
reduces tourism income, increases emigration, and at high levels devastates multiple
income streams.

### Bank

- Savings: 5% interest/game-turn
- Loans: interest rate = `base + (active_loans / total_empires) × scale` (more borrowers → higher rate)
- GC Bonds: cost 8,500; return 10,000 after 10–20 game days; invisible to attackers/hostage-takers

### Lottery

- Seed jackpot at game reset (500,000 credits)
- Standard ticket: 5,000 credits; 4,500 → jackpot (house keeps 500)
- Super ticket (Operations menu): 25,000 credits; counts as 10 entries
- Daily drawing: random ticket wins; all players notified via events
- Negative feedback: more tickets → lower expected payout → self-balancing participation

### Research

Each turn: `breakthrough_chance = research_points / 1000`

On breakthrough, roll effect type: food yield boost, tourism attraction, pollution
reduction, military production increase, crop protein yield, etc.

- Permanent (20%): modifies `production_long`
- Temporary (80%): modifies `production_short`; expires after 5–15 turns
- Mean-reversion ensures temporary boosts fade naturally

### Pirates

NPC pirate teams spawn at game reset and periodically thereafter. Each team has
planets, soldiers, credits, food, and a loot inventory (stolen from empires).
Pirates raid empires automatically (written to `door_sre_events`). Players can spy
on pirates (free) or raid them (costs a battle turn) to recover loot.

---

## Data Flow

### Per-turn transaction pattern

Every turn wrapped in a `door.db` transaction:
```
BEGIN TRANSACTION
  read empire state
  compute income / run planet production
  prompt player for decisions
  write all changes
COMMIT
```
Disconnect mid-turn → rollback → empire unchanged → safe re-entry.

### Inter-empire interactions

Attacks, trades, and covert ops lock empires in consistent order (lower `id` first)
to prevent deadlocks when two players interact simultaneously.

### Daily reset

On first login of each real day: check `galaxy.last_reset_date < today`. If true,
a guarded transaction (unique constraint) fires the reset job exactly once regardless
of simultaneous logins:
- Refill all empires to 5 turns
- Accrue bank interest on savings and loans
- Age research effects (decrement temporary expiries)
- Advance petroleum price based on current planet counts
- Trigger pirate raids (random empire targets)
- Draw lottery winner
- Increment `game_day`

---

## Error Handling

| Scenario | Handling |
|----------|----------|
| Disconnect mid-turn | Transaction rollback; empire unchanged |
| Insufficient credits | Advisor warnings one step before crisis; forced partial payments (sell units at 1/3 price) |
| Insufficient food | Advisor warning; army shrinks if unfed; population drops |
| Table prefix violation | Rejected at Rust layer before SQL executes |
| Lua error in door | `bbs-doors` catches panic; session terminates gracefully |
| Concurrent attack | Empire state locked for combat transaction duration |
| Simultaneous daily reset | Unique constraint on reset record; only one session fires reset |
| Date/time bugs | Unix timestamps throughout; no string date comparisons for game logic |

---

## What Gets Built

| Component | Work |
|-----------|------|
| `crates/bbs-doors` | `door.db.query/execute` Lua API; `schema.sql` auto-run on door start; table prefix enforcement in Rust |
| `doors/dragonsbane` | `schema.sql` + refactor `main.lua` to `door.db.*` typed columns |
| `doors/example` | `schema.sql` + refactor `main.lua` to `door.db.*` |
| `doors/sre/schema.sql` | All `door_sre_*` table definitions |
| `doors/sre/main.lua` | Session entry point and turn loop |
| `doors/sre/lib/db.lua` | Centralized SQL queries |
| `doors/sre/lib/empire.lua` | Empire load/save |
| `doors/sre/lib/economy.lua` | Planet income, pricing modes |
| `doors/sre/lib/combat.lua` | 3-front battle engine |
| `doors/sre/lib/covert.lua` | 9 covert op types |
| `doors/sre/lib/diplomacy.lua` | 7 treaty types + custom |
| `doors/sre/lib/bank.lua` | Loans, savings, bonds |
| `doors/sre/lib/lottery.lua` | Jackpot mechanics |
| `doors/sre/lib/pirates.lua` | NPC pirate teams |
| `doors/sre/lib/population.lua` | Birth/death/immigration |
| `doors/sre/lib/research.lua` | Breakthrough events |
| `doors/sre/lib/messages.lua` | Inter-empire messaging |
| `doors/sre/lib/ui.lua` | ANSI helpers, menus, pager |
