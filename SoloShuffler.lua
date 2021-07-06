--[[
Project: BizHawk-Shuffler

Original Autor: brossentia
Original repo: https://github.com/brossentia/BizHawk-Shuffler

Modified by: EatonCiaran
Fork: https://github.com/EatonCiaran/BizHawk-Shuffler

ACKNOWLEDGEMENTS

Inspirations taken from the pull requests created by Tempystral
and alexjpaz:
- https://github.com/brossentia/BizHawk-Shuffler/pull/6
- https://github.com/brossentia/BizHawk-Shuffler/pull/13

CHANGES:

- Rewrite: minimize globals, no pointless function parameters,
naming convention, comments, more functions
- Move away from bulky xml settings format to something more slimline.
- Restructure how stats are stored so it's easier to manually delete for
a restart.
- More stats: Frames, swaps, time played on total and per ROM basis.
- Savestates written to Lua folder instead of emulator. Means easier to wipe,
resume a session, and ROM Hacks won't overwrite the original ROM's save
- Skips .bin files since BizHawk fails to detect which emuator to use.
Recommend to give affected ROMs more appropriate file extension.
- Seed Mode: Can select to use predetermined seed or "random".

TODO:

- Change from swapFrame to swapTime since emulator doesnt run at fixed 60fps
like is assumed.
- Replace the .exe with Lua form.
- Work on making the code more portable, currently Windows locked.
]]


--------------------------------------
--          Globals & Defaults      --
--------------------------------------

-- Windows notation paths for where to find/store:
pathROMs = ".\\CurrentROMs\\"                       -- ROMs being played
pathSaves = ".\\Savestates\\"                       -- Savestate location
pathStats = ".\\Stats\\"                            -- Statistics directory:
pathRomStats = pathStats .. "Rom\\"                 -- 	- Per Rom stats
pathSessionStats = pathStats .. "SessionStats.txt"  -- 	- Session stats
pathSettings = "settings.txt"                       -- Settings that override defaults

-- Default settings
settings = {}
settings["minTime"] = 5             -- Min shuffle time in seconds
settings["maxTime"] = 5             -- Max shuffle time in seconds
settings["showCountdown"] = false   -- Show countdown timer
settings["seed"] = 0                -- Random seed
settings["seedMode"] = 0            -- Mode of generator. 0 dont use give seed. 1 use seed
settings["fps"] = 60                -- Frames per second, used to convert frame to time
settings["pauseDelay"] = 500        -- Delay in ms to pause on swap. -1 for no delay
settings["log_level"] = 0           -- Control what level of log messages to see in console

-- Session data
if not userdata.get("sessionType") then
    userdata.set("sessionType", 1)          -- Flag for type of session: Fresh, Resume/Swap
    userdata.set("currentRomName", "")      -- Current ROM's name
    userdata.set("currentRomFilename", "")  -- Current ROM's filename
    userdata.set("currentConsole", "")      -- Current Console
    userdata.set("swapFrame", 0)            -- Frame to swap ROM on
    userdata.set("totalPlayCount", 0)       -- Total number of ROMs been played / swapped to
    userdata.set("totalSwapCount", 0)       -- Total number of swaps
    userdata.set("totalFrameCount", 0)      -- Total frame count across swaps
    userdata.set("totalPlayTime", 0)
    userdata.set("frameCount", 0)           -- Frame count
    userdata.set("playTime", 0)
    userdata.set("swapCount", 0)
    userdata.set("playCount", 0)
end

currentRoms = {}            -- List of active ROMs
timeStarted = os.time()     -- Current time in seconds


--------------------------------------
--          Basic Utilities         --
--------------------------------------

-- Wrapper for console that adds timestamp and debug level toggablity
function message(msg, level)
    -- set up default parameters
    local level = level or 4
    
    if settings["log_level"] <= level then
        local timestamp = os.date("%X")
        console.writeline(timestamp .. ": " .. tostring(msg))
    end
end
message("Script starting...", 1)

-- Check if a file or directory exists in this path
function exists(file)
    local ok, err, code = os.rename(file, file)
    if not ok then
        if code == 13 then
            -- Permission denied, but it exists
            return true
        end
    end
    return ok, err
end

-- Check if a directory exists in this path
function is_dir(path)
    -- "/" works on both Unix and Windows
    -- TODO: Check if works if already ends with directory seperator
    return exists(path .. "/")
end

-- Create directory at path. NOT very OS portable
function create_dir(path)
    -- DANGEROUS: Potential to execute shell code with specially crafted name
    -- TODO: Detect semicolon in name to help guard against escaping
    os.execute("mkdir " .. path)
    message("Directory created: " .. path, 2)
end


function ends_with(str, pat)
    return bizstring.endswith(str, pat)
end


-- Basic OS detectioned based on path seperators
function get_os()
    local path_notation = package.config:sub(1, 1)
    if path_notation == "/" then
        return "Unix"
    elseif path_notation == "\\" then
        return "Window"
    end
    
    message("Failed to detect OS.", 2)
    return "UNKNOWN"
end



--------------------------------------
--          Data Handling           --
--------------------------------------
--[[
Returns the data contained in file at PATH.
File contents expected to be lines in the format: KEY: VALUE
Data returned as set in the format: table[KEY] = VALUE
--]]
function load_data(path)
    -- Check file exists
    if not exists(path) then
        message("Missing path: " .. path, 3)
        return
    end
    
    local data = {}-- The data being loaded
    local fh = io.open(path, "a+")-- Open file
    
    -- for each line in the file
    for line in fh:lines() do
        -- extract key and value assuming format "NAME: VALUE"
        local key, value = string.match(line, '(%w+): (.+)')
        
        -- if something was extracted i.e. Line wasn't blank
        if key and value then
            -- assume appropriate conversion for VALUE based on data it contains
            if value == "true" or value == "false" then -- Boolean
                value = value == "true"
            elseif tonumber(value) then -- Number
                value = tonumber(value)
            end -- else leave as String
            
            -- assign to the set
            data[key] = value
        end
    end
    
    fh:close()-- Close file
    return data
end


--[[
Saves DATA to file at PATH.
Data expected to be a table in the format: table[KEY] = VALUE
File will have the DATA with each table entry written in the format: KEY: VALUE
Any existing file will be overwritten.
--]]
function save_data(path, data)
    local fh = io.open(path, "w")-- Open file
    
    -- for each entry get key, value pair
    for key, value in pairs(data) do
        -- format into KEY: VALUE
        line = tostring(key) .. ": " .. tostring(value) .. "\n"
        fh:write(line)
    end
    fh:close()-- Close file
end


-- Load the stats file for a ROM
function load_rom_stats(romFilename)
    -- Check stats paths exist, create them if not
    if not exists(pathStats) then
        message("Missing path, creating it: " .. pathStats, 3)
        create_dir(pathStats)
    end
    if not exists(pathRomStats) then
        message("Missing path, creating it: " .. pathRomStats, 3)
        create_dir(pathRomStats)
    end
    
    local path = pathRomStats .. romFilename .. ".txt" -- Construct path to ROM's stats file
    local data = load_data(path)-- Load data
    
    -- if no data loaded then assign defaults
    if not data then
        data = {}
        data["swapCount"] = 0
        data["frameCount"] = 0
        data["playTime"] = 0
        data["playCount"] = 1
    end
    
    -- for each entry in loaded userdata
    for key, value in pairs(data) do
        -- check if KEY is valid by seeing it exists as a default in SETTINGS
        if userdata.get(key) ~= nil then
            userdata.set(key, value)
        end
    end
end


-- update and save total swap count
function update_stats()
    -- Check stats paths exist, create them if not
    if not exists(pathStats) then
        message("Missing path, creating it: " .. pathStats, 3)
        create_dir(pathStats)
    end
    
    local path = pathSessionStats
    
    -- update data
    local data = {}
    data["totalSwapCount"] = userdata.get("totalSwapCount") + 1
    data["totalPlayCount"] = userdata.get("totalPlayCount") + 1
    data["totalFrameCount"] = userdata.get("totalFrameCount") + emu.framecount()
    
    local elapsedTime = os.time() - timeStarted
    data["totalPlayTime"] = userdata.get("totalPlayTime") + elapsedTime
    
    data["currentRomName"] = userdata.get("currentRomName")
    data["currentRomFilename"] = userdata.get("currentRomFilename")
    data["currentConsole"] = userdata.get("currentConsole")
    
    -- save data
    save_data(path, data)
end

-- update and save the swap count for a ROM
function update_rom_stats(romFilename)
    message("Updating ROM stats for: " .. romFilename, 1)
    
    -- Check stats paths exist, create them if not
    if not exists(pathStats) then
        message("Missing path, creating it: " .. pathStats, 3)
        create_dir(pathStats)
    end
    if not exists(pathRomStats) then
        message("Missing path, creating it: " .. pathRomStats, 3)
        create_dir(pathRomStats)
    end
    
    local path = pathRomStats .. romFilename .. ".txt"
    
    -- update data
    local data = {}
    data["swapCount"] = userdata.get("swapCount") + 1
    data["playCount"] = userdata.get("playCount") + 1
    data["frameCount"] = userdata.get("frameCount") + emu.framecount()
    
    local elapsedTime = os.time() - timeStarted
    data["playTime"] = userdata.get("playTime") + elapsedTime
    
    data["romName"] = userdata.get("currentRomName")
    data["console"] = userdata.get("currentConsole")
    
    -- save data
    save_data(path, data)
    message("Updated ROM stats for: " .. romFilename, 1)
end


-- Load ROM list
function load_rom_list()
    local ROMs = {}-- list of ROMs
    
    -- Check ROM path exists
    if not exists(pathROMs) then
        message("Missing path, creating it: " .. pathRoms, 3)
        create_dir(pathRomStats)
    end
    
    -- DANGEROUS: Potential to execute shell code with specially crafted path name
    -- Windows specific method of listing directories in a path
    local fh = io.popen("dir " .. pathROMs .. " /b")
    
    -- Iterate over list of files in ROM path
    for filename in fh:lines() do
        -- Skip .bin files since BizHawk can't autodetect what emulator to use.
        -- This will mainly affect Genesis ROMs. User should rename those ROMs to
        -- use more appropriate extension e.g. .gen or .md
        if ends_with(filename, ".bin") then
            message("Skipping ROM as it's a .bin, consider renaming: " .. filename, 4)
        else
            message("Found: " .. filename, 1)
            table.insert(ROMs, filename)
        end
    end
    
    currentRoms = ROMs
    message("Found " .. table.maxn(ROMs) .. " ROMs.", 4)
end


-- Loads saved session data into SESSION
function load_session()
    -- Check stats paths exist, create them if not
    if not exists(pathStats) then
        message("Missing path, creating it: " .. pathStats, 3)
        create_dir(pathStats)
    end
    
    -- Try to load
    local data = load_data(pathSessionStats)
    
    if not data then
        -- The default session will be used
        message("No session data found. Fresh start.", 4)
        return
    end
    
    -- for each entry in loaded userdata
    for key, value in pairs(data) do
        -- check if KEY is valid by seeing it exists as a default in SETTINGS
        if userdata.get(key) ~= nil then
            userdata.set(key, value)
        end
    end
    
    message("Finished session load", 1)
end


-- Load settings to override the defaults in SETTINGS
function load_settings()
    -- Warn user of possibly using the old format
    if ends_with(pathSettings, ".xml") then
        message("Settings file has .xml extension. That is not the expected format. Continuing anyway", 4)
    end
    
    -- Try to load
    local data = load_data(pathSettings)
    if not data then
        message("Settings file failed to load. Using defaults.", 4)
        return
    end
    
    -- for each entry in loaded DATA
    for key, value in pairs(data) do
        -- check if KEY is valid by seeing it exists as a default in SETTINGS
        if settings[key] ~= nil then
            settings[key] = value
        end
    end
    
    message("Finished settings file load.", 3)
end

-- create a savestate for romFilename
function save_state(romFilename)
    -- Check stats paths exist, create them if not
    if not exists(pathSaves) then
        message("Missing path, creating it: " .. pathSaves, 3)
        create_dir(pathSaves)
    end
    
    -- create savestate of current ROM
    local path = pathSaves .. userdata.get("currentRomFilename") .. ".save"
    savestate.save(path)
    message("Savestate created: " .. path, 1)
end

-- Load a ROM based on its index in currentRoms
-- Updates session data but not stat data.
function load_rom(romIndex)
    message("Loading ROM with index: " .. romIndex, 1)
    
    -- create savestate of current ROM
    save_state(userdata.get("currentRomFilename"))
    
    -- update session data
    userdata.set("currentRomFilename", currentRoms[romIndex])
    
    -- open new ROM
    path = pathROMs .. userdata.get("currentRomFilename")
    client.openrom(path)
    
    -- load new ROM's save state, fails silently if one doesn't exist
    path = pathSaves .. userdata.get("currentRomFilename") .. ".save"
    savestate.load(path)
    
    -- get new ROM's info
    userdata.set("currentRomName", gameinfo.getromname())
    userdata.set("currentConsole", emu.getsystemid())
    
    -- load new ROM's stats
    load_rom_stats(userdata.get("currentRomFilename"))
    
    message("Loaded ROM: " .. userdata.get("currentRomName"), 3)
end

-- Returns a ROM index into the ROM list
function pick_random_rom()
    load_rom_list()
    local romCount = table.maxn(currentRoms)
    
    -- check edge cases
    if romCount == 0 then
        message("No ROMs available. Exiting", 4)
        client.exitCode()
    elseif romCount == 1 then
        message("Pick: 1 ROM available. Nothing to swap", 2)
        return
    end
    
    -- Select ROM by picking a random index into the ROM list
    local index = math.random(1, romCount)
    
    -- Reroll until ROM isn't the current one
    -- compare filenames instead of indexes incase ROM list changed
    while currentRoms[index] == userdata.get("currentRomName") do
        index = math.random(1, romCount)
    end
    
    return index
end

-- Changes to the next game and saves the current settings into userdata
function swap_rom()
    message("Swapping ROM...", 3)
    
    local romIndex = pick_random_rom()
    if not romIndex then
        return
    end
    
    local filename = userdata.get("currentRomFilename")
    
    update_rom_stats(filename)-- update current ROM's stats to reflect about to swap
    load_rom(romIndex)-- load newly select ROM
    update_stats()-- update main stats
    
    message("Swapping complete.", 3)
end


-- Draw the countdown box
function draw_countdown_alert()
    if not userdata.get("showCountdown") then
        -- Not enabled so do nothing
        return
    end
    
    -- Only render if 3 seconds or less remaining til swap
    local showThreshold = userdata.get("fps") * 3 -- 3 seconds
    if userdata.get("frameCount") >= userdata.get("swapFrame") - showThreshold then
        -- Adding 8 makes it appear correct for the NES.
        local buffer = 0
        if emu.getsystemid() == "NES" then
            buffer = 8
        end
        
        -- Draw box
        local x1 = client.bufferwidth() / 2 - 60
        local y1 = buffer
        local x2 = client.bufferwidth() - (client.bufferwidth() / 2 + 1 - 60)
        local y2 = 15 + buffer
        gui.drawBox(x1, y1, x2, y2, "white", "black")
        
        -- Draw text
        local x = client.bufferwidth() / 2
        local y = buffer
        local msg = "!....THREE....!"
        local col = "lime"
        
        local threshold1 = userdata.get("fps") * 1  -- 1 second remaining
        local threshold2 = userdata.get("fps") * 2  -- 2 seconds remaining
        
        if (userdata.get("frameCount") >= timeLimit - threshold1) then
            msg = "!.!.!.ONE.!.!.!"
            col = "red"
        elseif (userdata.get("frameCount") >= timeLimit - threshold2) then
            msg = "!.!...TWO...!.!"
            col = "yellow"
        end
        
        gui.drawText(x, y, msg, col, null, null, null, "center")
    end
end

-- Pause after a swap
function delay()
    if settings["pauseDelay"] >= 0 and userdata.get("sessionType") > 1 then
        sound = client.GetSoundOn()
        client.SetSoundOn(false)
        client.sleep(settings["pauseDelay"])
        client.SetSoundOn(sound)
    end
end

-- Set the seed for random based on seedMode.
function set_randomness()
    --[[
    Look at seedMode.
    - == 0: Use current time
    - > 0: Use a known seed, meaning a seed needs to be propagated to next session
    If new session seed is the initial seed from settings
    If a swap load from seed from session i.e. seed was propagated
    Make a new seed and save to seesion
    ]]
    message("Setting seed.", 1)
    
    -- default seed mode: Not a known seed so use time
    local seed = os.time()
    
    -- if known seed mode
    if settings["seedMode"] ~= 0 then
        -- if not a swap session
        if userdata.get("sessionType") <= 1 then
            -- set initial seed from settings
            seed = settings["seed"]
        else
            -- load fom session
            seed = userdata.get("seed")
        end
    end
    
    message("Current seed: " .. seed, 3)
    math.randomseed(seed)       -- apply the seed
    
    -- create a deterministic seed that can be propogated to the next session.
    seed = math.floor(math.random() * 1000000)
    userdata.set("seed", seed)
    message("Next seed: " .. userdata.get("seed"), 2)
end

--[[
Randomly generate frame number to swap on.
If minTime and maxTime are the same then maxTime will be the fixed time.
]]
function set_swapFrame()
    -- convert times to frames
    -- TODO: check the FPS is correct for this conversion
    local min = settings["minTime"] * settings["fps"]
    local max = settings["maxTime"] * settings["fps"]
    
    -- if min and max are different
    if min ~= max then
        -- pick random frame to swap on within those limits
        userdata.set("swapFrame", math.random(min, max))
    else
        -- else frame to swap on is MAXTIME
        userdata.set("swapFrame", max)
    end
    
    message("Swap frame set to: " .. userdata.get("swapFrame"), 2)
end


--------------------------------------
--          Initialisation          --
--------------------------------------

-- load data
load_settings()
load_session()
message("Loaded data", 1)

-- set up
set_randomness()    -- set seed up
set_swapFrame()     -- determine frame to swap on
message("Set up", 1)

-- misc
delay()             -- add a pause delay
message("Script initilised", 1)

-- if no ROM loaded then pick a random one
if gameinfo.getromname() == "Null" then
    message("No ROM loaded so loading one.")
    
    local index = pick_random_rom()
    load_rom(index)
end


--------------------------------------
--             Main loop            --
--------------------------------------

while true do
    -- debug message
    if emu.framecount() % 100 == 0 then
        message("On frame " .. emu.framecount(), 1)
    end
    
    -- draw alert box
    draw_countdown_alert()
    
    -- check if time to swap
    if emu.framecount() >= userdata.get("swapFrame") then
        swap_rom()
    end
    
    -- advance the frame one step, if a ROM was loaded the script we be reloaded.
    emu.frameadvance()
end
