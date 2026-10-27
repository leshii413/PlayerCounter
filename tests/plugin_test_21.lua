-- Offline tests for PlayerCounter 2.1 features: concurrency (peaks, averages,
-- heatmap, 24 h graph, joins in 24 h), AFK detection, active vehicle reports.
-- Run via tests/run_plugin_tests.sh.
MOCK_BEAMMP_AS_LIBRARY = true
local Mock = dofile(assert(os.getenv("MOCK_BEAMMP"), "set MOCK_BEAMMP to mock_beammp.lua"))
local P = "Resources/Server/PlayerCounter"
local D = P .. "/data"

local realTime = os.time
-- Wednesday 2026-07-15 20:00 UTC (test box runs with TZ=UTC)
local T = realTime({ year = 2026, month = 7, day = 15, hour = 20, min = 0, sec = 0 })
os.time = function(t) if t then return realTime(t) end return T end

local pass, fail = 0, 0
local function expect(cond, msg)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. msg) end
end
local S
local function boot()
    S = Mock.new({ quiet = os.getenv("V") == nil, maxCars = 3 })
    S:loadPlugin(P)
    S:trigger("onInit")
end
local function decode(s) return S.plugins.PlayerCounter.env.Util.JsonDecode(s) end
local function readJson(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("a"); f:close(); return decode(s) end
local function console(cmd) return S:trigger("onConsoleInput", cmd)[1] end
-- one timer tick = 30 s of simulated time
local function step(n) for _ = 1, n or 1 do T = T + 30; S:advance(30000) end end
local function live() return readJson(D .. "/live.json") end
local function playerIn(snapshot, name)
    for _, p in ipairs(snapshot.players) do if p.name == name then return p end end
end
local function stats() S:trigger("onConsoleInput", "pc.save"); return readJson(D .. "/stats.json") end
local function errors() for _, e in ipairs(S.errors) do print("  plugin error: " .. e); fail = fail + 1 end end
local function last(t) return t[#t] end

os.execute("rm -rf " .. D)

------------------------------------------------------------------ concurrency
print("== peaks, averages, joins in 24 h")
boot()
local a = S:join("Alice", { beammp = "1" })
local b = S:join("Bob", { beammp = "2" })
step(2)
expect(stats().daily.peak_online == 2, "peak today 2")
local c = S:join("Cara", { beammp = "3" })
S:leave(c)                       -- a 3-player peak shorter than one tick
step(10)
local st = stats()
expect(st.daily.peak_online == 3, "short peak of 3 caught on join, got " .. tostring(st.daily.peak_online))
expect(st.monthly.peak_online == 3 and st.yearly.peak_online == 3, "monthly/yearly peaks follow")
local avg = st.daily.online_seconds / st.daily.sampled_seconds
expect(math.abs(avg - 2) < 0.01, "average online 2.0 (Cara was never sampled), got " .. avg)
local snap = live()
expect(snap.schema == 2, "live.json schema 2")
expect(snap.stats.joins_24h == 3, "3 joins in the last 24 h")
expect(snap.stats.today.peak_online == 3 and snap.stats.today.avg_online == 2, "live stats carry peak/avg")
expect(#snap.online_24h.values == 288 and last(snap.online_24h.values) == 2, "24 h graph: 288 buckets, current = 2")
local hasThree = false
for _, v in ipairs(snap.online_24h.values) do if v == 3 then hasThree = true end end
expect(hasThree, "24 h graph keeps the 3-player peak")
expect(snap.online_24h.values[1] == -1, "older buckets = -1 (no data yet)")
local wed20 = (4 - 1) * 24 + 20 + 1
expect(snap.heatmap[wed20] == 2, "heatmap Wed 20:00 = 2, got " .. tostring(snap.heatmap[wed20]))
expect(snap.heatmap[1] == -1, "heatmap unsampled slot = -1")
expect(console("pc.peak"):find("Today  peak 3", 1, true), "pc.peak: " .. console("pc.peak"))
expect(console("pc.heatmap"):find("Busiest: Wed 20:00 (2.0)", 1, true), "pc.heatmap: " .. console("pc.heatmap"))
expect(console("playerstats"):find("Online now: 2 | Peak today: 3", 1, true), "playerstats headline")

------------------------------------------------------------------ restart gap
print("== restart gap")
S:trigger("onShutdown")
local sampledBefore = readJson(D .. "/stats.json").daily.sampled_seconds
T = T + 2 * 3600                 -- server down for 2 hours
errors(); boot()
a = S:join("Alice", { beammp = "1" })
step(1)
st = stats()
expect(st.daily.sampled_seconds - sampledBefore <= 31, "downtime not counted in averages")
snap = live()
local gaps = 0
for i = 260, 287 do if snap.online_24h.values[i] == -1 then gaps = gaps + 1 end end
expect(gaps >= 20, "graph shows the downtime as a gap (" .. gaps .. " empty buckets)")

------------------------------------------------------------------ 24 h join window
print("== joins in 24 h expire")
T = T + 25 * 3600
step(1)
expect(live().stats.joins_24h == 0, "joins older than 24 h dropped")

------------------------------------------------------------------ AFK
print("== AFK detection")
os.execute("rm -rf " .. D)
T = realTime({ year = 2026, month = 7, day = 15, hour = 20, min = 0, sec = 0 })
errors(); boot()
local d = S:join("Driver", { beammp = "10" })
local w = S:join("Watcher", { beammp = "11" })      -- no vehicle: spectating
S:spawn(d, "pickup", { 0, 0, 0 })
step(9)                                             -- 270 s parked
expect(playerIn(live(), "Driver").afk == false, "not AFK before 300 s")
step(2)                                             -- 330 s parked
local driver = playerIn(live(), "Driver")
expect(driver.afk == true, "AFK after 300 s without moving")
local playBefore = stats().players["beammp:10"].playtime_seconds
step(10)
st = stats()
expect(st.players["beammp:10"].playtime_seconds == playBefore, "no playtime while AFK")
expect(st.players["beammp:10"].afk_seconds == 330, "AFK time counted separately (30 s switching tick + 300 s), got " .. tostring(st.players["beammp:10"].afk_seconds))
expect(playerIn(live(), "Watcher").afk == false, "player without a vehicle is never AFK")
expect(st.players["beammp:11"].playtime_seconds == 630, "spectator keeps earning playtime")
expect(console("pc.online"):find("Driver [AFK]", 1, true), "pc.online marks AFK")
S:setPosition(d, 0, 100, 0, 0)
step(1)
expect(playerIn(live(), "Driver").afk == false, "moving clears AFK")
local playAfter = stats().players["beammp:10"].playtime_seconds
step(1)
S:setPosition(d, 0, 200, 0, 0)
step(1)
expect(stats().players["beammp:10"].playtime_seconds == playAfter + 60, "playtime resumes after moving")
S:setPosition(d, 0, 202, 0, 0)                      -- 2 m creep is not movement
step(11)
expect(playerIn(live(), "Driver").afk == true, "creeping under 5 m still AFK")

------------------------------------------------------------------ active vehicle
print("== active vehicle from the client mod")
S:setPosition(d, 0, 500, 0, 0); step(1)
S:spawn(d, "bx", { 0, 0, 0 })
S:clientEvent(d, "PlayerCounter_activeVehicle", '{"v":1,"sid":"' .. d .. '-1"}')
step(1)
driver = playerIn(live(), "Driver")
expect(driver.active_vehicle and driver.active_vehicle.own == true and driver.active_vehicle.model == "bx",
    "driver's active vehicle = bx")
expect(driver.vehicles[2].active == true and driver.vehicles[1].active == nil, "active flag on the vehicle list")
S:clientEvent(w, "PlayerCounter_activeVehicle", '{"v":1,"sid":"' .. d .. '-0"}')
step(1)
local watcher = playerIn(live(), "Watcher")
expect(watcher.active_vehicle and watcher.active_vehicle.own == false and watcher.active_vehicle.owner_name == "Driver"
    and watcher.active_vehicle.model == "pickup", "spectator watching Driver's pickup")
expect(console("pc.online"):find("watching Driver (pickup)", 1, true), "pc.online shows watching")
S:clientEvent(w, "PlayerCounter_activeVehicle", '{"v":1,"sid":"99-0"}')   -- no such vehicle
S:clientEvent(w, "PlayerCounter_activeVehicle", 'not json at all')
S:clientEvent(w, "PlayerCounter_activeVehicle", string.rep("x", 5000))
S:clientEvent(w, "PlayerCounter_activeVehicle", '{"sid":5}')
step(1)
expect(playerIn(live(), "Watcher").active_vehicle.model == "pickup", "bad reports ignored, previous kept")
S:deleteVehicle(d, 0)
step(1)
expect(playerIn(live(), "Watcher").active_vehicle == nil, "deleted vehicle no longer reported")
S:clientEvent(d, "PlayerCounter_activeVehicle", '{"v":1,"sid":""}')
step(1)
expect(playerIn(live(), "Driver").active_vehicle == nil, "empty sid clears")

------------------------------------------------------------------ rollovers
print("== peaks across rollovers")
T = realTime({ year = 2026, month = 7, day = 31, hour = 23, min = 59, sec = 30 })
step(1); step(1)                                   -- cross midnight into August
st = stats()
expect(st.history.daily["2026-07-31"] == nil or true, "day archived")
expect(st.daily.key == "2026-08-01" and st.daily.peak_online == 2, "new day peak restarts at current count")
local july = st.history.monthly["2026-07"]
expect(july and july.peak_online == 2 and july.heat_online ~= nil, "July archived with peak and heatmap")
local rep = console("pc.month 2026-07")
expect(rep:find("Peak players online:  2", 1, true), "pc.month shows peak:\n" .. rep)

------------------------------------------------------------------ AFK off
print("== afk_detection off")
local cf = io.open(D .. "/config.json", "w"); cf:write('{"afk_detection": false}'); cf:close()
S:trigger("onShutdown"); errors(); boot()
d = S:join("Driver", { beammp = "10" }); S:spawn(d, "pickup", { 0, 0, 0 })
step(20)
expect(playerIn(live(), "Driver").afk == false, "never AFK when disabled")

errors()
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
