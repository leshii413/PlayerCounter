/* PlayerCounter stats page. Loads api.php every minute and renders it.
   Every value from the servers is inserted as text, never as HTML. */
(function () {
  "use strict";

  var REFRESH_MS = 60000;
  var SVG = "http://www.w3.org/2000/svg";
  var DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  var VEHICLES = {
    pickup: "Gavril D-Series", van: "Gavril H-Series", fullsize: "Gavril Grand Marshal",
    bluebuck: "Gavril Bluebuck", barstow: "Gavril Barstow", roamer: "Gavril Roamer",
    md_series: "Gavril MD-Series", us_semi: "Gavril T-Series", covet: "Ibishu Covet",
    pessima: "Ibishu Pessima", midsize: "Ibishu Pessima (1996)", miramar: "Ibishu Miramar",
    hopper: "Ibishu Hopper", bx: "Ibishu BX-Series", pigeon: "Ibishu Pigeon",
    wigeon: "Ibishu Wigeon", etk800: "ETK 800-Series", etkc: "ETK K-Series",
    etki: "ETK I-Series", sbr: "Hirochi SBR4", moonhawk: "Bruckell Moonhawk",
    legran: "Bruckell LeGran", bastion: "Bruckell Bastion", burnside: "Burnside Special",
    vivace: "Cherrier Vivace", autobello: "Autobello Piccolina", scintilla: "Civetta Scintilla",
    bolide: "Civetta Bolide", wendover: "Soliad Wendover", lansdale: "Soliad Lansdale",
    citybus: "Wentward DT40L"
  };
  var STATUS_TEXT = {
    online: "Online", empty: "Online, empty", starting: "Starting up",
    offline: "Offline", error: "Not reporting", stale: "No recent data"
  };

  var boardScope = {};     // board id -> "month" | "all_time"
  var lastCounts = {};     // server key -> player count, to animate changes
  var data = null;

  // Times on the page: the site's display time zone (config.php), else the
  // visitor's own. Falls back to local time if the browser lacks the zone.
  function tzOpts(extra) {
    var o = {};
    Object.keys(extra || {}).forEach(function (k) { o[k] = extra[k]; });
    if (data && data.display_time_zone) o.timeZone = data.display_time_zone;
    return o;
  }
  function fmtTime(date, extra) {
    try { return date.toLocaleTimeString([], tzOpts(extra)); }
    catch (e) { return date.toLocaleTimeString([], extra); }
  }
  // Hour (0-23) and minute of a date in the display time zone.
  function hourMinute(date) {
    try {
      var parts = new Intl.DateTimeFormat("en-GB", tzOpts({ hour: "2-digit", minute: "2-digit", hourCycle: "h23" })).formatToParts(date);
      var get = function (t) { return Number((parts.filter(function (p) { return p.type === t; })[0] || {}).value); };
      return { h: get("hour"), m: get("minute") };
    } catch (e) {
      return { h: date.getHours(), m: date.getMinutes() };
    }
  }
  function zoneName() {
    if (data && data.display_time_zone_name) return data.display_time_zone_name;
    if (data && data.display_time_zone) return data.display_time_zone.replace(/_/g, " ");
    return "your local time";
  }

  // DOM helper: h("tag.class", {attr}, children...)
  function h(spec, attrs) {
    var parts = spec.split(".");
    var el = document.createElement(parts[0]);
    if (parts.length > 1) el.className = parts.slice(1).join(" ");
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        if (attrs[k] === null || attrs[k] === undefined || attrs[k] === false) return;
        if (k === "text") el.textContent = attrs[k];
        else el.setAttribute(k, attrs[k] === true ? "" : attrs[k]);
      });
    }
    for (var i = 2; i < arguments.length; i++) append(el, arguments[i]);
    return el;
  }
  function append(el, child) {
    if (child === null || child === undefined || child === false) return;
    if (Array.isArray(child)) { child.forEach(function (c) { append(el, c); }); return; }
    el.appendChild(typeof child === "string" ? document.createTextNode(child) : child);
  }
  function s(tag, attrs, text) {
    var el = document.createElementNS(SVG, tag);
    Object.keys(attrs || {}).forEach(function (k) { el.setAttribute(k, attrs[k]); });
    if (text !== undefined) el.textContent = text;
    return el;
  }

  function duration(sec) {
    sec = Math.max(0, Math.floor(sec || 0));
    var d = Math.floor(sec / 86400), hr = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60);
    if (d) return d + "d " + hr + "h";
    if (hr) return hr + "h " + (m < 10 ? "0" : "") + m + "m";
    return m + "m";
  }
  function n(v) { return (Number(v) || 0).toLocaleString(); }
  function vehicleName(v) {
    if (!v) return "";
    var name = VEHICLES[v.model] || v.model;
    return v.config && v.config !== v.model ? name + " (" + v.config + ")" : name;
  }
  function ago(iso) {
    if (!iso) return "never";
    var sec = (Date.now() - Date.parse(iso)) / 1000;
    if (sec < 90) return "just now";
    if (sec < 3600) return Math.round(sec / 60) + " min ago";
    return duration(sec) + " ago";
  }
  function monthLabel(key) {
    var m = /^(\d{4})-(\d{2})$/.exec(key || "");
    if (!m) return "This month";
    return new Date(Date.UTC(+m[1], +m[2] - 1, 15)).toLocaleString(undefined, { month: "long", timeZone: "UTC" });
  }
  function slug(key) { return "server-" + String(key).replace(/[^a-z0-9_-]/gi, ""); }

  // Plates ------------------------------------------------------------------

  function renderPlates(servers) {
    var box = document.getElementById("plates");
    box.textContent = "";
    if (!servers.length) {
      box.appendChild(h("p.empty-note", { text: "Waiting for the first BeamMP server to report. Servers appear here about a minute after they start with PlayerCounter installed." }));
      return;
    }
    servers.forEach(function (sv) {
      var down = sv.status !== "online" && sv.status !== "empty";
      var num = h("span.plate-number", { text: down ? "–" : String(sv.player_count), "aria-hidden": "true" });
      if (lastCounts[sv.key] !== undefined && lastCounts[sv.key] !== sv.player_count) num.classList.add("changed");
      lastCounts[sv.key] = sv.player_count;
      var label = sv.name + ": " + (down ? STATUS_TEXT[sv.status] : sv.player_count + " of " + sv.max_players + " players online");
      box.appendChild(h("a.plate" + (down ? ".is-down" : ""), { href: "#" + slug(sv.key), "aria-label": label },
        num,
        h("span.plate-name", { text: sv.name }),
        h("span.plate-meta", null, h("span.status.status-" + sv.status, { text: STATUS_TEXT[sv.status] || sv.status }),
          down ? null : ", " + sv.player_count + " of " + (sv.max_players || "?")),
        h("span.plate-meta", { text: sv.map ? "Map: " + sv.map.replace(/_/g, " ") : "" })
      ));
    });
  }

  // Leaderboards --------------------------------------------------------------

  function renderToggle(container, id, monthKey, onChange) {
    container.textContent = "";
    var scope = boardScope[id] || "month";
    [["month", monthLabel(monthKey)], ["all_time", "All time"]].forEach(function (opt) {
      var b = h("button", { type: "button", "aria-pressed": scope === opt[0] ? "true" : "false", text: opt[1] });
      b.addEventListener("click", function () { boardScope[id] = opt[0]; onChange(); });
      container.appendChild(b);
    });
  }

  function boardList(rows, withServers) {
    if (!rows || !rows.length) return h("p.empty-note", { text: "No playtime recorded for this period yet." });
    return h("ol.board", null, rows.map(function (r, i) {
      var sub = n(r.joins) + " joins, last seen " + (r.last_seen || "?");
      if (withServers && r.servers > 1) sub += ", on " + r.servers + " servers";
      return h("li", null,
        h("span.rank", { text: String(i + 1) }),
        h("span.who", null, r.name, h("span.sub", { text: sub })),
        h("span.time", { text: duration(r.playtime_seconds) }));
    }));
  }

  function renderSeries(series) {
    var section = document.getElementById("series-section");
    if (!series || (!series.all_time.length && !series.month.length) || data.servers.length < 1) {
      section.hidden = true;
      return;
    }
    section.hidden = false;
    var draw = function () {
      renderToggle(section.querySelector(".toggle"), "series", series.month_key, draw);
      var box = document.getElementById("series-board");
      box.textContent = "";
      box.appendChild(boardList(series[boardScope.series || "month"], true));
    };
    draw();
  }

  // 24 h chart ----------------------------------------------------------------

  function chart(graph) {
    var wrap = h("div.chart");
    var values = graph && graph.values ? graph.values : [];
    var real = values.filter(function (v) { return v >= 0; });
    if (!real.length) {
      wrap.appendChild(h("p.empty-note", { text: "The graph fills in once the server has been running for a few minutes." }));
      return wrap;
    }
    var W = 520, H = 210, L = 30, R = 8, T = 22, B = 28;
    var peak = Math.max.apply(null, real);
    var top = Math.max(4, Math.ceil(peak / 4) * 4);
    var step = top / 4;
    var count = values.length, bucket = graph.bucket_seconds || 300, start = graph.start_unix;
    var x = function (i) { return L + (i / count) * (W - L - R); };
    var y = function (v) { return T + (1 - v / top) * (H - T - B); };
    var svg = s("svg", { viewBox: "0 0 " + W + " " + H, role: "img",
      "aria-label": "Players online over the last 24 hours, peak " + peak });
    var grid = s("g", { "class": "grid" }), axis = s("g", { "class": "axis" });
    for (var v = 0; v <= top; v += step) {
      grid.appendChild(s("line", { x1: L, x2: W - R, y1: y(v), y2: y(v) }));
      axis.appendChild(s("text", { x: L - 6, y: y(v) + 4, "text-anchor": "end" }, String(v)));
    }
    for (var i = 0; i < count; i++) {
      var t = start + i * bucket;
      var d = new Date(t * 1000);
      var hm = hourMinute(d);
      if (hm.m === 0 && hm.h % 3 === 0) {
        axis.appendChild(s("text", { x: x(i), y: H - 8, "text-anchor": "middle" },
          fmtTime(d, { hour: "numeric" })));
      }
    }
    svg.appendChild(grid);
    // step path per continuous run (gaps = -1 stay empty)
    var line = "", area = "", runStart = null, prev = null;
    function closeRun(endI) {
      if (runStart === null) return;
      area += "L" + x(endI) + "," + y(0) + "L" + x(runStart) + "," + y(0) + "Z";
      runStart = null;
    }
    values.forEach(function (val, i) {
      if (val < 0) { closeRun(i); prev = null; return; }
      if (runStart === null) {
        runStart = i;
        line += "M" + x(i) + "," + y(val);
        area += "M" + x(i) + "," + y(val);
      } else if (val !== prev) {
        line += "L" + x(i) + "," + y(prev) + "L" + x(i) + "," + y(val);
        area += "L" + x(i) + "," + y(prev) + "L" + x(i) + "," + y(val);
      }
      prev = val;
      if (i === count - 1 || values[i + 1] < 0) {
        line += "L" + x(i + 1) + "," + y(val);
        area += "L" + x(i + 1) + "," + y(val);
      }
    });
    closeRun(count);
    svg.appendChild(s("path", { "class": "area", d: area }));
    svg.appendChild(s("path", { "class": "line", d: line }));
    svg.appendChild(axis);
    var pi = values.lastIndexOf(peak);
    var px = x(pi + 0.5), py = y(peak);
    var g = s("g", { "class": "peak" });
    g.appendChild(s("circle", { cx: px, cy: py, r: 5 }));
    var when = fmtTime(new Date((start + pi * bucket) * 1000), { hour: "numeric", minute: "2-digit" });
    g.appendChild(s("text", { x: px, y: py - 10, "text-anchor": px > W - 90 ? "end" : "middle" }, "Peak " + peak + " at " + when));
    svg.appendChild(g);
    wrap.appendChild(svg);
    wrap.appendChild(h("p.chart-note", { text: "Most players on at once in each 5-minute window. Gaps mean the server was down." }));
    return wrap;
  }

  // Heatmap ---------------------------------------------------------------------

  function heatmap(values, offset, calendarName) {
    var wrap = h("div");
    var real = (values || []).filter(function (v) { return v >= 0; });
    if (!real.length) {
      wrap.appendChild(h("p.empty-note", { text: "Builds up over the month as the server runs." }));
      return wrap;
    }
    var busiest = Math.max.apply(null, real);   // real value, may be 0
    var max = busiest || 1;                      // scale only; never shown
    var grid = h("div.heat", { role: "img", "aria-label": "Average players online by weekday and hour this month" });
    grid.appendChild(h("span"));
    for (var hr = 0; hr < 24; hr++) grid.appendChild(h("span.hr", { text: hr % 6 === 0 ? String(hr) : "" }));
    for (var d = 0; d < 7; d++) {
      grid.appendChild(h("span.lbl", { text: DAYS[d] }));
      for (var hh = 0; hh < 24; hh++) {
        var v = values[d * 24 + hh];
        var level = v < 0 ? null : v <= 0 ? 0 : Math.min(4, Math.ceil((v / max) * 4));
        var title = DAYS[d] + " " + (hh < 10 ? "0" : "") + hh + ":00 – " +
          (v < 0 ? "no data" : v.toFixed(1) + " players on average");
        grid.appendChild(h("span.cell" + (level === null ? ".nodata" : ""), { "data-l": level === null ? null : String(level), title: title }));
      }
    }
    wrap.appendChild(grid);
    var tz = (calendarName ? calendarName + ", " : "") + "UTC" + (offset >= 0 ? "+" : "") + offset;
    wrap.appendChild(h("div.heat-legend", null, "Quiet",
      [0, 1, 2, 3, 4].map(function (l) { return h("span.sw", { "data-l": String(l) }); }),
      busiest > 0
        ? "Busy. The busiest hour so far averages " + busiest.toFixed(1) + " players. Striped hours aren't recorded yet. Times in " + tz + "."
        : "Busy. No players online in the hours recorded so far. Striped hours aren't recorded yet. Times in " + tz + "."));
    return wrap;
  }

  // Server section ---------------------------------------------------------------

  function driversTable(sv) {
    if (sv.status !== "online") {
      var why = {
        empty: "Nobody is on right now.",
        offline: "The server is offline.",
        starting: "The server is starting up.",
        stale: "No update from this server for a while. The status script may be stopped.",
        error: "The server is running, but PlayerCounter hasn't reported recently" + (sv.error ? " (" + sv.error + ")." : ".")
      };
      return h("p.empty-note", { text: why[sv.status] || "" });
    }
    if (!data.show_player_names) return h("p.empty-note", { text: sv.player_count + " players online." });
    var rows = sv.players.map(function (p) {
      var veh;
      if (p.driving && !p.driving.own) veh = h("span.watch", { text: "Watching " + (p.driving.owner || "another player") + " (" + vehicleName(p.driving) + ")" });
      else if (p.driving) veh = h("span.veh", { text: vehicleName(p.driving) });
      else if (p.vehicles.length) veh = h("span.veh", { text: p.vehicles.slice(0, 3).map(vehicleName).join(", ") });
      else veh = h("span.watch", { text: "On foot" });
      return h("tr", null,
        h("td.name", null, p.name, p.guest ? h("span.tag", { text: "guest" }) : null,
          p.afk ? h("span.tag.tag-afk", { text: "AFK " + duration(p.idle_seconds), title: "Not moving; playtime paused" }) : null),
        h("td.veh-cell", null, veh),
        h("td.num.time", { text: duration(p.session_seconds) }),
        h("td.num.col-played", { text: p.played_seconds === null ? "–" : duration(p.played_seconds) }));
    });
    return h("table.drivers", null,
      h("thead", null, h("tr", null, h("th", { scope: "col", text: "Driver" }), h("th", { scope: "col", text: "Vehicle" }),
        h("th.num", { scope: "col", text: "This session" }), h("th.num.col-played", { scope: "col", text: "Played" }))),
      h("tbody", null, rows));
  }

  function numbersTable(sv) {
    var st = sv.stats || {};
    var rows = [["Today", st.today], [monthLabel(st.month && sv.leaderboard ? sv.leaderboard.month_key : null), st.month], ["This year", st.year]];
    if (!st.today && !st.month && !st.all_time) {
      return h("p.empty-note", { text: "Numbers appear once the server has reported at least once." });
    }
    var body = rows.filter(function (r) { return r[1]; }).map(function (r) {
      var p = r[1];
      return h("tr", null, h("th", { scope: "row", text: r[0] }),
        h("td", { text: n(p.unique_users) }), h("td", { text: n(p.new_users) }), h("td", { text: n(p.joins) }),
        h("td", { text: n(p.peak_online) }), h("td", { text: (Number(p.avg_online) || 0).toFixed(1) }));
    });
    if (st.all_time) {
      body.push(h("tr", null, h("th", { scope: "row", text: "All time" }), h("td", { text: n(st.all_time.unique_users) }),
        h("td", { text: "" }), h("td", { text: n(st.all_time.joins) }), h("td", { text: "" }), h("td", { text: "" })));
    }
    var table = h("table.numbers", null,
      h("thead", null, h("tr", null, ["", "Players", "New", "Joins", "Peak online", "Avg online"].map(function (t) { return h("th", { scope: "col", text: t }); }))),
      h("tbody", null, body));
    var ret = st.retention;
    var note = ret && ret.rate !== null && ret.rate !== undefined
      ? h("p.chart-note", { text: Number(ret.rate).toFixed(1) + "% of last month's " + n(ret.previous_users) + " players came back this month. " + n(st.joins_24h) + " joins in the last 24 hours." })
      : h("p.chart-note", { text: n(st.joins_24h) + " joins in the last 24 hours." });
    return [table, note];
  }

  function copyButton(text) {
    var b = h("button.copy", { type: "button", text: "Copy" });
    b.addEventListener("click", function () {
      if (!navigator.clipboard) return;
      navigator.clipboard.writeText(text).then(function () {
        b.textContent = "Copied";
        setTimeout(function () { b.textContent = "Copy"; }, 1500);
      });
    });
    return b;
  }

  function renderServer(sv) {
    var id = slug(sv.key);
    var facts = [h("li", null, h("span.status.status-" + sv.status, { text: STATUS_TEXT[sv.status] || sv.status }))];
    if (sv.status === "online" || sv.status === "empty") facts.push(h("li", null, h("strong", { text: sv.player_count + " / " + (sv.max_players || "?") }), " players"));
    if (sv.map) facts.push(h("li", null, "Map ", h("strong", { text: sv.map.replace(/_/g, " ") })));
    if (sv.uptime_seconds) facts.push(h("li", null, "Up ", h("strong", { text: duration(sv.uptime_seconds) })));
    if (sv.connect) facts.push(h("li", null, "Join ", h("strong", { text: sv.connect }), copyButton(sv.connect)));
    facts.push(h("li", { text: "Updated " + ago(sv.received_at) }));

    var section = h("section.wrap.server", { id: id, "aria-labelledby": id + "-h" },
      h("header.server-head", null, h("h2", { id: id + "-h", text: sv.name }), h("ul.server-facts", null, facts)));

    var boardBox = h("div");
    var boardToggle = h("div.toggle", { role: "group", "aria-label": "Leaderboard period" });
    var drawBoard = function () {
      if (!sv.leaderboard) return;
      renderToggle(boardToggle, sv.key, sv.leaderboard.month_key, drawBoard);
      boardBox.textContent = "";
      boardBox.appendChild(boardList(sv.leaderboard[boardScope[sv.key] || "month"], false));
    };

    var grid = h("div.server-grid", null,
      h("div", null, h("h3", { text: "Who's on" }), driversTable(sv)),
      h("div", null, h("h3", { text: "Last 24 hours" }), chart(sv.graph)),
      h("div", null, h("h3", { text: "Numbers" }), numbersTable(sv)),
      h("div", null, h("h3", { text: "When people play" }), heatmap(sv.heatmap, sv.calendar_utc_offset_hours || 0, sv.calendar_name)),
      sv.leaderboard && data.show_player_names ? h("div.span-all", null,
        h("div.board-head", null, h("h3", { text: "Most seat time on this server" }), boardToggle), boardBox) : null);
    section.appendChild(grid);
    drawBoard();
    return section;
  }

  // Load --------------------------------------------------------------------------

  function render() {
    document.title = data.title;
    document.getElementById("site-title").textContent = data.title;
    var local = !data.display_time_zone;
    document.getElementById("updated").textContent = "Updated " + fmtTime(new Date(data.generated_unix * 1000), { hour: "numeric", minute: "2-digit" }) +
      (local ? "" : " " + zoneName()) + ", refreshes every minute";
    document.getElementById("time-note").textContent = "Playtime counts time on a server minus time spent AFK. " +
      (local ? "Times are shown in your own time zone; the activity grid uses each server's calendar, named under the grid."
             : "All times are " + zoneName() + ".");
    renderPlates(data.servers);
    renderSeries(data.series);
    var box = document.getElementById("servers");
    box.textContent = "";
    data.servers.forEach(function (sv) { box.appendChild(renderServer(sv)); });
  }

  function load() {
    fetch("api.php", { cache: "no-store" })
      .then(function (r) {
        if (!r.ok) return r.json().then(function (j) { throw new Error(j.error || ("HTTP " + r.status)); });
        return r.json();
      })
      .then(function (json) { data = json; render(); })
      .catch(function (err) {
        document.getElementById("updated").textContent = "Couldn't load stats: " + err.message + ". Retrying in a minute.";
      });
  }

  load();
  setInterval(function () { if (!document.hidden) load(); }, REFRESH_MS);
})();
