# BeamMP PlayerCounter + Retention Analytics

A server-side analytics plugin for BeamMP Server 3.x that tracks unique players, join sessions, new and returning users, and month-over-month player retention using permanent BeamMP account IDs.

File Structure:
```Resources/
└── Server/
    └── PlayerCounter/
        ├── main.lua
        └── data/
            ├── stats.json
            └── joins.csv


**Features**


Daily unique players

Monthly unique players

Yearly unique players

All-time unique players

Daily, monthly, yearly, and all-time join sessions

New player tracking

Returning player tracking

Month-over-month retention

Permanent per-player statistics

CSV connection log

JSON statistics database

Automatic calendar rollover

Existing PlayerCounter V1 migration

BeamMP connectivity-check filtering

Optional in-game statistics commands

Server-console statistics commands

Requirements

BeamMP Server 3.x

Server-side Lua resources enabled

Write access to the server's Resources/Server/PlayerCounter/ directory

Installation

Create the following directory structure in your BeamMP server:

Resources/
└── Server/
    └── PlayerCounter/
        └── main.lua

Place main.lua inside:

Resources/Server/PlayerCounter/

The plugin automatically creates its data directory:

Resources/Server/PlayerCounter/data/

After the server starts, the structure will look like:

Resources/
└── Server/
    └── PlayerCounter/
        ├── main.lua
        └── data/
            ├── stats.json
            └── joins.csv

Restart the BeamMP server after installing or replacing the script.

Updating From the Original PlayerCounter

If you are upgrading from the earlier PlayerCounter version, keep your existing data folder and replace only:

Resources/Server/PlayerCounter/main.lua

The retention version automatically detects the old all_users database and migrates known BeamMP IDs into the new player database.

Migration Remarks

Existing all-time unique-player records are preserved.

Existing total join counts are preserved.

Historical retention cannot be reconstructed from the old stats.json if the previous version only stored monthly totals instead of the individual BeamMP IDs that formed each monthly cohort.

As a result:

Current and all-time statistics are preserved where possible.

New vs. returning classification becomes increasingly accurate after migration.

Exact month-over-month retention becomes available after the plugin has captured a complete previous month.

The migration status is stored in stats.json.

Configuration

Configuration options are located near the top of main.lua.

Analytics Time Zone

local UTC_OFFSET_HOURS = 0

This controls which calendar day, month, and year are used for analytics.

Examples:

local UTC_OFFSET_HOURS = 0

UTC

local UTC_OFFSET_HOURS = 8

Philippines / UTC+8

Changing this setting changes when daily, monthly, and yearly analytics roll over.

For consistent historical reporting, avoid changing the time-zone setting after you have already collected a large amount of data.

Guest Unique-User Tracking

local COUNT_GUESTS_AS_UNIQUE = false

Recommended setting:

false

Guest accounts do not have the same reliable permanent BeamMP account identity as authenticated players.

With this setting disabled:

Guest connections still count as join sessions.

Guest connections are recorded in joins.csv.

Guest connections do not increase unique-player totals.

If enabled:

local COUNT_GUESTS_AS_UNIQUE = true

the script uses the guest's player name as an approximate identity.

This is less accurate because guest names can change or be reused.

Player Chat Commands

local ALLOW_PLAYER_COMMANDS = true

When enabled, players may use:

/playerstats
/retention

To restrict statistics to server administrators using the console, set:

local ALLOW_PLAYER_COMMANDS = false

Commands

In-Game Command: /playerstats

/playerstats

Returns the current player analytics summary privately to the requesting player.

Example:

Today: 47 unique, 12 new, 35 returning, 103 joins |
Month: 381 unique, 119 new, 262 returning, 1824 joins |
MoM retention: 160/400 (40.0%) |
Year: 2184 unique, 1087 new, 1097 returning, 18492 joins |
All-time: 3719 unique, 31527 joins

This command is available only when:

local ALLOW_PLAYER_COMMANDS = true

In-Game Command: /retention

/retention

Returns current month-over-month retention information.

Example:

Retention | 2026-07 -> 2026-08: 160 of 400 returned (40.0%) |
Current unique: 381 |
New: 119 |
Returning-ever: 262

If there is no valid previous-month cohort available:

Retention | Current month: 2026-08 |
Previous-month cohort unavailable |
Current unique: 381 |
New: 119 |
Returning-ever: 262

This normally occurs:

Immediately after first installation

Immediately after upgrading from the old PlayerCounter

If an entire previous calendar month was not captured

If previous-month membership data is unavailable

Server Console Command: playerstats

Run from the BeamMP server console:

playerstats

Returns the same overall analytics summary as /playerstats.

This command remains available even if player chat commands are disabled.

Server Console Command: retention

Run from the BeamMP server console:

retention

Returns the same retention summary as /retention.

This command remains available even if player chat commands are disabled.

Statistic Definitions

Unique Player

An authenticated BeamMP account identified by its permanent BeamMP ID.

A player reconnecting multiple times during the same period counts as one unique player for that period.

Example:

A player joins 15 times in one day.

Daily Unique Players: 1
Daily Join Sessions: 15

Join Session

Every accepted player connection recorded by the plugin.

Reconnections count as additional join sessions.

Authenticated users and guests both contribute to join-session totals unless specifically filtered by the script.

New Player

A player whose permanent BeamMP ID has never previously been stored in the plugin's player database.

A player can only be a new player once for the lifetime of the database.

Returning Player

A player whose BeamMP ID was already known before their first connection during the current reporting period.

Returning does not necessarily mean the player participated in the immediately previous month.

For example, a player who last played three months ago and returns today is still a returning player.

Retained Player

A player who:

Played during the immediately previous calendar month, and

Also played during the current calendar month.

This is more specific than the general "returning player" statistic.

Month-over-Month Retention

Calculated as:

Players from previous month who returned this month
--------------------------------------------------- × 100
        Previous month's unique players

Example:

July Unique Players: 400
July Players Returning in August: 160

Retention:

160 / 400 = 40.0%

Example: Returning vs. Retained

Assume August has:

Current unique players: 450
New players: 180
Returning players: 270
Retained July players: 160

The additional 110 returning users may have last played in June, May, or an even earlier month.

Therefore:

Returning Players: 270
Retained Previous-Month Players: 160

These values are intentionally different.

Reporting Periods

The plugin maintains four primary scopes.

Daily

Tracks:

Unique players today

New players today

Returning players today

Join sessions today

Guest joins today

Daily statistics reset when the configured analytics calendar reaches a new day.

The completed day is archived in stats.json.

Monthly

Tracks:

Unique players this month

New players this month

Returning players this month

Join sessions this month

Guest joins this month

Previous-month retained users

Month-over-month retention rate

Monthly statistics reset at the beginning of a new configured calendar month.

The completed month is archived in stats.json.

Yearly

Tracks:

Unique players this year

New players this year

Returning players this year

Join sessions this year

Guest joins this year

Yearly statistics reset at the beginning of a new configured calendar year.

The completed year is archived in stats.json.

All-Time

Tracks:

All known unique authenticated players

All recorded join sessions

All-time totals do not reset automatically.

Data Files

stats.json

Location:

Resources/Server/PlayerCounter/data/stats.json

This is the plugin's primary analytics database.

It contains:

Current daily statistics

Current monthly statistics

Current yearly statistics

Player database

Total join count

Historical daily summaries

Historical monthly summaries

Historical yearly summaries

Migration information

Do not manually modify this file while the BeamMP server is running.

Back it up before performing manual edits.

joins.csv

Location:

Resources/Server/PlayerCounter/data/joins.csv

This is the permanent raw connection log.

Columns:

timestamp_utc,date,month,year,beammp_id,player_name,is_guest

Example:

2026-08-10T03:12:41Z,2026-08-10,2026-08,2026,583921,Leshii413,false
2026-08-10T03:26:17Z,2026-08-10,2026-08,2026,774125,Hilly,false
2026-08-10T04:01:52Z,2026-08-10,2026-08,2026,583921,Leshii413,false

In this example:

Unique Players: 2
Join Sessions: 3

The CSV can be imported into:

Microsoft Excel

Google Sheets

LibreOffice Calc

Power BI

Tableau

SQL databases

Custom dashboards

Python or R analytics tools

Player Records

Authenticated players are stored in stats.json using an internal key similar to:

beammp:583921

Each player can contain metadata such as:

{
  "first_seen": "2026-08-10T05:00:00Z",
  "last_seen": "2026-08-10T07:15:00Z",
  "first_name": "ExamplePlayer",
  "last_name": "ExamplePlayer",
  "joins": 6,
  "legacy": false
}

first_seen

UTC timestamp from the first known connection.

last_seen

UTC timestamp from the most recent connection.

first_name

Player name observed when the user was first added to the V2 database.

last_name

Most recently observed player name.

This allows statistics to remain associated with the same BeamMP account even if the player changes their display name.

joins

Number of tracked join sessions associated with that player's database record.

legacy

Indicates that the player was migrated from the original PlayerCounter database and may not have complete first-seen metadata.

BeamMP Connectivity Checker

The script ignores:

CHK_BMP

This prevents BeamMP's automated connectivity/server-check process from being treated as a real player.

The filter is handled automatically.

Automatic Saving

Statistics are saved:

After each tracked player join

When a reporting-period rollover is processed through a command

During plugin initialization

During server shutdown

The plugin registers an onShutdown handler to save the current state before normal server shutdown.

A hard crash, power loss, forced process termination, or filesystem failure can still prevent the most recent unsaved operation from being written.

Because the script saves after every join, normal data-loss exposure should generally be limited.

Calendar Rollover

The plugin automatically checks for calendar changes when:

A player joins

playerstats is executed

retention is executed

/playerstats is executed

/retention is executed

The plugin starts

The server shuts down

Completed reporting periods are archived before the new period is initialized.

Retention History and Storage

Exact month-over-month retention requires knowing which individual BeamMP IDs participated in the previous month.

The plugin therefore temporarily preserves the previous month's player membership set.

After it is no longer required for the next month's retention calculation, older membership sets are removed while their aggregate statistics remain archived.

This prevents stats.json from continuously growing with a full duplicate user list for every historical month.

Historical monthly summaries can still include:

Unique users

Join sessions

Guest joins

New users

Returning users

Retained users

Previous month

Previous-month user count

Retention rate

Privacy and Data Remarks

This plugin is intended for aggregate server analytics.

It stores:

BeamMP account ID

Player display name

Join timestamps

Guest status

First and last observed names

First and last observed timestamps

Join counts

It does not intentionally require IP addresses for unique-player analytics.

Server operators are responsible for informing users about logging where required by their own policies, hosting provider, community rules, or applicable law.

Do not publicly expose stats.json or joins.csv unless you have intentionally reviewed the information they contain.

For public dashboards, aggregate statistics are preferable to publishing individual player records.

Recommended Backups

Back up this directory:

Resources/Server/PlayerCounter/data/

At minimum, preserve:

stats.json
joins.csv

A simple backup schedule is recommended before:

Updating the plugin

Updating the BeamMP server

Editing analytics configuration

Moving the server

Manually modifying statistics

Resetting counters

Resetting Statistics

To perform a complete analytics reset:

Stop the BeamMP server.

Back up the existing data directory if needed.

Remove or rename:

Resources/Server/PlayerCounter/data/stats.json
Resources/Server/PlayerCounter/data/joins.csv

Start the server.

The plugin will create a fresh statistics database and connection log.

Warning: This permanently removes historical analytics unless you made a backup.

Troubleshooting

Plugin Does Not Load

Verify the path is exactly:

Resources/Server/PlayerCounter/main.lua

Check the BeamMP server console for messages beginning with:

[PlayerCounter]

A successful startup should include:

[PlayerCounter] PlayerCounter + Retention Analytics loaded.

Data Directory Cannot Be Created

Look for:

[PlayerCounter] ERROR: Could not create data directory:

Verify the BeamMP server process has filesystem write permission for:

Resources/Server/PlayerCounter/

stats.json Cannot Be Written

Look for:

[PlayerCounter] ERROR: Could not write

Check:

File permissions

Directory ownership

Available disk space

Read-only filesystem settings

Existing JSON Cannot Be Read

Possible warning:

[PlayerCounter] WARNING: Could not decode stats.json

Stop the server and inspect the file for:

Manual-editing mistakes

Truncated JSON

Invalid characters

Incomplete writes caused by a previous crash

Restore a known-good backup if necessary.

Retention Says N/A

This is expected if the plugin does not have the complete immediately previous calendar month's membership set.

Typical causes:

Fresh installation

Upgrade from V1

Missing previous month

Previous-month data was removed

Analytics collection began midway through the current month

Once a complete previous month exists, retention is calculated automatically.

A Player Reconnected Multiple Times but Unique Count Did Not Increase

This is expected.

The plugin separates:

Unique Players

from:

Join Sessions

One player reconnecting ten times is:

1 unique player
10 join sessions

Guests Do Not Increase Unique Counts

This is expected with:

local COUNT_GUESTS_AS_UNIQUE = false

Guest connections still increase join-session and guest-join statistics.

Console Output

Every tracked join produces a console line similar to:

[PlayerCounter] ExamplePlayer joined | Today: 47 unique, 12 new, 35 returning, 103 joins | Month: 381 unique, 119 new, 262 returning, 1824 joins | MoM retention: 160/400 (40.0%) | Year: 2184 unique, 1087 new, 1097 returning, 18492 joins | All-time: 3719 unique, 31527 joins

The plugin may also report:

[PlayerCounter] Ignoring CHK_BMP server check.

This is normal.

Suggested Server Metrics

For community-growth reporting, the most useful metrics are:

Daily Unique Players
Monthly Unique Players
New Players
Returning Players
Month-over-Month Retention
Monthly Join Sessions
Annual Unique Players
All-Time Unique Players

A useful monthly report might look like:

AUGUST 2026

Unique Players:          381
New Players:             119
Returning Players:       262
Join Sessions:         1,824

Previous Month Users:    400
Players Retained:        160
Monthly Retention:     40.0%

2026 Unique Players:   2,184
All-Time Players:      3,719

File Safety

Do not delete stats.json unless you intend to reset your unique-player and retention database.

Do not delete joins.csv if you want to preserve the raw historical join log.

When updating the script, the safest procedure is:

1. Stop server
2. Back up PlayerCounter/data/
3. Replace main.lua
4. Start server
5. Run playerstats
6. Run retention
7. Confirm there are no PlayerCounter errors

License

GNU General Public License v3.0

You may use, modify, and redistribute this software under the terms of the GPL-3.0 license.

If you distribute modified versions, the GPL's source-code and license requirements apply.

See the repository's LICENSE file for the complete license text.

Repository Description

BeamMP player analytics plugin with daily, monthly, yearly and all-time unique-user tracking, join counts, new/returning players, and month-over-month retention.
