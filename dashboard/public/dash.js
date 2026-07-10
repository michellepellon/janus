// ABOUTME: Renders the Janus dashboard: fetches /api/dashboard and draws Tufte-style
// ABOUTME: SVG sparklines and device on/off strips with crosshair, tooltips, and tables.
"use strict";

// ---------------------------------------------------------------------------
// Pure logic (no DOM) — exported for node tests at the bottom of this file.
// ---------------------------------------------------------------------------

var DAY_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
var DAY_LONG = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
var MONTH_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
var MONTH_LONG = ["January", "February", "March", "April", "May", "June", "July",
  "August", "September", "October", "November", "December"];

function pointMs(p) {
  return p.tMs !== undefined ? p.tMs : Date.parse(p.t);
}

// Linear scale from domain [d0,d1] to range [r0,r1]; also exposes .invert.
function linScale(domain, range) {
  var d0 = domain[0], d1 = domain[1], r0 = range[0], r1 = range[1];
  var span = d1 - d0;
  var scale = function (v) {
    if (span === 0) return (r0 + r1) / 2;
    return r0 + ((v - d0) / span) * (r1 - r0);
  };
  scale.invert = function (r) {
    if (r1 - r0 === 0) return d0;
    return d0 + ((r - r0) / (r1 - r0)) * span;
  };
  return scale;
}

function extentOf(points, key) {
  var min = Infinity, max = -Infinity;
  for (var i = 0; i < points.length; i++) {
    var v = points[i][key];
    if (v < min) min = v;
    if (v > max) max = v;
  }
  return [min, max];
}

// Median interval between successive timestamps (ms). Fewer than 2 times -> 0.
function medianSpacing(times) {
  if (times.length < 2) return 0;
  var diffs = [];
  for (var i = 1; i < times.length; i++) diffs.push(times[i] - times[i - 1]);
  diffs.sort(function (a, b) { return a - b; });
  var mid = diffs.length >> 1;
  return diffs.length % 2 ? diffs[mid] : (diffs[mid - 1] + diffs[mid]) / 2;
}

// Split a series into contiguous segments, breaking where the interval is
// strictly greater than gapFactor x the median spacing (no interpolation
// across missing buckets).
function segmentSeries(points, gapFactor) {
  if (gapFactor === undefined) gapFactor = 2;
  if (points.length === 0) return [];
  var times = points.map(pointMs);
  var med = medianSpacing(times);
  var segs = [];
  var cur = [points[0]];
  for (var i = 1; i < points.length; i++) {
    if (med > 0 && times[i] - times[i - 1] > gapFactor * med) {
      segs.push(cur);
      cur = [];
    }
    cur.push(points[i]);
  }
  segs.push(cur);
  return segs;
}

// SVG path ("M x,y L x,y ...") for one contiguous segment.
function pathFor(segment, xScale, yScale, key) {
  var d = "";
  for (var i = 0; i < segment.length; i++) {
    var p = segment[i];
    var x = +xScale(pointMs(p)).toFixed(2);
    var y = +yScale(p[key]).toFixed(2);
    d += (i === 0 ? "M" : "L") + x + "," + y;
  }
  return d;
}

// Indices of the minimum and maximum values; ties go to the first occurrence.
function minMaxIndices(points, key) {
  if (points.length === 0) return { min: null, max: null };
  var min = 0, max = 0;
  for (var i = 1; i < points.length; i++) {
    if (points[i][key] < points[min][key]) min = i;
    if (points[i][key] > points[max][key]) max = i;
  }
  return { min: min, max: max };
}

// Sparse, round local-time ticks: every 6 h for a day, midnights for 3 d,
// alternate midnights for 7 d, weekly midnights for 30 d.
function tickTimes(startMs, endMs, hours) {
  var stepH, alignH;
  if (hours <= 24) { stepH = 6; alignH = 6; }
  else if (hours <= 72) { stepH = 24; alignH = 24; }
  else if (hours <= 168) { stepH = 48; alignH = 24; }
  else { stepH = 168; alignH = 24; }
  var d = new Date(startMs);
  d.setMinutes(0, 0, 0);
  while (d.getTime() < startMs || d.getHours() % alignH !== 0) {
    d.setHours(d.getHours() + 1);
  }
  var ticks = [];
  while (d.getTime() <= endMs) {
    ticks.push(d.getTime());
    d.setHours(d.getHours() + stepH);
  }
  return ticks;
}

function fmtClock(d) {
  var h = d.getHours();
  var h12 = ((h + 11) % 12) + 1;
  var mm = String(d.getMinutes()).padStart(2, "0");
  return h12 + ":" + mm + " " + (h < 12 ? "am" : "pm");
}

function fmtTemp(v) {
  if (v === null || v === undefined) return "—";
  return v.toFixed(1) + "°";
}

function fmtHum(v) {
  if (v === null || v === undefined) return "—";
  return Math.round(v) + "% rh";
}

// Compact timestamp for tooltips and tables: weekday-prefixed up to a week
// (even a 24 h window crosses midnight, so bare clocks would repeat),
// date-prefixed for a month (weekdays repeat).
function fmtTimeShort(date, hours) {
  var clock = fmtClock(date);
  if (hours <= 168) return DAY_SHORT[date.getDay()] + " " + clock;
  return MONTH_SHORT[date.getMonth()] + " " + date.getDate() + ", " + clock;
}

// Axis-tick label: hour of day for a day, weekday for multi-day, date for a month.
function fmtTick(ms, hours) {
  var d = new Date(ms);
  if (hours <= 24) {
    var h = d.getHours();
    if (h === 0) return "12 am";
    if (h === 12) return "12 pm";
    return h < 12 ? h + " am" : (h - 12) + " pm";
  }
  if (hours <= 168) return DAY_SHORT[d.getDay()];
  return MONTH_SHORT[d.getMonth()] + " " + d.getDate();
}

// Time of the first sample when a series starts materially after the window
// opens (the sensor is younger than the range), else null. The 10% grace
// absorbs bucket alignment at the window edge.
function recordsBeginMs(points, xDomain) {
  if (!points || points.length === 0) return null;
  var firstMs = pointMs(points[0]);
  return firstMs - xDomain[0] > (xDomain[1] - xDomain[0]) * 0.1 ? firstMs : null;
}

// Stale threshold adapted to a series' cadence: at least floorMinutes, widened
// to 2.5x the series' median spacing so a slow-cadence source (an hourly
// weather station) is not flagged by a rule tuned to minute-cadence sensors.
function staleThresholdMinutes(points, floorMinutes) {
  var floor = floorMinutes === undefined ? 15 : floorMinutes;
  var med = medianSpacing((points || []).map(pointMs)) / 60000;
  return Math.max(floor, 2.5 * med);
}

// Time of the latest reading when it lags now beyond the threshold (a sensor
// that has stopped reporting), else null.
function staleSinceMs(latestIso, nowMs, thresholdMinutes) {
  var t = Date.parse(latestIso);
  if (isNaN(t)) return null;
  var minutes = thresholdMinutes === undefined ? 15 : thresholdMinutes;
  return nowMs - t > minutes * 60000 ? t : null;
}

// Month-and-day date, e.g. "Jul 5".
function fmtDate(d) {
  return MONTH_SHORT[d.getMonth()] + " " + d.getDate();
}

// True when the point at index sits within factor x the series' median
// spacing of xMs — i.e. the cursor is genuinely near data, not reaching
// across a gap to a distant point. Series too short to have a spacing are
// always in reach; out-of-range indices never are.
function withinReach(points, index, xMs, factor) {
  if (index < 0 || index >= points.length) return false;
  var med = medianSpacing(points.map(pointMs));
  if (med === 0) return true;
  return Math.abs(pointMs(points[index]) - xMs) <= factor * med;
}

// Signed temperature differential, always with an explicit sign and one
// decimal, using a true minus sign: "+8.1°" / "−3.2°".
function fmtDelta(v) {
  var abs = Math.abs(v).toFixed(1);
  return (v < 0 ? "−" : "+") + abs + "°";
}

// Split a delta series into sign-consistent runs for the diverging wash:
// returns [{sign: 1|-1, points: [...]}], inserting an interpolated
// {tMs, delta: 0} point at each zero crossing so adjacent runs meet exactly
// on the baseline. Zero deltas extend the current run; a leading run of
// zeros takes the sign of the first nonzero value.
function splitAtZero(points) {
  var segs = [];
  var cur = [];
  var sign = 0;
  for (var i = 0; i < points.length; i++) {
    var p = points[i];
    var s = p.delta > 0 ? 1 : p.delta < 0 ? -1 : 0;
    if (s !== 0 && sign === 0) sign = s;
    if (s !== 0 && s !== sign && cur.length > 0) {
      var prev = points[i - 1];
      var t0 = pointMs(prev), t1 = pointMs(p);
      var frac = prev.delta / (prev.delta - p.delta);
      var zero = { tMs: t0 + (t1 - t0) * frac, delta: 0 };
      cur.push(zero);
      segs.push({ sign: sign, points: cur });
      cur = [zero];
      sign = s;
    }
    cur.push(p);
  }
  if (cur.length > 0) segs.push({ sign: sign || 1, points: cur });
  return segs;
}

// Dew point rendered as a whole degree for the cooling sentence.
function fmtDewPoint(v) {
  return Math.round(v) + "°";
}

// The cooling strip's one-line verdict, as parts ({text, value: true} parts
// render in ink). Three states: outside warmer (sealed), cooler and dry
// (free cooling), cooler but muggy (not worth it). Null when there is no
// current differential.
function coolingSentence(now) {
  if (now === null || now === undefined) return null;
  var mag = { text: Math.abs(now.delta).toFixed(1) + "°", value: true };
  if (now.dew_point === null || now.dew_point === undefined) {
    if (now.delta >= 0) {
      return [{ text: "Outside is " }, mag,
        { text: " warmer than the house — keep it sealed" }];
    }
    return [{ text: "Outside is " }, mag,
      { text: " cooler, but the dew point is unknown — keep it sealed" }];
  }
  var dew = { text: fmtDewPoint(now.dew_point), value: true };
  if (now.delta >= 0) {
    return [{ text: "Outside is " }, mag,
      { text: " warmer than the house · dew point " }, dew,
      { text: " — keep it sealed" }];
  }
  if (now.free_cooling) {
    return [{ text: "Outside is " }, mag,
      { text: " cooler · dew point " }, dew,
      { text: " — free cooling available" }];
  }
  return [{ text: "Outside is " }, mag,
    { text: " cooler, but dew point " }, dew,
    { text: " — not worth opening up" }];
}

function intervalMs(iv) {
  return [
    iv.fromMs !== undefined ? iv.fromMs : Date.parse(iv.from),
    iv.toMs !== undefined ? iv.toMs : Date.parse(iv.to),
  ];
}

// Clip state intervals to the x-domain for drawing: ascending
// [{fromMs, toMs, on}], dropping intervals entirely outside the domain and
// any clipped to zero width. Only known state produces a segment.
function intervalSegments(intervals, xDomain) {
  var out = [];
  for (var i = 0; i < (intervals || []).length; i++) {
    var ms = intervalMs(intervals[i]);
    var a = Math.max(ms[0], xDomain[0]);
    var b = Math.min(ms[1], xDomain[1]);
    if (b <= a) continue;
    out.push({ fromMs: a, toMs: b, on: intervals[i].on });
  }
  return out;
}

// Stretches of the domain covered by no interval — periods with no recorded
// state. Rendered as a neutral wash because unknown is not "off".
function unknownRanges(segments, xDomain) {
  var out = [];
  var cursor = xDomain[0];
  for (var i = 0; i < segments.length; i++) {
    if (segments[i].fromMs > cursor) out.push({ fromMs: cursor, toMs: segments[i].fromMs });
    if (segments[i].toMs > cursor) cursor = segments[i].toMs;
  }
  if (cursor < xDomain[1]) out.push({ fromMs: cursor, toMs: xDomain[1] });
  return out;
}

// State recorded at tMs: {on, sinceMs} where sinceMs is when that state
// began (clipped to the queried window server-side), or null when no state
// is recorded there. On a shared boundary the later interval wins — the
// state changed at that instant.
function stateAtTime(intervals, tMs) {
  var list = intervals || [];
  for (var i = 0; i < list.length; i++) {
    var ms = intervalMs(list[i]);
    var last = i === list.length - 1;
    if (tMs >= ms[0] && (tMs < ms[1] || (last && tMs <= ms[1]))) {
      return { on: list[i].on, sinceMs: ms[0] };
    }
  }
  return null;
}

// Compact duration from the two largest units: "3 h 40 m", "2 d 5 h",
// "45 m"; sub-minute clamps to "0 m".
function fmtDuration(ms) {
  var minutes = Math.floor(ms / 60000);
  var days = Math.floor(minutes / 1440);
  var hours = Math.floor((minutes % 1440) / 60);
  var mins = minutes % 60;
  if (days > 0) return days + " d" + (hours > 0 ? " " + hours + " h" : "");
  if (hours > 0) return hours + " h" + (mins > 0 ? " " + mins + " m" : "");
  return mins + " m";
}

var THEME_MODES = ["auto", "light", "dark"];

// Next mode in the auto -> light -> dark cycle; unknown input counts as auto.
function nextTheme(current) {
  var i = THEME_MODES.indexOf(current);
  if (i === -1) i = 0;
  return THEME_MODES[(i + 1) % THEME_MODES.length];
}

// Index of the point nearest to xMs; ties snap to the earlier point.
function nearestIndex(points, xMs) {
  if (points.length === 0) return -1;
  var best = 0;
  var bestDist = Math.abs(pointMs(points[0]) - xMs);
  for (var i = 1; i < points.length; i++) {
    var dist = Math.abs(pointMs(points[i]) - xMs);
    if (dist < bestDist) { best = i; bestDist = dist; }
  }
  return best;
}

// ---------------------------------------------------------------------------
// DOM rendering — only runs in the browser.
// ---------------------------------------------------------------------------

if (typeof document !== "undefined") {
  (function () {
    var SVG_NS = "http://www.w3.org/2000/svg";
    var VBW = 960;
    var PAD_X = 10;
    // Colors live in the stylesheet's custom properties (which follow the
    // prefers-color-scheme media query); read them once per render so SVG
    // marks, rings, and swatches track the active scheme.
    var colors = {};
    function readColors() {
      var cs = getComputedStyle(document.documentElement);
      ["page", "muted", "secondary", "hairline", "temp", "hum", "lights"].forEach(function (name) {
        colors[name] = cs.getPropertyValue("--" + name).trim();
      });
    }
    var PRESETS = [
      { hours: 24, label: "24 h" },
      { hours: 72, label: "3 d" },
      { hours: 168, label: "7 d" },
      { hours: 720, label: "30 d" },
    ];
    var REFRESH_MS = 5 * 60 * 1000;

    var state = { hours: 24, data: null };
    var main = document.getElementById("sensors");
    var coolingEl = document.getElementById("cooling");
    var devicesModule = document.getElementById("lights-module");
    var devicesEl = document.getElementById("devices");
    var generatedEl = document.getElementById("generated");
    var themeBtn = document.getElementById("theme");
    var presetsEl = document.getElementById("presets");
    var tooltip = document.getElementById("tooltip");
    var tooltipVal = tooltip.querySelector(".val");
    var tooltipTime = tooltip.querySelector(".time");

    function el(tag, className, text) {
      var node = document.createElement(tag);
      if (className) node.className = className;
      if (text !== undefined) node.textContent = text;
      return node;
    }

    function svgEl(tag, attrs) {
      var node = document.createElementNS(SVG_NS, tag);
      for (var k in attrs) node.setAttribute(k, attrs[k]);
      return node;
    }

    function hideTooltip() {
      tooltip.style.display = "none";
    }

    // Position the tooltip beside a chart point given in viewBox coordinates.
    function showTooltip(svg, height, xVb, yVb, valueText, timeText) {
      tooltipVal.textContent = valueText;
      tooltipTime.textContent = " — " + timeText;
      tooltip.style.display = "block";
      var rect = svg.getBoundingClientRect();
      var px = rect.left + window.scrollX + (xVb / VBW) * rect.width;
      var py = rect.top + window.scrollY + (yVb / height) * rect.height;
      var left = px + 12;
      var top = py - tooltip.offsetHeight - 10;
      if (left + tooltip.offsetWidth > window.scrollX + document.documentElement.clientWidth - 8) {
        left = px - tooltip.offsetWidth - 12;
      }
      if (left < window.scrollX + 4) left = window.scrollX + 4;
      if (top < window.scrollY + 4) top = py + 14;
      tooltip.style.left = left + "px";
      tooltip.style.top = top + "px";
    }

    // Build one single-series chart (line, gap breaks, min/max/end marks,
    // crosshair, pointer + keyboard interaction).
    function buildChart(opts) {
      var points = opts.points;
      var key = opts.key;
      var height = opts.height;
      var wrap = el("div", "chartwrap");

      var keyRow = el("div", "key");
      var swatch = el("span", "swatch");
      swatch.style.background = opts.color;
      keyRow.appendChild(swatch);
      keyRow.appendChild(el("span", null, opts.unitLabel));
      wrap.appendChild(keyRow);

      // The plot box wraps just the SVG so mark labels can be positioned as
      // percentages of the chart area (the key row above would skew them).
      var plot = el("div", "plot");
      wrap.appendChild(plot);

      var svg = svgEl("svg", {
        viewBox: "0 0 " + VBW + " " + height,
        role: "img",
        tabindex: "0",
        "aria-label": opts.ariaLabel,
      });
      plot.appendChild(svg);

      var padTop = opts.padTop, padBottom = opts.padBottom;
      var xs = linScale(opts.xDomain, [PAD_X, VBW - PAD_X]);
      var ext = extentOf(points, key);
      // A diverging chart anchors its scale to zero even when the data
      // stays on one side of it.
      if (opts.includeZero) {
        if (ext[0] > 0) ext[0] = 0;
        if (ext[1] < 0) ext[1] = 0;
      }
      if (ext[0] === ext[1]) { ext = [ext[0] - 1, ext[1] + 1]; }
      var ys = linScale(ext, [height - padBottom, padTop]);

      // Underlays (washes, baselines) go in before the line so it stays on top.
      if (opts.decorate) opts.decorate(svg, xs, ys);

      var segs = segmentSeries(points);
      for (var i = 0; i < segs.length; i++) {
        svg.appendChild(svgEl("path", {
          d: pathFor(segs[i], xs, ys, key),
          fill: "none",
          stroke: opts.color,
          "stroke-width": "2",
          "stroke-linejoin": "round",
          "stroke-linecap": "round",
        }));
      }

      function dot(p) {
        return svgEl("circle", {
          cx: xs(pointMs(p)).toFixed(2),
          cy: ys(p[key]).toFixed(2),
          r: "4",
          fill: opts.color,
          stroke: colors.page,
          "stroke-width": "2",
        });
      }

      // Direct labels for min and max: HTML spans positioned as percentages
      // of the plot box so they render at a fixed screen size regardless of
      // chart width. Nudged away from the line, flipped when they would leave
      // the chart, and clamped inside the plot box (never over the tick row);
      // text stays in the secondary color, never the data color.
      var labelGap = 6;
      function mark(idx, below) {
        var p = points[idx];
        var x = xs(pointMs(p));
        var y = ys(p[key]);
        svg.appendChild(dot(p));
        if (below && y + labelGap > height - 4) below = false;
        if (!below && y - labelGap < 4) below = true;
        var tx = "-50%";
        if (x < 42) tx = "0%";
        if (x > VBW - 42) tx = "-100%";
        var lbl = el("span", "marklabel", opts.fmtLabel(p[key]));
        lbl.style.left = ((x / VBW) * 100).toFixed(2) + "%";
        if (below) {
          lbl.style.top = "min(" + (((y + labelGap) / height) * 100).toFixed(2) + "%, calc(100% - 0.8rem))";
          lbl.style.transform = "translate(" + tx + ", 0)";
        } else {
          lbl.style.top = "max(" + (((y - labelGap) / height) * 100).toFixed(2) + "%, 0.8rem)";
          lbl.style.transform = "translate(" + tx + ", -100%)";
        }
        plot.appendChild(lbl);
      }

      var mm = minMaxIndices(points, key);
      mark(mm.max, false);
      if (mm.min !== mm.max) mark(mm.min, true);
      svg.appendChild(dot(points[points.length - 1])); // end dot, no label

      var crosshair = svgEl("line", {
        y1: "0", y2: String(height),
        stroke: colors.muted, "stroke-width": "1",
        style: "display:none",
      });
      svg.appendChild(crosshair);

      var activeIdx = -1;
      function showAt(idx) {
        if (idx < 0 || idx >= points.length) return;
        activeIdx = idx;
        var p = points[idx];
        var x = xs(pointMs(p));
        crosshair.setAttribute("x1", x.toFixed(2));
        crosshair.setAttribute("x2", x.toFixed(2));
        crosshair.style.display = "";
        showTooltip(svg, height, x, ys(p[key]),
          opts.fmtValue(p[key]),
          fmtTimeShort(new Date(pointMs(p)), opts.hours));
      }
      function clear() {
        activeIdx = -1;
        crosshair.style.display = "none";
        hideTooltip();
      }

      svg.addEventListener("pointermove", function (e) {
        var rect = svg.getBoundingClientRect();
        var xVb = ((e.clientX - rect.left) / rect.width) * VBW;
        var xMs = xs.invert(xVb);
        var idx = nearestIndex(points, xMs);
        // Over a void (a gap or the empty edge of a young sensor), hide the
        // crosshair rather than teleporting it to a distant point.
        if (withinReach(points, idx, xMs, 3)) showAt(idx);
        else clear();
      });
      svg.addEventListener("pointerleave", clear);
      svg.addEventListener("keydown", function (e) {
        if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
          e.preventDefault();
          var idx = activeIdx;
          if (idx === -1) idx = points.length - 1;
          else idx += e.key === "ArrowRight" ? 1 : -1;
          showAt(Math.max(0, Math.min(points.length - 1, idx)));
        } else if (e.key === "Home") {
          e.preventDefault();
          showAt(0);
        } else if (e.key === "End") {
          e.preventDefault();
          showAt(points.length - 1);
        } else if (e.key === "Escape") {
          clear();
        }
      });
      svg.addEventListener("focus", function () { showAt(points.length - 1); });
      svg.addEventListener("blur", clear);

      return wrap;
    }

    function buildTicksRow(xDomain, hours) {
      var row = el("div", "ticks");
      var ticks = tickTimes(xDomain[0], xDomain[1], hours);
      var xs = linScale(xDomain, [PAD_X, VBW - PAD_X]);
      for (var i = 0; i < ticks.length; i++) {
        var span = el("span", "tick", fmtTick(ticks[i], hours));
        span.style.left = ((xs(ticks[i]) / VBW) * 100).toFixed(2) + "%";
        row.appendChild(span);
      }
      return row;
    }

    function buildDataTable(points, hours) {
      var details = el("details", "datatable");
      details.appendChild(el("summary", null, "readings"));
      var scroller = el("div", "tablescroll");
      var table = document.createElement("table");
      var thead = document.createElement("thead");
      var hr = document.createElement("tr");
      hr.appendChild(el("th", "tcol", "time"));
      hr.appendChild(el("th", "ncol", "°F"));
      hr.appendChild(el("th", "ncol", "% rh"));
      thead.appendChild(hr);
      table.appendChild(thead);
      var tbody = document.createElement("tbody");
      // Newest reading first: the latest row is the one people come for.
      for (var i = points.length - 1; i >= 0; i--) {
        var p = points[i];
        var tr = document.createElement("tr");
        tr.appendChild(el("td", "tcol", fmtTimeShort(new Date(pointMs(p)), hours)));
        tr.appendChild(el("td", "ncol", p.temp.toFixed(1)));
        tr.appendChild(el("td", "ncol", p.hum.toFixed(1)));
        tbody.appendChild(tr);
      }
      table.appendChild(tbody);
      scroller.appendChild(table);
      details.appendChild(scroller);
      return details;
    }

    function buildSensor(sensor, xDomain, hours, openTables) {
      var section = el("section", "sensor");

      var meta = el("div", "meta");
      meta.appendChild(el("h3", "name", sensor.name));
      var latest = sensor.latest;
      meta.appendChild(el("div", "big", latest ? fmtTemp(latest.temperature) : "—"));
      if (latest) meta.appendChild(el("div", "humnow", fmtHum(latest.humidity)));
      var staleMs = latest ?
        staleSinceMs(latest.observed, xDomain[1], staleThresholdMinutes(sensor.series)) : null;
      if (staleMs !== null) {
        meta.appendChild(el("div", "note", "as of " + fmtTimeShort(new Date(staleMs), hours)));
      }
      var beginMs = recordsBeginMs(sensor.series, xDomain);
      if (beginMs !== null) {
        meta.appendChild(el("div", "note", "records begin " + fmtDate(new Date(beginMs))));
      }
      if (typeof sensor.battery_percentage === "number" && sensor.battery_percentage < 25) {
        meta.appendChild(el("div", "battery", "battery " + Math.round(sensor.battery_percentage) + "%"));
      }
      section.appendChild(meta);

      var charts = el("div", "charts");
      if (!latest || !sensor.series || sensor.series.length === 0) {
        charts.appendChild(el("div", "nodata", "no data in range"));
        section.appendChild(charts);
        return section;
      }

      charts.appendChild(buildChart({
        points: sensor.series, key: "temp",
        height: 96, padTop: 20, padBottom: 18,
        color: colors.temp, unitLabel: "°F",
        xDomain: xDomain, hours: hours,
        ariaLabel: sensor.name + " temperature, " + hoursLabel(hours),
        fmtValue: fmtTemp,
        fmtLabel: fmtTemp,
      }));
      charts.appendChild(buildTicksRow(xDomain, hours));
      charts.appendChild(buildChart({
        points: sensor.series, key: "hum",
        height: 56, padTop: 20, padBottom: 13,
        color: colors.hum, unitLabel: "% rh",
        xDomain: xDomain, hours: hours,
        ariaLabel: sensor.name + " humidity, " + hoursLabel(hours),
        fmtValue: fmtHum,
        fmtLabel: function (v) { return Math.round(v) + "%"; },
      }));
      var table = buildDataTable(sensor.series, hours);
      table.dataset.sensorId = sensor.id;
      if (openTables && openTables[sensor.id]) table.open = true;
      charts.appendChild(table);
      section.appendChild(charts);
      return section;
    }

    // The cooling strip: a one-line verdict on opening up the house plus a
    // diverging outside-minus-house chart. The line stays neutral (secondary
    // text color); the wash between line and zero carries the sign — warm
    // red above the baseline, cool blue below.
    function buildCoolingStrip(cooling, xDomain, hours) {
      var strip = el("section", "cooling");

      var parts = coolingSentence(cooling.now);
      if (parts) {
        var sentence = el("p", "sentence");
        for (var i = 0; i < parts.length; i++) {
          sentence.appendChild(el("span", parts[i].value ? "val" : null, parts[i].text));
        }
        strip.appendChild(sentence);
      }

      var points = cooling.series;
      var charts = el("div", "charts");
      charts.appendChild(buildChart({
        points: points, key: "delta",
        height: 72, padTop: 14, padBottom: 12,
        color: colors.secondary, unitLabel: "Δ °F, outside − house",
        xDomain: xDomain, hours: hours,
        ariaLabel: "Outside minus house temperature difference, " + hoursLabel(hours),
        fmtValue: function (v) { return "Δ " + fmtDelta(v); },
        fmtLabel: fmtDelta,
        includeZero: true,
        decorate: function (svg, xs, ys) {
          var y0 = ys(0).toFixed(2);
          var gapSegs = segmentSeries(points);
          for (var g = 0; g < gapSegs.length; g++) {
            var signed = splitAtZero(gapSegs[g]);
            for (var s = 0; s < signed.length; s++) {
              var run = signed[s];
              if (run.points.length < 2) continue;
              var d = pathFor(run.points, xs, ys, "delta") +
                "L" + xs(pointMs(run.points[run.points.length - 1])).toFixed(2) + "," + y0 +
                "L" + xs(pointMs(run.points[0])).toFixed(2) + "," + y0 + "Z";
              svg.appendChild(svgEl("path", {
                d: d,
                fill: run.sign >= 0 ? colors.temp : colors.hum,
                "fill-opacity": "0.1",
                stroke: "none",
              }));
            }
          }
          svg.appendChild(svgEl("line", {
            x1: String(PAD_X), x2: String(VBW - PAD_X), y1: y0, y2: y0,
            stroke: colors.hairline, "stroke-width": "1",
          }));
        },
      }));
      strip.appendChild(charts);
      return strip;
    }

    // The on/off journal strip for one device: on-intervals filled in the
    // lights amber, known-off left as page background, and unknown stretches
    // (no recorded state) washed in the hairline color at low opacity —
    // encoding chosen so absence of data never reads as "off". Crosshair,
    // tooltip, and keyboard interaction mirror the sensor charts, stepping
    // across state-change boundaries.
    function buildStateStrip(device, xDomain, hours) {
      var height = 28;
      var wrap = el("div", "stripwrap");
      var svg = svgEl("svg", {
        viewBox: "0 0 " + VBW + " " + height,
        role: "img",
        tabindex: "0",
        "aria-label": device.name + " on/off history, " + hoursLabel(hours),
      });
      wrap.appendChild(svg);

      var xs = linScale(xDomain, [PAD_X, VBW - PAD_X]);
      var segments = intervalSegments(device.intervals, xDomain);

      function band(fromMs, toMs, fill, opacity) {
        svg.appendChild(svgEl("rect", {
          x: xs(fromMs).toFixed(2),
          y: "1",
          width: Math.max(0, xs(toMs) - xs(fromMs)).toFixed(2),
          height: String(height - 2),
          fill: fill,
          "fill-opacity": opacity,
        }));
      }

      var gaps = unknownRanges(segments, xDomain);
      for (var g = 0; g < gaps.length; g++) {
        band(gaps[g].fromMs, gaps[g].toMs, colors.hairline, "0.3");
      }
      for (var s = 0; s < segments.length; s++) {
        if (segments[s].on) band(segments[s].fromMs, segments[s].toMs, colors.lights, "1");
      }
      ["0.5", String(height - 0.5)].forEach(function (y) {
        svg.appendChild(svgEl("line", {
          x1: String(PAD_X), x2: String(VBW - PAD_X), y1: y, y2: y,
          stroke: colors.hairline, "stroke-width": "1",
        }));
      });

      var crosshair = svgEl("line", {
        y1: "0", y2: String(height),
        stroke: colors.muted, "stroke-width": "1",
        style: "display:none",
      });
      svg.appendChild(crosshair);

      function showAtMs(xMs) {
        var st = stateAtTime(device.intervals, xMs);
        if (!st) { clear(); return; }
        var x = xs(xMs);
        crosshair.setAttribute("x1", x.toFixed(2));
        crosshair.setAttribute("x2", x.toFixed(2));
        crosshair.style.display = "";
        showTooltip(svg, height, x, height / 2,
          st.on ? "on" : "off",
          "since " + fmtTimeShort(new Date(st.sinceMs), hours));
      }
      function clear() {
        activeStop = -1;
        crosshair.style.display = "none";
        hideTooltip();
      }

      // Keyboard stops: each state change plus the end of the record.
      var stops = segments.map(function (seg) { return seg.fromMs; });
      if (segments.length > 0) stops.push(segments[segments.length - 1].toMs);
      var activeStop = -1;
      function showStop(idx) {
        if (stops.length === 0) return;
        activeStop = Math.max(0, Math.min(stops.length - 1, idx));
        showAtMs(stops[activeStop]);
      }

      svg.addEventListener("pointermove", function (e) {
        var rect = svg.getBoundingClientRect();
        var xVb = ((e.clientX - rect.left) / rect.width) * VBW;
        showAtMs(xs.invert(xVb));
      });
      svg.addEventListener("pointerleave", clear);
      svg.addEventListener("keydown", function (e) {
        if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
          e.preventDefault();
          if (activeStop === -1) showStop(stops.length - 1);
          else showStop(activeStop + (e.key === "ArrowRight" ? 1 : -1));
        } else if (e.key === "Home") {
          e.preventDefault();
          showStop(0);
        } else if (e.key === "End") {
          e.preventDefault();
          showStop(stops.length - 1);
        } else if (e.key === "Escape") {
          clear();
        }
      });
      svg.addEventListener("focus", function () { showStop(stops.length - 1); });
      svg.addEventListener("blur", clear);

      return wrap;
    }

    function buildDeviceRow(device, xDomain, hours) {
      var row = el("div", "device");

      var meta = el("div", "meta");
      meta.appendChild(el("h3", "name", device.name));
      if (device.room) meta.appendChild(el("div", "room", device.room));
      var stateRow = el("div", "staterow");
      if (device.on === null || device.on === undefined) {
        stateRow.appendChild(el("span", "state unknown", "no record yet"));
      } else {
        stateRow.appendChild(el("span", "state " + (device.on ? "ison" : "isoff"),
          device.on ? "on" : "off"));
        // How long the current state has held (from the recorded journal,
        // clipped to the window like everything else on the page).
        var current = stateAtTime(device.intervals, xDomain[1]);
        if (current && current.on === device.on) {
          stateRow.appendChild(el("span", "statefor",
            " for " + fmtDuration(xDomain[1] - current.sinceMs)));
        }
      }
      meta.appendChild(stateRow);
      row.appendChild(meta);

      var strip = el("div", "strip");
      strip.appendChild(buildStateStrip(device, xDomain, hours));
      row.appendChild(strip);
      return row;
    }

    // The lights & outlets module renders only when devices exist; a house
    // without a paired bridge never sees an empty shell.
    function renderDevices(devices, xDomain, hours) {
      devicesEl.textContent = "";
      if (!devices || devices.length === 0) {
        devicesModule.hidden = true;
        return;
      }
      devicesModule.hidden = false;
      devicesEl.classList.remove("stale");
      for (var i = 0; i < devices.length; i++) {
        devicesEl.appendChild(buildDeviceRow(devices[i], xDomain, hours));
      }
      // One sparse tick row for the whole module, aligned with the strips.
      var ticksRow = el("div", "device-ticks");
      ticksRow.appendChild(el("div"));
      var strip = el("div", "strip");
      strip.appendChild(buildTicksRow(xDomain, hours));
      ticksRow.appendChild(strip);
      devicesEl.appendChild(ticksRow);
    }

    function hoursLabel(hours) {
      if (hours <= 24) return "24 hours";
      return (hours / 24) + " days";
    }

    function fmtGenerated(d) {
      return DAY_LONG[d.getDay()] + ", " + MONTH_LONG[d.getMonth()] + " " +
        d.getDate() + " · " + fmtClock(d);
    }

    function showMessage(text) {
      hideTooltip();
      coolingEl.textContent = "";
      coolingEl.classList.remove("stale");
      main.textContent = "";
      main.appendChild(el("div", "message", text));
      main.classList.remove("stale");
      devicesEl.textContent = "";
      devicesModule.hidden = true;
    }

    function render(data) {
      hideTooltip();
      readColors();
      // The timestamp is the data's freshness, not a wall clock, so say so.
      // Assigning textContent also drops any pending update-failure marker.
      generatedEl.textContent = "data as of " + fmtGenerated(new Date(data.generated_at));
      // Carry each sensor's open data table across the rebuild.
      var openTables = {};
      main.querySelectorAll(".datatable[open]").forEach(function (d) {
        openTables[d.dataset.sensorId] = true;
      });
      main.textContent = "";
      var endMs = Date.parse(data.generated_at);
      var xDomain = [endMs - data.hours * 3600 * 1000, endMs];
      if (!data.sensors || data.sensors.length === 0) {
        showMessage("No readings yet — add SensorPush credentials to .env and run bin/collect.");
        renderDevices(data.devices, xDomain, data.hours);
        return;
      }
      renderDevices(data.devices, xDomain, data.hours);
      coolingEl.textContent = "";
      if (data.cooling && data.cooling.series && data.cooling.series.length > 0) {
        coolingEl.appendChild(buildCoolingStrip(data.cooling, xDomain, data.hours));
      }
      coolingEl.classList.remove("stale");
      for (var i = 0; i < data.sensors.length; i++) {
        main.appendChild(buildSensor(data.sensors[i], xDomain, data.hours, openTables));
      }
      main.classList.remove("stale");
    }

    function renderPresets() {
      presetsEl.textContent = "";
      for (var i = 0; i < PRESETS.length; i++) {
        if (i > 0) presetsEl.appendChild(el("span", "sep", "·"));
        var a = el("a", state.hours === PRESETS[i].hours ? "selected" : "", PRESETS[i].label);
        a.href = "?hours=" + PRESETS[i].hours;
        a.dataset.hours = String(PRESETS[i].hours);
        presetsEl.appendChild(a);
      }
    }

    // dim=true marks a user-initiated range change, where the old charts no
    // longer answer the question being asked; background refreshes keep the
    // current render at full strength until new data lands.
    function load(hours, dim) {
      if (dim) {
        main.classList.add("stale");
        coolingEl.classList.add("stale");
        devicesEl.classList.add("stale");
      }
      fetch("/api/dashboard?hours=" + hours)
        .then(function (res) {
          if (!res.ok) throw new Error("http " + res.status);
          return res.json();
        })
        .then(function (data) {
          state.data = data;
          render(data);
        })
        .catch(function () {
          // Keep any previous render on screen; the refresh timer retries.
          if (!state.data) { showMessage("Can't reach the server."); return; }
          main.classList.remove("stale");
          coolingEl.classList.remove("stale");
          devicesEl.classList.remove("stale");
          if (!generatedEl.querySelector(".updatefail")) {
            generatedEl.appendChild(el("span", "updatefail", " · update failed — retrying"));
          }
        });
    }

    presetsEl.addEventListener("click", function (e) {
      var a = e.target.closest("a");
      if (!a) return;
      e.preventDefault();
      var hours = parseInt(a.dataset.hours, 10);
      if (hours === state.hours) return;
      state.hours = hours;
      history.replaceState(null, "", "?hours=" + hours);
      renderPresets();
      load(hours, true);
    });

    // Theme override: "auto" follows the OS via the media query; "light" and
    // "dark" pin the palette by stamping data-theme on the root element. The
    // meta color-scheme follows so scrollbars and form controls match.
    var THEME_STORAGE_KEY = "janus-theme";
    var theme = localStorage.getItem(THEME_STORAGE_KEY);
    if (THEME_MODES.indexOf(theme) === -1) theme = "auto";

    function applyTheme() {
      if (theme === "auto") delete document.documentElement.dataset.theme;
      else document.documentElement.dataset.theme = theme;
      document.querySelector('meta[name="color-scheme"]')
        .setAttribute("content", theme === "auto" ? "light dark" : theme);
      themeBtn.textContent = "theme: " + theme;
      themeBtn.setAttribute("aria-label", "theme: " + theme);
    }

    themeBtn.addEventListener("click", function () {
      theme = nextTheme(theme);
      try { localStorage.setItem(THEME_STORAGE_KEY, theme); } catch (e) { /* private mode */ }
      applyTheme();
      // Redraw so canvas-side colors (SVG strokes, washes, dot rings,
      // swatches) re-read the custom properties under the new theme.
      if (state.data) render(state.data);
    });
    applyTheme();

    // Re-render on light/dark scheme changes so canvas-side colors (SVG
    // strokes, dot rings, swatches) pick up the new custom-property values.
    // Under a pinned theme the palette doesn't change, so the redraw is a
    // harmless no-op.
    matchMedia("(prefers-color-scheme: dark)").addEventListener("change", function () {
      if (state.data) render(state.data);
    });

    var param = parseInt(new URLSearchParams(location.search).get("hours"), 10);
    if ([24, 72, 168, 720].indexOf(param) !== -1) state.hours = param;
    renderPresets();
    load(state.hours);
    setInterval(function () { load(state.hours); }, REFRESH_MS);
  })();
}

if (typeof module !== "undefined") {
  module.exports = {
    linScale: linScale,
    extentOf: extentOf,
    medianSpacing: medianSpacing,
    segmentSeries: segmentSeries,
    pathFor: pathFor,
    minMaxIndices: minMaxIndices,
    tickTimes: tickTimes,
    fmtTemp: fmtTemp,
    fmtHum: fmtHum,
    fmtTimeShort: fmtTimeShort,
    fmtDate: fmtDate,
    recordsBeginMs: recordsBeginMs,
    staleSinceMs: staleSinceMs,
    staleThresholdMinutes: staleThresholdMinutes,
    fmtTick: fmtTick,
    nearestIndex: nearestIndex,
    withinReach: withinReach,
    fmtDelta: fmtDelta,
    splitAtZero: splitAtZero,
    coolingSentence: coolingSentence,
    nextTheme: nextTheme,
    intervalSegments: intervalSegments,
    unknownRanges: unknownRanges,
    stateAtTime: stateAtTime,
    fmtDuration: fmtDuration,
  };
}
