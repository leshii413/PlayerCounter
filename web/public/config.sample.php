<?php
// PlayerCounter stats website: settings.
// Copy this file to config.php (same folder) and change the secret.
// config.php is PHP, so visitors can never download it, and .htaccess
// blocks it as well.

return [
    // Shared secret. Every upload is signed with it. Use the same value as
    // "secret" in the BeamMP servers' data/website.json (or "website_secret"
    // in discord_status.json if the status script uploads instead).
    // Make it long and random, e.g. 48+ characters from a password manager.
    'secret' => 'CHANGE_ME_TO_A_LONG_RANDOM_SECRET',

    // Where uploaded server data is stored. Best outside the website folder,
    // e.g. dirname(__DIR__) . '/playercounter-data' (one level above
    // public_html / the subdomain folder). The default inside this folder is
    // protected by data/.htaccess.
    'data_dir' => __DIR__ . '/data',

    // Page title and the name shown at the top.
    'site_title' => 'BAJA75SERIES server stats',

    // A server that has not sent data for this long is shown as "no data".
    // The plugin uploads every minute (and on joins/leaves); if the Discord
    // status script uploads instead (every 5 minutes), use 900.
    'stale_after_seconds' => 300,

    // Show player names (live list and leaderboards). false = totals only.
    'show_player_names' => true,

    // Players per leaderboard on the page.
    'leaderboard_size' => 15,
];
