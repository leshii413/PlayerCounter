-- Offline tests for PlayerCounter under the BeamMP server mock (Lua 5.3).
-- Run via tests/run_plugin_tests.sh, which builds a throwaway server root.
MOCK_BEAMMP_AS_LIBRARY = true
local Mock = dofile(assert(os.getenv("MOCK_BEAMMP"), "set MOCK_BEAMMP to mock_beammp.lua"))
local P = "Resources/Server/PlayerCounter"
local D = P .. "/data"

local realTime = os.time
local T = realTime({ year = 2026, month = 7, day = 10, hour = 12, min = 0, sec = 0 }) -- local tz of box is UTC
os.time = function(t) if t then return realTime(t) end return T end

local pass, fail = 0, 0
local function expect(cond, msg)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. msg) end
end
local function readAll(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("a"); f:close(); return s end
local function json(p) local s = readAll(p); return s and Util_decode(s) end
local S
local function boot()
    S = Mock.new({ quiet = os.getenv("V") == nil, maxCars = 3 })
    S:loadPlugin(P)
    S:trigger("onInit")
    return S
end
function Util_decode(s) return S.plugins.PlayerCounter.env.Util.JsonDecode(s) end
local function console(cmd) return S:trigger("onConsoleInput", cmd)[1] end
-- Advances the clock one 30 s timer tick at a time, like a real server.
-- Every spawned vehicle is nudged 10 m per tick so players count as driving
-- (AFK behaviour has its own tests in plugin_test_21.lua).
local function tick(seconds)
    for _ = 1, math.max(1, seconds // 30) do
        T = T + 30
        for _, p in pairs(S.players) do
            for _, v in pairs(p.vehicles) do v.pos[1] = v.pos[1] + 10 end
        end
        S:advance(30000)
    end
end
local function wipe() os.execute("rm -rf " .. D) end
local function errors() for _, e in ipairs(S.errors) do print("  plugin error: " .. e); fail = fail + 1 end end

------------------------------------------------------------------ fresh install
print("== fresh install")
wipe(); boot()
expect(readAll(D .. "/config.json") ~= nil, "config.json created")
expect(readAll(D .. "/stats.json") ~= nil, "stats.json created")
local live = json(D .. "/live.json")
expect(live and live.state == "running" and live.player_count == 0, "live.json written with 0 players")
expect(#S.timers == 1, "one tick timer created, got " .. #S.timers)

------------------------------------------------------------------ joins
print("== joins, guests, checker")
local a = S:join("Alice", { beammp = "101" })
local b = S:join("Bob", { beammp = "102" })
S:leave(b); b = S:join("Bob", { beammp = "102" })     -- reconnect
local g = S:join("guest123", { guest = true, beammp = "" })
local chk = S:join("CHK_BMP", { beammp = "" }); S:leave(chk)
local stats = console("playerstats")
expect(stats:find("Today: 2 unique, 2 new, 0 returning, 4 joins", 1, true), "daily counts: " .. stats)
expect(stats:find("All%-time: 2 unique, 4 joins"), "all-time counts")
expect(console("playerstats  ") == stats, "console command tolerates trailing spaces")
local st = json(D .. "/stats.json")
expect(st.daily.guest_joins == 1, "guest join counted")

------------------------------------------------------------------ playtime + live + vehicles
print("== playtime, live.json, vehicles")
S:spawn(a, "pickup", { 0, 0, 0 })
S:spawn(a, "cones", { 0, 0, 0 })
tick(3600)
live = json(D .. "/live.json")
expect(live.player_count == 3, "live count 3 (alice, bob, guest), got " .. tostring(live.player_count))
local alice
for _, p in ipairs(live.players) do if p.name == "Alice" then alice = p end end
expect(alice and alice.session_seconds == 3600, "alice session 3600s")
expect(alice and alice.total_playtime_seconds == 3600, "alice total 3600s")
expect(alice and #alice.vehicles == 2 and alice.vehicles[1].model == "pickup" and alice.vehicles[1].config == "base",
    "alice vehicles parsed")
expect(live.server.map == "gridmap_v2" and live.server.max_players == 8, "server info in live.json")
S:chat(a, "/playtime")
expect(S:lastChatTo(a):find("Session: 1h 00m | Total playtime: 1h 00m | Joins: 1", 1, true), "/playtime reply: " .. tostring(S:lastChatTo(a)))
tick(1800); S:leave(a)
st = json(D .. "/stats.json")
expect(st.players["beammp:101"].playtime_seconds == 5400, "alice playtime 5400 after leaving, got " ..
    tostring(st.players["beammp:101"].playtime_seconds))
local top = console("pc.top 5")
expect(top:find("Alice - 1h 30m", 1, true), "pc.top: " .. top)

------------------------------------------------------------------ chat commands
print("== chat commands")
local n0 = #S.chatLog
expect(S:chat(b, "/playerstats") == false, "/playerstats is not broadcast")
expect(#S.chatLog - n0 == 6, "/playerstats sends 6 short lines")
expect(S:chat(b, "  /Retention ") == false, "/Retention handled case/space-insensitively")
expect(S:chat(b, "hello") == true, "normal chat untouched")

------------------------------------------------------------------ CSV safety
print("== joins.csv")
local evil = S:join('=HYPERLINK("http://x","hi")', { beammp = "103" })
local lastLine; for l in io.lines(D .. "/joins.csv") do lastLine = l end
expect(lastLine:find(",\"'=HYPERLINK", 1, true), "formula name neutralised: " .. lastLine)
S:leave(evil)

------------------------------------------------------------------ shutdown/restart keeps playtime, live says stopped
print("== shutdown + restart")
tick(600)
S:trigger("onShutdown")
live = json(D .. "/live.json")
expect(live.state == "stopped" and live.player_count == 0, "live.json marks server stopped")
local bobBefore = json(D .. "/stats.json").players["beammp:102"].playtime_seconds
expect(bobBefore == 6000, "bob credited until shutdown (3600+1800+600), got " .. tostring(bobBefore))
errors(); boot()
expect(console("playerstats"):find("All%-time: 3 unique"), "restart keeps data")

------------------------------------------------------------------ crash recovery
print("== crash recovery")
local before = console("playerstats")
local s = readAll(D .. "/stats.json")
local f = io.open(D .. "/stats.json", "wb"); f:write(s:sub(1, #s // 2)); f:close()
errors(); boot()
local after = console("playerstats")
expect(after:find("All%-time: %d+ unique") and not after:find("All%-time: 0 unique"), "data recovered from .bak: " .. after)
local corrupt = io.popen("ls " .. D .. " | grep -c corrupt"):read("a")
expect(tonumber(corrupt) == 1, "damaged file kept as .corrupt copy")
-- interrupted save: main missing, tmp present
os.rename(D .. "/stats.json", D .. "/stats.json.tmp")
errors(); boot()
expect(console("playerstats"):find("All%-time: 0 unique") == nil, "recovered from .tmp after interrupted save")

------------------------------------------------------------------ rollovers + retention
print("== rollovers and retention")
wipe()
T = realTime({ year = 2026, month = 7, day = 31, hour = 23, min = 50, sec = 0 })
errors(); boot()
for i = 1, 4 do local p = S:join("J" .. i, { beammp = tostring(200 + i) }); S:leave(p) end
tick(20 * 60)  -- past midnight into Aug 1 with nobody joining: timer archives the day
st = json(D .. "/stats.json")
expect(st.history.daily["2026-07-31"] and st.history.daily["2026-07-31"].unique_users == 4, "Jul 31 archived by timer")
expect(st.history.monthly["2026-07"] and st.history.monthly["2026-07"].unique_users == 4, "July archived")
expect(st.monthly.previous_key == "2026-07", "August cohort compares against July")
local j1 = S:join("J1", { beammp = "201" }); local j2 = S:join("J2", { beammp = "202" }); local nw = S:join("New", { beammp = "300" })
local r = console("retention")
expect(r:find("2026-07 -> 2026-08: 2 of 4 returned (50.0%)", 1, true), "retention 2/4: " .. r)
S:leave(j1); S:leave(j2); S:leave(nw)
T = realTime({ year = 2026, month = 9, day = 2, hour = 10, min = 0, sec = 0 }); tick(30)
st = json(D .. "/stats.json")
expect(st.history.monthly["2026-08"].retention_rate == 50, "August archived with 50% retention")
expect(st.history.monthly["2026-08"].users ~= nil and st.history.monthly["2026-07"].users == nil, "July membership pruned, August kept")
local rep = console("pc.month 2026-08")
expect(rep:find("Unique players:       3", 1, true) and rep:find("Monthly retention:    50.0%", 1, true), "pc.month report:\n" .. rep)
expect(console("pc.month 1999-01"):find("No archived data"), "pc.month unknown month")
-- skipped month: jump to November -> October missing -> N/A
T = realTime({ year = 2026, month = 11, day = 5, hour = 10, min = 0, sec = 0 }); tick(30)
expect(console("retention"):find("cohort unavailable", 1, true), "retention N/A after a missing month")
expect(json(D .. "/stats.json").history.yearly["2026"] == nil, "year not archived yet")
T = realTime({ year = 2027, month = 1, day = 1, hour = 0, min = 5, sec = 0 }); tick(30)
expect(json(D .. "/stats.json").history.yearly["2026"].unique_users == 5, "2026 archived on new year")

------------------------------------------------------------------ admins mode + offset
print("== config: admins mode, offset warning")
local cf = io.open(D .. "/config.json", "w")
cf:write('{"utc_offset_hours": 8, "player_commands": "admins", "admin_beammp_ids": [201]}'); cf:close()
errors(); boot()
local warned = false
for _, l in ipairs(S.log) do if l:find("data was collected with 0") then warned = true end end
expect(warned, "warns when offset differs from recorded one")
local adm = S:join("J1", { beammp = "201" }); local usr = S:join("J3", { beammp = "203" })
S:chat(usr, "/playerstats")
expect(S:lastChatTo(usr):find("for server admins"), "non-admin refused")
S:chat(adm, "/playerstats")
expect(S:lastChatTo(adm):find("All%-time"), "admin allowed")

------------------------------------------------------------------ hot reload with players online
print("== hot reload")
local oldPlayers = S.players
local S2 = Mock.new({ quiet = true }); S2.players = oldPlayers; S2.nextPid = S.nextPid
S = S2; S:loadPlugin(P); S:trigger("onInit")
live = json(D .. "/live.json")
expect(live.player_count == 2 and live.players[1].session_resumed == true, "sessions resumed after reload")
tick(120)
expect(json(D .. "/stats.json").players["beammp:203"].playtime_seconds >= 120, "resumed sessions earn playtime")

------------------------------------------------------------------ V1 migration
print("== V1 migration")
wipe(); os.execute("mkdir -p " .. D)
cf = io.open(D .. "/stats.json", "w"); cf:write('{"all_users":{"beammp:1":true,"beammp:2":true},"total_joins":57}'); cf:close()
errors(); boot()
local m = console("playerstats")
expect(m:find("All%-time: 2 unique, 57 joins"), "V1 data migrated: " .. m)
local v1 = S:join("Old", { beammp = "1" })
expect(console("playerstats"):find("Today: 1 unique, 0 new, 1 returning"), "V1 player counts as returning")
errors()

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
