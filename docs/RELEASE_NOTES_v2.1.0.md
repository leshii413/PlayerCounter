## PlayerCounter 2.1.0

- **Players online:** peak and average per day, month and year; a weekday × hour activity grid; a 24 h graph; joins in the last 24 hours.
- **Playtime without AFK:** playtime pauses when a player hasn't moved for 5 minutes. All-time and monthly playtime leaderboards (`pc.top`).
- **Time zones:** calendar offset with US/EU daylight saving (`utc_offset_hours`, `dst`, `time_zone_name`).
- **Driven vehicle:** an optional client mod (`playercounter.zip` in `Resources/Client/`) shows the vehicle each player is driving or watching.
- **Discord status:** a 24 h player graph, plus driving / watching / AFK in player lines.
- **Stats website** (`website/`): a PHP site for shared hosting with live players, graphs, heatmap and leaderboards per server and across all servers. Each BeamMP server uploads its own signed stats. BeamMP IDs are never published, and times show in the visitor's own time zone.

**Install:** extract the zip. Copy `Resources/` into your BeamMP server and restart. For the website, follow `website/README.md`. All details are in [CHANGELOG.md](https://github.com/leshii413/PlayerCounter/blob/main/CHANGELOG.md).

By Leshii413 · [Patreon](https://www.patreon.com/Leshii413)
