-- BeamMP Player Counter + Retention Analytics by Leshii413 with Youtube, Reddit & AI assistance.
-- Tracks daily, monthly, yearly and all-time unique users + total joins.
-- Public Config
-- Version 08.10.2026.1600
--
-- Philippines Offset added for myself during creation to allow future timezone changes. Default can be easily changed to your timezone, just change based on your UTC + .or -
--
-- Tracks:
--   * Daily / monthly / yearly unique authenticated users
--   * Raw join sessions
--   * New vs returning users
--   * Month-over-month retained users and retention rate
--   * All-time unique users and joins
--
-- Identity is based on the permanent BeamMP ID returned by
-- MP.GetPlayerIdentifiers(playerID).beammp.

local DATA_DIR = "Resources/Server/PlayerCounter/data"
local STATE_FILE = DATA_DIR .. "/stats.json"
local JOIN_LOG = DATA_DIR .. "/joins.csv"

-- Analytics calendar offset.
-- 0 = UTC
-- 8 = Philippines (UTC+8)
local UTC_OFFSET_HOURS = 0

-- Guests do not have a stable BeamMP account ID.
-- Recommended: false, so they affect join-session counts but not unique-user counts.
local COUNT_GUESTS_AS_UNIQUE = false

-- Allow players to use /playerstats and /retention in chat.
local ALLOW_PLAYER_COMMANDS = true

local function blankPeriod()
    return {
        key = "",
        users = {},
        new_users = {},
        returning_users = {},
        retained_users = {}, -- monthly only; harmless on daily/yearly
        previous_key = "",  -- monthly only
        joins = 0,
        guest_joins = 0
    }
end

local state = {
    schema_version = 2,
    daily = blankPeriod(),
    monthly = blankPeriod(),
    yearly = blankPeriod(),

    -- ["beammp:123456"] = {
    --     first_seen = "2026-08-10T05:00:00Z",
    --     last_seen = "2026-08-10T05:00:00Z",
    --     first_name = "Player",
    --     last_name = "Player",
    --     joins = 1,
    --     legacy = false
    -- }
    players = {},

    total_joins = 0,

    history = {
        daily = {},
        monthly = {},
        yearly = {}
    },

    migration = {
        upgraded_from_v1 = false,
        upgraded_at = ""
    }
}

--------------------------------------------------
-- Utility
--------------------------------------------------

local function countKeys(tbl)
    local count = 0
    if type(tbl) ~= "table" then
        return 0
    end

    for _ in pairs(tbl) do
        count = count + 1
    end

    return count
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

local function shiftedTime()
    return os.time() + (UTC_OFFSET_HOURS * 3600)
end

local function periodKeys()
    local now = shiftedTime()

    return {
        day = os.date("!%Y-%m-%d", now),
        month = os.date("!%Y-%m", now),
        year = os.date("!%Y", now)
    }
end

local function utcTimestamp()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function previousMonthKey(monthKey)
    local yearText, monthText = tostring(monthKey):match("^(%d%d%d%d)%-(%d%d)$")
    if not yearText or not monthText then
        return ""
    end

    local year = tonumber(yearText)
    local month = tonumber(monthText)

    month = month - 1
    if month == 0 then
        month = 12
        year = year - 1
    end

    return string.format("%04d-%02d", year, month)
end

local function csvEscape(value)
    value = tostring(value or "")

    if value:find('[,"\n\r]') then
        value = '"' .. value:gsub('"', '""') .. '"'
    end

    return value
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

--------------------------------------------------
-- State normalization / migration
--------------------------------------------------

local function normalizePeriod(period)
    period = type(period) == "table" and period or {}

    period.key = period.key or ""
    period.users = type(period.users) == "table" and period.users or {}
    period.new_users = type(period.new_users) == "table" and period.new_users or {}
    period.returning_users = type(period.returning_users) == "table" and period.returning_users or {}
    period.retained_users = type(period.retained_users) == "table" and period.retained_users or {}
    period.previous_key = period.previous_key or ""
    period.joins = tonumber(period.joins) or 0
    period.guest_joins = tonumber(period.guest_joins) or 0

    return period
end

local function normalizeState()
    state.daily = normalizePeriod(state.daily)
    state.monthly = normalizePeriod(state.monthly)
    state.yearly = normalizePeriod(state.yearly)

    state.players = type(state.players) == "table" and state.players or {}
    state.total_joins = tonumber(state.total_joins) or 0

    state.history = type(state.history) == "table" and state.history or {}
    state.history.daily = type(state.history.daily) == "table" and state.history.daily or {}
    state.history.monthly = type(state.history.monthly) == "table" and state.history.monthly or {}
    state.history.yearly = type(state.history.yearly) == "table" and state.history.yearly or {}

    state.migration = type(state.migration) == "table" and state.migration or {}
    state.migration.upgraded_from_v1 = state.migration.upgraded_from_v1 == true
    state.migration.upgraded_at = state.migration.upgraded_at or ""
end

local function migrateV1IfNeeded()
    -- V1 stored all-time users as: state.all_users[uniqueID] = true
    -- V2 stores per-player metadata in state.players.
    if type(state.all_users) == "table" then
        for uniqueID, value in pairs(state.all_users) do
            if value and state.players[uniqueID] == nil then
                state.players[uniqueID] = {
                    first_seen = "",
                    last_seen = "",
                    first_name = "",
                    last_name = "",
                    joins = 0,
                    legacy = true
                }
            end
        end

        state.all_users = nil
        state.migration.upgraded_from_v1 = true
        state.migration.upgraded_at = utcTimestamp()

        print("[PlayerCounter] Migrated V1 all-time users to retention schema V2.")
        print("[PlayerCounter] New/returning classification becomes fully accurate after the next period rollover.")
        print("[PlayerCounter] Month-over-month retention becomes available after one complete month is captured by V2.")
    end

    state.schema_version = 2
end

--------------------------------------------------
-- Storage
--------------------------------------------------

local function saveState()
    local encoded = Util.JsonEncode(state)
    if not encoded then
        print("[PlayerCounter] ERROR: Could not encode stats state.")
        return false
    end

    local file = io.open(STATE_FILE, "w")
    if not file then
        print("[PlayerCounter] ERROR: Could not write " .. STATE_FILE)
        return false
    end

    file:write(Util.JsonPrettify(encoded))
    file:close()
    return true
end

local function loadState()
    if not FS.Exists(STATE_FILE) then
        return
    end

    local file = io.open(STATE_FILE, "r")
    if not file then
        print("[PlayerCounter] WARNING: Could not open existing stats.json")
        return
    end

    local contents = file:read("*a")
    file:close()

    if contents == "" then
        return
    end

    local loaded = Util.JsonDecode(contents)
    if type(loaded) == "table" then
        state = loaded
        normalizeState()
        migrateV1IfNeeded()
        normalizeState()
        print("[PlayerCounter] Existing statistics loaded.")
    else
        print("[PlayerCounter] WARNING: Could not decode stats.json; starting with in-memory defaults.")
    end
end

local function appendJoinLog(timestamp, day, month, year, beammpID, playerName, isGuest)
    local exists = FS.Exists(JOIN_LOG)
    local file = io.open(JOIN_LOG, "a")

    if not file then
        print("[PlayerCounter] ERROR: Could not write joins.csv")
        return
    end

    -- Keep the V1 CSV format so an existing joins.csv remains compatible.
    if not exists then
        file:write("timestamp_utc,date,month,year,beammp_id,player_name,is_guest\n")
    end

    file:write(
        csvEscape(timestamp) .. "," ..
        csvEscape(day) .. "," ..
        csvEscape(month) .. "," ..
        csvEscape(year) .. "," ..
        csvEscape(beammpID) .. "," ..
        csvEscape(playerName) .. "," ..
        csvEscape(isGuest and "true" or "false") ..
        "\n"
    )

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

    return retained, previousUsers, percent(retained, previousUsers)
end

local function archiveDaily(period)
    if period.key == "" then
        return
    end

    state.history.daily[period.key] = {
        unique_users = countKeys(period.users),
        joins = period.joins or 0,
        guest_joins = period.guest_joins or 0,
        new_users = countKeys(period.new_users),
        returning_users = countKeys(period.returning_users)
    }
end

local function archiveMonthly(period)
    if period.key == "" then
        return
    end

    local retained, previousUsers, retentionRate = monthlyRetentionFor(period)

    state.history.monthly[period.key] = {
        unique_users = countKeys(period.users),
        joins = period.joins or 0,
        guest_joins = period.guest_joins or 0,
        new_users = countKeys(period.new_users),
        returning_users = countKeys(period.returning_users),
        retained_users = retained,
        previous_month = period.previous_key or "",
        previous_month_users = previousUsers,
        retention_rate = retentionRate,

        -- Membership is retained temporarily so the NEXT month can calculate
        -- exact month-over-month retention. Older membership sets are pruned.
        users = copySet(period.users)
    }
end

local function archiveYearly(period)
    if period.key == "" then
        return
    end

    state.history.yearly[period.key] = {
        unique_users = countKeys(period.users),
        joins = period.joins or 0,
        guest_joins = period.guest_joins or 0,
        new_users = countKeys(period.new_users),
        returning_users = countKeys(period.returning_users)
    }
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
end

local function pruneOldMonthlyMembership()
    -- Current retention only needs the immediately previous calendar month's IDs.
    local keepKey = state.monthly.previous_key

    for monthKey, record in pairs(state.history.monthly) do
        if monthKey ~= keepKey and type(record) == "table" then
            record.users = nil
        end
    end
end

local function updatePeriods()
    local keys = periodKeys()
    local changed = false

    if state.daily.key ~= keys.day then
        archiveDaily(state.daily)
        resetPeriod(state.daily, keys.day)
        changed = true
    end

    if state.monthly.key ~= keys.month then
        archiveMonthly(state.monthly)
        resetPeriod(state.monthly, keys.month)
        state.monthly.previous_key = previousMonthKey(keys.month)

        -- If there is no archived immediate previous calendar month with
        -- membership data, current-month retention is intentionally N/A.
        local previous = state.history.monthly[state.monthly.previous_key]
        if type(previous) ~= "table" or type(previous.users) ~= "table" then
            state.monthly.previous_key = ""
        end

        pruneOldMonthlyMembership()
        changed = true
    end

    if state.yearly.key ~= keys.year then
        archiveYearly(state.yearly)
        resetPeriod(state.yearly, keys.year)
        changed = true
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
        return false
    end

    local previous = state.history.monthly[previousKey]
    if type(previous) ~= "table" or type(previous.users) ~= "table" then
        return false
    end

    if previous.users[uniqueID] then
        state.monthly.retained_users[uniqueID] = true
        return true
    end

    return false
end

--------------------------------------------------
-- Reporting
--------------------------------------------------

local function currentRetentionData()
    local retained, previousUsers, rate = monthlyRetentionFor(state.monthly)
    return {
        previous_key = state.monthly.previous_key,
        retained = retained,
        previous_users = previousUsers,
        rate = rate
    }
end

local function statsMessage()
    local retention = currentRetentionData()

    local retentionText
    if retention.rate == nil then
        retentionText = "MoM retention: N/A"
    else
        retentionText = string.format(
            "MoM retention: %d/%d (%s)",
            retention.retained,
            retention.previous_users,
            formatPercent(retention.rate)
        )
    end

    return string.format(
        "Today: %d unique, %d new, %d returning, %d joins | " ..
        "Month: %d unique, %d new, %d returning, %d joins | " ..
        "%s | " ..
        "Year: %d unique, %d new, %d returning, %d joins | " ..
        "All-time: %d unique, %d joins",

        countKeys(state.daily.users),
        countKeys(state.daily.new_users),
        countKeys(state.daily.returning_users),
        state.daily.joins,

        countKeys(state.monthly.users),
        countKeys(state.monthly.new_users),
        countKeys(state.monthly.returning_users),
        state.monthly.joins,

        retentionText,

        countKeys(state.yearly.users),
        countKeys(state.yearly.new_users),
        countKeys(state.yearly.returning_users),
        state.yearly.joins,

        countKeys(state.players),
        state.total_joins
    )
end

local function retentionMessage()
    local retention = currentRetentionData()

    if retention.rate == nil then
        return string.format(
            "Retention | Current month: %s | Previous-month cohort unavailable | " ..
            "Current unique: %d | New: %d | Returning-ever: %d",
            state.monthly.key,
            countKeys(state.monthly.users),
            countKeys(state.monthly.new_users),
            countKeys(state.monthly.returning_users)
        )
    end

    return string.format(
        "Retention | %s -> %s: %d of %d returned (%s) | " ..
        "Current unique: %d | New: %d | Returning-ever: %d",
        retention.previous_key,
        state.monthly.key,
        retention.retained,
        retention.previous_users,
        formatPercent(retention.rate),
        countKeys(state.monthly.users),
        countKeys(state.monthly.new_users),
        countKeys(state.monthly.returning_users)
    )
end

--------------------------------------------------
-- Player joins
--------------------------------------------------

function PlayerCounter_OnPlayerJoining(playerID)
    local playerName = MP.GetPlayerName(playerID)

    -- BeamMP connectivity checker / non-player probe.
    if playerName == "CHK_BMP" then
        print("[PlayerCounter] Ignoring CHK_BMP server check.")
        return
    end

    local identifiers = MP.GetPlayerIdentifiers(playerID)
    if type(identifiers) ~= "table" then
        print("[PlayerCounter] Could not get identifiers for " .. tostring(playerName))
        return
    end

    local isGuest = MP.IsPlayerGuest(playerID)
    local periodsChanged = updatePeriods()

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
    local uniqueID = nil

    if not isGuest and beammpID then
        uniqueID = "beammp:" .. tostring(beammpID)
    elseif isGuest and COUNT_GUESTS_AS_UNIQUE then
        -- Guest names are not permanent identities, so this mode is less accurate.
        uniqueID = "guest:" .. tostring(playerName)
    end

    if uniqueID then
        local isNewEver = state.players[uniqueID] == nil
        local now = utcTimestamp()

        if isNewEver then
            state.players[uniqueID] = {
                first_seen = now,
                last_seen = now,
                first_name = tostring(playerName),
                last_name = tostring(playerName),
                joins = 1,
                legacy = false
            }
        else
            local record = state.players[uniqueID]
            if type(record) ~= "table" then
                -- Defensive recovery if an unusual old value survived migration.
                record = {
                    first_seen = "",
                    last_seen = "",
                    first_name = "",
                    last_name = "",
                    joins = 0,
                    legacy = true
                }
                state.players[uniqueID] = record
            end

            record.last_seen = now
            record.last_name = tostring(playerName)
            record.joins = (tonumber(record.joins) or 0) + 1
        end

        markPeriodUser(state.daily, uniqueID, isNewEver)
        markPeriodUser(state.monthly, uniqueID, isNewEver)
        markPeriodUser(state.yearly, uniqueID, isNewEver)
        markMonthlyRetention(uniqueID)
    end

    local keys = periodKeys()
    appendJoinLog(
        utcTimestamp(),
        keys.day,
        keys.month,
        keys.year,
        beammpID or "",
        playerName,
        isGuest
    )

    saveState()

    print(
        "[PlayerCounter] " .. tostring(playerName) ..
        " joined | " .. statsMessage()
    )
end

--------------------------------------------------
-- Chat commands
--------------------------------------------------

function PlayerCounter_OnChatMessage(playerID, playerName, message)
    if not ALLOW_PLAYER_COMMANDS then
        return 0
    end

    if message == "/playerstats" then
        if updatePeriods() then
            saveState()
        end

        MP.SendChatMessage(playerID, statsMessage())
        return 1
    end

    if message == "/retention" then
        if updatePeriods() then
            saveState()
        end

        MP.SendChatMessage(playerID, retentionMessage())
        return 1
    end

    return 0
end

--------------------------------------------------
-- Server console commands
--------------------------------------------------

function PlayerCounter_OnConsoleInput(command)
    if command == "playerstats" then
        if updatePeriods() then
            saveState()
        end
        return statsMessage()
    end

    if command == "retention" then
        if updatePeriods() then
            saveState()
        end
        return retentionMessage()
    end
end

--------------------------------------------------
-- Initialization / shutdown
--------------------------------------------------

function PlayerCounter_OnInit()
    local success, errorMessage = FS.CreateDirectory(DATA_DIR)
    if not success then
        print("[PlayerCounter] ERROR: Could not create data directory: " .. tostring(errorMessage))
        return
    end

    loadState()
    normalizeState()
    migrateV1IfNeeded()
    normalizeState()

    if updatePeriods() then
        print("[PlayerCounter] Calendar period rollover processed on startup.")
    end

    saveState()

    print("[PlayerCounter] PlayerCounter + Retention Analytics loaded.")
    print("[PlayerCounter] " .. statsMessage())
    print("[PlayerCounter] " .. retentionMessage())
end

function PlayerCounter_OnShutdown()
    updatePeriods()
    saveState()
    print("[PlayerCounter] Statistics saved on shutdown.")
end

--------------------------------------------------
-- Register events (BeamMP Server 3.x)
--------------------------------------------------

MP.RegisterEvent("onInit", "PlayerCounter_OnInit")
MP.RegisterEvent("onPlayerJoining", "PlayerCounter_OnPlayerJoining")
MP.RegisterEvent("onChatMessage", "PlayerCounter_OnChatMessage")
MP.RegisterEvent("onConsoleInput", "PlayerCounter_OnConsoleInput")
MP.RegisterEvent("onShutdown", "PlayerCounter_OnShutdown")
