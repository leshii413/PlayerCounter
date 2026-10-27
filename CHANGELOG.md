# Changelog

## 2.1.0 (2026-10-27)

### Added
- **Players online:** peak (with time) and average players online per day, month and year; peaks shorter than one sample are caught at join. Archived in `history` and shown in `pc.month`.
- **Heatmap:** average players online for each weekday hour of the current month (configured calendar); console `pc.heatmap` prints the busiest hours and a 7 × 24 grid. The previous month's heatmap is kept until the next rollover.
- **24-hour graph data:** most players online per 5-minute bucket for the last 24 h (`online_24h` in `live.json`, `-1` = server not running), kept across restarts.
- **Joins in the last 24 hours** in `/playerstats`, `pc.peak` and `live.json`.
- **AFK detection:** playtime pauses when none of a player's vehicles moved `afk_move_meters` (5) for `afk_after_seconds` (300); AFK time is stored as `afk_seconds`. Players with no vehicle are not judged. Settings `afk_detection`, `afk_after_seconds`, `afk_move_meters`.
- **Optional client mod** (`client/`, `playercounter.zip` in `Resources/Client/`): reports the vehicle a player is driving or watching. The server accepts only vehicles that exist. `live.json` gains `active_vehicle` and an `active` flag on the vehicle list.
- **Discord status:** a 24-hour player graph (PNG drawn by the script, attached to the message) with the peak time as a Discord timestamp; player lines show the vehicle being driven, "watching <player>", and an AFK marker; Today field shows the peak. `show_graph` setting.
- Console `pc.peak`; `pc.online` shows AFK and the vehicle being driven or watched.
- **Stats website** (`web/`): PHP site for shared hosting (Namecheap-ready, e.g. `stats.baja75series.org`) with race-plate server overview, live players, 24 h graph, heatmap, numbers, per-server and series-wide playtime leaderboards (the same BeamMP account merged across servers). Signed uploads (HMAC-SHA256, 5-minute window, replay protection); BeamMP IDs never published; `.htaccess` blocks settings and data. Setup guide in `web/README.md`.
- **Discord script** uploads every server to the website (`website_url`, `website_secret` / `PLAYERCOUNTER_WEBSITE_SECRET`, per-server `site_key`); works with or without a Discord webhook.
- **Leaderboards** in `live.json` (`leaderboard_size`, default 25): all-time and this-month playtime; players now also track `month_playtime_seconds`. `pc.top [N] [month]`.
- `live.json` carries `calendar_utc_offset_hours`.
- Tests: `tests/plugin_test_21.lua` (49 checks), `tests/client_test.lua` (7 checks, LuaJIT), `tests/run_web_test.sh` (20 checks: content, privacy, merging, forged/old/replayed uploads).

### Changed
- `live.json` schema 1 → 2 (fields added only; readers of schema 1 keep working).
- Playtime excludes AFK time from 2.1.0 on.
- A single playtime credit is capped at three timer intervals, so a frozen server or a clock jump can no longer add hours of playtime.
- `/playerstats` starts with an "Online now / Peak today / Peak this month / Joins last 24h" line (6 lines).

### Compatibility
- `stats.json` stays schema 2; new fields are added on first start. `joins.csv` unchanged.

## 2.0.1 (2026-10-07)

### Fixed
- **Data loss after a crash.** If `stats.json` was cut off mid-write (crash, power loss, full disk), the next start loaded an empty database and saved over the damaged file, wiping all history. Saves are now atomic (`.tmp` then swap), the previous save is kept as `stats.json.bak`, and an unreadable `stats.json` is preserved as `stats.json.corrupt-<date>` while the backup is loaded.
- **Spreadsheet formula injection in `joins.csv`.** A player named e.g. `=HYPERLINK(...)` became a live formula when the log was opened in Excel or Google Sheets. Such names are now prefixed with `'`.
- Statistics no longer start if the data folder cannot be created, so a temporary permission problem cannot lead to an empty database being saved.
- Days with no joins are now archived at midnight by a timer instead of waiting for the next join or command.
- Console commands with trailing spaces and chat commands with different capitalisation are recognised.
- Long `/playerstats` replies are split into short lines instead of one line that the chat box truncates.

### Added
- **Playtime tracking:** per-player total playtime (`playtime_seconds`), saved at least every two minutes while players are online and on disconnect/shutdown. `/playtime` chat command, `pc.top` console command.
- **Live snapshot** `data/live.json` every 30 s: players online, session time, total playtime, spawned vehicles, server name/map/max players, current stats. Survives hot reloads (sessions are rebuilt from the connected players).
- **Discord live status** (`discord/discord_status.py`): reads `live.json` from each Pterodactyl server via the client API every 5 minutes and edits one Discord message per server. Handles offline servers, missing/stalled plugin, deleted messages and Discord rate limits; player names can never ping.
- **`data/config.json`** for settings, so replacing `main.lua` no longer resets the time zone or other options. Warns if the time zone changes after data was collected.
- `player_commands`: `"everyone"`, `"admins"` (by BeamMP ID) or `"off"`.
- Console commands `pc.month [YYYY-MM]`, `pc.online`, `pc.top [N]`, `pc.save`, `pc.help` (existing `playerstats` and `retention` still work).

### Compatibility
- `stats.json` stays schema 2 (fields only added); `joins.csv` columns unchanged.
- Settings from 2.0.0's `main.lua` are not carried over automatically: copy `UTC_OFFSET_HOURS` etc. into `data/config.json` after the first start.

## 2.0.0

- Retention analytics: new vs returning players, month-over-month retention, per-player records, V1 migration.
