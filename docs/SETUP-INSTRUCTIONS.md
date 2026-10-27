# PlayerCounter 2.1.0: upload and go

Two zips, nothing to edit. They share the same secret, so they work together as they are. Stats use **St George, Utah time** (US Mountain Time, daylight saving included): days and months roll over at St George midnight. Everything on the website, including the busy-hours grid and "last seen" dates, is shown in each visitor's own time zone; only the Today / month / year totals follow St George's calendar.

| Zip | Goes to |
|---|---|
| `stats.baja75series.org-site.zip` | The stats website, on Namecheap |
| `BeamMP-server-files.zip` | Each BeamMP server, on Pterodactyl (the same zip for every server) |

Keep both zips private: they contain the secret that lets a server post stats to the site.

---

## 1. Website (Namecheap cPanel)

1. **Create the subdomain.** cPanel → **Domains** (older cPanel: **Subdomains**) → create `stats.baja75series.org`. Keep the suggested folder, usually `/home/<your cPanel user>/stats.baja75series.org`.
2. **Wait for HTTPS.** Namecheap adds a free SSL certificate to the new subdomain automatically, usually within 30 minutes (cPanel → **Namecheap SSL** shows it). It's free for the first year, then renewed through Namecheap.
3. **Upload and extract.** cPanel → **File Manager** → open the `stats.baja75series.org` folder → **Upload** `stats.baja75series.org-site.zip` → right-click it → **Extract** → delete the zip.

   **Already uploaded an earlier version?** Do the same again and let it overwrite the existing files when File Manager asks.

That's the website done. Until the first server uploads, the page says no server has sent stats yet.

> Only if baja75series.org does **not** use Namecheap's hosting nameservers: also add an A record (Domain List → Manage → Advanced DNS → Add New Record, Host `stats`, Value = the **Shared IP Address** shown in cPanel).

## 2. Each BeamMP server (Pterodactyl panel)

Do this on every BeamMP server, with the same zip.

1. **Stop** the server.
2. **Back up** `Resources/Server/PlayerCounter/data/` if it exists (Files → select the folder → Archive → Download). Your stats stay where they are; the zip doesn't touch `stats.json` or `joins.csv`. This is just a safety copy.
3. **Upload** `BeamMP-server-files.zip` in **Files**, at the top level of the server (the folder that contains `Resources` and `ServerConfig.toml`).
4. Click the **⋯** menu on the zip → **Unarchive**. It puts:
   - `Resources/Server/PlayerCounter/main.lua`: the plugin (replaces the old one)
   - `Resources/Server/PlayerCounter/data/website.json`: the website address and secret
   - `Resources/Server/PlayerCounter/data/config.json`: the settings, preset to St George, Utah time (if you change settings later, extracting this zip again resets them)
   - `Resources/Client/playercounter.zip`: the small client mod that shows which vehicle each player is driving (players download it automatically when they join)
5. Delete `BeamMP-server-files.zip`, then **Start** the server.

### What you should see in the console

```text
[PlayerCounter] Website uploads on: https://stats.baja75series.org/ingest.php as "<your server name>" (key ...).
[PlayerCounter] PlayerCounter 2.1.0 loaded (calendar St George, Utah time, UTC-6, US daylight saving, ...). Type pc.help in the console.
[PlayerCounter] Website upload OK.
```

`Website upload OK.` appears within about a minute. (UTC-6 is summer time in St George; from the first Sunday of November it shows UTC-7 on its own.) Then open https://stats.baja75series.org: the server shows up under its BeamMP server name. Each server appears on its own, so give your servers different names in Pterodactyl (they already are, e.g. "Baja75 Series #1 NA", "#2 EU").

Players already on the server need to rejoin once to get the client mod.

### Quick checks in the console

- `pc.online`: who's on, their vehicle, AFK
- `pc.peak`: players online today / this month
- `pc.help`: all commands

## 3. Check the website is locked down

Open these in a browser once the site is up. Each should show **403 Forbidden** or an empty page, never any text:

- https://stats.baja75series.org/config.php
- https://stats.baja75series.org/data/
- https://stats.baja75series.org/lib.php

---

## If something doesn't work

| You see | Fix |
|---|---|
| Console: `website upload failed (HTTP 401)` | The site and server files come from different downloads. Re-upload both zips from the same set. |
| Console: `website upload failed (HTTP 403)` or `(406)` | Namecheap's firewall blocked the upload. Ask Namecheap support to allow POST requests to `stats.baja75series.org/ingest.php`. |
| Console: `website upload failed (HTTP 000)` | The site isn't reachable yet: the subdomain or SSL is still being set up. Wait 30 minutes; the server retries every minute. |
| Console: `curl is not installed on this server` | The server's image has no curl. Tell me which egg it uses and I'll switch that server to the other upload method. |
| Page: a server says "No recent data" | That BeamMP server is stopped or crashed (no upload for 5 minutes). |
| Page: two entries for one server | The server was renamed. Remove the old entry's file from `/home/<cPanel user>/playercounter-data/` in File Manager. |

## Optional, later

- **Discord live status:** separate, and needs your panel address, API key and Discord webhook. See the README's "Discord live status" section when you want it.
