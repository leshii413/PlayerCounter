#!/usr/bin/env bash
# End-to-end test of discord/discord_status.py against a fake panel + fake Discord.
# Expected: 5 POSTs on the first run, 5 PATCHes (edits in place) on the second.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'kill $FAKE 2>/dev/null; rm -rf "$WORK"' EXIT
cp "$HERE/discord_test_config.json" "$WORK/cfg.json"
cd "$WORK"
python3 "$HERE/fake_panel_discord.py" "$HERE/live_sample.json" & FAKE=$!
while [ ! -f ready ]; do sleep 0.2; done
python3 "$HERE/../discord/discord_status.py" --config cfg.json --once
python3 "$HERE/../discord/discord_status.py" --config cfg.json --once
sleep 0.5
python3 - <<'PY'
import json
d = json.load(open("discord.json"))
print(d["log"])
assert [m for m, _ in d["log"]].count("PATCH") == 5, "expected 5 edits"
graphs = {e["embeds"][0]["title"]: m.get("_png_bytes") for e, m in ((m, m) for m in d["msgs"].values())}
running = [t for t in graphs if "Baja75" in t or "Stale" in t]
assert all(graphs[t] for t in running), f"running servers carry a graph: {graphs}"
assert not any(graphs[t] for t in graphs if "Offline" in t or "No Plugin" in t), "no graph without data"
desc = [m for m in d["msgs"].values() if "Baja75" in m["embeds"][0]["title"]][0]["embeds"][0]["description"]
assert "Last 24 h: peak" in desc and "<t:" in desc, desc
assert "watching Leshii413" in desc and "AFK" in desc, desc
print("OK")
PY
