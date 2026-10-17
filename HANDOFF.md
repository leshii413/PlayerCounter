# PlayerCounter: session handoff

> **Read this first** if you are a new Claude session (or a person) taking over.
> It is the single source of truth for the project's current state. The full
> prompt-by-prompt history is in [`docs/SESSION_LOG.md`](docs/SESSION_LOG.md).
> **Update both files in the same commit as any change you push** (rules in [`CLAUDE.md`](CLAUDE.md)).

Last updated: 2026-10-18 (session 1, Claude Code cloud session `session_01YMAAefrrzE187RmbqyseJo`)

## 1. What this project is

A BeamMP Server 3.x **server-side Lua plugin** (`main.lua`) by Leshii413 that tracks player analytics for BeamMP servers: unique players, join sessions, new/returning players, month-over-month retention and (since 2.0.1) playtime. It also writes a live snapshot of who is online, which a separate Python script (`discord/discord_status.py`) turns into a live Discord status message per server.

- Repo: https://github.com/leshii413/PlayerCounter (public, GPL-3.0)
- Owner's servers: BeamMP servers hosted on **Pterodactyl** (BAJA75SERIES off-road racing community; BeamJoy Revived is the race engine on those servers).
- claude.ai Project: "Player Counter v2.0.1" (this file is mirrored there as `PlayerCounter/HANDOFF.md`).

## 2. Current state

| Item | State |
|---|---|
| `main` on GitHub | Still the original 2.0.0 code (commit `d878b57`). |
| Branch `playercounter-2.0.1` | All 2.0.1 work + this handoff. |
| Pull request | **#2** https://github.com/leshii413/PlayerCounter/pull/2, open, waiting for the owner to review/merge. |
| Plugin version | 2.0.1 (in `main.lua` `PLUGIN_VERSION`). |
| Tested offline | Yes: 45/45 plugin checks (BeamMP mock, Lua 5.3); Discord script end to end vs fake panel + fake Discord. |
| Tested live | **No.** Never run on a real BeamMP server, Pterodactyl panel or Discord. First live test is the top open item. |

## 3. File map

```text
main.lua                         the plugin (install at Resources/Server/PlayerCounter/main.lua)
discord/discord_status.py        Pterodactyl -> Discord live status (Python 3.8+, stdlib only)
discord/discord_status.example.json   config template (copy to discord_status.json, git-ignored)
tests/plugin_test.lua            45 offline checks for main.lua
tests/run_plugin_tests.sh        runner: LUA=lua5.3 MOCK_BEAMMP=/path/mock_beammp.lua tests/run_plugin_tests.sh
tests/fake_panel_discord.py      fake Pterodactyl client API + fake Discord webhook (127.0.0.1:8765)
tests/run_discord_test.sh        end-to-end test of discord_status.py (expects 5 POST then 5 PATCH)
tests/live_sample.json           realistic live.json produced by the plugin under the mock
tests/discord_test_config.json   config pointing discord_status.py at the fake server
README.md                        user docs (rewritten in 2.0.1)
CHANGELOG.md                     release notes
Full Installation Guide          long setup guide (no extension; sections 17, 18, 33, 37 updated in 2.0.1)
BEFORE YOU DOWNLOAD              owner's note asking downloaders for feedback
HANDOFF.md / docs/SESSION_LOG.md / CLAUDE.md   handoff system (this)
.gitignore                       keeps discord_status.json (secrets) and state files out of git
```

Runtime data written by the plugin (on the BeamMP server, never in this repo):

```text
Resources/Server/PlayerCounter/data/
  config.json        settings (created on first start)
  stats.json         analytics database (schema_version 2)
  stats.json.bak     previous save, used for recovery
  stats.json.corrupt-<date>   kept copy if stats.json was unreadable
  joins.csv          raw join log (V1-compatible columns)
  live.json          online snapshot, rewritten every live_interval_seconds (default 30)
```

## 4. How it works (architecture)

**Plugin (`main.lua`, Lua 5.3 inside BeamMP-Server):**
- Events: `onInit`, `onPlayerJoining` (counts the join, starts a session), `onPlayerDisconnect` (credits playtime), `onChatMessage` (`/playerstats`, `/retention`, `/playtime`), `onConsoleInput` (`playerstats`, `retention`, `pc.*`), `onShutdown`. Handlers are global functions named `PlayerCounter_*`.
- One timer, `PlayerCounter_Tick`, every `live_interval_seconds`: calendar rollover, `reconcileSessions()` (rebuilds sessions from `MP.GetPlayers()` after hot reloads/missed disconnects), playtime credit, save at most every 120 s when dirty, write `live.json`.
- Identity: `beammp:<BeamMP ID>`; guests only as `guest:<name>` if `count_guests_as_unique`.
- Periods `daily/monthly/yearly` keep ID sets; on rollover they are archived to `history.*` as counts. Only the previous month's ID set is kept (for retention), older ones pruned.
- Storage: `writeFileAtomic()` = write `.tmp`, move old file to `.bak`, rename `.tmp` into place (FS.Remove before rename for Windows). `loadState()` never overwrites an unreadable file; it copies it to `.corrupt-<date>` and loads `.bak`/`.tmp`.
- `saveState()` refuses to run until `ready` (set at end of successful init), so a failed init can never save an empty database over real data.

**Discord script (`discord/discord_status.py`):**
- Every `interval_seconds` (default 300, min 60): for each server in config, `GET /api/client/servers/<id>/resources` (state, uptime), then if running `GET /api/client/servers/<id>/files/contents?file=/Resources/Server/PlayerCounter/data/live.json`.
- Builds one embed per server; posts it once (`?wait=true`) and afterwards PATCHes `/messages/<id>`. Message IDs in `discord_status_state.json`, keyed by a hash of the webhook URL (token never stored). A 404 on edit re-posts; 429 retried with `retry_after`.
- Colours: green online, grey empty, yellow (starting / live.json missing / not updated for `stale_after_seconds`), red offline.
- `allowed_mentions: {parse: []}` and markdown escaping so player names can't ping or format.
- Servers may instead use `"live_json_file": "/local/path"` (no panel).

## 5. Decisions made (and why)

| # | Decision | Reason |
|---|---|---|
| D1 | Keep `stats.json` schema 2, only add fields (`playtime_seconds`, `recorded_settings`, `plugin_version`). | Existing servers' data loads unchanged; no migration step. |
| D2 | Keep `joins.csv` columns identical to V1. | Owner's and users' existing tools/spreadsheets keep working. |
| D3 | Settings moved from `main.lua` constants to `data/config.json`. | Updating `main.lua` used to reset settings. Trade-off: 2.0.0 users must copy `UTC_OFFSET_HOURS` once; the console prints a notice. |
| D4 | Plugin does **not** call Discord/Pterodactyl itself; it writes `live.json` and an external Python script does the HTTP. | BeamMP Lua has no HTTPS client; shelling out to curl blocks the Lua state and needs escaping. The owner's install guide already prefers network calls outside BeamMP Lua (weekly_push.py). Also one script can serve all Pterodactyl servers. |
| D5 | Script reads `live.json` through the **Pterodactyl client API** (file contents endpoint) rather than BeamMP's own server list/heartbeat. | Owner asked for "the actual player count via our pterodactyl servers"; the panel also gives running/offline state and uptime. Works without opening extra ports. |
| D6 | Edit one message per server instead of posting every 5 minutes. | Avoids channel spam; standard pattern for status boards. |
| D7 | "Current vehicle" = the player's spawned vehicles (up to 3 listed), model key mapped to a display name. | BeamMP server cannot see which vehicle a player is sitting in. Flagged to the owner. |
| D8 | Playtime counts from `onPlayerJoining` to disconnect, authenticated players only; credited every tick, saved at most every 120 s. | Bounded data loss (≈2 min) without writing the DB every 30 s. Playtime starts at 2.0.1 (no backfill possible). |
| D9 | CSV names starting with `= + - @ TAB CR` get a `'` prefix. | Prevents spreadsheet formula injection from player-chosen names. |
| D10 | Changes go to branch `playercounter-2.0.1` + PR, not straight to `main`. | Public repo; owner reviews before release. |
| D11 | `mock_beammp.lua` is **not** vendored into the repo. | It comes from the `beamng-beammp-dev` skill (scripts/mock_beammp.lua) and has no license header; pass its path via `MOCK_BEAMMP`. |
| D12 | Commits authored as `Claude <noreply@anthropic.com>` with Co-Authored-By/Claude-Session trailers. | Required by the session's commit-verification hook. |
| D13 | Least-privilege Pterodactyl key suggested: separate panel account added as subuser with file-read only. | Not verified that file-read alone also allows the `/resources` call; check on first live run. |

## 6. Open items / next steps

1. **First live test** on one server: install 2.0.1, check `[PlayerCounter] PlayerCounter 2.0.1 loaded`, join, run `pc.online`, confirm `data/live.json` updates.
2. **Discord script live test**: create `discord_status.json`, run `--once --dry-run`, then `--once`, then confirm subuser permissions (D13).
3. Owner to review and merge PR #2; then tag `v2.0.1` and attach the release zip.
4. `weekly_push.py` is described in the install guide (sections 20–24, 26, 28) but **does not exist** in the repo. Offered to write it; not started.
5. Possible: add vanilla names for more BeamNG models / Baja75 mod vehicles in `VEHICLE_NAMES` or the config's `vehicle_names`.
6. Possible: per-server channel/thread support already exists (`webhook_url` per server, `thread_id` query kept); not tested on real Discord threads.

## 7. How to verify after any change

```bash
# plugin (needs Lua 5.3 and the skill's mock)
LUA=lua5.3 MOCK_BEAMMP=/path/to/mock_beammp.lua tests/run_plugin_tests.sh   # expect "45 passed, 0 failed"
# discord script (python3 only)
tests/run_discord_test.sh                                                     # expect "OK"
```

No Lua 5.3 on the machine? Build it: `git clone --depth 1 --branch v5.3.6 https://github.com/lua/lua && cd lua && gcc -O2 -DLUA_COMPAT_5_2 -DLUA_USE_POSIX -o lua53 $(ls *.c | grep -v -e luac.c -e onelua.c) -lm`.

## 8. Conventions

- Lua 5.3 dialect (server). Log prefix `[PlayerCounter]`. Global handler names `PlayerCounter_*`.
- Data files only under `data/` (root-folder changes hot-reload the plugin).
- Owner's style: plain-English docs, no spreadsheet summaries of work, don't over-report during guided work.
- Owner's handle in credits: Leshii413. Don't put the owner's personal email in the repo.
