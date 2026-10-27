# Stats website (stats.baja75series.org)

A small PHP site that shows every server's live players, 24-hour graph, activity heatmap, numbers and playtime leaderboards, plus leaderboards across the whole series. It runs on ordinary shared hosting such as Namecheap's: no database, no Node, nothing to install on the BeamMP servers.

## How it fits together

```text
BeamMP servers (Pterodactyl)          the machine running discord_status.py         Namecheap hosting
PlayerCounter writes live.json  --->  reads each live.json every 5 min       --->  stats.baja75series.org
                                      posts to Discord (optional)                   ingest.php saves it
                                      posts to the website, signed with a secret    api.php + the page show it
```

The status script already reads every server, so it also sends each server's stats to the website. Every upload is signed with a secret that only the script and the site know, so nobody else can post fake stats. BeamMP account IDs travel to the site (to merge the same player across servers) but are never shown on the page or in `api.php`.

## Files

`web/public/` is everything that goes on the hosting:

| File | What it is |
|---|---|
| `index.html`, `style.css`, `app.js` | The page. Refreshes itself every minute. |
| `api.php` | Public stats as JSON for the page (no IDs). |
| `ingest.php` | Receives signed uploads from the status script. |
| `lib.php` | Shared helpers (blocked from direct access). |
| `config.sample.php` | Settings template: copy to `config.php`. |
| `.htaccess` | Blocks settings, data and helper files; forces HTTPS; security headers. |
| `data/` | Where uploads are stored by default (blocked by its own `.htaccess`). |

## Setup on Namecheap shared hosting

### 1. Create the subdomain

1. Log in to cPanel (Namecheap dashboard: Hosting List, then **Go to cPanel**).
2. Open **Domains** (older cPanel: **Subdomains**) and create `stats.baja75series.org`.
3. Leave the suggested document root, usually `/home/<cpanel user>/stats.baja75series.org`. That folder is where the site files go.

If baja75series.org uses Namecheap's hosting nameservers, that's all the DNS you need. If the domain uses **BasicDNS** or other nameservers instead, also add an **A record** in Namecheap: Domain List, **Manage**, **Advanced DNS**, **Add New Record**, Host `stats`, Value = your hosting server's IP (shown in cPanel as **Shared IP Address**). New records usually work within 30 minutes.

### 2. HTTPS

Namecheap installs a free certificate for a new subdomain on shared hosting automatically, usually within 30 minutes, through the **Namecheap SSL** plugin in cPanel. Check it there; the certificate is free for the first year and renewed through Namecheap after that. The site's `.htaccess` redirects visitors to `https://` once the certificate works.

### 3. PHP version

In cPanel, open **Select PHP Version** (or **MultiPHP Manager**) and pick PHP 8.1 or newer for the subdomain. PHP 7.4 also works.

### 4. Upload the site

1. Zip the **contents** of `web/public/` (not the folder itself). Include the hidden `.htaccess` files.
2. In cPanel **File Manager**, open the subdomain's folder, **Upload** the zip, then right-click it and **Extract**. Delete the zip afterwards.
3. In File Manager, enable **Settings > Show Hidden Files** and check that `.htaccess` and `data/.htaccess` are there.

### 5. Settings and secret

1. Copy `config.sample.php` to `config.php` (File Manager: right-click, **Copy**, name it `config.php`), then **Edit** it.
2. Set `secret` to a long random value. To make one, run this on any computer with Python:

   ```bash
   python3 -c "import secrets; print(secrets.token_urlsafe(36))"
   ```

   or use your password manager's generator (40+ characters).
3. Recommended: keep uploaded data outside the website folder:

   ```php
   'data_dir' => dirname(__DIR__) . '/playercounter-data',
   ```

   This puts it in `/home/<cpanel user>/playercounter-data`, which the web server never serves.
4. Optional: `site_title`, `show_player_names` (`false` = totals and graphs only), `leaderboard_size`.

### 6. Point the status script at the site

In `discord/discord_status.json` on the machine that runs the script:

```json
"website_url": "https://stats.baja75series.org/ingest.php",
"website_secret": "the same secret as in config.php",
```

or set the secret as the environment variable `PLAYERCOUNTER_WEBSITE_SECRET`. Give each server a short `site_key` (`"na1"`, `"eu2"`): it names the server's data file, and changing it later starts that server fresh on the site. Servers appear on the page in the order they're listed.

The website works without Discord too: leave `webhook_url` empty and the script only updates the site.

Run it once to check:

```bash
python3 discord_status.py --once
```

Each server should log without a `website update failed` line. Then open https://stats.baja75series.org.

### 7. Check the protection

Open these in a browser; each must say **403 Forbidden** (or not found):

- `https://stats.baja75series.org/config.php` shows a blank page or 403, never the secret (PHP runs it, it prints nothing).
- `https://stats.baja75series.org/data/`
- `https://stats.baja75series.org/lib.php`

If `data/` is visible, your hosting ignores `.htaccess`: move `data_dir` outside the website folder (step 5.3).

## Troubleshooting

| Script log or page says | Fix |
|---|---|
| `website rejected the upload (401): Bad signature` | `website_secret` and `config.php`'s `secret` differ (watch for spaces or quotes). |
| `(401): Timestamp too far from server time` | The clock on the machine running the script is off by more than 5 minutes; turn on automatic time sync. |
| `(409): Not newer than the last upload` | Two copies of the script are running, or the clock went backwards. Run one copy. |
| `(500): config.php is missing` / `Set a long secret` | Step 5. |
| `(500): Cannot write the data file` | The data folder isn't writable. In File Manager, set it to 750 or 755 owned by your cPanel user. |
| `(403)` or `(406)` with an HTML page | Hosting firewall (ModSecurity) blocked the upload. Ask Namecheap support to allow POST requests to `ingest.php` on the subdomain. |
| Page says "No server has sent stats yet" | The script hasn't uploaded yet, or `website_url` points to the wrong address. |
| A server shows "No recent data" | No upload for 15 minutes (`stale_after_seconds`): the status script stopped. |
| Page looks unstyled | The browser blocked fonts or the CSS didn't upload; reload, check `style.css` exists. |

## Privacy

The page shows player names, playtime, vehicles and leaderboards, like the Discord status. BeamMP IDs, IP addresses and player slot numbers are never published. Set `show_player_names` to `false` to show only totals, graphs and the heatmap. Tell your community that these stats are public, as your rules or local law require.
