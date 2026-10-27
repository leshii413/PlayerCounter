# PlayerCounter: session handoff

> **Read this first** if you are a new Claude session (or a person) taking over.
> It is the single source of truth for the project's current state. The full
> prompt-by-prompt history is in [`docs/SESSION_LOG.md`](docs/SESSION_LOG.md).
> **Update both files in the same commit as any change you push** (rules in [`CLAUDE.md`](CLAUDE.md)).

Last updated: 2026-10-27 14:45 (session 1 handing over) (session 1 part 2, Claude Code cloud session `session_01YMAAefrrzE187RmbqyseJo`)

## 0. Taking over? Start here

1. Read §2 (state) and §6 (open items); skim the decision table in §5 (D1–D33) before changing behaviour.
2. Branches: `playercounter-2.0.1` (PR #2 → `main`) and `playercounter-2.1` (PR #3, stacked on #2). Work on a new branch off `playercounter-2.1` unless the owner has merged by then; check with `gh api repos/leshii413/PlayerCounter/pulls`.
3. Set up the test tools (§7): Lua 5.3 build, the `beamng-beammp-dev` skill's `mock_beammp.lua`, LuaJIT, PHP 7.4+, Python 3. Run every suite before and after your change.
4. The owner wants ready-to-upload packages with **no editing**. To rebuild them after a change use `tools/build_deploy_zips.sh` (needs the owner's secret in `PC_SECRET`; without it a new secret is generated and BOTH zips must be redeployed). Deliver the zips privately; never commit them.
5. Follow `CLAUDE.md` on every push (session log + this file + mirror to the claude.ai Project).

## 1. What this project is

A BeamMP Server 3.x **server-side Lua plugin** (`main.lua`) by Leshii413 that tracks player analytics for BeamMP servers: unique players, join sessions, new/returning players, month-over-month retention, playtime (2.0.1, AFK excluded since 2.1.0), and players online (peaks, averages, weekday-hour heatmap, 24 h graph; 2.1.0). It writes a live snapshot of who is online, which a separate Python script (`discord/discord_status.py`) turns into a live Discord status message per server. An optional client mod (`client/`) reports which vehicle each player is actually in. A PHP stats website (`web/`, planned for **stats.baja75series.org** on the owner's Namecheap shared hosting) shows live players, graphs, heatmap, numbers and per-server + series-wide playtime leaderboards; each BeamMP server uploads to it by itself (`data/website.json`, curl, HMAC signed in Lua); the Discord script can upload instead.

Research on similar tools and the feature roadmap: claude.ai doc "BeamMP Tools Landscape & PlayerCounter Roadmap" (https://claude.ai/artifact/PiRfqZkrXfvJpy3EbxK8Js, private to the owner). Summary: nothing else does long-term analytics for BeamMP; Discord bots (DiscordGSM/GameServerMonitor, BeamMP Stats, BEAMER, BeamMP Status) only read the public server list; panels (beamng-server-panel is the closest, same file-bridge design, restrictive license) focus on moderation.

- Repo: https://github.com/leshii413/PlayerCounter (public, GPL-3.0)
- Owner's servers: BeamMP servers hosted on **Pterodactyl** (BAJA75SERIES off-road racing community; BeamJoy Revived is the race engine on those servers).
- claude.ai Project: "Player Counter v2.0.1" (this file is mirrored there as `PlayerCounter/HANDOFF.md`).

## 2. Current state

| Item | State |
|---|---|
| `main` on GitHub | Still the original 2.0.0 code (commit `d878b57`). |
| Branch `playercounter-2.0.1` | 2.0.1 work + handoff system. **PR #2** https://github.com/leshii413/PlayerCounter/pull/2 (base `main`), open. |
| Branch `playercounter-2.1` | 2.1.0 work incl. the stats website, stacked on `playercounter-2.0.1`. **PR #3** https://github.com/leshii413/PlayerCounter/pull/3 (base `playercounter-2.0.1`; retarget to `main` after #2 merges, or merge #2 then #3). |
| Plugin version | 2.1.0 on `playercounter-2.1` (`PLUGIN_VERSION` in `main.lua`); Discord script 2.1.0; `live.json` schema 2. |
| Tested offline | Yes: 45/45 + 49/49 plugin checks (BeamMP mock, Lua 5.3), 7/7 client-mod checks (LuaJIT, stubbed game API), Discord script end to end vs fake panel + fake Discord incl. multipart graph upload, website end to end 20/20 (PHP 8.3 built-in server; content, privacy, merging, forged/old/replayed uploads), page screenshots desktop/mobile/dark with no console errors or horizontal scroll. |
| Tested live | **Partly.** The website is live on Namecheap and at least one BeamMP server uploads to it with the St George calendar (2026-10-27). Not yet live-tested: the client mod in BeamNG, AFK in real play, and the Discord status script. |
| Website hosting | stats.baja75series.org is **live** on the owner's Namecheap shared hosting, and at least one BeamMP server is uploading with the St George calendar (owner screenshots, 2026-10-27 14:10). Owner received ready-to-extract zips (2026-10-27): `stats.baja75series.org-site.zip` (site + filled `config.php`) and `BeamMP-server-files.zip` (main.lua, `data/website.json`, client mod) plus `SETUP-INSTRUCTIONS.md`. The shared secret exists **only in those zips** (generated in-session, never committed, not in the Project or memory); a new session cannot recover it and should generate a new one for both sides if needed. |

### Live deployment (2026-10-27)

- **Website**: https://stats.baja75series.org on the owner's Namecheap shared hosting (cPanel). Subdomain folder holds the site files (plus cPanel's own `.well-known` and `cgi-bin`, keep them); uploaded data lives in `/home/<cpanel user>/playercounter-data/`. Owner screenshots confirmed the page works, the activity grid shows the St George calendar, and the live player list shows `Leshii413 | TrackfabLightBuggy (DesertRacingSoloLimited) | 2m | 4h 45m`.
- **BeamMP servers (Pterodactyl)**: at least one server runs 2.1.0 from `BeamMP-server-files.zip` and uploads to the site. `data/config.json` there: `utc_offset_hours -7`, `dst "us"`, `time_zone_name "St George, Utah time"`.
- **Packages delivered** (latest, 14:20): `stats.baja75series.org-site.zip`, `BeamMP-server-files.zip`, `SETUP-INSTRUCTIONS.md` (copy in `docs/`), public `PlayerCounter-2.1.0.zip`. `tools/build_deploy_zips.sh` reproduces the two private zips byte for byte given the secret.
- **Not deployed / not live-tested**: Discord status script, client-mod "watching" display, AFK in real play.

## 3. File map

```text
main.lua                         the plugin (install at Resources/Server/PlayerCounter/main.lua)
discord/discord_status.py        Pterodactyl -> Discord live status (Python 3.8+, stdlib only)
discord/discord_status.example.json   config template (copy to discord_status.json, git-ignored)
client/scripts/playerCounter/modScript.lua           client mod loader (loads playerCounter_client)
client/lua/ge/extensions/playerCounter/client.lua    client mod: reports the active vehicle (LuaJIT, GE)
client/build_zip.sh              builds client/playercounter.zip (git-ignored) -> server Resources/Client/
tools/build_deploy_zips.sh       builds the owner's two private ready-to-extract zips (PC_SECRET env; output deploy-out/, git-ignored)
docs/SETUP-INSTRUCTIONS.md       owner-facing upload steps for those zips (Namecheap + Pterodactyl)
web/README.md                    Namecheap setup guide for the stats website (subdomain, SSL, upload, secret, checks)
web/public/index.html, style.css, app.js   the page (vanilla JS, renders api.php, refreshes every minute)
web/public/api.php               public JSON: servers cleaned of IDs + merged series leaderboards
web/public/ingest.php            receives signed uploads from discord_status.py
web/public/lib.php               shared PHP helpers (blocked by .htaccess)
web/public/config.sample.php     settings template -> config.php (git-ignored)
web/public/.htaccess, data/.htaccess   block config/lib/data, force HTTPS, CSP + security headers
tests/run_web_test.sh            website e2e: script -> PHP built-in server -> api.php checks (20); with LUA+MOCK_BEAMMP also runs tests/web_push_test.lua
tests/web_push_test.lua          plugin's own upload via curl to the PHP test site (9 checks incl. wrong secret, shell injection)
tests/plugin_test.lua            45 offline checks for main.lua (2.0.1 behaviour)
tests/plugin_test_21.lua         40 offline checks for 2.1 (concurrency, heatmap, graph, AFK, active vehicle)
tests/plugin_test_tz.lua         192 DST checks vs Python zoneinfo cases in tests/tz_cases.txt (America/Denver, Europe/London 2025-2030)
tests/run_plugin_tests.sh        runs every tests/plugin_test*.lua: LUA=lua5.3 MOCK_BEAMMP=/path/mock_beammp.lua tests/run_plugin_tests.sh
tests/client_test.lua            7 checks for the client mod with stubbed game API: luajit tests/client_test.lua client/lua/ge/extensions/playerCounter/client.lua
tests/fake_panel_discord.py      fake Pterodactyl client API + fake Discord webhook (127.0.0.1:8765)
tests/run_discord_test.sh        end-to-end test of discord_status.py (5 POST then 5 PATCH, graph PNG attached to running servers)
tests/live_sample.json           schema-2 live.json: a simulated week of traffic + players driving, watching, AFK
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
- Tick order (2.1): `updatePeriods` → `reconcileSessions` → `updateAfk(dt)` → `creditPlaytime` → `sampleOnline` → save if due → `writeLive`.
- Concurrency (2.1): `sampleOnline()` adds players-online × seconds to `online_seconds`/`sampled_seconds` of daily/monthly/yearly (gaps > 3 intervals skipped), adds to the month's 168-slot `heat_online`/`heat_sampled` (slot = (wday-1)*24+hour+1 in the configured calendar), updates `peak_online`/`peak_at`, the 24 h graph `state.online_24h` (288 × 5-min buckets, max count, -1 = not running) and prunes `state.recent_joins` (unix times, 24 h). Joins also call `notePeaks`/`noteGraph` so short peaks count. Previous month's heat arrays are kept in `history.monthly` until the next rollover (pruned with `users`).
- AFK (2.1): per session `last_pos[vid]` from `MP.GetPositionRaw`; no movement ≥ `afk_move_meters` on any vehicle → `idle += dt`; `idle >= afk_after_seconds` → `afk = true`; while AFK `creditPlaytime` adds to `afk_seconds` instead of `playtime_seconds`. No vehicles → never AFK.
- Active vehicle (2.1): client mod sends `PlayerCounter_activeVehicle` with `{"v":1,"sid":"<owner pid>-<vid>"}`; `PlayerCounter_OnActiveVehicle` accepts it only if that vehicle exists (`MP.GetPlayerVehicles(owner)[vid]`), stores `session.active`; `activeVehicleFor()` re-validates on every snapshot (deleted vehicle → nil).

**Discord script (`discord/discord_status.py`):**
- Every `interval_seconds` (default 300, min 60): for each server in config, `GET /api/client/servers/<id>/resources` (state, uptime), then if running `GET /api/client/servers/<id>/files/contents?file=/Resources/Server/PlayerCounter/data/live.json`.
- Builds one embed per server; posts it once (`?wait=true`) and afterwards PATCHes `/messages/<id>`. Message IDs in `discord_status_state.json`, keyed by a hash of the webhook URL (token never stored). A 404 on edit re-posts; 429 retried with `retry_after`.
- Colours: green online, grey empty, yellow (starting / live.json missing / not updated for `stale_after_seconds`), red offline.
- `allowed_mentions: {parse: []}` and markdown escaping so player names can't ping or format.
- Servers may instead use `"live_json_file": "/local/path"` (no panel).
- Graph (2.1): `graph_series(live)` reads `online_24h`; `render_graph()` draws a 720×160 transparent PNG step chart with stdlib (`zlib`, `struct`), grid at nice_max/4 steps and dotted ticks every 3 h; sent as multipart (`payload_json` + `files[0]`, `attachments:[{id:0,filename:"players_24h.png"}]`, embed `image.url = attachment://players_24h.png`). Without a graph the payload sends `attachments: []` so an old image is removed. Caption uses `<t:unix:t>` so viewers see their own time zone. `--dry-run` writes `preview_<server>.png` to the working directory.
- Player line (2.1): `current_vehicle_text()` prefers `active_vehicle` (own → car, else "watching <owner> (car)"), falls back to spawned vehicles; AFK adds "AFK <idle>".
- Plugin website upload (2.1, preferred): `data/website.json` = `{url, secret}` (+ optional `server_name`, `server_key`, `connect`, `order`, `interval_seconds`); `loadWebsite()` at init validates the URL pattern (https://host/path only; quotes impossible), secret ≥ 24, `command -v curl`; key defaults to a slug of the BeamMP server name (colour codes stripped). `writeLive()` builds the snapshot (`buildSnapshot`) and calls `pushWebsite()` every `interval` (60 s), when the player count changed (≥ 5 s since last), and forced at init and shutdown (`panel_state` "offline", waits up to 5 s). Body written to `data/website_upload.json`, signed with `hmacSha256Hex` (pure Lua 5.3 SHA-256, verified on 46 vectors against Python), sent with `curl ... > data/website_status.txt &`; `checkWebsiteReply()` logs `Website upload OK.` / `website upload failed (HTTP n): <reply>` when the status changes. Pterodactyl debian yolks include curl + ca-certificates.
- Script website upload (2.1, alternative): when `website_url` is set, every refresh POSTs `{"server":{key,name,connect,order},"panel_state","error","uptime_ms","live"}` to `ingest.php` with headers `X-PlayerCounter-Timestamp` and `X-PlayerCounter-Signature: sha256=HMAC_SHA256(secret, "<ts>.<body>")`. A failed upload is logged and never blocks Discord. `site_key` per server (else slug of id); `website_url` must be https (localhost allowed for tests); servers without `webhook_url` only update the site.

**Website (`web/public`, PHP 7.4+, no database):**
- `ingest.php`: POST only, body ≤ 2 MB, signature via `hash_equals`, timestamp within ±300 s and newer than the stored `received_ts` (replay), key `^[a-z0-9][a-z0-9_-]{0,39}$`; writes `data_dir/server-<key>.json` atomically under `flock`.
- `api.php`: status per server = stale (no upload for `stale_after_seconds`, default 900) / offline (panel) / error (no live.json or live.json older than 180 s) / starting / online / empty; strips BeamMP IDs and pids; adds drift to session/played times; series boards merge `beammp_id` across servers (players without an ID stay per server; month board uses the newest `month_key`); `Cache-Control: max-age=30`. `show_player_names=false` removes names, live lists and leaderboards.
- Page: race-plate hero (one yellow plate per server, number = players online), series board, then per server: who's on, 24 h SVG step chart (viewer's local time), heatmap (server calendar, labelled with UTC offset), numbers table, server board with This month / All time toggle. Fonts: Big Shoulders Display + Archivo (Google Fonts); palette limestone #ECEEEA, ink #1D2522, plate #F2C230, dust #B59F78, live #2E9D5B, flag #E2571E; dark mode via prefers-color-scheme. All server text inserted with textContent; CSP forbids inline script/style.

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
| D14 | PlayerCounter stays focused on analytics + live status; kick/ban/map rotation/mod uploads are left to panels and BeamJoy. | Research (2026-10-27): those are well covered elsewhere; long-term analytics is not. |
| D15 | 2.1.0 = roadmap items 1, 2, 3, 6: peak/average/heatmap, Discord 24 h graph, real current vehicle, AFK. | Mostly reuses existing code and fixes the live status's weak spots (no history, guessed vehicle). |
| D16 | AFK judged server-side from vehicle positions; players without a vehicle are never AFK; AFK time counts from the threshold onward (not retroactive). | No client cooperation needed; spectators at Baja75 broadcasts keep playtime; simpler and bounded. |
| D17 | Current vehicle comes from an **optional** client mod; the server treats the report as untrusted and only accepts existing vehicles. | The server cannot see which vehicle a player sits in; keeping it optional means the plugin works without any client download. |
| D18 | The 24 h graph data is kept by the plugin (`online_24h`, persisted) and drawn by the Discord script as a PNG with the stdlib; no outside chart service. | Survives script restarts, 5-min resolution, no third party gets server data, no extra Python packages. |
| D19 | `live.json` schema 2 is additive only; the Discord script still handles schema 1. | Existing dashboards keep working. |
| D20 | 2.1 work goes to branch `playercounter-2.1` with PR #3 based on `playercounter-2.0.1`. | PR #2 is still unmerged; stacking keeps the 2.1 diff reviewable on its own. |
| D21 | Stats website = plain PHP + JSON files on the owner's Namecheap shared hosting at stats.baja75series.org; no database. | Owner's hosting is Namecheap shared (cPanel); PHP is always there, MySQL setup is extra work for little gain at this size. |
| D22 | The Discord status script pushes to the site (HMAC-signed, 5-minute window, replay check) instead of the site pulling from Pterodactyl or the plugin pushing. | The script already reads every server; the Pterodactyl key stays off shared hosting; BeamMP Lua has no HTTPS client. |
| D23 | BeamMP IDs are sent to the site only to merge the same player across servers; `api.php` never publishes IDs or pids. Owner chose "everything + leaderboards" (names shown); `show_player_names` can turn names off. | Privacy with a working series leaderboard. |
| D24 | One playtime credit is capped at 3 timer intervals. | Found by a test: a frozen server or clock jump would otherwise add the whole gap as playtime. |
| D25 | The website ships inside 2.1.0 / PR #3 rather than a separate branch. | 2.1.0 is unreleased; one PR to review is simpler for the owner. |
| D26 | Page design: race-plate look (yellow class plates, condensed door-number type) instead of a generic dashboard. | Specific to Baja racing; documented palette/type in the Website architecture notes. |
| D27 | The site secret was generated in-session and delivered only inside the owner's zips; never committed, mirrored or remembered. | It authorises uploads; the repo is public. |
| D28 | Each BeamMP server uploads to the site itself (Lua HMAC + background curl) instead of relying on the Discord script; the server zip is identical for all servers (name/key from the BeamMP server name). Supersedes D22 as the default path; the script upload remains as an alternative (use one per server). | Owner asked for "no editing, ready to upload"; the script needs panel URL/API key/server ids only the owner has. |
| D29 | `stale_after_seconds` default 300 (plugin uploads every 60 s + on joins/leaves); 900 only when the script uploads. | Faster "No recent data" when a server dies. |
| D30 | The website footer credits "By Leshii413" linking to https://www.patreon.com/Leshii413; no GitHub link on the page. | Owner's request (2026-10-27). |
| D31 | Time zone = St George, Utah (US Mountain): plugin `utc_offset_hours` -7 + `dst` "us" (new US/EU DST rules in Lua, `time_zone_name`); website shows all times in `America/Denver` for every visitor (`display_time_zone`). Both preset in the owner's zips (server zip now ships `data/config.json`; re-extracting it overwrites that file). | Owner's request (2026-10-27); a fixed offset would be an hour off half the year. |
| D32 | Website shows times in each visitor's own time zone (`display_time_zone` empty in the owner's config.php); the plugin calendar stays St George, Utah (heatmap labelled with it). Supersedes the website half of D31. | Owner's request (2026-10-27 13:57). |
| D33 | Every time on the website follows the visitor's zone: graph, peak, updated, heatmap (rotated in the browser from the server calendar), leaderboard last-seen dates (api.php sends full UTC timestamps). Only Today/month/year totals use the server calendar and the page says so. | Owner's request (2026-10-27 14:11). |

## 6. Open items / next steps

1. ~~First live test~~ **Done 2026-10-27**: a server runs 2.1.0 and uploads to the site; vehicle + session + playtime show. Still worth checking in real play: AFK marking after 5 min parked, `pc.peak`, `pc.heatmap`.
2. **Client mod live test**: copy `playercounter.zip` to `Resources/Client/`, rejoin, switch vehicles and spectate another player; `pc.online` should show "driving" / "watching". Uses `MPVehicleGE.getServerVehicleID` and `getPlayerVehicle(0)`; not yet run in BeamNG.
3. ~~Website live setup~~ **Done 2026-10-27**: stats.baja75series.org is live. If more BeamMP servers are added, they only need `BeamMP-server-files.zip` (each appears under its BeamMP server name; keep names unique).
4. **Discord script live test**: create `discord_status.json`, run `--once --dry-run` (writes a preview PNG), then `--once`; confirm the graph attachment replaces itself on edits (multipart PATCH with `attachments`, untested on real Discord) and subuser permissions (D13).
5. Owner to review and merge PR #2, then PR #3 (or retarget #3 to `main`); tag `v2.0.1` / `v2.1.0` and attach `main.lua` + `playercounter.zip`.
6. `weekly_push.py` is described in the install guide (sections 20–24, 26, 28) but **does not exist** in the repo. Roadmap item 9 proposes a weekly Discord summary instead; not started.
7. **Optional, owner said "nevermind" for now (2026-10-27): in-game vehicle names.** The site shows the model key + config (`TrackfabLightBuggy (DesertRacingSoloLimited)`) instead of the in-game name ("Trackfab Apache"). Plan if asked again: client mod reads names from `core_vehicles.getModelList().models[<model key>]` (confirmed in BeamMP's `MPVehicleGE.lua`, used as `vehiclesList.models[vehicleName]`; the entries come from each vehicle's `info.json` "Brand"/"Name", config display name from `info_<config>.json` "Configuration" — field names not yet verified in-game, code defensively with pcall), sends them with the active-vehicle report (bump payload to `"v":2`); server accepts a name only for a model that player really has spawned (compare with `jbm` from `MP.GetPlayerVehicles`), sanitises (≤ 60 chars, no control/colour codes), caches per model in `stats.json`, lets `config.json` `vehicle_names` override, and adds `display_name` to live.json vehicles; site/Discord prefer it.
8. Remaining roadmap (research doc): BeamJoy race/event stats, better retention measures (second-session return, day-7/30, cohorts, activity labels), vehicle/mod usage stats, network-wide totals, milestone posts and offline role ping, player profiles + `/stats <player>`, friend alerts, scheduled messages, privacy tools, public stats page; plus improvements: split `joins.csv` monthly, move player records out of `stats.json`, DST-aware calendar, uptime/unclean-shutdown tracking, public server list fallback in the Discord script.
9. Possible: add vanilla names for more BeamNG models / Baja75 mod vehicles in `VEHICLE_NAMES` or the config's `vehicle_names`.
10. Possible: per-server channel/thread support already exists (`webhook_url` per server, `thread_id` query kept); not tested on real Discord threads.

## 7. How to verify after any change

```bash
# plugin (needs Lua 5.3 and the skill's mock)
LUA=lua5.3 MOCK_BEAMMP=/path/to/mock_beammp.lua tests/run_plugin_tests.sh   # expect "45 passed" and "40 passed", 0 failed
# client mod (needs LuaJIT: git clone https://github.com/LuaJIT/LuaJIT && make)
luajit tests/client_test.lua client/lua/ge/extensions/playerCounter/client.lua   # expect "7 passed, 0 failed"
# discord script (python3 only)
tests/run_discord_test.sh                                                     # expect "OK"
# website (python3 + php 7.4+)
tests/run_web_test.sh                                                         # expect 20 "ok" lines and "OK"
```

No Lua 5.3 on the machine? Build it: `git clone --depth 1 --branch v5.3.6 https://github.com/lua/lua && cd lua && gcc -O2 -DLUA_COMPAT_5_2 -DLUA_USE_POSIX -o lua53 $(ls *.c | grep -v -e luac.c -e onelua.c) -lm`.

## 8. Conventions

- Lua 5.3 dialect (server). Log prefix `[PlayerCounter]`. Global handler names `PlayerCounter_*`.
- Data files only under `data/` (root-folder changes hot-reload the plugin).
- Owner's style: plain-English docs, no spreadsheet summaries of work, don't over-report during guided work.
- Owner's handle in credits: Leshii413. Don't put the owner's personal email in the repo.
