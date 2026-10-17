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
python3 -c "import json; d=json.load(open('discord.json')); print(d['log']); assert [m for m,_ in d['log']].count('PATCH')==5, 'expected 5 edits'; print('OK')"
