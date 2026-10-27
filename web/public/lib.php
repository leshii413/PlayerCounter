<?php
// Shared helpers for ingest.php and api.php. Not a page: .htaccess blocks it.
// Works on PHP 7.4 and newer.

if (!defined('PLAYERCOUNTER_WEB')) {
    http_response_code(404);
    exit;
}

function pc_config()
{
    static $config = null;
    if ($config !== null) {
        return $config;
    }
    $file = __DIR__ . '/config.php';
    if (!is_file($file)) {
        pc_fail(500, 'config.php is missing: copy config.sample.php to config.php and set a secret.');
    }
    $config = require $file;
    $config += [
        'secret' => '',
        'data_dir' => __DIR__ . '/data',
        'site_title' => 'Server stats',
        'stale_after_seconds' => 300,
        'show_player_names' => true,
        'leaderboard_size' => 15,
        'display_time_zone' => '',
        'display_time_zone_name' => '',
    ];
    return $config;
}

function pc_json($status, $data, $cacheSeconds = 0)
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('X-Content-Type-Options: nosniff');
    header($cacheSeconds > 0 ? "Cache-Control: public, max-age=$cacheSeconds" : 'Cache-Control: no-store');
    echo json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PARTIAL_OUTPUT_ON_ERROR);
    exit;
}

function pc_fail($status, $message)
{
    pc_json($status, ['ok' => false, 'error' => $message]);
}

function pc_data_dir()
{
    $dir = rtrim(pc_config()['data_dir'], '/\\');
    if (!is_dir($dir) && !@mkdir($dir, 0750, true)) {
        pc_fail(500, 'Cannot create the data folder; check data_dir in config.php.');
    }
    return $dir;
}

// Writes via a temporary file and rename so readers never see half a file.
function pc_write_atomic($path, $contents)
{
    $tmp = $path . '.' . bin2hex(random_bytes(4)) . '.tmp';
    if (file_put_contents($tmp, $contents, LOCK_EX) === false) {
        return false;
    }
    if (!@rename($tmp, $path)) {
        @unlink($tmp);
        return false;
    }
    return true;
}

// Trims text to $max characters (mbstring is usual on cPanel, but optional).
function pc_cut($text, $max)
{
    $text = (string) $text;
    return function_exists('mb_substr') ? mb_substr($text, 0, $max) : substr($text, 0, $max);
}

function pc_server_files()
{
    $files = glob(pc_data_dir() . '/server-*.json');
    return $files ? $files : [];
}
