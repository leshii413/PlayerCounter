-- Daylight-saving calendar (dst "us" / "eu") checked against Python zoneinfo
-- cases in tests/tz_cases.txt (America/Denver = St George, Utah; Europe/London).
MOCK_BEAMMP_AS_LIBRARY = true
local Mock = dofile(assert(os.getenv("MOCK_BEAMMP")))
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$")
local D = "Resources/Server/PlayerCounter/data"
local realTime = os.time
local T = 0
os.time = function(t) if t then return realTime(t) end return T end
local pass, fail = 0, 0
for line in io.lines(HERE .. "/tz_cases.txt") do
    local u, rule, std, off, day = line:match("^(%d+) (%a+) (%-?%d+) (%-?%d+) (%S+)$")
    if u then
        T = tonumber(u)
        os.execute("rm -rf " .. D .. " && mkdir -p " .. D)
        local f = io.open(D .. "/config.json", "w")
        f:write('{"utc_offset_hours": ' .. std .. ', "dst": "' .. rule .. '", "time_zone_name": "Test time"}'); f:close()
        local S = Mock.new({ quiet = true })
        S:loadPlugin("Resources/Server/PlayerCounter"); S:trigger("onInit")
        local live = S.plugins.PlayerCounter.env.Util.JsonDecode(io.open(D .. "/live.json"):read("a"))
        local st = S.plugins.PlayerCounter.env.Util.JsonDecode(io.open(D .. "/stats.json"):read("a"))
        if live.calendar_utc_offset_hours == tonumber(off) and st.daily.key == day and live.calendar_name == "Test time" then
            pass = pass + 1
        else
            fail = fail + 1
            print(string.format("  FAIL %s %s: offset %s (want %s), day %s (want %s)", u, rule,
                tostring(live.calendar_utc_offset_hours), off, st.daily.key, day))
        end
        for _, e in ipairs(S.errors) do print("  plugin error: " .. e); fail = fail + 1 end
    end
end
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
