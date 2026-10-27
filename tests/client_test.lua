-- Unit test for client/lua/ge/extensions/playerCounter/client.lua with the
-- game and BeamMP functions stubbed. Run with LuaJIT (the game's Lua):
--   luajit tests/client_test.lua client/lua/ge/extensions/playerCounter/client.lua
local sent = {}
local camera = nil            -- game vehicle id the camera is on, or nil
local serverIds = {}          -- game id -> "pid-vid"
local mp = true
MPCoreNetwork = { isMPSession = function() return mp end }
MPVehicleGE = { getServerVehicleID = function(gid) return serverIds[gid] end }
TriggerServerEvent = function(name, data) sent[#sent + 1] = { name = name, data = data } end
jsonEncode = function(t) return string.format('{"v":%d,"sid":"%s"}', t.v, t.sid) end
getPlayerVehicle = function() if camera then return { getID = function() return camera end } end end

local M = dofile(arg[1])
local pass, fail = 0, 0
local function expect(c, m) if c then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. m) end end
local function run(seconds) for _ = 1, seconds * 10 do M.onUpdate(0.1) end end

M.onBeamMPPostJoin(); run(1)
expect(#sent == 1 and sent[1].data == '{"v":1,"sid":""}', "on foot reported after joining")
run(10)
expect(#sent == 1, "nothing resent while unchanged")
camera = 5000; run(3)
expect(#sent == 1, "waits while the new vehicle has no server id")
serverIds[5000] = "3-0"; run(3)
expect(#sent == 2 and sent[2].name == "PlayerCounter_activeVehicle" and sent[2].data == '{"v":1,"sid":"3-0"}',
  "own vehicle reported once synced")
camera = 6000; serverIds[6000] = "7-2"; M.onVehicleSwitched(); M.onUpdate(0.01)
expect(#sent == 3 and sent[3].data:find('"7-2"', 1, true), "switch to another player's car reported immediately")
run(61)
expect(#sent == 4 and sent[4].data:find('"7-2"', 1, true), "unchanged value repeated once a minute")
mp = false; camera = 5000; run(5)
expect(#sent == 4, "silent in single-player")
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
