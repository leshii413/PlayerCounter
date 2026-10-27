<?php
// Receives one server's stats from discord_status.py.
//
// Request:  POST, JSON body, headers
//   X-PlayerCounter-Timestamp: <unix seconds>
//   X-PlayerCounter-Signature: sha256=<hex HMAC-SHA256 of "<timestamp>.<body>" with the secret>
// Body:     {"server": {"key", "name", "connect"}, "panel_state", "error", "uptime_ms", "live": {...}}
//
// Rejected: wrong method, bad or missing signature, timestamps more than
// 5 minutes off, or not newer than the last accepted upload for that server
// (stops replays), bodies over 2 MB, invalid JSON or server key.

define('PLAYERCOUNTER_WEB', 1);
require __DIR__ . '/lib.php';

const MAX_BODY = 2 * 1024 * 1024;
const MAX_SKEW = 300;

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    header('Allow: POST');
    pc_fail(405, 'POST only.');
}

$config = pc_config();
$secret = (string) $config['secret'];
if (strlen($secret) < 24 || $secret === 'CHANGE_ME_TO_A_LONG_RANDOM_SECRET') {
    pc_fail(500, 'Set a long secret in config.php (24+ characters).');
}

$length = (int) ($_SERVER['CONTENT_LENGTH'] ?? 0);
if ($length <= 0 || $length > MAX_BODY) {
    pc_fail(413, 'Body missing or larger than 2 MB.');
}
$body = file_get_contents('php://input', false, null, 0, MAX_BODY + 1);
if ($body === false || strlen($body) > MAX_BODY) {
    pc_fail(413, 'Body larger than 2 MB.');
}

$timestamp = $_SERVER['HTTP_X_PLAYERCOUNTER_TIMESTAMP'] ?? '';
$signature = $_SERVER['HTTP_X_PLAYERCOUNTER_SIGNATURE'] ?? '';
if (!preg_match('/^\d{9,11}$/', $timestamp) || !preg_match('/^sha256=[0-9a-f]{64}$/', $signature)) {
    pc_fail(401, 'Missing or malformed signature headers.');
}
$expected = 'sha256=' . hash_hmac('sha256', $timestamp . '.' . $body, $secret);
if (!hash_equals($expected, $signature)) {
    pc_fail(401, 'Bad signature: check that website_secret matches config.php.');
}
if (abs(time() - (int) $timestamp) > MAX_SKEW) {
    pc_fail(401, 'Timestamp too far from server time: check the clock on the machine running the script.');
}

$payload = json_decode($body, true);
if (!is_array($payload) || !isset($payload['server']) || !is_array($payload['server'])) {
    pc_fail(400, 'Body must be a JSON object with a "server" object.');
}
$key = (string) ($payload['server']['key'] ?? '');
if (!preg_match('/^[a-z0-9][a-z0-9_-]{0,39}$/', $key)) {
    pc_fail(400, 'server.key must be 1-40 characters: a-z, 0-9, _ or -.');
}

$path = pc_data_dir() . "/server-$key.json";
$lock = fopen($path . '.lock', 'c');
if (!$lock || !flock($lock, LOCK_EX)) {
    pc_fail(500, 'Cannot lock the data file.');
}
$previous = is_file($path) ? json_decode((string) file_get_contents($path), true) : null;
if (is_array($previous) && (int) ($previous['received_ts'] ?? 0) >= (int) $timestamp) {
    flock($lock, LOCK_UN);
    pc_fail(409, 'Not newer than the last upload for this server (replay or clock change).');
}

$record = [
    'received_ts' => (int) $timestamp,
    'received_at' => gmdate('Y-m-d\TH:i:s\Z'),
    'server' => [
        'key' => $key,
        'name' => pc_cut($payload['server']['name'] ?? $key, 100),
        'connect' => pc_cut($payload['server']['connect'] ?? '', 100),
        'order' => (int) ($payload['server']['order'] ?? 0),
    ],
    'panel_state' => is_string($payload['panel_state'] ?? null) ? $payload['panel_state'] : null,
    'error' => is_string($payload['error'] ?? null) ? pc_cut($payload['error'], 200) : null,
    'uptime_ms' => is_numeric($payload['uptime_ms'] ?? null) ? (int) $payload['uptime_ms'] : null,
    'live' => is_array($payload['live'] ?? null) ? $payload['live'] : null,
];

$ok = pc_write_atomic($path, json_encode($record, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
flock($lock, LOCK_UN);
fclose($lock);
if (!$ok) {
    pc_fail(500, 'Cannot write the data file; check folder permissions.');
}
pc_json(200, ['ok' => true, 'server' => $key]);
