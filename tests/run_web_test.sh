#!/usr/bin/env bash
# End-to-end test of the stats website: discord_status.py pushes to web/public
# (PHP built-in server) and api.php is checked for content and privacy.
# Needs python3, php (7.4+) and curl; with LUA + MOCK_BEAMMP set it also tests the plugin's own upload. Note: the PHP built-in server ignores
# .htaccess, so the "data files are not downloadable" rule is not covered here.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'kill $FAKE $PHPSRV 2>/dev/null; rm -rf "$WORK"' EXIT
SECRET="test-secret-0123456789-abcdefghijklmnop"
cp -r "$HERE/../web/public" "$WORK/site"
rm -rf "$WORK/site/data"
cat > "$WORK/site/config.php" <<PHP
<?php return ['secret' => '$SECRET', 'data_dir' => '$WORK/data', 'site_title' => 'Test stats'];
PHP
cd "$WORK"
python3 "$HERE/fake_panel_discord.py" "$HERE/live_sample.json" & FAKE=$!
php -S 127.0.0.1:8766 -t "$WORK/site" >/dev/null 2>&1 & PHPSRV=$!
while [ ! -f ready ]; do sleep 0.2; done
sleep 0.5
python3 - "$HERE/discord_test_config.json" <<PY
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["website_url"] = "http://127.0.0.1:8766/ingest.php"
cfg["website_secret"] = "$SECRET"
json.dump(cfg, open("cfg.json", "w"))
PY
python3 "$HERE/../discord/discord_status.py" --config cfg.json --once
python3 - "$SECRET" <<'PY'
import hashlib, hmac, json, sys, time, urllib.request, urllib.error
secret = sys.argv[1]
base = "http://127.0.0.1:8766/"
fails = 0
def check(cond, msg):
    global fails
    print(("ok   " if cond else "FAIL ") + msg)
    fails += 0 if cond else 1

api = json.loads(urllib.request.urlopen(base + "api.php").read())
raw = json.dumps(api)
check(len(api["servers"]) == 5, f"5 servers on the page, got {len(api['servers'])}")
by = {s["key"]: s for s in api["servers"]}
check(by["aaaa"]["status"] == "online" and by["aaaa"]["player_count"] == 4, "live server online with 4 players")
check(by["bbbb"]["status"] == "offline", "offline server shown offline")
check(by["cccc"]["status"] == "error" and "live.json" in (by["cccc"]["error"] or ""), "missing plugin shown as not reporting")
check(by["dddd"]["status"] == "error", "stale live.json shown as not reporting")
check("583921" not in raw and "beammp" not in raw and '"pid"' not in raw, "no BeamMP IDs or player ids published")
names = [p["name"] for p in by["aaaa"]["players"]]
check(names[0] == "Leshii413" and "Hilly_*Racing*" in names, "players listed by session length")
watcher = [p for p in by["aaaa"]["players"] if p["name"] == "@everyone"][0]
check(watcher["driving"]["own"] is False and watcher["driving"]["owner"] == "Leshii413", "watching another player kept")
check(any(p["afk"] for p in by["aaaa"]["players"]), "AFK flag kept")
check(len(by["aaaa"]["graph"]["values"]) == 288 and len(by["aaaa"]["heatmap"]) == 168, "graph and heatmap published")
check(by["aaaa"]["calendar_utc_offset_hours"] == 8, "calendar offset published")
s_all = api["series"]["all_time"]
top = s_all[0]
check(top["name"] == "Leshii413" and top["playtime_seconds"] == 2 * 126380 and top["servers"] == 2,
      "series board merges the same BeamMP ID across servers")
check(api["series"]["month"][0]["name"] == "Hilly_*Racing*", "series month board ordered by playtime")
check(by["aaaa"]["leaderboard"]["all_time"][0]["last_seen"] == "2026-10-12", "server board dates trimmed")

def post(body, ts=None, sig=None, key=None):
    ts = str(ts if ts is not None else int(time.time()))
    data = json.dumps(body).encode()
    if sig is None:
        sig = "sha256=" + hmac.new(secret.encode(), ts.encode() + b"." + data, hashlib.sha256).hexdigest()
    req = urllib.request.Request(base + "ingest.php", data=data, method="POST",
                                 headers={"Content-Type": "application/json", "X-PlayerCounter-Timestamp": ts,
                                          "X-PlayerCounter-Signature": sig})
    try:
        return urllib.request.urlopen(req).status
    except urllib.error.HTTPError as e:
        return e.code

good = {"server": {"key": "zz", "name": "Z"}, "panel_state": "offline"}
check(post(good, sig="sha256=" + "0" * 64) == 401, "forged signature rejected")
check(post(good, ts=int(time.time()) - 3600) == 401, "old timestamp rejected")
check(post({"server": {"key": "../x"}}) == 400, "bad server key rejected")
t = int(time.time()) + 5
check(post(good, ts=t) == 200, "valid upload accepted")
check(post(good, ts=t) == 409, "replayed upload rejected")
try:
    urllib.request.urlopen(base + "ingest.php")
    check(False, "GET on ingest rejected")
except urllib.error.HTTPError as e:
    check(e.code == 405, "GET on ingest rejected")
sys.exit(1 if fails else 0)
PY
# The plugin's own upload (data/website.json + curl), if Lua 5.3 and the mock are available.
if [ -n "${MOCK_BEAMMP:-}" ] && command -v "${LUA:-lua5.3}" >/dev/null 2>&1; then
  mkdir -p "$WORK/server/Resources/Server/PlayerCounter"
  cp "$HERE/../main.lua" "$WORK/server/Resources/Server/PlayerCounter/"
  (cd "$WORK/server" && SITE_URL="http://127.0.0.1:8766/ingest.php" SITE_SECRET="$SECRET" \
    MOCK_BEAMMP="$(cd "$(dirname "$MOCK_BEAMMP")" && pwd)/$(basename "$MOCK_BEAMMP")" \
    TZ=UTC "${LUA:-lua5.3}" "$HERE/web_push_test.lua")
else
  echo "(skipping plugin upload test: set LUA and MOCK_BEAMMP)"
fi
echo "OK"
