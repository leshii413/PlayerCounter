# BeamMP PlayerCounter + Retention Analytics

A server-side analytics plugin for **BeamMP Server 3.x**. It tracks unique players, join sessions, new and returning players, month-over-month retention and playtime using permanent BeamMP account IDs, and can show who is online right now in a live Discord message.

**Version 2.0.1** · [Changelog](CHANGELOG.md) · [Full installation guide](Full%20Installation%20Guide) · GPL-3.0

## Features

- Daily, monthly, yearly and all-time **unique players** and **join sessions**
- **New vs returning** players and **month-over-month retention**
- **Playtime** per player (session and all-time)
- **Live snapshot** (`data/live.json`) of who is online: name, session time, total playtime, vehicles
- **Discord live status** for one or many Pterodactyl servers, refreshed every 5 minutes (`discord/`)
- Crash-safe storage: atomic saves, automatic `.bak`, recovery from a damaged `stats.json`
- Raw connection log (`joins.csv`) safe to open in Excel / Google Sheets
- Settings in `data/config.json`, so updating `main.lua` keeps them
- Automatic calendar rollover (even when nobody joins), V1 migration, `CHK_BMP` filtering
- In-game and server-console commands

## Requirements

- BeamMP Server 3.x
- Write access to `Resources/Server/PlayerCounter/`
- For Discord status (optional): Python 3.8+ anywhere that can reach your panel and Discord

## Installation

Place `main.lua` here and restart the server:

```text
Resources/
└── Server/
    └── PlayerCounter/
        └── main.lua
```

On first start the plugin creates its data folder:

```text
Resources/Server/PlayerCounter/
├── main.lua
└── data/
    ├── config.json     settings (edit this, then restart)
    ├── stats.json      analytics database
    ├── stats.json.bak  previous save, used for automatic recovery
    ├── joins.csv       raw connection log
    └── live.json       who is online right now (rewritten every 30 s)
```

A successful start prints:

```text
[PlayerCounter] PlayerCounter 2.0.1 loaded (calendar UTC+0, player commands: everyone). Type pc.help in the console.
```

### Updating

1. Stop the server.
2. Back up `Resources/Server/PlayerCounter/data/`.
3. Replace `main.lua` only. Keep the `data/` folder.
4. Start the server and check the `[PlayerCounter]` console lines.

**Upgrading from 2.0.0:** settings used to live inside `main.lua`. The first 2.0.1 start creates `data/config.json` with defaults; copy your old `UTC_OFFSET_HOURS` and other values into it and restart. Existing `stats.json` and `joins.csv` are used as-is.

**Upgrading from V1:** the old `all_users` list is migrated automatically. All-time totals are kept; retention starts once a full month has been captured.

## Configuration

`data/config.json`:

```json
{
    "utc_offset_hours": 0,
    "count_guests_as_unique": false,
    "player_commands": "everyone",
    "admin_beammp_ids": [],
    "live_snapshot": true,
    "live_interval_seconds": 30
}
```

| Setting | Meaning |
|---|---|
| `utc_offset_hours` | Calendar used for day/month/year rollover. `0` = UTC, `8` = Philippines/Singapore, `-5` = US Eastern. Pick it before collecting data; the console warns if it changes later. |
| `count_guests_as_unique` | `false` (recommended): guests count as join sessions but not unique players, because guests have no permanent ID. `true` uses the guest name as an approximate identity. |
| `player_commands` | Who may use the chat commands: `"everyone"`, `"admins"` or `"off"`. |
| `admin_beammp_ids` | BeamMP IDs allowed when `player_commands` is `"admins"`, e.g. `["583921"]`. |
| `live_snapshot` | Write `data/live.json` for dashboards and the Discord status script. |
| `live_interval_seconds` | How often `live.json` is refreshed (minimum 5). |

## Commands

| In chat | Server console | Shows |
|---|---|---|
| `/playerstats` | `playerstats` or `pc.stats` | Today, month, retention, year and all-time totals |
| `/retention` | `retention` or `pc.retention` | Month-over-month retention |
| `/playtime` | | Your session time, total playtime and joins |
| | `pc.month [YYYY-MM]` | Monthly report (current month if omitted) |
| | `pc.online` | Who is online, session time, vehicles |
| | `pc.top [N]` | Top N players by playtime (default 10) |
| | `pc.save` | Save immediately |
| | `pc.help` | List console commands |

Chat replies are private to the player who asked and are split into short lines. Console commands always work, whatever `player_commands` is set to.

Example `/playerstats`:

```text
Today: 47 unique, 12 new, 35 returning, 103 joins
Month: 381 unique, 119 new, 262 returning, 1824 joins
MoM retention: 160/400 (40.0%)
Year: 2184 unique, 1087 new, 1097 returning, 18492 joins
All-time: 3719 unique, 31527 joins
```

Example `pc.month 2026-08`:

```text
PlayerCounter report for 2026-08
  Unique players:       381
  New players:          119
  Returning players:    262
  Join sessions:        1824
  Guest joins:          14
  Previous month users: 400
  Players retained:     160
  Monthly retention:    40.0%
```

## Discord live status

`discord/discord_status.py` keeps **one Discord message per server** up to date (edited in place, no channel spam). Every 5 minutes it:

1. asks your Pterodactyl panel whether each server is running,
2. reads that server's `data/live.json` through the Pterodactyl client API,
3. updates the message with status, player count (`4 / 24`), map, connect address, uptime, and every player online with **name, session time, total playtime and current vehicle(s)**, plus today / month / all-time stats.

Offline servers turn red, a missing or silent plugin turns yellow, and player names can never ping `@everyone`.

### Setup

1. Install PlayerCounter 2.0.1 on each BeamMP server (it writes `live.json`).
2. In Discord: channel settings → Integrations → Webhooks → New Webhook → copy URL.
3. In Pterodactyl: Account → API Credentials → create a client API key. For least privilege, create a separate panel account that is added to each BeamMP server as a **subuser with only file read permissions** and make the key on that account.
4. Find each server's ID: the short code in the panel URL, e.g. `https://panel.example.com/server/1a2b3c4d`.
5. Copy `discord/discord_status.example.json` to `discord/discord_status.json` and fill in `panel_url`, `api_key`, `webhook_url` and the `servers` list.
6. Test, then run it:

```bash
python3 discord_status.py --once --dry-run   # print what would be sent
python3 discord_status.py --once             # post/update the messages once
python3 discord_status.py                    # keep updating every 5 minutes
```

Secrets can be passed as environment variables instead of the file: `PTERODACTYL_API_KEY`, `DISCORD_WEBHOOK_URL`.

Where to run it: any always-on machine (VPS, home server) or a separate Pterodactyl server using a generic Python egg, with `discord_status.py` and `discord_status.json` uploaded and the startup command `python3 discord_status.py`. It uses only the Python standard library. Message IDs are stored in `discord_status_state.json`; delete a message in Discord and the script posts a new one on the next refresh.

Each server can have its own `webhook_url` (different channels) and `live_json_path`. A server on the same machine as the script can use `"live_json_file": "/path/to/live.json"` instead of a Pterodactyl `id`. Mod vehicles show their model key; give them nice names under `vehicle_names`.

**Vehicle note:** the BeamMP server knows which vehicles a player has spawned, not which one they are sitting in. The status lists a player's spawned vehicles in spawn order (up to three).

### live.json format

Useful if you want your own website or bot to read it:

```json
{
  "schema": 1,
  "plugin_version": "2.0.1",
  "state": "running",
  "updated_at": "2026-10-07T05:44:48Z",
  "updated_unix": 1791351888,
  "server": { "name": "Baja75 Series #4 NA", "map": "johnson_valley", "max_players": 24 },
  "player_count": 1,
  "players": [
    {
      "name": "Leshii413", "beammp_id": "583921", "guest": false,
      "joined_at": "2026-10-07T04:31:12Z", "session_seconds": 4416,
      "total_playtime_seconds": 126416,
      "vehicles": [ { "vid": 0, "model": "pickup", "config": "d35_4wd_prerunner" } ]
    }
  ],
  "stats": { "today": {}, "month": {}, "year": {}, "retention": {}, "all_time": {} }
}
```

`state` becomes `"stopped"` on a clean shutdown. An empty list may appear as `{}` (BeamMP's JSON encoder), so treat `{}` as an empty list.

## Statistic definitions

**Unique player:** an authenticated BeamMP account. One player joining 15 times in a day is 1 daily unique player and 15 join sessions.

**Join session:** every accepted connection, including reconnects and guests.

**New player:** a BeamMP ID never seen before by the database. A player is new only once, ever.

**Returning player:** an already-known player making their first connection of the period. They may have last played months ago.

**Retained player:** played in the immediately previous calendar month **and** this month.

**Month-over-month retention:** retained players ÷ previous month's unique players × 100. Example: 400 players in July, 160 of them came back in August → 40.0%. Retention shows N/A until a complete previous month has been captured (fresh install, V1 upgrade, or a month with the server down).

**Playtime:** time from joining (after mods download) until disconnect, counted for authenticated players. It is saved at least every two minutes while players are online, so a crash loses at most a couple of minutes. Playtime tracking starts with 2.0.1.

Daily, monthly and yearly figures reset at the start of each period in the configured time zone; completed periods are archived in `stats.json` under `history`. Only the previous month's player list is kept for retention; older months keep their totals only, so `stats.json` does not grow with a full player list per month.

## Data files

### stats.json

The analytics database: current periods, player records, history and migration info. Each player record looks like:

```json
"beammp:583921": {
  "first_seen": "2026-08-10T05:00:00Z",
  "last_seen": "2026-10-07T04:31:12Z",
  "first_name": "Leshii413",
  "last_name": "Leshii413",
  "joins": 42,
  "playtime_seconds": 126416,
  "legacy": false
}
```

`legacy: true` marks players migrated from V1 without first-seen details.

**Crash safety:** every save writes `stats.json.tmp` first, keeps the previous file as `stats.json.bak`, then swaps the new file in. If `stats.json` is ever unreadable at startup, PlayerCounter keeps a copy as `stats.json.corrupt-<date>` and loads the backup instead of starting from zero.

Do not edit `stats.json` while the server is running.

### joins.csv

Permanent raw connection log, same columns as V1:

```text
timestamp_utc,date,month,year,beammp_id,player_name,is_guest
2026-08-10T03:12:41Z,2026-08-10,2026-08,2026,583921,Leshii413,false
2026-08-10T03:26:17Z,2026-08-10,2026-08,2026,774125,Hilly,false
2026-08-10T04:01:52Z,2026-08-10,2026-08,2026,583921,Leshii413,false
```

`date`, `month` and `year` use the configured calendar; `timestamp_utc` is always UTC. Player names that start with `=`, `+`, `-` or `@` are prefixed with `'` so spreadsheet apps show them as text instead of running them as formulas.

## Privacy

PlayerCounter stores BeamMP account IDs, display names, join times, playtime, guest status and spawned vehicle models. It does not use IP addresses. Inform your players where your community rules or local law require it.

Do not publish `stats.json`, `joins.csv` or `live.json` directly. The Discord status hides BeamMP IDs unless you set `show_beammp_ids` to `true`.

## Resetting statistics

Stop the server, back up `data/`, delete `stats.json`, `stats.json.bak` and `joins.csv`, then start the server. This permanently removes history unless you kept the backup.

## Troubleshooting

| Symptom | Check |
|---|---|
| No `[PlayerCounter]` lines | The path must be exactly `Resources/Server/PlayerCounter/main.lua`. |
| `Could not create data directory` | The BeamMP process needs write permission on `Resources/Server/PlayerCounter/`. Statistics stay disabled until fixed. |
| `Could not write ...` | Permissions, disk space, read-only filesystem. |
| `stats.json is invalid JSON ... Recovered statistics from stats.json.bak` | A crash or manual edit damaged the file; the backup was loaded. Joins after the last good save may be missing. |
| `utc_offset_hours is X but this data was collected with Y` | The time zone in `config.json` changed. Change it back unless intended. |
| `/playerstats` is shown in public chat | `player_commands` is `"off"`. |
| Retention says N/A | Expected until a full previous month is captured. |
| Unique count didn't rise on reconnect | Intended: 1 player, many join sessions. |
| Discord shows "live.json not found" | PlayerCounter 2.0.1+ is not installed on that server, or `live_json_path` differs. |
| Discord shows "has not reported for ..." | The server is running but the plugin stopped updating: check the server console for Lua errors. |
| Discord shows "API key has no access" | The key's account is not a (sub)user on that server, or the server ID is wrong. |

## License

GNU General Public License v3.0. You may use, modify and redistribute this software under the GPL-3.0; modified versions you distribute must remain under the GPL with source available. See [LICENSE](LICENSE).
