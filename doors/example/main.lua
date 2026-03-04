-- doors/example/main.lua
-- Example door game demonstrating the full door.* API.
-- Run by bbs-doors when a user launches the "example" door.

local DOOR_NAME = "Example Door"
local VERSION   = "1.0"

local function show_banner()
    door.clear()
    door.writeln(door.ansi("bold") .. "=== " .. DOOR_NAME .. " v" .. VERSION .. " ===" .. door.ansi("reset"))
    door.writeln("Welcome, " .. door.user.name .. "!")
    door.writeln("")
end

local function show_stats()
    -- Upsert visit counter via door.db
    local uid = door.user.id
    door.db.execute([[
        INSERT INTO door_example_stats (user_id, visits) VALUES (?, 1)
        ON CONFLICT(user_id) DO UPDATE SET visits = visits + 1
    ]], {uid})
    local rows   = door.db.query(
        "SELECT visits, best_guesses FROM door_example_stats WHERE user_id = ?",
        {uid}
    )
    local visits = rows[1] and rows[1].visits or 1

    door.writeln("Your visit count: " .. visits)
    door.writeln("Server time:      " .. os.date("%Y-%m-%d %H:%M:%S", door.time()))
    if door.user.is_sysop then
        door.writeln("(You are the sysop)")
    end
    door.writeln("")
end

local function guessing_game()
    door.writeln("--- Number Guessing Game ---")
    door.writeln("I'm thinking of a number between 1 and 10.")
    door.writeln("")

    math.randomseed(door.time())
    local secret  = math.random(1, 10)
    local guesses = 0
    local max     = 3

    while guesses < max do
        local input = door.read_line("Guess (" .. (max - guesses) .. " left): ")
        if input == nil then break end
        local n = tonumber(input)
        guesses = guesses + 1

        if not n then
            door.writeln("Please enter a number.")
        elseif n == secret then
            door.writeln("Correct! Well done!")
            -- Save best guesses via door.db
            local uid  = door.user.id
            local rows = door.db.query(
                "SELECT best_guesses FROM door_example_stats WHERE user_id = ?",
                {uid}
            )
            local best = rows[1] and rows[1].best_guesses
            if best == nil or guesses < best then
                door.db.execute(
                    "UPDATE door_example_stats SET best_guesses = ? WHERE user_id = ?",
                    {guesses, uid}
                )
                door.writeln("New personal best: " .. guesses .. " guess(es)!")
            end
            return
        elseif n < secret then
            door.writeln("Too low!")
        else
            door.writeln("Too high!")
        end
    end

    door.writeln("The number was " .. secret .. ". Better luck next time!")
end

local function main_loop()
    local running = true
    while running do
        door.writeln("[G]uessing game  [S]tats  [Q]uit")
        local key = door.read_key()
        if key == nil then break end
        key = key:upper()

        if key == "G" then
            door.writeln("")
            guessing_game()
            door.writeln("")
        elseif key == "S" then
            door.writeln("")
            show_stats()
        elseif key == "Q" then
            running = false
        end
    end
end

-- Entry point
show_banner()
show_stats()
main_loop()

door.writeln("")
door.writeln("Thanks for playing! Returning to BBS...")
door.sleep(1000)
door.exit()
