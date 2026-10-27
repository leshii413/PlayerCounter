-- BeamMP PlayerCounter + Retention Analytics
-- by Leshii413, with YouTube, Reddit & AI assistance.
-- Version 2.1.0
-- License: GPL-3.0 (see LICENSE)
--
-- Tracks, per BeamMP account ID:
--   * Daily / monthly / yearly / all-time unique players and join sessions
--   * New vs returning players
--   * Month-over-month retention
--   * Playtime per player (AFK time excluded)
--   * Peak and average players online, weekday-hour heatmap, 24 h graph
--   * A live snapshot of who is online (data/live.json) for dashboards and
--     the Discord status script (discord_status.py)
--
-- Install: Resources/Server/PlayerCounter/main.lua
-- Data:    Resources/Server/PlayerCounter/data/   (created automatically)
--
-- SETTINGS
-- Settings are stored in data/config.json, which is created on first start
-- from the defaults below. Edit data/config.json (then restart the server)
-- so your settings survive future main.lua updates.

local PLUGIN_VERSION = "2.1.0"

local DATA_DIR = "Resources/Server/PlayerCounter/data"
local STATE_FILE = DATA_DIR .. "/stats.json"
local JOIN_LOG = DATA_DIR .. "/joins.csv"
local LIVE_FILE = DATA_DIR .. "/live.json"
local CONFIG_FILE = DATA_DIR .. "/config.json"
-- Optional: stats website upload settings (see web/README.md). The file is
-- separate from config.json so a ready-made copy can ship with the plugin.
local WEBSITE_FILE = DATA_DIR .. "/website.json"
local WEBSITE_BODY = DATA_DIR .. "/website_upload.json"
local WEBSITE_REPLY = DATA_DIR .. "/website_reply.txt"
local WEBSITE_CODE = DATA_DIR .. "/website_status.txt"

local DEFAULT_CONFIG = {
    -- Calendar used for day / month / year rollover and the heatmap.
    -- utc_offset_hours is the STANDARD (winter) offset: 0 = UTC, 8 = UTC+8
    -- (PH/SG), -7 = US Mountain (St George, Utah), -5 = US Eastern.
    -- Fractions work (5.5 = India). dst adds one hour in summer:
    -- "us" (second Sunday of March to first Sunday of November),
    -- "eu" (last Sunday of March to last Sunday of October) or "none".
    -- Avoid changing these after collecting data: they shift period boundaries.
    utc_offset_hours = 0,
    dst = "none",
    -- Optional name for the calendar, shown on the website (e.g. "St George, Utah time").
    time_zone_name = "",

    -- Guests have no permanent BeamMP ID. false = guests count as join
    -- sessions but not as unique players (recommended).
    count_guests_as_unique = false,

    -- Who may use /playerstats, /retention and /playtime in chat:
    -- "everyone", "admins" (BeamMP IDs listed below) or "off".
    player_commands = "everyone",
    admin_beammp_ids = {},

    -- Write data/live.json (online players, playtime, vehicles) this often.
    live_snapshot = true,
    live_interval_seconds = 30,

    -- AFK: a player whose vehicles have not moved afk_move_meters in
    -- afk_after_seconds stops earning playtime until they move again.
    -- Players with no vehicle spawned (spectating, menus) are not marked AFK.
    afk_detection = true,
    afk_after_seconds = 300,
    afk_move_meters = 5,

    -- Players listed in each playtime leaderboard in live.json (all-time and
    -- this month), used by the stats website. 0 = no leaderboards.
    leaderboard_size = 25
}

local HEAT_SLOTS = 168         -- 7 weekdays x 24 hours
local ONLINE_BUCKET = 300      -- 24 h player graph: one value per 5 minutes
local ONLINE_BUCKETS = 288
local ACTIVE_VEHICLE_EVENT = "PlayerCounter_activeVehicle"

local config = {}

local function blankPeriod()
    return {
        key = "",
        users = {},
        new_users = {},
        returning_users = {},
        retained_users = {}, -- monthly only; harmless on daily/yearly
        previous_key = "",   -- monthly only
        joins = 0,
        guest_joins = 0,
        -- Concurrency (2.1): players online, sampled every tick.
        peak_online = 0,
        peak_at = "",
        online_seconds = 0,  -- sum of players online x seconds
        sampled_seconds = 0, -- seconds the plugin was running in this period
        heat_online = nil,   -- monthly only: 168 weekday-hour slots
        heat_sampled = nil
    }
end

local function blankState()
    return {
        schema_version = 2,
        plugin_version = PLUGIN_VERSION,
        daily = blankPeriod(),
        monthly = blankPeriod(),
        yearly = blankPeriod(),

        -- ["beammp:123456"] = {
        --     first_seen = "2026-08-10T05:00:00Z", last_seen = "...",
        --     first_name = "Player", last_name = "Player",
        --     joins = 1, playtime_seconds = 0, legacy = false
        -- }
        players = {},
        total_joins = 0,

        history = { daily = {}, monthly = {}, yearly = {} },
        migration = { upgraded_from_v1 = false, upgraded_at = "" },

        -- Settings that change how stored data is interpreted.
        recorded_settings = {},

        -- 2.1: unix times of joins in the last 24 h, and the 24 h player graph
        -- (max players online per 5-minute bucket, -1 = server not running).
        recent_joins = {},
        online_24h = { last_bucket = 0, values = {} }
    }
end

local state = blankState()

-- Live (not persisted) runtime state.
local ready = false          -- false until onInit loaded data successfully
local dirty = false          -- state changed since last save
local lastSaveTime = 0
local sessions = {}          -- [pid] = { uid, name, guest, beammp, joined, credited,
                             --           afk, idle, last_pos, active }
local lastSample = nil       -- unix time of the last concurrency sample
local lastTick = nil         -- unix time of the last timer tick (AFK checks)
local vehicleInfo            -- defined in the live snapshot section
local vehicleCache = {}      -- [pid] = { [vid] = { raw = string, info = table } }

local PLAYTIME_SAVE_INTERVAL = 120 -- seconds between saves caused only by playtime

--------------------------------------------------
-- Utility
--------------------------------------------------

local function log(message)
    print("[PlayerCounter] " .. tostring(message))
end

local function countKeys(tbl)
    if type(tbl) ~= "table" then
        return 0
    end
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

local function int(value)
    return math.floor(tonumber(value) or 0)
end

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function copySet(tbl)
    local out = {}
    if type(tbl) ~= "table" then
        return out
    end
    for key, value in pairs(tbl) do
        if value then
            out[key] = true
        end
    end
    return out
end

local function now()
    return os.time()
end

-- Days since 1970-01-01 for a calendar date (proleptic Gregorian).
local function daysFromCivil(y, m, d)
    if m <= 2 then
        y = y - 1
    end
    local era = (y >= 0 and y or y - 399) // 400
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = (153 * mp + 2) // 5 + d - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468
end

-- Day of month of the n-th (or last, n = -1) Sunday of a month.
local function nthSunday(y, m, n)
    if n > 0 then
        local wday = (daysFromCivil(y, m, 1) + 4) % 7 -- 0 = Sunday
        return 1 + (7 - wday) % 7 + (n - 1) * 7
    end
    local lastDay = daysFromCivil(m == 12 and y + 1 or y, m == 12 and 1 or m + 1, 1) - daysFromCivil(y, m, 1)
    local wday = (daysFromCivil(y, m, lastDay) + 4) % 7
    return lastDay - wday
end

-- True while daylight saving time is in effect at unix time t.
local function dstActive(t)
    local rule = config.dst
    if rule ~= "us" and rule ~= "eu" then
        return false
    end
    local year = tonumber(os.date("!%Y", t))
    local start, finish
    if rule == "us" then
        -- 02:00 local standard time / 02:00 local daylight time
        local std = (config.utc_offset_hours or 0) * 3600
        start = daysFromCivil(year, 3, nthSunday(year, 3, 2)) * 86400 + 7200 - std
        finish = daysFromCivil(year, 11, nthSunday(year, 11, 1)) * 86400 + 7200 - (std + 3600)
    else
        -- 01:00 UTC on both changes
        start = daysFromCivil(year, 3, nthSunday(year, 3, -1)) * 86400 + 3600
        finish = daysFromCivil(year, 10, nthSunday(year, 10, -1)) * 86400 + 3600
    end
    return t >= start and t < finish
end

-- The calendar's offset from UTC right now, in hours (DST included).
local function currentOffsetHours(t)
    return (config.utc_offset_hours or 0) + (dstActive(t or now()) and 1 or 0)
end

local function shiftedTime()
    local t = now()
    return math.floor(t + currentOffsetHours(t) * 3600)
end

local function calendarLabel()
    local offset = currentOffsetHours()
    local text = "UTC" .. (offset >= 0 and "+" or "") .. tostring(offset)
    if config.time_zone_name and config.time_zone_name ~= "" then
        text = config.time_zone_name .. ", " .. text
    end
    return text
end

local function periodKeys()
    local t = shiftedTime()
    return {
        day = os.date("!%Y-%m-%d", t),
        month = os.date("!%Y-%m", t),
        year = os.date("!%Y", t)
    }
end

local function utcTimestamp(t)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", t or now())
end

local function previousMonthKey(monthKey)
    local yearText, monthText = tostring(monthKey):match("^(%d%d%d%d)%-(%d%d)$")
    if not yearText then
        return ""
    end
    local year, month = tonumber(yearText), tonumber(monthText) - 1
    if month == 0 then
        month = 12
        year = year - 1
    end
    return string.format("%04d-%02d", year, month)
end

local function csvCell(value)
    value = tostring(value == nil and "" or value)
    if value:find('[,"\n\r]') then
        value = '"' .. value:gsub('"', '""') .. '"'
    end
    return value
end

-- Player names are chosen by players. A name such as =HYPERLINK(...) would be
-- run as a formula when joins.csv is opened in Excel/Sheets, so prefix those.
local function csvTextCell(value)
    value = tostring(value == nil and "" or value)
    if value:find("^[=+%-@\t\r]") then
        value = "'" .. value
    end
    return csvCell(value)
end

local function percent(numerator, denominator)
    if not denominator or denominator <= 0 then
        return nil
    end
    return (numerator / denominator) * 100
end

local function formatPercent(value)
    if value == nil then
        return "N/A"
    end
    return string.format("%.1f%%", value)
end

local function formatDuration(seconds)
    seconds = math.max(0, int(seconds))
    local days = seconds // 86400
    local hours = (seconds % 86400) // 3600
    local minutes = (seconds % 3600) // 60
    if days > 0 then
        return string.format("%dd %dh", days, hours)
    elseif hours > 0 then
        return string.format("%dh %02dm", hours, minutes)
    end
    return string.format("%dm", minutes)
end

--------------------------------------------------
-- SHA-256 / HMAC-SHA256 (pure Lua 5.3) for signing website uploads
--------------------------------------------------

local SHA_K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

local function sha256(message)
    local M = 0xffffffff
    local function rotr(x, n)
        return ((x >> n) | (x << (32 - n))) & M
    end
    local bitLength = #message * 8
    message = message .. "\128" .. string.rep("\0", (55 - #message) % 64) .. string.pack(">I8", bitLength)
    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    local w = {}
    for chunk = 1, #message, 64 do
        for i = 1, 16 do
            w[i] = string.unpack(">I4", message, chunk + (i - 1) * 4)
        end
        for i = 17, 64 do
            local a, b = w[i - 15], w[i - 2]
            local s0 = rotr(a, 7) ~ rotr(a, 18) ~ (a >> 3)
            local s1 = rotr(b, 17) ~ rotr(b, 19) ~ (b >> 10)
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & M
        end
        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
        for i = 1, 64 do
            local S1 = rotr(e, 6) ~ rotr(e, 11) ~ rotr(e, 25)
            local ch = (e & f) ~ ((~e) & g)
            local t1 = (h + S1 + ch + SHA_K[i] + w[i]) & M
            local S0 = rotr(a, 2) ~ rotr(a, 13) ~ rotr(a, 22)
            local maj = (a & b) ~ (a & c) ~ (b & c)
            local t2 = (S0 + maj) & M
            h, g, f, e, d, c, b, a = g, f, e, (d + t1) & M, c, b, a, (t1 + t2) & M
        end
        h0, h1, h2, h3 = (h0 + a) & M, (h1 + b) & M, (h2 + c) & M, (h3 + d) & M
        h4, h5, h6, h7 = (h4 + e) & M, (h5 + f) & M, (h6 + g) & M, (h7 + h) & M
    end
    return string.pack(">I4I4I4I4I4I4I4I4", h0, h1, h2, h3, h4, h5, h6, h7)
end

local function toHex(bytes)
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function hmacSha256Hex(key, message)
    if #key > 64 then
        key = sha256(key)
    end
    key = key .. string.rep("\0", 64 - #key)
    local inner = key:gsub(".", function(c) return string.char(c:byte() ~ 0x36) end)
    local outer = key:gsub(".", function(c) return string.char(c:byte() ~ 0x5c) end)
    return toHex(sha256(outer .. sha256(inner .. message)))
end

--------------------------------------------------
-- Files
--------------------------------------------------

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local contents = file:read("a")
    file:close()
    return contents
end

-- Write to path.tmp, keep the previous file as path.bak, then move the new
-- file into place. A crash mid-write can no longer leave a half-written
-- stats.json behind.
local function writeFileAtomic(path, contents, keepBackup)
    local tmp = path .. ".tmp"
    local file, openErr = io.open(tmp, "wb")
    if not file then
        return false, openErr
    end
    local wrote, writeErr = file:write(contents)
    local closed = file:close()
    if not wrote or not closed then
        FS.Remove(tmp)
        return false, writeErr or "could not finish writing"
    end

    if FS.Exists(path) then
        if keepBackup then
            FS.Remove(path .. ".bak")
            FS.Rename(path, path .. ".bak")
        else
            FS.Remove(path) -- Windows cannot rename over an existing file
        end
    end

    local renamed, renameErr = FS.Rename(tmp, path)
    if not renamed then
        if keepBackup and not FS.Exists(path) and FS.Exists(path .. ".bak") then
            FS.Copy(path .. ".bak", path)
        end
        return false, renameErr
    end
    return true
end

local function decodeJsonFile(path)
    if not FS.Exists(path) then
        return nil, "missing"
    end
    local contents = readFile(path)
    if not contents then
        return nil, "unreadable"
    end
    if contents:match("^%s*$") then
        return nil, "empty"
    end
    local ok, decoded = pcall(Util.JsonDecode, contents)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return nil, "invalid JSON"
end

--------------------------------------------------
-- Config
--------------------------------------------------

local function applyConfig(loaded)
    config = {}
    for key, value in pairs(DEFAULT_CONFIG) do
        config[key] = value
    end
    if type(loaded) == "table" then
        for key, value in pairs(loaded) do
            if DEFAULT_CONFIG[key] ~= nil then
                config[key] = value
            end
        end
        -- Old setting name from earlier versions.
        if loaded.allow_player_commands == false and loaded.player_commands == nil then
            config.player_commands = "off"
        end
    end

    config.utc_offset_hours = tonumber(config.utc_offset_hours) or 0
    if config.utc_offset_hours < -12 or config.utc_offset_hours > 14 then
        log("WARNING: utc_offset_hours " .. config.utc_offset_hours .. " is out of range; using 0.")
        config.utc_offset_hours = 0
    end
    config.dst = tostring(config.dst or "none"):lower()
    if config.dst ~= "us" and config.dst ~= "eu" and config.dst ~= "none" then
        log("WARNING: dst must be us, eu or none; using none.")
        config.dst = "none"
    end
    config.time_zone_name = tostring(config.time_zone_name or ""):sub(1, 60)
    config.count_guests_as_unique = config.count_guests_as_unique == true
    config.player_commands = tostring(config.player_commands):lower()
    if config.player_commands ~= "everyone" and config.player_commands ~= "admins"
        and config.player_commands ~= "off" then
        log("WARNING: player_commands must be everyone, admins or off; using everyone.")
        config.player_commands = "everyone"
    end
    local admins = {}
    if type(config.admin_beammp_ids) == "table" then
        for _, id in pairs(config.admin_beammp_ids) do
            admins[tostring(id)] = true
        end
    end
    config.admin_set = admins
    config.live_snapshot = config.live_snapshot ~= false
    config.live_interval_seconds = math.max(5, int(config.live_interval_seconds))
    config.afk_detection = config.afk_detection ~= false
    config.afk_after_seconds = math.max(60, int(config.afk_after_seconds))
    config.afk_move_meters = math.max(0.5, tonumber(config.afk_move_meters) or 5)
    config.leaderboard_size = math.max(0, math.min(100, int(config.leaderboard_size)))
end

local function loadConfig()
    local loaded, err = decodeJsonFile(CONFIG_FILE)
    if loaded then
        applyConfig(loaded)
        return false
    end

    applyConfig(nil)
    if err ~= "missing" then
        log("WARNING: data/config.json is " .. err .. "; using defaults until it is fixed.")
        return false
    end

    -- Written by hand so the order is stable and the admin list is a JSON array.
    local order = { "utc_offset_hours", "dst", "time_zone_name", "count_guests_as_unique", "player_commands",
        "admin_beammp_ids", "live_snapshot", "live_interval_seconds",
        "afk_detection", "afk_after_seconds", "afk_move_meters", "leaderboard_size" }
    local lines = {}
    for _, key in ipairs(order) do
        local value = DEFAULT_CONFIG[key]
        local text
        if type(value) == "table" then
            local items = {}
            for _, item in ipairs(value) do
                items[#items + 1] = string.format("%q", tostring(item))
            end
            text = "[" .. table.concat(items, ", ") .. "]"
        elseif type(value) == "string" then
            text = string.format("%q", value)
        else
            text = tostring(value)
        end
        lines[#lines + 1] = string.format('    "%s": %s', key, text)
    end
    local ok = writeFileAtomic(CONFIG_FILE, "{\n" .. table.concat(lines, ",\n") .. "\n}\n", false)
    if ok then
        log("Created data/config.json with default settings.")
    end
    return true
end

--------------------------------------------------
-- State normalization / migration
--------------------------------------------------

local function normalizePeriod(period)
    period = type(period) == "table" and period or {}
    period.key = type(period.key) == "string" and period.key or ""
    period.users = type(period.users) == "table" and period.users or {}
    period.new_users = type(period.new_users) == "table" and period.new_users or {}
    period.returning_users = type(period.returning_users) == "table" and period.returning_users or {}
    period.retained_users = type(period.retained_users) == "table" and period.retained_users or {}
    period.previous_key = type(period.previous_key) == "string" and period.previous_key or ""
    period.joins = int(period.joins)
    period.guest_joins = int(period.guest_joins)
    period.peak_online = int(period.peak_online)
    period.peak_at = type(period.peak_at) == "string" and period.peak_at or ""
    period.online_seconds = tonumber(period.online_seconds) or 0
    period.sampled_seconds = tonumber(period.sampled_seconds) or 0
    return period
end

-- A JSON array may come back as a table with string or missing keys; rebuild
-- a dense numeric array of the given length.
local function denseArray(value, length, fill)
    local out = {}
    local source = type(value) == "table" and value or {}
    for i = 1, length do
        out[i] = tonumber(source[i]) or tonumber(source[tostring(i)]) or fill
    end
    return out
end

local function normalizeHeat(period)
    period.heat_online = denseArray(period.heat_online, HEAT_SLOTS, 0)
    period.heat_sampled = denseArray(period.heat_sampled, HEAT_SLOTS, 0)
end

local function normalizeState()
    state.daily = normalizePeriod(state.daily)
    state.monthly = normalizePeriod(state.monthly)
    state.yearly = normalizePeriod(state.yearly)

    state.players = type(state.players) == "table" and state.players or {}
    state.total_joins = int(state.total_joins)

    state.history = type(state.history) == "table" and state.history or {}
    for _, scope in ipairs({ "daily", "monthly", "yearly" }) do
        state.history[scope] = type(state.history[scope]) == "table" and state.history[scope] or {}
    end

    state.migration = type(state.migration) == "table" and state.migration or {}
    state.migration.upgraded_from_v1 = state.migration.upgraded_from_v1 == true
    state.migration.upgraded_at = state.migration.upgraded_at or ""

    state.recorded_settings = type(state.recorded_settings) == "table" and state.recorded_settings or {}
    state.plugin_version = PLUGIN_VERSION

    normalizeHeat(state.monthly)
    local joins = {}
    if type(state.recent_joins) == "table" then
        for _, t in pairs(state.recent_joins) do
            if tonumber(t) then
                joins[#joins + 1] = math.floor(tonumber(t))
            end
        end
        table.sort(joins)
    end
    state.recent_joins = joins
    local graph = type(state.online_24h) == "table" and state.online_24h or {}
    state.online_24h = {
        last_bucket = int(graph.last_bucket),
        values = denseArray(graph.values, int(graph.last_bucket) > 0 and ONLINE_BUCKETS or 0, -1)
    }
end

local function migrateV1IfNeeded()
    -- V1 stored all-time users as state.all_users[uniqueID] = true.
    if type(state.all_users) == "table" then
        for uniqueID, value in pairs(state.all_users) do
            if value and state.players[uniqueID] == nil then
                state.players[uniqueID] = {
                    first_seen = "", last_seen = "", first_name = "", last_name = "",
                    joins = 0, playtime_seconds = 0, legacy = true
                }
            end
        end
        state.all_users = nil
        state.migration.upgraded_from_v1 = true
        state.migration.upgraded_at = utcTimestamp()
        log("Migrated V1 all-time users to retention schema V2.")
        log("Month-over-month retention becomes available after one complete month is captured.")
    end
    state.schema_version = 2
end

--------------------------------------------------
-- Storage
--------------------------------------------------

local function saveState()
    if not ready then
        return false
    end
    local okEncode, encoded = pcall(Util.JsonEncode, state)
    if not okEncode or not encoded then
        log("ERROR: Could not encode statistics: " .. tostring(encoded))
        return false
    end
    local ok, err = writeFileAtomic(STATE_FILE, Util.JsonPrettify(encoded), true)
    if not ok then
        log("ERROR: Could not write " .. STATE_FILE .. ": " .. tostring(err))
        return false
    end
    dirty = false
    lastSaveTime = now()
    return true
end

-- Returns true if a database was loaded (or none existed yet).
local function loadState()
    local mainExists = FS.Exists(STATE_FILE)
    local loaded, err = decodeJsonFile(STATE_FILE)

    if not loaded and mainExists then
        -- Never overwrite a damaged database: keep a copy for manual recovery.
        local corruptCopy = STATE_FILE .. ".corrupt-" .. os.date("!%Y%m%d-%H%M%S", now())
        FS.Copy(STATE_FILE, corruptCopy)
        log("WARNING: stats.json is " .. err .. ". A copy was kept as " .. corruptCopy)

        for _, candidate in ipairs({ STATE_FILE .. ".bak", STATE_FILE .. ".tmp" }) do
            local recovered = decodeJsonFile(candidate)
            if recovered then
                loaded = recovered
                log("Recovered statistics from " .. candidate ..
                    ". Joins after its last save may be missing.")
                break
            end
        end
        if not loaded then
            log("ERROR: No readable backup found. Starting a new database; the damaged file is preserved.")
        end
    elseif not loaded then
        -- Fresh install, or a crash between moving stats.json aside and replacing it.
        loaded = decodeJsonFile(STATE_FILE .. ".tmp") or decodeJsonFile(STATE_FILE .. ".bak")
        if loaded then
            log("Recovered statistics from an interrupted save.")
        end
    end

    if loaded then
        state = loaded
        normalizeState()
        migrateV1IfNeeded()
        normalizeState()
        log("Statistics loaded: " .. countKeys(state.players) .. " known players.")
    else
        state = blankState()
    end
    return mainExists or loaded ~= nil
end

local function appendJoinLog(timestamp, keys, beammpID, playerName, isGuest)
    local exists = FS.Exists(JOIN_LOG)
    local file = io.open(JOIN_LOG, "a")
    if not file then
        log("ERROR: Could not write joins.csv")
        return
    end
    -- Same columns as V1 so existing joins.csv files and tools keep working.
    if not exists then
        file:write("timestamp_utc,date,month,year,beammp_id,player_name,is_guest\n")
    end
    file:write(table.concat({
        csvCell(timestamp), csvCell(keys.day), csvCell(keys.month), csvCell(keys.year),
        csvCell(beammpID), csvTextCell(playerName), csvCell(isGuest and "true" or "false")
    }, ",") .. "\n")
    file:close()
end

--------------------------------------------------
-- Period archive / rollover
--------------------------------------------------

local function monthlyRetentionFor(period)
    if type(period) ~= "table" or period.previous_key == "" then
        return 0, 0, nil
    end
    local previous = state.history.monthly[period.previous_key]
    if type(previous) ~= "table" then
        return countKeys(period.retained_users), 0, nil
    end
    local previousUsers = tonumber(previous.unique_users) or countKeys(previous.users)
    local retained = countKeys(period.retained_users)
    return retained, int(previousUsers), percent(retained, previousUsers)
end

local function periodSummary(period)
    return {
        unique_users = countKeys(period.users),
        joins = period.joins or 0,
        guest_joins = period.guest_joins or 0,
        new_users = countKeys(period.new_users),
        returning_users = countKeys(period.returning_users),
        peak_online = period.peak_online or 0,
        peak_at = period.peak_at or "",
        avg_online = period.sampled_seconds and period.sampled_seconds > 0
            and math.floor(period.online_seconds / period.sampled_seconds * 100 + 0.5) / 100 or 0
    }
end

local function archiveMonthly(period)
    if period.key == "" then
        return
    end
    local record = periodSummary(period)
    local retained, previousUsers, retentionRate = monthlyRetentionFor(period)
    record.retained_users = retained
    record.previous_month = period.previous_key or ""
    record.previous_month_users = previousUsers
    record.retention_rate = retentionRate
    -- Kept only until the next month has used them (retention, heatmap), then pruned.
    record.users = copySet(period.users)
    record.heat_online = period.heat_online
    record.heat_sampled = period.heat_sampled
    state.history.monthly[period.key] = record
end

local function resetPeriod(period, newKey)
    period.key = newKey
    period.users = {}
    period.new_users = {}
    period.returning_users = {}
    period.retained_users = {}
    period.previous_key = ""
    period.joins = 0
    period.guest_joins = 0
    period.peak_online = 0
    period.peak_at = ""
    period.online_seconds = 0
    period.sampled_seconds = 0
    if period.heat_online then
        period.heat_online = nil
        period.heat_sampled = nil
        normalizeHeat(period)
    end
end

local function pruneOldMonthlyMembership()
    local keepKey = state.monthly.previous_key
    for monthKey, record in pairs(state.history.monthly) do
        if monthKey ~= keepKey and type(record) == "table" then
            record.users = nil
            record.heat_online = nil
            record.heat_sampled = nil
        end
    end
end

local function updatePeriods()
    local keys = periodKeys()
    local changed = false

    if state.daily.key ~= keys.day then
        if state.daily.key ~= "" then
            state.history.daily[state.daily.key] = periodSummary(state.daily)
        end
        resetPeriod(state.daily, keys.day)
        changed = true
    end

    if state.monthly.key ~= keys.month then
        archiveMonthly(state.monthly)
        resetPeriod(state.monthly, keys.month)
        state.monthly.previous_key = previousMonthKey(keys.month)

        -- Without the previous calendar month's membership, retention is N/A.
        local previous = state.history.monthly[state.monthly.previous_key]
        if type(previous) ~= "table" or type(previous.users) ~= "table" then
            state.monthly.previous_key = ""
        end
        pruneOldMonthlyMembership()
        changed = true
    end

    if state.yearly.key ~= keys.year then
        if state.yearly.key ~= "" then
            state.history.yearly[state.yearly.key] = periodSummary(state.yearly)
        end
        resetPeriod(state.yearly, keys.year)
        changed = true
    end

    if changed then
        dirty = true
    end
    return changed
end

--------------------------------------------------
-- Classification
--------------------------------------------------

local function markPeriodUser(period, uniqueID, isNewEver)
    if period.users[uniqueID] then
        return
    end
    period.users[uniqueID] = true
    if isNewEver then
        period.new_users[uniqueID] = true
    else
        period.returning_users[uniqueID] = true
    end
end

local function markMonthlyRetention(uniqueID)
    local previousKey = state.monthly.previous_key
    if previousKey == "" then
        return
    end
    local previous = state.history.monthly[previousKey]
    if type(previous) == "table" and type(previous.users) == "table" and previous.users[uniqueID] then
        state.monthly.retained_users[uniqueID] = true
    end
end

local function playerRecord(uniqueID)
    local record = state.players[uniqueID]
    if type(record) ~= "table" then
        record = {
            first_seen = "", last_seen = "", first_name = "", last_name = "",
            joins = 0, playtime_seconds = 0, legacy = true
        }
        state.players[uniqueID] = record
    end
    return record
end

--------------------------------------------------
-- Sessions and playtime
--------------------------------------------------

local function uniqueIDFor(beammpID, playerName, isGuest)
    if not isGuest and beammpID and beammpID ~= "" then
        return "beammp:" .. tostring(beammpID)
    elseif isGuest and config.count_guests_as_unique then
        -- Guest names are not permanent identities, so this is approximate.
        return "guest:" .. tostring(playerName)
    end
    return nil
end

-- Moves elapsed session time into each player's stored playtime. Time spent
-- AFK goes to afk_seconds instead, so playtime means time actually playing.
local function creditPlaytime()
    local t = now()
    -- Credits normally cover one tick. A longer gap means the server was frozen
    -- or the clock jumped, so at most three intervals are counted.
    local cap = (config.live_interval_seconds or 30) * 3
    for _, session in pairs(sessions) do
        local elapsed = math.min(t - session.credited, cap)
        if elapsed > 0 then
            if session.afk then
                session.afk_seconds = session.afk_seconds + elapsed
            end
            if session.uid then
                local record = playerRecord(session.uid)
                if session.afk then
                    record.afk_seconds = int(record.afk_seconds) + elapsed
                else
                    record.playtime_seconds = int(record.playtime_seconds) + elapsed
                    -- Playtime this calendar month, for the monthly leaderboard.
                    if record.month_key ~= state.monthly.key then
                        record.month_key = state.monthly.key
                        record.month_playtime_seconds = 0
                    end
                    record.month_playtime_seconds = int(record.month_playtime_seconds) + elapsed
                end
                dirty = true
            end
            session.credited = t
        end
    end
end

local function startSession(pid, playerName, beammpID, isGuest, resumed)
    local t = now()
    sessions[pid] = {
        uid = uniqueIDFor(beammpID, playerName, isGuest),
        name = tostring(playerName),
        guest = isGuest == true,
        beammp = beammpID and tostring(beammpID) or nil,
        joined = t,
        credited = t,
        resumed = resumed == true,
        afk = false,
        idle = 0,            -- seconds without moving
        afk_seconds = 0,     -- AFK time in this session
        last_pos = {},       -- [vid] = { x, y, z }
        active = nil         -- { owner = pid, vid = n } reported by the client mod
    }
end

local function endSession(pid)
    if sessions[pid] then
        creditPlaytime()
        sessions[pid] = nil
    end
    vehicleCache[pid] = nil
end

local function isCheckBot(name)
    return name == "CHK_BMP"
end

--------------------------------------------------
-- Concurrency: peaks, averages, heatmap, 24 h graph
--------------------------------------------------

local function onlineCount()
    return countKeys(sessions)
end

local function heatSlot()
    local d = os.date("!*t", shiftedTime())
    return (d.wday - 1) * 24 + d.hour + 1 -- 1 = Sunday 00:00, 168 = Saturday 23:00
end

local function notePeak(period, count, timestamp)
    if count > (period.peak_online or 0) then
        period.peak_online = count
        period.peak_at = timestamp
        dirty = true
    end
end

local function notePeaks(count)
    local timestamp = utcTimestamp()
    notePeak(state.daily, count, timestamp)
    notePeak(state.monthly, count, timestamp)
    notePeak(state.yearly, count, timestamp)
end

-- Records the largest player count seen in the current 5-minute bucket.
-- Buckets the server was not running for stay at -1 (a gap in the graph).
local function noteGraph(count)
    local graph = state.online_24h
    local bucket = now() // ONLINE_BUCKET
    if graph.last_bucket <= 0 or #graph.values ~= ONLINE_BUCKETS then
        graph.values = denseArray(nil, ONLINE_BUCKETS, -1)
        graph.last_bucket = bucket
    elseif bucket > graph.last_bucket then
        local shift = math.min(ONLINE_BUCKETS, bucket - graph.last_bucket)
        for _ = 1, shift do
            table.remove(graph.values, 1)
            graph.values[#graph.values + 1] = -1
        end
        graph.last_bucket = bucket
    elseif bucket < graph.last_bucket then
        return -- clock went backwards; ignore until it catches up
    end
    if count > graph.values[ONLINE_BUCKETS] then
        graph.values[ONLINE_BUCKETS] = count
    end
end

local function pruneRecentJoins()
    local cutoff = now() - 86400
    local joins = state.recent_joins
    local first = 1
    while joins[first] and joins[first] <= cutoff do
        first = first + 1
    end
    if first > 1 then
        table.move(joins, first, #joins + first - 1, 1)
        for i = #joins, #joins - first + 2, -1 do
            joins[i] = nil
        end
    end
end

-- Adds the time since the last sample to the averages and heatmap. Gaps longer
-- than three intervals (server frozen or stopped) are not counted.
local function sampleOnline()
    local t = now()
    local count = onlineCount()
    if not state.monthly.heat_online then
        normalizeHeat(state.monthly)
    end
    if lastSample then
        local dt = t - lastSample
        if dt > 0 and dt <= config.live_interval_seconds * 3 then
            for _, period in ipairs({ state.daily, state.monthly, state.yearly }) do
                period.online_seconds = period.online_seconds + count * dt
                period.sampled_seconds = period.sampled_seconds + dt
            end
            local slot = heatSlot()
            state.monthly.heat_online[slot] = state.monthly.heat_online[slot] + count * dt
            state.monthly.heat_sampled[slot] = state.monthly.heat_sampled[slot] + dt
            dirty = true
        end
    end
    lastSample = t
    notePeaks(count)
    noteGraph(count)
    pruneRecentJoins()
end

--------------------------------------------------
-- AFK detection
--------------------------------------------------

local function vehiclePosition(pid, vid)
    local ok, raw, err = pcall(MP.GetPositionRaw, pid, vid)
    if not ok or type(raw) ~= "table" or (err ~= nil and err ~= "") then
        return nil
    end
    local pos = raw.pos
    if type(pos) ~= "table" then
        return nil
    end
    local x, y, z = tonumber(pos[1] or pos.x), tonumber(pos[2] or pos.y), tonumber(pos[3] or pos.z)
    if not x or not y or not z then
        return nil
    end
    return { x, y, z }
end

-- Marks players AFK when none of their vehicles moved afk_move_meters since
-- the last check for afk_after_seconds. Called before playtime is credited.
local function updateAfk(dt)
    if not config.afk_detection then
        return
    end
    local limit = config.afk_move_meters * config.afk_move_meters
    for pid, session in pairs(sessions) do
        local ok, vehicles = pcall(MP.GetPlayerVehicles, pid)
        local moved, any = false, false
        local seen = {}
        if ok and type(vehicles) == "table" then
            for vid in pairs(vehicles) do
                local pos = vehiclePosition(pid, vid)
                if pos then
                    any = true
                    seen[vid] = true
                    local last = session.last_pos[vid]
                    if not last then
                        moved = true -- new vehicle: count as activity
                    else
                        local dx, dy, dz = pos[1] - last[1], pos[2] - last[2], pos[3] - last[3]
                        if dx * dx + dy * dy + dz * dz >= limit then
                            moved = true
                        end
                    end
                    session.last_pos[vid] = pos
                end
            end
        end
        for vid in pairs(session.last_pos) do
            if not seen[vid] then
                session.last_pos[vid] = nil
            end
        end

        if moved or not any then
            -- Moving, or no vehicle to judge (spectating / in menus).
            if session.afk then
                log(session.name .. " is back from AFK")
            end
            session.idle = 0
            session.afk = false
        else
            session.idle = session.idle + dt
            if not session.afk and session.idle >= config.afk_after_seconds then
                session.afk = true
                log(session.name .. " is AFK (no movement for " .. formatDuration(session.idle) .. ")")
            end
        end
    end
end

--------------------------------------------------
-- Active vehicle (reported by the optional PlayerCounter client mod)
--------------------------------------------------

-- Returns { owner, owner_name, vid, model, config, own } for the vehicle the
-- player is driving or watching, or nil when unknown or no longer valid.
local function activeVehicleFor(pid, session)
    local active = session.active
    if not active then
        return nil
    end
    local ok, vehicles = pcall(MP.GetPlayerVehicles, active.owner)
    if not ok or type(vehicles) ~= "table" then
        return nil
    end
    local raw = vehicles[active.vid]
    if raw == nil then
        return nil
    end
    local info = vehicleInfo(raw)
    local ownerName = sessions[active.owner] and sessions[active.owner].name
        or tostring(MP.GetPlayerName(active.owner) or "")
    return {
        owner_pid = active.owner,
        owner_name = ownerName,
        vid = active.vid,
        model = info.model,
        config = info.config,
        own = active.owner == pid
    }
end

-- Keeps sessions in line with who is actually connected (covers hot reloads
-- and missed disconnect events).
local function reconcileSessions()
    local ok, players = pcall(MP.GetPlayers)
    if not ok or type(players) ~= "table" then
        return
    end
    for pid in pairs(sessions) do
        if players[pid] == nil then
            endSession(pid)
        end
    end
    for pid, name in pairs(players) do
        if sessions[pid] == nil and not isCheckBot(name) then
            local identifiers = MP.GetPlayerIdentifiers(pid)
            local beammpID = type(identifiers) == "table" and identifiers.beammp or nil
            startSession(pid, name, beammpID, MP.IsPlayerGuest(pid), true)
        end
    end
end

--------------------------------------------------
-- Live snapshot (data/live.json)
--------------------------------------------------

function vehicleInfo(raw)
    if type(raw) ~= "string" then
        return { model = "unknown" }
    end
    local start = raw:find("{", 1, true)
    if not start then
        return { model = "unknown" }
    end
    local ok, data = pcall(Util.JsonDecode, raw:sub(start))
    if not ok or type(data) ~= "table" then
        return { model = "unknown" }
    end
    local vcf = type(data.vcf) == "table" and data.vcf or {}
    local model = data.jbm or vcf.model or vcf.mainPartName or "unknown"
    local config = nil
    if type(vcf.partConfigFilename) == "string" then
        config = vcf.partConfigFilename:match("([^/\\]+)%.pc$")
    end
    return { model = tostring(model), config = config }
end

local function playerVehicles(pid)
    local list = {}
    local ok, vehicles = pcall(MP.GetPlayerVehicles, pid)
    if not ok or type(vehicles) ~= "table" then
        vehicleCache[pid] = nil
        return list
    end
    local cache = vehicleCache[pid] or {}
    local fresh = {}
    for vid, raw in pairs(vehicles) do
        local cached = cache[vid]
        local info
        if cached and cached.raw == raw then
            info = cached.info
        else
            info = vehicleInfo(raw)
        end
        fresh[vid] = { raw = raw, info = info }
        list[#list + 1] = { vid = int(vid), model = info.model, config = info.config }
    end
    vehicleCache[pid] = fresh
    table.sort(list, function(a, b) return a.vid < b.vid end)
    return list
end

local function setting(id)
    local ok, value = pcall(MP.Get, id)
    if ok then
        return value
    end
    return nil
end

-- Top players by playtime. scope "all" = all-time, "month" = this calendar
-- month. Entries carry the BeamMP ID so the stats website can merge the same
-- player across servers; the website never shows it.
local function leaderboard(scope, limit)
    local rows = {}
    for uid, record in pairs(state.players) do
        if type(record) == "table" then
            local seconds
            if scope == "month" then
                seconds = record.month_key == state.monthly.key and int(record.month_playtime_seconds) or 0
            else
                seconds = int(record.playtime_seconds)
            end
            if seconds > 0 then
                rows[#rows + 1] = {
                    name = record.last_name ~= "" and record.last_name or uid,
                    beammp_id = uid:match("^beammp:(.+)$"),
                    playtime_seconds = seconds,
                    joins = int(record.joins),
                    last_seen = record.last_seen or ""
                }
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.playtime_seconds ~= b.playtime_seconds then
            return a.playtime_seconds > b.playtime_seconds
        end
        return a.name < b.name
    end)
    for i = #rows, limit + 1, -1 do
        rows[i] = nil
    end
    return rows
end

local function buildSnapshot(serverState)
    local t = now()
    local players = {}
    for pid, session in pairs(sessions) do
        local record = session.uid and state.players[session.uid] or nil
        local sessionSeconds = t - session.joined
        local pending = session.afk and 0 or (t - session.credited)
        local total = nil
        if record then
            -- Stored playtime plus the part of this session not yet credited.
            total = int(record.playtime_seconds) + pending
        end
        local vehicles, active = {}, nil
        if serverState == "running" then
            vehicles = playerVehicles(pid)
            active = activeVehicleFor(pid, session)
            if active and active.own then
                for _, v in ipairs(vehicles) do
                    v.active = v.vid == active.vid or nil
                end
            end
        end
        local afkSeconds = session.afk_seconds + (session.afk and (t - session.credited) or 0)
        players[#players + 1] = {
            pid = pid,
            name = session.name,
            beammp_id = session.beammp,
            guest = session.guest,
            joined_at = utcTimestamp(session.joined),
            session_seconds = sessionSeconds,
            session_resumed = session.resumed,
            total_playtime_seconds = total,
            afk = session.afk,
            idle_seconds = session.idle,
            session_afk_seconds = afkSeconds,
            active_vehicle = active,
            vehicles = vehicles
        }
    end
    table.sort(players, function(a, b) return a.session_seconds > b.session_seconds end)

    local map = tostring(setting(MP.Settings.Map) or "")
    local retained, previousUsers, rate = monthlyRetentionFor(state.monthly)
    local snapshot = {
        schema = 2,
        plugin_version = PLUGIN_VERSION,
        state = serverState,
        updated_at = utcTimestamp(t),
        updated_unix = t,
        interval_seconds = config.live_interval_seconds,
        calendar_utc_offset_hours = currentOffsetHours(t), -- day/month/heatmap calendar, DST included
        calendar_name = config.time_zone_name ~= "" and config.time_zone_name or nil,
        server = {
            name = tostring(setting(MP.Settings.Name) or ""),
            map = map:match("/levels/([^/]+)/") or map,
            max_players = int(setting(MP.Settings.MaxPlayers))
        },
        player_count = #players,
        players = players,
        stats = {
            today = periodSummary(state.daily),
            month = periodSummary(state.monthly),
            year = periodSummary(state.yearly),
            retention = {
                previous_month = state.monthly.previous_key,
                retained = retained,
                previous_users = previousUsers,
                rate = rate
            },
            all_time = {
                unique_users = countKeys(state.players),
                joins = state.total_joins
            },
            joins_24h = #state.recent_joins
        },
        leaderboard = config.leaderboard_size > 0 and {
            month_key = state.monthly.key,
            all_time = leaderboard("all", config.leaderboard_size),
            month = leaderboard("month", config.leaderboard_size)
        } or nil,
        -- Max players online per 5-minute bucket, oldest first; -1 = no data.
        online_24h = {
            bucket_seconds = ONLINE_BUCKET,
            start_unix = (state.online_24h.last_bucket - ONLINE_BUCKETS + 1) * ONLINE_BUCKET,
            values = state.online_24h.values
        },
        -- Average players online per weekday-hour this month (configured
        -- calendar), index 1 = Sunday 00:00 ... 168 = Saturday 23:00; -1 = no data.
        heatmap = (function()
            local out = {}
            for i = 1, HEAT_SLOTS do
                local sampled = state.monthly.heat_sampled and state.monthly.heat_sampled[i] or 0
                out[i] = sampled > 0
                    and math.floor(state.monthly.heat_online[i] / sampled * 100 + 0.5) / 100 or -1
            end
            return out
        end)()
    }
    return snapshot
end

--------------------------------------------------
-- Stats website upload (optional, data/website.json)
--------------------------------------------------
-- Each upload is the live snapshot plus server info, signed with
-- HMAC-SHA256 over "<unix time>.<body>" using the shared secret, and sent by
-- curl in the background so the game server never waits for the website.

local website = nil          -- loaded settings, or nil when not configured
local websiteLastPush = 0
local websiteLastStatus = nil
local websiteLastPlayers = nil  -- player count at the last upload
local WEBSITE_MIN_GAP = 5       -- seconds between uploads caused by joins/leaves
local startedAt = now()

local function cleanServerName(text)
    return (tostring(text or ""):gsub("%^[%da-fA-FlmnoprLMNOPR]", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shellQuote(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function loadWebsite()
    website = nil
    local loaded, err = decodeJsonFile(WEBSITE_FILE)
    if not loaded then
        if err ~= "missing" then
            log("WARNING: data/website.json is " .. err .. "; website uploads are off.")
        end
        return
    end
    local url = tostring(loaded.url or "")
    local secret = tostring(loaded.secret or "")
    if url == "" then
        return
    end
    if not url:match("^https://[%w%.%-]+[%w%-%./_]*$") and not url:match("^http://127%.0%.0%.1[:%d]*/[%w%-%./_]*$") then
        log("WARNING: data/website.json url must look like https://stats.example.com/ingest.php; uploads are off.")
        return
    end
    if #secret < 24 then
        log("WARNING: data/website.json secret is missing or too short; uploads are off.")
        return
    end
    local ok = os.execute(MP.GetOSName() == "Windows" and "where curl >nul 2>nul" or "command -v curl >/dev/null 2>&1")
    if not ok then
        log("WARNING: curl is not installed on this server, so website uploads are off.")
        return
    end
    local name = cleanServerName(loaded.server_name ~= nil and loaded.server_name or setting(MP.Settings.Name))
    local key = tostring(loaded.server_key or ""):lower()
    if key == "" then
        key = name:lower():gsub("[^%w_%-]+", "-"):gsub("^[-_]+", ""):gsub("[-_]+$", ""):sub(1, 40)
    end
    if not key:match("^[a-z0-9][a-z0-9_%-]*$") or #key > 40 then
        key = "server"
    end
    website = {
        url = url,
        secret = secret,
        key = key,
        name = name ~= "" and name or key,
        connect = tostring(loaded.connect or ""),
        order = int(loaded.order),
        interval = math.max(30, int(loaded.interval_seconds ~= nil and loaded.interval_seconds or 60))
    }
    log("Website uploads on: " .. url .. " as \"" .. website.name .. "\" (key " .. key .. ").")
end

-- Logs the result of the previous background upload when it changes.
local function checkWebsiteReply()
    if not website then
        return
    end
    local code = readFile(WEBSITE_CODE)
    if not code or code == "" then
        return
    end
    code = code:match("%d+") or code
    if code ~= websiteLastStatus then
        if code == "200" then
            log("Website upload OK.")
        else
            local reply = (readFile(WEBSITE_REPLY) or ""):gsub("%s+", " "):sub(1, 200)
            log("WARNING: website upload failed (HTTP " .. code .. "): " .. reply)
        end
        websiteLastStatus = code
    end
end

local function pushWebsite(snapshot, serverState, wait)
    if not website or not snapshot then
        return
    end
    local payload = {
        server = { key = website.key, name = website.name, connect = website.connect, order = website.order },
        panel_state = serverState == "running" and "running" or "offline",
        uptime_ms = (now() - startedAt) * 1000,
        live = snapshot
    }
    local ok, body = pcall(Util.JsonEncode, payload)
    if not ok or not body then
        return
    end
    local file = io.open(WEBSITE_BODY, "wb")
    if not file then
        log("WARNING: could not write " .. WEBSITE_BODY)
        return
    end
    file:write(body)
    file:close()
    local timestamp = tostring(now())
    local signature = hmacSha256Hex(website.secret, timestamp .. "." .. body)
    local parts = {
        "curl -s -m " .. (wait and "5" or "15"),
        "-A " .. shellQuote("PlayerCounter/" .. PLUGIN_VERSION),
        "-H " .. shellQuote("Content-Type: application/json"),
        "-H " .. shellQuote("X-PlayerCounter-Timestamp: " .. timestamp),
        "-H " .. shellQuote("X-PlayerCounter-Signature: sha256=" .. signature),
        "--data-binary @" .. shellQuote(WEBSITE_BODY),
        "-o " .. shellQuote(WEBSITE_REPLY),
        "-w " .. shellQuote("%{http_code}"),
        shellQuote(website.url)
    }
    local command = table.concat(parts, " ")
    if MP.GetOSName() == "Windows" then
        command = command:gsub("'", '"'):gsub("%%{http_code}", "%%%%{http_code}")
        command = (wait and "" or 'start "" /B ') .. 'cmd /C "' .. command .. ' > "' .. WEBSITE_CODE .. '""'
    else
        command = command .. " > " .. shellQuote(WEBSITE_CODE) .. " 2>/dev/null" .. (wait and "" or " &")
    end
    os.execute(command)
    websiteLastPush = now()
end

local function writeLive(serverState, forcePush)
    if not ready then
        return
    end
    local snapshot = buildSnapshot(serverState)
    if config.live_snapshot then
        local ok, encoded = pcall(Util.JsonEncode, snapshot)
        if ok and encoded then
            local wrote, err = writeFileAtomic(LIVE_FILE, encoded, false)
            if not wrote then
                log("ERROR: Could not write live.json: " .. tostring(err))
            end
        end
    end
    local count = snapshot.player_count
    local since = now() - websiteLastPush
    if website and (forcePush or since >= website.interval
        or (count ~= websiteLastPlayers and since >= WEBSITE_MIN_GAP)) then
        websiteLastPlayers = count
        pushWebsite(snapshot, serverState, serverState ~= "running")
    end
end

--------------------------------------------------
-- Reporting
--------------------------------------------------

local function retentionText()
    local retained, previousUsers, rate = monthlyRetentionFor(state.monthly)
    if rate == nil then
        return "MoM retention: N/A"
    end
    return string.format("MoM retention: %d/%d (%s)", retained, previousUsers, formatPercent(rate))
end

local function periodLine(label, period)
    return string.format("%s: %d unique, %d new, %d returning, %d joins",
        label, countKeys(period.users), countKeys(period.new_users),
        countKeys(period.returning_users), period.joins)
end

local function statsLines()
    return {
        string.format("Online now: %d | Peak today: %d | Peak this month: %d | Joins last 24h: %d",
            countKeys(sessions), state.daily.peak_online, state.monthly.peak_online, #state.recent_joins),
        periodLine("Today", state.daily),
        periodLine("Month", state.monthly),
        retentionText(),
        periodLine("Year", state.yearly),
        string.format("All-time: %d unique, %d joins", countKeys(state.players), state.total_joins)
    }
end

local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function slotName(slot)
    local day = (slot - 1) // 24 + 1
    local hour = (slot - 1) % 24
    return string.format("%s %02d:00", WEEKDAYS[day], hour)
end



-- Peak and average players online for today, this month, this year.
local function peakReport()
    local lines = { "Players online (" .. calendarLabel() .. " calendar):" }
    for _, item in ipairs({ { "Today", state.daily }, { "Month", state.monthly }, { "Year", state.yearly } }) do
        local s = periodSummary(item[2])
        lines[#lines + 1] = string.format("  %-6s peak %d%s | average %.2f",
            item[1], s.peak_online, s.peak_at ~= "" and (" at " .. s.peak_at) or "", s.avg_online)
    end
    lines[#lines + 1] = string.format("  Now %d | joins in the last 24 h: %d", countKeys(sessions), #state.recent_joins)
    return table.concat(lines, "\n")
end

-- Busiest and quietest hours of the week this month, plus a compact 7 x 24 grid.
local function heatmapReport()
    local heat, sampled = state.monthly.heat_online, state.monthly.heat_sampled
    local averages = {}
    for i = 1, HEAT_SLOTS do
        if sampled[i] > 0 then
            averages[#averages + 1] = { slot = i, avg = heat[i] / sampled[i] }
        end
    end
    if #averages == 0 then
        return "No heatmap data yet for " .. state.monthly.key .. "."
    end
    table.sort(averages, function(a, b) return a.avg > b.avg end)
    local lines = { string.format("Average players online by hour, %s (%s calendar)", state.monthly.key, calendarLabel()) }
    local busiest = {}
    for i = 1, math.min(5, #averages) do
        busiest[#busiest + 1] = string.format("%s (%.1f)", slotName(averages[i].slot), averages[i].avg)
    end
    lines[#lines + 1] = "  Busiest: " .. table.concat(busiest, ", ")
    local max = averages[1].avg
    local shades = { " ", ".", ":", "-", "=", "+", "*", "#", "%", "@" }
    lines[#lines + 1] = "       " .. "0         1         2   "
    lines[#lines + 1] = "       " .. "012345678901234567890123"
    for day = 1, 7 do
        local row = {}
        for hour = 0, 23 do
            local slot = (day - 1) * 24 + hour + 1
            if sampled[slot] <= 0 then
                row[#row + 1] = "?"
            else
                local level = max > 0 and math.floor(heat[slot] / sampled[slot] / max * 9 + 0.5) or 0
                row[#row + 1] = shades[level + 1]
            end
        end
        lines[#lines + 1] = string.format("  %s  %s", WEEKDAYS[day], table.concat(row))
    end
    lines[#lines + 1] = "  (blank = empty, @ = busiest, ? = server not running)"
    return table.concat(lines, "\n")
end

local function statsMessage()
    return table.concat(statsLines(), " | ")
end

local function retentionLines()
    local retained, previousUsers, rate = monthlyRetentionFor(state.monthly)
    local tail = string.format("Current unique: %d | New: %d | Returning-ever: %d",
        countKeys(state.monthly.users), countKeys(state.monthly.new_users),
        countKeys(state.monthly.returning_users))
    if rate == nil then
        return {
            string.format("Retention | Current month: %s | Previous-month cohort unavailable", state.monthly.key),
            tail
        }
    end
    return {
        string.format("Retention | %s -> %s: %d of %d returned (%s)",
            state.monthly.previous_key, state.monthly.key, retained, previousUsers, formatPercent(rate)),
        tail
    }
end

local function retentionMessage()
    return table.concat(retentionLines(), " | ")
end

local function monthReport(monthKey)
    local record
    if monthKey == nil or monthKey == "" or monthKey == state.monthly.key then
        monthKey = state.monthly.key
        record = periodSummary(state.monthly)
        local retained, previousUsers, rate = monthlyRetentionFor(state.monthly)
        record.retained_users, record.previous_month_users, record.retention_rate = retained, previousUsers, rate
        record.in_progress = true
    else
        record = state.history.monthly[monthKey]
        if type(record) ~= "table" then
            return "No archived data for " .. tostring(monthKey) .. " (use YYYY-MM)."
        end
    end
    local lines = {
        string.format("PlayerCounter report for %s%s", monthKey, record.in_progress and " (in progress)" or ""),
        string.format("  Unique players:       %d", int(record.unique_users)),
        string.format("  New players:          %d", int(record.new_users)),
        string.format("  Returning players:    %d", int(record.returning_users)),
        string.format("  Join sessions:        %d", int(record.joins)),
        string.format("  Guest joins:          %d", int(record.guest_joins)),
        string.format("  Previous month users: %d", int(record.previous_month_users)),
        string.format("  Players retained:     %d", int(record.retained_users)),
        string.format("  Monthly retention:    %s", formatPercent(tonumber(record.retention_rate))),
        string.format("  Peak players online:  %d", int(record.peak_online)),
        string.format("  Average online:       %.2f", tonumber(record.avg_online) or 0)
    }
    return table.concat(lines, "\n")
end

local function onlineReport()
    local lines = {}
    local t = now()
    for pid, session in pairs(sessions) do
        local vehicles = {}
        for _, v in ipairs(playerVehicles(pid)) do
            vehicles[#vehicles + 1] = v.config and (v.model .. " (" .. v.config .. ")") or v.model
        end
        local active = activeVehicleFor(pid, session)
        local driving = ""
        if active then
            driving = active.own and (" | driving " .. active.model)
                or (" | watching " .. active.owner_name .. " (" .. active.model .. ")")
        end
        lines[#lines + 1] = string.format("  [%d] %s%s | session %s%s | vehicles: %s",
            pid, session.name, session.afk and " [AFK]" or "", formatDuration(t - session.joined),
            driving, #vehicles > 0 and table.concat(vehicles, ", ") or "none")
    end
    table.sort(lines)
    table.insert(lines, 1, string.format("Online: %d player(s)", #lines))
    return table.concat(lines, "\n")
end

local function topPlaytimeReport(limit, scope)
    creditPlaytime()
    local rows = leaderboard(scope, limit)
    local lines = { scope == "month" and ("Top playtime in " .. state.monthly.key .. ":")
        or "Top playtime (tracked since v2.0.1):" }
    for i, row in ipairs(rows) do
        lines[#lines + 1] = string.format("  %2d. %s - %s", i, row.name, formatDuration(row.playtime_seconds))
    end
    if #rows == 0 then
        lines[#lines + 1] = "  No playtime recorded yet."
    end
    return table.concat(lines, "\n")
end

local function playtimeLine(pid)
    local session = sessions[pid]
    if not session then
        return "PlayerCounter: no active session found for you."
    end
    local t = now()
    local text = "Session: " .. formatDuration(t - session.joined)
    if session.uid and state.players[session.uid] then
        local record = state.players[session.uid]
        local pending = session.afk and 0 or (t - session.credited)
        text = text .. " | Total playtime: " ..
            formatDuration(int(record.playtime_seconds) + pending) ..
            " | Joins: " .. int(record.joins)
    end
    return text
end

local function refreshPeriods()
    if updatePeriods() then
        saveState()
    end
end

--------------------------------------------------
-- Player events
--------------------------------------------------

function PlayerCounter_OnPlayerJoining(playerID)
    if not ready then
        return
    end
    local playerName = MP.GetPlayerName(playerID)

    -- BeamMP connectivity checker, not a real player.
    if isCheckBot(playerName) then
        log("Ignoring CHK_BMP server check.")
        return
    end

    local identifiers = MP.GetPlayerIdentifiers(playerID)
    if type(identifiers) ~= "table" then
        log("Could not get identifiers for " .. tostring(playerName))
        return
    end

    local isGuest = MP.IsPlayerGuest(playerID) == true
    updatePeriods()

    -- Every real connection counts as a join session, including guests.
    state.daily.joins = state.daily.joins + 1
    state.monthly.joins = state.monthly.joins + 1
    state.yearly.joins = state.yearly.joins + 1
    state.total_joins = state.total_joins + 1
    if isGuest then
        state.daily.guest_joins = state.daily.guest_joins + 1
        state.monthly.guest_joins = state.monthly.guest_joins + 1
        state.yearly.guest_joins = state.yearly.guest_joins + 1
    end

    local beammpID = identifiers.beammp
    local uniqueID = uniqueIDFor(beammpID, playerName, isGuest)
    local timestamp = utcTimestamp()

    if uniqueID then
        local isNewEver = state.players[uniqueID] == nil
        if isNewEver then
            state.players[uniqueID] = {
                first_seen = timestamp, last_seen = timestamp,
                first_name = tostring(playerName), last_name = tostring(playerName),
                joins = 1, playtime_seconds = 0, legacy = false
            }
        else
            local record = playerRecord(uniqueID)
            record.last_seen = timestamp
            record.last_name = tostring(playerName)
            record.joins = int(record.joins) + 1
        end
        markPeriodUser(state.daily, uniqueID, isNewEver)
        markPeriodUser(state.monthly, uniqueID, isNewEver)
        markPeriodUser(state.yearly, uniqueID, isNewEver)
        markMonthlyRetention(uniqueID)
    end

    if sessions[playerID] then
        endSession(playerID)
    end
    startSession(playerID, playerName, beammpID, isGuest, false)
    state.recent_joins[#state.recent_joins + 1] = now()
    pruneRecentJoins()
    notePeaks(onlineCount())  -- catch peaks shorter than one tick
    noteGraph(onlineCount())

    appendJoinLog(timestamp, periodKeys(), beammpID or "", playerName, isGuest)
    dirty = true
    saveState()
    writeLive("running")

    log(tostring(playerName) .. " joined | " .. statsMessage())
end

function PlayerCounter_OnPlayerDisconnect(playerID)
    if not ready or not sessions[playerID] then
        return
    end
    local session = sessions[playerID]
    endSession(playerID)
    log(session.name .. " left after " .. formatDuration(now() - session.joined))
    saveState()
    writeLive("running")
end

-- The optional client mod reports which vehicle the player is in, as JSON
-- {"v":1,"sid":"<owner pid>-<vid>"} ("sid":"" = none). Client data is
-- untrusted: only a vehicle that currently exists on the server is accepted.
function PlayerCounter_OnActiveVehicle(playerID, data)
    local session = ready and sessions[playerID]
    if not session or type(data) ~= "string" or #data > 200 then
        return
    end
    local ok, payload = pcall(Util.JsonDecode, data)
    if not ok or type(payload) ~= "table" or type(payload.sid) ~= "string" then
        return
    end
    if payload.sid == "" then
        session.active = nil
        return
    end
    local owner, vid = payload.sid:match("^(%d+)%-(%d+)$")
    owner, vid = tonumber(owner), tonumber(vid)
    if not owner or not vid then
        return
    end
    local okVehicles, vehicles = pcall(MP.GetPlayerVehicles, owner)
    if not okVehicles or type(vehicles) ~= "table" or vehicles[vid] == nil then
        return
    end
    session.active = { owner = owner, vid = vid }
end

--------------------------------------------------
-- Chat commands
--------------------------------------------------

local function isAdmin(playerID)
    local identifiers = MP.GetPlayerIdentifiers(playerID)
    return type(identifiers) == "table" and identifiers.beammp ~= nil
        and config.admin_set[tostring(identifiers.beammp)] == true
end

local function sendLines(playerID, lines)
    for _, line in ipairs(lines) do
        MP.SendChatMessage(playerID, line)
    end
end

function PlayerCounter_OnChatMessage(playerID, playerName, message)
    local command = trim(message):match("^(/%S+)")
    if not command then
        return 0
    end
    command = command:lower()
    if command ~= "/playerstats" and command ~= "/retention" and command ~= "/playtime" then
        return 0
    end
    if not ready or config.player_commands == "off" then
        return 0
    end
    if config.player_commands == "admins" and not isAdmin(playerID) then
        MP.SendChatMessage(playerID, "PlayerCounter: this command is for server admins.")
        return 1
    end

    refreshPeriods()
    if command == "/playerstats" then
        sendLines(playerID, statsLines())
    elseif command == "/retention" then
        sendLines(playerID, retentionLines())
    else
        MP.SendChatMessage(playerID, playtimeLine(playerID))
    end
    return 1
end

--------------------------------------------------
-- Server console commands
--------------------------------------------------

local CONSOLE_HELP = table.concat({
    "PlayerCounter " .. PLUGIN_VERSION .. " console commands:",
    "  playerstats / pc.stats        overall analytics",
    "  retention   / pc.retention    month-over-month retention",
    "  pc.month [YYYY-MM]            monthly report (current month if omitted)",
    "  pc.online                     who is online, session time, AFK, vehicles",
    "  pc.peak                       peak and average players online",
    "  pc.heatmap                    busiest hours of the week this month",
    "  pc.top [N] [month]            top N players by playtime (default 10; month = this month)",
    "  pc.save                       save statistics and live.json now"
}, "\n")

function PlayerCounter_OnConsoleInput(input)
    local words = {}
    for word in trim(input):gmatch("%S+") do
        words[#words + 1] = word
    end
    local command = (words[1] or ""):lower()

    if command == "playerstats" or command == "pc.stats" then
        refreshPeriods()
        return statsMessage()
    elseif command == "retention" or command == "pc.retention" then
        refreshPeriods()
        return retentionMessage()
    elseif command == "pc.month" then
        refreshPeriods()
        return monthReport(words[2])
    elseif command == "pc.online" then
        return onlineReport()
    elseif command == "pc.peak" then
        refreshPeriods()
        return peakReport()
    elseif command == "pc.heatmap" then
        refreshPeriods()
        return heatmapReport()
    elseif command == "pc.top" then
        local count, scope = words[2], words[3]
        if count and not tonumber(count) then
            count, scope = nil, count -- "pc.top month"
        end
        refreshPeriods()
        return topPlaytimeReport(math.max(1, math.min(50, int(count or 10))),
            (scope or ""):lower() == "month" and "month" or "all")
    elseif command == "pc.save" then
        refreshPeriods()
        creditPlaytime()
        local ok = saveState()
        writeLive("running")
        return ok and "PlayerCounter: saved." or "PlayerCounter: save failed, see errors above."
    elseif command == "pc.help" or command == "pc" then
        return CONSOLE_HELP
    end
end

--------------------------------------------------
-- Timer, initialization, shutdown
--------------------------------------------------

function PlayerCounter_OnTick()
    if not ready then
        return
    end
    local t = now()
    local dt = lastTick and (t - lastTick) or 0
    lastTick = t
    updatePeriods()       -- day/month/year rollover even when nobody joins
    reconcileSessions()
    if dt > 0 and dt <= config.live_interval_seconds * 3 then
        updateAfk(dt)
    end
    creditPlaytime()
    sampleOnline()
    if dirty and now() - lastSaveTime >= PLAYTIME_SAVE_INTERVAL then
        saveState()
    end
    checkWebsiteReply()
    writeLive("running")
end

function PlayerCounter_OnInit()
    if ready then
        return -- already initialised in this Lua state
    end
    local success, errorMessage = FS.CreateDirectory(DATA_DIR)
    if not success and not FS.IsDirectory(DATA_DIR) then
        print("[PlayerCounter] ERROR: Could not create data directory: " .. tostring(errorMessage))
        print("[PlayerCounter] Statistics are DISABLED until this is fixed.")
        return
    end

    local hadDatabase = FS.Exists(STATE_FILE)
    local createdConfig = loadConfig()
    loadState()

    -- Warn when the calendar offset differs from the one the data was built with.
    local recorded = tonumber(state.recorded_settings.utc_offset_hours)
    if recorded and recorded ~= config.utc_offset_hours then
        log(string.format("WARNING: utc_offset_hours is %s but this data was collected with %s. " ..
            "Day/month boundaries will shift. Fix data/config.json if this was not intended.",
            tostring(config.utc_offset_hours), tostring(recorded)))
    elseif not recorded and createdConfig and hadDatabase then
        log("NOTICE: Settings now live in data/config.json (created with utc_offset_hours = " ..
            tostring(config.utc_offset_hours) .. "). If your previous main.lua used a different " ..
            "UTC_OFFSET_HOURS, set it in data/config.json and restart.")
    end
    state.recorded_settings.utc_offset_hours = config.utc_offset_hours

    ready = true
    if updatePeriods() then
        log("Calendar period rollover processed on startup.")
    end
    reconcileSessions() -- players already online after a hot reload
    sampleOnline()      -- starts the averages clock and the 24 h graph
    lastTick = now()
    saveState()

    MP.RegisterEvent("PlayerCounter_Tick", "PlayerCounter_OnTick")
    MP.CancelEventTimer("PlayerCounter_Tick")
    MP.CreateEventTimer("PlayerCounter_Tick", config.live_interval_seconds * 1000)
    loadWebsite()
    writeLive("running", true)

    log("PlayerCounter " .. PLUGIN_VERSION .. " loaded (calendar " .. calendarLabel() ..
        (config.dst ~= "none" and (", " .. config.dst:upper() .. " daylight saving") or "") ..
        ", player commands: " .. config.player_commands .. "). Type pc.help in the console.")
    log(statsMessage())
    log(retentionMessage())
end

function PlayerCounter_OnShutdown()
    if not ready then
        return
    end
    updatePeriods()
    creditPlaytime()
    sampleOnline()
    saveState()
    sessions = {}
    writeLive("stopped", true)  -- tells the website the server went offline
    log("Statistics saved on shutdown.")
end

--------------------------------------------------
-- Register events (BeamMP Server 3.x)
--------------------------------------------------

MP.RegisterEvent("onInit", "PlayerCounter_OnInit")
MP.RegisterEvent("onPlayerJoining", "PlayerCounter_OnPlayerJoining")
MP.RegisterEvent("onPlayerDisconnect", "PlayerCounter_OnPlayerDisconnect")
MP.RegisterEvent("onChatMessage", "PlayerCounter_OnChatMessage")
MP.RegisterEvent("onConsoleInput", "PlayerCounter_OnConsoleInput")
MP.RegisterEvent("onShutdown", "PlayerCounter_OnShutdown")
MP.RegisterEvent(ACTIVE_VEHICLE_EVENT, "PlayerCounter_OnActiveVehicle")
