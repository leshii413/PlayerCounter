<?php
// Public stats for the page: every server's latest upload, cleaned for the
// public (no BeamMP IDs, no player IDs), plus series-wide leaderboards that
// merge the same BeamMP account across servers.

define('PLAYERCOUNTER_WEB', 1);
require __DIR__ . '/lib.php';

$config = pc_config();
$now = time();
$showNames = (bool) $config['show_player_names'];
$boardSize = max(1, min(100, (int) $config['leaderboard_size']));

function num($value, $default = 0)
{
    return is_numeric($value) ? $value + 0 : $default;
}

// BeamMP encodes an empty Lua table as {} instead of [].
function as_list($value)
{
    return is_array($value) ? array_values($value) : [];
}

function clean_name($text)
{
    return trim(preg_replace('/\^[0-9a-fA-FlmnoprLMNOPR]/', '', (string) $text));
}

function vehicle($v)
{
    if (!is_array($v) || !isset($v['model'])) {
        return null;
    }
    $out = ['model' => pc_cut($v['model'], 60)];
    if (!empty($v['config']) && $v['config'] !== 'base') {
        $out['config'] = pc_cut($v['config'], 60);
    }
    return $out;
}

function board_entry($e)
{
    return [
        'name' => pc_cut(clean_name($e['name'] ?? ''), 40),
        'playtime_seconds' => (int) num($e['playtime_seconds'] ?? 0),
        'joins' => (int) num($e['joins'] ?? 0),
        'last_seen' => substr((string) ($e['last_seen'] ?? ''), 0, 10),
    ];
}

$servers = [];
$series = ['all_time' => [], 'month' => []];
$seriesMonth = null;

foreach (pc_server_files() as $file) {
    $record = json_decode((string) @file_get_contents($file), true);
    if (!is_array($record) || !isset($record['server']['key'])) {
        continue;
    }
    $live = is_array($record['live'] ?? null) ? $record['live'] : null;
    $panel = $record['panel_state'] ?? null;
    $age = $now - (int) ($record['received_ts'] ?? 0);
    $liveAge = $live ? $now - (int) num($live['updated_unix'] ?? 0) : null;

    // online / empty / starting / offline / stale / error
    if ($age > (int) $config['stale_after_seconds']) {
        $status = 'stale';
    } elseif ($panel !== null && $panel !== 'running' && $panel !== 'starting') {
        $status = 'offline';
    } elseif (!$live) {
        $status = $panel === 'starting' ? 'starting' : 'error';
    } elseif ($panel === 'starting' || ($live['state'] ?? '') === 'stopped') {
        $status = 'starting';
    } elseif ($liveAge !== null && $liveAge > 180) {
        $status = 'error';
    } else {
        $status = count(as_list($live['players'] ?? [])) > 0 ? 'online' : 'empty';
    }
    $running = in_array($status, ['online', 'empty'], true);

    $players = [];
    if ($running && $showNames) {
        foreach (as_list($live['players'] ?? []) as $p) {
            if (!is_array($p)) {
                continue;
            }
            $afk = ($p['afk'] ?? false) === true;
            $drift = max(0, (int) $liveAge);
            $active = $p['active_vehicle'] ?? null;
            $entry = [
                'name' => pc_cut(clean_name($p['name'] ?? ''), 40),
                'guest' => ($p['guest'] ?? false) === true,
                'session_seconds' => (int) num($p['session_seconds'] ?? 0) + $drift,
                'played_seconds' => isset($p['total_playtime_seconds'])
                    ? (int) num($p['total_playtime_seconds']) + ($afk ? 0 : $drift) : null,
                'afk' => $afk,
                'idle_seconds' => $afk ? (int) num($p['idle_seconds'] ?? 0) + $drift : 0,
                'vehicles' => array_values(array_filter(array_map('vehicle', array_slice(as_list($p['vehicles'] ?? []), 0, 5)))),
            ];
            if (is_array($active) && isset($active['model'])) {
                $entry['driving'] = vehicle($active);
                $entry['driving']['own'] = ($active['own'] ?? true) !== false;
                if (!$entry['driving']['own']) {
                    $entry['driving']['owner'] = pc_cut(clean_name($active['owner_name'] ?? ''), 40);
                }
            }
            $players[] = $entry;
        }
        usort($players, function ($a, $b) {
            return $b['session_seconds'] <=> $a['session_seconds'];
        });
    }

    $stats = is_array($live['stats'] ?? null) ? $live['stats'] : [];
    $board = is_array($live['leaderboard'] ?? null) ? $live['leaderboard'] : null;
    $serverBoard = null;
    if ($board && $showNames) {
        $serverBoard = [
            'month_key' => (string) ($board['month_key'] ?? ''),
            'all_time' => array_slice(array_map('board_entry', as_list($board['all_time'] ?? [])), 0, $boardSize),
            'month' => array_slice(array_map('board_entry', as_list($board['month'] ?? [])), 0, $boardSize),
        ];
        // Series boards: merge by BeamMP ID; players without one stay per server.
        $monthKey = (string) ($board['month_key'] ?? '');
        if ($seriesMonth === null || strcmp($monthKey, $seriesMonth) > 0) {
            if ($seriesMonth !== null) {
                $series['month'] = []; // a newer month wins; older month data is stale
            }
            $seriesMonth = $monthKey;
        }
        foreach (['all_time', 'month'] as $scope) {
            if ($scope === 'month' && $monthKey !== $seriesMonth) {
                continue;
            }
            foreach (as_list($board[$scope] ?? []) as $e) {
                if (!is_array($e)) {
                    continue;
                }
                $id = isset($e['beammp_id']) && $e['beammp_id'] !== '' ? 'id:' . $e['beammp_id']
                    : 'name:' . $record['server']['key'] . ':' . ($e['name'] ?? '');
                $entry = board_entry($e);
                if (!isset($series[$scope][$id])) {
                    $entry['servers'] = 1;
                    $series[$scope][$id] = $entry;
                } else {
                    $cur = &$series[$scope][$id];
                    $cur['playtime_seconds'] += $entry['playtime_seconds'];
                    $cur['joins'] += $entry['joins'];
                    $cur['servers'] += 1;
                    if (strcmp($entry['last_seen'], $cur['last_seen']) > 0) {
                        $cur['last_seen'] = $entry['last_seen'];
                        $cur['name'] = $entry['name'];
                    }
                    unset($cur);
                }
            }
        }
    }

    $graph = is_array($live['online_24h'] ?? null) ? $live['online_24h'] : null;
    $info = is_array($live['server'] ?? null) ? $live['server'] : [];
    $servers[] = [
        'key' => $record['server']['key'],
        'order' => (int) ($record['server']['order'] ?? 0),
        'name' => clean_name($record['server']['name'] ?: ($info['name'] ?? $record['server']['key'])),
        'connect' => $record['server']['connect'] ?? '',
        'status' => $status,
        'error' => $status === 'error' ? ($record['error'] ?? null) : null,
        'received_at' => $record['received_at'] ?? null,
        'uptime_seconds' => isset($record['uptime_ms']) ? intdiv((int) $record['uptime_ms'], 1000) : null,
        'map' => pc_cut(clean_name($info['map'] ?? ''), 60),
        'max_players' => (int) num($info['max_players'] ?? 0),
        'player_count' => $running ? count(as_list($live['players'] ?? [])) : 0,
        'players' => $players,
        'calendar_utc_offset_hours' => num($live['calendar_utc_offset_hours'] ?? 0),
        'stats' => [
            'today' => is_array($stats['today'] ?? null) ? $stats['today'] : null,
            'month' => is_array($stats['month'] ?? null) ? $stats['month'] : null,
            'year' => is_array($stats['year'] ?? null) ? $stats['year'] : null,
            'retention' => is_array($stats['retention'] ?? null) ? $stats['retention'] : null,
            'all_time' => is_array($stats['all_time'] ?? null) ? $stats['all_time'] : null,
            'joins_24h' => (int) num($stats['joins_24h'] ?? 0),
        ],
        'graph' => $graph ? [
            'bucket_seconds' => (int) num($graph['bucket_seconds'] ?? 300),
            'start_unix' => (int) num($graph['start_unix'] ?? 0),
            'values' => array_map('intval', as_list($graph['values'] ?? [])),
        ] : null,
        'heatmap' => isset($live['heatmap']) ? array_map('floatval', as_list($live['heatmap'])) : null,
        'leaderboard' => $serverBoard,
    ];
}

usort($servers, function ($a, $b) {
    return [$a['order'], $a['name']] <=> [$b['order'], $b['name']];
});

$finish = function ($rows) use ($boardSize) {
    $rows = array_values($rows);
    usort($rows, function ($a, $b) {
        return [$b['playtime_seconds'], $a['name']] <=> [$a['playtime_seconds'], $b['name']];
    });
    return array_slice($rows, 0, $boardSize);
};

pc_json(200, [
    'title' => (string) $config['site_title'],
    'generated_unix' => $now,
    'show_player_names' => $showNames,
    'servers' => $servers,
    'series' => $showNames ? [
        'month_key' => $seriesMonth,
        'all_time' => $finish($series['all_time']),
        'month' => $finish($series['month']),
    ] : null,
], 30);
