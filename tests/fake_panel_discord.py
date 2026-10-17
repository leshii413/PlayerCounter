# Fake Pterodactyl client API + fake Discord webhook on 127.0.0.1:8765 for testing discord_status.py.
# Usage: python3 fake_panel_discord.py live_sample.json  (writes ./discord.json with received messages)
import json, sys, time, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
live = json.load(open(sys.argv[1]))
now = int(time.time())
live["updated_unix"] = now - 20
for p in live["players"] if isinstance(live["players"], list) else []:
    p["session_seconds"] = {"Leshii413": 4380, "Hilly_*Racing*": 600}.get(p["name"], 60)
    if p.get("total_playtime_seconds") is not None: p["total_playtime_seconds"] = p["session_seconds"] + 122000
stale = dict(live, updated_unix=now - 900)
STATE = {"msgs": {}, "log": [], "fail429": 1}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body):
        b = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u = urllib.parse.urlsplit(self.path); q = urllib.parse.parse_qs(u.query)
        assert self.headers["Authorization"] == "Bearer ptlc_test", self.headers
        parts = u.path.split("/")  # /api/client/servers/<id>/<what>
        sid, what = parts[4], parts[5]
        if sid == "denied": return self.send(403, {"errors": []})
        states = {"aaaa": "running", "bbbb": "offline", "cccc": "running", "dddd": "running"}
        if what == "resources": return self.send(200, {"attributes": {"current_state": states[sid], "resources": {"uptime": 3*3600*1000}}})
        if what == "files":
            assert q["file"] == ["/Resources/Server/PlayerCounter/data/live.json"], q
            if sid == "cccc": return self.send(404, {"errors": []})
            return self.send(200, json.dumps(stale if sid == "dddd" else live))
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert "wait=true" in self.path
        if STATE["fail429"]:
            STATE["fail429"] -= 1; return self.send(429, {"retry_after": 0.2})
        STATE["n"] = STATE.get("n", 999) + 1; mid = str(STATE["n"]); STATE["msgs"][mid] = body
        STATE["log"].append(("POST", mid)); self.send(200, {"id": mid})
    def do_PATCH(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        mid = self.path.split("/messages/")[1].split("?")[0]
        if mid not in STATE["msgs"]: return self.send(404, {"message": "Unknown Message"})
        STATE["msgs"][mid] = body; STATE["log"].append(("PATCH", mid)); self.send(200, {"id": mid})
    def do_DELETE(self):
        mid = self.path.split("/messages/")[1]; STATE["msgs"].pop(mid, None); self.send(204, "")
srv = ThreadingHTTPServer(("127.0.0.1", 8765), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
json.dump({}, open("ready", "w"))
while True:
    time.sleep(0.2)
    open("discord.json", "w").write(json.dumps({"msgs": STATE["msgs"], "log": STATE["log"]}, ensure_ascii=False))
