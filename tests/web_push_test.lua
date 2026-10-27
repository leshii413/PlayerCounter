-- The plugin uploads to the stats website by itself (data/website.json, curl).
-- Run by tests/run_web_test.sh with SITE_URL and SITE_SECRET set and the PHP
-- test site running; cwd = a throwaway server root.
MOCK_BEAMMP_AS_LIBRARY = true
local Mock = dofile(assert(os.getenv("MOCK_BEAMMP")))
local P = "Resources/Server/PlayerCounter"
local D = P .. "/data"
local URL, SECRET = assert(os.getenv("SITE_URL")), assert(os.getenv("SITE_SECRET"))

local pass, fail = 0, 0
local function expect(c, m) if c then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. m) end end
local function sh(cmd) local f = io.popen(cmd); local out = f:read("a"); f:close(); return out end
local function api() return sh("curl -s " .. URL:gsub("ingest%.php$", "api.php")) end
local function sleep(s) os.execute("sleep " .. s) end

os.execute("rm -rf " .. D .. " && mkdir -p " .. D)
local f = io.open(D .. "/website.json", "w")
f:write('{"url": "' .. URL .. '", "secret": "' .. SECRET .. '"}')
f:close()

local S = Mock.new({ quiet = os.getenv("V") == nil, maxCars = 3 })
S.settings[5] = "^l^4Baja75 ^7Series #9 TEST"   -- server name with BeamMP colour codes
S:loadPlugin(P); S:trigger("onInit")
local logs = table.concat(S.log, "\n")
expect(logs:find('Website uploads on: ' .. URL .. ' as "Baja75 Series #9 TEST" (key baja75-series-9-test)', 1, true),
    "uploads enabled with a key from the server name")
sleep(6)                                          -- joins/leaves upload at most every 5 s
local a = S:join("Ana", { beammp = "31" })
S:spawn(a, "pickup", { 0, 0, 0 })
for _ = 1, 3 do S:advance(30000) end              -- 90 s of ticks (interval 60 s -> one more push)
sleep(2)
local out = api()
expect(out:find('"key":"baja75-series-9-test"', 1, true), "server appears on the site")
expect(out:find('"status":"online"', 1, true) and out:find('"name":"Ana"', 1, true), "online with the live player")
expect(not out:find('"31"', 1, true), "BeamMP ID not published")
S:advance(30000); sleep(1)
expect(table.concat(S.log, "\n"):find("Website upload OK.", 1, true), "plugin logs a successful upload")

S:trigger("onShutdown"); sleep(1)
out = api()
expect(out:find('"status":"offline"', 1, true), "shutdown marks the server offline on the site")

-- wrong secret: the site rejects it and the plugin says so in the console
f = io.open(D .. "/website.json", "w")
f:write('{"url": "' .. URL .. '", "secret": "wrong-secret-0123456789-abcdefgh", "server_key": "badkey"}')
f:close()
S = Mock.new({ quiet = os.getenv("V") == nil })
S:loadPlugin(P); S:trigger("onInit"); sleep(2)
S:advance(30000)
expect(table.concat(S.log, "\n"):find("website upload failed (HTTP 401): ", 1, true), "bad secret reported in the console")

-- invalid settings never reach the shell
f = io.open(D .. "/website.json", "w")
f:write([[{"url": "https://x.example/ingest.php'; touch /tmp/pc_pwned; '", "secret": "]] .. SECRET .. [["}]])
f:close()
S = Mock.new({ quiet = true }); S:loadPlugin(P); S:trigger("onInit")
expect(table.concat(S.log, "\n"):find("url must look like", 1, true), "suspicious url refused")
local pwned = io.open("/tmp/pc_pwned"); expect(pwned == nil, "no command injection"); if pwned then pwned:close() end

for _, e in ipairs(S.errors) do print("  plugin error: " .. e); fail = fail + 1 end
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
