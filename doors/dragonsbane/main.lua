-- doors/dragonsbane/main.lua
-- Dragon's Bane — A classic BBS door RPG
--
-- Fight monsters in the realm, level up your hero, equip better gear,
-- and eventually face the Dragon.  Character progress is saved between
-- sessions via door.db (SQLite).  You get 10 turns per day.

math.randomseed(door.time() + door.user.id * 1337)

-- ── ANSI helpers ──────────────────────────────────────────────────────────
local ESC = string.char(27)
local function ansi(code) return ESC.."["..code.."m" end
local RST  = ansi("0")
local BOL  = ansi("1")
local RED  = ansi("31"); local GRN = ansi("32"); local YEL = ansi("33")
local BLU  = ansi("34"); local MAG = ansi("35"); local CYN = ansi("36")
local WHT  = ansi("37")
local BRED = BOL..RED;   local BGRN = BOL..GRN; local BYEL = BOL..YEL
local BCYN = BOL..CYN;   local BMAG = BOL..MAG; local BWHT = BOL..WHT

local function W(s)   door.write(s)      end
local function WL(s)  door.writeln(s or "") end
local function CLS()  door.clear()       end
local function KEY()  return door.read_key()  end
local function WAIT(ms) door.sleep(ms or 600) end

local function pause()
    WL(CYN.."\r\n  [ press any key ]"..RST)
    KEY()
end

local function input(prompt)
    W(prompt)
    return door.read_line()
end

local function divider()
    WL(CYN..string.rep("-", 52)..RST)
end

local function header(title)
    WL("")
    WL(BCYN..string.rep("=", 52)..RST)
    WL(BCYN.."  "..title..RST)
    WL(BCYN..string.rep("=", 52)..RST)
    WL("")
end

local function hp_bar(hp, max)
    local w     = 20
    local fill  = math.max(0, math.floor(hp / max * w))
    local color = hp > max * 0.5 and GRN
               or hp > max * 0.25 and YEL
               or BRED
    return "["..color..string.rep("#", fill)..RST..string.rep(".", w - fill).."]"
end

-- ── DATA TABLES ──────────────────────────────────────────────────────────
local DAILY_TURNS = 10

local WEAPONS = {
    { n="Rusty Dagger",    a=0,  c=0    },
    { n="Short Sword",     a=3,  c=150  },
    { n="Broadsword",      a=7,  c=400  },
    { n="Battle Axe",      a=11, c=900  },
    { n="War Hammer",      a=16, c=1800 },
    { n="Enchanted Blade", a=22, c=3500 },
}

local ARMORS = {
    { n="Tattered Cloth",  d=0,  c=0    },
    { n="Leather Armor",   d=3,  c=100  },
    { n="Chain Mail",      d=7,  c=350  },
    { n="Plate Mail",      d=12, c=800  },
    { n="Mithril Armor",   d=18, c=2000 },
}

-- name, min_level, hp_range, atk_range, def, xp, gold_range
local MONSTERS = {
    { n="Goblin",       ml=1,  hp={8,18},    a={3,8},    d=1,  x=20,  g={5,20}   },
    { n="Giant Rat",    ml=1,  hp={5,14},    a={2,7},    d=0,  x=14,  g={2,14}   },
    { n="Kobold",       ml=1,  hp={12,22},   a={4,9},    d=2,  x=28,  g={8,25}   },
    { n="Skeleton",     ml=2,  hp={18,32},   a={6,12},   d=3,  x=45,  g={12,35}  },
    { n="Orc",          ml=3,  hp={25,42},   a={8,15},   d=5,  x=65,  g={20,50}  },
    { n="Zombie",       ml=3,  hp={20,38},   a={7,13},   d=3,  x=55,  g={15,40}  },
    { n="Hobgoblin",    ml=4,  hp={30,52},   a={10,17},  d=6,  x=85,  g={28,65}  },
    { n="Troll",        ml=5,  hp={42,68},   a={13,20},  d=7,  x=115, g={38,85}  },
    { n="Ogre",         ml=6,  hp={55,85},   a={15,24},  d=9,  x=145, g={50,110} },
    { n="Gargoyle",     ml=6,  hp={38,65},   a={14,21},  d=10, x=135, g={44,95}  },
    { n="Dark Knight",  ml=8,  hp={65,95},   a={17,26},  d=12, x=185, g={65,140} },
    { n="Demon",        ml=9,  hp={75,115},  a={19,29},  d=14, x=225, g={85,170} },
    { n="Dragon",       ml=10, hp={120,160}, a={22,35},  d=16, x=400, g={200,400} },
}

-- ── CHARACTER ─────────────────────────────────────────────────────────────
local C = {}
local UID = door.user.id

local function load_char()
    local today = os.date("%Y-%m-%d")
    local rows  = door.db.query(
        "SELECT * FROM door_dragonsbane_characters WHERE user_id = ?",
        {UID}
    )
    if #rows == 0 then
        -- First visit: insert a default row then load defaults
        door.db.execute(
            "INSERT INTO door_dragonsbane_characters (user_id) VALUES (?)",
            {UID}
        )
        C.level  = 1;  C.xp    = 0;  C.max_hp = 25; C.hp    = 25
        C.str    = 5;  C.def   = 2;  C.gold   = 50; C.watk  = 0
        C.ddef   = 0;  C.kills = 0;  C.deaths = 0
        C.wname  = "Rusty Dagger";   C.aname  = "Tattered Cloth"
        C.turns  = DAILY_TURNS;      C.tdate  = today
    else
        local r  = rows[1]
        C.level  = r.level;    C.xp     = r.xp;    C.max_hp = r.max_hp
        C.hp     = r.hp;       C.str    = r.strength; C.def  = r.defense
        C.gold   = r.gold;     C.watk   = r.watk;  C.ddef   = r.ddef
        C.wname  = r.wname;    C.aname  = r.aname
        C.kills  = r.kills;    C.deaths = r.deaths
        if r.tdate ~= today then
            C.turns = DAILY_TURNS
        else
            C.turns = r.turns
        end
        C.tdate = today
    end
end

local function save_char()
    door.db.execute([[
        UPDATE door_dragonsbane_characters SET
            level=?, xp=?, max_hp=?, hp=?, strength=?, defense=?,
            gold=?, watk=?, ddef=?, wname=?, aname=?,
            kills=?, deaths=?, turns=?, tdate=?
        WHERE user_id=?
    ]], {
        C.level, C.xp, C.max_hp, math.max(1, C.hp), C.str, C.def,
        C.gold, C.watk, C.ddef, C.wname, C.aname,
        C.kills, C.deaths, C.turns, C.tdate, UID
    })
end

local function xp_cap()  return C.level * 100 end

local function check_levelup()
    while C.xp >= xp_cap() do
        C.xp     = C.xp - xp_cap()
        C.level  = C.level + 1
        local gh = math.random(8, 15)
        local gs = math.random(1, 3)
        local gd = math.random(1, 2)
        C.max_hp = C.max_hp + gh
        C.hp     = math.min(C.hp + gh, C.max_hp)   -- heal on level-up
        C.str    = C.str + gs
        C.def    = C.def + gd
        WL("")
        WL(BYEL.."  *** LEVEL UP!  You are now Level "..C.level.." ***"..RST)
        WAIT(200)
        WL(GRN..string.format("  Max HP +%d | Strength +%d | Defense +%d",
            gh, gs, gd)..RST)
        WAIT(200)
    end
end

local function show_status()
    header(BYEL.."[ Character Status ]"..RST)
    WL(string.format("  %sHero:%s %-18s  %sLevel:%s %d  (%sXP:%s %d / %d)",
        CYN, RST, door.user.name,
        CYN, RST, C.level,
        CYN, RST, C.xp, xp_cap()))
    WL(string.format("  %sHP:%s %s %3d/%-3d  %sStr:%s %2d  %sDef:%s %2d  %sGold:%s %d",
        CYN, RST, hp_bar(C.hp, C.max_hp), C.hp, C.max_hp,
        CYN, RST, C.str + C.watk,
        CYN, RST, C.def + C.ddef,
        CYN, RST, C.gold))
    WL(string.format("  %sWeapon:%s %-22s  %sArmor:%s %s",
        CYN, RST, C.wname,
        CYN, RST, C.aname))
    WL(string.format("  %sKills:%s %-5d  %sDeaths:%s %-5d  %sTurns left today:%s %s%d%s",
        CYN, RST, C.kills,
        CYN, RST, C.deaths,
        CYN, RST,
        C.turns > 0 and BGRN or BRED, C.turns, RST))
    divider()
end

-- ── COMBAT ────────────────────────────────────────────────────────────────
local function pick_monster()
    local pool = {}
    for _, m in ipairs(MONSTERS) do
        if m.ml <= C.level + 1 and m.ml >= math.max(1, C.level - 2) then
            table.insert(pool, m)
        end
    end
    if #pool == 0 then pool = { MONSTERS[1] } end
    return pool[math.random(#pool)]
end

local function do_combat()
    if C.turns <= 0 then
        WL(BRED.."  You have no turns left today.  Rest and return tomorrow."..RST)
        pause()
        return
    end

    local mt   = pick_monster()
    local mhp  = math.random(mt.hp[1], mt.hp[2])
    local matk = mt.a          -- kept as range table
    local mdef = mt.d

    C.turns = C.turns - 1
    save_char()

    CLS()
    WL("")
    WL(BRED..string.rep("*", 52)..RST)
    WL(BRED.."  A wild "..BWHT..mt.n..BRED.." appears!"..RST)
    WL(BRED..string.rep("*", 52)..RST)
    WL("")

    local escaped = false

    while C.hp > 0 and mhp > 0 do
        -- Status line
        WL(string.format("  %sYou:%s %s %d/%d   %s%s:%s %s%d HP%s",
            GRN, RST, hp_bar(C.hp, C.max_hp), C.hp, C.max_hp,
            YEL, mt.n, RST,
            mhp > mt.hp[2] * 0.5 and GRN or (mhp > mt.hp[2] * 0.25 and YEL or BRED),
            mhp, RST))
        WL("")
        W(CYN.."  [A]ttack  [F]lee > "..RST)
        local k = KEY()
        if k == nil then break end
        k = k:upper()
        WL("")

        if k == "F" then
            -- 40% base flee chance, improves with level difference
            local flee_roll = math.random(1, 100)
            if flee_roll <= 40 then
                WL(YEL.."  You dash away from the "..mt.n.."!"..RST)
                escaped = true
                break
            else
                WL(RED.."  You couldn't escape!  The "..mt.n.." blocks your path!"..RST)
            end
        else
            -- Player attacks
            local p_atk = C.str + C.watk + math.random(1, 8)
            local dmg   = math.max(1, p_atk - mdef)
            mhp = mhp - dmg
            WL(string.format("  %sYou strike the %s for %s%d damage%s!",
                GRN, mt.n, BYEL, dmg, RST))
            WAIT(300)
        end

        if mhp <= 0 then break end

        -- Monster attacks
        local m_atk  = math.random(matk[1], matk[2])
        local m_dmg  = math.max(1, m_atk - (C.def + C.ddef) - math.random(0, 3))
        C.hp = C.hp - m_dmg
        WL(string.format("  %sThe %s hits you for %s%d damage%s!",
            RED, mt.n, BRED, m_dmg, RST))
        WAIT(300)
        WL("")

        save_char()
    end

    WL("")

    if escaped then
        -- no reward
    elseif C.hp <= 0 then
        -- Death
        C.hp     = math.max(1, math.floor(C.max_hp * 0.3))
        C.gold   = math.floor(C.gold * 0.5)
        C.deaths = C.deaths + 1
        save_char()
        WL(BRED.."  You have been slain by the "..mt.n.."!"..RST)
        WL(RED.."  You wake in town, stripped of half your gold."..RST)
        WL(RED..string.format("  HP restored to %d.  Gold remaining: %d.", C.hp, C.gold)..RST)
        pause()
    else
        -- Victory
        local xp_gain   = mt.x + math.random(-5, 5)
        local gold_gain = math.random(mt.g[1], mt.g[2])
        C.xp    = C.xp    + xp_gain
        C.gold  = C.gold  + gold_gain
        C.kills = C.kills + 1
        WL(BGRN.."  You defeated the "..mt.n.."!"..RST)
        WL(GRN..string.format("  Gained %s%d XP%s and %s%d gold%s.",
            BYEL, xp_gain, RST, YEL, gold_gain, RST))
        check_levelup()
        save_char()
        WL("")
        W(CYN.."  [C]ontinue fighting  [T]own > "..RST)
        local k = KEY()
        WL("")
        if k == nil or k:upper() == "T" then return end
        -- loop back handled by caller
        do_combat()   -- tail-recurse for another fight
    end
end

-- ── TOWN ──────────────────────────────────────────────────────────────────
local function healer()
    header(BGRN.."[ The Healer's Hut ]"..RST)
    if C.hp >= C.max_hp then
        WL("  \"You look perfectly healthy to me!\"")
        pause()
        return
    end
    local missing = C.max_hp - C.hp
    local cost    = missing * 5
    WL(string.format("  \"I can restore %s%d HP%s for %s%d gold%s.\"",
        GRN, missing, RST, YEL, cost, RST))
    WL(string.format("  Your gold: %s%d%s", YEL, C.gold, RST))
    WL("")
    W(CYN.."  Heal? [Y/N] > "..RST)
    local k = KEY()
    WL("")
    if k and k:upper() == "Y" then
        if C.gold >= cost then
            C.gold = C.gold - cost
            C.hp   = C.max_hp
            save_char()
            WL(GRN.."  \"There you go, good as new!\""..RST)
        else
            WL(RED.."  \"You can't afford that!\""..RST)
        end
    end
    pause()
end

local function shop(items, label, stat_key, name_key, owned_name)
    header(BCYN.."[ "..label.." ]"..RST)
    WL(string.format("  Your gold: %s%d%s  |  Current: %s%s%s",
        YEL, C.gold, RST, CYN, owned_name, RST))
    WL("")
    for i, item in ipairs(items) do
        local tag = (item.n == owned_name) and GRN.." <equipped>"..RST or ""
        WL(string.format("  [%d] %-22s  %s+%2d%s  %s%d gold%s%s",
            i, item.n,
            YEL, (stat_key == "a" and item.a or item.d), RST,
            YEL, item.c, RST, tag))
    end
    WL("")
    W(CYN.."  Buy # (or Enter to leave) > "..RST)
    local choice = door.read_line()
    local n = tonumber(choice)
    if not n or not items[n] then return end
    local item = items[n]
    if item.n == owned_name then
        WL(YEL.."  You already own that."..RST)
    elseif C.gold < item.c then
        WL(RED.."  Not enough gold!"..RST)
    else
        C.gold = C.gold - item.c
        if stat_key == "a" then
            C.watk  = item.a
            C.wname = item.n
        else
            C.ddef  = item.d
            C.aname = item.n
        end
        save_char()
        WL(GRN.."  Purchased: "..item.n..RST)
    end
    pause()
end

local function town()
    while true do
        CLS()
        header(BCYN.."[ The Town of Arendel ]"..RST)
        WL("  A small but busy market town at the edge of the wild.")
        WL("")
        WL(string.format("  %sHP:%s %d/%d   %sGold:%s %d   %sTurns left:%s %s%d%s",
            GRN, RST, C.hp, C.max_hp,
            YEL, RST, C.gold,
            CYN, RST,
            C.turns > 0 and GRN or RED, C.turns, RST))
        WL("")
        WL("  [H] Healer     [W] Weapon Shop")
        WL("  [A] Armor Shop [Q] Leave Town")
        WL("")
        W(CYN.."  Choice > "..RST)
        local k = KEY()
        if k == nil then return end
        k = k:upper()
        WL("")

        if     k == "H" then healer()
        elseif k == "W" then shop(WEAPONS, "Weapon Shop", "a", "wn", C.wname)
        elseif k == "A" then shop(ARMORS,  "Armor Shop",  "d", "an", C.aname)
        elseif k == "Q" then return
        end
    end
end

-- ── TITLE / INTRO ─────────────────────────────────────────────────────────
local function title_screen()
    CLS()
    WL("")
    WL(BRED..  "  ██████╗ ██████╗  █████╗  ██████╗  ██████╗ ███╗   ██╗"..RST)
    WL(BRED..  "  ██╔══██╗██╔══██╗██╔══██╗██╔════╝ ██╔═══██╗████╗  ██║"..RST)
    WL(BRED..  "  ██║  ██║██████╔╝███████║██║  ███╗██║   ██║██╔██╗ ██║"..RST)
    WL(BRED..  "  ██║  ██║██╔══██╗██╔══██║██║   ██║██║   ██║██║╚██╗██║"..RST)
    WL(BRED..  "  ██████╔╝██║  ██║██║  ██║╚██████╔╝╚██████╔╝██║ ╚████║"..RST)
    WL(BRED..  "  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝"..RST)
    WL(YEL..   "                    ╔══════════════╗"..RST)
    WL(BYEL..  "                    ║  D R A G O N  ║"..RST)
    WL(BYEL..  "                    ║   ' S  B A N E ║"..RST)
    WL(YEL..   "                    ╚══════════════╝"..RST)
    WL("")
    WL(CYN.."  A classic BBS door RPG  —  "..BWHT..door.user.name..RST)
    WL("")
    WL(GRN.."  Fight monsters. Level up. Equip the best gear."..RST)
    WL(GRN.."  Survive long enough to slay the Dragon."..RST)
    WL("")
    WL(YEL..string.format("  You have %s%d turns%s available today.",
        C.turns > 0 and BGRN or BRED, C.turns, YEL)..RST)
    if C.level > 1 then
        WL(CYN..string.format("  Welcome back, %s!  Level %d hero.",
            door.user.name, C.level)..RST)
    else
        WL(CYN.."  A new hero enters the realm..."..RST)
    end
    WL("")
    pause()
end

-- ── MAIN LOOP ─────────────────────────────────────────────────────────────
load_char()
title_screen()

local running = true
while running do
    CLS()
    show_status()
    WL("  [1] Town of Arendel   [2] Venture into the Forest")
    WL("  [S] Full Status       [Q] Quit")
    WL("")
    W(CYN.."  Choice > "..RST)
    local k = KEY()
    if k == nil then break end
    k = k:upper()
    WL("")

    if k == "1" then
        town()
    elseif k == "2" then
        CLS()
        do_combat()
    elseif k == "S" then
        CLS()
        show_status()
        pause()
    elseif k == "Q" then
        running = false
    end
end

save_char()
CLS()
WL("")
WL(BCYN.."  Farewell, "..door.user.name.."."..RST)
WL(YEL..string.format("  Level %d | %d kills | %d deaths | %d gold",
    C.level, C.kills, C.deaths, C.gold)..RST)
WL("")
WL(GRN.."  Your legend continues..."..RST)
WL("")
door.sleep(1500)
door.exit()
