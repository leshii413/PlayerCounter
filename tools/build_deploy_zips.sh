#!/usr/bin/env bash
# Builds the owner's two ready-to-extract packages from this repo:
#   stats.baja75series.org-site.zip   website files + a filled config.php
#   BeamMP-server-files.zip           main.lua, data/website.json, data/config.json
#                                     (St George, Utah calendar), client mod
# Both carry the same shared secret. The secret is NEVER stored in the repo:
# pass the owner's existing one in PC_SECRET to rebuild matching zips, or leave
# it empty to generate a new one (then BOTH zips must be redeployed).
#
#   PC_SECRET='...' tools/build_deploy_zips.sh [output-dir]
#
# Defaults match the live setup (HANDOFF.md D21-D33): site URL
# https://stats.baja75series.org/ingest.php, data_dir one level above the site
# folder, visitor-local times on the site, servers on St George, Utah time.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/deploy-out}"
URL="${PC_SITE_URL:-https://stats.baja75series.org/ingest.php}"
SECRET="${PC_SECRET:-}"
if [ -z "$SECRET" ]; then
  SECRET="$(python3 -c 'import secrets; print(secrets.token_urlsafe(36))')"
  echo "Generated a NEW secret: redeploy both zips (old servers will get HTTP 401)."
fi
if [ "${#SECRET}" -lt 24 ]; then echo "PC_SECRET must be at least 24 characters" >&2; exit 1; fi
case "$SECRET" in *"'"*|*'"'*|*'\'*) echo "PC_SECRET must not contain quotes or backslashes" >&2; exit 1;; esac

rm -rf "$OUT/site" "$OUT/server"
mkdir -p "$OUT/site/data" "$OUT/server/Resources/Server/PlayerCounter/data" "$OUT/server/Resources/Client"

# Website
for f in index.html style.css app.js api.php ingest.php lib.php .htaccess; do
  cp "$ROOT/web/public/$f" "$OUT/site/"
done
cp "$ROOT/web/public/data/.htaccess" "$OUT/site/data/"
cat > "$OUT/site/config.php" <<PHP
<?php
// PlayerCounter stats website settings for stats.baja75series.org.
// Ready to use: nothing to edit. Keep this file private.

return [
    // Shared secret. Matches "secret" in each BeamMP server's
    // Resources/Server/PlayerCounter/data/website.json.
    'secret' => '$SECRET',

    // Uploaded server data is kept one folder ABOVE the website folder
    // (/home/<cpanel user>/playercounter-data), created automatically,
    // so the web server can never hand it out.
    'data_dir' => dirname(__DIR__) . '/playercounter-data',

    'site_title' => 'BAJA75SERIES server stats',

    // A server that has not uploaded for 5 minutes shows "No recent data".
    'stale_after_seconds' => 300,

    'show_player_names' => true,
    'leaderboard_size' => 15,

    // Times on the page are shown in each visitor's own time zone.
    // (Set e.g. 'America/Denver' to show everyone St George, Utah time.)
    'display_time_zone' => '',
    'display_time_zone_name' => '',
];
PHP
php -l "$OUT/site/config.php" >/dev/null

# BeamMP server
cp "$ROOT/main.lua" "$OUT/server/Resources/Server/PlayerCounter/"
"$ROOT/client/build_zip.sh" >/dev/null
cp "$ROOT/client/playercounter.zip" "$OUT/server/Resources/Client/"
printf '{\n    "url": "%s",\n    "secret": "%s"\n}\n' "$URL" "$SECRET" \
  > "$OUT/server/Resources/Server/PlayerCounter/data/website.json"
printf '{\n    "utc_offset_hours": -7,\n    "dst": "us",\n    "time_zone_name": "St George, Utah time"\n}\n' \
  > "$OUT/server/Resources/Server/PlayerCounter/data/config.json"

(cd "$OUT/site" && rm -f ../stats.baja75series.org-site.zip && zip -qr -X ../stats.baja75series.org-site.zip .)
(cd "$OUT/server" && rm -f ../BeamMP-server-files.zip && zip -qr -X ../BeamMP-server-files.zip Resources)
cp "$ROOT/docs/SETUP-INSTRUCTIONS.md" "$OUT/"
rm -rf "$OUT/site" "$OUT/server"
echo "Built in $OUT:"
ls -1 "$OUT"
echo "Both zips contain the secret: deliver them privately, never commit them."
