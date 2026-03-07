# BBS Features

A multi-protocol Bulletin Board System written in Rust with Lua scripting.
Rust is the engine; all BBS logic and door games are written in Lua.

---

## Protocols

| Protocol | Port  | Notes |
|----------|-------|-------|
| Telnet   | 2323  | Raw TCP, VT100 state machine |
| SSH      | 2222  | russh; full terminal after handshake |
| HTTP     | 8080  | axum + WebSocket terminal bridge |
| NNTP     | 1119  | Message boards exposed as newsgroups |

Each connection gets an isolated Lua VM running in its own OS thread.

---

## Authentication

- Login with username + password (argon2 password hashing)
- New-user self-registration (`new` at the login prompt)
- Login rate limiting / throttle with cooldown timer
- Account ban/unban by sysop
- Banned users are rejected at login

---

## Main Menu

- **Bulletins** — system announcements shown at login and browsable
- **Message Boards** — multi-board public message system
- **Door Games** — launch installed door games
- **E-mail / Mail** — private user-to-user messaging
- **User Profile** — stats and password change
- **Who's Online** — live list of connected users
- **System Info** — current time and role display
- **Admin Panel** — sysop-only user/board management

Unread mail count shown in the menu header when mail is waiting.
Last-callers list shown on the welcome screen.

---

## Bulletins

- Sysop-posted system-wide announcements
- Displayed automatically at login
- Interactive browser: list, read (with pager), post, delete
- Delete is sysop-only

---

## Message Boards

- Multiple named boards, each with description
- Threaded display: replies indented under parent messages, depth-first
- Per-board new-message count (unread tracking via visit timestamps)
- Post new messages and threaded replies
- Full-text search across all boards
- Boards appear as NNTP newsgroups (read/post via standard newsreaders)

---

## Private Mail

- User-to-user private messages
- Inbox with unread (`*`) indicators
- Sent-mail folder
- Compose with multi-line body (`.` to end)
- Mark individual messages read on open
- Unread count visible in the main menu header

---

## User Profile

- View stats: joined date, last login, post count, mail sent/received
- Change password (requires current password verification)
- Sysop role shown if applicable

---

## Who's Online

- Live list of currently connected users with connection time

---

## Sysop Admin Panel

Sysop-only. Accessible from the main menu (`A`).

**User management:**
- List all users with sysop/banned status and last-login date
- Promote user to sysop
- Demote sysop to user
- Ban user (sysops cannot be banned)
- Unban user

**Board management:**
- List all boards
- Create new board (name + description)
- Delete board and all its messages (with confirmation prompt)

---

## Door Games

Doors are drop-in Lua scripts in `doors/<name>/main.lua`.
Each door runs in an isolated Lua VM with the `door.*` API.
Per-door SQLite storage via `door.db.query()` / `door.db.execute()`.
Table-name prefix enforcement prevents doors from touching each other's data.
Optional `schema.sql` is run automatically on first session.
DOS game support reserved (`door.launch_dos()` stub for DOSBox-X integration).

### Dragon's Bane

Classic single-player BBS RPG door.

- 10 turns per day (resets at midnight)
- Character persistence: level, XP, HP, strength, defense, gold, kill/death counts
- Level-up system with HP and stat increases
- Combat against randomized monsters scaled to player level
- Weapon and armor shop (11 weapons, 10 armors)
- Boss fight: the Dragon (unlocked at level 5+)
- HP bar with color coding (green/yellow/red)
- Animated combat with delays

### Solar Realms Elite (SRE)

Multi-player space empire strategy door. Up to 26 simultaneous empires (A–Z).

**Empire management:**
- Register and name your empire; assigned a unique letter
- 6 planet types: ore, food, government, research, industrial, energy
- Buy planets, soldiers, fighters, heavy cruisers, carriers, generals, agents
- Net worth calculation drives maintenance costs
- 20 turns of new-empire protection
- 5 turns per real day, shared galaxy

**Economy:**
- Stochastic production using Box-Muller Gaussian noise with mean reversion
- Per-planet income: credits, food production, research points, supply, pollution
- Galaxy-wide food market with dynamic pricing (supply/demand)
- Buy/sell food on the open market
- Two economy modes: non-inflationary (fixed prices) and inflationary (net-worth scaling)
- Maintenance costs: army upkeep + planet maintenance (log-scaled)

**Population:**
- Population growth (births, immigration), death, and emigration each turn
- Draft population into soldiers at a configurable rate
- Starvation causes soldier desertions, population collapse, and violence increase
- Violence level affects emigration and mortality rates

**Research:**
- Spend research points each turn
- 8 breakthrough effect types (production boosts, food efficiency, etc.)
- Effects have configurable duration; some are permanent

**Combat (4 types):**
- Conventional: 20-round battle with general/carrier limits, cruiser pre-fire, planet capture
- Guerilla: proportional damage, 10% chance of insurgent ID
- Psionic: violence spike, soldiers flee
- Nuclear: destroys 40% of a random planet type, destroys food, reduces galactic goodwill
- Ally call-in: treaty partners contribute forces to defense

**Diplomacy (7 treaty types):**
- Neutrality, free trade, minor alliance, total defense, armed defense, cruiser protection, custom
- Propose, accept, and break treaties
- Attack restrictions enforced by treaty
- Tariff income from trade partners
- New-empire void protection (cannot be attacked for 20 turns)

**Covert ops (9 operations):**
- Spy (intel gathering), insurgent (sabotage), setup (planet capture), dissension (morale),
  demoralize (turns lost), bombing (planet destruction), relationship spy, hostage, bribery
- Daily limit per empire; protection check before each op
- Delayed effects applied on next login

**Banking:**
- Deposit and withdraw credits
- Variable-rate loans (8–20%, dynamic based on galaxy conditions)
- Government bonds: 10- and 20-day terms, guaranteed return
- Interest accrues daily

**Lottery:**
- Standard tickets and super tickets (10x entries)
- Daily jackpot draw; winner announced in events
- Jackpot seeds at 500,000 credits and rolls over if no winner

**Pirates:**
- 4 NPC pirate factions active in the galaxy at all times
- Raid empires daily for credits, food, and soldiers
- Players can spy on pirates or launch raids to steal their loot

**Messaging:**
- Empire-to-empire in-game mail (public or anonymous)
- Inbox with unread tracking
- Compose with subject and multi-line body

**Scoreboard & events:**
- Ranked scoreboard by net worth
- Per-empire event log: combat results, covert op outcomes, lottery wins, pirate raids
- Unread events shown on login

### Example Door

Minimal reference door demonstrating the `door.*` API and `door.db` persistence.
Tracks visit count and best guessing-game score per user across sessions.

---

## ANSI / Terminal

- Full ANSI/VT100 colour and formatting throughout
- Box-drawing characters for menus and status screens
- Scrollable pager for long content
- Color-coded HP bars, status indicators, and menu keys
- ANSI art support via `bbs.ansi()` / `door.ansi()` named art files

---

## Database

- SQLite via sqlx; all state is persistent across restarts
- Schema managed by numbered migration files
- Per-door isolated key-value store and arbitrary SQL tables
- Door table names enforced to `door_<name>_*` prefix (security isolation)
