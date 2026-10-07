#!/usr/bin/env python3
"""
PlayerCounter Discord live status
=================================

Every few minutes (default 5) this script asks each of your Pterodactyl
servers whether it is running, reads the live snapshot that PlayerCounter
2.0.1+ writes to Resources/Server/PlayerCounter/data/live.json, and keeps ONE
Discord message per server up to date (edited in place, no channel spam):

    * online / offline / starting status and player count (x / max)
    * every player online: name, session time, total playtime, vehicle(s)
    * today / this month / all-time stats from PlayerCounter

Needs only Python 3.8+ (standard library). Run it anywhere that can reach your
panel and Discord: a small VPS, your PC, or a Pterodactyl "Python" server.

    python3 discord_status.py                  # loop forever
    python3 discord_status.py --once           # single refresh (for cron)
    python3 discord_status.py --once --dry-run # print the Discord payload, send nothing

Settings: discord_status.json next to this script (see discord_status.example.json).
Secrets can come from the environment instead of the file:
    PTERODACTYL_API_KEY, DISCORD_WEBHOOK_URL

License: GPL-3.0, part of https://github.com/leshii413/PlayerCounter
"""

import argparse
import hashlib
import json
import os
import re
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

VERSION = "2.0.1"
USER_AGENT = "PlayerCounter-DiscordStatus/" + VERSION
HERE = os.path.dirname(os.path.abspath(__file__))

DEFAULTS = {
    "panel_url": "",
    "api_key": "",
    "webhook_url": "",
    "interval_seconds": 300,
    "live_json_path": "/Resources/Server/PlayerCounter/data/live.json",
    "stale_after_seconds": 180,
    "show_beammp_ids": False,
    "show_stats": True,
    "max_players_listed": 30,
    "webhook_username": "Server Status",
    "webhook_avatar_url": "",
    "vehicle_names": {},
    "servers": [],
}

# Vanilla BeamNG model keys -> display names. Mod vehicles fall back to their
# model key; add your own under "vehicle_names" in the config.
VEHICLE_NAMES = {
    "pickup": "Gavril D-Series",
    "van": "Gavril H-Series",
    "fullsize": "Gavril Grand Marshal",
    "bluebuck": "Gavril Bluebuck",
    "barstow": "Gavril Barstow",
    "roamer": "Gavril Roamer",
    "md_series": "Gavril MD-Series",
    "us_semi": "Gavril T-Series",
    "covet": "Ibishu Covet",
    "pessima": "Ibishu Pessima",
    "midsize": "Ibishu Pessima (1996)",
    "miramar": "Ibishu Miramar",
    "hopper": "Ibishu Hopper",
    "bx": "Ibishu BX-Series",
    "pigeon": "Ibishu Pigeon",
    "wigeon": "Ibishu Wigeon",
    "etk800": "ETK 800-Series",
    "etkc": "ETK K-Series",
    "etki": "ETK I-Series",
    "sbr": "Hirochi SBR4",
    "moonhawk": "Bruckell Moonhawk",
    "legran": "Bruckell LeGran",
    "bastion": "Bruckell Bastion",
    "burnside": "Burnside Special",
    "vivace": "Cherrier Vivace",
    "autobello": "Autobello Piccolina",
    "scintilla": "Civetta Scintilla",
    "bolide": "Civetta Bolide",
    "wendover": "Soliad Wendover",
    "lansdale": "Soliad Lansdale",
    "citybus": "Wentward DT40L",
}

COLOR_ONLINE = 0x2ECC71
COLOR_EMPTY = 0x95A5A6
COLOR_WARN = 0xF1C40F
COLOR_OFFLINE = 0xE74C3C

STATE_DOT = {"online": "\U0001F7E2", "empty": "⚪", "warn": "\U0001F7E1", "offline": "\U0001F534"}

running = True


def log(message):
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{stamp}] {message}", flush=True)


# --------------------------------------------------------------------------
# Config / state
# --------------------------------------------------------------------------

def load_config(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            loaded = json.load(fh)
    except FileNotFoundError:
        sys.exit(f"Config not found: {path}\nCopy discord_status.example.json to discord_status.json and edit it.")
    except json.JSONDecodeError as exc:
        sys.exit(f"Config {path} is not valid JSON: {exc}")

    cfg = dict(DEFAULTS)
    cfg.update({k: v for k, v in loaded.items() if not k.startswith("_")})
    cfg["api_key"] = os.environ.get("PTERODACTYL_API_KEY") or cfg["api_key"]
    cfg["webhook_url"] = os.environ.get("DISCORD_WEBHOOK_URL") or cfg["webhook_url"]
    cfg["panel_url"] = str(cfg["panel_url"]).rstrip("/")
    cfg["interval_seconds"] = max(60, int(cfg["interval_seconds"]))

    names = dict(VEHICLE_NAMES)
    names.update(cfg.get("vehicle_names") or {})
    cfg["vehicle_names"] = names

    problems = []
    if not cfg["servers"]:
        problems.append("add at least one entry to \"servers\"")
    for i, server in enumerate(cfg["servers"]):
        if not server.get("id") and not server.get("live_json_file"):
            problems.append(f"servers[{i}] needs \"id\" (Pterodactyl server id) or \"live_json_file\"")
        if not (server.get("webhook_url") or cfg["webhook_url"]):
            problems.append(f"servers[{i}] has no webhook_url and there is no global webhook_url")
    if any(s.get("id") for s in cfg["servers"]):
        if not cfg["panel_url"]:
            problems.append("panel_url is required for Pterodactyl servers")
        if not cfg["api_key"] or "xxxx" in cfg["api_key"]:
            problems.append("api_key (or PTERODACTYL_API_KEY) is required for Pterodactyl servers")
    if problems:
        sys.exit("Config problems:\n  - " + "\n  - ".join(problems))
    return cfg


def load_state(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
            return data if isinstance(data, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2)
    os.replace(tmp, path)


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

class HttpError(Exception):
    def __init__(self, status, body, retry_after=None):
        super().__init__(f"HTTP {status}: {body[:200]}")
        self.status = status
        self.body = body
        self.retry_after = retry_after


def http(method, url, headers=None, body=None, timeout=20):
    data = None
    all_headers = {"User-Agent": USER_AGENT}
    all_headers.update(headers or {})
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        all_headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, method=method, headers=all_headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        text = exc.read().decode("utf-8", "replace")
        retry_after = None
        if exc.code == 429:
            try:
                retry_after = float(json.loads(text).get("retry_after", 1))
            except (ValueError, AttributeError):
                retry_after = float(exc.headers.get("Retry-After", 1) or 1)
        raise HttpError(exc.code, text, retry_after)


# --------------------------------------------------------------------------
# Pterodactyl
# --------------------------------------------------------------------------

def ptero_get(cfg, path, raw=False):
    url = cfg["panel_url"] + "/api/client/servers/" + path
    headers = {"Authorization": "Bearer " + cfg["api_key"], "Accept": "application/json"}
    _, text = http("GET", url, headers=headers)
    return text if raw else json.loads(text)


def fetch_server(cfg, server):
    """Returns dict(panel_state, uptime_ms, live, error)."""
    result = {"panel_state": None, "uptime_ms": None, "live": None, "error": None}

    if server.get("live_json_file") and not server.get("id"):
        # Same machine as the BeamMP server: read the file directly.
        result["panel_state"] = "running"
        try:
            with open(server["live_json_file"], "r", encoding="utf-8") as fh:
                result["live"] = json.load(fh)
        except FileNotFoundError:
            result["error"] = "live.json not found (is PlayerCounter 2.0.1+ installed?)"
        except json.JSONDecodeError:
            result["error"] = "live.json could not be read"
        return result

    sid = urllib.parse.quote(str(server["id"]), safe="")
    try:
        resources = ptero_get(cfg, f"{sid}/resources")
        attrs = resources.get("attributes", {})
        result["panel_state"] = attrs.get("current_state")
        result["uptime_ms"] = (attrs.get("resources") or {}).get("uptime")
    except HttpError as exc:
        if exc.status in (401, 403):
            result["error"] = "API key has no access to this server"
        elif exc.status == 404:
            result["error"] = "server id not found on the panel"
        else:
            result["error"] = f"panel error ({exc.status})"
        return result
    except (urllib.error.URLError, OSError, ValueError) as exc:
        result["error"] = f"panel unreachable ({exc.__class__.__name__})"
        return result

    if result["panel_state"] not in ("running", "starting"):
        return result

    path = server.get("live_json_path") or cfg["live_json_path"]
    query = urllib.parse.urlencode({"file": path})
    try:
        text = ptero_get(cfg, f"{sid}/files/contents?{query}", raw=True)
        result["live"] = json.loads(text)
    except HttpError as exc:
        if exc.status == 404:
            result["error"] = "live.json not found (is PlayerCounter 2.0.1+ installed?)"
        elif exc.status in (401, 403):
            result["error"] = "API key cannot read files on this server"
        else:
            result["error"] = f"could not read live.json ({exc.status})"
    except ValueError:
        result["error"] = "live.json could not be read (mid-write?), will retry"
    except (urllib.error.URLError, OSError) as exc:
        result["error"] = f"panel unreachable ({exc.__class__.__name__})"
    return result


# --------------------------------------------------------------------------
# Formatting
# --------------------------------------------------------------------------

BEAMMP_COLOR_CODES = re.compile(r"\^[0-9a-fA-FlmnoprLMNOPR]")
MARKDOWN = re.compile(r"([\\*_~`|>\[\]()#:@])")


def clean_name(text):
    return BEAMMP_COLOR_CODES.sub("", str(text or "")).strip()


def escape_md(text):
    return MARKDOWN.sub(r"\\\1", clean_name(text))


def duration(seconds):
    seconds = max(0, int(seconds or 0))
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    minutes = rest // 60
    if days:
        return f"{days}d {hours}h"
    if hours:
        return f"{hours}h {minutes:02d}m"
    return f"{minutes}m"


def as_list(value):
    # BeamMP encodes an empty Lua table as {} rather than [].
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return list(value.values())
    return []


def vehicle_text(cfg, vehicles):
    vehicles = [v for v in as_list(vehicles) if isinstance(v, dict)]
    if not vehicles:
        return "on foot / no vehicle"
    parts = []
    for v in vehicles[:3]:
        model = str(v.get("model") or "unknown")
        name = cfg["vehicle_names"].get(model, model)
        config = v.get("config")
        if config and config not in ("base", model):
            name += f" ({config})"
        parts.append(escape_md(name))
    if len(vehicles) > 3:
        parts.append(f"+{len(vehicles) - 3} more")
    return ", ".join(parts)


def num(value):
    try:
        return f"{int(value):,}"
    except (TypeError, ValueError):
        return "0"


def build_embed(cfg, server, fetched, now):
    live = fetched["live"] if isinstance(fetched["live"], dict) else None
    title_name = server.get("name") or (live and clean_name(live.get("server", {}).get("name"))) or str(server.get("id"))
    panel_state = fetched["panel_state"]
    lines = []
    fields = []
    status = None  # online / empty / warn / offline
    age = None

    if live:
        age = now - int(live.get("updated_unix") or 0)

    if fetched["error"] and not live:
        status = "warn" if panel_state in ("running", "starting") else "offline"
        state_text = {"running": "Running", "starting": "Starting"}.get(panel_state, "Unknown")
        lines.append(f"**{state_text}** · {fetched['error']}")
    elif panel_state not in ("running", "starting"):
        status = "offline"
        lines.append("**Offline**" if panel_state in ("offline", None) else f"**Offline** ({panel_state})")
    elif panel_state == "starting" or live.get("state") == "stopped":
        status = "warn"
        lines.append("**Starting up…**")
    elif age is not None and age > int(cfg["stale_after_seconds"]):
        status = "warn"
        lines.append(f"**Running**, but PlayerCounter has not reported for {duration(age)} "
                     "(plugin error or server hung?)")

    players = []
    if live and status != "offline" and live.get("state") != "stopped":
        players = [p for p in as_list(live.get("players")) if isinstance(p, dict)]
        players.sort(key=lambda p: -int(p.get("session_seconds") or 0))
        info = live.get("server") or {}
        max_players = info.get("max_players") or "?"
        header = f"**{len(players)} / {max_players} players online**"
        if info.get("map"):
            header += f" · Map: `{clean_name(info['map'])}`"
        lines.insert(0, header)
        if status is None:
            status = "online" if players else "empty"

        if server.get("connect"):
            lines.append(f"Connect: `{server['connect']}`")
        uptime = fetched.get("uptime_ms")
        if uptime:
            lines.append(f"Uptime: {duration(int(uptime) / 1000)}")

        if players:
            lines.append("")
            drift = max(0, age or 0) if status == "online" else 0
            shown = players[: int(cfg["max_players_listed"])]
            for p in shown:
                name = escape_md(p.get("name"))
                if p.get("guest"):
                    name += " *(guest)*"
                if cfg["show_beammp_ids"] and p.get("beammp_id"):
                    name += f" `#{p['beammp_id']}`"
                session = int(p.get("session_seconds") or 0) + drift
                time_text = f"⏱ {duration(session)}"
                if p.get("session_resumed"):
                    time_text += "+"
                total = p.get("total_playtime_seconds")
                if total is not None:
                    time_text += f" · {duration(int(total) + drift)} total"
                lines.append(f"**{name}** — \U0001F697 {vehicle_text(cfg, p.get('vehicles'))}")
                lines.append(f" {time_text}")
            if len(players) > len(shown):
                lines.append(f"…and {len(players) - len(shown)} more")
        elif status == "empty":
            lines.append("")
            lines.append("Nobody is online right now.")

    if live and cfg["show_stats"] and isinstance(live.get("stats"), dict):
        stats = live["stats"]
        today = stats.get("today") or {}
        month = stats.get("month") or {}
        retention = stats.get("retention") or {}
        all_time = stats.get("all_time") or {}
        month_text = f"{num(month.get('unique_users'))} players · {num(month.get('joins'))} joins"
        if retention.get("rate") is not None:
            month_text += f"\n{float(retention['rate']):.1f}% kept from last month"
        fields = [
            {"name": "Today", "value": f"{num(today.get('unique_users'))} players · {num(today.get('joins'))} joins · "
                                       f"{num(today.get('new_users'))} new", "inline": True},
            {"name": "This month", "value": month_text, "inline": True},
            {"name": "All-time", "value": f"{num(all_time.get('unique_users'))} players · "
                                          f"{num(all_time.get('joins'))} joins", "inline": True},
        ]

    status = status or "empty"
    description = "\n".join(lines)
    if len(description) > 4000:
        description = description[:3990].rsplit("\n", 1)[0] + "\n…"

    color = {"online": COLOR_ONLINE, "empty": COLOR_EMPTY, "warn": COLOR_WARN, "offline": COLOR_OFFLINE}[status]
    embed = {
        "title": f"{STATE_DOT[status]} {clean_name(title_name)}"[:256],
        "description": description or "​",
        "color": color,
        "fields": fields,
        "footer": {"text": f"PlayerCounter {VERSION} · updates every {duration(cfg['interval_seconds'])}"},
        "timestamp": datetime.fromtimestamp(now, timezone.utc).isoformat(),
    }
    return embed


# --------------------------------------------------------------------------
# Discord
# --------------------------------------------------------------------------

def webhook_urls(webhook_url):
    parts = urllib.parse.urlsplit(webhook_url)
    base = urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path.rstrip("/"), "", ""))
    query = urllib.parse.parse_qs(parts.query)
    keep = {k: v[0] for k, v in query.items() if k == "thread_id"}
    return base, keep


def message_key(webhook_url, server):
    base, _ = webhook_urls(webhook_url)
    digest = hashlib.sha256(base.encode()).hexdigest()[:12]  # never store the token itself
    return f"{digest}:{server.get('id') or server.get('live_json_file')}"


def discord_send(webhook_url, payload, message_id):
    """Edits message_id if given, otherwise posts a new message. Returns the message id."""
    base, params = webhook_urls(webhook_url)
    for attempt in range(3):
        try:
            if message_id:
                url = f"{base}/messages/{message_id}"
                if params:
                    url += "?" + urllib.parse.urlencode(params)
                http("PATCH", url, body=payload)
                return message_id
            url = base + "?" + urllib.parse.urlencode(dict(params, wait="true"))
            _, text = http("POST", url, body=payload)
            return json.loads(text)["id"]
        except HttpError as exc:
            if exc.status == 429 and attempt < 2:
                time.sleep(min(30.0, exc.retry_after or 1.0) + 0.25)
                continue
            if exc.status == 404 and message_id:
                # Message was deleted (or the webhook changed): post a fresh one.
                log("Status message not found, posting a new one.")
                message_id = None
                continue
            raise
    raise RuntimeError("Discord rate limit kept blocking the update")


# --------------------------------------------------------------------------
# Main loop
# --------------------------------------------------------------------------

def refresh(cfg, state, state_path, dry_run):
    now = int(time.time())
    messages = state.setdefault("messages", {})
    for server in cfg["servers"]:
        label = clean_name(server.get("name") or server.get("id") or server.get("live_json_file"))
        try:
            fetched = fetch_server(cfg, server)
            embed = build_embed(cfg, server, fetched, now)
            payload = {
                "embeds": [embed],
                "allowed_mentions": {"parse": []},  # player names can never ping anyone
            }
            if cfg["webhook_username"]:
                payload["username"] = cfg["webhook_username"]
            if cfg["webhook_avatar_url"]:
                payload["avatar_url"] = cfg["webhook_avatar_url"]

            if dry_run:
                print(json.dumps(payload, indent=2, ensure_ascii=False))
                continue

            webhook_url = server.get("webhook_url") or cfg["webhook_url"]
            key = message_key(webhook_url, server)
            new_id = discord_send(webhook_url, payload, messages.get(key))
            if new_id != messages.get(key):
                messages[key] = new_id
                save_state(state_path, state)
            players = len(as_list((fetched["live"] or {}).get("players"))) if fetched["live"] else 0
            log(f"{label}: {fetched['panel_state'] or 'n/a'}, {players} online"
                + (f" ({fetched['error']})" if fetched["error"] else ""))
        except Exception as exc:  # keep the other servers updating
            log(f"{label}: update failed: {exc}")


def main():
    parser = argparse.ArgumentParser(description="Live BeamMP server status in Discord via Pterodactyl.")
    parser.add_argument("--config", default=os.path.join(HERE, "discord_status.json"))
    parser.add_argument("--state", default=None, help="where message ids are kept (default: next to the config)")
    parser.add_argument("--once", action="store_true", help="refresh once and exit")
    parser.add_argument("--dry-run", action="store_true", help="print payloads instead of sending them")
    args = parser.parse_args()

    cfg = load_config(args.config)
    state_path = args.state or os.path.join(os.path.dirname(os.path.abspath(args.config)), "discord_status_state.json")
    state = load_state(state_path)

    def stop(*_):
        global running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    log(f"PlayerCounter Discord status {VERSION}: {len(cfg['servers'])} server(s), "
        f"every {cfg['interval_seconds']}s")
    while running:
        started = time.time()
        refresh(cfg, state, state_path, args.dry_run)
        if args.once:
            break
        while running and time.time() - started < cfg["interval_seconds"]:
            time.sleep(1)
    log("Stopped.")


if __name__ == "__main__":
    main()
