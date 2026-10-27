-- PlayerCounter client mod (BeamNG GE Lua, LuaJIT). Extension: playerCounter_client
-- License: GPL-3.0, part of https://github.com/leshii413/PlayerCounter
--
-- Tells the PlayerCounter server plugin which vehicle this player is driving or
-- watching, so the live status can show the real current vehicle instead of
-- every vehicle the player has spawned. That is all it does: no UI, no input,
-- no other data. It sends only when the vehicle changes (checked every 2 s)
-- and repeats the current value once a minute in case the server restarted.
--
-- Payload: {"v":1,"sid":"<owner player id>-<vehicle id>"}, or "sid":"" when the
-- player is not in or viewing any multiplayer vehicle.

local M = {}

local EVENT = "PlayerCounter_activeVehicle"
local CHECK_EVERY = 2      -- seconds between checks
local RESEND_EVERY = 60    -- seconds before repeating an unchanged value

local lastSent = nil
local sinceCheck = 0
local sinceSend = 0

local function inSession()
  return MPCoreNetwork ~= nil and MPCoreNetwork.isMPSession ~= nil and MPCoreNetwork.isMPSession()
    and TriggerServerEvent ~= nil and MPVehicleGE ~= nil
end

-- Server id ("pid-vid") of the vehicle the camera is on, "" for none, or nil
-- while a just-spawned vehicle has not been given a server id yet.
local function currentServerVehicle()
  local veh = getPlayerVehicle(0)
  if not veh then
    return ""
  end
  local sid = MPVehicleGE.getServerVehicleID(veh:getID())
  if type(sid) ~= "string" or not sid:match("^%d+%-%d+$") then
    return nil
  end
  return sid
end

local function send(sid)
  TriggerServerEvent(EVENT, jsonEncode({ v = 1, sid = sid }))
  lastSent = sid
  sinceSend = 0
end

local function check(force)
  if not inSession() then
    return
  end
  local sid = currentServerVehicle()
  if sid == nil then
    return
  end
  if force or sid ~= lastSent or sinceSend >= RESEND_EVERY then
    send(sid)
  end
end

local function onUpdate(dtReal)
  sinceCheck = sinceCheck + (dtReal or 0)
  sinceSend = sinceSend + (dtReal or 0)
  if sinceCheck >= CHECK_EVERY then
    sinceCheck = 0
    check(false)
  end
end

local function onVehicleSwitched()
  sinceCheck = CHECK_EVERY -- check on the next frame
end

local function onBeamMPPostJoin()
  lastSent = nil
  sinceCheck = CHECK_EVERY
end

local function onBeamMPServerLeave()
  lastSent = nil
end

M.onUpdate = onUpdate
M.onVehicleSwitched = onVehicleSwitched
M.onBeamMPPostJoin = onBeamMPPostJoin
M.onBeamMPServerLeave = onBeamMPServerLeave
M.check = check
return M
